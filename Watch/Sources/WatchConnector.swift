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
        case .startTemplate, .startSession:
            // Never queued: starts go through `WatchConnector.requestStart`, which the user can cancel.
            return .bestEffort
        case .pause, .resume, .finish, .discard,
             .completeSet, .undoSet, .dropWeight, .makeCurrent, .answerFeedback, .recordEnergy:
            // Safe to deliver twice, so a failed sendMessage falls back to transferUserInfo: each names
            // its set or question (the phone logs, unticks or drops a set only if it isn't already),
            // asks for a state the phone then already has (paused, running, ended), or replaces the
            // earlier answer (energy).
            return .guaranteed
        default:
            // Toggles, "done current set", Start, rest changes and thread moves act on whatever is
            // current when they arrive, so a repeat would do something new: never sent twice.
            return .queued
        }
    }

    /// Starts a new workout on the phone.
    var startsWorkout: Bool {
        switch self {
        case .startTemplate, .startSession: return true
        default: return false
        }
    }
}

/// A workout start the watch asked the phone for and is waiting on.
struct StartRequest: Equatable, Identifiable {
    enum Status: Equatable {
        /// The phone has it (or is reachable): waiting for its live workout.
        case starting
        /// The phone isn't reachable: queued for at most `WatchConnector.startLifetime`, cancellable.
        case waitingForPhone
    }

    let id: UUID
    let command: WatchCommand
    let title: String?
    let sentAt: Date
    var status: Status
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
    /// A start the user asked for that hasn't turned into a live workout yet.
    private(set) var startRequest: StartRequest?
    /// Why the last start didn't happen (shown on the home screen until acknowledged).
    private(set) var startProblem: String?
    /// Finish summaries the user closed on the watch (session IDs, newest last).
    private var dismissedSummaryIDs: [UUID] = []

    private let defaults: UserDefaults
    @ObservationIgnored private var didRequestActivation = false
    /// True once the current `live` value was confirmed by the phone in this run (not just the disk cache).
    @ObservationIgnored private var liveIsFromPhone = false
    @ObservationIgnored private var lastLiveMessageAt: Date?
    @ObservationIgnored private var lastPhoneDataAt: Date?
    /// Workouts that ended (on the phone or here), with when. Late live states for them are ignored.
    /// One the phone ended is reopened by a snapshot the phone made after that (it runs it again:
    /// continued back on this iPhone from another device); one finished here never is
    /// (`distantFuture`); one discarded here is, by a snapshot made after the tap (a late Discard the
    /// phone ignored).
    @ObservationIgnored private var closedSessionIDs: [UUID: Date] = [:]
    @ObservationIgnored private var outbox: [(packet: WirePacket, policy: DeliveryPolicy)] = []
    @ObservationIgnored private var lastSnapshotRequestAt: Date?
    @ObservationIgnored private var alarmTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledAlarm: CountdownAlarm?
    /// Last command tapped on the watch: progress right after it is ours, not news from the phone.
    @ObservationIgnored private var lastLocalActionAt: Date?
    @ObservationIgnored private var holdEndedAt: Date?
    @ObservationIgnored private var lastRemoteHapticAt: Date?
    @ObservationIgnored private var startPacket: WirePacket?
    @ObservationIgnored private var startTransfer: WCSessionUserInfoTransfer?
    @ObservationIgnored private var startDeadlineTask: Task<Void, Never>?

    private static let cacheKey = "george.watch.snapshot"
    private static let dismissedSummariesKey = "george.watch.dismissedSummaries"
    /// The phone drops starts older than this; the watch gives up waiting then too.
    static let startLifetime: TimeInterval = 120
    /// How long to wait for the live workout once the phone has the start.
    private static let startReplyWait: TimeInterval = 30
    /// A finish summary is offered this long after the workout was saved.
    private static let summaryLifetime: TimeInterval = 30 * 60

    private init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        restoreCachedSnapshot()
        dismissedSummaryIDs = (defaults.stringArray(forKey: Self.dismissedSummariesKey) ?? []).compactMap(UUID.init(uuidString:))
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

