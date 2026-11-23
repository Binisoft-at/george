import Foundation
import SwiftUI
import SwiftData
import BinisoftKit
import UserNotifications
import GeorgeCore
#if os(iOS)
import UIKit
import AudioToolbox
#endif

/// Runs the "currently working out" mode: the clock, set completion, rest timer,
/// on-the-fly edits, the Apple Watch link and the finish → Apple Health flow.
@MainActor
@Observable
final class LiveWorkoutController {
    struct FinishSummary: Identifiable {
        let id = UUID()
        var sessionID: UUID
        var title: String
        var duration: Double
        var completedSets: Int
        var totalSets: Int
        var volumeKg: Double
        var energyKcal: Double
        var averageHeartRate: Double?
        var records: [PersonalRecord]
        var canUpdateTemplate: Bool
        var templateName: String
        var savedToHealth: Bool
        /// Compared with the last time this workout was done (nil the first time).
        var comparison: SessionComparison? = nil
        /// What "Update Loads" would change in the template ("Deadlift 100→105 kg", "Plank 45s→1 min").
        var loadChanges: [String] = []
        /// A workout without a template that could become one.
        var canSaveAsTemplate = false
        var kind: WorkoutKind = .gym
        /// The stretch routine that fits what was trained (offered on the finish screen).
        var coolDown: Routine? = nil
        /// Said instead of "Saved to Apple Health" ("Watch stopped recording · …").
        var healthNote: String? = nil
    }

    /// What a Start button wants to start. While another workout runs, George asks first.
    enum StartTarget: Identifiable {
        case template(WorkoutTemplate)
        case session(WorkoutSession)
        case empty(program: Program?, kind: WorkoutKind?, rescue: Bool)

        var id: String {
            switch self {
            case .template(let template): return "t" + template.id.uuidString
            case .session(let session): return "s" + session.id.uuidString
            case .empty(_, let kind, let rescue): return "e\(kind?.rawValue ?? "")\(rescue)"
            }
        }

        var title: String {
            switch self {
            case .template(let template): return template.name
            case .session(let session): return session.title
            case .empty(_, _, let rescue): return rescue ? "Rescue Workout" : "Empty Workout"
            }
        }
    }

    private let store: GeorgeStore
    private let health: HealthKitManager
    private let watch: PhoneWatchConnector
    private let library: ExerciseLibrary

    private(set) var session: WorkoutSession?
    private(set) var content = WorkoutContent()
    private(set) var currentRef: WorkoutContent.SetRef?
    /// The exercise shown in the live pager (follows the current set unless the user swipes).
    var focusedItemID: UUID?
    var isPresented = false
    /// The expanded coach panel (tap the bar at the bottom of live mode).
    var showPanel = false
    /// Screenshots: open the "lower the weight" ("drop") or "swap" sheet in live mode.
    var demoSheetRequest: String?
    /// The last set done out of the planned order (banner with "stay on plan" / "continue here").
    private(set) var offPlanNotice: OffPlanNotice?
    @ObservationIgnored private var offPlanTask: Task<Void, Never>?
    private(set) var restEndsAt: Date?
    private(set) var restTotal = 0
    private(set) var heartRate: Double?
    private(set) var watchAverageHeartRate: Double?
    private(set) var watchEnergy: Double?
    private(set) var watchIsRecording = false
    private(set) var lastCompletedSetID: UUID?
    var summary: FinishSummary?
    /// A start that would end the running workout – RootView asks "keep going / end and start".
    var pendingStart: StartTarget?
    /// Set with `pendingStart` when the start would collide with a workout another device runs
    /// (synced): RootView asks "continue here / start anyway / cancel" instead.
    private(set) var otherDeviceSession: WorkoutSession?
    /// Why a start was refused (the workout can't be read on this device) – RootView shows it once.
    var startRefusal: String?
    /// Live mode should open the finish sheet (watch, Live Activity, "finish first").
    var finishRequest = false
    /// The empty workout's "Add Exercise" button (the live view opens the picker).
    var requestAddExercise = false
    /// Menu bar "Discard…": the live view asks first.
    var discardRequest = false
    /// Per-side holds: 1 or 2 while a timed per-side set runs.
    private(set) var timedSide: Int?
    /// A tick that can be undone for a few seconds (the minimised bar and the coach bar show it).
    private(set) var undoableTick: UndoableTick?

    struct UndoableTick: Identifiable, Equatable {
        let id = UUID()
        var setID: UUID
        var text: String
    }

    // MARK: Coach state

    /// A moment worth a banner: exercise done, new best, halfway.
    struct Celebration: Identifiable, Equatable {
        enum Kind: Equatable { case exercise, record, halfway, allDone }
        let id = UUID()
        var kind: Kind
        var title: String
        var subtitle: String
        var symbol: String
    }

    /// After an exercise's last set: how fatigued the muscles are (and, for rep sets, how many reps
    /// were left). One quick card, gone by itself after a while.
    struct EffortRequest: Identifiable, Equatable {
        let id = UUID()
        var setID: UUID
        var itemID: UUID
        var itemName: String
        /// "chest, triceps"
        var muscles: String
        var asksReps: Bool
        var asksFatigue: Bool
        /// Answers given so far (each tap is saved at once).
        var fatigue: Double? = nil
        var repsInReserve: Int? = nil
    }

    /// A set was done outside the planned order. George counts it, says so, and asks whether to
    /// stay on the plan or continue from here.
    struct OffPlanNotice: Identifiable, Equatable {
        let id = UUID()
        var itemID: UUID
        var itemName: String
        var setText: String
        /// What the plan has next (nil when nothing is left).
        var plannedName: String?
        var plannedSetText: String?
    }

    /// Where the current set is.
    enum Phase: Equatable {
        /// Waiting for you to start (after a rest, or at the beginning).
        case ready
        /// The set is being done (Start tapped, or a timed set running).
        case working
        /// Resting after the last set.
        case resting
    }

    /// Planned versus actual, for the live panel.
    struct PaceSnapshot {
        var plannedRest: Double
        /// While waiting: over (+) or under (−) the planned rest so far.
        var waitingDelta: Double?
        /// All breaks so far: positive = behind the plan.
        var totalDelta: Double
        var averageDelta: Double?
        var lastGap: RestGap?
        var gaps: [RestGap]
        var plannedDuration: Double
        var projectedDuration: Double
        var tips: [String]
    }

    /// Momentum (the flame), on-time streak and the set timer.
    private(set) var pace = PaceTracker()
    /// How hard the coach pushes today (from the energy check-in, or chosen in the menu).
    private(set) var intensity: CoachIntensity = .normal
    private(set) var celebration: Celebration?
    private(set) var effortRequest: EffortRequest?
    /// Bumps on every completed set (drives bursts and the muscle pulse).
    private(set) var completionPulse = 0
    private(set) var lastCompletedItemID: UUID?

    @ObservationIgnored private var effortAsked = 0
    /// When the current set's timer (timed sets) runs out.
    private(set) var timedSetEndsAt: Date?
    @ObservationIgnored private var timedSetTask: Task<Void, Never>?
    @ObservationIgnored private var plannedDuration: Double = 0
    /// The heaviest weight per exercise before this workout; nil until the first weighted tick needs it.
    @ObservationIgnored private var bestWeights: [String: Double]?
    @ObservationIgnored private var restBeforeNext: Double = 0
    @ObservationIgnored private var nudgeTask: Task<Void, Never>?
    @ObservationIgnored private var nudgesGiven = 0
    @ObservationIgnored private var halfwayAnnounced = false
    @ObservationIgnored private var restWarningTask: Task<Void, Never>?
    @ObservationIgnored private var celebrationTask: Task<Void, Never>?
    @ObservationIgnored private var effortTask: Task<Void, Never>?

    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var restNotificationTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveSync = Date.distantPast
    @ObservationIgnored private var liveSyncTask: Task<Void, Never>?
    @ObservationIgnored private var isFinishing = false
    /// Pace and rest before the last tick, so a mistaken tick can be undone cleanly. The set that
    /// was due is kept by id (an edit in between may move it).
    @ObservationIgnored private var beforeLastTick: (setID: UUID, pace: PaceTracker, restBeforeNext: Double, currentSetID: UUID?, best: [String: Double]?)?
    /// How the session looked before this Start (see `LiveResume.PreStart`): Discard puts a
    /// continued or rescheduled workout back instead of deleting what was saved before.
    @ObservationIgnored private var preStart: LiveResume.PreStart?
    /// The running session's id, also after the session was deleted (a deleted model is not read).
    @ObservationIgnored private var attachedID: UUID?
    /// The set and text the pending "Rest is over" notification was built with.
    @ObservationIgnored private var restNotificationKey: String?
    /// The exercise done off plan last (a second set on it adopts it quietly).
    @ObservationIgnored private var lastOffPlanItemID: UUID?
    /// "Not in this workout" on the feedback card.
    @ObservationIgnored private var skipFeedbackThisWorkout = false
    /// While paused: what was left of the rest and of a timed set.
    @ObservationIgnored private var pausedRest: (remaining: Double, total: Int)?
    @ObservationIgnored private var pausedTimed: (remaining: Double, setID: UUID)?
    @ObservationIgnored private var pausedAt: Date?
    /// Pauses since Start: Apple Health gets them as pause/resume events (kept in `LiveResume`).
    @ObservationIgnored private var pauseLog: [PauseSpan] = []
    /// The Apple Watch was asked to record this workout (paired, George installed): Finish waits a
    /// moment for it before the iPhone saves its own Apple Health workout. Kept in `LiveResume`.
    @ObservationIgnored private var watchExpected = false
    /// The watch's recording ended while the workout went on (ended there, or by watchOS): it saved
    /// that part, Finish saves the rest from the iPhone.
    private(set) var watchStoppedAt: Date?
    /// "Apple Watch stopped recording – …": live mode shows it (toasts don't show there) until closed
    /// or the watch records again.
    private(set) var watchStopNotice: String?
    /// The Apple Health workout the watch saved for this workout (or its first part).
    @ObservationIgnored private var watchWorkoutID: UUID?
    /// Finish is waiting for a sign from the watch (the finish sheet says so).
    private(set) var isWaitingForWatch = false
    /// Today's "Still training?" was answered with Continue for this workout.
    private(set) var stillTrainingDismissedID: UUID?
    @ObservationIgnored private var didRepairHealthLinks = false
    @ObservationIgnored private var pendingHealthSessionID: UUID?
    @ObservationIgnored private var pendingEffort = 0
    /// Tells the watch to throw away its Health recording for this session.
    @ObservationIgnored private var lastDiscardedSessionID: UUID?
    /// When this device claimed the running workout (`claim`). A later claim synced from another
    /// device means "Continue Here" was used there: this one lets go (`confirmOwnership`).
    @ObservationIgnored private var ownClaimedAt: Date?
    /// How often this device answered an older claim with its own since it claimed the workout.
    @ObservationIgnored private var reclaims = 0
    /// The stored workout as this device last wrote or read it. Different data at the next save means
    /// someone else wrote in between: their sets are merged in, not saved over (`mergeOutsideChanges`).
    @ObservationIgnored private var lastSeenData: Data?
    /// "Continued on your Mac" – the workout moved to another device; RootView shows it once.
    var handOverNotice: String?

