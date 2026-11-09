import Foundation
import Observation
import CoreData
import CloudKit
import BinisoftKitCore

/// Watches iCloud sync (SwiftData mirrors through NSPersistentCloudKitContainer) and the iCloud
/// account, so Settings can say whether syncing works – and why not. From George and Theo.
///
/// Apps on CKSyncEngine (Finn-style sharing) feed the same state with `recordSync(...)`.
@MainActor
@Observable
public final class SyncMonitor {
    public private(set) var state: SyncState
    public let appName: String

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init(mode: StorageMode, appName: String) {
        self.appName = appName
        self.state = SyncState(mode: mode)
        guard mode.isSynced else { return }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            let finished = event.endDate
            let succeeded = event.succeeded
            let isSetup = event.type == .setup
            let error = event.error.map(SyncMonitor.texts)
            MainActor.assumeIsolated {
                self?.recordSync(finished: finished, succeeded: succeeded, countsAsSync: !isSetup,
                                 short: error?.short, full: error?.full)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshAccount() }
            }
        })
    }

    /// One line for Settings, e.g. "On · synced 5 minutes ago".
    public var summary: String {
        state.summary { $0.formatted(.relative(presentation: .named)) }
    }

    /// Asks CloudKit for the account state. Only touches CloudKit when the store really syncs:
    /// builds without the iCloud entitlement must not create a CKContainer.
    public func refreshAccount() async {
        guard let containerID = state.mode.containerID else { return }
        do {
            let status = try await CKContainer(identifier: containerID).accountStatus()
            let account = Self.account(for: status)
            if account != state.account {
                AppLog.info("iCloud account: \(account.title)", category: "sync")
            }
            state.account = account
        } catch {
            state.account = .couldNotDetermine
            AppLog.warning("iCloud account check failed: \(error.localizedDescription)", category: "sync")
        }
    }

    /// Start (`finished == nil`) or end of a sync event.
    public func recordSync(finished: Date?, succeeded: Bool, countsAsSync: Bool = true,
                           short: String? = nil, full: String? = nil) {
        guard let finished else {
            state.isSyncing = true
            return
        }
        state.isSyncing = false
        if succeeded {
            if countsAsSync { state.lastSync = finished }
            if state.lastError != nil { AppLog.info("Sync works again", category: "sync") }
            state.lastError = nil
        } else if let short {
            let raw = full ?? short
            let friendly = SyncErrorText.describe(raw, appName: appName)
            state.lastError = friendly == raw ? short : friendly
            AppLog.warning("Sync failed: \(raw)", category: "sync")
        }
    }

    private static func account(for status: CKAccountStatus) -> ICloudAccount {
        switch status {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .couldNotDetermine: .couldNotDetermine
        @unknown default: .couldNotDetermine
        }
    }

    /// Short text for Settings, full text (with the underlying CloudKit errors) for the log.
    nonisolated private static func texts(_ error: Error) -> (short: String, full: String) {
        let ns = error as NSError
        var short = ns.localizedDescription
        if let partial = ns.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           let first = partial.values.first {
            short += " – " + (first as NSError).localizedDescription
        }
        return (short, short + " | " + String(describing: error))
    }
}
