import Foundation

/// Heart rate and calories measured for a George workout (by the Apple Watch, or read from Apple
/// Health), and when the watch's numbers belong to it. Kept on the device only (`HealthMetrics`).
public struct MeasuredNumbers: Equatable, Sendable {
    /// Beats per minute.
    public var averageHeartRate: Double?
    public var maxHeartRate: Double?
    /// Kilocalories.
    public var activeEnergy: Double?

    /// Zero or less stands for "not measured" (nil).
    public init(averageHeartRate: Double? = nil, maxHeartRate: Double? = nil, activeEnergy: Double? = nil) {
        self.averageHeartRate = Self.measured(averageHeartRate)
        self.maxHeartRate = Self.measured(maxHeartRate)
        self.activeEnergy = Self.measured(activeEnergy)
    }

    public var isEmpty: Bool { averageHeartRate == nil && maxHeartRate == nil && activeEnergy == nil }

    private static func measured(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else { return nil }
        return value
    }

    // MARK: The watch's running totals

    /// How much later than the workout's end the watch's totals may have been taken.
    public static let watchTotalsSlack: TimeInterval = 5 * 60

    /// The watch's calories and average heart rate are running totals since its recording started.
    /// They are the workout's only when they were taken (`countedUntil`) about when it ended – not
    /// for a workout left running and ended at its last set hours earlier, or a recording that ran
    /// on long after Finish. Then the workout's heart rate is read from Apple Health for its own
    /// time, and its calories are George's estimate.
    public static func watchTotalsFit(workoutEnd: Date, countedUntil: Date) -> Bool {
        countedUntil.timeIntervalSince(workoutEnd) <= watchTotalsSlack
    }

    // MARK: A workout continued after "stopped early"

    /// The numbers kept for the first part(s) (`earlier`, over `earlierSeconds` of active time) and
    /// those of the part since continuing (`part`, over `partSeconds`) make the whole workout's.
    /// Heart rate: the average weighted by active time, the higher maximum (one part's when only it
    /// has one). Calories: the sum, but only when both parts were measured – one part's calories
    /// are not the whole workout's (nil then: what was kept stays, else the estimate is shown).
    public static func combined(earlier: MeasuredNumbers, earlierSeconds: Double,
                                part: MeasuredNumbers, partSeconds: Double) -> MeasuredNumbers {
        var average: Double?
        switch (earlier.averageHeartRate, part.averageHeartRate) {
        case let (first?, second?):
            let a = max(0, earlierSeconds), b = max(0, partSeconds)
            average = a + b > 0 ? (first * a + second * b) / (a + b) : (first + second) / 2
        case let (first?, nil): average = first
        case let (nil, second?): average = second
        case (nil, nil): average = nil
        }
        let maximum = [earlier.maxHeartRate, part.maxHeartRate].compactMap { $0 }.max()
        var energy: Double?
        if let first = earlier.activeEnergy, let second = part.activeEnergy { energy = first + second }
        return MeasuredNumbers(averageHeartRate: average, maxHeartRate: maximum, activeEnergy: energy)
    }
}

/// The effort a finish stores. "Save without rating" (no rating) stores none (0) – in George and in
/// Apple Health – instead of a made-up one; the calorie estimate still uses the kind's usual effort.
public enum FinishRating {
    /// The rating given (1–10), or 0 for none.
    public static func stored(_ rating: Int?) -> Int {
        guard let rating, rating > 0 else { return 0 }
        return min(10, rating)
    }

    /// The effort the calorie estimate uses: the rating, else the kind's usual effort.
    public static func forEstimate(_ stored: Int, kind: WorkoutKind) -> Int {
        stored > 0 ? stored : kind.defaultEffort
    }
}

/// When George asks Apple Health (again) for an outside workout's effort score.
public enum HealthEffortLookup {
    /// A workout without a score may still get one this long after it ended – rated in Fitness
    /// later, or Apple's estimate written once the watch synced. Until then it is asked again on
    /// each refresh; after that "none" is kept.
    public static let pendingWindow: TimeInterval = 7 * 86_400

    /// - Parameters:
    ///   - known: a score (or "none") was read for it before.
    ///   - score: that score (nil: none).
    public static func needsLookup(known: Bool, score: Int?, endedAt: Date, now: Date) -> Bool {
        guard known else { return true }
        return score == nil && now.timeIntervalSince(endedAt) < pendingWindow
    }
}
