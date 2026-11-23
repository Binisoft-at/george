import Foundation

/// A workout marked "in progress" as one device sees it: the synced status (active) plus the id each
/// device keeps of the workout it runs itself (UserDefaults). A workout that is active but not this
/// device's own runs on another iPhone, iPad or Mac – or was left running by accident when an app was
/// closed mid-workout and never came back. When the session names the device that claimed it, that
/// claim decides (`LiveOwnership`).
public enum RunningWorkout {
    /// A workout nobody has touched for this long was left running by accident.
    public static let staleAfter: TimeInterval = 12 * 60 * 60

    /// The last sign of life: the newest ticked or started set, the last resume, else the start.
    public static func lastActivity(startedAt: Date?, resumedAt: Date?, content: WorkoutContent) -> Date? {
        let sets = content.allItems.flatMap(\.sets)
        let marks = sets.compactMap(\.doneAt) + sets.compactMap(\.startedAt) + [resumedAt, startedAt].compactMap { $0 }
        return marks.max()
    }

    /// Left running by accident: no sign of life for about half a day. Without any date it is stale
    /// too (it can't be running anywhere in a meaningful way).
    public static func isStale(startedAt: Date?, resumedAt: Date?, content: WorkoutContent, now: Date = Date()) -> Bool {
        guard let last = lastActivity(startedAt: startedAt, resumedAt: resumedAt, content: content) else { return true }
        return now.timeIntervalSince(last) > staleAfter
    }

    /// What a workout that is ended from outside becomes (a stale one, or one ended from another
    /// device with "Start anyway"): stopped early when sets were done, otherwise planned again.
    public static func endedStatusIsPartial(_ content: WorkoutContent) -> Bool {
        content.completedSets > 0
    }

    /// "UPPER · 7/17 sets" – the line for a workout running on another device.
    public static func progressLine(title: String, content: WorkoutContent) -> String {
        let name = title.isEmpty ? "Workout" : title
        guard content.totalSets > 0 else { return name }
        return "\(name) · \(content.completedSets)/\(content.totalSets) sets"
    }

    /// What a Start button should do, given what runs where.
    public enum StartDecision: Equatable {
        /// Nothing in the way: start (or resume this device's own workout).
        case start
        /// The target is the workout running here: just show it.
        case showRunning
        /// Another workout runs here: ask (keep going / finish first / save and start).
        case askRunningHere
        /// A workout runs on another device (this id): ask (continue here / start anyway / cancel)
        /// instead of starting a second one – both devices would save over each other.
        case askRunningElsewhere(UUID)
    }

    /// - Parameters:
    ///   - targetID: the session a Start button wants (nil for a template or an empty workout).
    ///   - targetIsActive: whether that session is marked in progress (synced status).
    ///   - runningHereID: the workout live mode runs on this device right now.
    ///   - ownedID: the workout this device started last (it may not be attached yet after a launch).
    ///   - elsewhereID: the workout shown as "running on another device" (already without stale ones).
    public static func decide(
        targetID: UUID?, targetIsActive: Bool, runningHereID: UUID?, ownedID: UUID?, elsewhereID: UUID?
    ) -> StartDecision {
        if let runningHereID {
            return targetID == runningHereID ? .showRunning : .askRunningHere
        }
        if let targetID, targetIsActive, targetID != ownedID {
            // Continuing a workout another device runs: never a second live copy without asking.
            return .askRunningElsewhere(targetID)
        }
        if let elsewhereID, elsewhereID != targetID {
            return .askRunningElsewhere(elsewhereID)
        }
        return .start
    }

    /// Whether starting the target means taking over a workout from another device ("Continue
    /// here") rather than starting it: it is in progress and not this device's own.
    public static func takesOver(targetIsActive: Bool, targetID: UUID?, runningHereID: UUID?, ownedID: UUID?) -> Bool {
        guard let targetID, targetIsActive else { return false }
        return targetID != runningHereID && targetID != ownedID
    }
}

/// Short header lines for detail screens.
public enum HeaderSummary {
    /// "Gym · Gym – Strength Block" reads twice: the kind is left out when the program name already
    /// starts with it ("Gym – Strength Block"). Without a program: "Gym · No program".
    public static func kindAndProgram(kind: String, program: String?) -> [String] {
        guard let program, !program.isEmpty else { return [kind, "No program"] }
        let programWords = program.lowercased()
        let kindWord = kind.lowercased()
        if !kindWord.isEmpty, programWords.hasPrefix(kindWord) {
            // Only a whole word: "Gymnastics" does not start with the kind "Gym".
            let rest = programWords.dropFirst(kindWord.count)
            if rest.isEmpty || rest.first.map({ !$0.isLetter && !$0.isNumber }) == true {
                return [program]
            }
        }
        return [kind, program]
    }

    /// "13 workouts · 3 templates" (the help text of a program's count in the Mac sidebar).
    public static func programCounts(workouts: Int, templates: Int) -> String {
        let w = workouts == 1 ? "1 workout" : "\(workouts) workouts"
        let t = templates == 1 ? "1 template" : "\(templates) templates"
        return "\(w) · \(t)"
    }
}
