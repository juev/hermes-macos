import Foundation
import Testing
@testable import HermesCore

@Suite("A chat open over the socket")
struct ChatSessionTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    private func connected(
        _ transport: ScriptedTransport,
        credentials: any SessionCredentials = FakeCredentials()
    ) async -> GatewaySession {
        let gateway = GatewaySession(
            endpoint: endpoint,
            credentials: credentials,
            transport: transport,
            firstPause: .milliseconds(20),
            maxPause: .milliseconds(80)
        )
        await gateway.start()
        try? await waitUntil { await gateway.currentState() == .ready }
        return gateway
    }

    private func answer(_ socket: FakeSocket, for method: String, result: JSONValue) async throws {
        try await waitUntil {
            socket.sentFrames.contains { $0["method"]?.stringValue == method }
        }
        let request = try #require(socket.sentFrames.last { $0["method"]?.stringValue == method })
        let id = try #require(request["id"]?.stringValue)
        let frame: JSONValue = ["jsonrpc": "2.0", "id": .string(id), "result": result]
        socket.push(frame.encodedString)
    }

    @Test("Joining a stored chat asks for its live session")
    func join() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let transport = ScriptedTransport([.socket(socket)])
        let gateway = await connected(transport)
        let chat = ChatSession(gateway: gateway)

        async let joined = chat.join(storedID: "stored-1")
        try await answer(socket, for: "session.resume", result: [
            "session_id": "live-1",
            "stored_session_id": "stored-1",
            "running": true,
            "info": ["model": "gpt-6.1-sol", "running": true],
            "inflight": ["assistant": "half an ans"]
        ])
        let opened = try await joined

        #expect(opened.liveID == "live-1")
        #expect(opened.storedID == "stored-1")
        #expect(opened.running)
        #expect(opened.model == "gpt-6.1-sol")
        #expect(opened.streamed == "half an ans")
        let current = await chat.currentLiveID()
        #expect(current == "live-1")

        let request = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.resume" })
        #expect(request["params"]?["session_id"]?.stringValue == "stored-1")
        #expect(request["params"]?["omit_messages"]?.boolValue == true)
        await gateway.stop()
    }

    @Test("A join without a live session is an error")
    func noLiveSession() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let gateway = await connected(ScriptedTransport([.socket(socket)]))
        let chat = ChatSession(gateway: gateway)

        async let joined = chat.join(storedID: "stored-1")
        try await answer(socket, for: "session.resume", result: [:])
        do {
            _ = try await joined
            Issue.record("A join without a session did not throw")
        } catch let error as ChatError {
            #expect(error == .noLiveSession)
        }
        await gateway.stop()
    }

    @Test("A prompt goes into the live session, and a stop ends it")
    func prompt() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let gateway = await connected(ScriptedTransport([.socket(socket)]))
        let chat = ChatSession(gateway: gateway)

        async let joined = chat.join(storedID: "stored-1")
        try await answer(socket, for: "session.resume", result: ["session_id": "live-1"])
        _ = try await joined

        async let sending = chat.submit("Привет")
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "prompt.submit" } }
        let sent = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "prompt.submit" })
        #expect(sent["params"]?["session_id"]?.stringValue == "live-1")
        #expect(sent["params"]?["text"]?.stringValue == "Привет")
        let sentFrame: JSONValue = ["jsonrpc": "2.0", "id": sent["id"] ?? "x", "result": [:]]
        socket.push(sentFrame.encodedString)
        try await sending

        async let stopping = chat.interrupt()
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "session.interrupt" } }
        let stop = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.interrupt" })
        let stopFrame: JSONValue = ["jsonrpc": "2.0", "id": stop["id"] ?? "x", "result": [:]]
        socket.push(stopFrame.encodedString)
        try await stopping
        await gateway.stop()
    }

    @Test("Only the events of this chat reach the sink")
    func events() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let gateway = await connected(ScriptedTransport([.socket(socket)]))
        let chat = ChatSession(gateway: gateway)

        async let joined = chat.join(storedID: "stored-1")
        try await answer(socket, for: "session.resume", result: ["session_id": "live-1"])
        _ = try await joined

        let seen = Recorder<GatewayEvent>()
        await chat.setEventSink { seen.record($0) }

        socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"live-1","payload":{"text":"hi"}}}"#)
        socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"another","payload":{"text":"no"}}}"#)
        try await waitUntil { seen.all.count == 1 }

        #expect(seen.all.first?.type == "message.delta")
        #expect(seen.all.first?.sessionID == "live-1")
        await gateway.stop()
    }

    @Test("Sending without a join is refused")
    func notJoined() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let gateway = await connected(ScriptedTransport([.socket(socket)]))
        let chat = ChatSession(gateway: gateway)
        do {
            try await chat.submit("hi")
            Issue.record("A prompt without a join did not throw")
        } catch let error as ChatError {
            #expect(error == .notConnected)
        }
        await gateway.stop()
    }
}

extension JSONValue {
    /// The frame as the socket would carry it, for a script to push back.
    var encodedString: String {
        guard let data = try? encoded() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
