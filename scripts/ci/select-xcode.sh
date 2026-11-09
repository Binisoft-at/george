#!/usr/bin/env bash
# Selects the newest installed release Xcode 26 or later on the GitHub macOS runner
# (or $XCODE_PATH when set). Synced from the Binisoft handbook.
set -euo pipefail
if [ -n "${XCODE_PATH:-}" ]; then
  xcode="$XCODE_PATH"
else
  xcode=$(python3 - <<'PY'
import glob, re
apps = [a for a in glob.glob("/Applications/Xcode_*.app")
        if not re.search(r"beta|rc|release.candidate", a, re.I)]
def version(path):
    return [int(x) for x in re.findall(r"\d+", path.split("Xcode_")[1])] or [0]
apps = [a for a in apps if version(a)[0] >= 26]
print(sorted(apps, key=version)[-1] if apps else "")
PY
)
fi
if [ -n "$xcode" ]; then
  sudo xcode-select -s "$xcode/Contents/Developer"
fi
xcodebuild -version
