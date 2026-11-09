#!/usr/bin/env bash
# Simulator screenshots for "[screenshots]" commits and manual CI runs, after build.sh.
# Screens come from Config/ci.env: SCREENSHOT_SCREENS (iPhone, light + dark), WATCH_SCREENS,
# MAC_SCREENS. Each name is opened with `-Demo -DemoScreen <name>`; "tour" opens the tour and
# "tour:<step>" opens it at that step. Output: $LOG_DIR/shots. Synced from the Binisoft handbook.
#   usage: scripts/ci/screenshots.sh [all|mac]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh"
cd "$ROOT" || exit 1
what=${1:-all}
shots="$LOG_DIR/shots"
mkdir -p "$shots"

# Launch arguments for a screen name.
args_for() {
  case "$1" in
    tour) echo "-Demo -Tour" ;;
    tour:*) echo "-Demo -TourStep ${1#tour:}" ;;
    *) echo "-Demo -DemoScreen $1" ;;
  esac
}

file_name() { echo "$1" | tr ':' '-'; }

iphone() {
  local app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/$IOS_PRODUCT.app"
  [ -d "$app" ] || { echo "no iOS build at $app"; return 0; }
  local bundle udid
  bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist")
  udid=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
phones = [d for runtime, items in devices.items() if 'iOS' in runtime for d in items if d['name'].startswith('iPhone')]
phones.sort(key=lambda d: ('Pro' not in d['name'], 'Max' in d['name']))
print(phones[0]['udid'] if phones else '')")
  [ -n "$udid" ] || { echo "no iPhone simulator"; return 0; }
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
  xcrun simctl install "$udid" "$app"
  for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance"
    for screen in $SCREENSHOT_SCREENS; do
      xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
      # shellcheck disable=SC2046
      xcrun simctl launch "$udid" "$bundle" $(args_for "$screen") >/dev/null
      sleep 8
      xcrun simctl io "$udid" screenshot "$shots/iphone-$(file_name "$screen")-$appearance.png" >/dev/null 2>&1 || true
    done
  done
  xcrun simctl spawn "$udid" log show --last 5m --predicate "process == \"$IOS_PRODUCT\"" --style compact > "$shots/iphone-log.txt" 2>&1 || true
}

watch() {
  [ "$HAS_WATCH" = 1 ] || return 0
  local app="$DERIVED_DATA/Build/Products/Debug-watchsimulator/$WATCH_SCHEME.app"
  [ -d "$app" ] || { echo "no watch build at $app"; return 0; }
  local bundle udid
  bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist")
  udid=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
watches = [d for runtime, items in devices.items() if 'watchOS' in runtime for d in items if d['name'].startswith('Apple Watch')]
watches.sort(key=lambda d: ('Series' not in d['name'], 'Ultra' in d['name']))
print(watches[0]['udid'] if watches else '')")
  if [ -z "$udid" ]; then
    local runtime device
    runtime=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
r = [x for x in json.load(sys.stdin)['runtimes'] if x.get('platform') == 'watchOS' and x.get('isAvailable')]
print(r[-1]['identifier'] if r else '')")
    device=$(xcrun simctl list devicetypes -j | python3 -c "
import json, sys
t = [x for x in json.load(sys.stdin)['devicetypes'] if x.get('productFamily') == 'Apple Watch' and 'Series' in x['name']]
print(t[-1]['identifier'] if t else '')")
    [ -n "$runtime" ] && [ -n "$device" ] || { echo "no watch simulator"; return 0; }
    udid=$(xcrun simctl create "CI Watch" "$device" "$runtime")
  fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl install "$udid" "$app"
  for screen in $WATCH_SCREENS; do
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    # shellcheck disable=SC2046
    xcrun simctl launch "$udid" "$bundle" $(args_for "$screen") >/dev/null
    sleep 10
    xcrun simctl io "$udid" screenshot "$shots/watch-$(file_name "$screen").png" >/dev/null 2>&1 || true
  done
}

mac() {
  [ "$HAS_MAC" = 1 ] || return 0
  local app="$DERIVED_DATA/Build/Products/Debug/$MAC_PRODUCT.app"
  [ -d "$app" ] || { echo "no macOS build at $app"; return 0; }
  for screen in $MAC_SCREENS; do
    pkill -x "$MAC_PRODUCT" 2>/dev/null || true
    sleep 1
    # Launch through LaunchServices (`open`), like a double-click; a direct exec doesn't get a window.
    # shellcheck disable=SC2046
    open "$app" --args $(args_for "$screen")
    sleep 6
    # A second `open` sends a reopen event – like a Dock click it opens the window if launch didn't.
    open "$app"
    sleep 6
    screencapture -x "$shots/mac-$(file_name "$screen").png" || true
  done
  pkill -x "$MAC_PRODUCT" 2>/dev/null || true
  log show --last 5m --predicate "process == \"$MAC_PRODUCT\"" --style compact > "$shots/mac-log.txt" 2>&1 || true
}

if [ "$what" != mac ]; then
  iphone
  watch
fi
mac
ls -la "$shots"
