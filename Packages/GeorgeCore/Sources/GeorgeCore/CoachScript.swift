import Foundation

/// When the voice coach speaks. Each can be switched off in Settings → Voice Coach.
public enum CoachCue: String, CaseIterable, Sendable, Identifiable {
    /// A set is due: "Bench Press, set 2 of 4: 8 reps at 60 kilos."
    case setUp
    /// Rest starts: "Rest 90 seconds. Up next: …"
    case restStart
    /// "10 seconds" and 3-2-1 before a rest or timed set ends.
    case countdown
    /// Rest is over: "Go!"
    case go
    /// Timed sets: halfway, done.
    case timedSet
    /// "Bench Press done."
    case exerciseDone
    /// New best weight.
    case records
    /// Halfway through the workout, last set.
    case progress
    /// Over the planned rest: "You're 40 seconds over your rest."
    case pace
    /// Short cheers after a set on a good streak.
    case motivation
    /// Start and end of the workout.
    case summary
    /// A set done outside the planned order, skipping ahead.
    case offPlan

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .setUp: return "Next set"
        case .restStart: return "Rest starts"
        case .countdown: return "Countdown (10 s, 3-2-1)"
        case .go: return "Go"
        case .timedSet: return "Timed sets (halfway, done)"
        case .exerciseDone: return "Exercise done"
        case .records: return "Personal records"
        case .progress: return "Halfway, last set"
        case .pace: return "Over the rest"
        case .motivation: return "Cheers"
        case .summary: return "Start and finish"
        case .offPlan: return "Off the plan"
        }
    }

    public var example: String {
        switch self {
        case .setUp: return "“Bench Press, set 2 of 4: 8 reps at 60 kilos.”"
        case .restStart: return "“Rest 90 seconds. Up next: Rows.”"
        case .countdown: return "“10 seconds.” “3, 2, 1.”"
        case .go: return "“Go!”"
        case .timedSet: return "“Halfway.” “Done.”"
        case .exerciseDone: return "“Bench Press done.”"
        case .records: return "“New personal best!”"
        case .progress: return "“Halfway there.” “Last set.”"
        case .pace: return "“40 seconds over your rest.”"
        case .motivation: return "“Strong set.”"
        case .summary: return "“Let's go.” “Workout complete.”"
        case .offPlan: return "“Off plan: Rows. Next on plan: Bench Press.”"
        }
    }

    /// On out of the box; cheers are off (they were the most repetitive part).
    public var isOnByDefault: Bool { self != .motivation }
}

/// The words the coach says. Short, specific, about the set that's actually next – never about
/// one that's already done.
public enum CoachScript {
    /// "8 reps at 62.5 kilos", "45 seconds", "400 meters".
    public static func spoken(_ set: WorkoutSet, mode: ExerciseMode, unit: WeightUnit) -> String {
        switch mode {
        case .reps:
            var parts: [String] = []
            if let reps = set.effectiveReps { parts.append("\(reps) reps") }
            if let kg = set.effectiveWeight, kg > 0 {
                parts.append("at \(Format.number(unit.fromKilograms(kg))) \(unit == .kg ? "kilos" : "pounds")")
            }
            return parts.joined(separator: " ")
        case .time:
            return set.effectiveSeconds.map(duration) ?? ""
        case .distance:
            return set.effectiveMeters.map { "\(Format.number($0)) meters" } ?? ""
        }
    }

    /// "90 seconds", "2 minutes", "2 minutes 30" – seconds up to two minutes, as people say it.
    public static func duration(_ seconds: Int) -> String {
        if seconds < 60 || (seconds < 120 && seconds % 60 != 0) { return "\(seconds) seconds" }
        let minutes = seconds / 60
        let rest = seconds % 60
        let minuteText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return rest == 0 ? minuteText : "\(minuteText) \(rest)"
    }

    /// "set 2 of 4", "warm-up set", "last set".
    public static func setPosition(_ set: WorkoutSet, in item: WorkoutItem) -> String {
        if set.kind == .warmup { return "warm-up set" }
        let working = item.sets.filter { $0.kind != .warmup }
        guard let index = working.firstIndex(where: { $0.id == set.id }) else { return "" }
        if working.count == 1 { return "" }
        if index == working.count - 1 { return "last set" }
        return "set \(index + 1) of \(working.count)"
    }

    /// The set that's due now. The very first one says "First up".
    public static func setUp(item: WorkoutItem, set: WorkoutSet, unit: WeightUnit, isFirst: Bool) -> String {
        let what = spoken(set, mode: item.mode, unit: unit)
        let position = setPosition(set, in: item)
        var line = isFirst ? "First up: \(item.name)" : item.name
        if !position.isEmpty { line += ", \(position)" }
        if !what.isEmpty { line += ": \(what)" }
        return line + "."
    }

    public static func restStart(seconds: Int, next: (item: WorkoutItem, set: WorkoutSet)?, sameExercise: Bool) -> String {
        var line = "Rest \(duration(seconds))."
        if let next, !sameExercise { line += " Up next: \(next.item.name)." }
        return line
    }

    public static func go(next: (item: WorkoutItem, set: WorkoutSet)?, unit: WeightUnit) -> String {
        guard let next else { return "Go!" }
        let position = setPosition(next.set, in: next.item)
        return position.isEmpty ? "Go! \(next.item.name)." : "Go! \(next.item.name), \(position)."
    }

    /// Over the planned rest by `seconds` (only said once per break).
    public static func overRest(seconds: Double) -> String {
        let value = max(10, Int((seconds / 10).rounded()) * 10)
        return value >= 60
            ? "\(duration(value)) over your rest. Ready when you are."
            : "\(value) seconds over your rest."
    }

    public static func exerciseDone(_ item: WorkoutItem) -> String { "\(item.name) done." }

    private static let cheers = ["Strong set.", "Nice and controlled.", "That's how it's done.", "Good work.", "Solid."]

    /// A short cheer, only on a streak of sets on time; varies with `seed`.
    public static func cheer(streak: Int, seed: Int) -> String? {
        guard streak >= 3 else { return nil }
        return cheers[abs(seed) % cheers.count]
    }
}
