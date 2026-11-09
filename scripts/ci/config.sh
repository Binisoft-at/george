#!/usr/bin/env bash
# Loads the app's CI settings. Source it from the other scripts: `. "$here/config.sh"`.
#
# App-specific values live in Config/ci.env (owned by the app, never synced). Everything else has a
# Binisoft default derived from APP_NAME. This file is synced from the Binisoft handbook
# (ci/scripts → scripts/ci): change it in the handbook, not in an app.

# Repo root: two levels above scripts/ci (logical path, so it also works through the template's symlink).
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT

if [ -f "$ROOT/Config/ci.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/Config/ci.env"
  set +a
fi

if [ -z "${APP_NAME:-}" ]; then
  echo "::error::Config/ci.env must set APP_NAME (see the handbook's CONVENTIONS.md)" >&2
  exit 1
fi

: "${PROJECT:=$APP_NAME.xcodeproj}"
: "${IOS_SCHEME:=$APP_NAME}"
: "${MAC_SCHEME:=${APP_NAME}Mac}"
: "${WATCH_SCHEME:=${APP_NAME}Watch}"
: "${WIDGETS_TARGET:=${APP_NAME}Widgets}"
: "${CORE_PACKAGE:=Packages/${APP_NAME}Core}"
: "${IOS_PRODUCT:=$APP_NAME}"
: "${MAC_PRODUCT:=$APP_NAME}"
: "${HAS_MAC:=1}"
: "${HAS_WATCH:=1}"
: "${HAS_WIDGETS:=1}"
: "${DERIVED_DATA:=$ROOT/build}"
: "${LOG_DIR:=$ROOT/ci-logs}"
: "${SCREENSHOT_SCREENS:=home}"
: "${WATCH_SCREENS:=home}"
: "${MAC_SCREENS:=home}"
export PROJECT IOS_SCHEME MAC_SCHEME WATCH_SCHEME WIDGETS_TARGET CORE_PACKAGE IOS_PRODUCT MAC_PRODUCT \
  HAS_MAC HAS_WATCH HAS_WIDGETS DERIVED_DATA LOG_DIR SCREENSHOT_SCREENS WATCH_SCREENS MAC_SCREENS
mkdir -p "$LOG_DIR"
