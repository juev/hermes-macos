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

@Suite("Files sent with a message")
struct AttachmentTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    private func opened(_ socket: FakeSocket) async -> (GatewaySession, ChatSession) {
        let gateway = GatewaySession(
            endpoint: endpoint,
            credentials: FakeCredentials(),
            transport: ScriptedTransport([.socket(socket)]),
            firstPause: .milliseconds(20),
            maxPause: .milliseconds(80)
        )
        await gateway.start()
        try? await waitUntil { await gateway.currentState() == .ready }
        let chat = ChatSession(gateway: gateway)

        async let joined = chat.join(storedID: "stored-1")
        try? await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "session.resume" } }
        if let request = socket.sentFrames.last(where: { $0["method"]?.stringValue == "session.resume" }) {
            let frame: JSONValue = ["jsonrpc": "2.0", "id": request["id"] ?? "x", "result": ["session_id": "live-1"]]
            socket.push(frame.encodedString)
        }
        _ = try? await joined
        return (gateway, chat)
    }

    @Test("A picture goes to the vision queue of the turn")
    func image() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, chat) = await opened(socket)

        let draft = AttachmentDraft(name: "shot.png", mime: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        async let attaching = chat.attach(draft)
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "image.attach_bytes" } }
        let frame = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "image.attach_bytes" })
        #expect(frame["params"]?["session_id"]?.stringValue == "live-1")
        #expect(frame["params"]?["filename"]?.stringValue == "shot.png")
        #expect(frame["params"]?["content_base64"]?.stringValue == draft.data.base64EncodedString())

        let answer: JSONValue = ["jsonrpc": "2.0", "id": frame["id"] ?? "x", "result": [:]]
        socket.push(answer.encodedString)
        #expect(try await attaching == nil)
        await gateway.stop()
    }

    @Test("Any other file answers with the text that names it")
    func file() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, chat) = await opened(socket)

        let draft = AttachmentDraft(name: "notes.md", mime: "text/markdown", data: Data("# hi".utf8))
        async let attaching = chat.attach(draft)
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "file.attach" } }
        let frame = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "file.attach" })
        #expect(frame["params"]?["name"]?.stringValue == "notes.md")
        #expect(frame["params"]?["data_url"]?.stringValue == "data:text/markdown;base64," + draft.data.base64EncodedString())

        let answer: JSONValue = ["jsonrpc": "2.0", "id": frame["id"] ?? "x", "result": ["ref_text": "@file:/opt/data/uploads/notes.md"]]
        socket.push(answer.encodedString)
        #expect(try await attaching == "@file:/opt/data/uploads/notes.md")
        await gateway.stop()
    }

    @Test("An attachment without a joined chat is refused")
    func notJoined() async throws {
        let socket = FakeSocket()
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
        do {
            _ = try await chat.attach(AttachmentDraft(name: "a", mime: "text/plain", data: Data("a".utf8)))
            Issue.record("An attachment without a join did not throw")
        } catch let error as ChatError {
            #expect(error == .notConnected)
        }
        await gateway.stop()
    }
}

