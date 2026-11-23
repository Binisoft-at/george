# George program CSV — format v1

One CSV file describes one or more **programs** (folders) with their **workouts** (templates).
Each row is one exercise. Header names are case-insensitive, column order doesn't matter,
unknown columns are ignored, and lines starting with `#` are comments. Comma, semicolon or tab
separated files all work. Use `.` for decimals.

**Decimals and lists in semicolon files.** Excel and Numbers in a comma locale (Austria, Germany …)
save `;` files with `62,5`. In a semicolon file a comma in `weight`, `duration` and `distance` is
therefore a decimal point, and per-set lists are written with `/`: `60/62,5/65`. A cell with several
commas (`15,12,10`) is still a list. In a comma file a quoted `"62,5"` is read as 62.5 too (one digit
after the comma, or two when `sets` is 1); `"20,25"` with more sets stays a list of 20 and 25. `/`
works as a list separator in every file.

## Columns

Only `exercise` is required. Everything else is optional.

**Program & workout** (repeat on every row, or fill only the first row of a workout — blank cells inherit from the row above)

| Column | Meaning | Example |
|---|---|---|
| `program` | Program (folder) name | `Elastic Bands – Tennis` |
| `program_notes` | Notes for the program (first row is enough) | `12 weeks, deload in week 4` |
| `program_color` | Program color as hex | `#FF9500` |
| `workout` | Workout/template name | `UPPER` |
| `workout_subtitle` | Focus line shown under the name | `UPPER BODY + SHOULDER/WRIST HEALTH` |
| `workout_type` | `gym`, `band`, `bodyweight`, `core`, `hiit`, `cardio`, `stretch`, `yoga`, `mobility`, `sport`, `other` — or any word (e.g. `tennis`, `pilates`) | `band` |
| `workout_order` | Position in the program's rotation (1, 2, 3…) | `2` |
| `schedule` | Usual weekdays, separated by `;` | `Tue;Thu` |
| `workout_notes` | Notes for the whole workout | `Keep rest short` |
| `tags` | Tags separated by `;` | `tennis;prehab` |

**Structure**

| Column | Meaning | Example |
|---|---|---|
| `section` | Heading the exercise sits under | `WARM-UP`, `MAIN`, `FINISHER` |
| `group` | Same letter on consecutive rows = superset / circuit. `A1`, `A2` also work. Leave empty for straight sets. | `A` |
| `group_style` | `superset`, `circuit`, `emom`, `amrap`, `interval` (default: 2 exercises = superset, 3+ = circuit) | `superset` |
| `rounds` | Rounds for the group: each exercise gets this many working sets. Warm-ups and drop sets don't count and stay; extra working sets are left out with a warning. | `3` |
| `rest_after_round` | Rest after each round of the group | `60s` |

**Exercise & sets**

| Column | Meaning | Example |
|---|---|---|
| `exercise` | Exercise name (**required**). Library names get images automatically. | `Band Face Pull` |
| `exercise_type` | Type for this exercise if different from the workout | `stretch` |
| `mode` | `reps`, `time` or `distance` (inferred if empty) | `time` |
| `sets` | Number of sets | `3` |
| `reps` | Reps: `12`, a range `8-12`, `AMRAP`, or per-set list `15,12,10` | `8-12` |
| `weight` | Weight per set, or per-set list `20,22.5,25` (in semicolon files `20/22,5/25`). 0–1000 kg; other values are clamped with a warning. | `20` |
| `unit` | `kg` (default) or `lb` | `kg` |
| `load` | Free-text load, e.g. band color | `red band` |
| `duration` | Time per set: `30`, `30s`, `1:30`, `2 min` | `45s` |
| `distance` | Distance: `400`, `400m`, `1.5km`, `1 mi` | `400m` |
| `rest` | Rest after each set | `90` |
| `tempo` | Tempo notation | `3-1-1` |
| `rpe` | Target RPE (1–10; other values are clamped with a warning) | `8` |
| `per_side` | `yes` if done per side/arm/leg | `yes` |
| `set_type` | `warmup`, `working` (default), `drop`, `failure` | `warmup` |
| `notes` | Coaching cue | `Elbows tucked` |
| `tutorial_url` | One or more links (space separated) | `https://youtu.be/…` |
| `image_url` | Picture or GIF for the exercise | `https://…/face-pull.gif` |
| `muscles` | Primary muscles, `;` separated | `chest;triceps` |
| `equipment` | Equipment | `bands` |

## Rules worth knowing

- **Warm-up + working sets of the same exercise:** put them on consecutive rows with the same
  exercise name in the same section; George merges them into one exercise (e.g. 2 warm-up rows +
  3 working rows). The same exercise under a new `section` (WARM-UP, then MAIN) stays separate.
