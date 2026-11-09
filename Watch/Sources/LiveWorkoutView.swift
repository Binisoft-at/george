import SwiftUI
import GeorgeCore

/// The running workout: metrics, exercises and controls as vertical pages (Digital Crown pages through them).
struct LiveWorkoutView: View {
    private enum Page: Hashable {
        case metrics, exercises, controls
    }

    @Environment(WatchConnector.self) private var connector
    @State private var page: Page = .metrics

    var body: some View {
        if let live = connector.live {
            TabView(selection: $page) {
                MetricsPage(live: live)
                    .tag(Page.metrics)
                ExercisesPage(live: live)
                    .tag(Page.exercises)
                ControlsPage(live: live)
                    .tag(Page.controls)
            }
            .tabViewStyle(.verticalPage)
            .navigationTitle(live.title)
        } else {
            ContentUnavailableView("No workout running", systemImage: "figure.cooldown")
        }
    }
}

// MARK: - Metrics

private struct MetricsPage: View {
    let live: WatchLiveState
    @Environment(WatchConnector.self) private var connector
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let remaining = live.restRemaining(at: context.date) {
                rest(remaining: remaining)
            } else {
                metrics(at: context.date)
            }
        }
        .containerBackground(live.kind.pageBackground, for: .tabView)
    }

    private func metrics(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.clock(Int(live.elapsed(at: now))))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.yellow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if live.isPaused {
                    Text("PAUSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.yellow)
                }
            }
            .opacity(live.isPaused ? 0.7 : 1)

            HStack(spacing: 10) {
                MetricValue(symbol: "heart.fill", tint: .red, value: Self.whole(workout.heartRate), unit: "BPM")
                MetricValue(symbol: "flame.fill", tint: .orange, value: Self.whole(workout.activeEnergy), unit: "KCAL")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Sets")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("\(live.completedSets)/\(live.totalSets)")
                        .monospacedDigit()
                }
                .font(.footnote)
                ProgressView(
                    value: Double(min(live.completedSets, max(live.totalSets, 0))),
                    total: Double(max(live.totalSets, 1))
                )
                .tint(live.kind.tint)
            }

            Spacer(minLength: 2)

            if let exercise = live.currentExercise, let currentSet = live.currentSet {
                Text("\(exercise.name) · \(currentSet.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            DoneSetButton(live: live)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rest(remaining: TimeInterval) -> some View {
        let total = max(Double(live.restTotalSeconds ?? 0), remaining, 1)
        let fraction = min(1, max(0, remaining / total))
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(live.kind.tint.opacity(0.25), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(live.kind.tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(Format.clock(Int(remaining.rounded(.up))))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("REST")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)

            HStack(spacing: 6) {
                Button("Skip") { connector.perform(.skipRest) }
                    .buttonStyle(CapsuleButtonStyle(fill: Color.white.opacity(0.18), foreground: .white))
                Button("+15s") { connector.perform(.addRest(15)) }
                    .buttonStyle(CapsuleButtonStyle(fill: live.kind.tint, foreground: live.kind.onTint))
            }

            if let next = live.currentExercise {
                Text("Next: \(next.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func whole(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(Int(value.rounded()))
    }
}

private struct MetricValue: View {
    let symbol: String
    let tint: Color
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DoneSetButton: View {
    let live: WatchLiveState
    @Environment(WatchConnector.self) private var connector

    var body: some View {
        let hasOpenSet = live.firstOpenSet() != nil
        Button {
            connector.perform(.completeCurrentSet)
        } label: {
            Label("Done set", systemImage: "checkmark")
        }
        .buttonStyle(CapsuleButtonStyle(fill: live.kind.tint, foreground: live.kind.onTint))
        .disabled(!hasOpenSet)
        .opacity(hasOpenSet ? 1 : 0.4)
    }
}

// MARK: - Exercises

private struct ExercisesPage: View {
    let live: WatchLiveState
    @Environment(WatchConnector.self) private var connector

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    DoneSetButton(live: live)
                    ForEach(ExerciseBlock.blocks(from: live.exercises)) { block in
                        if let section = block.sectionTitle {
                            Text(section.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        ExerciseBlockView(block: block, currentSetID: live.currentSetID, kind: live.kind) { setID in
                            connector.perform(.toggleSet(setID))
                        }
                    }
                }
            }
            .onAppear { scrollToCurrentSet(proxy, animated: false) }
            .onChange(of: live.currentSetID) { _, _ in
                scrollToCurrentSet(proxy, animated: true)
            }
        }
        .containerBackground(live.kind.pageBackground, for: .tabView)
    }

    private func scrollToCurrentSet(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = live.currentSetID else { return }
        if animated {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// Consecutive exercises sharing a group label (superset, circuit, ...) shown as one card.
private struct ExerciseBlock: Identifiable {
    let id: UUID
    let groupLabel: String?
    /// Section heading to show above this block when the section changes ("Warm-up", ...).
    let sectionTitle: String?
    var exercises: [WatchExercise]

    static func blocks(from exercises: [WatchExercise]) -> [ExerciseBlock] {
        var blocks: [ExerciseBlock] = []
        var currentSection: String? = nil
        for exercise in exercises {
            if let label = exercise.groupLabel, let last = blocks.last, last.groupLabel == label {
                blocks[blocks.count - 1].exercises.append(exercise)
                continue
            }
            var sectionTitle: String? = nil
            if let section = exercise.section?.trimmingCharacters(in: .whitespacesAndNewlines),
               !section.isEmpty, section != currentSection {
                sectionTitle = section
                currentSection = section
            }
            blocks.append(ExerciseBlock(id: exercise.id, groupLabel: exercise.groupLabel, sectionTitle: sectionTitle, exercises: [exercise]))
        }
        return blocks
    }
}

private struct ExerciseBlockView: View {
    let block: ExerciseBlock
    let currentSetID: UUID?
    let kind: WorkoutKind
    let onToggle: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = block.groupLabel {
                Label(label, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(kind.tint)
            }
            ForEach(Array(block.exercises.enumerated()), id: \.element.id) { index, exercise in
                if index > 0 {
                    Divider()
                }
                ExerciseSetsView(exercise: exercise, currentSetID: currentSetID, kind: kind, onToggle: onToggle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.1))
        )
    }
}

private struct ExerciseSetsView: View {
    let exercise: WatchExercise
    let currentSetID: UUID?
    let kind: WorkoutKind
    let onToggle: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(exercise.name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if exercise.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(kind.tint)
                }
            }
            if !exercise.detail.isEmpty {
                Text(exercise.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(exercise.sets) { workoutSet in
                SetPill(workoutSet: workoutSet, isCurrent: workoutSet.id == currentSetID, kind: kind) {
                    onToggle(workoutSet.id)
                }
                .id(workoutSet.id)
            }
        }
    }
}

private struct SetPill: View {
    let workoutSet: WatchSet
    let isCurrent: Bool
    let kind: WorkoutKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: workoutSet.isDone ? "checkmark.circle.fill" : "circle")
                Text(workoutSet.index)
                    .font(.footnote.weight(.bold))
                    .monospacedDigit()
                Text(workoutSet.label)
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(workoutSet.isDone ? kind.onTint : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(isCurrent ? kind.tint : Color.clear, lineWidth: 2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Set \(workoutSet.index), \(workoutSet.label)"))
        .accessibilityValue(Text(workoutSet.isDone ? "Done" : "Not done"))
    }

    private var fill: Color {
        if workoutSet.isDone { return kind.tint }
        return isCurrent ? kind.tint.opacity(0.3) : Color.white.opacity(0.14)
    }
}

// MARK: - Controls

private struct ControlsPage: View {
    let live: WatchLiveState
    @Environment(WatchConnector.self) private var connector
    @Environment(WorkoutManager.self) private var workout
    @State private var showingEnd = false
    @State private var confirmingDiscard = false
    @State private var pendingFinish: PendingFinish?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ControlButton(title: "End", systemImage: "xmark", tint: .red) {
                    showingEnd = true
                }
                ControlButton(
                    title: live.isPaused ? "Resume" : "Pause",
                    systemImage: live.isPaused ? "play.fill" : "pause.fill",
                    tint: .yellow
                ) {
                    connector.perform(live.isPaused ? .resume : .pause)
                }
            }
            Button(role: .destructive) {
                confirmingDiscard = true
            } label: {
                Label("Discard", systemImage: "trash")
            }
            recordingStatus
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingEnd, onDismiss: commitFinish) {
            EndWorkoutSheet(kind: live.kind) { effort in
                pendingFinish = PendingFinish(effort: effort)
            }
        }
        .confirmationDialog("Discard workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                connector.perform(.discard)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing from this workout will be saved.")
        }
        .containerBackground(live.kind.pageBackground, for: .tabView)
    }

    @ViewBuilder
    private var recordingStatus: some View {
        switch workout.phase {
        case .running, .paused:
            Label("Recording to Health", systemImage: "heart.fill")
        case .starting:
            Label("Starting Health recording", systemImage: "heart")
        case .ending:
            Label("Saving to Health", systemImage: "heart")
        case .idle:
            Label("Not recording to Health", systemImage: "heart.slash")
        }
    }

    /// The finish command goes out once the sheet is gone, so the pages are not torn down under it.
    private func commitFinish() {
        guard let finish = pendingFinish else { return }
        pendingFinish = nil
        connector.perform(.finish(effort: finish.effort))
    }
}

private struct PendingFinish {
    let effort: Int?
}

private struct ControlButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(tint.opacity(0.22))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            Text(title)
                .font(.caption2)
        }
    }
}

/// Confirms ending the workout and asks for effort (1–10) with a Digital Crown wheel.
private struct EndWorkoutSheet: View {
    let kind: WorkoutKind
    let onEnd: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var effort = 6

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                Picker("Effort", selection: $effort) {
                    ForEach(EffortScale.range, id: \.self) { value in
                        Text("\(value)")
                            .font(.title2.weight(.semibold))
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()

                Text("Effort · \(EffortScale.label(for: effort))")
                    .font(.footnote)
                    .foregroundStyle(kind.tint)

                HStack(spacing: 6) {
                    Button("Skip") { end(with: nil) }
                        .buttonStyle(CapsuleButtonStyle(fill: Color.white.opacity(0.18), foreground: .white))
                    Button("Save") { end(with: effort) }
                        .buttonStyle(CapsuleButtonStyle(fill: kind.tint, foreground: kind.onTint))
                }
            }
            .navigationTitle("End workout")
        }
    }

    private func end(with value: Int?) {
        onEnd(value)
        dismiss()
    }
}
