import Foundation
import SwiftUI
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
        /// Loads that went up against the template ("Deadlift 100 → 105 kg").
        var loadChanges: [String] = []
        /// A workout without a template that could become one.
        var canSaveAsTemplate = false
        var kind: WorkoutKind = .gym
        /// The stretch routine that fits what was trained (offered on the finish screen).
        var coolDown: Routine? = nil
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
    @ObservationIgnored private var bestWeights: [String: Double] = [:]
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
    /// Pace and rest before the last tick, so a mistaken tick can be undone cleanly.
    @ObservationIgnored private var beforeLastTick: (setID: UUID, pace: PaceTracker, restBeforeNext: Double, currentRef: WorkoutContent.SetRef?, best: [String: Double])?
    /// The exercise done off plan last (a second set on it adopts it quietly).
    @ObservationIgnored private var lastOffPlanItemID: UUID?
    /// "Not in this workout" on the feedback card.
    @ObservationIgnored private var skipFeedbackThisWorkout = false
    /// While paused: what was left of the rest and of a timed set.
    @ObservationIgnored private var pausedRest: (remaining: Double, total: Int)?
    @ObservationIgnored private var pausedTimed: (remaining: Double, setID: UUID)?
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var pendingHealthSessionID: UUID?
    @ObservationIgnored private var pendingEffort = 0
    /// Tells the watch to throw away its Health recording for this session.
    @ObservationIgnored private var lastDiscardedSessionID: UUID?

    init(store: GeorgeStore, health: HealthKitManager, watch: PhoneWatchConnector, library: ExerciseLibrary) {
        self.store = store
        self.health = health
        self.watch = watch
        self.library = library
        watch.onCommand = { [weak self] envelope in self?.handle(envelope) }
        watch.onMetrics = { [weak self] metrics in self?.handle(metrics) }
        watch.snapshotProvider = { [weak self] in
            self?.makeSnapshot() ?? WatchSnapshot(templates: [], upcoming: [], streak: nil, live: nil, unit: .kg)
        }
    }

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
        guard session == nil, let active = store.activeSession else { return }
        guard UserDefaults.standard.string(forKey: Prefs.liveSessionID) == active.id.uuidString else { return }
        attach(active, restoring: true)
        PhoneWorkoutSession.shared.begin(kind: active.kind, watchWillRecord: watch.isPaired && watch.isWatchAppInstalled)
        syncWatch()
        // Came back within half an hour of the last set: straight back into live mode.
        if let last = content.allItems.flatMap(\.sets).compactMap(\.doneAt).max() ?? active.startedAt,
           Date().timeIntervalSince(last) < 30 * 60 {
            isPresented = true
        }
    }

    /// A workout that runs on another device (synced through iCloud) – shown read-only with "Continue here".
    var workoutOnOtherDevice: WorkoutSession? {
        guard session == nil, let active = store.activeSession,
              UserDefaults.standard.string(forKey: Prefs.liveSessionID) != active.id.uuidString else { return nil }
        return active
    }

    /// "Continue here": this device takes over the workout running elsewhere.
    func continueHere(_ other: WorkoutSession) {
        UserDefaults.standard.set(other.id.uuidString, forKey: Prefs.liveSessionID)
        attach(other, restoring: true)
        PhoneWorkoutSession.shared.begin(kind: other.kind, watchWillRecord: watch.isPaired && watch.isWatchAppInstalled)
        isPresented = true
        syncWatch()
    }

    /// The synced copy says the workout ended elsewhere: let go of it here.
    func syncedStatusChanged() {
        guard let session, session.status != .active, !isFinishing else { return }
        AppLog.info("Workout ended on another device", category: "workout")
        detach()
    }

    private func attach(_ newSession: WorkoutSession, restoring: Bool = false) {
        resetTransientState()
        session = newSession
        content = newSession.content
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
            restBeforeNext = Double(content.restAfter(ref, defaultRest: store.settings.defaultRestSeconds) ?? 0)
        }
        // A set that was started before the app closed keeps running.
        if let set = currentSet, let started = set.startedAt, !set.isDone {
            pace.seed(lastSetAt: lastDone, startedAt: started)
            if let item = currentItem, item.mode == .time, let seconds = set.targetSeconds ?? set.seconds {
                let total = Double(seconds) * (item.perSide ? 2 : 1)
                let left = total - Date().timeIntervalSince(started)
                if left > 1 { startTimedSet(seconds: seconds, setID: set.id, startedAt: started, perSide: item.perSide, silent: true) }
            }
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
        if resume?.isPaused == true || newSession.resumedAt == nil {
            pausedRest = resume?.pausedRestRemaining.map { (remaining: $0, total: resume?.restTotal ?? 0) }
            pausedAt = resume?.pausedAt ?? Date()
        }
        plannedDuration = WorkoutPace.plannedSeconds(of: content, defaultRest: store.settings.defaultRestSeconds)
        effortAsked = 0
        halfwayAnnounced = content.completedSets * 2 >= max(1, content.totalSets)
        bestWeights = Self.bestWeights(in: SessionHistory.shared.records(store).filter { $0.id != newSession.id })
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
        persistTask?.cancel()
        persistTask = nil
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
            Haptics.warning()
            pendingStart = target
            return
        }
        perform(target)
    }

    /// "Keep going with …": the running workout stays, live mode opens.
    func keepCurrentWorkout() {
        pendingStart = nil
        isPresented = true
    }

    /// "Finish … and start": the running workout is saved properly (Apple Health included), then
    /// the new one starts.
    func finishCurrentAndStart() async {
        guard let target = pendingStart else { return }
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
        case .session(let session): start(session)
        case .empty(let program, let kind, let rescue): startEmpty(program: program, kind: kind, rescue: rescue)
        }
    }

    func start(_ newSession: WorkoutSession, present: Bool = true) {
        let previousDate = newSession.date
        AppLog.info("Workout started (\(newSession.content.exerciseCount) exercises, \(newSession.kind.rawValue))", category: "workout")
        if let session, session.id != newSession.id {
            // Only reached from code paths that already asked (demo screens, "end and start").
            stopCurrentAsPartial()
        }
        let now = Date()
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
        }
        // Already answered "how's your energy" on Today? Use it instead of asking again.
        if newSession.energyBefore == 0,
           let today = store.fetchEnergy().last(where: { $0.source == "today" && Calendar.current.isDateInToday($0.date) }) {
            newSession.energyBefore = today.level
        }
        store.save()
        UserDefaults.standard.set(newSession.id.uuidString, forKey: Prefs.liveSessionID)
        attach(newSession)
        heartRate = nil
        watchAverageHeartRate = nil
        watchEnergy = nil
        watchIsRecording = false
        if present { isPresented = true }
        #if os(iOS)
        if watch.isPaired && watch.isWatchAppInstalled {
            health.startWatchWorkout(kind: newSession.kind)
        }
        #endif
        syncWatch()
        Haptics.heavy()
        PhoneWorkoutSession.shared.begin(kind: newSession.kind, watchWillRecord: watch.isPaired && watch.isWatchAppInstalled)
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
        guard let session, session.resumedAt != nil else { return }
        flushPersist()
        let now = Date()
        session.accumulatedSeconds = session.elapsedSeconds()
        session.resumedAt = nil
        pausedAt = now
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
        guard let session, session.resumedAt == nil else { return }
        let now = Date()
        session.resumedAt = now
        if let pausedAt { pace.shift(by: now.timeIntervalSince(pausedAt)) }
        pausedAt = nil
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
        guard session != nil, let item = currentItem, let set = currentSet, !set.isDone, pace.startedAt == nil else { return }
        if isPaused { resume() }
        let now = Date()
        if restEndsAt != nil { cancelRest() }
        pace.setStarted(at: now, plannedRest: restBeforeNext)
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
                if perSide { self?.timedSide = side }
                if side == 2 {
                    Haptics.heavy()
                    VoiceCoach.shared.say("Switch sides.", cue: .timedSet, context: setID, priority: .high)
                }
                if seconds >= 40 && !flow {
                    await sleep(until: sideStart.addingTimeInterval(Double(seconds) / 2))
                    guard !Task.isCancelled else { return }
                    VoiceCoach.shared.say("Halfway.", cue: .timedSet, context: setID)
                }
                if seconds >= 20 && !flow && side == sides {
                    await sleep(until: sideEnd.addingTimeInterval(-10))
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
            self.toggleSet(setID)
        }
    }

    func toggleSet(_ id: UUID) {
        guard session != nil else { return }
        if isPaused { resume() }
        let ref = content.locate(setID: id)
        let wasCurrent = id == currentSet?.id
        // Another exercise than the planned one (a superset counts as one): done anyway, but the
        // plan keeps its place – unless it's the second set in a row there: then George follows.
        var offPlan = !wasCurrent && ref != nil && currentRef != nil && ref?.blockIndex != currentRef?.blockIndex
        let adoptOffPlan = offPlan && ref.flatMap { content.item(at: $0)?.id } == lastOffPlanItemID && content.set(id: id)?.isDone == false
        if adoptOffPlan { offPlan = false }
        let snapshot = (setID: id, pace: pace, restBeforeNext: restBeforeNext, currentRef: currentRef, best: bestWeights)
        let nowDone = content.toggleSet(id: id)
        if nowDone, let ref {
            let now = Date()
            GeorgeTips.firstSetDone()
            beforeLastTick = snapshot
            lastCompletedSetID = id
            if let item = content.item(at: ref), let set = content.set(at: ref) {
                if set.startedAt == nil, wasCurrent, let started = pace.startedAt {
                    content.updateSet(id: id) { $0.startedAt = started }
                }
                if wasCurrent, item.mode == .time, timedSetEndsAt != nil, let started = pace.startedAt {
                    // A timed set ticked early keeps the time it really took.
                    let took = Int(now.timeIntervalSince(started).rounded()) / (item.perSide ? 2 : 1)
                    if took > 0 { content.updateSet(id: id) { $0.seconds = took } }
                }
                let work = PaceTracker.workSeconds(for: set, mode: item.mode) * (item.perSide ? 2 : 1)
                if !wasCurrent { pace.setUndone(previous: pace.lastSetAt) }
                pace.setCompleted(at: now, plannedRest: pace.lastSetAt == nil ? nil : restBeforeNext, workSeconds: work)
                lastCompletedItemID = item.id
                undoableTick = UndoableTick(setID: id, text: "\(item.name) · \(CoachScript.setPosition(set, in: item)) done")
            }
            timedSetTask?.cancel()
            timedSetEndsAt = nil
            timedSide = nil
            nudgesGiven = 0
            completionPulse += 1
            Haptics.success()
            // On plan: the thread moves on. Off plan: it stays where it was (still the next open set).
            let next = offPlan ? (currentRef.flatMap { content.set(at: $0)?.isDone == false ? $0 : nil } ?? content.nextPendingSet(after: ref))
                               : content.nextPendingSet(after: ref)
            let autoRest = UserDefaults.standard.object(forKey: Prefs.autoRest) as? Bool ?? true
            let rest = next != nil ? content.restAfter(ref, defaultRest: store.settings.defaultRestSeconds) : nil
            restBeforeNext = Double(rest ?? 0)
            currentRef = next
            if !offPlan, let next, let nextItem = content.item(at: next) {
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
            if autoRest, let rest {
                startRest(rest)
            } else if next != nil && !offPlan {
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
                beforeLastTick = nil
                lastCompletedSetID = nil
            } else {
                pace.setUndone(previous: content.allItems.flatMap(\.sets).compactMap(\.doneAt).max())
            }
            undoableTick = nil
            if let again = content.locate(setID: id) {
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
        let remaining = WorkoutPace.remainingSeconds(in: content, defaultRest: store.settings.defaultRestSeconds)
        var projected = elapsed(at: date) + remaining
        if let restEndsAt { projected += max(0, restEndsAt.timeIntervalSince(date)) }
        let waiting = phase == .ready ? pace.waitingDelta(at: date, plannedRest: restBeforeNext) : nil
        if let waiting, waiting > 0 { projected += waiting }
        return PaceSnapshot(
            plannedRest: restBeforeNext, waitingDelta: waiting, totalDelta: pace.totalDelta + max(0, waiting ?? 0),
            averageDelta: pace.averageDelta, lastGap: pace.lastGap, gaps: pace.gaps,
            plannedDuration: plannedDuration, projectedDuration: projected,
            tips: WorkoutPace.tips(for: pace, restRange: store.profile.restSeconds)
        )
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
            store.context.insert(EnergyCheckIn(level: level, source: "workout", sessionID: session.id))
            setIntensity(CoachIntensity.from(energy: level))
            if level <= 2 {
                VoiceCoach.shared.say("Easy does it today. Every set counts.", cue: .motivation)
            }
        } else {
            session.energyBefore = -1
        }
        store.save()
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
        updateSet(request.setID) { $0.rpe = EffortPrompt.rpe(forRepsInReserve: rir) }
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
           let best = bestWeights[item.exerciseKey], weight > best {
            bestWeights[item.exerciseKey] = weight
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
        content.updateSet(id: id, body)
        persist(debounced: true)
    }

    /// Any structural change made mid-workout (add/remove/swap exercises, add sets, reorder). The
    /// current set is kept by id – an edit elsewhere never moves "now" to something else.
    func edit(_ body: (inout WorkoutContent) -> Void) {
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
            VoiceCoach.shared.moveOn(to: currentSet?.id)
        }
        if let focusedItemID, content.item(id: focusedItemID) == nil {
            self.focusedItemID = currentItem?.id
        }
        plannedDuration = WorkoutPace.plannedSeconds(of: content, defaultRest: store.settings.defaultRestSeconds)
        persist()
    }

    /// Replace the whole content (after editing in the full editor).
    func replaceContent(_ newContent: WorkoutContent) {
        edit { $0 = newContent }
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
    func dropWeight(repsDone: Int, newWeightKg: Double, applyToRemaining: Bool) {
        guard let item = currentItem, let set = currentSet else { return }
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
        syncLive()
    }

    /// Saves the live content. Never on the undo stack, no revision bump (dashboards refresh at
    /// start/finish). `debounced` waits for a pause in typing.
    private func persist(debounced: Bool = false) {
        guard let session else { return }
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
        let content = content
        store.saveWithoutUndo { session.content = content }
        saveResume()
        syncLive()
    }

    /// Saves a pending value edit now (before ticks, starts, finishing, leaving the app).
    func flushPersist() {
        guard persistTask != nil else { return }
        persist()
    }

    /// Where the workout stands, so a relaunch picks up the rest, the started set and the plan's place.
    private func saveResume() {
        guard let session else { return }
        LiveResume(
            currentSetID: currentSet?.id, focusedItemID: focusedItemID, restEndsAt: restEndsAt, restTotal: restTotal,
            restBeforeNext: restBeforeNext, nudgesGiven: nudgesGiven, isPaused: isPaused,
            pausedRestRemaining: pausedRest?.remaining, pausedAt: pausedAt
        ).save(for: session.id)
    }

    // MARK: Rest

    func startRest(_ seconds: Int) {
        guard seconds > 0 else { return }
        restTotal = seconds
        restEndsAt = Date().addingTimeInterval(Double(seconds))
        scheduleRestTask()
        scheduleRestNotification()
        saveResume()
        syncLive()
        let next = currentItem.flatMap { item in currentSet.map { (item: item, set: $0) } }
        if isFlow, let next {
            // Calm flow: just what's next.
            let hold = next.set.targetSeconds.map { ", \(CoachScript.duration($0))" } ?? ""
            VoiceCoach.shared.say("Next: \(next.item.name)\(hold).", cue: .restStart, context: currentSet?.id)
            return
        }
        let same = next?.item.id == lastCompletedItemID
        VoiceCoach.shared.say(CoachScript.restStart(seconds: seconds, next: next, sameExercise: same), cue: .restStart, context: currentSet?.id)
    }

    func addRest(_ seconds: Int) {
        guard let restEndsAt else {
            startRest(seconds)
            return
        }
        self.restEndsAt = restEndsAt.addingTimeInterval(Double(seconds))
        restTotal += seconds
        scheduleRestTask()
        scheduleRestNotification()
        saveResume()
        syncLive()
    }

    /// Ends the rest now (the set becomes due).
    func skipRest() {
        cancelRest()
        syncLive()
    }

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
        saveResume()
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
        if let next {
            content.body = "Now: \(next.item.name) · \(next.set.label(mode: next.item.mode, unit: unit))"
        } else {
            content.body = "Time for the next set."
        }
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

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Finish

    /// Ends the workout, estimates energy, saves to Apple Health and returns a summary.
    func finish(effort: Int, notes: String?, showSummary: Bool = true) async {
        guard let session, !isFinishing else { return }
        AppLog.info("Workout finished (\(content.completedSets)/\(content.totalSets) sets)", category: "workout")
        isFinishing = true
        defer { isFinishing = false }
        flushPersist()
        cancelRest()
        timedSetTask?.cancel()
        let now = Date()
        session.accumulatedSeconds = session.elapsedSeconds(at: now)
        session.resumedAt = nil
        session.endedAt = now
        session.content = content
        // A workout without sets (tennis, a run, "just track time") is complete when it's finished.
        session.status = content.isComplete || content.totalSets == 0 ? .completed : .partial
        session.effort = effort
        if let notes, !notes.isEmpty {
            session.notes = session.notes.isEmpty ? notes : session.notes + "\n" + notes
        }
        let settings = store.settings
        let bodyMass = health.latestBodyMassKg ?? settings.bodyMassKg
        let estimated = EnergyEstimator.kilocalories(kind: session.kind, durationSeconds: session.accumulatedSeconds, bodyMassKg: bodyMass, effort: effort)
        session.energyKcal = estimated
        var averageHeartRate = watchAverageHeartRate
        var measuredEnergy = watchEnergy
        let recordedOnWatch = watchIsRecording
        session.recordedOnWatch = recordedOnWatch
        store.save()

        let finishedID = session.id
        let start = session.startedAt ?? now.addingTimeInterval(-session.accumulatedSeconds)
        var savedToHealth = false
        if recordedOnWatch {
            // The watch saves the HKWorkout (with heart rate); we attach effort when its id arrives.
            pendingHealthSessionID = finishedID
            pendingEffort = effort
            savedToHealth = true
        } else if settings.saveToHealth && health.isAvailable {
            if let hr = await health.heartRate(from: start, to: now) {
                averageHeartRate = hr.average
                store.recordHealthMetrics(sessionID: finishedID, averageHeartRate: hr.average, maxHeartRate: hr.max, activeEnergy: nil)
            }
            let request = HealthKitManager.SaveRequest(
                sessionID: finishedID, title: session.title, kind: session.kind, start: start, end: now,
                activeSeconds: session.accumulatedSeconds, energyKcal: session.energyKcal, effort: effort,
                exercises: content.allItems.filter { $0.completedSets > 0 }.map(\.name),
                muscles: Array(Set(content.allItems.filter { $0.completedSets > 0 }.flatMap { library.muscles(for: $0) })).sorted(),
                completedSets: content.completedSets, volumeKg: content.volumeKg
            )
            if let workoutID = await health.saveWorkout(request) {
                session.healthWorkoutID = workoutID.uuidString
                savedToHealth = true
            }
        }
        if recordedOnWatch {
            store.recordHealthMetrics(sessionID: finishedID, averageHeartRate: averageHeartRate, maxHeartRate: nil, activeEnergy: measuredEnergy)
        } else {
            measuredEnergy = nil
        }
        store.save()

        let history = store.performedRecords()
        let record = session.record()
        let records = StatsEngine.newRecords(in: record, comparedTo: history)
        let template = store.template(id: session.templateID)
        let loadChanges = template.map { content.loadChanges(comparedTo: $0.content, unit: unit) } ?? []
        let canUpdate = settings.askToUpdateTemplate && (store.sessionDiffersFromTemplate(session) || !loadChanges.isEmpty)
        let templateOf = Dictionary(store.fetchSessions().map { ($0.id, $0.templateID) }, uniquingKeysWith: { a, _ in a })
        let comparison = StatsEngine.compare(record, templateID: session.templateID, previous: history) { id in
            templateOf[id] ?? nil
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
            kind: session.kind, coolDown: coolDown
        )
        lastFinished = WatchFinishSummary(
            sessionID: finishedID, title: session.title, finishedAt: now, durationSeconds: finished.duration,
            completedSets: finished.completedSets, totalSets: finished.totalSets, energyKcal: finished.energyKcal,
            averageHeartRate: finished.averageHeartRate, records: records.count,
            streakHeadline: store.streakSummary(healthEntries: health.externalWorkouts).headline
        )
        detach()
        store.bump()
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

    /// Throw the running session away.
    func discard() {
        guard let session, !isFinishing else { return }
        AppLog.info("Workout discarded", category: "workout")
        cancelRest()
        if watchIsRecording { lastDiscardedSessionID = session.id }
        // A session that was planned earlier goes back to the plan; one created by "Start" is deleted.
        let wasPlannedEarlier = session.createdAt < (session.startedAt ?? Date()).addingTimeInterval(-120)
        if content.completedSets == 0 && wasPlannedEarlier {
            session.content = content
            session.status = .planned
            session.resumedAt = nil
            session.accumulatedSeconds = 0
            session.startedAt = nil
        } else {
            store.delete(session)
        }
        store.save()
        detach()
        store.bump()
    }

    private func detach() {
        if let session { LiveResume.clear(for: session.id) }
        UserDefaults.standard.removeObject(forKey: Prefs.liveSessionID)
        resetTransientState()
        undoTask?.cancel()
        liveSyncTask?.cancel()
        LiveActivityBridge.shared.end(liveState())
        timedSetTask?.cancel()
        timedSetEndsAt = nil
        offPlanTask?.cancel()
        offPlanNotice = nil
        PhoneWorkoutSession.shared.end()
        VoiceCoach.shared.isMuted = false
        isVoiceMuted = false
        nudgeTask?.cancel()
        restWarningTask?.cancel()
        celebrationTask?.cancel()
        effortTask?.cancel()
        celebration = nil
        effortRequest = nil
        session = nil
        content = WorkoutContent()
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
            viewingExerciseID: isViewingElsewhere ? focusedItemID : nil
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
        let watchStreak = WatchStreak(
            weeks: streak.currentWeeks, doneDays: streak.thisWeek.workoutDays, goal: streak.thisWeek.goal,
            credits: streak.credits, headline: streak.headline, dots: streak.thisWeek.dots.map(\.didWorkout)
        )
        return WatchSnapshot(templates: watchTemplates, upcoming: upcoming, streak: watchStreak, live: liveState(), unit: unit,
                             discardedSessionID: lastDiscardedSessionID, lastFinished: lastFinished)
    }

    func syncWatch() {
        let snapshot = makeSnapshot()
        #if os(iOS)
        watch.sendSnapshot(snapshot)
        if let live = liveState() { watch.sendLive(live) }
        #endif
        // Widgets and the Lock Screen (deduplicated; also clears a Live Activity left over from a killed app).
        WidgetBridge.write(snapshot: snapshot)
    }

    private func syncLive() {
        lastLiveSync = Date()
        liveSyncTask?.cancel()
        liveSyncTask = nil
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
        guard envelope.isFresh(activeSessionID: session?.id) else {
            AppLog.info("Ignored a stale watch command", category: "watch")
            syncWatch()
            return
        }
        perform(envelope.command)
    }

    /// Runs a live command (watch, Live Activity buttons, App Intents).
    func perform(_ command: WatchCommand) {
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
            guard session != nil else { return }
            Task { await finish(effort: effort ?? session?.kind.defaultEffort ?? 6, notes: nil) }
        case .discard: discard()
        case .startTemplate(let id):
            guard session == nil else { return syncWatch() }
            if let template = store.template(id: id) { start(template: template) }
        case .startSession(let id):
            guard session == nil else { return syncWatch() }
            if let target = store.session(id: id) { start(target) }
        case .requestSnapshot: syncWatch()
        case .completeSet(let id, let reps, let weightKg):
            if reps != nil || weightKg != nil {
                content.updateSet(id: id) { set in
                    if let reps { set.reps = reps }
                    if let weightKg { set.weight = weightKg }
                }
            }
            if content.set(id: id)?.isDone == false { toggleSet(id) } else { persist() }
        case .dropWeight(let setID, let repsDone, let newWeightKg):
            if currentSet?.id != setID { makeCurrent(setID: setID) }
            dropWeight(repsDone: repsDone, newWeightKg: newWeightKg, applyToRemaining: true)
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
        persist()
    }

    private func handle(_ metrics: WatchMetrics) {
        if metrics.healthWorkoutID == nil {
            watchIsRecording = true
        }
        if let hr = metrics.heartRate { heartRate = hr }
        if let avg = metrics.averageHeartRate { watchAverageHeartRate = avg }
        if let energy = metrics.activeEnergy { watchEnergy = energy }
        if let workoutID = metrics.healthWorkoutID {
            // Only attach to a session we finished and are waiting on — never to one started afterwards.
            if let targetID = pendingHealthSessionID, let target = store.session(id: targetID) {
                target.healthWorkoutID = workoutID.uuidString
                target.recordedOnWatch = true
                store.recordHealthMetrics(sessionID: targetID, averageHeartRate: metrics.averageHeartRate, maxHeartRate: nil, activeEnergy: metrics.activeEnergy)
                let effort = pendingEffort > 0 ? pendingEffort : target.effort
                Task { await health.relateEffort(effort, toWorkoutWithID: workoutID) }
            }
            pendingHealthSessionID = nil
            pendingEffort = 0
        }
    }
}