    init(store: GeorgeStore, health: HealthKitManager, watch: PhoneWatchConnector, library: ExerciseLibrary) {
        self.store = store
        self.health = health
        self.watch = watch
        self.library = library
        watch.onCommand = { [weak self] envelope in self?.handle(envelope) }
        watch.onMetrics = { [weak self] metrics in self?.handle(metrics) }
        watch.onActivated = { [weak self] in self?.watchDidActivate() }
        watch.snapshotProvider = { [weak self] in
            self?.makeSnapshot() ?? WatchSnapshot(templates: [], upcoming: [], streak: nil, live: nil, unit: .kg)
        }
        // The watch came into reach: just the running workout, not a whole snapshot (streak, plans).
        watch.liveProvider = { [weak self] in self?.liveState() }
        // After each iCloud import: the running workout may have ended, been deleted or continued on
        // another device – checked directly, also when the import moved no counter.
        importObserver = NotificationCenter.default.addObserver(forName: CloudImportRefresher.didRefresh, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncedStatusChanged(fromImport: true) }
        }
    }

    @ObservationIgnored private var importObserver: NSObjectProtocol?

    var isActive: Bool { session != nil }
    /// The exercise catalog (routines, alternatives).
    var catalog: ExerciseCatalog { library.catalog }
    var isPaused: Bool { session?.resumedAt == nil }
    var unit: WeightUnit { store.unit }

    func elapsed(at date: Date = Date()) -> Double { session?.elapsedSeconds(at: date) ?? 0 }

    var currentItem: WorkoutItem? { currentRef.flatMap { content.item(at: $0) } }
    var currentSet: WorkoutSet? { currentRef.flatMap { content.set(at: $0) } }

    var focusedItem: WorkoutItem? {
        if let focusedItemID, let item = content.item(id: focusedItemID) { return item }
        return currentItem ?? content.allItems.first
    }

    /// The set that comes after the current one (for "Up next").
    var upNext: (item: WorkoutItem, set: WorkoutSet)? {
        guard let currentRef, let ref = content.nextPendingSet(after: currentRef), ref != currentRef,
              let item = content.item(at: ref), let set = content.set(at: ref) else { return nil }
        return (item, set)
    }

    func restRemaining(at date: Date = Date()) -> Int {
        guard let restEndsAt else { return 0 }
        return max(0, Int(restEndsAt.timeIntervalSince(date).rounded(.up)))
    }

    // MARK: Lifecycle

    /// Re-attach to a session that was running when the app was closed – only on the device that
    /// started it (another iPhone, iPad or Mac shows it as "running on another device").
    func restore() {
        // Once per launch: workouts the watch recorded whose Apple Health link never arrived.
        if !didRepairHealthLinks {
            didRepairHealthLinks = true
            Task { await repairWatchHealthLinks() }
        }
        // A workout handed over to a Mac that ended while George was closed: the watch ends its recording.
        checkWatchOnlyLink()
        // This device's own workout, by its id – not just the newest one in progress, which may be
        // another device's (then this one never got its own back, and it stayed in progress).
        guard session == nil,
              let id = UserDefaults.standard.string(forKey: Prefs.liveSessionID).flatMap(UUID.init(uuidString:)),
              let active = store.session(id: id) else { return }
        guard active.status == .active else {
            // Ended elsewhere while this device didn't hear of it (closed, or suspended before the
            // import was looked at): what it kept about the workout goes, as `detach` does, so a later
            // Continue Here or Discard never starts from an old run.
            // Ended on a Mac (continued there, or "Start … Anyway" there): it saved nothing to Apple
            // Health, so the watch's recording ends at the workout's end – or is thrown away – not now.
            let resume = LiveResume.load(for: id)
            if keepWatchRecording(sessionID: id, for: LiveOwner(raw: active.liveDeviceID), heard: resume?.watchRecording ?? false,
                                  expected: resume?.watchExpected ?? false, stopped: resume?.watchStoppedAt != nil,
                                  since: LiveResume.loadPreStart(for: id)?.segmentStartedAt ?? active.startedAt) {
                checkWatchOnlyLink()
            }
            LiveResume.clear(for: id)
            UserDefaults.standard.removeObject(forKey: Prefs.liveSessionID)
            UserDefaults.standard.removeObject(forKey: Prefs.liveClaimedAt)
            return
        }
        // Continued on another device while this app was closed: it isn't taken back here.
        guard restoreOwnership(of: active) else { return }
        attach(active, restoring: true)
        beginPhoneSessionWhenWatchIsKnown(kind: active.kind)
        syncWatch()
        // Came back within half an hour of the last set: straight back into live mode.
        if let last = content.allItems.flatMap(\.sets).compactMap(\.doneAt).max() ?? active.startedAt,
           Date().timeIntervalSince(last) < 30 * 60 {
            isPresented = true
        }
    }

    /// A workout that runs on another device (synced through iCloud) – shown read-only with "Continue here".
    /// One left in progress by accident (no sign of life for half a day) doesn't count; the next start
    /// ends it (`endStaleWorkouts`).
    var workoutOnOtherDevice: WorkoutSession? {
        guard session == nil else { return nil }
        let own = ownedSessionID
        let localID = ThisDevice.installID
        return store.activeSessions.first { active in
            // Another install's claim decides (it may still be this device's own id after a hand-over);
            // without one (older builds), the id this device keeps does.
            LiveOwnership.runsElsewhere(sessionID: active.id, ownedID: own, owner: LiveOwner(raw: active.liveDeviceID), localID: localID)
                && !RunningWorkout.isStale(startedAt: active.startedAt, resumedAt: active.resumedAt, content: active.content)
        }
    }

    /// Whether the start being asked about is the very workout running on the other device (a list's
    /// "Continue" on it): then the dialog offers only "Continue Here".
    var pendingStartIsOtherDeviceWorkout: Bool {
        guard let otherDeviceSession, case .session(let target) = pendingStart else { return false }
        return target.id == otherDeviceSession.id
    }

    /// The start dialog was cancelled.
    func cancelPendingStart() {
        pendingStart = nil
        otherDeviceSession = nil
    }

    /// "Continue Here" in the start dialog: the workout the other device runs continues on this one.
    func continueOtherDeviceWorkoutHere(_ other: WorkoutSession) {
        cancelPendingStart()
        guard session == nil, other.modelContext != nil, other.status == .active else { return }
        continueHere(other)
    }

    /// "Start … Anyway": the workout on the other device is saved as stopped early (that device lets
    /// go once the change syncs), then this start goes ahead.
    func startAnyway(_ target: StartTarget, endingOn other: WorkoutSession) {
        cancelPendingStart()
        guard session == nil else { return }
        endElsewhere(other)
        perform(target)
    }

    /// Ends a workout this device doesn't run: stopped early with the sets done, otherwise planned
    /// again. The device that ran it lets go when this syncs (`syncedStatusChanged`).
    private func endElsewhere(_ other: WorkoutSession) {
        guard other.modelContext != nil, other.status == .active, other.id != session?.id else { return }
        let content = other.content
        if RunningWorkout.endedStatusIsPartial(content) {
            // Where it really stopped, as Finish would: left idle, at its last set + rest – not hours
            // later, now (`FinishTime.endFromOutside`).
            let clock = LiveClock(startedAt: other.startedAt, accumulatedSeconds: other.accumulatedSeconds, resumedAt: other.resumedAt)
            let end = FinishTime.endFromOutside(clock: clock, kind: other.kind, content: content,
                                                restSeconds: Double(store.settings.defaultRestSeconds), now: Date())
            other.accumulatedSeconds = clock.activeSeconds(until: end)
            other.endedAt = end
            other.status = .partial
        } else {
            // Nothing done: planned again with a fresh clock (its next Start begins at 0:00).
            other.accumulatedSeconds = 0
            other.startedAt = nil
            other.endedAt = nil
            other.status = .planned
        }
        other.resumedAt = nil
        // Who ended it: the device that ran it says so ("UPPER was ended on your iPad").
        other.liveDeviceID = ThisDevice.owner.raw
        other.liveClaimedAt = LiveOwnership.claimTime(now: Date(), previous: other.liveClaimedAt)
        store.save()
        AppLog.info("Ended a workout running elsewhere (\(content.completedSets) sets)", category: "workout")
        // Handed over to a Mac from here: the watch ends its recording with it, before this start's snapshot.
        checkWatchOnlyLink()
    }

    /// Workouts left in progress by accident – an app closed mid-workout that never came back, on any
    /// device – end as stopped early when a new one starts, so they don't block or confuse later ones.
    private func endStaleWorkouts(keeping id: UUID) {
        for stale in store.activeSessions where stale.id != id && stale.id != session?.id
            && RunningWorkout.isStale(startedAt: stale.startedAt, resumedAt: stale.resumedAt, content: stale.content) {
            // The time it ran: up to its last sign of life, not the half day since.
            let last = RunningWorkout.lastActivity(startedAt: stale.startedAt, resumedAt: stale.resumedAt, content: stale.content)
            if let resumed = stale.resumedAt, let last, last > resumed {
                stale.accumulatedSeconds += last.timeIntervalSince(resumed)
            }
            stale.resumedAt = nil
            stale.endedAt = last ?? Date()
            stale.status = RunningWorkout.endedStatusIsPartial(stale.content) ? .partial : .planned
            if stale.status == .planned {
                // Nothing done: planned again with a fresh clock (its next Start begins at 0:00).
                stale.accumulatedSeconds = 0
                stale.startedAt = nil
                stale.endedAt = nil
            }
            LiveResume.clear(for: stale.id)
            AppLog.info("Stale workout ended as stopped early", category: "workout")
        }
    }

    /// "Continue here": this device takes over the workout running elsewhere.
    func continueHere(_ other: WorkoutSession) {
        // Ended or deleted elsewhere since it was shown: nothing to take over.
        guard other.modelContext != nil, other.status == .active else { return }
        // Handed over to a Mac from here while the watch recorded it: that recording is picked up again.
        let watchLink = takeWatchOnlyLink(for: other.id)
        // Unless this device made the last claim (its own run), what it kept about the workout is
        // from an earlier run here: never loaded (an old "before Start" for Discard, an old watch state).
        if LiveOwner(raw: other.liveDeviceID)?.id != ThisDevice.installID { LiveResume.clear(for: other.id) }
        UserDefaults.standard.set(other.id.uuidString, forKey: Prefs.liveSessionID)
        // Claimed and saved at once: the device that ran it lets go as soon as this syncs, instead of
        // saving its stale copy over the sets logged here.
        store.saveWithoutUndo { self.claim(other) }
        attach(other, restoring: true)
        if let watchLink { adoptWatchRecording(watchLink, of: other) }
        #if os(iOS)
        // A paired watch picks the workout up from here and records it.
        if !watchExpected, watch.isPaired && watch.isWatchAppInstalled {
            watchExpected = true
            saveResume()
        }
        #endif
        beginPhoneSessionWhenWatchIsKnown(kind: other.kind)
        isPresented = true
        syncWatch()
    }

    /// The iPhone's own workout session (keeps the coach talking when locked) is only for workouts no
    /// watch records. Right after a (background) launch the watch link may not be up yet, so whether a
    /// watch is paired isn't known: then it waits for `watchDidActivate`.
    @ObservationIgnored private var phoneSessionAwaitsWatch = false

    private func beginPhoneSessionWhenWatchIsKnown(kind: WorkoutKind) {
        if watch.awaitsActivation {
            phoneSessionAwaitsWatch = true
        } else {
            PhoneWorkoutSession.shared.begin(kind: kind, watchWillRecord: watch.isPaired && watch.isWatchAppInstalled)
        }
    }

    /// The watch link is up (paired / installed are known now).
    private func watchDidActivate() {
        guard phoneSessionAwaitsWatch else { return }
        phoneSessionAwaitsWatch = false
        guard let session else { return }
        PhoneWorkoutSession.shared.begin(kind: session.kind, watchWillRecord: watch.isPaired && watch.isWatchAppInstalled)
    }

    /// The synced copy says the workout ended elsewhere, or it was deleted (here or on another
    /// device): let go of it here. `fromImport`: called after an iCloud import (a change made on
    /// another device), not after a change here.
    func syncedStatusChanged(fromImport: Bool = false) {
        // A workout handed over to a Mac from here: the watch's recording of it ends with it.
        checkWatchOnlyLink()
        guard let session, !isFinishing else { return }
        // A deleted model is not read any further (its context is gone).
        let deleted = session.modelContext == nil || store.session(id: session.id) == nil
        if !deleted && session.status == .active {
            // Still in progress: another device may have continued it ("Continue Here" there) – then
            // this one lets go. Sets saved to it from elsewhere are merged in and saved at once.
            guard confirmOwnership() else { return }
            if WorkoutContent.writtenElsewhere(stored: session.contentData, lastSeen: lastSeenData) != nil { persist() }
            return
        }
        AppLog.info(deleted ? "Running workout was deleted" : "Workout ended on another device", category: "workout")
        endedAway(session, deleted: deleted, fromImport: fromImport)
        detach()
    }

    // MARK: Ownership (which device runs the workout)

    /// Marks `claimed` as run by this device from now on (Start, Continue Here). The caller saves
    /// right away, so the device that ran it before lets go as soon as this syncs.
    private func claim(_ claimed: WorkoutSession) {
        let now = LiveOwnership.claimTime(now: Date(), previous: claimed.liveClaimedAt)
        ownClaimedAt = now
        reclaims = 0
        UserDefaults.standard.set(now, forKey: Prefs.liveClaimedAt)
        // Running here again: the watch keeps its recording of it.
        if lastDiscardedSessionID == claimed.id { lastDiscardedSessionID = nil }
        stampClaim(on: claimed)
    }

    /// This device's claim (owner and time) on the synced session.
    private func stampClaim(on claimed: WorkoutSession) {
        claimed.liveDeviceID = ThisDevice.owner.raw
        claimed.liveClaimedAt = ownClaimedAt
    }

    /// Whether this device still runs the workout. A newer claim from another device means it was
    /// continued there: this one lets go (`letGo`) instead of saving its stale copy over the sets
    /// logged there. An older one (it arrived late) is answered with this device's claim again, so
    /// both devices end up agreeing on the newer claim.
    @discardableResult
    private func confirmOwnership() -> Bool {
        guard let session, session.modelContext != nil else { return true }
        let owner = LiveOwner(raw: session.liveDeviceID)
        switch LiveOwnership.verdict(stored: owner, storedClaimedAt: session.liveClaimedAt,
                                     localID: ThisDevice.installID, localClaimedAt: ownClaimedAt) {
        case .keep:
            return true
        case .reclaim:
            // Answered several times already: two devices keep writing over each other's claim.
            // This one lets go (Continue Here on either device settles it) instead of saving forever.
            reclaims += 1
            guard reclaims <= 5 else {
                letGo(to: owner)
                return false
            }
            AppLog.info("Older claim from another device answered", category: "workout")
            store.saveWithoutUndo { self.stampClaim(on: session) }
            return true
        case .letGo:
            letGo(to: owner)
            return false
        }
    }

    /// The claim this device kept for the workout it attaches to after a launch. Continued on
    /// another device while the app was closed: let go of it (false) without touching the session.
    private func restoreOwnership(of active: WorkoutSession) -> Bool {
        ownClaimedAt = UserDefaults.standard.object(forKey: Prefs.liveClaimedAt) as? Date
        reclaims = 0
        let owner = LiveOwner(raw: active.liveDeviceID)
        // Our own claim is the one stored with it (also when the local copy of its time is gone).
        if owner?.id == ThisDevice.installID, ownClaimedAt == nil { ownClaimedAt = active.liveClaimedAt }
        switch LiveOwnership.verdict(stored: owner, storedClaimedAt: active.liveClaimedAt,
                                     localID: ThisDevice.installID, localClaimedAt: ownClaimedAt) {
        case .keep:
            return true
        case .reclaim:
            store.saveWithoutUndo { self.stampClaim(on: active) }
            return true
        case .letGo:
            AppLog.info("Workout was continued on another device while George was closed", category: "workout")
            // The watch throws its recording away – or, for a Mac, keeps recording (`WatchOnlyLink`).
            let resume = LiveResume.load(for: active.id)
            if !keepWatchRecording(sessionID: active.id, for: owner, heard: resume?.watchRecording ?? false,
                                   expected: resume?.watchExpected ?? false, stopped: resume?.watchStoppedAt != nil,
                                   since: LiveResume.loadPreStart(for: active.id)?.segmentStartedAt ?? active.startedAt) {
                lastDiscardedSessionID = active.id
            }
            LiveResume.clear(for: active.id)
            UserDefaults.standard.removeObject(forKey: Prefs.liveSessionID)
            UserDefaults.standard.removeObject(forKey: Prefs.liveClaimedAt)
            ownClaimedAt = nil
            handOverNotice = LiveOwnership.continuedMessage(owner: owner, localID: ThisDevice.installID, localKind: ThisDevice.kind)
            syncWatch()
            return false
        }
    }

    /// Another device continued the workout: let go of it here without touching the synced session.
    /// Live mode closes, the watch gets "no workout", the Live Activity and the rest alert end, and
    /// what this device kept about it (where it stood, how it looked before Start) is cleared.
    private func letGo(to owner: LiveOwner?) {
        guard let session else { return }
        // Ended there ("Start … Anyway" writes its claim too), seen before the import was looked at:
        // said as such, and the watch saves its recording at the workout's end.
        if session.modelContext != nil, session.status != .active {
            AppLog.info("Workout ended on another device", category: "workout")
            VoiceCoach.shared.stop()
            endedAway(session, deleted: false, fromImport: true)
            detach()
            return
        }
        AppLog.info("Workout continued on another device", category: "workout")
        // The watch drops its recording of it: the device that finishes the workout saves it to
        // Apple Health (two overlapping workouts there otherwise). A Mac has no Apple Health: there
        // the watch keeps recording until the workout ends on the Mac (`WatchOnlyLink`).
        if !keepWatchRecording(sessionID: session.id, for: owner, heard: watchIsRecording, expected: watchExpected,
                               stopped: watchStoppedAt != nil, since: preStart?.segmentStartedAt ?? session.startedAt) {
            lastDiscardedSessionID = session.id
        }
        VoiceCoach.shared.stop()
        handOverNotice = LiveOwnership.continuedMessage(owner: owner, localID: ThisDevice.installID, localKind: ThisDevice.kind)
        detach()
    }

    /// Sets saved to the running workout from elsewhere since this device last saved it (a device
    /// that ran it before and saved late, an older build that knows nothing of claims) are merged into
    /// the live copy, so the next save keeps them instead of writing over them
    /// (`WorkoutContent.mergedLive`). "Now" stays on its set unless that one was done elsewhere.
    private func mergeOutsideChanges() {
        guard let session,
              let theirs = WorkoutContent.writtenElsewhere(stored: session.contentData, lastSeen: lastSeenData) else { return }
        AppLog.info("Merged sets saved elsewhere into the running workout", category: "workout")
        let currentID = currentSet?.id
        let anchorID = currentRef.flatMap { content.setBefore($0) }.flatMap { content.set(at: $0)?.id }
        content = WorkoutContent.mergedLive(mine: content, theirs: theirs)
        contentStamp &+= 1
        lastSeenData = session.contentData
        let resolved = content.resolveCurrent(currentID: currentID, anchorID: anchorID)
        let changed = resolved.flatMap { content.set(at: $0)?.id } != currentID
        currentRef = resolved
        if changed {
            timedSetTask?.cancel()
            timedSetEndsAt = nil
            timedSide = nil
            pace.setUndone(previous: pace.lastSetAt)
            VoiceCoach.shared.moveOn(to: currentSet?.id)
        }
        if let focusedItemID, content.item(id: focusedItemID) == nil {
            self.focusedItemID = currentItem?.id
        }
        plannedDuration = WorkoutPace.plannedSeconds(of: content, defaultRest: store.settings.defaultRestSeconds)
    }

    private func attach(_ newSession: WorkoutSession, restoring: Bool = false) {
        resetTransientState()
        // The watch's numbers of a workout before don't carry over (Continue Here, Undo, a relaunch):
        // the panel and Finish wait for this one's.
        heartRate = nil
        watchAverageHeartRate = nil
        watchEnergy = nil
        watchStopNotice = nil
        session = newSession
        attachedID = newSession.id
        content = newSession.content
        contentStamp &+= 1
        lastSeenData = newSession.contentData
        // After a relaunch: how it looked before Start, for Discard (`start` sets it otherwise).
        preStart = restoring ? LiveResume.loadPreStart(for: newSession.id) : nil
        let resume = restoring ? LiveResume.load(for: newSession.id) : nil
        if let id = resume?.currentSetID, let ref = content.locate(setID: id), content.set(at: ref)?.isDone == false {
            currentRef = ref
        } else {
            currentRef = content.nextPendingSet()
        }
        focusedItemID = resume?.focusedItemID.flatMap { content.item(id: $0) != nil ? $0 : nil } ?? currentRef.flatMap { content.item(at: $0)?.id }
        setIdleTimer(disabled: true)
        if newSession.energyBefore > 0 {
            intensity = CoachIntensity.from(energy: newSession.energyBefore)
        } else {
            // The energy rhythm expects a low day today: start calm (the check-in can change it).
            intensity = store.expectedLowEnergyDay(within: 0) != nil ? .calm : .normal
        }
        pace = PaceTracker(slack: intensity.paceSlack)
        let lastDone = content.allItems.flatMap(\.sets).compactMap(\.doneAt).max()
        if let lastDone {
            pace.setCompleted(at: lastDone, plannedRest: nil, workSeconds: 0)
        }
        // The rest the plan wanted before the current set: from the set done last.
        if let resume {
            restBeforeNext = resume.restBeforeNext
            nudgesGiven = resume.nudgesGiven
        } else if let lastDone, let ref = content.executionOrder().last(where: { content.set(at: $0)?.doneAt == lastDone }) {
            restBeforeNext = Double(content.restAfterDone(ref, defaultRest: store.settings.defaultRestSeconds) ?? 0)
        }
        // A set that was started before the app closed keeps running – a paused hold stays paused
        // with the time it had left, a running one continues where it is (pauses left out).
        let wasPaused = resume?.isPaused == true || newSession.resumedAt == nil
        if let set = currentSet, let started = set.startedAt, !set.isDone {
            var holdStart = started
            if let item = currentItem, item.mode == .time, let seconds = set.targetSeconds ?? set.seconds {
                let total = Double(seconds) * (item.perSide ? 2 : 1)
                if wasPaused {
                    if let resume, resume.pausedTimedSetID == set.id, let remaining = resume.pausedTimedRemaining {
                        pausedTimed = (remaining: remaining, setID: set.id)
                        holdStart = (resume.pausedAt ?? Date()).addingTimeInterval(remaining - total)
                    }
                } else {
                    if let resume, resume.currentSetID == set.id, let end = resume.timedSetEndsAt {
                        holdStart = end.addingTimeInterval(-total)
                    }
                    let left = total - Date().timeIntervalSince(holdStart)
                    if left > 1 { startTimedSet(seconds: seconds, setID: set.id, startedAt: holdStart, perSide: item.perSide, silent: true) }
                }
            }
            pace.seed(lastSetAt: lastDone, startedAt: holdStart)
        }
        // A rest that was running.
        if let resume, let end = resume.restEndsAt, end > Date().addingTimeInterval(1) {
            restTotal = resume.restTotal
            restEndsAt = end
            scheduleRestTask()
            scheduleRestNotification()
        }
        // Idle for a long time: no "over your rest" nudges for that.
        if let lastDone, Date().timeIntervalSince(lastDone) > 20 * 60 { nudgesGiven = 2 }
        if wasPaused {
            pausedRest = resume?.pausedRestRemaining.map { (remaining: $0, total: resume?.restTotal ?? 0) }
            pausedAt = resume?.pausedAt ?? Date()
        }
        // The pauses so far and the watch's recording of it (a relaunch keeps them; a Start begins
        // without – `start` sets whether the watch records).
        pauseLog = resume?.pauses ?? []
        if wasPaused, let pausedAt { pauseLog = PauseLog.pausing(pauseLog, at: pausedAt) }
        watchExpected = resume?.watchExpected ?? false
        watchIsRecording = resume?.watchRecording ?? false
        watchStoppedAt = resume?.watchStoppedAt
        watchWorkoutID = resume?.watchWorkoutID
        plannedDuration = WorkoutPace.plannedSeconds(of: content, defaultRest: store.settings.defaultRestSeconds)
        effortAsked = 0
        halfwayAnnounced = content.completedSets * 2 >= max(1, content.totalSets)
        // Worked out at the first weighted tick (`currentBestWeights`), not here: live mode opens first.
        bestWeights = nil
        startNudges()
        LiveActivityBridge.shared.start(liveState())
    }

    /// Clears everything that belongs to one workout (rest, timers, cards, banners) – nothing of the
    /// previous workout may leak into the next one.
    private func resetTransientState() {
        cancelRest()
        timedSetTask?.cancel()
        timedSetEndsAt = nil
        timedSide = nil
        effortTask?.cancel()
        effortRequest = nil
        celebrationTask?.cancel()
        celebration = nil
        offPlanTask?.cancel()
        offPlanNotice = nil
        lastOffPlanItemID = nil
        nudgesGiven = 0
        lastCompletedItemID = nil
        lastCompletedSetID = nil
        beforeLastTick = nil
        undoableTick = nil
        skipFeedbackThisWorkout = false
        restBeforeNext = 0
        pausedRest = nil
        pausedTimed = nil
        pausedAt = nil
        finishRequest = false
        discardRequest = false
        requestAddExercise = false
        persistTask?.cancel()
        persistTask = nil
    }

    /// The heaviest weight per exercise before this workout – worked out once, at the first weighted
    /// tick, from the shared history index (the running workout isn't in it).
    private func currentBestWeights() -> [String: Double] {
        if let bestWeights { return bestWeights }
        let runningID = session?.id
        let best = Self.bestWeights(in: SessionHistory.shared.records(store).filter { $0.id != runningID })
        bestWeights = best
        return best
    }

    private static func bestWeights(in records: [SessionRecord]) -> [String: Double] {
        var best: [String: Double] = [:]
        for record in records {
            for item in record.content.allItems {
                for set in item.sets where set.isDone && set.kind != .warmup {
                    if let weight = set.effectiveWeight, weight > (best[item.exerciseKey] ?? 0) { best[item.exerciseKey] = weight }
                }
            }
        }
        return best
    }

    // MARK: Starting

    /// Every Start button goes through here. With another workout running, George asks first
    /// (RootView shows the dialog) instead of silently ending it.
    func requestStart(_ target: StartTarget) {
        if let session {
            if case .session(let other) = target, other.id == session.id {
                isPresented = true
                return
            }
        }
        // A workout this device can't read, or one a newer George wrote, isn't started here: it would
        // run empty or stripped and then be saved over the real one (lane safety, #12).
        if let refusal = target.contentRefusal {
            AppLog.error("Start refused: \(refusal)", category: "workout")
            Haptics.warning()
            startRefusal = refusal
            return
        }
        if session != nil {
            Haptics.warning()
            pendingStart = target
            return
        }
        // Nothing runs here, but another device runs a workout (synced): ask. A second workout – or a
        // second live copy of the same one – would save over the other with every tick.
        var targetSession: WorkoutSession?
        if case .session(let candidate) = target { targetSession = candidate }
        let elsewhere = workoutOnOtherDevice
        let decision = RunningWorkout.decide(
            targetID: targetSession?.id, targetIsActive: targetSession?.status == .active,
            runningHereID: nil, ownedID: ownedSessionID, elsewhereID: elsewhere?.id
        )
        if case .askRunningElsewhere(let otherID) = decision {
            Haptics.warning()
            otherDeviceSession = otherID == targetSession?.id ? targetSession : elsewhere
            pendingStart = target
            return
        }
        perform(target)
    }

    /// The workout this device started last (UserDefaults; it may not be attached yet after a launch).
    private var ownedSessionID: UUID? {
        UserDefaults.standard.string(forKey: Prefs.liveSessionID).flatMap(UUID.init(uuidString:))
    }

    /// "Keep going with …": the running workout stays, live mode opens.
    func keepCurrentWorkout() {
        pendingStart = nil
        isPresented = true
    }

    /// "Finish … and start": the running workout is saved properly (Apple Health included), then
    /// the new one starts. `target` comes from the dialog's button: by the time this runs, the
    /// dialog's dismissal has cleared `pendingStart`.
    func finishCurrentAndStart(_ target: StartTarget) async {
        pendingStart = nil
        if let session {
            await finish(effort: session.effort > 0 ? session.effort : session.kind.defaultEffort, notes: nil, showSummary: false)
        }
        perform(target)
    }

    /// "Finish first": opens the running workout with its finish sheet.
    func finishCurrentFirst() {
        pendingStart = nil
        isPresented = true
        finishRequest = true
    }

    private func perform(_ target: StartTarget) {
        switch target {
        case .template(let template):
            // A planned session of this template (today or the last two days) is started instead of a duplicate.
            if let planned = store.plannedSession(for: template) { start(planned) } else { start(template: template) }
        case .session(let chosen):
            // In progress on another device: it's taken over ("Continue Here"), never started a second time.
            if RunningWorkout.takesOver(targetIsActive: chosen.status == .active, targetID: chosen.id,
                                        runningHereID: session?.id, ownedID: ownedSessionID) {
                continueHere(chosen)
            } else {
                start(chosen)
            }
        case .empty(let program, let kind, let rescue): startEmpty(program: program, kind: kind, rescue: rescue)
        }
    }

    func start(_ newSession: WorkoutSession, present: Bool = true) {
        let previousDate = newSession.date
        AppLog.info("Workout started (\(newSession.content.exerciseCount) exercises, \(newSession.kind.rawValue))", category: "workout")
        // Saved with the start below.
        endStaleWorkouts(keeping: newSession.id)
        if let session, session.id != newSession.id {
            // Only reached from code paths that already asked (demo screens, "end and start").
            stopCurrentAsPartial()
        }
        // How it looked before this Start, taken before anything changes: Discard puts a continued
        // workout back as it was saved, and a planned one back on its day with its name. A session
        // made by this Start (already active) has nothing to go back to.
        var before: LiveResume.PreStart? = newSession.status == .active ? nil : LiveResume.PreStart(
            statusRaw: newSession.statusRaw, contentData: newSession.contentData, startedAt: newSession.startedAt,
            plannedDate: newSession.plannedDate, endedAt: newSession.endedAt,
            accumulatedSeconds: newSession.accumulatedSeconds, title: newSession.title
        )
        // Started again while it runs here: the first snapshot stays.
        if session?.id == newSession.id { before = preStart }
        let now = Date()
        // A workout continued after "stopped early": Apple Health gets only the part from here.
        if session?.id != newSession.id { before?.segmentStartedAt = now }
        // Planned (or skipped) with nothing done starts with a fresh clock: one ended from outside
        // before may still carry its old start, time and end, and would run on from there.
        if newSession.status == .planned || newSession.status == .skipped, newSession.doneSetCount == 0 {
            newSession.accumulatedSeconds = 0
            newSession.startedAt = nil
            newSession.endedAt = nil
            newSession.resumedAt = nil
        }
        newSession.status = .active
        if newSession.startedAt == nil { newSession.startedAt = now }
        if newSession.plannedDate == nil { newSession.plannedDate = now }
        if newSession.resumedAt == nil { newSession.resumedAt = now }
        if Calendar.current.isDateInToday(newSession.plannedDate ?? now) == false, newSession.doneSetCount == 0 {
            // Starting a session planned for another day moves it to today and renames it.
            newSession.plannedDate = now
            newSession.startedAt = now
            // An automatic title follows the new date; a typed one stays.
            store.retitleIfAuto(newSession, previousDate: previousDate)
            if newSession.title != before?.title { before?.autoTitle = newSession.title }
        }
        // Already answered "how's your energy" on Today? Use it instead of asking again.
        if newSession.energyBefore == 0,
           let today = store.fetchEnergy().last(where: { $0.source == "today" && Calendar.current.isDateInToday($0.date) }) {
            newSession.energyBefore = today.level
        }
        // This device runs it (saved with the start): another device showing it knows where it runs.
        claim(newSession)
        store.save()
        UserDefaults.standard.set(newSession.id.uuidString, forKey: Prefs.liveSessionID)
        attach(newSession)
        preStart = before
        if let before { before.save(for: newSession.id) }
        heartRate = nil
        watchAverageHeartRate = nil
        watchEnergy = nil
        watchIsRecording = false
        if present { isPresented = true }
        #if os(iOS)
        if watch.isPaired && watch.isWatchAppInstalled {
            health.startWatchWorkout(kind: newSession.kind)
            // Kept with where the workout stands: after a relaunch Finish still knows to wait for it.
            watchExpected = true
            saveResume()
        }
        #endif
        // A workout handed over to a Mac that this Start ended as left running (`endStaleWorkouts`):
        // the watch ends that recording at its last sign of life, not now when the new one takes it.
        checkWatchOnlyLink()
        syncWatch()
        Haptics.heavy()
        beginPhoneSessionWhenWatchIsKnown(kind: newSession.kind)
        // Pictures for the whole workout now, while there's signal.
        let pictures = content.allItems.flatMap { library.imageURLs(for: $0) }
        Task.detached(priority: .utility) { await ImageCache.shared.prefetch(pictures) }
        VoiceCoach.shared.stop()
        if newSession.doneSetCount == 0 {
            VoiceCoach.shared.say("Let's go.", cue: .summary)
        }
        announceSetUp(isFirst: newSession.doneSetCount == 0)
    }

    @discardableResult
    func start(template: WorkoutTemplate) -> WorkoutSession {
        let newSession = store.makeSession(from: template, start: true)
        start(newSession)
        return newSession
    }

    @discardableResult
    func startEmpty(program: Program?, kind: WorkoutKind? = nil, rescue: Bool = false) -> WorkoutSession {
        let newSession = store.makeEmptySession(program: program, kind: kind, start: true, rescue: rescue)
        start(newSession)
        return newSession
    }

    private func stopCurrentAsPartial() {
        guard let session else { return }
        // Continued on another device in the meantime: it keeps running there.
        guard confirmOwnership() else { return }
        mergeOutsideChanges()
        session.accumulatedSeconds = session.elapsedSeconds()
        session.resumedAt = nil
        session.endedAt = Date()
        session.content = content
        session.status = content.completedSets > 0 ? .partial : .planned
        store.save()
        LiveResume.clear(for: session.id)
        self.session = nil
    }

    /// Pause: the clock, the rest and a running hold stop; nothing speaks or buzzes until Resume.
    func pause() {
        // While Finish saves (it waits for Apple Health), the session is done: nothing restarts it.
        guard !isFinishing else { return }
        guard let session, session.resumedAt != nil else { return }
        // Continued on another device: its clock isn't stopped from here.
        guard confirmOwnership() else { return }
        flushPersist()
        let now = Date()
        session.accumulatedSeconds = session.elapsedSeconds()
        session.resumedAt = nil
        pausedAt = now
        pauseLog = PauseLog.pausing(pauseLog, at: now)
        if let restEndsAt {
            pausedRest = (remaining: max(0, restEndsAt.timeIntervalSince(now)), total: restTotal)
            cancelRest()
        }
        if let timedSetEndsAt, let set = currentSet {
            pausedTimed = (remaining: max(0, timedSetEndsAt.timeIntervalSince(now)), setID: set.id)
            timedSetTask?.cancel()
            self.timedSetEndsAt = nil
        }
        VoiceCoach.shared.stop()
        store.save(bumping: false)
        saveResume()
        syncLive()
    }

    func resume() {
        guard !isFinishing else { return }
        guard let session, session.resumedAt == nil else { return }
        guard confirmOwnership() else { return }
        let now = Date()
        session.resumedAt = now
        if let pausedAt { pace.shift(by: now.timeIntervalSince(pausedAt)) }
        pausedAt = nil
        pauseLog = PauseLog.resuming(pauseLog, at: now)
        if let rest = pausedRest {
            pausedRest = nil
            if rest.remaining > 1 {
                restTotal = rest.total
                restEndsAt = now.addingTimeInterval(rest.remaining)
                scheduleRestTask()
                scheduleRestNotification()
            }
        }
        if let timed = pausedTimed {
            pausedTimed = nil
            if timed.remaining > 1, currentSet?.id == timed.setID, let item = currentItem, let set = currentSet,
               let seconds = set.targetSeconds ?? set.seconds {
                let total = Double(seconds) * (item.perSide ? 2 : 1)
                startTimedSet(seconds: seconds, setID: set.id, startedAt: now.addingTimeInterval(timed.remaining - total), perSide: item.perSide, silent: true)
            }
        }
        store.save(bumping: false)
        saveResume()
        syncLive()
    }

    func togglePause() { isPaused ? resume() : pause() }

    // MARK: Phase

    var phase: Phase {
        if restEndsAt != nil { return .resting }
        if pace.startedAt != nil { return .working }
        return .ready
    }

    /// Planned rest before the current set (0 before the first set).
    var plannedRestBeforeCurrent: Double { restBeforeNext }

    /// Target of the current set when it's timed (seconds; both sides for per-side holds), else nil.
    var timedTarget: Int? {
        guard let item = currentItem, let set = currentSet, item.mode == .time, let seconds = set.targetSeconds ?? set.seconds else { return nil }
        return seconds * (item.perSide ? 2 : 1)
    }

    /// Stretch, yoga and mobility: a calm sequence of holds – fewer banners and words, holds start by themselves.
    var isFlow: Bool {
        guard let session else { return false }
        if session.kind.isFlow { return true }
        let items = content.allItems
        return !items.isEmpty && items.allSatisfy { $0.mode == .time && ($0.kind ?? session.kind).isFlow }
    }

    // MARK: Sets

    /// "I'm starting the set now": ends a rest that's still running, measures the real break against
    /// the plan, and runs the countdown of a timed set.
    func startSet() {
        guard !isFinishing else { return }
        guard session != nil, let item = currentItem, let set = currentSet, !set.isDone else { return }
        // Continued on another device: nothing starts here any more.
        guard confirmOwnership() else { return }
        if isPaused {
            resume()
            // A paused hold just continues.
            if timedSetEndsAt != nil { return }
        }
        let now = Date()
        if pace.startedAt != nil {
            // Already working. Only a hold whose countdown isn't running (it ran out before a relaunch,
            // or the set changed under it) starts its timer again – the break was measured already.
            guard item.mode == .time, timedSetEndsAt == nil else { return }
            pace.seed(lastSetAt: pace.lastSetAt, startedAt: now)
        } else {
            pace.setStarted(at: now, plannedRest: restBeforeNext)
        }
        if restEndsAt != nil { cancelRest() }
        content.updateSet(id: set.id) { $0.startedAt = now }
        nudgesGiven = 2 // no "over your rest" while working
        Haptics.tap()
        VoiceCoach.shared.moveOn(to: set.id)
        if item.mode == .time, let seconds = set.targetSeconds ?? set.seconds, seconds > 0 {
            startTimedSet(seconds: seconds, setID: set.id, startedAt: now, perSide: item.perSide)
        }
        persist()
    }

    /// Runs a hold: one countdown, or for per-side holds side 1, a "switch sides" moment, then side 2.
    /// `silent` resumes a hold after a pause or relaunch without announcing it again.
    private func startTimedSet(seconds: Int, setID: UUID, startedAt: Date, perSide: Bool = false, silent: Bool = false) {
        timedSetTask?.cancel()
        let sides = perSide ? 2 : 1
        let end = startedAt.addingTimeInterval(Double(seconds * sides))
        timedSetEndsAt = end
        // The side that's running now (side 2 when a pause or relaunch resumes there).
        timedSide = perSide ? (Date() < startedAt.addingTimeInterval(Double(seconds)) ? 1 : 2) : nil
        let flow = isFlow
        if !silent {
            let line = perSide ? "\(CoachScript.duration(seconds)) each side. Go." : "\(CoachScript.duration(seconds)). Go."
            VoiceCoach.shared.say(line, cue: .timedSet, context: setID)
        }
        timedSetTask = Task { [weak self] in
            func sleep(until date: Date) async {
                let delay = date.timeIntervalSinceNow
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
            for side in 1...sides {
                let sideStart = startedAt.addingTimeInterval(Double(seconds * (side - 1)))
                let sideEnd = sideStart.addingTimeInterval(Double(seconds))
                guard sideEnd > Date() else { continue }
                if perSide, let self, self.timedSide != side {
                    self.timedSide = side
                    // The Lock Screen and the watch count the new side down.
                    self.syncLive()
                }
                // Each cue only while its moment is still ahead – a resumed hold doesn't repeat them.
                if side == 2 && sideStart > Date().addingTimeInterval(-3) {
                    Haptics.heavy()
                    VoiceCoach.shared.say("Switch sides.", cue: .timedSet, context: setID, priority: .high)
                }
                let halfway = sideStart.addingTimeInterval(Double(seconds) / 2)
                if seconds >= 40 && !flow && halfway > Date() {
                    await sleep(until: halfway)
                    guard !Task.isCancelled else { return }
                    VoiceCoach.shared.say("Halfway.", cue: .timedSet, context: setID)
                }
                let tenLeft = sideEnd.addingTimeInterval(-10)
                if seconds >= 20 && !flow && side == sides && tenLeft > Date() {
                    await sleep(until: tenLeft)
                    guard !Task.isCancelled else { return }
                    VoiceCoach.shared.say("10 seconds.", cue: .countdown, context: setID)
                }
                if side == sides {
                    await self?.countdown(to: sideEnd, setID: setID)
                }
                await sleep(until: sideEnd)
                guard !Task.isCancelled else { return }
            }
            guard let self, self.currentSet?.id == setID, self.currentSet?.isDone == false else { return }
            self.timedSide = nil
            VoiceCoach.shared.say("Done.", cue: .timedSet, context: setID, priority: .high)
            Haptics.success()
            self.updateSet(setID) { $0.seconds = seconds }
            // Done when the timer ran out, even if this task woke up late.
            self.toggleSet(setID, at: end)
        }
    }

    /// Ticks or unticks a set. `date`: when it was really done (a watch tick that arrived late, the end
    /// of a hold); never later than now.
    func toggleSet(_ id: UUID, at date: Date? = nil) {
        guard !isFinishing, session != nil else { return }
        // Continued on another device: the tick isn't logged on this stale copy (it lets go instead).
        guard confirmOwnership() else { return }
        let now = min(date ?? Date(), Date())
        // Logging a set while paused carries on; unticking a mistaken one doesn't.
        if isPaused, content.set(id: id)?.isDone == false { resume() }
        let ref = content.locate(setID: id)
        let wasCurrent = id == currentSet?.id
        // Another exercise than the planned one (a superset counts as one): done anyway, but the
        // plan keeps its place – unless it's the second set in a row there: then George follows.
        var offPlan = !wasCurrent && ref != nil && currentRef != nil && ref?.blockIndex != currentRef?.blockIndex
        let adoptOffPlan = offPlan && ref.flatMap { content.item(at: $0)?.id } == lastOffPlanItemID && content.set(id: id)?.isDone == false
        if adoptOffPlan { offPlan = false }
        let snapshot = (setID: id, pace: pace, restBeforeNext: restBeforeNext, currentSetID: currentSet?.id, best: bestWeights)
        let nowDone = content.toggleSet(id: id, at: now)
        if nowDone, let ref {
            GeorgeTips.firstSetDone()
            beforeLastTick = snapshot
            lastCompletedSetID = id
            if let item = content.item(at: ref), let set = content.set(at: ref) {
                if set.startedAt == nil, wasCurrent, let started = pace.startedAt {
                    content.updateSet(id: id) { $0.startedAt = started }
                }
                if wasCurrent, item.mode == .time, let endsAt = timedSetEndsAt, now < endsAt, let started = pace.startedAt {
                    // A timed set ticked early keeps the time it really took (one that ran out keeps its target).
                    let took = Int(now.timeIntervalSince(started).rounded()) / (item.perSide ? 2 : 1)
                    if took > 0 { content.updateSet(id: id) { $0.seconds = took } }
                }
                let work = PaceTracker.workSeconds(for: set, mode: item.mode) * (item.perSide ? 2 : 1)
                if !wasCurrent { pace.setUndone(previous: pace.lastSetAt) }
                // A late tick that arrives after a newer one never moves the pace backwards.
                pace.setCompleted(at: max(now, pace.lastSetAt ?? now), plannedRest: pace.lastSetAt == nil ? nil : restBeforeNext, workSeconds: work)
                lastCompletedItemID = item.id
                undoableTick = UndoableTick(setID: id, text: "\(item.name) · \(CoachScript.setPosition(set, in: item)) done")
            }
            timedSetTask?.cancel()
            timedSetEndsAt = nil
            timedSide = nil
            nudgesGiven = 0
            completionPulse += 1
            Haptics.success()
            // On plan: the thread moves on (a superset finishes its round first). Off plan, or a set
            // ahead of the one that's due (set 3 before set 2, B1 before A1): what was due stays due.
            let next = content.currentAfterTick(ref, previous: currentRef, offPlan: offPlan)
            let keepsCurrent = !wasCurrent && next != nil && next == currentRef
            let autoRest = UserDefaults.standard.object(forKey: Prefs.autoRest) as? Bool ?? true
            // A superset or circuit rests once its whole round is done, whichever set came last.
            let rest = next != nil ? content.restAfterDone(ref, defaultRest: store.settings.defaultRestSeconds) : nil
            restBeforeNext = Double(rest ?? 0)
            currentRef = next
            if !offPlan, !keepsCurrent, let next, let nextItem = content.item(at: next) {
                // Follow along unless the user is looking at another exercise.
                if focusedItemID == nil || focusedItemID == content.item(at: ref)?.id || adoptOffPlan {
                    focusedItemID = nextItem.id
                }
            }
            VoiceCoach.shared.moveOn(to: currentSet?.id)
            if offPlan, let item = content.item(at: ref), let set = content.set(at: ref) {
                noteOffPlan(item: item, set: set)
            } else if adoptOffPlan, let item = content.item(at: ref) {
                clearOffPlan()
                lastOffPlanItemID = nil
                VoiceCoach.shared.say("Following \(item.name).", cue: .offPlan, context: currentSet?.id)
            } else {
                clearOffPlan()
                lastOffPlanItemID = nil
            }
            celebrate(afterSetAt: ref)
            // The rest counts from when the set was really done (a late watch tick rested part of it).
            let resting = autoRest && rest.map { startRest($0, from: now) } == true
            if !resting && next != nil && !offPlan {
                if isFlow && CoachPrefs.autoStartHolds && currentItem?.mode == .time {
                    startSet()
                } else {
                    announceSetUp(isFirst: false)
                }
            }
            askForFeedbackIfUseful(afterSet: id)
            scheduleUndoExpiry()
            persist()
        } else {
            // Unticked (a mistaken tick): this set is due again, and what that tick started goes away.
            Haptics.tap()
            content.updateSet(id: id) { $0.startedAt = nil }
            let wasLastTick = id == lastCompletedSetID
            // The set that was due before the tick being undone (nil when it's gone or done since).
            var dueBefore: WorkoutContent.SetRef?
            if wasLastTick, let before = beforeLastTick, before.setID == id {
                cancelRest()
                VoiceCoach.shared.stop()
                pace = before.pace
                restBeforeNext = before.restBeforeNext
                bestWeights = before.best
                withAnimation(.snappy) {
                    celebration = nil
                    if effortRequest?.setID == id { effortRequest = nil }
                    offPlanNotice = nil
                }
                celebrationTask?.cancel()
                dueBefore = before.currentSetID.flatMap { content.locate(setID: $0) }.flatMap { content.set(at: $0)?.isDone == false ? $0 : nil }
                beforeLastTick = nil
                lastCompletedSetID = nil
            } else {
                pace.setUndone(previous: content.allItems.flatMap(\.sets).compactMap(\.doneAt).max())
            }
            undoableTick = nil
            if let dueBefore {
                // Undoing the last tick puts the plan back where it was: a mistaken off-plan tick
                // doesn't make that exercise the plan, and the set that was due is due again.
                currentRef = dueBefore
                focusedItemID = content.item(at: dueBefore)?.id
                lastOffPlanItemID = nil
            } else if let again = content.locate(setID: id) {
                // Only an unticked set of the planned thread (or the last tick) becomes current again.
                if wasLastTick || again.blockIndex == currentRef?.blockIndex || currentRef == nil {
                    currentRef = again
                    focusedItemID = content.item(at: again)?.id
                }
            }
            VoiceCoach.shared.moveOn(to: currentSet?.id)
            persist()
        }
    }

    /// Undo for the last tick (the "Undo" pill after a set is ticked).
    func undoLastTick() {
        guard let tick = undoableTick, content.set(id: tick.setID)?.isDone == true else { return }
        toggleSet(tick.setID)
    }

    @ObservationIgnored private var undoTask: Task<Void, Never>?

    private func scheduleUndoExpiry() {
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.undoableTick = nil }
        }
    }

    /// "Bench Press, set 2 of 4: 8 reps at 60 kilos." for the set that's due.
    private func announceSetUp(isFirst: Bool) {
        guard let item = currentItem, let set = currentSet else { return }
        VoiceCoach.shared.say(CoachScript.setUp(item: item, set: set, unit: unit, isFirst: isFirst), cue: .setUp, context: set.id)
    }

    // MARK: Coach

    /// Planned rest before the current set plus the time the set itself takes.
    func expectedGap() -> Double {
        guard let item = currentItem, let set = currentSet else { return restBeforeNext + 60 }
        return restBeforeNext + PaceTracker.workSeconds(for: set, mode: item.mode)
    }

    /// Seconds past the plan for the next set (0 while on time, resting or working).
    func overdueSeconds(at date: Date = Date()) -> Double {
        guard restEndsAt == nil, currentSet != nil else { return 0 }
        return pace.overdueSeconds(at: date, expectedGap: expectedGap())
    }

    /// Planned versus actual so far, and where the workout is heading.
    func paceSnapshot(at date: Date = Date()) -> PaceSnapshot {
        let remaining = remainingSeconds()
        var projected = elapsed(at: date) + remaining
        if let restEndsAt { projected += max(0, restEndsAt.timeIntervalSince(date)) }
        let waiting = phase == .ready ? pace.waitingDelta(at: date, plannedRest: restBeforeNext) : nil
        if let waiting, waiting > 0 { projected += waiting }
        return PaceSnapshot(
            plannedRest: restBeforeNext, waitingDelta: waiting, totalDelta: pace.totalDelta + max(0, waiting ?? 0),
            averageDelta: pace.averageDelta, lastGap: pace.lastGap, gaps: pace.gaps,
            plannedDuration: plannedDuration, projectedDuration: projected,
            tips: WorkoutPace.tips(for: pace, restRange: profileRestRange())
        )
    }

    /// Bumped by every save of the live content (and attach, merge, detach): `paceSnapshot` works the
    /// remaining time out once per change instead of twice a second (the coach bar's clock).
    @ObservationIgnored private var contentStamp = 0
    @ObservationIgnored private var remainingCache: (stamp: Int, defaultRest: Int, seconds: Double)?
    @ObservationIgnored private var restRangeCache: (key: String, range: ClosedRange<Int>)?

    private func remainingSeconds() -> Double {
        let defaultRest = store.settings.defaultRestSeconds
        if let cached = remainingCache, cached.stamp == contentStamp, cached.defaultRest == defaultRest { return cached.seconds }
        let seconds = WorkoutPace.remainingSeconds(in: content, defaultRest: defaultRest)
        remainingCache = (stamp: contentStamp, defaultRest: defaultRest, seconds: seconds)
        return seconds
    }

    /// The profile's rest range, kept until age, experience or goal change.
    private func profileRestRange() -> ClosedRange<Int> {
        let settings = store.settings
        let key = "\(store.birthYear)|\(settings.experienceRaw)|\(settings.goalRaw)"
        if let cached = restRangeCache, cached.key == key { return cached.range }
        let range = store.profile.restSeconds
        restRangeCache = (key: key, range: range)
        return range
    }

    func setIntensity(_ value: CoachIntensity) {
        intensity = value
        pace.slack = value.paceSlack
        AppLog.info("Coach intensity: \(value.rawValue)", category: "workout")
    }

    /// The energy check-in before the first set (nil = skipped).
    var needsEnergyCheckIn: Bool {
        guard let session, !LaunchOptions.current.isDemo, CoachPrefs.energyCheckIn else { return false }
        return session.energyBefore == 0 && content.completedSets == 0
    }

    func recordEnergy(_ level: Int?) {
        guard let session else { return }
        if let level {
            session.energyBefore = level
            // One check-in per workout: a second answer (or the watch delivering one twice) replaces it.
            let sessionID = session.id
            var isRepeat = false
            if let existing = store.fetchEnergy().last(where: { $0.source == "workout" && $0.sessionID == sessionID }) {
                isRepeat = existing.level == level
                existing.level = level
                existing.date = Date()
            } else {
                store.context.insert(EnergyCheckIn(level: level, source: "workout", sessionID: sessionID))
            }
            setIntensity(CoachIntensity.from(energy: level))
            if level <= 2 && !isRepeat {
                VoiceCoach.shared.say("Easy does it today. Every set counts.", cue: .motivation)
            }
        } else {
            session.energyBefore = -1
        }
        // No bump: Today and Energy don't need to recompute behind live mode (they do at Finish).
        store.save(bumping: false)
    }

    /// The answers of the quick card after an exercise: reps left (rep sets) and muscle fatigue.
    /// Both at once (watch, older call sites); the card itself saves each tap with `recordFatigue` /
    /// `recordReps`.
    func answerFeedback(repsInReserve rir: Int?, fatigue: Double?) {
        if let fatigue { recordFatigue(fatigue) }
        if let rir { recordReps(inReserve: rir) }
        if effortRequest != nil { closeFeedback() }
    }

    func answerEffort(repsInReserve rir: Int?) {
        answerFeedback(repsInReserve: rir, fatigue: nil)
    }

    /// Saved as soon as it's tapped – the card may time out afterwards without losing it.
    func recordFatigue(_ fatigue: Double) {
        guard var request = effortRequest else { return }
        edit { $0.updateItem(id: request.itemID) { $0.fatigue = fatigue } }
        AppLog.info("Fatigue logged: \(Int(fatigue * 100)) %", category: "workout")
        request.fatigue = fatigue
        Haptics.tap()
        if request.asksReps && request.repsInReserve == nil {
            withAnimation(.snappy) { effortRequest = request }
            restartFeedbackTimeout()
        } else {
            closeFeedback()
        }
    }

    func recordReps(inReserve rir: Int) {
        guard var request = effortRequest else { return }
        // The answer belongs to the last working set, not to a drop set that followed it (a drop set
        // is all-out by design and would make the progression say "go lighter").
        let target = content.item(id: request.itemID).flatMap { EffortPrompt.target(in: $0)?.id } ?? request.setID
        updateSet(target) { $0.rpe = EffortPrompt.rpe(forRepsInReserve: rir) }
        AppLog.info("Effort logged: \(rir) reps in reserve", category: "workout")
        request.repsInReserve = rir
        Haptics.tap()
        if request.asksFatigue && request.fatigue == nil {
            withAnimation(.snappy) { effortRequest = request }
            restartFeedbackTimeout()
        } else {
            closeFeedback()
        }
    }

    func closeFeedback() {
        effortTask?.cancel()
        withAnimation(.snappy) { effortRequest = nil }
        syncLive()
    }

    /// "Not in this workout" on the card.
    func skipFeedbackForThisWorkout() {
        skipFeedbackThisWorkout = true
        closeFeedback()
    }

    /// "Stop asking": both questions off in Settings.
    func stopAskingFeedback() {
        UserDefaults.standard.set(false, forKey: Prefs.askFatigue)
        UserDefaults.standard.set(false, forKey: Prefs.askEffort)
        closeFeedback()
    }

    private func restartFeedbackTimeout() {
        effortTask?.cancel()
        effortTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            self?.closeFeedback()
        }
    }

    private func askForFeedbackIfUseful(afterSet id: UUID) {
        guard !skipFeedbackThisWorkout, let session,
              let ref = content.locate(setID: id), let item = content.item(at: ref), let set = content.set(at: ref),
              item.isComplete, item.sets.last?.id == set.id || item.sets.allSatisfy(\.isDone) else { return }
        // Holds in a stretch/yoga/mobility flow and cardio don't tire muscles in a way worth asking about.
        let kind = item.kind ?? session.kind
        let calmKind = kind.isFlow || kind == .cardio
        let asksReps = !calmKind && CoachPrefs.askEffort && EffortPrompt.shouldAsk(after: set, in: item, askedSoFar: effortAsked, limit: 99)
        let asksFatigue = !calmKind && CoachPrefs.askFatigue && set.kind != .warmup
        guard asksReps || asksFatigue else { return }
        if asksReps { effortAsked += 1 }
        let muscles = analyticsMuscles(item)
        withAnimation(.snappy) {
            effortRequest = EffortRequest(setID: id, itemID: item.id, itemName: item.name, muscles: muscles, asksReps: asksReps, asksFatigue: asksFatigue)
        }
        restartFeedbackTimeout()
    }

    private func analyticsMuscles(_ item: WorkoutItem) -> String {
        let names = item.muscles.isEmpty ? library.muscles(for: item) : item.muscles
        return names.prefix(2).joined(separator: ", ")
    }

    private func celebrate(afterSetAt ref: WorkoutContent.SetRef) {
        guard let item = content.item(at: ref), let set = content.set(at: ref) else { return }
        let style = CoachPrefs.motivation
        var moment: Celebration?
        if isFlow {
            // A calm flow: only the end gets a word.
            if content.isComplete {
                moment = Celebration(kind: .allDone, title: "All done", subtitle: "Finish when you're ready", symbol: "flag.checkered")
                VoiceCoach.shared.say("That's the whole routine. Well done.", cue: .summary, priority: .high)
            }
            guard let moment, style != .off else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { celebration = moment }
            celebrationTask?.cancel()
            celebrationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { self?.celebration = nil }
            }
            return
        }
        if let weight = set.effectiveWeight, weight > 0, set.kind != .warmup,
           let best = currentBestWeights()[item.exerciseKey], weight > best {
            bestWeights?[item.exerciseKey] = weight
            moment = Celebration(kind: .record, title: "New best: \(Format.weight(weight, unit: unit))",
                                 subtitle: item.name, symbol: "trophy.fill")
            VoiceCoach.shared.say("New personal best! \(Format.number(unit.fromKilograms(weight))) \(unit == .kg ? "kilos" : "pounds").", cue: .records, priority: .high)
            Haptics.heavy()
        } else if content.isComplete {
            moment = Celebration(kind: .allDone, title: "All sets done", subtitle: "Finish when you're ready", symbol: "flag.checkered")
            VoiceCoach.shared.say("That's every set. Great work – finish when you're ready.", cue: .summary, priority: .high)
        } else if item.isComplete {
            let volume = item.sets.filter(\.isDone).reduce(0.0) { $0 + Double($1.effectiveReps ?? 0) * ($1.effectiveWeight ?? 0) }
            let detail = volume > 0 ? "\(item.completedSets) sets · \(Format.volume(volume, unit: unit))" : "\(item.completedSets) sets"
            moment = Celebration(kind: .exercise, title: "\(item.name) done", subtitle: detail, symbol: "checkmark.seal.fill")
            VoiceCoach.shared.say(CoachScript.exerciseDone(item), cue: .exerciseDone)
        } else if !halfwayAnnounced, content.completedSets * 2 >= max(1, content.totalSets), content.totalSets >= 6 {
            halfwayAnnounced = true
            moment = Celebration(kind: .halfway, title: "Halfway there", subtitle: "\(content.completedSets) of \(content.totalSets) sets", symbol: "flame.fill")
            VoiceCoach.shared.say("Halfway there.", cue: .progress)
        } else if let cheer = CoachScript.cheer(streak: pace.onTimeStreak, seed: completionPulse) {
            VoiceCoach.shared.say(cheer, cue: .motivation, priority: .low)
        }
        guard let moment, style != .off else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { celebration = moment }
        celebrationTask?.cancel()
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.celebration = nil }
        }
    }

    /// While waiting for a set: a word when you're clearly over the planned rest – with the number,
    /// not just "keep it up". At most twice per break, never on calm days.
    private func startNudges() {
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkNudge()
            }
        }
    }

    private func checkNudge() {
        guard session != nil, !isPaused, !isFlow, phase == .ready, CoachPrefs.paceNudges, intensity != .calm,
              let set = currentSet, let over = pace.waitingDelta(at: Date(), plannedRest: restBeforeNext) else { return }
        if nudgesGiven == 0, over > pace.slack {
            nudgesGiven = 1
            Haptics.warning()
            VoiceCoach.shared.say(CoachScript.overRest(seconds: over), cue: .pace, context: set.id)
        } else if nudgesGiven == 1, over > pace.slack + 90 {
            nudgesGiven = 2
            Haptics.warning()
            VoiceCoach.shared.say(CoachScript.overRest(seconds: over), cue: .pace, context: set.id)
        }
    }

    func completeCurrentSet() {
        if let set = currentSet, !set.isDone {
            toggleSet(set.id)
        } else if let ref = content.nextPendingSet(), let set = content.set(at: ref) {
            toggleSet(set.id)
        }
    }

    /// The main button: Start when the set is waiting (and the Start button is on), otherwise Done.
    /// A hold always starts its timer first – a hold can't be "done" without being held.
    func primaryAction() {
        flushPersist()
        // Paused: the main button (▶, Space, Lock Screen, Siri, watch) carries on – it never logs a set.
        if isPaused {
            resume()
            return
        }
        let isHold = currentItem?.mode == .time
        if phase != .working, currentSet != nil, CoachPrefs.startButton || isHold {
            startSet()
        } else {
            completeCurrentSet()
        }
    }

    /// What the main button does right now (for its icon and label).
    var primaryIsStart: Bool {
        phase != .working && currentSet != nil && (CoachPrefs.startButton || currentItem?.mode == .time)
    }

    /// Screenshots (`-DemoScreen live-mid` / `live-superset`): tick a few sets so momentum and the
    /// body figure show, without a rest timer or banner in the way.
    func demoProgress(sets: Int, focusSuperset: Bool, keepFeedback: Bool = false) {
        for _ in 0..<sets { completeCurrentSet() }
        skipRest()
        celebrationTask?.cancel()
        celebration = nil
        if !keepFeedback { effortRequest = nil }
        // Believable breaks for the pace panel: one a bit late, one on time, now waiting too long.
        var demo = PaceTracker(slack: pace.slack)
        let base = Date().addingTimeInterval(-560)
        demo.setCompleted(at: base, plannedRest: nil, workSeconds: 40)
        demo.setStarted(at: base.addingTimeInterval(150), plannedRest: 120)
        demo.setCompleted(at: base.addingTimeInterval(190), plannedRest: 120, workSeconds: 40)
        demo.setStarted(at: base.addingTimeInterval(305), plannedRest: 120)
        demo.setCompleted(at: base.addingTimeInterval(345), plannedRest: 120, workSeconds: 40)
        pace = demo
        restBeforeNext = 120
        if focusSuperset, let block = content.blocks.first(where: { $0.items.count > 1 }),
           let first = block.items.first, let last = block.items.last {
            // One extra set on the last exercise, so the screenshot shows "Match sets".
            edit { $0.addSet(to: last.id) }
            focus(itemID: first.id)
        }
    }

    /// A value edit (keypad, steppers): saved after a short pause in typing, so typing "62.5"
    /// doesn't save, sync and recompute four times.
    func updateSet(_ id: UUID, _ body: (inout WorkoutSet) -> Void) {
        guard !isFinishing else { return }
        content.updateSet(id: id, body)
        persist(debounced: true)
    }

    /// Any structural change made mid-workout (add/remove/swap exercises, add sets, reorder). The
    /// current set is kept by id – an edit elsewhere never moves "now" to something else.
    func edit(_ body: (inout WorkoutContent) -> Void) {
        guard !isFinishing else { return }
        let currentID = currentSet?.id
        let anchorID = currentRef.flatMap { content.setBefore($0) }.flatMap { content.set(at: $0)?.id }
        body(&content)
        content.normalizeBlocks()
        let resolved = content.resolveCurrent(currentID: currentID, anchorID: anchorID)
        let changed = resolved.flatMap { content.set(at: $0)?.id } != currentID
        currentRef = resolved
        if changed {
            timedSetTask?.cancel()
            timedSetEndsAt = nil
            timedSide = nil
            // The new current set hasn't been started (a hold must not look "working" without its timer).
            pace.setUndone(previous: pace.lastSetAt)
            VoiceCoach.shared.moveOn(to: currentSet?.id)
        }
        if let focusedItemID, content.item(id: focusedItemID) == nil {
            self.focusedItemID = currentItem?.id
        }
        plannedDuration = WorkoutPace.plannedSeconds(of: content, defaultRest: store.settings.defaultRestSeconds)
        persist()
    }

    /// Replace the whole content (the full editor, the set editor – their bindings call this on every
    /// keystroke). Typed values (same sets, same ticks) are saved after a pause in typing, like the
    /// keypad; anything structural goes through `edit`, which keeps "now" by id.
    func replaceContent(_ newContent: WorkoutContent) {
        guard !isFinishing, newContent != content else { return }
        if content.hasSameSetsAndTicks(as: newContent) {
            content = newContent
            persist(debounced: true)
        } else {
            edit { $0 = newContent }
        }
    }

    /// Just looking: shows another exercise without touching the plan (swiping, the strip).
    func view(itemID: UUID) {
        guard focusedItemID != itemID else { return }
        focusedItemID = itemID
    }

    /// Looking at another exercise (or superset) than the one that's due.
    var isViewingElsewhere: Bool {
        guard let current = currentRef, let viewed = focusedItem, let loc = content.locate(itemID: viewed.id) else { return false }
        return loc.block != current.blockIndex
    }

    /// Back to the exercise that's due.
    func returnToCurrent() {
        guard let item = currentItem else { return }
        withAnimation(.snappy) { focusedItemID = item.id }
        Haptics.tap()
    }

    /// Where an exercise sits relative to the plan: done, due now, still open from earlier, later.
    enum PlanPosition { case done, now, skipped, later }

    func planPosition(of item: WorkoutItem) -> PlanPosition {
        if item.isComplete { return .done }
        guard let current = currentRef, let loc = content.locate(itemID: item.id) else { return .later }
        if loc.block == current.blockIndex { return .now }
        return loc.block < current.blockIndex ? .skipped : .later
    }

    /// Changes the plan's thread on purpose: this exercise's first open set is due now.
    func focus(itemID: UUID) {
        guard focusedItemID != itemID || currentItem?.id != itemID else { return }
        focusedItemID = itemID
        if let loc = content.locate(itemID: itemID) {
            let item = content.blocks[loc.block].items[loc.item]
            if let s = item.sets.firstIndex(where: { !$0.isDone }) {
                let ref = WorkoutContent.SetRef(blockIndex: loc.block, itemIndex: loc.item, setIndex: s)
                if ref != currentRef {
                    currentRef = ref
                    timedSetTask?.cancel()
                    timedSetEndsAt = nil
                    pace.setUndone(previous: pace.lastSetAt)
                    VoiceCoach.shared.moveOn(to: currentSet?.id)
                }
            }
        }
        refreshRestNotification()
        syncLive()
    }

    /// Panel → Back / Skip: moves the plan to the previous or next exercise that still has open sets
    /// (open sets stay open for later) and says so.
    func moveThread(by offset: Int) {
        let blocks = content.blocks
        guard let current = currentRef else { return }
        var target = current.blockIndex + offset
        while blocks.indices.contains(target), blocks[target].items.allSatisfy(\.isComplete) { target += offset }
        guard blocks.indices.contains(target), target != current.blockIndex,
              let item = blocks[target].items.first(where: { !$0.isComplete }) else { return }
        let leaving = currentItem
        withAnimation(.snappy) { focus(itemID: item.id) }
        clearOffPlan()
        lastOffPlanItemID = nil
        Haptics.tap()
        if let leaving, !leaving.isComplete {
            VoiceCoach.shared.say("\(offset > 0 ? "Skipping" : "Back") to \(item.name). \(leaving.name) stays open for later.", cue: .offPlan, context: currentSet?.id)
        }
        announceSetUp(isFirst: false)
    }

    /// Previous / next exercise from the panel (kept for older call sites).
    func focusExercise(offset: Int) { moveThread(by: offset) }

    // MARK: Changing things mid-set

    /// "I can't finish this set": it counts with the reps you managed, a drop set with the lighter
    /// weight starts right away (no rest), optionally with the lighter weight for the remaining sets.
    /// `setID`: the set the sheet (or the watch) was opened for – it becomes the current one first; an
    /// already logged set is left alone. Nil: the current set.
    func dropWeight(setID: UUID? = nil, repsDone: Int, newWeightKg: Double, applyToRemaining: Bool) {
        if let setID, setID != currentSet?.id {
            guard content.set(id: setID)?.isDone == false else { return }
            makeCurrent(setID: setID)
        }
        guard let item = currentItem, let set = currentSet, !set.isDone, setID == nil || set.id == setID else { return }
        if isPaused { resume() }
        let now = Date()
        var updated = content
        guard let dropID = updated.dropWeight(setID: set.id, repsDone: repsDone, newWeightKg: newWeightKg, applyToRemaining: applyToRemaining, at: now) else { return }
        content = updated
        let work = PaceTracker.workSeconds(for: set, mode: item.mode)
        pace.setCompleted(at: now, plannedRest: pace.lastSetAt == nil ? nil : restBeforeNext, workSeconds: work)
        restBeforeNext = 0
        cancelRest()
        timedSetTask?.cancel()
        timedSetEndsAt = nil
        lastCompletedSetID = set.id
        currentRef = content.locate(setID: dropID)
        pace.setStarted(at: now, plannedRest: 0)
        content.updateSet(id: dropID) { $0.startedAt = now }
        completionPulse += 1
        clearOffPlan()
        Haptics.heavy()
        VoiceCoach.shared.moveOn(to: dropID)
        VoiceCoach.shared.say("Down to \(Format.number(unit.fromKilograms(newWeightKg))) \(unit == .kg ? "kilos" : "pounds"). Keep going.",
                              cue: .setUp, context: dropID, priority: .high)
        AppLog.info("Dropped weight mid-set (\(repsDone) reps done)", category: "workout")
        persist()
    }

    /// "Not available": the open sets go to `replacement` (done sets stay with the old exercise).
    func swapExercise(itemID: UUID, with replacement: WorkoutItem) {
        let wasCurrent = currentItem?.id == itemID
        var newID: UUID?
        edit { newID = $0.swapRemaining(itemID: itemID, with: replacement) }
        guard let newID, let item = content.item(id: newID) else { return }
        if wasCurrent || currentRef == nil {
            if let loc = content.locate(itemID: newID), let s = item.sets.firstIndex(where: { !$0.isDone }) {
                currentRef = WorkoutContent.SetRef(blockIndex: loc.block, itemIndex: loc.item, setIndex: s)
            }
            timedSetTask?.cancel()
            timedSetEndsAt = nil
            pace.setUndone(previous: pace.lastSetAt)
        }
        focusedItemID = newID
        Haptics.success()
        VoiceCoach.shared.moveOn(to: currentSet?.id)
        VoiceCoach.shared.say("Swapped to \(item.name).", cue: .setUp, context: currentSet?.id)
        AppLog.info("Swapped an exercise mid-workout", category: "workout")
        let pictures = library.imageURLs(for: item)
        Task.detached(priority: .utility) { await ImageCache.shared.prefetch(pictures) }
        refreshRestNotification()
        persist()
    }

    // MARK: Off plan

    private func noteOffPlan(item: WorkoutItem, set: WorkoutSet) {
        lastOffPlanItemID = item.id
        let planned = currentItem
        let notice = OffPlanNotice(
            itemID: item.id, itemName: item.name, setText: set.label(mode: item.mode, unit: unit),
            plannedName: planned?.name, plannedSetText: currentSet.map { s in planned.map { CoachScript.setPosition(s, in: $0) } ?? "" }
        )
        withAnimation(.snappy) { offPlanNotice = notice }
        Haptics.warning()
        var line = "Off plan: \(item.name)."
        if let planned { line += " Next on plan: \(planned.name)." }
        VoiceCoach.shared.say(line, cue: .offPlan, context: currentSet?.id)
        AppLog.info("Set done off plan (\(item.name))", category: "workout")
        offPlanTask?.cancel()
        offPlanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.offPlanNotice = nil }
        }
    }

    private func clearOffPlan() {
        offPlanTask?.cancel()
        if offPlanNotice != nil { withAnimation(.snappy) { offPlanNotice = nil } }
    }

    /// "Stay on plan": the banner goes, the plan's next set stays due.
    func stayOnPlan() {
        clearOffPlan()
        lastOffPlanItemID = nil
        returnToCurrent()
    }

    /// "Continue here": the exercise done off plan becomes the plan's thread.
    func continueOffPlan() {
        guard let notice = offPlanNotice else { return }
        clearOffPlan()
        if let item = content.item(id: notice.itemID), !item.isComplete {
            withAnimation(.snappy) { focus(itemID: item.id) }
            announceSetUp(isFirst: false)
        }
        Haptics.success()
    }

    /// The voice is muted for this workout (speaker button / menu).
    private(set) var isVoiceMuted = false

    func toggleVoiceMute() {
        isVoiceMuted.toggle()
        VoiceCoach.shared.isMuted = isVoiceMuted
        Haptics.tap()
        syncLive()
    }

    /// Jumps the current set to a specific set (tap on an open set in live mode).
    func makeCurrent(setID: UUID) {
        guard let ref = content.locate(setID: setID), content.set(at: ref)?.isDone == false, ref != currentRef else { return }
        currentRef = ref
        focusedItemID = content.item(at: ref)?.id
        timedSetTask?.cancel()
        timedSetEndsAt = nil
        pace.setUndone(previous: pace.lastSetAt)
        VoiceCoach.shared.moveOn(to: setID)
        refreshRestNotification()
        syncLive()
    }

    /// Saves the live content. Never on the undo stack, no revision bump (dashboards refresh at
    /// start/finish). `debounced` waits for a pause in typing.
    private func persist(debounced: Bool = false) {
        guard let session else { return }
        // The content changed (every live edit ends here): the coach bar's remaining time is worked out again.
        contentStamp &+= 1
        if debounced {
            persistTask?.cancel()
            persistTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                self?.persist()
            }
            syncLiveThrottled()
            return
        }
        persistTask?.cancel()
        persistTask = nil
        // Continued on another device: nothing more is saved from here (it lets go instead).
        guard confirmOwnership() else { return }
        // Someone else saved it in between: their sets are merged in, not written over.
        mergeOutsideChanges()
        let content = content
        store.saveWithoutUndo { session.content = content }
        lastSeenData = session.contentData
        // A weight or exercise changed during the rest: the "Rest is over" notification says the new one.
        refreshRestNotification()
        // Where the workout stands is written with the live sync (once per turn, also when a rest
        // started with the same tick).
        syncLive()
    }

    /// Saves a pending value edit now (before ticks, starts, finishing, leaving the app).
    func flushPersist() {
        guard persistTask != nil else { return }
        persist()
    }

    /// Leaving the app: a value typed a moment ago and where the workout stands (rest, plan's
    /// place, pause) are written now, so a relaunch continues exactly there.
    func saveState() {
        flushPersist()
        saveResume()
    }

    /// Where the workout stands, so a relaunch picks up the rest, the started set and the plan's place.
    private func saveResume() {
        guard let session else { return }
        LiveResume(
            currentSetID: currentSet?.id, focusedItemID: focusedItemID, restEndsAt: restEndsAt, restTotal: restTotal,
            restBeforeNext: restBeforeNext, nudgesGiven: nudgesGiven, isPaused: isPaused,
            pausedRestRemaining: pausedRest?.remaining, pausedAt: pausedAt,
            pausedTimedRemaining: pausedTimed?.remaining, pausedTimedSetID: pausedTimed?.setID,
            timedSetEndsAt: timedSetEndsAt,
            pauses: pauseLog.isEmpty ? nil : pauseLog,
            watchExpected: watchExpected, watchRecording: watchIsRecording,
            watchStoppedAt: watchStoppedAt, watchWorkoutID: watchWorkoutID
        ).save(for: session.id)
    }

    // MARK: Rest

    /// A rest of `seconds` from `start` (now by default). One that is already over by now isn't
    /// started. Returns whether a rest runs.
    @discardableResult
    func startRest(_ seconds: Int, from start: Date? = nil) -> Bool {
        guard seconds > 0 else { return false }
        let end = (start ?? Date()).addingTimeInterval(Double(seconds))
        guard start == nil || end > Date().addingTimeInterval(1) else { return false }
        restTotal = seconds
        restEndsAt = end
        scheduleRestTask()
        scheduleRestNotification()
        // Saves where the workout stands too; with the tick's own save that's one message per tick.
        syncLive()
        let next = currentItem.flatMap { item in currentSet.map { (item: item, set: $0) } }
        if isFlow, let next {
            // Calm flow: just what's next.
            let hold = next.set.targetSeconds.map { ", \(CoachScript.duration($0))" } ?? ""
            VoiceCoach.shared.say("Next: \(next.item.name)\(hold).", cue: .restStart, context: currentSet?.id)
            return true
        }
        let same = next?.item.id == lastCompletedItemID
        let left = min(seconds, Int(end.timeIntervalSinceNow.rounded()))
        VoiceCoach.shared.say(CoachScript.restStart(seconds: left, next: next, sameExercise: same), cue: .restStart, context: currentSet?.id)
        return true
    }

    func addRest(_ seconds: Int) {
        // Paused: no rest runs until Resume – the one waiting for it gets longer (none starts).
        if isPaused {
            guard let rest = pausedRest else { return }
            pausedRest = (remaining: max(0, rest.remaining + Double(seconds)), total: max(0, rest.total + seconds))
            saveResume()
            syncLive()
            return
        }
        guard let restEndsAt else {
            startRest(seconds)
            return
        }
        self.restEndsAt = restEndsAt.addingTimeInterval(Double(seconds))
        restTotal += seconds
        scheduleRestTask()
        scheduleRestNotification()
        // Saves where the workout stands too (once per turn).
        syncLive()
    }

    /// Ends the rest now (the set becomes due). Paused: the rest waiting for Resume goes.
    func skipRest() {
        if pausedRest != nil {
            pausedRest = nil
            saveResume()
        }
        cancelRest()
        syncLive()
    }

    /// A rest stopped by Pause, carried on by Resume.
    var hasPausedRest: Bool { pausedRest != nil }

    private func cancelRest() {
        restTask?.cancel()
        restWarningTask?.cancel()
        restNotificationTask?.cancel()
        restNotificationTask = nil
        restEndsAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["george.rest"])
    }

    private func scheduleRestTask() {
        restTask?.cancel()
        restWarningTask?.cancel()
        guard let end = restEndsAt else { return }
        let setID = currentSet?.id
        restWarningTask = Task { [weak self] in
            if end.timeIntervalSinceNow > 15 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, end.timeIntervalSinceNow - 10) * 1_000_000_000))
                guard !Task.isCancelled, self?.restEndsAt == end else { return }
                // Woken late (the app was suspended): "10 seconds" would be a lie now.
                if end.timeIntervalSinceNow > 5 {
                    Haptics.tap()
                    VoiceCoach.shared.say("10 seconds.", cue: .countdown, context: setID)
                }
            }
            if end.timeIntervalSinceNow > 4, self?.restEndsAt != nil {
                await self?.countdown(to: end, setID: setID)
            }
        }
        restTask = Task { [weak self] in
            let delay = end.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.restFinished()
        }
    }

    /// "3" – "2" – "1", one per second before `end` (a tap on each), instead of one rushed phrase.
    private func countdown(to end: Date, setID: UUID?) async {
        for number in [3, 2, 1] {
            let at = end.addingTimeInterval(-Double(number))
            let delay = at.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            guard delay > -0.5 else { continue } // already past this second
            Haptics.tap()
            VoiceCoach.shared.say(["", "One", "Two", "Three"][number], cue: .countdown, context: setID, priority: .high)
        }
    }

    private func restFinished() {
        guard let end = restEndsAt else { return }
        restEndsAt = nil
        restNotificationTask = nil
        // Woken more than a few seconds late (suspended): the notification already said "Go".
        let late = Date().timeIntervalSince(end) > 3
        if !late {
            Haptics.heavy()
            #if os(iOS)
            if CoachPrefs.sounds && !(CoachPrefs.voice && VoiceSettings.isOn(.go)) {
                AudioServicesPlaySystemSound(1007)
            }
            #endif
            let next = currentItem.flatMap { item in currentSet.map { (item: item, set: $0) } }
            VoiceCoach.shared.say(CoachScript.go(next: next, unit: unit), cue: .go, context: currentSet?.id, priority: .high)
        }
        if isFlow, CoachPrefs.autoStartHolds, currentItem?.mode == .time, currentSet?.isDone == false {
            startSet()
        }
        // Saves where the workout stands too (once per turn, also with the hold `startSet` began).
        syncLive()
    }

    private func scheduleRestNotification() {
        guard let restEndsAt else { return }
        let center = UNUserNotificationCenter.current()
        restNotificationTask?.cancel()
        center.removePendingNotificationRequests(withIdentifiers: ["george.rest"])
        let delay = restEndsAt.timeIntervalSinceNow
        guard delay > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest is over"
        let next = currentItem.flatMap { item in currentSet.map { (item: item, set: $0) } }
        content.body = restNotificationBody()
        restNotificationKey = restNotificationBody()
        content.sound = .default
        let goLine = CoachScript.go(next: next, unit: unit)
        let end = restEndsAt
        restNotificationTask = Task { [weak self] in
            // Spoken "Go!" as the notification sound – heard even when the phone is locked.
            if let sound = await VoiceCoach.shared.notificationSound(for: goLine) {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
            }
            // Skipped, finished or moved while the sound was being made: no stale alert.
            guard !Task.isCancelled, self?.restEndsAt == end else { return }
            let remaining = end.timeIntervalSinceNow
            guard remaining > 0.5 else { return }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "george.rest", content: content, trigger: trigger))
        }
    }

    /// "Now: Bench Press · 8 × 60 kg" – the set that's due, for the "Rest is over" notification.
    private func restNotificationBody() -> String {
        guard let item = currentItem, let set = currentSet else { return "Time for the next set." }
        return "Now: \(item.name) · \(set.label(mode: item.mode, unit: unit))"
    }

    /// A running rest's notification is rebuilt when the set it names changed (a swap, a jump to
    /// another set, warm-ups added, a weight changed during the rest).
    private func refreshRestNotification() {
        guard restEndsAt != nil, restNotificationKey != restNotificationBody() else { return }
        scheduleRestNotification()
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Finish

    /// Ends the workout, estimates energy, saves to Apple Health and returns a summary. `endedAt`: when
    /// it ended – chosen on the finish sheet (`endIsChosen`), or the watch's Finish tap; nil is now. A
    /// strength workout left running for hours ends at its last set instead (`FinishTime.resolvedEnd`).
    func finish(effort: Int, notes: String?, endedAt: Date? = nil, endIsChosen: Bool = false, showSummary: Bool = true) async {
        guard let session, !isFinishing else { return }
        // Continued on another device: it is finished there, not ended from this stale copy.
        guard confirmOwnership() else { return }
        AppLog.info("Workout finished (\(content.completedSets)/\(content.totalSets) sets)", category: "workout")
        isFinishing = true
        defer { isFinishing = false }
        flushPersist()
        // Sets saved to it elsewhere in the meantime are part of what's saved now.
        mergeOutsideChanges()
        cancelRest()
        timedSetTask?.cancel()
        // The history before this workout, from the shared index (usually ready), taken before anything
        // is saved: new records and "compared with last time" below don't decode the whole log again.
        let history = SessionHistory.shared.records(store)
        let now = Date()
        // When it really ended (not the next morning for a workout left running) and its active time
        // until then – the time, the calories, the stats and Apple Health all use it.
        let end = finishEnd(requested: endedAt, chosen: endIsChosen, now: now)
        // Continued after "stopped early": the part(s) saved before, read before the session changes.
        let earlierPart = continuedEarlierPart()
        session.accumulatedSeconds = activeSeconds(until: end)
        session.resumedAt = nil
        session.endedAt = end
        session.content = content
        // A workout without sets (tennis, a run, "just track time") is complete when it's finished.
        session.status = content.isComplete || content.totalSets == 0 ? .completed : .partial
        // No rating (0, the watch's "Save without rating"): a rating the workout already had stays.
        if effort > 0 { session.effort = effort }
        if let notes, !notes.isEmpty {
            session.notes = session.notes.isEmpty ? notes : session.notes + "\n" + notes
        }
        let settings = store.settings
        let bodyMass = health.latestBodyMassKg ?? settings.bodyMassKg
        let estimateEffort = FinishRating.forEstimate(effort, kind: session.kind)
        let estimated = EnergyEstimator.kilocalories(kind: session.kind, durationSeconds: session.accumulatedSeconds, bodyMassKg: bodyMass, effort: estimateEffort)
        session.energyKcal = estimated
        var averageHeartRate = watchAverageHeartRate
        var measuredEnergy = watchEnergy
        // A first guess (the watch's numbers came, or it saved already) – settled below.
        session.recordedOnWatch = watchIsRecording || watchWorkoutID != nil
        // Saved now, counted once below (one bump when Finish is done, not one around each wait).
        store.save(bumping: false)

        let finishedID = session.id
        let start = session.startedAt ?? end.addingTimeInterval(-session.accumulatedSeconds)
        var savedToHealth = false
        var healthNote: String?
        let canSaveToHealth = settings.saveToHealth && health.isAvailable
        // A watch asked to record that hasn't been heard from yet (a relaunch, it only just started)
        // gets a moment to say so – the iPhone saving as well would count the workout twice.
        if canSaveToHealth, HealthLink.waitsForWatch(expected: watchExpected, watchHeard: watchIsRecording, watchWorkoutID: watchWorkoutID,
                                                     watchStoppedAt: watchStoppedAt, reachable: watch.isReachable) {
            await waitForWatch()
            // Its numbers came while Finish waited (they reach the running workout, not the late link).
            averageHeartRate = watchAverageHeartRate
            measuredEnergy = watchEnergy
        }
        let recordedOnWatch = HealthLink.watchSaves(watchHeard: watchIsRecording, watchWorkoutID: watchWorkoutID, watchStoppedAt: watchStoppedAt)
        session.recordedOnWatch = recordedOnWatch || watchWorkoutID != nil
        // Continued after "stopped early": only the part since continuing is new (the first is in
        // Health, and its numbers are kept here already).
        let continued = discardKeepsSavedPart ? preStart : nil
        // Heart rate and calories measured for this part, kept below. Apple Health's heart rate of a
        // continued workout is read for the part since continuing only (also when taken over here).
        var partNumbers: MeasuredNumbers?
        let partSeconds = max(0, session.accumulatedSeconds - (earlierPart?.seconds ?? 0))
        let partStart = earlierPart.map {
            MeasuredNumbers.partStart(continuedAt: $0.continuedAt, earlierEndedAt: $0.endedAt, partSeconds: partSeconds, end: end)
        } ?? start
        if recordedOnWatch {
            // The watch saves the HKWorkout (with heart rate); effort is attached when its id arrives
            // (kept on the device until then), or now when it came while Finish waited.
            pendingHealthSessionID = finishedID
            pendingEffort = effort
            if let watchWorkoutID {
                Task { [health] in await health.relateEffort(effort, toWorkoutWithID: watchWorkoutID) }
            } else {
                LiveResume.addPendingHealthLink(PendingHealthLink(sessionID: finishedID, effort: effort, finishedAt: end))
            }
            savedToHealth = true
            // The watch's numbers are running totals until now (or its Finish tap). A workout that ended
            // clearly earlier (left running, ended at its last set) gets the heart rate of its own time
            // from Apple Health, and George's calorie estimate.
            if !MeasuredNumbers.watchTotalsFit(workoutEnd: end, countedUntil: (endIsChosen ? nil : endedAt) ?? now) {
                let hr = await health.heartRate(from: partStart, to: end)
                averageHeartRate = hr?.average
                measuredEnergy = nil
                partNumbers = MeasuredNumbers(averageHeartRate: hr?.average, maxHeartRate: hr?.max)
            } else {
                partNumbers = MeasuredNumbers(averageHeartRate: averageHeartRate, activeEnergy: measuredEnergy)
            }
        } else if canSaveToHealth {
            // The watch stopped recording on the way: its part is in Apple Health already.
            if let watchWorkoutID {
                Task { [health] in await health.relateEffort(effort, toWorkoutWithID: watchWorkoutID) }
                savedToHealth = true
            }
            if let hr = await health.heartRate(from: partStart, to: end) {
                averageHeartRate = hr.average
                partNumbers = MeasuredNumbers(averageHeartRate: hr.average, maxHeartRate: hr.max)
            }
            // Continued: only the part since continuing (also when taken over here, without the time
            // it was continued: from `partStart`) – the first part is in Apple Health already.
            if let span = FinishTime.healthSpan(start: start, end: end, activeSeconds: session.accumulatedSeconds,
                                                continuedAt: continued?.segmentStartedAt ?? (earlierPart == nil ? nil : partStart),
                                                activeBeforeContinuing: continued?.accumulatedSeconds ?? earlierPart?.seconds ?? 0,
                                                watchStoppedAt: watchWorkoutID == nil ? nil : watchStoppedAt, pauses: pauseLog) {
                let done = content.allItems.filter { $0.completedSets > 0 }
                let request = HealthKitManager.SaveRequest(
                    sessionID: finishedID, title: session.title, kind: session.kind, start: span.start, end: span.end,
                    activeSeconds: span.activeSeconds,
                    energyKcal: EnergyEstimator.kilocalories(kind: session.kind, durationSeconds: span.activeSeconds, bodyMassKg: bodyMass, effort: estimateEffort),
                    effort: effort,
                    exercises: done.map(\.name),
                    muscles: Array(Set(done.flatMap { library.muscles(for: $0) })).sorted(),
                    completedSets: content.completedSets, volumeKg: content.volumeKg,
                    pauses: span.pauses
                )
                if let workoutID = await health.saveWorkout(request) {
                    // A continued workout keeps the link of its first part, a watch's part stays linked.
                    if session.healthWorkoutID == nil { session.healthWorkoutID = workoutID.uuidString }
                    savedToHealth = true
                    if watchWorkoutID != nil {
                        healthNote = "Watch stopped recording · the rest was saved from iPhone"
                    } else if watchExpected || watch.isPaired {
                        // Saved without hearing from the watch: should its own workout turn up after
                        // all, this one goes (`receive(_:)`).
                        LiveResume.addPendingHealthLink(PendingHealthLink(sessionID: finishedID, effort: effort, finishedAt: end, phoneWorkoutID: workoutID))
                    }
                }
            }
        }
        if !recordedOnWatch { measuredEnergy = nil }
        if let earlierPart {
            // Continued: the whole workout's numbers, never one part's as the whole (calories added and
            // heart rate weighted by time when both parts were measured, else the estimate and no
            // heart rate). The first part's are kept on the device for the watch's late numbers.
            let kept = EarlierPartNumbers(sessionID: finishedID, numbers: storedNumbers(of: finishedID, endedAt: earlierPart.endedAt),
                                          seconds: earlierPart.seconds,
                                          partSeconds: partSeconds, partBegan: earlierPart.continuedAt ?? earlierPart.endedAt, finishedAt: end)
            LiveResume.keepEarlierPart(kept)
            let whole = kept.whole(with: partNumbers ?? MeasuredNumbers())
            averageHeartRate = whole.averageHeartRate
            measuredEnergy = whole.activeEnergy
            store.replaceHealthMetrics(sessionID: finishedID, with: whole, bumping: false)
        } else if let numbers = partNumbers, !numbers.isEmpty {
            store.recordHealthMetrics(sessionID: finishedID, averageHeartRate: numbers.averageHeartRate, maxHeartRate: numbers.maxHeartRate,
                                      activeEnergy: numbers.activeEnergy, bumping: false)
        }
        store.save(bumping: false)
        // The one bump of Finish – before the summary and the watch's snapshot, so the streak and
        // Today count the finished workout.
        store.bump()

        let record = session.record()
        let records = StatsEngine.newRecords(in: record, comparedTo: history)
        let template = store.template(id: session.templateID)
        // What "Update Loads" would write (heavier weights, longer holds and distances, to-failure
        // sets too) – the same rule the workout's page offers it by.
        let loadChanges = template.map { content.templateChanges(into: $0.content, mode: .loads, unit: unit) } ?? []
        let canUpdate = settings.askToUpdateTemplate && (store.sessionDiffersFromTemplate(session) || !loadChanges.isEmpty)
        // Each earlier workout's template, without loading the workouts.
        let templateOf = store.performedTemplateIDs()
        let comparison = StatsEngine.compare(record, templateID: session.templateID, previous: history) { id in
            templateOf[id]
        }
        let worked = MusclePlan.sets(of: content, completedOnly: true, kind: session.kind) { [library] item in library.contributions(for: item) }
        let coolDown = CoachPrefs.offerCoolDown && !session.kind.isFlow && content.completedSets > 0
            ? RoutineLibrary.coolDown(for: worked, catalog: library.catalog) : nil
        let finished = FinishSummary(
            sessionID: finishedID, title: session.title, duration: session.accumulatedSeconds,
            completedSets: content.completedSets, totalSets: content.totalSets, volumeKg: content.volumeKg,
            energyKcal: (measuredEnergy ?? 0) > 0 ? (measuredEnergy ?? 0) : session.energyKcal,
            averageHeartRate: (averageHeartRate ?? 0) > 0 ? averageHeartRate : nil,
            records: records, canUpdateTemplate: canUpdate, templateName: session.templateName, savedToHealth: savedToHealth,
            comparison: comparison, loadChanges: loadChanges,
            canSaveAsTemplate: session.templateID == nil && content.exerciseCount >= 2,
            kind: session.kind, coolDown: coolDown, healthNote: healthNote
        )
        lastFinished = WatchFinishSummary(
            sessionID: finishedID, title: session.title, finishedAt: end, durationSeconds: finished.duration,
            completedSets: finished.completedSets, totalSets: finished.totalSets, energyKcal: finished.energyKcal,
            averageHeartRate: finished.averageHeartRate, records: records.count,
            streakHeadline: store.streakSummary(healthEntries: health.externalWorkouts).headline
        )
        // Nothing may have restarted the clock while Health was saving.
        if session.resumedAt != nil {
            session.resumedAt = nil
            store.save(bumping: false)
        }
        detach()
        Haptics.success()
        VoiceCoach.shared.stop()
        if showSummary {
            VoiceCoach.shared.say("Workout complete! \(Int((finished.duration / 60).rounded())) minutes, \(finished.completedSets) sets. Well done.", cue: .summary, priority: .high)
            // Present the summary once the live view has finished dismissing.
            try? await Task.sleep(nanoseconds: 650_000_000)
            summary = finished
        }
    }

    /// The workout just saved (the watch shows it as a summary).
    @ObservationIgnored private var lastFinished: WatchFinishSummary?

    /// The running workout was saved before and continued (stopped early, "Save It and Start"):
    /// Discard throws away only what was done since continuing.
    var discardKeepsSavedPart: Bool {
        if let before = preStart {
            guard let status = SessionStatus(rawValue: before.statusRaw) else { return false }
            return status.isPerformed
        }
        // Taken over here (Continue Here): no snapshot on this device, the synced session tells.
        guard let session, session.modelContext != nil else { return false }
        if case .keepEarlierPart = TakenOverDiscard.outcome(createdAt: session.createdAt, startedAt: session.startedAt,
                                                            endedAt: session.endedAt) {
            return true
        }
        return false
    }

    /// The running workout was saved before and continued (`discardKeepsSavedPart`): the active time
    /// of the part(s) saved before, when they ended and when it was continued (known only on the
    /// device that continued it: taken over here, the synced session tells the rest). Read before
    /// Finish changes the session.
    private func continuedEarlierPart() -> (seconds: Double, endedAt: Date?, continuedAt: Date?)? {
        guard discardKeepsSavedPart, let session else { return nil }
        if let preStart {
            return (seconds: preStart.accumulatedSeconds, endedAt: preStart.endedAt, continuedAt: preStart.segmentStartedAt)
        }
        guard let endedAt = session.endedAt else { return nil }
        let seconds = TakenOverDiscard.earlierActiveSeconds(accumulated: session.accumulatedSeconds, startedAt: session.startedAt, endedAt: endedAt)
        return (seconds: seconds, endedAt: endedAt, continuedAt: nil)
    }

    /// What this device keeps measured for the part(s) of a session that ended at `earlierEnd`
    /// (`HealthMetrics`; empty without, or when kept before that end: one part's only, the one
    /// before a part done on another device).
    private func storedNumbers(of sessionID: UUID, endedAt earlierEnd: Date?) -> MeasuredNumbers {
        guard let kept = store.healthMetrics(for: sessionID) else { return MeasuredNumbers() }
        return MeasuredNumbers(averageHeartRate: kept.averageHeartRate, maxHeartRate: kept.maxHeartRate, activeEnergy: kept.activeEnergyKcal)
            .shown(workoutEnd: earlierEnd, keptAt: kept.updatedAt)
    }

    /// Throws away what was done since Start. A workout continued after "stopped early" goes back to
    /// how it was saved (its earlier sets, effort and Apple Health link stay), a planned one back to
    /// its day and name. Only a session this Start made is deleted; the result is an Undo for that
    /// (nil when nothing was deleted or there's no undo). `deleteSession`: the workout's own Delete,
    /// which deletes it whatever it was before.
    @discardableResult
    func discard(deleteSession: Bool = false) -> (() -> Void)? {
        guard let session, !isFinishing else { return nil }
        // Continued on another device: Discard doesn't reset it there (this device lets go instead).
        // Delete still deletes it.
        if !deleteSession && !confirmOwnership() { return nil }
        AppLog.info(deleteSession ? "Running workout deleted" : "Workout discarded", category: "workout")
        cancelRest()
        // Always – also before the watch's first numbers came: it throws its recording away instead
        // of saving a junk workout to Apple Health.
        lastDiscardedSessionID = session.id
        let id = session.id
        let before = preStart
        var deletes = false
        if !deleteSession, let before {
            // Back to how it was before Start.
            session.content = WorkoutContent.decode(before.contentData)
            if let data = before.contentData { session.contentData = data }
            session.status = SessionStatus(rawValue: before.statusRaw) ?? .planned
            session.startedAt = before.startedAt
            session.plannedDate = before.plannedDate
            session.endedAt = before.endedAt
            session.accumulatedSeconds = before.accumulatedSeconds
            session.resumedAt = nil
            // The automatic title Start gave it for today goes; a title typed since stays.
            if let auto = before.autoTitle, session.title == auto { session.title = before.title }
        } else if !deleteSession {
            // Taken over without a Start here (Continue Here): how it looked before Start stayed on the
            // device that started it. The synced session tells what it was (`TakenOverDiscard`).
            switch TakenOverDiscard.outcome(createdAt: session.createdAt, startedAt: session.startedAt, endedAt: session.endedAt) {
            case .keepEarlierPart(let endedAt):
                // Saved before and continued: that part stays (sets, effort, Apple Health link), the
                // sets ticked since go.
                let earlier = content.takingBackSets(doneAfter: endedAt)
                session.content = earlier
                session.status = TakenOverDiscard.earlierPartIsComplete(earlier) ? .completed : .partial
                session.accumulatedSeconds = TakenOverDiscard.earlierActiveSeconds(
                    accumulated: session.accumulatedSeconds, startedAt: session.startedAt, endedAt: endedAt)
                session.resumedAt = nil
            case .backToPlan:
                // Planned earlier: back to the plan, its ticks taken back.
                session.content = content.takingBackSets(doneAfter: nil)
                session.status = .planned
                session.resumedAt = nil
                session.accumulatedSeconds = 0
                session.startedAt = nil
                session.endedAt = nil
            case .delete:
                deletes = true
            }
        } else {
            deletes = true
        }
        store.save()
        // Let go first: a deleted session isn't read any more.
        detach()
        var undo: (() -> Void)?
        if deletes {
            store.delete(session)
            if let undoDelete = store.undoLastChange() {
                undo = { [weak self] in
                    undoDelete()
                    guard let self, self.session == nil, let back = self.store.session(id: id) else { return }
                    self.continueHere(back)
                    // A Delete of a continued workout keeps its way back for a later Discard.
                    if let before {
                        self.preStart = before
                        before.save(for: id)
                    }
                }
            }
        }
        store.bump()
        return undo
    }

    private func detach() {
        if let id = attachedID { LiveResume.clear(for: id) }
        UserDefaults.standard.removeObject(forKey: Prefs.liveSessionID)
        // The claim stays on the synced session (it only counts while the workout is in progress).
        UserDefaults.standard.removeObject(forKey: Prefs.liveClaimedAt)
        ownClaimedAt = nil
        lastSeenData = nil
        resetTransientState()
        undoTask?.cancel()
        liveSyncTask?.cancel()
        // A session deleted elsewhere isn't read (its context is gone).
        LiveActivityBridge.shared.end(session?.modelContext != nil ? liveState() : nil)
        timedSetTask?.cancel()
        timedSetEndsAt = nil
        offPlanTask?.cancel()
        offPlanNotice = nil
        PhoneWorkoutSession.shared.end()
        phoneSessionAwaitsWatch = false
        VoiceCoach.shared.isMuted = false
        isVoiceMuted = false
        nudgeTask?.cancel()
        restWarningTask?.cancel()
        celebrationTask?.cancel()
        effortTask?.cancel()
        celebration = nil
        effortRequest = nil
        session = nil
        attachedID = nil
        preStart = nil
        content = WorkoutContent()
        contentStamp &+= 1
        currentRef = nil
        focusedItemID = nil
        isPresented = false
        setIdleTimer(disabled: false)
        syncWatch()
    }

    private func setIdleTimer(disabled: Bool) {
        #if os(iOS)
        let keepAwake = UserDefaults.standard.object(forKey: Prefs.keepAwake) as? Bool ?? true
        UIApplication.shared.isIdleTimerDisabled = disabled && keepAwake
        #endif
    }

    // MARK: Watch

    func liveState() -> WatchLiveState? {
        guard let session else { return nil }
        return WatchLiveState(
            sessionID: session.id, title: session.title, kind: session.kind,
            startedAt: session.startedAt ?? Date(), accumulatedSeconds: session.accumulatedSeconds,
            resumedAt: session.resumedAt, isPaused: session.resumedAt == nil,
            restEndsAt: restEndsAt, restTotalSeconds: restEndsAt == nil ? nil : restTotal,
            currentSetID: currentSet?.id,
            exercises: WatchLiveState.exercises(from: content, unit: unit),
            completedSets: content.completedSets, totalSets: content.totalSets,
            setStartedAt: pace.startedAt, lastSetEndedAt: pace.lastSetAt,
            plannedRestSeconds: Int(restBeforeNext), timedSetSeconds: timedTarget,
            behindSeconds: pace.totalDelta, lastDeltaSeconds: pace.lastGap?.delta,
            usesStartButton: CoachPrefs.startButton,
            question: effortRequest.map {
                WatchQuestion(setID: $0.setID, exerciseName: $0.itemName, muscles: $0.muscles,
                              asksReps: $0.asksReps && $0.repsInReserve == nil, asksFatigue: $0.asksFatigue && $0.fatigue == nil)
            },
            asksEnergy: needsEnergyCheckIn,
            voiceMuted: isVoiceMuted,
            viewingExerciseID: isViewingElsewhere ? focusedItemID : nil,
            timedSides: timedTarget != nil && currentItem?.perSide == true ? 2 : nil
        )
    }

    func makeSnapshot() -> WatchSnapshot {
        let program = store.activeProgram
        let suggested = store.suggestedTemplate(in: program)
        var templates = program?.orderedTemplates ?? []
        let others = store.fetchTemplates()
            .filter { $0.program?.id != program?.id }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(8)
        templates.append(contentsOf: others)
        let watchTemplates = templates.map { template in
            WatchTemplate(
                id: template.id, name: template.name, subtitle: template.subtitle, kind: template.kind,
                programName: template.program?.name ?? "", exerciseCount: template.exerciseCount,
                estimatedMinutes: template.estimatedMinutes, isSuggested: template.id == suggested?.id
            )
        }
        let upcoming = store.upcomingSessions(limit: 6).map {
            WatchSessionSummary(id: $0.id, title: $0.title, kind: $0.kind, date: $0.plannedDate ?? $0.date, status: $0.statusRaw)
        }
        let streak = store.streakSummary(healthEntries: health.externalWorkouts)
        // The same count as the phone ("3/3" after a rescue), with the week it belongs to so the watch,
        // its complication and the widgets don't carry it into the next week.
        let watchStreak = WatchStreak(
            weeks: streak.currentWeeks, doneDays: streak.thisWeek.effectiveDays, goal: streak.thisWeek.goal,
            credits: streak.credits, headline: streak.headline, dots: streak.thisWeek.dots.map(\.didWorkout),
            weekStart: streak.thisWeek.weekStart
        )
        // A workout handed over to a Mac: the watch keeps recording it, or ends that recording.
        return WatchSnapshot(templates: watchTemplates, upcoming: upcoming, streak: watchStreak, live: liveState(), unit: unit,
                             discardedSessionID: lastDiscardedSessionID, lastFinished: lastFinished,
                             handedOver: watchOnlyLink?.handOver)
    }

    func syncWatch() {
        let snapshot = makeSnapshot()
        #if os(iOS)
        watch.sendSnapshot(snapshot)
        if let live = liveState() { watch.sendLive(live) }
        #endif
        // Widgets and the Lock Screen (deduplicated; also clears a Live Activity left over from a killed app).
        WidgetBridge.write(snapshot: snapshot)
        // A widget refresh asked for earlier in this turn (Start, detach) uses this snapshot – no second build.
        LiveActivityBridge.shared.widgetsWritten()
    }

    /// A live sync is due at the end of this main-actor turn (`syncLive`).
    @ObservationIgnored private var liveSyncPending = false

    /// The watch, the Lock Screen and where a relaunch continues hear about changes once per
    /// main-actor turn: a tick that starts a rest and saves sends one message and writes once.
    private func syncLive() {
        lastLiveSync = Date()
        liveSyncTask?.cancel()
        liveSyncTask = nil
        guard !liveSyncPending else { return }
        liveSyncPending = true
        Task { @MainActor [weak self] in self?.flushLiveSync() }
    }

    private func flushLiveSync() {
        guard liveSyncPending else { return }
        liveSyncPending = false
        // Ended or let go in the meantime: detach already told the watch and the Lock Screen.
        guard session != nil else { return }
        // Every change the watch and Lock Screen hear about (a skipped rest, a jump to another set,
        // the plan moved on) is also where a relaunch continues.
        saveResume()
        let state = liveState()
        #if os(iOS)
        if let state { watch.sendLive(state) }
        #endif
        LiveActivityBridge.shared.update(state)
    }

    /// At most twice a second for value edits (typing a weight shouldn't flood the watch).
    private func syncLiveThrottled() {
        let wait = 0.5 - Date().timeIntervalSince(lastLiveSync)
        guard wait > 0 else { return syncLive() }
        guard liveSyncTask == nil else { return }
        liveSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.syncLive()
        }
    }

    /// A command from the watch: stale ones (queued while out of range, meant for another workout)
    /// are dropped.
    private func handle(_ envelope: WatchCommandEnvelope) {
        // Launched in the background for this message (arriving at the gym, or iOS ended the app
        // mid-workout): the running workout is attached first, as for App Intents.
        if session == nil { restore() }
        guard envelope.isFresh(activeSessionID: session?.id) else {
            AppLog.info("Ignored a stale watch command", category: "watch")
            syncWatch()
            return
        }
        perform(envelope.command, sentAt: envelope.sentAt)
    }

    /// Runs a live command (watch, Live Activity buttons, App Intents). `sentAt`: when the watch sent
    /// it – a set logged on the watch counts from then, also when it arrives late.
    func perform(_ command: WatchCommand, sentAt: Date? = nil) {
        // Finish is saving (it waits for Apple Health): the workout is over – a tick or Resume from the
        // watch, Lock Screen or Siri must not restart its clock. The watch gets the current state back.
        guard !isFinishing else {
            syncWatch()
            return
        }
        switch command {
        case .toggleSet(let id): toggleSet(id)
        case .completeCurrentSet: completeCurrentSet()
        case .startSet: startSet()
        case .startRest(let seconds): startRest(seconds)
        case .addRest(let seconds): addRest(seconds)
        case .skipRest: skipRest()
        case .pause: pause()
        case .resume: resume()
        case .finish(let effort):
            guard let current = session else { return }
            // "Save without rating" on the watch: no effort is stored (George and Apple Health).
            let rating = FinishRating.stored(effort)
            // Known at once, before the save starts: the watch's saved workout may arrive any moment.
            pendingHealthSessionID = current.id
            pendingEffort = rating
            // A watch's Finish ends the workout when it was tapped, also when it arrives late.
            Task { await finish(effort: rating, notes: nil, endedAt: sentAt) }
        case .discard:
            // A Discard that arrives late doesn't throw away what was done here after it was tapped.
            if let sentAt, let last = lastSignOfLife, last > sentAt.addingTimeInterval(5) {
                AppLog.info("Ignored a late watch Discard: the workout went on here", category: "watch")
                // The watch threw its recording away when Discard was tapped (and sends nothing more):
                // Finish saves the workout from the iPhone instead of waiting for the watch's.
                if watchIsRecording {
                    watchIsRecording = false
                    watchStoppedAt = sentAt
                    watchStopNotice = WatchStopWording.liveNotice(savedPart: watchWorkoutID != nil)
                    saveResume()
                }
                return syncWatch()
            }
            discard()
        case .startTemplate(let id):
            guard session == nil else { return syncWatch() }
            // Today's planned session of this template, if there is one – never a duplicate next to it.
            // Through the same check as every Start button: with a workout running on another device,
            // this device asks (Continue Here / Start Anyway) instead of starting a second one.
            if let template = store.template(id: id) { requestStart(store.startTarget(for: template)) }
        case .startSession(let id):
            guard session == nil else { return syncWatch() }
            if let target = store.session(id: id) { requestStart(.session(target)) }
        case .requestSnapshot: syncWatch()
        case .completeSet(let id, let reps, let weightKg):
            if reps != nil || weightKg != nil {
                content.updateSet(id: id) { set in
                    if let reps { set.reps = reps }
                    if let weightKg { set.weight = weightKg }
                }
            }
            if content.set(id: id)?.isDone == false { toggleSet(id, at: sentAt) } else { persist() }
        case .undoSet(let id):
            // Only a set that is done is unticked: a repeat changes nothing.
            guard content.set(id: id)?.isDone == true else { return syncWatch() }
            toggleSet(id)
        case .dropWeight(let setID, let repsDone, let newWeightKg):
            // A late "Can't finish?" for a set the phone already logged is ignored.
            guard content.set(id: setID)?.isDone == false else { return syncWatch() }
            dropWeight(setID: setID, repsDone: repsDone, newWeightKg: newWeightKg, applyToRemaining: true)
        case .makeCurrent(let setID):
            makeCurrent(setID: setID)
            clearOffPlan()
            announceSetUp(isFirst: false)
        case .moveThread(let offset): moveThread(by: offset)
        case .toggleVoiceMute: toggleVoiceMute()
        case .answerFeedback(let setID, let rir, let fatigue):
            guard effortRequest?.setID == setID else { return }
            if let fatigue { recordFatigue(fatigue) }
            if let rir { recordReps(inReserve: rir) }
        case .recordEnergy(let level): recordEnergy(level)
        }
    }

    /// Adds warm-up sets in front of an exercise (empty bar, 50 %, 70 %, 85 % of the top weight).
    func addWarmups(to itemID: UUID) {
        var added = 0
        edit { added = $0.addWarmups(to: itemID, barKg: CoachPrefs.barKg, incrementKg: unit.toKilograms(unit.increment)) }
        guard added > 0 else { return }
        // The first warm-up is due now.
        if let loc = content.locate(itemID: itemID), let s = content.blocks[loc.block].items[loc.item].sets.firstIndex(where: { !$0.isDone }) {
            currentRef = WorkoutContent.SetRef(blockIndex: loc.block, itemIndex: loc.item, setIndex: s)
            focusedItemID = itemID
            VoiceCoach.shared.moveOn(to: currentSet?.id)
        }
        Haptics.success()
        announceSetUp(isFirst: false)
        refreshRestNotification()
        persist()
    }

    private func handle(_ metrics: WatchMetrics) {
        receive(metrics)
    }
}

