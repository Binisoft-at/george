import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

struct SessionDetailView: View {
    let sessionID: UUID
    @Query private var matches: [WorkoutSession]

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _matches = Query(filter: #Predicate<WorkoutSession> { $0.id == sessionID })
    }

    var body: some View {
        if let session = matches.first {
            SessionDocument(session: session)
        } else {
            MessageView(title: "Workout not found", systemImage: "questionmark.square.dashed", message: "It may have been deleted on another device.")
        }
    }
}

private struct SessionDocument: View {
    @Bindable var session: WorkoutSession
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @State private var content = WorkoutContent()
    @State private var loadedData: Data?
    @State private var editor = EditorState()
    @State private var newTag = ""
    @State private var confirmDelete = false
    @State private var showDetails = false
    @State private var showReorder = false
    @State private var confirmReset = false
    @State private var confirmNotDone = false
    @State private var logSession: WorkoutSession?
    /// A finished workout opens read-only (a stray tap or swipe doesn't change history); Edit unlocks it.
    @State private var isEditingPast = false
    /// On screen (not covered by a pushed screen): only then it's what ⌘↩ starts.
    @State private var isShown = false
    /// "Update Template" is offered only when saving would change the template.
    @State private var templateDiffers = false
    /// What "Update Template" would write, shown for confirmation.
    @State private var templateOffer: TemplateOffer?
    /// Whether this device can read and edit the stored workout (see `StoredContent`).
    @State private var readState: StoredContent.ReadState = .readable
    /// The workout as last loaded or written: an edit is compared with it, not with a fresh decode.
    @State private var lastSaved = WorkoutContent()
    /// Typed numbers not written yet: they're written once typing pauses (`editCount`), not per keystroke.
    @State private var pendingEdit: PendingEdit?
    /// Counts edits; the debounce task restarts with each one.
    @State private var editCount = 0
    /// Written without a revision bump: Today, the streak and stats refresh once editing ends.
    @State private var needsRefresh = false
    @Environment(\.scenePhase) private var scenePhase

    /// An edit waiting to be written, with the workout it belongs to (the list may switch to another).
    private struct PendingEdit {
        let session: WorkoutSession
        let content: WorkoutContent
    }

    private struct TemplateOffer {
        /// Heavier loads only (empty: none).
        var loads: [String]
        /// Everything: sets, exercises and numbers.
        var all: [String]
    }

    private var isLive: Bool { live.session?.id == session.id }

    /// A performed workout that isn't running (opened from history).
    private var isPastWorkout: Bool { session.status.isPerformed && !isLive }

    /// In progress but not live here: another device runs it (synced). Read-only – its next save
    /// would overwrite any change made here.
    private var runsElsewhere: Bool { session.status == .active && !isLive }

    /// Ticks, swipes and "+" are off for a finished workout until Edit.
    private var isLocked: Bool { (session.status.isPerformed && !isLive && !isEditingPast) || !canEditContent || runsElsewhere }

    /// Off when the stored workout can't be read here or a newer George wrote it: it is shown
    /// read-only, never saved over, and Start refuses (instead of an empty editor).
    private var canEditContent: Bool { isLive || readState.isEditable }

    /// While this session is running, edits go through the live controller.
    private var contentBinding: Binding<WorkoutContent> {
        if isLive {
            return Binding(get: { live.content }, set: { live.replaceContent($0) })
        }
        return $content
    }

    // Split in four so the compiler type-checks it in time.
    var body: some View {
        withTemplateOffer(withDialogs(withSaving(mainList)))
    }

