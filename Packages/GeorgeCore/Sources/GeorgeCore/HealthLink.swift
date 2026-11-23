import Foundation

/// One George workout, one Apple Health workout. The Apple Watch records the workout itself when it
/// can (heart rate, the watch's calories); otherwise the iPhone saves it on Finish. These rules keep
/// the two from both saving it (rings and apps like Bevel would count it twice) and keep the link
/// from the George workout to the watch's workout, also when the watch's message comes late.
public enum HealthLink {
    /// Finish waits at most this long for a watch that should record but hasn't been heard from.
    public static let watchWait: TimeInterval = 15

    /// The watch saves the workout to Apple Health itself: it was heard recording it (or already
    /// saved it) and didn't stop on the way.
    public static func watchSaves(watchHeard: Bool, watchWorkoutID: UUID?, watchStoppedAt: Date?) -> Bool {
        watchStoppedAt == nil && (watchHeard || watchWorkoutID != nil)
    }

    /// Finish waits a moment before the iPhone saves its own workout: the watch was asked to record
    /// and is in reach, but nothing came from it yet (a relaunch, or it only just started).
    public static func waitsForWatch(expected: Bool, watchHeard: Bool, watchWorkoutID: UUID?,
                                     watchStoppedAt: Date?, reachable: Bool) -> Bool {
        expected && reachable && !watchHeard && watchWorkoutID == nil && watchStoppedAt == nil
    }

    /// What to do when the watch reports the workout it saved for a George workout.
    public struct Plan: Equatable, Sendable {
        /// The George workout's Apple Health link from now on (nil: it stays as it is).
        public var linkID: UUID?
        /// A workout the iPhone saved for the same time because it didn't hear from the watch: it goes.
        public var deleteID: UUID?

        public init(linkID: UUID?, deleteID: UUID?) {
            self.linkID = linkID
            self.deleteID = deleteID
        }
    }

    /// - Parameters:
    ///   - watchWorkoutID: the workout the watch saved.
    ///   - linkedID: the George workout's current link (`healthWorkoutID`).
    ///   - phoneSavedID: what the iPhone saved on Finish without hearing from the watch (nil when it
    ///     didn't, or knew the watch recorded).
    public static func plan(watchWorkoutID: UUID, linkedID: UUID?, phoneSavedID: UUID?) -> Plan {
        let delete = phoneSavedID == watchWorkoutID ? nil : phoneSavedID
        if linkedID == watchWorkoutID { return Plan(linkID: nil, deleteID: delete) }
        if linkedID == nil || linkedID == phoneSavedID { return Plan(linkID: watchWorkoutID, deleteID: delete) }
        // Linked to an earlier part (a workout continued after "stopped early"): that link stays.
        return Plan(linkID: nil, deleteID: delete)
    }
}

/// A finished workout whose Apple Health link may still change: the watch's workout id hasn't come
/// yet, or the iPhone saved its own without hearing from the watch. Kept on the device (a relaunch
/// in between must not lose it) for a few days.
public struct PendingHealthLink: Codable, Equatable, Sendable {
    public var sessionID: UUID
    /// The effort rated on Finish (attached to the watch's workout when it comes).
    public var effort: Int
    public var finishedAt: Date
    /// The workout the iPhone saved itself – removed if the watch's own turns up after all.
    public var phoneWorkoutID: UUID?

    public init(sessionID: UUID, effort: Int, finishedAt: Date, phoneWorkoutID: UUID? = nil) {
        self.sessionID = sessionID
        self.effort = effort
        self.finishedAt = finishedAt
        self.phoneWorkoutID = phoneWorkoutID
    }

    /// Kept this long after Finish.
    public static let lifetime: TimeInterval = 3 * 86_400
    /// At most this many are kept (the newest).
    public static let limit = 20

    /// Without the expired ones (and at most `limit`, newest first).
    public static func pruned(_ links: [PendingHealthLink], now: Date) -> [PendingHealthLink] {
        let alive = links.filter { now.timeIntervalSince($0.finishedAt) <= lifetime }
            .sorted { $0.finishedAt > $1.finishedAt }
        return Array(alive.prefix(limit))
    }

    /// Adds `link`, replacing an older one for the same workout.
    public static func adding(_ link: PendingHealthLink, to links: [PendingHealthLink], now: Date) -> [PendingHealthLink] {
        pruned(links.filter { $0.sessionID != link.sessionID } + [link], now: now)
    }

    /// Without the one for `sessionID`.
    public static func removing(_ sessionID: UUID, from links: [PendingHealthLink]) -> [PendingHealthLink] {
        links.filter { $0.sessionID != sessionID }
    }
}
