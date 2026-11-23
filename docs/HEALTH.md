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
  Health link (`LiveResume.PreStart.segmentStartedAt`). Taken over with Continue Here (no such time
  on that device), the new part is its last active time before the end, never before the first part
  ended (`MeasuredNumbers.partStart`) – not the whole workout again.
- **Calories and heart rate of a continued workout** cover both parts or neither. When both parts
  were measured, the calories are added up, the average heart rate is weighted by each part's active
  time and the higher maximum is kept. A number only one part (or neither) has is left out: George
  shows its own estimate for the whole workout's calories (≈) and no heart rate – one part's numbers
  never stand for the whole workout (`MeasuredNumbers.combined`). The finish screen, the workout's
  tiles, the recap and the share card all show these numbers. Finish keeps the first part's numbers
  on the device for three days (`EarlierPartNumbers`), so the watch's final numbers for the second
  part, which can come after Finish, are still added to them. The first part's own final watch
  numbers that come only once the workout was continued (the recording ended before the second part
  began) link and update the first part – they are not the second part's numbers, and live mode
  doesn't say the watch stopped (`MeasuredNumbers.isEarlierRecording`). Taken over with Continue Here, the
  device uses the first part's numbers it has stored itself (none: the estimate), and reads Apple
  Health's heart rate only for time after the first part ended. Numbers a device stored before the
  workout's (new) end are one part's only – it was continued and finished on another device, or
  ended from outside – so that device shows the estimate and no heart rate too, and doesn't add them
  to a later part as the earlier parts' (`MeasuredNumbers.keptNumbersCover`). The finish screen and
  share card show the stored numbers once there are any, like the tiles and lists, so the watch's
  final numbers arriving after Finish don't turn a measured number into "≈".
- **Watch or iPhone, never both.** Whether the watch was asked to record and has been heard from is
  kept with the running workout (`LiveResume`), so a relaunch doesn't make the iPhone save a second
  copy. A watch that should record but hasn't sent anything yet gets up to 15 s on Finish. The watch's
  numbers and its saved workout carry the George session id (`WatchMetrics.sessionID`), so the link
  and the effort score land on the right workout also when they arrive late; if the iPhone had saved
  its own copy without hearing from the watch, that copy (with its calories) is removed
  (`HealthLink.plan`, pending links kept on the device for three days).
- **Watch stopped on the way** (ended by watchOS, or on the watch while the phone goes on): its part
  stays linked and Finish saves the rest from the iPhone. Live mode says so in a small notice above
  the coach bar ("Apple Watch stopped recording – George saves the rest from iPhone"; toasts don't
  show in live mode), and the finish sheet's Health line too. When the watch stopped without saving
  a part (a late watch Discard the iPhone ignored), the iPhone saves the whole workout and both say so.
- **The watch's end is the workout's end.** The watch ends its `HKLiveWorkoutBuilder` collection at
  the end the phone gives it (`endCollection(at:)`): the phone's finish time from its snapshot
  (`lastFinished.finishedAt`, e.g. *End at last set*), or the end of a workout handed over to a Mac
  (`WatchSnapshot.handedOver`), when that lies after the recording's start and before now – else,
  and on any error, now (`WatchRecordingEnd.collectionEnd`). The end never goes before a pause or
  resume HealthKit already holds for the recording (a workout's events lie inside its time): a workout
  paused and left running ends where the watch heard the pause. A Finish tapped on the watch for a
  strength workout past 4 h waits up to 8 s for the phone's end (it moves to the last set there; an
  end from before this recording began, an earlier part's, isn't taken). Apple
  Health works out the workout's totals for its own start…end, so for a moved end the watch sends
  the saved workout's own heart rate and calories, not its running totals. Calorie samples the
  watch already wrote during the night stay in Health (they count toward the Move ring); only the
  workout itself is shortened.
- **Continue Here on a Mac** (no Apple Health there): the iPhone doesn't ask its watch to throw the
  recording away. It keeps a watch-only link on the device (`WatchOnlyLink`, UserDefaults
  `live.watchOnlyLink`, survives a relaunch) and its snapshots tell the watch to keep recording
  without showing the workout live (the watch's home screen says "The workout continues on your
  Mac"). When the synced workout ends – finished or stopped early on the Mac, discarded, deleted,
  or left running there for 12 h – the iPhone tells the watch to save at the workout's end or to throw
  the recording away, then links the watch's workout to it (`HealthMetadataKey.sessionID`, pending
  link with the effort rated on the Mac). Continued back on the iPhone, it picks the still-running
  recording up again (nothing counted twice) and the link goes, whatever it had told the watch; a
  recording the watch was told to throw away isn't counted on (the iPhone saves the workout unless the
  watch is heard again). An iPad or another iPhone that takes over saves the
  workout itself, so the watch throws its recording away there, as before. An older watch app saves
  its part at the hand-over; that part is linked when the workout ends, or kept as the watch's part
  when the workout comes back to the iPhone (Finish then saves the rest). A recording that stopped
  before the workout's end (an older watch's part, or ended on the watch) is linked without its
  calories and heart rate – one part's numbers never stand for the whole workout
  (`WatchOnlyLink.linkedMetrics`). George closed on the iPhone the whole time: at its next launch a
  workout that ended with a Mac's claim on it (continued there, or "Start … Anyway" there) gets the
  same link, so the watch saves at the workout's end, not at the launch. A Start on the iPhone that
  ends the Mac's workout as left running ends the watch's recording at its last sign of life.
- **Ended on another device** ("Start … Anyway" there): the device that ran it shows a toast
  ("UPPER was ended on your iPad"; the ending device writes its claim on the ended workout), and its
  watch saves the recording at the workout's end. A running workout deleted elsewhere throws the
  watch's recording away.
- **Discard** always tells the watch to throw its recording away, also before its first numbers; a
  recording of a discarded workout that was saved anyway is removed. Watch Finish and Discard count
  however late they arrive (same workout only) – except a watch Discard that arrives after the workout
  went on on the iPhone: it is ignored, and the watch, which closed the workout only from the tap
  (`WatchClosing`), shows it again with the iPhone's next snapshot (without recording it again).
- **At launch** workouts recorded on the watch whose link never arrived are linked again by the
  session id in the Health workout's metadata (last 7 days).
