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

    init(session: DashboardSession) {
        self.session = session
    }

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
        do {
            let rows = try await session.messages(sessionID: id)
            items = Transcript.items(from: rows)
            transcriptState = .ready
        } catch {
            transcriptState = .failed(ErrorMessage.of(error))
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

    func reload() async {
        await load()
        if let selection {
            await open(selection)
        }
    }
}
