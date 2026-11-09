import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Compact weekly-streak card at the top of the sidebar.
struct StreakCard: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live
    @Query private var sessions: [WorkoutSession]

    var body: some View {
        let summary = store.streakSummary(healthEntries: health.externalWorkouts)
        let _ = sessions.count + store.revision
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "flame.fill")
                    .font(.title2)
                    .foregroundStyle(summary.currentWeeks > 0 ? Color.orange.gradient : Color.secondary.gradient)
                    .symbolEffect(.bounce, value: summary.currentWeeks)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(summary.currentWeeks) week\(summary.currentWeeks == 1 ? "" : "s")")
                        .font(.title3.weight(.bold))
                        .contentTransition(.numericText())
                    Text(summary.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                SavesBadge(credits: summary.credits, max: summary.maxCredits)
            }
            WeekDotsView(week: summary.thisWeek)
            if summary.thisWeek.status == .rescueAvailable && !live.isActive {
                Button {
                    live.startEmpty(program: store.activeProgram, kind: .mobility, rescue: true)
                } label: {
                    Label("Rescue workout · \(store.settings.rescueMinutes) min", systemImage: "lifepreserver")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
            }
        }
        .padding(16)
        .card(padding: 0, cornerRadius: 26)
        .contentShape(Rectangle())
        .onTapGesture { router.show(.streak) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct SavesBadge: View {
    let credits: Int
    let max: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Swift.max(max, 1), id: \.self) { index in
                Image(systemName: index < credits ? "shield.fill" : "shield")
                    .font(.caption)
                    .foregroundStyle(index < credits ? Color.cyan : Color.secondary.opacity(0.5))
            }
        }
        .accessibilityLabel("\(credits) streak saves")
    }
}

struct WeekDotsView: View {
    let week: CurrentWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(week.dots) { dot in
                    VStack(spacing: 4) {
                        Text(dot.letter)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(dot.isToday ? Color.primary : Color.secondary)
                        ZStack {
                            Circle()
                                .fill(dot.didWorkout ? Color.orange : Color.secondary.opacity(dot.isFuture ? 0.08 : 0.18))
                            if dot.didWorkout {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .overlay {
                            if dot.isToday {
                                Circle().strokeBorder(Color.orange, lineWidth: 2).padding(-3)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text("\(week.effectiveDays)/\(week.goal) days this week")
                    .font(.caption.weight(.medium))
                Spacer()
                ProgressView(value: week.progress)
                    .tint(.orange)
                    .frame(width: 90)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// "Up next" card: continue the running workout, today's planned one, or the rotation suggestion.
struct UpNextCard: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(MuscleAnalytics.self) private var muscles
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Query private var sessions: [WorkoutSession]
    @Query private var templates: [WorkoutTemplate]

    var body: some View {
        let _ = sessions.count + templates.count + store.revision
        VStack(alignment: .leading, spacing: 12) {
            if let session = live.session {
                header("In progress", symbol: "waveform.path.ecg", tint: .green)
                hero(
                    title: session.title,
                    subtitle: "\(live.content.completedSets) of \(live.content.totalSets) sets done" + (live.currentItem.map { " · next: \($0.name)" } ?? ""),
                    kind: session.kind, colorHex: session.colorHex,
                    buttonTitle: "Continue Workout", symbol: "play.fill",
                    onOpen: { live.isPresented = true }
                ) {
                    live.isPresented = true
                }
            } else if let planned = store.upcomingSessions(limit: 1).first, Calendar.current.isDateInToday(planned.plannedDate ?? .distantPast) || (planned.plannedDate ?? .distantFuture) < Date() {
                header("Planned today", symbol: "calendar", tint: .accentColor)
                hero(
                    title: planned.title,
                    subtitle: planned.subtitle.isEmpty ? planned.summaryLine : planned.subtitle,
                    kind: planned.kind, colorHex: planned.colorHex,
                    buttonTitle: "Start Workout", symbol: "play.fill",
                    onOpen: { router.open(.session(planned.id)) }
                ) {
                    live.start(planned)
                }
            } else if let suggestion = store.suggestedTemplate(in: store.activeProgram) {
                header("Up next" + (suggestion.program.map { " · \($0.name)" } ?? ""), symbol: "sparkles", tint: .accentColor)
                hero(
                    title: suggestion.name,
                    subtitle: suggestion.subtitle.isEmpty ? suggestion.summaryLine : suggestion.subtitle,
                    kind: suggestion.kind, colorHex: suggestion.colorHex,
                    buttonTitle: "Start \(suggestion.name)", symbol: "play.fill",
                    onOpen: { router.open(.template(suggestion.id)) }
                ) {
                    live.start(template: suggestion)
                }
                readiness(for: suggestion)
                otherTemplates(excluding: suggestion)
            } else {
                header("Get started", symbol: "sparkles", tint: .accentColor)
                Text("Set up your first program")
                    .font(.title2.weight(.bold))
                Text("Programs hold templates — reusable workouts like UPPER or LOWER. Create one, import a plan (e.g. written by an AI), or try the sample.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    router.showCreate = true
                } label: {
                    Label("Create", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                HStack {
                    Button {
                        router.showImport = true
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    Button {
                        store.loadSampleProgram()
                    } label: {
                        Label("Sample Program", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(18)
        .card(padding: 0, cornerRadius: 28)
    }

    private func header(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .textCase(.uppercase)
            .lineLimit(1)
    }

    private func hero(
        title: String, subtitle: String, kind: WorkoutKind, colorHex: String?,
        buttonTitle: String, symbol: String, onOpen: @escaping () -> Void, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    KindIcon(kind: kind, colorHex: colorHex, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: action) {
                Label(buttonTitle, systemImage: symbol)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.accentColor)
        }
    }

    /// Shown only when muscles the suggestion targets are still recovering, with a fresher alternative.
    @ViewBuilder
    private func readiness(for suggestion: WorkoutTemplate) -> some View {
        let content = suggestion.content
        let fatigued = muscles.fatiguedTargets(of: content, kind: suggestion.kind)
        if !fatigued.isEmpty {
            let score = muscles.readiness(of: content, kind: suggestion.kind)
            VStack(alignment: .leading, spacing: 8) {
                ReadinessHint(fatigued: fatigued, readiness: score, compact: true)
                if let fresher = fresherAlternative(to: suggestion, score: score) {
                    Button {
                        live.start(template: fresher.template)
                    } label: {
                        Label("Fresher: \(fresher.template.name) · \(Int((fresher.score * 100).rounded())) % ready", systemImage: "arrow.triangle.swap")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func fresherAlternative(to suggestion: WorkoutTemplate, score: Double) -> (template: WorkoutTemplate, score: Double)? {
        let others = (store.activeProgram?.orderedTemplates ?? []).filter { $0.id != suggestion.id }
        let scored = others.compactMap { template -> (template: WorkoutTemplate, score: Double)? in
            let content = template.content
            guard !muscles.plannedLoad(content, kind: template.kind).isEmpty else { return nil }
            return (template: template, score: muscles.readiness(of: content, kind: template.kind))
        }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score >= score + 0.15 else { return nil }
        return best
    }

    /// Quick-start chips for the other templates of the active program.
    @ViewBuilder
    private func otherTemplates(excluding suggestion: WorkoutTemplate) -> some View {
        let others = (store.activeProgram?.orderedTemplates ?? []).filter { $0.id != suggestion.id }
        if !others.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(others) { template in
                        Button {
                            live.start(template: template)
                        } label: {
                            Label(template.name, systemImage: "play.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
    }
}
