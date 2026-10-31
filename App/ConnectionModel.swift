import AppKit
import HermesCore
import Observation

/// The state of the first screen: an address, a dashboard, and the sign-in the dashboard asks for.
@MainActor
@Observable
final class ConnectionModel {
    enum Phase: Equatable {
        case idle
        case checking
        /// The app's own node is joining the tailnet before the dashboard is asked anything.
        case joiningTailnet
        case waitingForBrowser
        case connected(ServerStatus)
        case failed(String)
    }

    /// True while the dashboard of the last launch is being opened again: the window shows what it
    /// kept instead of asking for an address it already knows.
    private(set) var isRestoring = false

    var address = "" {
        didSet {
            if case .failed = phase { phase = .idle }
        }
    }

    private(set) var phase: Phase = .idle
    /// Where the socket of the dashboard is, once the sign-in is done.
    private(set) var gateway: GatewaySession.State = .idle
    /// True when the address is on the tailnet and this Mac has no tailnet route.
    private(set) var needsTailscale = false
    /// The tailnet this app can join itself, which replaces the Tailscale app for this dashboard.
    let tailnet = TailnetModel()
    private var task: Task<Void, Never>?
    private let bookmarks = ServerBookmarks()
    private(set) var gatewaySession: GatewaySession?
    /// The one listener of the socket, which feeds every chat the window holds.
    private(set) var chatHub: ChatHub?
    private(set) var dashboardSession: DashboardSession?

    init() {
        // The route can change under an open dashboard — the node is left, started, or the setting
        // that runs it is turned off — and the transports have to follow it.
        tailnet.onRouteChange = { [weak self] in self?.routeChanged() }
    }

    var endpoint: Endpoint? { Endpoint(address: address) }

    var isBusy: Bool { phase == .checking || phase == .joiningTailnet || phase == .waitingForBrowser }

    var canConnect: Bool { endpoint != nil && !isBusy }

    func connect() {
        connect(allowingSignIn: true)
    }

    /// Opens the dashboard this Mac used last, without a browser sign-in: if the tokens it kept are
    /// still good the person lands in the chats, and if they are not the connect screen says so.
    func restore() async {
        guard address.isEmpty, let last = bookmarks.last else {
            Log.app.notice("no dashboard remembered")
            return
        }
        Log.app.notice("restoring \(last, privacy: .public)")
        address = last
        guard let endpoint = Endpoint(address: last) else { return }
        isRestoring = true
        defer { isRestoring = false }
        await connect(to: endpoint, allowingSignIn: false)
    }

    /// Lets the dashboard go: the window goes back to the address, the tokens stay in the Keychain,
    /// and a tailnet this app joined is left with it.
    func disconnect() {
        task?.cancel()
        stopSocket()
        tailnet.leave()
        phase = .idle
        gateway = .idle
    }

    private func connect(allowingSignIn: Bool) {
        guard let endpoint, canConnect || !allowingSignIn else { return }
        task?.cancel()
        task = Task { await connect(to: endpoint, allowingSignIn: allowingSignIn) }
    }

    /// True when the stored tokens are gone or refused; false when they still open the dashboard.
    private func needsBrowserSignIn(_ session: DashboardSession) async throws -> Bool {
        guard let stored = try await session.load(), !stored.accessToken.isEmpty else { return true }
        do {
            _ = try await session.sessions(limit: 1)
            return false
        } catch let error as DashboardError where error.needsSignIn {
            return true
        } catch let error as SessionError where error == .signInRequired {
            return true
        }
    }

    private func openSocket(endpoint: Endpoint, session dashboard: DashboardSession, transport: any SocketTransport) async throws {
        dashboardSession = dashboard

        let session = GatewaySession(
            endpoint: endpoint,
            credentials: dashboard,
            transport: transport,
            onState: { [weak self] state in
                Log.app.notice("socket \(String(describing: state), privacy: .public)")
                Task { @MainActor in self?.gateway = state }
            }
        )
        gatewaySession = session
        chatHub = ChatHub(gateway: session)
        await session.start()
    }

    private func stopSocket() {
        let session = gatewaySession
        gatewaySession = nil
        chatHub = nil
        dashboardSession = nil
        if let session {
            Task { await session.stop() }
        }
    }

