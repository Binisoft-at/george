import Foundation

// MARK: - Pace

/// How the workout flows: sets on time keep the momentum (the flame in live mode) high, dawdling
/// between sets lets it sink. Also drives the set timer and gentle nudges.
public struct PaceTracker: Equatable, Sendable {
    public enum Level: String, Sendable {
        case onFire, steady, slow
    }

    /// 0…1 – how well the last sets kept to the plan.
    public private(set) var momentum: Double
    /// Sets in a row started within the planned rest (+ slack).
    public private(set) var onTimeStreak = 0
    public private(set) var lastSetAt: Date?
    /// Seconds of slack before a gap counts as dawdling (calm days get more).
    public var slack: Double

    public init(slack: Double = 30, momentum: Double = 0.6) {
        self.slack = slack
        self.momentum = momentum
    }

    public var level: Level {
        if momentum >= 0.75 { return .onFire }
        if momentum >= 0.4 { return .steady }
        return .slow
    }

    /// Call when a set is done. `expectedGap` = planned rest before it + the time the set takes
    /// (nil for the first set of the workout).
    public mutating func setCompleted(at date: Date, expectedGap: Double?) {
        if let last = lastSetAt, let expectedGap {
            let late = date.timeIntervalSince(last) - expectedGap - slack
            if late <= 0 {
                onTimeStreak += 1
                momentum = min(1, momentum + 0.12)
            } else {
                onTimeStreak = 0
                momentum = max(0, momentum - min(0.35, 0.05 + late / 300))
            }
        } else {
            momentum = min(1, momentum + 0.05)
        }
        lastSetAt = date
    }

    /// A set was unticked: forget it so the next gap isn't measured from it.
    public mutating func setUndone(previous: Date?) {
        lastSetAt = previous
    }

    /// Seconds since the last set (0 before the first).
    public func idleSeconds(at date: Date) -> Double {
        lastSetAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
    }

    /// How far past the plan (+ slack) the next set is – 0 while on time.
    public func overdueSeconds(at date: Date, expectedGap: Double) -> Double {
        guard lastSetAt != nil else { return 0 }
        return max(0, idleSeconds(at: date) - expectedGap - slack)
    }

    /// Rough time a set takes: about 3 s a rep plus 15 s to get set up, or the hold time.
    public static func workSeconds(for set: WorkoutSet, mode: ExerciseMode) -> Double {
        switch mode {
        case .reps: return Double(set.effectiveReps ?? 10) * 3 + 15
        case .time: return Double(set.effectiveSeconds ?? 30) + 10
        case .distance: return Double(set.effectiveSeconds ?? 120) + 10
        }
    }
}

// MARK: - Progression

/// What to try next time for an exercise, from last time's sets and how hard they felt.
public struct ProgressionSuggestion: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case addWeight, addReps, keep, lighten
    }

    public var kind: Kind
    /// Suggested weight in kg (nil: bodyweight or unchanged).
    public var weightKg: Double?
    /// Suggested reps (nil: unchanged).
    public var reps: Int?
    /// Plain words, e.g. "Last time 3 reps were left in the tank".
    public var reason: String
}

/// Double progression with reps in reserve (RIR = 10 − RPE): add weight when the top of the rep range
/// was reached or 3+ reps were left, add a rep when 1–2 were left, keep it when it was all-out, and go
/// a step lighter when reps were missed at all-out effort.
public enum ProgressionAdvisor {
    public static func suggest(lastSets: [WorkoutSet]?, mode: ExerciseMode, plan: WorkoutSet?, incrementKg: Double) -> ProgressionSuggestion? {
        guard mode == .reps, let lastSets else { return nil }
        let working = lastSets.filter { $0.isDone && $0.kind != .warmup }
        guard let top = working.max(by: { ($0.effectiveWeight ?? 0, $0.effectiveReps ?? 0) < ($1.effectiveWeight ?? 0, $1.effectiveReps ?? 0) }),
              let topReps = top.effectiveReps, topReps > 0 else { return nil }
        let weight = top.effectiveWeight ?? 0
        let range = plan?.targetRepsRange ?? top.targetRepsRange
        let rir = working.last(where: { $0.rpe != nil })?.repsInReserve
        let minReps = working.compactMap(\.effectiveReps).min() ?? topReps
        let hitTop = range.map { minReps >= $0.upperBound } ?? false
        let missed = range.map { minReps < $0.lowerBound } ?? false

        if weight > 0 {
            if let rir, rir >= 3 {
                return ProgressionSuggestion(kind: .addWeight, weightKg: weight + incrementKg, reps: range?.lowerBound ?? topReps,
                                             reason: "Last time \(rir)+ reps were left in the tank")
            }
            if hitTop {
                return ProgressionSuggestion(kind: .addWeight, weightKg: weight + incrementKg, reps: range?.lowerBound,
                                             reason: "Every set reached \(range?.upperBound ?? topReps) reps last time")
            }
            if missed, rir == 0 {
                return ProgressionSuggestion(kind: .lighten, weightKg: max(0, weight - incrementKg), reps: range?.lowerBound,
                                             reason: "Reps were missed at full effort last time")
            }
            if let rir, rir == 0 {
                return ProgressionSuggestion(kind: .keep, weightKg: weight, reps: topReps,
                                             reason: "Last time was all-out – match it")
            }
            return ProgressionSuggestion(kind: .addReps, weightKg: weight, reps: topReps + 1,
                                         reason: rir.map { "Last time \($0) reps were left" } ?? "Beat last time by one rep")
        }
        // Bodyweight: add reps.
        if let rir, rir == 0 {
            return ProgressionSuggestion(kind: .keep, weightKg: nil, reps: topReps, reason: "Last time was all-out – match it")
        }
        return ProgressionSuggestion(kind: .addReps, weightKg: nil, reps: topReps + 1, reason: "Beat last time by one rep")
    }
}

/// When to ask "how many more reps could you have done?" – smart and rare: after the last working
/// set of an exercise with reps, only if that set has no RPE yet, at most a few times per workout.
public enum EffortPrompt {
    public static let defaultLimit = 4

    public static func shouldAsk(after set: WorkoutSet, in item: WorkoutItem, askedSoFar: Int, limit: Int = defaultLimit) -> Bool {
        guard askedSoFar < limit, item.mode == .reps, set.isDone, set.kind != .warmup, set.rpe == nil else { return false }
        let working = item.sets.filter { $0.kind != .warmup }
        return working.last?.id == set.id
    }

    /// RPE stored for an answer of `rir` reps in reserve (3 means "3 or more").
    public static func rpe(forRepsInReserve rir: Int) -> Double {
        Double(10 - min(4, max(0, rir)))
    }
}
