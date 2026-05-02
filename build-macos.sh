#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$ROOT_DIR/macos"
APP_NAME="DKST Linux Battery"
PRODUCT_NAME="LinuxBatteryMenuBar"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"

swift build -c release --package-path "$MACOS_DIR"
BIN_DIR="$(swift build -c release --package-path "$MACOS_DIR" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$MACOS_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BIN_DIR/$PRODUCT_NAME" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
cp "$MACOS_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

chmod +x "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
fi

echo "Built $APP_BUNDLE"
