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
            /// A table: [rows] holds the header first, then one array per row.
            case table
        }

        public let kind: Kind
        public let text: String
        /// For a table: the header row and the rows under it. Empty for every other kind.
        public let rows: [[String]]
        /// For a table: where each column's text sits, from the `:---:` markers.
        public let alignments: [Alignment]

        public enum Alignment: Equatable {
            case leading, center, trailing
        }

        public init(kind: Kind, text: String, rows: [[String]] = [], alignments: [Alignment] = []) {
            self.kind = kind
            self.text = text
            self.rows = rows
            self.alignments = alignments
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

            // A table: a row of cells, a line of dashes under it, then the rows.
            if trimmed.contains("|"), let separator = tableSeparator(lines, after: index) {
                flushParagraph()
                let header = cells(of: trimmed)
                let alignments = separator
                var rows = [header]
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.contains("|"), !candidate.isEmpty else { break }
                    rows.append(cells(of: candidate))
                    index += 1
                }
                let width = rows.map(\.count).max() ?? 0
                let squared = rows.map { row in row + Array(repeating: "", count: max(0, width - row.count)) }
                blocks.append(Block(
                    kind: .table,
                    text: squared.map { $0.joined(separator: " | ") }.joined(separator: "\n"),
                    rows: squared,
                    alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count))
                ))
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

    /// The cells of a table row, without the pipes that hold it.
    public static func cells(of line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The alignment markers of the line under a header, when that line is one.
    public static func tableSeparator(_ lines: [String], after index: Int) -> [Block.Alignment]? {
        guard index + 1 < lines.count else { return nil }
        let cells = cells(of: lines[index + 1])
        guard !cells.isEmpty else { return nil }
        var alignments: [Block.Alignment] = []
        for cell in cells {
            let dashes = cell.filter { $0 == "-" }.count
            guard dashes >= 1, cell.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments
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

        case .table:
            TableView(rows: block.rows, alignments: block.alignments)
        }
    }
}

/// A Markdown table as the agent writes them: a header, a rule, and the numbers under it. Numbers
/// line up on the right by themselves when the whole column is one.
struct TableView: View {
    let rows: [[String]]
    let alignments: [Markdown.Block.Alignment]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        Text(Markdown.inline(cell))
                            .font(index == 0 ? .system(size: 13, weight: .semibold) : Theme.Fonts.answer)
                            .foregroundStyle(index == 0 ? .primary : .primary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridColumnAlignment(alignment(column: column))
                    }
                }
                if index == 0 {
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.Palette.inlineCode, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Numbers on the right, words on the left, `:---:` in the middle.
    private func alignment(column: Int) -> HorizontalAlignment {
        let declared = alignments.indices.contains(column) ? alignments[column] : .leading
        if declared != .leading {
            return declared == .center ? .center : .trailing
        }
        let columnCells = rows.dropFirst().compactMap { row in row.indices.contains(column) ? row[column] : nil }
        guard !columnCells.isEmpty else { return .leading }
        let numeric = columnCells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            return Double(trimmed.replacingOccurrences(of: ",", with: ".")) != nil
        }
        return numeric ? .trailing : .leading
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
