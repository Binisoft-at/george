import Foundation

/// A full copy of George's synced data in one file – programs, templates, workouts, energy check-ins,
/// your exercises, break weeks and settings – that can be restored on any device.
///
/// iCloud sync is no backup: a deleted program, a bad import or a buggy build reaches every device
/// within seconds. A backup file lives outside the synced store (a file you save, or the automatic
/// copies in the app's Documents/Backups folder), and a restore merges it back by id: what is missing
/// comes back, what changed since stays unless you ask for the backup's version, and what was added
/// since is never touched. Measured Health numbers stay out (they live on each device and in Health).
public struct BackupArchive: Codable, Hashable, Sendable {
    /// The format this build writes; a file with a higher version needs a newer George.
    public static let currentVersion = 1
    /// Marks the file as a George backup.
    public static let formatName = "george-backup"

    public var format: String = BackupArchive.formatName
    public var version: Int = BackupArchive.currentVersion
    public var createdAt: Date = Date()
    /// Why it was written ("weekly", "before import", "before restore", "manual").
    public var reason: String = BackupReason.manual.rawValue
    /// "1.4 (52)" – the George that wrote it.
    public var appVersion: String = ""
    public var programs: [Program] = []
    public var templates: [Template] = []
    public var sessions: [Session] = []
    public var energyCheckIns: [EnergyCheckIn] = []
    public var exercises: [Exercise] = []
    public var excusedWeeks: [ExcusedWeek] = []
    public var settings: Settings?

    public init() {}

    /// Nothing worth keeping (a new device before its first sync): never written as a rolling backup.
    public var isEmpty: Bool {
        programs.isEmpty && templates.isEmpty && sessions.isEmpty && energyCheckIns.isEmpty && exercises.isEmpty && excusedWeeks.isEmpty
    }

    /// "2 programs · 9 templates · 143 workouts"
    public var summary: String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts = [count(programs.count, "program", "programs"), count(templates.count, "template", "templates"),
                     count(sessions.count, "workout", "workouts")]
        if !energyCheckIns.isEmpty { parts.append(count(energyCheckIns.count, "check-in", "check-ins")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Records

    /// Data stored as is: JSON text when it is UTF-8 (readable in the file), else base64.
    public struct Blob: Codable, Hashable, Sendable {
        public var data: Data
        public init(_ data: Data) { self.data = data }

        /// nil for no data or empty data.
        public static func from(_ data: Data?) -> Blob? {
            guard let data, !data.isEmpty else { return nil }
            return Blob(data)
        }

        private enum Keys: String, CodingKey { case base64 }

        public init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                data = Data(text.utf8)
            } else {
                let c = try decoder.container(keyedBy: Keys.self)
                data = try c.decode(Data.self, forKey: .base64)
            }
        }

        public func encode(to encoder: Encoder) throws {
            if let text = String(data: data, encoding: .utf8) {
                var c = encoder.singleValueContainer()
                try c.encode(text)
            } else {
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(data, forKey: .base64)
            }
        }
    }

    public struct Program: Codable, Hashable, Sendable {
        public var id = UUID()
        public var name = ""
        public var subtitle = ""
        public var symbol = "folder.fill"
        public var colorHex = "#0A84FF"
        public var kindRaw = "gym"
        public var notes = ""
        public var isArchived = false
        public var isPinned = false
        public var sortIndex = 0.0
        public var createdAt = Date()
        public var updatedAt = Date()
        public init() {}
    }

    public struct Template: Codable, Hashable, Sendable {
        public var id = UUID()
        public var name = ""
        public var subtitle = ""
        public var kindRaw = "gym"
        public var notes = ""
        public var colorHex: String?
        public var tagsRaw = ""
        public var priorityRaw = 0
        public var scheduleRaw = ""
        public var isFavorite = false
        public var isPinned = false
        public var sortIndex = 0.0
        public var createdAt = Date()
        public var updatedAt = Date()
        public var lastUsedAt: Date?
        public var programID: UUID?
        /// The workout (`WorkoutContent` JSON) exactly as stored – fields of a newer George included.
        public var content: Blob?
        public init() {}
    }

