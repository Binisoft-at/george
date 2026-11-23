import Foundation
import BinisoftKitCore

/// Whether George is saving and syncing properly – for the banner on Today and the Mac sidebar.
/// Problems that lose data (nothing is saved) are red; "this device only", a signed-out or
/// unavailable iCloud account and a sync error that lasts are orange; a healthy state shows nothing.
public struct SyncHealth: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case ok, warning, critical
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Where the data lives (`StorageMode` without the container).
    public enum Storage: Equatable, Sendable {
        case iCloud, local(reason: String?), memory(reason: String?), demo
    }

    /// The iCloud account (`ICloudAccount`, folded).
    public enum Account: Equatable, Sendable {
        case unknown, available, noAccount, restricted, unavailable
    }

    public var level: Level
    public var title: String
    public var detail: String?

    public init(level: Level, title: String, detail: String? = nil) {
        self.level = level
        self.title = title
        self.detail = detail
    }

    public static let ok = SyncHealth(level: .ok, title: "")

    /// A sync error counts once it lasts this long (single failed syncs fix themselves).
    public static let errorGrace: TimeInterval = 15 * 60

    public static func evaluate(storage: Storage, account: Account, lastError: String?, errorSince: Date?, now: Date) -> SyncHealth {
        switch storage {
        case .demo:
            return .ok
        case .memory(let reason):
            return SyncHealth(level: .critical, title: "Not being saved – restart George",
                              detail: reason ?? "Changes are lost when George quits.")
        case .local(let reason):
            return SyncHealth(level: .warning, title: "This device only – not syncing",
                              detail: reason ?? "Your workouts stay on this device and don't reach your other devices.")
        case .iCloud:
            switch account {
            case .noAccount:
                return SyncHealth(level: .warning, title: "Not syncing – sign in to iCloud",
                                  detail: "Your workouts stay on this device until you sign in.")
            case .restricted:
                return SyncHealth(level: .warning, title: "Not syncing – iCloud is restricted",
                                  detail: "Screen Time or a device profile blocks iCloud for George.")
            case .unavailable:
                return SyncHealth(level: .warning, title: "iCloud unavailable – not syncing",
                                  detail: "George syncs again once iCloud is back.")
            case .unknown, .available:
                break
            }
            if let lastError, let errorSince, now.timeIntervalSince(errorSince) >= errorGrace {
                return SyncHealth(level: .warning, title: "Not syncing", detail: lastError)
            }
            return .ok
        }
    }

    /// From BinisoftKit's sync state.
    public static func evaluate(_ state: SyncState, errorSince: Date?, now: Date) -> SyncHealth {
        let storage: Storage
        switch state.mode {
        case .iCloud: storage = .iCloud
        case .local(let reason): storage = .local(reason: reason)
        case .memory(let reason): storage = .memory(reason: reason)
        case .demo: storage = .demo
        }
        let account: Account
        switch state.account {
        case .unknown: account = .unknown
        case .available: account = .available
        case .noAccount: account = .noAccount
        case .restricted: account = .restricted
        case .temporarilyUnavailable, .couldNotDetermine: account = .unavailable
        }
        return evaluate(storage: storage, account: account, lastError: state.lastError, errorSince: errorSince, now: now)
    }
}
