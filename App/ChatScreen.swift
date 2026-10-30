import HermesCore
import HermesUI
import SwiftUI

/// The chats on the left, the one that is open on the right.
struct ChatScreen: View {
    @State private var model: ChatModel
    @State private var selection: SessionSummary.ID?

    init(session: DashboardSession) {
        _model = State(initialValue: ChatModel(session: session))
    }

    var body: some View {
        NavigationSplitView {
            SessionListView(sessions: model.sessions, selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
                .overlay {
                    if case .loading = model.sessionsState, model.sessions.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay(alignment: .bottom) {
                    if case .failed(let message) = model.sessionsState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
        } detail: {
            detail
        }
        .task { await model.load() }
        .onChange(of: selection) { _, id in
            guard let id, id != model.selection else { return }
            Task { await model.open(id) }
        }
        .onChange(of: model.selection) { _, id in
            if selection != id { selection = id }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let selected = model.selected {
                    VStack(alignment: .leading) {
                        Text(selected.label)
                            .font(.headline)
                            .lineLimit(1)
                        Text(subtitle(for: selected))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.transcriptState {
        case .loading:
            ProgressView("Loading the chat…")
                .controlSize(.small)
        case .failed(let message):
            ContentUnavailableView("The chat could not be read", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            if model.items.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "bubble.left", description: Text("This chat has no stored messages."))
            } else {
                TranscriptView(items: model.items)
            }
        }
    }

    private func subtitle(for session: SessionSummary) -> String {
        var parts: [String] = []
        if let model = session.model { parts.append(model) }
        if !session.source.isEmpty { parts.append(session.source) }
        if session.messageCount > 0 { parts.append("\(session.messageCount) messages") }
        return parts.joined(separator: " · ")
    }
}
