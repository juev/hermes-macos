import HermesCore
import HermesUI
import SwiftUI

/// What the window shows between the launch and the chats: the list it read last time on the left,
/// and the work of opening the dashboard on the right. Not the address form — that is for a Mac that
/// has none, and asking a question the app can answer itself is how a launch feels slow.
struct RestoringView: View {
    let address: String

    private var cached: [Sidebar.Section] {
        guard let json = ChatCache.standard().read(ChatCache.sessionsName(server: address)) else { return [] }
        return Sidebar.sections(SessionPage(json).sessions)
    }

    var body: some View {
        NavigationSplitView {
            let sections = cached
            VStack(alignment: .leading, spacing: 0) {
                SearchFieldChrome(text: "")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Divider()
                if sections.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                Text(Sidebar.title(for: section.group))
                                    .font(Theme.Fonts.sectionLabel)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 12)
                                    .padding(.bottom, 2)
                                ForEach(section.chats) { chat in
                                    SessionRow(session: chat)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Opening your chats")
                    .font(.system(size: 14, weight: .medium))
                Text(address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
