import Foundation
import AVFoundation
import BinisoftKit
import GeorgeCore

/// Spoken cues during a workout: what's next, rest started, ten seconds left, go, exercise done,
/// new best, finished. Ducks music while it speaks. Settings → Workout Coach turns it off.
@MainActor
final class VoiceCoach: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceCoach()

    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "en-US")

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks unless the voice is off or this is a demo launch. `interrupt` cuts off what's being said.
    func say(_ text: String, interrupt: Bool = false) {
        guard CoachPrefs.voice, !LaunchOptions.current.isDemo, !text.isEmpty else { return }
        if interrupt, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        activateAudio()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.postUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func activateAudio() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        #endif
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            #if os(iOS)
            // Bring the music back up.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    // MARK: Phrases

    /// "8 reps at 62.5 kilos", "45 seconds", "400 meters".
    static func spoken(_ set: WorkoutSet, mode: ExerciseMode, unit: WeightUnit) -> String {
        switch mode {
        case .reps:
            var parts: [String] = []
            if let reps = set.effectiveReps { parts.append("\(reps) reps") }
            if let kg = set.effectiveWeight, kg > 0 {
                parts.append("at \(Format.number(unit.fromKilograms(kg))) \(unit == .kg ? "kilos" : "pounds")")
            }
            return parts.joined(separator: " ")
        case .time:
            return set.effectiveSeconds.map { "\($0) seconds" } ?? ""
        case .distance:
            return set.effectiveMeters.map { "\(Format.number($0)) meters" } ?? ""
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        let rest = seconds % 60
        let minuteText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return rest == 0 ? minuteText : "\(minuteText) \(rest)"
    }
}
