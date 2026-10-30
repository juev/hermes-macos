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

    let gatewayState: GatewaySession.State
    let onDisconnect: () -> Void

    init(
        session: DashboardSession,
        gateway: GatewaySession,
        hub: ChatHub,
        gatewayState: GatewaySession.State = .ready,
        onDisconnect: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: ChatModel(session: session, gateway: gateway, hub: hub))
        self.gatewayState = gatewayState
        self.onDisconnect = onDisconnect
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // The field keeps its place: whatever is below it changes, it does not.
                SearchField(text: Binding(get: { model.query }, set: { model.query = $0 }))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Divider()
                Group {
                    if model.isSearching {
                        searchResults
                    } else {
                        sessions
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if gatewayState != .ready {
                    ConnectionBanner(state: gatewayState)
                }
                detail
            }
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
                    Task { await model.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Read the chats and the open one again (⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.newChat() }
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Start a chat (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                modelMenu
            }
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
        }
    }

    private var sessions: some View {
        SessionListView(
            sections: model.sections,
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
            },
            onPin: { session, pinned in
                model.pin(session, pinned: pinned)
            },
            showingArchive: model.showingArchive,
            onToggleArchive: { Task { await model.toggleArchive() } }
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
                SearchResultsView(matches: SearchGrouping.byChat(model.hits), query: model.query, selection: Binding(
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
    /// The name of the chat and what it cost, above the transcript rather than in the toolbar: a
    /// window title is clipped to one rounded pill, and this has more to say than fits in one.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.Fonts.chatTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.Fonts.sessionMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The model the chat answers on, and the others it could. Opening the menu reads the list the
    /// first time; a pick on an expensive model comes back asking again.
    private var modelMenu: some View {
        Menu {
            if let models = model.modelList {
                ForEach(models.providers) { provider in
                    Section(provider.name) {
                        ForEach(provider.models, id: \.self) { name in
                            Button {
                                Task { await model.chooseModel(provider: provider.slug, model: name) }
                            } label: {
                                if name == model.currentModel {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Reading the models…")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(shortModel)
                    .font(.system(size: 11))
            }
        }
        .disabled(!model.hasOpenChat || model.changingModel)
        .help("Choose the model this chat answers on")
        .task { await model.loadModels() }
    }

    /// The model on the button: short enough for a toolbar, exact enough to read.
    private var shortModel: String {
        guard let model = model.currentModel else { return "Model" }
        guard let last = model.split(separator: "/").last else { return model }
        return String(last)
    }

    private var title: String {
        model.selected?.label ?? (model.isDraft ? "New chat" : "No chat open")
    }

    private var subtitle: String {
        model.selected.map(subtitle(for:)) ?? (model.isDraft ? "The dashboard names it from the first message." : "")
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header
            detailBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var detailBody: some View {
        switch model.transcriptState {
        case .loading:
            ProgressView("Loading the chat…")
                .controlSize(.small)
        case .failed(let message):
            ContentUnavailableView("The chat could not be read", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            if model.items.isEmpty && !model.isDraft {
                ContentUnavailableView("Nothing here yet", systemImage: "bubble.left", description: Text("This chat has no stored messages."))
            } else {
                VStack(spacing: 0) {
                    if model.isDraft && model.items.isEmpty {
                        ContentUnavailableView("A new chat", systemImage: "square.and.pencil", description: Text("Write the first message; the dashboard names the chat from it."))
                            .frame(maxHeight: .infinity)
                    }
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
                        chatID: model.selection,
                        loadFile: { path in try await model.fileData(path) },
                        openFile: { path in model.openFile(path) },
                        onAskAgain: { bubble in Task { await model.askAgain(bubble) } }
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
        // This chat's own model: switching another chat does not change what this one runs on.
        if let model = model.model(for: session) ?? (session.id == model.selection ? model.currentModel : nil) {
            parts.append(model)
        }
        if !session.source.isEmpty { parts.append(session.source) }
        if session.messageCount > 0 { parts.append("\(session.messageCount) messages") }
        if let usage = session.usage {
            parts.append("in \(Self.tokens(usage.inputTokens)) · out \(Self.tokens(usage.outputTokens))")
            if let cost = usage.costUSD {
                parts.append(String(format: "$%.2f", cost))
            } else if usage.included {
                parts.append("included")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Tokens as a person reads them at a glance: 6 353 536 is 6.4M.
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(count) / 1_000)
        default: return "\(count)"
        }
    }
}
