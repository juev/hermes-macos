import AppKit
import Foundation
import HermesCore
import Observation
import UniformTypeIdentifiers

/// The chats of one dashboard and the history of the one that is open.
@MainActor
@Observable
final class ChatModel {
    enum Loading: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private let session: DashboardSession
    private let gateway: GatewaySession
    private let hub: ChatHub
    /// The push of this dashboard, with the topic and keys it needs.
    let push: PushModel
    private var chat: ChatSession?

    private(set) var sessions: [SessionSummary] = []
    private(set) var sessionsState: Loading = .loading
    private(set) var items: [ChatItem] = []
    private(set) var transcriptState: Loading = .ready
    private(set) var selected: SessionSummary?
    private(set) var selection: String?
    private(set) var hits: [SearchHit] = []
    private(set) var searchState: Loading = .ready
    private var searchTask: Task<Void, Never>?
    private var admin: ChatAdmin?
    /// The chats left while their turn still ran: their session stays open so its end is noticed.
    private var watched: [String: ChatSession] = [:]
    /// Which chat holds the question on screen, which is not always the chat the window shows.
    private var questionOwners: [String: ChatSession] = [:]
    private let pins = LocalPins()
    /// What was read before, so a launch paints before the dashboard answers.
    private let cache = ChatCache.standard()
    private var prefetchTask: Task<Void, Never>?

    /// What the person typed into the search field; an empty one shows the chats again.
    var query = "" {
        didSet { scheduleSearch() }
    }

    /// The models this dashboard can answer on.
    private(set) var models: ModelOptions?
    /// The app has been told the model costs more and is waiting for a second yes.
    private(set) var modelConfirmation: String?
    private(set) var changingModel = false

    /// The model the open chat answers on, as the dashboard last said.
    var currentModel: String? {
        models?.model ?? selected?.model
    }

    /// True while the sidebar shows the archive instead of the chats.
    private(set) var showingArchive = false

