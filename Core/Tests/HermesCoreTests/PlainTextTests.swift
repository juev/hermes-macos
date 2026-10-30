import Testing
@testable import HermesCore

/// The same cases the Android client's `PlainTextTest` holds.
@Suite("Markdown as the words alone")
struct PlainTextTests {
    @Test("Emphasis, code and links keep only their words")
    func inline() {
        let text = "**Готово**: *почти* всё, ~~кроме~~ `make test` и [отчёта](https://example.org/r)."
        #expect(PlainText.of(text) == "Готово: почти всё, кроме make test и отчёта.")
    }

    @Test("Headings, quotes and lists lose their markers")
    func blocks() {
        let text = "## Итог\n\n> важно\n\n- один\n- [x] два\n1. три"
        #expect(PlainText.of(text) == "Итог\n\nважно\n\n• один\n• два\n1. три")
    }

    @Test("Code fences go, the code stays")
    func fences() {
        #expect(PlainText.of("Запусти:\n```bash\nmake test\n```") == "Запусти:\nmake test")
    }

    @Test("A table becomes rows of cells")
    func table() {
        let text = "| Хост | Диск |\n|---|:---:|\n| loffe | 34% |"
        #expect(PlainText.of(text) == "Хост · Диск\nloffe · 34%")
    }

    @Test("Rules and extra blank lines are dropped")
    func rules() {
        #expect(PlainText.of("один\n\n---\n\n\n\nдва") == "один\n\nдва")
    }

    @Test("Identifiers and arithmetic are not emphasis")
    func identifiers() {
        #expect(PlainText.of("snake_case_name и 2 * 3 * 4") == "snake_case_name и 2 * 3 * 4")
    }

    @Test("What is already words stays as it is")
    func plain() {
        #expect(PlainText.of("Просто строка") == "Просто строка")
        #expect(PlainText.of("") == "")
    }
}
