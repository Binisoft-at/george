import Foundation
import HealthKit
import Observation
import GeorgeCore

/// Records the George workout as an Apple Health workout on the watch (heart rate, active energy)
/// and streams live metrics to the phone. The phone stays the source of truth for the workout itself:
/// a live state from the phone starts a recording, a snapshot without one ends it.
@MainActor
@Observable
final class WorkoutManager: NSObject {
    enum Phase: Equatable {
        case idle, starting, running, paused, ending

        /// A recording exists and is not being saved.
        var isActive: Bool { self == .starting || self == .running || self == .paused }
    }

    static let shared = WorkoutManager(healthStore: HKHealthStore())

    /// Seconds an unmatched recording (launched by the phone, never tied to a George session) may live.
    private static let orphanGrace: TimeInterval = 30

    let healthStore: HKHealthStore

    private(set) var phase: Phase = .idle
    /// The George session this recording belongs to (nil until the phone tells us).
    private(set) var sessionID: UUID?
    private(set) var title: String?
    /// Beats per minute.
    private(set) var heartRate: Double?
    private(set) var averageHeartRate: Double?
    /// Kilocalories.
    private(set) var activeEnergy: Double?
    private(set) var lastError: String?

    var isRecording: Bool { phase != .idle }

    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    /// Watch clock: when this recording started.
    @ObservationIgnored private var startDate: Date?
    /// Phone clock: when the George session started, used to recognise stale snapshots.
    @ObservationIgnored private var phoneStartedAt: Date?
    @ObservationIgnored private var endRequestedAt: Date?
    @ObservationIgnored private var discardOnEnd = false
    @ObservationIgnored private var isFinalizing = false
    /// Bumped on every start so late async steps of an older attempt bail out.
    @ObservationIgnored private var attempt = 0
    /// George sessions already recorded (or ended) in this run: never auto-start them again.
    @ObservationIgnored private var recordedSessionIDs: Set<UUID> = []
    @ObservationIgnored private var metricsTask: Task<Void, Never>?

