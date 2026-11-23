import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Planned workouts from the last week that weren't done: one slim row each, "Do today" or "Skip".
/// They never take Today's hero – only today's plan does.
struct MissedPlansCard: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        // Saved changes move the revision (a running workout's sets don't: no refetch on every tick).
        let _ = store.revision
        let missed = store.overdueSessions(limit: 3)
        if !missed.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(missed.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().padding(.leading, 48) }
                    row(session)
                }
            }
            .card(padding: 0, cornerRadius: 20)
        }
    }

    private func row(_ session: WorkoutSession) -> some View {
        HStack(spacing: 10) {
            Button {
                router.open(.session(session.id))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    // The name on its own line: next to Do today, ▶ and Skip, one line with the
                    // date first cut the name off on an iPhone.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.displayName(of: session))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(line(for: session))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // "Do today" moves the plan to today (Today's hero then offers Start); ▶ starts it right away.
            Button("Do today") {
                moveToToday(session)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.glass)
            Button {
                live.requestStart(.session(session))
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Start \(store.displayName(of: session)) now")
            Button("Skip") {
                skip(session)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// "Missed · Tue 10.11" (under the name)
    private func line(for session: WorkoutSession) -> String {
        let date = store.plannedDay(of: session)
        let calendar = store.calendar
        let day = String(format: "%02d.%02d", calendar.component(.day, from: date), calendar.component(.month, from: date))
        return "Missed · \(date.formatted(.dateTime.weekday(.abbreviated))) \(day)"
    }

    /// Moves the missed plan to today (same time of day, an automatic title follows the date). Undo
    /// puts it back on its day.
    private func moveToToday(_ session: WorkoutSession) {
        let name = store.displayName(of: session)
        let calendar = store.calendar
        let oldPlanned = session.plannedDate
        let oldTitle = session.title
        let previousDate = session.date
        let day = store.plannedDay(of: session)
        session.plannedDate = calendar.addingDays(calendar.daysBetween(day, Date()), to: day)
        store.retitleIfAuto(session, previousDate: previousDate)
        store.save()
        Haptics.success()
        toasts.show("Moved \(name) to today", symbol: "calendar") {
            session.plannedDate = oldPlanned
            session.title = oldTitle
            store.save()
        }
    }

    private func skip(_ session: WorkoutSession) {
        let name = store.displayName(of: session)
        store.setStatus(.skipped, for: [session])
        Haptics.tap()
        toasts.show("Skipped \(name)", symbol: "forward.fill") {
            session.status = .planned
            store.save()
        }
    }
}

/// After an update with new tour steps: a card on Today that offers them – never a full-screen
/// tour that pops up by itself (maybe in the middle of the gym).
struct WhatsNewCard: View {
    @Environment(Router.self) private var router
    @State private var dismissed = false

    var body: some View {
        let schedule = TourSchedule()
        let steps = schedule.seenVersion > 0 ? schedule.stepsToOffer(GeorgeTour.catalog) : []
        if !dismissed && !steps.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in George")
                        .font(.headline)
                    Text("A short tour of what changed – about a minute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Show Me") {
                    dismissed = true
                    router.tour = TourRequest(steps: steps, startAt: nil)
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glassProminent)
                Button {
                    TourSchedule().markSeen(GeorgeTour.catalog)
                    withAnimation(.snappy) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(14)
            .card(padding: 0, cornerRadius: 22)
        }
    }
}

/// Streak rescue: the three ready-made routines closest to the rescue length – one tap starts it.
struct RescueSheet: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let minutes = store.settings.rescueMinutes
        let routines = RoutineLibrary.closest(toMinutes: minutes, count: 3, catalog: library.catalog)
        NavigationStack {
            List {
                Section {
                    ForEach(routines) { routine in
                        Button {
                            start(routine)
                        } label: {
                            HStack {
                                RoutineRow(routine: routine, content: routine.content(using: library.catalog))
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.orange)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("About \(minutes) minutes")
                } footer: {
                    Text("A rescue workout counts double, once a week. Any of these is enough – George starts it right away.")
                }
                Section {
                    Button {
                        let program = store.activeProgram
                        dismiss()
                        router.afterDismiss { live.requestStart(.empty(program: program, kind: .mobility, rescue: true)) }
                    } label: {
                        Label("Empty Rescue Workout", systemImage: "plus.square.dashed")
                    }
                } footer: {
                    Text("Add exercises as you go – a short band circuit works too.")
                }
            }
            .groupedList()
            .navigationTitle("Rescue Workout")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .macSheet(width: 520, height: 560)
    }

    private func start(_ routine: Routine) {
        let template = store.templateForRoutine(routine, catalog: library.catalog).template
        store.pendingRescue = (templateID: template.id, at: Date())
        dismiss()
        router.afterDismiss { live.requestStart(.template(template)) }
    }
}
