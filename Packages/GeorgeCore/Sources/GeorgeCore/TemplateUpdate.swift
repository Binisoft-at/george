import Foundation

// "Update Template": saving a finished workout back into the template it came from – without the
// things that only happened today (a drop set after "Can't finish", warm-ups added live, a missed
// target, a swap's leftovers, fatigue answers).

/// How a finished workout is saved back into its template.
public enum TemplateUpdateMode: String, CaseIterable, Sendable {
    /// Only the numbers, and only upwards: heavier weights, longer holds and distances go into the
    /// template's matching working sets (same exercise, same working-set number). Exercises, sets,
    /// warm-ups and reps stay as planned.
    case loads
    /// Exercises, sets and numbers as done today – without sets added for today only, with rep ranges
    /// and missed targets kept, and a swapped exercise in a superset saved as its replacement.
    case everything
}

public extension WorkoutContent {
    /// The template content this workout makes. `.loads` writes into `base` (the template's current
    /// content) and keeps its ids and structure; `.everything` builds it from the workout
    /// (`asTemplate(promoteActuals:)`). Without a base, `.loads` works like `.everything`.
    func asTemplate(mode: TemplateUpdateMode, base: WorkoutContent?) -> WorkoutContent {
        switch mode {
        case .loads:
            guard let base else { return templateCopy(promoteActuals: true) }
            return loadsWritten(into: base)
        case .everything:
            return templateCopy(promoteActuals: true)
        }
    }

    /// Short lines for what saving this workout into `template` would change ("Bench 4→3 sets",
    /// "Row 50→52.5 kg", "Face Pull added"). Empty when the template would stay the same.
    func templateChanges(into template: WorkoutContent, mode: TemplateUpdateMode, unit: WeightUnit = .kg) -> [String] {
        let old = mode == .everything ? template.withSwapsFolded() : template
        return asTemplate(mode: mode, base: template).changes(comparedTo: old, unit: unit)
    }

    /// Whether saving this workout would change the template's exercises, groups or set counts – not
    /// counting what was only added for today (a drop set, live warm-ups).
    func changesTemplateStructure(_ template: WorkoutContent) -> Bool {
        asTemplate(mode: .everything, base: template).structureDiffers(from: template.withSwapsFolded())
    }

    /// This content with each superset swap folded into one exercise, as `.everything` saves it. A
    /// template an older George saved straight after a swap still holds both exercises; compared
    /// folded, a workout done just as planned reads as unchanged.
    internal func withSwapsFolded() -> WorkoutContent {
        var copy = self
        for b in copy.blocks.indices where copy.blocks[b].items.count > 1 {
            copy.blocks[b].items = copy.blocks[b].foldedSwaps()
        }
        return copy
    }

    /// The template a workout makes: see `asTemplate(promoteActuals:)`.
    internal func templateCopy(promoteActuals: Bool) -> WorkoutContent {
        var copy = self
        for b in copy.blocks.indices {
            copy.blocks[b].id = UUID()
            copy.blocks[b].items = copy.blocks[b].foldedSwaps()
            for i in copy.blocks[b].items.indices {
                var item = copy.blocks[b].items[i]
                item.id = UUID()
                item.fatigue = nil
                item.roundOffset = nil
                let mode = item.mode
                item.sets = item.sets
                    .filter { $0.addedLive != true }
                    .map { promoteActuals && $0.isDone ? $0.promotedForTemplate(mode: mode) : $0.clearedForTemplate() }
                copy.blocks[b].items[i] = item
            }
        }
        copy.blocks.removeAll { $0.items.isEmpty }
        return copy
    }

