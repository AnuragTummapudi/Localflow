#!/bin/zsh
set -euo pipefail

APP_NAME="LocalFlow"
SCHEME="LocalFlow"
PROJECT="LocalFlow.xcodeproj"
DERIVED_DATA=".build/ReleaseDerivedData"
BUILD_DIR="${DERIVED_DATA}/Build/Products/Release"
STAGING_DIR=".build/dmg-staging"
OUTPUT_DIR="dist"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}.dmg"

echo "=== 1. Building Release Universal App for macOS ==="
mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGING_DIR" "$DMG_PATH"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "Error: App bundle not found at $APP_BUNDLE" >&2
  exit 1
fi

echo "=== 2. Ad-hoc Signing App Bundle for Pilot Testing ==="
# Ad-hoc sign all frameworks and main app bundle so it runs cleanly on local MacBooks
codesign --force --deep --sign - "$APP_BUNDLE"

echo "=== 3. Preparing DMG Staging ==="
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "=== 4. Creating Disk Image (DMG) ==="
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "======================================================"
echo " Successfully created: $DMG_PATH"
echo " Size: $(du -sh "$DMG_PATH" | awk '{print $1}')"
echo "======================================================"
