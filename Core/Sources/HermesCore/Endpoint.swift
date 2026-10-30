import Foundation

/// The address of a dashboard and the routes that sit under it.
///
/// A dashboard answers on its own root or under a path when it is behind a reverse proxy, so a route
/// is appended to whatever path the user gave instead of replacing it: `https://example.test/hermes`
/// asks `https://example.test/hermes/api/status`.
public struct Endpoint: Sendable, Hashable {
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// Reads what a person types: a bare host gets `https://`, a trailing slash is dropped, and the
    /// path stays, since that is where a proxied dashboard lives.
    public init?(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), components.host?.isEmpty == false else { return nil }
        if components.scheme == nil { components.scheme = "https" }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else { return nil }
        self.base = url
    }

    /// A route under the base, e.g. `api/status`.
    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        let prefix = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = prefix + String(path.drop(while: { $0 == "/" }))
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        return components.url ?? base
    }

    /// The address of the socket, `/api/ws`, with the one-time ticket a signed-in server wants.
    /// A plain dashboard takes no ticket.
    public func socketURL(ticket: String?) -> URL {
        let http = url("api/ws", query: ticket.map { [URLQueryItem(name: "ticket", value: $0)] } ?? [])
        guard var components = URLComponents(url: http, resolvingAgainstBaseURL: false) else { return http }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        return components.url ?? http
    }
}