// MARK: - Finish time and Apple Health links

@MainActor
extension LiveWorkoutController {
    /// The running workout's last sign of life: a ticked or started set, a resume, the start.
    private var lastSignOfLife: Date? {
        guard let session, session.modelContext != nil else { return nil }
        return RunningWorkout.lastActivity(startedAt: session.startedAt, resumedAt: session.resumedAt, content: content)
    }

    /// The clock as it stands, for an end before now.
    private var finishClock: LiveClock? {
        guard let session, session.modelContext != nil else { return nil }
        return LiveClock(startedAt: session.startedAt, accumulatedSeconds: session.accumulatedSeconds,
                         resumedAt: session.resumedAt, pausedAt: pausedAt)
    }

    /// Active seconds up to `end` (pauses left out) – the finish sheet's time for an earlier end.
    func activeSeconds(until end: Date) -> Double {
        finishClock?.activeSeconds(until: end) ?? 0
    }

    /// "Last set + rest" (the planned rest after it, else the default rest): where a workout left
    /// running ends. Only with a set done: a workout without sets (tennis, "just track time") is its time.
    func suggestedFinishEnd(now: Date = Date()) -> Date? {
        guard content.completedSets > 0, let last = lastSignOfLife else { return nil }
        let rest = restBeforeNext > 0 ? restBeforeNext : Double(store.settings.defaultRestSeconds)
        return FinishTime.suggestedEnd(lastActivity: last, restSeconds: rest, pausedAt: pausedAt, now: now)
    }

