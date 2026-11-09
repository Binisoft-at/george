#!/usr/bin/env bash
# Shared helpers for the CI scripts (synced from the Binisoft handbook).
# shellcheck source=config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

# Readable xcodebuild output on GitHub when xcbeautify is installed (it is on the macOS runners).
pretty() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcbeautify --renderer github-actions
  else
    cat
  fi
}

# redact: stdin → stdout with the values of secret variables replaced by ***. Logs and reports are
# published to ci-* branches and artifacts, which anyone can read on a public repository; GitHub
# masks secrets only in the live job log, not in files.
REDACT_VARS=${REDACT_VARS:-"ASC_KEY_ID ASC_ISSUER_ID CLOUDKIT_MANAGEMENT_TOKEN"}
redact() {
  local script="" name value
  for name in $REDACT_VARS; do
    value=${!name:-}
    [ "${#value}" -ge 6 ] || continue
    value=${value%%$'\n'*}
    script+="s/$(printf '%s' "$value" | sed 's/[][\.*^$/&]/\\&/g')/***/g;"
  done
  if [ -n "$script" ]; then sed -e "$script"; else cat; fi
}

# run_xcodebuild <log-name> <xcodebuild args…>
# Keeps the full log in $LOG_DIR/<name>.log; on failure writes <name>.errors.txt (compiler and
# signing errors, workspace paths shortened) and <name>.tail.txt, and annotates the errors.
run_xcodebuild() {
  local name=$1
  shift
  local log="$LOG_DIR/$name.log"
  local result=0
  group "xcodebuild $name"
  set -o pipefail
  xcodebuild "$@" 2>&1 | redact | tee "$log" | pretty || result=$?
  endgroup
  if [ "$result" -ne 0 ]; then
    grep -E "(error|fatal error):|\*\* (BUILD|ARCHIVE|EXPORT) FAILED|The following build commands failed|Code Signing Error|Provisioning profile|requires a provisioning|No signing certificate|doesn't (match|include)|exportArchive|xcodebuild: error|Error Domain" "$log" \
      | sed -E "s#$ROOT/##g" | awk '!seen[$0]++' | head -200 > "$LOG_DIR/$name.errors.txt" || true
    tail -n 150 "$log" | sed -E "s#$ROOT/##g" > "$LOG_DIR/$name.tail.txt" || true
    grep -E "^/.*:[0-9]+:[0-9]+: error:" "$log" | sort -u | head -50 | while IFS= read -r line; do
      local file lineno message
      file=$(echo "$line" | cut -d: -f1)
      lineno=$(echo "$line" | cut -d: -f2)
      message=$(echo "$line" | cut -d: -f5-)
      echo "::error file=${file#"$ROOT"/},line=$lineno::$message"
    done
    echo "xcodebuild $name failed (exit $result) – errors in $LOG_DIR/$name.errors.txt"
  fi
  return "$result"
}
