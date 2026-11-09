import SwiftUI
import BinisoftKit
import GeorgeCore

/// Rate effort, add a note, finish (→ Apple Health).
struct FinishWorkoutSheet: View {
    @Environment(LiveWorkoutController.self) private var live
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var effort = 6
    @State private var notes = ""
    @State private var isSaving = false
    @State private var prefilled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            ProgressRing(progress: Double(live.content.completedSets) / Double(max(1, live.content.totalSets)), tint: .green, lineWidth: 7)
                            Image(systemName: live.content.isComplete ? "flag.checkered" : "flag")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.green)
                        }
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(live.content.isComplete ? "Every set done – brilliant." : "Great effort – wrap it up?")
                                .font(.headline)
                            if live.pace.onTimeStreak >= 3 {
                                Label("\(live.pace.onTimeStreak) sets in a row on time", systemImage: "flame.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    HStack {
                        stat("Time", Format.minutes(live.elapsed()))
                        stat("Sets", "\(live.content.completedSets)/\(live.content.totalSets)")
                        if live.content.volumeKg > 0 {
                            stat("Volume", Format.volume(live.content.volumeKg, unit: live.unit))
                        }
                    }
                    if live.content.completedSets < live.content.totalSets {
                        Label("\(live.content.totalSets - live.content.completedSets) sets left — it will be saved as “stopped early” and still counts.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Effort")
                            Spacer()
                            Text("\(effort) · \(effortLabel)")
                                .foregroundStyle(effortColor)
                                .fontWeight(.semibold)
                        }
                        Slider(value: Binding(get: { Double(effort) }, set: { effort = Int($0.rounded()) }), in: 1...10, step: 1)
                            .tint(effortColor)
                    }
                } footer: {
                    Text(prefilledFromSets
                         ? "Suggested from how hard your sets felt. Saved to Apple Health as the workout effort score — Fitness and Bevel use it for training load."
                         : "Saved to Apple Health as the workout effort score — Fitness and Bevel use it for training load.")
                }
                Section("Notes") {
                    TextField("e.g. stopped early but lots done", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section {
                    if health.isAvailable && store.settings.saveToHealth {
                        Label(live.watchIsRecording ? "Apple Watch recorded heart rate — saving from the watch" : "Will be saved to Apple Health", systemImage: "heart.text.square.fill")
                            .foregroundStyle(.pink)
                            .font(.subheadline)
                    }
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) {
                Button(action: finish) {
                    HStack {
                        if isSaving { ProgressView().tint(.white) }
                        Label("Finish & Celebrate", systemImage: "flag.checkered")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .disabled(isSaving)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Finish Workout")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep Going") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish", action: finish)
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                }
            }
            .onAppear(perform: prefillEffort)
        }
    }

    private func finish() {
        guard !isSaving else { return }
        isSaving = true
        Haptics.heavy()
        Task {
            await live.finish(effort: effort, notes: notes)
            isSaving = false
        }
    }

    /// Logged RPEs (from the "how many more reps" question) suggest the workout's effort.
    private var loggedRPEs: [Double] {
        live.content.allItems.flatMap(\.sets).filter(\.isDone).compactMap(\.rpe)
    }

    private var prefilledFromSets: Bool { prefilled && !loggedRPEs.isEmpty }

    private func prefillEffort() {
        guard !prefilled else { return }
        prefilled = true
        let rpes = loggedRPEs
        guard !rpes.isEmpty else { return }
        effort = min(10, max(1, Int((rpes.reduce(0, +) / Double(rpes.count)).rounded())))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Shown after finishing: a celebration – confetti, counting numbers, records, muscles, streak –
/// the share card, and the "update template?" question.
struct WorkoutSummarySheet: View {
    let summary: LiveWorkoutController.FinishSummary
    @Environment(GeorgeStore.self) private var store
    @Environment(MuscleAnalytics.self) private var muscles
    @Environment(HealthKitManager.self) private var health
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.motivation) private var motivationRaw = MotivationStyle.full.rawValue
    @State private var templateUpdated = false
    @State private var confetti = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let recap {
                        RecapHero(recap: recap)
                            .padding(.top, 8)
                        RecapStatsGrid(recap: recap)
                        if !recap.records.isEmpty {
                            RecapRecordsCard(recap: recap)
                        }
                        if !recap.muscleSets.isEmpty {
                            WorkoutMuscleMap(sets: recap.muscleSets, title: "Muscles worked")
                                .padding()
                                .card(padding: 0, cornerRadius: 20)
                        }
                        if !recap.highlights.isEmpty {
                            RecapHighlightsCard(recap: recap)
                        }
                        ShareRecapButton(recap: recap)
                    }

                    if summary.canUpdateTemplate && !templateUpdated {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("You changed this workout", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                            Text("Save the exercises, sets and loads you used back into “\(summary.templateName)” so next time starts from here?")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button {
                                if let session = store.session(id: summary.sessionID) {
                                    store.updateTemplate(from: session)
                                    templateUpdated = true
                                    Haptics.success()
                                }
                            } label: {
                                Label("Update Template", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                        .padding()
                        .card(padding: 0, cornerRadius: 20)
                    } else if templateUpdated {
                        Label("Template updated", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    if summary.savedToHealth {
                        Label("Saved to Apple Health", systemImage: "heart.text.square.fill")
                            .font(.subheadline)
                            .foregroundStyle(.pink)
                    }
                }
                .padding()
            }
            .overlay {
                if motivationRaw == MotivationStyle.full.rawValue {
                    ConfettiView(trigger: confetti)
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("Summary")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("View Workout") {
                        router.open(.session(summary.sessionID))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                guard motivationRaw != MotivationStyle.off.rawValue else { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                confetti += 1
                Haptics.success()
            }
        }
    }

    private var recap: WorkoutRecap? {
        guard let session = store.session(id: summary.sessionID) else { return nil }
        return WorkoutRecap.make(session: session, store: store, muscles: muscles, health: health,
                                 records: summary.records, energyKcal: summary.energyKcal, averageHeartRate: summary.averageHeartRate)
    }
}
