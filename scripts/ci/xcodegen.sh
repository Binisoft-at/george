#!/usr/bin/env bash
# Runs XcodeGen: the installed one if present, otherwise a pinned release downloaded once into
# .build/. Usage: scripts/ci/xcodegen.sh generate. Synced from the Binisoft handbook.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh"
cd "$ROOT"
VERSION=${XCODEGEN_VERSION:-2.46.0}
if command -v xcodegen >/dev/null 2>&1; then
  exec xcodegen "$@"
fi
dir=".build/xcodegen-$VERSION"
if [ ! -x "$dir/xcodegen/bin/xcodegen" ]; then
  mkdir -p "$dir"
  if ! { curl -fsSL -o "$dir/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip" \
         && unzip -q -o "$dir/xcodegen.zip" -d "$dir"; }; then
    echo "XcodeGen $VERSION download failed – installing with Homebrew"
    brew install xcodegen
    exec xcodegen "$@"
  fi
fi
exec "$dir/xcodegen/bin/xcodegen" "$@"
