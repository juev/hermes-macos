import SwiftUI
import Testing
@testable import HermesUI

@Suite("Markdown in an answer")
struct MarkdownTests {
    @Test("The blocks of an answer")
    func blocks() {
        let text = """
        Первый абзац,
        во второй строке.

        ## Заголовок

        - один
        - два

        1. шаг
        2) ещё шаг

        ```sh
        swift build
        echo done
        ```

        > цитата

        ---
        """
        let blocks = Markdown.blocks(text)
        #expect(blocks.count == 9)
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[0].text == "Первый абзац,\nво второй строке.")
        #expect(blocks[1].kind == .heading(level: 2))
        #expect(blocks[2].kind == .listItem(ordered: false, index: 0))
        #expect(blocks[3].kind == .listItem(ordered: false, index: 0))
        #expect(blocks[4].kind == .listItem(ordered: true, index: 1))
        #expect(blocks[5].kind == .listItem(ordered: true, index: 2))
        #expect(blocks[6].kind == .code(language: "sh"))
        #expect(blocks[6].text == "swift build\necho done")
        #expect(blocks[7].kind == .quote)
        #expect(blocks[8].kind == .rule)
    }

    @Test("A fence that is never closed still becomes a block")
    func openFence() {
        let blocks = Markdown.blocks("before\n\n```\nlet x = 1")
        #expect(blocks.count == 2)
        #expect(blocks[1].kind == .code(language: nil))
        #expect(blocks[1].text == "let x = 1")
    }

    @Test("A line that only looks like a list keeps its text")
    func notAList() {
        let blocks = Markdown.blocks("2026.09.24 — дата релиза")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }

    @Test("Inline markup survives, and a code span is marked as one")
    func inline() {
        let attributed = Markdown.inline("Это **жирно**, *курсив* и `swift build`.")
        let runs = Array(attributed.runs)
        #expect(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(String(attributed.characters).contains("swift build"))
    }

    @Test("Text that is not markdown is still text")
    func plain() {
        let attributed = Markdown.inline("Просто строка без разметки")
        #expect(String(attributed.characters) == "Просто строка без разметки")
    }
}
