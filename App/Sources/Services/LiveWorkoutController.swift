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

    /// "How many more reps could you have done?" after an exercise's last working set.
    struct EffortRequest: Identifiable, Equatable {
        let id = UUID()
        var setID: UUID
        var itemName: String
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
            pace.setCompleted(at: last, expectedGap: nil)
        }
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
        if let item = currentItem, let set = currentSet {
            VoiceCoach.shared.say("Let's go. First up: \(item.name), \(VoiceCoach.spoken(set, mode: item.mode, unit: unit)).")
        }
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

    // MARK: Sets

    func toggleSet(_ id: UUID) {
        guard session != nil else { return }
        if isPaused { resume() }
        let ref = content.locate(setID: id)
        let expected = expectedGap()
        let nowDone = content.toggleSet(id: id)
        if nowDone, let ref {
            lastCompletedSetID = id
            pace.setCompleted(at: Date(), expectedGap: pace.lastSetAt == nil ? nil : expected)
            nudgesGiven = 0
            completionPulse += 1
            lastCompletedItemID = content.item(at: ref)?.id
            Haptics.success()
            let next = content.nextPendingSet(after: ref)
            let autoRest = UserDefaults.standard.object(forKey: Prefs.autoRest) as? Bool ?? true
            let rest = next != nil ? content.restAfter(ref, defaultRest: store.settings.defaultRestSeconds) : nil
            restBeforeNext = Double(rest ?? 0)
            celebrate(afterSetAt: ref)
            currentRef = next
            if autoRest, let rest {
                startRest(rest)
            } else if let next, let item = content.item(at: next), let set = content.set(at: next) {
                VoiceCoach.shared.say("Next: \(item.name), \(VoiceCoach.spoken(set, mode: item.mode, unit: unit)).")
            }
            if let next, let nextItem = content.item(at: next) {
                // Follow along unless the user is looking at another exercise.
                if focusedItemID == nil || focusedItemID == content.item(at: ref)?.id {
                    focusedItemID = nextItem.id
                }
            }
            askForEffortIfUseful(afterSet: id)
        } else {
            Haptics.tap()
            pace.setUndone(previous: nil)
            currentRef = content.nextPendingSet()
        }
        persist()
    }

    // MARK: Coach

    /// Planned rest before the current set plus the time the set itself takes.
    func expectedGap() -> Double {
        guard let item = currentItem, let set = currentSet else { return restBeforeNext + 60 }
        return restBeforeNext + PaceTracker.workSeconds(for: set, mode: item.mode)
    }

    /// Seconds past the plan for the next set (0 while on time or resting).
    func overdueSeconds(at date: Date = Date()) -> Double {
        guard restEndsAt == nil, currentSet != nil else { return 0 }
        return pace.overdueSeconds(at: date, expectedGap: expectedGap())
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
                VoiceCoach.shared.say("Easy does it today. Every set counts.")
            }
        } else {
            session.energyBefore = -1
        }
        store.save()
    }

    func answerEffort(repsInReserve rir: Int?) {
        effortTask?.cancel()
        if let request = effortRequest, let rir {
            updateSet(request.setID) { $0.rpe = EffortPrompt.rpe(forRepsInReserve: rir) }
            AppLog.info("Effort logged: \(rir) reps in reserve", category: "workout")
        }
        withAnimation(.snappy) { effortRequest = nil }
    }

    private func askForEffortIfUseful(afterSet id: UUID) {
        guard CoachPrefs.askEffort, let ref = content.locate(setID: id), let item = content.item(at: ref), let set = content.set(at: ref),
              EffortPrompt.shouldAsk(after: set, in: item, askedSoFar: effortAsked) else { return }
        effortAsked += 1
        withAnimation(.snappy) { effortRequest = EffortRequest(setID: id, itemName: item.name) }
        effortTask?.cancel()
        effortTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.effortRequest = nil }
        }
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
            VoiceCoach.shared.say("New personal best! \(Format.number(unit.fromKilograms(weight))) \(unit == .kg ? "kilos" : "pounds").", interrupt: true)
            Haptics.heavy()
        } else if content.isComplete {
            moment = Celebration(kind: .allDone, title: "All sets done", subtitle: "Finish when you're ready", symbol: "flag.checkered")
            VoiceCoach.shared.say("That's every set. Great work – finish when you're ready.")
        } else if item.isComplete {
            let volume = item.sets.filter(\.isDone).reduce(0.0) { $0 + Double($1.effectiveReps ?? 0) * ($1.effectiveWeight ?? 0) }
            let detail = volume > 0 ? "\(item.completedSets) sets · \(Format.volume(volume, unit: unit))" : "\(item.completedSets) sets"
            moment = Celebration(kind: .exercise, title: "\(item.name) done", subtitle: detail, symbol: "checkmark.seal.fill")
            VoiceCoach.shared.say("\(item.name) done.")
        } else if !halfwayAnnounced, content.completedSets * 2 >= max(1, content.totalSets), content.totalSets >= 6 {
            halfwayAnnounced = true
            moment = Celebration(kind: .halfway, title: "Halfway there", subtitle: "\(content.completedSets) of \(content.totalSets) sets", symbol: "flame.fill")
            VoiceCoach.shared.say("Halfway there. Keep it up.")
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

    /// Gentle nudges when the next set is late: a tap on the wrist and a word, at most twice per gap.
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
        guard session != nil, !isPaused, restEndsAt == nil, CoachPrefs.paceNudges, intensity != .calm,
              CoachPrefs.motivation != .off, let item = currentItem, let set = currentSet else { return }
        let overdue = overdueSeconds()
        if nudgesGiven == 0, overdue > 0 {
            nudgesGiven = 1
            Haptics.warning()
            VoiceCoach.shared.say("Ready when you are: \(item.name), \(VoiceCoach.spoken(set, mode: item.mode, unit: unit)).")
        } else if nudgesGiven == 1, overdue > 90 {
            nudgesGiven = 2
            Haptics.warning()
            VoiceCoach.shared.say("Let's keep the momentum going.")
        }
    }

    func completeCurrentSet() {
        if let set = currentSet, !set.isDone {
            toggleSet(set.id)
        } else if let ref = content.nextPendingSet(), let set = content.set(at: ref) {
            toggleSet(set.id)
        }
    }

    /// Screenshots (`-DemoScreen live-mid` / `live-superset`): tick a few sets so momentum and the
    /// body figure show, without a rest timer or banner in the way.
    func demoProgress(sets: Int, focusSuperset: Bool) {
        for _ in 0..<sets { completeCurrentSet() }
        skipRest()
        celebrationTask?.cancel()
        celebration = nil
        effortRequest = nil
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

    func focus(itemID: UUID) {
        focusedItemID = itemID
        // Jump the "current set" to this exercise's first open set.
        if let loc = content.locate(itemID: itemID) {
            let item = content.blocks[loc.block].items[loc.item]
            if let s = item.sets.firstIndex(where: { !$0.isDone }) {
                currentRef = WorkoutContent.SetRef(blockIndex: loc.block, itemIndex: loc.item, setIndex: s)
            }
        }
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
        VoiceCoach.shared.say("Rest \(VoiceCoach.duration(seconds)).")
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

    func skipRest() {
        restTask?.cancel()
        restWarningTask?.cancel()
        restEndsAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["george.rest"])
        syncLive()
    }

    private func scheduleRestTask() {
        restTask?.cancel()
        restWarningTask?.cancel()
        guard let end = restEndsAt else { return }
        if CoachPrefs.voiceCountdown, end.timeIntervalSinceNow > 15 {
            restWarningTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, end.timeIntervalSinceNow - 10) * 1_000_000_000))
                guard !Task.isCancelled, self?.restEndsAt != nil else { return }
                Haptics.tap()
                VoiceCoach.shared.say("10 seconds.")
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
        if CoachPrefs.sounds && !CoachPrefs.voice {
            AudioServicesPlaySystemSound(1007)
        }
        #endif
        if let item = currentItem, let set = currentSet {
            VoiceCoach.shared.say("Go! \(item.name), \(VoiceCoach.spoken(set, mode: item.mode, unit: unit)).", interrupt: true)
        } else {
            VoiceCoach.shared.say("Rest is over.", interrupt: true)
        }
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
        if let currentItem, let currentSet {
            content.body = "Next: \(currentItem.name) · \(currentSet.label(mode: currentItem.mode, unit: unit))"
        } else {
            content.body = "Time for the next set."
        }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        center.add(UNNotificationRequest(identifier: "george.rest", content: content, trigger: trigger))
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
        VoiceCoach.shared.say("Workout complete! \(Int((finished.duration / 60).rounded())) minutes, \(finished.completedSets) sets. Well done.", interrupt: true)
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
            completedSets: content.completedSets, totalSets: content.totalSets
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
