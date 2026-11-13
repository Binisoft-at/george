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
    @ObservationIgnored private var pendingHealthSessionID: UUID?
    @ObservationIgnored private var pendingEffort = 0
    /// Tells the watch to throw away its Health recording for this session.
    @ObservationIgnored private var lastDiscardedSessionID: UUID?

    init(store: GeorgeStore, health: HealthKitManager, watch: PhoneWatchConnector, library: ExerciseLibrary) {
        self.store = store
        self.health = health
        self.watch = watch
        self.library = library
        watch.onCommand = { [weak self] command in self?.handle(command) }
        watch.onMetrics = { [weak self] metrics in self?.handle(metrics) }
        watch.snapshotProvider = { [weak self] in
            self?.makeSnapshot() ?? WatchSnapshot(templates: [], upcoming: [], streak: nil, live: nil, unit: .kg)
        }
    }

    var isActive: Bool { session != nil }
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

    /// Re-attach to a session that was running when the app was closed.
    func restore() {
        guard session == nil, let active = store.activeSession else { return }
        attach(active)
    }

    private func attach(_ newSession: WorkoutSession) {
        session = newSession
        content = newSession.content
        currentRef = content.nextPendingSet()
        focusedItemID = currentRef.flatMap { content.item(at: $0)?.id }
        setIdleTimer(disabled: true)
        intensity = newSession.energyBefore > 0 ? CoachIntensity.from(energy: newSession.energyBefore) : .normal
        pace = PaceTracker(slack: intensity.paceSlack)
        if let last = content.allItems.flatMap(\.sets).compactMap(\.doneAt).max() {
            pace.setCompleted(at: last, plannedRest: nil, workSeconds: 0)
        }
        plannedDuration = WorkoutPace.plannedSeconds(of: content, defaultRest: store.settings.defaultRestSeconds)
        timedSetEndsAt = nil
        effortAsked = 0
        halfwayAnnounced = content.completedSets * 2 >= max(1, content.totalSets)
        bestWeights = Self.bestWeights(in: store.performedRecords().filter { $0.id != newSession.id })
        startNudges()
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

    func start(_ newSession: WorkoutSession, present: Bool = true) {
        AppLog.info("Workout started (\(newSession.content.exerciseCount) exercises, \(newSession.kind.rawValue))", category: "workout")
        if let session, session.id != newSession.id {
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
            if !newSession.templateName.isEmpty {
                newSession.title = store.title(for: newSession.templateName, on: now, excluding: newSession.id)
            }
        }
        // Already answered "how's your energy" on Today? Use it instead of asking again.
        if newSession.energyBefore == 0,
           let today = store.fetchEnergy().last(where: { $0.source == "today" && Calendar.current.isDateInToday($0.date) }) {
            newSession.energyBefore = today.level
        }
        store.save()
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
        self.session = nil
    }

    func pause() {
        guard let session, session.resumedAt != nil else { return }
        session.accumulatedSeconds = session.elapsedSeconds()
        session.resumedAt = nil
        store.save()
        syncLive()
    }

    func resume() {
        guard let session, session.resumedAt == nil else { return }
        session.resumedAt = Date()
        store.save()
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

    /// Target of the current set when it's timed (seconds), else nil.
    var timedTarget: Int? {
        guard let item = currentItem, let set = currentSet, item.mode == .time else { return nil }
        return set.targetSeconds ?? set.seconds
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
            startTimedSet(seconds: seconds, setID: set.id, startedAt: now)
        }
        persist()
    }

    private func startTimedSet(seconds: Int, setID: UUID, startedAt: Date) {
        timedSetTask?.cancel()
        let end = startedAt.addingTimeInterval(Double(seconds))
        timedSetEndsAt = end
        VoiceCoach.shared.say("\(CoachScript.duration(seconds)). Go.", cue: .timedSet, context: setID)
        timedSetTask = Task { [weak self] in
            func sleep(until date: Date) async {
                let delay = date.timeIntervalSinceNow
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
            if seconds >= 40 {
                await sleep(until: startedAt.addingTimeInterval(Double(seconds) / 2))
                guard !Task.isCancelled else { return }
                VoiceCoach.shared.say("Halfway.", cue: .timedSet, context: setID)
            }
            if seconds >= 20 {
                await sleep(until: end.addingTimeInterval(-10))
                guard !Task.isCancelled else { return }
                VoiceCoach.shared.say("10 seconds.", cue: .countdown, context: setID)
            }
            await sleep(until: end.addingTimeInterval(-3))
            guard !Task.isCancelled else { return }
            VoiceCoach.shared.say("3, 2, 1.", cue: .countdown, context: setID, priority: .high)
            await sleep(until: end)
            guard !Task.isCancelled, let self, self.currentSet?.id == setID, self.currentSet?.isDone == false else { return }
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
        // plan keeps its place.
        let offPlan = !wasCurrent && ref != nil && currentRef != nil && ref?.blockIndex != currentRef?.blockIndex
        let nowDone = content.toggleSet(id: id)
        if nowDone, let ref {
            let now = Date()
            lastCompletedSetID = id
            if let item = content.item(at: ref), let set = content.set(at: ref) {
                if set.startedAt == nil, wasCurrent, let started = pace.startedAt {
                    content.updateSet(id: id) { $0.startedAt = started }
                }
                if wasCurrent, item.mode == .time, timedSetEndsAt != nil, let started = pace.startedAt {
                    // A timed set ticked early keeps the time it really took.
                    let took = Int(now.timeIntervalSince(started).rounded())
                    if took > 0 { content.updateSet(id: id) { $0.seconds = took } }
                }
                let work = PaceTracker.workSeconds(for: set, mode: item.mode) * (item.perSide ? 2 : 1)
                if !wasCurrent { pace.setUndone(previous: pace.lastSetAt) }
                pace.setCompleted(at: now, plannedRest: pace.lastSetAt == nil ? nil : restBeforeNext, workSeconds: work)
                lastCompletedItemID = item.id
            }
            timedSetTask?.cancel()
            timedSetEndsAt = nil
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
                if focusedItemID == nil || focusedItemID == content.item(at: ref)?.id {
                    focusedItemID = nextItem.id
                }
            }
            VoiceCoach.shared.moveOn(to: currentSet?.id)
            if offPlan, let item = content.item(at: ref), let set = content.set(at: ref) {
                noteOffPlan(item: item, set: set)
            } else {
                clearOffPlan()
            }
            celebrate(afterSetAt: ref)
            if autoRest, let rest {
                startRest(rest)
            } else if next != nil && !offPlan {
                announceSetUp(isFirst: false)
            }
            askForFeedbackIfUseful(afterSet: id)
        } else {
            Haptics.tap()
            content.updateSet(id: id) { $0.startedAt = nil }
            pace.setUndone(previous: content.allItems.flatMap(\.sets).compactMap(\.doneAt).max())
            currentRef = content.nextPendingSet()
            VoiceCoach.shared.moveOn(to: currentSet?.id)
        }
        persist()
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
    func answerFeedback(repsInReserve rir: Int?, fatigue: Double?) {
        effortTask?.cancel()
        if let request = effortRequest {
            if let rir {
                updateSet(request.setID) { $0.rpe = EffortPrompt.rpe(forRepsInReserve: rir) }
                AppLog.info("Effort logged: \(rir) reps in reserve", category: "workout")
            }
            if let fatigue {
                edit { $0.updateItem(id: request.itemID) { $0.fatigue = fatigue } }
                AppLog.info("Fatigue logged: \(Int(fatigue * 100)) %", category: "workout")
            }
        }
        withAnimation(.snappy) { effortRequest = nil }
    }

    func answerEffort(repsInReserve rir: Int?) {
        answerFeedback(repsInReserve: rir, fatigue: nil)
    }

    private func askForFeedbackIfUseful(afterSet id: UUID) {
        guard let ref = content.locate(setID: id), let item = content.item(at: ref), let set = content.set(at: ref),
              item.isComplete, item.sets.last?.id == set.id || item.sets.allSatisfy(\.isDone) else { return }
        let asksReps = CoachPrefs.askEffort && EffortPrompt.shouldAsk(after: set, in: item, askedSoFar: effortAsked, limit: 99)
        let asksFatigue = CoachPrefs.askFatigue && set.kind != .warmup
        guard asksReps || asksFatigue else { return }
        if asksReps { effortAsked += 1 }
        let muscles = analyticsMuscles(item)
        withAnimation(.snappy) {
            effortRequest = EffortRequest(setID: id, itemID: item.id, itemName: item.name, muscles: muscles, asksReps: asksReps)
        }
        effortTask?.cancel()
        effortTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.effortRequest = nil }
        }
    }

    private func analyticsMuscles(_ item: WorkoutItem) -> String {
        let names = item.muscles.isEmpty ? library.muscles(for: item) : item.muscles
        return names.prefix(2).joined(separator: ", ")
    }

    private func celebrate(afterSetAt ref: WorkoutContent.SetRef) {
        guard let item = content.item(at: ref), let set = content.set(at: ref) else { return }
        let style = CoachPrefs.motivation
        var moment: Celebration?
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
        guard session != nil, !isPaused, phase == .ready, CoachPrefs.paceNudges, intensity != .calm,
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
    func primaryAction() {
        if phase != .working, CoachPrefs.startButton, currentSet != nil {
            startSet()
        } else {
            completeCurrentSet()
        }
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

    func updateSet(_ id: UUID, _ body: (inout WorkoutSet) -> Void) {
        content.updateSet(id: id, body)
        persist()
    }

    /// Any structural change made mid-workout (add/remove/swap exercises, add sets, reorder).
    func edit(_ body: (inout WorkoutContent) -> Void) {
        body(&content)
        content.normalizeBlocks()
        if let currentRef, content.set(at: currentRef) == nil || content.set(at: currentRef)?.isDone == true {
            self.currentRef = content.nextPendingSet()
        } else if currentRef == nil {
            currentRef = content.nextPendingSet()
        }
        if let focusedItemID, content.item(id: focusedItemID) == nil {
            self.focusedItemID = currentItem?.id
        }
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
        Haptics.tap()
        if let leaving, !leaving.isComplete {
            VoiceCoach.shared.say("\(offset > 0 ? "Skipping" : "Back") to \(item.name). \(leaving.name) stays open for later.", cue: .offPlan, context: currentSet?.id)
        }
        announceSetUp(isFirst: false)
    }

    /// Previous / next exercise from the panel (kept for older call sites).
    func focusExercise(offset: Int) { moveThread(by: offset) }

    // MARK: Off plan

    private func noteOffPlan(item: WorkoutItem, set: WorkoutSet) {
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

    private func persist() {
        guard let session else { return }
        session.content = content
        store.save()
        syncLive()
    }

    // MARK: Rest

    func startRest(_ seconds: Int) {
        guard seconds > 0 else { return }
        restTotal = seconds
        restEndsAt = Date().addingTimeInterval(Double(seconds))
        scheduleRestTask()
        scheduleRestNotification()
        syncLive()
        let next = currentItem.flatMap { item in currentSet.map { (item: item, set: $0) } }
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
                guard !Task.isCancelled, self?.restEndsAt != nil else { return }
                Haptics.tap()
                VoiceCoach.shared.say("10 seconds.", cue: .countdown, context: setID)
            }
            if end.timeIntervalSinceNow > 4 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, end.timeIntervalSinceNow - 3.2) * 1_000_000_000))
                guard !Task.isCancelled, self?.restEndsAt != nil else { return }
                VoiceCoach.shared.say("3, 2, 1.", cue: .countdown, context: setID)
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

    private func restFinished() {
        guard restEndsAt != nil else { return }
        restEndsAt = nil
        Haptics.heavy()
        #if os(iOS)
        if CoachPrefs.sounds && !(CoachPrefs.voice && VoiceSettings.isOn(.go)) {
            AudioServicesPlaySystemSound(1007)
        }
        #endif
        let next = currentItem.flatMap { item in currentSet.map { (item: item, set: $0) } }
        VoiceCoach.shared.say(CoachScript.go(next: next, unit: unit), cue: .go, context: currentSet?.id, priority: .high)
        syncLive()
    }

    private func scheduleRestNotification() {
        guard let restEndsAt else { return }
        let center = UNUserNotificationCenter.current()
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
        Task {
            // Spoken "Go!" as the notification sound – heard even when the phone is locked.
            if let sound = await VoiceCoach.shared.notificationSound(for: goLine) {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
            }
            let remaining = restEndsAt.timeIntervalSinceNow
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
    func finish(effort: Int, notes: String?) async {
        AppLog.info("Workout finished (\(content.completedSets)/\(content.totalSets) sets)", category: "workout")
        guard let session else { return }
        restTask?.cancel()
        restEndsAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["george.rest"])
        let now = Date()
        session.accumulatedSeconds = session.elapsedSeconds(at: now)
        session.resumedAt = nil
        session.endedAt = now
        session.content = content
        session.status = content.isComplete ? .completed : .partial
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

        let records = StatsEngine.newRecords(in: session.record(), comparedTo: store.performedRecords())
        let canUpdate = settings.askToUpdateTemplate && store.sessionDiffersFromTemplate(session)
        let finished = FinishSummary(
            sessionID: finishedID, title: session.title, duration: session.accumulatedSeconds,
            completedSets: content.completedSets, totalSets: content.totalSets, volumeKg: content.volumeKg,
            energyKcal: (measuredEnergy ?? 0) > 0 ? (measuredEnergy ?? 0) : session.energyKcal,
            averageHeartRate: (averageHeartRate ?? 0) > 0 ? averageHeartRate : nil,
            records: records, canUpdateTemplate: canUpdate, templateName: session.templateName, savedToHealth: savedToHealth
        )
        detach()
        Haptics.success()
        VoiceCoach.shared.stop()
        VoiceCoach.shared.say("Workout complete! \(Int((finished.duration / 60).rounded())) minutes, \(finished.completedSets) sets. Well done.", cue: .summary, priority: .high)
        // Present the summary once the live view has finished dismissing.
        try? await Task.sleep(nanoseconds: 650_000_000)
        summary = finished
    }

    /// Throw the running session away.
    func discard() {
        AppLog.info("Workout discarded", category: "workout")
        guard let session else { return }
        restTask?.cancel()
        restEndsAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["george.rest"])
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
    }

    private func detach() {
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
            behindSeconds: pace.totalDelta, lastDeltaSeconds: pace.lastGap?.delta
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
        return WatchSnapshot(templates: watchTemplates, upcoming: upcoming, streak: watchStreak, live: liveState(), unit: unit, discardedSessionID: lastDiscardedSessionID)
    }

    func syncWatch() {
        #if os(iOS)
        watch.sendSnapshot(makeSnapshot())
        if let live = liveState() { watch.sendLive(live) }
        #endif
    }

    private func syncLive() {
        #if os(iOS)
        if let live = liveState() { watch.sendLive(live) }
        #endif
    }

    private func handle(_ command: WatchCommand) {
        switch command {
        case .toggleSet(let id): toggleSet(id)
        case .completeCurrentSet: completeCurrentSet()
        case .startSet: startSet()
        case .startRest(let seconds): startRest(seconds)
        case .addRest(let seconds): addRest(seconds)
        case .skipRest: skipRest()
        case .pause: pause()
        case .resume: resume()
        case .finish(let effort): Task { await finish(effort: effort ?? 0, notes: nil) }
        case .discard: discard()
        case .startTemplate(let id):
            if let template = store.template(id: id) { start(template: template) }
        case .startSession(let id):
            if let target = store.session(id: id) { start(target) }
        case .requestSnapshot: syncWatch()
        }
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
