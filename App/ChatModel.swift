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

    func reload() async {
        await load()
        if let selection {
            await open(selection)
        }
    }
}
