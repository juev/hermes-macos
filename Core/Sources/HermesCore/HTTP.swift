import Foundation

/// One request to a dashboard, kept apart from `URLSession` so the client can be tested without a
/// server and, later, routed through a proxy without touching the callers.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// How long this one request may take; nil means the transport's own default.
    public var timeout: TimeInterval?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public func json(_ value: JSONValue) -> HTTPRequest {
        var request = self
        request.headers["Content-Type"] = "application/json; charset=utf-8"
        request.body = try? value.encoded()
        return request
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// The body as JSON, or nil when it is empty or not JSON at all.
    public var json: JSONValue? {
        guard !body.isEmpty else { return nil }
        return try? JSONValue.decode(body)
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The transport of the app: `URLSession` with no cache and no cookie jar. A dashboard's sign-in is
/// carried in a header the client sends itself, so a session cookie would only confuse the picture.
/// The cookie jar stays empty for the `/login` page the dashboard offers, which the app opens in the
/// browser and never loads itself.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return HTTPResponse(status: http?.statusCode ?? 0, body: data, headers: headers)
    }
}
