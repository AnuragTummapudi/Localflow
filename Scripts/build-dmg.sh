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

# Install-window art and volume icon. Regenerate the background with Scripts/dmg/make-background.py.
mkdir -p "$STAGING_DIR/.background"
cp Scripts/dmg/background.tiff "$STAGING_DIR/.background/background.tiff"
ICONSET="$(mktemp -d)/VolumeIcon.iconset"
mkdir -p "$ICONSET"
ICONS="Resources/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 128 256 512; do
  cp "$ICONS/localflow-icon-${size}.png" "$ICONSET/icon_${size}x${size}.png"
  double=$((size * 2))
  [ -f "$ICONS/localflow-icon-${double}.png" ] && cp "$ICONS/localflow-icon-${double}.png" "$ICONSET/icon_${size}x${size}@2x.png"
done
VOLUME_ICON="$(dirname "$ICONSET")/VolumeIcon.icns"
iconutil -c icns "$ICONSET" -o "$VOLUME_ICON"

echo "=== 4. Creating Disk Image (DMG) ==="
RW_DMG="${OUTPUT_DIR}/${APP_NAME}-rw.dmg"
rm -f "$RW_DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDRW -fs HFS+ "$RW_DMG"
rm -rf "$STAGING_DIR"

# Detach any stale mount with the same name so Finder styles the right window.
[ -d "/Volumes/$APP_NAME" ] && hdiutil detach "/Volumes/$APP_NAME" -force -quiet || true
MOUNT_DIR="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')"

# Lay out the Finder window: fixed size, no toolbar, large icons over the background art.
# Positions must match Scripts/dmg/make-background.py. Needs a GUI session; skipped if Finder is unavailable.
if ! osascript <<EOF
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 200}
    set position of item "Applications" of container window to {470, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "Warning: Finder layout skipped; the DMG will open with a default window." >&2
fi

# Added after the Finder step: hdiutil -srcfolder and Finder's update both drop .VolumeIcon.icns.
cp "$VOLUME_ICON" "$MOUNT_DIR/.VolumeIcon.icns"
SetFile -a C "$MOUNT_DIR"
chmod -Rf go-w "$MOUNT_DIR" || true
sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH"
rm -f "$RW_DMG"

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
