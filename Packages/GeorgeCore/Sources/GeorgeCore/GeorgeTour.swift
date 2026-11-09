import Foundation
import BinisoftKitCore

/// What the tour's practice template looks like right now (rebuilt after every change).
public struct GeorgeTourSnapshot: Equatable, Sendable {
    public var exerciseCount = 0
    public var setCount = 0
    /// Exercises that sit in a superset or circuit.
    public var groupedExerciseCount = 0
    public var exerciseNames: [String] = []
    /// One prescription per exercise ("3 × 8 · 60 kg") – changes when reps or weights change.
    public var prescriptions: [String] = []
    /// Supersets/circuits whose exercises have different numbers of sets.
    public var mismatchedGroups = 0
    /// Start was tapped on the practice page (it never starts a real workout).
    public var startTapped = false

    public init() {}

    public init(content: WorkoutContent, unit: WeightUnit, startTapped: Bool) {
        let items = content.allItems
        exerciseCount = items.count
        setCount = items.reduce(0) { $0 + $1.sets.count }
        groupedExerciseCount = content.blocks.filter { $0.items.count > 1 }.reduce(0) { $0 + $1.items.count }
        exerciseNames = items.map(\.name)
        prescriptions = items.map { $0.prescription(unit: unit) }
        mismatchedGroups = content.mismatchedGroupCount
        self.startTapped = startTapped
    }
}

/// George's hands-on tour (BinisoftKit tour engine) on a practice copy of a template. To teach a new
/// feature: add a step with `since: version + 1` and bump `version` – people who already took the
/// tour then get just the new steps as "What's new". The Core tests check the catalog.
public enum GeorgeTour {
    public static let version = 2

    public static let catalog = TourCatalog<GeorgeTourSnapshot>.standard(
        appName: "George",
        version: version,
        practiceNoun: "workouts",
        replayHint: "Settings → Help (Help → George Tour on the Mac)",
        steps: [
            TourStep(
                id: "add", symbol: "plus.circle", title: "Add an exercise",
                body: "Scroll down and tap Add Exercises. Pick one or more – search helps – then tap Add at the bottom.",
                macBody: "Scroll down and click Add Exercises. Pick one or more, then click Add.",
                goal: .increased(\.exerciseCount)
            ),
            TourStep(
                id: "set", symbol: "plus.square.on.square", title: "One more set",
                body: "Tap the small + after an exercise's sets – or swipe right on the exercise and tap Set.",
                macBody: "Click the small + after an exercise's sets.",
                goal: .increased(\.setCount)
            ),
            TourStep(
                id: "numbers", symbol: "slider.horizontal.3", title: "Change the numbers",
                body: "Tap a set chip and change its reps or weight, then tap Done.",
                macBody: "Click a set chip and change its reps or weight, then click Done.",
                goal: .changed(\.prescriptions)
            ),
            TourStep(
                id: "swap", symbol: "arrow.triangle.swap", title: "Machine taken? Swap it",
                body: "Swipe left on an exercise, tap Swap and pick another one.",
                macBody: "Right-click an exercise, choose Swap Exercise… and pick another one.",
                goal: .changed(\.exerciseNames)
            ),
            TourStep(
                id: "superset", symbol: "link", title: "Build a superset",
                body: "Touch and hold an exercise and choose Superset with Next.",
                macBody: "Right-click an exercise and choose Superset with Next.",
                goal: .increased(\.groupedExerciseCount)
            ),
            TourStep(
                id: "match", since: 2, symbol: "equal.square", title: "Even out a superset",
                body: "When the exercises of a superset have different numbers of sets, its header shows Match sets – tap it and they all get the same. (All even? Give one an extra set with the small + first.) Works mid-workout too.",
                macBody: "When the exercises of a superset have different numbers of sets, click Match sets in its header. (All even? Give one an extra set with the small + first.)",
                goal: TourGoal { base, now, memory in
                    if base.mismatchedGroups > 0 || now.mismatchedGroups > base.mismatchedGroups { memory.sawChange = true }
                    return memory.sawChange && now.mismatchedGroups == 0
                }
            ),
            TourStep(
                id: "start", symbol: "play.fill", title: "Start the workout",
                body: "Tap Start at the bottom. For real, this opens live mode: tick sets off, tap a number to type it, a rest timer and voice coach that run by themselves, and your Apple Watch follows along. Everything you just tried also works mid-workout.",
                macBody: "Click Start at the bottom or press ⌘↩. For real, this opens live mode with check-offs and a rest timer. Everything you just tried also works mid-workout.",
                goal: .isTrue(\.startTapped)
            ),
        ]
    )
}
