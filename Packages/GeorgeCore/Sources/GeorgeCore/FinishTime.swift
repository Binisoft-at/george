import Foundation

/// When a finished workout really ended, how long it was active, and which part of it Apple Health
/// gets. A workout left running after the gym (Finish tapped the next morning) must not become a
/// 12-hour, 5,000 kcal workout; a watch's Finish counts from its tap, not from when the iPhone heard
/// of it; a workout continued after "stopped early" adds only the new part to Apple Health.
public enum FinishTime {
    /// No sign of life for this long: the finish sheet offers to end at the last set + rest.
    public static let offerAfter: TimeInterval = 30 * 60
    /// No sign of life for this long: Today asks "Still training?".
    public static let stillTrainingAfter: TimeInterval = 3 * 60 * 60
    /// The rest counted after the last set is at most this long.
    public static let maxRest: TimeInterval = 10 * 60
    /// The longest believable active time of a strength workout. A longer one that wasn't given an
    /// end on the finish sheet ends at its last set + rest.
    public static let strengthLimit: TimeInterval = 4 * 60 * 60
    /// The part left after the watch stopped recording must be at least this long for the iPhone to
    /// save it as a workout of its own.
    public static let minimumRemainder: TimeInterval = 2 * 60

    /// Gym, bands and bodyweight: nobody lifts for more than four hours.
    public static func plausibleActiveSeconds(for kind: WorkoutKind) -> TimeInterval? {
        [WorkoutKind.gym, .band, .bodyweight].contains(kind) ? strengthLimit : nil
    }

    /// How long nothing happened: since the last ticked or started set, resume or start
    /// (`RunningWorkout.lastActivity`) – or the pause, when that came later.
    public static func idleSeconds(lastActivity: Date?, pausedAt: Date?, now: Date) -> TimeInterval {
        guard let last = [lastActivity, pausedAt].compactMap({ $0 }).max() else { return 0 }
        return max(0, now.timeIntervalSince(last))
    }

    /// "Last set + rest": where a workout left running ends (never later than now; a pause that
    /// came later than that is the end).
    public static func suggestedEnd(lastActivity: Date, restSeconds: Double, pausedAt: Date?, now: Date) -> Date {
        var end = lastActivity.addingTimeInterval(min(maxRest, max(0, restSeconds)))
        if let pausedAt, pausedAt > end { end = pausedAt }
        return min(end, now)
    }

    /// `end` inside the workout: not before its start, not after now.
    public static func clamp(_ end: Date, startedAt: Date?, now: Date) -> Date {
        let result = min(end, now)
        if let startedAt, result < startedAt { return min(startedAt, now) }
        return result
    }

    /// The end a finish uses. `requested` is a time chosen on the finish sheet (`chosen`) or when a
    /// remote asked to finish (the watch's tap); nil is now. A remote's time before `lastActivity`
    /// (the workout went on here after the tap) moves to it. It is clamped into the workout. One that
    /// wasn't chosen, of a kind with a believable limit, whose clock ran longer than that (left
    /// running after the gym) ends at `suggestedEnd` (last set + rest) instead.
    public static func resolvedEnd(requested: Date?, chosen: Bool, clock: LiveClock, kind: WorkoutKind,
                                   suggestedEnd: Date?, lastActivity: Date? = nil, now: Date) -> Date {
        var asked = requested ?? now
        if !chosen, let lastActivity, lastActivity > asked { asked = lastActivity }
        let end = clamp(asked, startedAt: clock.startedAt, now: now)
        guard !chosen, let limit = plausibleActiveSeconds(for: kind), clock.activeSeconds(until: end) > limit,
              let suggestedEnd, suggestedEnd < end else { return end }
        return clamp(suggestedEnd, startedAt: clock.startedAt, now: now)
    }

