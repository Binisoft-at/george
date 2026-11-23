import SwiftUI
import GeorgeCore

/// The running workout: metrics, exercises and controls as vertical pages (Digital Crown pages through them).
struct LiveWorkoutView: View {
    private enum Page: Hashable {
        case metrics, exercises, controls
    }

    @Environment(WatchConnector.self) private var connector
    @State private var page: Page = .metrics
    /// The end sheet (effort, Save) – opened by Finish after the last set and by End on the controls page.
    @State private var showingEnd = false
    @State private var pendingFinish: PendingFinish?

    var body: some View {
        if let live = connector.live {
            let unit = connector.snapshot?.unit ?? .kg
            TabView(selection: $page) {
                MetricsPage(live: live, unit: unit) {
                    showingEnd = true
                }
                .tag(Page.metrics)
                ExercisesPage(live: live, unit: unit)
                    .tag(Page.exercises)
                ControlsPage(live: live) {
                    showingEnd = true
                }
                .tag(Page.controls)
            }
            .tabViewStyle(.verticalPage)
            .navigationTitle(live.title)
            .sheet(isPresented: $showingEnd, onDismiss: commitFinish) {
                EndWorkoutSheet(kind: live.kind) { effort in
                    pendingFinish = PendingFinish(effort: effort)
                }
            }
        } else {
            ContentUnavailableView("No workout running", systemImage: "figure.cooldown")
        }
    }

    /// The finish command goes out once the sheet is gone, so the pages are not torn down under it.
    private func commitFinish() {
        guard let finish = pendingFinish else { return }
        pendingFinish = nil
        connector.perform(.finish(effort: finish.effort))
    }
}

// MARK: - Metrics

/// The glance page: the current set as the hero, the rest ring while resting, a green ring while a hold runs.
private struct MetricsPage: View {
    let live: WatchLiveState
    let unit: WeightUnit
    let onFinish: () -> Void
    @Environment(WatchConnector.self) private var connector
    @State private var logging: SetLogTarget?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                content(at: context.date)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .containerBackground(live.kind.pageBackground, for: .tabView)
        .sheet(item: $logging) { target in
            SetLogSheet(target: target, unit: unit, kind: live.kind)
                .environment(connector)
        }
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        if let remaining = live.restRemaining(at: now) {
            RestLayout(live: live, remaining: remaining)
        } else if let remaining = live.holdRemaining(at: now) {
            HoldLayout(live: live, remaining: remaining, date: now)
        } else {
            WorkingLayout(live: live, date: now, onLog: { logging = $0 }, onFinish: onFinish)
        }
    }
}

