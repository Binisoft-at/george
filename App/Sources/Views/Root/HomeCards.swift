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
    @Environment(ToastCenter.self) private var toasts
    @Query private var sessions: [WorkoutSession]
    @State private var showRescue = false

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
                    if summary.thisWeek.status == .onBreak {
                        // A break week: calm, nothing to chase.
                        Label(summary.headline, systemImage: "bed.double.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        // On the Mac (no Apple Health) no alarm the iPhone wouldn't raise.
                        Text(MacHealth.headline(summary, store: store))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                SavesBadge(credits: summary.credits, max: summary.maxCredits)
            }
            WeekDotsView(week: summary.thisWeek, marks: store.dayMarks(for: summary.thisWeek)) { date, templateID in
                plan(templateID, on: date)
            }
            MacHealthNote(topic: .streak)
            if summary.thisWeek.status == .rescueAvailable && !live.isActive && MacHealth.offersRescue(store) {
                Button {
                    showRescue = true
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
        .sheet(isPresented: $showRescue) {
            RescueSheet()
        }
    }

    /// A tap on a coming day's letter plans the template scheduled for it.
    private func plan(_ templateID: UUID, on date: Date) {
        guard let template = store.template(id: templateID) else { return }
        let session = store.makeSession(from: template, date: date, start: false)
        Haptics.success()
        toasts.show("Planned \(template.name) for \(store.shortDay(date))", symbol: "calendar.badge.checkmark") {
            store.removePlanned([session])
        }
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
    /// Coming days: the initial of the planned workout (accent) or of the template scheduled that day.
    var marks: [Date: GeorgeStore.DayMark] = [:]
    /// Tapping a scheduled (not yet planned) day plans its template.
    var onPlan: ((Date, UUID) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(week.dots) { dot in
                    let mark = dot.didWorkout ? nil : marks[dot.date]
                    VStack(spacing: 4) {
                        Text(dot.letter)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(dot.isToday ? Color.primary : Color.secondary)
                        ZStack {
                            Circle()
                                .fill(fill(for: dot, mark: mark))
                            if dot.didWorkout {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(.white)
                            } else if let mark {
                                Text(mark.initial)
                                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color.accentColor.opacity(mark.isPlanned ? 1 : 0.55))
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
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture().onEnded {
                            if let onPlan, let templateID = mark?.templateID { onPlan(dot.date, templateID) }
                        },
                        // Only scheduled days take the tap; elsewhere it opens the streak as before.
                        including: onPlan != nil && mark?.templateID != nil ? .all : .subviews
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText(for: dot, mark: mark))
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

    private func fill(for dot: DayDot, mark: GeorgeStore.DayMark?) -> Color {
        if dot.didWorkout { return .orange }
        if mark?.isPlanned == true { return Color.accentColor.opacity(0.16) }
        return Color.secondary.opacity(dot.isFuture ? 0.08 : 0.18)
    }

    private func accessibilityText(for dot: DayDot, mark: GeorgeStore.DayMark?) -> String {
        let day = dot.date.formatted(.dateTime.weekday(.wide))
        if dot.didWorkout { return "\(day): trained" }
        if let mark { return "\(day): \(mark.isPlanned ? "planned" : "scheduled") \(mark.initial)" }
        return day
    }
}

/// "Up next" card: continue the running workout, today's planned one, what was done today, a rest
/// day, or the rotation suggestion – plus the energy forecast when a low day is coming.
struct UpNextCard: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(MuscleAnalytics.self) private var muscles
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(HealthKitManager.self) private var health
    @Environment(ExerciseLibrary.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Query private var sessions: [WorkoutSession]
    @Query private var templates: [WorkoutTemplate]
    @State private var showPlanWeek = false

    var body: some View {
        let _ = sessions.count + templates.count + store.revision
        VStack(alignment: .leading, spacing: 12) {
            mainContent
            energyForecast
        }
        .padding(18)
        .card(padding: 0, cornerRadius: 28)
        .sheet(isPresented: $showPlanWeek) {
            // Only the energy hint opens it here: the low day starts out lighter.
            PlanWeekSheet(preferLighter: true)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
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
        } else if let other = live.workoutOnOtherDevice {
            // Running on another iPhone, iPad or Mac (synced): no second Start here – continue it here.
            header("On another device", symbol: "iphone.and.arrow.forward", tint: .green)
            hero(
                title: other.title,
                subtitle: "\(other.content.completedSets) of \(other.content.totalSets) sets done · running there now",
                kind: other.kind, colorHex: other.colorHex,
                buttonTitle: "Continue Here", symbol: "play.fill",
                onOpen: { router.open(.session(other.id)) }
            ) {
                live.continueHere(other)
            }
        } else if let planned = store.plannedToday().first {
            header("Planned today", symbol: "calendar", tint: .accentColor)
            hero(
                title: planned.title,
                subtitle: planned.subtitle.isEmpty ? planned.summaryLine : planned.subtitle,
                kind: planned.kind, colorHex: planned.colorHex,
                buttonTitle: "Start Workout", symbol: "play.fill",
                onOpen: { router.open(.session(planned.id)) }
            ) {
                live.requestStart(.session(planned))
            }
        } else if let done = store.performedToday().first {
            doneToday(done)
        } else if let suggestion = store.suggestedTemplate(in: store.activeProgram) {
            if let reason = restReason(for: suggestion) {
                restDay(reason: reason, suggestion: suggestion)
            } else {
                header("Up next" + (suggestion.program.map { " · \($0.name)" } ?? ""), symbol: "sparkles", tint: .accentColor)
                hero(
                    title: suggestion.name,
                    subtitle: suggestion.subtitle.isEmpty ? suggestion.summaryLine : suggestion.subtitle,
                    kind: suggestion.kind, colorHex: suggestion.colorHex,
                    buttonTitle: "Start \(suggestion.name)", symbol: "play.fill",
                    onOpen: { router.open(.template(suggestion.id)) }
                ) {
                    store.requestStart(suggestion, live: live, toasts: toasts)
                }
                readiness(for: suggestion)
                otherTemplates(excluding: suggestion)
            }
        } else {
            header("Get started", symbol: "sparkles", tint: .accentColor)
            Text("Set up your first program")
                .font(.title2.weight(.bold))
            Text("Programs hold templates — reusable workouts like UPPER or LOWER. Create one, import a plan (e.g. written by an AI), or try a sample.")
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
                Menu {
                    ForEach(GeorgeStore.SampleProgram.allCases) { sample in
                        Button {
                            if let program = store.loadSampleProgram(sample) {
                                toasts.show("Added \u{201C}\(program.name)\u{201D}", symbol: "wand.and.stars")
                            }
                        } label: {
                            Label {
                                Text(sample.title)
                                Text(sample.detail)
                            } icon: {
                                Image(systemName: sample == .gym ? "dumbbell" : "figure.tennis")
                            }
                        }
                    }
                } label: {
                    Label("Sample Program", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: Done today / rest day

    /// A workout was done today: what it was, what's next – and a quiet way to train again anyway.
    @ViewBuilder
    private func doneToday(_ done: WorkoutSession) -> some View {
        let next = store.nextUp()
        header("Done today", symbol: "checkmark.seal.fill", tint: .green)
        Button {
            router.open(.session(done.id))
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.15))
                    Image(systemName: "checkmark")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.green)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.displayName(of: done))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(doneLine(done))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Same rule as the streak and the week dots: a short routine is done, but no training day yet.
        if !TrainingDays.isTrainingDay(Date(), in: store.trainingEntries(healthEntries: health.externalWorkouts), calendar: store.calendar) {
            Label("Doesn't count toward your streak yet (min \(store.settings.minimumMinutes) min)", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let next {
            HStack(spacing: 10) {
                Label(nextText(next), systemImage: "arrow.forward.circle")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Button("Start anyway") { start(next) }
                    .font(.subheadline)
                    .buttonStyle(.glass)
            }
        }
    }

    /// Goal met, nothing scheduled or tired muscles: a rest day, with a stretch routine instead.
    @ViewBuilder
    private func restDay(reason: String, suggestion: WorkoutTemplate) -> some View {
        let next = store.nextUp()
        header("Rest day", symbol: "moon.zzz.fill", tint: .indigo)
        HStack(spacing: 12) {
            Image(systemName: "bed.double.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.indigo)
                .frame(width: 46, height: 46)
                .background(Color.indigo.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Rest day")
                    .font(.title2.weight(.bold))
                Text(next.map(nextText) ?? "Next: \(suggestion.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        Text(reason)
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack(spacing: 8) {
            Button {
                stretchInstead()
            } label: {
                Label("Stretch instead", systemImage: "figure.flexibility")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(.green)
            Button {
                store.requestStart(suggestion, live: live, toasts: toasts)
            } label: {
                Label("Start \(suggestion.name)", systemImage: "play.fill")
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }

    private func doneLine(_ session: WorkoutSession) -> String {
        var parts: [String] = []
        if session.durationSeconds > 0 { parts.append(Format.minutes(session.durationSeconds)) }
        if session.setCount > 0 {
            parts.append("\(session.doneSetCount)/\(session.setCount) sets")
        } else if let energy = store.displayEnergy(for: session) {
            // Measured when the Watch recorded it, else George's estimate ("≈").
            parts.append(energy.text)
        }
        return parts.isEmpty ? session.kind.displayName : parts.joined(separator: " · ")
    }

    private func nextText(_ next: GeorgeStore.NextUp) -> String {
        "Next: \(next.name)" + (next.date.map { " · \(store.shortDay($0))" } ?? "")
    }

    private func start(_ next: GeorgeStore.NextUp) {
        if let session = next.session {
            live.requestStart(.session(session))
        } else if let template = next.template {
            store.requestStart(template, live: live, toasts: toasts)
        }
    }

    /// Why today is a rest day (nil: it isn't). Only when the week has room to spare.
    private func restReason(for suggestion: WorkoutTemplate) -> String? {
        let week = store.streakSummary(healthEntries: health.externalWorkouts).thisWeek
        if week.status == .onBreak { return "Break week – your streak is safe. Rest as long as you need." }
        if week.neededDays == 0 {
            return "Weekly goal met – \(week.effectiveDays) of \(week.goal) days. Rest is part of the plan."
        }
        let available = week.remainingDays - (week.workedOutToday ? 1 : 0)
        guard week.neededDays < available else { return nil }
        let more = "\(week.neededDays) more day\(week.neededDays == 1 ? "" : "s") this week"
        if store.isUnscheduledDay(in: store.activeProgram) {
            return "Nothing is scheduled today – \(more), with room to spare."
        }
        let content = suggestion.content
        let score = muscles.readiness(of: content, kind: suggestion.kind)
        if score < 0.7, !muscles.fatiguedTargets(of: content, kind: suggestion.kind).isEmpty,
           fresherAlternative(to: suggestion, score: score) == nil {
            return "Muscles \(Int((score * 100).rounded())) % ready – recovery is training too (\(more))."
        }
        return nil
    }

    /// A short routine for the time of day, started like any template.
    private func stretchInstead() {
        let hour = Calendar.current.component(.hour, from: Date())
        let id = hour < 11 ? "morning-mobility" : (hour >= 19 ? "evening-wind-down" : "hip-openers")
        guard let routine = RoutineLibrary.routine(id: id) ?? RoutineLibrary.all.first else { return }
        let result = store.templateForRoutine(routine, catalog: library.catalog)
        live.requestStart(.template(result.template))
    }

    // MARK: Energy forecast

    @ViewBuilder
    private var energyForecast: some View {
        if live.session == nil, let low = store.expectedLowEnergyDay(within: 3) {
            Button {
                showPlanWeek = true
            } label: {
                // A tendency, not a forecast: "Energy often dips around Wed – plan it lighter?"
                let day = store.shortDay(low)
                let when = day == "today" || day == "tomorrow" ? day : "around \(day)"
                Label("Energy often dips \(when) – plan it lighter?", systemImage: "battery.25percent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tone.cautionText)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        }
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
                        store.requestStart(fresher.template, live: live, toasts: toasts)
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
        let others = (store.activeProgram?.orderedTemplates ?? []).filter { $0.id != suggestion.id && $0.isPlannable }
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
        // Empty templates (just created) aren't offered as a quick start.
        let others = (store.activeProgram?.orderedTemplates ?? []).filter { $0.id != suggestion.id && $0.isPlannable }
        if !others.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(others) { template in
                        Button {
                            store.requestStart(template, live: live, toasts: toasts)
                        } label: {
                            Label(template.name, systemImage: "play.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}
