import Foundation

/// Heart rate and calories measured for a George workout (by the Apple Watch, or read from Apple
/// Health), and when the watch's numbers belong to it. Kept on the device only (`HealthMetrics`).
public struct MeasuredNumbers: Codable, Equatable, Sendable {
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

    // MARK: Numbers kept on this device

    /// How much earlier than the workout's end its numbers may have been kept (clocks of two devices).
    public static let keptSlack: TimeInterval = 60

    /// Numbers this device kept at `keptAt` are the workout's only when they were kept once it had
    /// ended (`workoutEnd`). Kept earlier, they are one part's: the workout was continued after it
    /// was stopped early and ended later – finished on another device, or ended from outside.
    public static func keptNumbersCover(workoutEnd: Date?, keptAt: Date) -> Bool {
        guard let workoutEnd else { return true }
        return keptAt.addingTimeInterval(keptSlack) >= workoutEnd
    }

    /// What a workout shows of the numbers kept for it (`keptAt`): them, or none when they are one
    /// part's only (`keptNumbersCover`) – George's estimate then, and no heart rate.
    public func shown(workoutEnd: Date?, keptAt: Date) -> MeasuredNumbers {
        Self.keptNumbersCover(workoutEnd: workoutEnd, keptAt: keptAt) ? self : MeasuredNumbers()
    }

    // MARK: A workout continued after "stopped early"

    /// The numbers kept for the first part(s) (`earlier`, over `earlierSeconds` of active time) and
    /// those of the part since continuing (`part`, over `partSeconds`) make the whole workout's –
    /// each number only when both parts have it, never one part's standing for the whole workout:
    /// calories added up, the average heart rate weighted by active time, the higher maximum. A
    /// number only one part (or neither) has is nil: George's estimate is shown for the calories,
    /// and no heart rate.
    public static func combined(earlier: MeasuredNumbers, earlierSeconds: Double,
                                part: MeasuredNumbers, partSeconds: Double) -> MeasuredNumbers {
        var average: Double?
        if let first = earlier.averageHeartRate, let second = part.averageHeartRate {
            let a = max(0, earlierSeconds), b = max(0, partSeconds)
            average = a + b > 0 ? (first * a + second * b) / (a + b) : (first + second) / 2
        }
        var maximum: Double?
        if let first = earlier.maxHeartRate, let second = part.maxHeartRate { maximum = max(first, second) }
        var energy: Double?
        if let first = earlier.activeEnergy, let second = part.activeEnergy { energy = first + second }
        return MeasuredNumbers(averageHeartRate: average, maxHeartRate: maximum, activeEnergy: energy)
    }

    /// A watch recording that ended (`recordingEndedAt`) before the running part began (`partBegan`:
    /// when it was continued) is the earlier part's, reported late – its numbers and its end aren't
    /// this part's. Unknown times: this part's.
    public static func isEarlierRecording(endedAt recordingEndedAt: Date?, partBegan: Date?) -> Bool {
        guard let recordingEndedAt, let partBegan else { return false }
        return recordingEndedAt <= partBegan
    }

    /// From when the part since continuing is read from Apple Health (heart rate): when it was
    /// continued. Not known on this device (continued on another one, or by an older version): the
    /// last `partSeconds` before `end`, never before the first part ended – time of this part only,
    /// not the first part's or the time in between.
    public static func partStart(continuedAt: Date?, earlierEndedAt: Date?, partSeconds: Double, end: Date) -> Date {
        if let continuedAt { return continuedAt }
        let latest = end.addingTimeInterval(-max(0, partSeconds))
        guard let earlierEndedAt else { return latest }
        return max(earlierEndedAt, latest)
    }
}

/// A workout stopped early and continued later has two parts. Finish keeps what was measured for
/// the part(s) before continuing on the device for a few days: the watch's final numbers for the
/// part since continuing can come after Finish, when the stored numbers are already the whole
/// workout's and the snapshot from Start (`LiveResume.PreStart`) is gone.
public struct EarlierPartNumbers: Codable, Equatable, Sendable {
    public var sessionID: UUID
    /// Measured for the part(s) before continuing (empty: nothing).
    public var numbers: MeasuredNumbers
    /// Their active time.
    public var seconds: Double
    /// The active time of the part since continuing.
    public var partSeconds: Double
    /// When the part since continuing began, or the earliest it can have (the first part's end);
    /// nil when not known.
    public var partBegan: Date?
    public var finishedAt: Date

    public init(sessionID: UUID, numbers: MeasuredNumbers, seconds: Double, partSeconds: Double,
                partBegan: Date?, finishedAt: Date) {
        self.sessionID = sessionID
        self.numbers = numbers
        self.seconds = seconds
        self.partSeconds = partSeconds
        self.partBegan = partBegan
        self.finishedAt = finishedAt
    }

    /// The whole workout's numbers with `part`, the numbers of the part since continuing
    /// (`MeasuredNumbers.combined`).
    public func whole(with part: MeasuredNumbers) -> MeasuredNumbers {
        MeasuredNumbers.combined(earlier: numbers, earlierSeconds: seconds, part: part, partSeconds: partSeconds)
    }

    /// A watch recording that ended at `recordingEndedAt` is of the part since continuing; one that
    /// ended before that part began is the first part's, reported late. Unknown times count as this part's.
    public func isLaterPart(recordingEndedAt: Date?) -> Bool {
        guard let recordingEndedAt, let partBegan else { return true }
        return recordingEndedAt > partBegan
    }

    /// Kept this long after Finish (as `PendingHealthLink`).
    public static let lifetime: TimeInterval = 3 * 86_400
    /// At most this many are kept (the newest).
    public static let limit = 20

    /// Without the expired ones (and at most `limit`, newest first).
    public static func pruned(_ parts: [EarlierPartNumbers], now: Date) -> [EarlierPartNumbers] {
        let alive = parts.filter { now.timeIntervalSince($0.finishedAt) <= lifetime }
            .sorted { $0.finishedAt > $1.finishedAt }
        return Array(alive.prefix(limit))
    }

    /// Adds `part`, replacing an older one for the same workout (continued once more).
    public static func adding(_ part: EarlierPartNumbers, to parts: [EarlierPartNumbers], now: Date) -> [EarlierPartNumbers] {
        pruned(parts.filter { $0.sessionID != part.sessionID } + [part], now: now)
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
