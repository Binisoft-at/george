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
