import Foundation

/// Ready-made stretch, mobility and yoga routines built from the bundled library. Each can be added
/// as a template, started right away, or shared (PDF / George file) like any template.
public struct Routine: Identifiable, Sendable {
    public struct Entry: Sendable {
        public var exercise: String
        public var sets: Int
        /// Hold per set (time-mode exercises), seconds.
        public var hold: Int?
        /// Reps per set (rep-mode exercises).
        public var reps: Int?

        public init(_ exercise: String, sets: Int = 1, hold: Int? = nil, reps: Int? = nil) {
            self.exercise = exercise
            self.sets = sets
            self.hold = hold
            self.reps = reps
        }
    }

    public var id: String
    public var name: String
    public var subtitle: String
    public var kind: WorkoutKind
    public var symbol: String
    public var entries: [Entry]

    /// The routine as workout content; exercises missing from `catalog` are left out.
    public func content(using catalog: ExerciseCatalog) -> WorkoutContent {
        var content = WorkoutContent()
        let items: [WorkoutItem] = entries.compactMap { entry in
            guard let exercise = catalog.exercise(named: entry.exercise) else { return nil }
            var item = exercise.makeItem(defaultRest: 10)
            let template: WorkoutSet
            switch item.mode {
            case .time: template = WorkoutSet(targetSeconds: entry.hold ?? exercise.defaults?.holdSec ?? 30)
            case .reps: template = WorkoutSet(targetReps: String(entry.reps ?? Int(exercise.defaults?.reps ?? "") ?? 10))
            case .distance: template = item.sets.first ?? WorkoutSet(targetMeters: 400)
            }
            item.sets = (0..<max(1, entry.sets)).map { _ in template.clearedCopy() }
            item.restSeconds = 10
            return item
        }
        content.append(items: items, asGroup: false, section: subtitle.uppercased())
        return content
    }

    /// Names the catalog doesn't know (the tests keep this empty).
    public func missing(in catalog: ExerciseCatalog) -> [String] {
        entries.map(\.exercise).filter { catalog.exercise(named: $0) == nil }
    }
}

public enum RoutineLibrary {
    public static let all: [Routine] = [
        Routine(id: "morning-mobility", name: "Morning Mobility", subtitle: "Wake up joints and spine", kind: .mobility, symbol: "sunrise", entries: [
            .init("Cat-Cow", reps: 10), .init("Thoracic Open Book", reps: 8), .init("World's Greatest Stretch", hold: 30),
            .init("90/90 Hip Switches", reps: 8), .init("Hip CARs", reps: 5), .init("Shoulder CARs", reps: 5),
            .init("Squat-to-Stand", reps: 8), .init("Standing Roll-Down", reps: 5),
        ]),
        Routine(id: "desk-break", name: "Desk Break", subtitle: "Neck, back and hips after sitting", kind: .stretch, symbol: "desktopcomputer", entries: [
            .init("Neck Rotation Stretch", hold: 20), .init("Levator Scapulae Stretch", hold: 30), .init("Seated Thoracic Extension", hold: 30),
            .init("Desk Lat Stretch", hold: 30), .init("Chair Hip Flexor Stretch", hold: 30), .init("Seated Figure-Four Stretch", hold: 30),
            .init("Chair Forward Fold", hold: 30),
        ]),
        Routine(id: "post-workout", name: "After the Gym", subtitle: "Full-body cool-down", kind: .stretch, symbol: "figure.cooldown", entries: [
            .init("Doorway Pec Stretch", hold: 30), .init("Overhead Lat", hold: 30), .init("Triceps Stretch", hold: 30),
            .init("Kneeling Hip Flexor", hold: 40), .init("Lying Hamstring", hold: 40), .init("Seated Figure-Four Stretch", hold: 40),
            .init("Standing Gastrocnemius Calf Stretch", hold: 30), .init("Child's Pose", hold: 60),
        ]),
        Routine(id: "post-run", name: "After the Run", subtitle: "Legs and hips, standing", kind: .stretch, symbol: "figure.run", entries: [
            .init("Standing Quad Stretch", hold: 30), .init("Standing Hamstring and Calf Stretch", hold: 30), .init("Standing Outer Hip Stretch", hold: 30),
            .init("Standing Adductor Stretch", hold: 30), .init("Toes-Up Wall Calf Stretch", hold: 30), .init("Standing Shin Stretch", hold: 20),
            .init("Runner's Stretch", hold: 40),
        ]),
        Routine(id: "hip-openers", name: "Hip Openers", subtitle: "Deep hips and groin", kind: .yoga, symbol: "figure.yoga", entries: [
            .init("90/90 Hip Stretch", hold: 45), .init("Lizard Pose", hold: 45), .init("Pigeon Pose", hold: 60),
            .init("Frog Pose", hold: 45), .init("Garland Pose", hold: 45), .init("Bound Angle Pose", hold: 45),
            .init("Happy Baby Pose", hold: 45), .init("Reclined Pigeon Pose", hold: 45),
        ]),
        Routine(id: "sun-salutations", name: "Sun Salutation Flow", subtitle: "Ten minutes of yoga flow", kind: .yoga, symbol: "sun.max", entries: [
            .init("Mountain Pose", hold: 30), .init("Sun Salutation A", sets: 3, hold: 60), .init("Sun Salutation B", sets: 2, hold: 90),
            .init("Warrior II", hold: 30), .init("Triangle Pose", hold: 30), .init("Downward-Facing Dog", hold: 45),
            .init("Child's Pose", hold: 45), .init("Corpse Pose", hold: 120),
        ]),
        Routine(id: "evening-wind-down", name: "Evening Wind-Down", subtitle: "Restorative, before bed", kind: .yoga, symbol: "moon.stars", entries: [
            .init("Extended Child's Pose", hold: 60), .init("Supine Spinal Twist", hold: 45), .init("Reclined Bound Angle Pose", hold: 90),
            .init("Supported Bridge Pose", hold: 60), .init("Legs Up the Wall", hold: 180), .init("Corpse Pose", hold: 180),
        ]),
        Routine(id: "tennis-warm-up", name: "Tennis Warm-Up", subtitle: "Dynamic, before you play", kind: .mobility, symbol: "figure.tennis", entries: [
            .init("A-March", reps: 10), .init("Walking Knee Hug", reps: 8), .init("Walking Quad Pull", reps: 8),
            .init("Hamstring Sweeps", reps: 8), .init("Reverse Lunge with Overhead Reach", reps: 6), .init("Cossack Squat", reps: 6),
            .init("Shoulder CARs", reps: 5), .init("Racket Forearm Rotations", reps: 10),
        ]),
        Routine(id: "shoulders-upper-back", name: "Shoulders & Upper Back", subtitle: "Posture and overhead mobility", kind: .stretch, symbol: "figure.arms.open", entries: [
            .init("Wall Angels", reps: 10), .init("Thread the Needle Pose", hold: 30), .init("Puppy Pose", hold: 45),
            .init("Doorway Pec Stretch", hold: 30), .init("Sleeper Stretch", hold: 30), .init("Eagle Arms Stretch", hold: 30),
            .init("Supine External Rotation Stretch", hold: 30),
        ]),
    ]

    public static func routine(id: String) -> Routine? { all.first { $0.id == id } }
}