    private init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
        super.init()
    }

    // MARK: Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)]
        let read: Set<HKObjectType> = [HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Start

    /// Starts a recording. Safe to call repeatedly: while one runs, this only attaches the George
    /// session ID if it was not known yet (e.g. after `handle(_ workoutConfiguration:)`).
    func start(configuration: HKWorkoutConfiguration, sessionID: UUID?, title: String?, phoneStartedAt: Date? = nil) {
        guard phase == .idle else {
            adopt(sessionID: sessionID, title: title, phoneStartedAt: phoneStartedAt)
            return
        }
        if let sessionID, recordedSessionIDs.contains(sessionID) { return }
        attempt += 1
        let token = attempt
        phase = .starting
        self.sessionID = sessionID
        self.title = title
        self.phoneStartedAt = phoneStartedAt
        if let sessionID { recordedSessionIDs.insert(sessionID) }
        heartRate = nil
        averageHeartRate = nil
        activeEnergy = nil
        lastError = nil
        discardOnEnd = false
        isFinalizing = false
        endRequestedAt = nil
        startDate = Date()
        Task { await self.beginSession(configuration: configuration, token: token) }
        if sessionID == nil { scheduleOrphanCheck(token: token) }
    }

    private func beginSession(configuration: HKWorkoutConfiguration, token: Int) async {
        await requestAuthorization()
        guard attempt == token, phase == .starting, session == nil else { return }

        let newSession: HKWorkoutSession
        do {
            newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        } catch {
            lastError = error.localizedDescription
            reset()
            return
        }
        let newBuilder = newSession.associatedWorkoutBuilder()
        newBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        newSession.delegate = self
        newBuilder.delegate = self
        session = newSession
        builder = newBuilder
        persistRecoveryInfo()

        let start = Date()
        newSession.startActivity(with: start)
        do {
            try await newBuilder.beginCollection(at: start)
        } catch {
            lastError = error.localizedDescription
            if attempt == token { end(discard: true) }
            return
        }
        guard attempt == token, phase.isActive else { return }
        // A pause that arrived while HealthKit was starting up.
        if let live = WatchConnector.shared.live, live.sessionID == sessionID, live.isPaused {
            newSession.pause()
        }
        startMetricsLoop()
    }

    private func adopt(sessionID newID: UUID?, title newTitle: String?, phoneStartedAt newStart: Date?) {
        guard let newID else { return }
        if sessionID == nil {
            sessionID = newID
            recordedSessionIDs.insert(newID)
            persistRecoveryInfo()
        }
        guard sessionID == newID else { return }
        if phoneStartedAt == nil { phoneStartedAt = newStart }
        if let newTitle, newTitle != title {
            title = newTitle
            persistRecoveryInfo()
        }
    }

    // MARK: Control

    func pause() {
        guard phase == .running, let session else { return }
        session.pause()
    }

    func resume() {
        guard phase == .paused, let session else { return }
        session.resume()
    }

    /// Ends the recording: saves it to Apple Health, or throws it away with `discard`.
    func end(discard: Bool = false) {
        switch phase {
        case .idle, .ending:
            return
        case .starting where session == nil:
            // Still waiting for authorization: cancel the pending start.
            attempt += 1
            reset()
            return
        default:
            break
        }
        discardOnEnd = discard
        phase = .ending
        endRequestedAt = Date()
        stopMetricsLoop()
        session?.end()
        scheduleFinalizeFallback(token: attempt)
    }

    /// The user finished or discarded the George workout on the watch.
    func endRecording(sessionID id: UUID, discard: Bool) {
        recordedSessionIDs.insert(id)
        guard sessionID == nil || sessionID == id else { return }
        end(discard: discard)
    }

    // MARK: Phone sync

    /// Called with every live state from the phone. `snapshot` is set when it came with a snapshot
    /// (application context); then `live == nil` means the phone has no running workout.
    func phoneDidUpdate(live: WatchLiveState?, snapshot: WatchSnapshot?) {
        guard let live else {
            phoneHasNoWorkout(snapshot: snapshot)
            return
        }
        switch phase {
        case .idle:
            guard !recordedSessionIDs.contains(live.sessionID) else { return }
            start(configuration: live.kind.healthConfiguration(), sessionID: live.sessionID, title: live.title, phoneStartedAt: live.startedAt)
        case .ending:
            // Re-synced by `WatchConnector.workoutRecordingDidEnd()` once saved.
            return
        case .starting, .running, .paused:
            adopt(sessionID: live.sessionID, title: live.title, phoneStartedAt: live.startedAt)
            if sessionID == live.sessionID {
                if live.isPaused { pause() } else { resume() }
            } else if !isStale(snapshot?.generatedAt) {
                // The phone moved on to another workout: save this one; the next starts once saved.
                end(discard: false)
            }
        }
    }

    private func phoneHasNoWorkout(snapshot: WatchSnapshot?) {
        guard phase.isActive, !isStale(snapshot?.generatedAt) else { return }
        guard let recordingID = sessionID else {
            // Launched by the phone but never matched to a George workout.
            if let startDate, Date().timeIntervalSince(startDate) > Self.orphanGrace { end(discard: true) }
            return
        }
        // A discarded planned workout goes back to "upcoming" on the phone; a finished one never does.
        let wasDiscarded = snapshot?.discardedSessionID == recordingID
            || (snapshot?.upcoming.contains(where: { $0.id == recordingID }) ?? false)
        end(discard: wasDiscarded)
    }

    /// A snapshot generated before this recording's workout started cannot end it.
    private func isStale(_ generatedAt: Date?) -> Bool {
        guard let generatedAt, let reference = phoneStartedAt ?? startDate else { return false }
        return generatedAt < reference
    }

    private func scheduleOrphanCheck(token: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(WorkoutManager.orphanGrace + 1))
            guard let self, self.attempt == token, self.phase.isActive, self.sessionID == nil,
                  let startDate = self.startDate else { return }
            let connector = WatchConnector.shared
            if connector.hasPhoneData(since: startDate), connector.live == nil {
                self.end(discard: true)
            }
        }
    }

    // MARK: Session events (main actor)

    private func sessionDidChange(_ id: ObjectIdentifier, to state: HKWorkoutSessionState, at date: Date) {
        guard let session, ObjectIdentifier(session) == id else { return }
        switch state {
        case .running:
            if phase != .ending { phase = .running }
        case .paused:
            if phase != .ending { phase = .paused }
        case .ended:
            if phase != .ending {
                // Ended by the system rather than by us.
                phase = .ending
                stopMetricsLoop()
            }
            Task { await self.finalize(endDate: date) }
        default:
            break
        }
    }

    private func sessionDidFail(_ id: ObjectIdentifier, message: String) {
        guard let session, ObjectIdentifier(session) == id else { return }
        lastError = message
    }

    private func apply(_ reading: LiveReading, builderID: ObjectIdentifier) {
        guard let builder, ObjectIdentifier(builder) == builderID else { return }
        if let value = reading.heartRate { heartRate = value }
        if let value = reading.averageHeartRate { averageHeartRate = value }
        if let value = reading.activeEnergy { activeEnergy = value }
    }

    // MARK: Finish

    private func finalize(endDate: Date) async {
        guard !isFinalizing, let builder else { return }
        isFinalizing = true
        if discardOnEnd {
            builder.discardWorkout()
        } else {
            do {
                try await builder.endCollection(at: endDate)
            } catch {
                lastError = error.localizedDescription
            }
            let metadata = workoutMetadata()
            if !metadata.isEmpty {
                do {
                    try await builder.addMetadata(metadata)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            var workoutID: UUID?
            do {
                workoutID = try await Self.finishedWorkoutID(of: builder)
            } catch {
                lastError = error.localizedDescription
            }
            WatchConnector.shared.send(WatchMetrics(
                heartRate: heartRate,
                averageHeartRate: averageHeartRate,
                activeEnergy: activeEnergy,
                healthWorkoutID: workoutID,
                endedAt: endDate
            ))
        }
        reset()
        WatchConnector.shared.workoutRecordingDidEnd()
    }

    /// Saves the workout and returns only its (Sendable) UUID, so the non-Sendable `HKWorkout`
    /// never crosses into the main actor.
    nonisolated private static func finishedWorkoutID(of builder: HKLiveWorkoutBuilder) async throws -> UUID? {
        // Typed as optional so this compiles whether the SDK's async variant returns `HKWorkout` or `HKWorkout?`.
        let workout: HKWorkout? = try await builder.finishWorkout()
        return workout?.uuid
    }

    private func workoutMetadata() -> [String: Any] {
        var metadata: [String: Any] = [:]
        if let configuration = session?.workoutConfiguration {
            switch configuration.locationType {
            case .indoor: metadata[HKMetadataKeyIndoorWorkout] = true
            case .outdoor: metadata[HKMetadataKeyIndoorWorkout] = false
            default: break
            }
        }
        if let sessionID { metadata[HealthMetadataKey.sessionID] = sessionID.uuidString }
        if let title, !title.isEmpty { metadata[HealthMetadataKey.workoutTitle] = title }
        return metadata
    }

    /// Safety net in case the session never reports `.ended`.
    private func scheduleFinalizeFallback(token: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.attempt == token, self.phase == .ending, !self.isFinalizing else { return }
            await self.finalize(endDate: self.endRequestedAt ?? Date())
        }
    }

    private func reset() {
        stopMetricsLoop()
        session?.delegate = nil
        builder?.delegate = nil
        session = nil
        builder = nil
        phase = .idle
        sessionID = nil
        title = nil
        startDate = nil
        phoneStartedAt = nil
        endRequestedAt = nil
        discardOnEnd = false
        isFinalizing = false
        RecoveryInfo.clear()
    }

    // MARK: Live metrics

    private func startMetricsLoop() {
        metricsTask?.cancel()
        // The first message tells the phone that the watch records this workout.
        sendLiveMetrics()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.sendLiveMetrics()
            }
        }
    }

    private func stopMetricsLoop() {
        metricsTask?.cancel()
        metricsTask = nil
    }

    private func sendLiveMetrics() {
        guard phase.isActive else { return }
        WatchConnector.shared.send(WatchMetrics(
            heartRate: heartRate,
            averageHeartRate: averageHeartRate,
            activeEnergy: activeEnergy
        ))
    }

    // MARK: Crash recovery

    private func persistRecoveryInfo() {
        RecoveryInfo.save(sessionID: sessionID, title: title)
    }

    /// Reattaches to a workout session that was running when the app was terminated.
    func recoverActiveWorkout() {
        guard phase == .idle else { return }
        attempt += 1
        let token = attempt
        phase = .starting
        startDate = Date()
        healthStore.recoverActiveWorkoutSession { @Sendable recovered, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                WorkoutManager.shared.finishRecovery(recovered, errorMessage: message, token: token)
            }
        }
    }

    private func finishRecovery(_ recovered: HKWorkoutSession?, errorMessage: String?, token: Int) {
        guard attempt == token, phase == .starting, session == nil else { return }
        guard let recovered else {
            if let errorMessage { lastError = errorMessage }
            reset()
            return
        }
        let recoveredBuilder = recovered.associatedWorkoutBuilder()
        if recoveredBuilder.dataSource == nil {
            recoveredBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: recovered.workoutConfiguration)
        }
        recovered.delegate = self
        recoveredBuilder.delegate = self
        session = recovered
        builder = recoveredBuilder
        let info = RecoveryInfo.load()
        sessionID = info.sessionID ?? sessionID
        title = info.title ?? title
        if let sessionID { recordedSessionIDs.insert(sessionID) }
        startDate = recovered.startDate ?? startDate
        switch recovered.state {
        case .paused:
            phase = .paused
            startMetricsLoop()
        case .ended, .stopped:
            phase = .running
            end(discard: false)
        default:
            phase = .running
            startMetricsLoop()
        }
    }
}

