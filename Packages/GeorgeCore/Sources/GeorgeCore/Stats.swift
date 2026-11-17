import Foundation

/// Lightweight, platform-independent view of a performed session used for statistics.
public struct SessionRecord: Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var kind: WorkoutKind
    public var durationSeconds: Double
    public var energyKcal: Double
    public var isCompleted: Bool
    public var content: WorkoutContent

    public init(id: UUID, date: Date, title: String, kind: WorkoutKind, durationSeconds: Double, energyKcal: Double = 0, isCompleted: Bool, content: WorkoutContent) {
        self.id = id
        self.date = date
        self.title = title
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.energyKcal = energyKcal
        self.isCompleted = isCompleted
        self.content = content
    }
}

public struct WeekStat: Identifiable, Hashable, Sendable {
    public var id: Date { weekStart }
    public var weekStart: Date
    public var sessions: Int
    public var workoutDays: Int
    public var minutes: Double
    public var volumeKg: Double
    public var sets: Int
    public var energyKcal: Double
}

public struct ExercisePoint: Identifiable, Hashable, Sendable {
    public var id: UUID { sessionID }
    public var sessionID: UUID
    public var date: Date
    public var bestWeight: Double?
    public var bestReps: Int?
    public var bestSeconds: Int?
    public var estimatedOneRepMax: Double?
    public var volume: Double
    public var sets: [WorkoutSet]
}

public struct PersonalRecord: Identifiable, Hashable, Sendable {
    public enum Metric: String, Sendable { case weight, reps, oneRepMax, duration, volume }
    public var id: String { exerciseKey + metric.rawValue }
    public var exerciseKey: String
    public var exerciseName: String
    public var metric: Metric
    public var value: Double
    public var date: Date

    public init(exerciseKey: String, exerciseName: String, metric: Metric, value: Double, date: Date) {
        self.exerciseKey = exerciseKey
        self.exerciseName = exerciseName
        self.metric = metric
        self.value = value
        self.date = date
    }

    /// Which record counts most when one exercise sets several at once.
    var priority: Int {
        switch metric {
        case .weight: return 0
        case .oneRepMax: return 1
        case .reps: return 2
        case .duration: return 3
        case .volume: return 4
        }
    }

    /// "e1RM 96 kg", "12 reps", "1:30" – the value in words.
    public func detail(unit: WeightUnit = .kg) -> String {
        switch metric {
        case .weight: return Format.weight(value, unit: unit)
        case .oneRepMax: return "e1RM " + Format.weight(value, unit: unit)
        case .reps: return "\(Int(value)) reps"
        case .duration: return Format.clock(Int(value))
        case .volume: return Format.volume(value, unit: unit)
        }
    }
}

/// How an exercise went compared with the last time it was done.
public struct ExerciseComparison: Hashable, Sendable, Identifiable {
    public enum Direction: String, Sendable { case up, same, down }
    public enum Measure: String, Sendable { case oneRepMax, reps, seconds }
    public var id: String { exerciseKey }
    public var exerciseKey: String
    public var exerciseName: String
    public var measure: Measure
    public var before: Double
    public var now: Double
    public var direction: Direction

    /// "80 → 82.5 kg", "30 → 36 reps", "0:45 → 1:00".
    public func change(unit: WeightUnit = .kg) -> String {
        switch measure {
        case .oneRepMax:
            return "\(Format.number((unit.fromKilograms(before) * 2).rounded() / 2)) → \(Format.weight((now * 2).rounded() / 2, unit: unit))"
        case .reps: return "\(Int(before)) → \(Int(now)) reps"
        case .seconds: return "\(Format.clock(Int(before))) → \(Format.clock(Int(now)))"
        }
    }
}

/// A session compared with the previous one of the same workout.
public struct SessionComparison: Hashable, Sendable {
    public var previousDate: Date
    public var exercises: [ExerciseComparison]
    /// Volume (kg) now minus before.
    public var volumeDelta: Double
    public var up: Int { exercises.filter { $0.direction == .up }.count }
    public var same: Int { exercises.filter { $0.direction == .same }.count }
    public var down: Int { exercises.filter { $0.direction == .down }.count }
}

