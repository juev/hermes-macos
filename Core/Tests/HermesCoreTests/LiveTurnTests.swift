import Foundation
import Testing
@testable import HermesCore

/// The events a turn sends, as the dashboard writes them in `GatewayEvent.payload`.
private func event(_ type: String, _ payload: [String: JSONValue]) -> GatewayEvent {
    GatewayEvent(params: ["type": .string(type), "session_id": "live-1", "payload": .object(payload)])
}

private func turn(_ items: [ChatItem]) -> AssistantTurn? {
    if case .assistant(let turn)? = items.last { return turn }
    return nil
}

/// Names the turns a test opens, so a key is readable in a failure.
private final class Counter: @unchecked Sendable {
    private var value = 0
    func next() -> String {
        value += 1
        return "a\(value)"
    }
}

@Suite("A turn as it arrives")
struct LiveTurnTests {

    @Test("Words grow one delta at a time and the final text replaces them")
    func words() {
        let keys = Counter()
        var items: [ChatItem] = [.user(UserBubble(key: "u1", text: "hi"))]
        items = LiveTurn.apply(event("message.start", [:]), to: items, newKey: keys.next)
        #expect(turn(items)?.streaming == true)

        items = LiveTurn.apply(event("message.delta", ["text": "Hel"]), to: items, newKey: keys.next)
        items = LiveTurn.apply(event("message.delta", ["text": "lo"]), to: items, newKey: keys.next)
        #expect(turn(items)?.text == "Hello")

        // The dashboard's final text is what the bubble keeps.
        items = LiveTurn.apply(event("message.complete", ["status": "complete", "text": "Hello!"]), to: items, newKey: keys.next)
        #expect(turn(items)?.text == "Hello!")
        #expect(turn(items)?.streaming == false)
        #expect(items.count == 2)
    }

    @Test("Reasoning that streams is one part; reasoning that arrives whole goes before the words")
    func reasoning() {
        let keys = Counter()
        var items: [ChatItem] = [.user(UserBubble(key: "u1", text: "hi"))]
        items = LiveTurn.apply(event("reasoning.delta", ["text": "Let me "]), to: items, newKey: keys.next)
        items = LiveTurn.apply(event("reasoning.delta", ["text": "think."]), to: items, newKey: keys.next)
        #expect(turn(items)?.reasoning == "Let me think.")

        items = LiveTurn.apply(event("message.delta", ["text": "Answer"]), to: items, newKey: keys.next)
        items = LiveTurn.apply(event("reasoning.available", ["text": "Let me think, properly."]), to: items, newKey: keys.next)
        let parts = try! #require(turn(items)?.parts)
        #expect(turn(items)?.reasoning == "Let me think, properly.")
        // The finished reasoning sits in front of the words, and there is only one of it.
        if case .reasoning = parts[0] {} else { Issue.record("Reasoning is not first") }
        if case .text = parts[1] {} else { Issue.record("The words are not second") }
        #expect(parts.count == 2)
    }

    @Test("A tool opens, closes and keeps its output")
    func tools() {
        let keys = Counter()
        var items: [ChatItem] = [.user(UserBubble(key: "u1", text: "hi"))]
        items = LiveTurn.apply(event("tool.start", [
            "tool_id": "t-1", "name": "terminal", "context": "ls -la"
        ]), to: items, newKey: keys.next)
        #expect(turn(items)?.tools.count == 1)
        #expect(turn(items)?.tools.first?.done == false)

        // The same tool opening twice is one part.
        items = LiveTurn.apply(event("tool.start", ["tool_id": "t-1", "name": "terminal"]), to: items, newKey: keys.next)
        #expect(turn(items)?.tools.count == 1)

        items = LiveTurn.apply(event("tool.complete", [
            "tool_id": "t-1", "duration_s": 1.5, "summary": "Listed 3 files", "result": "a\nb\nc"
        ]), to: items, newKey: keys.next)
        let run = try! #require(turn(items)?.tools.first)
        #expect(run.done)
        #expect(run.output == "a\nb\nc")
        #expect(run.durationSeconds == 1.5)
        #expect(run.summary == "Listed 3 files")
    }

    @Test("An interim message the words already carried is dropped")
    func interim() {
        let keys = Counter()
        var items: [ChatItem] = [.user(UserBubble(key: "u1", text: "hi"))]
        items = LiveTurn.apply(event("message.interim", ["text": "quick note", "already_streamed": true]), to: items, newKey: keys.next)
        #expect(turn(items) == nil)

        items = LiveTurn.apply(event("message.interim", ["text": "quick note"]), to: items, newKey: keys.next)
        #expect(turn(items)?.text == "quick note")
    }

    @Test("A failed turn keeps its reason")
    func failed() {
        let keys = Counter()
        var items: [ChatItem] = [.user(UserBubble(key: "u1", text: "hi"))]
        items = LiveTurn.apply(event("message.start", [:]), to: items, newKey: keys.next)
        items = LiveTurn.apply(event("message.complete", [
            "status": "error", "failure_reason": "the model ran out of context"
        ]), to: items, newKey: keys.next)
        #expect(turn(items)?.error == "the model ran out of context")
        #expect(turn(items)?.streaming == false)
    }

    @Test("A turn that never completes is closed by the client")
    func closed() {
        let keys = Counter()
        var items: [ChatItem] = [.user(UserBubble(key: "u1", text: "hi"))]
        items = LiveTurn.apply(event("message.delta", ["text": "half an ans"]), to: items, newKey: keys.next)
        items = LiveTurn.apply(event("tool.start", ["tool_id": "t-1", "name": "terminal"]), to: items, newKey: keys.next)
        items = LiveTurn.close(items, interrupted: true)

        #expect(turn(items)?.streaming == false)
        #expect(turn(items)?.interrupted == true)
        #expect(turn(items)?.tools.first?.done == true)
    }

    @Test("A turn that ran while the chat was away continues the stored part")
    func resumed() {
        let keys = Counter()
        let stored: [ChatItem] = [
            .user(UserBubble(key: "u1", text: "hi")),
            .assistant(AssistantTurn(key: "a2", parts: [.text("The first half")]))
        ]
        let resumed = LiveTurn.resume(stored, streamed: "The first half and the rest.")
        #expect(turn(resumed)?.streaming == true)
        #expect(turn(resumed)?.text == "The first half and the rest.")

        // Text that does not continue what is stored is not shown twice.
        let unrelated = LiveTurn.resume(stored, streamed: "Something else entirely")
        #expect(turn(unrelated)?.text == "The first half")
    }

    @Test("An unknown event changes nothing")
    func unknown() {
        let keys = Counter()
        let items: [ChatItem] = [.user(UserBubble(key: "u1", text: "hi"))]
        #expect(LiveTurn.apply(event("status.update", ["text": "thinking"]), to: items, newKey: keys.next) == items)
    }
}
