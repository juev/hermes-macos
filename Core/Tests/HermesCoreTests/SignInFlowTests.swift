import Foundation
import Testing
@testable import HermesCore

/// Stands in for the loopback listener: the browser part is the test's to play.
final class FakeReceiver: CallbackReceiver, @unchecked Sendable {
    let redirectURI = "http://127.0.0.1:4242/callback"
    var result: CallbackResult = .code(code: "c-1", state: "wrong")
    private(set) var closed = false
    private(set) var waited = false

    func wait(timeout: Duration) async throws -> CallbackResult {
        waited = true
        return result
    }

    func close() {
        closed = true
    }
}

/// Keeps what the "browser" was opened on; a box because the closure that opens it is @Sendable.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: URL?

    var url: URL? {
        get { lock.lock(); defer { lock.unlock() }; return kept }
        set { lock.lock(); defer { lock.unlock() }; kept = newValue }
    }
}

private func state(of url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == "state" }?
        .value
}

@Suite("The browser part of the sign-in")
struct SignInFlowTests {
    private func flow(_ transport: StubTransport) throws -> SignInFlow {
        SignInFlow(client: DashboardClient(
            endpoint: try #require(Endpoint(address: "https://hermes.example.test")),
            transport: transport
        ))
    }

    private let tokenAnswer = HTTPResponse(
        status: 200,
        body: Data(#"{"access_token":"at","refresh_token":"rt","expires_at":1760000000,"provider":"self-hosted","user_id":"u-1"}"#.utf8)
    )

    @Test("The code from the browser becomes tokens")
    func happyPath() async throws {
        let transport = StubTransport([tokenAnswer])
        let receiver = FakeReceiver()
        let opened = Recorder()

        let tokens = try await flow(transport).signIn(
            receiver: receiver,
            openBrowser: { url in
                opened.url = url
                receiver.result = .code(code: "code-1", state: state(of: url) ?? "")
            }
        )

        #expect(tokens.accessToken == "at")
        #expect(receiver.waited)
        #expect(receiver.closed)

        let url = try #require(opened.url)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/auth/native/authorize")
        #expect(items["redirect_uri"] == receiver.redirectURI)
        #expect(items["code_challenge_method"] == "S256")
        #expect((items["code_challenge"]?.count ?? 0) == 43)
        #expect(items["provider"] == nil)

        let sent = try JSONValue.decode(try #require(transport.requests.first?.body))
        #expect(sent["code"]?.stringValue == "code-1")
        #expect(sent["code_verifier"]?.stringValue?.isEmpty == false)
    }

    @Test("A chosen provider goes into the address")
    func provider() async throws {
        let transport = StubTransport([tokenAnswer])
        let receiver = FakeReceiver()
        let opened = Recorder()
        _ = try await flow(transport).signIn(
            provider: "self-hosted",
            receiver: receiver,
            openBrowser: { url in
                opened.url = url
                receiver.result = .code(code: "c", state: state(of: url) ?? "")
            }
        )
        #expect(opened.url?.absoluteString.contains("provider=self-hosted") == true)
    }

    @Test("A refusal in the browser is an error, not a broken state check")
    func refused() async throws {
        let transport = StubTransport([])
        let receiver = FakeReceiver()
        receiver.result = .error(code: "access_denied", description: "No account")

        do {
            _ = try await flow(transport).signIn(receiver: receiver, openBrowser: { _ in })
            Issue.record("A refusal did not throw")
        } catch let error as SignInError {
            #expect(error == .refused(code: "access_denied", description: "No account"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("A state from another sign-in drops the code unused")
    func stateMismatch() async throws {
        let transport = StubTransport([tokenAnswer])
        let receiver = FakeReceiver()
        receiver.result = .code(code: "c", state: "not-the-one")

        do {
            _ = try await flow(transport).signIn(receiver: receiver, openBrowser: { _ in })
            Issue.record("A mismatched state did not throw")
        } catch let error as SignInError {
            #expect(error == .stateMismatch)
        }
        #expect(transport.requests.isEmpty)
        #expect(receiver.closed)
    }
}
