import Foundation

/// One call to the gateway: JSON-RPC 2.0 over one text frame of `/api/ws`.
public struct RPCRequest: Sendable, Equatable {
    public let id: String
    public let method: String
    public let params: [String: JSONValue]

    public init(id: String, method: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var frame: JSONValue {
        [
            "jsonrpc": "2.0",
            "id": .string(id),
            "method": .string(method),
            "params": .object(params)
        ]
    }
}

/// An error the gateway answered a call with; `code` is negative for the JSON-RPC ones.
public struct RPCFailure: Sendable, Equatable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A question the gateway asks the client — an approval, a clarification — whose answer goes back
/// with the same id through `Frame.answer`.
public struct ServerRequest: Sendable, Equatable {
    public let id: String
    public let method: String
    public let params: [String: JSONValue]

    public init(id: String, method: String, params: [String: JSONValue]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// What arrived in one frame of the socket.
public enum IncomingFrame: Sendable, Equatable {
    /// A notification: `method` is `event` and the payload sits under `params`.
    case event(GatewayEvent)
    /// A call from the server that waits for an answer.
    case request(ServerRequest)
    /// The answer to a call this client made.
    case result(id: String, value: JSONValue)
    /// The failure of a call this client made.
    case failure(id: String, error: RPCFailure)
}

public enum Frame {
    /// Sorts one decoded frame into the four kinds. Nil for a frame that is none of them, which the
    /// socket drops: an unknown notification is not a reason to lose the connection.
    public static func parse(_ value: JSONValue) -> IncomingFrame? {
        guard case .object(let frame) = value else { return nil }
        let id = frame["id"]?.scalarString
        let method = frame["method"]?.stringValue

        if method == "event" {
            guard case .object(let params) = frame["params"] ?? .null else { return nil }
            return .event(GatewayEvent(params: params))
        }
        if let method, let id {
            return .request(ServerRequest(id: id, method: method, params: frame["params"]?.objectValue ?? [:]))
        }
        if let id {
            if case .object(let error) = frame["error"] ?? .null {
                return .failure(id: id, error: RPCFailure(
                    code: error["code"]?.intValue ?? -1,
                    message: error["message"]?.stringValue ?? defaultErrorMessage,
                    data: error["data"]
                ))
            }
            return .result(id: id, value: frame["result"] ?? .null)
        }
        return nil
    }

    /// The answer to a server request, accepted.
    public static func answer(id: String, result: JSONValue = .object([:])) -> JSONValue {
        ["jsonrpc": "2.0", "id": .string(id), "result": result]
    }

    /// The answer to a server request, refused. `-32000` is the range the gateway reads as "the
    /// person said no" rather than as a protocol error.
    public static func answer(id: String, error: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": .string(id), "error": ["code": -32000, "message": .string(error)]]
    }

    static let defaultErrorMessage = "The dashboard answered with an error."
}

/// An event of the gateway: the `params` of a notification whose method is `event`.
public struct GatewayEvent: Sendable, Equatable {
    public let type: String
    public let sessionID: String?
    public let seq: Int64?
    public let payload: [String: JSONValue]

    public init(params: [String: JSONValue]) {
        type = params["type"]?.stringValue ?? ""
        sessionID = params["session_id"]?.scalarString
        seq = params["seq"]?.int64Value
        payload = params["payload"]?.objectValue ?? [:]
    }
}

/// The first event of every connection: the gateway is ready and says what it offers.
public struct GatewayReady: Sendable, Equatable {
    /// Identifies the replay window; a client that saw another epoch may have missed events.
    public let replayEpoch: String?
    /// The gateway owns the sessions (`session_authority`), which changes what the REST routes do.
    public let sessionAuthority: Bool
    /// The gateway answers `gateway.ping`, so the client keeps a heartbeat of its own.
    public let heartbeat: Bool

    public init(payload: [String: JSONValue]) {
        replayEpoch = payload["replay_epoch"]?.scalarString
        sessionAuthority = payload["session_authority"]?.boolValue ?? false
        heartbeat = payload["heartbeat"]?.boolValue ?? false
    }
}
