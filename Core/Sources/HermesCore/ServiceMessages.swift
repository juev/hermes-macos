import Foundation

/// What a person's message really is, when the dashboard built it rather than the person.
///
/// A cron run files its report as a user row, a skill invocation is a prompt the dashboard wrote
/// around what the person asked, and a chat on Telegram carries what was replied to. Shown as they
/// are, each of them is a wall of text with directions to the agent inside it; read, each is a chip
/// and the words that were actually written.
public enum ServiceMessages {
    static let cronDelivery = "[Cron delivery: "
    static let cronHint = "[IMPORTANT: You are running as a scheduled cron job."
    static let skillInvoked = "[IMPORTANT: The user has invoked the "
    static let skillInstruction = "The user has provided the following instruction alongside the skill invocation: "
    static let runtimeNote = "\n\n[Runtime note:"
    static let bundle = " skill bundle,"
    static let bundleInstruction = "\nUser instruction: "
    static let bundleFirstSkill = "\n\n[Loaded as part of the "
    static let autoLoaded = "[IMPORTANT: The \""
    static let autoLoadedSuffix = "\" skill is auto-loaded."
    static let skillDirNoteEnd = "then run them with the terminal tool using the absolute path."
    static let replyingTo = "[Replying to: \""

    nonisolated(unsafe) static let skillNames = #/(?m)^\[IMPORTANT: The (?:user has invoked the )?"([^"]*)"/#

    /// The job and the report of a cron run the dashboard filed into the chat, or nil.
    public static func cronReport(_ text: String) -> (job: String, report: String)? {
        guard text.hasPrefix(cronDelivery) else { return nil }
        let head = String(text.prefix { $0 != "\n" })
        guard head.hasSuffix("]") else { return nil }
        let job = String(head.dropFirst(cronDelivery.count).dropLast())
        let rest = text.dropFirst(head.count)
        return (job, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The skills or the cron run a message was expanded into, and what the person wrote alongside
    /// them; nil for a message written as it is. A cron run shows no words of its own: its prompt,
    /// the previous report and the notes for the agent are all in the full text.
    public static func invocation(_ text: String) -> (invocation: Invocation, written: String)? {
        let names = text.matches(of: skillNames)
            .flatMap { String($0.1).split(separator: " ") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        let skills = names.reduce(into: [String]()) { list, name in
            if !list.contains(name) { list.append(name) }
        }

        let written: String
        if text.hasPrefix(cronHint) {
            return (Invocation(cron: true, skills: [], full: text), "")
        } else if text.hasPrefix(skillInvoked), String(text.prefix { $0 != "\n" }).contains(bundle) {
            written = between(text, from: text.range(of: bundleInstruction)?.lowerBound, start: bundleInstruction, end: bundleFirstSkill)
        } else if text.hasPrefix(skillInvoked) {
            written = between(text, from: text.range(of: skillInstruction, options: .backwards)?.lowerBound, start: skillInstruction, end: runtimeNote)
        } else if text.hasPrefix(autoLoaded), String(text.prefix { $0 != "\n" }).contains(autoLoadedSuffix) {
            if let range = text.range(of: skillDirNoteEnd, options: .backwards) {
                written = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                written = ""
            }
        } else {
            return nil
        }

        let cron = written.hasPrefix(cronHint)
        return (Invocation(cron: cron, skills: skills, full: text), cron ? "" : written)
    }

    /// Splits `[Replying to: "…"]`, which the dashboard puts before a reply on a chat platform, from
    /// the reply.
    public static func splitQuote(_ text: String) -> (quote: String?, text: String) {
        guard text.hasPrefix(replyingTo) else { return (nil, text) }
        let afterHeader = text.index(text.startIndex, offsetBy: replyingTo.count)
        let rest = text[afterHeader...]
        guard let end = rest.range(of: "\"]\n") ?? (rest.hasSuffix("\"]") ? rest.index(rest.endIndex, offsetBy: -2)..<rest.endIndex : nil) else {
            return (nil, text)
        }
        let quote = String(text[afterHeader..<end.lowerBound])
        let body = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (quote, body)
    }

    /// The text between [start] and [end], from [from]; empty when the marker is not there.
    private static func between(_ text: String, from: String.Index?, start: String, end: String) -> String {
        guard let from else { return "" }
        let begin = text.index(from, offsetBy: start.count)
        let finish = text.range(of: end, range: begin..<text.endIndex)?.lowerBound ?? text.endIndex
        return String(text[begin..<finish]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The skills or cron run a message was expanded into: a chip with their names, and the text the
/// agent got on demand.
public struct Invocation: Sendable, Equatable {
    public let cron: Bool
    public let skills: [String]
    public let full: String

    public init(cron: Bool, skills: [String], full: String) {
        self.cron = cron
        self.skills = skills
        self.full = full
    }
}
