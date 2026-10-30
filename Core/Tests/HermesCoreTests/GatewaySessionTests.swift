import Foundation
import Testing
@testable import HermesCore

final class MemoryStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Tokens] = [:]

    func tokens(for server: String) throws -> Tokens? {
        lock.withLock { items[server] }
    }

    func save(_ tokens: Tokens?, for server: String) throws {
        lock.withLock { items[server] = tokens }
    }

    var saved: [String: Tokens] {
        lock.withLock { items }
    }
}

@Suite("The tokens of one dashboard")
struct DashboardSessionTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!
    private let server = "https://hermes.example.test"

    private func response(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(text.utf8))
    }

    @Test("A token that is still good is sent without a refresh")
    func validToken() async throws {
        let transport = StubTransport([])
        let session = DashboardSession(endpoint: endpoint, transport: transport)
        try await session.adopt(Tokens(accessToken: "at", expiresAt: 0))

        #expect(try await session.accessToken() == "at")
        #expect(transport.requests.isEmpty)
    }

    @Test("A token near its end is refreshed and the new one is kept")
    func refresh() async throws {
        let transport = StubTransport([response(#"{"access_token":"new","expires_at":4102444800}"#)])
        let storage = MemoryStorage()
        let session = DashboardSession(
            endpoint: endpoint,
            transport: transport,
            storage: storage,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try await session.adopt(Tokens(accessToken: "old", refreshToken: "rt", expiresAt: 1_030, provider: "self-hosted"))

        #expect(try await session.accessToken() == "new")
        #expect(storage.saved[server]?.accessToken == "new")
        #expect(storage.saved[server]?.refreshToken == "rt")
        let sent = try JSONValue.decode(try #require(transport.requests.first?.body))
        #expect(sent["refresh_token"]?.stringValue == "rt")
    }

    @Test("A refused refresh ends the session and forgets the tokens")
    func refusedRefresh() async throws {
        let transport = StubTransport([response(#"{"detail":"unknown refresh token"}"#, status: 401)])
        let storage = MemoryStorage()
        let session = DashboardSession(endpoint: endpoint, transport: transport, storage: storage)
        try await session.adopt(Tokens(accessToken: "old", refreshToken: "rt", expiresAt: 10))

        do {
            _ = try await session.accessToken()
            Issue.record("A refused refresh did not throw")
        } catch let error as SessionError {
            #expect(error == .signInRequired)
        }
        #expect(storage.saved[server] == nil)
        #expect(await session.currentTokens == nil)
    }

    @Test("An unreachable identity provider keeps the tokens for a later try")
    func providerDown() async throws {
        let transport = StubTransport([response(#"{"detail":"idp down"}"#, status: 503)])
        let storage = MemoryStorage()
        let session = DashboardSession(endpoint: endpoint, transport: transport, storage: storage)
        try await session.adopt(Tokens(accessToken: "old", refreshToken: "rt", expiresAt: 10))

        do {
            _ = try await session.accessToken()
            Issue.record("503 did not throw")
        } catch let error as DashboardError {
            #expect(error.providerUnavailable)
        }
        #expect(storage.saved[server]?.refreshToken == "rt")
        #expect(await session.currentTokens?.accessToken == "old")
    }

    @Test("A dashboard that needs no sign-in has no tokens and no ticket")
    func unauthenticated() async throws {
        let transport = StubTransport([])
        let session = DashboardSession(endpoint: endpoint, transport: transport)
        #expect(try await session.accessToken() == nil)
        #expect(try await session.socketTicket() == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test("The ticket carries the token")
    func ticket() async throws {
        let transport = StubTransport([response(#"{"ticket":"t-9"}"#)])
        let session = DashboardSession(endpoint: endpoint, transport: transport)
        try await session.adopt(Tokens(accessToken: "at"))

        #expect(try await session.socketTicket() == "t-9")
        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://hermes.example.test/api/auth/ws-ticket")
        #expect(request.headers["Authorization"] == "Bearer at")
    }

    @Test("What the Keychain kept comes back at launch")
    func load() async throws {
        let storage = MemoryStorage()
        try storage.save(Tokens(accessToken: "at", refreshToken: "rt"), for: server)
        let session = DashboardSession(endpoint: endpoint, transport: StubTransport([]), storage: storage)
        #expect(try await session.load()?.accessToken == "at")
        #expect(await session.currentTokens?.refreshToken == "rt")
    }
}

/// A transport that hands out sockets from a script, so a drop and a retry can be played.
final class ScriptedTransport: SocketTransport, @unchecked Sendable {
    enum Step {
        case socket(FakeSocket)
        case failure(URLError)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var used: [FakeSocket] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var attempts: Int {
        lock.withLock { used.count + steps.filter { if case .failure = $0 { return true } else { return false } }.count }
    }

    var sockets: [FakeSocket] {
        lock.withLock { used }
    }

    var lastSocket: FakeSocket? {
        lock.withLock { used.last }
    }

    func connect(to url: URL) async throws -> any SocketConnection {
        let step: Step? = lock.withLock {
            steps.isEmpty ? nil : steps.removeFirst()
        }
        switch step {
        case .socket(let socket):
            lock.withLock { used.append(socket) }
            return socket
        case .failure(let error):
            throw error
        case nil:
            throw URLError(.cannotConnectToHost)
        }
    }
}

final class FakeCredentials: SessionCredentials, @unchecked Sendable {
    private let lock = NSLock()
    private var ticket: String?
    private var error: Error?
    private var count = 0

    init(ticket: String? = nil, error: Error? = nil) {
        self.ticket = ticket
        self.error = error
    }

    var calls: Int {
        lock.withLock { count }
    }

    func socketTicket() async throws -> String? {
        let (result, failure) = lock.withLock { () -> (String?, Error?) in
            count += 1
            return (ticket, error)
        }
        if let failure { throw failure }
        return result
    }
}

/// Polls until the condition holds, so a test waits for the loop instead of guessing.
func waitUntil(_ condition: @escaping @Sendable () async -> Bool, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The condition did not come true in time")
}

@Suite("The socket of one dashboard, kept open")
struct GatewaySessionTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    private func session(
        _ transport: ScriptedTransport,
        credentials: any SessionCredentials = FakeCredentials(),
        states: Recorder<GatewaySession.State>? = nil
    ) -> GatewaySession {
        GatewaySession(
            endpoint: endpoint,
            credentials: credentials,
            transport: transport,
            firstPause: .milliseconds(20),
            maxPause: .milliseconds(80),
            onState: { states?.record($0) }
        )
    }

    @Test("A first attempt that fails is tried again")
    func retry() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let transport = ScriptedTransport([.failure(URLError(.cannotConnectToHost)), .socket(socket)])
        let gateway = session(transport)

        await gateway.start()
        try await waitUntil { await gateway.currentState() == .ready }
        #expect(transport.sockets.count == 1)
        await gateway.stop()
    }

    @Test("A socket that drops is opened again with a fresh ticket")
    func reconnects() async throws {
        let first = FakeSocket()
        first.push(readyFrame())
        let second = FakeSocket()
        second.push(readyFrame())
        let transport = ScriptedTransport([.socket(first), .socket(second)])
        let credentials = FakeCredentials(ticket: "t")
        let states = Recorder<GatewaySession.State>()
        let gateway = session(transport, credentials: credentials, states: states)

        await gateway.start()
        try await waitUntil { await gateway.currentState() == .ready }

        first.finish()
        try await waitUntil { transport.sockets.count == 2 }
        try await waitUntil { await gateway.currentState() == .ready }
        #expect(credentials.calls >= 2)
        #expect(states.all.contains(.waiting))
        #expect(states.all.contains(.ready))
        await gateway.stop()
    }

    @Test("An ended sign-in stops the retries and says why")
    func signInOver() async throws {
        let transport = ScriptedTransport([.socket(FakeSocket())])
        let credentials = FakeCredentials(error: SessionError.signInRequired)
        let gateway = session(transport, credentials: credentials)

        await gateway.start()
        try await waitUntil { await gateway.currentState() == .failed("The sign-in is over. Sign in again to keep the connection.") }
        try await Task.sleep(for: .milliseconds(60))
        #expect(transport.sockets.isEmpty)
        #expect(credentials.calls == 1)
    }

    @Test("A refused handshake is tried again, and three in a row are reported")
    func refused() async throws {
        let sockets = (0..<3).map { _ -> FakeSocket in
            let socket = FakeSocket()
            socket.fail(with: GatewayError.refused(status: 403))
            return socket
        }
        let transport = ScriptedTransport(sockets.map { .socket($0) })
        let gateway = session(transport)

        await gateway.start()
        try await waitUntil { await gateway.currentState() == .failed("The dashboard refused the socket (403). The sign-in may be over.") }
        #expect(transport.sockets.count == 3)
        try await Task.sleep(for: .milliseconds(80))
        #expect(transport.sockets.count == 3)
    }

    @Test("A refusal followed by a good socket comes up")
    func refusalThenReady() async throws {
        let refused = FakeSocket()
        refused.fail(with: GatewayError.refused(status: 403))
        let good = FakeSocket()
        good.push(readyFrame())
        let transport = ScriptedTransport([.socket(refused), .socket(good)])
        let gateway = session(transport)

        await gateway.start()
        try await waitUntil { await gateway.currentState() == .ready }
        await gateway.stop()
    }

    @Test("Calls go to the connection that is up")
    func calls() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let transport = ScriptedTransport([.socket(socket)])
        let gateway = session(transport)

        await gateway.start()
        try await waitUntil { await gateway.currentState() == .ready }

        async let answer = gateway.call("session.list", timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(80))
        let id = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.list" }?["id"]?.stringValue)
        socket.push(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"sessions":["a"]}}"#)

        let result = try await answer
        #expect(result == ["sessions": ["a"]])
        await gateway.stop()
    }

    @Test("A stopped session opens nothing more")
    func stop() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let transport = ScriptedTransport([.socket(socket)])
        let gateway = session(transport)

        await gateway.start()
        try await waitUntil { await gateway.currentState() == .ready }
        await gateway.stop()

        try await Task.sleep(for: .milliseconds(80))
        #expect(await gateway.currentState() == .stopped)
        #expect(transport.sockets.count == 1)
    }
}

@Suite("A call made before the socket is up")
struct EarlyCallTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    @Test("A call waits for the connection instead of failing at once")
    func waits() async throws {
        let socket = FakeSocket()
        let transport = ScriptedTransport([.socket(socket)])
        let gateway = GatewaySession(
            endpoint: endpoint,
            credentials: FakeCredentials(),
            transport: transport,
            firstPause: .milliseconds(20)
        )
        await gateway.start()

        // Asked before the gateway said it was ready; the ready frame arrives a moment later.
        async let answer = gateway.call("session.list", timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(60))
        socket.push(readyFrame())
        try await Task.sleep(for: .milliseconds(80))
        let request = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.list" })
        socket.push(#"{"jsonrpc":"2.0","id":"\#(request["id"]?.stringValue ?? "x")","result":{"sessions":[]}}"#)
        _ = try await answer
        await gateway.stop()
    }

    @Test("A call on a session that was never started is an error, not a wait")
    func notStarted() async throws {
        let gateway = GatewaySession(
            endpoint: endpoint,
            credentials: FakeCredentials(),
            transport: ScriptedTransport([])
        )
        do {
            _ = try await gateway.call("session.list", timeout: .seconds(2))
            Issue.record("A call on a stopped session did not throw")
        } catch let error as GatewayError {
            #expect(error == .notConnected)
        }
    }
}
