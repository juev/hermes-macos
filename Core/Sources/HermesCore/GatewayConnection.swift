import Foundation

public enum GatewayError: Error, Equatable {
    /// The socket is not open, or the call was made before `start` or after the connection ended.
    case notConnected
    /// The connection ended under a call or before the gateway said it was ready.
    case closed
    /// No answer arrived in time.
    case timedOut(method: String)
    /// The dashboard refused the handshake itself: 403 for a socket without a good ticket.
    case refused(status: Int)
}

/// One connection to `/api/ws`, from the handshake to the last frame.
///
/// It looks after the four things a client must not forget: waiting for `gateway.ready` instead of
/// assuming the socket is usable, announcing `client.capabilities` so the dashboard asks this client
/// about approvals, pinging while the dashboard offers a heartbeat, and failing every call in flight
/// when the connection ends rather than leaving the callers waiting.
public actor GatewayConnection {
    public typealias EventHandler = @Sendable (GatewayEvent) -> Void
    public typealias RequestHandler = @Sendable (ServerRequest) -> Void

    private let url: URL
    private let transport: any SocketTransport
    private let heartbeatInterval: Duration
    private let silence: Duration
    private let onEvent: EventHandler?
    private let onRequest: RequestHandler?

    private var socket: (any SocketConnection)?
    private var pump: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID = 0
    private var readyWaiter: CheckedContinuation<GatewayReady, Error>?
    private var ready: GatewayReady?
    private var sessionAuthority = false
    private var ended = false
    /// When the last frame arrived, whatever it was: a frame is the connection living.
    private var lastFrame = ContinuousClock.now
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        url: URL,
        transport: any SocketTransport = URLSessionSocketTransport(),
        heartbeatInterval: Duration = .seconds(15),
        silence: Duration = .seconds(45),
        onEvent: EventHandler? = nil,
        onRequest: RequestHandler? = nil
    ) {
        self.url = url
        self.transport = transport
        self.heartbeatInterval = heartbeatInterval
        self.silence = silence
        self.onEvent = onEvent
        self.onRequest = onRequest
    }

    /// True when the gateway owns the sessions; it says so in `gateway.ready`.
    public func isSessionAuthority() -> Bool { sessionAuthority }

    /// True once the connection is over, for a caller that watches it without waiting on it.
    public func hasEnded() -> Bool { ended }

    /// Opens the socket, waits for `gateway.ready` and leaves the connection ready for calls.
    @discardableResult
    public func start(timeout: Duration = .seconds(20)) async throws -> GatewayReady {
        guard !ended else { throw GatewayError.closed }
        let connection = try await transport.connect(to: url)
        socket = connection
        // A slow handshake is not silence: the window counts from the moment the socket is up.
        lastFrame = .now
        pump = Task { [weak self] in
            await self?.run(connection)
        }

        let readiness = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GatewayReady, Error>) in
            if let ready {
                continuation.resume(returning: ready)
            } else {
                readyWaiter = continuation
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.readyTimedOut()
            }
        }

        sessionAuthority = readiness.sessionAuthority
        // Without this the dashboard fails approvals at once instead of asking this client.
        await transmit(
            RPCRequest(id: nextCallID(), method: "client.capabilities", params: ["server_requests": true]).frame
        )
        if readiness.heartbeat {
            startHeartbeat()
        }
        return readiness
    }

    /// Calls a method of the gateway and waits for its result.
    public func call(_ method: String, params: [String: JSONValue] = [:], timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard socket != nil, !ended else { throw GatewayError.notConnected }
        let id = nextCallID()
        let frame = RPCRequest(id: id, method: method, params: params).frame

        Task { [weak self] in
            await self?.transmit(frame, id: id)
        }
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id, method: method)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    public func respond(to request: ServerRequest, result: JSONValue = .object([:])) async {
        await transmit(Frame.answer(id: request.id, result: result))
    }

    public func refuse(_ request: ServerRequest, reason: String) async {
        await transmit(Frame.answer(id: request.id, error: reason))
    }

    public func close() {
        socket?.close()
        end(nil)
    }

    /// Suspends until the connection ends, for whoever keeps it open: the session that reconnects.
    public func waitForEnd() async {
        await withCheckedContinuation { continuation in
            if ended {
                continuation.resume()
            } else {
                endWaiters.append(continuation)
            }
        }
    }

    // MARK: - Sending

    private func transmit(_ frame: JSONValue, id: String? = nil) async {
        do {
            guard let socket else { throw GatewayError.notConnected }
            let data = try frame.encoded()
            try await socket.send(String(decoding: data, as: UTF8.self))
        } catch {
            if let id { fail(id, with: error) }
        }
    }

    private func nextCallID() -> String {
        nextID += 1
        return "c\(nextID)"
    }

    // MARK: - Receiving

    private func run(_ connection: any SocketConnection) async {
        while true {
            let text: String?
            do {
                text = try await connection.next()
            } catch {
                end(error)
                return
            }
            guard let text else {
                end(nil)
                return
            }
            // Any frame counts, including an answer to a ping and one this client does not parse.
            lastFrame = .now
            guard let value = try? JSONValue.decode(text), let frame = Frame.parse(value) else { continue }

            switch frame {
            case .event(let event):
                if event.type == "gateway.ready" {
                    let readiness = GatewayReady(payload: event.payload)
                    ready = readiness
                    sessionAuthority = readiness.sessionAuthority
                    readyWaiter?.resume(returning: readiness)
                    readyWaiter = nil
                } else {
                    onEvent?(event)
                }
            case .request(let request):
                onRequest?(request)
            case .result(let id, let value):
                resolve(id, value: value)
            case .failure(let id, let error):
                fail(id, with: error)
            }
        }
    }

    private func resolve(_ id: String, value: JSONValue) {
        pending.removeValue(forKey: id)?.resume(returning: value)
    }

    private func fail(_ id: String, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func expire(_ id: String, method: String) {
        fail(id, with: GatewayError.timedOut(method: method))
    }

    private func readyTimedOut() {
        readyWaiter?.resume(throwing: GatewayError.timedOut(method: "gateway.ready"))
        readyWaiter = nil
    }

    /// Ends the connection once, failing everything that waits on it with [failure] when there is one.
    private func end(_ failure: Error? = nil) {
        guard !ended else { return }
        ended = true
        heartbeat?.cancel()
        heartbeat = nil
        sessionAuthority = false
        let reason = failure ?? GatewayError.closed
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: reason)
        }
        readyWaiter?.resume(throwing: reason)
        readyWaiter = nil
        let finished = endWaiters
        endWaiters.removeAll()
        for continuation in finished {
            continuation.resume()
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let interval = heartbeatInterval
        let silence = silence
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                // `docs/protocol.md` §5: 45 seconds without a frame is a lost connection. It has to
                // be decided here rather than left to the transport — a userspace tailnet node keeps
                // a connection whose path is gone open, and `receive` never returns.
                guard await self.stillThere(after: silence) else { return }
                // Sent, not waited for: the ping exists to make the gateway write something, and the
                // frame it answers with is what this loop counts. Waiting for the answer here would
                // park the loop for the ping's whole timeout — exactly when the socket may be dead.
                Task { [weak self] in _ = try? await self?.call("gateway.ping", timeout: .seconds(10)) }
            }
        }
    }

    /// True while a frame came within [window]. A longer silence ends the connection: the socket is
    /// closed, so the pump stops and whoever watches the end of the connection makes another one.
    private func stillThere(after window: Duration) -> Bool {
        guard ContinuousClock.now - lastFrame >= window else { return true }
        socket?.close()
        end(GatewayError.timedOut(method: "gateway.ping"))
        return false
    }
}
