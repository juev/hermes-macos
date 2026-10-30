import HermesCore
import SwiftUI

/// The history of one chat, drawn as turns: the person's messages and the agent's answers.
public struct TranscriptView: View {
    public let items: [ChatItem]
    /// Which chat this is: a different one starts at its end again.
    public let chatID: String?
    public let loadFile: (@MainActor (String) async throws -> Data)?
    public let openFile: (@MainActor (String) -> Void)?
    public let onAskAgain: (@MainActor (UserBubble) -> Void)?

    public init(
        items: [ChatItem],
        chatID: String? = nil,
        loadFile: (@MainActor (String) async throws -> Data)? = nil,
        openFile: (@MainActor (String) -> Void)? = nil,
        onAskAgain: (@MainActor (UserBubble) -> Void)? = nil
    ) {
        self.items = items
        self.chatID = chatID
        self.loadFile = loadFile
        self.openFile = openFile
        self.onAskAgain = onAskAgain
    }

    @State private var followsTheEnd = true

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptContent(items: items, loadFile: loadFile, openFile: openFile, onAskAgain: onAskAgain)
                // A stream of words grows under the fold; this is what the view keeps in sight.
                Color.clear.frame(height: 1).id(Self.bottomID)
            }
            // Every chat opens at its end, and stays there while the wire fills it in: the cached
            // history arrives first and the dashboard's may be longer, so the end is asked for twice.
            .task(id: chatID) {
                followsTheEnd = true
                try? await Task.sleep(for: .milliseconds(30))
                scrollToEnd(proxy, animated: false)
                try? await Task.sleep(for: .milliseconds(150))
                // Unconditional: the measurement of a stack that has just changed can report the top
                // as the end for a moment, and a chat that opens in the middle is what that costs.
                scrollToEnd(proxy, animated: false)
            }
            .onChange(of: items) { _, _ in
                if followsTheEnd { scrollToEnd(proxy, animated: true) }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, atEnd in
                followsTheEnd = atEnd
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsTheEnd {
                    Button {
                        scrollToEnd(proxy, animated: true)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(Theme.Fonts.sessionMeta)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .padding(.trailing, Theme.Metrics.contentPadding)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private static let bottomID = "transcript-bottom"

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.snappy(duration: 0.2)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
        followsTheEnd = true
    }
}

/// The turns themselves, without the scroll view around them: what a snapshot can draw.
public struct TranscriptContent: View {
    public let items: [ChatItem]
    /// Which chat this is: a different one starts at its end again.
    public let chatID: String?
    public let loadFile: (@MainActor (String) async throws -> Data)?
    public let openFile: (@MainActor (String) -> Void)?
    public let onAskAgain: (@MainActor (UserBubble) -> Void)?

    public init(
        items: [ChatItem],
        chatID: String? = nil,
        loadFile: (@MainActor (String) async throws -> Data)? = nil,
        openFile: (@MainActor (String) -> Void)? = nil,
        onAskAgain: (@MainActor (UserBubble) -> Void)? = nil
    ) {
        self.items = items
        self.chatID = chatID
        self.loadFile = loadFile
        self.openFile = openFile
        self.onAskAgain = onAskAgain
    }

    public var body: some View {
        stack(TranscriptDays.group(items))
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.vertical, 24)
            .frame(maxWidth: Theme.Metrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    /// A chat of a few hundred messages is drawn whole: a lazy stack that is culled while the view is
    /// still measuring is what left a chat blank until the person scrolled it. Only a transcript too
    /// long to draw at once is lazy, and then it has been measured before the culling matters.
    @ViewBuilder
    private func stack(_ entries: [TranscriptDays.Entry]) -> some View {
        let rows = ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                if let day = entry.day {
                    DaySeparator(day: day)
                }
                switch entry.item {
                case .user(let bubble):
                    MessageView(bubble: bubble, onAskAgain: onAskAgain)
                case .assistant(let turn):
                    AnswerView(turn: turn, loadFile: loadFile, openFile: openFile)
                case .cronReport(let report):
                    CronReportView(report: report)
                }
        }
        if items.count > 400 {
            LazyVStack(alignment: .leading, spacing: Theme.Metrics.turnSpacing) { rows }
        } else {
            VStack(alignment: .leading, spacing: Theme.Metrics.turnSpacing) { rows }
        }
    }
}

/// The line that opens a day: the date in the middle of two rules, quiet enough to skip.
struct DaySeparator: View {
    let day: Date

    var body: some View {
        HStack(spacing: 10) {
            rule
            Text(TranscriptDays.label(for: day))
                .font(Theme.Fonts.sessionMeta)
                .foregroundStyle(.tertiary)
                .fixedSize()
            rule
        }
        .padding(.vertical, 2)
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.Palette.reasoningRule)
            .frame(height: 1)
            .opacity(0.5)
    }
}

/// The skills or the cron run the dashboard expanded a message into: their names, and the text the
/// agent got on demand.
struct InvocationChip: View {
    let invocation: Invocation
    @State private var expanded = false

    private var label: String {
        if invocation.cron { return "Cron run" }
        if invocation.skills.isEmpty { return "Skill" }
        return invocation.skills.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: invocation.cron ? "clock.arrow.circlepath" : "wand.and.stars")
                        .font(.system(size: 9))
                    Text(label)
                        .font(Theme.Fonts.sessionMeta)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.Palette.toolBackground, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("What the agent was told")

