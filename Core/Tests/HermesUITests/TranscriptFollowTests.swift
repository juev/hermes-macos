import CoreGraphics
import Testing
@testable import HermesUI

/// What the transcript does when the chat grows under it. The window cannot be opened from a test,
/// but the decision is a frame and a bool, so the cases that were wrong are decided here.
@Suite("The transcript and its end")
struct TranscriptFollowTests {
    /// A chat with a page of text in it, scrolled to the end.
    static let atEnd = TranscriptFollow.Frame(offset: 900, contentHeight: 1_500, viewportHeight: 600)
    /// The same chat with the person reading a page up.
    static let inHistory = TranscriptFollow.Frame(offset: 300, contentHeight: 1_500, viewportHeight: 600)

    @Test("A chat opens with the end in view")
    func opensAtTheEnd() {
        let follow = TranscriptFollow()
        #expect(follow.isFollowing)
        #expect(Self.atEnd.isAtEnd)
        #expect(!Self.inHistory.isAtEnd)
    }

    @Test("A message appended at the end is scrolled to")
    func appendedMessageIsShown() {
        var follow = TranscriptFollow()
        let before = Self.atEnd
        // The person's message, then the answer: neither changes the offset by itself, and both
        // push the end of the chat down.
        let after = TranscriptFollow.Frame(offset: before.offset, contentHeight: 1_640, viewportHeight: 600)
        #expect(follow.changed(from: before, to: after) == .showEnd)
        #expect(follow.isFollowing)
    }

    @Test("The end is still followed when the append is smaller than the slack")
    func smallAppendIsShown() {
        var follow = TranscriptFollow()
        let before = Self.atEnd
        // A one-line bubble is 46 points: the old frame is still "at the end" by the slack, which is
        // why a follow state read from it looked fine while the new message sat below the fold.
        let after = TranscriptFollow.Frame(offset: before.offset, contentHeight: 1_546, viewportHeight: 600)
        #expect(after.isAtEnd)
        #expect(follow.changed(from: before, to: after) == .showEnd)
    }

    @Test("A transcript that grows while somebody reads the history is left alone")
    func historyIsNotInterrupted() {
        var follow = TranscriptFollow()
        var frame = Self.inHistory
        #expect(follow.changed(from: Self.atEnd, to: frame, personIsScrolling: true) == .nothing)
        #expect(!follow.isFollowing)

        // A streaming answer arrives while they read: the view must not be pulled away.
        let grown = TranscriptFollow.Frame(offset: frame.offset, contentHeight: 1_700, viewportHeight: 600)
        #expect(follow.changed(from: frame, to: grown) == .nothing)
        #expect(!follow.isFollowing)

        for height in stride(from: 1_760.0, through: 2_100, by: 40) {
            let next = TranscriptFollow.Frame(offset: frame.offset, contentHeight: height, viewportHeight: 600)
            #expect(follow.changed(from: frame, to: next) == .nothing)
            frame = next
        }
        #expect(!follow.isFollowing)
    }

    @Test("Scrolling up from the end stops the following")
    func scrollingUpStopsFollowing() {
        var follow = TranscriptFollow()
        var frame = Self.atEnd
        for offset in [760.0, 640.0, 300.0] {
            let next = TranscriptFollow.Frame(offset: offset, contentHeight: frame.contentHeight, viewportHeight: 600)
            #expect(follow.changed(from: frame, to: next, personIsScrolling: true) == .nothing)
            frame = next
        }
        #expect(!follow.isFollowing)
    }

    @Test("Scrolling back to the end starts it again")
    func scrollingBackFollows() {
        var follow = TranscriptFollow(isFollowing: false)
        var frame = Self.inHistory
        for offset in [600.0, 900.0] {
            let next = TranscriptFollow.Frame(offset: offset, contentHeight: frame.contentHeight, viewportHeight: 600)
            _ = follow.changed(from: frame, to: next, personIsScrolling: true)
            frame = next
        }
        #expect(follow.isFollowing)
    }

    @Test("The person's own message comes into view from the middle of the history")
    func ownMessageIsShownFromAnywhere() {
        var follow = TranscriptFollow(isFollowing: false)
        follow.sent()
        #expect(follow.isFollowing)
        let after = TranscriptFollow.Frame(offset: Self.inHistory.offset, contentHeight: 1_746, viewportHeight: 600)
        #expect(follow.changed(from: Self.inHistory, to: after) == .showEnd)
    }

    @Test("A scroll of the view's own making is not read as the person leaving")
    func ownScrollKeepsFollowing() {
        var follow = TranscriptFollow()
        // showEnd puts the end in view; the scroll that follows moves the offset, and the frame it
        // lands on is the end of the chat.
        follow.showEnd()
        let landing = TranscriptFollow.Frame(offset: 1_100, contentHeight: 1_700, viewportHeight: 600)
        #expect(follow.changed(from: TranscriptFollow.Frame(offset: 900, contentHeight: 1_700, viewportHeight: 600), to: landing) == .nothing)
        #expect(follow.isFollowing)
    }

    @Test("A composer that takes a line keeps the end in view")
    func composerGrowthKeepsTheEnd() {
        var follow = TranscriptFollow()
        let before = Self.atEnd
        let squeezed = TranscriptFollow.Frame(offset: before.offset, contentHeight: before.contentHeight, viewportHeight: 580)
        #expect(follow.changed(from: before, to: squeezed) == .showEnd)
        #expect(follow.isFollowing)
    }

    @Test("A window that grows needs no scroll")
    func biggerWindowDoesNothing() {
        var follow = TranscriptFollow()
        let before = Self.atEnd
        let taller = TranscriptFollow.Frame(offset: before.offset, contentHeight: before.contentHeight, viewportHeight: 900)
        #expect(follow.changed(from: before, to: taller) == .nothing)
        #expect(follow.isFollowing)
    }

    @Test("A rewrite with the same height is not a scroll")
    func sameHeightDoesNothing() {
        var follow = TranscriptFollow(isFollowing: false)
        let before = Self.inHistory
        let same = TranscriptFollow.Frame(offset: before.offset, contentHeight: before.contentHeight, viewportHeight: before.viewportHeight)
        #expect(follow.changed(from: before, to: same) == .nothing)
        #expect(!follow.isFollowing)
    }

    @Test("A chat shorter than the window is at its end")
    func shortChatIsAtTheEnd() {
        let short = TranscriptFollow.Frame(offset: 0, contentHeight: 200, viewportHeight: 600)
        #expect(short.isAtEnd)
    }
}
