# George – architecture

George follows the [Binisoft handbook](https://github.com/Binisoft-at/binisoft-handbook) (private;
version in [`.binisoft-handbook`](../.binisoft-handbook)). `Vendor/BinisoftKit`, `scripts/ci` and the four
handbook workflows are synced from it – change them there, never here.

## Targets

| Target | What |
|---|---|
| `George` (iOS/iPadOS) | Tab bar (Today · Workouts · Plans · Insights · Search, sidebar on iPad), now-playing bar for the running workout. Embeds the watch app. |
| `GeorgeMac` | Same sources: sidebar → list → detail like Notes (dashboards like Today, Muscles and Stats use the full width), live mode in a window of its own, menu commands and shortcuts. |
| `GeorgeWatch` | Gets the running workout from the iPhone (WatchConnectivity), records it with HealthKit, shows sets and rest, logs reps/weight and steers the plan through `WatchCommandEnvelope`s (time + workout id; stale ones are dropped). No store of its own. |
| `GeorgeWidgets` (iOS extension) | Live Activity / Dynamic Island (`Shared/WorkoutActivity.swift`, buttons are `LiveActivityIntent`s from `Shared/WorkoutIntents.swift`), Home/Lock Screen widgets reading `Shared/WidgetBridge.swift`'s JSON in the App Group, a Control Center control. App side: `LiveActivityBridge`, `App/Sources/Intents/GeorgeIntents.swift` (App Intents, App Shortcuts). |
| `GeorgeWatchWidgets` (watchOS extension) | The complication (rest countdown or next workout), data from `Watch/Sources/ComplicationBridge.swift`. |
| `Packages/GeorgeCore` | All logic without Apple UI frameworks: workout model and editing, CSV import/export, naming, streaks, stats, muscle analytics, body map, the tour catalog, the Binisoft exchange for Thalia. Tested on Linux in CI. |

## Data

- SwiftData models in `App/Sources/Model`. `Persistence.open()` (BinisoftKit `ModelStore`):
  `.private(iCloud.at.binisoft.george)` with `groupContainer: .none`; Apple Health numbers
  (`HealthMetrics`) in a device-only store; local-only fallback; `-Demo` in-memory sample data.
- `GeorgeStore` is the one place that changes data (naming, ordering, denormalised fields, save,
  delete with Undo toasts). The window's undo manager is attached to the context (⌘Z, shake).
- The workout itself (`WorkoutContent`: blocks, exercises, sets) is a Codable value from GeorgeCore,
  stored as `contentData` on templates and sessions.
- CloudKit can't keep records unique, so two devices may each create settings, an exercise's notes, a
  break week or the "Stretch & Yoga" folder before they sync. `GeorgeStore.resolveDuplicates()`
  (`GeorgeStore+Merge.swift`, rules in GeorgeCore `DuplicateMerge`) merges them at launch and after
  every iCloud import, the same way on every device. Settings changes go through
  `GeorgeStore.updateSettings` so the latest choice is known.
- Failed saves go to the App Log and show once as a toast; `SyncHealthBanner` (Today on iPhone/iPad,
  the Mac sidebar footer) says when nothing is saved or iCloud doesn't sync.
- `contentData` is never emptied or stripped (GeorgeCore `StoredContent`): the model setters keep data
  this build can't read or that a newer George wrote (`WorkoutContent.currentVersion`, bump it with
  every new content field), and NaN/infinity never turn a workout into empty data. Such a workout
  shows read-only ("Can't read this workout" / "Update George on this device to edit") and doesn't start.
- Backups (`GeorgeStore+Backup.swift`, format in GeorgeCore `BackupArchive`): Settings → Import &
  Export → Export Full Backup… / Restore from Backup…; automatic ones weekly and before every import
  or restore in Documents/Backups (last 8, visible in Files). A restore merges by id: missing records
  come back, changes made since stay unless asked for, records added since are never touched. Plain
  files – no CloudKit schema change.
