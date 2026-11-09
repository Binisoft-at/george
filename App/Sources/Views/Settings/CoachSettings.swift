import SwiftUI
import BinisoftKit
import GeorgeCore

/// Settings → Workout Coach: every voice, sound, haptic and motivation extra can be switched off.
struct CoachSettingsSection: View {
    @AppStorage(Prefs.voiceCoach) private var voice = true
    @AppStorage(Prefs.voiceCountdown) private var countdown = true
    @AppStorage(Prefs.restSounds) private var sounds = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.motivation) private var motivationRaw = MotivationStyle.full.rawValue
    @AppStorage(Prefs.paceNudges) private var nudges = true
    @AppStorage(Prefs.askEffort) private var askEffort = true
    @AppStorage(Prefs.energyCheckIn) private var energyCheckIn = true
    @AppStorage(Prefs.autoRest) private var autoRest = true
    @AppStorage(Prefs.keepAwake) private var keepAwake = true

    var body: some View {
        Section {
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

            Toggle(isOn: $voice) { Label("Voice coach", systemImage: "waveform") }
            if voice {
                Toggle(isOn: $countdown) { Label("“10 seconds” warning", systemImage: "timer") }
                Button {
                    VoiceCoach.shared.say("Rest 90 seconds. Next: Bench Press, 8 reps at 62.5 kilos.", interrupt: true)
                } label: {
                    Label("Play a Sample", systemImage: "play.circle")
                }
            }
            Toggle(isOn: $sounds) { Label("Sound when rest ends", systemImage: "bell") }
            Toggle(isOn: $haptics) { Label("Haptics", systemImage: "iphone.radiowaves.left.and.right") }
            Toggle(isOn: $nudges) { Label("Nudge me when I dawdle", systemImage: "hourglass") }
            Toggle(isOn: $askEffort) { Label("Ask how hard sets felt", systemImage: "gauge.with.dots.needle.67percent") }
            Toggle(isOn: $energyCheckIn) { Label("Energy check-in", systemImage: "battery.75percent") }
            Toggle(isOn: $autoRest) { Label("Start rest timer automatically", systemImage: "timer.circle") }
            Toggle(isOn: $keepAwake) { Label("Keep screen awake", systemImage: "sun.max") }
        } header: {
            Text("Workout Coach")
        } footer: {
            Text("The voice ducks your music while it speaks. Low-energy days: pick “Calm” in the workout's ⋯ menu (or answer the check-in) – no nudges, more slack between sets. The effort question comes at most four times per workout and makes the weight suggestions better.")
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
