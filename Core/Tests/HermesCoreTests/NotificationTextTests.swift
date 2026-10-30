import Testing
@testable import HermesCore

@Suite("What a finished turn says")
struct NotificationTextTests {
    @Test("A title falls back to the app name")
    func title() {
        #expect(NotificationText.title(chat: "  План релиза  ") == "План релиза")
        #expect(NotificationText.title(chat: "   ") == "Hermes")
    }

    @Test("A preview folds the answer onto one line")
    func preview() {
        #expect(NotificationText.preview("Готово.\n\nСборка зелёная.") == "Готово. Сборка зелёная.")
        #expect(NotificationText.preview("   ") == "The turn is finished.")
    }

    @Test("A long preview is cut at a word, not in one")
    func cutting() {
        let answer = String(repeating: "слово ", count: 100)
        let preview = NotificationText.preview(answer)
        #expect(preview.hasSuffix("…"))
        #expect(!preview.hasSuffix("слов…"))
        #expect(preview.count <= NotificationText.previewLength + 1)
    }

    @Test("A short answer is shown whole")
    func short() {
        let answer = "Готово"
        #expect(NotificationText.preview(answer) == answer)
    }

    @Test("A banner is for a person looking elsewhere")
    func when() {
        #expect(NotificationText.shouldNotify(appIsActive: false))
        #expect(!NotificationText.shouldNotify(appIsActive: true))
    }
}
