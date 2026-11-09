# George – workout coach, energy and profile (v2)

Everything that makes live mode feel like training with a coach. Every extra can be switched off in
**Settings → Workout Coach**.

## Live mode

| What | How it works | Code |
|---|---|---|
| **No big Done button** | Each set is clearly *done* (filled, ✓), *current* (highlighted, "NOW", big numbers) or *open*. Tick whichever you did. The bottom bar shows what's next and a set timer instead. ␣ still completes the current set on a keyboard. | `LiveWorkoutView`, `LiveSetRow` |
| **Typing numbers** | Tap a number → big keypad with the phone's decimal key; "62,5" and "62.5" both work. Chips: last time, previous set, plan, ± one step. "Same for the rest" copies to the following open sets. Drag a number sideways to step it. Long-press a set for every field. | `ValuePadSheet`, `ValueTile`, `NumberParser` |
| **Edits that stick** | In a workout a number changes what was done; while the set is still open the plan follows, so the set always shows what you typed. Templates change their plan. Finished sets show "Plan was …" when they differ. | `WorkoutSet.setValue(_:_:inSession:)` |
| **Supersets side by side** | One page per superset/circuit: exercises as columns (A1, A2), one row per round, the current cell highlighted. "Match sets" evens out different set counts (adds copies of the last set, removes only open sets). Also in the editor's group header. | `SupersetCard`, `WorkoutContent.matchSetCounts` |
| **Set timer against dawdling** | Time since the last set; turns orange, then red, once it's past the planned rest + set time + slack (calm 90 s, normal 30 s, full energy 15 s). Up to two gentle nudges per gap (haptic + voice), never on calm days. | `PaceTracker`, `SetTimerBar` |
| **Momentum** | A flame that breathes when sets come on time and shrinks when they don't, a progress bar that glows, a body figure whose muscles fill as their sets get done, bursts on each tick, banners for "exercise done", new best weight and halfway. | `MomentumHeader`, `FlameBadge`, `MiniBodyFill`, `BurstView`, `CelebrationBanner` |
| **Voice coach** | "Let's go. First up …", "Rest 90 seconds", "10 seconds", "Go! Bench Press, 8 reps at 62.5 kilos", "Bench Press done", "New personal best!", the finish summary. Ducks music while speaking. | `VoiceCoach` |
| **Smart questions** | After the last working set of an exercise (at most 4× per workout): "How many more reps could you have done?" 0 / 1 / 2 / 3+ → stored as RPE (10 − reps in reserve). Disappears by itself after 14 s. | `EffortPrompt`, `EffortPromptCard` |
| **What to try today** | Before the first set: "Go up: 65 kg × 8 – last time 3+ reps were left". Double progression with reps in reserve: add weight at the top of the rep range or with 3+ left, add a rep with 1–2 left, match an all-out set, go lighter after missed reps at full effort. Tap to apply to the open sets. | `ProgressionAdvisor`, `ProgressionChip` |
| **Low-energy days** | Energy check-in before the first set (1–5, skipped if you answered on Today). 1–2 → *Calm*: no nudges, more slack, "Easy day". The ⋯ menu → Today's Pace switches any time. Motivation style Full / Calm / Off in Settings. | `CoachIntensity`, `EnergyCheckInCard` |

## Finish

Finish sheet: progress ring, effort pre-filled from the reps-in-reserve answers, a big "Finish &
Celebrate" button. Summary: confetti, ring and numbers that count up, records, muscles worked,
highlights, streak, and **Share** – a 4:5 picture (body map, time, sets, volume, a record, top
exercises) rendered with `ImageRenderer`, shared through the share sheet. Only the picture is shared.
Finished workouts show the same overview at the top of their page (`RecapOverviewSection`).

## Energy over the weeks

- Check-ins come from **Today** ("How's your energy today?", once a day, changeable) and before a
  workout. Stored as `EnergyCheckIn` (synced; self-reported, not Health data).
- **Insights → Energy**: weekly averages, trend, best/lowest weekday, a **rhythm** (autocorrelation of
  the daily series over 5–40 day lags; needs ≥ 30 check-ins over ≥ 6 weeks and r ≥ 0.3 over two full
  cycles), the link with workout performance (volume against the usual for the same workout), and –
  with Apple Health – with sleep and HRV.
- **Apple Health signals** (Settings → Workout Coach and the Energy page): HRV, resting heart rate and
  sleep vs. your own 30-day median → "Your body says: take it easy today", shown in the check-in with a
  suggested level. **State of Mind** moods can fill in days without a check-in. Both are read on demand
  and kept in memory only – Health data never goes to iCloud (App Store guideline 5.1.3).

Code: `GeorgeCore/Energy.swift`, `GeorgeCore/HealthSignals.swift`, `EnergyView.swift`,
`HealthKitManager+Signals.swift`.

## Your profile – what's optimal for you

Settings → Your Profile: birth year (or the age from Apple Health, kept on the device), experience and
goal. From it (`TrainingProfile`):

| | Example (intermediate, muscle) |
|---|---|
| Hard sets per muscle and week | 10–16 (beginner 6–10, advanced 12–20; strength 6–12) |
| Reps per set / reps in reserve | 6–15 / 1–3 (60+: 8–15) |
| Rest between sets | 1.5–3 min |
| Recovery before the same muscle works hard again | 48–72 h, ×1 up to 30 then +0.8 %/year (max ×1.35) |
| Muscular load | 80–130 % of the usual (80–120 % for beginners and 60+) |

The muscle screens use these targets (bands, "below/in/above target"), the freshness model stretches
recovery with age, and muscle detail, muscular load and Settings show an **Optimal for You** section
with the sources (Schoenfeld 2016/2017, Pelland 2024, ACSM 2009). Guidelines, not rules.

## Settings → Workout Coach

Motivation (Full / Calm / Off) · Voice coach · "10 seconds" warning · Sound when rest ends · Haptics ·
Nudge me when I dawdle · Ask how hard sets felt · Energy check-in · Start rest timer automatically ·
Keep screen awake. Device-local (`Prefs`), defaults on.
