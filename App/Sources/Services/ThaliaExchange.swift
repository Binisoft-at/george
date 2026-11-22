#if !os(watchOS)
import Foundation
import CoreData
import SwiftData
import Observation
import BinisoftKit
import GeorgeCore
#if os(macOS)
import AppKit
import Security
#else
import UIKit
#endif

// Thalia exchange (Binisoft exchange v1, docs/THALIA.md): George writes its finished workouts as small
// JSON files into the shared App Group on this device; Thalia reads them. Never on the Watch, never
// from the demo, preview or in-memory store, never anything from Apple Health.

/// The App Group side: folder, entitlement check, Darwin notification, Thalia's catalog.
enum ThaliaExchange {
    /// `<App Group>/George` – nil without the App Group (unsigned builds) and, on the Mac, without the
    /// entitlement. Call off the main thread.
    static func appFolder() -> URL? {
        guard let group = AppIdentifiers.main.sharedAppGroup else { return nil }
        #if os(macOS)
        guard hasAppGroupEntitlement(group) else { return nil }
        #endif
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return root.appendingPathComponent(ThaliaExport.appName, isDirectory: true)
    }

    /// Thalia's catalog next to George's folder; nil until Thalia wrote it on this device.
    static func catalog(appFolder: URL) -> ExchangeCatalog? {
        let thalia = appFolder.deletingLastPathComponent().appendingPathComponent("Thalia", isDirectory: true)
        let url = BinisoftExchange.exchangeFolder(appFolder: thalia).appendingPathComponent(BinisoftExchange.catalogFileName)
        guard let data = try? Data(contentsOf: url), case .success(let catalog) = ExchangeReader.catalog(data) else { return nil }
        return catalog
    }

    /// After a write: Thalia may look right away (it also reads on launch, in the foreground and every 5 minutes).
    static func postChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(BinisoftExchange.changedNotification as CFString), nil, nil, true)
    }

    #if os(macOS)
    /// Does the signed app really have the group? Without it macOS may ask about other apps' data.
    /// Off the main thread, not during launch.
    static func hasAppGroupEntitlement(_ group: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        return (value as? [String])?.contains(group) ?? false
    }
    #endif
}

/// What one sync writes, as plain values built on the main actor from the synced store.
struct ThaliaSnapshot: Sendable {
    var enabled: Bool
    var workouts: [ThaliaWorkout]
    var templates: [ThaliaTemplate]
    var appVersion: String
    var now: Date
    var timeZone: TimeZone
}

struct ThaliaWriteResult: Sendable {
    /// The App Group folder exists on this device (signed build with the group).
    var available: Bool
    /// A file was written or deleted.
    var wrote: Bool
    var catalog: ExchangeCatalog?
}

/// Writes off the main thread, one sync at a time.
actor ThaliaWriter {
    private var folderChecked = false
    private var folder: URL?

    func write(_ snapshot: ThaliaSnapshot) -> ThaliaWriteResult {
        if !folderChecked {
            folder = ThaliaExchange.appFolder()
            folderChecked = true
            if folder == nil { AppLog.info("Thalia: no App Group on this device – nothing is written", category: "thalia") }
        }
        guard let folder else { return ThaliaWriteResult(available: false, wrote: false, catalog: nil) }
        let zone = snapshot.timeZone
        let today = ExchangeDate.day(snapshot.now, timeZone: zone)
        var wrote = false
        do {
            // Switched off counts as "nothing there": days that had a file get "facts":[].
            let facts = snapshot.enabled ? ThaliaExport.factsByDay(snapshot.workouts, today: today, timeZone: zone) : [:]
            if try ThaliaExchangeWriter.sync(facts, source: ThaliaExport.source, appFolder: folder, today: today,
                                             now: snapshot.now, timeZone: zone) {
                wrote = true
            }
            if snapshot.enabled,
               try ThaliaExchangeWriter.syncSource(refs: ThaliaExport.refs(snapshot.templates), source: ThaliaExport.source,
                                                   app: ThaliaExport.appName, appVersion: snapshot.appVersion,
                                                   appFolder: folder, today: today, now: snapshot.now, timeZone: zone) {
                wrote = true
            }
        } catch {
            AppLog.warning("Thalia: writing failed – \(error.localizedDescription)", category: "thalia")
        }
        if wrote {
            ThaliaExchange.postChanged()
            AppLog.info("Thalia: exchange files updated", category: "thalia")
        }
        return ThaliaWriteResult(available: true, wrote: wrote, catalog: ThaliaExchange.catalog(appFolder: folder))
    }
}

