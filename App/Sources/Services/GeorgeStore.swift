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

    /// Bumped after bulk changes so dependent views (streak, stats) recompute.
    private(set) var revision = 0

    init(container: ModelContainer) {
        self.container = container
    }

    /// A routine template started from the streak rescue sheet: the session it starts counts as a
    /// rescue workout (a few minutes to get from the sheet to the start).
    @ObservationIgnored var pendingRescue: (templateID: UUID, at: Date)?
    /// The energy rhythm's next low day, cached per revision and day (see `expectedLowEnergyDay`).
    @ObservationIgnored var lowEnergyCache: (revision: Int, day: Date, value: Date?)?
    /// Apple Health's latest body weight (kept on this device, set by the views that read Health).
    /// Energy estimates use it before the body weight from Settings.
    @ObservationIgnored var healthBodyMassKg: Double?

    func bump() { revision &+= 1 }

    func save() {
        save(bumping: true)
    }

    /// Saves; `bumping: false` skips the revision bump (live set edits – dashboards don't need to
    /// recompute on every keystroke; they refresh when the workout starts, finishes or is discarded).
    func save(bumping: Bool) {
        do {
            if context.hasChanges { try context.save() }
        } catch {
            print("George save failed: \(error)")
        }
        if bumping { bump() }
    }

    /// Saves changes without putting them on the undo stack (live sets must not be undone by ⌘Z or shake).
    func saveWithoutUndo(bumping: Bool = false, _ changes: () -> Void) {
        let manager = context.undoManager
        manager?.disableUndoRegistration()
        changes()
        do {
            if context.hasChanges { try context.save() }
        } catch {
            print("George save failed: \(error)")
        }
        manager?.enableUndoRegistration()
        if bumping { bump() }
    }

    // MARK: Settings

    @ObservationIgnored private var cachedSettings: SyncedSettings?

    var settings: SyncedSettings {
        if let cachedSettings, cachedSettings.modelContext != nil { return cachedSettings }
        let all = (try? context.fetch(FetchDescriptor<SyncedSettings>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let first = all.first {
            // Sync can create duplicates on first launch of a second device: keep the oldest.
            for extra in all.dropFirst() { context.delete(extra) }
            cachedSettings = first
            return first
        }
        let fresh = SyncedSettings()
        context.insert(fresh)
        cachedSettings = fresh
        return fresh
    }

    var calendar: Calendar { Calendar.training(firstWeekday: settings.weekStartsOn) }
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
        return fetchPrograms(includeArchived: false).first
    }

    var activeSession: WorkoutSession? {
        fetchSessions().filter { $0.status == .active }.sorted { $0.date > $1.date }.first
    }

    /// Performed sessions as plain records for statistics.
    func performedRecords() -> [SessionRecord] {
        fetchSessions().filter { $0.status.isPerformed }.map { $0.record() }
    }

    // MARK: Programs

    @discardableResult
    func createProgram(name: String, kind: WorkoutKind = .gym, colorHex: String? = nil, symbol: String? = nil) -> Program {
        let program = Program(name: name.isEmpty ? "New Program" : name, kind: kind, colorHex: colorHex, symbol: symbol)
        program.sortIndex = (fetchPrograms().map(\.sortIndex).max() ?? 0) + 1
        context.insert(program)
        if settings.activeProgramID == nil { settings.activeProgramID = program.id }
        save()
        return program
    }

    func setActive(_ program: Program) {
        settings.activeProgramID = program.id
        settings.updatedAt = Date()
        save()
    }

    func delete(_ program: Program) {
        if settings.activeProgramID == program.id { settings.activeProgramID = nil }
        context.delete(program)
        save()
    }

    func duplicate(_ program: Program) -> Program {
        let copy = createProgram(name: program.name + " copy", kind: program.kind, colorHex: program.colorHex, symbol: program.symbol)
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
        let count = fetchSessions().filter { session in
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
        save()
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
        save()
        return session
    }

    /// Log a workout after the fact (marks every set done). `bodyMassKg`: Apple Health's latest
    /// value when there is one – otherwise the one from Settings is used.
    @discardableResult
    func logPastSession(from template: WorkoutTemplate, date: Date, minutes: Int, bodyMassKg: Double? = nil) -> WorkoutSession {
        let session = makeSession(from: template, date: date, start: false)
        markPerformed(session, date: date, minutes: minutes, bodyMassKg: bodyMassKg)
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

    func trash(_ sessions: [WorkoutSession], toasts: ToastCenter) {
        guard !sessions.isEmpty else { return }
        for session in sessions { context.delete(session) }
        save()
        toasts.show(sessions.count == 1 ? "Deleted 1 workout" : "Deleted \(sessions.count) workouts", symbol: "trash.fill", undo: undoLastChange())
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
                markPerformed(session, date: min(Date(), session.plannedDate ?? session.date), minutes: defaultMinutes(for: session), saving: false)
                continue
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
        let programName = "Stretch & Yoga"
        let program = fetchPrograms(includeArchived: false).first { $0.name == programName }
            ?? createProgram(name: programName, kind: .stretch, symbol: "figure.yoga")
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

    /// Push a session's edits back into the template it came from.
    func updateTemplate(from session: WorkoutSession) {
        guard let template = template(id: session.templateID) else { return }
        template.content = session.content.asTemplate()
        save()
    }

    func sessionDiffersFromTemplate(_ session: WorkoutSession) -> Bool {
        guard let template = template(id: session.templateID) else { return false }
        return session.content.structureDiffers(from: template.content)
    }

    // MARK: Suggestions

    /// The template for a day: the one scheduled on that weekday (unless it's done that day already),
    /// otherwise the next one in the program's rotation (the one after the most recently used).
    func suggestedTemplate(in program: Program?, on date: Date = Date()) -> WorkoutTemplate? {
        guard let program else { return nil }
        let templates = program.orderedTemplates
        guard !templates.isEmpty else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        if let scheduled = templates.first(where: { $0.scheduleDays.contains(weekday) }) {
            let doneThatDay = program.allSessions.contains { $0.templateID == scheduled.id && calendar.isDate($0.date, inSameDayAs: date) && $0.status.isPerformed }
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
            .filter { plannedDay(of: $0) >= startOfToday && plannedDay(of: $0) < endOfToday }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Planned sessions from the last 7 days that weren't done ("Missed"), most recent first. Older
    /// ones stay in the Workouts list but no longer ask for attention.
    func overdueSessions(limit: Int = 5) -> [WorkoutSession] {
        let startOfToday = calendar.startOfDay(for: Date())
        let earliest = calendar.addingDays(-7, to: startOfToday)
        return fetchPlannedSessions()
            .filter { plannedDay(of: $0) >= earliest && plannedDay(of: $0) < startOfToday }
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
    func recordHealthMetrics(sessionID: UUID, averageHeartRate: Double?, maxHeartRate: Double?, activeEnergy: Double?) {
        let metrics = healthMetrics(for: sessionID) ?? {
            let created = HealthMetrics(sessionID: sessionID)
            context.insert(created)
            return created
        }()
        if let averageHeartRate, averageHeartRate > 0 { metrics.averageHeartRate = averageHeartRate }
        if let maxHeartRate, maxHeartRate > 0 { metrics.maxHeartRate = maxHeartRate }
        if let activeEnergy, activeEnergy > 0 { metrics.activeEnergyKcal = activeEnergy }
        metrics.updatedAt = Date()
        save()
    }

    // MARK: Streak

    func streakSummary(healthEntries: [ActivityEntry] = []) -> StreakSummary {
        let s = settings
        let minimum = Double(s.minimumMinutes)
        let rescueMinimum = Double(max(1, s.rescueMinutes))
        var entries: [ActivityEntry] = []
        for session in fetchSessions() where session.status.isPerformed {
            let minutes = session.durationSeconds / 60
            // Completed or not: the minimum minutes count (strength work logged without a time counts
            // with 3 sets) – so a 2-minute routine is no training day, as Settings → Streak says.
            let qualifies = StreakRules.qualifies(
                minutes: minutes, doneSets: session.doneSetCount, isRescue: session.isRescue, kind: session.kind,
                minimumMinutes: minimum, rescueMinutes: rescueMinimum
            )
            if qualifies {
                entries.append(ActivityEntry(date: session.date, minutes: minutes, isRescue: session.isRescue, source: .george))
            }
        }
        if s.countHealthWorkouts {
            entries.append(contentsOf: healthEntries.filter { $0.minutes >= minimum })
        }
        let excused = (try? context.fetch(FetchDescriptor<ExcusedWeek>())) ?? []
        return StreakEngine(calendar: calendar).evaluate(
            entries: entries,
            excusedWeeks: Set(excused.map(\.weekStart)),
            config: s.streakConfig,
            now: Date()
        )
    }

    func toggleExcused(weekStart: Date, reason: String = "Break") {
        let start = calendar.weekStart(for: weekStart)
        let all = (try? context.fetch(FetchDescriptor<ExcusedWeek>())) ?? []
        if let existing = all.first(where: { calendar.weekStart(for: $0.weekStart) == start }) {
            context.delete(existing)
        } else {
            context.insert(ExcusedWeek(weekStart: start, reason: reason))
        }
        save()
    }

    func isExcused(weekStart: Date) -> Bool {
        let start = calendar.weekStart(for: weekStart)
        let all = (try? context.fetch(FetchDescriptor<ExcusedWeek>())) ?? []
        return all.contains { calendar.weekStart(for: $0.weekStart) == start }
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

    /// Imports and remembers what changed: new programs and templates are removed again by `undo`,
    /// replaced templates get their old content, notes and weekdays back. Without `replaceTemplates`,
    /// a name that's taken gets a number ("UPPER (2)") – nothing of yours is overwritten.
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
            if !importedProgram.notes.isEmpty {
                programNotes.append((program, program.notes))
                program.notes = importedProgram.notes
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
                    old.content = workout.content
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
            for backup in backups {
                backup.template.subtitle = backup.subtitle
                backup.template.kindRaw = backup.kindRaw
                backup.template.notes = backup.notes
                backup.template.scheduleRaw = backup.scheduleRaw
                backup.template.tagsRaw = backup.tagsRaw
                backup.template.content = WorkoutContent.decode(backup.contentData)
            }
            for (program, notes) in programNotes where !createdPrograms.contains(where: { $0.id == program.id }) {
                program.notes = notes
            }
            self.settings.activeProgramID = previousActive
            self.save()
            AppLog.info("Import undone", category: "import")
        }
        return ImportOutcome(programs: result, created: createdCount, replaced: backups.count, undo: undo)
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
                scheduleDays: template.scheduleDays, notes: template.notes, content: template.content
            )
        }
        return ProgramCSV.export(programName: program.name, workouts: workouts, unit: unit)
    }

    func exportLogCSV(sessions: [WorkoutSession]) -> String {
        let log = sessions.filter { $0.status.isPerformed }.map { session in
            ProgramCSV.LogSession(
                date: session.date, title: session.title, program: session.program?.name ?? "",
                kind: session.kind, durationSeconds: session.durationSeconds,
                status: session.status.rawValue, content: session.content
            )
        }
        return ProgramCSV.exportLog(log, unit: unit)
    }
}
