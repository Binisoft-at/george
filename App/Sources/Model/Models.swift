import Foundation
import SwiftData
import GeorgeCore

// SwiftData models, synced through iCloud (CloudKit private database).
// CloudKit rules: every attribute has a default or is optional, relationships are optional
// with inverses, and nothing is marked unique.

/// A folder of workouts — e.g. "Elastic Bands – Tennis", "Gym Hypertrophy Block".
/// Holds templates (the plan) and sessions (what was actually done).
@Model
final class Program {
    var id: UUID = UUID()
    var name: String = ""
    var subtitle: String = ""
    var symbol: String = "folder.fill"
    var colorHex: String = "#0A84FF"
    var kindRaw: String = "gym"
    var notes: String = ""
    var isArchived: Bool = false
    var isPinned: Bool = false
    var sortIndex: Double = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \WorkoutTemplate.program)
    var templates: [WorkoutTemplate]? = []

    @Relationship(deleteRule: .nullify, inverse: \WorkoutSession.program)
    var sessions: [WorkoutSession]? = []

    init(name: String, kind: WorkoutKind = .gym, colorHex: String? = nil, symbol: String? = nil) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.colorHex = colorHex ?? kind.colorHex
        self.symbol = symbol ?? "folder.fill"
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// A reusable workout plan ("UPPER", "LOWER", "PRE&MOB").
@Model
final class WorkoutTemplate {
    var id: UUID = UUID()
    var name: String = ""
    var subtitle: String = ""
    var kindRaw: String = "gym"
    var notes: String = ""
    var colorHex: String?
    var tagsRaw: String = ""
    var priorityRaw: Int = 0
    var scheduleRaw: String = ""
    var isFavorite: Bool = false
    var isPinned: Bool = false
    var sortIndex: Double = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastUsedAt: Date?
    var contentData: Data?
    /// Denormalized from content for fast lists and search.
    var exerciseNames: String = ""
    var exerciseCount: Int = 0
    var setCount: Int = 0
    var estimatedMinutes: Int = 0
    var program: Program?

    init(name: String, subtitle: String = "", kind: WorkoutKind = .gym, program: Program? = nil, content: WorkoutContent = WorkoutContent()) {
        self.id = UUID()
        self.name = name
        self.subtitle = subtitle
        self.kindRaw = kind.rawValue
        self.program = program
        self.createdAt = Date()
        self.updatedAt = Date()
        self.content = content
    }
}

enum SessionStatus: String, CaseIterable, Identifiable, Codable {
    case planned, active, completed, partial, skipped
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .planned: return "Planned"
        case .active: return "In progress"
        case .completed: return "Completed"
        case .partial: return "Stopped early"
        case .skipped: return "Skipped"
        }
    }
    var symbol: String {
        switch self {
        case .planned: return "calendar"
        case .active: return "play.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .partial: return "stop.circle"
        case .skipped: return "forward.circle"
        }
    }
    /// Counts as a performed workout (streaks, stats).
    var isPerformed: Bool { self == .completed || self == .partial }
}

/// One concrete workout on a day — planned, running, or done ("W44: 3 UPPER - 29.10").
@Model
final class WorkoutSession {
    var id: UUID = UUID()
    var title: String = ""
    var subtitle: String = ""
    var kindRaw: String = "gym"
    var statusRaw: String = "planned"
    /// Planned day (also acts as a "deadline" for planned sessions).
    var plannedDate: Date?
    var startedAt: Date?
    var endedAt: Date?
    /// Seconds of activity accumulated before the last resume (pauses excluded).
    var accumulatedSeconds: Double = 0
    /// When the clock was last (re)started; nil while paused or not running.
    var resumedAt: Date?
    var notes: String = ""
    var tagsRaw: String = ""
    var priorityRaw: Int = 0
    var colorHex: String?
    var isPinned: Bool = false
    var isFavorite: Bool = false
    var isRescue: Bool = false
    var effort: Int = 0
    /// Energy before the workout, 1 (drained) … 5 (great); 0 = not asked.
    var energyBefore: Int = 0
    /// George's own estimate (MET × body weight × time). Measured values from Apple Health live in `HealthMetrics`.
    var energyKcal: Double = 0
    var healthWorkoutID: String?
    var recordedOnWatch: Bool = false
    var templateID: UUID?
    var templateName: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var contentData: Data?
    /// Denormalized from content for fast lists and search.
    var exerciseNames: String = ""
    var exerciseCount: Int = 0
    var setCount: Int = 0
    var doneSetCount: Int = 0
    var volumeKg: Double = 0
    var program: Program?

