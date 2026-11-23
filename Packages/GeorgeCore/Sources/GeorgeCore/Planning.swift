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
    /// How a barbell load is built from the plates at hand – and what they can't make up.
    public struct Load: Equatable, Sendable {
        /// Plates per side in kilograms, heaviest first.
        public var perSide: [Double]
        /// Kilograms per side the plates can't make up (0 when the load is exact).
        public var missingPerSideKg: Double
        /// What the bar really weighs with these plates (bar plus both sides).
        public var loadedKg: Double
        /// The plates make up the load (to within 50 g a side).
        public var isExact: Bool { missingPerSideKg == 0 }
    }

    /// No plate hint above this many kilograms a side (about 2,200 lb): no bar is loaded like that, and
    /// a stray number on the keypad (9,999,999) must not build thousands of plates on every keystroke.
    public static let maxPerSideKg: Double = 1000
    /// No plate hint either when a side would need more plates than this (a set of small plates).
    public static let maxPlatesPerSide = 60

    /// Plates per side for a barbell load (kg), greedy from the heaviest, with the leftover the plates
    /// can't build; nil if the load is below the bar, above `maxPerSideKg` a side or would take more
    /// than `maxPlatesPerSide` plates a side.
    public static func load(totalKg: Double, barKg: Double = 20, plates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]) -> Load? {
        guard totalKg.isFinite, barKg.isFinite, totalKg + 0.0001 >= barKg else { return nil }
        var remaining = max(0, (totalKg - barKg) / 2)
        guard remaining <= maxPerSideKg + 0.0001 else { return nil }
        var result: [Double] = []
        for plate in plates.filter({ $0 > 0 }).sorted(by: >) {
            while remaining + 0.0001 >= plate {
                guard result.count < maxPlatesPerSide else { return nil }
                result.append(plate)
                remaining -= plate
            }
        }
        let missing = remaining >= 0.05 ? remaining : 0
        return Load(perSide: result, missingPerSideKg: missing, loadedKg: barKg + 2 * result.reduce(0, +))
    }

    /// Plates per side for a barbell load (kg), greedy from the heaviest; nil if the load is below the bar
    /// or past the limits of `load(totalKg:barKg:plates:)` – check it for what they can't make up.
    public static func perSide(totalKg: Double, barKg: Double = 20, plates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]) -> [Double]? {
        load(totalKg: totalKg, barKg: barKg, plates: plates)?.perSide
    }

    /// "20 + 15 + 2.5 per side" (plates in kg; `plates` = the gym's plate set). When the plates can't
    /// make up the load, what they do make follows: "20 per side ≈ 60 kg" (show it as a caution –
    /// `load(…)?.isExact` is false then). Nil – no hint – where `load` is nil (below the bar, too heavy).
    public static func text(totalKg: Double, barKg: Double = 20, plates available: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25], unit: WeightUnit = .kg) -> String? {
        guard let load = load(totalKg: totalKg, barKg: barKg, plates: available) else { return nil }
        let text = load.perSide.isEmpty
            ? "Empty bar"
            : load.perSide.map { Format.number(unit.fromKilograms($0)) }.joined(separator: " + ") + " per side"
        guard !load.isExact else { return text }
        let loaded = (unit.fromKilograms(load.loadedKg) * 10).rounded() / 10
        return text + " ≈ \(Format.number(loaded)) \(unit.rawValue)"
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
        // Built from today's top weight: for this workout only, not saved back into the template.
        let warmups = WarmupBuilder.sets(topKg: top, barKg: barKg, incrementKg: incrementKg).map { set -> WorkoutSet in
            var tagged = set
            tagged.addedLive = true
            return tagged
        }
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
    /// * Templates with weekdays go on those days (a program that schedules every template: that's the plan).
    /// * The other templates (the rotation, starting at `rotationStart`) fill each week up to its goal:
    ///   this week `weeklyGoal` minus the days trained and the days already planned; the part of next
    ///   week inside the window gets its share of the goal, minus what is planned there already.
    ///   Picks are spread with rest days in between where possible, earlier days first (the end of
    ///   the week stays as a fallback).
    /// Days in `busyDays` (already planned or trained) are left free. `plannedDays`: days from `from`
    /// on with a planned workout (not trained yet) – they count toward their week's goal.
    public static func propose(templates: [PlannableTemplate], rotationStart: Int, weeklyGoal: Int, trainedThisWeek: Int,
                               plannedDays: Set<Date> = [], busyDays: Set<Date>, lowEnergyDay: Date? = nil, from: Date,
                               days: Int = 7, calendar: Calendar = .training()) -> [PlannedDay] {
        guard !templates.isEmpty else { return [] }
        let start = calendar.startOfDay(for: from)
        let window = (0..<max(1, days)).map { calendar.addingDays($0, to: start) }
        let busy = Set(busyDays.map { calendar.startOfDay(for: $0) })
        let planned = Set(plannedDays.map { calendar.startOfDay(for: $0) }.filter { $0 >= start })
        let free = window.filter { !busy.contains($0) }
        let low = lowEnergyDay.map { calendar.startOfDay(for: $0) }
        var result: [PlannedDay] = []

        // Templates with weekdays on their days.
        var taken = Set<Date>()
        let scheduled = templates.filter { !$0.scheduleDays.isEmpty }
        for day in free {
            let weekday = calendar.component(.weekday, from: day)
            if let template = scheduled.first(where: { $0.scheduleDays.contains(weekday) }) {
                result.append(PlannedDay(date: day, templateID: template.id, templateName: template.name, isLowEnergyDay: day == low))
                taken.insert(day)
            }
        }
        let rotation = rotationOrder(templates, start: rotationStart)
        guard !rotation.isEmpty else { return result }

        // The rotation, week by week up to the goal.
        let thisWeek = calendar.weekStart(for: start)
        var weekStarts: [Date] = []
        for day in window where !weekStarts.contains(calendar.weekStart(for: day)) {
            weekStarts.append(calendar.weekStart(for: day))
        }
        var occupied = busy.union(taken)
        var chosen: [Date] = []
        for week in weekStarts {
            let inWindow = window.filter { calendar.weekStart(for: $0) == week }
            let open = inWindow.filter { !occupied.contains($0) }
            let placed = taken.filter { calendar.weekStart(for: $0) == week }.count
            var wanted: Int
            if week == thisWeek {
                let plannedHere = planned.filter { calendar.weekStart(for: $0) == week }.count
                wanted = weeklyGoal - max(0, trainedThisWeek) - plannedHere
            } else {
                // Only part of that week is in the window: its share of the goal, never more than the goal.
                let share = inWindow.count >= 7 ? weeklyGoal : Int((Double(weeklyGoal) * Double(inWindow.count) / 7).rounded())
                let plannedInWindow = planned.filter { inWindow.contains($0) }.count
                let plannedInWeek = planned.filter { calendar.weekStart(for: $0) == week }.count
                wanted = min(share - plannedInWindow, weeklyGoal - plannedInWeek)
            }
            wanted = min(open.count, max(0, wanted - placed))
            let picks = spread(wanted, over: open, occupied: occupied, calendar: calendar)
            chosen += picks
            occupied.formUnion(picks)
        }
        for (i, day) in chosen.sorted().enumerated() {
            let template = rotation[i % rotation.count]
            result.append(PlannedDay(date: day, templateID: template.id, templateName: template.name, isLowEnergyDay: day == low))
        }
        return result.sorted { $0.date < $1.date }
    }

    /// The templates without weekdays in rotation order, starting at `start` (an index into
    /// `templates`; a scheduled template there hands over to the next unscheduled one).
    static func rotationOrder(_ templates: [PlannableTemplate], start: Int) -> [PlannableTemplate] {
        guard !templates.isEmpty else { return [] }
        let first = ((start % templates.count) + templates.count) % templates.count
        return (0..<templates.count)
            .map { templates[(first + $0) % templates.count] }
            .filter { $0.scheduleDays.isEmpty }
    }

    /// `count` of the `open` days (sorted, at most a week) with as few workouts on back-to-back days
    /// as possible – next to `occupied` days or to each other – and among those the earliest.
    static func spread(_ count: Int, over open: [Date], occupied: Set<Date>, calendar: Calendar) -> [Date] {
        guard count > 0, !open.isEmpty else { return [] }
        guard count < open.count else { return open }
        func neighbours(of day: Date, in days: Set<Date>) -> Int {
            (days.contains(calendar.addingDays(-1, to: day)) ? 1 : 0) + (days.contains(calendar.addingDays(1, to: day)) ? 1 : 0)
        }
        // At most 7 open days: trying every combination is cheap.
        var indices = Array(0..<count)
        var best = indices
        var bestScore = (Int.max, Int.max)
        while true {
            let days = indices.map { open[$0] }
            let all = occupied.union(days)
            let score = (days.reduce(0) { $0 + neighbours(of: $1, in: all) }, indices.reduce(0, +))
            if score < bestScore {
                bestScore = score
                best = indices
            }
            var i = count - 1
            while i >= 0 && indices[i] == open.count - count + i { i -= 1 }
            if i < 0 { break }
            indices[i] += 1
            for j in (i + 1)..<count { indices[j] = indices[j - 1] + 1 }
        }
        return best.map { open[$0] }
    }
}