    /// What the iPhone saves to Apple Health for a finished workout (start…end, active seconds and
    /// the pauses in between). A workout continued after "stopped early" saves only what was done
    /// since `continuedAt` (its first part is in Apple Health already); when the watch stopped
    /// recording on the way (it saved its part), only the rest after `watchStoppedAt`. Nil when
    /// nothing is left to save (under `minimumRemainder` after the watch, or nothing since continuing).
    public static func healthSpan(start: Date, end: Date, activeSeconds: Double, continuedAt: Date?,
                                  activeBeforeContinuing: Double, watchStoppedAt: Date?, pauses: [PauseSpan]) -> HealthSpan? {
        var spanStart = start
        var active = activeSeconds
        if let continuedAt, continuedAt > start {
            guard continuedAt < end else { return nil }
            spanStart = continuedAt
            active = activeSeconds - activeBeforeContinuing
        }
        if let watchStoppedAt, watchStoppedAt > spanStart {
            guard end.timeIntervalSince(watchStoppedAt) >= minimumRemainder else { return nil }
            spanStart = watchStoppedAt
            let unpaused = end.timeIntervalSince(spanStart) - PauseLog.pausedSeconds(pauses, from: spanStart, to: end)
            active = min(active, unpaused)
        }
        let wall = max(0, end.timeIntervalSince(spanStart))
        return HealthSpan(start: spanStart, end: end, activeSeconds: min(wall, max(0, active)),
                          pauses: PauseLog.clipped(pauses, from: spanStart, to: end))
    }
}

/// The clock of a running workout: active seconds before the last resume, and when it was resumed
/// (nil while paused) or paused.
public struct LiveClock: Equatable, Sendable {
    public var startedAt: Date?
    public var accumulatedSeconds: Double
    public var resumedAt: Date?
    public var pausedAt: Date?

    public init(startedAt: Date?, accumulatedSeconds: Double, resumedAt: Date?, pausedAt: Date? = nil) {
        self.startedAt = startedAt
        self.accumulatedSeconds = accumulatedSeconds
        self.resumedAt = resumedAt
        self.pausedAt = pausedAt
    }

    /// Active seconds up to `end`, which may lie before now: the running clock stops there, and an
    /// end before the last resume (or pause) takes that time off. Never more than `end − start`.
    public func activeSeconds(until end: Date) -> Double {
        var active = accumulatedSeconds
        if let resumedAt {
            active += end.timeIntervalSince(resumedAt)
        } else if let pausedAt, end < pausedAt {
            active -= pausedAt.timeIntervalSince(end)
        }
        active = max(0, active)
        if let startedAt { active = min(active, max(0, end.timeIntervalSince(startedAt))) }
        return active
    }
}

/// The part of a workout the iPhone saves to Apple Health.
public struct HealthSpan: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var activeSeconds: Double
    /// Pauses inside start…end (Apple Health gets them as pause/resume events).
    public var pauses: [PauseSpan]

    public init(start: Date, end: Date, activeSeconds: Double, pauses: [PauseSpan] = []) {
        self.start = start
        self.end = end
        self.activeSeconds = activeSeconds
        self.pauses = pauses
    }
}

/// A pause of the running workout; `end` is nil while it lasts (or when the workout ended paused).
public struct PauseSpan: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date?

    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }
}

/// The pauses of the running workout, kept on the device with where the workout stands.
public enum PauseLog {
    /// More is never needed; the oldest go first.
    public static let limit = 200

    /// A pause starts (nothing changes while one is open already).
    public static func pausing(_ log: [PauseSpan], at date: Date) -> [PauseSpan] {
        if let last = log.last, last.end == nil { return log }
        var result = log
        result.append(PauseSpan(start: date))
        if result.count > limit { result.removeFirst(result.count - limit) }
        return result
    }

    /// The open pause ends.
    public static func resuming(_ log: [PauseSpan], at date: Date) -> [PauseSpan] {
        guard let last = log.last, last.end == nil else { return log }
        var result = log
        result[result.count - 1].end = max(date, last.start)
        return result
    }

    /// The pauses inside from…to, cut to it. One that lasts past `to` has no end (the workout ended
    /// paused); empty ones are left out.
    public static func clipped(_ log: [PauseSpan], from: Date, to: Date) -> [PauseSpan] {
        log.compactMap { span in
            let start = max(span.start, from)
            guard start < to else { return nil }
            if let end = span.end {
                guard end > start else { return nil }
                return PauseSpan(start: start, end: end < to ? end : nil)
            }
            return PauseSpan(start: start, end: nil)
        }
    }

    /// Paused seconds inside from…to.
    public static func pausedSeconds(_ log: [PauseSpan], from: Date, to: Date) -> Double {
        clipped(log, from: from, to: to).reduce(0) { total, span in
            total + (span.end ?? to).timeIntervalSince(span.start)
        }
    }
}
