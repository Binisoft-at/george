<p align="center"><img src="design/icon-1024.png" width="160" alt="George app icon"></p>

# George – Your Gym Buddy

A workout manager for iPhone, iPad, Mac and Apple Watch that works the way an Apple Notes workout
log does — programs (folders), templates and dated sessions with checkable sets — but with a live
training mode, a real exercise library, smart streaks, Apple Health and a Watch companion.

## Highlights

- **Find your way in seconds** — iPhone/iPad: a Liquid Glass tab bar (Today · Workouts · Plans · Insights ·
  Search) with the running workout as a "now playing" bar above it; iPad shows programs in the sidebar.
  Mac: a three-column layout like Notes. **Today** shows what's next with one big Start button.
- **One place to create** — the **+** button starts, plans or logs a workout, creates templates (straight into
  the exercise picker) and programs, or imports a CSV. An interactive tutorial with try-it demos runs on
  first launch (Settings → Show the Tutorial).
- **Notes-style organisation** — Programs (folders) hold *templates* (UPPER, LOWER, FULLY…) and the
  *workouts* you did. Lists group like Notes (Today, Previous 7 Days, months) or by week, type, template,
  status or priority; sort, search with tokens, pin, favorite, prioritise, tag, plan with dates.
- **One tap instead of duplicate-move-rename** — ▶︎ on a template creates today's session named
  `W44: 3 UPPER - 29.10` (pattern configurable) and starts it. Rotation suggests the next template.
- **Edit anything, anytime** — add/swap/reorder exercises and sets, sections, supersets, circuits,
  EMOM/AMRAP, warm-up/drop/failure sets, per-side, tempo, RPE, band loads — also mid-workout. After a
  changed session George offers to update the template.
- **Live mode** — swipe between exercises (supersets side by side with "Match sets"), every set clearly
  done / now / open, tap a number for a big keypad (62,5 or 62.5) or drag it, a set timer against
  dawdling, momentum flame and a body figure that fills up, a voice coach (rest, "10 seconds", go, PRs),
  "how many reps were left?" in one tap and weight suggestions from it, calm mode for low-energy days,
  automatic rest timer, tutorial playback, keyboard shortcuts on Mac/iPad, mini player while you browse.
  See [docs/COACH.md](docs/COACH.md).
- **Finish & share** — confetti, counting stats, records, muscles worked and a share picture.
- **Energy** — a one-tap check-in, weekly patterns, a rhythm if you have one, links with workouts,
  sleep and HRV (Apple Health).
- **Exercise library** — 1,172 exercises: the public-domain [free-exercise-db](https://github.com/yuhonas/free-exercise-db)
  (gym, stretches, bands, with start/end images animated like a GIF) plus 296 curated elastic-band, yoga,
  stretching, mobility and tennis-prehab moves. Every exercise has a one-tap YouTube tutorial search; save your own links.
- **Smart streaks** — weekly goal (days/week, history-aware), saves earned every 2 successful weeks (max 3,
  auto-used), a "rescue workout" that counts double, excused break weeks, and Apple Health workouts from
  other apps count too.
- **Apple Health** — workouts with the right activity type, calories, heart rate (via Watch) and effort score.
  See [docs/HEALTH.md](docs/HEALTH.md) for what Bevel can read.
- **Apple Watch** — start workouts, check sets, rest countdown, heart rate; records the HealthKit workout.
- **CSV import/export** — another AI can write programs in [George's CSV format](docs/CSV_FORMAT.md);
  the app has a "Copy prompt for another AI" button ([docs/AI_PROMPT.md](docs/AI_PROMPT.md)).
- **Muscles** — freshness per muscle, sets per week, muscular load and a body map ([docs/MUSCLES.md](docs/MUSCLES.md)),
  with targets for your age, experience and goal ("Optimal for You", with sources).
- **Sync** — SwiftData + iCloud (CloudKit private database). Free, no account, works like Notes. Settings
  shows the sync status and explains where the data lives.
- **Design** — native SwiftUI on iOS/macOS 26 with Liquid Glass controls, light/dark/system themes.

### New in 1.1

- **Thalia**: George tells Thalia (Binisoft's planner) which workouts you finished – a small file per
  day in the shared App Group on each iPhone, iPad and Mac, never anything from Apple Health.
  Settings → Thalia; details in [docs/THALIA.md](docs/THALIA.md).

### New in v6

- **Hands-free**: Live Activity on the Lock Screen and in the Dynamic Island (what's due, the rest
  countdown, Start/Done, +15 s, skip rest), Siri and Shortcuts ("Start my workout in George",
  "Next set in George"), the Action Button, a Control Center control, Home/Lock Screen widgets
  (next workout, streak) and a watch complication.
- **Apple Watch as a remote**: log the reps and weight you really did, lower the weight, do another
  exercise now, skip, mute, answer the coach's questions, energy check-in, a summary after saving;
  the set is the hero, Double Tap for Start/Done (Resume while paused), wrist taps for 3-2-1 and a
  buzz to switch sides in per-side holds.
- **Live mode you can trust**: nothing ends by accident, "now" stays put through edits, Undo after
  each tick, real pause, relaunch continues where you were, calm stretch/yoga flow with per-side
  holds, − / + steppers, auto-scroll, warm-up sets, plates per side, your exercise notes.
- **Planning**: plan the week in one go, missed plans on Today, starting a template reuses its
  planned session, log tennis or a run without a template, reminders, reorder, "Add to…".
- **Insights that answer questions**: "Beat last time on 3 of 4", strength trends per lift (e1RM),
  muscular load in % of your usual week, honest numbers in the first weeks, other sports count in
  recovery.

## Project layout

George follows the Binisoft handbook, Binisoft's internal app conventions (version in
`.binisoft-handbook`). Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

| Path | What |
|---|---|
| `Packages/GeorgeCore` | All logic without Apple UI frameworks: workout model, CSV, streaks, naming, stats, muscles, tour catalog (tested on Linux) |
| `App/Sources` | iOS + macOS SwiftUI app (SwiftData models, services, views) |
| `Watch/Sources` | watchOS companion app |
| `Shared` | Code compiled into the phone and watch apps (HealthKit mapping) |
| `Config/` | Every identifier (`Base.xcconfig`), CI settings (`ci.env`), Info.plists and entitlements per platform |
| `cloudkit/schema.ckdb` | CloudKit schema of `iCloud.at.binisoft.george` |
| `Vendor/BinisoftKit`, `scripts/ci`, handbook workflows | Synced from the handbook – never edited here |
| `App/Resources/exercises.json` | Bundled exercise library (built by `make library`) |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is generated) |

## Build

```bash
make check   # without a Mac: Core tests + syntax check
make open    # on a Mac: generates George.xcodeproj and opens it
```

Requires Xcode 26+. Accounts, secrets, CloudKit and TestFlight: [docs/SETUP.md](docs/SETUP.md).

## Status, privacy, licence

- **Status**: in beta on TestFlight (iPhone, iPad, Mac, Apple Watch).
- **Privacy**: no servers, no accounts, no analytics. Workouts sync through the user's own private
  iCloud; Apple Health numbers stay on the device ([docs/HEALTH.md](docs/HEALTH.md)).
- **Licence**: © Binisoft LLC, all rights reserved – the source is public to read, not to reuse
  ([LICENSE](LICENSE)). Third-party data: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Feedback**: bug reports and ideas as GitHub issues are welcome; pull requests aren't accepted at
  the moment. Security problems: [SECURITY.md](SECURITY.md).
