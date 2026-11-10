import Foundation

// MARK: - Pace

/// One break between two sets: what the plan said and what really happened.
public struct RestGap: Equatable, Sendable, Codable {
    /// Planned rest before the set, in seconds.
    public var planned: Double
    /// From the end of the previous set to the start of this one.
    public var actual: Double

    public init(planned: Double, actual: Double) {
        self.planned = planned
        self.actual = actual
    }

    /// Positive: longer than planned (behind), negative: shorter (ahead).
    public var delta: Double { actual - planned }
}

/// How the workout flows. A set starts with the Start button (or, if you just tick it off, an
/// estimated start: its work time before the tick). Each break is compared with the planned rest;
/// the deltas add up to "behind / ahead of plan". Sets on time keep the momentum (the flame) high.
public struct PaceTracker: Equatable, Sendable {
    public enum Level: String, Sendable {
        case onFire, steady, slow
    }

    /// 0…1 – how well the last sets kept to the plan.
    public private(set) var momentum: Double
    /// Sets in a row started within the planned rest (+ slack).
    public private(set) var onTimeStreak = 0
    /// End of the last finished set.
    public private(set) var lastSetAt: Date?
    /// Start of the set in progress (nil while waiting or resting).
    public private(set) var startedAt: Date?
    /// Every break so far, oldest first.
    public private(set) var gaps: [RestGap] = []
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

    /// Sum of all deltas: positive = behind the plan by that many seconds.
    public var totalDelta: Double { gaps.reduce(0) { $0 + $1.delta } }

    public var averageDelta: Double? {
        gaps.isEmpty ? nil : totalDelta / Double(gaps.count)
    }

    public var lastGap: RestGap? { gaps.last }

    /// The set is being done from now on. Records the break before it (if there was a set before).
    public mutating func setStarted(at date: Date, plannedRest: Double) {
        guard startedAt == nil else { return }
        startedAt = date
        if let last = lastSetAt {
            record(RestGap(planned: plannedRest, actual: max(0, date.timeIntervalSince(last))))
        }
    }

    /// The set is done. Without a recorded start, the start is estimated as `workSeconds` before now.
    public mutating func setCompleted(at date: Date, plannedRest: Double?, workSeconds: Double) {
        if startedAt == nil, let last = lastSetAt, let plannedRest {
            let start = max(last, date.addingTimeInterval(-workSeconds))
            record(RestGap(planned: plannedRest, actual: start.timeIntervalSince(last)))
        } else if lastSetAt == nil {
            momentum = min(1, momentum + 0.05)
        }
        startedAt = nil
        lastSetAt = date
    }

    /// Older form: `expectedGap` = planned rest + the set's own work time.
    public mutating func setCompleted(at date: Date, expectedGap: Double?) {
        if let expectedGap, lastSetAt != nil {
            let work = min(60, max(0, expectedGap) / 4)
            setCompleted(at: date, plannedRest: max(0, expectedGap - work), workSeconds: work)
        } else {
            setCompleted(at: date, plannedRest: nil, workSeconds: 0)
        }
    }

    private mutating func record(_ gap: RestGap) {
        gaps.append(gap)
        let late = gap.delta - slack
        if late <= 0 {
            onTimeStreak += 1
            momentum = min(1, momentum + 0.12)
        } else {
            onTimeStreak = 0
            momentum = max(0, momentum - min(0.35, 0.05 + late / 300))
        }
    }

    /// A set was unticked: forget it so the next gap isn't measured from it.
    public mutating func setUndone(previous: Date?) {
        lastSetAt = previous
        startedAt = nil
    }

    /// Seconds since the last set ended (0 before the first).
    public func idleSeconds(at date: Date) -> Double {
        lastSetAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
    }

    /// Seconds the current set has been going.
    public func workingSeconds(at date: Date) -> Double {
        startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
    }

