import Foundation
import SwiftData
import BinisoftKit
import GeorgeCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Prefs {
    /// When the last full backup was written – automatic or exported (seconds since 2001, 0 = never).
    static let lastBackupAt = "lastBackupAt"
}

/// Full backups (Settings → Import & Export): the file you save, the automatic ones in
/// Documents/Backups (weekly and before every import or restore, the last 8 kept), and restoring one
/// by merging it back. iCloud sync is no backup – a deletion reaches every device within seconds.
/// Nothing here touches the CloudKit schema: a backup is a plain file outside the synced store.
extension GeorgeStore {
    // MARK: Writing

    /// Everything synced, as a backup (Health numbers stay on the device and in Health).
    func makeBackupArchive(reason: BackupReason) -> BackupArchive {
        var archive = BackupArchive()
        archive.createdAt = Date()
        archive.reason = reason.rawValue
        archive.appVersion = AppVersion.main.display
        archive.programs = fetchPrograms().map { Self.record($0) }
        archive.templates = fetchTemplates().map { Self.record($0) }
        archive.sessions = fetchSessions().map { Self.record($0) }
        archive.energyCheckIns = ((try? context.fetch(FetchDescriptor<EnergyCheckIn>())) ?? []).map { Self.record($0) }
        archive.exercises = ((try? context.fetch(FetchDescriptor<UserExercise>())) ?? []).map { Self.record($0) }
        archive.excusedWeeks = ((try? context.fetch(FetchDescriptor<ExcusedWeek>())) ?? []).map { Self.record($0) }
        // Not `settings`: that getter creates the record when there is none.
        let settingsRecords = (try? context.fetch(FetchDescriptor<SyncedSettings>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        archive.settings = settingsRecords.first.map { Self.record($0) }
        return archive
    }

    /// A backup file's bytes (Export Full Backup).
    func backupData() throws -> Data {
        try makeBackupArchive(reason: .manual).encoded()
    }

    /// Writes an automatic backup to Documents/Backups and prunes the folder (8 kept, the last 4 weekly
    /// ones always among them). The data is taken now,
    /// on the main actor, and written in the background (await the returned task to know it's done).
    /// Nothing is written while there is no data (a new device before its first sync), so empty
    /// copies never push out good ones.
    @discardableResult
    func writeAutomaticBackup(reason: BackupReason) -> Task<Void, Never>? {
        let archive = makeBackupArchive(reason: reason)
        guard !archive.isEmpty else { return nil }
        let date = archive.createdAt
        return Task.detached(priority: .utility) {
            do {
                let data = try archive.encoded()
                try BackupFolder.write(data, name: BackupSchedule.fileName(at: date, reason: reason))
                BackupFolder.prune()
                await MainActor.run {
                    UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: Prefs.lastBackupAt)
                }
                AppLog.info("Backup written (\(reason.rawValue), \(archive.summary))", category: "backup")
            } catch {
                AppLog.error("Backup failed (\(reason.rawValue)): \(error.localizedDescription)", category: "backup")
            }
        }
    }

    /// The weekly automatic backup, when the newest weekly one is a week old. Looked at after launch,
    /// then whenever the app comes back to the front and when the day changes (a Mac can stay open for
    /// weeks) – at most once an hour, however many windows the Mac opens.
    func backUpIfDue(now: Date = Date()) {
        watchForDueBackups()
        if let last = BackupFolder.lastCheck, now.timeIntervalSince(last) < 3600 { return }
        BackupFolder.lastCheck = now
        let newestWeekly = BackupFolder.entries().first { $0.reason == BackupReason.weekly.rawValue }?.date
        guard BackupSchedule.isDue(lastBackup: newestWeekly, now: now) else { return }
        writeAutomaticBackup(reason: .weekly)
    }

    /// Checks again in the foreground and on a new day (from the first check on).
    private func watchForDueBackups() {
        guard BackupFolder.observers.isEmpty else { return }
        #if os(macOS)
        let foreground = NSApplication.didBecomeActiveNotification
        #else
        let foreground = UIApplication.willEnterForegroundNotification
        #endif
        for name in [foreground, Notification.Name.NSCalendarDayChanged] {
            BackupFolder.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.backUpIfDue() }
            })
        }
    }

    // MARK: Restoring

    /// What restoring `archive` would do now.
    func restorePlan(for archive: BackupArchive) -> RestorePlan {
        archive.restorePlan(against: makeBackupArchive(reason: .manual))
    }

    /// Merges a backup back by id: what is missing comes back, a program's workouts and templates are
    /// linked to it again, changes made since stay unless `includingChanged`, and what was added since
    /// is never touched. A running workout is never changed. A backup of how things are now is written
    /// first. Returns how many records were written.
    @discardableResult
    func restoreBackup(_ archive: BackupArchive, includingChanged: Bool) -> Int {
        writeAutomaticBackup(reason: .beforeRestore)
        let plan = restorePlan(for: archive)
        var count = 0
        saveWithoutUndo(bumping: true) {
            count = applyRestore(archive, plan: plan, includingChanged: includingChanged)
        }
        forgetCachedSettings()
        AppLog.info("Backup restored: \(count) record(s) (\(archive.summary))", category: "backup")
        return count
    }

    private func applyRestore(_ archive: BackupArchive, plan: RestorePlan, includingChanged: Bool) -> Int {
        var count = 0

        // Programs first: templates and workouts link to them.
        var programs = Dictionary(fetchPrograms().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in archive.programs where plan.programs.restores(record.id.uuidString, includingChanged: includingChanged) {
            let program: Program
            if let existing = programs[record.id] {
                program = existing
            } else {
                program = Program(name: record.name)
                program.id = record.id
                context.insert(program)
                programs[record.id] = program
            }
            Self.apply(record, to: program)
            count += 1
        }
        func linkedProgram(_ id: UUID?) -> Program? {
            guard let id else { return nil }
            return programs[id]
        }

        let templates = Dictionary(fetchTemplates().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in archive.templates {
            if plan.templates.restores(record.id.uuidString, includingChanged: includingChanged) {
                let template: WorkoutTemplate
                if let existing = templates[record.id] {
                    template = existing
                } else {
                    template = WorkoutTemplate(name: record.name)
                    template.id = record.id
                    context.insert(template)
                }
                Self.apply(record, to: template)
                template.program = linkedProgram(record.programID)
                count += 1
            } else if plan.relinkTemplates.contains(record.id), let template = templates[record.id] {
                template.program = linkedProgram(record.programID)
                count += 1
            }
        }

        let sessions = Dictionary(fetchSessions().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in archive.sessions {
            let existing = sessions[record.id]
            // A workout running now is never changed by a restore.
            if existing?.status == .active { continue }
            if plan.sessions.restores(record.id.uuidString, includingChanged: includingChanged) {
                let hasDoneSets = WorkoutContent.decode(record.content?.data).completedSets > 0
                let restored = record.stoppedForRestore(at: archive.createdAt, hasDoneSets: hasDoneSets)
                let session: WorkoutSession
                if let existing {
                    session = existing
                } else {
                    session = WorkoutSession(title: restored.title)
                    session.id = restored.id
                    context.insert(session)
                }
                Self.apply(restored, to: session)
                session.program = linkedProgram(restored.programID)
                count += 1
            } else if plan.relinkSessions.contains(record.id), let existing {
                existing.program = linkedProgram(record.programID)
                count += 1
            }
        }

        let checkIns = Dictionary(((try? context.fetch(FetchDescriptor<EnergyCheckIn>())) ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        for record in archive.energyCheckIns where plan.energyCheckIns.restores(record.id.uuidString, includingChanged: includingChanged) {
            let checkIn: EnergyCheckIn
            if let existing = checkIns[record.id] {
                checkIn = existing
            } else {
                checkIn = EnergyCheckIn(level: record.level, source: record.source)
                checkIn.id = record.id
                context.insert(checkIn)
            }
            checkIn.date = record.date
            checkIn.level = record.level
            checkIn.source = record.source
            checkIn.sessionID = record.sessionID
            checkIn.note = record.note
            count += 1
        }

        let exercises = Dictionary(((try? context.fetch(FetchDescriptor<UserExercise>())) ?? []).map { ($0.key, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for record in archive.exercises where plan.exercises.restores(record.key, includingChanged: includingChanged) {
            let exercise: UserExercise
            if let existing = exercises[record.key] {
                exercise = existing
            } else {
                exercise = UserExercise(key: record.key, name: record.name, isCustom: record.isCustom)
                context.insert(exercise)
            }
            Self.apply(record, to: exercise)
            count += 1
        }

        let weeks = Dictionary(((try? context.fetch(FetchDescriptor<ExcusedWeek>())) ?? []).map { (BackupArchive.weekKey($0.weekStart), $0) },
                               uniquingKeysWith: { first, _ in first })
        for record in archive.excusedWeeks {
            let key = BackupArchive.weekKey(record.weekStart)
            guard plan.excusedWeeks.restores(key, includingChanged: includingChanged) else { continue }
            let week: ExcusedWeek
            if let existing = weeks[key] {
                week = existing
            } else {
                week = ExcusedWeek(weekStart: record.weekStart, reason: record.reason)
                context.insert(week)
            }
            week.reason = record.reason
            week.createdAt = record.createdAt
            count += 1
        }

        if let record = archive.settings, plan.settings.restores("settings", includingChanged: includingChanged) {
            Self.apply(record, to: settings)
            count += 1
        }
        if let active = plan.activeProgramID, programs[active] != nil, settings.activeProgramID == nil {
            settings.activeProgramID = active
            settings.updatedAt = Date()
        }
        return count
    }

    // MARK: Records

    private static func record(_ p: Program) -> BackupArchive.Program {
        var r = BackupArchive.Program()
        r.id = p.id
        r.name = p.name
        r.subtitle = p.subtitle
        r.symbol = p.symbol
        r.colorHex = p.colorHex
        r.kindRaw = p.kindRaw
        r.notes = p.notes
        r.isArchived = p.isArchived
        r.isPinned = p.isPinned
        r.sortIndex = p.sortIndex
        r.createdAt = p.createdAt
        r.updatedAt = p.updatedAt
        return r
    }

    private static func apply(_ r: BackupArchive.Program, to p: Program) {
        p.name = r.name
        p.subtitle = r.subtitle
        p.symbol = r.symbol
        p.colorHex = r.colorHex
        p.kindRaw = r.kindRaw
        p.notes = r.notes
        p.isArchived = r.isArchived
        p.isPinned = r.isPinned
        p.sortIndex = r.sortIndex
        p.createdAt = r.createdAt
        p.updatedAt = r.updatedAt
    }

    private static func record(_ t: WorkoutTemplate) -> BackupArchive.Template {
        var r = BackupArchive.Template()
        r.id = t.id
        r.name = t.name
        r.subtitle = t.subtitle
        r.kindRaw = t.kindRaw
        r.notes = t.notes
        r.colorHex = t.colorHex
        r.tagsRaw = t.tagsRaw
        r.priorityRaw = t.priorityRaw
        r.scheduleRaw = t.scheduleRaw
        r.isFavorite = t.isFavorite
        r.isPinned = t.isPinned
        r.sortIndex = t.sortIndex
        r.createdAt = t.createdAt
        r.updatedAt = t.updatedAt
        r.lastUsedAt = t.lastUsedAt
        r.programID = t.program?.id
        r.content = BackupArchive.Blob.from(t.contentData)
        return r
    }

    private static func apply(_ r: BackupArchive.Template, to t: WorkoutTemplate) {
        t.name = r.name
        t.subtitle = r.subtitle
        t.kindRaw = r.kindRaw
        t.notes = r.notes
        t.colorHex = r.colorHex
        t.tagsRaw = r.tagsRaw
        t.priorityRaw = r.priorityRaw
        t.scheduleRaw = r.scheduleRaw
        t.isFavorite = r.isFavorite
        t.isPinned = r.isPinned
        t.sortIndex = r.sortIndex
        t.createdAt = r.createdAt
        t.lastUsedAt = r.lastUsedAt
        t.restoreContentData(r.content?.data)
        t.updatedAt = r.updatedAt
    }

    private static func record(_ s: WorkoutSession) -> BackupArchive.Session {
        var r = BackupArchive.Session()
        r.id = s.id
        r.title = s.title
        r.subtitle = s.subtitle
        r.kindRaw = s.kindRaw
        r.statusRaw = s.statusRaw
        r.plannedDate = s.plannedDate
        r.startedAt = s.startedAt
        r.endedAt = s.endedAt
        r.accumulatedSeconds = s.accumulatedSeconds
        r.resumedAt = s.resumedAt
        r.notes = s.notes
        r.tagsRaw = s.tagsRaw
        r.priorityRaw = s.priorityRaw
        r.colorHex = s.colorHex
        r.isPinned = s.isPinned
        r.isFavorite = s.isFavorite
        r.isRescue = s.isRescue
        r.effort = s.effort
        r.energyBefore = s.energyBefore
        r.energyKcal = s.energyKcal
        r.healthWorkoutID = s.healthWorkoutID
        r.recordedOnWatch = s.recordedOnWatch
        r.templateID = s.templateID
        r.templateName = s.templateName
        r.createdAt = s.createdAt
        r.updatedAt = s.updatedAt
        r.programID = s.program?.id
        r.content = BackupArchive.Blob.from(s.contentData)
        return r
    }

    private static func apply(_ r: BackupArchive.Session, to s: WorkoutSession) {
        s.title = r.title
        s.subtitle = r.subtitle
        s.kindRaw = r.kindRaw
        s.statusRaw = r.statusRaw
        s.plannedDate = r.plannedDate
        s.startedAt = r.startedAt
        s.endedAt = r.endedAt
        s.accumulatedSeconds = r.accumulatedSeconds
        s.resumedAt = r.resumedAt
        s.notes = r.notes
        s.tagsRaw = r.tagsRaw
        s.priorityRaw = r.priorityRaw
        s.colorHex = r.colorHex
        s.isPinned = r.isPinned
        s.isFavorite = r.isFavorite
        s.isRescue = r.isRescue
        s.effort = r.effort
        s.energyBefore = r.energyBefore
        s.energyKcal = r.energyKcal
        s.healthWorkoutID = r.healthWorkoutID
        s.recordedOnWatch = r.recordedOnWatch
        s.templateID = r.templateID
        s.templateName = r.templateName
        s.createdAt = r.createdAt
        s.restoreContentData(r.content?.data)
        s.updatedAt = r.updatedAt
    }

    private static func record(_ e: EnergyCheckIn) -> BackupArchive.EnergyCheckIn {
        var r = BackupArchive.EnergyCheckIn()
        r.id = e.id
        r.date = e.date
        r.level = e.level
        r.source = e.source
        r.sessionID = e.sessionID
        r.note = e.note
        return r
    }

    private static func record(_ e: UserExercise) -> BackupArchive.Exercise {
        var r = BackupArchive.Exercise()
        r.key = e.key
        r.name = e.name
        r.kindRaw = e.kindRaw
        r.modeRaw = e.modeRaw
        r.musclesRaw = e.musclesRaw
        r.equipment = e.equipment
        r.instructions = e.instructions
        r.linksRaw = e.linksRaw
        r.notes = e.notes
        r.imageURL = e.imageURL
        r.isFavorite = e.isFavorite
        r.isCustom = e.isCustom
        r.perSide = e.perSide
        r.createdAt = e.createdAt
        r.updatedAt = e.updatedAt
        return r
    }

    private static func apply(_ r: BackupArchive.Exercise, to e: UserExercise) {
        e.name = r.name
        e.kindRaw = r.kindRaw
        e.modeRaw = r.modeRaw
        e.musclesRaw = r.musclesRaw
        e.equipment = r.equipment
        e.instructions = r.instructions
        e.linksRaw = r.linksRaw
        e.notes = r.notes
        e.imageURL = r.imageURL
        e.isFavorite = r.isFavorite
        e.isCustom = r.isCustom
        e.perSide = r.perSide
        e.createdAt = r.createdAt
        e.updatedAt = r.updatedAt
    }

    private static func record(_ w: ExcusedWeek) -> BackupArchive.ExcusedWeek {
        var r = BackupArchive.ExcusedWeek()
        r.weekStart = w.weekStart
        r.reason = w.reason
        r.createdAt = w.createdAt
        return r
    }

    private static func record(_ s: SyncedSettings) -> BackupArchive.Settings {
        var r = BackupArchive.Settings()
        r.createdAt = s.createdAt
        r.updatedAt = s.updatedAt
        r.weeklyGoal = s.weeklyGoal
        r.goalHistory = BackupArchive.Blob.from(s.goalHistoryData)
        r.unitRaw = s.unitRaw
        r.defaultRestSeconds = s.defaultRestSeconds
        r.namingPattern = s.namingPattern
        r.activeProgramID = s.activeProgramID
        r.autoUseSaves = s.autoUseSaves
        r.rescueCountsDouble = s.rescueCountsDouble
        r.rescueMinutes = s.rescueMinutes
        r.minimumMinutes = s.minimumMinutes
        r.countHealthWorkouts = s.countHealthWorkouts
        r.saveToHealth = s.saveToHealth
        r.bodyMassKg = s.bodyMassKg
        r.weekStartsOn = s.weekStartsOn
        r.prefillFromLastTime = s.prefillFromLastTime
        r.askToUpdateTemplate = s.askToUpdateTemplate
        r.birthYear = s.birthYear
        r.experienceRaw = s.experienceRaw
        r.goalRaw = s.goalRaw
        r.extras = BackupArchive.Blob.from(s.extrasData)
        return r
    }

    /// The record keeps its own `createdAt` (the oldest copy is the one every device keeps).
    private static func apply(_ r: BackupArchive.Settings, to s: SyncedSettings) {
        s.weeklyGoal = r.weeklyGoal
        s.goalHistoryData = r.goalHistory?.data
        s.unitRaw = r.unitRaw
        s.defaultRestSeconds = r.defaultRestSeconds
        s.namingPattern = r.namingPattern
        s.activeProgramID = r.activeProgramID
        s.autoUseSaves = r.autoUseSaves
        s.rescueCountsDouble = r.rescueCountsDouble
        s.rescueMinutes = r.rescueMinutes
        s.minimumMinutes = r.minimumMinutes
        s.countHealthWorkouts = r.countHealthWorkouts
        s.saveToHealth = r.saveToHealth
        s.bodyMassKg = r.bodyMassKg
        s.weekStartsOn = r.weekStartsOn
        s.prefillFromLastTime = r.prefillFromLastTime
        s.askToUpdateTemplate = r.askToUpdateTemplate
        s.birthYear = r.birthYear
        s.experienceRaw = r.experienceRaw
        s.goalRaw = r.goalRaw
        s.extrasData = r.extras?.data
        s.updatedAt = r.updatedAt
    }
}

/// The automatic backups: Documents/Backups in the app's own container – never iCloud and never the
/// shared App Group. On iPhone and iPad they show in Files (On My iPhone → George → Backups).
enum BackupFolder {
    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let date: Date
        /// "weekly", "before import" … (from the file name).
        let reason: String
        let size: Int
    }

    /// When `GeorgeStore.backUpIfDue()` last looked (nil until the first look after launch).
    @MainActor static var lastCheck: Date?
    /// Foreground and new-day observers that look again (`GeorgeStore.backUpIfDue()`).
    @MainActor static var observers: [NSObjectProtocol] = []

    static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Backups", isDirectory: true)
    }

    static func write(_ data: Data, name: String) throws {
        guard let folder = url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Automatic backups, newest first (other files in the folder are left alone).
    static func entries() -> [Entry] {
        guard let folder = url,
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return urls.compactMap { file -> Entry? in
            let name = file.lastPathComponent
            guard let date = BackupSchedule.date(fromFileName: name) else { return nil }
            let reason = name.range(of: "(").flatMap { open in
                name.range(of: ")", range: open.upperBound..<name.endIndex).map { String(name[open.upperBound..<$0.lowerBound]) }
            } ?? ""
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Entry(url: file, date: date, reason: reason, size: size)
        }
        .sorted { $0.date > $1.date }
    }

    static func newestDate() -> Date? { entries().first?.date }

    /// Keeps `BackupSchedule.keep` automatic backups, the newest weekly ones always among them
    /// (`BackupSchedule.filesToDelete`).
    static func prune() {
        guard let folder = url,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in BackupSchedule.filesToDelete(names) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
