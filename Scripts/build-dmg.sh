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

echo "=== 2. Signing App Bundle ==="
# Set SIGN_IDENTITY="Developer ID Application: …" for a distributable, hardened-runtime build.
# Without it the app is ad-hoc signed, which only runs on the machine that built it without warnings.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp \
    --entitlements App/LocalFlow.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

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

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi
# Set NOTARY_PROFILE to a profile saved with `xcrun notarytool store-credentials`.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "=== 5. Notarizing ==="
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
fi

echo "======================================================"
echo " Successfully created: $DMG_PATH"
echo " Size: $(du -sh "$DMG_PATH" | awk '{print $1}')"
echo "======================================================"
