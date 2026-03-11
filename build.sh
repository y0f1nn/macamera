#!/bin/zsh
# build.sh — Compile Camera.app (ad-hoc signed, sandboxed)
# Usage: ./build.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$PROJECT_DIR/Camera/Sources"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Camera"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

ENTITLEMENTS="$PROJECT_DIR/Camera/Camera.entitlements"
INFO_PLIST="$PROJECT_DIR/Camera/Info.plist"

# Minimum deployment target
MIN_MACOS="13.0"

echo "==> Cleaning previous build..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

echo "==> Compiling Swift sources..."
SWIFT_FILES=(
    "$SRC_DIR/CaptureMode.swift"
    "$SRC_DIR/CameraManager.swift"
    "$SRC_DIR/CameraPreview.swift"
    "$SRC_DIR/ContentView.swift"
    "$SRC_DIR/AppEntry.swift"
)

swiftc \
    -o "$MACOS/$APP_NAME" \
    -target "$(uname -m)-apple-macosx$MIN_MACOS" \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework AppKit \
    -framework Photos \
    -framework CoreMedia \
    -framework Combine \
    -framework Vision \
    -framework CoreImage \
    -framework CoreLocation \
    -parse-as-library \
    "${SWIFT_FILES[@]}"

echo "==> Assembling app bundle..."
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# Copy asset catalog (or create minimal PkgInfo)
echo -n "APPL????" > "$CONTENTS/PkgInfo"

# Create .icns from the icon PNGs using iconutil
ICON_SRC="$PROJECT_DIR/Camera/Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET="$BUILD_DIR/AppIcon.iconset"
if [ -f "$ICON_SRC/icon_512x512@2x.png" ]; then
    echo "==> Building app icon..."
    mkdir -p "$ICONSET"
    cp "$ICON_SRC/icon_16x16.png"      "$ICONSET/icon_16x16.png"
    cp "$ICON_SRC/icon_16x16@2x.png"   "$ICONSET/icon_16x16@2x.png"
    cp "$ICON_SRC/icon_32x32.png"       "$ICONSET/icon_32x32.png"
    cp "$ICON_SRC/icon_32x32@2x.png"   "$ICONSET/icon_32x32@2x.png"
    cp "$ICON_SRC/icon_128x128.png"     "$ICONSET/icon_128x128.png"
    cp "$ICON_SRC/icon_128x128@2x.png"  "$ICONSET/icon_128x128@2x.png"
    cp "$ICON_SRC/icon_256x256.png"     "$ICONSET/icon_256x256.png"
    cp "$ICON_SRC/icon_256x256@2x.png"  "$ICONSET/icon_256x256@2x.png"
    cp "$ICON_SRC/icon_512x512.png"     "$ICONSET/icon_512x512.png"
    cp "$ICON_SRC/icon_512x512@2x.png"  "$ICONSET/icon_512x512@2x.png"
    iconutil --convert icns --output "$RESOURCES/AppIcon.icns" "$ICONSET" 2>/dev/null \
        && echo "    Icon built." \
        || echo "    iconutil failed — icon may be missing."
    rm -rf "$ICONSET"
fi

echo "==> Ad-hoc code signing with entitlements..."
codesign \
    --force \
    --sign - \
    --entitlements "$ENTITLEMENTS" \
    --deep \
    "$APP_BUNDLE"

echo ""
echo "==> Build complete!"
echo "    $APP_BUNDLE"
echo ""
echo "    To run:  open $APP_BUNDLE"
echo ""
echo "    NOTE: On first launch, macOS will prompt for camera permission."
echo "    If the app is blocked by Gatekeeper, run:"
echo "      xattr -cr $APP_BUNDLE"
