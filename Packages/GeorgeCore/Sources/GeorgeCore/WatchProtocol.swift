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
    /// Days that count this week – a rescue workout counts double, like on the phone.
    public var doneDays: Int
    public var goal: Int
    public var credits: Int
    public var headline: String
    public var dots: [Bool]
    /// Start of the week `doneDays` and `dots` belong to (nil from older phone versions). Once that
    /// week is over the watch and its complication show an empty week instead of last week's days.
    public var weekStart: Date?

    public init(weeks: Int, doneDays: Int, goal: Int, credits: Int, headline: String, dots: [Bool], weekStart: Date? = nil) {
        self.weeks = weeks
        self.doneDays = doneDays
        self.goal = goal
        self.credits = credits
        self.headline = headline
        self.dots = dots
        self.weekStart = weekStart
    }
}

public struct WatchSet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var index: String
    public var label: String
    public var isDone: Bool
    /// Reps logged (done) or planned (open); nil for timed/distance sets. Optional: older phones don't send it.
    public var reps: Int?
    /// Planned reps (for the picker's starting point).
    public var targetReps: Int?
    /// Weight in kg (logged or planned), nil for bodyweight.
    public var weightKg: Double?
    /// Hold/interval seconds for timed sets.
    public var seconds: Int?
    /// A timed set (hold) rather than reps.
    public var isTimed: Bool?

    public init(id: UUID, index: String, label: String, isDone: Bool, reps: Int? = nil, targetReps: Int? = nil,
                weightKg: Double? = nil, seconds: Int? = nil, isTimed: Bool? = nil) {
        self.id = id
        self.index = index
        self.label = label
        self.isDone = isDone
        self.reps = reps
        self.targetReps = targetReps
        self.weightKg = weightKg
        self.seconds = seconds
        self.isTimed = isTimed
    }
}

/// A question the phone's coach asks after an exercise (also answerable on the watch).
public struct WatchQuestion: Codable, Hashable, Sendable {
    public var setID: UUID
    public var exerciseName: String
    public var muscles: String
    public var asksReps: Bool
    public var asksFatigue: Bool

    public init(setID: UUID, exerciseName: String, muscles: String, asksReps: Bool, asksFatigue: Bool) {
        self.setID = setID
        self.exerciseName = exerciseName
        self.muscles = muscles
        self.asksReps = asksReps
        self.asksFatigue = asksFatigue
    }
}