@Suite("A chat that is not open")
struct ChatAdminTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    private func connected(_ socket: FakeSocket) async -> GatewaySession {
        let gateway = GatewaySession(
            endpoint: endpoint,
            credentials: FakeCredentials(),
            transport: ScriptedTransport([.socket(socket)]),
            firstPause: .milliseconds(20)
        )
        await gateway.start()
        try? await waitUntil { await gateway.currentState() == .ready }
        return gateway
    }

    private func answer(_ socket: FakeSocket, method: String, result: JSONValue) async throws {
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == method } }
        let request = try #require(socket.sentFrames.last { $0["method"]?.stringValue == method })
        let frame: JSONValue = ["jsonrpc": "2.0", "id": request["id"] ?? "x", "result": result]
        socket.push(frame.encodedString)
    }

    @Test("A rename joins the chat for the call and lets it go")
    func rename() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let gateway = await connected(socket)
        let admin = ChatAdmin(gateway: gateway)

        async let renaming = admin.rename(storedID: "stored-1", title: "Новое имя")
        try await answer(socket, method: "session.resume", result: ["session_id": "live-1"])
        try await answer(socket, method: "session.title", result: [:])
        try await answer(socket, method: "session.close", result: [:])
        try await renaming

        let resume = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.resume" })
        #expect(resume["params"]?["lazy"]?.boolValue == true)
        #expect(resume["params"]?["omit_messages"]?.boolValue == true)
        let title = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.title" })
        #expect(title["params"]?["session_id"]?.stringValue == "live-1")
        #expect(title["params"]?["title"]?.stringValue == "Новое имя")
        #expect(socket.sentFrames.contains { $0["method"]?.stringValue == "session.close" })
        await gateway.stop()
    }

    @Test("An archive and a delete name the chat the sidebar knows")
    func archiveAndDelete() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let gateway = await connected(socket)
        let admin = ChatAdmin(gateway: gateway)

        async let archiving = admin.archive(storedID: "stored-1", archived: true)
        try await answer(socket, method: "session.archive", result: [:])
        try await archiving
        let archive = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.archive" })
        #expect(archive["params"]?["session_key"]?.stringValue == "stored-1")
        #expect(archive["params"]?["archived"]?.boolValue == true)

        async let deleting = admin.delete(storedID: "stored-2")
        try await answer(socket, method: "session.delete", result: [:])
        try await deleting
        let deletion = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.delete" })
        #expect(deletion["params"]?["session_id"]?.stringValue == "stored-2")
        await gateway.stop()
    }

    @Test("A chat that cannot be joined is not renamed")
    func noJoin() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let gateway = await connected(socket)
        let admin = ChatAdmin(gateway: gateway)

        async let renaming = admin.rename(storedID: "stored-1", title: "x")
        try await answer(socket, method: "session.resume", result: [:])
        do {
            try await renaming
            Issue.record("A chat without a live session was renamed")
        } catch let error as ChatError {
            #expect(error == .noLiveSession)
        }
        #expect(!socket.sentFrames.contains { $0["method"]?.stringValue == "session.title" })
        await gateway.stop()
    }
}

@Suite("A chat that does not exist yet")
struct NewChatTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    @Test("Creating a chat asks for a new session and keeps it")
    func create() async throws {
        let socket = FakeSocket()
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

        async let creating = chat.create()
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "session.create" } }
        let request = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.create" })
        #expect(request["params"]?["source"]?.stringValue == "macos")
        #expect(request["params"]?["close_on_disconnect"]?.boolValue == false)

        let answer: JSONValue = ["jsonrpc": "2.0", "id": request["id"] ?? "x", "result": ["session_id": "live-new"]]
        socket.push(answer.encodedString)
        #expect(try await creating == "live-new")
        let live = await chat.currentLiveID()
        #expect(live == "live-new")

        // The new session takes prompts at once.
        async let sending = chat.submit("Привет")
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "prompt.submit" } }
        let prompt = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "prompt.submit" })
        #expect(prompt["params"]?["session_id"]?.stringValue == "live-new")
        let promptAnswer: JSONValue = ["jsonrpc": "2.0", "id": prompt["id"] ?? "x", "result": [:]]
        socket.push(promptAnswer.encodedString)
        try await sending
        await gateway.stop()
    }

    @Test("A dashboard that creates nothing is an error")
    func noSession() async throws {
        let socket = FakeSocket()
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

        async let creating = chat.create()
        try await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "session.create" } }
        let request = try #require(socket.sentFrames.last { $0["method"]?.stringValue == "session.create" })
        let answer: JSONValue = ["jsonrpc": "2.0", "id": request["id"] ?? "x", "result": [:]]
        socket.push(answer.encodedString)
        do {
            _ = try await creating
            Issue.record("A dashboard that created nothing was taken as success")
        } catch let error as ChatError {
            #expect(error == .noLiveSession)
        }
        await gateway.stop()
    }
}
