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
    /// Nothing happened for half an hour (left running after the gym): "End at last set" is offered,
    /// on by default, with this time (last set + rest).
    @State private var earlierEnd: Date?
    @State private var endAtLastSet = true
    @State private var endTime = Date()

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
                        stat("Time", Format.minutes(shownDuration))
                        stat("Sets", "\(live.content.completedSets)/\(live.content.totalSets)")
                        // Working volume – the number the finish screen and Progress show.
                        if live.content.workingVolumeKg > 0 {
                            stat("Volume", Format.volume(live.content.workingVolumeKg, unit: live.unit))
                        }
                    }
                    if live.content.totalSets > 0 && live.content.completedSets < live.content.totalSets {
                        Label("\(live.content.totalSets - live.content.completedSets) sets left — it will be saved as “stopped early” and still counts.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let earlierEnd {
                    endSection(suggested: earlierEnd)
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
                        Label(healthLine, systemImage: "heart.text.square.fill")
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
            .onAppear {
                prefillEffort()
                prefillEnd()
            }
        }
    }

    private func finish() {
        guard !isSaving else { return }
        isSaving = true
        Haptics.heavy()
        // With the offer shown, the time is chosen here (now when switched off); without it George
        // decides (a strength workout left running for hours still ends at its last set).
        let offered = earlierEnd != nil
        let end = offered ? (endAtLastSet ? endTime : Date()) : nil
        Task {
            await live.finish(effort: effort, notes: notes, endedAt: end, endIsChosen: offered)
            isSaving = false
        }
    }

    // MARK: End time

    /// "End at last set": on by default when nothing happened for half an hour; the time can be changed.
    private func endSection(suggested: Date) -> some View {
        Section {
            Toggle(isOn: $endAtLastSet) {
                Text("End at last set")
                Text("\(suggested.formatted(date: .omitted, time: .shortened)) · last set + rest")
            }
            if endAtLastSet {
                DatePicker("Ended", selection: $endTime, in: endRange, displayedComponents: endComponents)
            }
        } footer: {
            Text(endAtLastSet ? "No sets for a while – the time after that doesn't count." : "Saved with the time until now.")
        }
    }

    private func prefillEnd() {
        guard earlierEnd == nil, let suggested = live.earlierFinishEnd() else { return }
        earlierEnd = suggested
        endTime = suggested
    }

    /// From the start to now.
    private var endRange: ClosedRange<Date> {
        let now = Date()
        return min(live.session?.startedAt ?? endTime, now)...now
    }

    /// The date too when the workout started on another day.
    private var endComponents: DatePickerComponents {
        let start = live.session?.startedAt ?? endTime
        return Calendar.current.isDate(start, inSameDayAs: Date()) ? [.hourAndMinute] : [.date, .hourAndMinute]
    }

    /// The time saved: up to the chosen end, or until now.
    private var shownDuration: Double {
        guard earlierEnd != nil, endAtLastSet else { return live.elapsed() }
        return live.activeSeconds(until: endTime)
    }

    private var healthLine: String {
        if live.isWaitingForWatch { return "Waiting for Apple Watch…" }
        if live.watchStoppedAt != nil { return "Apple Watch stopped recording — the rest is saved from iPhone" }
        return live.watchIsRecording ? "Apple Watch recorded heart rate — saving from the watch" : "Will be saved to Apple Health"
    }

    /// Logged RPEs (from the "how many more reps" question) suggest the workout's effort.
    private var loggedRPEs: [Double] {
        live.content.allItems.flatMap(\.sets).filter(\.isDone).compactMap(\.rpe)
    }

    private var prefilledFromSets: Bool { prefilled && !loggedRPEs.isEmpty }

    private func prefillEffort() {
        guard !prefilled else { return }
        prefilled = true
        // A calm yoga flow isn't "somewhat hard": the default follows the kind of workout.
        effort = live.session?.kind.defaultEffort ?? 6
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