/// Waiting for or doing a set: clock, heart rate and kcal on top, the set big below.
private struct WorkingLayout: View {
    let live: WatchLiveState
    let date: Date
    let onLog: (SetLogTarget) -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TopMetricsRow(live: live, date: date)
            if let due = live.due {
                VStack(alignment: .leading, spacing: 0) {
                    Text(due.exercise.name)
                        .font(.headline)
                        .lineLimit(2)
                    Button {
                        onLog(SetLogTarget(
                            exerciseName: due.exercise.name, workoutSet: due.set, number: due.number,
                            setCount: due.of, isCurrent: due.set.id == live.currentSetID
                        ))
                    } label: {
                        Text(due.set.label.isEmpty ? "Set \(due.number)" : due.set.label)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Log the reps and weight you did"))
                    HStack(spacing: 4) {
                        Text("Set \(due.number) of \(due.of)")
                        Spacer(minLength: 4)
                        Text("\(live.completedSets)/\(live.totalSets)")
                            .monospacedDigit()
                            .accessibilityLabel(Text("\(live.completedSets) of \(live.totalSets) sets done"))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } else {
                Label("All sets done", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(live.kind.tint)
            }
            // The main action right under the set, so it never needs a scroll – the pace and any
            // question or check-in come below it.
            PrimaryButton(live: live, onFinish: onFinish)
            PaceLine(live: live, date: date)
            LivePrompts(live: live)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Clock, heart rate and active energy in one compact row.
private struct TopMetricsRow: View {
    let live: WatchLiveState
    let date: Date
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if live.isPaused {
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                        .accessibilityLabel(Text("Paused"))
                }
                Text(Format.clock(Int(live.elapsed(at: date))))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(.yellow)
            .opacity(live.isPaused ? 0.7 : 1)
            Spacer(minLength: 2)
            CompactMetric(symbol: "heart.fill", tint: .red, value: Self.whole(workout.heartRate), label: "Heart rate")
            CompactMetric(symbol: "flame.fill", tint: .orange, value: Self.whole(workout.activeEnergy), label: "Active kilocalories")
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private static func whole(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(Int(value.rounded()))
    }
}

private struct CompactMetric: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label) \(value)"))
    }
}

/// The rest ring with what's next and the main button. With a question or check-in open, the ring
/// shrinks so the card fits.
private struct RestLayout: View {
    let live: WatchLiveState
    let remaining: TimeInterval
    @Environment(WatchConnector.self) private var connector

    var body: some View {
        let total = Double(live.restTotalSeconds ?? 0)
        VStack(spacing: 6) {
            if live.hasPrompt {
                HStack(spacing: 8) {
                    CountdownRing(remaining: remaining, total: total, tint: live.kind.tint, caption: "", lineWidth: 5, fontSize: 14)
                        .frame(width: 48, height: 48)
                    UpNext(live: live, alignment: .leading)
                    Spacer(minLength: 0)
                }
                LivePrompts(live: live)
            } else {
                CountdownRing(remaining: remaining, total: total, tint: live.kind.tint, caption: "REST")
                    .frame(width: 80, height: 80)
                UpNext(live: live, alignment: .center)
            }
            HStack(spacing: 6) {
                PrimaryButton(live: live, compact: true)
                Button("+15s") { connector.perform(.addRest(15)) }
                    .buttonStyle(CapsuleButtonStyle(fill: Color.white.opacity(0.18), foreground: .white))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The next exercise and its set line, e.g. "8 × 60 kg · set 2/4".
private struct UpNext: View {
    let live: WatchLiveState
    let alignment: HorizontalAlignment

    var body: some View {
        if let due = live.due {
            VStack(alignment: alignment, spacing: 0) {
                Text(due.exercise.name)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.setLine(label: due.set.label, number: due.number, of: due.of))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Up next: \(due.exercise.name), \(due.set.label), set \(due.number) of \(due.of)"))
        }
    }

    private static func setLine(label: String, number: Int, of count: Int) -> String {
        let position = "set \(number)/\(count)"
        return label.isEmpty ? position : "\(label) · \(position)"
    }
}

/// A running hold: the rest ring's style in green with the seconds left. "30 s each side": the ring
/// counts down the side that's running (the wrist buzzes at the switch).
private struct HoldLayout: View {
    let live: WatchLiveState
    let remaining: TimeInterval
    let date: Date

    var body: some View {
        let side = live.holdSide(at: date)
        VStack(spacing: 6) {
            if let side {
                CountdownRing(remaining: side.remaining(at: date), total: side.seconds, tint: .green, caption: "SIDE \(side.number)")
                    .frame(width: 80, height: 80)
            } else {
                CountdownRing(remaining: remaining, total: Double(live.timedSetSeconds ?? 0), tint: .green, caption: "HOLD")
                    .frame(width: 80, height: 80)
            }
            if let due = live.due {
                VStack(spacing: 0) {
                    Text(due.exercise.name)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(side.map { "Side \($0.number) of \($0.count) · set \(due.number)/\(due.of)" } ?? "Set \(due.number) of \(due.of)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            PrimaryButton(live: live)
            LivePrompts(live: live)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The page's one primary action (Double Tap): Resume while paused, Start while a set waits and the
/// Start button is on, otherwise Done – or Finish once every set is done.
private struct PrimaryButton: View {
    let live: WatchLiveState
    var compact = false
    var onFinish: (() -> Void)? = nil
    @Environment(WatchConnector.self) private var connector

    var body: some View {
        if live.isPaused {
            // Paused: carries on – never logs a set or starts one.
            Button {
                connector.perform(.resume)
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(CapsuleButtonStyle(fill: .yellow, foreground: .black))
            .handGestureShortcut(.primaryAction)
        } else if live.primaryIsStart {
            Button {
                connector.perform(.startSet)
            } label: {
                Label(compact ? "Start" : "Start set", systemImage: "play.fill")
            }
            .buttonStyle(CapsuleButtonStyle(fill: .green, foreground: .black))
            .handGestureShortcut(.primaryAction)
        } else if !live.hasOpenSet, let onFinish {
            Button(action: onFinish) {
                Label("Finish", systemImage: "flag.checkered")
            }
            .buttonStyle(CapsuleButtonStyle(fill: live.kind.tint, foreground: live.kind.onTint))
            .handGestureShortcut(.primaryAction)
        } else {
            Button {
                // The set shown here, by id: a reflex tap after the phone already logged it (end of a
                // hold) changes nothing, and it never logs whatever set the phone has moved on to.
                guard let due = live.due else { return }
                connector.perform(.completeSet(id: due.set.id, reps: nil, weightKg: nil))
            } label: {
                Label(compact ? "Done" : "Done set", systemImage: "checkmark")
            }
            .buttonStyle(CapsuleButtonStyle(fill: live.kind.tint, foreground: live.kind.onTint))
            .disabled(!live.hasOpenSet)
            .opacity(live.hasOpenSet ? 1 : 0.4)
            .handGestureShortcut(.primaryAction)
        }
    }
}

/// "Rest 1:30 · +0:23" while waiting, "In progress 0:41" while working, and the running total.
private struct PaceLine: View {
    let live: WatchLiveState
    let date: Date

    var body: some View {
        HStack(spacing: 4) {
            if live.isPaused {
                Text("Paused").foregroundStyle(.yellow)
            } else if let started = live.setStartedAt {
                if let target = live.timedSetSeconds {
                    let left = max(0, Double(target) - date.timeIntervalSince(started))
                    Text("\(Format.clock(Int(left.rounded(.up)))) left").foregroundStyle(.green)
                } else {
                    Text("Set \(Format.clock(Int(date.timeIntervalSince(started))))").foregroundStyle(.green)
                }
            } else if let waiting = live.waitingDelta(at: date), let planned = live.plannedRestSeconds {
                Text("Rest \(Format.clock(planned)) · \(WorkoutPace.signed(waiting))")
                    .foregroundStyle(waiting > 60 ? .red : (waiting > 0 ? .orange : .green))
            }
            if let behind = live.behindSeconds, abs(behind) >= 10 {
                Text("· \(WorkoutPace.deltaText(behind))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
    }
}

/// Quick "done" on the exercises page (no Double Tap: that belongs to the metrics page).
private struct DoneSetButton: View {
    let live: WatchLiveState
    @Environment(WatchConnector.self) private var connector

    var body: some View {
        Button {
            // By id, as on the metrics page.
            guard let due = live.due else { return }
            connector.perform(.completeSet(id: due.set.id, reps: nil, weightKg: nil))
        } label: {
            Label("Done set", systemImage: "checkmark")
        }
        .buttonStyle(CapsuleButtonStyle(fill: live.kind.tint, foreground: live.kind.onTint))
        .disabled(!live.hasOpenSet)
        .opacity(live.hasOpenSet ? 1 : 0.4)
    }
}

// MARK: - Exercises

/// An open set of another exercise the user tapped: do it now, or log it as done.
private struct SteerTarget {
    let setID: UUID
    let exerciseName: String
    let index: String
    let label: String
}

private struct ExercisesPage: View {
    let live: WatchLiveState
    let unit: WeightUnit
    @Environment(WatchConnector.self) private var connector
    @State private var steering: SteerTarget?
    /// A done set that was tapped: edit it or mark it not done (never unticked by a stray tap).
    @State private var reviewing: SetLogTarget?
    @State private var logging: SetLogTarget?

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
                        ExerciseBlockView(block: block, currentSetID: live.currentSetID, kind: live.kind) { exercise, workoutSet in
                            tap(workoutSet, of: exercise)
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
        .confirmationDialog(
            steering?.exerciseName ?? "",
            isPresented: isSteering,
            titleVisibility: .visible,
            presenting: steering
        ) { target in
            Button("Do this now") { connector.perform(.makeCurrent(setID: target.setID)) }
            Button("Log as done") { connector.perform(.completeSet(id: target.setID, reps: nil, weightKg: nil)) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(target.label.isEmpty ? "Set \(target.index)" : "Set \(target.index) · \(target.label)")
        }
        .confirmationDialog(
            reviewing?.exerciseName ?? "",
            isPresented: isReviewing,
            titleVisibility: .visible,
            presenting: reviewing
        ) { target in
            if Self.canEdit(target.workoutSet) {
                Button("Edit reps/weight") { logging = target }
            }
            Button("Mark not done") { connector.perform(.undoSet(target.workoutSet.id)) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            let done = target.workoutSet
            Text(done.label.isEmpty ? "Set \(done.index) · done" : "Set \(done.index) · \(done.label) · done")
        }
        .sheet(item: $logging) { target in
            SetLogSheet(target: target, unit: unit, kind: live.kind)
                .environment(connector)
        }
    }

    private var isSteering: Binding<Bool> {
        Binding(
            get: { steering != nil },
            set: { isPresented in
                if !isPresented { steering = nil }
            }
        )
    }

    private var isReviewing: Binding<Bool> {
        Binding(
            get: { reviewing != nil },
            set: { isPresented in
                if !isPresented { reviewing = nil }
            }
        )
    }

    /// Reps or a weight to change (holds and distances have nothing to edit here).
    private static func canEdit(_ workoutSet: WatchSet) -> Bool {
        workoutSet.isTimed != true && (workoutSet.reps != nil || workoutSet.targetReps != nil || workoutSet.weightKg != nil)
    }

    /// Open sets of the exercise that's due are logged (by id); open sets of another exercise ask
    /// whether to do them now or log them; a done set asks before anything changes.
    private func tap(_ workoutSet: WatchSet, of exercise: WatchExercise) {
        if workoutSet.isDone {
            let number = (exercise.sets.firstIndex(where: { $0.id == workoutSet.id }) ?? 0) + 1
            reviewing = SetLogTarget(exerciseName: exercise.name, workoutSet: workoutSet, number: number,
                                     setCount: exercise.sets.count, isCurrent: false)
        } else if let due = live.due, due.exercise.id != exercise.id {
            steering = SteerTarget(setID: workoutSet.id, exerciseName: exercise.name, index: workoutSet.index, label: workoutSet.label)
        } else {
            connector.perform(.completeSet(id: workoutSet.id, reps: nil, weightKg: nil))
        }
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
    let onTap: (WatchExercise, WatchSet) -> Void

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
                ExerciseSetsView(exercise: exercise, currentSetID: currentSetID, kind: kind) { workoutSet in
                    onTap(exercise, workoutSet)
                }
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
    let onTap: (WatchSet) -> Void

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
                    onTap(workoutSet)
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
    /// Opens the end sheet (it belongs to the whole live view, so Finish can open it too).
    let onEnd: () -> Void
    @Environment(WatchConnector.self) private var connector
    @Environment(WorkoutManager.self) private var workout
    @State private var confirmingDiscard = false

    var body: some View {
        let isMuted = live.voiceMuted == true
        let canMove = live.hasOpenSet
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ControlButton(title: "End", systemImage: "xmark", tint: .red) {
                        onEnd()
                    }
                    ControlButton(
                        title: live.isPaused ? "Resume" : "Pause",
                        systemImage: live.isPaused ? "play.fill" : "pause.fill",
                        tint: .yellow
                    ) {
                        connector.perform(live.isPaused ? .resume : .pause)
                    }
                }
                HStack(spacing: 8) {
                    ControlButton(title: "Back", systemImage: "backward.end.fill", tint: .cyan) {
                        connector.perform(.moveThread(-1))
                    }
                    .disabled(!canMove)
                    .opacity(canMove ? 1 : 0.4)
                    ControlButton(title: "Skip exercise", systemImage: "forward.end.fill", tint: .cyan) {
                        connector.perform(.moveThread(1))
                    }
                    .disabled(!canMove)
                    .opacity(canMove ? 1 : 0.4)
                }
                HStack(spacing: 8) {
                    ControlButton(
                        title: isMuted ? "Unmute voice" : "Mute voice",
                        systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        tint: isMuted ? .orange : .mint
                    ) {
                        connector.perform(.toggleVoiceMute)
                    }
                    .accessibilityValue(Text(isMuted ? "Voice muted" : "Voice on"))
                    ControlButton(title: "Discard", systemImage: "trash", tint: .red) {
                        confirmingDiscard = true
                    }
                }
                recordingStatus
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

                Button("Save") { end(with: effort) }
                    .buttonStyle(CapsuleButtonStyle(fill: kind.tint, foreground: kind.onTint))
                    .handGestureShortcut(.primaryAction)
                Button("Save without rating") { end(with: nil) }
                    .buttonStyle(CapsuleButtonStyle(fill: Color.white.opacity(0.18), foreground: .white))
            }
            .navigationTitle("End workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func end(with value: Int?) {
        onEnd(value)
        dismiss()
    }
}
