import Foundation

/// The chats of a dashboard, split the way a sidebar reads them: pinned first, then today, yesterday,
/// the last week and the last month, then by the month of this year, then by year.
public enum Sidebar {
    public enum Group: Sendable, Equatable, Hashable {
        case pinned
        case today
        case yesterday
        case previousWeek
        case previousMonth
        /// A month of the current year, 1 to 12.
        case month(Int)
        /// A year before this one.
        case year(Int)
    }

    /// One line of a section: a chat, or the runs of one cron job folded into the newest of them.
    ///
    /// The gateway keeps one session per firing of a job, titled `<job> · Nov 01 12:28`, and a list
    /// that draws sessions would show a firing per line. Telegram reads a job as one thread because
    /// the topic there is the job's delivery address, not a session; this is the same reading made of
    /// rows, keyed on the title the gateway wrote because a session carries no job field.
    public struct Row: Sendable, Equatable, Identifiable {
        /// The newest run of the job, or the chat itself.
        public let chat: SessionSummary
        /// The older runs of the same job, newest first; empty for anything that is not a folded row.
        public let runs: [SessionSummary]
        /// The job a folded row stands for, which is also the words the row shows.
        public let job: String?

        public var id: SessionSummary.ID { chat.id }
        public var count: Int { runs.count + 1 }
        public var folded: Bool { !runs.isEmpty }
        /// A folded row is named by its job: the newest run's own stamp would push the count out.
        public var label: String { job ?? chat.label }
        /// Any run of the job unread is the row unread.
        public var unread: Bool { chat.unread || runs.contains(where: \.unread) }

        public init(chat: SessionSummary, runs: [SessionSummary] = [], job: String? = nil) {
            self.chat = chat
            self.runs = runs
            self.job = job
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public let group: Group
        public let rows: [Row]

        public var id: Group { group }

        /// Every chat of the section, a folded job's runs in their place.
        public var chats: [SessionSummary] { rows.flatMap { [$0.chat] + $0.runs } }

        public init(group: Group, rows: [Row]) {
            self.group = group
            self.rows = rows
        }

        public init(group: Group, chats: [SessionSummary]) {
            self.init(group: group, rows: Sidebar.fold(chats))
        }
    }

    /// Newest activity first inside every group, and pinned chats apart from the dates they would
    /// otherwise fall into. The runs of one cron job inside a group fold into one row.
    public static func sections(
        _ chats: [SessionSummary],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        let sorted = chats.sorted { ($0.lastActive ?? $0.startedAt ?? .distantPast) > ($1.lastActive ?? $1.startedAt ?? .distantPast) }
        let pinned = sorted.filter(\.pinned)

        var order: [Group] = []
        var byGroup: [Group: [SessionSummary]] = [:]
        for chat in sorted where !chat.pinned {
            let group = self.group(for: chat, now: now, calendar: calendar)
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(chat)
        }

        var sections: [Section] = []
        if !pinned.isEmpty { sections.append(Section(group: .pinned, rows: fold(pinned))) }
        for group in order {
            sections.append(Section(group: group, rows: fold(byGroup[group] ?? [])))
        }
        return sections
    }

    /// Chats newest first in, rows out: each job's newest run stands where it was, its older runs behind it.
    static func fold(_ chats: [SessionSummary]) -> [Row] {
        var rows: [Row] = []
        var placed: [String: Int] = [:]
        for chat in chats {
            guard let job = cronJobKey(chat) else {
                rows.append(Row(chat: chat))
                continue
            }
            if let index = placed[job] {
                let row = rows[index]
                rows[index] = Row(chat: row.chat, runs: row.runs + [chat], job: job)
            } else {
                placed[job] = rows.count
                // A run on its own is an ordinary row, named by its own title until a second run
                // joins it and the row starts reading as the job.
                rows.append(Row(chat: chat))
            }
        }
        return rows
    }

    /// The gateway titles a run `<job name> · Nov 01 12:28`; `%b` may come out in another language.
    private static let stampPattern = try? NSRegularExpression(pattern: #"^(.*) · \p{L}{3} \d{1,2} \d{2}:\d{2}$"#)

    /// The fallback title of a run: `cron <job id>`, maybe with the end of the run id after it.
    private static let fallbackPattern = try? NSRegularExpression(pattern: #"^cron ([0-9a-fA-F]{6,})(?: \S+)?$"#)

    /// Which cron job a chat is a run of, read from the title the gateway wrote — the list carries no
    /// job field. Nil for any other source and for a run renamed by hand.
    public static func cronJobKey(_ chat: SessionSummary) -> String? {
        guard chat.source == "cron" else { return nil }
        let title = chat.title
        let range = NSRange(title.startIndex..., in: title)
        if let match = stampPattern?.firstMatch(in: title, range: range),
           let head = Range(match.range(at: 1), in: title) {
            let job = String(title[head]).trimmingCharacters(in: .whitespaces)
            return job.isEmpty ? nil : job
        }
        if let match = fallbackPattern?.firstMatch(in: title, range: range),
           let job = Range(match.range(at: 1), in: title) {
            return "cron \(title[job])"
        }
        return nil
    }

    static func group(for chat: SessionSummary, now: Date, calendar: Calendar) -> Group {
        guard let active = chat.lastActive ?? chat.startedAt else { return .month(calendar.component(.month, from: now)) }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: active)
        let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch age {
        case ..<1: return .today
        case 1: return .yesterday
        case 2...7: return .previousWeek
        case 8...30: return .previousMonth
        default:
            if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
                return .month(calendar.component(.month, from: day))
            }
            return .year(calendar.component(.year, from: day))
        }
    }

    /// The words a section header shows.
    public static func title(
        for group: Group,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        switch group {
        case .pinned: return "Pinned"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previousWeek: return "Previous 7 days"
        case .previousMonth: return "Previous 30 days"
        case .month(let number):
            var style = Date.FormatStyle.dateTime.month(.wide)
            style.locale = locale
            var components = calendar.dateComponents([.year], from: now)
            components.month = number
            components.day = 1
            return calendar.date(from: components).map { $0.formatted(style) } ?? "Month \(number)"
        case .year(let year):
            return String(year)
        }
    }
}

extension SessionSummary {
    /// The same chat with the pin this Mac keeps for itself, for a dashboard that refuses to keep it.
    public func settingPinned(_ value: Bool) -> SessionSummary {
        SessionSummary(
            id: id, title: title, preview: preview, source: source, model: model,
            startedAt: startedAt, lastActive: lastActive, messageCount: messageCount,
            pinned: value, archived: archived, active: active, unread: unread, usage: usage
        )
    }
}