    /// The finish sheet offers to end at the last set + rest: nothing happened for half an hour.
    func earlierFinishEnd(now: Date = Date()) -> Date? {
        guard FinishTime.idleSeconds(lastActivity: lastSignOfLife, pausedAt: pausedAt, now: now) > FinishTime.offerAfter else { return nil }
        return suggestedFinishEnd(now: now)
    }

    /// Today asks "Still training?" (with this end): no sign of life for three hours, and not
    /// answered with Continue.
    func stillTrainingEnd(at now: Date = Date()) -> Date? {
        guard session != nil, let id = attachedID, !isFinishing, id != stillTrainingDismissedID,
              FinishTime.idleSeconds(lastActivity: lastSignOfLife, pausedAt: pausedAt, now: now) > FinishTime.stillTrainingAfter else { return nil }
        return suggestedFinishEnd(now: now)
    }

    /// "Finish" on Today's "Still training?": live mode opens with the finish sheet, set to end at
    /// the last set.
    func finishLeftRunningWorkout() {
        guard session != nil else { return }
        isPresented = true
        finishRequest = true
    }

    /// "Continue" on Today's "Still training?": live mode opens; the question doesn't come back for it.
    func continueLeftRunningWorkout() {
        stillTrainingDismissedID = attachedID
        isPresented = true
    }

