import Foundation

/// Parses numbers people type: "62,5", "62.5", " 62 ", "62.5 kg". Both decimal separators work,
/// whatever the phone's region is.
public enum NumberParser {
    public static func double(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        let number = cleaned.prefix { $0.isNumber || $0 == "." }
        guard !number.isEmpty, number != ".", number.filter({ $0 == "." }).count <= 1 else { return nil }
        return Double(number)
    }

    public static func int(_ text: String) -> Int? {
        double(text).map { Int($0.rounded()) }
    }
}

/// The numbers a set carries.
public enum SetField: String, CaseIterable, Sendable {
    case reps, weight, seconds, meters, rpe
}

public extension WorkoutSet {
    /// Lower and upper end of the target reps ("8-12" → 8...12, "10" → 10...10).
    var targetRepsRange: ClosedRange<Int>? {
        guard let raw = targetReps else { return nil }
        let numbers = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let first = numbers.first else { return nil }
        let last = numbers.count > 1 ? numbers[1] : first
        return min(first, last)...max(first, last)
    }

    /// The number shown for a field: in a workout what was (or will be) done, in a template the plan.
    func value(_ field: SetField, inSession: Bool) -> Double? {
        switch field {
        case .reps: return (inSession ? effectiveReps : targetRepsValue).map(Double.init)
        case .weight: return inSession ? effectiveWeight : targetWeight
        case .seconds: return (inSession ? effectiveSeconds : targetSeconds).map(Double.init)
        case .meters: return inSession ? effectiveMeters : targetMeters
        case .rpe: return inSession ? (rpe ?? targetRPE) : targetRPE
        }
    }

    /// Changes a number the way people expect. A template changes its plan. In a workout the set
    /// changes what was done – and while the set is still open the plan follows too, so the set always
    /// shows exactly what was typed. (Separate plan and result fields made edits look ignored.)
    mutating func setValue(_ field: SetField, _ value: Double?, inSession: Bool) {
        let planFollows = !inSession || !isDone
        switch field {
        case .reps:
            let reps = value.map { max(0, Int($0.rounded())) }
            if inSession { self.reps = reps }
            if planFollows { targetReps = reps.map(String.init) }
        case .weight:
            let weight = value.map { max(0, $0) }
            if inSession { self.weight = weight }
            if planFollows { targetWeight = weight }
        case .seconds:
            let seconds = value.map { max(0, Int($0.rounded())) }
            if inSession { self.seconds = seconds }
            if planFollows { targetSeconds = seconds }
        case .meters:
            let meters = value.map { max(0, $0) }
            if inSession { self.meters = meters }
            if planFollows { targetMeters = meters }
        case .rpe:
            let rpe = value.map { min(10, max(0, $0)) }
            if inSession { self.rpe = rpe } else { targetRPE = rpe }
        }
    }

    /// Reps in reserve (10 − RPE), when an RPE was logged.
    var repsInReserve: Int? {
        rpe.map { max(0, Int((10 - $0).rounded())) }
    }
}

public extension WorkoutBlock {
    /// A superset or circuit whose exercises have different numbers of sets.
    var setCountsDiffer: Bool {
        items.count > 1 && Set(items.map(\.sets.count)).count > 1
    }

    var maxSetCount: Int { items.map(\.sets.count).max() ?? 0 }
}

public extension WorkoutContent {
    /// Supersets/circuits whose exercises have different numbers of sets.
    var mismatchedGroupCount: Int { blocks.filter(\.setCountsDiffer).count }

    /// Copies a set's numbers to the following open sets of the same exercise ("same for the rest").
    mutating func applyToFollowingSets(from setID: UUID, inSession: Bool) {
        guard let ref = locate(setID: setID) else { return }
        var item = blocks[ref.blockIndex].items[ref.itemIndex]
        let source = item.sets[ref.setIndex]
        for index in item.sets.indices where index > ref.setIndex && !item.sets[index].isDone {
            for field in SetField.allCases where field != .rpe {
                if let value = source.value(field, inSession: inSession) {
                    item.sets[index].setValue(field, value, inSession: inSession)
                }
            }
            item.sets[index].targetLoad = source.targetLoad
        }
        blocks[ref.blockIndex].items[ref.itemIndex] = item
    }

    /// Gives every exercise of a superset/circuit the same number of sets – by default as many as
    /// the exercise with the most. Missing sets copy that exercise's last set; extra open sets go,
    /// sets already done always stay.
    mutating func matchSetCounts(blockID: UUID, to count: Int? = nil) {
        guard let b = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let target = max(1, count ?? blocks[b].maxSetCount)
        for i in blocks[b].items.indices {
            var item = blocks[b].items[i]
            while item.sets.count < target {
                item.sets.append(item.makeNextSet())
            }
            while item.sets.count > target, let last = item.sets.last, !last.isDone {
                item.sets.removeLast()
            }
            blocks[b].items[i] = item
        }
        if blocks[b].rounds != nil { blocks[b].rounds = target }
    }
}

// MARK: - Mid-workout changes