    /// The tailnet route changed under the open socket. A `URLSession` keeps the proxy it was built
    /// with and cannot be re-aimed, so the ticket session and the socket session are handed transports
    /// for the route in force, and the socket is opened again on them — closing it is what makes the
    /// session come back over the new route instead of retrying through a port the node left behind.
    private func routeChanged() {
        guard let dashboard = dashboardSession, let gateway = gatewaySession else { return }
        let proxy = tailnet.proxy
        let route = proxy == nil ? "the system route" : "the node"
        Log.app.notice("tailnet: the route changed, reconnecting through \(route, privacy: .public)")
        Task {
            await dashboard.setTransport(URLSessionTransport(proxy: proxy))
            await gateway.setTransport(URLSessionSocketTransport(proxy: proxy))
            await gateway.reconnect()
        }
    }

    /// Opens the Tailscale app so the person can turn the tailnet on.
    func openTailscale() {
        let app = URL(fileURLWithPath: "/Applications/Tailscale.app")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func connect(to endpoint: Endpoint, allowingSignIn: Bool = true) async {
        phase = .checking
        needsTailscale = false
        gateway = .idle
        stopSocket()

        // A dashboard that only the tailnet reaches is reached by the node this app carries, which
        // joins the control server — Headscale, or Tailscale — before the dashboard is asked
        // anything. Without the route, the address is read first: a request to a tailnet address
        // that has no route would hang for its whole timeout.
        var proxy: TailnetProxy?
        if tailnet.isEnabled {
            phase = .joiningTailnet
            do {
                proxy = try await tailnet.bringUp()
            } catch is CancellationError {
                phase = .idle
                return
            } catch {
                Log.app.error("tailnet: \(ErrorMessage.of(error), privacy: .public)")
                phase = .failed(ErrorMessage.of(error))
                return
            }
        } else {
            let host = endpoint.base.host
            let refusal = await Task.detached { () -> ConnectRefusal? in
                guard let host else { return nil }
                return ConnectPreflight.refusal(
                    host: host,
                    addresses: Tailnet.resolvedAddresses(of: host),
                    tailnetUp: Tailnet.isUp()
                )
            }.value
            if let refusal {
                needsTailscale = true
                phase = .failed(refusal.message)
                return
            }
        }

        let http = URLSessionTransport(proxy: proxy)
        let client = DashboardClient(endpoint: endpoint, transport: http)
        do {
            let status = try await client.status()
            // The Keychain may already hold tokens of this dashboard: use them instead of sending
            // the person through the browser again on every launch.
            let session = DashboardSession(endpoint: endpoint, transport: http, storage: VaultTokenStorage(vault: AppSecrets.vault))
            try? await session.load()
            if status.authRequired {
                if try await needsBrowserSignIn(session) {
                    guard allowingSignIn else {
                        phase = .failed("The sign-in of this dashboard has run out. Connect again to sign in.")
                        return
                    }
                    // A browser reaches the dashboard over the network this Mac is on, not through
                    // the node: a sign-in page on a tailnet-only address would open and fail.
                    if proxy != nil {
                        phase = .failed("This dashboard asks the browser to sign in, and the browser does not go through the built-in tailnet. Turn the built-in tailnet off, connect once so the sign-in can run, then turn it back on: the tokens it keeps work through the node.")
                        return
                    }
                    phase = .waitingForBrowser
                    let signed = try await signIn(to: client, providers: status.authProviders)
                    try await session.adopt(signed)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            try await openSocket(
                endpoint: endpoint,
                session: session,
                transport: URLSessionSocketTransport(proxy: proxy)
            )
            bookmarks.remember(endpoint.base.absoluteString)
            phase = .connected(status)
            Log.app.notice("connected to \(endpoint.base.absoluteString, privacy: .public) v\(status.version ?? "-", privacy: .public)")
        } catch is CancellationError {
            phase = .idle
        } catch {
            Log.app.error("connect failed: \(ErrorMessage.of(error), privacy: .public)")
            phase = .failed(ErrorMessage.of(error))
        }
    }

    private func signIn(to client: DashboardClient, providers: [String]) async throws -> Tokens {
        let receiver = try LoopbackReceiver()
        return try await SignInFlow(client: client).signIn(
            // One provider is no choice; with several the picker comes with the accounts screen.
            provider: providers.count == 1 ? providers[0] : nil,
            receiver: receiver,
            openBrowser: { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
        )
    }

}