    public struct Session: Codable, Hashable, Sendable {
        public var id = UUID()
        public var title = ""
        public var subtitle = ""
        public var kindRaw = "gym"
        public var statusRaw = "planned"
        public var plannedDate: Date?
        public var startedAt: Date?
        public var endedAt: Date?
        public var accumulatedSeconds = 0.0
        public var resumedAt: Date?
        public var notes = ""
        public var tagsRaw = ""
        public var priorityRaw = 0
        public var colorHex: String?
        public var isPinned = false
        public var isFavorite = false
        public var isRescue = false
        public var effort = 0
        public var energyBefore = 0
        public var energyKcal = 0.0
        public var healthWorkoutID: String?
        public var recordedOnWatch = false
        public var templateID: UUID?
        public var templateName = ""
        public var createdAt = Date()
        public var updatedAt = Date()
        public var programID: UUID?
        public var content: Blob?
        public init() {}

        /// A workout that was running when the backup was made comes back stopped at that moment
        /// (its clock doesn't run on from then): stopped early when sets were done, else planned.
        public func stoppedForRestore(at backupDate: Date, hasDoneSets: Bool) -> Session {
            guard statusRaw == "active" else { return self }
            var copy = self
            if let resumedAt { copy.accumulatedSeconds += max(0, backupDate.timeIntervalSince(resumedAt)) }
            copy.resumedAt = nil
            copy.statusRaw = hasDoneSets ? "partial" : "planned"
            if hasDoneSets, copy.endedAt == nil { copy.endedAt = backupDate }
            return copy
        }
    }

    public struct EnergyCheckIn: Codable, Hashable, Sendable {
        public var id = UUID()
        public var date = Date()
        public var level = 3
        public var source = "today"
        public var sessionID: UUID?
        public var note = ""
        public init() {}
    }

    /// Your own exercises and personal additions to library ones (`UserExercise`), by library key.
    public struct Exercise: Codable, Hashable, Sendable {
        public var key = ""
        public var name = ""
        public var kindRaw = "gym"
        public var modeRaw = "reps"
        public var musclesRaw = ""
        public var equipment = ""
        public var instructions = ""
        public var linksRaw = ""
        public var notes = ""
        public var imageURL = ""
        public var isFavorite = false
        public var isCustom = false
        public var perSide = false
        public var createdAt = Date()
        public var updatedAt = Date()
        public init() {}
    }

    public struct ExcusedWeek: Codable, Hashable, Sendable {
        public var weekStart = Date.distantPast
        public var reason = ""
        public var createdAt = Date()
        public init() {}
    }

    /// The synced settings (one record).
    public struct Settings: Codable, Hashable, Sendable {
        public var createdAt = Date()
        public var updatedAt = Date()
        public var weeklyGoal = 3
        public var goalHistory: Blob?
        public var unitRaw = "kg"
        public var defaultRestSeconds = 90
        public var namingPattern = ""
        public var activeProgramID: UUID?
        public var autoUseSaves = true
        public var rescueCountsDouble = true
        public var rescueMinutes = 10
        public var minimumMinutes = 10
        public var countHealthWorkouts = true
        public var saveToHealth = true
        public var bodyMassKg = 75.0
        public var weekStartsOn = 2
        public var prefillFromLastTime = true
        public var askToUpdateTemplate = true
        public var birthYear = 0
        public var experienceRaw = ""
        public var goalRaw = ""
        public var extras: Blob?
        public init() {}
    }

    // MARK: File

