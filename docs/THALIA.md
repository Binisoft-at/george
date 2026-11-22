# Thalia exchange (Binisoft exchange format v1)

George tells Thalia (Binisoft's planner for weekly plans and yearly goals) which workouts were done.
It writes small JSON files into the shared App Group on the same device; Thalia reads them, keeps
them in its own iCloud inbox and counts from them. No network, no server, no permission prompt.
George only reads Thalia's catalog (structure only) and never changes Thalia's data.

## Mapping

| George | Exchange |
|---|---|
| A finished workout (status *Completed* or *Stopped early*, the same as streaks and stats count) | one fact `workout.done` on the calendar day of its end (device time zone) |
| `WorkoutSession.id` (synced UUID) | `id` = `"wo-" + UUID` |
| `WorkoutSession.templateID` / the template's name | `ref` / `refTitle` |
| no template | `ref` `"frei"`, `refTitle` `"Freies Workout"` |
| `WorkoutSession.title` | `title` |
| `WorkoutSession.endedAt` (or its start if no end was logged) | `at` |
| — | `origin` `"app"`; no `value`, no `metric` |
| all templates | `source.json` → `refs` (`"kind":"workout"`) plus `"frei"` |

Never written: planned, running and skipped workouts; workouts George only reads from Apple Health
(other apps, or George's own Watch workouts as Health stores them); any number from Apple Health
(heart rate, energy, distance, duration). Workouts recorded on the Watch arrive through George's
own sync (Watch → iPhone transfer, CloudKit) and are then written like any other workout.

## Files

`<group.at.binisoft.shared>/George/exchange/`

- `source.json`: heartbeat and the list of templates; written when the templates or the app
  version change, otherwise at most once a day.
- `days/YYYY-MM-DD.json`: one complete file per day. A day that had a file and now has nothing gets
  `"facts":[]`; a day that never had anything gets no file. Files older than 62 days are deleted.

JSON is UTF-8, compact, sorted keys, unescaped slashes; dates are ISO 8601 with the device's offset
and no fractional seconds. Writes are atomic, and the Darwin notification
`at.binisoft.exchange.changed` follows each write.

## When George writes

The last 62 days are rebuilt from the synced store and only changed days are written (compared
without `generatedAt`, so unchanged files keep their bytes):

- about 2 s after George saves (store revision),
- right after an iCloud import (`NSPersistentCloudKitContainer` import event),
- when George comes to the foreground, and when the day changes.

Never on the Watch, never from the demo/screenshot store (`-Demo`), the tour's practice store,
SwiftUI previews or an in-memory store. Writing happens off the main thread, never delays launch or
saving, and only logs problems. On the Mac, George first checks (off the main thread, not at launch)
that the signed app has the App Group entitlement; without the group (unsigned CI builds) nothing
is written.

## Code

- `Packages/GeorgeCore/Sources/GeorgeCore/ExchangeFormat.swift`: the format (paths, file names,
  clean-up, atomic writes, encoding, tolerant reader with German reasons, dates, FNV-1a), written to
  Thalia's specification.
- `Packages/GeorgeCore/Sources/GeorgeCore/ThaliaExport.swift`: George's facts and refs, and
  `ThaliaExchangeWriter` (day files and `source.json`), tested on Linux in a temporary folder.
- `App/Sources/Services/ThaliaExchange.swift`: App Group folder, entitlement check, Darwin
  notification, catalog, triggers.
- Settings → **Thalia**: the switch "Send to Thalia" (on by default), when George last wrote, and a
  hint that Thalia picks the workouts up when it is opened on this device. A template's page shows
  the Thalia measure that counts it, if Thalia's catalog has one.

Turning the switch off counts as "nothing there": the next sync rewrites the affected days with
`"facts":[]`, and Thalia removes them. The switch is stored on this device (George's synced
settings record has no free JSON field, and a new field needs a CloudKit schema deploy).
