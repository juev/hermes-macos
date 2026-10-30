import Foundation
import HermesUI
import Testing


@Suite("A table in an answer")
struct MarkdownTableTests {
    private let answer = """
    На момент проверки нагрузка невысокая.

    | Сервер | Load average | CPU | Доступно RAM |
    |---|:---:|---:|---:|
    | loffe | 0.42 | 3% | 47 GB |
    | ams | 0.11 | 1% | 3,8 GB |
    | moscow | 1.08 | 12% | 900 MB |

    Дальше — обычный текст.
    """

    @Test("The header, the rows and where the numbers sit")
    func parse() throws {
        let blocks = Markdown.blocks(answer)
        guard case .table = blocks[blocks.count - 2].kind else {
            Issue.record("the table is not a table: \(blocks.map(\.kind))")
            return
        }
        let table = blocks[blocks.count - 2]
        #expect(table.rows.count == 4)
        #expect(table.rows[0] == ["Сервер", "Load average", "CPU", "Доступно RAM"])
        #expect(table.rows[1][0] == "loffe")
        #expect(table.alignments[0] == .leading)
        #expect(table.alignments[1] == .center)
        #expect(table.alignments[2] == .trailing)
        #expect(table.alignments[3] == .trailing)
    }

    @Test("The text around the table stays text")
    func around() {
        let blocks = Markdown.blocks(answer)
        #expect(blocks.first?.kind == .paragraph)
        #expect(blocks.last?.kind == .paragraph)
        #expect(blocks.last?.text == "Дальше — обычный текст.")
    }

    @Test("A pipe in a paragraph is not a table")
    func notATable() {
        let blocks = Markdown.blocks("Выбор один: `a | b` — или нет.")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }
}
