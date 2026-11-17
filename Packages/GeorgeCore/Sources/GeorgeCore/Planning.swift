import Foundation

// MARK: - Streak rules

public enum StreakRules {
    /// Whether a performed George session counts as a training day.
    /// * Rescue workouts: about their (short) planned length, or any set done.
    /// * Otherwise: at least the minimum minutes – or, for strength work that was logged without
    ///   much time (e.g. entered afterwards), 3 done sets. Short stretch routines need the minutes.
    public static func qualifies(minutes: Double, doneSets: Int, isRescue: Bool, kind: WorkoutKind,
                                 minimumMinutes: Double, rescueMinutes: Double) -> Bool {
        if isRescue { return minutes >= rescueMinutes * 0.8 || doneSets > 0 }
        if minutes >= minimumMinutes { return true }
        return doneSets >= 3 && MuscleEngine.countsAsHardSets(kind)
    }
}

// MARK: - Effort defaults

public extension WorkoutKind {
    /// A sensible default effort (1–10) for the finish sheet: calm kinds are easy, the rest "somewhat hard".
    var defaultEffort: Int {
        switch rawValue {
        case "stretch", "yoga", "mobility": return 3
        case "cardio": return 5
        case "hiit": return 7
        default: return 6
        }
    }

    /// Kinds that are done as a calm sequence of holds (stretch, yoga, mobility).
    var isFlow: Bool { ["stretch", "yoga", "mobility"].contains(rawValue) }
}

// MARK: - Performed state

public enum PerformedState: String, Sendable {
    case none, some, all
}

public extension WorkoutContent {
    /// How much of the workout is ticked off (for deriving a session's status after edits).
    var performedState: PerformedState {
        let done = completedSets
        if done == 0 { return .none }
        return done == totalSets ? .all : .some
    }

    /// Ticks every set off with its planned values (for "I did it but didn't log it").
    mutating func markAllDone(at date: Date = Date()) {
        for b in blocks.indices {
            for i in blocks[b].items.indices {
                for s in blocks[b].items[i].sets.indices where !blocks[b].items[i].sets[s].isDone {
                    blocks[b].items[i].sets[s].isDone = true
                    blocks[b].items[i].sets[s].doneAt = date
                }
            }
        }
    }
}

// MARK: - Template follows progress

public extension WorkoutContent {
    /// Exercises whose top working weight went up against `template`: "Deadlift 100 → 105 kg".
    func loadChanges(comparedTo template: WorkoutContent, unit: WeightUnit = .kg) -> [String] {
        var lines: [String] = []
        var seen = Set<String>()
        for item in allItems where !seen.contains(item.exerciseKey) {
            seen.insert(item.exerciseKey)
            let done = item.sets.filter { $0.isDone && $0.kind == .working }
            guard let now = done.compactMap(\.effectiveWeight).max(), now > 0,
                  let planned = template.allItems.first(where: { $0.exerciseKey == item.exerciseKey }),
                  let before = planned.sets.filter({ $0.kind == .working }).compactMap(\.targetWeight).max(),
                  now > before + 0.01 else { continue }
            lines.append("\(item.name) \(Format.number(unit.fromKilograms(before))) → \(Format.weight(now, unit: unit))")
        }
        return lines
    }
}

// MARK: - Warm-ups and plates

public enum PlateMath {
    /// Plates per side for a barbell load (kg), greedy from the heaviest; nil if the load is below the bar.
    public static func perSide(totalKg: Double, barKg: Double = 20, plates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]) -> [Double]? {
        guard totalKg >= barKg else { return nil }
        var remaining = (totalKg - barKg) / 2
        var result: [Double] = []
        for plate in plates.sorted(by: >) {
            while remaining + 0.0001 >= plate {
                result.append(plate)
                remaining -= plate
            }
        }
        return remaining > 0.01 ? result : result
    }

    /// "20 + 15 + 2.5 per side" (plates in kg; `plates` = the gym's plate set).
    public static func text(totalKg: Double, barKg: Double = 20, plates available: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25], unit: WeightUnit = .kg) -> String? {
        guard let plates = perSide(totalKg: totalKg, barKg: barKg, plates: available) else { return nil }
        if plates.isEmpty { return "Empty bar" }
        let parts = plates.map { Format.number(unit.fromKilograms($0)) }
        return parts.joined(separator: " + ") + " per side"
    }
}

public enum WarmupBuilder {
    /// Warm-up sets before a top weight: empty bar × 10, 50 % × 5, 70 % × 3, 85 % × 1 (rounded to the
    /// increment, steps that are not lighter than the one before are dropped).
    public static func sets(topKg: Double, barKg: Double = 20, incrementKg: Double = 2.5) -> [WorkoutSet] {
        guard topKg > barKg else { return [] }
        let steps: [(Double, Int)] = [(0, 10), (0.5, 5), (0.7, 3), (0.85, 1)]
        var result: [WorkoutSet] = []
        var last = 0.0
        for (fraction, reps) in steps {
            var kg = fraction == 0 ? barKg : (topKg * fraction / incrementKg).rounded() * incrementKg
            kg = max(barKg, kg)
            guard kg > last + 0.001, kg < topKg - 0.001 else { continue }
            result.append(WorkoutSet(kind: .warmup, targetReps: String(reps), targetWeight: kg))
            last = kg
        }
        return result
    }
}

