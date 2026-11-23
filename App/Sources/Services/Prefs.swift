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
    static let askFatigue = "askFatigue"
    static let energyCheckIn = "energyCheckIn"
    static let healthSignals = "healthSignals"
    /// Include Apple Health "State of Mind" entries in the energy insights (read on demand, never stored).
    static let useStateOfMind = "useStateOfMind"
    /// Birth year read from Apple Health – kept on this device only (Health data must not go to iCloud).
    static let healthBirthYear = "healthBirthYear"

    // Voice coach (Settings → Voice Coach)
    static let voiceEngine = "voiceEngine"
    static let musicMode = "musicMode"
    static let voiceVolume = "voiceVolume"
    static let voiceRate = "voiceRate"
    static let voiceInBackground = "voiceInBackground"
    static let systemVoiceID = "systemVoiceID"
    static let naturalVoiceID = "naturalVoiceID"
    static let naturalVoiceName = "naturalVoiceName"
    /// Live mode: show the Start button between sets (measures the real rest).
    static let startButton = "startButton"
    /// Stretch/yoga/mobility: start the next hold by itself after the short rest.
    static let autoStartHolds = "autoStartHolds"
    /// Where the voice coach may speak: everywhere, headphones only, or following the silent switch.
    static let voiceRoute = "voiceRoute"
    /// The one-time "Voice coach is on" banner in the first live workout was answered.
    static let voiceBannerSeen = "voiceBannerSeen"
    /// Offer a matching cool-down routine on the finish screen.
    static let offerCoolDown = "offerCoolDown"
    /// Apple Health workouts (tennis, runs …) count toward muscle recovery and load.
    static let countOtherSports = "countOtherSports"
    /// Training-day and streak reminders (iOS notifications).
    static let trainingReminders = "trainingReminders"
    /// Reminder time (minutes after midnight).
    static let reminderMinutes = "reminderMinutes"
    /// Barbell weight for plate maths and warm-ups (kg).
    static let barKg = "barKg"
    /// The plates at hand for plate maths (`PlateSet` raw value, Settings → Training).
    static let plateSet = "plateSet"
    /// The running workout started on this device (only this device attaches to it on launch).
    static let liveSessionID = "george.liveSessionID"
    /// When this device claimed that workout (Start, Continue Here) – compared with a claim synced
    /// from another device (`LiveOwnership.verdict`).
    static let liveClaimedAt = "george.liveClaimedAt"
    /// This install's id for live ownership (`ThisDevice.installID`): made once, never synced as such
    /// and never the device's name.
    static let installID = "george.installID"
    /// Settings → Thalia: write finished workouts for Thalia on this device (default on).
    static let thaliaDeliver = "thaliaDeliver"
    /// When George last wrote a Thalia exchange file on this device.
    static let thaliaLastWritten = "thaliaLastWritten"
    /// An iCloud import has finished on this device at least once (Welcome stops waiting for it).
    static let cloudImportSeen = "george.cloudImportSeen"
}

/// Where the voice coach may speak.
enum VoiceRoute: String, CaseIterable, Identifiable {
    case everywhere, headphones, silentSwitch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everywhere: return "Headphones & speaker"
        case .headphones: return "Headphones only"
        case .silentSwitch: return "Follow silent mode"
        }
    }
    var detail: String {
        switch self {
        case .everywhere: return "George speaks through whatever is playing – also the phone's speaker in the gym."
        case .headphones: return "On the speaker George stays quiet; haptics and the rest sound still work."
        case .silentSwitch: return "Quiet when the phone is set to silent."
        }
    }
}

/// How much the live workout cheers you on.
enum MotivationStyle: String, CaseIterable, Identifiable {
    case full, calm, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: return "Lots"
        case .calm: return "Subtle"
        case .off: return "None"
        }
    }
    var detail: String {
        switch self {
        case .full: return "Flame, growing muscles, bursts and cheers."
        case .calm: return "Progress only – no bursts or banners."
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
    static var askFatigue: Bool { bool(Prefs.askFatigue, default: true) }
    static var startButton: Bool { bool(Prefs.startButton, default: true) }
    static var energyCheckIn: Bool { bool(Prefs.energyCheckIn, default: true) }
    static var healthSignals: Bool { bool(Prefs.healthSignals, default: true) }
    static var autoStartHolds: Bool { bool(Prefs.autoStartHolds, default: true) }
    static var offerCoolDown: Bool { bool(Prefs.offerCoolDown, default: true) }
    static var countOtherSports: Bool { bool(Prefs.countOtherSports, default: true) }
    static var voiceRoute: VoiceRoute {
        VoiceRoute(rawValue: UserDefaults.standard.string(forKey: Prefs.voiceRoute) ?? "") ?? .everywhere
    }
    static var barKg: Double {
        let value = UserDefaults.standard.double(forKey: Prefs.barKg)
        return value > 0 ? value : 20
    }
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
