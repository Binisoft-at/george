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
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var didLoad = false

    struct Row: Identifiable {
        var id: Date { date }
        var date: Date
        var choice: Choice
        var isOn = true
        var isLowEnergyDay = false
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
                        Text("Templates go on their usual weekdays; without weekdays George spreads the rotation over your weekly goal (\(store.settings.weeklyGoal) days). Days that already have a workout stay as they are.")
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
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
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
                if value.isLowEnergyDay {
                    Label("Low energy expected – lighter", systemImage: "battery.25percent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Tone.cautionText)
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
                    row.wrappedValue.choice = .template(template.id)
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
                    row.wrappedValue.choice = .routine(routine.id)
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
        let templates = store.activeProgram?.orderedTemplates ?? []
        // On the low day: an easy template of the program if there is one, else a mobility routine.
        let lighter: Choice = templates.first(where: { $0.kind.isFlow }).map { Choice.template($0.id) } ?? Choice.routine("morning-mobility")
        rows = store.proposeWeek().map { day in
            Row(date: day.date, choice: day.isLowEnergyDay ? lighter : .template(day.templateID), isLowEnergyDay: day.isLowEnergyDay)
        }
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
