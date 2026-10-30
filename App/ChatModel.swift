import Foundation
import HermesCore
import Observation

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

    /// What the person typed into the search field; an empty one shows the chats again.
    var query = "" {
        didSet { scheduleSearch() }
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(session: DashboardSession, gateway: GatewaySession) {
        self.session = session
        self.gateway = gateway
    }

    /// What the person is writing.
    var draft = ""
    /// True while a turn runs in the open chat.
    private(set) var running = false
    /// What the dashboard says about the turn: "thinking", a queued model, an error.
    private(set) var status: String?
    private(set) var sendError: String?

    func load() async {
        sessionsState = .loading
        do {
            let page = try await session.sessions()
            sessions = page.sessions
            sessionsState = .ready
            if selection == nil, let first = sessions.first {
                await open(first.id)
            }
        } catch {
            sessionsState = .failed(ErrorMessage.of(error))
        }
    }

    func open(_ id: String) async {
        selection = id
        selected = sessions.first { $0.id == id }
        transcriptState = .loading
        items = []
        status = nil
        sendError = nil
        await chat?.leave()
        chat = nil
        running = false

        do {
            let rows = try await session.messages(sessionID: id)
            items = Transcript.items(from: rows)
            transcriptState = .ready
        } catch {
            transcriptState = .failed(ErrorMessage.of(error))
            return
        }

        // The stored history does not know about a turn that runs now: the join does.
        let chat = ChatSession(gateway: gateway)
        self.chat = chat
        do {
            let joined = try await chat.join(storedID: id)
            await chat.setEventSink { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
            running = joined.running
            if joined.running {
                items = LiveTurn.resume(items, streamed: joined.streamed)
            }
        } catch {
            // A chat that cannot join is still readable; sending is what needs the socket.
            sendError = ErrorMessage.of(error)
        }
    }

    /// Sends what the person wrote into the open chat.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running, let chat else { return }
        draft = ""
        sendError = nil
        items.append(.user(UserBubble(key: "local-\(UUID().uuidString)", text: text)))
        running = true
        do {
            try await chat.submit(text)
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

    func reload() async {
        await load()
        if let selection {
            await open(selection)
        }
    }
}
