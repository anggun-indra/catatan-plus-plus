#!/bin/bash
# Local DMG packager for Catatan++
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$HERE/dist"
APP_NAME="Catatan++"
APP_BUNDLE="$DIST/$APP_NAME.app"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle not found at $APP_BUNDLE. Run ./build.sh first." >&2
    exit 1
fi

ARCH="$(uname -m)"
DMG_NAME="Catatan++-macOS-${ARCH}.dmg"
DMG_PATH="$DIST/$DMG_NAME"
STAGING="$DIST/dmg_staging"

echo "==> Preparing DMG staging area"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

# Copy application bundle
cp -R "$APP_BUNDLE" "$STAGING/"

# Create /Applications shortcut
ln -s /Applications "$STAGING/Applications"

# Copy optional volume icon if available
if [ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
    # Mark VolumeIcon if SetFile is available
    if command -v SetFile &>/dev/null; then
        SetFile -c icnC "$STAGING/.VolumeIcon.icns" 2>/dev/null || true
        SetFile -a C "$STAGING" 2>/dev/null || true
    fi
fi

echo "==> Building compressed disk image: $DMG_NAME"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING"

echo "==> Verifying DMG integrity"
MOUNT_DIR=$(mktemp -d /tmp/catatan_dmg_test.XXXXXX)
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
if [ -d "$MOUNT_DIR/$APP_NAME.app" ] && [ -L "$MOUNT_DIR/Applications" ]; then
    echo "    Integrity verified: $APP_NAME.app and /Applications shortcut present."
else
    echo "Error: DMG verification failed!" >&2
    hdiutil detach "$MOUNT_DIR" -force -quiet || true
    rm -rf "$MOUNT_DIR"
    exit 1
fi
hdiutil detach "$MOUNT_DIR" -force -quiet
rm -rf "$MOUNT_DIR"

SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo "==> Successfully created $DMG_PATH ($SIZE)"
