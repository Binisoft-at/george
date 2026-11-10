import Foundation
import AVFoundation
import BinisoftKit
import GeorgeCore
#if os(iOS)
import UIKit
#endif

/// What happens to your music while the coach speaks (Settings → Voice Coach).
enum MusicMode: String, CaseIterable, Identifiable {
    /// Lower the music while speaking (iOS decides how much).
    case duck
    /// Leave the music alone; the coach speaks on top.
    case mix
    /// Pause the music while speaking; it continues afterwards.
    case pause

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duck: return "Lower it while speaking"
        case .mix: return "Keep it as it is"
        case .pause: return "Pause it while speaking"
        }
    }
}

/// Which voice speaks.
enum VoiceEngineKind: String, CaseIterable, Identifiable {
    /// The best voice installed on the device (Settings → Accessibility → Spoken Content → Voices).
    case system
    /// ElevenLabs with your own API key – natural and energetic; needs internet.
    case natural

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "iPhone voice"
        case .natural: return "Natural (ElevenLabs)"
        }
    }
}

/// The spoken coach. Ansagen go through one queue: each belongs to a set ("context"), and when the
/// workout moves on, cues about sets that are no longer current are dropped – no more chatter about
/// an exercise you've finished. Every kind of cue can be switched off; the session can be muted.
@MainActor
final class VoiceCoach: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = VoiceCoach()

    enum Priority: Int, Comparable {
        case low, normal, high
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    private struct Utterance {
        let text: String
        let cue: CoachCue
        let context: UUID?
        let priority: Priority
        let createdAt: Date
    }

    /// Muted for this workout (the speaker button in live mode).
    var isMuted = false {
        didSet { if isMuted { stop() } }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [Utterance] = []
    private var speaking: Utterance?
    private var deactivateTask: Task<Void, Never>?
    private var sessionActive = false

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: Speaking

    /// Queues `text` unless the voice is off, muted, this cue is switched off or the app is in the
    /// background without permission. `context` is the set it's about.
    func say(_ text: String, cue: CoachCue, context: UUID? = nil, priority: Priority = .normal) {
        guard !text.isEmpty, canSpeak(cue) else { return }
        let utterance = Utterance(text: text, cue: cue, context: context, priority: priority, createdAt: Date())
        if priority == .high {
            // Something important happened: drop everything less important that's still waiting.
            queue.removeAll { $0.priority < .high }
        }
        // Only one cheer at a time.
        if cue == .motivation, queue.contains(where: { $0.cue == .motivation }) { return }
        queue.append(utterance)
        if speaking == nil { next() }
        if VoiceSettings.engine == .natural {
            Task { await NaturalVoice.shared.prefetch(text) }
        }
    }

    /// Settings → "Play a Sample": ignores the cue switches and the mute button.
    func preview(_ text: String) {
        stop()
        queue.append(Utterance(text: text, cue: .setUp, context: nil, priority: .high, createdAt: Date()))
        next()
    }

    /// Drops queued cues that belong to another set than `current` (and stops one being spoken, if
    /// it's about an old set and not important).
    func moveOn(to current: UUID?) {
        queue.removeAll { $0.context != nil && $0.context != current && $0.priority < .high }
        if let speaking, speaking.context != nil, speaking.context != current, speaking.priority < .high {
            stopCurrent()
        }
    }

    func stop() {
        queue.removeAll()
        stopCurrent()
    }

    private func stopCurrent() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        player?.stop()
        player = nil
        speaking = nil
        scheduleDeactivate()
    }

    private func canSpeak(_ cue: CoachCue) -> Bool {
        guard CoachPrefs.voice, !isMuted, !LaunchOptions.current.isDemo, VoiceSettings.isOn(cue) else { return false }
        #if os(iOS)
        if UIApplication.shared.applicationState == .background && !VoiceSettings.speakInBackground { return false }
        #endif
        return true
    }

    private func next() {
        // Skip cues that waited too long – they'd be about a moment that has passed.
        while let first = queue.first, Date().timeIntervalSince(first.createdAt) > (first.priority == .high ? 12 : 6) {
            queue.removeFirst()
        }
        guard !queue.isEmpty else {
            speaking = nil
            scheduleDeactivate()
            return
        }
        let utterance = queue.removeFirst()
        speaking = utterance
        activateAudio()
        if VoiceSettings.engine == .natural {
            Task { await speakNatural(utterance) }
        } else {
            speakSystem(utterance.text)
        }
    }

    private func speakSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceSettings.systemVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(VoiceSettings.rate)
        utterance.pitchMultiplier = 0.95
        utterance.volume = Float(VoiceSettings.volume)
        utterance.preUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    private func speakNatural(_ utterance: Utterance) async {
        let url = await NaturalVoice.shared.audioFile(for: utterance.text, timeout: 1.6)
        // The workout may have moved on while the audio was loading.
        guard speaking?.createdAt == utterance.createdAt else { return }
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
            speakSystem(utterance.text)
            return
        }
        player.volume = Float(VoiceSettings.volume)
        player.delegate = self
        self.player = player
        if !player.play() { speakSystem(utterance.text) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedOne() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedOne() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.finishedOne()
        }
    }

    private func finishedOne() {
        guard !synthesizer.isSpeaking, player?.isPlaying != true else { return }
        speaking = nil
        next()
    }

    // MARK: Audio session

    private func activateAudio() {
        deactivateTask?.cancel()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions
        switch VoiceSettings.musicMode {
        case .duck: options = [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        case .mix: options = [.mixWithOthers]
        case .pause: options = []
        }
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: options)
            try session.setActive(true)
            sessionActive = true
        } catch {
            AppLog.warning("Voice audio session: \(error.localizedDescription)", category: "voice")
        }
        #endif
    }

    /// Gives the music its volume back shortly after the last cue (not between two cues).
    private func scheduleDeactivate() {
        deactivateTask?.cancel()
        guard sessionActive else { return }
        deactivateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.speaking == nil, self.queue.isEmpty else { return }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            self.sessionActive = false
        }
    }

    // MARK: Notification sounds (when the app isn't running)

    /// Renders `text` into a sound file for a notification (rest over while the phone is locked).
    /// Returns the file name in Library/Sounds, or nil.
    func notificationSound(for text: String) async -> String? {
        guard CoachPrefs.voice, VoiceSettings.speakInBackground, !LaunchOptions.current.isDemo else { return nil }
        let name = "george-cue-\(abs(text.hashValue) % 1_000_000).caf"
        guard let directory = Self.soundsDirectory() else { return nil }
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return name }
        Self.cleanOldSounds(in: directory, keeping: name)
        if VoiceSettings.engine == .natural, let source = await NaturalVoice.shared.audioFile(for: text, timeout: 4),
           Self.convert(source, to: target) {
            return name
        }
        return await renderSystem(text, to: target) ? name : nil
    }

    private func renderSystem(_ text: String, to target: URL) async -> Bool {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceSettings.systemVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(VoiceSettings.rate)
        let renderer = AVSpeechSynthesizer()
        return await withCheckedContinuation { continuation in
            var file: AVAudioFile?
            var finished = false
            renderer.write(utterance) { buffer in
                _ = renderer // keep the synthesizer alive until it has written everything
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finished = true
                    continuation.resume(returning: file != nil)
                    return
                }
                if file == nil {
                    file = try? AVAudioFile(forWriting: target, settings: pcm.format.settings,
                                            commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try? file?.write(from: pcm)
            }
        }
    }

    private static func convert(_ source: URL, to target: URL) -> Bool {
        guard let input = try? AVAudioFile(forReading: source) else { return false }
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)),
              (try? input.read(into: buffer)) != nil,
              let output = try? AVAudioFile(forWriting: target, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        else { return false }
        return (try? output.write(from: buffer)) != nil
    }

    private static func soundsDirectory() -> URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let sounds = library.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        return sounds
    }

    private static func cleanOldSounds(in directory: URL, keeping: String) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("george-cue-") && file.lastPathComponent != keeping {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Phrases (kept for older call sites)

    static func spoken(_ set: WorkoutSet, mode: ExerciseMode, unit: WeightUnit) -> String {
        CoachScript.spoken(set, mode: mode, unit: unit)
    }

    static func duration(_ seconds: Int) -> String { CoachScript.duration(seconds) }
}