    /// The chats split for the sidebar, with the pins this Mac keeps.
    var sections: [Sidebar.Section] {
        Sidebar.sections(sessions)
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(session: DashboardSession, gateway: GatewaySession, hub: ChatHub) {
        self.session = session
        self.gateway = gateway
        self.hub = hub
        self.push = PushModel(session: session)
    }

    /// What the person is writing.
    var draft = ""
    /// Files picked for the message under it.
    private(set) var drafts: [AttachmentDraft] = []
    /// True while a turn runs in the open chat.
    private(set) var running = false
    /// What the dashboard says about the turn: "thinking", a queued model, an error.
    private(set) var status: String?
    private(set) var sendError: String?
    /// The question the agent waits on, if any.
    private(set) var question: AgentQuestion?
    /// A chat that exists only in the gateway so far: created, not yet named by its first message.
    private(set) var isDraft = false
    /// True while the gateway is being asked for the session of a new chat. The window shows the
    /// composer at once and only the send waits.
    private(set) var creatingChat = false

    /// True when a message can be written: a stored chat is open, or a new one is being started.
    var hasOpenChat: Bool { selection != nil || isDraft }

    func load() async {
        await push.restoreIfEnabled()

        // What the last launch read, painted at once; the dashboard's answer replaces it when it comes.
        if sessions.isEmpty, let cached = cache.read(ChatCache.sessionsName(server: server)) {
            take(SessionPage(cached))
            if sessionsState != .ready { sessionsState = .ready }
        }
        if sessions.isEmpty { sessionsState = .loading }

        do {
            let payload = try await session.sessionsPayload(archived: showingArchive ? .only : .exclude)
            cache.write(payload, name: ChatCache.sessionsName(server: server))
            take(SessionPage(payload))
            sessionsState = .ready
            if selection == nil, let first = sessions.first {
                await open(first.id)
            }
            prefetch()
        } catch {
            // A list that was already painted stays: a refresh that fails is not a blank window.
            if sessions.isEmpty {
                sessionsState = .failed(ErrorMessage.of(error))
            } else {
                sendError = ErrorMessage.of(error)
            }
        }
    }

    /// Takes a page of chats and marks the ones this Mac pinned itself.
    private func take(_ page: SessionPage) {
        let pinnedHere = pins.pins(for: server)
        sessions = page.sessions.map { chat in
            !chat.pinned && pinnedHere.contains(chat.id) ? chat.settingPinned(true) : chat
        }
    }

    /// Reads the chats around the open one while nothing else needs the wire, so opening one of them
    /// paints from disk instead of waiting.
    private func prefetch() {
        prefetchTask?.cancel()
        let ids = sessions.prefix(30).map(\.id)
        let session = self.session
        let cache = self.cache
        prefetchTask = Task {
            // A few at a time: enough to fill the list while the person reads, not enough to make the
            // dashboard feel hammered.
            await withTaskGroup(of: Void.self) { group in
                var queue = ids[...]
                for _ in 0..<4 {
                    guard let id = queue.popFirst() else { break }
                    group.addTask {
                        if cache.read(ChatCache.transcriptName(chat: id), olderThan: 900) != nil { return }
                        guard let payload = try? await session.messagesPayload(sessionID: id) else { return }
                        cache.write(payload, name: ChatCache.transcriptName(chat: id))
                    }
                }
                for await _ in group {
                    if Task.isCancelled { return }
                    guard let id = queue.popFirst() else { continue }
                    group.addTask {
                        if cache.read(ChatCache.transcriptName(chat: id), olderThan: 900) != nil { return }
                        guard let payload = try? await session.messagesPayload(sessionID: id) else { return }
                        cache.write(payload, name: ChatCache.transcriptName(chat: id))
                    }
                }
            }
        }
    }

    func open(_ id: String) async {
        let previousID = selection
        let previousChat = chat
        let previousRunning = running

        selection = id
        selected = sessions.first { $0.id == id }
        status = nil
        sendError = nil
        question = nil
        running = false
        chat = nil

        // What was read last time, before anything is awaited: the chat is on screen in the same turn
        // of the run loop as the click. The wire corrects it a moment later.
        if let cached = cache.read(ChatCache.transcriptName(chat: id)) {
            items = Transcript.items(from: StoredMessage.page(cached))
            transcriptState = .ready
            Log.app.debug("chat \(id.prefix(12), privacy: .public): painted from the cache, \(self.items.count) items")
        } else {
            items = []
            transcriptState = .loading
            Log.app.debug("chat \(id.prefix(12), privacy: .public): nothing cached")
        }

        // Letting go of the chat being left costs a round trip, and the chat being opened has no
        // reason to wait for it.
        if let previousChat {
            Task {
                await release(previousChat, storedID: previousRunning ? previousID : nil, opening: id)
            }
        }

        do {
            let started = Date()
            let payload = try await session.messagesPayload(sessionID: id)
            cache.write(payload, name: ChatCache.transcriptName(chat: id))
            items = Transcript.items(from: StoredMessage.page(payload))
            transcriptState = .ready
            Log.app.debug("chat \(id.prefix(12), privacy: .public): read from the dashboard in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            if items.isEmpty {
                transcriptState = .failed(ErrorMessage.of(error))
                return
            }
        }

        // Coming back to a chat whose turn never ended: its session is still the live one.
        if let existing = watched.removeValue(forKey: id) {
            chat = existing
            await wire(existing)
            running = true
            transcriptState = .ready
            return
        }

        // The stored history does not know about a turn that runs now: the join does.
        let chat = ChatSession(gateway: gateway, hub: hub)
        self.chat = chat
        do {
            let joined = try await chat.join(storedID: id)
            await wire(chat)
            running = joined.running
            if joined.running {
                items = LiveTurn.resume(items, streamed: joined.streamed)
            }
        } catch {
            // A chat that cannot join is still readable; sending is what needs the socket.
            sendError = ErrorMessage.of(error)
        }
    }

    /// Reads a file the person picked into the message under the field.
    func addFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= AttachmentDraft.largestByteCount else {
                sendError = "That file is larger than 25 MB, which this client will not send."
                return
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            drafts.append(AttachmentDraft(name: url.lastPathComponent, mime: type, data: data))
            sendError = nil
        } catch {
            sendError = "The file could not be read: \(error.localizedDescription)"
        }
    }

