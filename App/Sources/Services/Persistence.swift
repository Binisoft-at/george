import Foundation
import SwiftData
import BinisoftKit

/// Names used in texts and file paths. Identifiers live in Config/Base.xcconfig, not here.
enum AppInfo {
    static let name = "George"
    /// What George keeps, in the person's words.
    static let dataNoun = "workouts"
}

/// Opens George's store the Binisoft way (BinisoftKit `ModelStore`): synced through
/// `.private(APP_CLOUDKIT_CONTAINER)` with `groupContainer: .none`, Health numbers in a device-only
/// store, local-only when iCloud isn't available, sample data in memory for `-Demo`, and a separate
/// practice store for the tour.
enum Persistence {
    static let models: [any PersistentModel.Type] = [
        Program.self, WorkoutTemplate.self, WorkoutSession.self,
        UserExercise.self, ExcusedWeek.self, SyncedSettings.self, EnergyCheckIn.self,
    ]
    /// Health-derived numbers never go to iCloud (guideline 5.1.3(ii)).
    static let deviceOnlyModels: [any PersistentModel.Type] = [HealthMetrics.self]

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    @MainActor
    static func open() -> ModelStore.Opened {
        ModelStore.open(
            name: AppInfo.name,
            models: models,
            deviceOnlyModels: deviceOnlyModels,
            initializeCloudKitSchema: isDebugBuild,
            seedDemo: DemoData.seed
        )
    }

    /// The tour's practice page: in memory, seeded, never synced, gone when the tour closes.
    @MainActor
    static func practiceStore() -> ModelContainer {
        ModelStore.inMemory(name: "\(AppInfo.name)Tour", models: models + deviceOnlyModels, seed: DemoData.seedPractice)
    }
}
