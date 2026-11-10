import Foundation
import BinisoftKit
import GeorgeCore
#if os(iOS)
import HealthKit
#endif

/// Keeps George running while the iPhone is locked, so the voice coach keeps talking: a HealthKit
/// workout session on the iPhone itself (iOS 26) when no Apple Watch records the workout. It has no
/// workout builder – it doesn't save anything to Apple Health; George saves the workout as before.
@MainActor
final class PhoneWorkoutSession {
    static let shared = PhoneWorkoutSession()

    #if os(iOS)
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    #endif

    /// Starts the session unless the watch records the workout, the voice is off, or coaching in the
    /// background is switched off.
    func begin(kind: WorkoutKind, watchWillRecord: Bool) {
        #if os(iOS)
        guard session == nil, !watchWillRecord, !LaunchOptions.current.isDemo, CoachPrefs.voice,
              VoiceSettings.speakInBackground, HKHealthStore.isHealthDataAvailable() else { return }
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: kind.healthConfiguration())
            session.startActivity(with: Date())
            self.session = session
            AppLog.info("iPhone workout session started (keeps the coach running when locked)", category: "voice")
        } catch {
            AppLog.warning("iPhone workout session: \(error.localizedDescription)", category: "voice")
        }
        #endif
    }

    func end() {
        #if os(iOS)
        guard let session else { return }
        session.end()
        self.session = nil
        #endif
    }
}