- **Pyramids:** use lists in `reps`/`weight` (`15,12,10,8`). The set count grows to match the list
  (with a warning when that's more than `sets` says – often a decimal comma read as a list).
- **Numbers that can't be stored** (`nan`, `inf`, `1e999`) are skipped with a warning; the rest of
  the workout imports.
- **Importing into an existing program:** nothing of yours is overwritten unless you turn on
  “Replace templates with the same name” (and confirm). Without it, a taken name gets a number
  (“UPPER (2)”) and the file's `program_notes` go below your notes under “— Imported <date> —”. With
  it, the template's exercises, notes, tags and weekdays and the program notes are replaced. George
  saves a full backup before every import (Settings → Import & Export).
- **Export and import back:** a program exported from George (program menu → Export as CSV…) holds its
  tags, pictures, program notes and color, so importing it again with “Replace” keeps them.
- **Supersets:** consecutive rows with the same `group` value. Different groups (`A`, `B`, `C`) are separate blocks.
- **Timed holds** (planks, stretches, yoga): give a `duration` and leave `reps` empty.
- Muscle names George understands: abdominals, abductors, adductors, biceps, calves, chest,
  forearms, glutes, hamstrings, hip flexors, lats, lower back, middle back, neck, obliques, quadriceps,
  shoulders, traps, triceps. They drive the muscle map, freshness and muscular load (see `docs/MUSCLES.md`);
  leave the column empty to use the exercise library's muscles.

## Example

```csv
program,workout,workout_subtitle,workout_type,workout_order,schedule,section,group,group_style,rounds,rest_after_round,exercise,sets,reps,weight,unit,load,duration,rest,per_side,set_type,notes
Elastic Bands – Tennis,UPPER,UPPER BODY + SHOULDER/WRIST HEALTH,band,2,Tue;Thu,PREHAB,,,,,External Rotation with Band,2,15,,,light band,,30,yes,warmup,Elbow tucked
Elastic Bands – Tennis,UPPER,,,,,PREHAB,,,,,External Rotation with Band,2,12,,,light band,,30,yes,,
Elastic Bands – Tennis,UPPER,,,,,MAIN,A,superset,4,75,Band Bent-Over Row,4,"15,12,12,10",,,heavy band,,,,,
Elastic Bands – Tennis,UPPER,,,,,MAIN,A,,,,Band Chest Press,4,"15,12,12,10",,,heavy band,,,,,
Elastic Bands – Tennis,UPPER,,,,,MAIN,,,,,Band Face Pull,3,15,,,medium band,,45,,,Pull to eyes
Elastic Bands – Tennis,UPPER,,,,,CORE,,,,,Side Plank,3,,,,,30s,30,yes,,
```

A complete sample lives in `samples/elastic-bands-tennis.csv`.

## Workout log export

Settings → Import & Export → **Export Workout Log (CSV)** writes what you did, for Numbers, Excel or
another AI to analyse. It is a readable log, **not a backup**: it can't be imported back (your
workouts live on your devices and in iCloud).

One row per set of every finished workout (completed or stopped early). A workout without sets —
tennis, a run or a class logged with Log Activity — gets one row of its own with the exercise
columns empty. The workout columns repeat on every row of that workout.

| Column | Meaning | Example |
|---|---|---|
| `date` | The day you trained, in your time zone (not UTC) | `2026-11-20` |
| `session` | Workout title | `W47: 2 UPPER - 20.11` |
| `program` | Program name (empty without one) | `Gym – Strength Block` |
| `type` | Workout type | `gym`, `tennis` |
| `duration_min` | Active minutes (pauses left out) | `48` |
| `status` | `completed` or `partial` (stopped early) | `completed` |
| `exercise`, `set`, `set_type` | Exercise name, set number, `working` / `warmup` / `drop` / `failure` | `Bench Press`, `2`, `working` |
| `done` | `yes` when the set was ticked | `yes` |
| `reps`, `weight`, `unit` | What you did (weight in your unit) | `8`, `60`, `kg` |
| `duration`, `distance`, `rpe` | Seconds, metres, RPE for timed, distance or rated sets | `45` |
| `target_reps`, `target_weight` | What the plan said | `8-10`, `60` |
| `started_at` | Local start date and time | `2026-11-20T18:05` |
| `effort` | Your effort rating, 1–10 (empty when not rated) | `7` |
| `kcal` | George's calorie estimate (body weight × time × activity). Measured calories from Apple Health stay on the device and aren't exported. | `312` |
| `notes` | The workout's notes | `Felt strong` |
