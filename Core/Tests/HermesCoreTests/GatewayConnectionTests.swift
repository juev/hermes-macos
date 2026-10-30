import Foundation
import Testing
@testable import HermesCore

/// A socket scripted by the test: frames are pushed in and everything the client sends is kept.
final class FakeSocket: SocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var finished = false
    private var outbox: [String] = []

    func push(_ text: String) {
        let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
            if let waiter {
                self.waiter = nil
                return waiter
            }
            inbox.append(text)
            return nil
        }
        waiting?.resume(returning: text)
    }

    func finish() {
        let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
            finished = true
            guard let waiter else { return nil }
            self.waiter = nil
            return waiter
        }
        waiting?.resume(returning: nil)
    }

    var sent: [String] {
        lock.withLock { outbox }
    }

    var sentFrames: [JSONValue] {
        sent.compactMap { try? JSONValue.decode($0) }
    }

    func send(_ text: String) async throws {
        lock.withLock { outbox.append(text) }
    }

    func next() async throws -> String? {
        await withCheckedContinuation { continuation in
            var frame: String?
            var ended = false
            lock.withLock {
                if !inbox.isEmpty {
                    frame = inbox.removeFirst()
                } else if finished {
                    ended = true
                } else {
                    waiter = continuation
                }
            }
            if let frame {
                continuation.resume(returning: frame)
            } else if ended {
                continuation.resume(returning: nil)
            }
        }
    }

    func close() {
        finish()
    }
}

final class FakeTransport: SocketTransport, @unchecked Sendable {
    let socket = FakeSocket()
    func connect(to url: URL) async throws -> any SocketConnection { socket }
}

/// Keeps what a handler was given; a box because the handlers are @Sendable.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func record(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

func readyFrame(heartbeat: Bool = false, sessionAuthority: Bool = false) -> String {
    #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"e-1","session_authority":\#(sessionAuthority),"heartbeat":\#(heartbeat)}}}"#
}

@Suite("One gateway connection")
struct GatewayConnectionTests {
    private func make(
        heartbeatInterval: Duration = .seconds(60),
        events: Recorder<GatewayEvent>? = nil,
        requests: Recorder<ServerRequest>? = nil
    ) -> (GatewayConnection, FakeSocket) {
        let transport = FakeTransport()
        let connection = GatewayConnection(
            url: URL(string: "wss://hermes.example.test/api/ws")!,
            transport: transport,
            heartbeatInterval: heartbeatInterval,
            onEvent: { events?.record($0) },
            onRequest: { requests?.record($0) }
        )
        return (connection, transport.socket)
    }

    @Test("The connection is ready only when the gateway says so")
    func ready() async throws {
        let (connection, socket) = make()
        socket.push(readyFrame(sessionAuthority: true))

        let readiness = try await connection.start(timeout: .seconds(5))
        #expect(readiness.replayEpoch == "e-1")
        #expect(readiness.heartbeat == false)
        #expect(await connection.isSessionAuthority())

        let sent = socket.sentFrames
        #expect(sent.contains { $0["method"]?.stringValue == "client.capabilities" })
        #expect(sent.first { $0["method"]?.stringValue == "client.capabilities" }?["params"]?["server_requests"]?.boolValue == true)
    }

