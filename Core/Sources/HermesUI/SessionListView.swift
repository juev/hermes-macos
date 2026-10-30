import HermesCore
import SwiftUI

/// The chats of the dashboard, newest activity first.
public struct SessionListView: View {
    public let sessions: [SessionSummary]
    @Binding public var selection: SessionSummary.ID?
    public let onRename: ((SessionSummary) -> Void)?
    public let onArchive: ((SessionSummary, Bool) -> Void)?
    public let onDelete: ((SessionSummary) -> Void)?

    public init(
        sessions: [SessionSummary],
        selection: Binding<SessionSummary.ID?>,
        onRename: ((SessionSummary) -> Void)? = nil,
        onArchive: ((SessionSummary, Bool) -> Void)? = nil,
        onDelete: ((SessionSummary) -> Void)? = nil
    ) {
        self.sessions = sessions
        _selection = selection
        self.onRename = onRename
        self.onArchive = onArchive
        self.onDelete = onDelete
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
            ForEach(sessions) { session in
                SessionRow(session: session)
                    .tag(session.id)
                    .contextMenu {
                        Button("Rename…") { onRename?(session) }
                        Button(session.archived ? "Unarchive" : "Archive") { onArchive?(session, !session.archived) }
                        Divider()
                        Button("Delete…", role: .destructive) { onDelete?(session) }
                    }
            }
        }
        .listStyle(.sidebar)
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
