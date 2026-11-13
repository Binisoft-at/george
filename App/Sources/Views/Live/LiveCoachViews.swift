import SwiftUI
import Charts
import BinisoftKit
import GeorgeCore

// MARK: - Coach bar (bottom of live mode)

/// The bar at the bottom of live mode, one per phase:
/// - resting: the rest ring, what's up next, Start now
/// - ready: NOW + the set, how long you've been waiting against the planned rest, big Start
/// - working: the set's timer (a countdown for timed sets), Done
/// Tap it (or swipe up) for the full panel with pace, controls and what's next.
struct CoachBar: View {
    let onExpand: () -> Void
    let onFinish: () -> Void
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(at: context.date)
        }
        .background {
            // ␣ starts or completes the current set on a keyboard (Mac, iPad).
            Button("") { live.primaryAction() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -30 { onExpand() }
            }
        )
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        if live.currentSet == nil {
            Button(action: onFinish) {
                Label("Finish Workout", systemImage: "flag.checkered")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
        } else {
            HStack(spacing: 12) {
                Button(action: onExpand) {
                    HStack(spacing: 12) {
                        PhaseRing(date: date)
                            .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline(at: date))
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(tint(at: date))
                                .lineLimit(1)
                            Text(live.currentItem?.name ?? "")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(setLine)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if let detail = detail(at: date) {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows pace, controls and what's next")

                primaryButton
            }
            .padding(12)
            .floatingGlass(cornerRadius: 28, tint: live.phase == .resting ? .orange : nil)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch live.phase {
        case .resting:
            Button {
                live.startSet()
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: "play.fill").font(.headline)
                    Text("Start").font(.caption2.weight(.bold))
                }
                .frame(width: 64, height: 58)
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)
            .accessibilityLabel("Skip rest and start the set")
        case .ready:
            Button {
                live.primaryAction()
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: CoachPrefs.startButton ? "play.fill" : "checkmark").font(.headline)
                    Text(CoachPrefs.startButton ? "Start" : "Done").font(.caption2.weight(.bold))
                }
                .frame(width: 64, height: 58)
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .accessibilityLabel(CoachPrefs.startButton ? "Start the set" : "Mark set done")
        case .working:
            Button {
                live.completeCurrentSet()
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: "checkmark").font(.headline.weight(.heavy))
                    Text("Done").font(.caption2.weight(.bold))
                }
                .frame(width: 64, height: 58)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Mark set done")
        }
    }

    /// "set 2 of 4 · 8 × 60 kg"
    private var setLine: String {
        guard let item = live.currentItem, let set = live.currentSet else { return "" }
        let position = CoachScript.setPosition(set, in: item)
        let what = set.label(mode: item.mode, unit: live.unit)
        return [position.isEmpty ? nil : position, what].compactMap { $0 }.joined(separator: " · ")
    }

    private func headline(at date: Date) -> String {
        switch live.phase {
        case .resting: return live.restRemaining(at: date) <= 10 ? "GET READY · UP NEXT" : "REST · UP NEXT"
        case .ready:
            let total = live.paceSnapshot(at: date).totalDelta
            return abs(total) >= 10 ? "NOW · \(WorkoutPace.deltaText(total).uppercased())" : "NOW"
        case .working:
            if let end = live.timedSetEndsAt { return "\(Format.clock(Int(max(0, end.timeIntervalSince(date)).rounded(.up)))) LEFT" }
            return "IN PROGRESS"
        }
    }

    private func detail(at date: Date) -> String? {
        let snapshot = live.paceSnapshot(at: date)
        switch live.phase {
        case .resting:
            return "Rest \(Format.clock(live.restRemaining(at: date))) of \(Format.clock(live.restTotal)) · tap for pace"
        case .ready:
            if let waiting = snapshot.waitingDelta {
                let planned = Format.clock(Int(snapshot.plannedRest))
                return waiting > 0
                    ? "\(WorkoutPace.signed(waiting)) over the \(planned) rest"
                    : "\(Format.clock(Int(-waiting))) left of the \(planned) rest"
            }
            return "Tap Start when you begin"
        case .working:
            if abs(snapshot.totalDelta) >= 10 { return WorkoutPace.deltaText(snapshot.totalDelta) }
            return "Working \(Format.clock(Int(live.pace.workingSeconds(at: date))))"
        }
    }

    private func tint(at date: Date) -> Color {
        switch live.phase {
        case .resting: return .orange
        case .working: return .accentColor
        case .ready:
            let waiting = live.paceSnapshot(at: date).waitingDelta ?? 0
            if waiting > 60 { return .red }
            if waiting > 0 { return .orange }
            return .green
        }
    }
}

