import Foundation

/// A file the user attached or the agent delivered: a path on the server, shown as a chip.
public struct Attachment: Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let isImage: Bool

    public init(path: String, name: String, isImage: Bool) {
        self.path = path
        self.name = name
        self.isImage = isImage
    }

    public var id: String { path }
}

/// What the dashboard writes into the text of a message, and what a bubble must not show: the
/// attached context it appended, the `@file:` and `@image:` lines it keeps, the `MEDIA:` directives,
/// and the placeholders a person never typed.
public enum TextParsing {
    // A compiled regex is immutable and matching is thread-safe, but `Regex` is not marked
    // Sendable, so the constants say so themselves instead of being rebuilt for every message.
    nonisolated(unsafe) static let attachmentLine = #/@(image|file):(.+)/#
    nonisolated(unsafe) static let mediaLine = #/(?m)^[\t ]*[`"']?MEDIA:\s*[`"']?([^`"'\n]+?)[`"']?[\t ]*$/#
    nonisolated(unsafe) static let mediaInline = #/[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|[^\s`"]+)/#
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "svg"]
    static let imagePlaceholders: Set<String> = ["[screenshot]", "[image]"]
    static let contextSections = ["\n\n--- Context Warnings ---", "\n\n--- Attached Context ---"]
    static let contextKeys = ["command", "query", "url", "path", "file_path", "pattern", "name", "action", "goal", "task", "question"]

    /// Splits a stored user message into what the person wrote and the files it points at. The
    /// dashboard appends the content of the files after `--- Attached Context ---`, which a bubble
    /// does not show; the `@image:` and `@file:` lines become attachments.
    public static func splitUserText(_ text: String) -> (text: String, attachments: [Attachment]) {
        let cuts = contextSections.compactMap { marker in
            text.range(of: marker).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        }
        let cut = cuts.min()
        let written = cut.map { String(text.prefix($0)) } ?? text
        // Pictures sent to the model are named by `@image:` lines the dashboard appends after the context.
        let appended: [String] = cut.map { at in
            String(text.dropFirst(at)).components(separatedBy: .newlines).filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("@image:")
            }
        } ?? []

        var attachments: [Attachment] = []
        var kept: [String] = []
        for line in written.components(separatedBy: .newlines) + appended {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if imagePlaceholders.contains(trimmed) { continue }
            if let match = trimmed.wholeMatch(of: attachmentLine) {
                let path = String(match.2).trimmingCharacters(in: .whitespaces)
                let name = path.split(separator: "/").last.map(String.init) ?? path
                let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
                attachments.append(Attachment(
                    path: path,
                    name: name,
                    isImage: String(match.1) == "image" || imageExtensions.contains(ext)
                ))
                continue
            }
            kept.append(line)
        }

        var seen = Set<String>()
        let unique = attachments.filter { seen.insert($0.path).inserted }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), unique)
    }

    /// Paths the agent delivered with `MEDIA:` directives, in order and without repeats.
    public static func mediaPaths(in text: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for match in text.matches(of: mediaInline) {
            var value = String(match.1).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)\"'"))
            // A bare word is not a file: it needs a directory or an extension.
            guard value.contains("/") || value.range(of: #"\.[^.]"#, options: .regularExpression) != nil else { continue }
            if seen.insert(value).inserted { paths.append(value) }
        }
        return paths
    }

    /// The answer with its `MEDIA:` lines gone; the files are drawn as cards under it.
    public static func stripMedia(_ text: String) -> String {
        text.replacing(mediaLine, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The one-line hint of what a tool call did, taken from its JSON arguments: the command, the
    /// query, the URL — whichever the tool names first.
    public static func argumentContext(_ arguments: String) -> String {
        guard let value = try? JSONValue.decode(arguments), let object = value.objectValue else { return "" }
        for key in contextKeys {
            guard let text = object[key]?.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let firstLine = text.components(separatedBy: .newlines).first ?? ""
            return String(firstLine.prefix(80))
        }
        return ""
    }
}
