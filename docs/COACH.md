# George – workout coach, energy and profile

Everything that makes live mode feel like training with a coach. Every extra can be switched off in
**Settings → Workout Coach** (voice: **Settings → Workout Coach → Voice Coach**).

## Flow of a set (v3)

Each set goes **ready → working → resting**:

| Phase | Bottom bar | Ring |
|---|---|---|
| **Ready** | NOW + exercise, set 2 of 4, the numbers; “+0:23 over the 1:30 rest”; big **Start** | time since the last set, green → orange → red against the planned rest |
| **Working** | IN PROGRESS / 3:12 LEFT; big **Done** | a timed set (warm-up bike, plank) counts down and ticks itself off at zero; a rep set shows how long it's going |
| **Resting** | REST · UP NEXT + what's next; **Start** skips the rest | the rest countdown |

- **Start** is the moment you really begin – George compares that with the planned rest (gap =
  end of last set → start of this one) and keeps a running total: “2:10 behind plan”. Ticking a set
  without Start works too: the start is then estimated from the set's typical work time. Off in
  Settings → Workout Coach → *Start button between sets*.
- The page you swipe to is the exercise you're doing – the current set follows it. Supersets go
  round by round (A1 → A2 → A1 …).
- **Tap the bar (or swipe up)** for the full panel: the big ring, NOW / NEXT / THEN, previous /
  pause / next, ±15 s and skip rest, Start/Done, and **Pace**: behind or ahead of plan, this break
  (planned vs. took), the average break, the finish time at this pace against the planned time, a
  chart of every break (bar = actual, line = planned) and tips (“your breaks run 0:45 over – set up
  the weight in the last 15 seconds”; rest guideline from your profile). Swipe down to close.
- After an exercise's last set: **how fatigued are your chest, triceps?** 25 / 50 / 75 / 100 % (and,
  for rep sets, reps left). The fatigue scales that exercise's muscular load (50 % neutral, 100 %
  ×1.4) – so freshness reflects how hard it really was.
- Apple Watch: the same **Start set** button after a rest, the planned rest with the delta, and the
  running total.

Rest guidelines behind the tips: rests longer than ~60–90 s are at least as good for muscle growth
as short ones (Singer et al. 2024, Bayesian meta-analysis; Grgic et al. 2017 review), heavy compound
lifts profit from 2–3 min (Schoenfeld et al. 2016). Your range comes from Settings → Your Profile.

## Voice coach (v3)

- **One queue, no chatter about the past**: every line belongs to a set; when you move on, lines
  about other sets are dropped, and anything that waited more than a few seconds is skipped.
- **You choose when it speaks** (Settings → Voice Coach → When the coach speaks): next set, rest
  starts, countdown (10 s, 3-2-1), go, timed sets, exercise done, records, halfway/last set, over the
  rest, cheers (off by default), start/finish.
- **Music**: lower it while speaking (iOS ducking, given back 0.4 s after the last line), keep it as
  it is, or pause it. Voice volume and speed sliders. **Mute** for one workout: ⋯ menu or the panel.
- **Voices**: the best installed iPhone voice (premium/enhanced first, male preferred – download
  “Evan (Premium)” or “Nathan (Premium)” in iPhone Settings → Accessibility → Spoken Content → Voices),
  or **Natural (ElevenLabs)** with your own API key, stored only in this device's Keychain. Lines
  are generated once and cached; if a line isn't ready in 1.6 s (or there's no internet) the iPhone
  voice says it. Code: `VoiceCoach.swift`, `NaturalVoice.swift`, `GeorgeCore/CoachScript.swift`.
- **Phone locked**: with *Keep coaching when the phone is locked* on and no Apple Watch recording,
  George starts an iPhone workout session (iOS 26 HealthKit, no builder – nothing extra is saved;
  `PhoneWorkoutSession.swift`) and has the `audio` background mode, so cues can keep coming while
  locked. (`workout-processing` is a watchOS-only background mode – App Store Connect rejects it on
  iOS.) Whether iOS keeps George running between cues has to be checked on a device. As a fallback
  the rest-end notification plays the spoken “Go!” as its sound (rendered into Library/Sounds);
  while George is open, that notification stays silent.

## Stretch & yoga (v3)

The library has 162 stretches, 107 yoga poses (with Sanskrit names, Sun Salutation A/B and their
parts, flows) and 56 mobility drills. **Plans → Stretch & Yoga Routines**: nine ready-made routines
(Morning Mobility, Desk Break, After the Gym, After the Run, Hip Openers, Sun Salutation Flow,
Evening Wind-Down, Tennis Warm-Up, Shoulders & Upper Back) – *Start Now* or *Add to My Templates*
(program “Stretch & Yoga”), then edit, start or share like any template. Definitions:
`GeorgeCore/Routines.swift` (a test checks every move exists in the library).

## Sharing routines (v3)

Any template → **Share** (toolbar): a **PDF** for anyone (numbered exercises with sets/holds, muscles
and the key cues), a **George file** (`.csv` – opens straight in George as a template) or plain text.

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
