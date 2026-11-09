# George program CSV — format v1

One CSV file describes one or more **programs** (folders) with their **workouts** (templates).
Each row is one exercise. Header names are case-insensitive, column order doesn't matter,
unknown columns are ignored, and lines starting with `#` are comments. Comma, semicolon or tab
separated files all work. Use `.` for decimals.

## Columns

Only `exercise` is required. Everything else is optional.

**Program & workout** (repeat on every row, or fill only the first row of a workout — blank cells inherit from the row above)

| Column | Meaning | Example |
|---|---|---|
| `program` | Program (folder) name | `Elastic Bands – Tennis` |
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
| `rounds` | Rounds for the group (sets of each exercise are matched to it) | `3` |
| `rest_after_round` | Rest after each round of the group | `60s` |

**Exercise & sets**

| Column | Meaning | Example |
|---|---|---|
| `exercise` | Exercise name (**required**). Library names get images automatically. | `Band Face Pull` |
| `exercise_type` | Type for this exercise if different from the workout | `stretch` |
| `mode` | `reps`, `time` or `distance` (inferred if empty) | `time` |
| `sets` | Number of sets | `3` |
| `reps` | Reps: `12`, a range `8-12`, `AMRAP`, or per-set list `15,12,10` | `8-12` |
| `weight` | Weight per set, or per-set list `20,22.5,25` | `20` |
| `unit` | `kg` (default) or `lb` | `kg` |
| `load` | Free-text load, e.g. band color | `red band` |
| `duration` | Time per set: `30`, `30s`, `1:30`, `2 min` | `45s` |
| `distance` | Distance: `400`, `400m`, `1.5km`, `1 mi` | `400m` |
| `rest` | Rest after each set | `90` |
| `tempo` | Tempo notation | `3-1-1` |
| `rpe` | Target RPE (1–10) | `8` |
| `per_side` | `yes` if done per side/arm/leg | `yes` |
| `set_type` | `warmup`, `working` (default), `drop`, `failure` | `warmup` |
| `notes` | Coaching cue | `Elbows tucked` |
| `tutorial_url` | One or more links (space separated) | `https://youtu.be/…` |
| `muscles` | Primary muscles, `;` separated | `chest;triceps` |
| `equipment` | Equipment | `bands` |

## Rules worth knowing

- **Warm-up + working sets of the same exercise:** put them on consecutive rows with the same
  exercise name; George merges them into one exercise (e.g. 2 warm-up rows + 3 working rows).
- **Pyramids:** use lists in `reps`/`weight` (`15,12,10,8`). The set count grows to match the list.
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