    /// The end a finish uses (see `FinishTime.resolvedEnd`).
    func finishEnd(requested: Date?, chosen: Bool, now: Date) -> Date {
        guard let session, let clock = finishClock else { return min(requested ?? now, now) }
        return FinishTime.resolvedEnd(requested: requested, chosen: chosen, clock: clock, kind: session.kind,
                                      suggestedEnd: suggestedFinishEnd(now: now), lastActivity: lastSignOfLife, now: now)
    }

    /// Finish waits for a sign from the watch – its numbers, or the workout it saved – at most
    /// `HealthLink.watchWait`.
    func waitForWatch() async {
        isWaitingForWatch = true
        defer { isWaitingForWatch = false }
        let deadline = Date().addingTimeInterval(HealthLink.watchWait)
        while Date() < deadline, !watchIsRecording, watchWorkoutID == nil, watchStoppedAt == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        AppLog.info(watchIsRecording || watchWorkoutID != nil ? "Apple Watch records the workout" : "No word from Apple Watch: saving from iPhone",
                    category: "health")
    }

    /// Numbers, or the saved Apple Health workout, from the watch's recording.
    func receive(_ metrics: WatchMetrics) {
        // Older watches send no workout id: numbers belong to the running workout, a saved workout to
        // the one just finished (else the running one).
        let targetID = metrics.sessionID ?? (metrics.isFinal ? (pendingHealthSessionID ?? attachedID) : attachedID)
        guard let targetID else { return }
        if session != nil, targetID == attachedID {
            // Continued soon after "stopped early": the final numbers of the part before, come late (that
            // recording ended before this part began), are linked as that part's – not this part's
            // numbers, and not "Apple Watch stopped recording".
            if metrics.isFinal, metrics.sessionID != nil, discardKeepsSavedPart,
               MeasuredNumbers.isEarlierRecording(endedAt: metrics.endedAt, partBegan: preStart?.segmentStartedAt) {
                if let workoutID = metrics.healthWorkoutID { linkFinishedWorkout(targetID, toWatchWorkout: workoutID, metrics: metrics) }
                return
            }
            receiveForRunningWorkout(metrics)
        } else if let link = watchOnlyLink, link.sessionID == targetID {
            // The recording of a workout handed over to a Mac.
            receiveForWatchOnlyLink(link, metrics: metrics)
        } else if let workoutID = metrics.healthWorkoutID {
            linkFinishedWorkout(targetID, toWatchWorkout: workoutID, metrics: metrics)
        }
    }

