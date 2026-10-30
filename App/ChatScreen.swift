import HermesCore
import HermesUI
import SwiftUI

/// The chats on the left, the one that is open on the right.
struct ChatScreen: View {
    @State private var model: ChatModel
    @State private var selection: SessionSummary.ID?
    @State private var showingPush = false
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""
    @State private var deleting: SessionSummary?

    let onDisconnect: () -> Void

    init(session: DashboardSession, gateway: GatewaySession, onDisconnect: @escaping () -> Void = {}) {
        _model = State(initialValue: ChatModel(session: session, gateway: gateway))
        self.onDisconnect = onDisconnect
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
        .sheet(isPresented: $showingPush) {
            PushSettingsView(model: model.push)
        }
        .sheet(item: $renaming) { session in
            RenameChatSheet(title: newTitle) { title in
                renaming = nil
                Task { await model.rename(session, to: title) }
            } onCancel: {
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { session in
            Button("Delete \(session.label.prefix(40))", role: .destructive) {
                deleting = nil
                Task { await model.delete(session) }
            }
            Button("Keep it", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("The chat and its messages are removed from the dashboard. This cannot be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingPush = true
                } label: {
                    Label("Push", systemImage: "bell")
                }
                .help("Push from the dashboard when a turn ends anywhere")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onDisconnect()
                } label: {
                    Label("Change server", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .help("Close this dashboard and go back to the address")
            }
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
        SessionListView(
            sessions: model.sessions,
            selection: $selection,
            onRename: { session in
                newTitle = session.title.isEmpty ? session.label : session.title
                renaming = session
            },
            onArchive: { session, archived in
                Task { await model.archive(session, archived: archived) }
            },
            onDelete: { session in
                deleting = session
            }
        )
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
