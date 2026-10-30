import Foundation

/// The page the browser shows once the sign-in is over.
///
/// It is the first thing a person sees of this client, and it is a browser page, not a window of the
/// app: it follows the system's light or dark setting, uses the system font stack and says one thing.
public struct CallbackPage: Sendable {
    public var signedInTitle: String
    public var signedInMessage: String
    public var failedTitle: String
    public var failedMessage: String

    public init(
        signedInTitle: String = "Signed in",
        signedInMessage: String = "You can close this window and go back to Hermes.",
        failedTitle: String = "Sign-in failed",
        failedMessage: String = "You can close this window and try again from Hermes."
    ) {
        self.signedInTitle = signedInTitle
        self.signedInMessage = signedInMessage
        self.failedTitle = failedTitle
        self.failedMessage = failedMessage
    }

    public func html(for result: CallbackResult) -> String {
        let ok: Bool
        let title: String
        var message: String
        switch result {
        case .code:
            ok = true
            title = signedInTitle
            message = signedInMessage
        case .error(_, let description):
            ok = false
            title = failedTitle
            message = failedMessage
            if let description, !description.isEmpty {
                message = "\(Self.escape(description)) — \(failedMessage)"
            }
        }
        let accent = ok ? "#0a7d33" : "#a3231f"
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escape(title)) — Hermes</title>
        <style>
        :root { color-scheme: light dark; }
        body {
            margin: 0;
            min-height: 100vh;
            display: grid;
            place-items: center;
            background: Canvas;
            color: CanvasText;
            font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            -webkit-font-smoothing: antialiased;
        }
        main { text-align: center; padding: 32px; max-width: 32rem; }
        h1 { font-size: 1.35rem; line-height: 1.25; font-weight: 600; letter-spacing: -0.01em; margin: 0 0 0.5rem; }
        p { margin: 0; color: color-mix(in srgb, CanvasText 62%, Canvas); }
        .mark { width: 10px; height: 10px; border-radius: 50%; background: \(accent); display: inline-block; margin-right: 8px; vertical-align: 1px; }
        </style>
        </head>
        <body>
        <main>
        <h1><span class="mark"></span>\(Self.escape(title))</h1>
        <p>\(message)</p>
        </main>
        </body>
        </html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum LoopbackError: Error, Equatable {
    case socket(Int32)
    case timedOut
    case cancelled
}

/// A listener on the loopback address for the one redirect of a sign-in.
///
/// The dashboard accepts a native redirect only on `http://127.0.0.1:<port>/…`, so the client opens
/// the address itself, asks the system for a free port, and waits for the browser to come back with
/// the one-time code. Requests that are not the callback — a favicon, a probe — are answered `404` and
/// the listener keeps waiting; the whole thing gives up after [timeout] or when the caller cancels.
public final class LoopbackReceiver: @unchecked Sendable {
    public let port: UInt16
    /// The address the dashboard is told to send the browser back to.
    public let redirectURI: String

    private let fd: Int32
    private let page: CallbackPage
    private let lock = NSLock()
    private var closed = false
    private let queue = DispatchQueue(label: "org.evsyukov.hermes.loopback", qos: .userInitiated)

    public init(page: CallbackPage = CallbackPage()) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw LoopbackError.socket(errno) }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 1) == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw LoopbackError.socket(code)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw LoopbackError.socket(code)
        }

        fd = socketFD
        port = UInt16(bigEndian: assigned.sin_port)
        redirectURI = "http://127.0.0.1:\(port)/callback"
        self.page = page
    }

    deinit {
        close()
    }

    /// Waits for the browser to arrive on the callback address. Closes the listener when it returns.
    public func wait(timeout: Duration = .seconds(300)) async throws -> CallbackResult {
        let seconds = Self.seconds(of: timeout)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        continuation.resume(with: Result { try self.serve(timeout: seconds) })
                    }
                }
            } onCancel: {
                self.close()
            }
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    // MARK: - Serving

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func serve(timeout: TimeInterval) throws -> CallbackResult {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LoopbackError.timedOut }
            if isClosed { throw LoopbackError.cancelled }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(clamping: Int(remaining * 1000)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw isClosed ? LoopbackError.cancelled : LoopbackError.socket(errno)
            }
            if ready == 0 { throw LoopbackError.timedOut }

            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw isClosed ? LoopbackError.cancelled : LoopbackError.socket(errno)
            }
            defer { Darwin.close(client) }

            var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

            guard let target = requestTarget(of: client) else { continue }
            if let result = SignIn.parseCallback(target) {
                write(response(status: "200 OK", body: page.html(for: result)), to: client)
                return result
            }
            write(response(status: "404 Not Found", body: ""), to: client)
        }
    }

    /// The request target of the first line of an HTTP request, e.g. `/callback?code=…`.
    private func requestTarget(of client: Int32) -> String? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while data.count < 16_384 {
            let read = recv(client, &chunk, chunk.count, 0)
            if read <= 0 { break }
            data.append(contentsOf: chunk[0..<read])
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private func response(status: String, body: String) -> String {
        let bytes = body.utf8.count
        return """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bytes)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        \(body)
        """
    }

    private func write(_ text: String, to client: Int32) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let wrote = send(client, base.advanced(by: sent), data.count - sent, 0)
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
