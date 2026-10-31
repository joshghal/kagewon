#!/usr/bin/env bash
# Tests the system proxy code against a stand-in for networksetup, so no real network setting is touched.
set -euo pipefail
cd "$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -swift-version 5 -o "$WORK/harness" tests/main.swift System.swift
"$WORK/harness" "$PWD/tests/fake-networksetup"
