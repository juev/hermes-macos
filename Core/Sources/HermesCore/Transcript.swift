import Foundation

/// A tool the agent ran during a turn.
public struct ToolRun: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The one-line hint of what the call did, from its arguments.
    public let context: String
    public let arguments: String
    public var output: String?
    public var done: Bool
    /// How long the call took, when the dashboard says.
    public var durationSeconds: Double?
    /// The dashboard's own one-line account, like "Did 3 searches in 2s".
    public var summary: String?

    public init(id: String, name: String, context: String = "", arguments: String = "", output: String? = nil, done: Bool = true, durationSeconds: Double? = nil, summary: String? = nil) {
        self.durationSeconds = durationSeconds
        self.summary = summary
        self.id = id
        self.name = name
        self.context = context
        self.arguments = arguments
        self.output = output
        self.done = done
    }
}

/// A piece of an answer, in the order the agent produced it.
public enum Part: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case tool(ToolRun)
}

/// A message the person sent.
public struct UserBubble: Sendable, Equatable {
    public let key: String
    public let text: String
    public let attachments: [Attachment]
    public let rowID: Int?

    public init(key: String, text: String, attachments: [Attachment] = [], rowID: Int? = nil) {
        self.key = key
        self.text = text
        self.attachments = attachments
        self.rowID = rowID
    }
}

/// One answer of the agent: its reasoning, its words and the tools it ran, in order.
public struct AssistantTurn: Sendable, Equatable {
    public let key: String
    public var parts: [Part]
    /// True while the turn streams; `message.complete` closes it.
    public var streaming: Bool
    public var error: String?
    public var interrupted: Bool

    public init(key: String, parts: [Part], streaming: Bool = false, error: String? = nil, interrupted: Bool = false) {
        self.key = key
        self.parts = parts
        self.streaming = streaming
        self.error = error
        self.interrupted = interrupted
    }

    /// The answer without tools and reasoning: what copying and reading aloud take.
    public var text: String {
        parts.compactMap { part in
            if case .text(let text) = part { return text }
            return nil
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var reasoning: String? {
        parts.compactMap { part in
            if case .reasoning(let text) = part { return text }
            return nil
        }
        .first { !$0.isEmpty }
    }

    /// The answer with the `MEDIA:` lines gone: the files are drawn as cards under it.
    public var displayText: String {
        TextParsing.stripMedia(text)
    }

    /// Files the agent delivered with `MEDIA:` directives, in order and without repeats.
    public var deliveredFiles: [String] {
        TextParsing.mediaPaths(in: text)
    }

    public var tools: [ToolRun] {
        parts.compactMap { part in
            if case .tool(let run) = part { return run }
            return nil
        }
    }
}

public enum ChatItem: Sendable, Equatable {
    case user(UserBubble)
    case assistant(AssistantTurn)
}

public enum Transcript {
    /// Builds the transcript of a stored history: the tools' output joins the call that asked for
    /// them, one answer gathers everything the agent produced until the person spoke again, and the
    /// rows the dashboard wrote for the model itself are dropped.
    public static func items(from messages: [StoredMessage]) -> [ChatItem] {
        var items: [ChatItem] = []
        var current: AssistantTurn?

        func flush() {
            if let current { items.append(.assistant(current)) }
            current = nil
        }

        for message in messages where !message.hidden {
            switch message.role {
            case "user":
                flush()
                let (text, attachments) = TextParsing.splitUserText(message.text)
                let images = message.images.map { Attachment(path: $0, name: "image", isImage: true) }
                items.append(.user(UserBubble(
                    key: "u\(message.rowID)",
                    text: text,
                    attachments: attachments + images,
                    rowID: message.rowID
                )))

            case "assistant":
                var parts = current?.parts ?? []
                if let reasoning = message.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(.reasoning(reasoning))
                }
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(.text(message.text))
                }
                for call in message.toolCalls {
                    parts.append(.tool(ToolRun(
                        id: call.id,
                        name: call.name,
                        context: TextParsing.argumentContext(call.arguments),
                        arguments: call.arguments
                    )))
                }
                current = AssistantTurn(key: current?.key ?? "a\(message.rowID)", parts: parts)

            case "tool":
                guard var turn = current else { continue }
                turn.parts = turn.parts.map { part in
                    guard case .tool(var run) = part, run.id == message.toolCallID else { return part }
                    run.output = message.text
                    run.done = true
                    return .tool(run)
                }
                current = turn

            default:
                continue
            }
        }
        flush()
        return items
    }
}
