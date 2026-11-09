#!/usr/bin/env bash
# Runs the Core package tests (Swift Testing). In CI this runs on Linux in the swift:6.2-noble
# container; locally use `make test`, or scripts/ci/local-check.sh without a Mac.
# Synced from the Binisoft handbook.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh"
cd "$ROOT" || exit 1
echo "swift test --package-path $CORE_PACKAGE"
swift test --package-path "$CORE_PACKAGE" 2>&1 | tee "$LOG_DIR/core-tests.log"
result=${PIPESTATUS[0]}
if [ "$result" -ne 0 ]; then
  grep -E "error:|✘|failed" "$LOG_DIR/core-tests.log" | sed -E "s#$ROOT/##g" | awk '!seen[$0]++' | head -150 > "$LOG_DIR/core-tests.errors.txt" || true
fi
exit "$result"
