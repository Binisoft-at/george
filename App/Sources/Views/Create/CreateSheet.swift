import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Steps of the create sheet that can be opened directly (e.g. from Today's quick actions).
enum CreateStep: Hashable {
    case start
    case plan
    case logPast
    case logPastTemplate(UUID)
    case newTemplate
}

/// One place to create anything: start, plan or log a workout, new templates and programs, CSV import.
struct WorkoutCreateSheet: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State private var path: [CreateStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        CreateTile(title: "Start Workout", subtitle: "Right now, from a template or empty", symbol: "play.fill", tint: .accentColor) {
                            path.append(.start)
                        }
                        CreateTile(title: "Plan Workout", subtitle: "Put a template on a day", symbol: "calendar.badge.plus", tint: .indigo) {
                            path.append(.plan)
                        }
                        CreateTile(title: "New Template", subtitle: "A reusable workout like UPPER", symbol: "square.on.square.fill", tint: .orange) {
                            path.append(.newTemplate)
                        }
                        CreateTile(title: "Log Past Workout", subtitle: "Something you already did", symbol: "clock.arrow.circlepath", tint: .teal) {
                            path.append(.logPast)
                        }
                    }

                    VStack(spacing: 0) {
                        CreateRow(title: "Empty Workout Now", subtitle: "Add exercises as you go", symbol: "bolt.fill", tint: .accentColor) {
                            let program = store.activeProgram
                            dismiss()
                            router.afterDismiss { live.startEmpty(program: program) }
                        }
                        Divider().padding(.leading, 56)
                        CreateRow(title: "New Program", subtitle: "A folder of templates, e.g. a training block", symbol: "folder.badge.plus", tint: .blue) {
                            dismiss()
                            router.afterDismiss { router.showNewProgram = true }
                        }
                        Divider().padding(.leading, 56)
                        CreateRow(title: "Import CSV", subtitle: "A plan from a spreadsheet or an AI chat", symbol: "square.and.arrow.down", tint: .purple) {
                            dismiss()
                            router.afterDismiss { router.showImport = true }
                        }
                    }
                    .card(padding: 0, cornerRadius: 22)

                    Label("Tip: templates live in programs. Start one and George names the workout for you, e.g. “W44: 3 UPPER - 31.10”.", systemImage: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(BrandBackdrop())
            .navigationTitle("Create")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(for: CreateStep.self) { step in
                switch step {
                case .start:
                    TemplateChooser(title: "Start Workout", emptyTitle: "Empty Workout") { template in
                        let program = store.activeProgram
                        dismiss()
                        router.afterDismiss {
                            if let template { live.start(template: template) } else { live.startEmpty(program: program) }
                        }
                    }
                case .plan:
                    PlanWorkoutView { session in
                        dismiss()
                        router.afterDismiss { router.open(.session(session.id)) }
                    }
                case .logPast:
                    TemplateChooser(title: "Log Past Workout", emptyTitle: nil) { template in
                        if let template { path.append(.logPastTemplate(template.id)) }
                    }
                case .logPastTemplate(let id):
                    if let template = store.template(id: id) {
                        LogPastWorkoutSheet(template: template) { dismiss() }
                    }
                case .newTemplate:
                    NewTemplateView { template in
                        dismiss()
                        router.afterDismiss {
                            router.pickExercisesFor = template.id
                            router.open(.template(template.id))
                        }
                    }
                }
            }
        }
        .onAppear {
            if let step = router.createStep {
                path = [step]
                router.createStep = nil
            }
        }
    }
}

private struct CreateTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 0, cornerRadius: 22)
    }
}

private struct CreateRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pick a template (active program first). `emptyTitle` adds an "empty workout" choice on top.
struct TemplateChooser: View {
    let title: String
    let emptyTitle: String?
    let onPick: (WorkoutTemplate?) -> Void

    @Environment(GeorgeStore.self) private var store
    @Query private var templates: [WorkoutTemplate]
    @State private var query = ""