    init(title: String, kind: WorkoutKind = .gym, status: SessionStatus = .planned, plannedDate: Date? = nil, program: Program? = nil, content: WorkoutContent = WorkoutContent()) {
        self.id = UUID()
        self.title = title
        self.kindRaw = kind.rawValue
        self.statusRaw = status.rawValue
        self.plannedDate = plannedDate
        self.program = program
        self.createdAt = Date()
        self.updatedAt = Date()
        self.content = content
    }
}

/// User-created exercises, and personal additions (links, notes, favorites) to library exercises.
@Model
final class UserExercise {
    /// Library id ("fedb:…", "george:…") or "custom:<uuid>".
    var key: String = ""
    var name: String = ""
    var kindRaw: String = "gym"
    var modeRaw: String = "reps"
    var musclesRaw: String = ""
    var equipment: String = ""
    var instructions: String = ""
    var linksRaw: String = ""
    var notes: String = ""
    var imageURL: String = ""
    var isFavorite: Bool = false
    var isCustom: Bool = false
    var perSide: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(key: String, name: String, kind: WorkoutKind = .gym, isCustom: Bool) {
        self.key = key
        self.name = name
        self.kindRaw = kind.rawValue
        self.isCustom = isCustom
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// Weeks the user marked as an excused break (sick, travel) — neutral for streaks.
@Model
final class ExcusedWeek {
    var weekStart: Date = Date.distantPast
    var reason: String = ""
    var createdAt: Date = Date()

    init(weekStart: Date, reason: String) {
        self.weekStart = weekStart
        self.reason = reason
        self.createdAt = Date()
    }
}

/// Numbers read from Apple Health / the Watch for a session (heart rate, measured calories).
/// Stored on this device only — never synced through iCloud (App Store guideline 5.1.3(ii)).
/// Other devices read them from Apple Health again via `WorkoutSession.healthWorkoutID`.
@Model
final class HealthMetrics {
    var sessionID: UUID = UUID()
    var averageHeartRate: Double = 0
    var maxHeartRate: Double = 0
    var activeEnergyKcal: Double = 0
    var updatedAt: Date = Date()

    init(sessionID: UUID) {
        self.sessionID = sessionID
        self.updatedAt = Date()
    }
}

/// Settings that sync across devices. Treated as a singleton (duplicates from sync are merged).
@Model
final class SyncedSettings {
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var weeklyGoal: Int = 3
    var goalHistoryData: Data?
    var unitRaw: String = "kg"
    var defaultRestSeconds: Int = 90
    var namingPattern: String = SessionNamer.defaultPattern
    var activeProgramID: UUID?
    var autoUseSaves: Bool = true
    var rescueCountsDouble: Bool = true
    var rescueMinutes: Int = 10
    var minimumMinutes: Int = 10
    var countHealthWorkouts: Bool = true
    var saveToHealth: Bool = true
    var bodyMassKg: Double = 75
    var weekStartsOn: Int = 2
    var prefillFromLastTime: Bool = true
    var askToUpdateTemplate: Bool = true
    /// Training profile for advice that fits (0 / "" = not set).
    var birthYear: Int = 0
    var experienceRaw: String = ""
    var goalRaw: String = ""

    init() {
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// A quick "how's your energy?" answer – from Today or before a workout. Used to find patterns
/// and cycles over the weeks (Insights → Energy).
@Model
final class EnergyCheckIn {
    var id: UUID = UUID()
    var date: Date = Date()
    /// 1 (drained) … 5 (great).
    var level: Int = 3
    /// "today" or "workout".
    var source: String = "today"
    var sessionID: UUID?
    var note: String = ""

    init(level: Int, source: String, sessionID: UUID? = nil, date: Date = Date()) {
        self.id = UUID()
        self.level = level
        self.source = source
        self.sessionID = sessionID
        self.date = date
    }
}