/// Keeps the exchange files up to date: about 2 s after George saves, right after an iCloud import,
/// in the foreground and when the day changes. Settings → Thalia.
@MainActor
@Observable
final class ThaliaSync {
    /// Settings → Thalia → "Send to Thalia" (this device).
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Prefs.thaliaDeliver)
            schedule(after: .milliseconds(300))
        }
    }
    /// When George last wrote a file on this device.
    private(set) var lastWritten: Date?
    /// Thalia's catalog on this device (nil until Thalia wrote one).
    private(set) var catalog: ExchangeCatalog? = nil
    /// False in demo/preview/in-memory launches and where the App Group is missing.
    private(set) var isAvailable: Bool

    @ObservationIgnored private let store: GeorgeStore
    @ObservationIgnored private let isRealStore: Bool
    @ObservationIgnored private let writer = ThaliaWriter()
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    init(store: GeorgeStore, mode: StorageMode, launch: LaunchOptions) {
        self.store = store
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Prefs.thaliaDeliver) as? Bool ?? true
        lastWritten = defaults.object(forKey: Prefs.thaliaLastWritten) as? Date
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        switch mode {
        case .iCloud, .local: isRealStore = !launch.isDemo && !isPreview
        case .memory, .demo: isRealStore = false
        }
        isAvailable = isRealStore
    }

    /// Starts watching for changes; the first sync runs a few seconds after launch.
    func start() {
        guard isRealStore, !started else { return }
        started = true
        observeRevision()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil else { return }
            MainActor.assumeIsolated { self?.schedule() }
        })
        #if os(macOS)
        let foreground = NSApplication.didBecomeActiveNotification
        #else
        let foreground = UIApplication.willEnterForegroundNotification
        #endif
        for name in [foreground, Notification.Name.NSCalendarDayChanged, Notification.Name.NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        schedule(after: .seconds(5))
    }

    /// Every save bumps the store's revision (iCloud imports too, see `CloudImportRefresher`).
    private func observeRevision() {
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule()
                self?.observeRevision()
            }
        }
    }

    /// Debounced: bursts of saves and imports end in one sync.
    func schedule(after delay: Duration = .seconds(2)) {
        guard isRealStore else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        let snapshot = makeSnapshot()
        let result = await writer.write(snapshot)
        isAvailable = result.available
        catalog = result.catalog
        if result.wrote {
            lastWritten = snapshot.now
            UserDefaults.standard.set(snapshot.now, forKey: Prefs.thaliaLastWritten)
        }
    }

    /// Finished workouts of the last 62 days and all templates, from the synced store.
    private func makeSnapshot() -> ThaliaSnapshot {
        let now = Date()
        let completed = SessionStatus.completed.rawValue
        let partial = SessionStatus.partial.rawValue
        let descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.statusRaw == completed || $0.statusRaw == partial })
        let sessions = (try? store.context.fetch(descriptor)) ?? []
        let templates = store.fetchTemplates()
        let names = Dictionary(templates.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let oldest = now.addingTimeInterval(-Double(BinisoftExchange.keepDays + 2) * 86_400)
        let workouts: [ThaliaWorkout] = sessions.compactMap { session in
            let end = session.endedAt ?? session.date
            guard end >= oldest else { return nil }
            return ThaliaWorkout(
                id: session.id,
                title: session.title,
                templateID: session.templateID,
                templateTitle: session.templateID.flatMap { names[$0] } ?? session.templateName,
                endedAt: end,
                isFinished: session.status.isPerformed,
                // Watch workouts are in the synced store once George's own sync brought them here.
                source: session.recordedOnWatch ? .watch : .george
            )
        }
        return ThaliaSnapshot(
            enabled: isEnabled,
            workouts: workouts,
            templates: templates.map { ThaliaTemplate(id: $0.id, title: $0.name) },
            appVersion: AppVersion.main.marketing,
            now: now,
            timeZone: .current
        )
    }

    /// The Thalia measures (from Thalia's catalog on this device) that count this template's workouts.
    func measures(countingTemplate id: UUID) -> [ExchangeCatalog.Measure] {
        catalog?.measures(linkedTo: ThaliaExport.workoutLink(templateID: id)) ?? []
    }
}
#endif