// MARK: - HealthKit delegates (called on HealthKit's queues)

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor in
            self.sessionDidChange(id, to: toState, at: date)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let id = ObjectIdentifier(workoutSession)
        let message = error.localizedDescription
        Task { @MainActor in
            self.sessionDidFail(id, message: message)
        }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let reading = LiveReading(builder: workoutBuilder)
        let id = ObjectIdentifier(workoutBuilder)
        Task { @MainActor in
            self.apply(reading, builderID: id)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

/// Current values read from the builder on HealthKit's queue, handed to the main actor.
private struct LiveReading: Sendable {
    var heartRate: Double?
    var averageHeartRate: Double?
    var activeEnergy: Double?

    init(builder: HKLiveWorkoutBuilder) {
        let beatsPerMinute = HKUnit.count().unitDivided(by: HKUnit.minute())
        if let statistics = builder.statistics(for: HKQuantityType(.heartRate)) {
            heartRate = statistics.mostRecentQuantity()?.doubleValue(for: beatsPerMinute)
            averageHeartRate = statistics.averageQuantity()?.doubleValue(for: beatsPerMinute)
        }
        if let statistics = builder.statistics(for: HKQuantityType(.activeEnergyBurned)) {
            activeEnergy = statistics.sumQuantity()?.doubleValue(for: HKUnit.kilocalorie())
        }
    }
}

/// Which George session a running recording belongs to, kept on disk for crash recovery.
private enum RecoveryInfo {
    static let sessionIDKey = "george.workout.sessionID"
    static let titleKey = "george.workout.title"

    static func save(sessionID: UUID?, title: String?) {
        let defaults = UserDefaults.standard
        defaults.set(sessionID?.uuidString, forKey: sessionIDKey)
        defaults.set(title, forKey: titleKey)
    }

    static func load() -> (sessionID: UUID?, title: String?) {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: sessionIDKey).flatMap { UUID(uuidString: $0) }
        return (id, defaults.string(forKey: titleKey))
    }

    static func clear() {
        save(sessionID: nil, title: nil)
    }
}
