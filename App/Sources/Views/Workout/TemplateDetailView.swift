import SwiftUI
import BinisoftKit
import TipKit
import SwiftData
import GeorgeCore

struct TemplateDetailView: View {
    let templateID: UUID
    @Query private var matches: [WorkoutTemplate]

    init(templateID: UUID) {
        self.templateID = templateID
        _matches = Query(filter: #Predicate<WorkoutTemplate> { $0.id == templateID })
    }

    var body: some View {
        if let template = matches.first {
            TemplateDocument(template: template)
        } else {
            MessageView(title: "Template not found", systemImage: "questionmark.square.dashed")
        }
    }
}

private struct TemplateDocument: View {
    @Bindable var template: WorkoutTemplate
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live
    /// Set on the tour's practice page: Start is only recorded there.
    @Environment(PracticeSession.self) private var practice: PracticeSession?
    @Environment(Router.self) private var router
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @Query private var allSessions: [WorkoutSession]
    @State private var content = WorkoutContent()
    @State private var loadedData: Data?
    @State private var editor = EditorState()
    @State private var logPast: WorkoutTemplate?
    @State private var shareRoutine = false
    @State private var planDate = Date()
    @State private var showPlan = false
    @State private var showDetails = false

    var body: some View {
        List {
            headerSection
            if !content.isEmpty {
                TipView(GeorgeTips.EditorTip())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            WorkoutEditorSections(content: $content, mode: .template, defaultKind: template.kind, state: editor)
            MuscleTargetsSection(content: content, kind: template.kind)
            Section("Notes") {
                TextField("Goals, cues, progression rules…", text: $template.notes, axis: .vertical)
                    .lineLimit(3...12)
            }
            historySection
        }
        .groupedList()
        .safeAreaInset(edge: .bottom) { actionBar }
        .workoutEditorSheets(content: $content, mode: .template, defaultKind: template.kind, state: editor)
        .navigationTitle(template.name.isEmpty ? "Template" : template.name)
        .inlineTitle()
        .toolbar { toolbarItems }
        .sheet(isPresented: $shareRoutine) {
            RoutineShareSheet(template: template)
        }
        .onAppear(perform: load)
        .task {
            // A template created a moment ago: go straight to picking exercises.
            guard router.pickExercisesFor == template.id else { return }
            router.pickExercisesFor = nil
            showDetails = true
            try? await Task.sleep(nanoseconds: 450_000_000)
            editor.showPicker = true
        }
        .onChange(of: template.contentData) { _, newData in
            if newData != loadedData { load() }
        }
        .onChange(of: content) { _, newContent in
            guard newContent != template.content else { return }
            template.content = newContent
            loadedData = template.contentData
            store.save()
        }
        .sheet(item: $logPast) { template in
            NavigationStack { LogPastWorkoutSheet(template: template) }
        }
        .sheet(isPresented: $showPlan) {
            NavigationStack {
                Form {
                    DatePicker("Date", selection: $planDate, displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                }
                .navigationTitle("Plan \(template.name)")
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPlan = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Plan") {
                            let session = store.makeSession(from: template, date: planDate, start: false)
                            showPlan = false
                            router.open(.session(session.id))
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    private func load() {
        content = template.content
        loadedData = template.contentData
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name (e.g. UPPER)", text: $template.name)
                    .font(.title2.weight(.bold))
                TextField("Focus (e.g. UPPER BODY + SHOULDER/WRIST HEALTH)", text: $template.subtitle, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                kindMenu
                                programMenu
                                priorityMenu
                                colorMenu
                            }
                        }
                        WeekdayPicker(selection: Binding(get: { template.scheduleDays }, set: { template.scheduleDays = $0; store.save() }))
                        TagEditor(tags: Binding(get: { template.tags }, set: { template.tags = $0; store.save() }))
                    }
                    .padding(.top, 6)
                } label: {
                    Text(detailsSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var detailsSummary: String {
        var parts = [template.kind.displayName, template.program?.name ?? "No program"]
        if !template.scheduleDays.isEmpty { parts.append(DateLabel.weekdayNames(template.scheduleDays)) }
        if template.priority != .none { parts.append(template.priority.displayName) }
        return parts.joined(separator: " · ")
    }

    private var kindMenu: some View {
        Menu {
            ForEach(WorkoutKind.presets) { kind in
                Button {
                    template.kind = kind
                    store.save()
                } label: { Label(kind.displayName, systemImage: kind.symbol) }
            }
        } label: {
            KindBadge(kind: template.kind, compact: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var programMenu: some View {
        Menu {
            ForEach(programs) { program in
                Button {
                    store.move([template], to: program)
                } label: { Label(program.name, systemImage: program.symbol) }
            }
        } label: {
            Chip(text: template.program?.name ?? "No Program", systemImage: "folder", tint: template.program.map { Color(hex: $0.colorHex) } ?? .secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(Priority.allCases) { priority in
                Button {
                    template.priority = priority
                    store.save()
                } label: { Label(priority.displayName, systemImage: priority.symbol) }
            }
        } label: {
            Chip(text: template.priority == .none ? "Priority" : template.priority.displayName, systemImage: template.priority.symbol, tint: template.priority.color)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var colorMenu: some View {
        Menu {
            Button("Default (\(template.kind.displayName))") { template.colorHex = nil; store.save() }
            ForEach(colorChoices, id: \.self) { hex in
                Button {
                    template.colorHex = hex
                    store.save()
                } label: {
                    Label(hex, systemImage: template.colorHex == hex ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: {
            Chip(text: "Color", systemImage: "paintpalette", tint: Color(hex: template.displayColorHex))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    /// Start / Plan / Log, always reachable at the bottom.
    private var actionBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if let practice { practice.startTapped = true } else { live.start(template: template) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
                .disabled(practice == nil && live.isActive)
                .keyboardShortcut(.return, modifiers: .command)
                Button {
                    planDate = Date()
                    showPlan = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                        .font(.headline)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Plan for a day")
                Button {
                    logPast = template
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.headline)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Log a past workout")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let history = allSessions
            .filter { $0.templateID == template.id && $0.status.isPerformed }
            .sorted { $0.date > $1.date }
        if !history.isEmpty {
            Section("History · \(history.count)") {
                ForEach(history.prefix(10)) { session in
                    Button {
                        router.open(.session(session.id))
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .georgeTrailing) {
            Button {
                shareRoutine = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share routine")
            Menu {
                TemplateMenuItems(template: template, logPastFor: $logPast)
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }
}

/// Mon–Sun toggles for a template's usual days.
struct WeekdayPicker: View {
    @Binding var selection: [Int]
    private let order = [2, 3, 4, 5, 6, 7, 1]
    private let letters = ["", "S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .font(.caption)
            ForEach(order, id: \.self) { day in
                let isOn = selection.contains(day)
                Button {
                    if isOn { selection.removeAll { $0 == day } } else { selection.append(day) }
                } label: {
                    Text(letters[day])
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(isOn ? Color.white : Color.secondary)
                        .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("Usual training days")
    }
}
