#if !os(watchOS)
import Foundation
import AppIntents

// Intents that both the app and the widget extension compile: the extension needs the types for
// its buttons (Live Activity, Home Screen widget, Control Center), the system then runs `perform()`
// in the app's process, where `GeorgeIntents.register` (App/Sources/Intents) installs the handler.
// App-only intents (templates, Shortcuts phrases) live in App/Sources/Intents.

/// What an intent asks the running app to do.
enum WorkoutIntentAction: Sendable, Equatable {
    /// "Start my workout": today's planned session, otherwise the program's suggested template
    /// (an empty workout when there's neither).
    case startNext
    /// The big button of the live workout: start the set that's due, or log it as done.
    case primary
    case addRest(Int)
    case skipRest
    case pause
    case resume
}

/// Hands intent actions to the app. Nil in the widget extension (it never performs them).
@MainActor
enum WorkoutIntentRelay {
    /// Runs the action and returns what Siri says back.
    static var handler: (@MainActor (WorkoutIntentAction) throws -> String)?

    static func run(_ action: WorkoutIntentAction) throws -> String {
        guard let handler else { throw GeorgeIntentError.notReady }
        return try handler(action)
    }
}

enum GeorgeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case noWorkout
    case templateNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "George isn't ready yet. Open the app and try again."
        case .noWorkout: return "No workout is running right now."
        case .templateNotFound: return "That workout doesn't exist anymore."
        }
    }
}

#if os(iOS)
/// Live commands run in the app's process, also from the Lock Screen and the Dynamic Island.
typealias WorkoutLiveIntent = LiveActivityIntent
#else
typealias WorkoutLiveIntent = AppIntent
#endif

// MARK: - Start

/// "Start my workout in George" (Siri, Shortcuts, Action Button, Control Center, widgets).
struct StartNextWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Next Workout"
    static let description = IntentDescription("Starts today's planned workout, or the next workout of your program.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try WorkoutIntentRelay.run(.startNext)
        return .result(dialog: "\(message)")
    }
}

// MARK: - Live workout

/// The big button: starts the set that's due, or logs it as done.
struct SetActionIntent: WorkoutLiveIntent {
    static let title: LocalizedStringResource = "Next Set"
    static let description = IntentDescription("Starts the set that's due, or logs it as done – the same as the big button of the live workout.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try WorkoutIntentRelay.run(.primary)
        return .result(dialog: "\(message)")
    }
}

struct AddRestIntent: WorkoutLiveIntent {
    static let title: LocalizedStringResource = "Add Rest Time"
    static let description = IntentDescription("Makes the current rest longer.")

    @Parameter(title: "Seconds", default: 15)
    var seconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$seconds) seconds of rest")
    }

    init() {}

    init(seconds: Int) {
        self.seconds = seconds
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try WorkoutIntentRelay.run(.addRest(min(600, max(5, seconds))))
        return .result(dialog: "\(message)")
    }
}

struct SkipRestIntent: WorkoutLiveIntent {
    static let title: LocalizedStringResource = "Skip Rest"
    static let description = IntentDescription("Ends the current rest – the next set is due now.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try WorkoutIntentRelay.run(.skipRest)
        return .result(dialog: "\(message)")
    }
}

struct PauseWorkoutIntent: WorkoutLiveIntent {
    static let title: LocalizedStringResource = "Pause Workout"
    static let description = IntentDescription("Pauses the running workout: the clock, the rest and a running hold stop.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try WorkoutIntentRelay.run(.pause)
        return .result(dialog: "\(message)")
    }
}

struct ResumeWorkoutIntent: WorkoutLiveIntent {
    static let title: LocalizedStringResource = "Resume Workout"
    static let description = IntentDescription("Continues a paused workout.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try WorkoutIntentRelay.run(.resume)
        return .result(dialog: "\(message)")
    }
}
#endif