- Change counters (what views and caches refresh on): `GeorgeStore.revision` moves when a save or
  an iCloud import changed any data, `historyRevision` only when performed workouts changed (finished,
  logged, edited, deleted, synced), `liveRevision` when a workout running on another device moved on.
  Saves classify what they change (`ModelContext.willSave`, autosaves included); nothing changed means
  nothing moves, and `save(bumping: false)` (live sets, Finish's waits) keeps it for the next bump.
  After an import `CloudImportRefresher` compares a cheap fingerprint (GeorgeCore `SyncFingerprint`):
  a set ticked on the iPhone doesn't make an idle Mac rebuild its history or Today. The history index
  (`SessionHistory`, GeorgeCore `HistoryIndex`) decodes only workouts that are new or changed since
  it last looked (the first build decodes on all cores); the muscle engine and "last time" rebuild only
  when its records really changed. Lists of numbers fetch without the content (`sessionScalars`) and by
  date (`fetchSessions(datedFrom:)`) instead of the whole log.
- What views ask for on every redraw is kept until its inputs change (`GeorgeStore+Caches.swift`):
  the calendar (per week start and time zone), the profile, the training days and the streak (per
  `revision`, settings and Apple Health workouts; a streak stays for the day until a workout dated later
  that day counts – GeorgeCore `StreakEngine.evaluatesAlike`), today's workouts (per `historyRevision`
  and day) and the suggested template (per `revision` and day). Muscular load is kept per muscle, days
  and day while the engine stays the same (`MuscleAnalytics.loadSummary`); Up next keeps its readiness
  numbers per suggestion, revision, engine and quarter hour.
- Editing a finished workout or a template writes typed numbers once typing pauses (0.5 s), saved
  without a bump; the bump comes once when editing ends (leaving the screen or the app, Done, Start,
  Plan, Log, Share). A tick is written at once (the status follows it). The exercise picker searches
  after a short pause (0.12 s) and reads its "Recently Used" once; the Workouts list filters 0.15 s
  after typing and decodes a row's exercises only when its preview opens.
- CloudKit schema: [`cloudkit/schema.ckdb`](../cloudkit/schema.ckdb).
- Thalia exchange ([THALIA.md](THALIA.md)): `ThaliaSync` (App/Sources/Services/ThaliaExchange.swift)
  rebuilds the last 62 days of finished workouts from the synced store and writes changed day files
  into `<App Group>/George/exchange/` (format and writer in GeorgeCore `ExchangeFormat.swift` /
  `ThaliaExport.swift`). Not on the Watch, not for `-Demo` or in-memory stores.

## Live ownership (which device runs a workout)

- One device runs a workout in progress at a time. `WorkoutSession.liveDeviceID` holds
  "<install id>|<kind>" – an id each install makes once and keeps in UserDefaults (`ThisDevice`,
  `Prefs.installID`) plus iPhone, iPad or Mac, never the device's name – and `liveClaimedAt` when it
  claimed the workout. Start and Continue Here claim it and save at once (`LiveWorkoutController.claim`);
  the device also keeps its own claim time (`Prefs.liveClaimedAt`).
- The device that ran it before sees the newer claim with the next iCloud import (`syncedStatusChanged`)
  or at the latest before its next save, tick, pause or Finish (`confirmOwnership`), and lets go
  without touching the synced session: live mode closes, the watch gets no workout (and drops its
  recording – the device that finishes saves the workout to Apple Health), the Live Activity and rest
  alert end, its resume state is cleared, and a toast says "Continued on your Mac". A relaunch doesn't
  take it back. A claim older than the device's own is answered with its claim again, so both
  devices end up agreeing (rules and tests: GeorgeCore `LiveOwnership`).
