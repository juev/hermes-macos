import SwiftUI

/// The answer as the agent wrote it: a few block kinds and inline markup, rendered rather than shown
/// as its own source.
///
/// The dashboard's answers are Markdown, but a chat bubble needs less than a document: paragraphs,
/// lists, fenced code, a heading now and then, and inline bold, italic, code and links. That is what
/// this reads, and anything it does not know stays as the text it was.
public enum Markdown {
    public struct Block: Equatable {
        public enum Kind: Equatable {
            case paragraph
            case heading(level: Int)
            case code(language: String?)
            case listItem(ordered: Bool, index: Int)
            case quote
            case rule
        }

        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Splits an answer into the blocks a bubble draws.
    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(Block(kind: .paragraph, text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1  // The closing fence, or the end.
                blocks.append(Block(kind: .code(language: language.isEmpty ? nil : language), text: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(kind: .heading(level: level), text: text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(Block(kind: .rule, text: ""))
                index += 1
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(Block(kind: .quote, text: String(trimmed.dropFirst(2))))
                index += 1
                continue
            }

            if let item = listItem(trimmed) {
                flushParagraph()
                blocks.append(Block(kind: .listItem(ordered: item.ordered, index: item.index), text: item.text))
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// Bold, italic, inline code and links; the block structure is the caller's business.
    public static func inline(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(text)
        }
        let codeRuns = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRuns {
            attributed[range].font = Theme.Fonts.inlineCode
            attributed[range].backgroundColor = Theme.Palette.inlineCode
        }
        return attributed
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        return stripped.count >= 3 && (stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" })
    }

    private static func listItem(_ line: String) -> (ordered: Bool, index: Int, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (false, 0, String(line.dropFirst(marker.count)))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits), digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (true, number, String(rest.dropFirst(2)))
    }
}

/// An answer drawn from its Markdown: paragraphs, lists, code and quotes, with the reading type of
/// the chat applied to each.
public struct MarkdownText: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        let blocks = Markdown.blocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(grouped(blocks).enumerated()), id: \.offset) { _, group in
                switch group {
                case .single(let block):
                    blockView(block)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            listRow(item)
                        }
                    }
                }
            }
        }
    }

    private enum Group {
        case single(Markdown.Block)
        case list([Markdown.Block])
    }

    /// Consecutive list items become one list, so their markers line up in a column.
    private func grouped(_ blocks: [Markdown.Block]) -> [Group] {
        var groups: [Group] = []
        var run: [Markdown.Block] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            groups.append(.list(run))
            run.removeAll()
        }
        for block in blocks {
            if case .listItem = block.kind {
                run.append(block)
            } else {
                flushRun()
                groups.append(.single(block))
            }
        }
        flushRun()
        return groups
    }

    @ViewBuilder
    private func listRow(_ block: Markdown.Block) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if case .listItem(let ordered, let index) = block.kind {
                Text(ordered ? "\(index)." : "•")
                    .font(Theme.Fonts.answer)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: ordered ? 18 : 8, alignment: .trailing)
            }
            Text(Markdown.inline(block.text))
                .font(Theme.Fonts.answer)
                .lineSpacing(Theme.Metrics.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func blockView(_ block: Markdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            Text(Markdown.inline(block.text))
                .font(Theme.Fonts.answer)
                .lineSpacing(Theme.Metrics.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level):
            Text(Markdown.inline(block.text))
                .font(.system(size: level <= 2 ? 15.5 : 14.5, weight: .semibold))
                .textSelection(.enabled)
                .padding(.top, 2)

        case .code(let language):
            CodeBlockView(code: block.text, language: language)

        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.Palette.reasoningRule)
                    .frame(width: 3)
                Text(Markdown.inline(block.text))
                    .font(Theme.Fonts.answer)
                    .foregroundStyle(Theme.Palette.accentText)
                    .lineSpacing(Theme.Metrics.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Divider().padding(.vertical, 2)

        case .listItem:
            listRow(block)
        }
    }
}

/// A fenced block: monospaced on its own surface. It wraps rather than scrolls sideways, so a
/// snapshot and a printed page show it whole; selecting it still gives the lines as they were.
struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(Theme.Fonts.sessionMeta)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            Text(code)
                .font(Theme.Fonts.codeBlock)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