public extension WorkoutContent {
    /// Puts warm-up sets in front of an exercise's first working set. Returns how many were added.
    @discardableResult
    mutating func addWarmups(to itemID: UUID, barKg: Double = 20, incrementKg: Double = 2.5) -> Int {
        guard let loc = locate(itemID: itemID) else { return 0 }
        let item = blocks[loc.block].items[loc.item]
        guard item.mode == .reps, !item.sets.contains(where: { $0.kind == .warmup }),
              let top = item.sets.filter({ $0.kind != .warmup }).compactMap(\.effectiveWeight).max() else { return 0 }
        let warmups = WarmupBuilder.sets(topKg: top, barKg: barKg, incrementKg: incrementKg)
        let firstOpen = item.sets.firstIndex { !$0.isDone } ?? item.sets.count
        blocks[loc.block].items[loc.item].sets.insert(contentsOf: warmups, at: firstOpen)
        return warmups.count
    }
}

// MARK: - Cool-down

public extension RoutineLibrary {
    /// The stretch/yoga routine that best covers the muscles a workout just trained.
    static func coolDown(for worked: [MuscleGroup: Double], catalog: ExerciseCatalog) -> Routine? {
        let total = worked.values.reduce(0, +)
        guard total > 0 else { return all.first { $0.id == "post-workout" } }
        var best: (score: Double, routine: Routine)?
        for routine in all where routine.kind.isFlow && routine.id != "morning-mobility" && routine.id != "tennis-warm-up" {
            var covered = Set<MuscleGroup>()
            for entry in routine.entries {
                guard let exercise = catalog.exercise(named: entry.exercise) else { continue }
                for name in exercise.primary + exercise.secondary {
                    if let group = MuscleGroup.from(libraryName: name) { covered.insert(group) }
                }
            }
            let score = worked.reduce(0.0) { $0 + (covered.contains($1.key) ? $1.value : 0) } / total
            let adjusted = score + (routine.id == "post-workout" ? 0.05 : 0)
            if adjusted > (best?.score ?? -1) { best = (adjusted, routine) }
        }
        return best?.routine
    }
}

// MARK: - Week planning

/// A template as the week planner sees it.
public struct PlannableTemplate: Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Weekdays (1 = Sunday … 7 = Saturday, Calendar style) the template is scheduled on.
    public var scheduleDays: [Int]

    public init(id: UUID, name: String, scheduleDays: [Int]) {
        self.id = id
        self.name = name
        self.scheduleDays = scheduleDays
    }
}

public struct PlannedDay: Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var templateID: UUID
    public var templateName: String
    /// The energy rhythm expects a low day: plan it lighter.
    public var isLowEnergyDay: Bool

    public init(date: Date, templateID: UUID, templateName: String, isLowEnergyDay: Bool = false) {
        self.date = date
        self.templateID = templateID
        self.templateName = templateName
        self.isLowEnergyDay = isLowEnergyDay
    }
}

public enum WeekPlanner {
    /// Proposes workouts for the next `days` days starting at `from`.
    /// * Templates with weekdays go on those days.
    /// * Otherwise the program's rotation (starting at `rotationStart`) is spread evenly over the
    ///   days so that `weeklyGoal` minus the days already trained this week is reached.
    /// Days in `busyDays` (already planned or trained) are skipped.
    public static func propose(templates: [PlannableTemplate], rotationStart: Int, weeklyGoal: Int, trainedThisWeek: Int,
                               busyDays: Set<Date>, lowEnergyDay: Date? = nil, from: Date, days: Int = 7,
                               calendar: Calendar = .training()) -> [PlannedDay] {
        guard !templates.isEmpty else { return [] }
        let start = calendar.startOfDay(for: from)
        let window = (0..<max(1, days)).map { calendar.addingDays($0, to: start) }
        let free = window.filter { !busyDays.contains(calendar.startOfDay(for: $0)) }
        let low = lowEnergyDay.map { calendar.startOfDay(for: $0) }
        var result: [PlannedDay] = []
        let scheduled = templates.filter { !$0.scheduleDays.isEmpty }
        if !scheduled.isEmpty {
            for day in free {
                let weekday = calendar.component(.weekday, from: day)
                if let template = scheduled.first(where: { $0.scheduleDays.contains(weekday) }) {
                    result.append(PlannedDay(date: day, templateID: template.id, templateName: template.name, isLowEnergyDay: day == low))
                }
            }
            return result
        }
        let wanted = min(free.count, max(0, weeklyGoal - trainedThisWeek))
        guard wanted > 0 else { return [] }
        // Evenly spread: pick free days at regular steps, leaving rest days in between.
        var chosen: [Date] = []
        for i in 0..<wanted {
            let index = Int((Double(i) * Double(free.count) / Double(wanted)).rounded(.down))
            chosen.append(free[min(free.count - 1, index)])
        }
        for (i, day) in Array(Set(chosen)).sorted().enumerated() {
            let template = templates[(rotationStart + i) % templates.count]
            result.append(PlannedDay(date: day, templateID: template.id, templateName: template.name, isLowEnergyDay: day == low))
        }
        return result
    }
}
