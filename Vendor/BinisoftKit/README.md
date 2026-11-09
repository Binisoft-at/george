# BinisoftKit

Shared Swift package for every Binisoft app (iOS / macOS / watchOS 26, Swift 5 language mode,
swift-tools 6.0). Synced into each app as `Vendor/BinisoftKit` by `tools/sync.sh` – **never edit it
inside an app**; change it in the handbook, tag, sync.

Two products:

- **`BinisoftKitCore`** – Foundation only, tested on Linux (`swift test --package-path kit/BinisoftKit`).
  An app's Core package depends on it (`.product(name: "BinisoftKitCore", package: "BinisoftKit")`).
- **`BinisoftKit`** – SwiftUI, SwiftData, CloudKit, TipKit; re-exports the core. App targets
  `import BinisoftKit`. Left out when the manifest is evaluated on Linux.

## Tour (Core: `Tour.swift`, UI: `TourCoach.swift`)

```swift
struct MyTourSnapshot: Equatable, Sendable { var itemCount = 0; var trashed = 0; var editorOpen = false }

enum MyTour {
    static let version = 2
    static let catalog = TourCatalog<MyTourSnapshot>.standard(appName: "Nora", version: version, steps: [
        TourStep(id: "add", symbol: "plus", title: "Add a plant", body: "Tap + …", macBody: "Press ⌘N …",
                 goal: .increased(\.itemCount)),
        TourStep(id: "undo", symbol: "arrow.uturn.backward", title: "Mistakes are fine", body: "…",
                 goal: .undone(\.trashed)),
        TourStep(id: "edit", since: 2, symbol: "pencil", title: "Edit", body: "…", goal: .isTrue(\.editorOpen)),
    ])
}
```

- Goals: `.none` (read and continue), `.increased`, `.decreased`, `.changed`, `.isTrue`, `.undone`
  (went up and back – delete then Undo), `.all([...])`, or a custom closure.
- `catalog.steps(newerThan: seen)` – full tour on first run, only the new steps ("What's new") after
  an update. `catalog.problems()` – check it in the app's Core tests.
- `TourSchedule().stepsToOffer(catalog)` / `markSeen(catalog)` – opens once after install/update.
- UI: on the practice page, inside its NavigationStack:
  `MyListView().tourCoach(steps: steps, snapshot: snapshot, startAt: launch.tourStep, onClose: finish)`.
  Build `snapshot` from `@Query`s on the demo store; each step ticks itself off and moves on.

## Log (Core: `AppLog.swift`, UI: `LogSupport.swift`, `LogView.swift`)

- `AppLog.bootstrap(appName:)` once at launch (file in Application Support, mirrored to the system log).
- `AppLog.info("…", category: "sync")`, `.notice`, `.warning`, `.error`, `.debug`. Counts and kinds, never private content.
- Settings: `NavigationLink { LogView(appName: "Nora", mode: mode) }` – filter, search, **Copy log**, share, clear.

## Sync status (Core: `SyncStatus.swift`, UI: `SyncMonitor.swift`, `SyncSettings.swift`)

- `SyncMonitor(mode:appName:)` watches NSPersistentCloudKitContainer events and the iCloud account
  (CKSyncEngine apps call `recordSync(...)`); `summary` = "On · synced 5 minutes ago".
- Settings: `SyncStatusSection(monitor:footer:) { DataLocationView(sections: DataSection.standard(appName:dataNoun:), monitor:) }`.
- `SyncErrorText.describe` turns schema / quota / network errors into sentences with the fix.

## Store (`ModelStore.swift`)

```swift
let opened = ModelStore.open(name: "Nora", models: [Plant.self], deviceOnlyModels: [HealthSample.self],
                             initializeCloudKitSchema: isDebugBuild, seedDemo: DemoData.seed)
// opened.container, opened.mode (.iCloud / .local / .memory / .demo)
let practice = ModelStore.inMemory(name: "NoraTour", models: [Plant.self], seed: DemoData.seedPractice)
```

`.private(AppCloudKitContainer)` + `groupContainer: .none`, device-only configuration for Health
data, Debug schema push, local and in-memory fallbacks, `-Demo` in-memory store.

## Records (`Records.swift`)

- `SoftDeletable` (`deletedAt`, `modifiedAt`): `moveToTrash()`, `restoreFromTrash()`, `touch()`, `isInTrash`.
- `TrashPolicy(keepDays: 30)`: `isExpired`, `daysLeft`.
- `ListOrder`: fractional sort orders – `between`, `after`, `before`, `move(_:from:to:)` for List `onMove`.

## Undo and toasts (`Toasts.swift`)

- `ToastCenter.show("Deleted …", symbol: "trash.fill") { restore() }` – floating glass toast with Undo.
- `.toasts(center)` on the window root; `.undoableChanges(in: container.mainContext)` for ⌘Z / shake.

## Theme and platform (`Theme.swift`, `Platform.swift`)

`Brand.accent` (AccentColor asset), `.card()` for content, `.floatingGlass()` for floating controls
only, `.primaryActionStyle()`, `Appearance` + `.appearanceFromSettings()` + `AppearancePicker`,
`Color.groupedBackground` / `.cardBackground`, `.inlineNavigationTitle()`, `.sheetFrame()`,
`.minimizingTabBar()`, `Clipboard`, `PlatformInfo`. Mac: `@NSApplicationDelegateAdaptor(MainWindowGuard.self)`
plus `.defaultLaunchBehavior(.presented)` – opens the main window if launch ended without one.

## Create, empty states, hints (`CreateSheet.swift`, `Tips.swift`)

- `CreateSheet(options: [CreateOption(...)], footnote:)` – the central "+".
- `EmptyStateView(title:message:symbol:createTitle:onCreate:onImport:)` – always offers "Import my data".
- `BinisoftTips.configure()` at launch; `BinisoftTips.requestReset()` for "Show hints again".

## Environment and import (Core: `AppEnvironment.swift`, `Import.swift`)

- `AppIdentifiers.main` (Info.plist `AppCloudKitContainer`, `SharedCloudKitContainer`, `SharedAppGroup`),
  `AppVersion.main.display`, `LaunchOptions.current` (`-Demo`, `-DemoScreen`, `-Tour`, `-TourStep`, `-ResetTour`).
- `SnapshotFile<T>` – small Codable files (widget snapshot); `AppGroupFolder.url(appName:)`.
- `CSV` (parse, records, write, encodings, delimiter detection), `ImportPlan` (create / update /
  unchanged by stable key – safe re-imports), `AIImportPrompt` (the "Copy prompt for another AI" text).
