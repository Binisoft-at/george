import SwiftUI
import BinisoftKit
import GeorgeCore

/// Activities George doesn't run set by set.
enum ActivityPreset: String, CaseIterable, Identifiable {
    case tennis, run, walk, cycling, swim, fitnessClass, yoga, hiit, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tennis: return "Tennis"
        case .run: return "Run"
        case .walk: return "Walk"
        case .cycling: return "Cycling"
        case .swim: return "Swim"
        case .fitnessClass: return "Class"
        case .yoga: return "Yoga"
        case .hiit: return "HIIT"
        case .other: return "Other"
        }
    }

    var kind: WorkoutKind {
        switch self {
        case .tennis: return WorkoutKind("tennis")
        case .run: return .cardio
        case .walk: return WorkoutKind("walking")
        case .cycling: return WorkoutKind("cycling")
        case .swim: return WorkoutKind("swimming")
        case .fitnessClass: return WorkoutKind("class")
        case .yoga: return .yoga
        case .hiit: return .hiit
        case .other: return .other
        }
    }

    var symbol: String {
        switch self {
        case .run: return "figure.run"
        case .fitnessClass: return "figure.mind.and.body"
        case .other: return "figure.mixed.cardio"
        default: return kind.symbol
        }
    }

    var defaultMinutes: Int {
        switch self {
        case .tennis: return 90
        case .run, .cycling: return 45
        case .walk, .yoga, .fitnessClass, .other: return 60
        case .swim: return 40
        case .hiit: return 30
        }
    }
}

/// Log tennis, a run or a class: no template, no sets – the kind, when, how long and how hard.
/// Optionally saved to Apple Health like a finished George workout.
struct LogActivitySheet: View {
    /// Called instead of dismissing when shown inside another flow (e.g. the create sheet).
    var onDone: (() -> Void)? = nil

    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var preset: ActivityPreset = .tennis
    @State private var name = ""
    @State private var start = Date().addingTimeInterval(-90 * 60)
    @State private var minutes = 90
    @State private var effort = ActivityPreset.tennis.kind.defaultEffort
    @State private var effortTouched = false
    @State private var saveToHealth = true
    @State private var notes = ""
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Activity") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(ActivityPreset.allCases) { option in
                        Button {
                            choose(option)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: option.symbol).font(.title3)
                                Text(option.title).font(.caption.weight(.semibold)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(preset == option ? Color.white : option.kind.color)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(preset == option ? option.kind.color : option.kind.color.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(preset == option ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
                TextField("Name (optional) – \(preset.title) if empty", text: $name)
            }

            Section {
                DatePicker("Started", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                Stepper("Duration: \(Format.minutes(Double(minutes * 60)))", value: $minutes, in: 5...360, step: 5)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Effort")
                        Spacer()
                        Text("\(effort) · \(effortLabel)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(get: { Double(effort) }, set: { effort = Int($0.rounded()); effortTouched = true }), in: 1...10, step: 1)
                        .tint(effortColor)
                }
            } footer: {
                Text("1 is easy, 10 is all out. It goes into the calorie estimate and, with Apple Health, into your training load in Fitness.")
            }

            if health.isAvailable {
                Section {
                    Toggle(isOn: $saveToHealth) {
                        Label("Save to Apple Health", systemImage: "heart.text.square.fill")
                    }
                } footer: {
                    Text("Leave it off when your watch already recorded this activity – otherwise it counts twice in Fitness.")
                }
            }

            Section("Notes") {
                TextField("How did it go?", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Log Activity")
        .inlineTitle()
        .toolbar {
            if onDone == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Log") { log() }
                    .fontWeight(.semibold)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            saveToHealth = store.settings.saveToHealth && health.isAvailable
        }
    }

    private func choose(_ option: ActivityPreset) {
        Haptics.tap()
        preset = option
        if !effortTouched { effort = option.kind.defaultEffort }
        minutes = option.defaultMinutes
        start = min(start, Date().addingTimeInterval(-Double(minutes * 60)))
    }

    private func log() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? preset.title : trimmed
        let session = store.logActivity(
            kind: preset.kind, name: title, start: start, minutes: minutes, effort: effort,
            notes: notes, bodyMassKg: health.latestBodyMassKg
        )
        if saveToHealth && health.isAvailable {
            let seconds = Double(minutes * 60)
            let request = HealthKitManager.SaveRequest(
                sessionID: session.id, title: session.title, kind: session.kind, start: start, end: start.addingTimeInterval(seconds),
                activeSeconds: seconds, energyKcal: session.energyKcal, effort: effort,
                exercises: [], muscles: [], completedSets: 0, volumeKg: 0
            )
            Task {
                if let workoutID = await health.saveWorkout(request) {
                    session.healthWorkoutID = workoutID.uuidString
                    store.save()
                }
            }
        }
        Haptics.success()
        toasts.show("Logged \(title) · \(Format.minutes(Double(minutes * 60)))", symbol: preset.symbol)
        if let onDone { onDone() } else { dismiss() }
    }

    private var effortLabel: String {
        switch effort {
        case 1...2: return "Easy"
        case 3...4: return "Moderate"
        case 5...6: return "Somewhat hard"
        case 7...8: return "Hard"
        case 9: return "Very hard"
        default: return "All out"
        }
    }

    private var effortColor: Color {
        switch effort {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}
