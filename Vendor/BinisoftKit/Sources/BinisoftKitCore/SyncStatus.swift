import Foundation

// Plain-language sync status for Settings (from George's SyncMonitor and Theo's status text).
// The Apple side (BinisoftKit `SyncMonitor`) fills a `SyncState`; the wording lives here so it is
// the same in every app and testable on Linux.

/// Where this launch keeps its data, decided when the store is opened.
public enum StorageMode: Equatable, Sendable {
    /// Synced through the private database of this iCloud container.
    case iCloud(container: String)
    /// iCloud wasn't usable at launch (no entitlement, store error): data stays on this device.
    case local(reason: String?)
    /// Nothing could be opened: data is lost on quit.
    case memory(reason: String?)
    /// Screenshot / demo launch: sample data in memory, nothing saved, nothing synced.
    case demo

    public var title: String {
        switch self {
        case .iCloud: "On this device + iCloud"
        case .local: "On this device only"
        case .memory: "Temporary (not saved)"
        case .demo: "Demo data (not saved)"
        }
    }

    public var isSynced: Bool {
        if case .iCloud = self { return true }
        return false
    }

    public var containerID: String? {
        if case .iCloud(let container) = self { return container }
        return nil
    }
}

/// The iCloud account as CloudKit reports it.
public enum ICloudAccount: String, Equatable, Sendable {
    case unknown, available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine

    public var title: String {
        switch self {
        case .unknown: "Checking…"
        case .available: "Signed in"
        case .noAccount: "Not signed in"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily unavailable"
        case .couldNotDetermine: "Unknown"
        }
    }
}

public struct SyncState: Equatable, Sendable {
    public var mode: StorageMode
    public var account: ICloudAccount
    public var isSyncing: Bool
    public var lastSync: Date?
    public var lastError: String?

    public init(mode: StorageMode, account: ICloudAccount = .unknown, isSyncing: Bool = false,
                lastSync: Date? = nil, lastError: String? = nil) {
        self.mode = mode
        self.account = account
        self.isSyncing = isSyncing
        self.lastSync = lastSync
        self.lastError = lastError
    }

    /// Green dot in Settings.
    public var isHealthy: Bool {
        mode.isSynced && lastError == nil && account != .noAccount && account != .restricted
    }

    /// One line for Settings, e.g. "On · synced 5 minutes ago".
    /// - Parameter relative: formats `lastSync` ("5 minutes ago"); BinisoftKit passes the system style.
    public func summary(relative: (Date) -> String) -> String {
        switch mode {
        case .memory: return "Off – data can't be saved"
        case .demo: return "Off – demo data"
        case .local: return "Off – this device only"
        case .iCloud:
            if account == .noAccount { return "Off – sign in to iCloud" }
            if account == .restricted { return "Off – iCloud is restricted" }
            if lastError != nil { return "Not syncing" }
            if isSyncing { return "Syncing…" }
            if let lastSync { return "On · synced \(relative(lastSync))" }
            return "On"
        }
    }
}

/// Turns CloudKit / Core Data errors into sentences people understand, with the fix.
public enum SyncErrorText {
    public static func describe(_ raw: String, appName: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("schema") || lowered.contains("cannot create or modify field")
            || lowered.contains("did not find record type") || lowered.contains("unknown item") {
            return "iCloud doesn't know \(appName)'s data types yet (the CloudKit schema isn't deployed to Production). Your data is safe on this device and syncs once that's done."
        }
        if lowered.contains("quota") { return "Your iCloud storage is full. \(appName) syncs again once there is space." }
        if lowered.contains("not authenticated") || lowered.contains("no account") || lowered.contains("notauthenticated") {
            return "Sign in to iCloud in Settings to sync."
        }
        if lowered.contains("network") || lowered.contains("offline") || lowered.contains("internet") {
            return "No network – \(appName) syncs when you're back online."
        }
        if lowered.contains("zone") && lowered.contains("not found") {
            return "iCloud is setting up \(appName)'s storage. This fixes itself after the next sync."
        }
        return raw
    }
}
