#!/bin/zsh
# package.sh — Create a styled Camera.dmg with drag-to-install layout
# Usage: ./package.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Camera.app"
DMG_NAME="Camera"
DMG_FINAL="$BUILD_DIR/$DMG_NAME.dmg"
DMG_RW="$BUILD_DIR/${DMG_NAME}_rw.dmg"
DMG_TEMP="$BUILD_DIR/dmg_staging"
VOLUME_NAME="Camera"

# ── Step 1: Build the app ──────────────────────────────────────────────
echo "==> Building Camera.app..."
bash "$PROJECT_DIR/build.sh"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: build.sh did not produce $APP_BUNDLE"
    exit 1
fi

# ── Step 2: Prepare staging directory ──────────────────────────────────
echo ""
echo "==> Preparing DMG staging area..."
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"

cp -R "$APP_BUNDLE" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

# ── Step 3: Create read-write DMG ─────────────────────────────────────
echo "==> Creating read-write DMG..."
rm -f "$DMG_RW" "$DMG_FINAL"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDRW \
    -size 200m \
    "$DMG_RW"

# ── Step 4: Mount and style with Finder ───────────────────────────────
echo "==> Styling DMG window..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_RW" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')

# Use DS_Store to set window appearance
# Position: Camera.app on left, Applications on right, nice big icons
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, 860, 540}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 104
        set text size of theViewOptions to 14
        -- Camera.app on the left, Applications folder on the right
        set position of item "Camera.app" of container window to {150, 160}
        set position of item "Applications" of container window to {510, 160}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
sleep 1

# ── Step 5: Detach and compress ───────────────────────────────────────
echo "==> Finalizing DMG..."
hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DIR" -force
sleep 1

hdiutil convert "$DMG_RW" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FINAL"

rm -f "$DMG_RW"
rm -rf "$DMG_TEMP"

echo ""
echo "==> DMG created!"
echo "    $DMG_FINAL"
echo ""
echo "    To install: Open the DMG and drag Camera.app to Applications."
