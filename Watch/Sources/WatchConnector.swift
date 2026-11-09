import Foundation
import Observation
import WatchConnectivity
import GeorgeCore

/// The Sendable part of a WatchConnectivity dictionary: the message type and its JSON payload.
/// `[String: Any]` is not Sendable, so delegate callbacks reduce dictionaries to this before hopping
/// to the main actor, and outgoing sends rebuild the dictionary from it.
struct WirePacket: Sendable {
    let type: WatchWire.MessageType
    let data: Data

    init?(_ dictionary: [String: Any]) {
        guard let type = WatchWire.type(of: dictionary),
              let data = dictionary[WatchWire.payloadKey] as? Data else { return nil }
        self.type = type
        self.data = data
    }

    init?<Value: Encodable>(_ value: Value, as type: WatchWire.MessageType) {
        self.init(WatchWire.pack(value, as: type))
    }

    var dictionary: [String: Any] {
        [WatchWire.typeKey: type.rawValue, WatchWire.payloadKey: data]
    }

    func decode<Value: Decodable>(_ valueType: Value.Type) -> Value? {
        WatchWire.unpack(dictionary, as: valueType)
    }
}

/// How an outgoing packet travels to the phone.
enum DeliveryPolicy: Equatable {
    /// `sendMessage` when reachable, dropped otherwise (live metrics, snapshot requests).
    case bestEffort
    /// `sendMessage` when reachable, otherwise queued with `transferUserInfo`.
    case queued
    /// Like `.queued`, and a failed `sendMessage` falls back to `transferUserInfo`.
    /// Only for packets that are harmless if they arrive twice.
    case guaranteed
}

extension WatchCommand {
    var deliveryPolicy: DeliveryPolicy {
        switch self {
        case .requestSnapshot:
            return .bestEffort
        case .pause, .resume, .skipRest, .finish, .discard:
            return .guaranteed
        default:
            // Toggles and "done set" are not idempotent: never send them twice.
            return .queued
        }
    }
}

/// Watch side of the iPhone link. The phone owns all data; the watch shows the last snapshot,
/// mirrors the live workout and sends commands back. Local commands are applied optimistically
/// and the phone's next live state is taken as the truth.
@MainActor
@Observable
final class WatchConnector: NSObject, WCSessionDelegate {
    static let shared = WatchConnector(defaults: .standard)

    /// Last snapshot from the phone (restored from disk on launch so the app shows data instantly).
    private(set) var snapshot: WatchSnapshot?
    /// The running workout, or nil when none is running.
    private(set) var live: WatchLiveState?
    private(set) var isReachable = false
    private(set) var isActivated = false

    private let defaults: UserDefaults
    @ObservationIgnored private var didRequestActivation = false
    /// True once the current `live` value was confirmed by the phone in this run (not just the disk cache).
    @ObservationIgnored private var liveIsFromPhone = false
    @ObservationIgnored private var lastLiveMessageAt: Date?
    @ObservationIgnored private var lastPhoneDataAt: Date?
    /// Workouts that ended (on the phone or here). Late live states for them are ignored.
    @ObservationIgnored private var closedSessionIDs: Set<UUID> = []
    @ObservationIgnored private var outbox: [(packet: WirePacket, policy: DeliveryPolicy)] = []
    @ObservationIgnored private var lastSnapshotRequestAt: Date?
    @ObservationIgnored private var restAlarmTask: Task<Void, Never>?
    @ObservationIgnored private var restAlarmDate: Date?

    private static let cacheKey = "george.watch.snapshot"

