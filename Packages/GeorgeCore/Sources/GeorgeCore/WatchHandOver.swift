import Foundation

// The Apple Watch's recording of a workout when the workout moves to another device, ends there,
// or ends at a time other than "now". The watch records the George workout as an Apple Health
// workout (heart rate, calories); the phone tells it, through its snapshot, when and how that
// recording ends.

/// A workout this iPhone handed over to a Mac ("Continue Here" there) while its watch recorded it
/// (`WatchSnapshot.handedOver`). A Mac has no Apple Health, so the watch keeps recording while the
/// Mac runs the workout, and ends that recording as this says once the workout ended there.
public struct WatchHandOver: Codable, Hashable, Sendable {
    public var sessionID: UUID
    /// When the workout ended on the Mac: the recording ends (and is saved) at this time. Nil while
    /// the Mac runs it: keep recording.
    public var endedAt: Date?
    /// The workout was discarded or deleted, or another device took it over that saves it to Apple
    /// Health itself: the recording is thrown away.
    public var discard: Bool

    public init(sessionID: UUID, endedAt: Date? = nil, discard: Bool = false) {
        self.sessionID = sessionID
        self.endedAt = endedAt
        self.discard = discard
    }
}

/// The iPhone's side of a hand-over to a Mac while the watch records (the "watch-only link"): kept
/// on the iPhone (it survives a relaunch) until the watch's recording is settled. The iPhone ends
/// the watch's recording when the synced workout ends – at its end time, or thrown away when it was
/// discarded or deleted – and links the watch's Apple Health workout to it. Continued back on the
/// iPhone, the iPhone picks the same recording up again, so nothing is counted twice.
public struct WatchOnlyLink: Codable, Equatable, Sendable {
    /// What happens to the watch's recording once the workout ended elsewhere.
    public enum Ending: Codable, Equatable, Sendable {
        /// Saved, ending at the workout's end.
        case save(at: Date)
        /// Thrown away.
        case discard
    }

    /// The synced workout as this iPhone sees it after a sync.
    public enum SyncedWorkout: Equatable, Sendable {
        case deleted
        /// Still in progress, claimed by `owner`; `lastActivity` is its last sign of life.
        case running(owner: LiveOwner?, lastActivity: Date?)
        /// Finished or stopped early.
        case performed(endedAt: Date?)
        /// Planned or skipped again (ended with nothing done, or its ticks taken back).
        case notDone
    }

    /// What the iPhone does with the link after a sync.
    public enum Step: Equatable, Sendable {
        /// The Mac still runs it: the watch keeps recording.
        case keep
        /// The watch ends its recording at this time and saves it.
        case end(at: Date)
        /// The watch throws its recording away.
        case discard
    }

    /// What is left to do once the workout ended (`ending` is set).
    public enum Settlement: Equatable, Sendable {
        /// Waiting for the watch's saved workout (or for the workout to be performed).
        case wait
        /// The watch's workout becomes the George workout's Apple Health link (effort attached).
        case link(UUID)
        /// A workout the watch saved although its recording is thrown away: it goes from Apple Health.
        case deleteWatchWorkout(UUID)
        /// Nothing left to do.
        case drop
    }

    public var sessionID: UUID
    /// When the watch's recording of this run began: the iPhone's start, or when it continued a
    /// workout stopped early before.
    public var recordingSince: Date?
    /// When the iPhone let go of the workout.
    public var linkedAt: Date
    /// The watch was heard recording it.
    public var watchRecording: Bool
    /// The watch's last word on its recording (`WatchMetrics.isFinal`): it ended – saved
    /// (`healthWorkoutID`) or not. An older watch saves its part at the hand-over; watchOS may end
    /// a recording too.
    public var watchFinal: WatchMetrics?
    /// Set once the workout ended elsewhere.
    public var ending: Ending?
    public var endingSince: Date?

    public init(sessionID: UUID, recordingSince: Date?, linkedAt: Date, watchRecording: Bool,
                watchFinal: WatchMetrics? = nil, ending: Ending? = nil, endingSince: Date? = nil) {
        self.sessionID = sessionID
        self.recordingSince = recordingSince
        self.linkedAt = linkedAt
        self.watchRecording = watchRecording
        self.watchFinal = watchFinal
        self.ending = ending
        self.endingSince = endingSince
    }

    /// The Apple Health workout the watch saved for it, if it did.
    public var watchWorkoutID: UUID? { watchFinal?.healthWorkoutID }
    /// When the watch's recording ended (nil while it records).
    public var watchStoppedAt: Date? { watchFinal?.endedAt }

    /// Kept at most this long once the workout ended (the watch may never answer a discard).
    public static let settleTime: TimeInterval = 24 * 60 * 60
    /// Kept at most this long at all.
    public static let lifetime: TimeInterval = 3 * 24 * 60 * 60

