# Exercise data

The app ships one bundled library, `App/Resources/exercises.json`. It is generated from the two source files in this folder. Do not edit the generated file by hand.

## Sources

| File | Source | License |
| --- | --- | --- |
| `free-exercise-db.json` | [yuhonas/free-exercise-db](https://github.com/yuhonas/free-exercise-db), 876 entries | Unlicense (public domain) |
| `curated_exercises.json` | George curated library: elastic band, yoga, mobility, stretching, core, tennis-conditioning and cardio entries that free-exercise-db lacks | Original content written for this project |

- free-exercise-db entries get ids of the form `fedb:<original id>`. Curated entries use `george:<kebab-case-slug>`.
- Images are not bundled. Each entry's `images` holds paths relative to the `imageBase` URL in the output file (`https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/`).
- A curated entry can borrow pictures from free-exercise-db through `imageFrom` (a free-exercise-db id), but only when that entry shows a visually equivalent movement. Otherwise `imageFrom` is `null` and `images` is empty.
- Curated names must not duplicate any free-exercise-db name. The check ignores case and punctuation. If a movement already exists there under the same name, it is left out of the curated file.

## Regenerating

From the repository root (Python 3, standard library only):

```sh
python3 -I scripts/build_exercise_db.py data/free-exercise-db.json data/curated_exercises.json App/Resources/exercises.json
```

The script:

1. Converts every free-exercise-db entry into the common schema, deriving `kind`, `mode`, `defaults`, `perSide`, `symbol` and some `tags` with simple rules.
2. Appends the curated entries.
3. Validates the result: required keys, unique ids and names, allowed kinds, categories, muscles and symbols, the shape of `defaults`, and that every `imageFrom` id exists.
4. Prints counts per kind and writes compact JSON sorted by name, ignoring case.

If validation fails, the script exits non-zero and writes nothing.

## Editing the curated library

Each object in `curated_exercises.json` has exactly these keys: `id`, `name`, `kind`, `category`, `equipment`, `level`, `force`, `mechanic`, `primary`, `secondary`, `steps` (2 to 5 short coaching cues), `aliases` (Sanskrit names for yoga), `tags` (lowercase), `mode` (`reps`, `time` or `distance`), `defaults` (`sets`, `reps`, `holdSec`, `restSec`), `perSide`, `imageFrom` and `symbol` (an SF Symbol name).

- Muscles must come from this list: abdominals, abductors, adductors, biceps, calves, chest, forearms, glutes, hamstrings, lats, lower back, middle back, neck, quadriceps, shoulders, traps, triceps.
- In `time` mode, `reps` is `null` and `holdSec` gives the duration.
- In `distance` mode, `reps` holds the distance as text, for example `"500 m"`.

Run the build after every edit.
