import Foundation
import Testing
@testable import HermesCore

@Suite("Two chats on one socket")
struct ChatHubTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    private func opened(_ socket: FakeSocket) async -> (GatewaySession, ChatHub) {
        let gateway = GatewaySession(
            endpoint: endpoint,
            credentials: FakeCredentials(),
            transport: ScriptedTransport([.socket(socket)]),
            firstPause: .milliseconds(20)
        )
        await gateway.start()
        try? await waitUntil { await gateway.currentState() == .ready }
        return (gateway, ChatHub(gateway: gateway))
    }

    private func join(_ chat: ChatSession, _ socket: FakeSocket, stored: String, live: String) async throws {
        async let joined = chat.join(storedID: stored)
        try await waitUntil { socket.sentFrames.filter { $0["method"]?.stringValue == "session.resume" }.count >= (stored == "stored-1" ? 1 : 2) }
        let resume = socket.sentFrames.last { $0["method"]?.stringValue == "session.resume" }
        let answer: JSONValue = ["jsonrpc": "2.0", "id": resume?["id"] ?? "x", "result": ["session_id": .string(live)]]
        socket.push(answer.encodedString)
        _ = try await joined
    }

    @Test("Each chat hears its own events and no other")
    func dispatch() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, hub) = await opened(socket)

        let first = ChatSession(gateway: gateway, hub: hub)
        try await join(first, socket, stored: "stored-1", live: "live-1")
        let second = ChatSession(gateway: gateway, hub: hub)
        try await join(second, socket, stored: "stored-2", live: "live-2")
        #expect(await hub.joinedChats == 2)

        let one = Recorder<GatewayEvent>()
        let two = Recorder<GatewayEvent>()
        await first.setEventSink { one.record($0) }
        await second.setEventSink { two.record($0) }

        socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"live-1","payload":{"text":"a"}}}"#)
        socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"live-2","payload":{"text":"b"}}}"#)
        try await waitUntil { one.all.count == 1 && two.all.count == 1 }

        #expect(one.all.first?.sessionID == "live-1")
        #expect(two.all.first?.sessionID == "live-2")
        await gateway.stop()
    }

    @Test("A question reaches the chat that holds the session")
    func questions() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, hub) = await opened(socket)

        let chat = ChatSession(gateway: gateway, hub: hub)
        try await join(chat, socket, stored: "stored-1", live: "live-1")
        let asked = Recorder<AgentQuestion>()
        await chat.setQuestionSink { asked.record($0) }

        socket.push(#"{"jsonrpc":"2.0","id":"srv-1","method":"approval","params":{"session_id":"live-1","command":"rm -rf x"}}"#)
        try await waitUntil { asked.all.count == 1 }
        #expect(asked.all.first?.id == "srv-1")
        await gateway.stop()
    }

    @Test("A question of a session nobody holds is refused at once")
    func orphanQuestion() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, hub) = await opened(socket)

        let chat = ChatSession(gateway: gateway, hub: hub)
        try await join(chat, socket, stored: "stored-1", live: "live-1")

        socket.push(#"{"jsonrpc":"2.0","id":"srv-9","method":"approval","params":{"session_id":"live-gone","command":"x"}}"#)
        try await waitUntil { socket.sentFrames.contains { $0["id"]?.stringValue == "srv-9" } }
        let answer = try #require(socket.sentFrames.last { $0["id"]?.stringValue == "srv-9" })
        #expect(answer["error"]?["code"]?.intValue == -32000)
        await gateway.stop()
    }

    @Test("A chat that leaves is no longer registered")
    func leave() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, hub) = await opened(socket)

        let chat = ChatSession(gateway: gateway, hub: hub)
        try await join(chat, socket, stored: "stored-1", live: "live-1")
        #expect(await hub.joinedChats == 1)

        async let leaving = chat.leave()
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "session.close" } }
        let close = socket.sentFrames.last { $0["method"]?.stringValue == "session.close" }
        let answer: JSONValue = ["jsonrpc": "2.0", "id": close?["id"] ?? "x", "result": [:]]
        socket.push(answer.encodedString)
        await leaving
        #expect(await hub.joinedChats == 0)
        await gateway.stop()
    }
}