    public enum ReadError: Error, LocalizedError, Equatable, Sendable {
        case notABackup
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notABackup: return "This file isn't a George backup."
            case .newerVersion: return "This backup was made by a newer George. Update George to restore it."
            }
        }
    }

    // Dates stay in their own form (seconds since 2001, `.deferredToDate`): converting to 1970 seconds
    // can change the last bit, and an unchanged record must compare equal after a round trip.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    public func encoded() throws -> Data {
        try BackupArchive.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> BackupArchive {
        struct Header: Decodable { var format: String?; var version: Int? }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == formatName else {
            throw ReadError.notABackup
        }
        if let version = header.version, version > currentVersion { throw ReadError.newerVersion(version) }
        return try decoder.decode(BackupArchive.self, from: data)
    }

    // MARK: Restore plan

    /// What a restore would do, compared with what is on the device now (`current`, the same data as
    /// an archive). Records are matched by id (exercises by library key, break weeks by week).
    public func restorePlan(against current: BackupArchive) -> RestorePlan {
        var plan = RestorePlan()
        plan.programs = classify(programs, current.programs) { $0.id.uuidString }
        plan.templates = classify(templates, current.templates) { $0.id.uuidString }
        plan.sessions = classify(sessions, current.sessions) { $0.id.uuidString }
        plan.energyCheckIns = classify(energyCheckIns, current.energyCheckIns) { $0.id.uuidString }
        plan.exercises = classify(exercises, current.exercises) { $0.key }
        plan.excusedWeeks = classify(excusedWeeks, current.excusedWeeks) { Self.weekKey($0.weekStart) }
        plan.settings = classify(settings.map { [$0] } ?? [], current.settings.map { [$0] } ?? []) { _ in "settings" }

        // A deleted program took its templates along and left its workouts without a program: the
        // workouts and templates of a program that comes back are linked to it again, and it is the
        // active program again when none is chosen now.
        let returning = plan.programs.bringBack
        let currentSessions = Dictionary(current.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in sessions {
            guard let programID = session.programID, returning.contains(programID.uuidString),
                  let now = currentSessions[session.id], now.programID == nil else { continue }
            plan.relinkSessions.insert(session.id)
        }
        let currentTemplates = Dictionary(current.templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for template in templates {
            guard let programID = template.programID, returning.contains(programID.uuidString),
                  let now = currentTemplates[template.id], now.programID == nil else { continue }
            plan.relinkTemplates.insert(template.id)
        }
        if let active = settings?.activeProgramID, returning.contains(active.uuidString),
           current.settings == nil || current.settings?.activeProgramID == nil {
            plan.activeProgramID = active
        }
        return plan
    }

    /// Break weeks match by their day: a local midnight anywhere between UTC−12 and UTC+12 rounds to
    /// the same day number, so a time-zone change doesn't make the same week look new.
    public static func weekKey(_ date: Date) -> String {
        guard date.timeIntervalSince1970.isFinite else { return "0" }
        return String(Int((date.timeIntervalSince1970 / 86_400).rounded()))
    }

    /// Missing here → back; equal → same; different → changed since the backup. (No timestamp decides
    /// which is newer: typing a title or a note doesn't always stamp `updatedAt`.)
    private func classify<T: Hashable>(_ backup: [T], _ now: [T], key: (T) -> String) -> RestorePlan.Part {
        var part = RestorePlan.Part()
        let current = Dictionary(now.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for record in backup {
            let k = key(record)
            if let existing = current[k] {
                if existing == record { part.same += 1 } else { part.changedSince.insert(k) }
            } else {
                part.bringBack.insert(k)
            }
        }
        return part
    }
}

/// Why a backup was written. Automatic ones go to Documents/Backups (the last few are kept).
public enum BackupReason: String, Codable, Sendable, CaseIterable {
    case weekly
    case beforeImport = "before import"
    case beforeRestore = "before restore"
    case manual
}

/// What restoring a backup does, per kind of record (keys: ids as text, exercise keys, week keys).
/// Records added since the backup are never part of it: a restore leaves them alone.
public struct RestorePlan: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        /// In the backup, gone here: added back.
        public var bringBack: Set<String> = []
        /// Different here: kept as it is now, unless the backup's version is asked for.
        public var changedSince: Set<String> = []
        /// The same here and in the backup.
        public var same = 0
        public init() {}

        public func restores(_ key: String, includingChanged: Bool) -> Bool {
            bringBack.contains(key) || (includingChanged && changedSince.contains(key))
        }
    }

    public var programs = Part()
    public var templates = Part()
    public var sessions = Part()
    public var energyCheckIns = Part()
    public var exercises = Part()
    public var excusedWeeks = Part()
    public var settings = Part()
    /// Workouts and templates linked again to their program that comes back (only the link changes).
    public var relinkSessions: Set<UUID> = []
    public var relinkTemplates: Set<UUID> = []
    /// The program that comes back was the active one, and none is active now.
    public var activeProgramID: UUID?

    public init() {}

    private var all: [Part] { [programs, templates, sessions, energyCheckIns, exercises, excusedWeeks, settings] }

    /// Records the restore adds back.
    public var bringBackCount: Int { all.reduce(0) { $0 + $1.bringBack.count } }
    /// Records changed here since the backup (kept unless asked for).
    public var changedSinceCount: Int { all.reduce(0) { $0 + $1.changedSince.count } }
    /// Workouts and templates that get their program back.
    public var relinkCount: Int { relinkSessions.count + relinkTemplates.count }
    public var sameCount: Int { all.reduce(0) { $0 + $1.same } }

    /// Whether the restore would change anything.
    public func changesSomething(includingChanged: Bool) -> Bool {
        bringBackCount > 0 || relinkCount > 0 || (includingChanged && changedSinceCount > 0)
    }

    /// One preview line per bucket: "3 workouts, 1 program" ("Nothing" when empty).
    public func describe(_ pick: (Part) -> Int) -> String {
        let names: [(Part, String, String, Bool)] = [
            (programs, "program", "programs", false), (templates, "template", "templates", false),
            (sessions, "workout", "workouts", false), (energyCheckIns, "energy check-in", "energy check-ins", false),
            (exercises, "exercise", "exercises", false), (excusedWeeks, "break week", "break weeks", false),
            (settings, "settings", "settings", true),
        ]
        let parts = names.compactMap { part, one, many, isSettings -> String? in
            let n = pick(part)
            guard n > 0 else { return nil }
            return isSettings ? "settings" : "\(n) \(n == 1 ? one : many)"
        }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: ", ")
    }
}

