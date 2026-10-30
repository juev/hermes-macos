import Foundation
import Testing
@testable import HermesCore

private func request(_ method: String, _ params: [String: JSONValue]) -> ServerRequest {
    ServerRequest(id: "srv-1", method: method, params: params)
}

@Suite("A question the agent asks")
struct AgentQuestionsTests {
    @Test("A dangerous command")
    func command() {
        let question = AgentQuestion(request("approval", [
            "session_id": "live-1",
            "command": "rm -rf /tmp/build",
            "description": "writes outside the workspace",
            "pattern_key": "dangerous_command",
            "choices": ["once", "always", "deny"]
        ]))
        guard case .approval(let approval)? = question else {
            Issue.record("Not an approval")
            return
        }
        #expect(approval.kind == .command)
        #expect(approval.command == "rm -rf /tmp/build")
        #expect(approval.description == "writes outside the workspace")
        #expect(approval.choices == ["once", "always", "deny"])
        #expect(approval.title == "Approve a command")
        #expect(approval.summary.contains("rm -rf"))
    }

    @Test("A plugin rule names its tool and shows no command")
    func pluginRule() {
        let labelled = AgentQuestion(request("approval", [
            "command": "<deploy> (plugin approval rule)",
            "pattern_key": "plugin_rule:deploy"
        ]))
        guard case .approval(let approval)? = labelled else {
            Issue.record("Not an approval")
            return
        }
        #expect(approval.kind == .tool("deploy"))
        #expect(approval.command.isEmpty)
        #expect(approval.choices == ["once", "deny"])

        let named = AgentQuestion(request("approval", [
            "command": "anything",
            "tool_name": "terminal",
            "pattern_key": "plugin_rule:terminal"
        ]))
        guard case .approval(let withName)? = named else { return }
        #expect(withName.kind == .tool("terminal"))
    }

    @Test("An MCP elicitation offers only yes and no")
    func mcp() {
        let question = AgentQuestion(request("approval", [
            "command": "Server asks: send an email?",
            "pattern_key": "mcp_elicitation",
            "choices": ["once", "session", "deny"]
        ]))
        guard case .approval(let approval)? = question else {
            Issue.record("Not an approval")
            return
        }
        #expect(approval.kind == .mcp)
        #expect(approval.choices == ["once", "deny"])
        #expect(approval.title == "The server asks")
    }

    @Test("Questions with offered choices")
    func clarify() {
        let question = AgentQuestion(request("clarify", [
            "session_id": "live-1",
            "questions": [
                ["qid": "q1", "question": "Which branch?", "choices": ["main", "release"]],
                ["qid": "q2", "question": "Anything else?"]
            ]
        ]))
        guard case .clarify(let clarify)? = question else {
            Issue.record("Not a clarify")
            return
        }
        #expect(clarify.questions.count == 2)
        #expect(clarify.questions[0].id == "q1")
        #expect(clarify.questions[0].choices == ["main", "release"])
        #expect(clarify.questions[1].choices.isEmpty)
    }

    @Test("A secret and a sudo password")
    func secrets() {
        let secret = AgentQuestion(request("secret", ["prompt": "API key for the deploy", "env_var": "DEPLOY_KEY"]))
        guard case .secret(let one)? = secret else {
            Issue.record("Not a secret")
            return
        }
        #expect(one.prompt == "API key for the deploy")
        #expect(!one.isSudo)

        let sudo = AgentQuestion(request("sudo", ["command": "brew install x"]))
        guard case .secret(let two)? = sudo else { return }
        #expect(two.isSudo)
        #expect(two.prompt.contains("brew install x"))
    }

    @Test("A question this client does not answer is not modelled")
    func unsupported() {
        #expect(AgentQuestion(request("window.pick", [:])) == nil)
    }

    @Test("The answers the dashboard reads")
    func answers() {
        #expect(AgentAnswer.approval("once") == ["choice": "once"])
        #expect(AgentAnswer.clarify(["q1": "main", "q2": nil]) == [
            "answers": ["q1": "main", "q2": .null], "outcome": "submitted"
        ])
        #expect(AgentAnswer.clarifyCancelled == ["outcome": "cancelled"])
        #expect(AgentAnswer.secret("hunter2") == ["value": "hunter2"])
    }
}

@Suite("Questions of an open chat")
struct ChatQuestionTests {
    private let endpoint = Endpoint(address: "https://hermes.example.test")!

    private func opened(_ socket: FakeSocket) async -> (GatewaySession, ChatSession) {
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
        try? await waitUntil { socket.sentFrames.contains { $0["method"]?.stringValue == "session.resume" } }
        if let frame = socket.sentFrames.last(where: { $0["method"]?.stringValue == "session.resume" }) {
            let answer: JSONValue = ["jsonrpc": "2.0", "id": frame["id"] ?? "x", "result": ["session_id": "live-1"]]
            socket.push(answer.encodedString)
        }
        _ = try? await joined
        return (gateway, chat)
    }

    @Test("A question of this chat reaches the sink and its answer goes back")
    func answered() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, chat) = await opened(socket)

        let seen = Recorder<AgentQuestion>()
        await chat.setQuestionSink { seen.record($0) }
        socket.push(#"{"jsonrpc":"2.0","id":"srv-9","method":"approval","params":{"session_id":"live-1","command":"rm -rf x","pattern_key":"dangerous_command"}}"#)

        try await waitUntil { seen.all.count == 1 }
        let question = try #require(seen.all.first)
        await chat.answer(question, with: AgentAnswer.approval("deny"))

        try await waitUntil { socket.sentFrames.contains { $0["id"]?.stringValue == "srv-9" } }
        let answer = try #require(socket.sentFrames.last { $0["id"]?.stringValue == "srv-9" })
        #expect(answer["result"]?["choice"]?.stringValue == "deny")
        await gateway.stop()
    }

    @Test("A question of another chat is left alone")
    func otherChat() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, chat) = await opened(socket)

        let seen = Recorder<AgentQuestion>()
        await chat.setQuestionSink { seen.record($0) }
        socket.push(#"{"jsonrpc":"2.0","id":"srv-8","method":"approval","params":{"session_id":"another","command":"x"}}"#)
        try await Task.sleep(for: .milliseconds(120))
        #expect(seen.all.isEmpty)
        await gateway.stop()
    }

    @Test("A question this client cannot answer is refused at once")
    func refused() async throws {
        let socket = FakeSocket()
        socket.push(readyFrame())
        let (gateway, chat) = await opened(socket)

        let seen = Recorder<AgentQuestion>()
        await chat.setQuestionSink { seen.record($0) }
        socket.push(#"{"jsonrpc":"2.0","id":"srv-7","method":"window.pick","params":{"session_id":"live-1"}}"#)

        try await waitUntil { socket.sentFrames.contains { $0["id"]?.stringValue == "srv-7" } }
        let answer = try #require(socket.sentFrames.last { $0["id"]?.stringValue == "srv-7" })
        #expect(answer["error"]?["code"]?.intValue == -32000)
        #expect(seen.all.isEmpty)
        await gateway.stop()
    }
}
