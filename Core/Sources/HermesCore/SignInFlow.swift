import Foundation

/// Whatever waits for the browser to come back with a code: the real loopback listener in the app, a
/// script in a test.
public protocol CallbackReceiver: Sendable {
    var redirectURI: String { get }
    func wait(timeout: Duration) async throws -> CallbackResult
    func close()
}

extension LoopbackReceiver: CallbackReceiver {}

public enum SignInError: Error, Equatable {
    /// The identity provider said no and the browser carried the reason back.
    case refused(code: String, description: String?)
    /// The state that came back is not the one this sign-in made; the code is dropped unused.
    case stateMismatch
    /// A dashboard that needs no token does not run this.
    case notNeeded
}

/// The browser part of `native_pkce`, end to end: make the pair, open the browser on the dashboard's
/// authorize page, wait for the loopback callback and trade the code for tokens.
public struct SignInFlow: Sendable {
    public let client: DashboardClient

    public init(client: DashboardClient) {
        self.client = client
    }

    public func signIn(
        provider: String? = nil,
        receiver: CallbackReceiver,
        openBrowser: @Sendable (URL) -> Void,
        timeout: Duration = .seconds(300)
    ) async throws -> Tokens {
        defer { receiver.close() }

        let pkce = PKCE.make()
        let url = SignIn.authorizeURL(
            endpoint: client.endpoint,
            redirectURI: receiver.redirectURI,
            pkce: pkce,
            provider: provider
        )
        openBrowser(url)

        switch try await receiver.wait(timeout: timeout) {
        case .error(let code, let description):
            throw SignInError.refused(code: code, description: description)
        case .code(let code, let state):
            guard state == pkce.state else { throw SignInError.stateMismatch }
            return try await client.signIn(code: code, verifier: pkce.verifier)
        }
    }
}
