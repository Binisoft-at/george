import AppIntents
import SwiftUI
import WidgetKit

/// "Start Workout" for Control Center, the Lock Screen and the Action Button: opens George and
/// starts the next workout (the same as "Start my workout" with Siri).
struct StartWorkoutControl: ControlWidget {
    static let kind = "StartWorkoutControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartNextWorkoutIntent()) {
                Label("Start Workout", systemImage: "figure.strengthtraining.traditional")
            }
        }
        .displayName("Start Workout")
        .description("Starts your next workout in George.")
    }
}
