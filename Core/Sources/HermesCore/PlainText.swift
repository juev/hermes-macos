import Foundation

/// Markdown as the words alone, for the places that cannot render it: a notification, a list row.
/// The words stay and the syntax goes — emphasis, headings, quotes, link targets, fences and table
/// borders; a list item keeps a bullet so the list still reads as one.
///
/// The rules are the Android client's (`chat/PlainText.kt`), and they are applied with
/// `NSRegularExpression` because two of them need a backreference and two a lookbehind, which Swift's
/// own `Regex` does not have.
public enum PlainText {
    // Compiled once at first use and immutable afterwards; `NSRegularExpression` says it is safe to
    // share, so these need no ceremony.
    private static let fence = pattern(#"(?m)^[\t ]*(```|~~~).*$\n?"#)
    private static let rule = pattern(#"(?m)^[\t ]*([-*_])([\t ]*\1){2,}[\t ]*$"#)
    private static let tableDivider = pattern(#"(?m)^[\t ]*\|?[\t ]*:?-+:?[\t ]*(\|[\t ]*:?-+:?[\t ]*)+\|?[\t ]*$\n?"#)
    private static let tableRow = pattern(#"^[\t ]*\|(.*?)\|?[\t ]*$"#)
    private static let tableCells = pattern(#"[\t ]*\|[\t ]*"#)
    private static let heading = pattern(#"(?m)^[\t ]*#{1,6}[\t ]+(.*?)[\t ]*#*[\t ]*$"#)
    private static let quote = pattern(#"(?m)^[\t ]*>[\t ]?"#)
    private static let task = pattern(#"(?m)^([\t ]*)[-*+][\t ]+\[[ xX]][\t ]+"#)
    private static let bullet = pattern(#"(?m)^([\t ]*)[-*+][\t ]+"#)
    private static let image = pattern(#"!\[([^\]]*)]\([^)]*\)"#)
    private static let link = pattern(#"\[([^\]]+)]\([^)]*\)"#)
    private static let code = pattern(#"`([^`\n]+)`"#)
    private static let strong = pattern(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let strike = pattern(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let emphasisStar = pattern(#"(?<![*\w])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![*\w])"#)
    private static let emphasisUnderscore = pattern(#"(?<![_\w])_(?=\S)([^_\n]+?)(?<=\S)_(?![_\w])"#)
    private static let blankLines = pattern(#"\n{3,}"#)

    public static func of(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        text = replace(fence, in: text, with: "")
        text = replace(tableDivider, in: text, with: "")
        text = replace(rule, in: text, with: "")
        text = table(in: text)
        text = replace(heading, in: text, with: "$1")
        text = replace(quote, in: text, with: "")
        text = replace(task, in: text, with: "$1• ")
        text = replace(bullet, in: text, with: "$1• ")
        text = replace(image, in: text, with: "$1")
        text = replace(link, in: text, with: "$1")
        text = replace(code, in: text, with: "$1")
        text = replace(strong, in: text, with: "$2")
        text = replace(strike, in: text, with: "$1")
        text = replace(emphasisStar, in: text, with: "$1")
        text = replace(emphasisUnderscore, in: text, with: "$1")
        text = replace(blankLines, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A table row keeps its cells, separated by the middle dot the app uses elsewhere.
    private static func table(in text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = tableRow.firstMatch(in: line, range: range), match.numberOfRanges > 1,
                  let cells = Range(match.range(at: 1), in: line) else { return line }
            return replace(tableCells, in: String(line[cells]).trimmingCharacters(in: .whitespaces), with: " · ")
        }
        .joined(separator: "\n")
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func pattern(_ source: String) -> NSRegularExpression {
        // Every pattern here is a constant of this file and correct; a failure would be a bug in it.
        try! NSRegularExpression(pattern: source)
    }
}
