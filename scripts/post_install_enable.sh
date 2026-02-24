#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-/Applications/PeekX.app}"
EXT_ID="altic.PeekX.PeekXExt"
EXT_PATH="$APP_PATH/Contents/PlugIns/PeekXExt.appex"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app not found at $APP_PATH"
  exit 1
fi

if [[ ! -d "$EXT_PATH" ]]; then
  echo "Error: extension not found at $EXT_PATH"
  exit 1
fi

echo "==> Clearing quarantine and metadata"
xattr -dr com.apple.quarantine "$APP_PATH" || true
xattr -cr "$APP_PATH" || true

echo "==> Registering Quick Look extension"
pluginkit -a "$EXT_PATH"
pluginkit -e use -i "$EXT_ID"

echo "==> Restarting Quick Look services"
qlmanage -r cache
killall Finder || true
killall quicklookd 2>/dev/null || true

echo "==> Verifying registration"
pluginkit -m -v -p com.apple.quicklook.preview | grep -i peekx -A6 || true

echo "Done."
