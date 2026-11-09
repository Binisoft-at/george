import Foundation

public extension Calendar {
    /// ISO-8601 style calendar (weeks start Monday, week 1 contains Jan 4th) in the current time zone.
    static func training(firstWeekday: Int = 2, timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = 4
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    func weekStart(for date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)?.start ?? startOfDay(for: date)
    }

    func weekNumber(for date: Date) -> Int {
        component(.weekOfYear, from: date)
    }

    func addingWeeks(_ weeks: Int, to date: Date) -> Date {
        self.date(byAdding: .weekOfYear, value: weeks, to: date) ?? date.addingTimeInterval(Double(weeks) * 7 * 86_400)
    }

    func addingDays(_ days: Int, to date: Date) -> Date {
        self.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
    }

    /// Whole days from `a` to `b` (start of day based).
    func daysBetween(_ a: Date, _ b: Date) -> Int {
        dateComponents([.day], from: startOfDay(for: a), to: startOfDay(for: b)).day ?? 0
    }
}

/// Notes-style grouping of dated items: Today, Yesterday, Previous 7 Days, Previous 30 Days, months, years.
public enum DateBucket: Hashable, Comparable, Sendable {
    case upcoming
    case today
    case yesterday
    case previous7
    case previous30
    case month(year: Int, month: Int)
    case year(Int)

    public static func bucket(for date: Date, now: Date = Date(), calendar: Calendar = .training()) -> DateBucket {
        let days = calendar.daysBetween(date, now)
        if days < 0 { return .upcoming }
        if days == 0 { return .today }
        if days == 1 { return .yesterday }
        if days <= 7 { return .previous7 }
        if days <= 30 { return .previous30 }
        let year = calendar.component(.year, from: date)
        if year == calendar.component(.year, from: now) {
            return .month(year: year, month: calendar.component(.month, from: date))
        }
        return .year(year)
    }

    /// Lower sorts first (newest first).
    private var rank: (Int, Int) {
        switch self {
        case .upcoming: return (0, 0)
        case .today: return (1, 0)
        case .yesterday: return (2, 0)
        case .previous7: return (3, 0)
        case .previous30: return (4, 0)
        case .month(let year, let month): return (5, -(year * 100 + month))
        case .year(let year): return (6, -year)
        }
    }

    public static func < (lhs: DateBucket, rhs: DateBucket) -> Bool {
        lhs.rank < rhs.rank
    }

    public var title: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7: return "Previous 7 Days"
        case .previous30: return "Previous 30 Days"
        case .month(_, let month):
            let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            return names[max(0, min(11, month - 1))]
        case .year(let year): return String(year)
        }
    }
}

/// Builds session titles like "W44: 3 UPPER - 29.10" from a pattern.
///
/// Tokens: `{W}` week number, `{N}` number of the session within the week, `{T}` template name,
/// `{D}` day.month, `{DATE}` day.month.year, `{WD}` short weekday, `{Y}` year, `{M}` month.
public struct SessionNamer: Sendable {
    public static let defaultPattern = "W{W}: {N} {T} - {D}"
    public var pattern: String
    public var calendar: Calendar

    public init(pattern: String = SessionNamer.defaultPattern, calendar: Calendar = .training()) {
        self.pattern = pattern.isEmpty ? SessionNamer.defaultPattern : pattern
        self.calendar = calendar
    }

    public func title(templateName: String, date: Date, indexInWeek: Int) -> String {
        let day = calendar.component(.day, from: date)
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        let weekdayIndex = calendar.component(.weekday, from: date) - 1
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = pattern
        let replacements: [(String, String)] = [
            ("{DATE}", String(format: "%02d.%02d.%02d", day, month, year % 100)),
            ("{WD}", weekdays[max(0, min(6, weekdayIndex))]),
            ("{W}", String(calendar.weekNumber(for: date))),
            ("{N}", String(max(1, indexInWeek))),
            ("{T}", name.isEmpty ? "Workout" : name),
            ("{D}", String(format: "%02d.%02d", day, month)),
            ("{Y}", String(year)),
            ("{M}", String(month)),
        ]
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// "W44 · 26 Oct – 1 Nov"
    public func weekTitle(for date: Date) -> String {
        let start = calendar.weekStart(for: date)
        let end = calendar.addingDays(6, to: start)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        func short(_ d: Date) -> String {
            "\(calendar.component(.day, from: d)) \(months[calendar.component(.month, from: d) - 1])"
        }
        return "W\(calendar.weekNumber(for: date)) · \(short(start)) – \(short(end))"
    }
}
