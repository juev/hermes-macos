import HermesCore

/// A chat that is not on screen but still runs: it keeps just enough of the turn to say how it ended.
@MainActor
final class ChatWatcher {
    private var items: [ChatItem] = []

    func apply(_ event: GatewayEvent) {
        items = LiveTurn.apply(event, to: items)
    }

    var text: String {
        if case .assistant(let turn)? = items.last { return turn.text }
        return ""
    }
}
