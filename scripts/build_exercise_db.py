#!/usr/bin/env python3
"""Build the bundled exercise library for George - Your Gym Buddy.

Merges the public-domain free-exercise-db dataset with George's hand-written
curated exercises, normalises everything into one schema, validates it and
writes a compact JSON file for the app bundle.

Usage:
    python3 scripts/build_exercise_db.py \
        data/free-exercise-db.json data/curated_exercises.json App/Resources/exercises.json

Python 3 standard library only. Exits non-zero if validation fails.
"""

import json
import os
import re
import sys
from collections import Counter

IMAGE_BASE = "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/"

SOURCES = [
    {
        "id": "fedb",
        "name": "Free Exercise DB",
        "url": "https://github.com/yuhonas/free-exercise-db",
        "license": "Unlicense (public domain)",
    },
    {
        "id": "george",
        "name": "George curated library",
        "url": None,
        "license": "Original content",
    },
]

# Keys every curated entry must have, in output order. Output adds "images".
KEYS = (
    "id", "name", "kind", "category", "equipment", "level", "force", "mechanic",
    "primary", "secondary", "steps", "aliases", "tags", "mode", "defaults",
    "perSide", "imageFrom", "symbol",
)
OUTPUT_KEYS = KEYS + ("images",)
DEFAULT_KEYS = ("sets", "reps", "holdSec", "restSec")

KINDS = {"band", "gym", "bodyweight", "stretch", "yoga", "mobility", "cardio", "core", "hiit"}
CATEGORIES = {"strength", "stretching", "mobility", "yoga", "cardio", "plyometrics", "core"}
LEVELS = {"beginner", "intermediate", "expert"}
FORCES = {"pull", "push", "static", None}
MECHANICS = {"compound", "isolation", None}
MODES = {"reps", "time", "distance"}
MUSCLES = {
    "abdominals", "abductors", "adductors", "biceps", "calves", "chest", "forearms",
    "glutes", "hamstrings", "lats", "lower back", "middle back", "neck", "quadriceps",
    "shoulders", "traps", "triceps",
}
SYMBOLS = {
    "figure.strengthtraining.functional", "figure.strengthtraining.traditional",
    "figure.flexibility", "figure.yoga", "figure.mind.and.body", "figure.cooldown",
    "figure.core.training", "figure.highintensity.intervaltraining", "figure.run",
    "figure.indoor.cycle", "figure.rower", "figure.jumprope", "figure.tennis",
    "figure.walk", "figure.stairs", "figure.pool.swim", "figure.mixed.cardio",
    "figure.pilates", "figure.cross.training", "dumbbell.fill",
}

# free-exercise-db categories outside George's vocabulary fold into "strength";
# the original category is kept as a tag so nothing is lost.
CATEGORY_MAP = {
    "powerlifting": "strength",
    "olympic weightlifting": "strength",
    "strongman": "strength",
}

PER_SIDE_RE = re.compile(
    r"\b(single|one[- ]arm(ed)?|one[- ]leg(ged)?|one[- ]handed|alternat(e|ing)|side)\b", re.I)
NOT_PER_SIDE_RE = re.compile(
    r"side[- ]lateral|side to side|lateral raise|single[- ]cone|single response|single dumbbell",
    re.I)
SHOULDER_PREHAB_RE = re.compile(
    r"external rotation|internal rotation|face pull|cuban press|scaption|pull apart|rotator", re.I)
WRIST_RE = re.compile(
    r"wrist|pronation|supination|finger curl|plate pinch|hand squeeze|forearm", re.I)
ROTATION_CORE_RE = re.compile(r"pallof|wood chop|russian twist|full twist|scoop throw", re.I)


