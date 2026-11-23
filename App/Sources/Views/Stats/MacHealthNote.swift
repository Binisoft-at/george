import SwiftUI
import GeorgeCore

/// Apple Health isn't available on the Mac, and Health data never goes to iCloud (docs/HEALTH.md):
/// tennis, runs and other Health workouts count for the streak, muscular load and freshness on iPhone
/// and Watch only. On the Mac those numbers can be lower – these helpers say so, and keep the Mac
/// from raising a streak alarm (or offering a rescue) that the iPhone wouldn't.
enum MacHealth {
    static let note = "Tennis and other Apple Health workouts count on iPhone and Watch only – numbers here may be lower."

    /// The streak here leaves out Health workouts that count on iPhone (Mac, "Count Apple Health
    /// workouts" on).
    @MainActor
    static func streakMissesWorkouts(_ store: GeorgeStore) -> Bool {
        #if os(macOS)
        return store.settings.countHealthWorkouts
        #else
        return false
        #endif
    }

    /// Muscular load and freshness here leave out other sports (Mac, "Count other sports" on).
    static var loadMissesWorkouts: Bool {
        #if os(macOS)
        return CoachPrefs.countOtherSports
        #else
        return false
        #endif
    }

    /// The streak headline. Where Health workouts are missing (the Mac), anything short of "Week
    /// done" is just the days logged in George – no "at risk", "rescue" or "a save will cover".
    @MainActor
    static func headline(_ summary: StreakSummary, store: GeorgeStore) -> String {
        guard streakMissesWorkouts(store), summary.thisWeek.status != .goalMet, summary.thisWeek.status != .onBreak else { return summary.headline }
        return "\(summary.thisWeek.effectiveDays)/\(summary.thisWeek.goal) days logged in George"
    }

    /// Whether to offer a rescue workout (never where Health workouts are missing – the week may
    /// already be done on iPhone).
    @MainActor
    static func offersRescue(_ store: GeorgeStore) -> Bool {
        !streakMissesWorkouts(store)
    }
}

/// The Mac's note under the streak or the load, shown only where it applies.
struct MacHealthNote: View {
    enum Topic { case streak, load }
    let topic: Topic
    @Environment(GeorgeStore.self) private var store

    var body: some View {
        if applies {
            Label(MacHealth.note, systemImage: "applewatch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    private var applies: Bool {
        switch topic {
        case .streak: return MacHealth.streakMissesWorkouts(store)
        case .load: return MacHealth.loadMissesWorkouts
        }
    }
}