    func removeDraft(_ draft: AttachmentDraft) {
        drafts.removeAll { $0.id == draft.id }
    }

    /// Starts a chat that has no name yet: the dashboard names it from the first message.
    func newChat() async {
        let previous = chat
        let previousID = selection
        chat = nil
        selection = nil
        selected = nil
        items = []
        running = false
        question = nil
        status = nil
        sendError = nil
        transcriptState = .ready
        // The window shows the new chat at once: the session is asked for behind it, and only a
        // message waits for the answer.
        isDraft = true
        creatingChat = true

        await release(previous, storedID: running ? previousID : nil, opening: nil)

        let chat = ChatSession(gateway: gateway, hub: hub)
        self.chat = chat
        await wire(chat)
        do {
            try await chat.create()
        } catch {
            isDraft = false
            sendError = ErrorMessage.of(error)
        }
        creatingChat = false
    }

    /// The first turn of a new chat is over: the dashboard has stored it, so the list is read again
    /// and the chat is opened by the id the sidebar knows, named like any other.
    private func adoptDraft() async {
        isDraft = false
        await load()
    }

    /// What becomes of a chat the window is leaving: one whose turn still runs keeps its session for
    /// the end of that turn — closing it could stop the turn, and its end deserves a banner — while
    /// any other is let go. [opening] is the chat being opened, which a watcher is not kept for.
    private func release(_ leaving: ChatSession?, storedID: String?, opening: String?) async {
        guard let leaving else { return }
        if let storedID, storedID != opening {
            await watch(leaving, storedID: storedID)
        } else {
            await leaving.leave()
        }
    }

