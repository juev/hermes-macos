import HermesCore
import SwiftUI

/// The chats of the dashboard, newest activity first.
public struct SessionListView: View {
    public let sections: [Sidebar.Section]
    @Binding public var selection: SessionSummary.ID?
    public let onRename: ((SessionSummary) -> Void)?
    public let onArchive: ((SessionSummary, Bool) -> Void)?
    public let onDelete: ((SessionSummary) -> Void)?
    public let onPin: ((SessionSummary, Bool) -> Void)?
    public let showingArchive: Bool
    public let onToggleArchive: (() -> Void)?

    /// Which folded rows are open, by the id of the run they show. A run that arrives later replaces
    /// the row's id and the row closes again, which is what a fresh run should do.
    @State private var expanded: Set<SessionSummary.ID> = []

    public init(
        sections: [Sidebar.Section],
        selection: Binding<SessionSummary.ID?>,
        onRename: ((SessionSummary) -> Void)? = nil,
        onArchive: ((SessionSummary, Bool) -> Void)? = nil,
        onDelete: ((SessionSummary) -> Void)? = nil,
        onPin: ((SessionSummary, Bool) -> Void)? = nil,
        showingArchive: Bool = false,
        onToggleArchive: (() -> Void)? = nil
    ) {
        self.sections = sections
        _selection = selection
        self.onRename = onRename
        self.onArchive = onArchive
        self.onDelete = onDelete
        self.onPin = onPin
        self.showingArchive = showingArchive
        self.onToggleArchive = onToggleArchive
    }

    /// A sidebar reads ages at a glance: "now", "12 min", "3 h", "4 d", then the date.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3_600)) h"
        case ..<604_800: return "\(Int(seconds / 86_400)) d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        SessionRow(
                            session: row.chat,
                            label: row.folded ? row.label : nil,
                            runCount: row.folded ? row.count : nil,
                            unread: row.unread,
                            expanded: expanded.contains(row.id),
                            onToggleRuns: row.folded ? { toggle(row.id) } : nil
                        )
                        .tag(row.chat.id)
                        .contextMenu { menu(for: row.chat) }
                        if row.folded, expanded.contains(row.id) {
                            ForEach(row.runs) { run in
                                SessionRow(session: run)
                                    .tag(run.id)
                                    .padding(.leading, 14)
                                    .contextMenu { menu(for: run) }
                            }
                        }
                    }
                } header: {
                    Text(Sidebar.title(for: section.group))
                        .font(Theme.Fonts.sectionLabel)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if onToggleArchive != nil {
                Button {
                    onToggleArchive?()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showingArchive ? "tray.full" : "archivebox")
                            .font(.system(size: 10))
                        Text(showingArchive ? "Back to the chats" : "Archive")
                            .font(Theme.Fonts.sessionMeta)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.bar)
            }
        }
    }

    private func toggle(_ id: SessionSummary.ID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    @ViewBuilder
    private func menu(for session: SessionSummary) -> some View {
        Button(session.pinned ? "Unpin" : "Pin") { onPin?(session, !session.pinned) }
        Button("Rename…") { onRename?(session) }
        Button(session.archived ? "Unarchive" : "Archive") { onArchive?(session, !session.archived) }
        Divider()
        Button("Delete…", role: .destructive) { onDelete?(session) }
    }
}

/// One chat in the list: what it is called, where it came from, when it last moved.
///
/// A folded row stands for the runs of one cron job: it is named by the job, says how many runs it
/// holds, and its chevron opens the older runs in the list.
public struct SessionRow: View {
    public let session: SessionSummary
    /// The job's name, for a row that folds several runs; nil for a chat.
    public let label: String?
    /// How many runs a folded row holds, the one it shows included; nil for a chat.
    public let runCount: Int?
    /// The row is unread when any run it folds is unread.
    public let unread: Bool
    public let expanded: Bool
    public let onToggleRuns: (() -> Void)?

    public init(
        session: SessionSummary,
        label: String? = nil,
        runCount: Int? = nil,
        unread: Bool? = nil,
        expanded: Bool = false,
        onToggleRuns: (() -> Void)? = nil
    ) {
        self.session = session
        self.label = label
        self.runCount = runCount
        self.unread = unread ?? session.unread
        self.expanded = expanded
        self.onToggleRuns = onToggleRuns
    }

    private var glyph: String {
        switch session.source {
        case "android": "iphone"
        case "cron": "clock.arrow.circlepath"
        case "matrix": "bubble.left.and.bubble.right"
        case "telegram": "paperplane"
        case "desktop", "web": "macwindow"
        default: "bubble.left"
        }
    }

    /// A sidebar reads ages at a glance: "now", "12 min", "3 h", "4 d", then the date.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3_600)) h"
        case ..<604_800: return "\(Int(seconds / 86_400)) d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(PlainText.of(label ?? session.label))
                        .font(Theme.Fonts.sessionTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if unread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                    Spacer(minLength: 4)
                    if let onToggleRuns, let runCount {
                        Button(action: onToggleRuns) {
                            HStack(spacing: 3) {
                                Text("\(runCount) runs")
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            }
                            .font(Theme.Fonts.sessionMeta)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded ? "Hide earlier runs" : "Show earlier runs")
                    }
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    if session.active {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    if let lastActive = session.lastActive ?? session.startedAt {
                        Text(Self.age(since: lastActive))
                    }
                    if session.messageCount > 0 {
                        Text("·")
                        Text("\(session.messageCount) messages")
                    }
                }
                .font(Theme.Fonts.sessionMeta)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
