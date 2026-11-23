import Foundation

// One meaning per number: "Volume" and "Sets" on Progress, the finish screen, the share card and the
// exercise chart are working sets; a "training day" is the same day for the streak, the Progress
// days chart, the week strip and Plan Week; estimated maxes are rounded the same way everywhere.

// MARK: - Working sets and volume

public extension WorkoutItem {
    /// Done sets without warm-ups.
    var workingSets: Int { sets.filter { $0.isDone && $0.kind != .warmup }.count }

    /// Reps × kg of the done working sets (warm-ups left out), × 2 for each-side moves.
    var workingVolumeKg: Double {
        let sides: Double = perSide ? 2 : 1
        var total = 0.0
        for set in sets where set.isDone && set.kind != .warmup {
            total += Double(set.effectiveReps ?? 0) * (set.effectiveWeight ?? 0) * sides
        }
        return total
    }
}

public extension WorkoutContent {
    /// Done sets without warm-ups – what Progress counts as "Working sets".
    var workingSets: Int { allItems.reduce(0) { $0 + $1.workingSets } }

    /// Volume of the done working sets (no warm-ups, × 2 for each-side moves) – what Progress, the
    /// finish screen, the share card and the exercise chart call "Volume".
    var workingVolumeKg: Double { allItems.reduce(0) { $0 + $1.workingVolumeKg } }
}

// MARK: - Estimated maxes

public extension Format {
    /// An estimate (e1RM) in the display unit: converted first, then rounded to 0.5 kg or 1 lb – so
    /// "101.33 kg" or "212.74 lb" never show and every screen rounds it the same way.
    static func estimate(_ kg: Double, unit: WeightUnit) -> String {
        "\(number(estimateValue(kg, unit: unit))) \(unit.rawValue)"
    }

    /// The number `estimate` shows (in the display unit).
    static func estimateValue(_ kg: Double, unit: WeightUnit) -> Double {
        let value = unit.fromKilograms(kg)
        return unit == .kg ? (value * 2).rounded() / 2 : value.rounded()
    }
}

// MARK: - Training days

/// What counts as a training day. The streak, the Progress "Workout days" chart, the Today hero and
/// Plan Week all use these entries, so a day is trained (or not) on every screen.
public enum TrainingDays {
    /// A performed George workout as the streak rules see it.
    public struct Workout: Hashable, Sendable {
        public var date: Date
        public var minutes: Double
        public var doneSets: Int
        public var isRescue: Bool
        public var kind: WorkoutKind

        public init(date: Date, minutes: Double, doneSets: Int, isRescue: Bool = false, kind: WorkoutKind) {
            self.date = date
            self.minutes = minutes
            self.doneSets = doneSets
            self.isRescue = isRescue
            self.kind = kind
        }
    }

    /// The qualifying entries: George workouts that meet `StreakRules.qualifies` (the minimum minutes,
    /// 3 sets of strength work, or a rescue) and – when Apple Health workouts count – Health workouts
    /// of at least the minimum minutes.
    public static func entries(workouts: [Workout], health: [ActivityEntry] = [], countHealth: Bool,
                               minimumMinutes: Double, rescueMinutes: Double) -> [ActivityEntry] {
        var result: [ActivityEntry] = []
        for workout in workouts where StreakRules.qualifies(
            minutes: workout.minutes, doneSets: workout.doneSets, isRescue: workout.isRescue, kind: workout.kind,
            minimumMinutes: minimumMinutes, rescueMinutes: rescueMinutes
        ) {
            result.append(ActivityEntry(date: workout.date, minutes: workout.minutes, isRescue: workout.isRescue, source: .george))
        }
        if countHealth {
            result.append(contentsOf: health.filter { $0.minutes >= minimumMinutes })
        }
        return result
    }

    /// Whether `day` (any time on it) has a qualifying entry.
    public static func isTrainingDay(_ day: Date, in entries: [ActivityEntry], calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: day)
        return entries.contains { calendar.startOfDay(for: $0.date) == start }
    }

    /// Distinct training days in the week starting at `weekStart`.
    public static func days(inWeekStarting weekStart: Date, entries: [ActivityEntry], calendar: Calendar) -> Int {
        let start = calendar.weekStart(for: weekStart)
        return Set(entries.filter { calendar.weekStart(for: $0.date) == start }.map { calendar.startOfDay(for: $0.date) }).count
    }
}

// MARK: - Averages over short histories

public extension MuscleEngine {
    /// What a per-week average is over: "Average per week in this range" – or, when the history is
    /// shorter than the range, "Average of the last 8 weeks with data" (see `weeksCovered(in:now:)`).
    static func averageCaption(weeksCovered: Double, rangeWeeks: Double) -> String {
        guard weeksCovered < rangeWeeks - 0.5 else { return "Average per week in this range" }
        let weeks = max(1, Int(weeksCovered.rounded()))
        return weeks == 1 ? "Average of the last week with data" : "Average of the last \(weeks) weeks with data"
    }
}

// MARK: - Comparing with the period before

/// How much of a period George's history covers – whether "vs prev." compares with anything.
public enum PeriodCoverage: String, Sendable {
    /// Nothing was logged before the period ended: no comparison.
    case noHistory
    /// Logging started during the period: the comparison is with part of it.
    case partial
    /// Logging started before the period: a fair comparison.
    case complete
}

public extension StatsEngine {
    /// How much of `interval` the history covers (by the first logged session).
    static func coverage(of sessions: [SessionRecord], in interval: DateInterval) -> PeriodCoverage {
        guard let first = sessions.map(\.date).min(), first < interval.end else { return .noHistory }
        return first < interval.start ? .complete : .partial
    }
}
