#!/usr/bin/env bash
# TestFlight steps 2–4 for one platform: archive with automatic (cloud) signing through the App Store
# Connect API key, check the signed entitlements, then export and upload. No certificates or
# profiles live in the repo. Build number = BUILD_NUMBER (the workflow run number).
#   usage: scripts/ci/archive-upload.sh ios|macos
#   env:   APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH BUILD_NUMBER
# Synced from the Binisoft handbook.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
cd "$ROOT"
platform=${1:?ios or macos}
: "${APPLE_TEAM_ID:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}" "${BUILD_NUMBER:?}"

case "$platform" in
  ios) scheme=$IOS_SCHEME; destination='generic/platform=iOS' ;;
  macos) scheme=$MAC_SCHEME; destination='generic/platform=macOS' ;;
  *) echo "unknown platform $platform"; exit 1 ;;
esac

work="${RUNNER_TEMP:-/tmp}/archive-$platform"
rm -rf "$work"
mkdir -p "$work"
archive="$work/$scheme.xcarchive"
auth=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

# 2. Archive (automatic cloud signing).
run_xcodebuild "archive-$platform" archive -project "$PROJECT" -scheme "$scheme" -configuration Release \
  -destination "$destination" -archivePath "$archive" -skipPackagePluginValidation \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${auth[@]}"

# 3. Check entitlements before export (Apple rejects uploads that lost them, much later and less clearly).
"$here/check-entitlements.sh" "$archive" "$platform" | tee "$LOG_DIR/entitlements-$platform.txt"

# 4. Export and upload.
cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${APPLE_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
PLIST

run_xcodebuild "upload-$platform" -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export" "${auth[@]}"

version=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$archive/Info.plist" 2>/dev/null || echo "?")
echo "Uploaded $scheme $version ($BUILD_NUMBER). It shows up in TestFlight after Apple's processing (5–30 min); check with the App Store Connect status workflow."
echo "$platform $version ($BUILD_NUMBER) uploaded" >> "$LOG_DIR/uploaded.txt"
