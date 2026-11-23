import SwiftUI
import GeorgeCore

struct HomeView: View {
    @Environment(WatchConnector.self) private var connector
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLive = false
    @State private var didAutoOpen = false
    @State private var pendingStart: PendingStart?
    @State private var shownSummary: ShownSummary?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("George")
                .navigationDestination(isPresented: $showingLive) {
                    LiveWorkoutView()
                }
                .confirmationDialog(
                    pendingStart?.title ?? "Start workout?",
                    isPresented: isConfirmingStart,
                    titleVisibility: .visible,
                    presenting: pendingStart
                ) { start in
                    Button("Start") { connector.requestStart(start.command, title: start.name) }
                    Button("Cancel", role: .cancel) {}
                } message: { start in
                    Text(start.message)
                }
        }
        // Open the live workout when one starts (here or on the phone) and close it when it ends.
        .onChange(of: connector.live?.sessionID, initial: true) { oldValue, newValue in
            guard newValue != nil else {
                showingLive = false
                return
            }
            shownSummary = nil
            if newValue != oldValue || !didAutoOpen {
                didAutoOpen = true
                showingLive = true
            }
        }
        // The summary of a just-saved workout, once the live pages are gone.
        .onChange(of: connector.finishSummary?.sessionID, initial: true) { _, newValue in
            guard newValue != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard let summary = connector.finishSummary, !showingLive, shownSummary == nil else { return }
                shownSummary = ShownSummary(summary: summary)
            }
        }
        .sheet(item: $shownSummary) { shown in
            FinishSummaryView(summary: shown.summary) {
                shownSummary = nil
            }
            // Closed with Done or swiped away: don't offer it again.
            .onDisappear { connector.dismissFinishSummary(shown.summary.sessionID) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connector.refresh() }
        }
        .task {
            await workout.requestAuthorization()
        }
    }

    private var isConfirmingStart: Binding<Bool> {
        Binding(
            get: { pendingStart != nil },
            set: { isPresented in
                if !isPresented { pendingStart = nil }
            }
        )
    }

    /// The recording is of a workout the iPhone handed over to a Mac (it goes on until that ends).
    private var isHandedOver: Bool {
        guard let id = workout.sessionID else { return false }
        return WatchRecordingEnd.verdict(for: id, in: connector.snapshot) == .keep
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = connector.snapshot {
            let canStart = connector.live == nil && connector.startRequest == nil
            List {
                if let live = connector.live {
                    Section {
                        ResumeRow(live: live) { showingLive = true }
                    }
                } else if let request = connector.startRequest {
                    Section {
                        StartRequestRow(request: request, isReachable: connector.isReachable) { connector.cancelStart() }
                    }
                } else if workout.phase.isActive {
                    Section {
                        UnmatchedRecordingRow(handedOver: isHandedOver) { workout.end() }
                    }
                }

                if let problem = connector.startProblem, connector.live == nil, connector.startRequest == nil {
                    Section {
                        StartProblemRow(message: problem) { connector.clearStartProblem() }
                    }
                }

                if let streak = snapshot.streak {
                    Section {
                        StreakCard(streak: streak)
                    }
                }

                if !snapshot.upcoming.isEmpty {
                    Section("Up next") {
                        ForEach(snapshot.upcoming) { planned in
                            Button {
                                pendingStart = PendingStart(session: planned, reachable: connector.isReachable)
                            } label: {
                                WorkoutRow(kind: planned.kind, title: planned.title, subtitle: DayLabel.text(for: planned.date))
                            }
                            .disabled(!canStart)
                        }
                    }
                }

                if !snapshot.templates.isEmpty {
                    Section("Start") {
                        ForEach(Self.ordered(snapshot.templates)) { template in
                            Button {
                                pendingStart = PendingStart(template: template, reachable: connector.isReachable)
                            } label: {
                                WorkoutRow(
                                    kind: template.kind,
                                    title: template.name,
                                    subtitle: Self.subtitle(for: template),
                                    isSuggested: template.isSuggested
                                )
                            }
                            .disabled(!canStart)
                        }
                    }
                }

                if snapshot.upcoming.isEmpty && snapshot.templates.isEmpty {
                    Text("Add a program or template in George on your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if connector.isActivated && !connector.isReachable {
                    Label("iPhone not connected", systemImage: "iphone.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .containerBackground(background, for: .navigation)
        } else {
            ContentUnavailableView(
                "Open George on your iPhone",
                systemImage: "iphone",
                description: Text("Your workouts, plan and streak will show up here.")
            )
        }
    }

    private var background: LinearGradient {
        LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.black], startPoint: .top, endPoint: .bottom)
    }

    /// Suggested templates first, otherwise in the phone's order.
    private static func ordered(_ templates: [WatchTemplate]) -> [WatchTemplate] {
        templates.filter(\.isSuggested) + templates.filter { !$0.isSuggested }
    }

    private static func subtitle(for template: WatchTemplate) -> String {
        if !template.subtitle.isEmpty { return template.subtitle }
        var parts: [String] = []
        if template.exerciseCount > 0 {
            parts.append("\(template.exerciseCount) exercise\(template.exerciseCount == 1 ? "" : "s")")
        }
        if template.estimatedMinutes > 0 { parts.append("~\(template.estimatedMinutes) min") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Start confirmation

private struct PendingStart {
    let name: String
    let title: String
    let message: String
    let command: WatchCommand

    init(template: WatchTemplate, reachable: Bool) {
        name = template.name
        title = "Start \(template.name)?"
        var details: [String] = []
        if !template.programName.isEmpty { details.append(template.programName) }
        if template.estimatedMinutes > 0 { details.append("About \(template.estimatedMinutes) min") }
        message = PendingStart.composeMessage(details: details, reachable: reachable)
        command = .startTemplate(template.id)
    }

    init(session: WatchSessionSummary, reachable: Bool) {
        name = session.title
        title = "Start \(session.title)?"
        message = PendingStart.composeMessage(details: [session.kind.displayName, DayLabel.text(for: session.date)], reachable: reachable)
        command = .startSession(session.id)
    }

    private static func composeMessage(details: [String], reachable: Bool) -> String {
        var lines = [details.joined(separator: " · ")]
        if !reachable {
            let minutes = Int(WatchConnector.startLifetime / 60)
            lines.append("Your iPhone isn't connected. The watch waits up to \(minutes) min for it – you can cancel.")
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A just-saved workout's summary, presented once.
private struct ShownSummary: Identifiable {
    let summary: WatchFinishSummary
    var id: UUID { summary.sessionID }
}

// MARK: - Start status

/// "Waiting for iPhone…" / "Starting…" with Cancel, so a start never fires unnoticed later.
private struct StartRequestRow: View {
    let request: StartRequest
    let isReachable: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.status == .waitingForPhone ? "Waiting for iPhone…" : "Starting on iPhone…")
                        .font(.headline)
                        .lineLimit(2)
                    if let title = request.title {
                        Text(title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if request.status == .waitingForPhone {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(request.sentAt.addingTimeInterval(WatchConnector.startLifetime).timeIntervalSince(context.date).rounded()))
                    Text(isReachable
                         ? "Sending… gives up in \(Format.clock(left))."
                         : "Bring your iPhone closer or turn on Bluetooth. Gives up in \(Format.clock(left)).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(.vertical, 4)
    }
}

private struct StartProblemRow: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not started", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK", action: onDismiss)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rows

private struct ResumeRow: View {
    let live: WatchLiveState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: live.isPaused ? "pause.circle.fill" : live.kind.symbol)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(live.isPaused ? "Paused" : "Resume workout")
                        .font(.headline)
                    Text(live.title)
                        .font(.caption2)
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.clock(Int(live.elapsed(at: context.date))))
                            .font(.caption.monospacedDigit())
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(live.kind.onTint)
            .padding(.vertical, 4)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(live.kind.tint.gradient)
        )
    }
}

/// A HealthKit recording with no George workout behind it (e.g. the phone ended it while unreachable),
/// or one for a workout that continues on a Mac (`handedOver`).
private struct UnmatchedRecordingRow: View {
    var handedOver = false
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Recording on watch", systemImage: "heart.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(handedOver ? "The workout continues on your Mac. Heart rate and calories are recorded here." : "No workout is running in George on your iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("End recording", role: .destructive, action: onEnd)
        }
        .padding(.vertical, 4)
    }
}

private struct StreakCard: View {
    let streak: WatchStreak

    /// The snapshot's week is still running (a cached one from last week shows an empty week).
    private var isCurrent: Bool {
        SnapshotTiming.isInWeek(startingAt: streak.weekStart, Date(), calendar: .current)
    }

    var body: some View {
        let dots = SnapshotTiming.dots(streak.dots, weekStart: streak.weekStart, on: Date(), calendar: .current)
        let doneDays = SnapshotTiming.doneDays(streak.doneDays, weekStart: streak.weekStart, on: Date(), calendar: .current)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("\(streak.weeks) wk streak")
                } icon: {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                }
                .font(.headline)
                Spacer(minLength: 4)
                if streak.credits > 0 {
                    Label("\(streak.credits)", systemImage: "shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.cyan)
                        .accessibilityLabel(Text("\(streak.credits) saves"))
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(dots.prefix(7).enumerated()), id: \.offset) { item in
                    Circle()
                        .fill(item.element ? Color.orange : Color.white.opacity(0.2))
                        .frame(width: 8, height: 8)
                }
                Spacer(minLength: 4)
                Text("\(doneDays)/\(streak.goal) days")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if isCurrent && !streak.headline.isEmpty {
                Text(streak.headline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WorkoutRow: View {
    let kind: WorkoutKind
    let title: String
    let subtitle: String
    var isSuggested = false

    var body: some View {
        HStack(spacing: 10) {
            KindIcon(kind: kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if isSuggested {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(Text("Suggested"))
            }
        }
        .padding(.vertical, 2)
    }
}
