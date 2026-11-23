import SwiftUI
import WatchKit
import HealthKit
import WatchConnectivity

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
        // A context from the phone that arrives while the app isn't running: WatchConnectivity hands it
        // to WatchConnector during this task, which rewrites the complication (new streak, new plan).
        .backgroundTask(.watchConnectivity) {
            await WatchBackgroundDelivery.receivePendingContent()
        }
    }
}

/// Keeps the app awake in the background until WatchConnectivity has delivered what's pending.
enum WatchBackgroundDelivery {
    static func receivePendingContent() async {
        await MainActor.run { WatchConnector.shared.activate() }
        let session = WCSession.default
        // At most about 10 seconds: the system grants only a short time.
        for _ in 0..<100 {
            if session.activationState == .activated && !session.hasContentPending { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // The delegate hops to the main actor before it writes the complication; let that run.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run {}
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