public extension WorkoutContent {
    /// "I can't finish this set": the set counts with the reps you managed, and a drop set with the
    /// lighter weight follows right after it (no rest). With `applyToRemaining`, the open sets after
    /// it get the lighter weight too. Returns the drop set's id.
    @discardableResult
    mutating func dropWeight(setID: UUID, repsDone: Int, newWeightKg: Double, applyToRemaining: Bool, at date: Date = Date()) -> UUID? {
        guard let ref = locate(setID: setID) else { return nil }
        var item = blocks[ref.blockIndex].items[ref.itemIndex]
        var set = item.sets[ref.setIndex]
        let target = set.targetRepsValue ?? set.reps
        set.reps = max(0, repsDone)
        if set.weight == nil { set.weight = set.targetWeight }
        set.isDone = true
        set.doneAt = date
        item.sets[ref.setIndex] = set

        var drop = WorkoutSet(kind: .drop, targetWeight: max(0, newWeightKg))
        if let target { drop.targetReps = String(max(1, target - repsDone)) }
        item.sets.insert(drop, at: ref.setIndex + 1)

        if applyToRemaining {
            for index in item.sets.indices where index > ref.setIndex + 1 && !item.sets[index].isDone && item.sets[index].kind != .warmup {
                item.sets[index].setValue(.weight, newWeightKg, inSession: true)
            }
        }
        blocks[ref.blockIndex].items[ref.itemIndex] = item
        return drop.id
    }

    /// Swaps an exercise for another mid-workout (machine taken, not available). Sets already done
    /// stay with the old exercise; the open ones move to the new one right after it, keeping their
    /// reps or times (weights are cleared – they don't carry over between exercises). Without done
    /// sets the exercise is simply replaced. Returns the id of the item that now holds the open sets.
    @discardableResult
    mutating func swapRemaining(itemID: UUID, with replacement: WorkoutItem) -> UUID? {
        guard let loc = locate(itemID: itemID) else { return nil }
        let old = blocks[loc.block].items[loc.item]
        let open = old.sets.filter { !$0.isDone }
        // Every set already done: nothing left to swap.
        guard !open.isEmpty || old.sets.isEmpty else { return nil }
        var new = replacement
        new.id = old.done.isEmpty ? old.id : UUID()
        new.restSeconds = old.restSeconds ?? replacement.restSeconds
        new.notes = nil
        new.fatigue = nil
        new.sets = old.sets.isEmpty ? replacement.sets : open.map { set in
            var copy = set.clearedCopy(newID: false)
            copy.targetWeight = nil
            copy.targetLoad = nil
            if new.mode != old.mode {
                switch new.mode {
                case .reps: copy.targetReps = copy.targetReps ?? replacement.sets.first?.targetReps ?? "10"
                case .time: copy.targetSeconds = copy.targetSeconds ?? replacement.sets.first?.targetSeconds ?? 30
                case .distance: copy.targetMeters = copy.targetMeters ?? replacement.sets.first?.targetMeters ?? 400
                }
            }
            return copy
        }
        if old.done.isEmpty {
            blocks[loc.block].items[loc.item] = new
        } else {
            blocks[loc.block].items[loc.item].sets = old.done
            blocks[loc.block].items.insert(new, at: loc.item + 1)
        }
        return new.id
    }
}

private extension WorkoutItem {
    var done: [WorkoutSet] { sets.filter(\.isDone) }
}

public extension ExerciseCatalog {
    /// Exercises that train the same muscles – for "this one isn't available". Ranked by shared
    /// primary muscles, then the same kind of movement (push/pull, compound/isolation); a different
    /// piece of equipment counts as a plus (the point is usually that the machine is taken).
    func alternatives(for item: WorkoutItem, limit: Int = 8) -> [LibraryExercise] {
        let source = match(for: item)
        let primary = Set(item.muscles.isEmpty ? (source?.primary ?? []) : item.muscles)
        guard !primary.isEmpty else { return [] }
        let secondary = Set(source?.secondary ?? [])
        let name = item.name.lowercased()
        var scored: [(Double, LibraryExercise)] = []
        for exercise in exercises {
            guard exercise.id != source?.id, exercise.name.lowercased() != name, exercise.mode == item.mode || item.mode == .reps && exercise.mode == .reps else { continue }
            let sharedPrimary = primary.intersection(exercise.primary).count
            guard sharedPrimary > 0 else { continue }
            var score = Double(sharedPrimary) * 3 - Double(Set(exercise.primary).subtracting(primary).count)
            score += Double(secondary.intersection(exercise.secondary).count) * 0.5
            if let source {
                if exercise.force != nil, exercise.force == source.force { score += 1 }
                if exercise.mechanic != nil, exercise.mechanic == source.mechanic { score += 1 }
                if exercise.kind == source.kind { score += 0.5 }
                if exercise.equipment != source.equipment { score += 0.5 }
            }
            if !exercise.images.isEmpty { score += 0.3 }
            scored.append((score, exercise))
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.name < $1.1.name }.prefix(limit).map(\.1)
    }
}

