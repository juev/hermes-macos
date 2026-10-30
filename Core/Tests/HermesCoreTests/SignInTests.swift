import Foundation
import Testing
@testable import HermesCore

@Suite("Address of a dashboard")
struct EndpointTests {
    @Test("A bare host gets https")
    func bareHost() throws {
        let endpoint = try #require(Endpoint(address: "hermes.example.test:8443"))
        #expect(endpoint.base.absoluteString == "https://hermes.example.test:8443")
        #expect(endpoint.url("api/status").absoluteString == "https://hermes.example.test:8443/api/status")
    }

    @Test("A trailing slash does not double")
    func trailingSlash() throws {
        let endpoint = try #require(Endpoint(address: " http://127.0.0.1:8765/ "))
        #expect(endpoint.base.absoluteString == "http://127.0.0.1:8765")
        #expect(endpoint.url("/api/sessions").absoluteString == "http://127.0.0.1:8765/api/sessions")
    }

    @Test("A dashboard behind a path keeps it")
    func pathPrefix() throws {
        let endpoint = try #require(Endpoint(address: "https://example.test/hermes/"))
        #expect(endpoint.url("api/status").absoluteString == "https://example.test/hermes/api/status")
        #expect(endpoint.socketURL(ticket: nil).absoluteString == "wss://example.test/hermes/api/ws")
    }

    @Test("The socket takes the ticket and the websocket scheme")
    func socketURL() throws {
        let endpoint = try #require(Endpoint(address: "https://example.test"))
        #expect(endpoint.socketURL(ticket: "t-1").absoluteString == "wss://example.test/api/ws?ticket=t-1")

        let local = try #require(Endpoint(address: "http://127.0.0.1:8765"))
        #expect(local.socketURL(ticket: nil).absoluteString == "ws://127.0.0.1:8765/api/ws")
    }

    @Test("A query is appended to the route")
    func query() throws {
        let endpoint = try #require(Endpoint(address: "https://example.test"))
        let url = endpoint.url("api/sessions", query: [URLQueryItem(name: "limit", value: nil)])
        #expect(url.absoluteString == "https://example.test/api/sessions?limit")
    }

    @Test("What is not an address is refused")
    func refused() {
        #expect(Endpoint(address: "") == nil)
        #expect(Endpoint(address: "   ") == nil)
        #expect(Endpoint(address: "https://") == nil)
    }
}

@Suite("Sign-in with native_pkce")
struct SignInTests {
    @Test("The challenge of the RFC test vector")
    func rfcVector() {
        // RFC 7636, appendix B.
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("A fresh pair is URL-safe and long enough")
    func freshPair() {
        let pkce = PKCE.make()
        #expect(pkce.verifier.count == 43)
        #expect(pkce.state.count == 32)
        #expect(pkce.challenge.count == 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(pkce.verifier.unicodeScalars.allSatisfy(allowed.contains))
        #expect(PKCE.make().verifier != pkce.verifier)
    }

    @Test("The authorize address")
    func authorizeURL() throws {
        let endpoint = try #require(Endpoint(address: "https://example.test/hermes"))
        let pkce = PKCE(verifier: "v", challenge: "chal", state: "st")
        let url = SignIn.authorizeURL(endpoint: endpoint, redirectURI: "http://127.0.0.1:5000/callback", pkce: pkce)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/hermes/auth/native/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["code_challenge"] == "chal")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5000/callback")
        #expect(items["state"] == "st")
        #expect(items["provider"] == nil)
    }

    @Test("A provider is added when one is asked for")
    func provider() throws {
        let endpoint = try #require(Endpoint(address: "https://example.test"))
        let url = SignIn.authorizeURL(
            endpoint: endpoint,
            redirectURI: "http://127.0.0.1:5000/callback",
            pkce: PKCE(verifier: "v", challenge: "c", state: "s"),
            provider: "nous"
        )
        #expect(url.absoluteString.contains("provider=nous"))
    }

