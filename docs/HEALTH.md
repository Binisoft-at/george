# Apple Health, Apple Watch & Bevel

## What George writes to Apple Health

| Data | How | Who reads it |
|---|---|---|
| **Workout** (`HKWorkout`) | Activity type per workout type (below), start/end, duration | Fitness, Bevel, Athlytic, Strava… |
| **Active energy** | From the Apple Watch session when it ran; otherwise estimated (MET × body weight × time, scaled by effort) | Fitness rings, Bevel |
| **Heart rate** | Recorded by the George Watch app's live workout session (`HKWorkoutSession` + `HKLiveWorkoutBuilder`) and attached to the workout | Bevel strain, Fitness, everything HR-based |
| **Workout effort score** (1–10) | Your rating at the end, related to the workout (`workoutEffortScore`, iOS 18+) | Fitness training load; **Bevel reads this field** |
| **Metadata** | `HKMetadataKeyIndoorWorkout`, brand "George", and custom keys: session id, title, exercises, muscles, completed sets, volume (kg) | Kept with the workout; most apps ignore custom keys |

Workout type → HealthKit activity type:

| George | HealthKit |
|---|---|
| Gym | Traditional Strength Training |
| Elastic Band, Bodyweight | Functional Strength Training |
| Core | Core Training |
| HIIT | High Intensity Interval Training |
| Cardio | Mixed Cardio |
| Stretching | Flexibility |
| Yoga | Yoga |
| Mobility & Prehab | Preparation and Recovery |
| Sport / tennis | Tennis |
| pilates, climbing, swimming, cycling, walking, running, boxing, dance, rowing | matching types |

## Privacy rule: health numbers stay on the device

App Store guideline 5.1.3(ii) forbids storing personal health information in iCloud. George therefore keeps
heart rate and measured calories in a **device-only** store (`HealthMetrics`), never in the iCloud-synced
database. Other iPhones/iPads read them back from Apple Health (which syncs itself) using the workout's
Health ID; the Mac shows George's own calorie estimate instead. Workouts, sets, notes and the effort
rating you type in are your training log and sync normally.

## What George reads

- **Workouts from other apps/devices** (e.g. a tennis session tracked on the Watch) — counted toward the weekly streak if ≥ the minimum length (Settings → Streak).
  They are read on iPhone/iPad only and never synced: **on the Mac** (no HealthKit) the streak, muscular
  load and freshness leave them out. The Mac says so under the streak and the load card, shows only
  "x/y days logged in George" instead of "at risk"/rescue/save wording, and offers no rescue workout.
- **Heart rate** during a session (average/max) when the watch app wasn't used but the Watch recorded HR anyway.
- **Body mass** for calorie estimates.
- **HRV, resting heart rate and sleep** (daily, last ~4 months) – today's values against your 30-day
  usual give the "take it easy today" hint in the energy check-in and the links in Insights → Energy.
  Settings → Workout Coach → Health signals turns it off.
- **State of Mind** (moods logged in the Health app) – optional, fills in days without an energy
  check-in on the Energy page.
- **Date of birth** – only when you tap "Use Age from Apple Health" in Settings → Your Profile.

None of these are stored in iCloud: signals and moods are read when needed and kept in memory, the
age from Health is kept in this device's preferences.

## What Bevel can (and can't) use

Bevel imports everything from Apple Health. For a George workout it gets the workout type, duration,
energy, heart-rate samples (→ strain / training load) and the effort score (Bevel reads the Apple Health
RPE/effort field). **Muscle groups, sets, reps and weights cannot be transferred**: HealthKit has no
data type for exercise-level strength data, and Bevel's muscle map only uses workouts logged in
Bevel's own strength logger. George stores the muscles and exercises in the workout's metadata so the
information is not lost, but other apps won't display it.

To get the best numbers in Bevel:
1. Use the George Apple Watch app during workouts (or start the workout on the phone — George launches
   the watch app automatically when a watch is paired) so heart rate is sampled continuously.
2. Rate your effort when finishing.

## Apple Watch companion

- Shows streak, planned workouts and your templates (active program first, suggested one marked).
- Start a workout from the watch or the phone; the phone owns the data and mirrors the live state.
- Check off sets, see the current exercise and rest countdown, pause/resume, finish with an effort rating.
- Runs an `HKWorkoutSession`, so heart rate and calories are recorded and the workout is saved to
  Health from the watch (the phone then attaches the effort score instead of saving a duplicate).

## One George workout, one Apple Health workout (v7)

- **When it ended.** The end is clamped into the workout and used for the time, calories, stats and
  Health alike: a time chosen on the finish sheet (*End at last set*), the tap time of a watch's
  Finish, else now – and a gym/band/bodyweight workout whose clock passed 4 h ends at its last set
  + rest (`FinishTime`). Pauses go to Health as pause/resume events, so its duration leaves them out.
- **Continued workouts** ("stopped early", continued later) add only the new part to Health: its
  start, active time and heart-rate window begin where it was continued, and the first part keeps its
  Health link (`LiveResume.PreStart.segmentStartedAt`).
- **Watch or iPhone, never both.** Whether the watch was asked to record and has been heard from is
  kept with the running workout (`LiveResume`), so a relaunch doesn't make the iPhone save a second
  copy. A watch that should record but hasn't sent anything yet gets up to 15 s on Finish. The watch's
  numbers and its saved workout carry the George session id (`WatchMetrics.sessionID`), so the link
  and the effort score land on the right workout also when they arrive late; if the iPhone had saved
  its own copy without hearing from the watch, that copy (with its calories) is removed
  (`HealthLink.plan`, pending links kept on the device for three days).
- **Watch stopped on the way** (ended by watchOS, or on the watch while the phone goes on): its part
  stays linked and Finish saves the rest from the iPhone ("Watch stopped recording").
- **Discard** always tells the watch to throw its recording away, also before its first numbers; a
  recording of a discarded workout that was saved anyway is removed. Watch Finish and Discard count
  however late they arrive (same workout only).
- **At launch** workouts recorded on the watch whose link never arrived are linked again by the
  session id in the Health workout's metadata (last 7 days).
