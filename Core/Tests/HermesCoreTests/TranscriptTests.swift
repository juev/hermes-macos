import Foundation
import Testing
@testable import HermesCore

/// The payloads the dashboard really answered, copied from the contract by `scripts/sync-fixtures.sh`.
enum Fixtures {
    /// The payloads come from the contract repository and are copied in by `scripts/sync-fixtures.sh`;
    /// a checkout without them — continuous integration, for one — runs the other suites and leaves
    /// these alone, which is what that script promises.
    static let available = Bundle.module.url(forResource: "list", withExtension: "json", subdirectory: "Fixtures/sessions") != nil

    static func json(_ area: String, _ name: String) -> JSONValue? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(area)"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue.decode(data)
    }
}

@Suite("A chat as the sidebar lists it", .enabled(if: Fixtures.available))
struct SessionTests {
    @Test("The list of sessions the dashboard answered")
    func list() throws {
        guard let json = Fixtures.json("sessions", "list") else {
            Issue.record("The contract payloads are missing: run scripts/sync-fixtures.sh")
            return
        }
        let page = SessionPage(json)
        #expect(page.sessions.count == 5)
        #expect(page.total == 263)

        let raw = try #require(json["sessions"]?.arrayValue?.first)
        let first = try #require(page.sessions.first)
        #expect(first.source == "cron")
        #expect(first.model == "gpt-6.1-sol")
        #expect(first.messageCount == raw["message_count"]?.intValue)
        #expect(first.active)
        #expect(!first.pinned)
        #expect(!first.archived)
        #expect(first.title.isEmpty)
        // A session the dashboard never named shows the start of its first message.
        #expect(first.label == first.preview)
        #expect(!first.preview.isEmpty)
        #expect(first.startedAt != nil)
        #expect(first.lastActive != nil)
        #expect(first.lastActive! >= first.startedAt!)

        // The session has spent tokens but its plan bills by subscription, so nothing to price.
        let usage = try #require(first.usage)
        let expected = (raw["input_tokens"]?.intValue ?? 0)
            + (raw["cache_read_tokens"]?.intValue ?? 0)
            + (raw["cache_write_tokens"]?.intValue ?? 0)
        #expect(usage.inputTokens == expected)
        #expect(usage.outputTokens == raw["output_tokens"]?.intValue)
        #expect(usage.costUSD == nil)
        #expect(usage.included)
    }

    @Test("A session the dashboard priced itself")
    func priced() throws {
        guard let json = Fixtures.json("sessions", "list") else {
            Issue.record("The contract payloads are missing: run scripts/sync-fixtures.sh")
            return
        }
        let page = SessionPage(json)
        let raw = try #require(json["sessions"]?.arrayValue?.first { $0["source"]?.stringValue == "android" })
        let android = try #require(page.sessions.first { $0.source == "android" })
        #expect(android.model == "deepseek-flash")
        #expect(android.messageCount == raw["message_count"]?.intValue)
        let usage = try #require(android.usage)
        #expect(!usage.included)
        // The dashboard priced this one itself.
        let price = try #require(raw["estimated_cost_usd"]?.doubleValue)
        #expect(usage.costUSD == price)
    }

    @Test("A row without an id is not a session")
    func noID() {
        #expect(SessionSummary(["title": "x"]) == nil)
        #expect(SessionSummary(["session_id": "s-1"])?.id == "s-1")
    }
}

@Suite("The stored history of one chat", .enabled(if: Fixtures.available))
struct TranscriptTests {
    private func messages() throws -> [StoredMessage] {
        guard let json = Fixtures.json("sessions", "transcript") else {
            throw FixtureError.missing
        }
        return StoredMessage.page(json)
    }

    @Test("Every row of the answer is read")
    func rows() throws {
        guard let json = Fixtures.json("sessions", "transcript") else {
            Issue.record("The contract payloads are missing: run scripts/sync-fixtures.sh")
            return
        }
        let rows = StoredMessage.page(json)
        #expect(rows.count == 16)
        #expect(rows.filter { $0.role == "assistant" }.count == 3)
        #expect(rows.filter { $0.role == "tool" }.count == 12)
        #expect(rows.filter { $0.role == "user" }.count == 1)
        #expect(rows.allSatisfy { $0.timestamp != nil })

        let assistant = try #require(rows.first { $0.role == "assistant" })
        #expect(assistant.toolCalls.count == 4)
        #expect(assistant.toolCalls.map(\.name) == ["skill_view", "skill_view", "memcue_search", "terminal"])
        #expect(assistant.toolCalls.allSatisfy { !$0.id.isEmpty })
        #expect(assistant.text.isEmpty)
        #expect(assistant.reasoning == nil)

        let reasoningRow = try #require(rows.filter { $0.role == "assistant" }.last)
        #expect(reasoningRow.reasoning != nil)
        #expect(reasoningRow.text.isEmpty)
    }

