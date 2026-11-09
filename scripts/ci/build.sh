#!/usr/bin/env bash
# Unsigned builds – no secrets needed: the macOS app, then the iOS app (simulator) with the embedded
# watch app and widgets, then a check that the iPhone app really carries them.
# Keeps going after a failing build so one run reports every error. Logs land in $LOG_DIR.
#   usage: scripts/ci/build.sh [all|mac|ios]
# Synced from the Binisoft handbook.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
cd "$ROOT" || exit 1
what=${1:-all}
status=0

if [ ! -d "$PROJECT" ]; then
  "$here/xcodegen.sh" generate || exit 1
fi

common=(-configuration Debug -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
        -skipPackagePluginValidation -IDEBuildingContinueBuildingAfterErrors=YES)

if [ "$HAS_MAC" = 1 ] && [ "$what" != ios ]; then
  run_xcodebuild build-mac build -project "$PROJECT" -scheme "$MAC_SCHEME" \
    -destination 'generic/platform=macOS' "${common[@]}" || status=1
fi

if [ "$what" != mac ]; then
  run_xcodebuild build-ios build -project "$PROJECT" -scheme "$IOS_SCHEME" \
    -destination 'generic/platform=iOS Simulator' "${common[@]}" || status=1

  # The iPhone app must carry the watch app and the widgets (a missing embed fails silently otherwise).
  app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/$IOS_PRODUCT.app"
  if [ -d "$app" ]; then
    {
      echo "Bundle layout of $IOS_PRODUCT.app:"
      find "$app" -maxdepth 4 \( -name "*.app" -o -name "*.appex" \) | sed "s#$DERIVED_DATA/Build/Products/##"
    } | tee "$LOG_DIR/bundle.txt"
    parts=()
    [ "$HAS_WATCH" = 1 ] && parts+=("Watch/$WATCH_SCHEME.app")
    [ "$HAS_WIDGETS" = 1 ] && parts+=("PlugIns/$WIDGETS_TARGET.appex")
    for part in ${parts[@]+"${parts[@]}"}; do
      if [ ! -d "$app/$part" ]; then
        echo "::error::$IOS_PRODUCT.app is missing $part"
        echo "$IOS_PRODUCT.app is missing $part" >> "$LOG_DIR/bundle.errors.txt"
        status=1
      fi
    done
  fi
fi

exit $status
