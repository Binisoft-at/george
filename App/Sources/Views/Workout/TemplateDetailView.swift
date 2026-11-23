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
    @Environment(ToastCenter.self) private var toasts
    @Environment(ThaliaSync.self) private var thalia: ThaliaSync?
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @State private var content = WorkoutContent()
    @State private var loadedData: Data?
    @State private var editor = EditorState()
    @State private var logPast: WorkoutTemplate?
    @State private var shareRoutine = false
    @State private var planDate = Date()
    @State private var showPlan = false
    @State private var showDetails = false
    @State private var showReorder = false
    /// Whether this device can read and edit the stored workout (see `StoredContent`).
    @State private var readState: StoredContent.ReadState = .readable
    /// On screen (not covered by a pushed screen): only then it's what ⌘↩ starts.
    @State private var isShown = false
    /// The workout as last loaded or written: an edit is compared with it, not with a fresh decode.
    @State private var lastSaved = WorkoutContent()
    /// Typed numbers not written yet: they're written once typing pauses (`editCount`), not per keystroke.
    @State private var pendingEdit: PendingEdit?
    /// Counts edits; the debounce task restarts with each one.
    @State private var editCount = 0
    /// Written without a revision bump: Today and the suggestions refresh once editing ends.
    @State private var needsRefresh = false
    @Environment(\.scenePhase) private var scenePhase

    /// An edit waiting to be written, with the template it belongs to (the list may switch to another).
    private struct PendingEdit {
        let template: WorkoutTemplate
        let content: WorkoutContent
    }

    /// ⌘↩ (Workout menu): "Start UPPER" while this template is shown – not on the tour's practice page.
    private var startCommand: StartCommand? {
        guard practice == nil else { return nil }
        let name = template.name.isEmpty ? "Template" : template.name
        return StartCommand(title: "Start \(name)", isEnabled: readState.isEditable) {
            commitEdits()
            store.requestStart(template, live: live, toasts: toasts)
        }
    }

    // Split in two so the compiler type-checks it in time.
    var body: some View {
        withSaving(mainList)
    }

    private var mainList: some View {
        List {
            headerSection
            if !content.isEmpty {
                TipView(GeorgeTips.EditorTip())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if readState.isEditable {
                WorkoutEditorSections(content: $content, mode: .template, defaultKind: template.kind, state: editor)
            } else {
                // "Can't read this workout" / "Update George on this device to edit" – never an empty editor.
                ReadOnlyContentSection(state: readState, content: content)
            }
            MuscleTargetsSection(content: content, kind: template.kind)
            Section("Notes") {
                TextField("Goals, cues, progression rules…", text: $template.notes, axis: .vertical)
                    .lineLimit(3...12)
            }
            historySection
            thaliaSection
        }
        .groupedList()
        .safeAreaInset(edge: .bottom) { actionBar }
        .workoutEditorSheets(content: $content, mode: .template, defaultKind: template.kind, state: editor)
        .navigationTitle(template.name.isEmpty ? "Template" : template.name)
        .inlineTitle()
        .toolbar { toolbarItems }
        .focusedSceneValue(\.startTarget, isShown ? startCommand : nil)
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
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
        .sheet(item: $logPast) { template in
            NavigationStack { LogPastWorkoutSheet(template: template) }
        }
        .sheet(isPresented: $showReorder) {
            ReorderBlocksSheet(content: $content)
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
                            // On top of the template (with Back on the Mac).
                            router.push(.session(session.id))
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    private func load() {
        content = template.content
        lastSaved = content
        loadedData = template.contentData
        readState = template.contentReadState
    }

    // MARK: Saving edits

    /// Edits are written once typing pauses (not on every keystroke) and saved without a revision
    /// bump; the bump comes once, when editing ends (leaving the screen or the app, Start, Plan …).
    private func withSaving(_ base: some View) -> some View {
        base
        .onChange(of: template.contentData) { _, newData in externalChange(newData) }
        .onChange(of: content) { _, newContent in contentEdited(newContent) }
        .task(id: editCount) {
            guard pendingEdit != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writePendingEdit()
        }
        .onChange(of: template.id) { _, _ in commitEdits() }
        .onDisappear { commitEdits() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { commitEdits() }
        }
    }

    /// External change (sync, an import, Update Template): reload unless it's our own write.
    private func externalChange(_ newData: Data?) {
        guard newData != loadedData else { return }
        if let edit = pendingEdit, edit.template !== template {
            // The list switched to another template: the one before keeps what was typed into it.
            writePendingEdit()
        } else {
            // This template changed elsewhere: that change wins, as it did when each keystroke was saved.
            pendingEdit = nil
        }
        load()
    }

    private func contentEdited(_ newContent: WorkoutContent) {
        guard readState.isEditable else { return }
        guard newContent != lastSaved else {
            // Typed back to what's stored: nothing to write.
            pendingEdit = nil
            return
        }
        pendingEdit = PendingEdit(template: template, content: newContent)
        editCount &+= 1
    }

    private func writePendingEdit() {
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        let target = edit.template
        // Deleted meanwhile: nothing to write.
        guard target.modelContext != nil, !target.isDeleted else { return }
        let isShownOne = target === template
        guard target.storeContent(edit.content) else {
            // Kept as stored (a newer George wrote it meanwhile): show what's there.
            if isShownOne { load() }
            return
        }
        if isShownOne {
            lastSaved = edit.content
            loadedData = target.contentData
        }
        store.save(bumping: false)
        needsRefresh = true
    }

    /// Writes what's waiting and lets Today and the suggestions catch up (one revision bump).
    private func commitEdits() {
        writePendingEdit()
        guard needsRefresh else { return }
        needsRefresh = false
        store.save()
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
        // "Gym – Strength Block", not "Gym · Gym – Strength Block".
        var parts = HeaderSummary.kindAndProgram(kind: template.kind.displayName, program: template.program?.name)
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
                    // Start, Plan and Log copy the stored template: what was just typed goes with it.
                    commitEdits()
                    if let practice { practice.startTapped = true } else { store.requestStart(template, live: live, toasts: toasts) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
                // ⌘↩ is the Workout menu's item ("Start UPPER" while this is shown).
                Button {
                    commitEdits()
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
                .help("Plan for a day")
                Button {
                    commitEdits()
                    logPast = template
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.headline)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Log a past workout")
                .help("Log a past workout")
            }
            // A workout this device can't read (or a newer George wrote) isn't started or copied here.
            .disabled(!readState.isEditable)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
    }

    /// The Thalia measures that count this template (from Thalia's catalog on this device).
    @ViewBuilder
    private var thaliaSection: some View {
        if practice == nil, let thalia, thalia.isEnabled {
            let measures = thalia.measures(countingTemplate: template.id)
            if !measures.isEmpty {
                Section {
                    ForEach(measures, id: \.code) { measure in
                        Label(measure.title, systemImage: "arrow.left.arrow.right")
                    }
                } header: {
                    Text("Thalia")
                } footer: {
                    Text("Thalia counts this template's workouts here.")
                }
            }
        }
    }

    /// This template's performed workouts – its own query (`TemplateHistorySection`).
    private var historySection: some View {
        TemplateHistorySection(templateID: template.id)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .georgeTrailing) {
            Button {
                commitEdits()
                shareRoutine = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share routine")
            .help("Share routine")
            Menu {
                if readState.isEditable && content.blocks.count > 1 {
                    Button {
                        showReorder = true
                    } label: {
                        Label("Reorder Exercises", systemImage: "arrow.up.arrow.down")
                    }
                    Divider()
                }
                TemplateMenuItems(template: template, logPastFor: $logPast, beforeAction: { commitEdits() })
            } label: {
                Image(systemName: "ellipsis")
            }
            .help("More")
        }
    }
}

/// A template's performed workouts, newest first (the last 10, with the count). Fetched by template
/// and status – not every workout – so a running workout's sets don't fetch it again.
private struct TemplateHistorySection: View {
    @Environment(Router.self) private var router
    @Query private var performed: [WorkoutSession]

    init(templateID: UUID) {
        let id: UUID? = templateID
        let completed = SessionStatus.completed.rawValue
        let partial = SessionStatus.partial.rawValue
        _performed = Query(filter: #Predicate<WorkoutSession> { session in
            session.templateID == id && (session.statusRaw == completed || session.statusRaw == partial)
        })
    }

    var body: some View {
        let history = performed.sorted { $0.date > $1.date }
        if !history.isEmpty {
            Section("History · \(history.count)") {
                ForEach(history.prefix(10)) { session in
                    Button {
                        // On top of the template, with Back – the list keeps the template selected.
                        router.push(.session(session.id))
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
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
