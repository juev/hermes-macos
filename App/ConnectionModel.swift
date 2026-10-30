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
    private var task: Task<Void, Never>?

    var endpoint: Endpoint? { Endpoint(address: address) }

    var isBusy: Bool { phase == .checking || phase == .waitingForBrowser }

    var canConnect: Bool { endpoint != nil && !isBusy }

    func connect() {
        guard let endpoint, canConnect else { return }
        task?.cancel()
        task = Task { await connect(to: endpoint) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func connect(to endpoint: Endpoint) async {
        phase = .checking
        let client = DashboardClient(endpoint: endpoint)
        do {
            let status = try await client.status()
            if status.authRequired {
                phase = .waitingForBrowser
                let tokens = try await signIn(to: client, providers: status.authProviders)
                try KeychainTokenStorage().save(tokens, for: endpoint.base.absoluteString)
                NSApp.activate(ignoringOtherApps: true)
            }
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
