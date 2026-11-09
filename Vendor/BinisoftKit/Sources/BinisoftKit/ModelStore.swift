import Foundation
import SwiftData
import CoreData
import BinisoftKitCore

/// Opens an app's SwiftData store the Binisoft way (Theo + George):
///
/// - Synced data: `ModelConfiguration(..., groupContainer: .none, cloudKitDatabase: .private(<own container>))`.
///   Both are explicit because the entitlements also list the shared Binisoft container and App
///   Group: `.automatic` would pick the first container and put the store into the shared group.
/// - Device-only data (anything from Apple Health): a second configuration with `cloudKitDatabase: .none`.
/// - Debug builds push the complete CloudKit schema once, so Development never misses a field.
/// - No iCloud (unsigned CI builds, no entitlement, store error): the same store, local only.
///   Nothing opens at all: an in-memory store, and Settings says so.
/// - `-Demo`: a separate in-memory store with sample data that never syncs.
public enum ModelStore {
    public struct Opened {
        public let container: ModelContainer
        public let mode: StorageMode
    }

    @MainActor
    public static func open(
        name: String,
        models: [any PersistentModel.Type],
        deviceOnlyModels: [any PersistentModel.Type] = [],
        identifiers: AppIdentifiers = .main,
        launch: LaunchOptions = .current,
        initializeCloudKitSchema: Bool = false,
        seedDemo: (@MainActor (ModelContext) -> Void)? = nil
    ) -> Opened {
        let schema = Schema(models + deviceOnlyModels)
        if launch.isDemo {
            AppLog.info("Demo launch: sample data in memory, nothing syncs", category: "store")
            return Opened(container: inMemory(name: "\(name)Demo", models: models + deviceOnlyModels, seed: seedDemo), mode: .demo)
        }

        let device: [ModelConfiguration] = deviceOnlyModels.isEmpty ? [] : [
            ModelConfiguration("\(name)Device", schema: Schema(deviceOnlyModels), groupContainer: .none, cloudKitDatabase: .none),
        ]

        var reason: String
        if let containerID = identifiers.appCloudKitContainer {
            do {
                let synced = ModelConfiguration(name, schema: Schema(models), groupContainer: .none,
                                                cloudKitDatabase: .private(containerID))
                #if !os(watchOS)
                if initializeCloudKitSchema {
                    pushCloudKitSchemaOnce(name: name, models: models, containerID: containerID, storeURL: synced.url)
                }
                #endif
                let container = try ModelContainer(for: schema, configurations: [synced] + device)
                AppLog.info("Store opened, syncing with \(containerID)", category: "store")
                return Opened(container: container, mode: .iCloud(container: containerID))
            } catch {
                reason = "iCloud store couldn't open: \(error.localizedDescription)"
                AppLog.error(reason, category: "store")
            }
        } else {
            reason = "No iCloud container in Info.plist (AppCloudKitContainer)"
            AppLog.notice(reason, category: "store")
        }

        do {
            let local = ModelConfiguration(name, schema: Schema(models), groupContainer: .none, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [local] + device)
            AppLog.notice("Store opened on this device only", category: "store")
            return Opened(container: container, mode: .local(reason: reason))
        } catch {
            let message = "Local store couldn't open: \(error.localizedDescription)"
            AppLog.error(message, category: "store")
            return Opened(container: inMemory(name: "\(name)Memory", models: models + deviceOnlyModels, seed: nil),
                          mode: .memory(reason: message))
        }
    }

    /// A throwaway in-memory store (tour practice page, demo launches, previews).
    @MainActor
    public static func inMemory(name: String, models: [any PersistentModel.Type],
                                seed: (@MainActor (ModelContext) -> Void)?) -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true,
                                               groupContainer: .none, cloudKitDatabase: .none)
        // An in-memory store only fails to open when the process is out of memory.
        let container = try! ModelContainer(for: schema, configurations: configuration)
        if let seed {
            seed(container.mainContext)
            try? container.mainContext.save()
        }
        return container
    }

    #if !os(watchOS)
    /// Pushes every record type and field (even ones no saved record has used yet) to the
    /// Development environment once per container, so "deploy the schema to Production" never
    /// leaves fields missing. Debug builds only.
    @MainActor
    private static func pushCloudKitSchemaOnce(name: String, models: [any PersistentModel.Type],
                                               containerID: String, storeURL: URL) {
        let key = "binisoft.cloudKitSchemaInitialized.\(containerID)"
        guard !UserDefaults.standard.bool(forKey: key),
              let model = NSManagedObjectModel.makeManagedObjectModel(for: models) else { return }
        do {
            try autoreleasepool {
                let description = NSPersistentStoreDescription(url: storeURL)
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
                description.shouldAddStoreAsynchronously = false
                let container = NSPersistentCloudKitContainer(name: name, managedObjectModel: model)
                container.persistentStoreDescriptions = [description]
                let load = LoadResult()
                container.loadPersistentStores { _, error in load.error = error }
                if let error = load.error { throw error }
                try container.initializeCloudKitSchema()
                for store in container.persistentStoreCoordinator.persistentStores {
                    try container.persistentStoreCoordinator.remove(store)
                }
            }
            UserDefaults.standard.set(true, forKey: key)
            AppLog.info("CloudKit development schema pushed for \(containerID)", category: "store")
        } catch {
            AppLog.warning("CloudKit schema push skipped: \(error.localizedDescription)", category: "store")
        }
    }
    #endif
}

#if !os(watchOS)
/// Carries the synchronous `loadPersistentStores` result out of its completion handler.
private final class LoadResult: @unchecked Sendable {
    var error: Error?
}
#endif
