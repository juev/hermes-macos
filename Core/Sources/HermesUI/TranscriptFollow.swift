import CoreGraphics

/// Where the transcript stands relative to the end of the chat, and what the view should do when the
/// end moves. A frame at a time, so the decision can be made — and tested — without a window: the
/// view measures two frames and asks what to do with them.
///
/// The end of a transcript moves for two reasons, and they must not be confused. The content grew
/// under a person who was reading its end, which is a scroll to follow; or the person moved the
/// viewport away from the end, which is the one case where the view stays where it was put.
/// Reading a growing transcript as "the person scrolled away" is what leaves a chat one message
/// behind: the frame measured right after an append is short of an end that has just been pushed
/// down, and a follow state set from that frame refuses every later scroll.
public struct TranscriptFollow: Sendable, Equatable {
    /// What a scroll view measured at one moment.
    public struct Frame: Sendable, Equatable {
        public var offset: CGFloat
        public var contentHeight: CGFloat
        public var viewportHeight: CGFloat

        public init(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
            self.offset = offset
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
        }

        /// True when the end of the chat is in view, give or take a rounding.
        public var isAtEnd: Bool {
            offset + viewportHeight >= contentHeight - TranscriptFollow.endSlack
        }
    }

    public enum Next: Sendable, Equatable {
        /// The view can stay as it is.
        case nothing
        /// The end of the chat moved and the person is still with it: put the end back in view.
        case showEnd
    }

    /// A row that measures a point differently is not the content moving.
    public static let tolerance: CGFloat = 1
    /// How far above the end still counts as being at it: a person who stopped on the last line is
    /// reading the end, not the history.
    public static let endSlack: CGFloat = 80

    /// The person is with the end of the chat: the view keeps the end in view as the chat grows.
    public private(set) var isFollowing: Bool

    public init(isFollowing: Bool = true) {
        self.isFollowing = isFollowing
    }

    /// One measurement of the scroll view, replacing the one before it.
    ///
    /// `personIsScrolling` is the scroll view's own phase, and it is the only certain word on who
    /// moved the viewport: a scrolling phase is the person, and a growth or a programmatic scroll
    /// is not.
    public mutating func changed(from old: Frame, to new: Frame, personIsScrolling: Bool = false) -> Next {
        if personIsScrolling {
            // Their hand is on it: only where they put it says where they want to be.
            isFollowing = new.isAtEnd
            return .nothing
        }

        let grew = new.contentHeight > old.contentHeight + Self.tolerance
        let squeezed = new.viewportHeight < old.viewportHeight - Self.tolerance
        let moved = abs(new.offset - old.offset) > Self.tolerance

        if isFollowing, grew || squeezed {
            // The end moved under somebody who was with it — a message arrived, a row above became
            // taller, the composer took a line. The layout that moved it has been made, so the new
            // end can be put in view now instead of a frame too early, which lands nowhere.
            return .showEnd
        }
        if new.isAtEnd {
            isFollowing = true
        } else if moved, !grew {
            // The viewport moved while the content stood still: the person is reading the history.
            isFollowing = false
        }
        return .nothing
    }

    /// The person wrote a message. It is theirs, so it comes into view even from the middle of the
    /// history — and it is the line the answer will be read from.
    public mutating func sent() {
        isFollowing = true
    }

    /// The end was asked for — a chat opened, or the person pressed the way back to it.
    public mutating func showEnd() {
        isFollowing = true
    }
}
