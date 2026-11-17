import Foundation

// MARK: - Auto titles

public extension SessionNamer {
    /// Whether `title` is one George generated for one of `templateNames` on `date` (any number in
    /// the week). Typed titles never match, so they stay untouched when a workout moves to another day.
    func isGenerated(_ title: String, templateNames: [String], date: Date, maxIndex: Int = 21) -> Bool {
        generatedName(of: title, templateNames: templateNames, date: date, maxIndex: maxIndex) != nil
    }

    /// The template name an auto title was made from (nil for a typed title). An empty title counts
    /// as generated from the first name.
    func generatedName(of title: String, templateNames: [String], date: Date, maxIndex: Int = 21) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return templateNames.first }
        for name in templateNames {
            for index in 1...max(1, maxIndex) where self.title(templateName: name, date: date, indexInWeek: index) == trimmed {
                return name
            }
        }
        return nil
    }
}

// MARK: - Import names

public enum ImportNaming {
    /// A name that doesn't collide (ignoring case) with `taken`: "UPPER" → "UPPER (2)", "UPPER (3)" …
    public static func uniqueName(_ name: String, taken: [String]) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(name.lowercased()) else { return name }
        var number = 2
        while lowered.contains("\(name) (\(number))".lowercased()) { number += 1 }
        return "\(name) (\(number))"
    }
}

// MARK: - Rescue routines

public extension RoutineLibrary {
    /// The `count` ready-made routines whose length is closest to `minutes` (the shorter one wins a tie).
    static func closest(toMinutes minutes: Int, count: Int = 3, catalog: ExerciseCatalog) -> [Routine] {
        let target = max(1, minutes) * 60
        let scored = all.map { routine -> (routine: Routine, distance: Int, seconds: Int) in
            let seconds = routine.content(using: catalog).estimatedSeconds()
            return (routine, abs(seconds - target), seconds)
        }
        return scored
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.seconds < $1.seconds }
            .prefix(max(0, count))
            .map(\.routine)
    }
}

// MARK: - Reordering

public extension WorkoutContent {
    /// Moves blocks like `moveBlocks`, and each moved block joins the section it lands in: it takes the
    /// section of the block before it (or, at the very top, of the block after it).
    mutating func moveBlocksAdoptingSection(fromOffsets source: IndexSet, toOffset destination: Int) {
        let movingIDs = Set(source.compactMap { blocks.indices.contains($0) ? blocks[$0].id : nil })
        guard !movingIDs.isEmpty else { return }
        moveBlocks(fromOffsets: source, toOffset: destination)
        let indices = blocks.indices.filter { movingIDs.contains(blocks[$0].id) }
        guard let first = indices.first else { return }
        let neighbour: WorkoutBlock
        if first > 0 {
            neighbour = blocks[first - 1]
        } else if let lastMoved = indices.last, lastMoved + 1 < blocks.count {
            neighbour = blocks[lastMoved + 1]
        } else {
            return
        }
        for index in indices { blocks[index].section = neighbour.section }
    }
}

// MARK: - Changing all sets at once

public extension WorkoutContent {
    /// Open (not done) working sets of an exercise – what "All sets" changes. Warm-ups stay as they are.
    func openSetIDs(of itemID: UUID) -> [UUID] {
        guard let item = item(id: itemID) else { return [] }
        return item.sets.filter { !$0.isDone && $0.kind != .warmup }.map(\.id)
    }

    /// The value "All sets" shows for a field: the first open working set's (else the last set's).
    func allSetsValue(_ field: SetField, of itemID: UUID, inSession: Bool) -> Double? {
        guard let item = item(id: itemID) else { return nil }
        let open = item.sets.filter { !$0.isDone && $0.kind != .warmup }
        return (open.first ?? item.sets.last)?.value(field, inSession: inSession)
    }

