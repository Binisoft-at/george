import SwiftUI
import Charts
import TipKit
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(Prefs.startButton) private var startButtonOn = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(at: context.date)
        }
        .background {
            // ␣ starts or completes the current set on a keyboard (Mac, iPad); paused, it resumes.
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
            if live.content.isEmpty {
                // An empty workout: add exercises, or just track the time and finish.
                HStack(spacing: 10) {
                    Button(action: onFinish) {
                        Label("Finish", systemImage: "flag.checkered")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.glass)
                    Button {
                        live.requestAddExercise = true
                    } label: {
                        Label("Add Exercise", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.glassProminent)
                }
            } else {
                Button(action: onFinish) {
                    Label("Finish Workout", systemImage: "flag.checkered")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
            }
        } else {
            let snapshot = live.paceSnapshot(at: date)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button(action: onExpand) {
                    HStack(spacing: 12) {
                        PhaseRing(date: date)
                            .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline(at: date))
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(tint(snapshot))
                                .lineLimit(1)
                            Text(live.currentItem?.name ?? "")
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(setLine)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let detail = detail(at: date, snapshot: snapshot) {
                                // The long form when it fits, otherwise the short one – never "…".
                                ViewThatFits(in: .horizontal) {
                                    Text(detail.long)
                                    Text(detail.short)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows pace, controls and what's next")

                primaryButton
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
            }
            .padding(12)
            .floatingGlass(cornerRadius: 28, tint: live.isPaused ? .gray : (live.phase == .resting ? .teal : nil))
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        let _ = startButtonOn
        if live.isPaused {
            Button {
                live.resume()
            } label: {
                buttonLabel("play.fill", "Resume")
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Resume the workout")
        } else if live.primaryIsStart {
            Button {
                live.primaryAction()
            } label: {
                buttonLabel("play.fill", "Start")
            }
            .buttonStyle(.glassProminent)
            .tint(live.phase == .resting ? .teal : .accentColor)
            .accessibilityLabel(live.phase == .resting ? "Skip rest and start the set" : "Start the set")
            .popoverTip(GeorgeTips.CoachStartTip())
        } else {
            Button {
                live.primaryAction()
            } label: {
                buttonLabel("checkmark", "Done")
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Mark set done")
        }
    }

    private func buttonLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol).font(.headline.weight(.heavy))
            Text(title).font(.caption.weight(.bold))
        }
        .frame(minWidth: 64, minHeight: 58)
    }

    /// "set 2 of 4 · 8 × 60 kg"
    private var setLine: String {
        guard let item = live.currentItem, let set = live.currentSet else { return "" }
        let position = CoachScript.setPosition(set, in: item)
        let what = set.label(mode: item.mode, unit: live.unit)
        return [position.isEmpty ? nil : position, what].compactMap { $0 }.joined(separator: " · ")
    }

    private func headline(at date: Date) -> String {
        if live.isPaused { return "PAUSED" }
        switch live.phase {
        case .resting: return live.restRemaining(at: date) <= 10 ? "GET READY · UP NEXT" : "REST · UP NEXT"
        case .ready: return "NOW"
        case .working:
            if let end = live.timedSetEndsAt {
                let total = max(0, end.timeIntervalSince(date))
                if let side = live.timedSide, let target = live.timedTarget {
                    // The side that's running, the same number as the ring.
                    let sideLeft = max(0, total - (side == 1 ? Double(target) / 2 : 0))
                    return "SIDE \(side) OF 2 · \(Format.clock(Int(sideLeft.rounded(.up)))) LEFT"
                }
                return "\(Format.clock(Int(total.rounded(.up)))) LEFT"
            }
            return "IN PROGRESS"
        }
    }

    private func detail(at date: Date, snapshot: LiveWorkoutController.PaceSnapshot) -> (long: String, short: String)? {
        if live.isPaused { return ("Clock and rest stopped", "Stopped") }
        switch live.phase {
        case .resting:
            let text = "Rest \(Format.clock(live.restRemaining(at: date))) of \(Format.clock(live.restTotal))"
            return (text, text)
        case .ready:
            guard snapshot.plannedRest > 0 else { return live.primaryIsStart ? ("Tap Start when you begin", "Tap Start") : nil }
            let planned = "Planned rest \(Format.clock(Int(snapshot.plannedRest)))"
            // The running total only when it matters – the full pace is in the panel.
            if abs(snapshot.totalDelta) >= 60 {
                let delta = "\(Format.clock(Int(abs(snapshot.totalDelta).rounded()))) \(snapshot.totalDelta > 0 ? "behind" : "ahead")"
                return ("\(planned) · \(delta)", "Rest \(Format.clock(Int(snapshot.plannedRest))) · \(delta)")
            }
            return (planned, planned)
        case .working:
            let text = "Working \(Format.clock(Int(live.pace.workingSeconds(at: date))))"
            return (text, text)
        }
    }

    private func tint(_ snapshot: LiveWorkoutController.PaceSnapshot) -> Color {
        if live.isPaused { return .secondary }
        switch live.phase {
        case .resting: return .teal
        case .working: return .accentColor
        case .ready:
            // NOW is always the accent colour; only lateness is tinted.
            let waiting = snapshot.waitingDelta ?? 0
            if waiting > 60 { return .red }
            if waiting > 0 { return .orange }
            return .accentColor
        }
    }
}

/// The ring in the coach bar and the panel: the rest countdown, a timed set's countdown, the time a
/// set has been going, or – while waiting – the rest left, then the time over it.
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
                    .font(large ? .system(.largeTitle, design: .rounded).weight(.bold) : .subheadline.weight(.bold))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.text) \(state.caption)")
    }

    private struct RingState {
        var progress: Double
        var text: String
        var caption: String
        var tint: Color
        var countsDown: Bool
    }

    private var ringState: RingState {
        if live.isPaused {
            return RingState(progress: 1, text: "II", caption: "paused", tint: .gray, countsDown: false)
        }
        switch live.phase {
        case .resting:
            let remaining = live.restRemaining(at: date)
            return RingState(progress: Double(remaining) / Double(max(1, live.restTotal)), text: Format.clock(remaining),
                             caption: "rest", tint: remaining <= 10 ? .accentColor : .teal, countsDown: true)
        case .working:
            if let end = live.timedSetEndsAt, let total = live.timedTarget {
                let left = max(0, end.timeIntervalSince(date))
                if let side = live.timedSide {
                    // Per side: the ring and the number show the side that's running.
                    let perSide = Double(total) / 2
                    let sideLeft = max(0, left - (side == 1 ? perSide : 0))
                    return RingState(progress: sideLeft / max(1, perSide), text: Format.clock(Int(sideLeft.rounded(.up))),
                                     caption: "side \(side) of 2", tint: sideLeft <= 10 ? .orange : .accentColor, countsDown: true)
                }
                return RingState(progress: left / Double(max(1, total)), text: Format.clock(Int(left.rounded(.up))),
                                 caption: "left", tint: left <= 10 ? .orange : .accentColor, countsDown: true)
            }
            let working = live.pace.workingSeconds(at: date)
            let expected = live.currentItem.flatMap { item in live.currentSet.map { PaceTracker.workSeconds(for: $0, mode: item.mode) } } ?? 45
            return RingState(progress: min(1, working / max(1, expected)), text: Format.clock(Int(working)),
                             caption: "working", tint: working > expected * 1.5 ? .orange : .accentColor, countsDown: false)
        case .ready:
            let planned = live.plannedRestBeforeCurrent
            if planned > 0, let waiting = live.pace.waitingDelta(at: date, plannedRest: planned) {
                if waiting <= 0 {
                    // Still within the planned rest: keep counting down.
                    let left = -waiting
                    return RingState(progress: left / planned, text: Format.clock(Int(left.rounded(.up))),
                                     caption: "rest left", tint: .accentColor, countsDown: true)
                }
                // Over the planned rest: one number – how much over.
                return RingState(progress: 1, text: "+" + Format.clock(Int(waiting)), caption: "over rest",
                                 tint: waiting > 60 ? .red : .orange, countsDown: false)
            }
            if let target = live.timedTarget {
                return RingState(progress: 1, text: Format.clock(target), caption: "ready", tint: .accentColor, countsDown: false)
            }
            return RingState(progress: 1, text: "GO", caption: "ready", tint: .accentColor, countsDown: false)
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
                    if live.phase == .working, live.timedSetEndsAt != nil {
                        if let side = live.timedSide {
                            Text(side == 1 ? "Side 1 of 2" : "Side 2 of 2 – switched")
                                .font(.title3.weight(.bold))
                            Text("George says when to switch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Hold")
                                .font(.title3.weight(.bold))
                            Text("Ticks itself off at zero")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(Format.clock(set.targetSeconds ?? set.seconds ?? 0))\(item.perSide ? " each side" : "")")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Button {
                            // Paused: carries on (a paused hold continues where it stopped).
                            if live.isPaused { live.resume() } else { live.startSet() }
                        } label: {
                            Label(live.isPaused ? "Resume" : "Start timer", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.glassProminent)
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

    /// One question at a time: fatigue first (if asked), then reps left. Each tap is saved at once.
    private var showsFatigue: Bool { request.asksFatigue && request.fatigue == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.itemName) done")
                        .font(.subheadline.weight(.bold))
                    Text(question)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Menu {
                    Button { live.skipFeedbackForThisWorkout() } label: { Label("Not in This Workout", systemImage: "moon.zzz") }
                    Button { live.stopAskingFeedback() } label: { Label("Stop Asking (Settings → Coach)", systemImage: "bell.slash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Question options")
                Button {
                    live.closeFeedback()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
            }
            HStack(spacing: 6) {
                if showsFatigue {
                    ForEach(fatigueChoices) { choice in
                        chip(title: choice.title, caption: choice.caption) { live.recordFatigue(Double(choice.id) / 4) }
                    }
                } else {
                    ForEach(repChoices) { choice in
                        chip(title: choice.title, caption: nil) { live.recordReps(inReserve: choice.id) }
                    }
                }
            }
        }
        .padding(12)
        .floatingGlass(cornerRadius: 24)
    }

    private var question: String {
        if showsFatigue {
            return request.muscles.isEmpty ? "How fatigued are the muscles?" : "How fatigued are your \(request.muscles)?"
        }
        return "Reps left in the tank on the last set?"
    }

    private func chip(title: String, caption: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title).font(.subheadline.weight(.bold)).monospacedDigit()
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
    }
}

// MARK: - Full panel

/// The coach bar, expanded: the big ring, now / up next / after that, all controls, and the pace –
/// planned against actual rest, how far behind or ahead, when you'll finish, and how to get faster.
struct LivePanelSheet: View {
    let onFinish: () -> Void
    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.liveActions) private var actions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        // A column next to live mode (inspector): no toolbar – the header holds the title and buttons.
        VStack(spacing: 0) {
            macHeader
            Divider()
            panel
        }
        #else
        NavigationStack {
            panel
                .navigationTitle(title)
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        muteButton
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var panel: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Only what changes every half second sits in the timeline.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    PhaseRing(date: context.date, lineWidth: 14, large: true)
                        .frame(width: 230, height: 230)
                        .padding(.top, 8)
                }
                mainControls
                UpcomingList()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 20) {
                        PaceSection(snapshot: live.paceSnapshot(at: context.date))
                        statsSection(at: context.date)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var muteButton: some View {
        Button {
            live.toggleVoiceMute()
        } label: {
            Image(systemName: live.isVoiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .accessibilityLabel(live.isVoiceMuted ? "Unmute voice" : "Mute voice")
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            muteButton
                .buttonStyle(.borderless)
                .help(live.isVoiceMuted ? "Unmute voice" : "Mute voice")
            Button {
                live.showPanel = false
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Hide Pace & Controls")
            .help("Hide Pace & Controls")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
    #endif

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
            if let item = live.currentItem, let set = live.currentSet {
                HStack(spacing: 12) {
                    if (set.effectiveWeight ?? 0) > 0 {
                        control("arrow.down.circle", "Lower weight") { afterClosing { actions.dropWeight(set.id, item.id) } }
                    }
                    control("arrow.triangle.swap", "Swap exercise") { afterClosing { actions.swap(item.id) } }
                }
            }
            if live.phase == .resting {
                HStack(spacing: 12) {
                    control("gobackward.15", "−15 s") { live.addRest(-15) }
                    control("goforward.15", "+15 s") { live.addRest(15) }
                    control("forward.fill", "Skip rest") { live.skipRest() }
                }
            }
            if live.isPaused {
                Button {
                    live.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
            } else if live.currentSet != nil {
                Button {
                    live.primaryAction()
                } label: {
                    Label(live.primaryIsStart ? "Start Set" : "Set Done", systemImage: live.primaryIsStart ? "play.fill" : "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
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

    /// Closes the panel first – the next sheet opens from the live screen. On the Mac the panel is a
    /// column next to live mode and stays.
    private func afterClosing(_ action: @escaping @MainActor () -> Void) {
        #if os(macOS)
        action()
        #else
        live.showPanel = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            action()
        }
        #endif
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
            if live.content.workingVolumeKg > 0 { stat("Volume", Format.volume(live.content.workingVolumeKg, unit: live.unit), "scalemass") }
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

/// Where Pace & Controls (`LivePanelSheet`) opens: a sheet on iPhone/iPad, an inspector column next to
/// live mode on the Mac – no sheet over the workout window there.
struct LivePanelPresentation: ViewModifier {
    let onFinish: () -> Void
    @Environment(LiveWorkoutController.self) private var live

    func body(content: Content) -> some View {
        let shown = Binding(get: { live.showPanel }, set: { live.showPanel = $0 })
        #if os(macOS)
        content
            .inspector(isPresented: shown) {
                LivePanelSheet(onFinish: onFinish)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
        #else
        content
            .sheet(isPresented: shown) {
                LivePanelSheet(onFinish: onFinish)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        #endif
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
        return .accentColor
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
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                }
                // Short label (the exercise is named in the title above), accent for contrast.
                Button {
                    live.continueOffPlan()
                } label: {
                    Text("Continue here")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .accessibilityLabel("Continue with \(notice.itemName)")
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