    /// The watch's recording of the workout that runs here.
    private func receiveForRunningWorkout(_ metrics: WatchMetrics) {
        if let hr = metrics.heartRate { heartRate = hr }
        if let avg = metrics.averageHeartRate { watchAverageHeartRate = avg }
        if let energy = metrics.activeEnergy { watchEnergy = energy }
        guard metrics.isFinal else {
            // The watch records it (again, after it stopped on the way). Kept, so a relaunch knows.
            if !watchIsRecording || watchStoppedAt != nil {
                watchIsRecording = true
                watchStoppedAt = nil
                watchStopNotice = nil
                saveResume()
            }
            return
        }
        if let workoutID = metrics.healthWorkoutID {
            watchWorkoutID = workoutID
            if let session, session.modelContext != nil {
                let plan = HealthLink.plan(watchWorkoutID: workoutID, linkedID: session.healthWorkoutID.flatMap(UUID.init(uuidString:)), phoneSavedID: nil)
                store.saveWithoutUndo {
                    if let linkID = plan.linkID { session.healthWorkoutID = linkID.uuidString }
                    session.recordedOnWatch = true
                }
            }
        }
        // Being finished (here, or the watch's Finish is on its way): the watch saved the workout.
        let finishing = isFinishing || pendingHealthSessionID == attachedID
        if !finishing || metrics.healthWorkoutID == nil {
            // Ended on the watch or by watchOS while the workout goes on (or it couldn't save): Finish
            // saves the rest from the iPhone.
            watchIsRecording = false
            watchStoppedAt = metrics.endedAt ?? Date()
            // Said in live mode, which covers toasts.
            if !finishing { watchStopNotice = WatchStopWording.liveNotice(savedPart: watchWorkoutID != nil) }
            AppLog.info("Apple Watch stopped recording the running workout", category: "watch")
        }
        saveResume()
    }

