import Foundation
import Observation
import GeorgeCore
#if os(iOS)
import WatchConnectivity
#endif

/// iPhone side of the Apple Watch link. The phone owns the data: it pushes snapshots and the
/// live workout state, and receives commands (set toggles, rest, finish) and live metrics.
@MainActor
@Observable
final class PhoneWatchConnector: NSObject {
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false

    /// Commands from the watch, with when and for which workout they were sent.
    var onCommand: ((WatchCommandEnvelope) -> Void)?
    var onMetrics: ((WatchMetrics) -> Void)?
    /// Supplies a fresh snapshot when the watch asks for one.
    var snapshotProvider: (() -> WatchSnapshot)?
    /// Called each time activation completes (paired / installed are known from then on).
    var onActivated: (() -> Void)?

    /// Activation completed at least once (`isPaired` / `isWatchAppInstalled` are real values).
    private(set) var isActivated = false
    @ObservationIgnored private var didRequestActivation = false

    /// True while `isPaired` / `isWatchAppInstalled` are still unknown: this iPhone supports a watch
    /// but activation hasn't completed yet. False on iPad and Mac.
    var awaitsActivation: Bool {
        #if os(iOS)
        return WCSession.isSupported() && !isActivated
        #else
        return false
        #endif
    }

    /// Safe to call more than once: as early as possible at launch (also for background launches),
    /// and again from the window.
    func activate() {
        #if os(iOS)
        guard !didRequestActivation, WCSession.isSupported() else { return }
        didRequestActivation = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    func sendSnapshot(_ snapshot: WatchSnapshot) {
        #if os(iOS)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(WatchWire.pack(snapshot, as: .snapshot))
        #endif
    }

    func sendLive(_ state: WatchLiveState) {
        #if os(iOS)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(WatchWire.pack(state, as: .live), replyHandler: nil, errorHandler: nil)
        #endif
    }

    // MARK: Incoming

    fileprivate func handle(type: String?, payload: Data?) {
        guard let type, let payload, let kind = WatchWire.MessageType(rawValue: type) else { return }
        let message: [String: Any] = [WatchWire.typeKey: type, WatchWire.payloadKey: payload]
        switch kind {
        case .command:
            // Newer watches send an envelope (time + workout id); older ones the bare command.
            let envelope = WatchWire.unpack(message, as: WatchCommandEnvelope.self)
                ?? WatchWire.unpack(message, as: WatchCommand.self).map { WatchCommandEnvelope(command: $0, sessionID: nil) }
            guard let envelope else { return }
            if envelope.command == .requestSnapshot {
                if let snapshot = snapshotProvider?() { sendSnapshot(snapshot) }
                if let live = snapshotProvider?().live { sendLive(live) }
            } else {
                onCommand?(envelope)
            }
        case .metrics:
            guard let metrics = WatchWire.unpack(message, as: WatchMetrics.self) else { return }
            onMetrics?(metrics)
        case .snapshot, .live:
            break
        }
    }

    fileprivate func updateState(paired: Bool, installed: Bool, reachable: Bool) {
        isPaired = paired
        isWatchAppInstalled = installed
        isReachable = reachable
    }
}

#if os(iOS)
extension PhoneWatchConnector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        Task { @MainActor in
            self.updateState(paired: paired, installed: installed, reachable: reachable)
            self.isActivated = true
            // A workout restored before the link was up decides now whether the iPhone records it itself.
            self.onActivated?()
            if let snapshot = self.snapshotProvider?() { self.sendSnapshot(snapshot) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        Task { @MainActor in
            self.updateState(paired: paired, installed: installed, reachable: reachable)
            if reachable, let live = self.snapshotProvider?().live { self.sendLive(live) }
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        Task { @MainActor in
            self.updateState(paired: paired, installed: installed, reachable: reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let type = message[WatchWire.typeKey] as? String
        let payload = message[WatchWire.payloadKey] as? Data
        Task { @MainActor in self.handle(type: type, payload: payload) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let type = message[WatchWire.typeKey] as? String
        let payload = message[WatchWire.payloadKey] as? Data
        replyHandler([:])
        Task { @MainActor in self.handle(type: type, payload: payload) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let type = userInfo[WatchWire.typeKey] as? String
        let payload = userInfo[WatchWire.payloadKey] as? Data
        Task { @MainActor in self.handle(type: type, payload: payload) }
    }
}
#endif