    /// Whether the watch keeps recording a workout this iPhone lets go of: only for a Mac (no Apple
    /// Health there; an iPad or iPhone saves the workout itself, so the watch throws its recording
    /// away), and only while the watch records it – or was asked to and hasn't stopped.
    public static func keepsRecording(newOwner: LiveOwner.Kind?, watchHeard: Bool, watchExpected: Bool, watchStopped: Bool) -> Bool {
        newOwner == .mac && !watchStopped && (watchHeard || watchExpected)
    }

    /// What happens to a watch recording of a workout this iPhone doesn't run (any more).
    /// - Parameters:
    ///   - recordingSince: when the recording began – a workout that ended before (a discard that
    ///     kept only the part saved earlier) throws it away.
    ///   - localID: this install's id.
    public static func step(for workout: SyncedWorkout, recordingSince: Date?, localID: String, now: Date) -> Step {
        switch workout {
        case .deleted, .notDone:
            return .discard
        case .performed(let endedAt):
            guard let endedAt else { return .end(at: now) }
            if let recordingSince, endedAt <= recordingSince { return .discard }
            return .end(at: endedAt)
        case .running(let owner, let lastActivity):
            // Taken back here: Continue Here picks the recording up again.
            if owner?.id == localID { return .keep }
            // Another iPhone or an iPad (or a kind this build doesn't know) saves it itself.
            guard owner?.kind == .mac else { return .discard }
            // Left running on the Mac: the recording ends where the workout stopped.
            if let lastActivity, now.timeIntervalSince(lastActivity) > RunningWorkout.staleAfter {
                return .end(at: lastActivity)
            }
            return .keep
        }
    }

    /// The link with a packet from the watch for this workout.
    public func receiving(_ metrics: WatchMetrics, now: Date) -> WatchOnlyLink {
        var result = self
        if metrics.isFinal {
            var final = metrics
            if final.endedAt == nil { final.endedAt = now }
            result.watchFinal = final
            result.watchRecording = false
        } else if watchFinal == nil {
            result.watchRecording = true
        }
        return result
    }

    /// What the iPhone's snapshot tells the watch (nil once there's nothing to say: the watch's
    /// recording ended while the Mac ran the workout).
    public var handOver: WatchHandOver? {
        switch ending {
        case nil:
            return watchFinal == nil ? WatchHandOver(sessionID: sessionID) : nil
        case .save(let at):
            return WatchHandOver(sessionID: sessionID, endedAt: at)
        case .discard:
            return WatchHandOver(sessionID: sessionID, discard: true)
        }
    }

    /// What Continue Here back on this iPhone takes over of the watch's recording.
    public struct Resumption: Equatable, Sendable {
        /// The watch still records it: no new recording starts, nothing is counted twice.
        public var recording: Bool
        /// The watch's recording ended while the workout ran elsewhere (its part saved, or not):
        /// Finish saves the rest from the iPhone.
        public var final: WatchMetrics?

        public init(recording: Bool, final: WatchMetrics?) {
            self.recording = recording
            self.final = final
        }
    }

    /// Continue Here on the workout this link is for – whatever its state, the link goes then. Nil
    /// once the watch was told to throw the recording away (it may have: the iPhone then counts on
    /// the watch only when it hears from it again, else it saves the workout itself).
    public var resumption: Resumption? {
        if case .discard = ending { return nil }
        return Resumption(recording: watchFinal == nil && watchRecording, final: watchFinal)
    }

    /// The watch's final packet as it is linked once the workout ended: its calories and heart rate
    /// only when the recording ran up to the workout's end (`workoutEnd`, else the end it was told).
    /// One that stopped earlier – an older watch saves its part at the hand-over, or it was ended on
    /// the watch – measured one part only, never the whole workout; the link and effort still count.
    public func linkedMetrics(workoutEnd: Date?) -> WatchMetrics? {
        guard var final = watchFinal else { return nil }
        var end = workoutEnd
        if end == nil, case .save(let at) = ending { end = at }
        if let end, let stopped = final.endedAt, end.timeIntervalSince(stopped) > MeasuredNumbers.watchTotalsSlack {
            final.heartRate = nil
            final.averageHeartRate = nil
            final.activeEnergy = nil
        }
        return final
    }

    public func settlement(sessionExists: Bool, sessionPerformed: Bool) -> Settlement {
        switch ending {
        case nil:
            return .wait
        case .discard:
            if let id = watchWorkoutID { return .deleteWatchWorkout(id) }
            return watchFinal != nil ? .drop : .wait
        case .save:
            guard let final = watchFinal else { return .wait }
            guard let id = final.healthWorkoutID else { return .drop }
            if sessionPerformed { return .link(id) }
            return sessionExists ? .wait : .drop
        }
    }

    /// Gone: settled too long ago, or older than `lifetime`.
    public func isExpired(now: Date) -> Bool {
        if let endingSince, now.timeIntervalSince(endingSince) > Self.settleTime { return true }
        return now.timeIntervalSince(linkedAt) > Self.lifetime
    }
}

