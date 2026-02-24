#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/PeekX.xcodeproj"
SCHEME="PeekX"
CONFIGURATION="Release"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_DIR="$BUILD_DIR/PeekX.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="PeekX.app"
DMG_NAME="PeekX-$(date +%Y%m%d-%H%M%S).dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo "Error: full Xcode is not installed or selected."
  echo "Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$DIST_DIR"
rm -rf "$ARCHIVE_DIR" "$EXPORT_DIR/$APP_NAME"

echo "==> Archiving $SCHEME ($CONFIGURATION)"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_DIR" \
  archive

APP_PATH="$(find "$ARCHIVE_DIR/Products/Applications" -maxdepth 1 -name "$APP_NAME" -print -quit)"
if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "Error: could not locate $APP_NAME in archive."
  exit 1
fi

cp -R "$APP_PATH" "$EXPORT_DIR/"

echo "==> Creating DMG: $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "PeekX" \
  -srcfolder "$EXPORT_DIR/$APP_NAME" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Done: $DMG_PATH"
