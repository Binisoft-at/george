# Muscles: freshness, muscular load, sets & volume

George looks at your logged gym work per muscle. It only uses what you log in George (sets, reps,
weight, set type, RPE, the workout's effort rating). It does **not** use sleep, HRV, resting heart
rate or cardio fitness, so it is not a general "recovery score".

Where to find it: sidebar → **Insights → Muscles**, the cards at the top of **Stats & Records**,
the **Targets** section of a template, **Muscles worked** on a logged workout, the post-workout
summary, and the readiness hint on the **Up next** card. On the Mac and iPad (760 pt or wider) the
Muscles screen shows the metric, a larger body map and the filters on the left and the muscles on the right.

## From sets to muscles

- Each exercise's muscles come from the exercise library (primary and secondary), or from the
  muscles you set on the exercise (these replace the library's primary muscles).
- **Fractional sets:** a set counts 1 for primary muscles and 0.5 for secondary muscles. This is the
  counting method that best explains growth in dose–response meta-analyses (Pelland et al.).
- Obliques and hip flexors are not in the library data, so George infers them from the movement
  (twists, woodchops, side planks, Pallof presses → obliques; leg/knee raises, mountain climbers → hip flexors).
- Warm-up sets count no sets and a quarter of the load.

## Hard-set load

Every completed set becomes "hard-set equivalents" per muscle:

| Factor | Value |
|---|---|
| Set type | warm-up 0.25 · working 1 · drop 0.75 · to failure 1.1 |
| Effort | 0.5 + RPE × 0.0625 (RPE 8 → 1.0); the workout's effort rating is used when a set has no RPE |
| Workout type | stretching / yoga / mobility 0.15 · cardio 0.4 · everything else 1 |
| Muscle | primary 1 · secondary 0.5 |

Stretching, yoga, mobility and cardio add this (small) load but **no hard sets** – a stretch-only week
doesn't fill your weekly set targets (`MuscleEngine.countsAsHardSets`).

**Other sports** (v6, Settings → Training → *Count other sports in muscle recovery*): Apple Health
workouts such as tennis, runs, rides, hikes, HIIT, swimming or climbing add load to the muscles that
sport uses – scaled by duration (per hour) and effort (5 = neutral) – but never sets
(`GeorgeCore/SportLoad.swift`). So freshness is honest on the day after two hours of tennis.

## Freshness (per muscle)

- Each set adds fatigue `load / capacity` that fades as `e^(−t/τ)`.
- τ (how fast fatigue fades) depends on the muscle: 30 h for big muscles (quads, glutes, hamstrings,
  lats, upper and lower back, chest), 24 h for medium ones (shoulders, traps, adductors, abductors,
  hip flexors, obliques), 20 h for small ones (arms, calves, abs, neck).
- **Capacity** starts at 10 hard sets (roughly where one session per muscle stops adding much) and
  is personalised to 1.25 × your median session load for that muscle (between 6 and 16) once you
  have three sessions within six weeks.
- Freshness = 1 − remaining fatigue. **Recovered** ≥ 80 %, **Recovering** 40–80 %, **Depleted** < 40 %.
  "Ready in ~X h" solves the decay for the time to reach 80 %.
- **Calibrating:** fewer than three workouts that trained the muscle in the last six weeks.

## Muscular load (whole body or one muscle)

- **Acute:** the load of the last 7 days. **Chronic:** the weekly average of the history so far –
  up to 6 weeks, at least 2 (v6: before, the first weeks were divided by 6 weeks and steady training
  read as "Fatigued"). Shown as **% of your usual week** ("150 % of your usual week").
- **Optimal range:** 80–130 % of the chronic value (beginners and 60+: 80–120 %, from Your Profile).
- **Status** from the acute:chronic ratio:
  - < 0.8 Detraining
  - 0.8–1.0 Maintaining, or **Peaking** if the ratio was ≥ 1.1 within the previous two weeks (tapering off a hard block)
  - 1.0–1.3 Productive (up to the profile's upper bound)
  - up to 0.2 above it: **High** (was "Fatigued")
  - beyond: **Big jump** (was "Overtraining")
  - Ratios of the first two weeks don't count toward "Peaking".
- **Volume check (v6.2):** High and Big jump are only shown when at least one muscle got more sets
  in the last 7 days than your profile's weekly upper target (10–16 → 16, …). A normal week after
  lighter weeks is far above the "usual" average, but that's coming back to training, not overload:
  it shows as Productive with "More than your recent weeks, but a normal amount per muscle".
- **Units:** load adds up every muscle a set trains (a bench press set counts for chest 1, triceps
  ½, shoulders ½), weighted by set type, effort/RPE and the fatigue answer – a 17-set workout gives
  ~40 load. The card therefore shows real sets next to the %: "52 sets in 7 days · usual ≈ 24 a
  week" (each set once; cardio, stretching and yoga add no sets).
- **Calibrating** until there are 14 days since the first logged set and at least 4 sessions
  (whole body) or 3 sessions (one muscle) in the last six weeks.
- Only the shown days (plus 84 days for the long average and 42 for the calibration window) are
  read – not the whole log; the result is the same (tested against the full walk on three years).

## Sets per week

The muscle screen and the per-muscle chart show fractional sets per week against your target band
from Settings → Your Profile (e.g. 10–16 for an intermediate building muscle; defaults when not set).
While the history is shorter than the range, the average only counts the weeks with data (from the
week of the first logged set: 8 weeks of 12 sets read 12 a week on 1Y, not 1.8), and the footer says
so. The Load metric's rows show "Load 12" – effort-weighted load, never called sets.
Recovery estimates stretch with age (×1 up to 30, +0.8 % a year, at most ×1.35). Details and sources:
[COACH.md](COACH.md#your-profile--whats-optimal-for-you).

## Body map

The front/back body map is drawn from `scripts/body_map.py` (the source of truth). Regenerate the
Swift data after editing it:

```bash
python3 scripts/body_map.py swift > Packages/GeorgeCore/Sources/GeorgeCore/BodyMapData.swift
```

Preview with example values:

```bash
python3 scripts/body_map.py preview /tmp/body.svg values.json
```
