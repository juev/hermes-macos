import Foundation
import Testing
@testable import HermesCore

@Suite("A chat read by days")
struct TranscriptDaysTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func item(_ key: String, _ at: Date?) -> ChatItem {
        .user(UserBubble(key: key, text: key, timestamp: at))
    }

    @Test("A day opens once, in front of its first item")
    func grouping() {
        let items = [
            item("a", day(2026, 10, 29, 22)),
            item("b", day(2026, 10, 29, 23)),
            item("c", day(2026, 10, 30, 9)),
            item("d", day(2026, 10, 30, 10))
        ]
        let entries = TranscriptDays.group(items, calendar: calendar)
        #expect(entries.count == 4)
        #expect(entries[0].day == day(2026, 10, 29, 0))
        #expect(entries[1].day == nil)
        #expect(entries[2].day == day(2026, 10, 30, 0))
        #expect(entries[3].day == nil)
    }

    @Test("An item with no time keeps the day it is in")
    func untimed() {
        let items = [item("a", day(2026, 10, 29, 22)), item("b", nil), item("c", day(2026, 10, 30, 9))]
        let entries = TranscriptDays.group(items, calendar: calendar)
        #expect(entries[1].day == nil)
        #expect(entries[2].day == day(2026, 10, 30, 0))
    }

    @Test("The words of a separator")
    func labels() {
        let now = day(2026, 10, 30, 12)
        #expect(TranscriptDays.label(for: day(2026, 10, 30, 1), now: now, calendar: calendar) == "Today")
        #expect(TranscriptDays.label(for: day(2026, 10, 29, 1), now: now, calendar: calendar) == "Yesterday")
        let older = TranscriptDays.label(for: day(2026, 9, 27, 1), now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(older.contains("27"))
        #expect(!older.isEmpty)
        // A date of another year says which.
        let lastYear = TranscriptDays.label(for: day(2025, 9, 27, 1), now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(lastYear.contains("2025"))
    }
}
