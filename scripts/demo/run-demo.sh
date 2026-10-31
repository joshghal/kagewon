#!/usr/bin/env bash
# Records the demonstration GIFs in docs/demo, with dummy data only. It builds a patched copy of the app and helper (see
# build-demo.sh), starts fake services (fixtures.mjs), drives the real interface through a command file, runs real curl commands
# against the demonstration helper, and assembles the GIFs.
#
# Needs macOS, the Xcode command line tools, Node.js, and permission for your terminal app to record the screen
# (System Settings, Privacy and Security, Screen Recording). Only the window of the demonstration app is captured, never your
# desktop. The Terminal part runs the real curl commands in a hidden shell and draws their real output as a terminal window,
# so no Terminal.app window is opened or touched.
# It uses local ports 18888, 18889, 18080 and 29100 to 29112, and never touches your real network settings or your real app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO="${DEMO_DIR:-${TMPDIR:-/tmp}/kagewon-demo}"
OUT="$ROOT/docs/demo"
PROJ="$DEMO/proj"
FR="$DEMO/frames"
MAN="$DEMO/manifest.txt"
KEY="demo-0000-1111-2222-3333-4444-5555"
PROXY="http://127.0.0.1:18888"
FIXTURES_PID=""

[ "$(uname)" = Darwin ] || { echo "macOS only" >&2; exit 1; }
cleanup() {
  pkill -f "$DEMO/KagewonDemo.app" 2>/dev/null || true
  sleep 1.5
  pkill -f "$PROJ/proxy.mjs" 2>/dev/null || true
  [ -n "$FIXTURES_PID" ] && kill "$FIXTURES_PID" 2>/dev/null || true
}
trap cleanup EXIT

bash "$ROOT/scripts/demo/build-demo.sh" "$DEMO"
rm -rf "$FR"; mkdir -p "$FR" "$OUT" "$DEMO/home"; : > "$MAN"
printf 'resolve = ip.example.com:18080:127.0.0.1\n' > "$DEMO/home/.curlrc" # the dummy "direct" IP echo, for the Terminal part only
node "$ROOT/scripts/demo/fixtures.mjs" > "$DEMO/fixtures.log" 2>&1 & FIXTURES_PID=$!
sleep 1.5

