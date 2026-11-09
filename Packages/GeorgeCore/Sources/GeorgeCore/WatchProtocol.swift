import Foundation

// Messages exchanged between the iPhone app and the Apple Watch app over WatchConnectivity.
// Everything is Codable and sent as JSON `Data` under `WatchWire.payloadKey`.

public enum WatchWire {
    public static let payloadKey = "payload"
    public static let typeKey = "type"

    public enum MessageType: String, Sendable {
        case snapshot, live, command, metrics
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static func pack<T: Encodable>(_ value: T, as type: MessageType) -> [String: Any] {
        let data = (try? encoder.encode(value)) ?? Data()
        return [typeKey: type.rawValue, payloadKey: data]
    }

    public static func unpack<T: Decodable>(_ message: [String: Any], as type: T.Type) -> T? {
        guard let data = message[payloadKey] as? Data else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    public static func type(of message: [String: Any]) -> MessageType? {
        (message[typeKey] as? String).flatMap(MessageType.init(rawValue:))
    }
}

public struct WatchTemplate: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var subtitle: String
    public var kind: WorkoutKind
    public var programName: String
    public var exerciseCount: Int
    public var estimatedMinutes: Int
    public var isSuggested: Bool

    public init(id: UUID, name: String, subtitle: String, kind: WorkoutKind, programName: String, exerciseCount: Int, estimatedMinutes: Int, isSuggested: Bool = false) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
        self.programName = programName
        self.exerciseCount = exerciseCount
        self.estimatedMinutes = estimatedMinutes
        self.isSuggested = isSuggested
    }
}

public struct WatchSessionSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: WorkoutKind
    public var date: Date
    public var status: String

    public init(id: UUID, title: String, kind: WorkoutKind, date: Date, status: String) {
        self.id = id
        self.title = title
        self.kind = kind
        self.date = date
        self.status = status
    }
}

public struct WatchStreak: Codable, Hashable, Sendable {
    public var weeks: Int
    public var doneDays: Int
    public var goal: Int
    public var credits: Int
    public var headline: String
    public var dots: [Bool]

    public init(weeks: Int, doneDays: Int, goal: Int, credits: Int, headline: String, dots: [Bool]) {
        self.weeks = weeks
        self.doneDays = doneDays
        self.goal = goal
        self.credits = credits
        self.headline = headline
        self.dots = dots
    }
}

public struct WatchSet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var index: String
    public var label: String
    public var isDone: Bool

    public init(id: UUID, index: String, label: String, isDone: Bool) {
        self.id = id
        self.index = index
        self.label = label
        self.isDone = isDone
    }
}

public struct WatchExercise: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var detail: String
    public var groupLabel: String?
    public var section: String?
    public var notes: String?
    public var sets: [WatchSet]

    public init(id: UUID, name: String, detail: String, groupLabel: String?, section: String?, notes: String?, sets: [WatchSet]) {
        self.id = id
        self.name = name
        self.detail = detail
        self.groupLabel = groupLabel
        self.section = section
        self.notes = notes
        self.sets = sets
    }

    public var isComplete: Bool { !sets.isEmpty && sets.allSatisfy(\.isDone) }
}

/// Full state of the running workout, mirrored to the watch.
public struct WatchLiveState: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var title: String
    public var kind: WorkoutKind
    public var startedAt: Date
    /// Active seconds accumulated before `resumedAt` (pauses excluded).
    public var accumulatedSeconds: Double
    public var resumedAt: Date?
    public var isPaused: Bool
    public var restEndsAt: Date?
    public var restTotalSeconds: Int?
    public var currentSetID: UUID?
    public var exercises: [WatchExercise]
    public var completedSets: Int
    public var totalSets: Int

    public init(sessionID: UUID, title: String, kind: WorkoutKind, startedAt: Date, accumulatedSeconds: Double, resumedAt: Date?, isPaused: Bool, restEndsAt: Date?, restTotalSeconds: Int?, currentSetID: UUID?, exercises: [WatchExercise], completedSets: Int, totalSets: Int) {
        self.sessionID = sessionID
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.accumulatedSeconds = accumulatedSeconds
        self.resumedAt = resumedAt
        self.isPaused = isPaused
        self.restEndsAt = restEndsAt
        self.restTotalSeconds = restTotalSeconds
        self.currentSetID = currentSetID
        self.exercises = exercises
        self.completedSets = completedSets
        self.totalSets = totalSets
    }

    public func elapsed(at date: Date = Date()) -> Double {
        guard !isPaused, let resumedAt else { return accumulatedSeconds }
        return accumulatedSeconds + max(0, date.timeIntervalSince(resumedAt))
    }

    /// Builds the watch representation from workout content.
    public static func exercises(from content: WorkoutContent, unit: WeightUnit) -> [WatchExercise] {
        var result: [WatchExercise] = []
        var groupIndex = 0
        for block in content.blocks {
            var label: String? = nil
            if block.items.count > 1 {
                let letter = String(Character(UnicodeScalar(65 + (groupIndex % 26)) ?? "A"))
                label = "\(block.style.displayName) \(letter)"
                groupIndex += 1
            }
            for item in block.items {
                let sets = item.sets.map { set in
                    WatchSet(id: set.id, index: item.displayIndex(of: set), label: set.label(mode: item.mode, unit: unit), isDone: set.isDone)
                }
                result.append(WatchExercise(
                    id: item.id, name: item.name, detail: item.prescription(unit: unit), groupLabel: label,
                    section: block.section, notes: item.notes, sets: sets
                ))
            }
        }
        return result
    }
}

public struct WatchSnapshot: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var templates: [WatchTemplate]
    public var upcoming: [WatchSessionSummary]
    public var streak: WatchStreak?
    public var live: WatchLiveState?
    public var unit: WeightUnit
    /// The last George session the phone discarded — the watch throws its Health recording away instead of saving it.
    public var discardedSessionID: UUID?

    public init(generatedAt: Date = Date(), templates: [WatchTemplate], upcoming: [WatchSessionSummary], streak: WatchStreak?, live: WatchLiveState?, unit: WeightUnit, discardedSessionID: UUID? = nil) {
        self.generatedAt = generatedAt
        self.templates = templates
        self.upcoming = upcoming
        self.streak = streak
        self.live = live
        self.unit = unit
        self.discardedSessionID = discardedSessionID
    }
}

/// Commands the watch sends to the phone (the phone owns the data).
public enum WatchCommand: Codable, Hashable, Sendable {
    case toggleSet(UUID)
    case completeCurrentSet
    case startRest(Int)
    case addRest(Int)
    case skipRest
    case pause
    case resume
    case finish(effort: Int?)
    case discard
    case startTemplate(UUID)
    case startSession(UUID)
    case requestSnapshot
}

/// Live metrics the watch measures during its HealthKit workout session.
public struct WatchMetrics: Codable, Hashable, Sendable {
    public var heartRate: Double?
    public var averageHeartRate: Double?
    public var activeEnergy: Double?
    public var healthWorkoutID: UUID?
    public var endedAt: Date?

    public init(heartRate: Double? = nil, averageHeartRate: Double? = nil, activeEnergy: Double? = nil, healthWorkoutID: UUID? = nil, endedAt: Date? = nil) {
        self.heartRate = heartRate
        self.averageHeartRate = averageHeartRate
        self.activeEnergy = activeEnergy
        self.healthWorkoutID = healthWorkoutID
        self.endedAt = endedAt
    }
}
