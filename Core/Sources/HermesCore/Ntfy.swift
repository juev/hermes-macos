import Foundation

/// Where the pushes of `hermes-push` arrive: an ntfy topic the client subscribes to.
///
/// ntfy names a topic in the path of its own server, `https://ntfy.example.org/upabc`, and serves it
/// as a JSON stream of lines. That address is what the client registers as its endpoint; the same
/// topic is where the dashboard posts the encrypted Web Push.
public struct NtfyTopic: Sendable, Equatable {
    public let base: URL
    public let topic: String

    public init(base: URL, topic: String) {
        self.base = base
        self.topic = topic
    }

    /// Reads a topic address as a person types it: `https://ntfy.example.org/upabc`.
    public init?(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty else { return nil }
        let pieces = components.path.split(separator: "/").map(String.init)
        guard let topic = pieces.last, pieces.count >= 1, !topic.isEmpty else { return nil }
        components.path = "/" + pieces.dropLast().joined(separator: "/")
        if components.path == "/" { components.path = "" }
        guard let base = components.url else { return nil }
        self.init(base: base, topic: topic)
    }

    /// The address to register with the dashboard: the topic as a URL.
    public var endpoint: String {
        base.appending(path: topic).absoluteString
    }

    /// The long-lived stream of the topic: one JSON object per line.
    public var streamURL: URL {
        base.appending(path: topic).appending(path: "json")
    }
}

/// How the reader signs in to ntfy. The server here refuses an anonymous reader.
public struct NtfyCredentials: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case basic(user: String, password: String)
        case token(String)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var headers: [String: String] {
        switch kind {
        case .basic(let user, let password):
            let pair = "\(user):\(password)"
            return ["Authorization": "Basic " + Data(pair.utf8).base64EncodedString()]
        case .token(let token):
            return ["Authorization": "Bearer \(token)"]
        }
    }
}

/// One line of the stream. ntfy sends `open` first, `keepalive` while nothing happens, and `message`
/// for each push.
public struct NtfyMessage: Sendable, Equatable {
    public let id: String
    public let event: String
    public let topic: String
    /// The text of the message as ntfy wrote it.
    public let text: String
    /// The body as bytes when ntfy said how it encoded them.
    public let body: Data
    /// The text read as base64. A push is binary, and this server hands a binary body back as base64
    /// in `message` with **no** `encoding` field to say so — so the bytes cannot be taken on trust and
    /// this is the other reading to try.
    public let base64Body: Data?

    /// Reads one line of the JSON stream; nil for a line that is not a message.
    public init?(line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONValue.decode(data) else { return nil }
        let event = json["event"]?.stringValue ?? "message"
        id = json["id"]?.stringValue ?? ""
        self.event = event
        topic = json["topic"]?.stringValue ?? ""
        let text = json["message"]?.stringValue ?? ""
        self.text = text
        base64Body = Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
        if json["encoding"]?.stringValue == "base64" {
            body = Data(base64Encoded: text) ?? Data()
        } else {
            body = Data(text.utf8)
        }
    }

    /// The body in one of the two readings it can have, whichever opens.
    public var candidateBodies: [Data] {
        [body, base64Body].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

/// A stream of lines from a server that keeps the connection open: the ntfy topic, in the app.
public protocol PushStreamProvider: Sendable {
    func lines(from url: URL, headers: [String: String]) async throws -> AsyncThrowingStream<String, Error>
}

/// The stream of `URLSession`, one line at a time.
public struct URLSessionLineStream: PushStreamProvider {
    public init() {}

    public func lines(from url: URL, headers: [String: String]) async throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // The stream is the point: a body that URLSession compresses is held back until a block of it
        // is complete, and a push would arrive in a burst whenever the block filled.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let session = URLSession(configuration: .ephemeral)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DashboardError(status: http.statusCode, detail: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return AsyncThrowingStream { continuation in
            // The session has to outlive this function: a session that is released cancels its task,
            // and the stream would end before a push ever came. Capturing it in the task keeps it for
            // as long as the stream is read.
            let session = session
            let task = Task {
                _ = session
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The receiving end of `hermes-push`: subscribes to the topic, opens each body with the keys of the
/// subscription, and hands on what the dashboard sent.
public actor PushListener {
    public enum State: Sendable, Equatable {
        case idle
        case listening
        case failed(String)
    }

    private let topic: NtfyTopic
    private let credentials: NtfyCredentials?
    private let keys: PushKeys
    private let stream: any PushStreamProvider
    private let onPush: @Sendable (PushMessage) -> Void
    private let onState: (@Sendable (State) -> Void)?
    private var task: Task<Void, Never>?
    private var state: State = .idle

    public init(
        topic: NtfyTopic,
        credentials: NtfyCredentials?,
        keys: PushKeys,
        stream: any PushStreamProvider = URLSessionLineStream(),
        onPush: @escaping @Sendable (PushMessage) -> Void,
        onState: (@Sendable (State) -> Void)? = nil
    ) {
        self.topic = topic
        self.credentials = credentials
        self.keys = keys
        self.stream = stream
        self.onPush = onPush
        self.onState = onState
    }

    public func currentState() -> State { state }

    public func start() {
        guard task == nil else { return }
        setState(.listening)
        // A strong reference on purpose: the listener is a long-lived one, and a task that let it go
        // the moment `start` returned listened to nothing at all. `stop` cancels the task, which ends
        // the loop and the reference with it.
        task = Task {
            await listen()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        setState(.idle)
    }

    private func listen() async {
        while !Task.isCancelled {
            do {
                let lines = try await stream.lines(from: topic.streamURL, headers: credentials?.headers ?? [:])
                for try await line in lines {
                    guard !Task.isCancelled else { return }
                    guard let message = NtfyMessage(line: line), message.event == "message" else { continue }
                    // One of the readings opens; the other is why this is a loop and not an `if let`.
                    for body in message.candidateBodies {
                        guard let plain = try? WebPush.decrypt(body, keys: keys),
                              let json = try? JSONValue.decode(plain) else { continue }
                        onPush(PushMessage(json))
                        break
                    }
                }
            } catch {
                if Task.isCancelled { return }
                setState(.failed(Self.message(for: error)))
            }
            // A stream that ends is a stream to open again, unless the listener was stopped.
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// What a person can do about a stream that will not open: the one refusal a reader meets is a
    /// push server that will not serve the topic without a user who may read it.
    static func message(for error: Error) -> String {
        if let error = error as? DashboardError, error.status == 401 || error.status == 403 {
            return "The push server refused to serve the topic. Check that the ntfy user may read it."
        }
        return error.localizedDescription
    }

    private func setState(_ next: State) {
        state = next
        onState?(next)
    }
}
