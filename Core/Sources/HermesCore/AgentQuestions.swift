import Foundation

/// A question the agent asks in the middle of a turn and cannot go on without: the approval of a
/// command, a choice it needs, a secret it cannot read for itself.
public enum AgentQuestion: Sendable, Equatable, Identifiable {
    case approval(Approval)
    case clarify(Clarify)
    case secret(Secret)

    /// The id of the request, the one the answer must carry back.
    public var id: String {
        switch self {
        case .approval(let approval): approval.id
        case .clarify(let clarify): clarify.id
        case .secret(let secret): secret.id
        }
    }

    /// Reads a request of the gateway; nil for one this client does not answer — a desktop-only
    /// question, which has to be refused so the agent does not wait for it.
    public init?(_ request: ServerRequest) {
        switch request.method {
        case "approval":
            self = .approval(Approval(request))
        case "clarify":
            self = .clarify(Clarify(request))
        case "sudo":
            self = .secret(Secret(request, isSudo: true))
        case "secret":
            self = .secret(Secret(request, isSudo: false))
        default:
            return nil
        }
    }
}

/// An approval of a shell command or of a tool call the dashboard stops before running.
public struct Approval: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A command the dashboard flagged as dangerous, and anything of unknown origin.
        case command
        /// A plugin rule holds a call of a tool until a person allows it.
        case tool(String)
        /// An MCP server confirms one action; the dashboard takes only yes or no.
        case mcp
    }

    public let id: String
    public let kind: Kind
    /// What is about to run. Empty for a plugin rule, whose command is the dashboard's label for an
    /// allowlist and not something to read.
    public let command: String
    /// Why it is asked: the rule's reason, the MCP server's question, or the tool's name.
    public let description: String
    /// What the dashboard offers: usually `once` and `deny`.
    public let choices: [String]

    /// The words of the dashboard for a choice.
    public static let labels: [String: String] = [
        "once": "Allow once",
        "always": "Always allow",
        "session": "Allow for this chat",
        "deny": "Deny"
    ]

    public init(id: String, kind: Kind, command: String, description: String, choices: [String]) {
        self.id = id
        self.kind = kind
        self.command = command
        self.description = description
        self.choices = choices
    }

    init(_ request: ServerRequest) {
        let params = request.params
        let rawCommand = params["command"]?.stringValue ?? ""
        let patternKey = params["pattern_key"]?.stringValue ?? ""
        let toolName = params["tool_name"]?.stringValue

        let kind: Kind
        if patternKey == "mcp_elicitation" {
            kind = .mcp
        } else if patternKey.hasPrefix("plugin_rule:") {
            kind = .tool(Self.toolName(command: rawCommand, toolName: toolName, patternKey: patternKey))
        } else {
            kind = .command
        }

        let offered = params["choices"]?.stringArray ?? ["once", "deny"]
        self.init(
            id: request.id,
            kind: kind,
            command: kind == .command ? rawCommand : "",
            description: params["description"]?.stringValue ?? toolName ?? "",
            // Every MCP answer but a denial is the same yes; a choice for the chat or for always
            // would promise what the dashboard does not keep.
            choices: kind == .mcp ? ["once", "deny"] : offered
        )
    }

    /// A plugin rule writes its tool as `<name> (plugin approval rule)`.
    static func toolName(command: String, toolName: String?, patternKey: String) -> String {
        if let toolName, !toolName.isEmpty { return toolName }
        if let open = command.firstIndex(of: "<"), let close = command.firstIndex(of: ">"), open < close {
            return String(command[command.index(after: open)..<close])
        }
        return patternKey.replacingOccurrences(of: "plugin_rule:", with: "")
    }

    /// What a card or a banner says: the question, then the reason.
    public var summary: String {
        [command, description].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public var title: String {
        switch kind {
        case .command: "Approve a command"
        case .tool(let name): "Allow \(name)"
        case .mcp: "The server asks"
        }
    }
}

/// Questions the agent needs a person to answer, with or without offered choices.
public struct Clarify: Sendable, Equatable, Identifiable {
    public struct Question: Sendable, Equatable, Identifiable {
        public let id: String
        public let text: String
        public let choices: [String]
    }

    public let id: String
    public let questions: [Question]

    init(_ request: ServerRequest) {
        id = request.id
        questions = request.params["questions"]?.arrayValue?.compactMap { question in
            guard let qid = question["qid"]?.stringValue else { return nil }
            return Question(
                id: qid,
                text: question["question"]?.stringValue ?? "",
                choices: question["choices"]?.stringArray ?? []
            )
        } ?? []
    }
}

/// A secret or a password the agent cannot read for itself.
public struct Secret: Sendable, Equatable, Identifiable {
    public let id: String
    public let prompt: String
    public let isSudo: Bool

    init(_ request: ServerRequest, isSudo: Bool) {
        id = request.id
        self.isSudo = isSudo
        prompt = request.params["prompt"]?.stringValue
            ?? (isSudo
                ? "Sudo password for \(request.params["command"]?.stringValue ?? "the command")"
                : "Value for \(request.params["env_var"]?.stringValue ?? "the secret")")
    }
}

/// The answers the dashboard takes back through `respond`, in the shapes it reads.
public enum AgentAnswer {
    public static func approval(_ choice: String) -> JSONValue {
        ["choice": .string(choice)]
    }

    public static func clarify(_ answers: [String: String?]) -> JSONValue {
        ["answers": .object(answers.mapValues { $0.map { JSONValue.string($0) } ?? .null }), "outcome": "submitted"]
    }

    public static let clarifyCancelled: JSONValue = ["outcome": "cancelled"]

    public static func secret(_ value: String) -> JSONValue {
        ["value": .string(value)]
    }
}