/// A trend of one exercise over a period.
public struct ExerciseTrend: Hashable, Sendable, Identifiable {
    public var id: String { exerciseKey }
    public var exerciseKey: String
    public var exerciseName: String
    public var measure: ExerciseComparison.Measure
    /// (date, value) oldest first.
    public var points: [TrendPoint]
    public var first: Double { points.first?.value ?? 0 }
    public var last: Double { points.last?.value ?? 0 }
    public var delta: Double { last - first }
    public var sessions: Int { points.count }
}

public struct TrendPoint: Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var value: Double
    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct ExerciseSummary: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var sessions: Int
    public var lastDate: Date
}

public enum StatsEngine {
    /// Epley estimate.
    public static func oneRepMax(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        if reps == 1 { return weight }
        return weight * (1 + Double(reps) / 30)
    }

    public static func weekly(_ sessions: [SessionRecord], calendar: Calendar = .training(), weeks: Int = 12, now: Date = Date()) -> [WeekStat] {
        let current = calendar.weekStart(for: now)
        var stats: [Date: WeekStat] = [:]
        for offset in 0..<max(1, weeks) {
            let start = calendar.addingWeeks(-offset, to: current)
            stats[start] = WeekStat(weekStart: start, sessions: 0, workoutDays: 0, minutes: 0, volumeKg: 0, sets: 0, energyKcal: 0)
        }
        var days: [Date: Set<Date>] = [:]
        for session in sessions {
            let start = calendar.weekStart(for: session.date)
            guard var stat = stats[start] else { continue }
            stat.sessions += 1
            stat.minutes += session.durationSeconds / 60
            stat.volumeKg += session.content.volumeKg
            stat.sets += session.content.completedSets
            stat.energyKcal += session.energyKcal
            stats[start] = stat
            days[start, default: []].insert(calendar.startOfDay(for: session.date))
        }
        for (start, set) in days { stats[start]?.workoutDays = set.count }
        return stats.values.sorted { $0.weekStart < $1.weekStart }
    }