/// The ring in the coach bar and the panel: the rest countdown, a timed set's countdown, the time a
/// set has been going, or the time you've been waiting against the planned rest.
struct PhaseRing: View {
    let date: Date
    var lineWidth: CGFloat = 6
    var large = false
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        let state = ringState
        ZStack {
            ProgressRing(progress: state.progress, tint: state.tint, lineWidth: lineWidth)
            VStack(spacing: 0) {
                Text(state.text)
                    .font(large ? .system(size: 54, weight: .bold, design: .rounded) : .subheadline.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: state.countsDown))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if large {
                    Text(state.caption)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(lineWidth + 4)
        }
        .animation(.easeInOut(duration: 0.3), value: state.progress)
    }

    private struct RingState {
        var progress: Double
        var text: String
        var caption: String
        var tint: Color
        var countsDown: Bool
    }

    private var ringState: RingState {
        switch live.phase {
        case .resting:
            let remaining = live.restRemaining(at: date)
            return RingState(progress: Double(remaining) / Double(max(1, live.restTotal)), text: Format.clock(remaining),
                             caption: "rest", tint: remaining <= 10 ? .red : .orange, countsDown: true)
        case .working:
            if let end = live.timedSetEndsAt, let total = live.timedTarget {
                let left = max(0, end.timeIntervalSince(date))
                return RingState(progress: left / Double(max(1, total)), text: Format.clock(Int(left.rounded(.up))),
                                 caption: "left", tint: left <= 10 ? .red : .accentColor, countsDown: true)
            }
            let working = live.pace.workingSeconds(at: date)
            let expected = live.currentItem.flatMap { item in live.currentSet.map { PaceTracker.workSeconds(for: $0, mode: item.mode) } } ?? 45
            return RingState(progress: min(1, working / max(1, expected)), text: Format.clock(Int(working)),
                             caption: "working", tint: working > expected * 1.5 ? .orange : .accentColor, countsDown: false)
        case .ready:
            if let waiting = live.pace.waitingDelta(at: date, plannedRest: live.plannedRestBeforeCurrent) {
                let idle = live.pace.idleSeconds(at: date)
                let planned = max(1, live.plannedRestBeforeCurrent)
                let tint: Color = waiting > 60 ? .red : (waiting > 0 ? .orange : .green)
                return RingState(progress: min(1, idle / planned), text: Format.clock(Int(idle)),
                                 caption: waiting > 0 ? "over by \(Format.clock(Int(waiting)))" : "since last set", tint: tint, countsDown: false)
            }
            if let target = live.timedTarget {
                return RingState(progress: 1, text: Format.clock(target), caption: "ready", tint: .green, countsDown: false)
            }
            return RingState(progress: 1, text: "GO", caption: "ready", tint: .green, countsDown: false)
        }
    }
}

/// A timed set (warm-up bike, plank, hold) in the exercise card: the countdown as a big ring with
/// Start, or – while it runs – the time left.
struct TimedSetDial: View {
    let item: WorkoutItem
    let set: WorkoutSet
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 16) {
                PhaseRing(date: context.date, lineWidth: 8)
                    .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    if live.phase == .working, let end = live.timedSetEndsAt {
                        Text("\(Format.clock(Int(max(0, end.timeIntervalSince(context.date)).rounded(.up)))) left")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text("Ticks itself off at zero")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(Format.clock(set.targetSeconds ?? set.seconds ?? 0)) \(item.perSide ? "each side" : "")")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Button {
                            live.startSet()
                        } label: {
                            Label("Start timer", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.green)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Quick feedback after an exercise

/// After an exercise's last set: how fatigued the muscles are (one tap), plus – for rep sets – how
/// many more reps were possible. Both feed the muscle model and the next weight suggestion.
struct FeedbackCard: View {
    let request: LiveWorkoutController.EffortRequest
    @Environment(LiveWorkoutController.self) private var live
    @State private var fatigue: Double?
    @State private var repsLeft: Int?

    private struct Choice: Identifiable {
        let id: Int
        let title: String
        let caption: String?
    }

    /// Fatigue in quarters (id 1…4 → 25…100 %).
    private let fatigueChoices = [Choice(id: 1, title: "25 %", caption: "Fresh"), Choice(id: 2, title: "50 %", caption: "Worked"),
                                  Choice(id: 3, title: "75 %", caption: "Tired"), Choice(id: 4, title: "100 %", caption: "Spent")]
    private let repChoices = [Choice(id: 0, title: "0", caption: nil), Choice(id: 1, title: "1", caption: nil),
                              Choice(id: 2, title: "2", caption: nil), Choice(id: 3, title: "3+", caption: nil)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.itemName) done")
                        .font(.subheadline.weight(.bold))
                    Text(request.muscles.isEmpty ? "How fatigued are the muscles?" : "How fatigued are your \(request.muscles)?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    live.answerFeedback(repsInReserve: repsLeft, fatigue: fatigue)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
            }
            HStack(spacing: 6) {
                ForEach(fatigueChoices) { choice in
                    chip(selected: fatigue == Double(choice.id) / 4, title: choice.title, caption: choice.caption) {
                        fatigue = Double(choice.id) / 4
                        submitIfComplete()
                    }
                }
            }
            if request.asksReps {
                Text("Reps left in the tank on the last set?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(repChoices) { choice in
                        chip(selected: repsLeft == choice.id, title: choice.title, caption: nil) {
                            repsLeft = choice.id
                            submitIfComplete()
                        }
                    }
                }
            }
        }
        .padding(14)
        .floatingGlass(cornerRadius: 24)
    }

    private func chip(selected: Bool, title: String, caption: String?, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 0) {
                Text(title).font(.subheadline.weight(.bold)).monospacedDigit()
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.glass)
    }

    private func submitIfComplete() {
        guard fatigue != nil, !request.asksReps || repsLeft != nil else { return }
        live.answerFeedback(repsInReserve: repsLeft, fatigue: fatigue)
    }
}