    private init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        restoreCachedSnapshot()
    }

    // MARK: Lifecycle

    func activate() {
        guard !didRequestActivation, WCSession.isSupported() else { return }
        didRequestActivation = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Asks the phone for a fresh snapshot (throttled unless `force`).
    func refresh(force: Bool = false) {
        guard isActivated, isReachable else { return }
        let now = Date()
        if !force, let last = lastSnapshotRequestAt, now.timeIntervalSince(last) < 30 { return }
        lastSnapshotRequestAt = now
        send(.requestSnapshot)
    }

    /// Whether anything arrived from the phone since `date`.
    func hasPhoneData(since date: Date) -> Bool {
        (lastPhoneDataAt ?? .distantPast) >= date
    }

    // MARK: Sending

    func send(_ command: WatchCommand) {
        guard let packet = WirePacket(command, as: .command) else { return }
        deliver(packet, policy: command.deliveryPolicy)
    }

    func send(_ metrics: WatchMetrics) {
        guard let packet = WirePacket(metrics, as: .metrics) else { return }
        let isFinal = metrics.healthWorkoutID != nil || metrics.endedAt != nil
        deliver(packet, policy: isFinal ? .guaranteed : .bestEffort)
    }

    /// Sends a command and applies it to the local live state right away (optimistic UI),
    /// mirroring what the phone will do, including pausing/resuming and ending the HealthKit recording.
    func perform(_ command: WatchCommand) {
        send(command)
        guard var state = live else { return }
        let now = Date()
        switch command {
        case .toggleSet(let id):
            guard state.position(of: id) != nil else { return }
            resumeIfPaused(&state, at: now)
            if state.toggleSet(id) == true {
                Haptics.success()
            } else {
                Haptics.click()
            }
        case .completeCurrentSet:
            guard state.firstOpenSet() != nil else { return }
            resumeIfPaused(&state, at: now)
            if state.completeCurrentSet() { Haptics.success() }
        case .startRest(let seconds):
            state.startRest(seconds, now: now)
        case .addRest(let seconds):
            state.addRest(seconds, now: now)
            Haptics.click()
        case .skipRest:
            state.skipRest()
            Haptics.click()
        case .pause:
            guard !state.isPaused else { return }
            state.markPaused(at: now)
            WorkoutManager.shared.pause()
            Haptics.stop()
        case .resume:
            guard state.isPaused else { return }
            state.markResumed(at: now)
            WorkoutManager.shared.resume()
            Haptics.start()
        case .finish:
            Haptics.success()
            close(state.sessionID)
            WorkoutManager.shared.endRecording(sessionID: state.sessionID, discard: false)
            return
        case .discard:
            Haptics.click()
            close(state.sessionID)
            WorkoutManager.shared.endRecording(sessionID: state.sessionID, discard: true)
            return
        default:
            return
        }
        setLive(state)
    }

    /// Called by `WorkoutManager` after a recording was saved or discarded, so a workout the phone
    /// started in the meantime gets its own recording.
    func workoutRecordingDidEnd() {
        guard liveIsFromPhone, let live else { return }
        WorkoutManager.shared.phoneDidUpdate(live: live, snapshot: nil)
    }

    private func deliver(_ packet: WirePacket, policy: DeliveryPolicy) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            if policy != .bestEffort { outbox.append((packet: packet, policy: policy)) }
            return
        }
        if session.isReachable {
            let fallBackToUserInfo = policy == .guaranteed
            session.sendMessage(packet.dictionary, replyHandler: nil, errorHandler: { @Sendable _ in
                guard fallBackToUserInfo else { return }
                WCSession.default.transferUserInfo(packet.dictionary)
            })
        } else if policy != .bestEffort {
            session.transferUserInfo(packet.dictionary)
        }
    }

    // MARK: Receiving (main actor)

    private enum Origin {
        /// Delivered by the phone while this app runs.
        case phone
        /// `receivedApplicationContext` read at activation: possibly old, never drives HealthKit.
        case storedContext
    }

    private func activationCompleted(activated: Bool, reachable: Bool, storedContext: WirePacket?) {
        isActivated = activated
        isReachable = reachable
        guard activated else { return }
        if let storedContext { receive(storedContext, origin: .storedContext) }
        let queued = outbox
        outbox.removeAll()
        for item in queued {
            deliver(item.packet, policy: item.policy)
        }
        refresh(force: true)
    }

    private func reachabilityChanged(_ reachable: Bool) {
        let becameReachable = reachable && !isReachable
        isReachable = reachable
        if becameReachable { refresh(force: true) }
    }

    private func receive(_ packet: WirePacket, origin: Origin) {
        switch packet.type {
        case .snapshot:
            guard let incoming = packet.decode(WatchSnapshot.self) else { return }
            apply(incoming, origin: origin)
        case .live:
            guard let incoming = packet.decode(WatchLiveState.self) else { return }
            applyLive(incoming)
        default:
            break
        }
    }

    private func apply(_ incoming: WatchSnapshot, origin: Origin) {
        if let current = snapshot, incoming.generatedAt < current.generatedAt { return }
        snapshot = incoming
        if origin == .phone { lastPhoneDataAt = Date() }
        if shouldAdoptLive(from: incoming) {
            setLive(openState(incoming.live))
            if origin == .phone {
                liveIsFromPhone = true
                WorkoutManager.shared.phoneDidUpdate(live: live, snapshot: incoming)
            }
        }
        saveCache()
    }

    private func applyLive(_ incoming: WatchLiveState) {
        guard !closedSessionIDs.contains(incoming.sessionID) else { return }
        let now = Date()
        lastLiveMessageAt = now
        lastPhoneDataAt = now
        liveIsFromPhone = true
        let isNewSession = live?.sessionID != incoming.sessionID
        setLive(incoming)
        if isNewSession { saveCache() }
        WorkoutManager.shared.phoneDidUpdate(live: incoming, snapshot: nil)
    }

    /// Application contexts and live messages travel separately and can arrive out of order.
    private func shouldAdoptLive(from incoming: WatchSnapshot) -> Bool {
        guard let current = live else { return true }
        if incoming.live?.sessionID == current.sessionID {
            // Same workout: a live message received after this context was generated is fresher.
            guard let lastMessage = lastLiveMessageAt else { return true }
            return incoming.generatedAt >= lastMessage.addingTimeInterval(-2)
        }
        // Ended or replaced: a context generated before this workout started (phone clock) is stale.
        return incoming.generatedAt >= current.startedAt
    }

    private func openState(_ state: WatchLiveState?) -> WatchLiveState? {
        guard let state, !closedSessionIDs.contains(state.sessionID) else { return nil }
        return state
    }

    private func setLive(_ newValue: WatchLiveState?) {
        if let old = live, old.sessionID != newValue?.sessionID {
            closedSessionIDs.insert(old.sessionID)
        }
        if live != newValue { live = newValue }
        scheduleRestAlarm()
    }

    private func close(_ sessionID: UUID) {
        closedSessionIDs.insert(sessionID)
        setLive(nil)
        saveCache()
    }

    private func resumeIfPaused(_ state: inout WatchLiveState, at date: Date) {
        // The phone resumes a paused workout when a set is logged; mirror that.
        guard state.isPaused else { return }
        state.markResumed(at: date)
        WorkoutManager.shared.resume()
    }

    /// Plays a haptic when the rest ends, even with the wrist down (the workout session keeps us running).
    private func scheduleRestAlarm() {
        let endsAt = live?.restEndsAt
        guard endsAt != restAlarmDate else { return }
        restAlarmTask?.cancel()
        restAlarmTask = nil
        restAlarmDate = endsAt
        guard let endsAt, endsAt > Date() else { return }
        restAlarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.live?.restEndsAt == endsAt else { return }
            Haptics.notify()
        }
    }

    // MARK: Cache

    private func saveCache() {
        guard var cached = snapshot else { return }
        cached.live = live
        guard let data = try? WatchWire.encoder.encode(cached) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }

    private func restoreCachedSnapshot() {
        guard let data = defaults.data(forKey: Self.cacheKey),
              let cached = try? WatchWire.decoder.decode(WatchSnapshot.self, from: data) else { return }
        snapshot = cached
        live = cached.live
    }

    // MARK: WCSessionDelegate (called on a background queue)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let activated = activationState == .activated
        let reachable = session.isReachable
        let stored = activated ? WirePacket(session.receivedApplicationContext) : nil
        Task { @MainActor in
            self.activationCompleted(activated: activated, reachable: reachable, storedContext: stored)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachabilityChanged(reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let packet = WirePacket(applicationContext) else { return }
        Task { @MainActor in
            self.receive(packet, origin: .phone)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let packet = WirePacket(message) else { return }
        Task { @MainActor in
            self.receive(packet, origin: .phone)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let packet = WirePacket(message)
        replyHandler([:])
        guard let packet else { return }
        Task { @MainActor in
            self.receive(packet, origin: .phone)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let packet = WirePacket(userInfo) else { return }
        Task { @MainActor in
            self.receive(packet, origin: .phone)
        }
    }
}

// MARK: - Optimistic updates

extension WatchLiveState {
    struct SetPosition: Equatable {
        let exerciseIndex: Int
        let setIndex: Int
    }

    func position(of setID: UUID) -> SetPosition? {
        for (exerciseIndex, exercise) in exercises.enumerated() {
            if let setIndex = exercise.sets.firstIndex(where: { $0.id == setID }) {
                return SetPosition(exerciseIndex: exerciseIndex, setIndex: setIndex)
            }
        }
        return nil
    }

    func firstOpenSet() -> SetPosition? {
        for (exerciseIndex, exercise) in exercises.enumerated() {
            if let setIndex = exercise.sets.firstIndex(where: { !$0.isDone }) {
                return SetPosition(exerciseIndex: exerciseIndex, setIndex: setIndex)
            }
        }
        return nil
    }

    var currentExercise: WatchExercise? {
        guard let id = currentSetID, let location = position(of: id) else { return nil }
        return exercises[location.exerciseIndex]
    }

    var currentSet: WatchSet? {
        guard let id = currentSetID, let location = position(of: id) else { return nil }
        return exercises[location.exerciseIndex].sets[location.setIndex]
    }

    /// Seconds of rest left at `date`, or nil when not resting.
    func restRemaining(at date: Date) -> TimeInterval? {
        guard let restEndsAt, restEndsAt > date else { return nil }
        return restEndsAt.timeIntervalSince(date)
    }

    /// Flips a set. Returns the new `isDone`, or nil when the set is unknown.
    @discardableResult
    mutating func toggleSet(_ id: UUID) -> Bool? {
        guard let location = position(of: id) else { return nil }
        exercises[location.exerciseIndex].sets[location.setIndex].isDone.toggle()
        let isDone = exercises[location.exerciseIndex].sets[location.setIndex].isDone
        completedSets = max(0, completedSets + (isDone ? 1 : -1))
        if isDone, currentSetID == id {
            currentSetID = nextOpenSetID(after: location)
        }
        return isDone
    }

    /// Completes the current set (or the first open one) and moves on. Returns false when nothing was open.
    @discardableResult
    mutating func completeCurrentSet() -> Bool {
        var candidate: SetPosition? = nil
        if let id = currentSetID, let location = position(of: id),
           !exercises[location.exerciseIndex].sets[location.setIndex].isDone {
            candidate = location
        } else {
            candidate = firstOpenSet()
        }
        guard let target = candidate else { return false }
        exercises[target.exerciseIndex].sets[target.setIndex].isDone = true
        completedSets += 1
        currentSetID = nextOpenSetID(after: target)
        return true
    }

    /// The next open set after `location` in program order, wrapping around. The phone may pick a
    /// different one (supersets); its next live state corrects it.
    func nextOpenSetID(after location: SetPosition) -> UUID? {
        let ordered = exercises.flatMap(\.sets)
        let flatIndex = exercises.prefix(location.exerciseIndex).reduce(0) { $0 + $1.sets.count } + location.setIndex
        let later = ordered.dropFirst(flatIndex + 1).first(where: { !$0.isDone })
        return (later ?? ordered.first(where: { !$0.isDone }))?.id
    }

    mutating func markPaused(at date: Date) {
        guard !isPaused else { return }
        accumulatedSeconds = elapsed(at: date)
        resumedAt = nil
        isPaused = true
    }

    mutating func markResumed(at date: Date) {
        guard isPaused else { return }
        isPaused = false
        resumedAt = date
    }

    mutating func startRest(_ seconds: Int, now: Date) {
        guard seconds > 0 else { return }
        restEndsAt = now.addingTimeInterval(TimeInterval(seconds))
        restTotalSeconds = seconds
    }

    mutating func addRest(_ seconds: Int, now: Date) {
        guard let endsAt = restEndsAt, endsAt > now else {
            startRest(seconds, now: now)
            return
        }
        restEndsAt = endsAt.addingTimeInterval(TimeInterval(seconds))
        restTotalSeconds = (restTotalSeconds ?? Int(endsAt.timeIntervalSince(now).rounded(.up))) + seconds
    }

    mutating func skipRest() {
        restEndsAt = nil
        restTotalSeconds = nil
    }
}