    @Test("The callback carries the code and the state")
    func callback() {
        #expect(SignIn.parseCallback("/callback?code=abc%2F1&state=st-1") == .code(code: "abc/1", state: "st-1"))
        #expect(SignIn.parseCallback("/callback?state=st&code=x") == .code(code: "x", state: "st"))
        #expect(SignIn.parseCallback("/callback?error=access_denied&error_description=No+account") ==
            .error(code: "access_denied", description: "No account"))
        #expect(SignIn.parseCallback("/callback") == .code(code: "", state: ""))
    }

    @Test("Anything but the callback is not the callback")
    func otherRequest() {
        #expect(SignIn.parseCallback("/favicon.ico") == nil)
        #expect(SignIn.parseCallback("/") == nil)
        #expect(SignIn.parseCallback("/callback/extra?code=x") == nil)
    }

    @Test("A query string is percent-decoded")
    func query() {
        let parameters = SignIn.queryParameters("a=1&b=two%20words&c=x%2By&d&e=")
        #expect(parameters["a"] == "1")
        #expect(parameters["b"] == "two words")
        #expect(parameters["c"] == "x+y")
        #expect(parameters["d"] == "")
        #expect(parameters["e"] == "")
    }
}

@Suite("Tokens and status")
struct TokensTests {
    @Test("The token answer")
    func tokens() throws {
        let json = try JSONValue.decode(#"{"access_token":"at","refresh_token":"rt","expires_at":1760000000,"provider":"nous","user_id":"u-1"}"#)
        let tokens = try Tokens(serverAnswer: json)
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.expiresAt == 1_760_000_000)
        #expect(tokens.provider == "nous")
        #expect(tokens.userID == "u-1")
    }

    @Test("An expiry written as a string")
    func stringExpiry() throws {
        let json = try JSONValue.decode(#"{"access_token":"at","expires_at":"1760000000.0"}"#)
        #expect(try Tokens(serverAnswer: json).expiresAt == 1_760_000_000)
    }

    @Test("A refresh keeps what the provider did not repeat")
    func refreshKeepsTheRest() throws {
        let previous = Tokens(accessToken: "old", refreshToken: "rt", expiresAt: 5, provider: "nous", userID: "u")
        let renewed = try Tokens(serverAnswer: try JSONValue.decode(#"{"access_token":"new","expires_at":10}"#), previous: previous)
        #expect(renewed.accessToken == "new")
        #expect(renewed.refreshToken == "rt")
        #expect(renewed.provider == "nous")
        #expect(renewed.userID == "u")
    }

    @Test("An answer without an access token is refused")
    func missing() {
        #expect(throws: TokensError.missingAccessToken) { try Tokens(serverAnswer: ["refresh_token": "rt"]) }
    }

    @Test("When a token is still good")
    func validity() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(Tokens(accessToken: "a").isValid(at: now))
        #expect(Tokens(accessToken: "a", expiresAt: 2_000).isValid(at: now))
        #expect(!Tokens(accessToken: "a", expiresAt: 1_000).isValid(at: now))
        #expect(!Tokens(accessToken: "a", expiresAt: 1_030).isValid(at: now, skew: 60))
        #expect(Tokens(accessToken: "a", expiresAt: 1_100).isValid(at: now, skew: 60))
    }

    @Test("The status of a dashboard")
    func status() {
        let json: JSONValue = [
            "auth_required": true,
            "auth_flows": ["native_pkce", "password"],
            "auth_providers": ["nous", "github"],
            "version": "0.22.5"
        ]
        let status = ServerStatus(json)
        #expect(status.authRequired)
        #expect(status.supportsNativePKCE)
        #expect(status.authProviders == ["nous", "github"])
        #expect(status.version == "0.22.5")
        #expect(!ServerStatus([:]).supportsNativePKCE)
    }
}
