import Foundation

/// What a notification says about a finished turn: enough to know whether the answer is worth
/// switching back for, and not the answer itself.
public enum NotificationText {
    /// The most a banner body shows before it is cut.
    public static let previewLength = 180

    public static func title(chat: String) -> String {
        let trimmed = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Hermes" : trimmed
    }

    /// The first words of the answer on one line, cut at a word where it can be cut.
    public static func preview(_ answer: String) -> String {
        let folded = answer.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !folded.isEmpty else { return "The turn is finished." }
        guard folded.count > previewLength else { return folded }
        let cut = String(folded.prefix(previewLength))
        // A cut in the middle of a word reads as a mistake; back off to the last space.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > previewLength / 2 {
            return cut[..<space] + "…"
        }
        return cut + "…"
    }

    /// True when a finished turn deserves a banner: the person is looking elsewhere.
    public static func shouldNotify(appIsActive: Bool, runningTurnWasHere: Bool) -> Bool {
        // A turn that ends while the window is in front needs no banner — the answer is right there.
        !appIsActive || !runningTurnWasHere
    }
}
