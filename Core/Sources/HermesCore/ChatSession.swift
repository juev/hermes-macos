import Foundation

public enum ChatError: Error, Equatable {
    /// The dashboard answered a join without a live session.
    case noLiveSession
    /// The socket is not up, so there is nothing to send on.
    case notConnected
}

/// One chat as the gateway knows it while it is open: a live session joined from a stored one, the
/// prompt that goes into it, the stop that ends it, and the events that carry the answer.
public actor ChatSession {
    /// What a join answers: the live session, whether a turn already runs in it, and how much of that
    /// turn was written down before the chat opened.
    public struct Joined: Sendable, Equatable {
        public let liveID: String
        public let storedID: String?
        public let running: Bool
        public let model: String?
        /// What streamed before the join, so a turn in progress can be picked up where it is.
        public let streamed: String
    }

    private let gateway: GatewaySession
    private var liveID: String?
    private var sink: (@Sendable (GatewayEvent) -> Void)?

    public init(gateway: GatewaySession) {
        self.gateway = gateway
    }

    public func currentLiveID() -> String? { liveID }

    /// Who hears the events of this chat. Events of other sessions are not passed on.
    public func setEventSink(_ sink: (@Sendable (GatewayEvent) -> Void)?) {
        self.sink = sink
    }

    /// Joins the live session of a stored chat. A dashboard that does not host it answers with a new
    /// live one; either way the answer names it.
    public func join(storedID: String) async throws -> Joined {
        let answer = try await gateway.call("session.resume", params: [
            "session_id": .string(storedID),
            "close_on_disconnect": false,
            "omit_messages": true,
            "inline_images": false
        ], timeout: .seconds(120))

        guard let live = answer["session_id"]?.scalarString, !live.isEmpty else {
            throw ChatError.noLiveSession
        }
        liveID = live
        await gateway.setHandlers(onEvent: { [weak self] event in
            guard let self else { return }
            Task { await self.receive(event) }
        })

        let info = answer["info"]
        return Joined(
            liveID: live,
            storedID: answer["stored_session_id"]?.scalarString ?? storedID,
            running: answer["running"]?.flag ?? info?["running"]?.flag ?? false,
            model: info?["model"]?.stringValue ?? answer["model"]?.stringValue,
            streamed: answer["inflight"]?["assistant"]?.stringValue ?? ""
        )
    }

    /// Sends a prompt into the live session.
    public func submit(_ text: String) async throws {
        guard let liveID else { throw ChatError.notConnected }
        _ = try await gateway.call("prompt.submit", params: [
            "session_id": .string(liveID),
            "text": .string(text)
        ])
    }

    /// Stops the turn under way.
    public func interrupt() async throws {
        guard let liveID else { throw ChatError.notConnected }
        _ = try await gateway.call("session.interrupt", params: ["session_id": .string(liveID)])
    }

    /// Lets the live session go, so the gateway does not hold it for a client that closed the chat.
    public func leave() async {
        guard let liveID else { return }
        _ = try? await gateway.call("session.close", params: ["session_id": .string(liveID)])
        self.liveID = nil
        await gateway.setHandlers(onEvent: nil, onRequest: nil)
    }

    private func receive(_ event: GatewayEvent) {
        guard let liveID, event.sessionID == liveID else { return }
        sink?(event)
    }
}