    /// Sets a field on every open working set of an exercise ("All sets: 12 reps").
    mutating func setOpenSets(of itemID: UUID, _ field: SetField, to value: Double?, inSession: Bool) {
        for id in openSetIDs(of: itemID) {
            updateSet(id: id) { $0.setValue(field, value, inSession: inSession) }
        }
    }

    /// Changes a field on every open working set by `delta` (sets without a value start at 0).
    mutating func adjustOpenSets(of itemID: UUID, _ field: SetField, by delta: Double, inSession: Bool) {
        for id in openSetIDs(of: itemID) {
            updateSet(id: id) { set in
                let current = set.value(field, inSession: inSession) ?? 0
                set.setValue(field, max(0, current + delta), inSession: inSession)
            }
        }
    }

    /// Adds sets (copies of the last one) or removes open sets from the end until the exercise has
    /// `count` sets. Sets already done always stay.
    mutating func setSetCount(of itemID: UUID, to count: Int) {
        let target = max(1, count)
        updateItem(id: itemID) { item in
            while item.sets.count < target { item.sets.append(item.makeNextSet()) }
            while item.sets.count > target, let index = item.sets.lastIndex(where: { !$0.isDone }) {
                item.sets.remove(at: index)
            }
        }
    }
}

// MARK: - Reminders

/// A local notification George schedules (training day, streak at risk).
public struct PlannedReminder: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case training, streak }
    public var id: String
    public var kind: Kind
    public var fireDate: Date
    public var title: String
    public var body: String

    public init(id: String, kind: Kind, fireDate: Date, title: String, body: String) {
        self.id = id
        self.kind = kind
        self.fireDate = fireDate
        self.title = title
        self.body = body
    }
}

public enum ReminderPlanner {
    /// Reminders for the next `days` days:
    /// * a training-day reminder at `minutesAfterMidnight` on each day in `workouts` (start of day →
    ///   workout name, e.g. a planned session or a template scheduled on that weekday),
    /// * one "streak at risk" reminder on the last day the weekly goal can still be reached by training
    ///   every day (`neededThisWeek` days to go). On a training day it's folded into that reminder.
    /// Times already past are left out.
    public static func plan(now: Date, workouts: [Date: String], neededThisWeek: Int, weekStart: Date,
                            minutesAfterMidnight: Int, rescueMinutes: Int = 10, days: Int = 7,
                            calendar: Calendar) -> [PlannedReminder] {
        let today = calendar.startOfDay(for: now)
        let minutes = max(0, min(24 * 60 - 1, minutesAfterMidnight))
        func fire(on day: Date) -> Date { day.addingTimeInterval(Double(minutes * 60)) }
        func key(_ day: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }

        var riskDay: Date?
        if neededThisWeek > 0 {
            let start = calendar.startOfDay(for: weekStart)
            let last = calendar.addingDays(6, to: start)
            var day = calendar.addingDays(7 - min(7, neededThisWeek), to: start)
            if day < today { day = today }
            if day <= last { riskDay = day }
        }
        let streakLine = neededThisWeek == 1
            ? "One more workout day keeps your streak – even a \(rescueMinutes)-minute routine counts."
            : "\(neededThisWeek) more workout days keep your streak this week."

        var result: [PlannedReminder] = []
        var foldedStreak = false
        for offset in 0..<max(0, days) {
            let day = calendar.addingDays(offset, to: today)
            guard let name = workouts[day] else { continue }
            let date = fire(on: day)
            guard date > now else { continue }
            var body = "\(name) is on the plan today. Tap to start."
            if day == riskDay {
                body += " " + streakLine
                foldedStreak = true
            }
            result.append(PlannedReminder(id: "training-\(key(day))", kind: .training, fireDate: date, title: "Time for \(name)", body: body))
        }
        if let riskDay, !foldedStreak {
            let date = fire(on: riskDay)
            if date > now {
                result.append(PlannedReminder(id: "streak-\(key(riskDay))", kind: .streak, fireDate: date, title: "Streak at risk", body: streakLine))
            }
        }
        return result.sorted { $0.fireDate < $1.fireDate }
    }
}