    private var mainList: some View {
        List {
            if runsElsewhere {
                runningElsewhereBanner
            }
            if session.status.isPerformed && !isLive {
                RecapOverviewSection(session: session)
            }
            headerSection
                .disabled(runsElsewhere)
            if session.status.isPerformed {
                StatsTilesSection(session: session)
            }
            if canEditContent {
                WorkoutEditorSections(
                    content: contentBinding,
                    mode: .session(isLive: isLive),
                    defaultKind: session.kind,
                    onToggleSet: isLive ? { (setID: UUID) in live.toggleSet(setID) } : nil,
                    isEditing: !isLocked,
                    state: editor,
                    // A finished workout compares with the one before it, not with itself or a later one.
                    previousBefore: isPastWorkout ? session.date : nil,
                    excludingSessionID: isPastWorkout ? session.id : nil
                )
                // Running on another device: read-only, like the header and notes – an exercise
                // added or a number changed here would never be saved.
                .disabled(runsElsewhere)
            } else {
                // "Can't read this workout" / "Update George on this device to edit" – never an empty editor.
                ReadOnlyContentSection(state: readState, content: content)
            }
            MuscleTargetsSection(content: contentBinding.wrappedValue, kind: session.kind, performed: session.status.isPerformed)
            notesSection
                .disabled(runsElsewhere)
        }
        .groupedList()
        .safeAreaInset(edge: .bottom) { actionBar }
        .workoutEditorSheets(content: contentBinding, mode: .session(isLive: isLive), defaultKind: session.kind, state: editor,
                             onToggleSet: isLive ? { (setID: UUID) in live.toggleSet(setID) } : nil)
        .onChange(of: session.id) { _, _ in isEditingPast = false }
        // "New Empty Workout" left without adding anything goes again (no empty "Missed" tomorrow).
        // Edits still waiting are written first, so a just-added exercise counts.
        .onChange(of: session.id) { oldID, _ in
            commitEdits()
            discardDraftIfEmpty(oldID)
        }
        .onDisappear {
            commitEdits()
            discardDraftIfEmpty(session.id)
        }
        .navigationTitle(session.title.isEmpty ? "Workout" : session.title)
        .inlineTitle()
        .toolbar { toolbarItems }
        // ⌘↩ (Workout menu) starts or continues this workout while it's shown.
        .focusedSceneValue(\.startTarget, isShown ? startCommand : nil)
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
        .onAppear(perform: load)
    }

    /// Edits are written once typing pauses (not on every keystroke) and saved without a revision
    /// bump; the bump comes once, when editing ends (leaving the screen or the app, Done, Start …).
    private func withSaving(_ base: some View) -> some View {
        base
        .onChange(of: session.contentData) { _, newData in externalChange(newData) }
        // Live mode ended (Finish, Discard, continued elsewhere) while this page stayed open: its
        // saves were skipped while it ran, so the page reloads – the copy from before Start would
        // otherwise show, and the next edit would write it over the logged sets.
        .onChange(of: isLive) { _, nowLive in
            guard !nowLive, session.modelContext != nil, !session.isDeleted else { return }
            if let edit = pendingEdit, edit.session !== session { writePendingEdit() }
            pendingEdit = nil
            load()
        }
        .onChange(of: content) { _, newContent in contentEdited(newContent) }
        .task(id: editCount) {
            guard pendingEdit != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writePendingEdit()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { commitEdits() }
        }
    }

    /// External change (sync, watch, live view): reload unless it's our own write.
    private func externalChange(_ newData: Data?) {
        guard newData != loadedData, !isLive else { return }
        if let edit = pendingEdit, edit.session !== session {
            // The list switched to another workout: the one before keeps what was typed into it.
            writePendingEdit()
        } else {
            // This workout changed elsewhere: that change wins, as it did when each keystroke was saved.
            pendingEdit = nil
        }
        load()
    }

    private func contentEdited(_ newContent: WorkoutContent) {
        guard !isLive, !runsElsewhere, canEditContent else { return }
        guard newContent != lastSaved else {
            // Typed back to what's stored: nothing to write.
            pendingEdit = nil
            return
        }
        pendingEdit = PendingEdit(session: session, content: newContent)
        if newContent.completedSets != lastSaved.completedSets {
            // A tick (or one taken back) is written at once: the status follows it.
            writePendingEdit()
        } else {
            editCount &+= 1
        }
    }

