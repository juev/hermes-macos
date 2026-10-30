import Foundation

/// Tokens and money a chat has spent, as the dashboard totals them for the session.
public struct SessionUsage: Sendable, Equatable {
    /// Every token the model read, cached ones included.
    public let inputTokens: Int
    public let outputTokens: Int
    /// Nil when the dashboard knows no price for the model.
    public let costUSD: Double?
    /// The provider bills by subscription, not per token.
    public let included: Bool

    public init(inputTokens: Int, outputTokens: Int, costUSD: Double?, included: Bool) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.included = included
    }

    public var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 }
}

/// A chat as the sidebar lists it.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let preview: String
    public let source: String
    public let model: String?
    public let startedAt: Date?
    public let lastActive: Date?
    public let messageCount: Int
    public let pinned: Bool
    public let archived: Bool
    public let active: Bool
    public let unread: Bool
    public let usage: SessionUsage?

    /// What the sidebar shows: the dashboard's title, else the start of the first message.
    public var label: String { title.isEmpty ? preview : title }

    public init(
        id: String, title: String = "", preview: String = "", source: String = "", model: String? = nil,
        startedAt: Date? = nil, lastActive: Date? = nil, messageCount: Int = 0,
        pinned: Bool = false, archived: Bool = false, active: Bool = false, unread: Bool = false,
        usage: SessionUsage? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.source = source
        self.model = model
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.pinned = pinned
        self.archived = archived
        self.active = active
        self.unread = unread
        self.usage = usage
    }
}

public struct SessionPage: Sendable, Equatable {
    public let sessions: [SessionSummary]
    public let total: Int

    public init(sessions: [SessionSummary], total: Int) {
        self.sessions = sessions
        self.total = total
    }
}

/// One call of a tool, as the assistant's row records it.
public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// A row of the stored history, as `GET /api/sessions/{id}/messages` answers it.
public struct StoredMessage: Sendable, Equatable {
    public let rowID: Int
    public let role: String
    public let text: String
    public let reasoning: String?
    public let toolCalls: [ToolCall]
    public let toolName: String?
    public let toolCallID: String?
    public let timestamp: Date?
    public let hidden: Bool
    public let images: [String]

    public init(
        rowID: Int, role: String, text: String, reasoning: String? = nil, toolCalls: [ToolCall] = [],
        toolName: String? = nil, toolCallID: String? = nil, timestamp: Date? = nil, hidden: Bool = false,
        images: [String] = []
    ) {
        self.rowID = rowID
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.timestamp = timestamp
        self.hidden = hidden
        self.images = images
    }
}

// MARK: - Reading the dashboard's JSON

extension SessionSummary {
    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["session_id"]?.stringValue else { return nil }
        let started = json["started_at"]?.numericValue ?? json["session_started"]?.numericValue
        self.init(
            id: id,
            title: json["title"]?.stringValue ?? "",
            preview: json["preview"]?.stringValue ?? "",
            source: json["source"]?.stringValue ?? "",
            model: json["model"]?.stringValue,
            startedAt: started.flatMap(Self.date),
            lastActive: (json["last_active"]?.numericValue ?? json["last_activity_at"]?.numericValue).flatMap(Self.date) ?? started.flatMap(Self.date),
            messageCount: json["message_count"]?.intValue ?? 0,
            pinned: json["pinned"]?.flag ?? false,
            archived: json["archived"]?.flag ?? false,
            active: json["is_active"]?.flag ?? false,
            unread: json["unread"]?.flag ?? false,
            usage: Self.usage(json)
        )
    }

    private static func usage(_ json: JSONValue) -> SessionUsage? {
        let input = (json["input_tokens"]?.intValue ?? 0)
            + (json["cache_read_tokens"]?.intValue ?? 0)
            + (json["cache_write_tokens"]?.intValue ?? 0)
        let output = json["output_tokens"]?.intValue ?? 0
        guard input != 0 || output != 0 else { return nil }
        // The billed amount when the provider reported one, else the dashboard's own estimate.
        let cost = [json["actual_cost_usd"]?.doubleValue, json["estimated_cost_usd"]?.doubleValue]
            .compactMap { $0 }
            .first { $0 > 0 }
        return SessionUsage(inputTokens: input, outputTokens: output, costUSD: cost, included: cost == nil && json["cost_status"]?.stringValue == "included")
    }

    static func date(_ unixSeconds: Double) -> Date? {
        guard unixSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: unixSeconds)
    }
}

