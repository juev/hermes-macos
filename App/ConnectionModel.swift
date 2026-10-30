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
    private var task: Task<Void, Never>?
    private let bookmarks = ServerBookmarks()
    private(set) var gatewaySession: GatewaySession?
    /// The one listener of the socket, which feeds every chat the window holds.
    private(set) var chatHub: ChatHub?
    private(set) var dashboardSession: DashboardSession?

    var endpoint: Endpoint? { Endpoint(address: address) }

    var isBusy: Bool { phase == .checking || phase == .waitingForBrowser }

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

    /// Lets the dashboard go: the window goes back to the address, the tokens stay in the Keychain.
    func disconnect() {
        task?.cancel()
        stopSocket()
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

    private func openSocket(endpoint: Endpoint, session dashboard: DashboardSession) async throws {
        dashboardSession = dashboard

        let session = GatewaySession(
            endpoint: endpoint,
            credentials: dashboard,
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

        // A dashboard published only on the tailnet has no route while Tailscale is off, and a
        // request would hang for its whole timeout. Say that at once instead.
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

        let client = DashboardClient(endpoint: endpoint)
        do {
            let status = try await client.status()
            // The Keychain may already hold tokens of this dashboard: use them instead of sending
            // the person through the browser again on every launch.
            let session = DashboardSession(endpoint: endpoint, storage: VaultTokenStorage(vault: AppSecrets.vault))
            try? await session.load()
            if status.authRequired {
                if try await needsBrowserSignIn(session) {
                    guard allowingSignIn else {
                        phase = .failed("The sign-in of this dashboard has run out. Connect again to sign in.")
                        return
                    }
                    phase = .waitingForBrowser
                    let signed = try await signIn(to: client, providers: status.authProviders)
                    try await session.adopt(signed)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            try await openSocket(endpoint: endpoint, session: session)
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