    /// `.loads`: the template's content with the heavier numbers of this workout written into its
    /// matching working sets. Exercises pair by `exerciseKey` (the n-th occurrence with the n-th),
    /// sets by working-set number (warm-ups, drop sets and sets added today don't count).
    private func loadsWritten(into base: WorkoutContent) -> WorkoutContent {
        var result = base
        var performed: [String: [WorkoutItem]] = [:]
        for item in allItems { performed[item.exerciseKey, default: []].append(item) }
        var seen: [String: Int] = [:]
        for b in result.blocks.indices {
            for i in result.blocks[b].items.indices {
                let planned = result.blocks[b].items[i]
                let n = seen[planned.exerciseKey, default: 0]
                seen[planned.exerciseKey] = n + 1
                guard let candidates = performed[planned.exerciseKey], n < candidates.count else { continue }
                let done = candidates[n].sets.filter(\.countsAsPlannedWorkingSet)
                var k = 0
                for s in planned.sets.indices where planned.sets[s].countsAsPlannedWorkingSet {
                    if k < done.count, done[k].isDone {
                        result.blocks[b].items[i].sets[s].raiseLoads(to: done[k], mode: planned.mode)
                    }
                    k += 1
                }
            }
        }
        return result
    }

    /// Short lines for how this content differs from `old`, one per exercise: "Bench 4→3 sets",
    /// "Row 50→52.5 kg", "Curl 10→12 reps", "Face Pull added", "Fly removed".
    func changes(comparedTo old: WorkoutContent, unit: WeightUnit = .kg) -> [String] {
        var lines: [String] = []
        var explained = false
        var before: [String: [WorkoutItem]] = [:]
        for item in old.allItems { before[item.exerciseKey, default: []].append(item) }
        var after: [String: Int] = [:]
        for item in allItems {
            let n = after[item.exerciseKey, default: 0]
            after[item.exerciseKey] = n + 1
            guard let candidates = before[item.exerciseKey], n < candidates.count else {
                lines.append("\(item.name) added")
                explained = true
                continue
            }
            let parts = item.changeParts(from: candidates[n], unit: unit)
            if parts.contains(where: { $0.hasSuffix(" sets") || $0.hasSuffix(" warm-ups") }) { explained = true }
            if !parts.isEmpty { lines.append(item.name + " " + parts.joined(separator: ", ")) }
        }
        var counted: [String: Int] = [:]
        for item in old.allItems {
            let n = counted[item.exerciseKey, default: 0]
            counted[item.exerciseKey] = n + 1
            if n >= after[item.exerciseKey, default: 0] {
                lines.append("\(item.name) removed")
                explained = true
            }
        }
        if !explained && structureDiffers(from: old) { lines.append("Order or groups changed") }
        return lines
    }
}

extension WorkoutBlock {
    /// The items of a superset/circuit with each mid-workout swap folded back into one exercise: the
    /// replacement takes the place of the exercise it replaced, with the rounds of both (the rounds
    /// done before the swap become copies of the replacement's first working set).
    func foldedSwaps() -> [WorkoutItem] {
        guard items.count > 1 else { return items }
        var result: [WorkoutItem] = []
        for lane in lanes {
            guard let first = lane.first, let last = lane.last else { continue }
            guard lane.count > 1 else {
                result.append(items[last])
                continue
            }
            var merged = items[last]
            let earlier = lane.dropLast().reduce(0) { total, i in
                total + WorkoutItem(name: items[i].name, sets: items[i].sets.filter { $0.addedLive != true }).roundSetCount
            }
            if earlier > 0 {
                let model: WorkoutSet
                if let own = merged.sets.first(where: { $0.countsAsPlannedWorkingSet }) {
                    model = own
                } else {
                    // Nothing of the replacement to copy: the old exercise's set, without its weight.
                    var old = items[first].sets.first(where: { $0.countsAsPlannedWorkingSet })?.clearedCopy() ?? WorkoutSet()
                    old.targetWeight = nil
                    model = old
                }
                let copies = (0..<earlier).map { _ -> WorkoutSet in
                    var copy = model
                    copy.id = UUID()
                    return copy
                }
                let at = merged.sets.firstIndex { $0.kind != .warmup } ?? merged.sets.count
                merged.sets.insert(contentsOf: copies, at: at)
            }
            merged.roundOffset = items[first].roundOffset
            result.append(merged)
        }
        return result
    }
}

extension WorkoutSet {
    /// A working or to-failure set that was planned (not added during the workout).
    var countsAsPlannedWorkingSet: Bool {
        (kind == .working || kind == .failure) && addedLive != true
    }

