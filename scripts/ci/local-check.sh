#!/usr/bin/env bash
# Checks without a Mac (cloud session, Linux), cheapest first:
#   1. swift test for the Core package – Docker swift:6.2-noble if available, else a local toolchain
#      (download one from swift.org if neither exists)
#   2. swiftc -parse for the app, watch, widget and shared code (syntax only; type checks need Xcode)
# Then push: CI builds for real; then TestFlight. Synced from the Binisoft handbook.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh"
cd "$ROOT" || exit 1
IMAGE=${SWIFT_IMAGE:-swift:6.2-noble}
status=0

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # The handbook's template links Vendor/BinisoftKit to ../../kit, so mount one level higher there.
  mount=$ROOT
  [ -L "$ROOT/Vendor/BinisoftKit" ] && mount=$(cd "$ROOT/.." && pwd)
  run() { docker run --rm -v "$mount:$mount" -w "$ROOT" "$IMAGE" "$@"; }
  echo "Using Docker $IMAGE"
elif command -v swift >/dev/null 2>&1; then
  run() { "$@"; }
  echo "Using local $(swift --version 2>&1 | head -1)"
else
  echo "Neither Docker nor a Swift toolchain found."
  echo "Install one: https://www.swift.org/install/linux/ (Swift 6.2, Ubuntu 24.04), or start dockerd."
  exit 1
fi

echo "== 1. swift test --package-path $CORE_PACKAGE"
run swift test --package-path "$CORE_PACKAGE" || status=1

echo "== 2. swiftc -parse (syntax of the Apple-only code)"
files=$(find App Shared Watch Widgets -name "*.swift" 2>/dev/null | sort)
if [ -n "$files" ]; then
  # shellcheck disable=SC2086
  run bash -c 'for f in "$@"; do swiftc -parse "$f" || { echo "syntax error in $f"; exit 1; }; done' _ $files || status=1
fi

[ "$status" = 0 ] && echo "Local checks passed. Next: push – CI builds macOS and iOS." || echo "Local checks failed."
exit $status
