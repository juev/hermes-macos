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
    private var gatewaySession: GatewaySession?
    private var dashboardSession: DashboardSession?

    var endpoint: Endpoint? { Endpoint(address: address) }

    var isBusy: Bool { phase == .checking || phase == .waitingForBrowser }

    var canConnect: Bool { endpoint != nil && !isBusy }

    func connect() {
        guard let endpoint, canConnect else { return }
        task?.cancel()
        task = Task { await connect(to: endpoint) }
    }

    private func openSocket(endpoint: Endpoint, tokens: Tokens?) async throws {
        let dashboard = DashboardSession(endpoint: endpoint, storage: KeychainTokenStorage())
        try await dashboard.adopt(tokens)
        dashboardSession = dashboard

        let session = GatewaySession(
            endpoint: endpoint,
            credentials: dashboard,
            onState: { [weak self] state in
                Task { @MainActor in self?.gateway = state }
            }
        )
        gatewaySession = session
        await session.start()
    }

    private func stopSocket() {
        let session = gatewaySession
        gatewaySession = nil
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

    private func connect(to endpoint: Endpoint) async {
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
            let tokens: Tokens?
            if status.authRequired {
                phase = .waitingForBrowser
                let signed = try await signIn(to: client, providers: status.authProviders)
                try KeychainTokenStorage().save(signed, for: endpoint.base.absoluteString)
                NSApp.activate(ignoringOtherApps: true)
                tokens = signed
            } else {
                tokens = nil
            }
            try await openSocket(endpoint: endpoint, tokens: tokens)
            phase = .connected(status)
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(Self.message(for: error))
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

    /// What a person can do about the failure, not the failure itself.
    static func message(for error: Error) -> String {
        if let error = error as? SignInError {
            switch error {
            case .refused(_, let description):
                return description ?? "The identity provider refused the sign-in."
            case .stateMismatch:
                return "The browser came back with another sign-in. Try again."
            case .notNeeded:
                return "This dashboard does not ask for a sign-in."
            }
        }
        if let error = error as? DashboardError {
            if error.providerUnavailable {
                return "The dashboard cannot reach its identity provider right now. Try again in a moment."
            }
            return error.detail
        }
        if let error = error as? LoopbackError {
            switch error {
            case .timedOut:
                return "The browser did not come back. Try again."
            case .cancelled:
                return "The sign-in was cancelled."
            case .socket(let code):
                return "The sign-in could not listen on the loopback address (error \(code))."
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                return "No dashboard answers at that address."
            case .notConnectedToInternet:
                return "This Mac is not connected to the network."
            case .timedOut:
                return "The dashboard did not answer in time."
            default:
                return error.localizedDescription
            }
        }
        if error is DecodingError {
            return "The dashboard answered something this client does not understand."
        }
        return error.localizedDescription
    }
}