    /// How far past the plan (+ slack) the next set is – 0 while on time.
    public func overdueSeconds(at date: Date, expectedGap: Double) -> Double {
        guard lastSetAt != nil, startedAt == nil else { return 0 }
        return max(0, idleSeconds(at: date) - expectedGap - slack)
    }

    /// While waiting for the next set: how far over (positive) or under the planned rest you are.
    public func waitingDelta(at date: Date, plannedRest: Double) -> Double? {
        guard lastSetAt != nil, startedAt == nil else { return nil }
        return idleSeconds(at: date) - plannedRest
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

/// The plan for the rest of the workout and where the pace leads.
public enum WorkoutPace {
    /// Work time plus planned rests for every set still open (in execution order).
    public static func remainingSeconds(in content: WorkoutContent, defaultRest: Int) -> Double {
        let order = content.executionOrder()
        let open = order.filter { content.set(at: $0)?.isDone == false }
        var total = 0.0
        for (index, ref) in open.enumerated() {
            guard let item = content.item(at: ref), let set = content.set(at: ref) else { continue }
            total += PaceTracker.workSeconds(for: set, mode: item.mode) * (item.perSide ? 2 : 1)
            if index < open.count - 1 {
                total += Double(content.restAfter(ref, defaultRest: defaultRest) ?? 0)
            }
        }
        return total
    }

    /// The whole workout as planned: every set's work time plus the rests between them.
    public static func plannedSeconds(of content: WorkoutContent, defaultRest: Int) -> Double {
        var all = content
        for b in all.blocks.indices {
            for i in all.blocks[b].items.indices {
                for s in all.blocks[b].items[i].sets.indices { all.blocks[b].items[i].sets[s].isDone = false }
            }
        }
        return remainingSeconds(in: all, defaultRest: defaultRest)
    }

    /// Plain advice from the breaks so far, for the expanded live panel.
    public static func tips(for pace: PaceTracker, restRange: ClosedRange<Int>?) -> [String] {
        var tips: [String] = []
        guard let average = pace.averageDelta, pace.gaps.count >= 2 else {
            tips.append("Tap Start when you begin a set – George then compares your real rest with the plan.")
            if let restRange {
                tips.append("Rest guideline for you: \(Format.shortDuration(restRange.lowerBound))–\(Format.shortDuration(restRange.upperBound)) between sets (Settings → Your Profile).")
            }
            return tips
        }
        if average > 30 {
            tips.append("Your breaks run about \(Format.shortDuration(Int(average.rounded()))) over the plan. Start when the ring hits zero: set up the weight and get in position during the last 15 seconds.")
            tips.append("Phone and chats between sets add up – leave them for after the workout.")
        } else if average < -20 {
            tips.append("You rest less than planned (\(Format.shortDuration(Int((-average).rounded()))) shorter). Fine for light work; on heavy sets take the full rest – strength drops when rests get too short.")
        } else {
            tips.append("Right on plan – your breaks are within \(Format.shortDuration(max(5, Int(abs(average).rounded())))) of the planned rest.")
        }
        if let last = pace.lastGap, last.delta > 60 {
            tips.append("The last break was \(Format.shortDuration(Int(last.delta.rounded()))) longer than planned.")
        }
        if let restRange {
            tips.append("Rest guideline for you: \(Format.shortDuration(restRange.lowerBound))–\(Format.shortDuration(restRange.upperBound)) between sets – longer (2–3 min) on heavy compound lifts.")
        }
        return tips
    }

    /// "2:10 behind plan", "0:40 ahead of plan", "on plan".
    public static func deltaText(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if abs(value) < 10 { return "on plan" }
        return "\(Format.clock(abs(value))) \(value > 0 ? "behind" : "ahead of") plan"
    }

    /// "+0:40" / "−0:15" / "±0".
    public static func signed(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if value == 0 { return "±0:00" }
        return (value > 0 ? "+" : "−") + Format.clock(abs(value))
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