    /// History of one exercise, oldest first.
    public static func history(of exerciseKey: String, in sessions: [SessionRecord]) -> [ExercisePoint] {
        var points: [ExercisePoint] = []
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            let items = session.content.allItems.filter { $0.exerciseKey == exerciseKey }
            guard !items.isEmpty else { continue }
            let done = items.flatMap { $0.sets.filter(\.isDone) }
            guard !done.isEmpty else { continue }
            let bestWeight = done.compactMap(\.effectiveWeight).max()
            let bestReps = done.compactMap(\.effectiveReps).max()
            let bestSeconds = done.compactMap(\.effectiveSeconds).max()
            let orm = done.map { oneRepMax(weight: $0.effectiveWeight ?? 0, reps: $0.effectiveReps ?? 0) }.max()
            let volume = done.reduce(0.0) { $0 + Double($1.effectiveReps ?? 0) * ($1.effectiveWeight ?? 0) }
            points.append(ExercisePoint(
                sessionID: session.id, date: session.date, bestWeight: bestWeight, bestReps: bestReps,
                bestSeconds: bestSeconds, estimatedOneRepMax: (orm ?? 0) > 0 ? orm : nil, volume: volume, sets: done
            ))
        }
        return points
    }

    /// Sets performed the last time this exercise was done before `date`.
    public static func lastPerformance(of exerciseKey: String, in sessions: [SessionRecord], before date: Date = .distantFuture, excluding sessionID: UUID? = nil) -> [WorkoutSet]? {
        let sorted = sessions.filter { $0.date < date && $0.id != sessionID }.sorted { $0.date > $1.date }
        for session in sorted {
            if let item = session.content.allItems.first(where: { $0.exerciseKey == exerciseKey && $0.completedSets > 0 }) {
                return item.sets
            }
        }
        return nil
    }

    public static func personalRecords(in sessions: [SessionRecord]) -> [PersonalRecord] {
        var best: [String: PersonalRecord] = [:]
        func consider(_ record: PersonalRecord) {
            if let existing = best[record.id], existing.value >= record.value { return }
            best[record.id] = record
        }
        for session in sessions {
            for item in session.content.allItems {
                for set in item.sets where set.isDone {
                    if let w = set.effectiveWeight, w > 0 {
                        consider(PersonalRecord(exerciseKey: item.exerciseKey, exerciseName: item.name, metric: .weight, value: w, date: session.date))
                        if let r = set.effectiveReps, r > 0 {
                            consider(PersonalRecord(exerciseKey: item.exerciseKey, exerciseName: item.name, metric: .oneRepMax, value: oneRepMax(weight: w, reps: r), date: session.date))
                        }
                    }
                    if let r = set.effectiveReps, r > 0, (set.effectiveWeight ?? 0) <= 0 {
                        consider(PersonalRecord(exerciseKey: item.exerciseKey, exerciseName: item.name, metric: .reps, value: Double(r), date: session.date))
                    }
                    if item.mode == .time, let s = set.effectiveSeconds, s > 0 {
                        consider(PersonalRecord(exerciseKey: item.exerciseKey, exerciseName: item.name, metric: .duration, value: Double(s), date: session.date))
                    }
                }
            }
        }
        return best.values.sorted { $0.date > $1.date }
    }

    /// Records set in a specific session (compared with everything before it): at most one per
    /// exercise, in the order weight > e1RM > reps (bodyweight/band sets only) > duration.
    public static func newRecords(in session: SessionRecord, comparedTo previous: [SessionRecord]) -> [PersonalRecord] {
        let before = personalRecords(in: previous.filter { $0.date < session.date && $0.id != session.id })
        let beforeMap = Dictionary(before.map { ($0.id, $0.value) }, uniquingKeysWith: { Swift.max($0, $1) })
        let beaten = personalRecords(in: [session]).filter { record in
            guard record.metric != .volume else { return false }
            guard let old = beforeMap[record.id] else { return false }
            return record.value > old + 0.0001
        }
        return collapsedPerExercise(beaten)
    }

    /// One record per exercise (the most meaningful one), newest first.
    public static func collapsedPerExercise(_ records: [PersonalRecord]) -> [PersonalRecord] {
        var best: [String: PersonalRecord] = [:]
        for record in records {
            if let existing = best[record.exerciseKey], existing.priority <= record.priority { continue }
            best[record.exerciseKey] = record
        }
        return best.values.sorted { ($0.date, $1.exerciseName) > ($1.date, $0.exerciseName) }
    }

    /// The comparable measure of one exercise's done sets: best e1RM for weighted reps, total reps for
    /// bodyweight/band reps, longest hold for timed sets.
    static func measure(of item: WorkoutItem) -> (ExerciseComparison.Measure, Double)? {
        let done = item.sets.filter { $0.isDone && $0.kind != .warmup }
        guard !done.isEmpty else { return nil }
        if item.mode == .time {
            let best = done.compactMap(\.effectiveSeconds).max() ?? 0
            return best > 0 ? (.seconds, Double(best)) : nil
        }
        let weighted = done.filter { ($0.effectiveWeight ?? 0) > 0 && ($0.effectiveReps ?? 0) > 0 }
        if !weighted.isEmpty {
            let best = weighted.map { oneRepMax(weight: $0.effectiveWeight ?? 0, reps: $0.effectiveReps ?? 0) }.max() ?? 0
            return (.oneRepMax, best)
        }
        let reps = done.compactMap(\.effectiveReps).reduce(0, +)
        return reps > 0 ? (.reps, Double(reps)) : nil
    }

    /// Compares a session with the latest earlier performed one of the same workout (same template, or
    /// the same title when there is no template). Nil when there is nothing to compare with.
    public static func compare(_ session: SessionRecord, templateID: UUID?, previous sessions: [SessionRecord], templateOf: (UUID) -> UUID? = { _ in nil }) -> SessionComparison? {
        let earlier = sessions
            .filter { $0.id != session.id && $0.date < session.date && $0.content.completedSets > 0 }
            .sorted { $0.date > $1.date }
        let match = earlier.first { candidate in
            if let templateID, let other = templateOf(candidate.id) { return other == templateID }
            return candidate.title.lowercased() == session.title.lowercased()
        }
        guard let previous = match else { return nil }
        var comparisons: [ExerciseComparison] = []
        var seen = Set<String>()
        for item in session.content.allItems where !seen.contains(item.exerciseKey) {
            seen.insert(item.exerciseKey)
            guard let now = measure(of: item),
                  let oldItem = previous.content.allItems.first(where: { $0.exerciseKey == item.exerciseKey }),
                  let before = measure(of: oldItem), before.0 == now.0 else { continue }
            let tolerance = now.0 == .oneRepMax ? 0.25 : 0.5
            let direction: ExerciseComparison.Direction = now.1 > before.1 + tolerance ? .up : (now.1 < before.1 - tolerance ? .down : .same)
            comparisons.append(ExerciseComparison(exerciseKey: item.exerciseKey, exerciseName: item.name, measure: now.0,
                                                  before: before.1, now: now.1, direction: direction))
        }
        guard !comparisons.isEmpty else { return nil }
        return SessionComparison(previousDate: previous.date, exercises: comparisons,
                                 volumeDelta: session.content.volumeKg - previous.content.volumeKg)
    }

    /// The trend of one exercise since a date (one point per session, oldest first).
    public static func trend(of exerciseKey: String, in sessions: [SessionRecord], since: Date) -> ExerciseTrend? {
        var points: [TrendPoint] = []
        var measureKind: ExerciseComparison.Measure?
        var name = ""
        for session in sessions.sorted(by: { $0.date < $1.date }) where session.date >= since {
            guard let item = session.content.allItems.first(where: { $0.exerciseKey == exerciseKey && $0.completedSets > 0 }),
                  let m = measure(of: item) else { continue }
            if measureKind == nil { measureKind = m.0 }
            guard m.0 == measureKind else { continue }
            name = item.name
            points.append(TrendPoint(date: session.date, value: m.1))
        }
        guard let measureKind, !points.isEmpty else { return nil }
        return ExerciseTrend(exerciseKey: exerciseKey, exerciseName: name, measure: measureKind, points: points)
    }

    /// The most-trained exercises since a date with their trends (most sessions first).
    public static func topTrends(in sessions: [SessionRecord], since: Date, limit: Int = 6) -> [ExerciseTrend] {
        var counts: [String: Int] = [:]
        for session in sessions where session.date >= since {
            for key in Set(session.content.allItems.filter { $0.completedSets > 0 }.map(\.exerciseKey)) {
                counts[key, default: 0] += 1
            }
        }
        let keys = counts.filter { $0.value >= 2 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit * 2).map(\.key)
        return Array(keys.compactMap { trend(of: $0, in: sessions, since: since) }.filter { $0.sessions >= 2 }.prefix(limit))
    }

    public static func exercises(in sessions: [SessionRecord]) -> [ExerciseSummary] {
        var map: [String: ExerciseSummary] = [:]
        for session in sessions {
            for item in session.content.allItems where item.completedSets > 0 {
                if var existing = map[item.exerciseKey] {
                    existing.sessions += 1
                    if session.date > existing.lastDate {
                        existing.lastDate = session.date
                        existing.name = item.name
                    }
                    map[item.exerciseKey] = existing
                } else {
                    map[item.exerciseKey] = ExerciseSummary(key: item.exerciseKey, name: item.name, sessions: 1, lastDate: session.date)
                }
            }
        }
        return map.values.sorted { $0.lastDate > $1.lastDate }
    }

    public static func muscleSets(in sessions: [SessionRecord], since: Date, lookup: (WorkoutItem) -> [String]) -> [(muscle: String, sets: Int)] {
        var totals: [String: Int] = [:]
        for session in sessions where session.date >= since {
            for (muscle, count) in session.content.muscleSets(completedOnly: true, lookup: lookup) {
                totals[muscle, default: 0] += count
            }
        }
        return totals.map { (muscle: $0.key, sets: $0.value) }.sorted { $0.sets > $1.sets }
    }

    public static func kindMinutes(in sessions: [SessionRecord], since: Date) -> [(kind: WorkoutKind, minutes: Double)] {
        var totals: [WorkoutKind: Double] = [:]
        for session in sessions where session.date >= since {
            totals[session.kind, default: 0] += session.durationSeconds / 60
        }
        return totals.map { (kind: $0.key, minutes: $0.value) }.sorted { $0.minutes > $1.minutes }
    }
}

