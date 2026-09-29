#!/bin/bash
# Launch Lumi the way macOS expects.
#
# TCC attributes Accessibility and Screen Recording to the app LaunchServices
# started. Running build/Lumi.app/Contents/MacOS/Lumi directly attributes them
# to the shell instead, so the app reports "not trusted" even though the toggle
# in System Settings is on. Always go through `open`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Lumi.app"
[ -d "$APP" ] || { echo "not built yet — run ./build.sh first"; exit 1; }

pkill -f "Lumi.app/Contents/MacOS/Lumi" 2>/dev/null || true
sleep 0.5

ARGS=(-n "$APP")
for var in "$@"; do ARGS+=(--env "$var"); done
open "${ARGS[@]}"
echo "▸ launched $APP"
