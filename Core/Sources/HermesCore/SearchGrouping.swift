import Foundation

/// A search over a dashboard finds messages; a sidebar is a list of chats. One row per chat, with the
/// best match of that chat under it, is what a person looking for a conversation can use.
public struct ChatMatch: Sendable, Equatable, Identifiable {
    public let chat: SessionSummary
    /// The match shown under the chat: the first one the dashboard ranked.
    public let best: SearchHit
    /// How many messages of this chat matched.
    public let matches: Int

    public var id: String { chat.id }

    public init(chat: SessionSummary, best: SearchHit, matches: Int) {
        self.chat = chat
        self.best = best
        self.matches = matches
    }
}

public enum SearchGrouping {
    /// The hits folded by chat, in the order the dashboard ranked them: the first hit of a chat decides
    /// where that chat stands, and the rest only raise its count.
    public static func byChat(_ hits: [SearchHit]) -> [ChatMatch] {
        var order: [String] = []
        var byChat: [String: [SearchHit]] = [:]
        for hit in hits {
            let id = hit.session.id
            if byChat[id] == nil { order.append(id) }
            byChat[id, default: []].append(hit)
        }
        return order.compactMap { id in
            guard let group = byChat[id], let best = group.first else { return nil }
            return ChatMatch(chat: best.session, best: best, matches: group.count)
        }
    }
}