/// What the watch shows after a workout was saved.
public struct WatchFinishSummary: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var title: String
    public var finishedAt: Date
    public var durationSeconds: Double
    public var completedSets: Int
    public var totalSets: Int
    public var energyKcal: Double?
    public var averageHeartRate: Double?
    public var records: Int
    public var streakHeadline: String?

    public init(sessionID: UUID, title: String, finishedAt: Date, durationSeconds: Double, completedSets: Int, totalSets: Int,
                energyKcal: Double? = nil, averageHeartRate: Double? = nil, records: Int = 0, streakHeadline: String? = nil) {
        self.sessionID = sessionID
        self.title = title
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
        self.completedSets = completedSets
        self.totalSets = totalSets
        self.energyKcal = energyKcal
        self.averageHeartRate = averageHeartRate
        self.records = records
        self.streakHeadline = streakHeadline
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
    /// When the current set was started (Start button); nil while waiting or resting.
    public var setStartedAt: Date?
    /// End of the last finished set – the break is measured from here.
    public var lastSetEndedAt: Date?
    /// Planned rest before the current set, seconds.
    public var plannedRestSeconds: Int?
    /// Target of a timed current set (countdown), seconds.
    public var timedSetSeconds: Int?
    /// Planned minus actual over all breaks so far: positive = behind.
    public var behindSeconds: Double?
    /// The last break against the plan (positive = longer than planned).
    public var lastDeltaSeconds: Double?
    /// False when the user turned the Start button off (one tap per set). Nil from older phones = on.
    public var usesStartButton: Bool?
    /// The coach's open question (fatigue / reps left), answerable on the watch.
    public var question: WatchQuestion?
    /// True until the first set: the watch may offer the energy check-in.
    public var asksEnergy: Bool?
    /// The voice coach is muted for this workout.
    public var voiceMuted: Bool?
    /// The exercise the user is looking at on the phone when it differs from the plan's current one.
    public var viewingExerciseID: UUID?
    /// Sides of the timed current set: 2 for "30 s each side" (`timedSetSeconds` covers both sides).
    /// Nil from older phones and for one-sided holds.
    public var timedSides: Int?

    public init(sessionID: UUID, title: String, kind: WorkoutKind, startedAt: Date, accumulatedSeconds: Double, resumedAt: Date?, isPaused: Bool, restEndsAt: Date?, restTotalSeconds: Int?, currentSetID: UUID?, exercises: [WatchExercise], completedSets: Int, totalSets: Int,
                setStartedAt: Date? = nil, lastSetEndedAt: Date? = nil, plannedRestSeconds: Int? = nil, timedSetSeconds: Int? = nil, behindSeconds: Double? = nil, lastDeltaSeconds: Double? = nil,
                usesStartButton: Bool? = nil, question: WatchQuestion? = nil, asksEnergy: Bool? = nil, voiceMuted: Bool? = nil, viewingExerciseID: UUID? = nil, timedSides: Int? = nil) {
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
        self.setStartedAt = setStartedAt
        self.lastSetEndedAt = lastSetEndedAt
        self.plannedRestSeconds = plannedRestSeconds
        self.timedSetSeconds = timedSetSeconds
        self.behindSeconds = behindSeconds
        self.lastDeltaSeconds = lastDeltaSeconds
        self.usesStartButton = usesStartButton
        self.question = question
        self.asksEnergy = asksEnergy
        self.voiceMuted = voiceMuted
        self.viewingExerciseID = viewingExerciseID
        self.timedSides = timedSides
    }

    /// One side of a running per-side hold.
    public struct HoldSide: Equatable, Sendable {
        /// 1 or 2.
        public var number: Int
        public var count: Int
        public var start: Date
        public var end: Date

        public init(number: Int, count: Int, start: Date, end: Date) {
            self.number = number
            self.count = count
            self.start = start
            self.end = end
        }

        public func remaining(at date: Date) -> Double { max(0, end.timeIntervalSince(date)) }
        public var seconds: Double { end.timeIntervalSince(start) }
    }

    /// 2 while a per-side hold is current, else 1.
    public var holdSideCount: Int { max(1, min(2, timedSides ?? 1)) }

    /// The side of the running per-side hold at `date` (side 2 also once the hold ran out, until the
    /// phone logs it). Nil for one-sided holds, while paused or resting, or when no hold runs.
    public func holdSide(at date: Date) -> HoldSide? {
        guard holdSideCount > 1, !isPaused, restEndsAt == nil, let start = setStartedAt,
              let total = timedSetSeconds, total > 0 else { return nil }
        let perSide = Double(total) / Double(holdSideCount)
        let elapsed = max(0, date.timeIntervalSince(start))
        let number = min(holdSideCount, Int(elapsed / perSide) + 1)
        let sideStart = start.addingTimeInterval(perSide * Double(number - 1))
        return HoldSide(number: number, count: holdSideCount, start: sideStart, end: sideStart.addingTimeInterval(perSide))
    }

    /// When to switch sides in a running per-side hold (the end of side 1); nil otherwise.
    public var holdSwitchAt: Date? {
        guard let start = setStartedAt, let first = holdSide(at: start) else { return nil }
        return first.end
    }

    /// The exercise and set the plan says are due.
    public var current: (exercise: WatchExercise, set: WatchSet, number: Int, of: Int)? {
        guard let currentSetID else { return nil }
        for exercise in exercises {
            if let index = exercise.sets.firstIndex(where: { $0.id == currentSetID }) {
                return (exercise, exercise.sets[index], index + 1, exercise.sets.count)
            }
        }
        return nil
    }

    /// While waiting for the current set: seconds over (positive) or under the planned rest.
    public func waitingDelta(at date: Date = Date()) -> Double? {
        guard restEndsAt == nil, setStartedAt == nil, let lastSetEndedAt, let plannedRestSeconds else { return nil }
        return date.timeIntervalSince(lastSetEndedAt) - Double(plannedRestSeconds)
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
                    WatchSet(id: set.id, index: item.displayIndex(of: set), label: set.label(mode: item.mode, unit: unit), isDone: set.isDone,
                             reps: item.mode == .reps ? set.effectiveReps : nil,
                             targetReps: item.mode == .reps ? set.targetRepsValue : nil,
                             weightKg: set.effectiveWeight,
                             seconds: item.mode == .time ? set.effectiveSeconds : nil,
                             isTimed: item.mode == .time)
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
    /// The workout that was just saved (shown as a summary on the watch).
    public var lastFinished: WatchFinishSummary?
    /// Which commands the phone's George reads (nil: a phone from before v7 – it drops a command
    /// it can't read). 1: `WatchCommand.undoSet`.
    public var protocolVersion: Int?

    /// What this build of George reads.
    public static let currentProtocolVersion = 1

    public init(generatedAt: Date = Date(), templates: [WatchTemplate], upcoming: [WatchSessionSummary], streak: WatchStreak?, live: WatchLiveState?, unit: WeightUnit, discardedSessionID: UUID? = nil, lastFinished: WatchFinishSummary? = nil,
                protocolVersion: Int? = WatchSnapshot.currentProtocolVersion) {
        self.generatedAt = generatedAt
        self.templates = templates
        self.upcoming = upcoming
        self.streak = streak
        self.live = live
        self.unit = unit
        self.discardedSessionID = discardedSessionID
        self.lastFinished = lastFinished
        self.protocolVersion = protocolVersion
    }
}

/// Commands the watch sends to the phone (the phone owns the data).
public enum WatchCommand: Codable, Hashable, Sendable {
    /// Flips a set (older watches; newer ones send `completeSet` / `undoSet`, which name the outcome).
    case toggleSet(UUID)
    /// Older watches: whatever set is current when it arrives. Newer ones send `completeSet(id:)`.
    case completeCurrentSet
    /// "I'm starting the set now" – measures the real rest against the plan.
    case startSet
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
    /// Logs a set with what was really done (reps / weight in kg; nil keeps the planned value).
    case completeSet(id: UUID, reps: Int?, weightKg: Double?)
    /// "Can't finish": the set counts with `repsDone`, a lighter drop set follows.
    case dropWeight(setID: UUID, repsDone: Int, newWeightKg: Double)
    /// Make this (open) set the current one – "do this now" instead of the plan's next.
    case makeCurrent(setID: UUID)
    /// Skip to the next (+1) or back to the previous (−1) exercise of the plan.
    case moveThread(Int)
    case toggleVoiceMute
    /// Answers the coach's question (reps left 0…3, fatigue 0…1).
    case answerFeedback(setID: UUID, repsInReserve: Int?, fatigue: Double?)
    /// Energy check-in 1…5.
    case recordEnergy(Int)
    /// "Mark not done": the phone unticks the set only if it is done (a repeat changes nothing).
    case undoSet(UUID)
}

public extension WatchCommand {
    /// "Mark not done" for a done set: `undoSet` for a phone that reads it (`phone` is its latest
    /// snapshot), else `toggleSet` – an older phone drops a command it can't read, and toggling a
    /// done set unticks it too.
    static func markNotDone(_ setID: UUID, phone: WatchSnapshot?) -> WatchCommand {
        (phone?.protocolVersion ?? 0) >= 1 ? .undoSet(setID) : .toggleSet(setID)
    }
}

/// A command with when and for which workout it was sent. The phone drops stale starts (older
/// than two minutes) and commands meant for another workout, e.g. ones queued while out of range.
public struct WatchCommandEnvelope: Codable, Hashable, Sendable {
    public var command: WatchCommand
    public var sentAt: Date
    /// The live workout the watch saw when it sent the command (nil on the home screen).
    public var sessionID: UUID?

    public init(command: WatchCommand, sentAt: Date = Date(), sessionID: UUID?) {
        self.command = command
        self.sentAt = sentAt
        self.sessionID = sessionID
    }

    /// Commands that start something new.
    public var isStart: Bool {
        switch command {
        case .startTemplate, .startSession: return true
        default: return false
        }
    }

    /// Logs or unlogs one named set: safe to apply late, and to apply twice.
    public var targetsOneSet: Bool {
        switch command {
        case .completeSet, .undoSet: return true
        default: return false
        }
    }

    /// Finish or Discard: they end the workout they name, so they count however late they arrive
    /// (the phone finishes at the time of the tap, `sentAt`).
    public var endsWorkout: Bool {
        switch command {
        case .finish, .discard: return true
        default: return false
        }
    }

    /// Whether the phone should act on it, given the running workout and the time now.
    public func isFresh(activeSessionID: UUID?, now: Date = Date()) -> Bool {
        if case .requestSnapshot = command { return true }
        if isStart { return activeSessionID == nil && now.timeIntervalSince(sentAt) <= 120 }
        guard let activeSessionID else { return false }
        if let sessionID, sessionID != activeSessionID { return false }
        // A tick made out of range still counts, however late, as long as it's the same workout –
        // and so does a Finish or Discard (else the workout would run on on the phone for hours).
        if targetsOneSet || endsWorkout, sessionID == activeSessionID { return true }
        // Live commands that are very old are no longer meaningful (the set has moved on).
        return now.timeIntervalSince(sentAt) <= 15 * 60
    }
}

/// Live metrics the watch measures during its HealthKit workout session.
public struct WatchMetrics: Codable, Hashable, Sendable {
    public var heartRate: Double?
    public var averageHeartRate: Double?
    public var activeEnergy: Double?
    public var healthWorkoutID: UUID?
    public var endedAt: Date?
    /// The George workout this recording belongs to (nil from older watches, or before the watch
    /// knows it). The phone links the saved workout by it – also when the message comes late.
    public var sessionID: UUID?

    public init(heartRate: Double? = nil, averageHeartRate: Double? = nil, activeEnergy: Double? = nil, healthWorkoutID: UUID? = nil,
                endedAt: Date? = nil, sessionID: UUID? = nil) {
        self.heartRate = heartRate
        self.averageHeartRate = averageHeartRate
        self.activeEnergy = activeEnergy
        self.healthWorkoutID = healthWorkoutID
        self.endedAt = endedAt
        self.sessionID = sessionID
    }

    /// The recording ended (saved, with its id, or not).
    public var isFinal: Bool { healthWorkoutID != nil || endedAt != nil }
}