    /// Sends a command with when and for which workout it was meant, so the phone can drop it when
    /// it arrives late (queued while out of range) or after that workout ended.
    func send(_ command: WatchCommand) {
        let envelope = WatchCommandEnvelope(command: command, sentAt: Date(), sessionID: live?.sessionID)
        guard let packet = WirePacket(envelope, as: .command) else { return }
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
        if command.startsWorkout {
            requestStart(command, title: nil)
            return
        }
        lastLocalActionAt = Date()
        send(command)
        guard var state = live else { return }
        let now = Date()
        switch command {
        case .toggleSet(let id):
            guard let location = state.position(of: id) else { return }
            // Logging a set carries on after a pause; unticking one doesn't (as on the phone).
            if !state.exercises[location.exerciseIndex].sets[location.setIndex].isDone {
                resumeIfPaused(&state, at: now)
            }
            if state.toggleSet(id) == true {
                Haptics.success()
            } else {
                Haptics.click()
            }
        case .completeCurrentSet:
            guard state.firstOpenSet() != nil else { return }
            resumeIfPaused(&state, at: now)
            if state.completeCurrentSet() { Haptics.success() }
        case .startSet:
            resumeIfPaused(&state, at: now)
            state.startSet(now: now)
            Haptics.start()
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
            // A strength workout left running for hours ends at its last set on the phone: the
            // recording waits a moment for that end instead of covering the hours since.
            let waits = isReachable && WatchRecordingEnd.waitsForPhoneEnd(kind: state.kind, activeSeconds: state.elapsed(at: now))
            WorkoutManager.shared.endRecording(sessionID: state.sessionID, discard: false, waitForPhoneEnd: waits)
            return
        case .discard:
            Haptics.click()
            // Closed from the tap: if the phone ignores this Discard (the workout went on there), its
            // next snapshot shows it again here.
            close(state.sessionID, from: WatchClosing.closedFrom(command, tappedAt: now))
            WorkoutManager.shared.endRecording(sessionID: state.sessionID, discard: true)
            return
        case .completeSet(let id, let reps, let weightKg):
            guard let location = state.position(of: id) else { return }
            if !state.exercises[location.exerciseIndex].sets[location.setIndex].isDone {
                resumeIfPaused(&state, at: now)
            }
            if state.logSet(id, reps: reps, weightKg: weightKg) {
                Haptics.success()
            } else {
                Haptics.click()
            }
        case .undoSet(let id):
            // "Mark not done": only a set that is done; the workout stays paused if it is.
            guard let location = state.position(of: id),
                  state.exercises[location.exerciseIndex].sets[location.setIndex].isDone else { return }
            state.toggleSet(id)
            Haptics.click()
        case .dropWeight:
            // The phone inserts the drop set and makes it current; its next live state shows it.
            Haptics.click()
            return
        case .makeCurrent(let setID):
            guard state.makeCurrent(setID) else { return }
            Haptics.click()
        case .moveThread:
            Haptics.click()
            return
        case .toggleVoiceMute:
            state.voiceMuted = !(state.voiceMuted ?? false)
            Haptics.click()
        case .answerFeedback(let setID, let repsInReserve, let fatigue):
            guard var question = state.question, question.setID == setID else { return }
            if fatigue != nil { question.asksFatigue = false }
            if repsInReserve != nil { question.asksReps = false }
            state.question = (question.asksFatigue || question.asksReps) ? question : nil
            Haptics.click()
        case .recordEnergy:
            state.asksEnergy = false
            Haptics.click()
        default:
            return
        }
        setLive(state)
    }

    // MARK: Starting a workout

    /// Asks the phone to start a workout. Never queued silently: while the phone is unreachable the
    /// home screen shows "Waiting for iPhone…" with Cancel, and the start is given up after
    /// `startLifetime` (the phone would drop it by then anyway).
    func requestStart(_ command: WatchCommand, title: String?) {
        guard command.startsWorkout, live == nil, startRequest == nil else { return }
        let envelope = WatchCommandEnvelope(command: command, sentAt: Date(), sessionID: nil)
        guard let packet = WirePacket(envelope, as: .command) else { return }
        startProblem = nil
        startPacket = packet
        startRequest = StartRequest(id: UUID(), command: command, title: title, sentAt: envelope.sentAt, status: .starting)
        Haptics.click()
        deliverStart()
    }

    /// Cancel on "Waiting for iPhone…": the queued transfer is withdrawn so it can't fire later.
    func cancelStart() {
        guard startRequest != nil else { return }
        endStartRequest()
        Haptics.click()
    }

    func clearStartProblem() {
        startProblem = nil
    }

    private func deliverStart() {
        guard let request = startRequest, let packet = startPacket else { return }
        guard WCSession.isSupported() else {
            failStart("This watch can't reach an iPhone.")
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            // Sent once WatchConnectivity is up (see `activationCompleted`).
            setStartStatus(.waitingForPhone)
            scheduleStartDeadline(at: request.sentAt.addingTimeInterval(Self.startLifetime))
            return
        }
        guard session.isReachable else {
            queueStartTransfer()
            return
        }
        let id = request.id
        setStartStatus(.starting)
        scheduleStartDeadline(at: Date().addingTimeInterval(Self.startReplyWait))
        session.sendMessage(packet.dictionary, replyHandler: { @Sendable _ in
            Task { @MainActor in self.startReachedPhone(id) }
        }, errorHandler: { @Sendable _ in
            Task { @MainActor in self.startMessageFailed(id) }
        })
    }

