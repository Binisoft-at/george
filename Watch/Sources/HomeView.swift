import SwiftUI
import GeorgeCore

struct HomeView: View {
    @Environment(WatchConnector.self) private var connector
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLive = false
    @State private var didAutoOpen = false
    @State private var pendingStart: PendingStart?

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
                    Button("Start") { connector.perform(start.command) }
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
            if newValue != oldValue || !didAutoOpen {
                didAutoOpen = true
                showingLive = true
            }
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

    @ViewBuilder
    private var content: some View {
        if let snapshot = connector.snapshot {
            List {
                if let live = connector.live {
                    Section {
                        ResumeRow(live: live) { showingLive = true }
                    }
                } else if workout.phase.isActive {
                    Section {
                        UnmatchedRecordingRow { workout.end() }
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
                            .disabled(connector.live != nil)
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
                            .disabled(connector.live != nil)
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
    let title: String
    let message: String
    let command: WatchCommand

    init(template: WatchTemplate, reachable: Bool) {
        title = "Start \(template.name)?"
        var details: [String] = []
        if !template.programName.isEmpty { details.append(template.programName) }
        if template.estimatedMinutes > 0 { details.append("About \(template.estimatedMinutes) min") }
        message = PendingStart.composeMessage(details: details, reachable: reachable)
        command = .startTemplate(template.id)
    }

    init(session: WatchSessionSummary, reachable: Bool) {
        title = "Start \(session.title)?"
        message = PendingStart.composeMessage(details: [session.kind.displayName, DayLabel.text(for: session.date)], reachable: reachable)
        command = .startSession(session.id)
    }

    private static func composeMessage(details: [String], reachable: Bool) -> String {
        var lines = [details.joined(separator: " · ")]
        if !reachable { lines.append("It starts as soon as your iPhone is reachable.") }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
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

/// A HealthKit recording with no George workout behind it (e.g. the phone ended it while unreachable).
private struct UnmatchedRecordingRow: View {
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Recording on watch", systemImage: "heart.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("No workout is running in George on your iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("End recording", role: .destructive, action: onEnd)
        }
        .padding(.vertical, 4)
    }
}

private struct StreakCard: View {
    let streak: WatchStreak

    var body: some View {
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
                ForEach(Array(streak.dots.prefix(7).enumerated()), id: \.offset) { item in
                    Circle()
                        .fill(item.element ? Color.orange : Color.white.opacity(0.2))
                        .frame(width: 8, height: 8)
                }
                Spacer(minLength: 4)
                Text("\(streak.doneDays)/\(streak.goal) days")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !streak.headline.isEmpty {
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
