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
        // A runaway digit string becomes infinity, which can't be stored (JSON has no infinity). Nothing
        // in a set comes near ten million; a pasted 20-digit number would trap where it becomes an Int.
        guard let value = Double(number), value.isFinite, value < WorkoutSet.largestValue else { return nil }
        return value
    }

    public static func int(_ text: String) -> Int? {
        // Int(_:) traps beyond its range; nothing typed into a set is that big.
        guard let value = double(text), value < 1_000_000_000 else { return nil }
        return Int(value.rounded())
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
            let reps = value.map { Int(Self.storable($0).rounded()) }
            if inSession { self.reps = reps }
            if planFollows { targetReps = reps.map(String.init) }
        case .weight:
            let weight = value.map(Self.storable)
            if inSession { self.weight = weight }
            if planFollows { targetWeight = weight }
        case .seconds:
            let seconds = value.map { Int(Self.storable($0).rounded()) }
            if inSession { self.seconds = seconds }
            if planFollows { targetSeconds = seconds }
        case .meters:
            let meters = value.map(Self.storable)
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

extension WorkoutSet {
    /// Every number a set stores stays below this (ten million): far above any real weight, rep
    /// count, time or distance, and far below where turning it into an Int traps.
    static let largestValue: Double = 10_000_000

    /// A number made safe to store in a set: at least 0, below `largestValue`, NaN as 0.
    static func storable(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return Swift.min(Swift.max(0, value), largestValue - 1)
    }
}

public extension WorkoutSet {
    /// The set done last time that corresponds to `set` (one of `item`'s sets): warm-ups pair with
    /// warm-ups, working and to-failure sets with last time's working sets (never a warm-up or a drop
    /// set), drop sets with drop sets – the n-th of its kind with the n-th, the last one for sets
    /// beyond what was done. Nil when last time had no done set of that kind.
    static func matchingPrevious(_ set: WorkoutSet, in item: WorkoutItem, previous: [WorkoutSet]?) -> WorkoutSet? {
        guard let previous, !previous.isEmpty, let index = item.sets.firstIndex(where: { $0.id == set.id }) else { return nil }
        let role = set.pairingRole
        let position = item.sets.prefix(upTo: index).filter { $0.pairingRole == role }.count
        let candidates = previous.filter { $0.isDone && $0.pairingRole == role }
        guard !candidates.isEmpty else { return nil }
        return position < candidates.count ? candidates[position] : candidates[candidates.count - 1]
    }
}

private extension WorkoutSet {
    /// 0 warm-up, 1 working or to failure, 2 drop set.
    var pairingRole: Int {
        switch kind {
        case .warmup: return 0
        case .working, .failure: return 1
        case .drop: return 2
        }
    }
}

public extension WorkoutItem {
    /// Sets that take a round of a superset/circuit: warm-ups (a lead-in before the rounds) and drop
    /// sets that follow a set (same round, no rest) don't count.
    var roundSetCount: Int {
        var count = 0
        for set in sets where set.kind != .warmup {
            if set.kind == .drop && count > 0 { continue }
            count += 1
        }
        return count
    }

    /// A set for one more round: a copy of the last working set (targets only) – never a warm-up or
    /// a drop set.
    func makeNextWorkingSet() -> WorkoutSet {
        if let last = sets.last(where: { $0.kind == .working }) ?? sets.last(where: { $0.kind == .failure }) {
            var next = last.clearedCopy()
            next.addedLive = nil
            return next
        }
        var next = makeNextSet()
        next.kind = .working
        return next
    }
}

public extension WorkoutBlock {
    /// The round after the last one item `i` fills: its `roundOffset` plus its round sets.
    private func roundEnd(_ i: Int) -> Int { (items[i].roundOffset ?? 0) + items[i].roundSetCount }

    /// Exercises that share one column of rounds (item indices, in order): an exercise and the ones
    /// that replaced it mid-workout – an item whose `roundOffset` is the round the item right before
    /// it stopped at continues that item's rounds.
    var lanes: [[Int]] {
        var result: [[Int]] = []
        for i in items.indices {
            if i > 0, !result.isEmpty, let offset = items[i].roundOffset, offset == roundEnd(i - 1) {
                result[result.count - 1].append(i)
            } else {
                result.append([i])
            }
        }
        return result
    }

    /// Rounds each lane fills, in order ("3 · 4 sets" when they differ).
    var laneRoundCounts: [Int] { lanes.compactMap { $0.last.map(roundEnd) } }

    /// Rounds the exercises fill, warm-ups and drop sets not counted.
    var workingRoundCount: Int { laneRoundCounts.max() ?? 0 }

    /// A superset or circuit whose exercises end on different rounds. A drop set, warm-ups or a
    /// swapped exercise (its replacement continues the same rounds) are no difference.
    var setCountsDiffer: Bool {
        items.count > 1 && Set(laneRoundCounts).count > 1
    }

    /// The rounds "Match sets" evens every exercise out to.
    var maxSetCount: Int { workingRoundCount }

    /// The order a superset/circuit is done in: warm-ups first as a straight lead-in (round -1,
    /// exercise by exercise), then round by round, each item's set followed by its drop sets. Items
    /// that replaced a swapped exercise start at their `roundOffset`.
    func roundSlots() -> [WorkoutContent.RoundSlot] {
        var leadIn: [WorkoutContent.RoundSlot] = []
        var slots: [WorkoutContent.RoundSlot] = []
        for (i, item) in items.enumerated() {
            var round = (item.roundOffset ?? 0) - 1
            var follower = 0
            var hasRoundSet = false
            for (s, set) in item.sets.enumerated() {
                if set.kind == .warmup {
                    leadIn.append(WorkoutContent.RoundSlot(round: -1, itemIndex: i, setIndex: s, follower: 0))
                    continue
                }
                if set.kind == .drop && hasRoundSet {
                    follower += 1
                } else {
                    round += 1
                    follower = 0
                    hasRoundSet = true
                }
                slots.append(WorkoutContent.RoundSlot(round: max(0, round), itemIndex: i, setIndex: s, follower: follower))
            }
        }
        return leadIn + slots.sorted { ($0.round, $0.itemIndex, $0.follower) < ($1.round, $1.itemIndex, $1.follower) }
    }

    /// The first round (0-based) that still has an open set; nil when every round is done.
    /// Warm-ups don't count.
    var firstOpenRound: Int? {
        roundSlots()
            .filter { $0.round >= 0 && !items[$0.itemIndex].sets[$0.setIndex].isDone }
            .map(\.round)
            .min()
    }

    /// Whether a warm-up of the lead-in is still open.
    var hasOpenWarmup: Bool {
        items.contains { $0.sets.contains { $0.kind == .warmup && !$0.isDone } }
    }

    /// Gives every exercise of a superset/circuit the same number of rounds – by default as many as
    /// the longest. Only the last exercise of each lane changes (a swapped exercise's replacement,
    /// never the one it replaced): missing rounds copy its last working set, extra open sets go, sets
    /// already done always stay. Warm-ups and drop sets are not rounds and are never added.
    mutating func matchRounds(to count: Int? = nil) {
        let target = max(1, count ?? workingRoundCount)
        for lane in lanes {
            guard let i = lane.last else { continue }
            var item = items[i]
            let start = item.roundOffset ?? 0
            while start + item.roundSetCount < target {
                item.sets.append(item.makeNextWorkingSet())
            }
            while start + item.roundSetCount > target, item.sets.count > 1,
                  let last = item.sets.last, !last.isDone, last.kind != .warmup {
                item.sets.removeLast()
            }
            items[i] = item
        }
        if rounds != nil { rounds = target }
    }
}

public extension WorkoutContent {
    /// Supersets/circuits whose exercises end on different rounds.
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

    /// Gives every exercise of a superset/circuit the same number of rounds – by default as many as
    /// the longest (`WorkoutBlock.matchRounds`): missing rounds copy the exercise's last working set,
    /// extra open sets go, sets already done always stay. Warm-ups, drop sets and a swapped exercise
    /// (its replacement continues the rounds) are taken into account, not padded.
    mutating func matchSetCounts(blockID: UUID, to count: Int? = nil) {
        guard let b = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        blocks[b].matchRounds(to: count)
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
        // A rescue for today only: never saved back into the template.
        drop.addedLive = true
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
            // Replaced before its first set: it keeps the round it was to start in (a replacement
            // swapped again stays in its superset round).
            new.roundOffset = old.roundOffset
            blocks[loc.block].items[loc.item] = new
        } else if blocks[loc.block].style.isGrouped && blocks[loc.block].items.count > 1 {
            // In a superset the replacement takes over in the round the old exercise stopped at
            // (warm-ups and drop sets don't take a round).
            blocks[loc.block].items[loc.item].sets = old.done
            new.roundOffset = (old.roundOffset ?? 0) + blocks[loc.block].items[loc.item].roundSetCount
            blocks[loc.block].items.insert(new, at: loc.item + 1)
        } else {
            // Straight sets: the replacement becomes its own block right after – never a fake superset.
            blocks[loc.block].items[loc.item].sets = old.done
            var block = WorkoutBlock(style: .single, items: [new])
            block.section = blocks[loc.block].section
            blocks.insert(block, at: loc.block + 1)
        }
        return new.id
    }
}