    /// Queues the start with `transferUserInfo` and keeps the transfer, so Cancel can withdraw it.
    private func queueStartTransfer() {
        guard let request = startRequest, let packet = startPacket else { return }
        let deadline = request.sentAt.addingTimeInterval(Self.startLifetime)
        guard deadline > Date() else {
            startTimedOut(request.id)
            return
        }
        startTransfer?.cancel()
        startTransfer = WCSession.default.transferUserInfo(packet.dictionary)
        setStartStatus(.waitingForPhone)
        scheduleStartDeadline(at: deadline)
    }

    private func startReachedPhone(_ id: UUID) {
        guard startRequest?.id == id else { return }
        setStartStatus(.starting)
        scheduleStartDeadline(at: Date().addingTimeInterval(Self.startReplyWait))
    }

    private func startMessageFailed(_ id: UUID) {
        guard startRequest?.id == id, startTransfer == nil else { return }
        queueStartTransfer()
    }

    private func userInfoTransferFinished(_ transferID: ObjectIdentifier, delivered: Bool) {
        guard let transfer = startTransfer, ObjectIdentifier(transfer) == transferID, let request = startRequest else { return }
        startTransfer = nil
        if delivered {
            startReachedPhone(request.id)
        } else {
            failStart("Couldn't reach your iPhone. Nothing was started.")
        }
    }

    private func startTimedOut(_ id: UUID) {
        guard let request = startRequest, request.id == id else { return }
        failStart(request.status == .waitingForPhone
                  ? "Your iPhone wasn't reachable, so nothing was started."
                  : "Your iPhone didn't start the workout. Try again or start it there.")
    }

    private func failStart(_ message: String) {
        endStartRequest()
        startProblem = message
        Haptics.failure()
    }

    private func setStartStatus(_ status: StartRequest.Status) {
        guard var request = startRequest, request.status != status else { return }
        request.status = status
        startRequest = request
    }