extension SessionPage {
    /// Reads `GET /api/sessions`.
    public init(_ json: JSONValue) {
        let sessions = json["sessions"]?.arrayValue?.compactMap(SessionSummary.init) ?? []
        self.init(sessions: sessions, total: json["total"]?.intValue ?? sessions.count)
    }
}

extension StoredMessage {
    /// The openings the dashboard wrote for the model itself before it learned to say so with a
    /// `display_kind`; only them identifies such a row on an older dashboard.
    static let oldNotices = ["[IMPORTANT: Background process ", "[ASYNC DELEGATION BATCH COMPLETE", "[System: "]

    public init?(_ json: JSONValue) {
        let role = json["role"]?.stringValue ?? "assistant"
        let (text, images) = Self.content(json["content"])
        let kind = json["display_kind"]?.stringValue
        let shown = json["display_content"]?.stringValue ?? text

        // A user row the dashboard wrote for the model: the person did not write it.
        let writtenByServer = role == "user" && kind != nil && kind != "steer"
        let oldNotice = role == "user" && kind == nil && Self.oldNotices.contains { shown.hasPrefix($0) }
        let hidden = kind == "hidden" || writtenByServer || oldNotice || json["_compressed_summary"]?.flag == true

        let calls = json["tool_calls"]?.arrayValue?.compactMap { call -> ToolCall? in
            let function = call["function"]
            let name = function?["name"]?.stringValue ?? call["name"]?.stringValue ?? ""
            let arguments = function?["arguments"].map(Self.arguments) ?? ""
            return ToolCall(id: call["id"]?.stringValue ?? call["call_id"]?.stringValue ?? "", name: name, arguments: arguments)
        } ?? []

        self.init(
            rowID: json["id"]?.intValue ?? 0,
            role: role,
            text: shown,
            reasoning: json["reasoning"]?.stringValue ?? json["reasoning_content"]?.stringValue,
            toolCalls: calls,
            toolName: json["tool_name"]?.stringValue,
            toolCallID: json["tool_call_id"]?.stringValue,
            timestamp: json["timestamp"]?.numericValue.flatMap(SessionSummary.date),
            hidden: hidden,
            images: images
        )
    }

    /// `content` is a string, or a list of parts on a message that carries pictures.
    static func content(_ value: JSONValue?) -> (String, [String]) {
        switch value {
        case .string(let text):
            return (text, [])
        case .array(let parts):
            var texts: [String] = []
            var images: [String] = []
            for part in parts {
                switch part["type"]?.stringValue {
                case "text", "input_text":
                    if let text = part["text"]?.stringValue { texts.append(text) }
                case "image_url":
                    if let url = part["image_url"]?["url"]?.stringValue { images.append(url) }
                default:
                    break
                }
            }
            return (texts.joined(separator: "\n"), images)
        default:
            return ("", [])
        }
    }

    /// Tool arguments arrive as a JSON string, or as an object on some rows.
    static func arguments(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        guard let data = try? value.encoded(), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Reads `GET /api/sessions/{id}/messages`.
    public static func page(_ json: JSONValue) -> [StoredMessage] {
        json["messages"]?.arrayValue?.compactMap(StoredMessage.init) ?? []
    }
}

extension JSONValue {
    /// A flag the dashboard writes as `true`, `"1"` or `1`: SQLite keeps some of them as numbers.
    var flag: Bool {
        if let value = boolValue { return value }
        switch self {
        case .number(let value): return value != 0
        case .string(let text): return text == "true" || text == "1"
        default: return false
        }
    }
}