    @Test("The transcript gathers one answer until the person speaks again")
    func items() throws {
        let rows = try messages()
        let items = Transcript.items(from: rows)

        // One person's message and one answer: the three assistant rows of the stored history are
        // rounds of the same turn.
        #expect(items.count == 2)
        guard case .user(let user) = try #require(items.first) else {
            Issue.record("The first item is not the person's message")
            return
        }
        #expect(user.text.hasPrefix("<text:"))
        #expect(user.attachments.isEmpty)
        #expect(user.rowID != nil)

        guard case .assistant(let answer) = try #require(items.last) else {
            Issue.record("The second item is not an answer")
            return
        }
        #expect(answer.text.isEmpty)
        #expect(answer.tools.map(\.name) == [
            "skill_view", "skill_view", "memcue_search", "terminal",
            "read_file", "read_file", "read_file", "read_file", "terminal",
            "terminal", "skill_view", "read_file", "memcue_search"
        ])
        #expect(answer.tools.allSatisfy { $0.done })
        // Every call carries an output. In this payload all ids are the same placeholder, so which
        // output belongs to which call cannot be read from it; `outputMatching` below does that
        // with ids of its own.
        #expect(answer.tools.compactMap(\.output).count == 13)

        #expect(answer.reasoning != nil)
    }

    @Test("The output lands on the call that asked for it")
    func outputMatching() {
        let messages = [
            StoredMessage(rowID: 1, role: "user", text: "run both"),
            StoredMessage(rowID: 2, role: "assistant", text: "", toolCalls: [
                ToolCall(id: "call-a", name: "terminal", arguments: #"{"command":"ls"}"#),
                ToolCall(id: "call-b", name: "read_file", arguments: #"{"path":"/tmp/x"}"#)
            ]),
            StoredMessage(rowID: 3, role: "tool", text: "output of a", toolName: "terminal", toolCallID: "call-a"),
            StoredMessage(rowID: 4, role: "tool", text: "output of b", toolName: "read_file", toolCallID: "call-b")
        ]
        let items = Transcript.items(from: messages)
        guard case .assistant(let answer) = items.last else {
            Issue.record("The turn is not an answer")
            return
        }
        #expect(answer.tools.count == 2)
        #expect(answer.tools[0].name == "terminal")
        #expect(answer.tools[0].output == "output of a")
        #expect(answer.tools[0].context == "ls")
        #expect(answer.tools[1].name == "read_file")
        #expect(answer.tools[1].output == "output of b")
        #expect(answer.tools[1].context == "/tmp/x")
    }

    @Test("A cron report and a skill prompt become what they are")
    func serviceMessages() {
        let report = StoredMessage(
            rowID: 10, role: "user",
            text: "[Cron delivery: research-daily]\n**Тема:** NixOS."
        )
        let skillPrompt = StoredMessage(
            rowID: 11, role: "user",
            text: "[IMPORTANT: The user has invoked the \"homelab\" skill, indicating they want you to follow its instructions. The full skill content is loaded below.]\n\n---\nname: homelab\n---\n# homelab\n\nThe user has provided the following instruction alongside the skill invocation: проверь диски"
        )
        let quoted = StoredMessage(
            rowID: 12, role: "user",
            text: "[Replying to: \"the earlier line\"]\n\nи это ответ"
        )
        let items = Transcript.items(from: [report, skillPrompt, quoted])

        guard case .cronReport(let cron) = items[0] else {
            Issue.record("The cron report is not a report")
            return
        }
        #expect(cron.job == "research-daily")
        #expect(cron.text == "**Тема:** NixOS.")

        guard case .user(let bubble) = items[1] else {
            Issue.record("The skill prompt is not a message")
            return
        }
        #expect(bubble.text == "проверь диски")
        #expect(bubble.invocation?.skills == ["homelab"])
        // The bubble shows the instruction; asking again has to send the whole prompt the agent got.
        #expect(bubble.sent == skillPrompt.text)
        #expect(bubble.sent.contains("[IMPORTANT:"))
        #expect(bubble.invocation?.full.hasPrefix("[IMPORTANT:") == true)

        guard case .user(let reply) = items[2] else {
            Issue.record("The reply is not a message")
            return
        }
        #expect(reply.quote == "the earlier line")
        #expect(reply.text == "и это ответ")
    }

    @Test("A row the dashboard wrote for itself is not shown")
    func sessionMeta() throws {
        guard let json = Fixtures.json("sessions", "session-meta") else {
            Issue.record("The contract payloads are missing: run scripts/sync-fixtures.sh")
            return
        }
        let row = try #require(StoredMessage(json["message"] ?? .null))
        #expect(row.role == "session_meta")
        // The role is unknown to the transcript, so nothing is drawn for it.
        #expect(Transcript.items(from: [row]).isEmpty)
    }

    @Test("A user row the dashboard wrote for the model is hidden")
    func hidden() {
        let serverWritten = StoredMessage([
            "id": 1, "role": "user", "content": "<text:9>", "display_kind": "process_complete"
        ])
        #expect(serverWritten?.hidden == true)

        let notice = StoredMessage([
            "id": 2, "role": "user", "content": "[System: the run finished]"
        ])
        #expect(notice?.hidden == true)

        // A steering message is the person speaking during a turn and is shown.
        let steer = StoredMessage([
            "id": 3, "role": "user", "content": "stop", "display_kind": "steer"
        ])
        #expect(steer?.hidden == false)

        let ordinary = StoredMessage(["id": 4, "role": "user", "content": "hello"])
        #expect(ordinary?.hidden == false)
    }

    @Test("Content that arrives as parts is joined")
    func parts() {
        let row = StoredMessage([
            "id": 5, "role": "user",
            "content": [
                ["type": "text", "text": "one"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAA"]],
                ["type": "text", "text": "two"]
            ]
        ])
        #expect(row?.text == "one\ntwo")
        #expect(row?.images == ["data:image/png;base64,AAA"])
    }
}

enum FixtureError: Error {
    case missing
}

@Suite("What the dashboard writes into a message", .enabled(if: Fixtures.available))
struct TextParsingTests {
    @Test("The attached context is cut and the references become attachments")
    func attachments() {
        let text = """
        Look at this
        @file:/srv/data/report.csv
        @image:/srv/data/chart.png

        --- Attached Context ---

        the file contents
        """
        let (written, attachments) = TextParsing.splitUserText(text)
        #expect(written == "Look at this")
        #expect(attachments.map(\.name) == ["report.csv", "chart.png"])
        #expect(attachments[0].isImage == false)
        #expect(attachments[1].isImage == true)
        #expect(attachments.allSatisfy { $0.path.hasPrefix("/srv/data/") })
    }

    @Test("A placeholder the person never typed is dropped")
    func placeholder() {
        let (written, attachments) = TextParsing.splitUserText("look\n[screenshot]")
        #expect(written == "look")
        #expect(attachments.isEmpty)
    }

    @Test("An image the server appends after the context is still found")
    func appendedImage() {
        let text = """
        look

        --- Attached Context ---

        @image:/tmp/shot.png
        """
        let (written, attachments) = TextParsing.splitUserText(text)
        #expect(written == "look")
        #expect(attachments.map(\.path) == ["/tmp/shot.png"])
    }

    @Test("Delivered files are read out of the answer")
    func media() {
        let answer = """
        Here it is.

        MEDIA: /tmp/build/app.zip
        `MEDIA: /tmp/build/shot.png`
        MEDIA:not-a-path
        MEDIA: /tmp/build/app.zip
        """
        #expect(TextParsing.mediaPaths(in: answer) == ["/tmp/build/app.zip", "/tmp/build/shot.png"])
        let stripped = TextParsing.stripMedia(answer)
        #expect(!stripped.contains("MEDIA:"))
        #expect(stripped.hasPrefix("Here it is."))
    }

    @Test("A tool's hint comes from its arguments")
    func context() {
        #expect(TextParsing.argumentContext(#"{"command":"ls -la /tmp\nand more"}"#) == "ls -la /tmp")
        #expect(TextParsing.argumentContext(#"{"query":"swift concurrency"}"#) == "swift concurrency")
        #expect(TextParsing.argumentContext(#"{"other":"x"}"#) == "")
        #expect(TextParsing.argumentContext("not json") == "")
        #expect(TextParsing.argumentContext(#"{"command":"   "}"#) == "")
    }
}

@Suite("A turn that worked before it answered")
struct WorkBlockTests {
    @Test("Thinking and calls between the words become one block, and text stays out of it")
    func grouping() {
        let parts: [Part] = [
            .reasoning("смотрю на сборку"),
            .tool(ToolRun(id: "a", name: "terminal", context: "$ xcodebuild", output: "FAILED")),
            .tool(ToolRun(id: "b", name: "read_file", context: "Package.swift")),
            .text("Сборка падает вот тут."),
            .tool(ToolRun(id: "c", name: "terminal", context: "$ git status")),
            .reasoning("и ещё раз")
        ]
        let blocks = TranscriptBlocking.blocks(of: parts)
        #expect(blocks.count == 3)
        guard case .work(let first) = blocks[0] else { Issue.record("first is not work"); return }
        #expect(first.count == 3)
        guard case .text(let words) = blocks[1] else { Issue.record("second is not text"); return }
        #expect(words == "Сборка падает вот тут.")
        guard case .work(let last) = blocks[2] else { Issue.record("third is not work"); return }
        #expect(last.count == 2)
    }

    @Test("An answer of words alone has no block to open")
    func wordsOnly() {
        let blocks = TranscriptBlocking.blocks(of: [.text("Готово.")])
        #expect(blocks.count == 1)
    }
}