/// When and how the watch ends its Apple Health recording of a George workout.
public enum WatchRecordingEnd {
    /// What the phone's snapshot says about a recording of a workout it doesn't run live.
    public enum PhoneVerdict: Equatable, Sendable {
        /// Keep recording (the workout runs on a Mac).
        case keep
        /// Save it, ending at this time (nil: now).
        case save(at: Date?)
        case discard
    }

    /// - Parameter sessionID: the workout the recording belongs to.
    public static func verdict(for sessionID: UUID, in snapshot: WatchSnapshot?) -> PhoneVerdict {
        guard let snapshot else { return .save(at: nil) }
        if let handOver = snapshot.handedOver, handOver.sessionID == sessionID {
            if handOver.discard { return .discard }
            if let endedAt = handOver.endedAt { return .save(at: endedAt) }
            return .keep
        }
        // A discarded planned workout goes back to "upcoming" on the phone; a finished one never does.
        if snapshot.discardedSessionID == sessionID || snapshot.upcoming.contains(where: { $0.id == sessionID }) {
            return .discard
        }
        // Finished on the phone: its end, which may be earlier than now (ended at the last set).
        if let finished = snapshot.lastFinished, finished.sessionID == sessionID { return .save(at: finished.finishedAt) }
        return .save(at: nil)
    }

    /// Where the recording's collection ends: the phone's end when it lies after the recording's
    /// start and before now (`now` is when the recording session ended), else now – so a workout
    /// left running and finished at its last set doesn't cover the whole night in Apple Health.
    /// `lastEvent`: the latest pause or resume HealthKit holds for the recording (watch clock) – the
    /// end never goes before it, as a workout's events must lie inside its time. A workout paused and
    /// left running ends where the watch heard the pause (just after the phone's end).
    public static func collectionEnd(requested: Date?, startedAt: Date?, lastEvent: Date? = nil, now: Date) -> Date {
        guard let requested, requested < now else { return now }
        if let startedAt, requested <= startedAt { return now }
        if let lastEvent, lastEvent > requested { return min(lastEvent, now) }
        return requested
    }

    /// After a Finish tapped on the watch: the end the phone's snapshot gives this recording's workout
    /// – nil while it has none, or only one from before this recording began (an earlier part of a
    /// continued workout).
    public static func phoneEnd(for sessionID: UUID, in snapshot: WatchSnapshot?, recordingStart: Date?) -> Date? {
        guard case .save(let end) = verdict(for: sessionID, in: snapshot), let end else { return nil }
        if let recordingStart, end <= recordingStart { return nil }
        return end
    }

    /// A Finish tapped on the watch ends a strength workout that ran past its believable length at
    /// the last set on the phone (`FinishTime.resolvedEnd`): the watch waits a moment for that end
    /// before it saves its recording.
    public static func waitsForPhoneEnd(kind: WorkoutKind, activeSeconds: Double) -> Bool {
        guard let limit = FinishTime.plausibleActiveSeconds(for: kind) else { return false }
        return activeSeconds > limit
    }

    /// How long the watch waits for the phone's end after its own Finish.
    public static let phoneEndWait: TimeInterval = 8

    /// The recording ended clearly before its session did: its running totals cover more than the
    /// workout, so the saved workout's own numbers are sent instead.
    public static func endMovedEarlier(collectionEnd: Date, sessionEnd: Date) -> Bool {
        sessionEnd.timeIntervalSince(collectionEnd) > 60
    }
}

/// When a workout ended on the watch counts as closed there (a late phone state for it is ignored;
/// a phone snapshot made after this time reopens it).
public enum WatchClosing {
    /// Finish: for good – a phone snapshot that crossed with it never reopens it. Discard: from the
    /// tap – the phone ignores a Discard that arrives after the workout went on there, and the
    /// snapshot it sends then shows the workout still running, so the watch shows it again.
    public static func closedFrom(_ command: WatchCommand, tappedAt: Date) -> Date {
        if case .discard = command { return tappedAt }
        return .distantFuture
    }
}

/// What George says when the Apple Watch stopped recording a workout that goes on.
public enum WatchStopWording {
    /// Live mode's notice. `savedPart`: the watch saved what it recorded (else the iPhone saves the
    /// whole workout).
    public static func liveNotice(savedPart: Bool) -> String {
        savedPart
            ? "Apple Watch stopped recording – George saves the rest from iPhone"
            : "Apple Watch stopped recording – George saves the whole workout from iPhone"
    }

    /// The finish sheet's Apple Health line.
    public static func finishLine(savedPart: Bool) -> String {
        savedPart
            ? "Apple Watch stopped recording — the rest is saved from iPhone"
            : "Apple Watch stopped recording — the whole workout is saved from iPhone"
    }
}

public extension LiveOwnership {
    /// "UPPER was ended on your iPad" – said once when another device ended the workout this one ran
    /// ("Start … Anyway" there). "another device" without a known kind.
    static func endedMessage(title: String, owner: LiveOwner?, localID: String, localKind: LiveOwner.Kind?) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "The workout" : name) + " was ended on " + deviceName(of: owner, localID: localID, localKind: localKind)
    }
}
