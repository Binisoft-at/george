import SwiftUI
import BinisoftKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Device-local preferences (not synced).
enum Prefs {
    static let haptics = "haptics"
    static let keepAwake = "keepAwake"
    static let restSounds = "restSounds"
    static let autoRest = "autoRest"
    static let didOnboard = "didOnboard"
    static let listGrouping = "listGrouping"
    static let healthAsked = "healthAsked"
    static let showImages = "showImages"
    /// Which version of the welcome & setup pages was seen (the hands-on tour keeps its own
    /// version in BinisoftKit `TourSchedule`).
    static let welcomeVersion = "tutorialVersion"
    static let currentWelcomeVersion = 1

    // Workout coach (Settings → Workout Coach)
    static let voiceCoach = "voiceCoach"
    static let voiceCountdown = "voiceCountdown"
    static let motivation = "motivation"
    static let paceNudges = "paceNudges"
    static let askEffort = "askEffort"
    static let energyCheckIn = "energyCheckIn"
    static let healthSignals = "healthSignals"
    /// Include Apple Health "State of Mind" entries in the energy insights (read on demand, never stored).
    static let useStateOfMind = "useStateOfMind"
    /// Birth year read from Apple Health – kept on this device only (Health data must not go to iCloud).
    static let healthBirthYear = "healthBirthYear"
}

/// How much the live workout cheers you on.
enum MotivationStyle: String, CaseIterable, Identifiable {
    case full, calm, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: return "Full"
        case .calm: return "Calm"
        case .off: return "Off"
        }
    }
    var detail: String {
        switch self {
        case .full: return "Flame, growing muscles, bursts and cheers."
        case .calm: return "Progress only, no bursts or nudges."
        case .off: return "Just your sets and the rest timer."
        }
    }
}

/// The workout-coach settings for non-view code (defaults match Settings).
enum CoachPrefs {
    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var voice: Bool { bool(Prefs.voiceCoach, default: true) }
    static var voiceCountdown: Bool { bool(Prefs.voiceCountdown, default: true) }
    static var sounds: Bool { bool(Prefs.restSounds, default: true) }
    static var paceNudges: Bool { bool(Prefs.paceNudges, default: true) }
    static var askEffort: Bool { bool(Prefs.askEffort, default: true) }
    static var energyCheckIn: Bool { bool(Prefs.energyCheckIn, default: true) }
    static var healthSignals: Bool { bool(Prefs.healthSignals, default: true) }
    static var motivation: MotivationStyle {
        MotivationStyle(rawValue: UserDefaults.standard.string(forKey: Prefs.motivation) ?? "") ?? .full
    }
}

/// Haptics usable from non-view code (the live workout controller).
@MainActor
enum Haptics {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: Prefs.haptics) as? Bool ?? true
    }

    static func tap() {
        guard enabled else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    static func success() {
        guard enabled else { return }
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    static func warning() {
        guard enabled else { return }
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func heavy() {
        guard enabled else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
    }
}