/// When automatic backups are written and which are kept.
public enum BackupSchedule {
    /// Automatic backups kept in Documents/Backups.
    public static let keep = 8
    /// A weekly backup is written when the last automatic one is this old.
    public static let interval: TimeInterval = 7 * 24 * 3600
    static let prefix = "George Backup "

    public static func isDue(lastBackup: Date?, now: Date) -> Bool {
        guard let lastBackup else { return true }
        return now.timeIntervalSince(lastBackup) >= interval
    }

    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }

    /// "George Backup 2026-11-23 091500 (weekly).json" – sorts by date in Files and Finder.
    public static func fileName(at date: Date, reason: BackupReason, timeZone: TimeZone = .current) -> String {
        "\(prefix)\(formatter(timeZone).string(from: date)) (\(reason.rawValue)).json"
    }

    /// The date in an automatic backup's file name (nil for any other file – those are never touched).
    public static func date(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let stamp = name.dropFirst(prefix.count).prefix(17)
        return formatter(timeZone).date(from: String(stamp))
    }

    /// The automatic backups to delete so that the newest `keep` stay.
    public static func filesToDelete(_ names: [String], keep: Int = BackupSchedule.keep, timeZone: TimeZone = .current) -> [String] {
        let dated = names.compactMap { name in date(fromFileName: name, timeZone: timeZone).map { (name, $0) } }
            .sorted { $0.1 > $1.1 }
        return dated.dropFirst(max(0, keep)).map(\.0)
    }
}