    @Test("A gateway that never says ready fails the start")
    func noReady() async throws {
        let (connection, _) = make()
        await #expect(throws: GatewayError.timedOut(method: "gateway.ready")) {
            _ = try await connection.start(timeout: .milliseconds(120))
        }
    }

    @Test("A call is answered by its own id")
    func call() async throws {
        let (connection, socket) = make()
        socket.push(readyFrame())
        _ = try await connection.start(timeout: .seconds(5))

        async let answer = connection.call("session.list", params: ["limit": 20], timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(80))

        let request = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.list" })
        let id = try #require(request["id"]?.stringValue)
        #expect(request["params"]?["limit"]?.intValue == 20)
        socket.push(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"sessions":[]}}"#)

        let result = try await answer
        #expect(result == ["sessions": []])
    }

    @Test("A call that is not answered gives up")
    func timeout() async throws {
        let (connection, socket) = make()
        socket.push(readyFrame())
        _ = try await connection.start(timeout: .seconds(5))

        await #expect(throws: GatewayError.timedOut(method: "slow.method")) {
            _ = try await connection.call("slow.method", timeout: .milliseconds(100))
        }
    }

    @Test("A refusal of the gateway is an error, not an empty answer")
    func rpcFailure() async throws {
        let (connection, socket) = make()
        socket.push(readyFrame())
        _ = try await connection.start(timeout: .seconds(5))

        async let answer = connection.call("session.join", timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(80))
        let id = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.join" }?["id"]?.stringValue)
        socket.push(#"{"jsonrpc":"2.0","id":"\#(id)","error":{"code":-32602,"message":"no such session"}}"#)

        do {
            _ = try await answer
            Issue.record("A refusal did not throw")
        } catch let error as RPCFailure {
            #expect(error.code == -32602)
            #expect(error.message == "no such session")
        }
    }

    @Test("Events and questions reach their handlers")
    func handlers() async throws {
        let events = Recorder<GatewayEvent>()
        let requests = Recorder<ServerRequest>()
        let (connection, socket) = make(events: events, requests: requests)
        socket.push(readyFrame())
        _ = try await connection.start(timeout: .seconds(5))

        socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"assistant.delta","session_id":"s-1","payload":{"text":"hi"}}}"#)
        socket.push(#"{"jsonrpc":"2.0","id":"srv-7","method":"approval.request","params":{"pattern_key":"mcp_elicitation"}}"#)
        try await Task.sleep(for: .milliseconds(120))

        #expect(events.all.count == 1)
        #expect(events.all.first?.type == "assistant.delta")
        #expect(events.all.first?.sessionID == "s-1")

        let request = try #require(requests.all.first)
        #expect(request.id == "srv-7")
        #expect(request.method == "approval.request")

        await connection.refuse(request, reason: "not now")
        let answer = try #require(socket.sentFrames.last { $0["id"]?.stringValue == "srv-7" })
        #expect(answer["error"]?["code"]?.intValue == -32000)
        #expect(answer["error"]?["message"]?.stringValue == "not now")
    }

    @Test("A closed socket fails the calls in flight")
    func closed() async throws {
        let (connection, socket) = make()
        socket.push(readyFrame())
        _ = try await connection.start(timeout: .seconds(5))

        async let answer = connection.call("session.list", timeout: .seconds(10))
        try await Task.sleep(for: .milliseconds(80))
        socket.finish()

        do {
            _ = try await answer
            Issue.record("A closed socket did not fail the call")
        } catch let error as GatewayError {
            #expect(error == .closed)
        }
    }

    @Test("The heartbeat pings while the gateway offers one")
    func heartbeat() async throws {
        let (connection, socket) = make(heartbeatInterval: .milliseconds(50))
        socket.push(readyFrame(heartbeat: true))
        _ = try await connection.start(timeout: .seconds(5))

        try await Task.sleep(for: .milliseconds(260))
        let pings = socket.sentFrames.filter { $0["method"]?.stringValue == "gateway.ping" }
        #expect(pings.count >= 1)
        await connection.close()
    }

    @Test("Without the heartbeat flag the client stays quiet")
    func noHeartbeat() async throws {
        let (connection, socket) = make(heartbeatInterval: .milliseconds(50))
        socket.push(readyFrame(heartbeat: false))
        _ = try await connection.start(timeout: .seconds(5))

        try await Task.sleep(for: .milliseconds(260))
        #expect(socket.sentFrames.allSatisfy { $0["method"]?.stringValue != "gateway.ping" })
        await connection.close()
    }
}
