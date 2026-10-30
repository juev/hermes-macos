import Foundation

/// A long chat is read by days: a separator where the date changes, so the eye finds yesterday
/// without reading every time.
public enum TranscriptDays {
    public struct Entry: Sendable, Equatable {
        /// A day to open, when the item under it is the first of that day; nil for the rest.
        public let day: Date?
        public let item: ChatItem

        public init(day: Date?, item: ChatItem) {
            self.day = day
            self.item = item
        }
    }

    /// The items with a day in front of the first one of each day. An item with no time of its own
    /// keeps the day before it, so a message still being sent does not open a new one.
    public static func group(_ items: [ChatItem], calendar: Calendar = .current) -> [Entry] {
        var entries: [Entry] = []
        var currentDay: Date?
        for item in items {
            guard let timestamp = item.timestamp else {
                entries.append(Entry(day: nil, item: item))
                continue
            }
            let day = calendar.startOfDay(for: timestamp)
            let opens = currentDay.map { !calendar.isDate($0, inSameDayAs: day) } ?? true
            entries.append(Entry(day: opens ? day : nil, item: item))
            currentDay = day
        }
        return entries
    }

    /// The words for a separator: today and yesterday by name, anything else by its date.
    public static func label(for day: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.day(.defaultDigits).month(.wide)
        style.locale = locale
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return day.formatted(style)
    }
}
