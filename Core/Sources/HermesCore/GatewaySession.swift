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
    private let transport: any SocketTransport
    private let firstPause: Duration
    private let maxPause: Duration
    private var onEvent: (@Sendable (GatewayEvent) -> Void)?
    private var onRequest: (@Sendable (ServerRequest) -> Void)?
    private let onState: (@Sendable (State) -> Void)?

    private var loop: Task<Void, Never>?
    private var connection: GatewayConnection?
    private var state: State = .idle
    private var wanted = false

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

    /// Calls a method on the connection under way; it is an error to call before the socket is ready.
    public func call(_ method: String, params: [String: JSONValue] = [:], timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard let connection else { throw GatewayError.notConnected }
        return try await connection.call(method, params: params, timeout: timeout)
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
