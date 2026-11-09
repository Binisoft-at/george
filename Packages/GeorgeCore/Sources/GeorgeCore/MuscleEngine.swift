import Foundation

/// One completed set's effect on one muscle.
public struct MuscleEvent: Hashable, Sendable {
    public var date: Date
    public var sessionID: UUID
    public var group: MuscleGroup
    /// Hard-set equivalents (set type, effort and contribution weight applied).
    public var load: Double
    /// Fractional set count (1 per primary, 0.5 per secondary) — what "Total Sets" shows.
    public var sets: Double
    /// reps × kg, scaled by contribution weight.
    public var volumeKg: Double
    public var exerciseKey: String
    public var exerciseName: String
}

public enum FreshnessStatus: String, Sendable, CaseIterable {
    case recovered, fatigued, depleted
    public var displayName: String {
        switch self {
        case .recovered: return "Recovered"
        case .fatigued: return "Fatigued"
        case .depleted: return "Depleted"
        }
    }
}

public struct MuscleFreshness: Hashable, Sendable, Identifiable {
    public var id: MuscleGroup { group }
    public var group: MuscleGroup
    /// 0…1 (1 = fully recovered).
    public var freshness: Double
    public var status: FreshnessStatus
    /// Fewer than 3 recent sessions train this muscle: the estimate is still being calibrated.
    public var isCalibrating: Bool
    public var lastTrained: Date?
    /// Hours until freshness reaches the "Recovered" threshold (0 if already recovered).
    public var hoursUntilRecovered: Double
    /// The hard-set capacity used for this muscle (personalised from typical session volume).
    public var capacity: Double

    public var percent: Int { Int((freshness * 100).rounded()) }
}

public enum LoadStatus: String, Sendable, CaseIterable, Identifiable {
    case calibrating, detraining, peaking, maintaining, productive, fatigued, overtraining
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .calibrating: return "Calibrating"
        case .detraining: return "Detraining"
        case .peaking: return "Peaking"
        case .maintaining: return "Maintaining"
        case .productive: return "Productive"
        case .fatigued: return "Fatigued"
        case .overtraining: return "Overtraining"
        }
    }

    public var explanation: String {
        switch self {
        case .calibrating: return "Not enough history yet — keep training 1–2× a week per muscle for a few weeks."
        case .detraining: return "Recent load is well below your usual level; strength and muscle may slowly decline."
        case .peaking: return "Load is easing off after a hard block — a good time to test strength or rest up."
        case .maintaining: return "Enough to keep what you have, not much new stimulus."
        case .productive: return "Challenging enough to drive progress while still recoverable."
        case .fatigued: return "Clearly above your usual level. Fine short-term — plan an easier week soon."
        case .overtraining: return "Far above what you're used to. Injury and burnout risk rise — back off."
        }
    }
}

public struct LoadPoint: Hashable, Sendable, Identifiable {
    public var id: Date { day }
    public var day: Date
    /// Load of the last 7 days.
    public var acute: Double
    /// Average weekly load of the last 6 weeks.
    public var chronic: Double
    public var status: LoadStatus
    public var optimalLow: Double { chronic * MuscleEngine.optimalLowRatio }
    public var optimalHigh: Double { chronic * MuscleEngine.optimalHighRatio }
}

public struct LoadSummary: Sendable {
    public var current: LoadPoint
    /// Oldest first.
    public var history: [LoadPoint]

    /// Days per status in the history.
    public var breakdown: [(status: LoadStatus, days: Int)] {
        LoadStatus.allCases.map { status in (status: status, days: history.filter { $0.status == status }.count) }
    }

    /// Upper end for a gauge.
    public var gaugeMax: Double {
        max(current.acute * 1.15, current.optimalHigh * 1.4, 10).rounded(.up)
    }
}

public struct MuscleTotal: Hashable, Sendable, Identifiable {
    public var id: MuscleGroup { group }
    public var group: MuscleGroup
    public var sets: Double
    public var volumeKg: Double
    public var load: Double
    public var sessions: Int
    /// Sets per week over the interval.
    public var setsPerWeek: Double
}

public struct MuscleExerciseShare: Hashable, Sendable, Identifiable {
    public var id: String { exerciseKey }
    public var exerciseKey: String
    public var exerciseName: String
    public var sets: Double
}

