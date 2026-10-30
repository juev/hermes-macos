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

    public struct Section: Sendable, Equatable, Identifiable {
        public let group: Group
        public let chats: [SessionSummary]

        public var id: Group { group }

        public init(group: Group, chats: [SessionSummary]) {
            self.group = group
            self.chats = chats
        }
    }

    /// Newest activity first inside every group, and pinned chats apart from the dates they would
    /// otherwise fall into.
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
        if !pinned.isEmpty { sections.append(Section(group: .pinned, chats: pinned)) }
        for group in order {
            sections.append(Section(group: group, chats: byGroup[group] ?? []))
        }
        return sections
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