send() { printf '%s\n' "$@" >> "$PROJ/cmd.txt"; }
popshot() { # flow, name, caption, milliseconds
  for _ in 1 2 3 4 5 6; do
    screencapture -x -o -l "$("$DEMO/wid" KagewonDemo)" "$FR/$2.png" 2>/dev/null && [ "$(stat -f %z "$FR/$2.png")" -gt 20000 ] && break
    sleep 0.7
  done
  [ "$(stat -f %z "$FR/$2.png")" -gt 20000 ] || { echo "could not capture the demonstration window" >&2; exit 1; }
  echo "$1|$2.png|$3|$4|0" >> "$MAN"
}
token() { ps eww -o command= -p "$(cat "$PROJ/.helper.pid")" | grep -oE 'CONTROL_TOKEN=[A-Fa-f0-9]+' | cut -d= -f2; }
state() { curl -s -m 3 -H "X-Control-Token: $(token)" http://127.0.0.1:18889/api/status | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' 2>/dev/null || true; }
wait_running() { for _ in $(seq 1 80); do [ "$(state)" = running ] && return 0; sleep 0.5; done; return 1; }
traffic() { for site in "$@"; do curl -s -m 8 -o /dev/null -x "$PROXY" "http://$site/"; done; }
export CURL_HOME=/nonexistent # the traffic commands below must not read your own curl settings

# ---- start the demonstration app
open -n "$DEMO/KagewonDemo.app"
for _ in $(seq 1 60); do "$DEMO/wid" KagewonDemo >/dev/null 2>&1 && [ -f "$PROJ/.helper.pid" ] && break; sleep 0.5; done
sleep 2

# ---- 1. add a provider
F=1-add-provider
popshot $F f1a "A new install has no provider yet. Open the Providers tab." 2200
send "tab providers"; sleep 1.2
send "add webshare"; sleep 1.2
popshot $F f1b "Add Webshare. The API key comes from your account." 2200
send "key wrong-key"; sleep 0.8; send "testdraft"; sleep 3.2
popshot $F f1c "A wrong key is reported clearly." 2400
send "key $KEY"; sleep 0.8; send "testdraft"; sleep 4
popshot $F f1d "With a valid key, Test connection lists the proxies and shows an exit IP. The key is never shown again." 3200
send "save"; sleep 3
popshot $F f1e "Saved. The provider is ready." 2200
send "tab home"; sleep 1.2

# ---- 2. turn on
F=2-turn-on-and-off
popshot $F f2a "The dashboard: off, so traffic goes direct." 1800
send "power"; sleep 0.7
popshot $F f2b "Turning on: the proxy list loads." 1500
sleep 1.7; popshot $F f2c "The proxies are checked." 1500
sleep 1.6; popshot $F f2d "The Mac's proxy settings are switched on, with the local network left out." 1500
wait_running; sleep 6
popshot $F f2e "On. The exit IP is not your own, and the proxies are reachable." 3200

# ---- 3. rotation and activity
F=3-rotation-and-activity
send "verbose on"; sleep 1.5
traffic example.com example.org example.net
send "tab activity"; sleep 4.2
popshot $F f3a "Sticky: each site keeps its own proxy, so logins keep working. The log shows the choices." 3400
send "tab home"; sleep 1
send "sticky 30"; sleep 1
popshot $F f3b "Keep each IP for 30 seconds up to 4 hours, in steps of 30 seconds." 2600
send "sticky 120"; sleep 0.8

# ---- 7. the terminal: ip check, curl and rotation (real commands, real output, drawn as a terminal window)
F=7-terminal
SCREEN="$DEMO/screen.txt"; : > "$SCREEN"; STEP=0
tstep() { # command, caption, milliseconds, [new screen]
  local cmd="$1" caption="$2" ms="$3" fresh="${4:-}" out
  [ -n "$fresh" ] && : > "$SCREEN"
  out="$(env -i HOME="$DEMO/home" PATH=/usr/bin:/bin:/usr/sbin:/sbin CURL_HOME="$DEMO/home" bash --noprofile --norc -c "$cmd" 2>&1 || true)"
  { printf '$ %s\n' "$cmd"; [ -n "$out" ] && printf '%s\n' "$out"; } >> "$SCREEN"
  { cat "$SCREEN"; printf '$ \n'; } > "$SCREEN.view"
  STEP=$((STEP + 1))
  "$DEMO/term-render" "$FR/t$STEP.png" "$SCREEN.view"
  echo "$F|t$STEP.png|$caption|$ms|0" >> "$MAN"
}
tstep "curl -s http://ip.example.com:18080/" "IP check without the proxy: this is your real address. Every address here is dummy data." 3000
tstep "curl -s -x $PROXY http://ip.example.com:18080/" "The same check through Kagewon: the exit address is different." 3000
tstep "curl -s -x $PROXY http://ip.example.com:18080/" "Sticky: asking again gives the same address, so a session survives." 3000
tstep "for s in example.com example.org example.net; do curl -s -x $PROXY http://\$s/; done" "Every site gets its own proxy and keeps it." 3200 new
send "rotation random"; sleep 1
tstep "for i in 1 2 3 4 5 6; do curl -s -x $PROXY http://ip.example.com:18080/; done" "Random mode: a new address for every connection." 3400 new
send "tab activity"; sleep 4.2
popshot 3-rotation-and-activity f3c "Random: the same site now takes a different proxy for each connection, as the log shows." 3600
send "tab home"; sleep 1.2
popshot 3-rotation-and-activity f3d "The rotation setting is Random. Switch back to Sticky when logins matter." 2600
send "rotation sticky"; sleep 1
tstep "for i in 1 2 3 4 5 6; do curl -s -x $PROXY http://ip.example.com:18080/; done" "Back to Sticky: the same address again." 3000 new
tstep "export http_proxy=$PROXY; curl -s http://ip.example.com:18080/" "Set the proxy once with http_proxy, and plain curl uses it." 3400 new

# ---- 4. a warning when the real address is still reaching the internet
F=4-leak-warning
send "power"; sleep 3.5
printf 'leak\n' > "$PROJ/lookup-mode"
send "power"; sleep 1; wait_running; sleep 9
popshot $F f4a "A warning appears when your real address still reaches the internet, for example when a VPN routes around the proxy." 4200
send "power"; sleep 3.5
printf 'ok\n' > "$PROJ/lookup-mode"

# ---- 5. the kill switch
F=5-kill-switch
send "killswitch on"; sleep 1.2; send "settings"; sleep 1.2
popshot $F f5a "Settings: the kill switch is on. It keeps the internet blocked if the proxy ever stops." 2800
send "tab home"; sleep 1; send "power"; sleep 1; wait_running; sleep 7
popshot $F f5b "The proxy is on." 1800
kill -9 "$(cat "$PROJ/.helper.pid")"; sleep 3.5
popshot $F f5c "The helper stopped. With the kill switch on, nothing leaks: apps stay blocked until you act." 3800
send "power"; sleep 1; wait_running; sleep 7
popshot $F f5d "Try Again: the proxy is back." 2400
send "killswitch off"; sleep 1.2

# ---- 6. settings and Tor
F=6-settings-and-tor
send "settings"; sleep 1.2
popshot $F f6a "Settings: local port, refresh interval, logging and the kill switch." 2800
send "tab providers"; sleep 1; send "add tor"; sleep 1.2
popshot $F f6b "Tor is the free provider. It needs Tor installed, and a local port." 2600
send "torguide on"; sleep 1.2
popshot $F f6c "A built-in guide explains how to set up Tor from scratch." 3000
send "torguide off" "cancel"; sleep 1; send "tab home"; sleep 1

# ---- finish with turning it off
F=2-turn-on-and-off
send "power"; sleep 4
popshot $F f2f "Off: the Mac goes back to its normal settings." 2600

# ---- assemble
"$DEMO/make-gif" "$MAN" "$FR" "$OUT"
D2="$DEMO/icons"; rm -rf "$D2"; mkdir -p "$D2"; cp "$ROOT/scripts/demo/icon-states.swift" "$D2/main.swift"
swiftc -O -swift-version 5 -o "$D2/icons" "$D2/main.swift" "$ROOT/menubar/Glyph.swift" "$ROOT/menubar/Model.swift" "$ROOT/menubar/System.swift" "$ROOT/menubar/Views.swift" -framework AppKit -framework SwiftUI 2>&1 | grep -E "error" || true
"$D2/icons" "$OUT/menu-bar-icons.png"
# keep only the picture: drop every optional PNG chunk (some tools add metadata about the machine that made it)
python3 - "$OUT/menu-bar-icons.png" <<'PY'
import struct, sys, zlib
path = sys.argv[1]; d = open(path, 'rb').read(); out = d[:8]; i = 8
while i < len(d):
    n, t = struct.unpack('>I4s', d[i:i + 8]); body = d[i + 8:i + 8 + n]; i += 12 + n
    if t in (b'IHDR', b'IDAT', b'IEND', b'PLTE', b'tRNS', b'sRGB', b'gAMA'):
        out += struct.pack('>I', n) + t + body + struct.pack('>I', zlib.crc32(t + body) & 0xffffffff)
open(path, 'wb').write(out)
PY
echo "done: $(ls "$OUT" | tr '\n' ' ')"
