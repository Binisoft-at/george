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
                    if let r = set.effectiveReps, r > 0 {
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

    /// Records set in a specific session (compared with everything before it).
    public static func newRecords(in session: SessionRecord, comparedTo previous: [SessionRecord]) -> [PersonalRecord] {
        let before = personalRecords(in: previous.filter { $0.date < session.date && $0.id != session.id })
        let beforeMap = Dictionary(before.map { ($0.id, $0.value) }, uniquingKeysWith: { Swift.max($0, $1) })
        return personalRecords(in: [session]).filter { record in
            guard record.metric == .weight || record.metric == .oneRepMax || record.metric == .duration else { return false }
            guard let old = beforeMap[record.id] else { return false }
            return record.value > old + 0.0001
        }
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
