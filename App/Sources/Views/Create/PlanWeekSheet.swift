import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// "Plan this week": the next 7 days with the active program's templates on their weekdays (or the
/// rotation spread over the weekly goal), days that already have a workout left free, the expected
/// low-energy day marked "lighter". One button plans them all; the toast can undo it.
struct PlanWeekSheet: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(HealthKitManager.self) private var health
    @Environment(\.dismiss) private var dismiss
    /// Opened from Today's energy hint: the low-energy day starts with the lighter choice (and still
    /// says what it replaced). Otherwise the lighter choice is only offered.
    var preferLighter = false
    @State private var rows: [Row] = []
    @State private var didLoad = false
    /// Days in the next weeks that already have a workout (moving a template skips them).
    @State private var busyDays: Set<Date> = []

    struct Row: Identifiable {
        var id: Date { date }
        var date: Date
        var choice: Choice
        var isOn = true
        var isLowEnergyDay = false
        /// The template George proposed for the day – what another choice replaces.
        var proposedTemplateID: UUID? = nil
        /// The proposed template was moved to this day (a row was added there).
        var movedTo: Date? = nil
        /// Added by "Move LOWER to Fri" (taken away again when the original day gets LOWER back).
        var isMoved = false
    }

    enum Choice: Hashable {
        case template(UUID)
        case routine(String)
    }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Section {
                        Label(emptyMessage, systemImage: "calendar.badge.checkmark")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach($rows) { $row in
                            rowView($row)
                        }
                    } header: {
                        Text(store.activeProgram.map { "Next 7 days · \($0.name)" } ?? "Next 7 days")
                    } footer: {
                        Text("Templates go on their usual weekdays; the others fill up your weekly goal (\(store.settings.weeklyGoal) days), counting the days already trained or planned. Days that already have a workout stay as they are.")
                    }
                }
                let upcoming = store.upcomingSessions(limit: 7)
                if !upcoming.isEmpty {
                    Section("Already planned") {
                        ForEach(upcoming) { session in
                            HStack(spacing: 12) {
                                DayBadge(date: store.plannedDay(of: session))
                                Text(store.displayName(of: session))
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                            }
                        }
                    }
                }
            }
            .groupedList()
            .navigationTitle("Plan This Week")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !rows.isEmpty {
                    Button {
                        plan()
                    } label: {
                        Label(planTitle, systemImage: "calendar.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(selectedCount == 0)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 560)
                }
            }
            .onAppear(perform: load)
        }
        .macSheet(width: 520, height: 600)
    }

    private func rowView(_ row: Binding<Row>) -> some View {
        let value = row.wrappedValue
        return HStack(spacing: 12) {
            DayBadge(date: value.date)
            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    choices(for: row)
                } label: {
                    HStack(spacing: 4) {
                        Text(name(of: value.choice))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                if let replaced = replacedName(value) {
                    // Never a silent swap: what the day had, and a way to keep it in the week.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(replacedLine(value, replaced: replaced))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if value.movedTo == nil, let free = nextFreeDay(after: value.date) {
                            Button("Move \(replaced) to \(store.shortDay(free))") {
                                moveProposed(from: value.date, to: free)
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .lineLimit(1)
                        }
                    }
                } else if value.isLowEnergyDay {
                    HStack(spacing: 6) {
                        Label("Low energy expected", systemImage: "battery.25percent")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Tone.cautionText)
                            .lineLimit(1)
                        if lighterChoice != value.choice {
                            Button("Make it lighter") {
                                setChoice(lighterChoice, for: value.date)
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .lineLimit(1)
                        }
                    }
                } else {
                    Text(detail(of: value.choice))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Toggle("Plan", isOn: row.isOn)
                .labelsHidden()
        }
        .opacity(value.isOn ? 1 : 0.5)
    }

    @ViewBuilder
    private func choices(for row: Binding<Row>) -> some View {
        let templates = store.activeProgram?.orderedTemplates ?? []
        Section(store.activeProgram?.name ?? "Templates") {
            ForEach(templates) { template in
                Button {
                    setChoice(.template(template.id), for: row.wrappedValue.date)
                } label: {
                    if row.wrappedValue.choice == .template(template.id) {
                        Label(template.name, systemImage: "checkmark")
                    } else {
                        Text(template.name)
                    }
                }
            }
        }
        Section("Lighter: Stretch & Yoga") {
            ForEach(RoutineLibrary.all) { routine in
                Button {
                    setChoice(.routine(routine.id), for: row.wrappedValue.date)
                } label: {
                    Label(routine.name, systemImage: row.wrappedValue.choice == .routine(routine.id) ? "checkmark" : routine.symbol)
                }
            }
        }
    }

    // MARK: Data

    private var selectedCount: Int { rows.filter(\.isOn).count }

    private var planTitle: String {
        selectedCount == 1 ? "Plan 1 Workout" : "Plan \(selectedCount) Workouts"
    }

    private var emptyMessage: String {
        guard let program = store.activeProgram, !program.orderedTemplates.isEmpty else {
            return "Add templates to your active program first – then George can spread them over the week."
        }
        return "Nothing to add: the coming days are planned already, or this week's goal is met."
    }

    private func name(of choice: Choice) -> String {
        switch choice {
        case .template(let id): return store.template(id: id)?.name ?? "Workout"
        case .routine(let id): return RoutineLibrary.routine(id: id)?.name ?? "Routine"
        }
    }

    private func detail(of choice: Choice) -> String {
        switch choice {
        case .template(let id):
            guard let template = store.template(id: id) else { return "" }
            return template.subtitle.isEmpty ? template.summaryLine : template.subtitle
        case .routine(let id):
            return RoutineLibrary.routine(id: id)?.subtitle ?? ""
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let calendar = store.calendar
        let today = calendar.startOfDay(for: Date())
        let horizon = calendar.addingDays(14, to: today)
        busyDays = Set(store.fetchSessions().filter { $0.status != .skipped }.map { session in
            calendar.startOfDay(for: session.status == .planned ? store.plannedDay(of: session) : session.date)
        }.filter { $0 >= today && $0 < horizon })
        let lighter = lighterChoice
        // The days already trained this week count like the streak (Health workouts included when on).
        rows = store.proposeWeek(healthEntries: health.externalWorkouts).map { day in
            // The low-energy day keeps its template unless the sheet was opened from Today's energy hint.
            let choice: Choice = day.isLowEnergyDay && preferLighter ? lighter : .template(day.templateID)
            return Row(date: day.date, choice: choice, isLowEnergyDay: day.isLowEnergyDay, proposedTemplateID: day.templateID)
        }
    }

    /// On the low day: an easy template of the program if there is one, else a mobility routine.
    private var lighterChoice: Choice {
        let templates = store.activeProgram?.orderedTemplates ?? []
        return templates.first(where: { $0.kind.isFlow }).map { Choice.template($0.id) } ?? Choice.routine("morning-mobility")
    }

    /// The proposed template's name when the day has something else now ("Instead of LOWER").
    private func replacedName(_ row: Row) -> String? {
        guard let proposed = row.proposedTemplateID, row.choice != .template(proposed) else { return nil }
        return store.template(id: proposed)?.name
    }

    /// "Instead of LOWER", "Low energy · instead of LOWER · moved to Fri".
    private func replacedLine(_ row: Row, replaced: String) -> String {
        var line = row.isLowEnergyDay ? "Low energy · instead of \(replaced)" : "Instead of \(replaced)"
        if let moved = row.movedTo { line += " · moved to \(store.shortDay(moved))" }
        return line
    }

    /// The first day after `date` (within a week) with nothing planned or done and no row in the sheet.
    private func nextFreeDay(after date: Date) -> Date? {
        let calendar = store.calendar
        for offset in 1...7 {
            let day = calendar.addingDays(offset, to: calendar.startOfDay(for: date))
            if !busyDays.contains(day) && !rows.contains(where: { calendar.isDate($0.date, inSameDayAs: day) }) { return day }
        }
        return nil
    }

    /// Changes a day's choice. Taking the proposed template back also takes back its move.
    private func setChoice(_ choice: Choice, for date: Date) {
        guard let index = rows.firstIndex(where: { $0.date == date }) else { return }
        rows[index].choice = choice
        if let proposed = rows[index].proposedTemplateID, choice == .template(proposed), let moved = rows[index].movedTo {
            rows.removeAll { $0.date == moved && $0.isMoved }
            rows[index].movedTo = nil
        }
    }

    /// "Move LOWER to Fri": the proposed template goes on a free day, so the week keeps its leg day.
    private func moveProposed(from date: Date, to day: Date) {
        guard let index = rows.firstIndex(where: { $0.date == date }), let proposed = rows[index].proposedTemplateID else { return }
        rows[index].movedTo = day
        var moved = Row(date: day, choice: .template(proposed), proposedTemplateID: proposed)
        moved.isMoved = true
        rows.append(moved)
        rows.sort { $0.date < $1.date }
    }

    private func plan() {
        var entries: [(date: Date, template: WorkoutTemplate)] = []
        for row in rows where row.isOn {
            switch row.choice {
            case .template(let id):
                if let template = store.template(id: id) { entries.append((row.date, template)) }
            case .routine(let id):
                if let routine = RoutineLibrary.routine(id: id) {
                    entries.append((row.date, store.templateForRoutine(routine, catalog: library.catalog).template))
                }
            }
        }
        let sessions = store.planWeek(entries)
        Haptics.success()
        let message = sessions.count == 1 ? "Planned 1 workout" : "Planned \(sessions.count) workouts"
        toasts.show(message, symbol: "calendar.badge.checkmark") {
            store.removePlanned(sessions)
        }
        dismiss()
    }
}
