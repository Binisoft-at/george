import Foundation
import SwiftData
import BinisoftKit
import GeorgeCore

/// Planning, after-the-fact logging and Today's state: planned sessions that are reused instead of
/// duplicated, auto titles that follow the date, "done today" and rest days, the week plan, reminders.
extension GeorgeStore {
    // MARK: Planned sessions

    /// A planned session of `template` dated in the last two days or today. Starting the template starts
    /// that one, so starting UPPER doesn't put a second UPPER next to the planned one.
    func plannedSession(for template: WorkoutTemplate) -> WorkoutSession? {
        let startOfToday = calendar.startOfDay(for: Date())
        let earliest = calendar.addingDays(-2, to: startOfToday)
        let end = calendar.addingDays(1, to: startOfToday)
        return fetchPlannedSessions()
            .filter { $0.templateID == template.id && plannedDay(of: $0) >= earliest && plannedDay(of: $0) < end }
            .sorted { plannedDay(of: $0) > plannedDay(of: $1) }
            .first
    }

    /// What a Start button for `template` starts: its planned session (see `plannedSession(for:)`) or a new one.
    func startTarget(for template: WorkoutTemplate) -> LiveWorkoutController.StartTarget {
        if let planned = plannedSession(for: template) { return .session(planned) }
        return .template(template)
    }

    /// Starts `template` through `live.requestStart` – its planned session when there is one
    /// ("Started your planned UPPER").
    func requestStart(_ template: WorkoutTemplate, live: LiveWorkoutController, toasts: ToastCenter? = nil) {
        guard let planned = plannedSession(for: template) else {
            live.requestStart(.template(template))
            return
        }
        live.requestStart(.session(planned))
        if live.session?.id == planned.id {
            toasts?.show("Started your planned \(template.name)", symbol: "calendar")
        }
    }

    /// The name a session goes by in lists and on Today (its template's name, else its title).
    func displayName(of session: WorkoutSession) -> String {
        session.templateName.isEmpty ? (session.title.isEmpty ? "Workout" : session.title) : session.templateName
    }

    // MARK: Auto titles

    /// The template name an automatic title was made from on `date` (nil when the title was typed).
    func autoTitleName(of session: WorkoutSession, on date: Date) -> String? {
        let names = session.templateName.isEmpty ? ["Workout", "Rescue"] : [session.templateName]
        return SessionNamer(pattern: settings.namingPattern, calendar: calendar)
            .generatedName(of: session.title, templateNames: names, date: date)
    }

    func isAutoTitle(_ session: WorkoutSession, on date: Date? = nil) -> Bool {
        autoTitleName(of: session, on: date ?? session.date) != nil
    }

    /// After a date change: an automatic title follows the new date ("W46: 2 UPPER - 10.11" →
    /// "W47: 1 UPPER - 16.11"). Typed titles are never touched.
    func retitleIfAuto(_ session: WorkoutSession, previousDate: Date) {
        guard !calendar.isDate(previousDate, inSameDayAs: session.date),
              let name = autoTitleName(of: session, on: previousDate) else { return }
        session.title = title(for: name, on: session.date, excluding: session.id)
    }

    // MARK: Done, but not logged

    /// A sensible length for a session that's logged afterwards: what it took, else its planned length.
    func defaultMinutes(for session: WorkoutSession) -> Int {
        Self.defaultMinutes(for: session)
    }

    static func defaultMinutes(for session: WorkoutSession) -> Int {
        if session.durationSeconds > 0 { return max(5, Int((session.durationSeconds / 60).rounded())) }
        let estimated = Double(session.content.estimatedSeconds()) / 60
        guard estimated > 0 else { return 40 }
        return max(5, Int((estimated / 5).rounded()) * 5)
    }

