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
                    ForEach(section.chats) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button(session.pinned ? "Unpin" : "Pin") { onPin?(session, !session.pinned) }
                                Button("Rename…") { onRename?(session) }
                                Button(session.archived ? "Unarchive" : "Archive") { onArchive?(session, !session.archived) }
                                Divider()
                                Button("Delete…", role: .destructive) { onDelete?(session) }
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
}

/// One chat in the list: what it is called, where it came from, when it last moved.
public struct SessionRow: View {
    public let session: SessionSummary

    public init(session: SessionSummary) {
        self.session = session
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
                    Text(PlainText.of(session.label))
                        .font(Theme.Fonts.sessionTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if session.unread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                    Spacer(minLength: 4)
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