    /// Writes the waiting edit. A finished workout's status follows its ticks: all done → completed,
    /// some → stopped early, the last tick taken back → ask.
    private func writePendingEdit() {
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        let target = edit.session
        // Deleted meanwhile, or started (a running workout is written by live mode, not here).
        guard target.modelContext != nil, !target.isDeleted, target.status != .active else { return }
        let isShownOne = target === session
        let doneBefore = lastSaved.completedSets
        guard target.storeContent(edit.content) else {
            // Kept as stored (a newer George wrote it meanwhile): show what's there.
            if isShownOne { load() }
            return
        }
        if isShownOne {
            lastSaved = edit.content
            loadedData = target.contentData
        }
        let nothingDone = store.deriveStatus(of: target, from: edit.content)
        if nothingDone && doneBefore > 0 && isShownOne { confirmNotDone = true }
        store.save(bumping: false)
        needsRefresh = true
    }

    /// Writes what's waiting and lets Today, the streak and stats catch up (one revision bump).
    private func commitEdits() {
        writePendingEdit()
        guard needsRefresh else { return }
        needsRefresh = false
        store.save()
    }

    private func withDialogs(_ base: some View) -> some View {
        base
        .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // Nothing typed is written into a deleted workout.
                pendingEdit = nil
                router.close(.session(session.id))
                if isLive {
                    // The running workout itself is deleted (not just what was done since Start).
                    let title = session.title
                    let undo = live.discard(deleteSession: true)
                    toasts.show("Deleted \u{201C}\(title)\u{201D}", symbol: "trash.fill", undo: undo)
                } else {
                    store.trash(session, toasts: toasts)
                }
            }
        }
        .confirmationDialog("Reset all sets?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset All Sets", role: .destructive) {
                if session.status.isPerformed { store.markNotDone(session) }
                content.resetProgress()
            }
        } message: {
            Text(session.status.isPerformed
                 ? "Every tick and logged number is cleared, and the workout no longer counts as done."
                 : "Every tick and logged number is cleared.")
        }
        .confirmationDialog("Mark as not done?", isPresented: $confirmNotDone, titleVisibility: .visible) {
            Button("Mark as Not Done", role: .destructive) { store.markNotDone(session) }
            Button("Keep as Done", role: .cancel) {}
        } message: {
            Text("No set is ticked any more. As not done, it doesn't count for your streak and stats.")
        }
    }

    private func withTemplateOffer(_ base: some View) -> some View {
        base
        .confirmationDialog("Update “\(session.templateName)”?", isPresented: showsTemplateOffer, titleVisibility: .visible, presenting: templateOffer) { offer in
            if !offer.loads.isEmpty {
                Button("Heavier Loads Only") { applyTemplateUpdate(.loads) }
            }
            Button(offer.loads.isEmpty ? "Update Template" : "Save All Changes") { applyTemplateUpdate(.everything) }
            Button("Cancel", role: .cancel) {}
        } message: { offer in
            Text(templateOfferMessage(offer))
        }
        // Whether "Update Template" would change anything, refreshed when the workout changes.
        .task(id: session.contentData) {
            templateDiffers = session.templateID != nil && !store.templateChanges(from: session, mode: .everything).isEmpty
        }
        .sheet(item: $logSession) { session in
            NavigationStack { LogPastWorkoutSheet(session: session) }
        }
        .sheet(isPresented: $showReorder) {
            ReorderBlocksSheet(content: contentBinding)
        }
    }

    private func load() {
        content = session.content
        lastSaved = content
        loadedData = session.contentData
        readState = session.contentReadState
    }

    // MARK: Update Template

    private var showsTemplateOffer: Binding<Bool> {
        Binding(get: { templateOffer != nil }, set: { if !$0 { templateOffer = nil } })
    }

    /// Works out what the update would write, then asks with those lines.
    private func offerTemplateUpdate() {
        commitEdits()
        let all = store.templateChanges(from: session, mode: .everything)
        guard !all.isEmpty else {
            templateDiffers = false
            toasts.show("\u{201C}\(session.templateName)\u{201D} already matches", symbol: "checkmark.circle.fill")
            return
        }
        templateOffer = TemplateOffer(loads: store.templateChanges(from: session, mode: .loads), all: all)
    }

    private func templateOfferMessage(_ offer: TemplateOffer) -> String {
        var lines = Array(offer.all.prefix(6))
        if offer.all.count > 6 { lines.append("and \(offer.all.count - 6) more") }
        lines.append(offer.loads.isEmpty
                     ? "Drop sets and warm-ups added during the workout stay out."
                     : "“Heavier Loads Only” keeps the sets and reps as planned.")
        return lines.joined(separator: "\n")
    }

    private func applyTemplateUpdate(_ mode: TemplateUpdateMode) {
        let name = session.templateName
        let restore = store.updateTemplate(from: session, mode: mode)
        templateOffer = nil
        guard restore != nil else {
            toasts.show("\u{201C}\(name)\u{201D} wasn't changed – it was saved by a newer George", symbol: "exclamationmark.triangle")
            return
        }
        templateDiffers = !store.templateChanges(from: session, mode: .everything).isEmpty
        let undo: (() -> Void)? = restore.map { restore in
            {
                restore()
                templateDiffers = true
            }
        }
        toasts.show("Updated \u{201C}\(name)\u{201D}", symbol: "arrow.triangle.2.circlepath", undo: undo)
    }

    private func discardDraftIfEmpty(_ id: UUID) {
        // Covered by a page opened on top of it (Back returns to it): not left yet.
        guard router.draftSessionID == id, !router.isCovered(.session(id)) else { return }
        router.draftSessionID = nil
        // Gone: no list or tab keeps it, to show it again as "Workout not found".
        if store.discardIfEmptyDraft(sessionID: id) { router.close(.session(id)) }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $session.title, axis: .vertical)
                    .font(.title2.weight(.bold))
                    .onSubmit { store.save() }
                TextField("Subtitle (e.g. UPPER BODY + SHOULDER/WRIST HEALTH)", text: $session.subtitle, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                DatePicker(
                    session.status == .planned ? "Planned for" : "Date",
                    selection: Binding<Date>(
                        get: { session.status == .planned ? (session.plannedDate ?? Date()) : (session.startedAt ?? session.plannedDate ?? session.createdAt) },
                        set: { newDate in
                            let previousDate = session.date
                            if session.status == .planned { session.plannedDate = newDate } else { session.startedAt = newDate; session.plannedDate = newDate }
                            // "W46: 2 UPPER - 10.11" follows the new day; a typed title stays.
                            store.retitleIfAuto(session, previousDate: previousDate)
                            store.save()
                        }
                    ),
                    displayedComponents: session.status == .planned ? [.date] : [.date, .hourAndMinute]
                )
                .font(.subheadline)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                statusMenu
                                kindMenu
                                programMenu
                                priorityMenu
                                Button {
                                    session.isFavorite.toggle()
                                    store.save()
                                } label: {
                                    Chip(text: "Favorite", systemImage: session.isFavorite ? "star.fill" : "star", tint: session.isFavorite ? .yellow : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        TagEditor(tags: Binding(get: { session.tags }, set: { session.tags = $0; store.save() }))
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
        var parts = [session.status.displayName, session.kind.displayName]
        if let program = session.program { parts.append(program.name) }
        if session.priority != .none { parts.append(session.priority.displayName) }
        return parts.joined(separator: " · ")
    }

    private var startButtonTitle: String {
        if isLive { return "Open Live Workout" }
        if runsElsewhere { return "Continue Here" }
        return session.status == .partial ? "Continue Workout" : "Start Workout"
    }

    /// Start, continue – or take over a workout another device runs (asks first while one runs here).
    private func startOrContinue() {
        // Live mode starts from the stored workout: what was just typed goes with it.
        commitEdits()
        if runsElsewhere && !live.isActive {
            live.continueHere(session)
        } else {
            live.requestStart(.session(session))
        }
    }

    /// What ⌘↩ does on this screen (nil: a finished or skipped workout – the menu then starts the
    /// suggested one).
    private var startCommand: StartCommand? {
        guard session.status != .completed && session.status != .skipped else { return nil }
        let title = session.title.isEmpty ? "Workout" : session.title
        let verb: String
        if isLive {
            verb = "Show"
        } else if runsElsewhere || session.status == .partial {
            verb = "Continue"
        } else {
            verb = "Start"
        }
        return StartCommand(title: "\(verb) \(title)", isEnabled: canEditContent) { startOrContinue() }
    }

    /// Shown while another device runs this workout.
    private var runningElsewhereBanner: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ThisDevice.runningTitle(for: session))
                        .font(.subheadline.weight(.semibold))
                    Text("Read-only here – changes would be overwritten. Continue Here to take it over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "iphone.and.arrow.forward")
                    .foregroundStyle(.green)
            }
        }
    }

    /// Start / continue, always reachable at the bottom.
    @ViewBuilder
    private var actionBar: some View {
        if session.status != .completed && session.status != .skipped {
            Button {
                startOrContinue()
            } label: {
                Label(startButtonTitle, systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.accentColor)
            // ⌘↩ is the Workout menu's item (it follows this screen), not a second shortcut here.
            .disabled(!canEditContent)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(SessionStatus.allCases.filter { $0 != .active }) { status in
                Button {
                    commitEdits()
                    if status == .completed && !session.status.isPerformed && !isLive {
                        logSession = session
                    } else {
                        store.setStatus(status, for: [session])
                    }
                } label: {
                    Label(status.displayName, systemImage: status.symbol)
                }
            }
            .disabled(isLive)
        } label: {
            Chip(text: session.status.displayName, systemImage: session.status.symbol, tint: session.status == .completed ? .green : .blue)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var kindMenu: some View {
        Menu {
            ForEach(WorkoutKind.presets) { kind in
                Button {
                    session.kind = kind
                    store.save()
                } label: {
                    Label(kind.displayName, systemImage: kind.symbol)
                }
            }
        } label: {
            KindBadge(kind: session.kind, compact: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var programMenu: some View {
        Menu {
            Button("No Program") { store.move([session], to: nil) }
            ForEach(programs) { program in
                Button {
                    store.move([session], to: program)
                } label: {
                    Label(program.name, systemImage: program.symbol)
                }
            }
        } label: {
            Chip(text: session.program?.name ?? "No Program", systemImage: "folder", tint: session.program.map { Color(hex: $0.colorHex) } ?? .secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(Priority.allCases) { priority in
                Button {
                    session.priority = priority
                    store.save()
                } label: {
                    Label(priority.displayName, systemImage: priority.symbol)
                }
            }
        } label: {
            Chip(text: session.priority == .none ? "Priority" : session.priority.displayName, systemImage: session.priority.symbol, tint: session.priority.color)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("How did it feel? Anything to change next time?", text: $session.notes, axis: .vertical)
                .lineLimit(3...12)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .georgeTrailing) {
            if session.status.isPerformed && !isLive && canEditContent {
                // A finished workout is read-only until Edit (ticks, swipes and "+" change history).
                Button(isEditingPast ? "Done" : "Edit") {
                    if isEditingPast { commitEdits() }
                    withAnimation(.snappy) { isEditingPast.toggle() }
                }
                .fontWeight(isEditingPast ? .semibold : .regular)
            }
            Menu {
                // Copies of a workout this device can't fully read would come out empty or stripped.
                if canEditContent {
                    // Opens on top (with Back on the Mac); the list keeps this workout selected.
                    Button {
                        commitEdits()
                        let copy = store.duplicate(session, asPlannedOn: Date())
                        router.push(.session(copy.id))
                    } label: { Label("Do Again Today", systemImage: "arrow.clockwise") }
                    Button {
                        commitEdits()
                        let template = store.saveAsTemplate(session, into: session.program)
                        router.push(.template(template.id))
                    } label: { Label("Save as New Template", systemImage: "square.on.square") }
                }
                if canEditContent && session.templateID != nil && templateDiffers {
                    Button {
                        offerTemplateUpdate()
                    } label: { Label("Update “\(session.templateName)” Template…", systemImage: "arrow.triangle.2.circlepath") }
                }
                Button {
                    session.isPinned.toggle()
                    store.save()
                } label: { Label(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") }
                if canEditContent && !runsElsewhere && contentBinding.wrappedValue.blocks.count > 1 {
                    Button {
                        showReorder = true
                    } label: { Label("Reorder Exercises", systemImage: "arrow.up.arrow.down") }
                }
                if session.status.isPerformed && !isLive && canEditContent {
                    Button {
                        confirmReset = true
                    } label: { Label("Reset All Sets", systemImage: "arrow.uturn.backward") }
                }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .help("More")
        }
    }
}

/// Summary tiles for a finished workout.
private struct StatsTilesSection: View {
    let session: WorkoutSession
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @State private var metrics: HealthMetrics?

    var body: some View {
        // Measured (Watch, this device) or George's estimate – marked, so the two are never mixed up.
        let energy = EnergyDisplay.choose(measured: metrics?.activeEnergyKcal, estimated: session.energyKcal)
        let heartRate = metrics?.averageHeartRate ?? 0
        // Working volume (no warm-ups, both sides) – the same number as the share card and Progress.
        let volume = session.content.workingVolumeKg
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                tile("Duration", Format.minutes(session.durationSeconds), "clock")
                tile("Sets", "\(session.doneSetCount)/\(session.setCount)", "checklist")
                if volume > 0 { tile("Volume", Format.volume(volume, unit: store.unit), "scalemass") }
                if let energy { tile("Energy", energy.text, "flame", note: energy.isMeasured ? nil : "estimated") }
                if heartRate > 0 { tile("Avg HR", "\(Int(heartRate)) bpm", "heart") }
                if session.effort > 0 { tile("Effort", "\(session.effort)/10", "gauge.with.dots.needle.67percent") }
            }
            .padding(.vertical, 4)
            if session.healthWorkoutID != nil {
                Label(session.recordedOnWatch ? "Recorded on Apple Watch · in Apple Health" : "Saved to Apple Health", systemImage: "heart.text.square.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
            }
        }
        .task(id: session.id) { await loadMetrics() }
    }

    /// Heart rate is kept on-device; on another iPhone/iPad it's read back from Apple Health.
    private func loadMetrics() async {
        metrics = store.healthMetrics(for: session.id)
        guard metrics == nil, health.isAvailable, let start = session.startedAt, let end = session.endedAt else { return }
        if let hr = await health.heartRate(from: start, to: end) {
            store.recordHealthMetrics(sessionID: session.id, averageHeartRate: hr.average, maxHeartRate: hr.max, activeEnergy: nil)
            metrics = store.healthMetrics(for: session.id)
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Editable tag chips.
struct TagEditor: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    tags.removeAll { $0 == tag }
                } label: {
                    HStack(spacing: 3) {
                        Text("#" + tag)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            TextField("+ tag", text: $draft)
                .font(.caption)
                .frame(width: 80)
                .onSubmit {
                    let cleaned = draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "").replacingOccurrences(of: ",", with: "")
                    if !cleaned.isEmpty && !tags.contains(cleaned) { tags.append(cleaned) }
                    draft = ""
                }
        }
    }
}
