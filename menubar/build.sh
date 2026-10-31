#!/usr/bin/env bash
# Builds "Kagewon.app" into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

PROJECT_DIR="$(cd .. && pwd)"
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "node not found in PATH" >&2; exit 1; }

APP="$HOME/Applications/Kagewon.app"
# Quit a running copy (it cleans up after itself) and wait, for up to about 10 seconds, until it is really gone.
if pkill -x Kagewon 2>/dev/null; then
  for _ in $(seq 1 100); do pgrep -x Kagewon >/dev/null || break; sleep 0.1; done
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/Kagewon" main.swift System.swift Model.swift Views.swift Glyph.swift -framework AppKit -framework SwiftUI

PLIST="$APP/Contents/Info.plist"
plutil -create xml1 "$PLIST"
add() { plutil -insert "$1" -"$2" "$3" "$PLIST"; } # plutil escapes the values, so odd characters in a path are safe
add CFBundleName string "Kagewon"
add CFBundleDisplayName string "Kagewon"
add CFBundleIdentifier string "app.kagewon.menubar"
add CFBundleExecutable string "Kagewon"
add CFBundleIconFile string "AppIcon"
add CFBundlePackageType string "APPL"
add CFBundleShortVersionString string "0.1.0"
add CFBundleVersion string "1"
add LSMinimumSystemVersion string "14.0"
add LSUIElement bool true
add LSMultipleInstancesProhibited bool true
add ProxyDir string "$PROJECT_DIR"
add NodePath string "$NODE_BIN"

# the app icon is drawn by make-icon.swift, so no binary image has to live in the repository
ICON_WORK="$(mktemp -d)"
mkdir -p "$APP/Contents/Resources"
swiftc -O -o "$ICON_WORK/make-icon" make-icon.swift -framework AppKit
"$ICON_WORK/make-icon" "$ICON_WORK/Kagewon.iconset"
iconutil -c icns "$ICON_WORK/Kagewon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_WORK"

codesign --force --deep --options runtime --sign - "$APP" >/dev/null
echo "Built: $APP"