/// Muscle-level analytics: freshness (recovery per muscle), muscular load and range totals.
///
/// * Each completed set becomes "hard-set equivalents" per muscle: set type (warm-up 0.25, working 1,
///   drop 0.75, failure 1.1) × effort (RPE, or the session's effort rating) × contribution
///   (1 primary, 0.5 secondary). Stretching/yoga/mobility sets barely load muscles (0.15).
/// * Freshness: every set adds fatigue `load / capacity` that decays as e^(-t/τ) with a muscle-size
///   dependent τ. Capacity is ~10 hard sets (the per-session point of diminishing returns),
///   personalised to 1.25 × your typical session volume for that muscle (6…16).
/// * Muscular load: the last 7 days (acute) vs. the weekly average of the last 6 weeks (chronic);
///   the acute:chronic ratio gives the status, the optimal range is 0.8…1.3 × chronic.
public struct MuscleEngine: Sendable {
    public static let recoveredThreshold = 0.8
    public static let depletedThreshold = 0.4
    public static let optimalLowRatio = 0.8
    public static let optimalHighRatio = 1.3
    public static let defaultCapacity = 10.0

    public var calendar: Calendar
    public let events: [MuscleEvent]
    /// Stretches recovery times (≥ 1 for older lifters, see `TrainingProfile.recoveryScale`).
    public let recoveryScale: Double

    public init(events: [MuscleEvent], calendar: Calendar = .training(), recoveryScale: Double = 1) {
        self.events = events.sorted { $0.date < $1.date }
        self.calendar = calendar
        self.recoveryScale = max(0.5, recoveryScale)
    }

    // MARK: Building events

    /// Hard-set equivalent of one completed set before muscle weighting.
    public static func setLoad(kind: SetKind, rpe: Double?, sessionEffort: Int, workoutKind: WorkoutKind) -> Double {
        let typeFactor: Double
        switch kind {
        case .warmup: typeFactor = 0.25
        case .working: typeFactor = 1
        case .drop: typeFactor = 0.75
        case .failure: typeFactor = 1.1
        }
        var effortFactor = 1.0
        if let rpe, rpe > 0 {
            effortFactor = 0.5 + min(10, rpe) * 0.0625
        } else if sessionEffort > 0 {
            effortFactor = 0.5 + Double(min(10, sessionEffort)) * 0.0625
        }
        let kindFactor: Double
        switch workoutKind.rawValue {
        case "stretch", "yoga", "mobility": kindFactor = 0.15
        case "cardio": kindFactor = 0.4
        default: kindFactor = 1
        }
        return typeFactor * effortFactor * kindFactor
    }

