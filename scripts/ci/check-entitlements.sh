#!/usr/bin/env bash
# TestFlight step 3: every key in a target's handwritten entitlements file must be in the signed
# bundle of the archive. Catches entitlements dropped by signing (App ID missing a capability)
# or by XcodeGen regenerating the file – before the upload, with a readable message.
#   usage: scripts/ci/check-entitlements.sh <archive> ios|macos
# Bundles and files follow the Binisoft layout; override with ENTITLEMENTS_IOS / ENTITLEMENTS_MACOS
# in Config/ci.env ("<bundle path in Products/Applications>|<entitlements file>" pairs, space-separated).
# Synced from the Binisoft handbook.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh"
cd "$ROOT"
archive=${1:?archive path}
platform=${2:?ios or macos}
apps="$archive/Products/Applications"

if [ "$platform" = ios ]; then
  pairs=${ENTITLEMENTS_IOS:-"$IOS_PRODUCT.app|Config/iOS/$APP_NAME.entitlements"}
  if [ -z "${ENTITLEMENTS_IOS:-}" ]; then
    [ "$HAS_WATCH" = 1 ] && pairs="$pairs $IOS_PRODUCT.app/Watch/$WATCH_SCHEME.app|Config/watchOS/${APP_NAME}Watch.entitlements"
    [ "$HAS_WIDGETS" = 1 ] && pairs="$pairs $IOS_PRODUCT.app/PlugIns/$WIDGETS_TARGET.appex|Config/Widgets/${APP_NAME}Widgets.entitlements"
  fi
else
  pairs=${ENTITLEMENTS_MACOS:-"$MAC_PRODUCT.app|Config/macOS/$APP_NAME.entitlements"}
fi

keys() {
  plutil -convert json -o - "$1" | python3 -c 'import json, sys; print("\n".join(sorted(json.load(sys.stdin))))'
}

failed=0
tmp=$(mktemp -d)
for pair in $pairs; do
  bundle="$apps/${pair%%|*}"
  source="${pair##*|}"
  name=${pair%%|*}
  if [ ! -d "$bundle" ]; then
    echo "error: $name is not in the archive"
    failed=1
    continue
  fi
  [ -f "$source" ] || { echo "error: $source not found"; failed=1; continue; }
  codesign -d --entitlements - --xml "$bundle" > "$tmp/signed.plist" 2>/dev/null || true
  if [ ! -s "$tmp/signed.plist" ]; then
    echo "error: $name has no entitlements at all"
    failed=1
    continue
  fi
  missing=$(comm -23 <(keys "$source") <(keys "$tmp/signed.plist") || true)
  if [ -n "$missing" ]; then
    echo "error: $name lost entitlements from $source:"
    echo "$missing" | sed 's/^/  - /'
    echo "  Fix: tick the capability on the App ID in the developer portal (SETUP_CHECKLIST.md, section 2)."
    echo "  Signed entitlements:"
    plutil -p "$tmp/signed.plist" | sed 's/^/    /'
    failed=1
  else
    echo "ok: $name has every entitlement from $source"
  fi
done
rm -rf "$tmp"
exit $failed
