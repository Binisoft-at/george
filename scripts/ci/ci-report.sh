#!/usr/bin/env bash
# Collects what the CI jobs left (artifacts) into one folder and publishes it to ci-output/ci:
#   status.txt   run, commit, result of every job
#   errors.txt   compiler / test errors, paths shortened
#   *.tail.txt, core-tests.log, logs/*.log.gz, shots/*.png
# Read it with: git fetch origin ci-output && git show origin/ci-output:ci/status.txt
#   usage: ci-report.sh <artifacts dir>
#   env:   GH_TOKEN GITHUB_REPOSITORY GITHUB_RUN_NUMBER GITHUB_RUN_ID GITHUB_SHA GITHUB_EVENT_NAME,
#          RESULTS ("core-tests=success build=failure …"), BRANCH (default ci-output), SUBDIR (default ci)
# Synced from the Binisoft handbook.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
artifacts=${1:?artifacts dir}
out=$(mktemp -d)
mkdir -p "$artifacts"

{
  echo "run ${GITHUB_RUN_NUMBER:-?} (${GITHUB_EVENT_NAME:-?}) commit ${GITHUB_SHA:-?}"
  echo "${RESULTS:-}"
  echo "details: https://github.com/${GITHUB_REPOSITORY:-?}/actions/runs/${GITHUB_RUN_ID:-?}"
} > "$out/status.txt"
cat "$out/status.txt"

find "$artifacts" -name "*.errors.txt" -print0 | sort -z | while IFS= read -r -d '' file; do
  echo "== $(basename "$file" .errors.txt) =="
  cat "$file"
  echo
done > "$out/errors.txt"
[ -s "$out/errors.txt" ] || rm -f "$out/errors.txt"

find "$artifacts" \( -name "*.tail.txt" -o -name "bundle.txt" -o -name "core-tests.log" -o -name "entitlements-*.txt" -o -name "uploaded.txt" -o -name "certificates*.log" \) -exec cp {} "$out/" \;
mkdir -p "$out/logs"
find "$artifacts" -name "*.log" ! -name "core-tests.log" ! -name "certificates*.log" | while IFS= read -r log; do
  gzip -c "$log" > "$out/logs/$(basename "$log").gz"
done
rmdir "$out/logs" 2>/dev/null || true
shots=$(find "$artifacts" -type d -name shots | head -1)
[ -n "$shots" ] && cp -R "$shots" "$out/shots"

"$here/publish-output.sh" "$out" "${GITHUB_WORKFLOW:-ci} run ${GITHUB_RUN_NUMBER:-?}: ${RESULTS:-}" "${BRANCH:-ci-output}" "${SUBDIR:-ci}"
