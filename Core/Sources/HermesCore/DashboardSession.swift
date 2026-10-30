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

    /// The chats the sidebar shows, newest activity first.
    public func sessions(limit: Int = 50, offset: Int = 0) async throws -> SessionPage {
        let token = try await accessToken()
        let json = try await client.get("api/sessions", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order", value: "recent"),
            URLQueryItem(name: "archived", value: "exclude"),
            URLQueryItem(name: "min_messages", value: "1")
        ], token: token)
        return SessionPage(json)
    }

    /// The stored history of one chat, oldest first.
    public func messages(sessionID: String, limit: Int = 500) async throws -> [StoredMessage] {
        let token = try await accessToken()
        let json = try await client.get("api/sessions/\(sessionID)/messages", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: "oldest"),
            URLQueryItem(name: "inline_images", value: "false")
        ], token: token)
        return StoredMessage.page(json)
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
