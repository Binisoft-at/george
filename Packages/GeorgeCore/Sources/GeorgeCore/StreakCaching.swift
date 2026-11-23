import Foundation

public extension StreakEngine {
    /// Whether `evaluate` gives the same summary at `a` as at `b`, so a streak worked out once can be
    /// shown again (Today redraws often): the same day, and no entry that counts at one moment but not
    /// at the other (`evaluate` counts entries up to a minute after `now` – a workout dated later today
    /// is not counted yet).
    func evaluatesAlike(entries: [ActivityEntry], at a: Date, and b: Date) -> Bool {
        guard calendar.isDate(a, inSameDayAs: b) else { return false }
        let low = min(a, b).addingTimeInterval(60)
        let high = max(a, b).addingTimeInterval(60)
        return !entries.contains { $0.date > low && $0.date <= high }
    }
}
