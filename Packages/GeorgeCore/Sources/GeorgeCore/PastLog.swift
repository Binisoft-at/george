import Foundation

/// Time and length for a workout logged afterwards ("I did UPPER but forgot to track it"): Log Past
/// Workout and "Mark As → Completed". The workout ends by now, and a planned day without a time of
/// its own (week plans sit at midnight) gets a real time of day.
public enum PastLog {
    /// The start used for a bare day when no earlier workout gives a usual time.
    public static let defaultHour = 18

    /// The start for a workout logged on `planned`. A time of day is kept; a bare day (midnight)
    /// gets the time of day `usualStart` has (the last workout's start), else 18:00. Either way the
    /// workout of `minutes` ends by `now`.
    public static func start(for planned: Date, minutes: Int, usualStart: Date?, now: Date, calendar: Calendar) -> Date {
        var start = planned
        if calendar.startOfDay(for: planned) == planned {
            var hour = defaultHour
            var minute = 0
            if let usualStart {
                let parts = calendar.dateComponents([.hour, .minute], from: usualStart)
                // A usual start at midnight is itself a bare day – not a time to copy.
                if let h = parts.hour, let m = parts.minute, h != 0 || m != 0 {
                    hour = h
                    minute = m
                }
            }
            start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: planned) ?? planned
        }
        return clamped(start, minutes: minutes, now: now)
    }

    /// `start`, moved earlier when a workout of `minutes` would otherwise end after `now`.
    public static func clamped(_ start: Date, minutes: Int, now: Date) -> Date {
        min(start, now.addingTimeInterval(-Double(max(1, minutes) * 60)))
    }

    /// Whether `date` is a bare day (midnight) rather than a time someone picked.
    public static func isBareDay(_ date: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: date) == date
    }

    /// A sensible length in minutes: the median of how long the last times took (the most recent
    /// first; at least two, at most five are used), else the plan's estimate plus about a minute per
    /// exercise for setting up – the estimate alone counts only reps and rest. Rounded to 5 minutes.
    public static func defaultMinutes(recentDurations: [Double], estimatedSeconds: Int, exerciseCount: Int) -> Int {
        let recent = Array(recentDurations.filter { $0 >= 60 }.prefix(5))
        if recent.count >= 2 {
            return rounded(median(recent))
        }
        guard estimatedSeconds > 0 else { return 40 }
        return rounded(Double(estimatedSeconds) + Double(max(0, exerciseCount)) * 60)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Seconds → minutes in steps of 5, between 5 and 240.
    static func rounded(_ seconds: Double) -> Int {
        max(5, min(240, Int((seconds / 60 / 5).rounded()) * 5))
    }
}