            if expanded {
                ScrollView {
                    Text(invocation.full)
                        .font(Theme.Fonts.toolOutput)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(9)
                .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

/// The report of a cron job: the job's name, then the report as the agent wrote it.
struct CronReportView: View {
    let report: CronReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Cron · \(report.job)")
                    .font(Theme.Fonts.sessionMeta)
                    .foregroundStyle(.secondary)
            }
            MarkdownText(report.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// What the person wrote: a bubble on the right, as far from the answer as the turn spacing.
struct MessageView: View {
    let bubble: UserBubble
    var onAskAgain: (@MainActor (UserBubble) -> Void)?

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 8) {
                if let quote = bubble.quote, !quote.isEmpty {
                    Text(quote)
                        .font(Theme.Fonts.reasoning)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.Palette.reasoningRule).frame(width: 2)
                        }
                }
                if let invocation = bubble.invocation {
                    InvocationChip(invocation: invocation)
                }
                if !bubble.text.isEmpty {
                    Text(bubble.text)
                        .font(Theme.Fonts.message)
                        .lineSpacing(Theme.Metrics.lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !bubble.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(bubble.attachments) { attachment in
                            AttachmentChip(attachment: attachment)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.Palette.messageBackground, in: RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius, style: .continuous))
            .contextMenu {
                Button("Copy") { Clipboard.copy(bubble.text) }
                if let quote = bubble.quote { Button("Copy what it answers") { Clipboard.copy(quote) } }
                if let onAskAgain { Button("Ask again") { onAskAgain(bubble) } }
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(attachment.name)
                .font(Theme.Fonts.toolContext)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
    }
}

/// One answer: its reasoning, its words and the tools it ran, in the order it produced them.
struct AnswerView: View {
    let turn: AssistantTurn
    let loadFile: (@MainActor (String) async throws -> Data)?
    let openFile: (@MainActor (String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.partSpacing) {
            ForEach(Array(TranscriptBlocking.blocks(of: turn.parts).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    // The directive is a card under the answer, not a line of it.
                    MarkdownText(TextParsing.stripMedia(text))
                case .work(let parts):
                    // Everything the answer did on its way — thinking, commands, tool runs — is one
                    // line until asked for: the answer is what the person came to read.
                    WorkGroupView(parts: parts)
                }
            }
            if !turn.deliveredFiles.isEmpty {
                DeliveredFilesView(paths: turn.deliveredFiles, load: loadFile, open: openFile)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy the answer") { Clipboard.copy(turn.text) }
            if let reasoning = turn.reasoning { Button("Copy the reasoning") { Clipboard.copy(reasoning) } }
        }
    }

}

/// One line for everything a turn did on the way: how many calls, which of them, and whether it also
/// thought out loud. Opening it gives the runs and the reasoning back, each as it was.
struct WorkGroupView: View {
    let parts: [Part]
    @State private var expanded = false

    private var runs: [ToolRun] {
        parts.compactMap { part in
            if case .tool(let run) = part { return run }
            return nil
        }
    }

    private var hasReasoning: Bool {
        parts.contains { part in
            if case .reasoning = part { return true }
            return false
        }
    }

    private var summary: String {
        var pieces: [String] = []
        if !runs.isEmpty {
            let names = runs.prefix(3).map(\.name).joined(separator: ", ")
            let more = runs.count > 3 ? " +" + String(runs.count - 3) : ""
            pieces.append("\(runs.count) tool run\(runs.count == 1 ? "" : "s") · \(names)\(more)")
        }
        if hasReasoning { pieces.append("reasoning") }
        return pieces.joined(separator: " · ")
    }

    private var unfinished: Bool {
        runs.contains { !$0.done }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    if unfinished {
                        ProgressView().controlSize(.mini)
                    }
                    Text(summary)
                        .font(Theme.Fonts.reasoningLabel)
                        .foregroundStyle(Theme.Palette.accentText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .reasoning(let text):
                        ReasoningView(text: text)
                    case .tool(let run):
                        ToolRunView(run: run)
                    case .text:
                        EmptyView()
                    }
                }
                .padding(.leading, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the model thought before it answered: a folded line that opens on a click, never louder
/// than the answer itself.
struct ReasoningView: View {
    let text: String
    @State private var expanded = false

    private var lines: Int {
        text.components(separatedBy: .newlines).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Reasoning")
                        .font(Theme.Fonts.reasoningLabel)
                        .foregroundStyle(Theme.Palette.accentText)
                    if !expanded {
                        Text("\(lines) line\(lines == 1 ? "" : "s")")
                            .font(Theme.Fonts.sessionMeta)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(Theme.Fonts.reasoning)
                    .lineSpacing(2)
                    .foregroundStyle(Theme.Palette.accentText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.Palette.reasoningRule)
                            .frame(width: 2)
                    }
            }
        }
    }
}

/// A tool the agent ran: one line while folded — its name and what it acted on — and its output
/// under it once opened.
struct ToolRunView: View {
    let run: ToolRun
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(run.name)
                        .font(Theme.Fonts.toolName)
                    if !run.context.isEmpty {
                        Text(run.context)
                            .font(Theme.Fonts.toolContext)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let summary = run.summary, !summary.isEmpty, !expanded {
                        Text(summary)
                            .font(Theme.Fonts.sessionMeta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 240, alignment: .trailing)
                    }
                    if let duration = run.durationSeconds {
                        Text(String(format: "%.1fs", duration))
                            .font(Theme.Fonts.sessionMeta)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the output" : "Show the output")

            if expanded {
                if let output = run.output, !output.isEmpty {
                    ScrollView(.vertical) {
                        Text(output)
                            .font(Theme.Fonts.toolOutput)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Theme.Metrics.toolOutputMaxHeight)
                    .padding(10)
                    .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text(run.done ? "No output." : "Running…")
                        .font(Theme.Fonts.toolContext)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 1)
    }
}