def fail(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as exc:
        fail("cannot read {}: {}".format(path, exc))


# --------------------------------------------------------------------------
# free-exercise-db conversion
# --------------------------------------------------------------------------

def fedb_kind(e):
    equipment = e.get("equipment")
    category = e.get("category")
    if equipment == "bands":
        return "band"
    if equipment == "foam roll":
        return "mobility"
    if category == "stretching":
        return "stretch"
    if category == "cardio":
        return "cardio"
    if equipment in ("body only", None) and category in ("strength", "plyometrics"):
        return "bodyweight"
    return "gym"


def fedb_mode_and_defaults(kind, e):
    # Foam-roll entries are kind "mobility" but category "stretching" in the
    # source; they are held for time like the other stretches.
    if kind == "stretch" or e.get("category") == "stretching":
        return "time", {"sets": 2, "reps": None, "holdSec": 30, "restSec": 15}
    if kind == "cardio":
        return "time", {"sets": 1, "reps": None, "holdSec": 600, "restSec": 0}
    if e.get("force") == "static":
        # Isometric holds (Plank, Side Bridge, plate pinches...) are timed.
        return "time", {"sets": 3, "reps": None, "holdSec": 30, "restSec": 60}
    if kind == "band":
        return "reps", {"sets": 3, "reps": "15", "holdSec": None, "restSec": 60}
    return "reps", {"sets": 3, "reps": "10", "holdSec": None, "restSec": 90}


def fedb_per_side(name):
    return bool(PER_SIDE_RE.search(name)) and not NOT_PER_SIDE_RE.search(name)


def fedb_symbol(kind, e):
    name = e["name"].lower()
    primary = e.get("primaryMuscles") or []
    category = e.get("category")
    if kind == "cardio":
        for needles, symbol in (
            (("run", "jog"), "figure.run"),
            (("bicycl", "bike"), "figure.indoor.cycle"),
            (("rowing",), "figure.rower"),
            (("rope",), "figure.jumprope"),
            (("stair", "step mill"), "figure.stairs"),
            (("walk",), "figure.walk"),
        ):
            if any(n in name for n in needles):
                return symbol
        return "figure.mixed.cardio"
    if kind == "stretch":
        return "figure.flexibility"
    if kind == "mobility":
        return "figure.cooldown"
    if "abdominals" in primary:
        return "figure.core.training"
    if kind == "band":
        return "figure.strengthtraining.functional"
    if kind == "bodyweight":
        if category == "plyometrics":
            return "figure.highintensity.intervaltraining"
        return "figure.strengthtraining.functional"
    # gym
    if category in ("plyometrics", "strongman"):
        return "figure.cross.training"
    if e.get("equipment") == "dumbbell":
        return "dumbbell.fill"
    return "figure.strengthtraining.traditional"


def fedb_tags(e):
    name = e["name"]
    primary = e.get("primaryMuscles") or []
    tags = []

    def add(*items):
        for t in items:
            if t not in tags:
                tags.append(t)

    if SHOULDER_PREHAB_RE.search(name) and "shoulders" in primary:
        add("tennis", "prehab", "shoulder health")
    if WRIST_RE.search(name) and "forearms" in primary:
        add("tennis", "prehab", "wrist")
    if "abdominals" in primary:
        add("core")
        if ROTATION_CORE_RE.search(name):
            add("tennis")
    if e.get("category") in CATEGORY_MAP:
        add(e["category"])
    return tags


def convert_fedb(e):
    kind = fedb_kind(e)
    mode, defaults = fedb_mode_and_defaults(kind, e)
    category = CATEGORY_MAP.get(e.get("category"), e.get("category"))
    steps = [s.strip() for s in (e.get("instructions") or []) if s and s.strip()]
    return {
        "id": "fedb:" + e["id"],
        "name": e["name"].strip(),
        "kind": kind,
        "category": category,
        "equipment": e.get("equipment"),
        "level": e.get("level"),
        "force": e.get("force"),
        "mechanic": e.get("mechanic"),
        "primary": list(e.get("primaryMuscles") or []),
        "secondary": list(e.get("secondaryMuscles") or []),
        "steps": steps,
        "aliases": [],
        "tags": fedb_tags(e),
        "mode": mode,
        "defaults": defaults,
        "perSide": fedb_per_side(e["name"]),
        "imageFrom": None,
        "symbol": fedb_symbol(kind, e),
        "images": list(e.get("images") or []),
    }


# --------------------------------------------------------------------------
# curated entries
# --------------------------------------------------------------------------

def convert_curated(c, fedb_by_id, errors):
    where = "curated {!r}".format(c.get("id", c.get("name", "?")) if isinstance(c, dict) else c)
    if not isinstance(c, dict):
        errors.append(where + ": entry is not an object")
        return None
    keys = set(c.keys())
    missing = [k for k in KEYS if k not in keys]
    extra = sorted(keys - set(KEYS))
    if missing:
        errors.append("{}: missing keys {}".format(where, missing))
    if extra:
        errors.append("{}: unexpected keys {}".format(where, extra))
    if missing:
        return None
    out = {k: c[k] for k in KEYS}
    images = []
    ref = c.get("imageFrom")
    if ref is not None:
        src = fedb_by_id.get(ref)
        if src is None:
            errors.append("{}: imageFrom {!r} is not a free-exercise-db id".format(where, ref))
        else:
            images = list(src.get("images") or [])
            if not images:
                errors.append("{}: imageFrom {!r} has no images".format(where, ref))
    out["images"] = images
    return out


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

def norm_name(name):
    return re.sub(r"[^a-z0-9]+", "", name.casefold())


def fold_name(name):
    # Mirrors ExerciseCatalog.fold in GeorgeCore: case-insensitive, "-" as space.
    return re.sub(r" +", " ", name.casefold().replace("-", " ")).strip()


def is_str_list(v):
    return isinstance(v, list) and all(isinstance(x, str) and x.strip() for x in v)


def validate(exercises, errors, warnings):
    seen_ids = set()
    names = Counter(e["name"].casefold() for e in exercises if isinstance(e.get("name"), str))
    fedb_norm = {norm_name(e["name"]): e["name"] for e in exercises
                 if e.get("id", "").startswith("fedb:") and isinstance(e.get("name"), str)}
    # The app resolves names and aliases through one map, so a curated alias must
    # never equal another exercise's name.
    name_owner = {fold_name(e["name"]): e.get("id") for e in exercises
                  if isinstance(e.get("name"), str)}

    for e in exercises:
        eid = e.get("id")
        where = repr(eid)
        curated = isinstance(eid, str) and eid.startswith("george:")

        if tuple(e.keys()) != OUTPUT_KEYS:
            errors.append("{}: keys {} != {}".format(where, list(e.keys()), list(OUTPUT_KEYS)))
            continue
        if not isinstance(eid, str) or not re.fullmatch(r"(fedb|george):\S+", eid):
            errors.append("{}: id must be 'fedb:<id>' or 'george:<slug>'".format(where))
        elif eid in seen_ids:
            errors.append("{}: duplicate id".format(where))
        seen_ids.add(eid)
        if curated and not re.fullmatch(r"george:[a-z0-9]+(-[a-z0-9]+)*", eid):
            errors.append("{}: curated id slug must be kebab-case".format(where))

        name = e["name"]
        if not isinstance(name, str) or not name.strip():
            errors.append("{}: empty name".format(where))
        else:
            if names[name.casefold()] > 1:
                errors.append("{}: duplicate name {!r} (case-insensitive)".format(where, name))
            if curated and norm_name(name) in fedb_norm:
                errors.append("{}: name {!r} collides with free-exercise-db {!r}".format(
                    where, name, fedb_norm[norm_name(name)]))

        if e["kind"] not in KINDS:
            errors.append("{}: kind {!r} not allowed".format(where, e["kind"]))
        if e["category"] not in CATEGORIES:
            errors.append("{}: category {!r} not allowed".format(where, e["category"]))
        if e["level"] not in LEVELS:
            errors.append("{}: level {!r} not allowed".format(where, e["level"]))
        if e["force"] not in FORCES:
            errors.append("{}: force {!r} not allowed".format(where, e["force"]))
        if e["mechanic"] not in MECHANICS:
            errors.append("{}: mechanic {!r} not allowed".format(where, e["mechanic"]))
        if e["mode"] not in MODES:
            errors.append("{}: mode {!r} not allowed".format(where, e["mode"]))
        if e["symbol"] not in SYMBOLS:
            errors.append("{}: symbol {!r} not allowed".format(where, e["symbol"]))
        if e["equipment"] is not None and not (isinstance(e["equipment"], str) and e["equipment"]):
            errors.append("{}: equipment must be a non-empty string or null".format(where))

        for key in ("primary", "secondary"):
            muscles = e[key]
            if not isinstance(muscles, list):
                errors.append("{}: {} must be a list".format(where, key))
                continue
            bad = [m for m in muscles if m not in MUSCLES]
            if bad:
                errors.append("{}: {} has unknown muscles {}".format(where, key, bad))
            if len(set(muscles)) != len(muscles):
                errors.append("{}: {} has duplicates".format(where, key))
        if isinstance(e["primary"], list) and isinstance(e["secondary"], list):
            overlap = set(e["primary"]) & set(e["secondary"])
            if overlap and curated:
                errors.append("{}: muscles in both primary and secondary {}".format(
                    where, sorted(overlap)))
            if not e["primary"]:
                warnings.append("{}: no primary muscles".format(where))

        steps = e["steps"]
        if not is_str_list(steps):
            errors.append("{}: steps must be a list of non-empty strings".format(where))
        elif curated and not 2 <= len(steps) <= 5:
            errors.append("{}: curated entries need 2-5 steps, got {}".format(where, len(steps)))
        elif not steps:
            warnings.append("{}: no steps in source data".format(where))

        if not is_str_list(e["aliases"]):
            errors.append("{}: aliases must be a list of strings".format(where))
        elif curated:
            for alias in e["aliases"]:
                owner = name_owner.get(fold_name(alias))
                if owner is not None and owner != eid:
                    errors.append("{}: alias {!r} is the name of {}".format(where, alias, owner))
        if not is_str_list(e["tags"]) or any(t != t.lower() for t in e["tags"]):
            errors.append("{}: tags must be a list of lowercase strings".format(where))
        if not isinstance(e["perSide"], bool):
            errors.append("{}: perSide must be a boolean".format(where))
        if not is_str_list(e["images"]):
            errors.append("{}: images must be a list of strings".format(where))

        # imageFrom existence is checked when curated entries are converted.
        ref = e["imageFrom"]
        if ref is not None and not curated:
            errors.append("{}: imageFrom is only for curated entries".format(where))

        d = e["defaults"]
        if not isinstance(d, dict) or tuple(d.keys()) != DEFAULT_KEYS:
            errors.append("{}: defaults must have keys {}".format(where, list(DEFAULT_KEYS)))
            continue
        if not (isinstance(d["sets"], int) and not isinstance(d["sets"], bool) and d["sets"] >= 1):
            errors.append("{}: defaults.sets must be an int >= 1".format(where))
        if not (isinstance(d["restSec"], int) and not isinstance(d["restSec"], bool)
                and d["restSec"] >= 0):
            errors.append("{}: defaults.restSec must be an int >= 0".format(where))
        if e["mode"] == "time":
            if d["reps"] is not None or not (isinstance(d["holdSec"], int) and d["holdSec"] > 0):
                errors.append("{}: time mode needs reps null and holdSec > 0".format(where))
        else:
            if not (isinstance(d["reps"], str) and d["reps"].strip()) or d["holdSec"] is not None:
                errors.append("{}: {} mode needs a reps string and holdSec null".format(
                    where, e["mode"]))


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main(argv):
    if len(argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    fedb_path, curated_path, out_path = argv[1:]

    fedb_raw = load_json(fedb_path)
    curated_raw = load_json(curated_path)
    if not isinstance(fedb_raw, list):
        fail(fedb_path + ": expected a JSON array")
    if not isinstance(curated_raw, list):
        fail(curated_path + ": expected a JSON array")

    errors, warnings = [], []
    fedb_by_id = {}
    for e in fedb_raw:
        if not isinstance(e, dict) or not e.get("id") or not e.get("name"):
            errors.append("free-exercise-db entry without id/name: {!r}".format(e)[:200])
            continue
        fedb_by_id[e["id"]] = e

    exercises = [convert_fedb(e) for e in fedb_by_id.values()]
    for c in curated_raw:
        converted = convert_curated(c, fedb_by_id, errors)
        if converted is not None:
            exercises.append(converted)

    validate(exercises, errors, warnings)

    for w in warnings:
        print("warning: " + w, file=sys.stderr)
    if errors:
        for err in errors:
            print("error: " + err, file=sys.stderr)
        print("{} validation error(s); nothing written.".format(len(errors)), file=sys.stderr)
        return 1

    exercises.sort(key=lambda x: (x["name"].casefold(), x["id"]))
    doc = {
        "version": 1,
        "imageBase": IMAGE_BASE,
        "sources": SOURCES,
        "exercises": exercises,
    }

    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    tmp_path = out_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp_path, out_path)

    by_source = Counter(x["id"].split(":", 1)[0] for x in exercises)
    by_kind = Counter(x["kind"] for x in exercises)
    by_kind_curated = Counter(x["kind"] for x in exercises if x["id"].startswith("george:"))
    print("Exercises per kind (total / curated):")
    for kind in sorted(by_kind, key=lambda k: (-by_kind[k], k)):
        print("  {:<11} {:>4} / {:>3}".format(kind, by_kind[kind], by_kind_curated.get(kind, 0)))
    print("Sources: " + ", ".join("{} {}".format(k, v) for k, v in sorted(by_source.items())))
    print("Total: {}".format(len(exercises)))
    print("Wrote {} ({:,} bytes)".format(out_path, os.path.getsize(out_path)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
