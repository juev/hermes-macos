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

    // MARK: - The runs of one cron job

    private func run(
        _ id: String, title: String, at: Date, source: String = "cron", unread: Bool = false
    ) -> SessionSummary {
        SessionSummary(id: id, title: title, source: source, lastActive: at, unread: unread)
    }

    @Test("Three runs of one job read as one row led by the newest")
    func foldedJob() {
        let now = day(2026, 11, 1)
        let rows = Sidebar.sections(
            [
                run("r1", title: "nightly · Nov 01 06:00", at: day(2026, 11, 1, 6)),
                run("r3", title: "nightly · Nov 01 18:00", at: day(2026, 11, 1, 18)),
                run("r2", title: "nightly · Nov 01 12:00", at: day(2026, 11, 1, 12))
            ],
            now: now, calendar: calendar
        ).first?.rows ?? []

        #expect(rows.count == 1)
        #expect(rows.first?.chat.id == "r3")
        #expect(rows.first?.runs.map(\.id) == ["r2", "r1"])
        #expect(rows.first?.count == 3)
        #expect(rows.first?.folded == true)
        #expect(rows.first?.label == "nightly")
    }

    @Test("A job with one run is an ordinary row")
    func singleRun() {
        let rows = Sidebar.sections(
            [run("r1", title: "nightly · Nov 01 06:00", at: day(2026, 11, 1, 6))],
            now: day(2026, 11, 1), calendar: calendar
        ).first?.rows ?? []

        #expect(rows.count == 1)
        #expect(rows.first?.folded == false)
        #expect(rows.first?.count == 1)
        #expect(rows.first?.label == "nightly · Nov 01 06:00")
    }

    @Test("Runs on either side of a date heading stay apart")
    func dayBoundary() {
        let sections = Sidebar.sections(
            [
                run("today", title: "nightly · Nov 01 06:00", at: day(2026, 11, 1, 6)),
                run("yesterday", title: "nightly · Oct 31 23:00", at: day(2026, 10, 31, 23))
            ],
            now: day(2026, 11, 1), calendar: calendar
        )

        #expect(sections.map(\.group) == [.today, .yesterday])
        #expect(sections.allSatisfy { $0.rows.allSatisfy { !$0.folded } })
    }

    @Test("A chat of another source is never folded")
    func otherSource() {
        let rows = Sidebar.sections(
            [
                run("t2", title: "nightly · Nov 01 12:00", at: day(2026, 11, 1, 12), source: "telegram"),
                run("t1", title: "nightly · Nov 01 06:00", at: day(2026, 11, 1, 6), source: "telegram")
            ],
            now: day(2026, 11, 1), calendar: calendar
        ).first?.rows ?? []

        #expect(rows.map(\.chat.id) == ["t2", "t1"])
        #expect(rows.allSatisfy { !$0.folded })
    }

    @Test("A run renamed by hand stays its own row")
    func renamedRun() {
        let rows = Sidebar.sections(
            [
                run("renamed", title: "nightly", at: day(2026, 11, 1, 18)),
                run("r2", title: "nightly · Nov 01 12:00", at: day(2026, 11, 1, 12)),
                run("r1", title: "nightly · Nov 01 06:00", at: day(2026, 11, 1, 6))
            ],
            now: day(2026, 11, 1), calendar: calendar
        ).first?.rows ?? []

        #expect(rows.map(\.chat.id) == ["renamed", "r2"])
        #expect(rows.map(\.count) == [1, 2])
    }

    @Test("The fallback titles of one job fold together")
    func fallbackTitles() {
        let rows = Sidebar.sections(
            [
                run("other", title: "cron 0f0f0f0f0f0f 9f8e7d", at: day(2026, 11, 1, 18)),
                run("r2", title: "cron 1a2b3c4d5e6f 9f8e7d", at: day(2026, 11, 1, 12)),
                run("r1", title: "cron 1a2b3c4d5e6f", at: day(2026, 11, 1, 6))
            ],
            now: day(2026, 11, 1), calendar: calendar
        ).first?.rows ?? []

        #expect(rows.map(\.chat.id) == ["other", "r2"])
        #expect(rows.map(\.count) == [1, 2])
        #expect(Sidebar.cronJobKey(run("r2", title: "cron 1a2b3c4d5e6f 9f8e7d", at: day(2026, 11, 1))) == "cron 1a2b3c4d5e6f")
    }

    @Test("Jobs whose names share a prefix stay apart")
    func sharedPrefix() {
        let rows = Sidebar.sections(
            [
                run("b", title: "nightly-report · Nov 01 12:00", at: day(2026, 11, 1, 12)),
                run("a", title: "nightly · Nov 01 06:00", at: day(2026, 11, 1, 6))
            ],
            now: day(2026, 11, 1), calendar: calendar
        ).first?.rows ?? []

        #expect(rows.map(\.chat.id) == ["b", "a"])
        #expect(rows.allSatisfy { !$0.folded })
    }

    @Test("A month printed in another language still folds")
    func localizedMonth() {
        let rows = Sidebar.sections(
            [
                run("r2", title: "nightly · ноя 01 12:00", at: day(2026, 11, 1, 12)),
                run("r1", title: "nightly · ноя 01 06:00", at: day(2026, 11, 1, 6))
            ],
            now: day(2026, 11, 1), calendar: calendar
        ).first?.rows ?? []

        #expect(rows.count == 1)
        #expect(rows.first?.count == 2)
    }

    @Test("A title that is only a stamp names no job")
    func stampOnly() {
        #expect(Sidebar.cronJobKey(run("x", title: " · Nov 01 06:00", at: day(2026, 11, 1))) == nil)
    }

    @Test("An unread run marks the folded row unread")
    func unreadRun() {
        let rows = Sidebar.sections(
            [
                run("r2", title: "nightly · Nov 01 12:00", at: day(2026, 11, 1, 12)),
                run("r1", title: "nightly · Nov 01 06:00", at: day(2026, 11, 1, 6), unread: true)
            ],
            now: day(2026, 11, 1), calendar: calendar
        ).first?.rows ?? []

        #expect(rows.first?.unread == true)
    }
}