    private func scheduleStartDeadline(at date: Date) {
        guard let id = startRequest?.id else { return }
        startDeadlineTask?.cancel()
        startDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.startTimedOut(id)
        }
    }

    /// Forgets the pending start and withdraws anything still queued for it.
    private func endStartRequest() {
        startDeadlineTask?.cancel()
        startDeadlineTask = nil
        startTransfer?.cancel()
        startTransfer = nil
        startPacket = nil
        startRequest = nil
        cancelQueuedStarts()
    }

    /// Withdraws start commands still waiting in WatchConnectivity's queue (e.g. from before a relaunch).
    private func cancelQueuedStarts() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        for transfer in session.outstandingUserInfoTransfers where transfer !== startTransfer {
            guard let packet = WirePacket(transfer.userInfo), packet.type == .command else { continue }
            let command = packet.decode(WatchCommandEnvelope.self)?.command ?? packet.decode(WatchCommand.self)
            if command?.startsWorkout == true { transfer.cancel() }
        }
    }

    // MARK: Finish summary

    /// The workout the phone just saved, while it's recent and not closed on the watch.
    var finishSummary: WatchFinishSummary? {
        guard live == nil, let summary = snapshot?.lastFinished,
              Date().timeIntervalSince(summary.finishedAt) < Self.summaryLifetime,
              !dismissedSummaryIDs.contains(summary.sessionID) else { return nil }
        return summary
    }

    func dismissFinishSummary(_ sessionID: UUID) {
        guard !dismissedSummaryIDs.contains(sessionID) else { return }
        dismissedSummaryIDs = Array((dismissedSummaryIDs + [sessionID]).suffix(20))
        defaults.set(dismissedSummaryIDs.map(\.uuidString), forKey: Self.dismissedSummariesKey)
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
        // Starts queued before a relaunch have no Cancel button any more: withdraw them.
        cancelQueuedStarts()
        let queued = outbox
        outbox.removeAll()
        for item in queued {
            deliver(item.packet, policy: item.policy)
        }
        if startRequest != nil, startTransfer == nil { deliverStart() }
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
        // The phone runs a workout again that it had ended here (continued back on it from another
        // device): a snapshot it made after that reopens it.
        if origin == .phone, let id = incoming.live?.sessionID, let closedAt = closedSessionIDs[id],
           incoming.generatedAt > closedAt {
            closedSessionIDs[id] = nil
        }
        if shouldAdoptLive(from: incoming) {
            let adopted = openState(incoming.live)
            if origin == .phone { noticeRemoteProgress(from: live, to: adopted) }
            setLive(adopted)
            if origin == .phone {
                liveIsFromPhone = true
                WorkoutManager.shared.phoneDidUpdate(live: live, snapshot: incoming)
            }
        } else {
            ComplicationBridge.write(snapshot: snapshot, live: live)
        }
        saveCache()
    }

    private func applyLive(_ incoming: WatchLiveState) {
        guard closedSessionIDs[incoming.sessionID] == nil else { return }
        let now = Date()
        lastLiveMessageAt = now
        lastPhoneDataAt = now
        liveIsFromPhone = true
        let isNewSession = live?.sessionID != incoming.sessionID
        noticeRemoteProgress(from: live, to: incoming)
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
        guard let state, closedSessionIDs[state.sessionID] == nil else { return nil }
        return state
    }

    private func setLive(_ newValue: WatchLiveState?) {
        if let old = live, old.sessionID != newValue?.sessionID, closedSessionIDs[old.sessionID] == nil {
            closedSessionIDs[old.sessionID] = Date()
        }
        if live != newValue { live = newValue }
        // A live workout arrived: the pending start is answered (or overtaken by one from the phone).
        if newValue != nil, startRequest != nil { endStartRequest() }
        scheduleCountdownHaptics()
        // Writes only when what the complication shows changed.
        ComplicationBridge.write(snapshot: snapshot, live: live)
    }

    /// A set ticked on the phone: a success haptic on the wrist (not for the watch's own taps or
    /// the end of a hold, which already played one).
    private func noticeRemoteProgress(from old: WatchLiveState?, to new: WatchLiveState?) {
        guard let old, let new, old.sessionID == new.sessionID, new.completedSets > old.completedSets else { return }
        let now = Date()
        if let at = lastLocalActionAt, now.timeIntervalSince(at) < 4 { return }
        if let at = holdEndedAt, now.timeIntervalSince(at) < 5 { return }
        if let at = lastRemoteHapticAt, now.timeIntervalSince(at) < 2 { return }
        lastRemoteHapticAt = now
        Haptics.success()
    }

    private func close(_ sessionID: UUID, from date: Date = .distantFuture) {
        // Finished here: never reopened by a phone snapshot that crossed with it. Discarded here:
        // reopened by a snapshot the phone made after the tap (`WatchClosing`).
        closedSessionIDs[sessionID] = date
        setLive(nil)
        saveCache()
    }

    private func resumeIfPaused(_ state: inout WatchLiveState, at date: Date) {
        // The phone resumes a paused workout when a set is logged; mirror that.
        guard state.isPaused else { return }
        state.markResumed(at: date)
        WorkoutManager.shared.resume()
    }

    /// The end of a rest or of a running hold, which the wrist counts down to – for a per-side hold
    /// also the moment to switch sides.
    private struct CountdownAlarm: Equatable {
        enum Kind: Equatable { case rest, hold }
        let kind: Kind
        let endsAt: Date
        /// Per-side holds: the end of side 1 (clicks, then a buzz to switch sides).
        let switchSidesAt: Date?

        init?(_ state: WatchLiveState?) {
            guard let state, !state.isPaused else { return nil }
            if let restEndsAt = state.restEndsAt {
                kind = .rest
                endsAt = restEndsAt
                switchSidesAt = nil
            } else if let holdEndsAt = state.holdEndsAt {
                kind = .hold
                endsAt = holdEndsAt
                switchSidesAt = state.holdSwitchAt
            } else {
                return nil
            }
        }
    }

    /// Clicks at 3, 2 and 1 seconds before `date` (one that is already past is skipped).
    private static func countdownClicks(before date: Date) async {
        for secondsBefore in [3.0, 2.0, 1.0] {
            let delay = date.addingTimeInterval(-secondsBefore).timeIntervalSinceNow
            // Already past (the countdown was scheduled late): skip that click.
            guard delay > -0.3 else { continue }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            Haptics.click()
        }
    }

    /// Clicks at 3, 2 and 1 seconds before a rest or hold ends, then a notification (rest) or a
    /// success (hold) – on the wrist, even with the wrist down, the voice off or music playing
    /// (the workout session keeps the app running). A per-side hold first counts down to the
    /// switch and buzzes there.
    private func scheduleCountdownHaptics() {
        let alarm = CountdownAlarm(live)
        guard alarm != scheduledAlarm else { return }
        alarmTask?.cancel()
        alarmTask = nil
        scheduledAlarm = alarm
        guard let alarm, alarm.endsAt > Date() else { return }
        alarmTask = Task { [weak self] in
            if let switchAt = alarm.switchSidesAt, switchAt > Date() {
                await WatchConnector.countdownClicks(before: switchAt)
                let delay = switchAt.timeIntervalSinceNow
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, self?.scheduledAlarm == alarm else { return }
                // Switch sides.
                Haptics.notify()
            }
            await WatchConnector.countdownClicks(before: alarm.endsAt)
            guard !Task.isCancelled else { return }
            let delay = alarm.endsAt.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.scheduledAlarm == alarm else { return }
            switch alarm.kind {
            case .rest:
                Haptics.notify()
            case .hold:
                self.holdEndedAt = Date()
                Haptics.success()
            }
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

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let transferID = ObjectIdentifier(userInfoTransfer)
        let delivered = error == nil
        Task { @MainActor in
            self.userInfoTransferFinished(transferID, delivered: delivered)
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

    /// When a running timed set (hold) ends; nil when none runs or the workout is paused.
    var holdEndsAt: Date? {
        guard !isPaused, restEndsAt == nil, let setStartedAt, let timedSetSeconds, timedSetSeconds > 0 else { return nil }
        return setStartedAt.addingTimeInterval(TimeInterval(timedSetSeconds))
    }

    /// Seconds left of a running hold (0 once over, until the phone logs it), or nil.
    func holdRemaining(at date: Date) -> TimeInterval? {
        guard let holdEndsAt else { return nil }
        return max(0, holdEndsAt.timeIntervalSince(date))
    }

    /// The set that's due: the phone's current one, else the first open set (older phones).
    var due: (exercise: WatchExercise, set: WatchSet, number: Int, of: Int)? {
        if let current, !current.set.isDone { return current }
        guard let location = firstOpenSet() else { return nil }
        let exercise = exercises[location.exerciseIndex]
        return (exercise, exercise.sets[location.setIndex], location.setIndex + 1, exercise.sets.count)
    }

    var hasOpenSet: Bool { firstOpenSet() != nil }

    /// The energy check-in is offered until the first set starts or is done.
    var showsEnergyCheckIn: Bool { asksEnergy == true && completedSets == 0 && setStartedAt == nil }

    /// The coach's question while part of it is still unanswered.
    var openQuestion: WatchQuestion? {
        guard let question, question.asksFatigue || question.asksReps else { return nil }
        return question
    }

    /// A question or check-in card is showing.
    var hasPrompt: Bool { showsEnergyCheckIn || openQuestion != nil }

    /// The main button is Start (rather than Done) while the current set waits and the Start button
    /// is on. A hold always starts first, as on the phone.
    var primaryIsStart: Bool {
        guard setStartedAt == nil, let set = currentSet, !set.isDone else { return false }
        return usesStartButton != false || set.isTimed == true
    }

    /// Logs a set with what was really done and moves on if it was current. Returns false when it
    /// was already done (the values are still updated, as on the phone).
    @discardableResult
    mutating func logSet(_ id: UUID, reps: Int?, weightKg: Double?) -> Bool {
        guard let location = position(of: id) else { return false }
        if let reps { exercises[location.exerciseIndex].sets[location.setIndex].reps = reps }
        if let weightKg { exercises[location.exerciseIndex].sets[location.setIndex].weightKg = weightKg }
        guard !exercises[location.exerciseIndex].sets[location.setIndex].isDone else { return false }
        exercises[location.exerciseIndex].sets[location.setIndex].isDone = true
        completedSets += 1
        if currentSetID == id {
            currentSetID = nextOpenSetID(after: location)
            setStartedAt = nil
            lastSetEndedAt = Date()
        }
        return true
    }

    /// "Do this now": an open set becomes the current one. Returns false when nothing changed.
    mutating func makeCurrent(_ id: UUID) -> Bool {
        guard let location = position(of: id), !exercises[location.exerciseIndex].sets[location.setIndex].isDone,
              currentSetID != id else { return false }
        currentSetID = id
        setStartedAt = nil
        // The phone sends the new set's target with its next state.
        timedSetSeconds = nil
        return true
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
        setStartedAt = nil
        lastSetEndedAt = Date()
        return true
    }

    /// "I'm starting the set now" (optimistic; the phone's next state has the real numbers).
    mutating func startSet(now: Date) {
        guard setStartedAt == nil, firstOpenSet() != nil else { return }
        restEndsAt = nil
        restTotalSeconds = nil
        setStartedAt = now
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