    /// The watch saved its workout for one that is finished (or not running here): it becomes the
    /// link, a copy the iPhone saved without hearing from the watch goes, the effort is attached.
    private func linkFinishedWorkout(_ sessionID: UUID, toWatchWorkout workoutID: UUID, metrics: WatchMetrics) {
        let pending = LiveResume.pendingHealthLinks().first { $0.sessionID == sessionID }
        let awaited = pending != nil || pendingHealthSessionID == sessionID
        let pendingRating = pendingHealthSessionID == sessionID ? pendingEffort : 0
        if pendingHealthSessionID == sessionID {
            pendingHealthSessionID = nil
            pendingEffort = 0
        }
        if pending != nil { LiveResume.removePendingHealthLink(for: sessionID) }
        // Discarded, but the watch heard of it too late and saved it anyway: it goes.
        if sessionID == lastDiscardedSessionID, !awaited {
            AppLog.info("Removing the watch's recording of a discarded workout", category: "health")
            Task { await health.deleteWorkout(id: workoutID) }
            return
        }
        // Performed – or running here again (continued), for the late recording of its part before.
        guard let target = store.session(id: sessionID), target.modelContext != nil,
              target.status.isPerformed || sessionID == attachedID else { return }
        let plan = HealthLink.plan(watchWorkoutID: workoutID, linkedID: target.healthWorkoutID.flatMap(UUID.init(uuidString:)),
                                   phoneSavedID: pending?.phoneWorkoutID)
        store.saveWithoutUndo {
            if let linkID = plan.linkID { target.healthWorkoutID = linkID.uuidString }
            if awaited || plan.linkID != nil { target.recordedOnWatch = true }
        }
        // Its totals count only when it didn't run on long after the workout ended (one left running and
        // ended at its last set).
        let fits = MeasuredNumbers.watchTotalsFit(workoutEnd: target.endedAt ?? .distantFuture, countedUntil: metrics.endedAt ?? Date())
        if let earlier = LiveResume.earlierPart(for: sessionID) {
            // Continued after "stopped early": the final totals of the part Finish waited for, with the
            // first part's numbers kept then, are the whole workout's – never this part's alone. A late
            // recording of the first part, or the same message again, changes nothing.
            if awaited, fits, earlier.isLaterPart(recordingEndedAt: metrics.endedAt) {
                let part = MeasuredNumbers(averageHeartRate: metrics.averageHeartRate, activeEnergy: metrics.activeEnergy)
                store.replaceHealthMetrics(sessionID: sessionID, with: earlier.whole(with: part))
            }
        } else if target.healthWorkoutID.flatMap(UUID.init(uuidString:)) == workoutID, fits {
            // The workout's own recording (its link).
            store.recordHealthMetrics(sessionID: sessionID, averageHeartRate: metrics.averageHeartRate, maxHeartRate: nil, activeEnergy: metrics.activeEnergy)
        }
        // The same message twice adds nothing.
        guard awaited || plan.linkID != nil else { return }
        let effort = pendingRating > 0 ? pendingRating : (pending?.effort ?? target.effort)
        Task {
            if let duplicate = plan.deleteID {
                AppLog.info("The watch's workout arrived: removing the copy the iPhone saved", category: "health")
                await health.deleteWorkout(id: duplicate)
            }
            await health.relateEffort(effort, toWorkoutWithID: workoutID)
        }
    }

