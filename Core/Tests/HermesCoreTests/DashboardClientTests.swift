import Foundation
import Testing
@testable import HermesCore

/// A transport that answers from a script and keeps what it was asked, so a call can be checked
/// without a dashboard.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
        return responses.removeFirst()
    }
}

private func body(_ text: String) -> HTTPResponse {
    HTTPResponse(status: 200, body: Data(text.utf8))
}

/// The body the dashboard answered a tokenless request with, captured on v0.22.5.
private let unauthorized = HTTPResponse(
    status: 401,
    body: Data(#"{"error":"unauthenticated","detail":"Unauthorized","reason":"no_cookie","login_url":"/login"}"#.utf8)
)

@Suite("The REST client")
struct DashboardClientTests {
    private func client(_ transport: StubTransport) throws -> DashboardClient {
        DashboardClient(endpoint: try #require(Endpoint(address: "https://hermes.example.test")), transport: transport)
    }

    @Test("The status is read without a token")
    func status() async throws {
        let transport = StubTransport([body(#"{"auth_required":true,"auth_flows":["cookie","native_pkce"],"auth_providers":["self-hosted"],"version":"0.22.5"}"#)])
        let status = try await client(transport).status()
        #expect(status.authRequired)
        #expect(status.supportsNativePKCE)
        #expect(status.authProviders == ["self-hosted"])
        #expect(status.version == "0.22.5")
        let request = try #require(transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://hermes.example.test/api/status")
        #expect(request.headers["Authorization"] == nil)
    }

    @Test("A refusal keeps what the server said")
    func refusal() async throws {
        let transport = StubTransport([unauthorized])
        do {
            _ = try await client(transport).status()
            Issue.record("A refusal did not throw")
        } catch let error as DashboardError {
            #expect(error.status == 401)
            #expect(error.code == "unauthenticated")
            #expect(error.reason == "no_cookie")
            #expect(error.loginURL == "/login")
            #expect(error.detail == "Unauthorized")
            #expect(error.needsSignIn)
            #expect(!error.providerUnavailable)
        }
    }

    @Test("A validation error from FastAPI is flattened")
    func validationError() throws {
        let response = HTTPResponse(
            status: 422,
            body: Data(#"{"detail":[{"loc":["body","code"],"msg":"field required"},{"loc":["body","state"],"msg":"bad state"}]}"#.utf8)
        )
        let error = DashboardError(status: 422, response: response)
        #expect(error.detail == "field required; bad state")
        #expect(!error.needsSignIn)
    }

    @Test("An error without a body still says something")
    func bareError() throws {
        let error = DashboardError(status: 500, response: HTTPResponse(status: 500))
        #expect(!error.detail.isEmpty)
        #expect(error.code == nil)
    }

    @Test("The code is traded for tokens")
    func exchange() async throws {
        let transport = StubTransport([body(#"{"access_token":"at","refresh_token":"rt","expires_at":1760000000,"provider":"self-hosted","user_id":"u-1"}"#)])
        let tokens = try await client(transport).signIn(code: "c-1", verifier: "v-1")
        #expect(tokens.accessToken == "at")
        #expect(tokens.expiresAt == 1_760_000_000)

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://hermes.example.test/auth/native/token")
        #expect(request.headers["Content-Type"]?.hasPrefix("application/json") == true)
        let sent = try JSONValue.decode(try #require(request.body))
        #expect(sent["code"]?.stringValue == "c-1")
        #expect(sent["code_verifier"]?.stringValue == "v-1")
    }

    @Test("A refresh sends what the server needs and stays signed in on 503")
    func refresh() async throws {
        let previous = Tokens(accessToken: "old", refreshToken: "rt", expiresAt: 10, provider: "self-hosted", userID: "u")
        let ok = StubTransport([body(#"{"access_token":"new","expires_at":20}"#)])
        let renewed = try await client(ok).refresh(previous)
        #expect(renewed.refreshToken == "rt")
        #expect(renewed.provider == "self-hosted")
        let sent = try JSONValue.decode(try #require(ok.requests.first?.body))
        #expect(sent["refresh_token"]?.stringValue == "rt")
        #expect(sent["provider"]?.stringValue == "self-hosted")

        let unavailable = StubTransport([HTTPResponse(status: 503, body: Data(#"{"detail":"identity provider unreachable"}"#.utf8))])
        do {
            _ = try await client(unavailable).refresh(previous)
            Issue.record("503 did not throw")
        } catch let error as DashboardError {
            #expect(error.providerUnavailable)
            #expect(!error.needsSignIn)
            #expect(error.detail == "identity provider unreachable")
        }
    }

    @Test("The socket ticket comes back with the bearer")
    func ticket() async throws {
        let transport = StubTransport([body(#"{"ticket":"t-1"}"#)])
        let ticket = try await client(transport).socketTicket(token: "at")
        #expect(ticket == "t-1")
        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://hermes.example.test/api/auth/ws-ticket")
        #expect(request.headers["Authorization"] == "Bearer at")
    }

    @Test("An answer without a ticket is an error, not an empty socket address")
    func noTicket() async throws {
        let transport = StubTransport([body(#"{}"#)])
        do {
            _ = try await client(transport).socketTicket(token: "at")
            Issue.record("An answer without a ticket did not throw")
        } catch let error as DashboardError {
            #expect(error.detail == "The dashboard sent no ticket.")
        }
    }
}