    /// The planned reps stay when they are a range ("8-12" – double progression needs it), not a
    /// number ("AMRAP"), or more than what was done (a missed target is not the new plan).
    func keepsTargetReps(over reps: Int) -> Bool {
        guard let raw = targetReps?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return false }
        guard let range = targetRepsRange else { return true }
        return range.lowerBound != range.upperBound || reps < range.lowerBound
    }

    /// A done set as a template set: what was done becomes the plan – except a rep range, a missed
    /// rep target or a hold cut short, which keep the plan.
    func promotedForTemplate(mode: ExerciseMode) -> WorkoutSet {
        var copy = clearedForTemplate()
        if let r = reps, !keepsTargetReps(over: r) { copy.targetReps = String(r) }
        if let w = weight { copy.targetWeight = w }
        if let s = seconds, mode != .time || s >= (targetSeconds ?? 0) { copy.targetSeconds = s }
        if let m = meters { copy.targetMeters = m }
        return copy
    }

    /// An open set as a template set: the plan, a new id, no tag.
    func clearedForTemplate() -> WorkoutSet {
        var copy = clearedCopy()
        copy.addedLive = nil
        return copy
    }

    /// `.loads`: takes the performed weight, hold or distance when it's more than planned.
    mutating func raiseLoads(to performed: WorkoutSet, mode: ExerciseMode) {
        if let w = performed.weight, w > 0, w > (targetWeight ?? 0) + 0.001 { targetWeight = w }
        switch mode {
        case .reps: break
        case .time:
            if let s = performed.seconds, s > (targetSeconds ?? 0) { targetSeconds = s }
        case .distance:
            if let m = performed.meters, m > (targetMeters ?? 0) + 0.001 { targetMeters = m }
        }
    }
}

extension WorkoutItem {
    /// What changed against `old` (the same exercise): set counts, reps, top weight, hold, distance.
    func changeParts(from old: WorkoutItem, unit: WeightUnit) -> [String] {
        var parts: [String] = []
        let newMain = sets.filter { $0.kind != .warmup }
        let oldMain = old.sets.filter { $0.kind != .warmup }
        if newMain.count != oldMain.count { parts.append("\(oldMain.count)→\(newMain.count) sets") }
        let newWarmups = sets.count - newMain.count
        let oldWarmups = old.sets.count - oldMain.count
        if newWarmups != oldWarmups { parts.append("\(oldWarmups)→\(newWarmups) warm-ups") }
        if let pair = zip(oldMain.map { $0.targetReps ?? "" }, newMain.map { $0.targetReps ?? "" }).first(where: { $0.0 != $0.1 }) {
            parts.append("\(pair.0.isEmpty ? "–" : pair.0)→\(pair.1.isEmpty ? "–" : pair.1) reps")
        }
        let oldTop = oldMain.compactMap(\.targetWeight).filter { $0 > 0 }.max()
        let newTop = newMain.compactMap(\.targetWeight).filter { $0 > 0 }.max()
        if let a = oldTop, let b = newTop, abs(a - b) > 0.001 {
            parts.append("\(Format.number(unit.fromKilograms(a)))→\(Format.weight(b, unit: unit))")
        } else if oldTop == nil, let b = newTop {
            parts.append("now \(Format.weight(b, unit: unit))")
        } else if let a = oldTop, newTop == nil {
            parts.append("no weight (was \(Format.weight(a, unit: unit)))")
        } else if zip(oldMain, newMain).contains(where: { pair in abs((pair.0.targetWeight ?? 0) - (pair.1.targetWeight ?? 0)) > 0.001 }) {
            parts.append("weights changed")
        }
        if mode == .time {
            let a = oldMain.compactMap(\.targetSeconds).max()
            let b = newMain.compactMap(\.targetSeconds).max()
            if let a, let b, a != b { parts.append("\(Format.shortDuration(a))→\(Format.shortDuration(b))") }
        }
        if mode == .distance {
            let a = oldMain.compactMap(\.targetMeters).max()
            let b = newMain.compactMap(\.targetMeters).max()
            if let a, let b, abs(a - b) > 0.001 { parts.append("\(Format.distance(a))→\(Format.distance(b))") }
        }
        return parts
    }
}
