import Foundation
import SwiftData
import BinisoftKit
import GeorgeCore

/// Narrow fetches – only the workouts a question is about, without their content where only numbers
/// and dates are read – and the summary `CloudImportRefresher` compares after each iCloud import to
/// move only the counters an import really changed (see `revision`, `historyRevision`, `liveRevision`).
extension GeorgeStore {
    // MARK: Narrow fetches

    /// Every stored field of a workout but its content: fetches that read only numbers, dates and names
    /// don't load the content (it's read from the store when something asks for it).
    static let sessionScalars: [PartialKeyPath<WorkoutSession>] = [
        \.id, \.title, \.subtitle, \.kindRaw, \.statusRaw, \.plannedDate, \.startedAt, \.endedAt,
        \.accumulatedSeconds, \.resumedAt, \.notes, \.tagsRaw, \.priorityRaw, \.colorHex, \.isPinned,
        \.isFavorite, \.isRescue, \.effort, \.energyBefore, \.energyKcal, \.healthWorkoutID, \.recordedOnWatch,
        \.liveDeviceID, \.liveClaimedAt, \.templateID, \.templateName, \.createdAt, \.updatedAt,
        \.exerciseNames, \.exerciseCount, \.setCount, \.doneSetCount, \.volumeKg,
    ]

    /// Completed and stopped-early workouts (`scalarsOnly`: without their content).
    func fetchPerformedSessions(scalarsOnly: Bool = false) -> [WorkoutSession] {
        let completed = SessionStatus.completed.rawValue
        let partial = SessionStatus.partial.rawValue
        var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.statusRaw == completed || $0.statusRaw == partial })
        if scalarsOnly { descriptor.propertiesToFetch = Self.sessionScalars }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Workouts that started, are planned, ended or were created on or after `start` – a superset of
    /// those dated then (`date`, `plannedDate`); callers filter exactly. Fetched with a predicate
    /// instead of every workout with its content; a store that can't run it gets the full list,
    /// filtered here.
    func fetchSessions(datedFrom start: Date, scalarsOnly: Bool = false) -> [WorkoutSession] {
        let past = Date.distantPast
        var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate<WorkoutSession> { session in
            (session.startedAt ?? past) >= start || (session.plannedDate ?? past) >= start
                || (session.endedAt ?? past) >= start || session.createdAt >= start
        })
        if scalarsOnly { descriptor.propertiesToFetch = Self.sessionScalars }
        do {
            return try context.fetch(descriptor)
        } catch {
            if !Self.datedFetchFailed {
                Self.datedFetchFailed = true
                AppLog.warning("Dated fetch not supported, reading all workouts: \(error)", category: "store")
            }
            return fetchSessions().filter { session in
                session.date >= start || (session.plannedDate ?? past) >= start || (session.endedAt ?? past) >= start
            }
        }
    }

    /// Logged once: the dated predicate failed and the full list is read instead.
    private static var datedFetchFailed = false

    /// The last `limit` performed workouts, newest first – looked for in the last weeks first, the whole
    /// log only when there are fewer.
    func recentPerformed(limit: Int) -> [WorkoutSession] {
        let cal = calendar
        let today = cal.startOfDay(for: Date())
        for days in [21, 182] {
            let since = cal.addingDays(-days, to: today)
            let found = fetchSessions(datedFrom: since).filter { $0.status.isPerformed && $0.date >= since }
            if found.count >= limit { return Array(found.sorted { $0.date > $1.date }.prefix(limit)) }
        }
        return Array(fetchPerformedSessions().sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Each performed workout's template (for "compared with last time"), without loading the workouts.
    func performedTemplateIDs() -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for session in fetchPerformedSessions(scalarsOnly: true) {
            if let templateID = session.templateID { result[session.id] = templateID }
        }
        return result
    }

    /// The user's own entry (notes, links, picture) for an exercise key – one index per revision instead
    /// of a query per exercise card (live mode). Two devices' copies: the one `UserExercise.preferred` picks.
    func userExercise(forKey key: String) -> UserExercise? {
        if userExerciseCache?.revision != revision {
            let all = (try? context.fetch(FetchDescriptor<UserExercise>())) ?? []
            var entries: [String: UserExercise] = [:]
            for (entryKey, copies) in Dictionary(grouping: all, by: \.key) {
                entries[entryKey] = UserExercise.preferred(copies, key: entryKey)
            }
            userExerciseCache = (revision: revision, entries: entries)
        }
        guard let entry = userExerciseCache?.entries[key], entry.modelContext != nil, !entry.isDeleted else { return nil }
        return entry
    }

    // MARK: After an iCloud import

    /// What the store holds, cheaply: every performed workout's stamp, plans, templates and programs row
    /// by row (a few fields each), the size and newest change of the other tables, and the workouts in
    /// progress. `CloudImportRefresher` compares it after each import.
    func syncFingerprint() -> SyncFingerprint {
        var performed: [UUID: HistoryStamp] = [:]
        for session in fetchPerformedSessions(scalarsOnly: true) { performed[session.id] = session.historyStamp }
        var running: [UUID: RunningStamp] = [:]
        for session in activeSessions { running[session.id] = session.runningStamp }
        let planned = SessionStatus.planned.rawValue
        let skipped = SessionStatus.skipped.rawValue
        let plans = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.statusRaw == planned || $0.statusRaw == skipped })
        // Plans, templates and programs row by row: a plan moved to another day, a new title, a program
        // archived or a restore's older dates don't stamp a newer date.
        let planFields: [PartialKeyPath<WorkoutSession>] = [\.id, \.statusRaw, \.plannedDate, \.title, \.updatedAt]
        let planStamp = rowStamp(plans, fields: planFields) { (session: WorkoutSession) -> PlanRow in
            PlanRow(id: session.id, status: session.statusRaw, plannedDate: session.plannedDate, title: session.title,
                    updatedAt: session.updatedAt)
        }
        let templateFields: [PartialKeyPath<WorkoutTemplate>] = [
            \.id, \.name, \.kindRaw, \.scheduleRaw, \.isPinned, \.isFavorite, \.sortIndex, \.updatedAt,
        ]
        let templateStamp = rowStamp(FetchDescriptor<WorkoutTemplate>(), fields: templateFields) { (template: WorkoutTemplate) -> TemplateStampRow in
            TemplateStampRow(id: template.id, name: template.name, kind: template.kindRaw, schedule: template.scheduleRaw,
                        isPinned: template.isPinned, isFavorite: template.isFavorite, sortIndex: template.sortIndex,
                        updatedAt: template.updatedAt)
        }
        let programFields: [PartialKeyPath<Program>] = [\.id, \.name, \.kindRaw, \.isArchived, \.isPinned, \.sortIndex, \.updatedAt]
        let programStamp = rowStamp(FetchDescriptor<Program>(), fields: programFields) { (program: Program) -> ProgramStampRow in
            ProgramStampRow(id: program.id, name: program.name, kind: program.kindRaw, isArchived: program.isArchived,
                       isPinned: program.isPinned, sortIndex: program.sortIndex, updatedAt: program.updatedAt)
        }
        let tables: [String: TableStamp] = [
            "plans": planStamp,
            "templates": templateStamp,
            "programs": programStamp,
            "settings": tableStamp(FetchDescriptor<SyncedSettings>(), newest: \.updatedAt),
            "exercises": tableStamp(FetchDescriptor<UserExercise>(), newest: \.updatedAt),
            "breaks": tableStamp(FetchDescriptor<ExcusedWeek>(), newest: \.createdAt),
            "energy": tableStamp(FetchDescriptor<EnergyCheckIn>(), newest: \.date),
        ]
        return SyncFingerprint(performed: performed, tables: tables, running: running)
    }

    /// A table's size and newest date: a count and one row, never the whole table.
    private func tableStamp<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, newest date: KeyPath<T, Date>) -> TableStamp {
        let count = (try? context.fetchCount(descriptor)) ?? 0
        var latest = descriptor
        latest.sortBy = [SortDescriptor(date, order: .reverse)]
        latest.fetchLimit = 1
        latest.propertiesToFetch = [date]
        let newest = (try? context.fetch(latest))?.first.map { $0[keyPath: date] }
        return TableStamp(count: count, newest: newest)
    }

    /// A small table read row by row – only `fields` are loaded (never a workout's content).
    private func rowStamp<T: PersistentModel, Row: Hashable>(_ descriptor: FetchDescriptor<T>, fields: [PartialKeyPath<T>],
                                                              row: (T) -> Row) -> TableStamp {
        var fetch = descriptor
        fetch.propertiesToFetch = fields
        let rows = ((try? context.fetch(fetch)) ?? []).map(row)
        return TableStamp(rows: rows, newest: nil)
    }
}