    var body: some View {
        List {
            if let emptyTitle, query.isEmpty {
                Section {
                    Button {
                        onPick(nil)
                    } label: {
                        Label(emptyTitle, systemImage: "plus.square.dashed")
                            .font(.body.weight(.semibold))
                    }
                } footer: {
                    Text("Starts with nothing — add exercises as you go.")
                }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.templates) { template in
                        Button {
                            onPick(template)
                        } label: {
                            TemplateRow(template: template)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if templates.isEmpty {
                Section {
                    Text("No templates yet. Create one with “New Template”, or import a CSV.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .groupedList()
        .navigationTitle(title)
        .inlineTitle()
        .searchable(text: $query, prompt: "Search templates")
    }

    private struct TemplateGroup {
        var title: String
        var templates: [WorkoutTemplate]
    }

    private var groups: [TemplateGroup] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matching = templates.filter { template in
            guard !words.isEmpty else { return true }
            let haystack = [template.name, template.subtitle, template.exerciseNames, template.program?.name ?? ""].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        let activeID = store.activeProgram?.id
        let byProgram = Dictionary(grouping: matching) { $0.program?.id }
        var result: [TemplateGroup] = []
        if let activeID, let active = byProgram[activeID], !active.isEmpty {
            result.append(TemplateGroup(title: "\(store.activeProgram?.name ?? "Active") · active", templates: sorted(active)))
        }
        let others = byProgram
            .filter { $0.key != activeID }
            .map { (name: $0.value.first?.program?.name ?? "No Program", templates: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for other in others {
            result.append(TemplateGroup(title: other.name, templates: sorted(other.templates)))
        }
        return result
    }

    private func sorted(_ templates: [WorkoutTemplate]) -> [WorkoutTemplate] {
        templates.sorted { $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.createdAt < $1.createdAt }
    }
}

/// Plan a template (or an empty workout) for a day.
struct PlanWorkoutView: View {
    let onPlanned: (WorkoutSession) -> Void
    @Environment(GeorgeStore.self) private var store
    @Query private var templates: [WorkoutTemplate]
    @State private var date = Date()
    @State private var templateID: UUID?

    var body: some View {
        Form {
            Section {
                DatePicker("Day", selection: $date, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
            }
            Section("Workout") {
                Picker("Template", selection: $templateID) {
                    Text("Empty workout").tag(UUID?.none)
                    ForEach(templates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { template in
                        Text(template.program.map { "\(template.name) · \($0.name)" } ?? template.name).tag(Optional(template.id))
                    }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif
            }
        }
        .navigationTitle("Plan Workout")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Plan") {
                    let session: WorkoutSession
                    if let template = store.template(id: templateID) {
                        session = store.makeSession(from: template, date: date, start: false)
                    } else {
                        session = store.makeEmptySession(program: store.activeProgram, start: false, date: date)
                    }
                    Haptics.success()
                    onPlanned(session)
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            if templateID == nil { templateID = store.suggestedTemplate(in: store.activeProgram)?.id }
        }
    }
}

/// Name, type and program for a new template; exercises are picked right after.
struct NewTemplateView: View {
    let onCreate: (WorkoutTemplate) -> Void
    @Environment(GeorgeStore.self) private var store
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @State private var name = ""
    @State private var focus = ""
    @State private var kind: WorkoutKind = .gym
    @State private var programID: UUID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. UPPER", text: $name)
                    .font(.title3.weight(.semibold))
                    .focused($nameFocused)
                    .capitalizeCharacters()
                TextField("Focus (optional), e.g. UPPER BODY + SHOULDER HEALTH", text: $focus, axis: .vertical)
            } footer: {
                Text("Workouts started from it are named automatically, e.g. “W44: 3 \(name.isEmpty ? "UPPER" : name) - 31.10”.")
            }
            Section("Type") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(WorkoutKind.presets) { option in
                        Button {
                            kind = option
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: option.symbol).font(.title3)
                                Text(option.shortName).font(.caption.weight(.semibold)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(kind == option ? Color.white : option.color)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(kind == option ? option.color : option.color.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Program") {
                Picker("Program", selection: $programID) {
                    Text("No Program").tag(UUID?.none)
                    ForEach(programs.filter { !$0.isArchived }) { program in
                        Label(program.name, systemImage: program.symbol).tag(Optional(program.id))
                    }
                }
            }
        }
        .navigationTitle("New Template")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let template = store.createTemplate(in: store.program(id: programID), name: trimmed.isEmpty ? "New Workout" : trimmed, kind: kind)
                    template.subtitle = focus
                    store.save()
                    onCreate(template)
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            if programID == nil { programID = store.activeProgram?.id }
            kind = store.activeProgram?.kind ?? .gym
            nameFocused = true
        }
    }
}