    /// "I did it but didn't log it": every set ticked with its planned numbers, the time and length set,
    /// energy estimated. `bodyMassKg`: Apple Health's latest value when there is one.
    func markPerformed(_ session: WorkoutSession, date: Date, minutes: Int, bodyMassKg: Double? = nil, saving: Bool = true) {
        let previousDate = session.date
        let seconds = Double(max(1, minutes) * 60)
        var content = session.content
        for item in content.allItems { content.setAllSets(of: item.id, done: true, at: date) }
        content.markAllDone(at: date)
        session.content = content
        session.plannedDate = date
        session.startedAt = date
        session.resumedAt = nil
        session.endedAt = date.addingTimeInterval(seconds)
        session.accumulatedSeconds = seconds
        session.status = .completed
        session.energyKcal = EnergyEstimator.kilocalories(
            kind: session.kind, durationSeconds: seconds, bodyMassKg: bodyMassKg ?? healthBodyMassKg ?? settings.bodyMassKg,
            effort: session.effort > 0 ? session.effort : nil
        )
        retitleIfAuto(session, previousDate: previousDate)
        if saving { save() }
    }

    /// Back to "planned": a performed session whose ticks were all taken back.
    func markNotDone(_ session: WorkoutSession) {
        if session.plannedDate == nil { session.plannedDate = session.date }
        session.status = .planned
        session.startedAt = nil
        session.endedAt = nil
        session.resumedAt = nil
        session.accumulatedSeconds = 0
        session.energyKcal = 0
        save()
    }

    /// Status after editing a performed session's sets: all done → completed, some → stopped early.
    /// Returns true when nothing is ticked any more (the view asks "Mark as not done?").
    @discardableResult
    func deriveStatus(of session: WorkoutSession, from content: WorkoutContent) -> Bool {
        guard session.status.isPerformed, content.totalSets > 0 else { return false }
        switch content.performedState {
        case .all:
            if session.status != .completed { session.status = .completed }
        case .some:
            if session.status != .partial { session.status = .partial }
        case .none:
            return true
        }
        return false
    }

    // MARK: Activities without a template

    /// Tennis, a run, a class: just the time, the kind and how hard it was.
    @discardableResult
    func logActivity(kind: WorkoutKind, name: String, start: Date, minutes: Int, effort: Int, notes: String = "", bodyMassKg: Double? = nil) -> WorkoutSession {
        let seconds = Double(max(1, minutes) * 60)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? kind.displayName : trimmed
        let session = WorkoutSession(title: title(for: base, on: start), kind: kind, status: .completed, plannedDate: start)
        session.templateName = base
        session.startedAt = start
        session.endedAt = start.addingTimeInterval(seconds)
        session.accumulatedSeconds = seconds
        session.effort = max(0, min(10, effort))
        session.notes = notes
        session.energyKcal = EnergyEstimator.kilocalories(
            kind: kind, durationSeconds: seconds, bodyMassKg: bodyMassKg ?? healthBodyMassKg ?? settings.bodyMassKg, effort: effort > 0 ? effort : nil
        )
        context.insert(session)
        save()
        AppLog.info("Activity logged (\(kind.rawValue), \(minutes) min)", category: "store")
        return session
    }

    // MARK: Today

    /// The active program's template for a day (its weekday's template, else the rotation) – e.g. to
    /// preselect the template when planning for that day.
    func suggestedTemplate(for date: Date) -> WorkoutTemplate? {
        suggestedTemplate(in: activeProgram, on: date)
    }

    /// Workouts done today, the latest first.
    func performedToday() -> [WorkoutSession] {
        fetchSessions()
            .filter { $0.status.isPerformed && calendar.isDateInToday($0.date) }
            .sorted { ($0.endedAt ?? $0.date) > ($1.endedAt ?? $1.date) }
    }

    /// What comes after today: a planned session, a template scheduled on that weekday – or, without
    /// either in the next week, the program's rotation (no day).
    struct NextUp {
        var name: String
        var date: Date?
        var template: WorkoutTemplate?
        var session: WorkoutSession?
    }

