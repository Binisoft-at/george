import Foundation
import BinisoftKitCore

// MARK: - Deleting a workout

/// What Delete does with a workout – one rule for every path: the Mac's Delete key, swipe, the
/// context menu, bulk Delete and the workout page's ⋯ Delete.
public enum SessionDelete {
    public enum Route: Equatable, Sendable {
        /// Not in progress: deleted with Undo.
        case delete
        /// Live mode runs it on this device: it's discarded there (live mode asks first and keeps a
        /// continued workout's saved part), never deleted behind live mode's back.
        case discardInLive
        /// In progress on another device: asks first ("Running on your iPhone" – "It stops there
        /// too."), then deleted with Undo. The other device drops its live mode once it syncs.
        case confirmRunningElsewhere
    }

    /// - Parameters:
    ///   - isActive: the workout is in progress (synced status).
    ///   - isLiveHere: live mode runs it on this device.
    public static func route(isActive: Bool, isLiveHere: Bool) -> Route {
        if isLiveHere { return .discardInLive }
        return isActive ? .confirmRunningElsewhere : .delete
    }

    /// The confirmation's message under "Running on your iPhone".
    public static let stopsThereToo = "It stops there too."

    /// Bulk Delete's question: "Delete 3 workouts?" – "Delete 1 workout?" for one (Select mode).
    public static func bulkTitle(count: Int) -> String {
        count == 1 ? "Delete 1 workout?" : "Delete \(count) workouts?"
    }

    /// One selected workout, as bulk Delete sees it.
    public struct Candidate: Equatable, Sendable {
        public var isActive: Bool
        public var isLiveHere: Bool
        /// Where it runs when it runs elsewhere ("your iPhone", "another device"); unused otherwise.
        public var deviceName: String

        public init(isActive: Bool, isLiveHere: Bool, deviceName: String = "another device") {
            self.isActive = isActive
            self.isLiveHere = isLiveHere
            self.deviceName = deviceName
        }

        public var route: Route { SessionDelete.route(isActive: isActive, isLiveHere: isLiveHere) }
    }

    /// What bulk Delete does with a selection – it asks once ("Delete 3 workouts?"), and that
    /// question says so when any of them runs on another device.
    public struct Bulk: Equatable, Sendable {
        /// Positions (in the selection) of the workouts deleted.
        public var deleted: [Int]
        /// The selection held the workout live mode runs here: it stays (discarded in live mode).
        public var keptRunningHere: Bool
        /// The question's message; nil when nothing selected runs on another device.
        public var message: String?
    }

    public static func bulk(_ selection: [Candidate]) -> Bulk {
        var deleted: [Int] = []
        var keptRunningHere = false
        var elsewhere: [String] = []
        for (index, candidate) in selection.enumerated() {
            switch candidate.route {
            case .discardInLive:
                keptRunningHere = true
            case .confirmRunningElsewhere:
                elsewhere.append(candidate.deviceName)
                deleted.append(index)
            case .delete:
                deleted.append(index)
            }
        }
        return Bulk(deleted: deleted, keptRunningHere: keptRunningHere, message: elsewhereMessage(elsewhere))
    }

    /// "Running on your iPhone. It stops there too." – nil when none runs elsewhere.
    public static func elsewhereMessage(_ deviceNames: [String]) -> String? {
        guard let first = deviceNames.first else { return nil }
        if deviceNames.count == 1 { return "Running on \(first). \(stopsThereToo)" }
        let place = Set(deviceNames).count == 1 ? first : "other devices"
        return "\(deviceNames.count) are running on \(place). They stop there too."
    }
}

// MARK: - Restoring a backup

/// Why a restore should ask first: this device may not have everything iCloud holds yet. A restore
/// adds what's missing here as new records, and what iCloud brings later sits next to them – two of
/// each, as iCloud can't keep records unique.
public enum RestoreCaution: Equatable, Sendable {
    /// iCloud's first import on this device hasn't finished (a new device).
    case firstImportPending
    /// The last iCloud import is older than `staleAfter` (a Mac that was asleep), or sync has a
    /// problem (an error, or an account that can't sync).
    case mayBeBehind

    /// An import older than this counts as behind.
    public static let staleAfter: TimeInterval = 60 * 60

    /// - Parameters:
    ///   - syncs: the store syncs with iCloud (nothing to wait for otherwise).
    ///   - importSeen: an iCloud import finished on this device at least once.
    ///   - lastImport: when the last iCloud import finished here (kept on the device; nil: not known).
    ///   - syncProblem: sync reports an error, or the account can't sync (`hasSyncProblem`).
    public static func evaluate(syncs: Bool, importSeen: Bool, lastImport: Date?, syncProblem: Bool, now: Date) -> RestoreCaution? {
        guard syncs else { return nil }
        guard importSeen else { return .firstImportPending }
        if syncProblem { return .mayBeBehind }
        guard let lastImport else { return .mayBeBehind }
        return now.timeIntervalSince(lastImport) > staleAfter ? .mayBeBehind : nil
    }

    /// From BinisoftKit's sync state.
    public static func evaluate(_ state: SyncState, importSeen: Bool, lastImport: Date?, now: Date) -> RestoreCaution? {
        evaluate(syncs: state.mode.isSynced, importSeen: importSeen, lastImport: lastImport,
                 syncProblem: hasSyncProblem(state), now: now)
    }

    /// A sync error right now (no grace period, unlike the banner), or an account that can't sync.
    public static func hasSyncProblem(_ state: SyncState) -> Bool {
        if state.lastError != nil { return true }
        switch state.account {
        case .noAccount, .restricted, .temporarilyUnavailable, .couldNotDetermine: return true
        case .unknown, .available: return false
        }
    }

    /// The orange note above Restore.
    public var note: String {
        switch self {
        case .firstImportPending:
            return "iCloud hasn't finished loading on this device. Restoring now can show workouts, templates and programs twice. Best wait until it's done."
        case .mayBeBehind:
            return "This device may not have the newest data from iCloud yet. Restoring now can bring back copies of workouts, templates and programs, so they show twice. Best wait until iCloud has synced."
        }
    }

    /// The question Restore asks first (buttons: Restore Anyway, Cancel).
    public var alertTitle: String {
        switch self {
        case .firstImportPending: return "Restore Before iCloud Is Done?"
        case .mayBeBehind: return "Restore Before iCloud Catches Up?"
        }
    }

    public var alertMessage: String {
        switch self {
        case .firstImportPending:
            return "What iCloud still brings would show twice."
        case .mayBeBehind:
            return "This device may not have the newest data from iCloud yet. Restoring now can bring back copies of workouts, templates and programs that then show twice."
        }
    }
}
