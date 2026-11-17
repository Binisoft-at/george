import Foundation

/// A workout recorded outside George (Apple Health: tennis, a run, a class …).
public struct ExternalWorkout: Hashable, Sendable, Identifiable {
    public var id: UUID
    /// A sport key such as "tennis", "running", "cycling", "hiking", "hiit", "yoga", "swimming".
    public var activity: String
    /// Display name ("Tennis").
    public var name: String
    public var start: Date
    public var durationSeconds: Double
    public var energyKcal: Double
    /// Effort 1–10 if known (Apple Health workout effort), otherwise nil.
    public var effort: Int?

    public init(id: UUID = UUID(), activity: String, name: String, start: Date, durationSeconds: Double, energyKcal: Double = 0, effort: Int? = nil) {
        self.id = id
        self.activity = activity
        self.name = name
        self.start = start
        self.durationSeconds = durationSeconds
        self.energyKcal = energyKcal
        self.effort = effort
    }
}

/// How other sports load muscles, so freshness and load stay honest on tennis or running days.
///
/// A sport adds load (hard-set equivalents) but never sets, so set targets aren't inflated.
/// Load scales with duration (per hour) and effort (5 = neutral, ±40 %).
public enum SportLoad {
    /// Hard-set equivalents per hour at neutral effort, spread over the muscles below.
    public static func profile(for activity: String) -> (perHour: Double, muscles: [MuscleContribution])? {
        func m(_ pairs: [(MuscleGroup, Double)]) -> [MuscleContribution] { pairs.map { MuscleContribution(group: $0.0, weight: $0.1) } }
        switch activity.lowercased() {
        case "tennis", "squash", "badminton", "padel", "pickleball", "table-tennis", "racquetball":
            return (6, m([(.quads, 1), (.calves, 1), (.glutes, 0.8), (.shoulders, 0.8), (.forearms, 0.8),
                          (.obliques, 0.7), (.adductors, 0.5), (.hamstrings, 0.5), (.upperBack, 0.4)]))
        case "running", "run", "trail-running":
            return (5, m([(.quads, 1), (.calves, 1), (.hamstrings, 0.8), (.glutes, 0.7), (.hipFlexors, 0.6)]))
        case "cycling", "biking", "spinning", "indoor-cycling":
            return (4, m([(.quads, 1), (.glutes, 0.7), (.calves, 0.5), (.hamstrings, 0.4)]))
        case "hiking", "walking-hike":
            return (3, m([(.quads, 0.8), (.calves, 0.8), (.glutes, 0.7), (.hamstrings, 0.4)]))
        case "hiit", "crossfit", "functional", "functional-strength", "cross-training", "bootcamp":
            return (8, m([(.quads, 0.8), (.glutes, 0.7), (.shoulders, 0.6), (.chest, 0.5), (.abs, 0.6), (.hamstrings, 0.5), (.calves, 0.4)]))
        case "swimming":
            return (5, m([(.lats, 1), (.shoulders, 1), (.upperBack, 0.7), (.triceps, 0.5), (.abs, 0.4)]))
        case "rowing":
            return (6, m([(.lats, 1), (.upperBack, 0.9), (.quads, 0.7), (.glutes, 0.6), (.biceps, 0.5), (.lowerBack, 0.4)]))
        case "soccer", "football", "basketball", "volleyball", "handball", "hockey", "rugby":
            return (6, m([(.quads, 1), (.calves, 0.9), (.hamstrings, 0.8), (.glutes, 0.8), (.adductors, 0.6), (.obliques, 0.4)]))
        case "climbing", "bouldering":
            return (7, m([(.forearms, 1), (.lats, 1), (.biceps, 0.8), (.upperBack, 0.7), (.shoulders, 0.5), (.abs, 0.4)]))
        case "skiing", "snowboarding":
            return (5, m([(.quads, 1), (.glutes, 0.7), (.calves, 0.5), (.adductors, 0.5), (.abs, 0.4)]))
        case "boxing", "martial-arts", "kickboxing":
            return (6, m([(.shoulders, 1), (.obliques, 0.8), (.triceps, 0.6), (.calves, 0.6), (.quads, 0.5)]))
        case "dance", "dancing":
            return (3, m([(.calves, 0.8), (.quads, 0.7), (.glutes, 0.6), (.abs, 0.4)]))
        case "yoga", "pilates", "stretching", "mobility", "mind-and-body":
            return (1.5, m([(.hamstrings, 0.6), (.hipFlexors, 0.6), (.abs, 0.6), (.shoulders, 0.4), (.glutes, 0.4)]))
        default:
            return nil
        }
    }

    /// Muscle events for external workouts (load only; sets and volume stay 0).
    public static func events(from workouts: [ExternalWorkout]) -> [MuscleEvent] {
        var result: [MuscleEvent] = []
        for workout in workouts {
            guard let profile = profile(for: workout.activity), workout.durationSeconds >= 300 else { continue }
            let hours = min(4, workout.durationSeconds / 3600)
            let effortFactor = workout.effort.map { 1 + (Double(min(10, max(1, $0))) - 5) * 0.08 } ?? 1
            let base = profile.perHour * hours * effortFactor
            for muscle in profile.muscles {
                result.append(MuscleEvent(
                    date: workout.start.addingTimeInterval(workout.durationSeconds),
                    sessionID: workout.id,
                    group: muscle.group,
                    load: base * muscle.weight / Double(max(1, profile.muscles.count)) * 3,
                    sets: 0,
                    volumeKg: 0,
                    exerciseKey: "sport:" + workout.activity,
                    exerciseName: workout.name
                ))
            }
        }
        return result
    }
}
