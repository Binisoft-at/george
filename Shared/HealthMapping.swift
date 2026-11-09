#if os(iOS) || os(watchOS)
import HealthKit
import GeorgeCore

/// Maps George workout kinds to HealthKit activity types. Shared by the iPhone and Watch apps
/// so both record the same type for the same workout.
extension WorkoutKind {
    var healthActivityType: HKWorkoutActivityType {
        switch rawValue {
        case "gym": return .traditionalStrengthTraining
        case "band", "bodyweight": return .functionalStrengthTraining
        case "core": return .coreTraining
        case "hiit": return .highIntensityIntervalTraining
        case "cardio": return .mixedCardio
        case "stretch": return .flexibility
        case "yoga": return .yoga
        case "mobility": return .preparationAndRecovery
        case "sport", "tennis": return .tennis
        case "pilates": return .pilates
        case "climbing": return .climbing
        case "swimming", "swim": return .swimming
        case "cycling", "bike": return .cycling
        case "walking", "walk": return .walking
        case "running": return .running
        case "boxing": return .boxing
        case "dance": return .socialDance
        case "rowing": return .rowing
        default: return .other
        }
    }

    var healthLocationType: HKWorkoutSessionLocationType {
        switch rawValue {
        case "cardio", "sport", "tennis", "cycling", "running", "walking": return .unknown
        default: return .indoor
        }
    }

    func healthConfiguration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = healthActivityType
        configuration.locationType = healthLocationType
        return configuration
    }
}

enum HealthMetadataKey {
    /// Custom metadata keys George writes on its workouts (other apps ignore them, but they keep the context).
    static let sessionID = "GeorgeSessionID"
    static let workoutTitle = "GeorgeWorkoutTitle"
    static let exercises = "GeorgeExercises"
    static let muscles = "GeorgeMuscles"
    static let completedSets = "GeorgeCompletedSets"
    static let volumeKg = "GeorgeVolumeKg"
}
#endif