    private func wire(_ chat: ChatSession) async {
        await chat.setEventSink { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        await chat.setQuestionSink { [weak self, weak chat] question in
            Task { @MainActor in
                guard let self else { return }
                if let chat { self.questionOwners[question.id] = chat }
                self.question = question
                if case .approval(let approval) = question {
                    TurnNotifier.shared.questionAsked(chat: self.selected?.label ?? "Hermes", approval: approval)
                }
            }
        }
    }

    /// Keeps a chat's session for the rest of its turn and says how the turn ended. The transcript is
    /// not drawn: the chat is not on screen, only its end matters.
    private func watch(_ chat: ChatSession, storedID: String) async {
        let label = sessions.first { $0.id == storedID }?.label ?? "Hermes"
        let watcher = ChatWatcher()
        watched[storedID] = chat

        await chat.setEventSink { [weak self, weak chat] event in
            Task { @MainActor in
                watcher.apply(event)
                guard event.type == "message.complete" else { return }
                self?.watched[storedID] = nil
                TurnNotifier.shared.turnFinished(chat: label, answer: watcher.text)
                if let chat { await chat.leave() }
            }
        }
        await chat.setQuestionSink { [weak self, weak chat] question in
            Task { @MainActor in
                guard let self else { return }
                if let chat { self.questionOwners[question.id] = chat }
                self.question = question
                if case .approval(let approval) = question {
                    TurnNotifier.shared.questionAsked(chat: label, approval: approval)
                }
            }
        }
    }

    /// Sends what the person wrote into the open chat, with the files picked for it.
    func send() async {
        // A chat being made: the words wait for the session instead of being refused, so hitting
        // Return the moment the window opens a new chat still sends.
        while creatingChat {
            try? await Task.sleep(for: .milliseconds(60))
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = drafts
        guard !text.isEmpty || !files.isEmpty, !running, let chat else { return }
        draft = ""
        drafts = []
        sendError = nil

        let shown = text.isEmpty
            ? (files.allSatisfy(\.isImage) ? "Describe the picture." : "Look at these files.")
            : text
        items.append(.user(UserBubble(
            key: "local-\(UUID().uuidString)",
            text: shown,
            attachments: files.map { Attachment(path: $0.name, name: $0.name, isImage: $0.isImage) }
        )))
        running = true
        do {
            // A file answers with the text that names it, which the prompt has to carry; a picture
            // joins the vision queue of the turn on its own.
            var refs: [String] = []
            for file in files {
                if let ref = try await chat.attach(file) { refs.append(ref) }
            }
            let prompt = refs.isEmpty ? shown : shown + "\n" + refs.joined(separator: "\n")
            try await chat.submit(prompt)
        } catch {
            running = false
            sendError = ErrorMessage.of(error)
        }
    }

    /// The chat that asked the question on screen: it need not be the one the window shows.
    private func owner(of question: AgentQuestion) -> ChatSession? {
        questionOwners[question.id] ?? chat
    }

    /// Answers the question the agent waits on.
    func answer(_ choice: String) async {
        guard let question else { return }
        let chat = owner(of: question)
        questionOwners[question.id] = nil
        await chat?.answer(question, with: AgentAnswer.approval(choice))
        self.question = nil
    }

    func answerClarify(_ answers: [String: String?]) async {
        guard let question else { return }
        let chat = owner(of: question)
        questionOwners[question.id] = nil
        await chat?.answer(question, with: AgentAnswer.clarify(answers))
        self.question = nil
    }

    func answerSecret(_ value: String) async {
        guard let question else { return }
        let chat = owner(of: question)
        questionOwners[question.id] = nil
        await chat?.answer(question, with: AgentAnswer.secret(value))
        self.question = nil
    }

    func dismissQuestion() async {
        guard let question else { return }
        let chat = owner(of: question)
        questionOwners[question.id] = nil
        switch question {
        case .approval:
            await chat?.answer(question, with: AgentAnswer.approval("deny"))
        case .clarify:
            await chat?.answer(question, with: AgentAnswer.clarifyCancelled)
        case .secret:
            await chat?.refuse(question)
        }
        self.question = nil
    }

    /// Asks the dashboard for the last turn again, with the very text the agent was sent.
    func askAgain(_ bubble: UserBubble) async {
        guard let chat, !isDraft, !bubble.sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if running { await stop() }
        do {
            try await chat.retry()
            // The dashboard dropped the turn; the window drops it too and asks again.
            if let index = items.lastIndex(where: { item in
                if case .user(let mine) = item { return mine.key == bubble.key }
                return false
            }) {
                items = Array(items.prefix(index + 1))
            }
            sendError = nil
            running = true
            try await chat.submit(bubble.sent)
        } catch {
            running = false
            sendError = ErrorMessage.of(error)
        }
    }

    func stop() async {
        guard let chat else { return }
        try? await chat.interrupt()
        items = LiveTurn.close(items, interrupted: true)
        running = false
    }

    private func apply(_ event: GatewayEvent) {
        let wasRunning = running
        switch event.type {
        case "message.start":
            running = true
            status = nil
        case "status.update":
            status = event.payload["text"]?.stringValue
        case "thinking.delta":
            status = "Thinking…"
        case "error":
            status = nil
            running = false
            sendError = event.payload["message"]?.stringValue
        case "message.complete":
            running = false
            status = nil
        default:
            break
        }
        items = LiveTurn.apply(event, to: items)

        if event.type == "message.complete", wasRunning, isDraft {
            Task { await self.adoptDraft() }
        }

        // A turn that ends while the window is behind another one is what a banner is for.
        if event.type == "message.complete", wasRunning {
            let answer: String
            if case .assistant(let turn)? = items.last {
                answer = turn.text
            } else {
                answer = ""
            }
            TurnNotifier.shared.turnFinished(chat: selected?.label ?? "Hermes", answer: answer)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = []
            searchState = .ready
            return
        }
        searchTask = Task { [weak self] in
            // A keystroke per letter would ask the dashboard once per letter.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        searchState = .loading
        do {
            let found = try await session.search(text)
            guard !Task.isCancelled else { return }
            hits = found
            searchState = .ready
        } catch {
            searchState = .failed(ErrorMessage.of(error))
        }
    }

    /// Opens the chat a result was found in, and clears the search so the list comes back.
    func openSearchResult(_ id: String) async {
        query = ""
        await open(id)
    }

    /// The bytes of a file the agent delivered.
    func fileData(_ path: String) async throws -> Data {
        let token = try await session.accessToken()
        return try await FileDownload(endpoint: session.endpoint).data(path: path, token: token)
    }

    /// Writes a delivered file where the system can open it.
    func openFile(_ path: String) {
        Task {
            guard let data = try? await fileData(path) else { return }
            let name = path.split(separator: "/").last.map(String.init) ?? "file"
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try data.write(to: destination)
                NSWorkspace.shared.open(destination)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                sendError = "The file could not be written: \(error.localizedDescription)"
            }
        }
    }

    /// Reads the models the dashboard offers: the list is small, and a menu that has to wait for it
    /// would open empty.
    func loadModels() async {
        guard models == nil else { return }
        models = try? await session.modelOptions()
    }

    /// Answers this chat on another model from its next turn.
    func chooseModel(provider: String, model: String, confirmed: Bool = false) async {
        guard let chat, hasOpenChat else { return }
        await loadModels()
        changingModel = true
        defer { changingModel = false }
        do {
            switch try await chat.setModel(provider: provider, model: model, confirmed: confirmed) {
            case .set:
                modelConfirmation = nil
                sendError = nil
                models = models.map { old in
                    ModelOptions(model: model, provider: provider, providers: old.providers.map { entry in
                        ModelProvider(slug: entry.slug, name: entry.name, models: entry.models,
                                      isCurrent: entry.slug == provider, warning: entry.warning)
                    })
                }
            case .deferred(let warning):
                modelConfirmation = nil
                status = warning ?? "The turn under way keeps the model it started on."
            case .needsConfirmation(let message):
                modelConfirmation = message
                pendingModel = (provider, model)
            }
        } catch {
            sendError = ErrorMessage.of(error)
        }
    }

    /// The list of models, named for the menu.
    var modelList: ModelOptions? { models }

    /// The pick the dashboard was unsure about, remembered so a second yes can finish it.
    private var pendingModel: (provider: String, model: String)?

    func dismissModelConfirmation() {
        modelConfirmation = nil
        pendingModel = nil
    }

    /// The second yes: the same switch, this time told that the price is understood.
    func confirmModelSwitch() async {
        guard let pending = pendingModel else { return }
        modelConfirmation = nil
        pendingModel = nil
        await chooseModel(provider: pending.provider, model: pending.model, confirmed: true)
    }

    /// Shows the archive instead of the chats, or goes back to them.
    func toggleArchive() async {
        showingArchive.toggle()
        selection = nil
        selected = nil
        items = []
        await load()
    }

    /// Pins a chat on this Mac, where a plain dashboard refuses to keep it.
    func pin(_ summary: SessionSummary, pinned: Bool) {
        pins.set(summary.id, pinned: pinned, for: server)
        sessions = sessions.map { $0.id == summary.id ? $0.settingPinned(pinned) : $0 }
    }

    /// Gives a chat another name, over the open chat's session or a join made for the call.
    func rename(_ summary: SessionSummary, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if summary.id == selection, let chat {
                try await chat.rename(trimmed)
            } else {
                try await administrator().rename(storedID: summary.id, title: trimmed)
            }
            await load()
            if let selection { await open(selection) }
        } catch {
            sendError = ErrorMessage.of(error)
        }
    }

    /// Files a chat away, or takes it back out of the archive.
    func archive(_ summary: SessionSummary, archived: Bool) async {
        do {
            try await administrator().archive(storedID: summary.id, archived: archived)
            if archived, summary.id == selection {
                await chat?.leave()
                chat = nil
                selection = nil
                items = []
            }
            await load()
        } catch {
            sendError = ErrorMessage.of(error)
        }
    }

    /// Deletes a chat and everything in it.
    func delete(_ summary: SessionSummary) async {
        do {
            if summary.id == selection {
                await chat?.leave()
                chat = nil
                selection = nil
                items = []
                transcriptState = .ready
            }
            try await administrator().delete(storedID: summary.id)
            await load()
        } catch {
            sendError = ErrorMessage.of(error)
        }
    }

    private var server: String { session.endpoint.base.absoluteString }

    private func administrator() -> ChatAdmin {
        if let admin { return admin }
        let made = ChatAdmin(gateway: gateway)
        admin = made
        return made
    }

    func reload() async {
        await load()
        // Re-opening the chat under the person would close its live session, and a turn in it with
        // it; a turn that runs is left alone, and the list is what a refresh is for.
        if let selection, !running {
            await open(selection)
        }
    }
}