private extension WorkoutItem {
    var done: [WorkoutSet] { sets.filter(\.isDone) }
}

public extension ExerciseCatalog {
    /// Equipment found in most gyms – ranked above rare gear (chains, medicine balls, …).
    static let commonEquipment: Set<String> = ["barbell", "dumbbell", "cable", "machine", "body only", "e-z curl bar", "bands", "band", "kettlebells"]
    /// Words that name the equipment or the side, not the movement.
    static let equipmentWords: Set<String> = ["barbell", "dumbbell", "dumbbells", "cable", "machine", "smith", "kettlebell", "kettlebells",
                                              "band", "banded", "lever", "one", "arm", "single", "alternating", "with", "the", "on", "a", "and"]

    /// Exercises that train the same muscles – for "this one isn't available". Ranked by the same
    /// movement first (shared name words like "bench" and "press", the same push/pull and
    /// compound/isolation), then shared primary muscles; common gym equipment ranks above rare
    /// gear, and a different piece of equipment counts as a small plus (the machine is usually taken).
    func alternatives(for item: WorkoutItem, limit: Int = 8) -> [LibraryExercise] {
        let source = match(for: item)
        let primary = Set(item.muscles.isEmpty ? (source?.primary ?? []) : item.muscles)
        guard !primary.isEmpty else { return [] }
        let secondary = Set(source?.secondary ?? [])
        let name = item.name.lowercased()
        let movement = ExerciseCatalog.tokens(item.name).subtracting(ExerciseCatalog.equipmentWords)
        var scored: [(Double, LibraryExercise)] = []
        for exercise in exercises {
            guard exercise.id != source?.id, exercise.name.lowercased() != name, exercise.mode == item.mode || item.mode == .reps && exercise.mode == .reps else { continue }
            let sharedPrimary = primary.intersection(exercise.primary).count
            guard sharedPrimary > 0 else { continue }
            var score = Double(sharedPrimary) * 3 - Double(Set(exercise.primary).subtracting(primary).count) * 1.5
            score += Double(secondary.intersection(exercise.secondary).count) * 0.5
            let words = ExerciseCatalog.tokens(exercise.name).subtracting(ExerciseCatalog.equipmentWords)
            score += Double(movement.intersection(words).count) * 2.5
            if let source {
                if exercise.force != nil, exercise.force == source.force { score += 1.5 }
                if exercise.mechanic != nil, exercise.mechanic == source.mechanic { score += 1.5 }
                if exercise.kind == source.kind { score += 0.5 }
                if exercise.equipment != source.equipment { score += 0.5 }
            }
            if let equipment = exercise.equipment?.lowercased() {
                score += ExerciseCatalog.commonEquipment.contains(equipment) ? 1 : -1.5
            }
            if exercise.level == "expert" { score -= 1 }
            if exercise.name.contains("(") { score -= 1 }
            if !exercise.images.isEmpty { score += 0.3 }
            scored.append((score, exercise))
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.name < $1.1.name }.prefix(limit).map(\.1)
    }
}