/// Totals of a period (Progress tiles).
public struct PeriodTotals: Hashable, Sendable {
    public var workouts: Int
    public var seconds: Double
    public var sets: Int
    public var volumeKg: Double

    public init(workouts: Int = 0, seconds: Double = 0, sets: Int = 0, volumeKg: Double = 0) {
        self.workouts = workouts
        self.seconds = seconds
        self.sets = sets
        self.volumeKg = volumeKg
    }
}

/// Minutes per workout type, George workouts and Apple Health workouts together.
public struct TypeTime: Hashable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    /// For colour and symbol.
    public var kind: WorkoutKind
    public var minutes: Double
    /// Some of the time comes from Apple Health workouts (tennis, runs …).
    public var includesHealth: Bool

    public init(title: String, kind: WorkoutKind, minutes: Double, includesHealth: Bool) {
        self.title = title
        self.kind = kind
        self.minutes = minutes
        self.includesHealth = includesHealth
    }
}

public extension StatsEngine {
    /// Workouts, active time, done sets and volume of the sessions in an interval.
    static func totals(of sessions: [SessionRecord], in interval: DateInterval) -> PeriodTotals {
        var totals = PeriodTotals()
        for session in sessions where session.date >= interval.start && session.date < interval.end {
            totals.workouts += 1
            totals.seconds += session.durationSeconds
            totals.sets += session.content.completedSets
            totals.volumeKg += session.content.volumeKg
        }
        return totals
    }

