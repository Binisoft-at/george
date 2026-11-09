# George – architecture

George follows the [Binisoft handbook](https://github.com/Binisoft-at/binisoft-handbook) (private;
version in [`.binisoft-handbook`](../.binisoft-handbook)). `Vendor/BinisoftKit`, `scripts/ci` and the four
handbook workflows are synced from it – change them there, never here.

## Targets

| Target | What |
|---|---|
| `George` (iOS/iPadOS) | Tab bar (Today · Workouts · Plans · Insights · Search, sidebar on iPad), now-playing bar for the running workout. Embeds the watch app. |
| `GeorgeMac` | Same sources: three-column split view, menu commands and shortcuts. |
| `GeorgeWatch` | Gets the running workout from the iPhone (WatchConnectivity), records it with HealthKit, shows sets and rest. No store of its own. |
| `Packages/GeorgeCore` | All logic without Apple UI frameworks: workout model and editing, CSV import/export, naming, streaks, stats, muscle analytics, body map, the tour catalog. Tested on Linux in CI. |

## Data

- SwiftData models in `App/Sources/Model`. `Persistence.open()` (BinisoftKit `ModelStore`):
  `.private(iCloud.at.binisoft.george)` with `groupContainer: .none`; Apple Health numbers
  (`HealthMetrics`) in a device-only store; local-only fallback; `-Demo` in-memory sample data.
- `GeorgeStore` is the one place that changes data (naming, ordering, denormalised fields, save,
  delete with Undo toasts). The window's undo manager is attached to the context (⌘Z, shake).
- The workout itself (`WorkoutContent`: blocks, exercises, sets) is a Codable value from GeorgeCore,
  stored as `contentData` on templates and sessions.
- CloudKit schema: [`cloudkit/schema.ckdb`](../cloudkit/schema.ckdb).

## Coach, energy, profile

Live mode, the voice coach, energy check-ins and the training profile are described in
[COACH.md](COACH.md). Logic (pace, progression, effort prompts, energy cycles, Health readiness,
profile targets, set editing) is in GeorgeCore and tested; the app holds only views and HealthKit.

## Navigation

`Router` (App/Sources/Views/Root/RootView.swift) drives both layouts: `sidebar`/`detail` on the Mac,
`tab` + one `[Route]` path per tab on iPhone/iPad. Screens open things with `router.open(...)` /
`router.show(...)` so the same code works on both.

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
ticked), `live-superset`, `muscles`, `energy`, `stats`, `streak`, `library`, `create`, `settings`,
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
