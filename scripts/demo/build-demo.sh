#!/usr/bin/env bash
# Builds the demonstration copy of the app and helper in a scratch folder: fake data, a stand-in for the network settings,
# and a command driver. The real sources are copied and patched there; nothing in the repository changes.
# Usage: build-demo.sh <scratch folder>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO="$1"
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "node not found in PATH" >&2; exit 1; }
mkdir -p "$DEMO"

python3 "$ROOT/scripts/demo/patch.py" "$ROOT" "$DEMO" "$NODE_BIN"

APP="$DEMO/KagewonDemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
(cd "$DEMO/build" && swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/KagewonDemo" \
  main.swift System.swift Model.swift Views.swift Glyph.swift -framework AppKit -framework SwiftUI)

PLIST="$APP/Contents/Info.plist"
plutil -create xml1 "$PLIST"
add() { plutil -insert "$1" -"$2" "$3" "$PLIST"; }
add CFBundleName string "KagewonDemo"
add CFBundleIdentifier string "app.kagewon.demo"
add CFBundleExecutable string "KagewonDemo"
add CFBundlePackageType string "APPL"
add LSMinimumSystemVersion string "14.0"
add LSUIElement bool true
add ProxyDir string "$DEMO/proj"
add NodePath string "$NODE_BIN"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

swiftc -O -o "$DEMO/wid" "$ROOT/scripts/demo/wid.swift"
swiftc -O -o "$DEMO/term-render" "$ROOT/scripts/demo/term-render.swift" -framework AppKit
swiftc -O -o "$DEMO/make-gif" "$ROOT/scripts/demo/make-gif.swift" -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers
echo "demonstration build ready in $DEMO"