// MARK: - Full panel

/// The coach bar, expanded: the big ring, now / up next / after that, all controls, and the pace –
/// planned against actual rest, how far behind or ahead, when you'll finish, and how to get faster.
struct LivePanelSheet: View {
    let onFinish: () -> Void
    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ScrollView {
                    VStack(spacing: 20) {
                        PhaseRing(date: context.date, lineWidth: 14, large: true)
                            .frame(width: 230, height: 230)
                            .padding(.top, 8)
                        mainControls
                        UpcomingList()
                        PaceSection(snapshot: live.paceSnapshot(at: context.date))
                        statsSection(at: context.date)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(title)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        live.toggleVoiceMute()
                    } label: {
                        Image(systemName: live.isVoiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityLabel(live.isVoiceMuted ? "Unmute voice" : "Mute voice")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var title: String {
        switch live.phase {
        case .resting: return "Rest"
        case .ready: return live.currentSet == nil ? "All sets done" : "Ready"
        case .working: return "Set in progress"
        }
    }

    private var mainControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                control("backward.end.fill", "Back") { live.moveThread(by: -1) }
                control(live.isPaused ? "play.fill" : "pause.fill", live.isPaused ? "Resume" : "Pause") { live.togglePause() }
                control("forward.end.fill", "Skip") { live.moveThread(by: 1) }
            }
            if live.phase == .resting {
                HStack(spacing: 12) {
                    control("gobackward.15", "−15 s") { live.addRest(-15) }
                    control("goforward.15", "+15 s") { live.addRest(15) }
                    control("forward.fill", "Skip rest") { live.skipRest() }
                }
            }
            if live.currentSet != nil {
                Button {
                    if live.phase == .working { live.completeCurrentSet() } else { live.startSet() }
                } label: {
                    Label(live.phase == .working ? "Set Done" : "Start Set", systemImage: live.phase == .working ? "checkmark" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(live.phase == .working ? .accentColor : .green)
            } else {
                Button(action: onFinish) {
                    Label("Finish Workout", systemImage: "flag.checkered")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
            }
        }
    }

    private func control(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.glass)
    }

    private func statsSection(at date: Date) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            stat("Time", Format.clock(Int(live.elapsed(at: date))), "clock")
            stat("Sets", "\(live.content.completedSets) of \(live.content.totalSets)", "checklist")
            if live.content.volumeKg > 0 { stat("Volume", Format.volume(live.content.volumeKg, unit: live.unit), "scalemass") }
            if let hr = live.heartRate { stat("Heart rate", "\(Int(hr)) bpm", "heart.fill") }
        }
    }

    private func stat(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card(padding: 0, cornerRadius: 16)
    }
}

