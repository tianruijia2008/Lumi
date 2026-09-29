#!/bin/bash
# Renders the app icon from source and installs it into Resources/.
#
# The icon is geometry in Swift rather than a checked-in PNG, so it can be
# re-rendered at any size and the design can be diffed like any other code.
set -euo pipefail

CONCEPT="${1:-slab}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O "$ROOT/Tools/IconForge/main.swift" -o "$WORK/iconforge"
"$WORK/iconforge" "$CONCEPT" "$WORK/Lumi.iconset"
iconutil -c icns "$WORK/Lumi.iconset" -o "$ROOT/Resources/Lumi.icns"
echo "▸ wrote Resources/Lumi.icns ($CONCEPT)"