    func nextUp(after day: Date = Date()) -> NextUp? {
        let start = calendar.startOfDay(for: day)
        let planned = fetchPlannedSessions()
        let program = activeProgram
        let templates = program?.orderedTemplates ?? []
        for offset in 1...7 {
            let date = calendar.addingDays(offset, to: start)
            if let session = planned.filter({ calendar.isDate(plannedDay(of: $0), inSameDayAs: date) }).min(by: { $0.createdAt < $1.createdAt }) {
                return NextUp(name: displayName(of: session), date: date, template: template(id: session.templateID), session: session)
            }
            let weekday = calendar.component(.weekday, from: date)
            if let template = templates.first(where: { $0.scheduleDays.contains(weekday) }) {
                return NextUp(name: template.name, date: date, template: template, session: nil)
            }
        }
        guard let template = suggestedTemplate(in: program) else { return nil }
        return NextUp(name: template.name, date: nil, template: template, session: nil)
    }

    /// The program puts its templates on weekdays, and none is on `date`'s weekday.
    func isUnscheduledDay(_ date: Date = Date(), in program: Program?) -> Bool {
        let templates = program?.orderedTemplates ?? []
        guard templates.contains(where: { !$0.scheduleDays.isEmpty }) else { return false }
        let weekday = calendar.component(.weekday, from: date)
        return !templates.contains { $0.scheduleDays.contains(weekday) }
    }

