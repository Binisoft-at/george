You are creating a workout program for my workout app "George". Output ONLY a CSV file (inside one ```csv code block) in the exact format below — no explanations before or after.

FORMAT (George program CSV v1)
- First line is this header (keep the column names exactly):
program,workout,workout_subtitle,workout_type,workout_order,schedule,section,group,group_style,rounds,rest_after_round,exercise,exercise_type,sets,reps,weight,unit,load,duration,distance,rest,tempo,rpe,per_side,set_type,notes,tutorial_url,muscles,equipment
- One row per exercise. Fill program, workout and exercise on every row. Fill workout_subtitle, workout_type, workout_order and schedule only on the first row of each workout.
- workout_type: gym, band (elastic/resistance bands), bodyweight, core, hiit, cardio, stretch, yoga, mobility, sport — or another single word.
- schedule: weekdays separated by ";" (Mon;Thu). Leave empty if flexible.
- section: a heading such as WARM-UP, MAIN, CORE, FINISHER, COOL-DOWN.
- Supersets/circuits: give consecutive rows the same group letter (A, B, …), set group_style (superset/circuit/emom/amrap/interval) and rounds on the first row of the group, rest_after_round in seconds. Leave group empty for straight sets.
- sets: number. reps: a number, a range like 8-12, AMRAP, or a per-set list in quotes like "15,12,10".
- weight in kg (or set unit to lb); for bands leave weight empty and describe resistance in load (e.g. light band, red band).
- Timed exercises (planks, stretches, yoga holds, cardio): put seconds in duration (e.g. 45s or 2 min) and leave reps empty.
- rest: seconds of rest after each set. per_side: yes for unilateral exercises.
- set_type: warmup for warm-up sets (put them on a separate row right before the working-set row of the same exercise), otherwise leave empty.
- notes: one short coaching cue. muscles: primary muscles separated by ";" using only: abdominals, abductors, adductors, biceps, calves, chest, forearms, glutes, hamstrings, hip flexors, lats, lower back, middle back, neck, obliques, quadriceps, shoulders, traps, triceps.
- tutorial_url: only include a link if you are certain it exists; otherwise leave empty (the app finds tutorials itself).
- Prefer common exercise names (e.g. "Band Face Pull", "Pallof Press", "Goblet Squat", "Child's Pose", "Downward-Facing Dog") so the app can match its exercise library and show images.
- Quote any cell that contains a comma.

MY REQUEST
<Describe goals, equipment, days per week, session length, injuries, sport (e.g. tennis), and the workouts you want — or paste your current workouts / Apple Notes and ask to convert them.>
