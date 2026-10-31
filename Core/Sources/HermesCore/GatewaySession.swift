import Foundation

/// The socket of one dashboard, kept open: a ticket, a connection, and another try when it drops.
///
/// A dashboard closes a socket whenever it restarts or the network changes, and neither is the
/// client's business. The session takes a fresh ticket — each one opens one socket — reconnects with
/// a pause that starts short and grows, and only stops when the sign-in is over or the caller says so.
public actor GatewaySession {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case ready
        /// Between two attempts, waiting out the pause.
        case waiting
        case failed(String)
        case stopped
    }

    private let endpoint: Endpoint
    private let credentials: any SessionCredentials
    private var transport: any SocketTransport
    private let firstPause: Duration
    private let maxPause: Duration
    private var onEvent: (@Sendable (GatewayEvent) -> Void)?
    private var onRequest: (@Sendable (ServerRequest) -> Void)?
    private let onState: (@Sendable (State) -> Void)?

    private var loop: Task<Void, Never>?
    private var connection: GatewayConnection?
    private var state: State = .idle
    private var wanted = false
    /// Set by `reconnect`: the next attempt is one this client asked for, not one the pause earned.
    private var startingOver = false

    public init(
        endpoint: Endpoint,
        credentials: any SessionCredentials,
        transport: any SocketTransport = URLSessionSocketTransport(),
        firstPause: Duration = .seconds(1),
        maxPause: Duration = .seconds(30),
        onEvent: (@Sendable (GatewayEvent) -> Void)? = nil,
        onRequest: (@Sendable (ServerRequest) -> Void)? = nil,
        onState: (@Sendable (State) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
        self.firstPause = firstPause
        self.maxPause = maxPause
        self.onEvent = onEvent
        self.onRequest = onRequest
        self.onState = onState
    }

    public func currentState() -> State { state }

    /// Who hears about the events and the questions of the gateway. The chat takes them once it has
    /// joined a session; until then nothing is listening.
    public func setHandlers(
        onEvent: (@Sendable (GatewayEvent) -> Void)?,
        onRequest: (@Sendable (ServerRequest) -> Void)? = nil
    ) {
        self.onEvent = onEvent
        self.onRequest = onRequest
    }

    /// Keeps a socket open until `stop`. Safe to call twice.
    public func start() {
        guard !wanted else { return }
        wanted = true
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        wanted = false
        loop?.cancel()
        loop = nil
        let open = connection
        connection = nil
        if open != nil {
            Task { await open?.close() }
        }
        setState(.stopped)
    }

    /// Points the session at another route: the next attempt is made with [transport]. A `URLSession`
    /// keeps the proxy it was built with and cannot be re-aimed, so the transport is replaced rather
    /// than shared when the tailnet route under the socket changes.
    public func setTransport(_ transport: any SocketTransport) {
        self.transport = transport
    }

    /// Drops the socket under way, so the session opens another one with the transport it has now,
    /// without waiting out the pause the last failure earned.
    public func reconnect() {
        guard wanted else { return }
        startingOver = true
        let open = connection
        connection = nil
        if let open {
            Task { await open.close() }
        } else {
            setState(.waiting)
        }
    }

    /// Calls a method on the connection under way. A chat opened while the socket is still coming up
    /// waits for it instead of failing at once: the window starts the socket and opens a chat in the
    /// same breath, and the order of those two is not something a person should be able to feel.
    public func call(_ method: String, params: [String: JSONValue] = [:], timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let connection = try await ready(timeout: .seconds(20))
        return try await connection.call(method, params: params, timeout: timeout)
    }

    /// The connection that is up, waiting for it if the session is still connecting.
    private func ready(timeout: Duration) async throws -> GatewayConnection {
        let deadline = ContinuousClock.now + timeout
        while true {
            if case .ready = state, let connection { return connection }
            switch state {
            case .stopped, .failed:
                throw GatewayError.notConnected
            case .idle where !wanted:
                throw GatewayError.notConnected
            default:
                break
            }
            guard ContinuousClock.now < deadline else {
                throw GatewayError.timedOut(method: "gateway.ready")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    public func respond(to request: ServerRequest, result: JSONValue = .object([:])) async {
        await connection?.respond(to: request, result: result)
    }

    public func refuse(_ request: ServerRequest, reason: String) async {
        await connection?.refuse(request, reason: reason)
    }

    // MARK: - The loop

    private func run() async {
        var pause = firstPause
        var refusals = 0
        while wanted {
            setState(.connecting)
            do {
                let ticket = try await credentials.socketTicket()
                let connection = GatewayConnection(
                    url: endpoint.socketURL(ticket: ticket),
                    transport: transport,
                    onEvent: { [weak self] event in
                        guard let self else { return }
                        Task { await self.handle(event) }
                    },
                    onRequest: { [weak self] request in
                        guard let self else { return }
                        Task { await self.handle(request) }
                    }
                )
                self.connection = connection
                try await connection.start()
                setState(.ready)
                pause = firstPause
                refusals = 0
                await connection.waitForEnd()
            } catch {
                if !wanted { break }
                if let gatewayError = error as? GatewayError, case .refused(let status) = gatewayError {
                    // A fresh ticket may fix one refusal; three in a row mean the sign-in is over.
                    refusals += 1
                    if refusals >= 3 {
                        wanted = false
                        connection = nil
                        setState(.failed("The dashboard refused the socket (\(status)). The sign-in may be over."))
                        return
                    }
                } else {
                    refusals = 0
                }
                if error as? SessionError == .signInRequired {
                    // No attempt can succeed without a sign-in, and saying so beats a silent loop.
                    wanted = false
                    connection = nil
                    setState(.failed("The sign-in is over. Sign in again to keep the connection."))
                    return
                }
            }

            connection = nil
            guard wanted else { break }
            // A socket this client asked to drop is not a failure: the next attempt goes at once
            // instead of after the pause a broken connection would have earned.
            if startingOver {
                startingOver = false
                pause = firstPause
            }
            setState(.waiting)
            try? await Task.sleep(for: pause)
            pause = min(pause * 2, maxPause)
        }
        setState(.stopped)
    }

    private func handle(_ event: GatewayEvent) {
        onEvent?(event)
    }

    private func handle(_ request: ServerRequest) {
        onRequest?(request)
    }

    private func setState(_ next: State) {
        state = next
        onState?(next)
    }
}