    /// "Mon", "tomorrow", "today".
    func shortDay(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    // MARK: Energy forecast

    /// The low day the energy rhythm expects within the next `days` days (start of day), if any.
    func expectedLowEnergyDay(within days: Int = 3) -> Date? {
        let today = calendar.startOfDay(for: Date())
        let low: Date?
        if let cache = lowEnergyCache, cache.revision == revision, cache.day == today {
            low = cache.value
        } else {
            let entries = fetchEnergy().map { EnergyEntry(date: $0.date, level: $0.level) }
            let insights = EnergyAnalysis.analyze(entries: entries, calendar: calendar)
            let next: Date? = insights.cycle?.nextLow
            low = next.map { calendar.startOfDay(for: $0) }
            lowEnergyCache = (revision: revision, day: today, value: low)
        }
        guard let low, low >= today, calendar.daysBetween(today, low) <= days else { return nil }
        return low
    }

    // MARK: Plan the week

    /// Workouts for the next `days` days: templates on their weekdays, otherwise the rotation spread
    /// over the weekly goal. Days that already have a workout are left free; the expected low-energy
    /// day is marked.
    func proposeWeek(from day: Date = Date(), days: Int = 7) -> [PlannedDay] {
        guard let program = activeProgram else { return [] }
        let templates = program.orderedTemplates
        guard !templates.isEmpty else { return [] }
        let start = calendar.startOfDay(for: day)
        let end = calendar.addingDays(days, to: start)
        let sessions = fetchSessions().filter { $0.status != .skipped }
        var busy = Set<Date>()
        for session in sessions {
            let date = calendar.startOfDay(for: session.status == .planned ? plannedDay(of: session) : session.date)
            if date >= start && date < end { busy.insert(date) }
        }
        let weekStart = calendar.weekStart(for: start)
        let trained = Set(sessions.filter { $0.status.isPerformed && calendar.weekStart(for: $0.date) == weekStart }
            .map { calendar.startOfDay(for: $0.date) }).count
        let suggestion = suggestedTemplate(in: program, on: start)
        let rotationStart = suggestion.flatMap { s in templates.firstIndex { $0.id == s.id } } ?? 0
        return WeekPlanner.propose(
            templates: templates.map { PlannableTemplate(id: $0.id, name: $0.name, scheduleDays: $0.scheduleDays) },
            rotationStart: rotationStart, weeklyGoal: settings.weeklyGoal, trainedThisWeek: trained,
            busyDays: busy, lowEnergyDay: expectedLowEnergyDay(within: days), from: start, days: days, calendar: calendar
        )
    }

    /// Creates the planned sessions in one go. Returns them (for the toast's Undo).
    @discardableResult
    func planWeek(_ entries: [(date: Date, template: WorkoutTemplate)]) -> [WorkoutSession] {
        let sessions = entries.sorted { $0.date < $1.date }.map { entry in
            makeSession(from: entry.template, date: calendar.startOfDay(for: entry.date), start: false)
        }
        AppLog.info("Week planned (\(sessions.count) workouts)", category: "store")
        return sessions
    }

    /// Removes planned sessions again (Undo after planning).
    func removePlanned(_ sessions: [WorkoutSession]) {
        for session in sessions where session.status == .planned { context.delete(session) }
        save()
    }

    /// A letter for the coming days on the week strip: the planned workout's initial, or the initial of
    /// the template scheduled on that weekday (`isPlanned` false).
    struct DayMark {
        var initial: String
        var isPlanned: Bool
        /// The template scheduled that day (not planned yet) – a tap on the dot plans it.
        var templateID: UUID? = nil
    }

    func dayMarks(for week: CurrentWeek) -> [Date: DayMark] {
        let today = calendar.startOfDay(for: Date())
        let planned = fetchPlannedSessions()
        let templates = activeProgram?.orderedTemplates ?? []
        func initial(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "•"
        }
        var result: [Date: DayMark] = [:]
        for dot in week.dots where !dot.didWorkout && calendar.startOfDay(for: dot.date) >= today {
            if let session = planned.first(where: { calendar.isDate(plannedDay(of: $0), inSameDayAs: dot.date) }) {
                result[dot.date] = DayMark(initial: initial(displayName(of: session)), isPlanned: true)
            } else if let template = templates.first(where: { $0.scheduleDays.contains(calendar.component(.weekday, from: dot.date)) }) {
                result[dot.date] = DayMark(initial: initial(template.name), isPlanned: false, templateID: template.id)
            }
        }
        return result
    }

    // MARK: Reminders

    /// Training days in the next `days` days (start of day → workout name): planned sessions, else the
    /// active program's template on that weekday. Days already trained are left out.
    func reminderWorkouts(days: Int = 7) -> [Date: String] {
        let start = calendar.startOfDay(for: Date())
        let end = calendar.addingDays(days, to: start)
        let trainedToday = !performedToday().isEmpty
        var result: [Date: String] = [:]
        for session in fetchPlannedSessions().sorted(by: { $0.createdAt < $1.createdAt }) {
            let day = calendar.startOfDay(for: plannedDay(of: session))
            guard day >= start, day < end, result[day] == nil else { continue }
            result[day] = displayName(of: session)
        }
        let templates = activeProgram?.orderedTemplates ?? []
        for offset in 0..<days {
            let day = calendar.addingDays(offset, to: start)
            guard result[day] == nil else { continue }
            let weekday = calendar.component(.weekday, from: day)
            if let template = templates.first(where: { $0.scheduleDays.contains(weekday) }) {
                result[day] = template.name
            }
        }
        if trainedToday { result[start] = nil }
        return result
    }

    // MARK: Adding exercises

    /// A new exercise for a workout or template: the library's defaults – or, when it was done before,
    /// last time's working sets as the new plan (warm-ups left out).
    func prefilledItem(from exercise: LibraryExercise, custom: UserExercise? = nil) -> WorkoutItem {
        var item = exercise.makeItem(defaultRest: nil)
        if exercise.id.hasPrefix("name:") { item.exerciseID = nil }
        if let custom {
            item.links = custom.links
            if !custom.imageURL.isEmpty { item.imageURL = custom.imageURL }
        }
        if let last = PreviousPerformanceCache.shared.sets(for: item.exerciseKey, store: self) {
            let working = last.filter { $0.isDone && $0.kind != .warmup }.map { $0.promotedToTarget() }
            if !working.isEmpty { item.sets = working }
        }
        return item
    }

    /// Appends exercises to a template.
    func add(_ items: [WorkoutItem], to template: WorkoutTemplate) {
        var content = template.content
        content.append(items: items, asGroup: false)
        template.content = content
        template.program?.touch()
        save()
    }
}