    /// Turns sessions into per-muscle events. `contributions` resolves which muscles an item trains.
    public static func events(
        from sessions: [SessionRecord],
        effort: (UUID) -> Int = { _ in 0 },
        contributions: (WorkoutItem) -> [MuscleContribution]
    ) -> [MuscleEvent] {
        var result: [MuscleEvent] = []
        for session in sessions {
            let sessionEffort = effort(session.id)
            for item in session.content.allItems {
                let done = item.sets.filter(\.isDone)
                guard !done.isEmpty else { continue }
                let muscles = contributions(item)
                guard !muscles.isEmpty else { continue }
                let workoutKind = item.kind ?? session.kind
                for set in done {
                    let base = setLoad(kind: set.kind, rpe: set.rpe, sessionEffort: sessionEffort, workoutKind: workoutKind)
                    let sides: Double = item.perSide ? 2 : 1
                    let volume = Double(set.effectiveReps ?? 0) * (set.effectiveWeight ?? 0) * sides
                    let countsAsSet = set.kind != .warmup
                    for muscle in muscles {
                        result.append(MuscleEvent(
                            date: set.doneAt ?? session.date,
                            sessionID: session.id,
                            group: muscle.group,
                            load: base * muscle.weight,
                            sets: countsAsSet ? muscle.weight : 0,
                            volumeKg: volume * muscle.weight,
                            exerciseKey: item.exerciseKey,
                            exerciseName: item.name
                        ))
                    }
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    // MARK: Freshness

    /// Typical per-session hard sets for a muscle over the last 6 weeks → personal capacity.
    public func capacity(for group: MuscleGroup, at date: Date) -> Double {
        let since = date.addingTimeInterval(-42 * 86_400)
        var perSession: [UUID: Double] = [:]
        for event in events where event.group == group && event.date >= since && event.date <= date {
            perSession[event.sessionID, default: 0] += event.load
        }
        let loads = perSession.values.filter { $0 >= 1 }.sorted()
        guard loads.count >= 3 else { return MuscleEngine.defaultCapacity }
        let median = loads[loads.count / 2]
        return min(16, max(6, median * 1.25))
    }

    public func freshness(of group: MuscleGroup, at date: Date = Date()) -> MuscleFreshness {
        let tau = group.recoveryTimeConstant * recoveryScale
        let cap = capacity(for: group, at: date)
        var residual = 0.0
        var last: Date?
        var recentSessions = Set<UUID>()
        let calibrationWindow = date.addingTimeInterval(-42 * 86_400)
        for event in events where event.group == group && event.date <= date {
            let hours = date.timeIntervalSince(event.date) / 3600
            if hours < tau * 8 {
                residual += (event.load / cap) * exp(-hours / tau)
            }
            if event.load > 0.3 { last = event.date }
            if event.date >= calibrationWindow && event.load >= 0.5 { recentSessions.insert(event.sessionID) }
        }
        let fatigue = min(1, residual)
        let freshness = max(0, 1 - fatigue)
        let status: FreshnessStatus
        if freshness >= MuscleEngine.recoveredThreshold { status = .recovered }
        else if freshness >= MuscleEngine.depletedThreshold { status = .fatigued }
        else { status = .depleted }
        // Solve residual·e^(-t/τ) = 1 − threshold for t (residual uncapped for accuracy).
        let target = 1 - MuscleEngine.recoveredThreshold
        let hours = residual > target ? tau * log(residual / target) : 0
        return MuscleFreshness(
            group: group, freshness: freshness, status: status, isCalibrating: recentSessions.count < 3,
            lastTrained: last, hoursUntilRecovered: hours, capacity: cap
        )
    }

    public func freshness(at date: Date = Date()) -> [MuscleFreshness] {
        MuscleGroup.allCases.map { freshness(of: $0, at: date) }
    }

    /// Average freshness weighted by how much a workout would load each muscle (0…1).
    public func readiness(for plannedLoad: [MuscleGroup: Double], at date: Date = Date()) -> Double {
        let total = plannedLoad.values.reduce(0, +)
        guard total > 0 else { return 1 }
        var sum = 0.0
        for (group, load) in plannedLoad {
            sum += freshness(of: group, at: date).freshness * load
        }
        return sum / total
    }

    // MARK: Muscular load

    /// Daily load totals (optionally for one muscle) from `start` to `end`.
    func dailyLoads(group: MuscleGroup?, from start: Date, to end: Date) -> [(day: Date, load: Double)] {
        var byDay: [Date: Double] = [:]
        for event in events where (group == nil || event.group == group) && event.date >= start && event.date < end {
            byDay[calendar.startOfDay(for: event.date), default: 0] += event.load
        }
        var result: [(Date, Double)] = []
        var day = calendar.startOfDay(for: start)
        var guardCount = 0
        while day < end && guardCount < 2000 {
            result.append((day, byDay[day] ?? 0))
            day = calendar.addingDays(1, to: day)
            guardCount += 1
        }
        return result.map { (day: $0.0, load: $0.1) }
    }

    /// Muscular load history (acute vs chronic) for the whole body or one muscle.
    public func loadSummary(group: MuscleGroup? = nil, days: Int = 30, now: Date = Date()) -> LoadSummary {
        let end = calendar.addingDays(1, to: calendar.startOfDay(for: now))
        let warmup = 84 // days of history used to seed the long average
        let start = calendar.addingDays(-(days + warmup), to: end)
        let firstEvent = events.first { group == nil || $0.group == group }?.date
        let series = dailyLoads(group: group, from: start, to: end)
        // Rolling windows: last 7 days vs. the weekly average of the last 6 weeks.
        var prefix: [Double] = [0]
        for entry in series { prefix.append(prefix[prefix.count - 1] + entry.load) }
        func windowSum(endingAt index: Int, days window: Int) -> Double {
            let upper = index + 1
            let lower = max(0, upper - window)
            return prefix[upper] - prefix[lower]
        }
        // Sessions that meaningfully trained the muscle(s), for the calibration rule (sliding 42-day window).
        let qualifying = events.filter { (group == nil || $0.group == group) && $0.load >= 0.5 }
        var windowCounts: [UUID: Int] = [:]
        var head = 0
        var tail = 0
        let minimumSessions = group == nil ? 4 : 3
        var points: [LoadPoint] = []
        var recentRatios: [Double] = []
        for (index, entry) in series.enumerated() {
            let weeklyAcute = windowSum(endingAt: index, days: 7)
            let weeklyChronic = windowSum(endingAt: index, days: 42) / 6
            let ratio = weeklyChronic > 0.01 ? weeklyAcute / weeklyChronic : 0
            recentRatios.append(ratio)
            if recentRatios.count > 14 { recentRatios.removeFirst() }

            let dayEnd = calendar.addingDays(1, to: entry.day)
            let windowStart = calendar.addingDays(-42, to: entry.day)
            while head < qualifying.count && qualifying[head].date < dayEnd {
                windowCounts[qualifying[head].sessionID, default: 0] += 1
                head += 1
            }
            while tail < head && qualifying[tail].date < windowStart {
                let id = qualifying[tail].sessionID
                windowCounts[id, default: 1] -= 1
                if windowCounts[id] ?? 0 <= 0 { windowCounts.removeValue(forKey: id) }
                tail += 1
            }

            let status: LoadStatus
            if let firstEvent, calendar.daysBetween(firstEvent, entry.day) >= 14, windowCounts.count >= minimumSessions {
                status = MuscleEngine.classify(ratio: ratio, recentRatios: recentRatios)
            } else {
                status = .calibrating
            }
            if index >= series.count - days {
                points.append(LoadPoint(day: entry.day, acute: weeklyAcute, chronic: weeklyChronic, status: status))
            }
        }
        let current = points.last ?? LoadPoint(day: calendar.startOfDay(for: now), acute: 0, chronic: 0, status: .calibrating)
        return LoadSummary(current: current, history: points)
    }

    static func classify(ratio: Double, recentRatios: [Double]) -> LoadStatus {
        switch ratio {
        case ..<MuscleEngine.optimalLowRatio:
            return .detraining
        case ..<1.0:
            let wasHigh = recentRatios.dropLast().contains { $0 >= 1.1 }
            return wasHigh ? .peaking : .maintaining
        case ...MuscleEngine.optimalHighRatio:
            return .productive
        case ...1.5:
            return .fatigued
        default:
            return .overtraining
        }
    }

    // MARK: Totals

    public func totals(in interval: DateInterval) -> [MuscleTotal] {
        let weeks = max(1.0, interval.duration / (7 * 86_400))
        var sets: [MuscleGroup: Double] = [:]
        var volume: [MuscleGroup: Double] = [:]
        var load: [MuscleGroup: Double] = [:]
        var sessions: [MuscleGroup: Set<UUID>] = [:]
        for event in events where event.date >= interval.start && event.date < interval.end {
            sets[event.group, default: 0] += event.sets
            volume[event.group, default: 0] += event.volumeKg
            load[event.group, default: 0] += event.load
            sessions[event.group, default: []].insert(event.sessionID)
        }
        return MuscleGroup.allCases.map { group in
            MuscleTotal(
                group: group, sets: sets[group] ?? 0, volumeKg: volume[group] ?? 0, load: load[group] ?? 0,
                sessions: sessions[group]?.count ?? 0, setsPerWeek: (sets[group] ?? 0) / weeks
            )
        }
    }

    /// Which exercises trained a muscle in an interval, most sets first.
    public func exercises(for group: MuscleGroup, in interval: DateInterval) -> [MuscleExerciseShare] {
        var map: [String: MuscleExerciseShare] = [:]
        for event in events where event.group == group && event.date >= interval.start && event.date < interval.end {
            var share = map[event.exerciseKey] ?? MuscleExerciseShare(exerciseKey: event.exerciseKey, exerciseName: event.exerciseName, sets: 0)
            share.sets += event.sets
            map[event.exerciseKey] = share
        }
        return map.values.sorted { $0.sets > $1.sets }
    }

    /// Weekly fractional sets for one muscle (oldest first).
    public func weeklySets(for group: MuscleGroup, weeks: Int, now: Date = Date()) -> [(weekStart: Date, sets: Double)] {
        let current = calendar.weekStart(for: now)
        var result: [(Date, Double)] = []
        for offset in stride(from: weeks - 1, through: 0, by: -1) {
            let start = calendar.addingWeeks(-offset, to: current)
            let end = calendar.addingWeeks(1, to: start)
            let sets = events.filter { $0.group == group && $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.sets }
            result.append((start, sets))
        }
        return result.map { (weekStart: $0.0, sets: $0.1) }
    }
}

/// Planned per-muscle load of a workout (for "targets" maps and readiness).
public enum MusclePlan {
    public static func load(of content: WorkoutContent, kind: WorkoutKind, contributions: (WorkoutItem) -> [MuscleContribution]) -> [MuscleGroup: Double] {
        var result: [MuscleGroup: Double] = [:]
        for item in content.allItems {
            let muscles = contributions(item)
            for set in item.sets {
                let base = MuscleEngine.setLoad(kind: set.kind, rpe: set.targetRPE, sessionEffort: 0, workoutKind: item.kind ?? kind)
                for muscle in muscles { result[muscle.group, default: 0] += base * muscle.weight }
            }
        }
        return result
    }

    /// Fractional set counts per muscle for a workout (done sets only when `completedOnly`).
    public static func sets(of content: WorkoutContent, completedOnly: Bool, contributions: (WorkoutItem) -> [MuscleContribution]) -> [MuscleGroup: Double] {
        var result: [MuscleGroup: Double] = [:]
        for item in content.allItems {
            let muscles = contributions(item)
            let count = item.sets.filter { $0.kind != .warmup && (!completedOnly || $0.isDone) }.count
            guard count > 0 else { continue }
            for muscle in muscles { result[muscle.group, default: 0] += Double(count) * muscle.weight }
        }
        return result
    }
}
