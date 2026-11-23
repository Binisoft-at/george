import Foundation

/// How the watch, its complication and the widgets read the phone's last snapshot at a later time –
/// a timeline entry at midnight, the first day of a new week – without asking the phone again.
/// (The iOS widget extension doesn't link GeorgeCore; Shared/WidgetBridge.swift mirrors these rules.)
public enum SnapshotTiming {
    /// When a planned workout is, seen from a given day.
    public enum Plan: Equatable, Sendable {
        /// Planned for that day.
        case today
        /// Planned for an earlier day and not done when the snapshot was made.
        case missed(Date)
        /// Planned for a later day.
        case later(Date)
    }

    /// Where `plannedDay` lies from `date`'s day.
    public static func plan(_ plannedDay: Date, on date: Date, calendar: Calendar) -> Plan {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: plannedDay)).day ?? 0
        if days == 0 { return .today }
        return days < 0 ? .missed(plannedDay) : .later(plannedDay)
    }

    /// Whether `date` still falls in the week that starts at `weekStart` (true without a week start,
    /// e.g. from an older phone version, and for a date before it – the clocks may differ a little).
    public static func isInWeek(startingAt weekStart: Date?, _ date: Date, calendar: Calendar) -> Bool {
        guard let weekStart else { return true }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: weekStart), to: calendar.startOfDay(for: date)).day ?? 0
        return days < 7
    }

    /// The week's done days as of `date`: the snapshot's count while its week runs, 0 once it is over.
    public static func doneDays(_ doneDays: Int, weekStart: Date?, on date: Date, calendar: Calendar) -> Int {
        isInWeek(startingAt: weekStart, date, calendar: calendar) ? doneDays : 0
    }

    /// The week's dots as of `date`: the snapshot's while its week runs, all open once it is over.
    public static func dots(_ dots: [Bool], weekStart: Date?, on date: Date, calendar: Calendar) -> [Bool] {
        isInWeek(startingAt: weekStart, date, calendar: calendar) ? dots : Array(repeating: false, count: dots.count)
    }
}
