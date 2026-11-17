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
        case .fatigued: return "Recovering"
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

/// One point of a freshness chart.
public struct FreshnessSample: Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public var date: Date
    /// 0…1 (1 = fully recovered).
    public var freshness: Double

    public init(date: Date, freshness: Double) {
        self.date = date
        self.freshness = freshness
    }
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
    /// Average weekly load of the history so far (up to 6 weeks, at least 2).
    public var chronic: Double
    public var status: LoadStatus
    /// The optimal acute:chronic band used for this point (from the training profile).
    public var lowRatio: Double = MuscleEngine.optimalLowRatio
    public var highRatio: Double = MuscleEngine.optimalHighRatio

    public init(day: Date, acute: Double, chronic: Double, status: LoadStatus,
                lowRatio: Double = MuscleEngine.optimalLowRatio, highRatio: Double = MuscleEngine.optimalHighRatio) {
        self.day = day
        self.acute = acute
        self.chronic = chronic
        self.status = status
        self.lowRatio = lowRatio
        self.highRatio = highRatio
    }

    public var optimalLow: Double { chronic * lowRatio }
    public var optimalHigh: Double { chronic * highRatio }
    /// This week's load relative to the usual week (1 = usual), 0 without history.
    public var ratio: Double { chronic > 0.01 ? acute / chronic : 0 }
    /// "150 %" – this week relative to the usual week.
    public var percentOfUsual: Int { Int((ratio * 100).rounded()) }
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
/// * Muscular load: the last 7 days (acute) vs. the weekly average of the history so far (chronic:
///   up to 6 weeks; while there is less history, the average is taken over the weeks that exist,
///   at least 2, so steady training in the first weeks is not read as overload). The
///   acute:chronic ratio gives the status; the optimal range is 0.8…1.3 × chronic by default and
///   follows the training profile (`loadBand`).
/// * Stretching, yoga, mobility and cardio add load but no hard sets (they don't count toward set targets).
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
    /// The optimal acute:chronic band (default 0.8…1.3; beginners get a narrower one).
    public let loadBand: ClosedRange<Double>
    /// Events per muscle (oldest first) – freshness and capacity only look at one muscle.
    private let eventsByGroup: [MuscleGroup: [MuscleEvent]]

    public init(events: [MuscleEvent], calendar: Calendar = .training(), recoveryScale: Double = 1,
                loadBand: ClosedRange<Double> = MuscleEngine.optimalLowRatio...MuscleEngine.optimalHighRatio) {
        let sorted = events.sorted { $0.date < $1.date }
        self.events = sorted
        self.calendar = calendar
        self.recoveryScale = max(0.5, recoveryScale)
        self.loadBand = loadBand
        self.eventsByGroup = Dictionary(grouping: sorted, by: \.group)
    }

    /// Events of one muscle up to (and including) `date`, oldest first (binary search on the date).
    func groupEvents(_ group: MuscleGroup, through date: Date) -> ArraySlice<MuscleEvent> {
        guard let list = eventsByGroup[group] else { return [] }
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].date <= date { low = mid + 1 } else { high = mid }
        }
        return list[0..<low]
    }

    /// Kinds whose sets stretch or move rather than load: they add a little load but no hard sets.
    public static func countsAsHardSets(_ kind: WorkoutKind) -> Bool {
        !["stretch", "yoga", "mobility", "cardio"].contains(kind.rawValue)
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
                // Subjective fatigue after the exercise (0–100 %): 50 % is neutral, 100 % counts 1.4×.
                let fatigueFactor = item.fatigue.map { 0.6 + 0.8 * min(1, max(0, $0)) } ?? 1
                for set in done {
                    let base = setLoad(kind: set.kind, rpe: set.rpe, sessionEffort: sessionEffort, workoutKind: workoutKind) * fatigueFactor
                    let sides: Double = item.perSide ? 2 : 1
                    let volume = Double(set.effectiveReps ?? 0) * (set.effectiveWeight ?? 0) * sides
                    let countsAsSet = set.kind != .warmup && countsAsHardSets(workoutKind)
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
        let upTo = groupEvents(group, through: date)
        let list = eventsByGroup[group] ?? []
        var index = MuscleEngine.firstIndex(in: list, notBefore: since)
        while index < upTo.endIndex {
            perSession[list[index].sessionID, default: 0] += list[index].load
            index += 1
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
        var recentSessions = Set<UUID>()
        let calibrationWindow = date.addingTimeInterval(-42 * 86_400)
        let upTo = groupEvents(group, through: date)
        let list = eventsByGroup[group] ?? []
        // Only the windows that matter are visited (binary search), not the whole history.
        let windowStart = min(calibrationWindow, date.addingTimeInterval(-tau * 8 * 3600))
        var index = MuscleEngine.firstIndex(in: list, notBefore: windowStart)
        while index < upTo.endIndex {
            let event = list[index]
            let hours = date.timeIntervalSince(event.date) / 3600
            if hours < tau * 8 {
                residual += (event.load / cap) * exp(-hours / tau)
            }
            if event.date >= calibrationWindow && event.load >= 0.5 { recentSessions.insert(event.sessionID) }
            index += 1
        }
        let last = upTo.last { $0.load > 0.3 }?.date
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

    /// Freshness of one muscle over time (for charts), in one pass over its events instead of one
    /// full `freshness(of:at:)` per sample. Matches it to within rounding (events older than 8 τ
    /// are not cut off here, they have decayed below 0.04 % anyway).
    public func freshnessSeries(of group: MuscleGroup, from start: Date, to end: Date, stepHours: Double = 3) -> [FreshnessSample] {
        guard end >= start, stepHours > 0 else { return [] }
        let tau = group.recoveryTimeConstant * recoveryScale
        let list = eventsByGroup[group] ?? []
        var samples: [FreshnessSample] = []
        samples.reserveCapacity(Int(end.timeIntervalSince(start) / (stepHours * 3600)) + 1)
        var index = 0
        var decayed = 0.0 // Σ load · e^(−age/τ) of the events up to the previous sample
        var previous: Date?
        var date = start
        var guardCount = 0
        while date <= end && guardCount < 10_000 {
            if let previous {
                decayed *= exp(-date.timeIntervalSince(previous) / 3600 / tau)
            }
            while index < list.count && list[index].date <= date {
                decayed += list[index].load * exp(-date.timeIntervalSince(list[index].date) / 3600 / tau)
                index += 1
            }
            let fatigue = min(1, decayed / capacity(for: group, at: date))
            samples.append(FreshnessSample(date: date, freshness: max(0, 1 - fatigue)))
            previous = date
            date = date.addingTimeInterval(stepHours * 3600)
            guardCount += 1
        }
        return samples
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

    /// The events of the whole body (nil) or one muscle, oldest first.
    func eventList(_ group: MuscleGroup?) -> [MuscleEvent] {
        guard let group else { return events }
        return eventsByGroup[group] ?? []
    }

    /// Index of the first event at or after `date` in a date-sorted list (binary search).
    static func firstIndex(in list: [MuscleEvent], notBefore date: Date) -> Int {
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].date < date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Daily load totals (optionally for one muscle) from `start` to `end`.
    func dailyLoads(group: MuscleGroup?, from start: Date, to end: Date) -> [(day: Date, load: Double)] {
        var byDay: [Date: Double] = [:]
        let list = eventList(group)
        var index = MuscleEngine.firstIndex(in: list, notBefore: start)
        while index < list.count && list[index].date < end {
            byDay[calendar.startOfDay(for: list[index].date), default: 0] += list[index].load
            index += 1
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
        let list = eventList(group)
        let firstEvent = list.first?.date
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
        let qualifying = list.filter { $0.load >= 0.5 }
        var windowCounts: [UUID: Int] = [:]
        var head = 0
        var tail = 0
        let minimumSessions = group == nil ? 4 : 3
        var points: [LoadPoint] = []
        var recentRatios: [Double] = []
        for (index, entry) in series.enumerated() {
            let weeklyAcute = windowSum(endingAt: index, days: 7)
            // The usual week: averaged over the history that exists (2…6 weeks), so the first weeks of
            // steady training read as "productive", not as overload against an empty past.
            let historyDays: Int
            if let firstEvent {
                historyDays = max(14, min(42, calendar.daysBetween(firstEvent, entry.day) + 1))
            } else {
                historyDays = 42
            }
            let weeklyChronic = windowSum(endingAt: index, days: 42) / (Double(historyDays) / 7)
            let ratio = weeklyChronic > 0.01 ? weeklyAcute / weeklyChronic : 0
            // Ratios of the first two weeks swing wildly (little history) – they don't count as "was high".
            if let firstEvent, calendar.daysBetween(firstEvent, entry.day) >= 14 {
                recentRatios.append(ratio)
                if recentRatios.count > 14 { recentRatios.removeFirst() }
            }

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
                status = MuscleEngine.classify(ratio: ratio, recentRatios: recentRatios, band: loadBand)
            } else {
                status = .calibrating
            }
            if index >= series.count - days {
                points.append(LoadPoint(day: entry.day, acute: weeklyAcute, chronic: weeklyChronic, status: status,
                                        lowRatio: loadBand.lowerBound, highRatio: loadBand.upperBound))
            }
        }
        let current = points.last ?? LoadPoint(day: calendar.startOfDay(for: now), acute: 0, chronic: 0, status: .calibrating,
                                               lowRatio: loadBand.lowerBound, highRatio: loadBand.upperBound)
        return LoadSummary(current: current, history: points)
    }

    static func classify(ratio: Double, recentRatios: [Double],
                         band: ClosedRange<Double> = MuscleEngine.optimalLowRatio...MuscleEngine.optimalHighRatio) -> LoadStatus {
        if ratio < band.lowerBound { return .detraining }
        if ratio < 1.0 {
            let wasHigh = recentRatios.dropLast().contains { $0 >= 1.1 }
            return wasHigh ? .peaking : .maintaining
        }
        if ratio <= band.upperBound { return .productive }
        if ratio <= band.upperBound + 0.2 { return .fatigued }
        return .overtraining
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
            let list = eventsByGroup[group] ?? []
            var index = MuscleEngine.firstIndex(in: list, notBefore: start)
            var sets = 0.0
            while index < list.count && list[index].date < end {
                sets += list[index].sets
                index += 1
            }
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
    /// Stretch, yoga, mobility and cardio items don't count as sets (see `MuscleEngine.countsAsHardSets`).
    public static func sets(of content: WorkoutContent, completedOnly: Bool, kind: WorkoutKind? = nil, contributions: (WorkoutItem) -> [MuscleContribution]) -> [MuscleGroup: Double] {
        var result: [MuscleGroup: Double] = [:]
        for item in content.allItems {
            if let itemKind = item.kind ?? kind, !MuscleEngine.countsAsHardSets(itemKind) { continue }
            let muscles = contributions(item)
            let count = item.sets.filter { $0.kind != .warmup && (!completedOnly || $0.isDone) }.count
            guard count > 0 else { continue }
            for muscle in muscles { result[muscle.group, default: 0] += Double(count) * muscle.weight }
        }
        return result
    }
}
