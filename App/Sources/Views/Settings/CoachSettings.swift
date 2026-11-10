import SwiftUI
import BinisoftKit
import GeorgeCore

/// Settings → Workout Coach: every voice, sound, haptic and motivation extra can be switched off.
struct CoachSettingsSection: View {
    @AppStorage(Prefs.voiceCoach) private var voice = true
    @AppStorage(Prefs.restSounds) private var sounds = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.motivation) private var motivationRaw = MotivationStyle.full.rawValue
    @AppStorage(Prefs.paceNudges) private var nudges = true
    @AppStorage(Prefs.askEffort) private var askEffort = true
    @AppStorage(Prefs.askFatigue) private var askFatigue = true
    @AppStorage(Prefs.startButton) private var startButton = true
    @AppStorage(Prefs.energyCheckIn) private var energyCheckIn = true
    @AppStorage(Prefs.autoRest) private var autoRest = true
    @AppStorage(Prefs.keepAwake) private var keepAwake = true

    var body: some View {
        Section {
            NavigationLink {
                VoiceSettingsView()
            } label: {
                LabeledContent {
                    Text(voice ? VoiceSettings.engine.title : "Off")
                } label: {
                    Label("Voice Coach", systemImage: "waveform")
                }
            }
            Picker(selection: $motivationRaw) {
                ForEach(MotivationStyle.allCases) { style in
                    Text(style.title).tag(style.rawValue)
                }
            } label: {
                Label("Motivation", systemImage: "flame.fill")
            }
            Text((MotivationStyle(rawValue: motivationRaw) ?? .full).detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(isOn: $startButton) { Label("Start button between sets", systemImage: "play.circle") }
            Toggle(isOn: $sounds) { Label("Sound when rest ends", systemImage: "bell") }
            Toggle(isOn: $haptics) { Label("Haptics", systemImage: "iphone.radiowaves.left.and.right") }
            Toggle(isOn: $nudges) { Label("Tell me when I'm over the rest", systemImage: "hourglass") }
            Toggle(isOn: $askFatigue) { Label("Ask how fatigued the muscles are", systemImage: "bolt.heart") }
            Toggle(isOn: $askEffort) { Label("Ask how many reps were left", systemImage: "gauge.with.dots.needle.67percent") }
            Toggle(isOn: $energyCheckIn) { Label("Energy check-in", systemImage: "battery.75percent") }
            Toggle(isOn: $autoRest) { Label("Start rest timer automatically", systemImage: "timer.circle") }
            Toggle(isOn: $keepAwake) { Label("Keep screen awake", systemImage: "sun.max") }
        } header: {
            Text("Workout Coach")
        } footer: {
            Text("Start button: tap it when you begin a set – George compares your real rest with the planned one and shows how far behind or ahead you are (tap the bar at the bottom of live mode). Low-energy days: pick “Calm” in the workout's ⋯ menu or answer the check-in – no nudges, more slack.")
        }
    }
}

/// Settings → Workout Coach → Voice Coach: which voice, when it speaks, what happens to the music,
/// and whether it keeps talking with the phone locked.
struct VoiceSettingsView: View {
    @AppStorage(Prefs.voiceCoach) private var voice = true
    @AppStorage(Prefs.voiceEngine) private var engineRaw = VoiceEngineKind.system.rawValue
    @AppStorage(Prefs.musicMode) private var musicRaw = MusicMode.duck.rawValue
    @AppStorage(Prefs.voiceVolume) private var volume = 1.0
    @AppStorage(Prefs.voiceRate) private var rate = 1.05
    @AppStorage(Prefs.voiceInBackground) private var background = true
    @AppStorage(Prefs.systemVoiceID) private var systemVoiceID = ""
    @AppStorage(Prefs.naturalVoiceID) private var naturalVoiceID = NaturalVoice.defaultVoiceID
    @AppStorage(Prefs.naturalVoiceName) private var naturalVoiceName = "Brian"
    @State private var cueStates: [CoachCue: Bool] = Dictionary(uniqueKeysWithValues: CoachCue.allCases.map { ($0, VoiceSettings.isOn($0)) })
    @State private var keyText = ""
    @State private var hasKey = NaturalVoice.hasKey
    @State private var voices: [NaturalVoice.Voice] = []
    @State private var voiceError: String?

