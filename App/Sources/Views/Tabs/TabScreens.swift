import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Workouts tab: every logged and planned workout, filtered by a segmented control.
struct WorkoutsTabView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        SessionListView(
            scope: router.workoutsFilter.scope,
            programHeader: AnyView(
                Picker("Show", selection: $router.workoutsFilter) {
                    ForEach(WorkoutsFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.vertical, 4)
            ),
            title: "Workouts"
        )
    }
}

/// Plans tab: the active program up front, all programs, templates and the exercise library.
struct PlansView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @Query private var templates: [WorkoutTemplate]
    @State private var showArchived = false
    @State private var editingProgram: Program?
    @State private var programToDelete: Program?

    var body: some View {
        let _ = store.revision
        List {
            if let active = store.activeProgram {
                Section {
                    ActiveProgramCard(program: active)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                ForEach(visiblePrograms) { program in
                    ScreenLink(.program(program.id)) {
                        ProgramRow(program: program, isActive: store.settings.activeProgramID == program.id)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { programToDelete = program } label: { Label("Delete", systemImage: "trash") }
                        Button { editingProgram = program } label: { Label("Edit", systemImage: "pencil") }
                            .tint(.indigo)
                    }
                    .swipeActions(edge: .leading) {
                        Button { store.setActive(program) } label: { Label("Set Active", systemImage: "star") }
                            .tint(.orange)
                    }
                    .contextMenu { menu(for: program) }
                }
                Button {
                    router.showNewProgram = true
                } label: {
                    Label("New Program", systemImage: "folder.badge.plus")
                }
            } header: {
                HStack {
                    Text("Programs")
                    Spacer()
                    if programs.contains(where: \.isArchived) {
                        Button(showArchived ? "Hide Archived" : "Show Archived") { showArchived.toggle() }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text("A program is a folder of templates (your reusable workouts). The active program drives “Up next”.")
            }

            Section("Library") {
                ScreenLink(.templates) {
                    HStack {
                        Label("All Templates", systemImage: "square.on.square")
                        Spacer()
                        Text("\(templates.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                ScreenLink(.library) {
                    Label("Exercise Library", systemImage: "books.vertical")
                }
                Button {
                    router.showImport = true
                } label: {
                    Label("Import CSV…", systemImage: "square.and.arrow.down")
                }
            }
        }
        .groupedList()
        .navigationTitle("Plans")
        .toolbar {
            ToolbarItem(placement: .georgeTrailing) {
                Menu {
                    Button { router.request(.newTemplate) } label: { Label("New Template", systemImage: "square.on.square") }
                    Button { router.showNewProgram = true } label: { Label("New Program", systemImage: "folder.badge.plus") }
                    Divider()
                    Button { router.showImport = true } label: { Label("Import CSV…", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if programs.isEmpty {
                EmptyStateView(
                    title: "No Programs Yet",
                    message: "Programs hold your templates, like “Gym – Hypertrophy” or “Bands – Tennis”.",
                    symbol: "square.stack.3d.up",
                    createTitle: "New Program",
                    onCreate: { router.showNewProgram = true },
                    onImport: { router.showImport = true }
                )
            }
        }
        .sheet(item: $editingProgram) { program in
            NavigationStack { ProgramEditorSheet(program: program) }
        }
        .confirmationDialog(
            "Delete “\(programToDelete?.name ?? "")”?",
            isPresented: Binding(get: { programToDelete != nil }, set: { if !$0 { programToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Program and Templates", role: .destructive) {
                if let programToDelete { store.trash(programToDelete, toasts: toasts) }
                programToDelete = nil
            }
        } message: {
            Text("Templates are deleted. Logged workouts are kept under Workouts.")
        }
    }

    private var visiblePrograms: [Program] {
        programs
            .filter { showArchived || !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.sortIndex < rhs.sortIndex
            }
    }

    @ViewBuilder
    private func menu(for program: Program) -> some View {
        Button { store.setActive(program) } label: { Label("Set as Active Program", systemImage: "star") }
        Button { editingProgram = program } label: { Label("Edit…", systemImage: "pencil") }
        Button {
            program.isPinned.toggle()
            store.save()
        } label: { Label(program.isPinned ? "Unpin" : "Pin", systemImage: "pin") }
        Button {
            let copy = store.duplicate(program)
            router.show(.program(copy.id))
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button {
            program.isArchived.toggle()
            store.save()
        } label: { Label(program.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") }
        Divider()
        Button(role: .destructive) { programToDelete = program } label: { Label("Delete…", systemImage: "trash") }
    }
}

struct ProgramRow: View {
    let program: Program
    var isActive = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: program.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(hex: program.colorHex))
                .frame(width: 36, height: 36)
                .background(Color(hex: program.colorHex).opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(program.name).font(.headline).lineLimit(1)
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    if program.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("\(program.templates?.count ?? 0) templates · \(program.performedSessions.count) workouts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(program.isArchived ? 0.5 : 1)
        .padding(.vertical, 2)
    }
}

/// The active program with its templates as start-able cards.
struct ActiveProgramCard: View {
    let program: Program
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        let tint = Color(hex: program.colorHex)
        let calendar = store.calendar
        let thisWeek = program.performedSessions.filter { calendar.weekStart(for: $0.date) == calendar.weekStart(for: Date()) }.count
        VStack(alignment: .leading, spacing: 14) {
            Button {
                router.show(.program(program.id))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: program.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ACTIVE PROGRAM")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(program.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(thisWeek) of \(store.settings.weeklyGoal) workouts this week")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let templates = program.orderedTemplates
            if templates.isEmpty {
                Button {
                    router.request(.newTemplate)
                } label: {
                    Label("Add the first template", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(templates) { template in
                            TemplateCard(template: template)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
        }
        .padding(16)
        .card(padding: 0, cornerRadius: 26)
    }
}

/// Small card: tap to open, ▶︎ to start.
struct TemplateCard: View {
    let template: WorkoutTemplate
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        let tint = Color(hex: template.displayColorHex)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: template.kind.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                Button {
                    live.start(template: template)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(live.isActive)
                .accessibilityLabel("Start \(template.name)")
            }
            Text(template.name.isEmpty ? "Untitled" : template.name)
                .font(.headline)
                .lineLimit(1)
            Text(template.subtitle.isEmpty ? template.summaryLine : template.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(width: 168, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { router.open(.template(template.id)) }
    }
}

/// Insights tab: Muscles, Progress (stats & records) and Streak behind one segmented control.
struct InsightsView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        Group {
            switch router.insights {
            case .muscles: MusclesView()
            case .progress: StatsView()
            case .energy: EnergyView()
            case .streak: StreakView()
            }
        }
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Insights", selection: $router.insights) {
                    ForEach(InsightsSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
        }
    }
}

/// Search tab: everything at once — workouts, templates, programs and exercises. Browses when empty.
struct SearchView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library
    @Query private var sessions: [WorkoutSession]
    @Query private var templates: [WorkoutTemplate]
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @Query private var customExercises: [UserExercise]
    @State private var query = ""

    var body: some View {
        let words = query.lowercased().split(separator: " ").map(String.init)
        List {
            if words.isEmpty {
                Section("Browse") {
                    ScreenLink(.library) { Label("Exercise Library", systemImage: "books.vertical.fill") }
                    ScreenLink(.templates) { Label("All Templates", systemImage: "square.on.square.fill") }
                    ScreenLink(.planned) { Label("Planned Workouts", systemImage: "calendar") }
                    ScreenLink(.favorites) { Label("Favorites", systemImage: "star.fill") }
                }
                let kinds = Array(Set(sessions.map(\.kind))).sorted()
                if !kinds.isEmpty {
                    Section("Workouts by Type") {
                        ForEach(kinds) { kind in
                            ScreenLink(.kind(kind.rawValue)) {
                                Label {
                                    Text(kind.displayName)
                                } icon: {
                                    Image(systemName: kind.symbol).foregroundStyle(kind.color)
                                }
                            }
                        }
                    }
                }
            } else {
                let matchingSessions = sessions
                    .filter { matches([$0.title, $0.subtitle, $0.notes, $0.exerciseNames, $0.tagsRaw], words) }
                    .sorted { $0.date > $1.date }
                    .prefix(8)
                let matchingTemplates = templates.filter { matches([$0.name, $0.subtitle, $0.notes, $0.exerciseNames, $0.tagsRaw], words) }.prefix(8)
                let matchingPrograms = programs.filter { matches([$0.name, $0.subtitle, $0.notes], words) }.prefix(5)
                let exercises = library.search(query, kind: nil, muscle: nil, equipment: nil, custom: customExercises).prefix(15)

                if !matchingTemplates.isEmpty {
                    Section("Templates") {
                        ForEach(Array(matchingTemplates)) { template in
                            DetailLink(.template(template.id)) { TemplateRow(template: template, showProgram: true) }
                        }
                    }
                }
                if !matchingSessions.isEmpty {
                    Section("Workouts") {
                        ForEach(Array(matchingSessions)) { session in
                            DetailLink(.session(session.id)) { SessionRow(session: session, showProgram: true) }
                        }
                    }
                }
                if !matchingPrograms.isEmpty {
                    Section("Programs") {
                        ForEach(Array(matchingPrograms)) { program in
                            ScreenLink(.program(program.id)) { ProgramRow(program: program) }
                        }
                    }
                }
                if !exercises.isEmpty {
                    Section("Exercises") {
                        ForEach(Array(exercises)) { exercise in
                            DetailLink(.exercise(exercise.id)) {
                                HStack(spacing: 12) {
                                    ExerciseThumb(urls: library.imageURLs(for: exercise), symbol: exercise.displaySymbol, tint: exercise.kind.color, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(exercise.name).font(.body.weight(.medium)).lineLimit(1)
                                        Text([exercise.kind.shortName, exercise.primary.first?.capitalized].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Workouts, templates, exercises")
        .overlay {
            if !words.isEmpty && noResults(words) {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func matches(_ fields: [String], _ words: [String]) -> Bool {
        let haystack = fields.joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    private func noResults(_ words: [String]) -> Bool {
        !sessions.contains { matches([$0.title, $0.subtitle, $0.notes, $0.exerciseNames, $0.tagsRaw], words) }
            && !templates.contains { matches([$0.name, $0.subtitle, $0.notes, $0.exerciseNames, $0.tagsRaw], words) }
            && !programs.contains { matches([$0.name, $0.subtitle, $0.notes], words) }
            && library.search(query, kind: nil, muscle: nil, equipment: nil, custom: customExercises).isEmpty
    }
}
