import Foundation
import SwiftData
import SwiftUI
import BinisoftKit
import GeorgeCore

/// High-level operations on the SwiftData store. Views call these instead of
/// mutating models directly so naming, ordering and denormalized fields stay consistent.
@MainActor
@Observable
final class GeorgeStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Any synced data changed – workouts, templates, programs, settings, check-ins (Today, lists, the
    /// sidebar, reminders). Moves after saves that changed something and after iCloud imports that
    /// brought changes (`CloudImportRefresher`); every `historyRevision` change moves it too.
    private(set) var revision = 0
    /// Performed workouts changed – finished, logged, edited, deleted or synced (the history index,
    /// "last time", muscles, Progress). Templates, plans, Set Active, Health numbers and a running
    /// workout's sets don't move it.
    private(set) var historyRevision = 0
    /// A workout in progress changed on another device (synced): the "running on another device" bars.
    private(set) var liveRevision = 0
    /// What saved changes move since the last bump (`save(bumping: false)` keeps it for the next one).
    @ObservationIgnored private var pendingChange: StoreChange = []
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    /// Undo and redo of the context's changes (`undoneOrRedone`).
    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []
    /// The user's exercise entries by key, per revision (`userExercise(forKey:)`).
    @ObservationIgnored var userExerciseCache: (revision: Int, entries: [String: UserExercise])?

    init(container: ModelContainer) {
        self.container = container
        // Autosaves and saves outside the store count too: what they change moves the counters at the
        // next `save()`.
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) { [weak self] _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { self?.notePendingChanges() }
        }
        // An undo or redo (Edit menu, ⌘Z, shake) changes the models without a save: the counters – and
        // Today, the streak and the lists keyed on them – would wait for the next save.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard Thread.isMainThread else { return }
                let sender = (note.object as? UndoManager).map { ObjectIdentifier($0) }
                MainActor.assumeIsolated { self?.undoneOrRedone(by: sender) }
            })
        }
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The context's undo manager undid or redid a change: saved once the undo has finished, which
    /// moves the counters for what it changed (nothing more when the toast's Undo saved already).
    private func undoneOrRedone(by sender: ObjectIdentifier?) {
        guard let sender, let manager = context.undoManager, ObjectIdentifier(manager) == sender else { return }
        Task { @MainActor [weak self] in self?.save() }
    }

    /// A routine template started from the streak rescue sheet: the session it starts counts as a
    /// rescue workout (a few minutes to get from the sheet to the start).
    @ObservationIgnored var pendingRescue: (templateID: UUID, at: Date)?
    /// The energy rhythm's next low day, cached per revision and day (see `expectedLowEnergyDay`).
    @ObservationIgnored var lowEnergyCache: (revision: Int, day: Date, value: Date?)?
    /// The calendar, profile, training days, streak, today's workouts and suggestions, kept between
    /// redraws (GeorgeStore+Caches).
    let caches = StoreCaches()
    /// Apple Health's latest body weight (kept on this device, set by the views that read Health).
    /// Energy estimates use it before the body weight from Settings.
    @ObservationIgnored var healthBodyMassKg: Double?
    /// Measured calories from Apple Health by session (device-only `HealthMetrics`) and when they were
    /// kept, cached per revision.
    @ObservationIgnored var measuredEnergyCache: (revision: Int, values: [UUID: (kcal: Double, keptAt: Date)])?
    /// The last save that failed (nil again after one that works). RootView shows it once as a toast.
    private(set) var lastSaveError: String?
    /// An iCloud import has finished on this device at least once (Welcome waits for it on a new device).
    private(set) var cloudImportSeen = UserDefaults.standard.bool(forKey: Prefs.cloudImportSeen)
    /// When the current iCloud sync error was first seen (the banner waits 15 minutes before it shows).
    @ObservationIgnored var syncErrorSince: (message: String, since: Date)?

    /// Everything recomputes (pull to refresh, a workout finished, a profile value from Apple Health).
    func bump() { bump(.all) }

    /// Moves the counters for `change`; a history change moves the data too.
    func bump(_ change: StoreChange) {
        guard !change.isEmpty else { return }
        if change.contains(.history) { historyRevision &+= 1 }
        if change.contains(.data) || change.contains(.history) { revision &+= 1 }
        if change.contains(.live) { liveRevision &+= 1 }
        pendingChange.subtract(change)
    }

    /// Notes what the context is about to save (before every save, autosaves included).
    func notePendingChanges() {
        guard context.hasChanges else { return }
        pendingChange.formUnion(unsavedChange())
    }

    /// What the unsaved changes move: any model the data, a workout that is or was performed the history.
    private func unsavedChange() -> StoreChange {
        var change: StoreChange = []
        let models = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
        for model in models {
            guard let session = model as? WorkoutSession else {
                change.insert(.data)
                continue
            }
            let wasPerformed = SessionHistory.shared.contains(session.id, in: self)
            change.formUnion(.session(isPerformed: session.status.isPerformed, wasPerformed: wasPerformed))
            if change.contains(.history) { break }
        }
        return change
    }

    /// Bumps what saves changed since the last bump – nothing when nothing changed.
    private func bumpPending() {
        let change = pendingChange
        pendingChange = []
        bump(change)
    }

    /// An iCloud import finished (CloudImportRefresher).
    func noteCloudImport() {
        guard !cloudImportSeen else { return }
        cloudImportSeen = true
        UserDefaults.standard.set(true, forKey: Prefs.cloudImportSeen)
    }

    private func recordSave(_ error: Error?) {
        if let error {
            AppLog.error("Save failed: \(error)", category: "store")
            lastSaveError = error.localizedDescription
        } else if lastSaveError != nil {
            AppLog.info("Saving works again", category: "store")
            lastSaveError = nil
        }
    }

    func save() {
        save(bumping: true)
    }

    /// Saves and moves the counters for what changed (`revision`, and `historyRevision` only when a
    /// performed workout changed; nothing when nothing changed). `bumping: false` keeps the change for
    /// the next bump (live set edits – dashboards don't need to recompute on every keystroke; they
    /// refresh when the workout starts, finishes or is discarded).
    func save(bumping: Bool) {
        notePendingChanges()
        do {
            if context.hasChanges { try context.save() }
            recordSave(nil)
        } catch {
            recordSave(error)
        }
        if bumping { bumpPending() }
    }

    /// Saves changes without putting them on the undo stack (live sets must not be undone by ⌘Z or shake).
    func saveWithoutUndo(bumping: Bool = false, _ changes: () -> Void) {
        let manager = context.undoManager
        manager?.disableUndoRegistration()
        changes()
        notePendingChanges()
        do {
            if context.hasChanges { try context.save() }
            recordSave(nil)
        } catch {
            recordSave(error)
        }
        manager?.enableUndoRegistration()
        if bumping { bumpPending() }
    }

    // MARK: Settings

    @ObservationIgnored private var cachedSettings: SyncedSettings?

    var settings: SyncedSettings {
        if let cachedSettings, cachedSettings.modelContext != nil { return cachedSettings }
        let all = (try? context.fetch(FetchDescriptor<SyncedSettings>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let first = all.first {
            // Sync can bring a second copy (a device that set up before its first sync): the oldest is
            // the one every device keeps; `resolveDuplicates()` merges the others into it (never here,
            // in a getter – the newer copy may hold the choices that count).
            cachedSettings = first
            return first
        }
        let fresh = SyncedSettings()
        context.insert(fresh)
        cachedSettings = fresh
        return fresh
    }

    /// Forgets the cached settings record (after duplicates were merged).
    func forgetCachedSettings() { cachedSettings = nil }

    /// Changes synced settings: stamps the change (so the latest choice wins when two devices made
    /// a copy each before they synced) and saves.
    func updateSettings(_ change: (SyncedSettings) -> Void) {
        let current = settings
        change(current)
        current.updatedAt = Date()
        save()
    }

    /// Built once per week start and time zone (`cachedCalendar`), not on every use.
    var calendar: Calendar { cachedCalendar() }
    var unit: WeightUnit { settings.unit }

    // MARK: Fetching

    func fetchPrograms(includeArchived: Bool = true) -> [Program] {
        let all = (try? context.fetch(FetchDescriptor<Program>())) ?? []
        return all
            .filter { includeArchived || !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func fetchSessions() -> [WorkoutSession] {
        (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
    }

    /// Sessions that are planned and not started yet.
    func fetchPlannedSessions() -> [WorkoutSession] {
        let planned = SessionStatus.planned.rawValue
        return (try? context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.statusRaw == planned }))) ?? []
    }

    func fetchTemplates() -> [WorkoutTemplate] {
        (try? context.fetch(FetchDescriptor<WorkoutTemplate>())) ?? []
    }

    func program(id: UUID?) -> Program? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Program>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func session(id: UUID?) -> WorkoutSession? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func template(id: UUID?) -> WorkoutTemplate? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<WorkoutTemplate>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    var activeProgram: Program? {
        if let program = program(id: settings.activeProgramID), !program.isArchived { return program }
        // Without a choice: your own first program before the "Stretch & Yoga" routines folder.
        let programs = fetchPrograms(includeArchived: false)
        return programs.first { !isRoutineProgram($0) } ?? programs.first
    }

    /// The program George keeps ready-made routines in ("Stretch & Yoga", see `templateForRoutine`).
    static let routineProgramName = "Stretch & Yoga"

    func isRoutineProgram(_ program: Program) -> Bool {
        program.name == Self.routineProgramName && program.kind == .stretch
    }

    var activeSession: WorkoutSession? {
        activeSessions.first
    }

    /// Workouts marked in progress (here, on another device, or left so by accident), newest first.
    /// Fetched by status – not every workout with its blob.
    var activeSessions: [WorkoutSession] {
        let active = SessionStatus.active.rawValue
        let descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.statusRaw == active })
        return ((try? context.fetch(descriptor)) ?? []).sorted { $0.date > $1.date }
    }

    /// Performed sessions as plain records for statistics.
    func performedRecords() -> [SessionRecord] {
        fetchPerformedSessions().map { $0.record() }
    }

    // MARK: Programs

    /// `activate`: make it the active program (Today's Up next and Plan This Week follow it). nil
    /// decides by itself: only your first own program becomes active – a new program never takes
    /// over Today silently.
    @discardableResult
    func createProgram(name: String, kind: WorkoutKind = .gym, colorHex: String? = nil, symbol: String? = nil, activate: Bool? = nil) -> Program {
        let existing = fetchPrograms(includeArchived: false)
        let program = Program(name: name.isEmpty ? "New Program" : name, kind: kind, colorHex: colorHex, symbol: symbol)
        program.sortIndex = (fetchPrograms().map(\.sortIndex).max() ?? 0) + 1
        context.insert(program)
        let isFirstOwn = !isRoutineProgram(program) && !existing.contains { !isRoutineProgram($0) }
        if activate ?? isFirstOwn {
            settings.activeProgramID = program.id
            settings.updatedAt = Date()
        }
        save()
        return program
    }

    func setActive(_ program: Program) {
        settings.activeProgramID = program.id
        settings.updatedAt = Date()
        save()
    }

    func delete(_ program: Program) {
        if settings.activeProgramID == program.id {
            settings.activeProgramID = nil
            settings.updatedAt = Date()
        }
        context.delete(program)
        save()
    }

    func duplicate(_ program: Program) -> Program {
        let copy = createProgram(name: program.name + " copy", kind: program.kind, colorHex: program.colorHex, symbol: program.symbol, activate: false)
        copy.notes = program.notes
        copy.subtitle = program.subtitle
        for template in program.orderedTemplates {
            _ = duplicate(template, into: copy, renamed: false)
        }
        save()
        return copy
    }

    // MARK: Templates

    @discardableResult
    func createTemplate(in program: Program?, name: String = "New Workout", kind: WorkoutKind? = nil, content: WorkoutContent = WorkoutContent()) -> WorkoutTemplate {
        let template = WorkoutTemplate(name: name, kind: kind ?? program?.kind ?? .gym, program: program, content: content)
        template.sortIndex = (program?.orderedTemplates.map(\.sortIndex).max() ?? 0) + 1
        context.insert(template)
        program?.touch()
        save()
        return template
    }

    @discardableResult
    func duplicate(_ template: WorkoutTemplate, into program: Program? = nil, renamed: Bool = true) -> WorkoutTemplate {
        let target = program ?? template.program
        let copy = WorkoutTemplate(name: renamed ? template.name + " copy" : template.name, subtitle: template.subtitle, kind: template.kind, program: target, content: template.content.freshCopy())
        copy.notes = template.notes
        copy.colorHex = template.colorHex
        copy.tagsRaw = template.tagsRaw
        copy.priorityRaw = template.priorityRaw
        copy.scheduleRaw = template.scheduleRaw
        copy.sortIndex = template.sortIndex + 0.5
        context.insert(copy)
        save()
        return copy
    }

    func move(_ templates: [WorkoutTemplate], to program: Program?) {
        for template in templates {
            template.program = program
            template.touch()
        }
        save()
    }

    func delete(_ template: WorkoutTemplate) {
        context.delete(template)
        save()
    }

    func reorder(_ templates: [WorkoutTemplate]) {
        for (index, template) in templates.enumerated() { template.sortIndex = Double(index) }
        save()
    }

    // MARK: Sessions

    /// Number of this session within its week (1-based), counting sessions that aren't skipped.
    func indexInWeek(for date: Date, excluding: UUID? = nil) -> Int {
        let cal = calendar
        let week = cal.weekStart(for: date)
        // Only that week's workouts, without their content.
        let count = fetchSessions(datedFrom: week, scalarsOnly: true).filter { session in
            session.id != excluding && session.status != .skipped && cal.weekStart(for: session.date) == week && session.date <= date
        }.count
        return count + 1
    }

    func title(for templateName: String, on date: Date, excluding: UUID? = nil) -> String {
        SessionNamer(pattern: settings.namingPattern, calendar: calendar)
            .title(templateName: templateName, date: date, indexInWeek: indexInWeek(for: date, excluding: excluding))
    }

    private func makeContent(from template: WorkoutTemplate, before date: Date) -> WorkoutContent {
        var content = template.content.freshCopy()
        if settings.prefillFromLastTime {
            // The shared index of last performances (built once per change of the log).
            content.applyPrevious { item in
                PreviousPerformanceCache.shared.sets(for: item.exerciseKey, store: self, before: date)
            }
        }
        return content
    }

    /// Creates a session from a template. `start` puts it straight into live mode.
    @discardableResult
    func makeSession(from template: WorkoutTemplate, date: Date = Date(), start: Bool) -> WorkoutSession {
        let session = WorkoutSession(
            title: title(for: template.name, on: date),
            kind: template.kind,
            status: start ? .active : .planned,
            plannedDate: date,
            program: template.program,
            content: makeContent(from: template, before: date)
        )
        session.subtitle = template.subtitle
        session.templateID = template.id
        session.templateName = template.name
        session.colorHex = template.colorHex
        session.tagsRaw = template.tagsRaw
        if start {
            session.startedAt = date
            session.resumedAt = date
            if let pending = pendingRescue, pending.templateID == template.id, Date().timeIntervalSince(pending.at) < 600 {
                session.isRescue = true
            }
            pendingRescue = nil
        }
        template.lastUsedAt = date
        context.insert(session)
        // Started: `LiveWorkoutController.start` saves again right away – one bump for both.
        save(bumping: !start)
        return session
    }

    @discardableResult
    func makeEmptySession(program: Program?, kind: WorkoutKind? = nil, title: String? = nil, start: Bool, rescue: Bool = false, date: Date = Date()) -> WorkoutSession {
        let name = title ?? (rescue ? "Rescue" : "Workout")
        let session = WorkoutSession(
            title: self.title(for: name, on: date),
            kind: kind ?? program?.kind ?? .gym,
            status: start ? .active : .planned,
            plannedDate: date,
            program: program
        )
        session.isRescue = rescue
        if start {
            session.startedAt = date
            session.resumedAt = date
        }
        context.insert(session)
        // Started: `LiveWorkoutController.start` saves again right away – one bump for both.
        save(bumping: !start)
        return session
    }

    /// Log a workout after the fact (marks every set done). `bodyMassKg`: Apple Health's latest
    /// value when there is one – otherwise the one from Settings is used.
    @discardableResult
    func logPastSession(from template: WorkoutTemplate, date: Date, minutes: Int, bodyMassKg: Double? = nil, exactTime: Bool = false) -> WorkoutSession {
        let session = makeSession(from: template, date: date, start: false)
        markPerformed(session, date: date, minutes: minutes, bodyMassKg: bodyMassKg, exactTime: exactTime)
        return session
    }

    @discardableResult
    func duplicate(_ session: WorkoutSession, asPlannedOn date: Date? = nil) -> WorkoutSession {
        let when = date ?? Date()
        let copy = WorkoutSession(
            title: title(for: session.templateName.isEmpty ? session.title : session.templateName, on: when),
            kind: session.kind, status: .planned, plannedDate: when, program: session.program,
            content: session.content.freshCopy()
        )
        copy.subtitle = session.subtitle
        copy.templateID = session.templateID
        copy.templateName = session.templateName
        copy.colorHex = session.colorHex
        copy.tagsRaw = session.tagsRaw
        copy.priorityRaw = session.priorityRaw
        copy.notes = ""
        context.insert(copy)
        save()
        return copy
    }

    func move(_ sessions: [WorkoutSession], to program: Program?) {
        for session in sessions {
            session.program = program
            session.touch()
        }
        save()
    }

    func delete(_ session: WorkoutSession) {
        context.delete(session)
        save()
    }

    // MARK: Delete with Undo

    /// Deletes and shows a toast with Undo. ⌘Z and shake-to-undo work too: the context records
    /// changes with the window's undo manager (BinisoftKit `undoableChanges(in:)`).
    func trash(_ session: WorkoutSession, toasts: ToastCenter) {
        let title = session.title
        delete(session)
        toasts.show("Deleted \u{201C}\(title)\u{201D}", symbol: "trash.fill", undo: undoLastChange())
    }

    /// `keptRunning`: the selection held the workout running here, which was left out (it's discarded
    /// in live mode) – the toast says so.
    func trash(_ sessions: [WorkoutSession], toasts: ToastCenter, keptRunning: Bool = false) {
        guard !sessions.isEmpty else { return }
        for session in sessions { context.delete(session) }
        save()
        let message = sessions.count == 1 ? "Deleted 1 workout" : "Deleted \(sessions.count) workouts"
        toasts.show(keptRunning ? message + " · the running one stays" : message, symbol: "trash.fill", undo: undoLastChange())
    }

    func trash(_ template: WorkoutTemplate, toasts: ToastCenter) {
        let name = template.name
        delete(template)
        toasts.show("Deleted template \u{201C}\(name)\u{201D}", symbol: "trash.fill", undo: undoLastChange())
    }

    func trash(_ program: Program, toasts: ToastCenter) {
        let name = program.name
        delete(program)
        toasts.show("Deleted program \u{201C}\(name)\u{201D}", symbol: "trash.fill", undo: undoLastChange())
    }

    /// Undo for the change just made; nil when there's no undo manager (then the toast has no Undo).
    func undoLastChange() -> (() -> Void)? {
        guard let manager = context.undoManager, manager.canUndo else { return nil }
        return { [weak self] in
            manager.undo()
            self?.save()
            AppLog.info("Delete undone", category: "store")
        }
    }

    /// "Mark As". A session that wasn't done becomes a real completed workout (every set ticked, its
    /// planned length, an energy estimate) instead of an empty one lasting days; views offer the
    /// Log sheet first (`LogPastWorkoutSheet(session:)`) so the date and minutes can be changed.
    func setStatus(_ status: SessionStatus, for sessions: [WorkoutSession]) {
        for session in sessions {
            if status == .completed && !session.status.isPerformed && session.status != .active {
                // A week-planned day (midnight) gets a real time; markPerformed makes it end by now.
                markPerformed(session, date: session.plannedDate ?? session.date, minutes: defaultMinutes(for: session), saving: false)
                continue
            }
            if session.status == .active && status != .active {
                // Leaving "in progress" (ended elsewhere, or marked here): the clock stops where it is,
                // instead of running on from `resumedAt` forever. Back to "planned" starts over.
                let now = Date()
                if status == .planned {
                    session.accumulatedSeconds = 0
                    session.startedAt = nil
                    session.endedAt = nil
                } else {
                    // Where it really stopped, as Finish would: left idle (another device's workout
                    // marked here hours later), at its last set + rest – not now.
                    let clock = LiveClock(startedAt: session.startedAt, accumulatedSeconds: session.accumulatedSeconds, resumedAt: session.resumedAt)
                    let end = FinishTime.endFromOutside(clock: clock, kind: session.kind, content: session.content,
                                                        restSeconds: Double(settings.defaultRestSeconds), now: now)
                    session.accumulatedSeconds = clock.activeSeconds(until: end)
                    // Its end now (a continued workout's earlier end isn't kept).
                    if status.isPerformed { session.endedAt = end }
                }
                session.resumedAt = nil
            }
            session.status = status
            if status == .completed && session.endedAt == nil {
                session.startedAt = session.startedAt ?? session.plannedDate ?? Date()
                session.endedAt = max(session.startedAt ?? Date(), Date())
            }
        }
        save()
    }

    /// A ready-made routine's template in the program "Stretch & Yoga" (created if needed, reused
    /// when it was added before). `created` tells whether it is new.
    func templateForRoutine(_ routine: Routine, catalog: ExerciseCatalog) -> (template: WorkoutTemplate, created: Bool) {
        let programName = Self.routineProgramName
        // Never made the active program: Up next and Plan This Week stay with your own program.
        let program = fetchPrograms(includeArchived: false).first { $0.name == programName }
            ?? createProgram(name: programName, kind: .stretch, symbol: "figure.yoga", activate: false)
        if let existing = program.orderedTemplates.first(where: { $0.name == routine.name }) {
            return (existing, false)
        }
        let template = createTemplate(in: program, name: routine.name, kind: routine.kind, content: routine.content(using: catalog))
        template.subtitle = routine.subtitle.uppercased()
        save()
        return (template, true)
    }

    /// Save a session's structure (and performed loads) as a new template.
    @discardableResult
    func saveAsTemplate(_ session: WorkoutSession, into program: Program?) -> WorkoutTemplate {
        let name = session.templateName.isEmpty ? session.title : session.templateName
        let template = createTemplate(in: program ?? session.program, name: name, kind: session.kind, content: session.content.asTemplate())
        template.subtitle = session.subtitle
        save()
        return template
    }

    /// Push a session back into the template it came from: `.loads` raises only the weights (holds,
    /// distances) of the matching working sets, `.everything` saves exercises, sets and numbers –
    /// never the drop sets and warm-ups added just for that workout. Returns an undo that restores
    /// the template as it was (nil when there is no template).
    @discardableResult
    func updateTemplate(from session: WorkoutSession, mode: TemplateUpdateMode = .everything) -> (() -> Void)? {
        guard let template = template(id: session.templateID) else { return nil }
        let before = template.content
        // Stored data this build can't read (a newer George wrote it) stays as it is: nothing to undo.
        guard template.storeContent(session.content.asTemplate(mode: mode, base: before)) else { return nil }
        save()
        AppLog.info("Template updated (\(mode.rawValue))", category: "store")
        return { [weak self, weak template] in
            guard let self, let template else { return }
            template.content = before
            self.save()
        }
    }

    /// What `updateTemplate(from:mode:)` would change, as short lines ("Bench 4→3 sets",
    /// "Row 50→52.5 kg"). Empty when the template already matches.
    func templateChanges(from session: WorkoutSession, mode: TemplateUpdateMode) -> [String] {
        guard let template = template(id: session.templateID) else { return [] }
        return session.content.templateChanges(into: template.content, mode: mode, unit: unit)
    }

    /// Whether the session changed the template's exercises, groups or set counts – not counting
    /// what was only added for that workout (a drop set after "Can't finish", live warm-ups).
    func sessionDiffersFromTemplate(_ session: WorkoutSession) -> Bool {
        guard let template = template(id: session.templateID) else { return false }
        return session.content.changesTemplateStructure(template.content)
    }

    // MARK: Suggestions

    /// The template for a day: the one scheduled on that weekday (unless it's done that day already),
    /// otherwise the next one in the program's rotation (the one after the most recently used).
    /// Callers use `suggestedTemplate(in:on:)`, which keeps the answer per revision and day.
    func uncachedSuggestedTemplate(in program: Program?, on date: Date = Date()) -> WorkoutTemplate? {
        guard let program else { return nil }
        // A template with nothing in it yet (just created) is no workout to suggest.
        let templates = program.orderedTemplates.filter(\.isPlannable)
        guard !templates.isEmpty else { return nil }
        let cal = calendar
        let weekday = cal.component(.weekday, from: date)
        if let scheduled = templates.first(where: { $0.scheduleDays.contains(weekday) }) {
            let doneThatDay = program.allSessions.contains { $0.templateID == scheduled.id && cal.isDate($0.date, inSameDayAs: date) && $0.status.isPerformed }
            if !doneThatDay { return scheduled }
        }
        let lastSession = program.performedSessions.first { $0.templateID != nil }
        guard let lastID = lastSession?.templateID, let index = templates.firstIndex(where: { $0.id == lastID }) else {
            return templates.first
        }
        return templates[(index + 1) % templates.count]
    }

    /// What "start my next workout" means (Today's hero, Siri / Shortcuts, the Action Button,
    /// widgets): today's planned session first, otherwise the program's suggested template.
    enum NextWorkout {
        case planned(WorkoutSession)
        case template(WorkoutTemplate)

        var title: String {
            switch self {
            case .planned(let session): return session.templateName.isEmpty ? session.title : session.templateName
            case .template(let template): return template.name
            }
        }
    }

    func nextWorkout() -> NextWorkout? {
        if let planned = plannedToday().first {
            return .planned(planned)
        }
        guard let template = suggestedTemplate(in: activeProgram) else { return nil }
        // The suggestion was planned for a day or two ago and not done yet: that session, not a second one.
        if let planned = plannedSession(for: template) { return .planned(planned) }
        return .template(template)
    }

    /// Planned sessions from today on (the next 7 days), soonest first.
    func upcomingSessions(limit: Int = 10) -> [WorkoutSession] {
        let startOfToday = calendar.startOfDay(for: Date())
        let end = calendar.addingDays(8, to: startOfToday)
        return fetchPlannedSessions()
            .filter { plannedDay(of: $0) >= startOfToday && plannedDay(of: $0) < end }
            .sorted { plannedDay(of: $0) != plannedDay(of: $1) ? plannedDay(of: $0) < plannedDay(of: $1) : $0.createdAt < $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Planned sessions for today, in the order they were planned.
    func plannedToday() -> [WorkoutSession] {
        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = calendar.addingDays(1, to: startOfToday)
        return fetchPlannedSessions()
            .filter { plannedDay(of: $0) >= startOfToday && plannedDay(of: $0) < endOfToday && !isBlankPlan($0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Planned sessions from the last 7 days that weren't done ("Missed"), most recent first. Older
    /// ones stay in the Workouts list but no longer ask for attention.
    func overdueSessions(limit: Int = 5) -> [WorkoutSession] {
        let startOfToday = calendar.startOfDay(for: Date())
        let earliest = calendar.addingDays(-7, to: startOfToday)
        // An empty workout nobody filled in isn't "missed".
        return fetchPlannedSessions()
            .filter { plannedDay(of: $0) >= earliest && plannedDay(of: $0) < startOfToday && !isBlankPlan($0) }
            .sorted { plannedDay(of: $0) > plannedDay(of: $1) }
            .prefix(limit)
            .map { $0 }
    }

    /// The day a planned session belongs to.
    func plannedDay(of session: WorkoutSession) -> Date {
        session.plannedDate ?? session.date
    }

    // MARK: Health metrics (device-only)

    func healthMetrics(for sessionID: UUID) -> HealthMetrics? {
        var descriptor = FetchDescriptor<HealthMetrics>(predicate: #Predicate { $0.sessionID == sessionID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Stores heart rate / measured energy for a session on this device only.
    /// `bumping: false`: Finish counts its changes once at the end (only the data moves, never the history).
    func recordHealthMetrics(sessionID: UUID, averageHeartRate: Double?, maxHeartRate: Double?, activeEnergy: Double?, bumping: Bool = true) {
        let metrics = healthMetrics(for: sessionID) ?? {
            let created = HealthMetrics(sessionID: sessionID)
            context.insert(created)
            return created
        }()
        if let averageHeartRate, averageHeartRate > 0 { metrics.averageHeartRate = averageHeartRate }
        if let maxHeartRate, maxHeartRate > 0 { metrics.maxHeartRate = maxHeartRate }
        if let activeEnergy, activeEnergy > 0 { metrics.activeEnergyKcal = activeEnergy }
        metrics.updatedAt = Date()
        save(bumping: bumping)
    }

    /// Sets a session's measured numbers to exactly `numbers` (0 where none): a workout continued
    /// after "stopped early" gets the whole workout's, and one part's must not stay as them
    /// (`MeasuredNumbers.combined`). A row of zeros also keeps the detail from reading heart rate
    /// from Apple Health for the whole span, the time between the parts included.
    func replaceHealthMetrics(sessionID: UUID, with numbers: MeasuredNumbers, bumping: Bool = true) {
        let metrics = healthMetrics(for: sessionID) ?? {
            let created = HealthMetrics(sessionID: sessionID)
            context.insert(created)
            return created
        }()
        metrics.averageHeartRate = numbers.averageHeartRate ?? 0
        metrics.maxHeartRate = numbers.maxHeartRate ?? 0
        metrics.activeEnergyKcal = numbers.activeEnergy ?? 0
        metrics.updatedAt = Date()
        save(bumping: bumping)
    }

    // MARK: Streak

    /// The days that count as training: performed George workouts that qualify and – with "Count
    /// Apple Health workouts" on – Health workouts of at least the minimum. The streak, the Progress
    /// days chart, the Today hero and Plan Week all use this one list (see `TrainingDays`), through
    /// `trainingEntries(healthEntries:)`, which keeps it until something changes.
    func uncachedTrainingEntries(healthEntries: [ActivityEntry] = []) -> [ActivityEntry] {
        let s = settings
        // Completed or not: the minimum minutes count (strength work logged without a time counts
        // with 3 sets) – so a 2-minute routine is no training day, as Settings → Streak says.
        // Performed workouts only, without their content (dates, minutes and set counts are fields).
        let workouts = fetchPerformedSessions(scalarsOnly: true).map { session in
            TrainingDays.Workout(date: session.date, minutes: session.durationSeconds / 60, doneSets: session.doneSetCount,
                                 isRescue: session.isRescue, kind: session.kind)
        }
        return TrainingDays.entries(workouts: workouts, health: healthEntries, countHealth: s.countHealthWorkouts,
                                    minimumMinutes: Double(s.minimumMinutes), rescueMinutes: Double(max(1, s.rescueMinutes)))
    }

    // `streakSummary(healthEntries:now:)` is in GeorgeStore+Caches (kept for the day).

    func toggleExcused(weekStart: Date, reason: String = "Break") {
        let cal = calendar
        let start = cal.weekStart(for: weekStart)
        let all = (try? context.fetch(FetchDescriptor<ExcusedWeek>())) ?? []
        // Two devices may each have marked the week before they synced: one tap clears every copy.
        let matches = all.filter { cal.weekStart(for: $0.weekStart) == start }
        if !matches.isEmpty {
            for match in matches { context.delete(match) }
        } else {
            context.insert(ExcusedWeek(weekStart: start, reason: reason))
        }
        save()
    }

    func isExcused(weekStart: Date) -> Bool {
        let cal = calendar
        let start = cal.weekStart(for: weekStart)
        let all = (try? context.fetch(FetchDescriptor<ExcusedWeek>())) ?? []
        return all.contains { cal.weekStart(for: $0.weekStart) == start }
    }

    // MARK: Import

    /// What an import did, with a way back (the toast's Undo).
    struct ImportOutcome {
        var programs: [Program]
        var created: Int
        var replaced: Int
        var undo: () -> Void
    }

    /// The program an imported program goes into: `existing`, else one with the same name.
    func importTarget(for imported: ImportedProgram, into existing: Program?) -> Program? {
        existing ?? fetchPrograms().first { $0.name.caseInsensitiveCompare(imported.name) == .orderedSame }
    }

    /// Creates programs (or adds to an existing one) from a parsed CSV.
    @discardableResult
    func importPrograms(_ imported: [ImportedProgram], into existing: Program? = nil, replaceTemplates: Bool = false) -> [Program] {
        importProgramsWithUndo(imported, into: existing, replaceTemplates: replaceTemplates).programs
    }

    /// What an import does to a program's notes (ImportView's preview).
    func notesChange(for imported: ImportedProgram, into existing: Program?, replace: Bool) -> ProgramCSV.NotesChange {
        guard let target = importTarget(for: imported, into: existing) else { return .unchanged }
        return ProgramCSV.notesChange(existing: target.notes, imported: imported.notes, replace: replace)
    }

    /// Imports and remembers what changed: new programs and templates are removed again by `undo`,
    /// replaced templates get their old content, notes and weekdays back. Without `replaceTemplates`,
    /// a name that's taken gets a number ("UPPER (2)") and imported program notes go below yours –
    /// nothing of yours is overwritten. ImportView writes a backup first.
    func importProgramsWithUndo(_ imported: [ImportedProgram], into existing: Program? = nil, replaceTemplates: Bool) -> ImportOutcome {
        struct TemplateBackup {
            let template: WorkoutTemplate
            let subtitle: String, kindRaw: String, notes: String, scheduleRaw: String, tagsRaw: String
            let contentData: Data?
        }
        var result: [Program] = []
        var createdPrograms: [Program] = []
        var createdTemplates: [WorkoutTemplate] = []
        var backups: [TemplateBackup] = []
        var programNotes: [(Program, String)] = []
        let previousActive = settings.activeProgramID
        for importedProgram in imported {
            let program: Program
            if let match = importTarget(for: importedProgram, into: existing) {
                program = match
            } else {
                let kind = importedProgram.workouts.first?.kind ?? .gym
                program = createProgram(name: importedProgram.name, kind: kind, colorHex: importedProgram.colorHex)
                createdPrograms.append(program)
            }
            // Program notes: replaced only with "Replace templates"; otherwise added below yours.
            let mergedNotes = ProgramCSV.mergedNotes(existing: program.notes, imported: importedProgram.notes, replace: replaceTemplates,
                                                     dateText: Date().formatted(date: .abbreviated, time: .omitted))
            if mergedNotes != program.notes {
                programNotes.append((program, program.notes))
                program.notes = mergedNotes
            }
            var taken = program.orderedTemplates.map(\.name)
            for workout in importedProgram.workouts {
                if replaceTemplates, let old = program.orderedTemplates.first(where: { $0.name.caseInsensitiveCompare(workout.name) == .orderedSame }) {
                    backups.append(TemplateBackup(template: old, subtitle: old.subtitle, kindRaw: old.kindRaw, notes: old.notes,
                                                  scheduleRaw: old.scheduleRaw, tagsRaw: old.tagsRaw, contentData: old.contentData))
                    old.subtitle = workout.subtitle
                    old.kind = workout.kind
                    old.notes = workout.notes
                    old.scheduleDays = workout.scheduleDays
                    old.tags = workout.tags
                    // An explicit replace: even a workout this device can't read (or a newer George
                    // wrote) gets the imported one. The backup written before the import keeps the old.
                    old.storeContent(workout.content, force: true)
                    continue
                }
                let name = ImportNaming.uniqueName(workout.name, taken: taken)
                taken.append(name)
                let template = WorkoutTemplate(name: name, subtitle: workout.subtitle, kind: workout.kind, program: program, content: workout.content)
                template.notes = workout.notes
                template.scheduleDays = workout.scheduleDays
                template.tags = workout.tags
                template.sortIndex = Double(workout.order)
                context.insert(template)
                if !createdPrograms.contains(where: { $0.id == program.id }) { createdTemplates.append(template) }
            }
            program.touch()
            result.append(program)
        }
        save()
        let createdCount = imported.reduce(0) { $0 + $1.workouts.count } - backups.count
        let undo: () -> Void = { [weak self] in
            guard let self else { return }
            for template in createdTemplates { self.context.delete(template) }
            for program in createdPrograms { self.context.delete(program) }
            // Newest first: a template replaced twice (two imported programs into one) ends with its
            // first backup – how it was before the import. The same for program notes.
            for backup in backups.reversed() {
                backup.template.subtitle = backup.subtitle
                backup.template.kindRaw = backup.kindRaw
                backup.template.notes = backup.notes
                backup.template.scheduleRaw = backup.scheduleRaw
                backup.template.tagsRaw = backup.tagsRaw
                // The bytes as they were – not re-encoded, so nothing a newer George added is lost.
                backup.template.restoreContentData(backup.contentData)
            }
            for (program, notes) in programNotes.reversed() where !createdPrograms.contains(where: { $0.id == program.id }) {
                program.notes = notes
            }
            self.settings.activeProgramID = previousActive
            self.save()
            AppLog.info("Import undone", category: "import")
        }
        let replacedCount = Set(backups.map { ObjectIdentifier($0.template) }).count
        return ImportOutcome(programs: result, created: createdCount, replaced: replacedCount, undo: undo)
    }

    /// The sample programs that come with the app (files in `samples/`).
    enum SampleProgram: String, CaseIterable, Identifiable {
        case gym, bandsTennis
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gym: return "Gym"
            case .bandsTennis: return "Bands & Tennis"
            }
        }
        var detail: String {
            switch self {
            case .gym: return "UPPER · LOWER · FULL – a 3-day strength block"
            case .bandsTennis: return "Elastic bands at home, built around tennis"
            }
        }
        var programName: String {
            switch self {
            case .gym: return "Gym – Strength Block"
            case .bandsTennis: return "Elastic Bands – Tennis"
            }
        }
        var fileName: String {
            switch self {
            case .gym: return "gym-strength-block"
            case .bandsTennis: return "elastic-bands-tennis"
            }
        }

        /// The sample as parsed CSV (nil if the file is missing from the bundle).
        var parsed: CSVImportResult? {
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "csv"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                AppLog.warning("Sample \(fileName).csv not found", category: "import")
                return nil
            }
            return try? ProgramCSV.parse(text, defaultProgramName: programName)
        }
    }

    /// Adds a sample program and makes it active. Tapping it again doesn't add copies: the existing
    /// sample program becomes active instead.
    @discardableResult
    func loadSampleProgram(_ sample: SampleProgram = .gym) -> Program? {
        if let existing = fetchPrograms().first(where: { $0.name.caseInsensitiveCompare(sample.programName) == .orderedSame }) {
            if existing.isArchived { existing.isArchived = false }
            setActive(existing)
            return existing
        }
        guard let parsed = sample.parsed else { return nil }
        let programs = importPrograms(parsed.programs, replaceTemplates: true)
        if let first = programs.first { setActive(first) }
        return programs.first
    }

    // MARK: Export

    func exportCSV(for program: Program) -> String {
        let workouts = program.orderedTemplates.enumerated().map { index, template in
            ProgramCSV.ExportWorkout(
                name: template.name, subtitle: template.subtitle, kind: template.kind, order: index + 1,
                scheduleDays: template.scheduleDays, notes: template.notes, tags: template.tags, content: template.content
            )
        }
        // Tags, pictures, the program's notes and color go along, so importing it back with
        // "Replace templates" doesn't wipe them.
        return ProgramCSV.export(programName: program.name, workouts: workouts, unit: unit,
                                 programNotes: program.notes, programColor: program.colorHex)
    }

    /// A readable log for Numbers or Excel (not a backup: it can't be imported back). Days are local
    /// days; activities without sets (tennis, runs) get a row too. Energy is George's estimate –
    /// measured calories stay on the device.
    func exportLogCSV(sessions: [WorkoutSession]) -> String {
        let log = sessions.filter { $0.status.isPerformed }.map { session in
            ProgramCSV.LogSession(
                date: session.date, title: session.title, program: session.program?.name ?? "",
                kind: session.kind, durationSeconds: session.durationSeconds,
                status: session.status.rawValue, content: session.content,
                startedAt: session.startedAt, effort: session.effort, energyKcal: session.energyKcal, notes: session.notes
            )
        }
        return ProgramCSV.exportLog(log, unit: unit, timeZone: calendar.timeZone)
    }
}