/// What the iCloud fingerprint compares of a planned or skipped workout, a template and a program.
private struct PlanRow: Hashable {
    let id: UUID
    let status: String
    let plannedDate: Date?
    let title: String
    let updatedAt: Date
}

private struct TemplateStampRow: Hashable {
    let id: UUID
    let name: String
    let kind: String
    let schedule: String
    let isPinned: Bool
    let isFavorite: Bool
    let sortIndex: Double
    let updatedAt: Date
}

private struct ProgramStampRow: Hashable {
    let id: UUID
    let name: String
    let kind: String
    let isArchived: Bool
    let isPinned: Bool
    let sortIndex: Double
    let updatedAt: Date
}

extension WorkoutSession {
    /// What the history index compares to see whether this workout changed (`HistoryIndex`).
    var historyStamp: HistoryStamp {
        HistoryStamp(updatedAt: updatedAt, status: statusRaw, title: title, kind: kindRaw, startedAt: startedAt,
                     plannedDate: plannedDate, endedAt: endedAt, accumulatedSeconds: accumulatedSeconds,
                     resumedAt: resumedAt, energyKcal: energyKcal, effort: effort)
    }

    /// A workout in progress as an import compares it (`SyncFingerprint`).
    var runningStamp: RunningStamp {
        RunningStamp(state: RunningStamp.State(owner: liveDeviceID, claimedAt: liveClaimedAt, isPaused: resumedAt == nil),
                     progress: RunningStamp.Progress(updatedAt: updatedAt, doneSets: doneSetCount, totalSets: setCount))
    }
}