- No claim (older builds don't write the fields): the old rule – the workout this device started
  (`Prefs.liveSessionID`). Safety net either way: every save of the running workout first merges a copy
  someone else wrote since (`WorkoutContent.writtenElsewhere` / `mergedLive` – done on either side stays
  done, the later tick's numbers win, sets and exercises only one side has are kept).
- Screens name the owner's kind ("Running on your Mac", "On your iPad"). Watch starts go through
  the same start check as every Start button, so they never start a second workout next to one
  running elsewhere. The two fields are in `cloudkit/schema.ckdb` (deploy to Production before release).

## Coach, energy, profile

Live mode, the voice coach, energy check-ins and the training profile are described in
[COACH.md](COACH.md). Logic (pace, progression, effort prompts, energy cycles, Health readiness,
profile targets, set editing) is in GeorgeCore and tested; the app holds only views and HealthKit.

## Navigation

`Router` (App/Sources/Views/Root/RootView.swift) drives both layouts: `sidebar`/`detail` on the Mac,
`tab` + one `[Route]` path per tab on iPhone/iPad. Screens open things with `router.open(...)` /
`router.show(...)` so the same code works on both.

On the Mac, `SplitRootView` is one `NavigationSplitView` for every sidebar item, so switching never
builds the sidebar anew (counts, scroll position and width stay). macOS always shows a three-column
split view's middle column, so it has two columns: the sidebar and `MacMainColumn`, which lays out a
list, a draggable edge (GeorgeCore `ResizableColumn`, width kept per window) and the list's selection
with `detailPath` on top (Back) – or a dashboard at full width with what's opened from it on
`detailPath`. Live mode is a `Window` of its own (`LiveWindow.swift`): the main window opens it and
brings it forward (`LiveWindowPresenter`), `isPresented` there means "the workout window is in
front", and closing it only hides live mode – the bar at the bottom of the main window or ⌘↩ bring it
back. The keypad is a popover on the clicked value and Pace & Controls an inspector column. File,
Go and Help menu items and Settings' Tour/Welcome/Import bring the main window forward
(`MainWindowFront`) or open it again when it was closed.

On iPad at regular width, Workouts, Plans and the program tabs are a list + detail split
(`SplitTabStack`, ListDetailSplit.swift): the list column keeps the tab's path (lists opened from
Plans stack there), rows select like on the Mac (`NavList`/`DetailLink`), and the chosen item sits
in the detail column (`splitDetail`, with what's opened from it on `splitPaths`). When the window
gets narrow, `setSplit` folds it back into the tab's path (GeorgeCore `ListDetailPath`, tested).
Today (two columns from 840 pt) and Muscles (map left, muscles right from 760 pt) read their width
with `onGeometryChange` and use it on the Mac and iPad.

## Help

- **Welcome & setup** (`WelcomeView`): first launch – what George does, small demos, weekly goal,
  units, how to start. Ends by offering the tour.
- **Hands-on tour** (`TourView`, BinisoftKit tour engine, steps in `GeorgeCore/GeorgeTour.swift`):
  the real template screen on a practice copy; each step ticks itself off. New steps with
  `since: version + 1` become "What's new" after an update.
- TipKit hints (`GeorgeTips`), App Log with "Copy log" (Settings → Diagnostics).

## Launch arguments (CI screenshots, support)

`-Demo` (sample data in memory, nothing syncs, no hints, no automatic welcome), `-DemoScreen <name>`
(`today`, `workouts`, `plans`, `templates`, `template`, `session`, `live`, `live-mid` (a few sets
ticked), `live-superset`, `live-panel`, `live-feedback`, `live-looking`, `live-offplan`, `finish`,
`share-card`, `share`, `voice`, `muscles`, `energy`, `stats`, `streak`, `library`, `create`, `settings`,
`welcome`), `-Tour`, `-TourStep <id>`, `-ResetTour`. Demo launches also get sample energy
check-ins and Health signals.
Screens for `[screenshots]` runs are listed in [`Config/ci.env`](../Config/ci.env).

## Deliberate differences from the handbook

- **Deletes are undone through the undo manager**, not soft delete with "Recently Deleted" – George's
  models have no `deletedAt` yet. (Handbook proposal: an undo-manager based delete helper in the kit.)
- **Create sheet**: George's own `WorkoutCreateSheet` with multi-step flows (start, plan, log past,
  new template) instead of the kit's flat `CreateSheet`.
- **Welcome pages** in addition to the kit tour, because streaks, muscles and sync can't be practised
  on one page.
- **Core tests use XCTest** (written before the handbook); new tests may use Swift Testing.
- **No widgets yet** (`HAS_WIDGETS=0`).