    /// Launch: workouts the watch recorded whose Apple Health link never arrived (George was closed,
    /// the message got lost) find it again by George's session id in the workout's metadata.
    func repairWatchHealthLinks() async {
        #if os(iOS)
        guard health.isAvailable, !LaunchOptions.current.isDemo, UserDefaults.standard.bool(forKey: Prefs.healthAsked) else { return }
        let since = Date().addingTimeInterval(-7 * 86_400)
        let descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.recordedOnWatch == true && $0.healthWorkoutID == nil })
        let missing = ((try? store.context.fetch(descriptor)) ?? []).filter { $0.status.isPerformed && ($0.endedAt ?? .distantPast) > since }
        guard !missing.isEmpty else { return }
        let found = await health.workoutIDs(forSessionIDs: missing.map(\.id))
        var repaired = 0
        for session in missing where session.modelContext != nil && session.healthWorkoutID == nil {
            guard let workoutID = found[session.id] else { continue }
            store.saveWithoutUndo { session.healthWorkoutID = workoutID.uuidString }
            LiveResume.removePendingHealthLink(for: session.id)
            if session.effort > 0 { await health.relateEffort(session.effort, toWorkoutWithID: workoutID) }
            repaired += 1
        }
        if repaired > 0 { AppLog.info("Linked \(repaired) watch workouts found in Apple Health", category: "health") }
        #endif
    }
}

// MARK: - Apple Watch recording across a hand-over

@MainActor
extension LiveWorkoutController {
    private static let watchOnlyLinkKey = "live.watchOnlyLink"

    /// A workout handed over to a Mac while the watch recorded it (`WatchOnlyLink`), kept on this
    /// device apart from the workout's own state (which goes when it lets go). One at a time.
    private var watchOnlyLink: WatchOnlyLink? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.watchOnlyLinkKey) else { return nil }
            return try? JSONDecoder().decode(WatchOnlyLink.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.watchOnlyLinkKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.watchOnlyLinkKey)
            }
        }
    }

    /// The watch saved the part it recorded before it stopped (Finish saves the rest from the iPhone).
    var watchSavedPart: Bool { watchWorkoutID != nil }

    /// Closes live mode's "Apple Watch stopped recording" notice.
    func dismissWatchStopNotice() {
        watchStopNotice = nil
    }

    /// Letting go of a workout to another device: a Mac saves nothing to Apple Health, so the watch
    /// keeps recording it (true: the link is kept) until the workout ends on the Mac. For an iPad or
    /// iPhone the watch throws its recording away (false), as that device saves the workout.
    private func keepWatchRecording(sessionID: UUID, for owner: LiveOwner?, heard: Bool, expected: Bool, stopped: Bool, since: Date?) -> Bool {
        guard WatchOnlyLink.keepsRecording(newOwner: owner?.kind, watchHeard: heard, watchExpected: expected, watchStopped: stopped) else { return false }
        AppLog.info("Continued on a Mac: Apple Watch keeps recording", category: "watch")
        watchOnlyLink = WatchOnlyLink(sessionID: sessionID, recordingSince: since, linkedAt: Date(), watchRecording: heard)
        return true
    }

    /// Continue Here on the workout the link is for: the link goes – also one whose end was already
    /// sent (its snapshot would tell the watch to end or drop the recording of the workout running
    /// here) – and the caller picks the recording up.
    private func takeWatchOnlyLink(for id: UUID) -> WatchOnlyLink? {
        guard let link = watchOnlyLink, link.sessionID == id else { return nil }
        watchOnlyLink = nil
        return link
    }

    /// Back from the Mac: the watch's recording, still running, records the workout here again (no
    /// second one). One that ended in the meantime keeps its part; Finish saves the rest from here.
    /// One the watch was told to throw away isn't counted on (`WatchOnlyLink.resumption`).
    private func adoptWatchRecording(_ link: WatchOnlyLink, of session: WorkoutSession) {
        guard let resumption = link.resumption else { return }
        AppLog.info("Back from the Mac: Apple Watch's recording picked up again", category: "watch")
        watchExpected = true
        watchIsRecording = resumption.recording
        if let final = resumption.final {
            watchStoppedAt = final.endedAt
            watchWorkoutID = final.healthWorkoutID
            // Live mode says so, as for a watch that stops while the workout runs here.
            watchStopNotice = WatchStopWording.liveNotice(savedPart: final.healthWorkoutID != nil)
            if let workoutID = final.healthWorkoutID {
                let plan = HealthLink.plan(watchWorkoutID: workoutID, linkedID: session.healthWorkoutID.flatMap(UUID.init(uuidString:)), phoneSavedID: nil)
                store.saveWithoutUndo {
                    if let linkID = plan.linkID { session.healthWorkoutID = linkID.uuidString }
                    session.recordedOnWatch = true
                }
            }
        }
        saveResume()
    }

    /// The synced workout as the link sees it.
    private func syncedWorkout(_ synced: WorkoutSession?) -> WatchOnlyLink.SyncedWorkout {
        guard let synced else { return .deleted }
        if synced.status == .active {
            return .running(owner: LiveOwner(raw: synced.liveDeviceID),
                            lastActivity: RunningWorkout.lastActivity(startedAt: synced.startedAt, resumedAt: synced.resumedAt, content: synced.content))
        }
        return synced.status.isPerformed ? .performed(endedAt: synced.endedAt) : .notDone
    }

    /// After a sync, an import or a launch: once the workout handed over to a Mac ended there (or
    /// was discarded, deleted, or taken over by a device that saves it), the watch is told to end its
    /// recording – at the workout's end, or thrown away – and its saved workout is linked.
    private func checkWatchOnlyLink(now: Date = Date()) {
        // Screenshot runs use a store of their own: they never judge a real workout.
        guard !LaunchOptions.current.isDemo, var link = watchOnlyLink else { return }
        guard !link.isExpired(now: now) else {
            watchOnlyLink = nil
            return
        }
        let synced = store.session(id: link.sessionID).flatMap { $0.modelContext != nil ? $0 : nil }
        if link.ending == nil {
            switch WatchOnlyLink.step(for: syncedWorkout(synced), recordingSince: link.recordingSince, localID: ThisDevice.installID, now: now) {
            case .keep:
                return
            case .end(let at):
                link.ending = .save(at: at)
                // Linked (effort attached) when the watch's workout arrives (`linkFinishedWorkout`) – or,
                // should that message get lost, at a later launch (`repairWatchHealthLinks`).
                LiveResume.addPendingHealthLink(PendingHealthLink(sessionID: link.sessionID, effort: synced?.effort ?? 0, finishedAt: at))
                if let synced, synced.status.isPerformed, link.watchRecording, !synced.recordedOnWatch {
                    store.saveWithoutUndo { synced.recordedOnWatch = true }
                }
                AppLog.info("Workout ended on the Mac: Apple Watch saves its recording", category: "watch")
            case .discard:
                link.ending = .discard
                AppLog.info("Workout left the Mac without a save: Apple Watch drops its recording", category: "watch")
            }
            link.endingSince = now
            watchOnlyLink = link
            syncWatch()
        }
        settleWatchOnlyLink(link, synced: synced)
    }

    /// Once the workout ended: the watch's saved workout is linked, or removed again when its
    /// recording was meant to go.
    private func settleWatchOnlyLink(_ link: WatchOnlyLink, synced: WorkoutSession?) {
        switch link.settlement(sessionExists: synced != nil, sessionPerformed: synced?.status.isPerformed == true) {
        case .wait:
            return
        case .link(let workoutID):
            watchOnlyLink = nil
            // With the effort as it is now (rated on the Mac).
            if let synced, case .save(let at) = link.ending {
                LiveResume.addPendingHealthLink(PendingHealthLink(sessionID: link.sessionID, effort: synced.effort, finishedAt: at))
            }
            // Its calories and heart rate only when it recorded up to the workout's end (not one part's).
            linkFinishedWorkout(link.sessionID, toWatchWorkout: workoutID,
                                metrics: link.linkedMetrics(workoutEnd: synced?.endedAt) ?? WatchMetrics(sessionID: link.sessionID))
        case .deleteWatchWorkout(let workoutID):
            watchOnlyLink = nil
            AppLog.info("Removing Apple Watch's recording of a workout that was handed over and dropped", category: "health")
            Task { await health.deleteWorkout(id: workoutID) }
        case .drop:
            watchOnlyLink = nil
        }
    }

    /// A packet from the watch's recording of the workout handed over to a Mac.
    private func receiveForWatchOnlyLink(_ link: WatchOnlyLink, metrics: WatchMetrics) {
        let updated = link.receiving(metrics, now: Date())
        guard updated != link else { return }
        watchOnlyLink = updated
        guard metrics.isFinal else { return }
        AppLog.info("Apple Watch ended its recording of the workout handed over to a Mac", category: "watch")
        checkWatchOnlyLink()
    }

    /// The running workout ended away from here – on another device ("Start … Anyway" there) or it
    /// was deleted: said once (a toast once live mode closes), and the watch's recording of it ends
    /// with it – saved at the workout's end, or thrown away.
    private func endedAway(_ session: WorkoutSession, deleted: Bool, fromImport: Bool) {
        guard !deleted else {
            lastDiscardedSessionID = attachedID
            // Deletes made here let go of live mode first, so a deleted running workout was deleted
            // elsewhere. Its title can't be read any more (the model is gone).
            handOverNotice = "The workout was deleted on another device"
            return
        }
        let owner = LiveOwner(raw: session.liveDeviceID)
        let endedByOther = owner.map { $0.id != ThisDevice.installID } ?? false
        if endedByOther || fromImport {
            handOverNotice = LiveOwnership.endedMessage(title: session.title, owner: owner, localID: ThisDevice.installID, localKind: ThisDevice.kind)
        }
        guard watchIsRecording || watchExpected else { return }
        let ended: WatchOnlyLink.SyncedWorkout = session.status.isPerformed ? .performed(endedAt: session.endedAt) : .notDone
        switch WatchOnlyLink.step(for: ended, recordingSince: preStart?.segmentStartedAt ?? session.startedAt,
                                  localID: ThisDevice.installID, now: Date()) {
        case .end(let at):
            // The watch ends its recording there (`WatchRecordingEnd.verdict`), not now.
            lastFinished = WatchFinishSummary(sessionID: session.id, title: session.title, finishedAt: at,
                                              durationSeconds: session.accumulatedSeconds, completedSets: session.doneSetCount,
                                              totalSets: session.setCount, energyKcal: session.energyKcal > 0 ? session.energyKcal : nil)
        case .discard:
            lastDiscardedSessionID = session.id
        case .keep:
            break
        }
    }
}
