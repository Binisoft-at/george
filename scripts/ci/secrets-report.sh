#!/usr/bin/env bash
# Shows which repository secrets this repo can see (never their values) in the job summary, and
# sets the step output ready=true|false for the secrets a workflow needs.
#   usage: secrets-report.sh testflight|cloudkit|asc   (needs the secrets in the step's env)
# Synced from the Binisoft handbook.
set -uo pipefail
purpose=${1:-testflight}
case "$purpose" in
  testflight|asc) needed="APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8" ;;
  cloudkit) needed="CLOUDKIT_MANAGEMENT_TOKEN APPLE_TEAM_ID" ;;
  *) echo "unknown purpose $purpose"; exit 1 ;;
esac
[ "$purpose" = asc ] && needed="ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8"

out=${SECRETS_REPORT:-/dev/null}
{
  echo "## Repository secrets"
  echo
  echo "| Secret | Used by | Visible to this repo |"
  echo "| --- | --- | --- |"
  for entry in "APPLE_TEAM_ID:TestFlight, CloudKit schema" "ASC_KEY_ID:TestFlight, ASC status" \
               "ASC_ISSUER_ID:TestFlight, ASC status" "ASC_KEY_P8:TestFlight, ASC status" \
               "CLOUDKIT_MANAGEMENT_TOKEN:CloudKit schema"; do
    name=${entry%%:*}
    if [ -n "${!name:-}" ]; then state="yes"; else state="**missing**"; fi
    echo "| \`$name\` | ${entry#*:} | $state |"
  done
  echo
  echo "Missing ones: GitHub repo → Settings → Secrets and variables → Actions → **New repository secret**."
  echo "Organization secrets don't reach private repositories on GitHub Free."
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" > "$out"
cat "$out" 2>/dev/null || true

missing=""
for name in $needed; do
  [ -n "${!name:-}" ] || missing="$missing $name"
done
if [ -n "$missing" ]; then
  echo "::warning::Missing repository secrets:$missing (see SETUP_CHECKLIST.md, section 4)"
  echo "ready=false" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "ready=true" >> "${GITHUB_OUTPUT:-/dev/null}"
fi
