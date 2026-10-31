#!/usr/bin/env bash
# Runs the app's real logic (turn on, leak check, kill switch, turn off, quit) against a scratch copy of the project and a
# real Tor. It takes a few minutes and needs Tor (brew install tor) and an internet connection.
# Your own network settings, config.json, key, and log are never touched: the network commands are replaced by a stand-in,
# and the project, its settings, and the log live in a temporary folder. It uses local ports 18888, 18889, and 19250.
set -euo pipefail
cd "$(dirname "$0")"
command -v tor >/dev/null || { echo "Tor is not installed (brew install tor)" >&2; exit 1; }
command -v node >/dev/null || { echo "node was not found" >&2; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir "$ROOT/proj"
cp -R ../proxy.mjs ../package.json ../src "$ROOT/proj/"
ln -s "$(cd .. && pwd)/node_modules" "$ROOT/proj/node_modules"
cp tests/fake-networksetup "$ROOT/fakens"
cp tests/live.swift "$ROOT/main.swift"

# The only change to the app code: its log goes to a scratch file instead of ~/Library/Logs
LOG_LINE='FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kagewon.log")'
grep -qF "$LOG_LINE" Model.swift || { echo "Model.swift changed: update the log line in test-live.sh" >&2; exit 1; }
python3 - "$LOG_LINE" > "$ROOT/Model.swift" <<'PY'
import sys
line = sys.argv[1]
print(open('Model.swift').read().replace(line, 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["HX_LOG"]!)'), end='')
PY

swiftc -O -swift-version 5 -o "$ROOT/live" "$ROOT/main.swift" "$ROOT/Model.swift" System.swift -framework AppKit -framework SwiftUI
HX_LOG="$ROOT/app.log" "$ROOT/live" "$ROOT"
