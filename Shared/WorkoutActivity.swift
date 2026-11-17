#if os(iOS) && canImport(ActivityKit)
import Foundation
import ActivityKit

/// The running workout on the Lock Screen and in the Dynamic Island (Live Activity).
///
/// Compiled into the iPhone app, which starts, updates and ends it (LiveActivityBridge), and into
/// the widget extension, which draws it. The state stays small: countdowns are dates the system
/// animates itself (`Text(timerInterval:)`), so the app only updates when something really changes.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The exercise that's due now; empty once every set is done.
        var exercise: String
        /// The due set as the app shows it ("8 × 60 kg", "45 s"); may be empty.
        var setLine: String
        /// Set n of m within the exercise (0 when nothing is due).
        var setNumber: Int
        var setCount: Int
        /// Sets done / planned in the whole workout.
        var completedSets: Int
        var totalSets: Int
        /// A running rest (nil while working or paused).
        var restStartedAt: Date?
        var restEndsAt: Date?
        /// A running hold (timed set).
        var holdStartedAt: Date?
        var holdEndsAt: Date?
        var isPaused: Bool
        /// What the big button does: start the set (true) or log it as done (false).
        var primaryIsStart: Bool
    }

    var sessionID: UUID
    /// The workout's name ("UPPER").
    var title: String
    /// SF Symbol of the workout kind.
    var symbol: String
}

extension WorkoutActivityAttributes.ContentState {
    var allSetsDone: Bool { exercise.isEmpty }

    var isResting: Bool { restEndsAt != nil }

    /// Rest countdown range (always lower ≤ upper; nil without a running rest).
    var restInterval: ClosedRange<Date>? { Self.interval(restStartedAt, restEndsAt) }

    /// Hold countdown range (nil without a running hold).
    var holdInterval: ClosedRange<Date>? { Self.interval(holdStartedAt, holdEndsAt) }

    /// The countdown to show right now: the rest, else a running hold.
    var countdown: (interval: ClosedRange<Date>, isRest: Bool)? {
        if let restInterval { return (restInterval, true) }
        if let holdInterval { return (holdInterval, false) }
        return nil
    }

    /// The content is outdated once the countdown ran out (the view then says "Go").
    var staleDate: Date? { restEndsAt ?? holdEndsAt }

    var primaryLabel: String { primaryIsStart ? "Start" : "Done" }
    var primarySymbol: String { primaryIsStart ? "play.fill" : "checkmark" }

    /// "Set 2 of 4".
    var setPosition: String {
        guard setCount > 0 else { return "" }
        return "Set \(setNumber) of \(setCount)"
    }

    /// Share of the workout's sets that are done, 0…1.
    var workoutProgress: Double {
        guard totalSets > 0 else { return 0 }
        return min(1, max(0, Double(completedSets) / Double(totalSets)))
    }

    private static func interval(_ start: Date?, _ end: Date?) -> ClosedRange<Date>? {
        guard let end else { return nil }
        let lower = min(start ?? end, end)
        return lower...end
    }
}
#endif
