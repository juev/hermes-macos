import Foundation
import Testing
@testable import HermesCore

@Suite("The models a dashboard offers")
struct ModelsTests {
    @Test("Options carry the current pick and every provider with models to offer")
    func options() {
        let json: JSONValue = [
            "model": "deepseek-flash", "provider": "deepseek",
            "providers": [
                ["slug": "deepseek", "name": "DeepSeek", "models": ["deepseek-flash", "deepseek-pro"], "is_current": true],
                ["slug": "anthropic", "name": "Anthropic", "models": ["opus", "sonnet"]],
                ["slug": "empty", "name": "Empty", "models": []]
            ]
        ]
        let options = ModelOptions(json)
        #expect(options.model == "deepseek-flash")
        #expect(options.provider == "deepseek")
        #expect(options.providers.map(\.slug) == ["deepseek", "anthropic"])
        #expect(options.providers[0].isCurrent)
        #expect(options.providers[1].models == ["opus", "sonnet"])
    }
}

@Suite("Asking a chat for another model")
struct ChatModelChangeTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    private func openChat(_ socket: FakeSocket) async throws -> (GatewaySession, ChatSession) {
        socket.push(readyFrame())
        let gateway = GatewaySession(
            endpoint: endpoint,
            credentials: FakeCredentials(),
            transport: ScriptedTransport([.socket(socket)]),
            firstPause: .milliseconds(20)
        )
        await gateway.start()
        try? await waitUntil { await gateway.currentState() == .ready }
        let chat = ChatSession(gateway: gateway)
        async let joined = chat.join(storedID: "stored-1")
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "session.resume" } }
        let resume = socket.sentFrames.last { $0["method"]?.stringValue == "session.resume" }
        let answer: JSONValue = ["jsonrpc": "2.0", "id": resume?["id"] ?? "x", "result": ["session_id": "live-1"]]
        socket.push(answer.encodedString)
        _ = try await joined
        return (gateway, chat)
    }

    @Test("The value the dashboard reads is the model and its provider")
    func value() async throws {
        let socket = FakeSocket()
        let (gateway, chat) = try await openChat(socket)
        async let changing = chat.setModel(provider: "deepseek", model: "deepseek-flash")
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "config.set" } }
        let call = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "config.set" })
        #expect(call["params"]?["key"]?.stringValue == "model")
        #expect(call["params"]?["value"]?.stringValue == "deepseek-flash --provider deepseek")
        #expect(call["params"]?["session_id"]?.stringValue == "live-1")
        let answer: JSONValue = ["jsonrpc": "2.0", "id": call["id"] ?? "x", "result": [:]]
        socket.push(answer.encodedString)
        #expect(try await changing == .set)
        await gateway.stop()
    }

    @Test("An expensive model is asked for twice")
    func confirmation() async throws {
        let socket = FakeSocket()
        let (gateway, chat) = try await openChat(socket)
        async let changing = chat.setModel(provider: "anthropic", model: "opus", confirmed: true)
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "config.set" } }
        let call = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "config.set" })
        #expect(call["params"]?["confirm_expensive_model"]?.boolValue == true)
        let answer: JSONValue = ["jsonrpc": "2.0", "id": call["id"] ?? "x", "result": ["confirm_required": true, "confirm_message": "opus costs more"]]
        socket.push(answer.encodedString)
        #expect(try await changing == .needsConfirmation(message: "opus costs more"))
        await gateway.stop()
    }

    @Test("A turn already running makes the switch wait for the next one")
    func deferred() async throws {
        let socket = FakeSocket()
        let (gateway, chat) = try await openChat(socket)
        async let changing = chat.setModel(provider: "deepseek", model: "deepseek-pro")
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "config.set" } }
        let call = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "config.set" })
        let answer: JSONValue = ["jsonrpc": "2.0", "id": call["id"] ?? "x", "result": ["deferred": true, "warning": "the turn under way keeps its model"]]
        socket.push(answer.encodedString)
        #expect(try await changing == .deferred(warning: "the turn under way keeps its model"))
        await gateway.stop()
    }
}
