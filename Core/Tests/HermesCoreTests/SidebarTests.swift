import Foundation
import Testing
@testable import HermesCore

@Suite("The chats of a sidebar")
struct SidebarTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func chat(_ id: String, at: Date, pinned: Bool = false) -> SessionSummary {
        SessionSummary(id: id, title: id, lastActive: at, pinned: pinned)
    }

    @Test("Pinned first, then the dates")
    func sections() {
        let now = day(2026, 10, 30)
        let chats = [
            chat("old", at: day(2024, 3, 1)),
            chat("today", at: day(2026, 10, 30)),
            chat("pinned", at: day(2025, 1, 1), pinned: true),
            chat("yesterday", at: day(2026, 10, 29)),
            chat("week", at: day(2026, 10, 26)),
            chat("month", at: day(2026, 10, 10)),
            chat("september", at: day(2026, 9, 15))
        ]
        let sections = Sidebar.sections(chats, now: now, calendar: calendar)
        #expect(sections.map(\.group) == [.pinned, .today, .yesterday, .previousWeek, .previousMonth, .month(9), .year(2024)])
        #expect(sections[0].chats.map(\.id) == ["pinned"])
        #expect(sections[1].chats.map(\.id) == ["today"])
    }

    @Test("Newest first inside a group")
    func ordering() {
        let now = day(2026, 10, 30)
        let chats = [
            chat("a", at: day(2026, 10, 30, 9)),
            chat("b", at: day(2026, 10, 30, 18)),
            chat("c", at: day(2026, 10, 30, 12))
        ]
        let sections = Sidebar.sections(chats, now: now, calendar: calendar)
        #expect(sections.count == 1)
        #expect(sections[0].chats.map(\.id) == ["b", "c", "a"])
    }

    @Test("A chat with no time falls into this month, not into a year of its own")
    func untimed() {
        let now = day(2026, 10, 30)
        let sections = Sidebar.sections([SessionSummary(id: "x")], now: now, calendar: calendar)
        #expect(sections.map(\.group) == [.month(10)])
    }

    @Test("The words of a header")
    func titles() throws {
        let now = day(2026, 10, 30)
        #expect(Sidebar.title(for: .pinned, now: now, calendar: calendar) == "Pinned")
        #expect(Sidebar.title(for: .previousWeek, now: now, calendar: calendar) == "Previous 7 days")
        let september = Sidebar.title(for: .month(9), now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(september.lowercased().contains("september"))
        #expect(Sidebar.title(for: .year(2024), now: now, calendar: calendar) == "2024")
    }

    @Test("A local pin marks the chat without the dashboard knowing")
    func localPin() {
        let chat = SessionSummary(id: "x", title: "x")
        #expect(!chat.pinned)
        let pinned = chat.settingPinned(true)
        #expect(pinned.pinned)
        #expect(pinned.id == chat.id)
        #expect(pinned.title == chat.title)
    }
}
