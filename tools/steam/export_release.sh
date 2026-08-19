#!/usr/bin/env bash
## Builds all three release exports (task 8.4) into export/release/<platform>/, gitignored same
## as the debug builds. Always goes through `agent godot` — it holds the shared import-cache lock
## so this can't race another lane's headless run (F-044).
##
##   tools/steam/export_release.sh
##
## The release presets ("macOS (Release)"/"Windows Desktop (Release)"/"Linux (Release)" in
## export_presets.cfg) are a deliberate near-duplicate of the existing debug presets, not a
## flag-swap on the same one: they carry exclude_filter="steam_appid.txt" so a release build can
## never ship it (D-022), while the debug presets keep shipping it so debug builds can still
## Steamworks-init standalone outside the Steam client. Verified empirically (2026-08-19): neither
## preset's export log ever emits a "Storing File: res://steam_appid.txt" line in the first place —
## Godot's all_resources filter does not pick up a bare non-imported .txt at the project root — so
## the exclude_filter is defense in depth against that changing, not the only thing stopping it
## today. macOS codesigning/notarisation stays ad-hoc/unset here on purpose — that's task 8.10's
## job, gated on an Apple Developer account Sequoyah doesn't have yet.

set -euo pipefail
cd "$(dirname "$0")/../.."

mkdir -p export/release/windows export/release/macos export/release/linux

.agent/bin/agent godot --headless --export-release "Windows Desktop (Release)" export/release/windows/MIRE.exe
.agent/bin/agent godot --headless --export-release "macOS (Release)" export/release/macos/MIRE.app
.agent/bin/agent godot --headless --export-release "Linux (Release)" export/release/linux/MIRE.x86_64

echo "Release exports built under export/release/. Smoke-test before uploading, e.g.:"
echo "  ./export/release/macos/MIRE.app/Contents/MacOS/MIRE --headless --quit-after 15"
