#!/usr/bin/env python3
"""Reads values from Config/Base.xcconfig without Xcode (Linux jobs: CloudKit schema, ASC status).

usage: xcconfig.py KEY [KEY…]     print each value, $(VARIABLES) resolved
       xcconfig.py --all          print every KEY=value
       --file <path>              another xcconfig (default: Config/Base.xcconfig of this repo)

Handles `//` comments, `#include "x"` / `#include? "x"` and $(VAR) / ${VAR}. Build-time variables
it can't know (e.g. $(AppIdentifierPrefix)) stay as they are. Synced from the Binisoft handbook.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "..", ".."))
REFERENCE = re.compile(r"\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]")


def parse(path, values, required=True):
    if not os.path.exists(path):
        if required:
            sys.exit(f"{path} not found")
        return
    for raw in open(path, encoding="utf-8"):
        line = raw.split("//", 1)[0].strip()
        if not line:
            continue
        include = re.match(r'#include(\?)?\s+"([^"]+)"', line)
        if include:
            parse(os.path.join(os.path.dirname(path), include.group(2)), values, required=not include.group(1))
            continue
        match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line)
        if match:
            values[match.group(1)] = match.group(2).strip()


def resolve(value, values, depth=0):
    if depth > 20:
        return value

    def substitute(match):
        name = match.group(1)
        if name == "inherited":
            return ""
        return resolve(values[name], values, depth + 1) if name in values else match.group(0)

    return REFERENCE.sub(substitute, value)


def main(argv):
    path = os.path.join(os.environ.get("ROOT", ROOT), "Config", "Base.xcconfig")
    if "--file" in argv:
        index = argv.index("--file")
        path = argv[index + 1]
        del argv[index:index + 2]
    values = {}
    parse(path, values)
    if argv == ["--all"]:
        for key in values:
            print(f"{key}={resolve(values[key], values)}")
        return
    if not argv:
        sys.exit(__doc__)
    for key in argv:
        if key not in values:
            sys.exit(f"{key} is not set in {path}")
        print(resolve(values[key], values))


if __name__ == "__main__":
    main(sys.argv[1:])
