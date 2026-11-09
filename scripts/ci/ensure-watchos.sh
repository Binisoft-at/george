#!/usr/bin/env bash
# The iOS app embeds the watch app, so its build needs the watchOS platform. Runner images usually
# ship it; download only when the matching runtime is missing. Synced from the Binisoft handbook.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh"
[ "$HAS_WATCH" = 1 ] || { echo "No watch app (HAS_WATCH=0)"; exit 0; }
SDK=$(xcrun --sdk watchsimulator --show-sdk-version 2>/dev/null || echo "")
if [ -n "$SDK" ] && xcrun simctl list runtimes | grep -q "watchOS ${SDK}"; then
  echo "watchOS ${SDK} runtime present"
else
  xcrun simctl list runtimes || true
  xcodebuild -downloadPlatform watchOS
fi