/// Now, up next, after that.
struct UpcomingList: View {
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        let rows = upcoming
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 12) {
                    Text(index == 0 ? "NOW" : (index == 1 ? "NEXT" : "THEN"))
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(index == 0 ? Color.accentColor : Color.secondary)
                        .frame(width: 40, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.item.name)
                            .font(index == 0 ? .headline : .subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text([CoachScript.setPosition(row.set, in: row.item), row.set.label(mode: row.item.mode, unit: live.unit)]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(index == 0 ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var upcoming: [(item: WorkoutItem, set: WorkoutSet)] {
        var result: [(item: WorkoutItem, set: WorkoutSet)] = []
        var ref = live.currentRef
        while let current = ref, result.count < 3 {
            if let item = live.content.item(at: current), let set = live.content.set(at: current), !set.isDone {
                result.append((item, set))
            }
            let next = live.content.nextPendingSet(after: current)
            if next == current || next == live.currentRef { break }
            ref = next
        }
        return result
    }
}

/// Pace: how far behind or ahead, this break against the plan, when you'll finish, and tips.
struct PaceSection: View {
    let snapshot: LiveWorkoutController.PaceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pace", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(WorkoutPace.deltaText(snapshot.totalDelta).capitalizedFirst)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(color(snapshot.totalDelta))
                Spacer()
            }
            VStack(spacing: 8) {
                row("This break", breakText)
                if let average = snapshot.averageDelta {
                    row("Average break", "\(WorkoutPace.signed(average)) vs. plan")
                }
                row("Finish at this pace", "\(Format.minutes(snapshot.projectedDuration)) (planned \(Format.minutes(snapshot.plannedDuration)))")
            }
            if snapshot.gaps.count >= 2 {
                GapChart(gaps: Array(snapshot.gaps.suffix(12)))
                    .frame(height: 120)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.tips, id: \.self) { tip in
                    Label(tip, systemImage: "lightbulb")
                        .font(.callout)
                }
            }
        }
        .padding()
        .card(padding: 0, cornerRadius: 20)
    }

    private var breakText: String {
        let planned = Format.clock(Int(snapshot.plannedRest))
        if let waiting = snapshot.waitingDelta {
            return "planned \(planned) · now \(WorkoutPace.signed(waiting))"
        }
        if let last = snapshot.lastGap {
            return "planned \(Format.clock(Int(last.planned))) · took \(Format.clock(Int(last.actual))) (\(WorkoutPace.signed(last.delta)))"
        }
        return "planned \(planned)"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func color(_ delta: Double) -> Color {
        if delta > 60 { return .red }
        if delta > 10 { return .orange }
        return .green
    }
}

/// Each break: planned (grey) against actual (coloured by how late).
struct GapChart: View {
    let gaps: [RestGap]

    private struct Row: Identifiable {
        let id: Int
        let planned: Double
        let actual: Double
    }

    var body: some View {
        let rows = gaps.enumerated().map { Row(id: $0.offset + 1, planned: $0.element.planned, actual: $0.element.actual) }
        Chart(rows) { row in
            BarMark(x: .value("Break", "\(row.id)"), y: .value("Seconds", row.actual))
                .foregroundStyle(row.actual - row.planned > 60 ? Color.red : (row.actual - row.planned > 10 ? Color.orange : Color.green))
                .cornerRadius(3)
            RectangleMark(x: .value("Break", "\(row.id)"), y: .value("Planned", row.planned), width: .ratio(0.9), height: 3)
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(Format.clock(Int(seconds))) }
                }
            }
        }
        .accessibilityLabel("Breaks against the planned rest")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Plan thread

/// Shown while you look at another exercise than the one that's due: swiping only looks.
struct ViewingPill: View {
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        Button {
            live.returnToCurrent()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Just looking")
                        .font(.caption.weight(.bold))
                    if let item = live.currentItem {
                        Text("Due now: \(item.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Label("Back", systemImage: "arrow.uturn.backward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floatingGlass(cornerRadius: 20)
        .accessibilityHint("Shows the exercise that's due now")
    }
}

/// A set was done outside the planned order: it counts – stay on the plan, or continue from here?
struct OffPlanCard: View {
    let notice: LiveWorkoutController.OffPlanNotice
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Off plan: \(notice.itemName)")
                        .font(.subheadline.weight(.bold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if notice.plannedName != nil {
                    Button {
                        live.stayOnPlan()
                    } label: {
                        Text("Stay on plan")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glass)
                }
                Button {
                    live.continueOffPlan()
                } label: {
                    Text("Continue with \(notice.itemName)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
            }
        }
        .padding(14)
        .floatingGlass(cornerRadius: 24, tint: .orange)
    }

    private var detail: String {
        var text = "\(notice.setText) counted."
        if let planned = notice.plannedName {
            text += " Next on plan: \(planned)"
            if let position = notice.plannedSetText, !position.isEmpty { text += ", \(position)" }
            text += "."
        }
        return text
    }
}

/// Where an exercise sits in the plan: done, due now, still open from earlier, or later.
struct PlanPositionChip: View {
    let position: LiveWorkoutController.PlanPosition

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var text: String {
        switch position {
        case .done: return "Done"
        case .now: return "Due now"
        case .skipped: return "Still open – skipped earlier"
        case .later: return "Later in the plan"
        }
    }

    private var symbol: String {
        switch position {
        case .done: return "checkmark.circle.fill"
        case .now: return "play.circle.fill"
        case .skipped: return "arrow.uturn.backward.circle"
        case .later: return "clock"
        }
    }

    private var tint: Color {
        switch position {
        case .done: return .green
        case .now: return .accentColor
        case .skipped: return .orange
        case .later: return .secondary
        }
    }
}
