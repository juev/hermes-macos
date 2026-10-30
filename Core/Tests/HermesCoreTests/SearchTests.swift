import Foundation
import Testing
@testable import HermesCore

@Suite("Search over the chats", .enabled(if: Fixtures.available))
struct SearchTests {
    @Test("The results the dashboard answered")
    func results() throws {
        guard let json = Fixtures.json("search", "results") else {
            Issue.record("The contract payloads are missing: run scripts/sync-fixtures.sh")
            return
        }
        let hits = SearchHit.page(json)
        #expect(hits.count == 5)

        let first = try #require(hits.first)
        #expect(first.role == "tool")
        #expect(!first.session.id.isEmpty)
        #expect(first.session.source == "matrix")
        #expect(first.session.model == "deepseek-flash")
        // A hit carries no pinned and no unread, unlike the list of chats.
        #expect(!first.session.pinned)
        #expect(!first.session.unread)
        #expect(!first.snippet.isEmpty)
        #expect(first.session.messageCount > 0)
    }

    @Test("A snippet is folded to one line")
    func oneLine() {
        let hit = SearchHit(
            session: SessionSummary(id: "s"),
            snippet: "...command not found\n---\n#!/bin/sh\n# Hermes wrapper",
            role: "tool"
        )
        #expect(hit.oneLine == "...command not found --- #!/bin/sh # Hermes wrapper")
    }

    @Test("A result without a session is dropped")
    func noSession() {
        #expect(SearchHit(["snippet": "x"]) == nil)
        #expect(SearchHit(["session_id": "s-1", "snippet": "x"])?.session.id == "s-1")
    }
}
