import HermesCore
import HermesUI
import SwiftUI

/// The chats on the left, the one that is open on the right.
struct ChatScreen: View {
    @State private var model: ChatModel
    @State private var selection: SessionSummary.ID?

    init(session: DashboardSession, gateway: GatewaySession) {
        _model = State(initialValue: ChatModel(session: session, gateway: gateway))
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SearchField(text: Binding(get: { model.query }, set: { model.query = $0 }))
                if model.isSearching {
                    searchResults
                } else {
                    sessions
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
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

    private var sessions: some View {
        SessionListView(sessions: model.sessions, selection: $selection)
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
    }

    @ViewBuilder
    private var searchResults: some View {
        switch model.searchState {
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(10)
        case .loading where model.hits.isEmpty:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 20)
        case .ready, .loading:
            if model.hits.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "magnifyingglass", description: Text("No chat holds that."))
            } else {
                SearchResultsView(hits: model.hits, query: model.query, selection: Binding(
                    get: { selection },
                    set: { id in
                        guard let id else { return }
                        selection = id
                        Task { await model.openSearchResult(id) }
                    }
                ))
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
                VStack(spacing: 0) {
                    if let question = model.question {
                        QuestionCard(
                            question: question,
                            onChoice: { choice in Task { await model.answer(choice) } },
                            onClarify: { answers in Task { await model.answerClarify(answers) } },
                            onCancel: { Task { await model.dismissQuestion() } },
                            onSecret: { value in Task { await model.answerSecret(value) } }
                        )
                    }
                    TranscriptView(
                        items: model.items,
                        loadFile: { path in try await model.fileData(path) },
                        openFile: { path in model.openFile(path) }
                    )
                    ComposerView(
                        text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                        isRunning: model.running,
                        drafts: model.drafts,
                        onAttach: pickFile,
                        onRemove: { model.removeDraft($0) },
                        onSend: { Task { await model.send() } },
                        onStop: { Task { await model.stop() } }
                    )
                }
            }
        }
    }

    /// The system picker: the person chooses the file, the app reads it.
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Attach a file or a picture to the message"
        if panel.runModal() == .OK, let url = panel.url {
            model.addFile(url)
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
