import Foundation

public enum SessionError: Error, Equatable {
    /// The refresh token is gone or was refused: only the browser sign-in helps now.
    case signInRequired
}

/// What a socket needs to come up: the one-time ticket, or nothing at all when the dashboard asks
/// for no sign-in.
public protocol SessionCredentials: Sendable {
    func socketTicket() async throws -> String?
}

/// The tokens of one dashboard, kept in memory and in the Keychain, refreshed a minute before they
/// run out, and dropped when the server says the session is over.
public actor DashboardSession: SessionCredentials {
    public nonisolated let endpoint: Endpoint
    private let client: DashboardClient
    private let storage: (any TokenStorage)?
    private let skew: TimeInterval
    private let now: @Sendable () -> Date
    private var tokens: Tokens?

    public init(
        endpoint: Endpoint,
        transport: any HTTPTransport = URLSessionTransport(),
        storage: (any TokenStorage)? = nil,
        skew: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        client = DashboardClient(endpoint: endpoint, transport: transport)
        self.storage = storage
        self.skew = skew
        self.now = now
    }

    public var currentTokens: Tokens? { tokens }

    /// Reads what the Keychain kept for this server, at launch.
    @discardableResult
    public func load() throws -> Tokens? {
        let stored = try storage?.tokens(for: endpoint.base.absoluteString)
        tokens = stored
        return stored
    }

    /// Takes the tokens of a finished sign-in and keeps them.
    public func adopt(_ tokens: Tokens?) throws {
        self.tokens = tokens
        try storage?.save(tokens, for: endpoint.base.absoluteString)
    }

    /// A token that can be sent now; nil when the dashboard asked for none.
    public func accessToken() async throws -> String? {
        guard let current = tokens else { return nil }
        if current.isValid(at: now(), skew: skew) { return current.accessToken }
        guard current.canRefresh else {
            try? adopt(nil)
            throw SessionError.signInRequired
        }
        do {
            let renewed = try await client.refresh(current)
            try? adopt(renewed)
            return renewed.accessToken
        } catch let error as DashboardError where error.needsSignIn {
            // Both 400 and 401 mean the refresh token is no good any more.
            try? adopt(nil)
            throw SessionError.signInRequired
        }
        // Anything else, 503 above all, keeps the tokens: the identity provider may come back.
    }

    /// What a list of chats does with the archive.
    public enum Archive: String, Sendable {
        case exclude
        case only
        case all
    }

    /// The sources a list of chats leaves out: one-shot CLI runs and the other programmatic callers.
    /// Cron stays, a scheduled run is a row with its clock glyph; subagent runs the dashboard hides itself.
    static let excludedSources = "oneshot,tool,api_server,acp,hermes_flow,vulcan_delegate,webhook"

    /// The chats the sidebar shows, newest activity first.
    public func sessions(limit: Int = 50, offset: Int = 0, archived: Archive = .exclude) async throws -> SessionPage {
        SessionPage(try await sessionsPayload(limit: limit, offset: offset, archived: archived))
    }

    /// The same payload the page is read from, so the window can keep it for the next launch.
    public func sessionsPayload(limit: Int = 50, offset: Int = 0, archived: Archive = .exclude) async throws -> JSONValue {
        let token = try await accessToken()
        return try await client.get("api/sessions", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order", value: "recent"),
            URLQueryItem(name: "archived", value: archived.rawValue),
            URLQueryItem(name: "min_messages", value: "1"),
            URLQueryItem(name: "exclude_sources", value: Self.excludedSources)
        ], token: token)
    }

    /// The stored history of one chat, oldest first.
    public func messages(sessionID: String, limit: Int = 500) async throws -> [StoredMessage] {
        StoredMessage.page(try await messagesPayload(sessionID: sessionID, limit: limit))
    }

    /// The same payload the history is read from, so a chat can be painted from disk next time.
    public func messagesPayload(sessionID: String, limit: Int = 500) async throws -> JSONValue {
        let token = try await accessToken()
        return try await client.get("api/sessions/\(sessionID)/messages", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: "oldest"),
            URLQueryItem(name: "inline_images", value: "false")
        ], token: token)
    }

    /// The models this dashboard can answer on, and the one it is set to.
    public func modelOptions() async throws -> ModelOptions {
        let token = try await accessToken()
        return ModelOptions(try await client.get("api/model/options", token: token))
    }

    /// The chats whose stored text matches [query], with the line around each match.
    public func search(_ query: String, limit: Int = 50) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let token = try await accessToken()
        let json = try await client.get("api/sessions/search", query: [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit))
        ], token: token)
        return SearchHit.page(json)
    }

    public func socketTicket() async throws -> String? {
        guard let token = try await accessToken() else { return nil }
        return try await client.socketTicket(token: token)
    }
}
