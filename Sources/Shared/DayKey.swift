import Foundation

/// A date-only key, "yyyy-MM-dd", matching the string SHARE-FORMAT.md's
/// `r`/`t` fields use. UTC throughout — a date-only key must not shift by a
/// day across a DST transition just because arithmetic used the local
/// calendar.
enum DayKey {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(from key: String) -> Date? {
        formatter.date(from: key)
    }

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// `k` in SHARE-FORMAT.md is always relative to `r` — this is the one
    /// place that offset becomes an actual date.
    static func adding(days: Int, to key: String) -> String? {
        guard let base = date(from: key),
              let shifted = utcCalendar.date(byAdding: .day, value: days, to: base)
        else { return nil }
        return string(from: shifted)
    }
}