    private static let sample = "Bench Press, set 2 of 4: 8 reps at 62.5 kilos. Let's go!"

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $voice) { Label("Voice coach", systemImage: "waveform") }
                if voice {
                    Picker("Voice", selection: $engineRaw) {
                        ForEach(VoiceEngineKind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Button {
                        VoiceCoach.shared.preview(Self.sample)
                    } label: {
                        Label("Play a Sample", systemImage: "play.circle")
                    }
                }
            } footer: {
                Text("Mute it for one workout with the speaker button in live mode (⋯ or the panel).")
            }

            if voice {
                if engineRaw == VoiceEngineKind.natural.rawValue {
                    naturalSection
                } else {
                    systemSection
                }

                Section {
                    ForEach(CoachCue.allCases) { cue in
                        Toggle(isOn: Binding(get: { cueStates[cue] ?? cue.isOnByDefault }, set: { on in
                            cueStates[cue] = on
                            VoiceSettings.set(cue, on: on)
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cue.title)
                                Text(cue.example).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("When the coach speaks")
                } footer: {
                    Text("The coach only talks about the set that's actually next. When you move on, anything still waiting is dropped.")
                }

                Section {
                    Picker(selection: $musicRaw) {
                        ForEach(MusicMode.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("Music", systemImage: "music.note")
                    }
                    VStack(alignment: .leading) {
                        Label("Voice volume", systemImage: "speaker.wave.2")
                        Slider(value: $volume, in: 0.3...1)
                    }
                    VStack(alignment: .leading) {
                        Label("Speed", systemImage: "hare")
                        Slider(value: $rate, in: 0.85...1.25)
                    }
                } header: {
                    Text("Music")
                } footer: {
                    Text("“Keep it as it is” never touches your music – lower the voice volume if it's too loud. “Lower it” is iOS's own ducking; George gives the volume back right after each cue.")
                }

                Section {
                    Toggle(isOn: $background) { Label("Keep coaching when the phone is locked", systemImage: "lock.iphone") }
                } footer: {
                    Text("With the screen locked, George keeps the workout running on the iPhone (an Apple Health workout session – nothing extra is saved), so the voice keeps coming. If iOS still pauses George, the end of a rest is spoken by the notification instead.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voice Coach")
        .inlineTitle()
    }

    @ViewBuilder
    private var systemSection: some View {
        let installed = VoiceSettings.englishVoices()
        Section {
            Picker("iPhone voice", selection: $systemVoiceID) {
                Text("Best installed").tag("")
                ForEach(installed, id: \.identifier) { voice in
                    Text("\(voice.name) · \(VoiceSettings.qualityLabel(voice))\(voice.gender == .male ? " · male" : "")").tag(voice.identifier)
                }
            }
        } header: {
            Text("iPhone voice")
        } footer: {
            Text("For a natural voice, download a Premium one: iPhone Settings → Accessibility → Spoken Content → Voices → English – e.g. “Evan (Premium)” or “Nathan (Premium)”. George picks the best installed voice by itself.")
        }
    }

    @ViewBuilder
    private var naturalSection: some View {
        Section {
            if hasKey {
                LabeledContent("API key", value: "Saved on this iPhone")
                Picker("Voice", selection: $naturalVoiceID) {
                    if voices.isEmpty { Text(naturalVoiceName).tag(naturalVoiceID) }
                    ForEach(voices) { voice in
                        Text(voice.summary.isEmpty ? voice.name : "\(voice.name) · \(voice.summary)").tag(voice.voice_id)
                    }
                }
                .onChange(of: naturalVoiceID) { _, id in
                    if let voice = voices.first(where: { $0.voice_id == id }) { naturalVoiceName = voice.name }
                }
                Button("Remove Key", role: .destructive) {
                    NaturalVoice.setAPIKey(nil)
                    NaturalVoice.clearCache()
                    hasKey = false
                }
            } else {
                SecureField("ElevenLabs API key", text: $keyText)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                Button("Save Key") {
                    NaturalVoice.setAPIKey(keyText)
                    keyText = ""
                    hasKey = NaturalVoice.hasKey
                    Task { await loadVoices() }
                }
                .disabled(keyText.trimmingCharacters(in: .whitespaces).count < 10)
            }
            if let voiceError {
                Text(voiceError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Natural voice (ElevenLabs)")
        } footer: {
            Text("Uses your own ElevenLabs account (elevenlabs.io → Profile → API keys). The key stays in this iPhone's Keychain. The coach's lines (exercise names and numbers, nothing else) are sent to ElevenLabs and cached here, so each line is made once – a workout costs roughly 1,000–3,000 characters of your plan. Without internet the iPhone voice speaks.")
        }
        .task { if hasKey && voices.isEmpty { await loadVoices() } }
    }

    private func loadVoices() async {
        do {
            voices = try await NaturalVoice.voices().sorted { $0.name < $1.name }
            voiceError = nil
        } catch {
            voiceError = error.localizedDescription
        }
    }
}

/// Settings → Your Profile: age, experience and goal, for advice that fits (weekly sets, reps,
/// rest, recovery).
struct ProfileSettingsSection: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @AppStorage(Prefs.healthBirthYear) private var healthBirthYear = 0
    @State private var healthMessage: String?

    var body: some View {
        let settings = store.settings
        let currentYear = Calendar.current.component(.year, from: Date())
        Section {
            Picker(selection: Binding(get: { settings.birthYear }, set: { settings.birthYear = $0; store.save() })) {
                Text("Not set").tag(0)
                ForEach((1930...(currentYear - 12)).reversed(), id: \.self) { year in
                    Text(verbatim: "\(year) · \(currentYear - year) years").tag(year)
                }
            } label: {
                Label("Born", systemImage: "birthday.cake")
            }
            if health.isAvailable && settings.birthYear == 0 {
                if healthBirthYear > 0 {
                    LabeledContent("From Apple Health", value: "\(currentYear - healthBirthYear) years · this device only")
                        .font(.subheadline)
                } else {
                    Button {
                        Task {
                            if let year = await health.birthYear() {
                                healthBirthYear = year
                                store.bump()
                                healthMessage = nil
                            } else {
                                healthMessage = "No birth date in Apple Health (or access not allowed)."
                            }
                        }
                    } label: {
                        Label("Use Age from Apple Health", systemImage: "heart.text.square")
                    }
                }
                if let healthMessage {
                    Text(healthMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker(selection: Binding(get: { settings.experienceRaw }, set: { settings.experienceRaw = $0; store.save() })) {
                Text("Not set").tag("")
                ForEach(TrainingExperience.allCases) { Text($0.title).tag($0.rawValue) }
            } label: {
                Label("Experience", systemImage: "chart.line.uptrend.xyaxis")
            }
            Picker(selection: Binding(get: { settings.goalRaw }, set: { settings.goalRaw = $0; store.save() })) {
                Text("Not set").tag("")
                ForEach(TrainingGoal.allCases) { Text($0.title).tag($0.rawValue) }
            } label: {
                Label("Goal", systemImage: "target")
            }
            NavigationLink {
                OptimalForYouView()
            } label: {
                Label("What's Optimal for You", systemImage: "sparkles")
            }
        } header: {
            Text("Your Profile")
        } footer: {
            Text("Used for the muscle targets (sets per week, reps, rest) and recovery estimates – recovery takes a little longer with age. What you pick here syncs through your iCloud; an age read from Apple Health stays on this device.")
        }
    }
}

extension GeorgeStore {
    /// Age, experience and goal from Settings → Your Profile (defaults when not set).
    var profile: TrainingProfile {
        TrainingProfile(birthYear: birthYear, experienceRaw: settings.experienceRaw, goalRaw: settings.goalRaw, calendar: calendar)
    }

    /// The year picked in Settings, else the one read from Apple Health on this device.
    var birthYear: Int {
        settings.birthYear > 0 ? settings.birthYear : UserDefaults.standard.integer(forKey: Prefs.healthBirthYear)
    }

    var hasProfile: Bool { birthYear > 0 || !settings.experienceRaw.isEmpty || !settings.goalRaw.isEmpty }
}

/// The numbers George aims for, for this person, with sources.
struct OptimalForYouView: View {
    @Environment(GeorgeStore.self) private var store

    var body: some View {
        Form {
            OptimalForYouSection(profile: store.profile, showsEdit: false)
        }
        .formStyle(.grouped)
        .navigationTitle("Optimal for You")
        .inlineTitle()
    }
}

/// Reusable "Optimal for you" block: the profile line, the targets and the sources. Sits in muscle
/// detail, muscular load and Settings.
struct OptimalForYouSection: View {
    let profile: TrainingProfile
    var focus: String? = nil
    var showsEdit = true
    @Environment(GeorgeStore.self) private var store

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.headline)
                        .font(.subheadline.weight(.semibold))
                    if !store.hasProfile {
                        Text("Defaults – set your age, experience and goal in Settings → Your Profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let focus {
                Text(focus)
                    .font(.subheadline)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                target("Sets / muscle / week", "\(profile.weeklySets.lowerBound)–\(profile.weeklySets.upperBound)", "square.stack.3d.up")
                target("Reps per set", "\(profile.repRange.lowerBound)–\(profile.repRange.upperBound)", "repeat")
                target("Rest", "\(Format.shortDuration(profile.restSeconds.lowerBound))–\(Format.shortDuration(profile.restSeconds.upperBound))", "timer")
                target("Recovery", "\(profile.recoveryHours.lowerBound)–\(profile.recoveryHours.upperBound) h", "bed.double")
                target("Reps in reserve", "\(profile.repsInReserve.lowerBound)–\(profile.repsInReserve.upperBound)", "gauge.with.dots.needle.50percent")
                target("Each muscle", "\(profile.sessionsPerMuscle.lowerBound)–\(profile.sessionsPerMuscle.upperBound)× a week", "calendar")
            }
            .padding(.vertical, 4)
            ForEach(profile.notes, id: \.self) { note in
                Label(note, systemImage: "checkmark.circle")
                    .font(.callout)
            }
            DisclosureGroup("Sources") {
                ForEach(TrainingProfile.sources) { source in
                    if let url = URL(string: source.url) {
                        Link(source.title, destination: url)
                            .font(.caption)
                    }
                }
            }
            .font(.subheadline)
        } header: {
            Text("Optimal for You")
        } footer: {
            Text("Guidelines from training research, not rules. Listen to your body – and a doctor, if something hurts.")
        }
    }

    private func target(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