    /// All-time records that were set since a date – one per exercise (the most meaningful), newest first.
    static func recordsSet(in sessions: [SessionRecord], since: Date) -> [PersonalRecord] {
        collapsedPerExercise(personalRecords(in: sessions).filter { $0.date >= since && $0.metric != .volume })
    }

    /// Minutes per type in an interval: George workouts by kind, Apple Health workouts by sport.
    /// A Health sport with the same name as a George kind ("Yoga") shares its row.
    static func timeByType(_ sessions: [SessionRecord], external: [ExternalWorkout] = [], in interval: DateInterval) -> [TypeTime] {
        var rows: [String: TypeTime] = [:]
        func add(title: String, kind: WorkoutKind, minutes: Double, health: Bool) {
            let key = title.lowercased()
            if var row = rows[key] {
                row.minutes += minutes
                row.includesHealth = row.includesHealth || health
                rows[key] = row
            } else {
                rows[key] = TypeTime(title: title, kind: kind, minutes: minutes, includesHealth: health)
            }
        }
        for session in sessions where session.date >= interval.start && session.date < interval.end {
            add(title: session.kind.displayName, kind: session.kind, minutes: session.durationSeconds / 60, health: false)
        }
        for workout in external where workout.start >= interval.start && workout.start < interval.end {
            add(title: workout.name, kind: WorkoutKind(workout.activity), minutes: workout.durationSeconds / 60, health: true)
        }
        return rows.values.filter { $0.minutes > 0 }.sorted { ($0.minutes, $1.title) > ($1.minutes, $0.title) }
    }
}

/// Energy estimate from METs when no heart-rate based number is available.
public enum EnergyEstimator {
    /// kcal = MET × body mass (kg) × hours, scaled ±25% by effort (1–10, 5 = neutral).
    public static func kilocalories(kind: WorkoutKind, durationSeconds: Double, bodyMassKg: Double, effort: Int? = nil) -> Double {
        guard durationSeconds > 0 else { return 0 }
        var met = kind.met
        if let effort, effort > 0 {
            let factor = 1 + (Double(min(10, max(1, effort))) - 5) * 0.05
            met *= factor
        }
        return met * max(30, bodyMassKg) * durationSeconds / 3600
    }
}
