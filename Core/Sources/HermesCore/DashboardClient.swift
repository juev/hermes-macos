import Foundation

/// What a dashboard answered with something other than success.
///
/// The body of a refusal is the dashboard's own shape, seen on v0.22.5 in
/// `docs/fixtures/api-status/unauthorized.json`:
/// `{"error": "unauthenticated", "detail": "Unauthorized", "reason": "no_cookie", "login_url": "/login"}`.
/// A FastAPI route instead puts a string, or a list of validation errors, under `detail`.
public struct DashboardError: Error, Sendable, Equatable {
    public let status: Int
    /// A sentence for a person: `detail` when the server wrote one, the reason otherwise.
    public let detail: String
    /// The server's machine-readable code: `unauthenticated`, `not_found`.
    public let code: String?
    /// Why it refused: `no_cookie` when no token was sent at all.
    public let reason: String?
    /// Where a browser could sign in, when the server names one.
    public let loginURL: String?

    public init(status: Int, detail: String, code: String? = nil, reason: String? = nil, loginURL: String? = nil) {
        self.status = status
        self.detail = detail
        self.code = code
        self.reason = reason
        self.loginURL = loginURL
    }

    /// The token is over: only a new sign-in helps.
    public var needsSignIn: Bool { status == 401 || status == 403 }

    /// The server could not reach the identity provider; the tokens stay valid for a later try.
    public var providerUnavailable: Bool { status == 503 }

    public init(status: Int, response: HTTPResponse) {
        let json = response.json
        var detail = json?["detail"]?.stringValue
        if detail == nil, let nested = json?["detail"]?.arrayValue {
            detail = nested.compactMap { $0["msg"]?.stringValue }.joined(separator: "; ")
        }
        if detail == nil { detail = json?["message"]?.stringValue }
        self.init(
            status: status,
            detail: detail?.isEmpty == false ? detail! : HTTPURLResponse.localizedString(forStatusCode: status),
            code: json?["error"]?.stringValue,
            reason: json?["reason"]?.stringValue,
            loginURL: json?["login_url"]?.stringValue
        )
    }
}

/// The calls a client makes over REST, each of them in the contract:
/// `../hermes/docs/protocol.md` §1 for the status, §3 for the tokens and the ticket.
public struct DashboardClient: Sendable {
    public let endpoint: Endpoint
    public let transport: HTTPTransport

    public init(endpoint: Endpoint, transport: HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    /// `/api/status`, sent without a token: a dashboard has to say whether it wants one.
    public func status() async throws -> ServerStatus {
        let response = try await transport.send(
            HTTPRequest(url: endpoint.url("api/status"), timeout: 10)
        )
        return try json(response, as: ServerStatus.init)
    }

    /// Trades the code the browser brought back for tokens (`POST /auth/native/token`).
    public func signIn(code: String, verifier: String) async throws -> Tokens {
        let request = HTTPRequest(method: "POST", url: endpoint.url("auth/native/token"))
            .json(["code": .string(code), "code_verifier": .string(verifier)])
        let response = try await transport.send(request)
        return try json(response) { try Tokens(serverAnswer: $0) }
    }

    /// A new access token from the refresh token (`POST /auth/native/refresh`).
    public func refresh(_ tokens: Tokens) async throws -> Tokens {
        let request = HTTPRequest(method: "POST", url: endpoint.url("auth/native/refresh"))
            .json(["refresh_token": .string(tokens.refreshToken), "provider": .string(tokens.provider)])
        let response = try await transport.send(request)
        return try json(response) { try Tokens(serverAnswer: $0, previous: tokens) }
    }

    /// The one-time ticket that opens the socket (`POST /api/auth/ws-ticket`).
    public func socketTicket(token: String) async throws -> String {
        let request = HTTPRequest(method: "POST", url: endpoint.url("api/auth/ws-ticket"), headers: ["Authorization": "Bearer \(token)"])
        let response = try await transport.send(request)
        let value = try json(response) { $0 }
        guard let ticket = value["ticket"]?.stringValue, !ticket.isEmpty else {
            throw DashboardError(status: response.status, detail: "The dashboard sent no ticket.")
        }
        return ticket
    }

    private func json<T>(_ response: HTTPResponse, as build: (JSONValue) throws -> T) throws -> T {
        guard response.isSuccess else { throw DashboardError(status: response.status, response: response) }
        guard let value = response.json else {
            throw DashboardError(status: response.status, detail: "The dashboard answered nothing.")
        }
        return try build(value)
    }
}