/// The voice settings, readable from anywhere.
enum VoiceSettings {
    private static var defaults: UserDefaults { .standard }

    static func isOn(_ cue: CoachCue) -> Bool {
        defaults.object(forKey: "voiceCue." + cue.rawValue) as? Bool ?? cue.isOnByDefault
    }

    static func set(_ cue: CoachCue, on: Bool) { defaults.set(on, forKey: "voiceCue." + cue.rawValue) }

    static var engine: VoiceEngineKind {
        let kind = VoiceEngineKind(rawValue: defaults.string(forKey: Prefs.voiceEngine) ?? "") ?? .system
        return kind == .natural && !NaturalVoice.hasKey ? .system : kind
    }

    static var musicMode: MusicMode { MusicMode(rawValue: defaults.string(forKey: Prefs.musicMode) ?? "") ?? .duck }
    static var volume: Double { defaults.object(forKey: Prefs.voiceVolume) as? Double ?? 1 }
    static var rate: Double { defaults.object(forKey: Prefs.voiceRate) as? Double ?? 1.05 }
    static var speakInBackground: Bool { defaults.object(forKey: Prefs.voiceInBackground) as? Bool ?? true }

    /// The chosen voice, or the best installed English one: premium before enhanced, male first.
    static var systemVoice: AVSpeechSynthesisVoice? {
        if let id = defaults.string(forKey: Prefs.systemVoiceID), let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        return englishVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// English voices, best first.
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if (a.gender == .male) != (b.gender == .male) { return a.gender == .male }
                if (a.language == "en-US") != (b.language == "en-US") { return a.language == "en-US" }
                return a.name < b.name
            }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Basic"
        }
    }
}
