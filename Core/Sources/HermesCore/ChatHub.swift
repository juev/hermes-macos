import Foundation

/// The one listener of the socket, and the chats it feeds.
///
/// A gateway speaks of many sessions on one connection, and a window may hold more than one at a
/// time: the chat on screen, and a chat left while its turn still runs. Each `ChatSession` registers
/// under the id the gateway gave it, and the hub hands every event and every question to the one it
/// belongs to. Without it, the last chat to join would take every event and the others would go quiet.
public actor ChatHub {
    private let gateway: GatewaySession
    private var chats: [String: ChatSession] = [:]
    private var listening = false

    public init(gateway: GatewaySession) {
        self.gateway = gateway
    }

    /// How many chats are registered: the one on screen and the ones left running.
    public var joinedChats: Int { chats.count }

    func register(_ chat: ChatSession, liveID: String) async {
        chats[liveID] = chat
        guard !listening else { return }
        listening = true
        await gateway.setHandlers(
            onEvent: { [weak self] event in
                guard let self else { return }
                Task { await self.dispatch(event) }
            },
            onRequest: { [weak self] request in
                guard let self else { return }
                Task { await self.dispatch(request) }
            }
        )
    }

    func unregister(liveID: String) {
        chats[liveID] = nil
    }

    private func dispatch(_ event: GatewayEvent) async {
        guard let session = event.sessionID, let chat = chats[session] else { return }
        await chat.receive(event)
    }

    private func dispatch(_ request: ServerRequest) async {
        guard let session = request.params["session_id"]?.scalarString, let chat = chats[session] else {
            // A question of a session that no chat holds is refused at once: the agent must not wait
            // for an answer that would never come.
            await gateway.refuse(request, reason: "No chat of this client holds that session")
            return
        }
        await chat.receive(request)
    }
}
