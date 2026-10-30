import Foundation

/// A turn as it arrives, event by event: the answer grows in the last item of the transcript, its
/// tools open and close inside it, and `message.complete` shuts it.
///
/// The dashboard sends the stored history after each round of tools, so the events carry what the
/// history does not yet have: a delta continues the last piece of text, a tool takes its place in the
/// order it ran, and reasoning that arrives whole after the answer goes where it belongs.
public enum LiveTurn {
    /// Applies one event to the transcript; [newKey] names a turn that had to be opened.
    public static func apply(_ event: GatewayEvent, to items: [ChatItem], newKey: (() -> String) = { UUID().uuidString }) -> [ChatItem] {
        let payload = event.payload
        switch event.type {
        case "message.start":
            return open(items, newKey: newKey)

        case "message.delta":
            guard let text = payload["text"]?.stringValue else { return items }
            return update(items, newKey: newKey) { parts in
                append(text, to: parts)
            }

        case "message.interim":
            let text = payload["text"]?.stringValue ?? ""
            let alreadyStreamed = payload["already_streamed"]?.flag ?? false
            guard !alreadyStreamed, !text.isEmpty else { return items }
            return update(items, newKey: newKey) { $0 + [.text(text)] }

        case "reasoning.delta":
            guard let text = payload["text"]?.stringValue else { return items }
            return update(items, newKey: newKey) { parts in
                if case .reasoning(let old)? = parts.last {
                    return parts.dropLast() + [.reasoning(old + text)]
                }
                return parts + [.reasoning(text)]
            }

        case "reasoning.available":
            guard let text = payload["text"]?.stringValue else { return items }
            return update(items, newKey: newKey) { parts in
                if let index = parts.firstIndex(where: { if case .reasoning = $0 { true } else { false } }) {
                    var copy = parts
                    copy[index] = .reasoning(text)
                    return copy
                }
                let firstText = parts.firstIndex(where: { if case .text = $0 { true } else { false } }) ?? parts.endIndex
                var copy = parts
                copy.insert(.reasoning(text), at: firstText)
                return copy
            }

        case "tool.start":
            let run = ToolRun(
                id: payload["tool_id"]?.scalarString ?? "",
                name: payload["name"]?.stringValue ?? "",
                context: payload["context"]?.stringValue ?? payload["preview"]?.stringValue ?? "",
                arguments: payload["args_text"]?.stringValue ?? payload["args"].map(Self.text) ?? "",
                done: false
            )
            return update(items, newKey: newKey) { parts in
                if parts.contains(where: { if case .tool(let existing) = $0 { existing.id == run.id } else { false } }) {
                    return parts
                }
                return parts + [.tool(run)]
            }

        case "tool.complete":
            let id = payload["tool_id"]?.scalarString ?? ""
            let output = payload["result"].map(Self.text) ?? payload["result_text"]?.stringValue
            return update(items, newKey: newKey) { parts in
                parts.map { part in
                    guard case .tool(var run) = part, run.id == id else { return part }
                    run.done = true
                    run.durationSeconds = payload["duration_s"]?.numericValue
                    run.summary = payload["summary"]?.stringValue
                    if let output { run.output = output }
                    return .tool(run)
                }
            }

        case "message.complete":
            return complete(items, payload: payload)

        default:
            return items
        }
    }

    /// Closes a turn that never got `message.complete`, e.g. the person stopped it.
    public static func close(_ items: [ChatItem], interrupted: Bool) -> [ChatItem] {
        guard case .assistant(let turn)? = items.last, turn.streaming else { return items }
        var parts = turn.parts
        parts = parts.map { part in
            guard case .tool(var run) = part, !run.done else { return part }
            run.done = true
            return .tool(run)
        }
        var closed = turn
        closed.parts = parts
        closed.streaming = false
        closed.interrupted = interrupted
        return items.dropLast() + [.assistant(closed)]
    }

    /// Picks up a turn that runs while the chat was not open. The dashboard writes the answer down
    /// after each round of tools, so the stored history may end with part of it; what streamed while
    /// the chat was away continues it, and text that does not continue the stored part is left out
    /// rather than shown twice.
    public static func resume(_ items: [ChatItem], streamed: String, newKey: (() -> String) = { UUID().uuidString }) -> [ChatItem] {
        if case .assistant(let last)? = items.last, last.streaming { return items }
        var opened = items
        if case .assistant(var last)? = opened.last {
            last.streaming = true
            opened = opened.dropLast() + [.assistant(last)]
        } else {
            opened = open(opened, newKey: newKey)
        }
        guard case .assistant(let turn)? = opened.last else { return opened }
        let stored = turn.text
        let missing = streamed.hasPrefix(stored) ? String(streamed.dropFirst(stored.count)) : ""
        guard !missing.isEmpty else { return opened }
        // What streamed while the chat was away continues the stored words rather than starting a
        // second paragraph of them.
        var parts = turn.parts
        if case .text(let stored)? = parts.last {
            parts[parts.count - 1] = .text(stored + missing)
        } else {
            parts.append(.text(missing))
        }
        return opened.dropLast() + [.assistant(AssistantTurn(key: turn.key, parts: parts, streaming: true))]
    }

    // MARK: - The open turn

    private static func open(_ items: [ChatItem], newKey: () -> String) -> [ChatItem] {
        if case .assistant(let last)? = items.last, last.streaming { return items }
        return items + [.assistant(AssistantTurn(key: newKey(), parts: [], streaming: true))]
    }

    private static func update(_ items: [ChatItem], newKey: () -> String, change: ([Part]) -> [Part]) -> [ChatItem] {
        let opened = open(items, newKey: newKey)
        guard case .assistant(var turn)? = opened.last else { return opened }
        turn.parts = change(turn.parts)
        return opened.dropLast() + [.assistant(turn)]
    }

    private static func append(_ text: String, to parts: [Part]) -> [Part] {
        if case .text(let old)? = parts.last {
            return parts.dropLast() + [.text(old + text)]
        }
        return parts + [.text(text)]
    }

    private static func complete(_ items: [ChatItem], payload: [String: JSONValue]) -> [ChatItem] {
        guard case .assistant(var turn)? = items.last else { return items }
        let status = payload["status"]?.stringValue ?? "complete"
        let error = status == "error"
            ? payload["error"]?.scalarString ?? payload["failure_reason"]?.stringValue ?? "The turn failed."
            : nil

        turn.parts = turn.parts.map { part in
            guard case .tool(var run) = part, !run.done else { return part }
            run.done = true
            return .tool(run)
        }

        // The final text replaces what streamed, which may lack what the dashboard rendered at the end.
        if let final = payload["text"]?.stringValue ?? payload["rendered"]?.stringValue, !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let streamed = turn.parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined()
            if streamed.trimmingCharacters(in: .whitespacesAndNewlines) != final.trimmingCharacters(in: .whitespacesAndNewlines) {
                let textParts = turn.parts.indices.filter { index in if case .text = turn.parts[index] { true } else { false } }
                if textParts.count == 1, let only = textParts.first {
                    turn.parts[only] = .text(final)
                } else if streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turn.parts.append(.text(final))
                }
            }
        }

        turn.streaming = false
        turn.error = error
        turn.interrupted = status == "interrupted"
        return items.dropLast() + [.assistant(turn)]
    }

    /// A payload value as the text a tool call keeps: a string as it is, anything else as JSON.
    private static func text(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        guard let data = try? value.encoded() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
