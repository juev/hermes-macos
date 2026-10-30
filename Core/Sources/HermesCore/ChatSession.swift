import Foundation

/// A file the person picked to send with the next message, before it is attached.
public struct AttachmentDraft: Sendable, Equatable, Identifiable {
    public let name: String
    public let mime: String
    public let data: Data
    /// Beyond this a message is a transfer, not a chat; the dashboard's own limit is unknown.
    public static let largestByteCount = 25 * 1_024 * 1_024

    public var id: String { name + "\(data.count)" }
    public var isImage: Bool { mime.hasPrefix("image/") }
    public var byteCount: Int { data.count }

    public init(name: String, mime: String, data: Data) {
        self.name = name
        self.mime = mime
        self.data = data
    }
}

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
    private let hub: ChatHub?
    private var liveID: String?
    private var sink: (@Sendable (GatewayEvent) -> Void)?
    private var questions: (@Sendable (AgentQuestion) -> Void)?
    private var pending: [String: ServerRequest] = [:]

    /// A chat whose events come straight from the session, for one chat at a time.
    public init(gateway: GatewaySession) {
        self.gateway = gateway
        self.hub = nil
    }

    /// A chat registered with [hub], so more than one can be open at once and each gets its own events.
    public init(gateway: GatewaySession, hub: ChatHub) {
        self.gateway = gateway
        self.hub = hub
    }

    /// Who hears the events of this chat. Events of other sessions are not passed on.
    public func setEventSink(_ sink: (@Sendable (GatewayEvent) -> Void)?) {
        self.sink = sink
    }

    /// Who hears the questions of this chat: an approval, a choice, a secret. A question this client
    /// does not answer is refused at once, so the agent does not wait for it.
    public func setQuestionSink(_ sink: (@Sendable (AgentQuestion) -> Void)?) {
        self.questions = sink
    }

    /// Answers a question the gateway asked. The request is kept until it is answered.
    public func answer(_ question: AgentQuestion, with result: JSONValue) async {
        guard let request = pending.removeValue(forKey: question.id) else { return }
        await gateway.respond(to: request, result: result)
    }

    /// Refuses a question — a cancelled prompt, or a secret the person would not type.
    public func refuse(_ question: AgentQuestion, reason: String = "cancelled") async {
        guard let request = pending.removeValue(forKey: question.id) else { return }
        await gateway.refuse(request, reason: reason)
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
        await listen()

        let info = answer["info"]
        return Joined(
            liveID: live,
            storedID: answer["stored_session_id"]?.scalarString ?? storedID,
            running: answer["running"]?.flag ?? info?["running"]?.flag ?? false,
            model: info?["model"]?.stringValue ?? answer["model"]?.stringValue,
            streamed: answer["inflight"]?["assistant"]?.stringValue ?? ""
        )
    }

    /// Attaches a file to the next turn. A picture goes to the vision queue of that turn and needs no
    /// reference in the prompt; any other file answers with the text that names it, which the prompt
    /// has to carry.
    public func attach(_ draft: AttachmentDraft) async throws -> String? {
        guard let liveID else { throw ChatError.notConnected }
        let encoded = draft.data.base64EncodedString()
        if draft.isImage {
            _ = try await gateway.call("image.attach_bytes", params: [
                "session_id": .string(liveID),
                "content_base64": .string(encoded),
                "filename": .string(draft.name)
            ], timeout: .seconds(120))
            return nil
        }
        let answer = try await gateway.call("file.attach", params: [
            "session_id": .string(liveID),
            "data_url": .string("data:\(draft.mime);base64,\(encoded)"),
            "name": .string(draft.name)
        ], timeout: .seconds(120))
        return answer["ref_text"]?.stringValue
    }

    /// Starts a new chat and keeps it as this session. The dashboard names it from the first message,
    /// so a client that wants it in the sidebar afterwards asks for the list again.
    @discardableResult
    public func create(source: String = "macos") async throws -> String {
        let answer = try await gateway.call("session.create", params: [
            "source": .string(source),
            "close_on_disconnect": false
        ])
        guard let live = answer["session_id"]?.scalarString, !live.isEmpty else {
            throw ChatError.noLiveSession
        }
        liveID = live
        await listen()
        return live
    }

    /// Sends a prompt into the live session.
    public func submit(_ text: String) async throws {
        guard let liveID else { throw ChatError.notConnected }
        _ = try await gateway.call("prompt.submit", params: [
            "session_id": .string(liveID),
            "text": .string(text)
        ])
    }

    /// Gives the chat another name. The dashboard titles a chat by its start until one is given.
    public func rename(_ title: String) async throws {
        guard let liveID else { throw ChatError.notConnected }
        _ = try await gateway.call("session.title", params: [
            "session_id": .string(liveID),
            "title": .string(title)
        ])
    }

    /// Asks for the last turn again: the dashboard drops it, and the prompt that asked for it goes
    /// in once more (`session.undo` with `intent: retry`).
    public func retry() async throws {
        guard let liveID else { throw ChatError.notConnected }
        _ = try await gateway.call("session.undo", params: [
            "session_id": .string(liveID),
            "intent": "retry"
        ])
    }

    /// Asks the dashboard to answer this chat on another model. A running turn keeps the old one, and
    /// an expensive model is asked for twice — once to hear that it is expensive.
    public func setModel(provider: String, model: String, confirmed: Bool = false) async throws -> ModelChange {
        guard let liveID else { throw ChatError.notConnected }
        var params: [String: JSONValue] = [
            "session_id": .string(liveID),
            "key": "model",
            "value": .string("\(model) --provider \(provider)")
        ]
        if confirmed { params["confirm_expensive_model"] = true }
        let answer = try await gateway.call("config.set", params: params)
        if answer["confirm_required"]?.boolValue == true {
            return .needsConfirmation(message: answer["confirm_message"]?.stringValue ?? "This model costs more than the one in use.")
        }
        if answer["deferred"]?.boolValue == true {
            return .deferred(warning: answer["warning"]?.stringValue)
        }
        return .set
    }

    /// Stops the turn under way.
    public func interrupt() async throws {
        guard let liveID else { throw ChatError.notConnected }
        _ = try await gateway.call("session.interrupt", params: ["session_id": .string(liveID)])
    }

    /// Lets the live session go, so the gateway does not hold it for a client that closed the chat.
    public func leave() async {
        guard let liveID else { return }
        if let hub {
            await hub.unregister(liveID: liveID)
        } else {
            await gateway.setHandlers(onEvent: nil, onRequest: nil)
        }
        self.liveID = nil
        _ = try? await gateway.call("session.close", params: ["session_id": .string(liveID)])
    }

    /// Who hears this chat's events and questions: the hub when there is one, the session alone otherwise.
    private func listen() async {
        if let hub, let liveID {
            await hub.register(self, liveID: liveID)
            return
        }
        await gateway.setHandlers(
            onEvent: { [weak self] event in
                guard let self else { return }
                Task { await self.receive(event) }
            },
            onRequest: { [weak self] request in
                guard let self else { return }
                Task { await self.receive(request) }
            }
        )
    }

    func receive(_ event: GatewayEvent) {
        guard let liveID, event.sessionID == liveID else { return }
        sink?(event)
    }

    func receive(_ request: ServerRequest) {
        // A question of another chat is not this chat's to answer.
        if let session = request.params["session_id"]?.scalarString, session != liveID { return }
        guard let question = AgentQuestion(request) else {
            Task { await gateway.refuse(request, reason: "This client does not answer that question") }
            return
        }
        pending[question.id] = request
        questions?(question)
    }
}
