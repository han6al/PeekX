#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DIR="$ROOT_DIR/build/DerivedData"
EXPORT_DIR="$ROOT_DIR/build/export_test"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DERIVED_DIR/Build/Products/Release/PeekX.app"
APP_EXPORT_PATH="$EXPORT_DIR/PeekX.app"
DMG_PATH="$DIST_DIR/PeekX-test-$(date +%Y%m%d-%H%M%S).dmg"

APP_ENTITLEMENTS="$ROOT_DIR/PeekX/PeekX.entitlements"
EXT_ENTITLEMENTS="$ROOT_DIR/PeekXExt/PeekXExt.entitlements"
EXT_PATH="$APP_EXPORT_PATH/Contents/PlugIns/PeekXExt.appex"

mkdir -p "$DIST_DIR" "$EXPORT_DIR"

echo "==> Building Release (unsigned)"
xcodebuild \
  -project "$ROOT_DIR/PeekX.xcodeproj" \
  -scheme PeekX \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: built app not found at $APP_PATH"
  exit 1
fi

echo "==> Preparing app bundle"
rm -rf "$APP_EXPORT_PATH"
ditto --noqtn --noextattr --norsrc "$APP_PATH" "$APP_EXPORT_PATH"
find "$APP_EXPORT_PATH" -name '._*' -delete
find "$APP_EXPORT_PATH" -exec xattr -c {} + || true
xattr -cr "$APP_EXPORT_PATH" || true
dot_clean -m "$APP_EXPORT_PATH" || true

echo "==> Ad-hoc signing extension and app"
codesign --force --sign - --timestamp=none --entitlements "$EXT_ENTITLEMENTS" "$EXT_PATH"
codesign --force --sign - --timestamp=none --entitlements "$APP_ENTITLEMENTS" "$APP_EXPORT_PATH"
codesign -vvv --deep --strict "$APP_EXPORT_PATH"

echo "==> Creating DMG"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "PeekX" \
  -srcfolder "$APP_EXPORT_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Done: $DMG_PATH"
