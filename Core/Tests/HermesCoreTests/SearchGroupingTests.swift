import Foundation
import Testing
@testable import HermesCore

@Suite("Search results read as chats")
struct SearchGroupingTests {
    private func hit(_ session: String, _ snippet: String, title: String? = nil) -> SearchHit {
        SearchHit(session: SessionSummary(id: session, title: title ?? session), snippet: snippet, role: "assistant")
    }

    @Test("One row per chat, in the order the dashboard ranked them")
    func collapse() {
        let matches = SearchGrouping.byChat([
            hit("a", "third"),
            hit("b", "first"),
            hit("a", "second")
        ])
        #expect(matches.map(\.id) == ["a", "b"])
        #expect(matches[0].matches == 2)
        #expect(matches[0].best.snippet == "third")
        #expect(matches[1].matches == 1)
    }

    @Test("No hits, no rows")
    func empty() {
        #expect(SearchGrouping.byChat([]).isEmpty)
    }
}
