import SwiftUI
import WatchKit
import HealthKit

@main
struct GeorgeWatchApp: App {
    @WKApplicationDelegateAdaptor(GeorgeWatchAppDelegate.self) private var appDelegate

    init() {
        // Activate WatchConnectivity as early as possible so a pending context or queued
        // messages from the phone are delivered right away.
        WatchConnector.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(WatchConnector.shared)
                .environment(WorkoutManager.shared)
        }
    }
}

/// Receives the workout launches from the iPhone (`HKHealthStore.startWatchApp(with:completion:)`)
/// and the relaunch after a crash during a workout.
///
/// `MainActor.assumeIsolated` keeps this correct whether or not the SDK marks `WKApplicationDelegate`
/// as main-actor isolated; WatchKit always calls these methods on the main thread.
final class GeorgeWatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        MainActor.assumeIsolated {
            WatchConnector.shared.activate()
        }
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        MainActor.assumeIsolated {
            // The George session ID arrives with the phone's next live state and is attached then.
            WorkoutManager.shared.start(configuration: workoutConfiguration, sessionID: nil, title: nil)
        }
    }

    func handleActiveWorkoutRecovery() {
        MainActor.assumeIsolated {
            WorkoutManager.shared.recoverActiveWorkout()
        }
    }
}
