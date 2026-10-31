import Foundation

/// One open socket of the gateway.
public protocol SocketConnection: Sendable {
    func send(_ text: String) async throws
    /// The next text frame; nil once the other side closed the socket.
    func next() async throws -> String?
    func close()
}

public protocol SocketTransport: Sendable {
    func connect(to url: URL) async throws -> any SocketConnection
}

/// `URLSession` opening the socket. No cache, no cookies: the dashboard's sign-in travels as the
/// one-time ticket in the address, not as a session cookie.
public final class URLSessionSocketTransport: SocketTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30, proxy: TailnetProxy? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        // The socket of a dashboard on the built-in tailnet is carried by the node's proxy too: a
        // `wss` address goes over the same CONNECT the rest of the session uses.
        configuration.connectionProxyDictionary = proxy?.settings
        session = URLSession(configuration: configuration)
    }

    /// The proxy this session opens its sockets through, for a test that checks the wiring.
    var proxySettings: [AnyHashable: Any]? { session.configuration.connectionProxyDictionary }

    public func connect(to url: URL) async throws -> any SocketConnection {
        let task = session.webSocketTask(with: url)
        task.resume()
        return URLSessionSocketConnection(task: task)
    }
}

final class URLSessionSocketConnection: SocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func next() async throws -> String? {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return nil
            }
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            // A refused handshake is an HTTP answer, not a broken socket: the dashboard denies the
            // upgrade with 403 and an empty body, which deserves a sentence of its own.
            if let response = task.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw GatewayError.refused(status: response.statusCode)
            }
            throw error
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
