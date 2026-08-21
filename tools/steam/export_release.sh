#!/usr/bin/env bash
## Builds all three release exports (task 8.4) into export/release/<platform>/, gitignored same
## as the debug builds. Always goes through `agent godot` — it holds the shared import-cache lock
## so this can't race another lane's engine run (F-044). The macOS and Linux release presets
## enable Godot 4.7's shader baker, which requires a real rendering device; `--windowed` provides
## one in the same 64x64 offscreen window the render checks use (F-077). Windows baking stays off
## in this macOS-hosted pipeline: D3D12 shaders must be baked on a Windows build host.
##
##   tools/steam/export_release.sh
##
## The release presets ("macOS (Release)"/"Windows Desktop (Release)"/"Linux (Release)" in
## export_presets.cfg) are a deliberate near-duplicate of the existing debug presets, not a
## flag-swap on the same one. Release filters omit steam_appid.txt (D-022), developer tools, audit
## renders, source previews/catalogues, and the editor half of GodotSteam. Runtime content and the
## platform-specific GodotSteam libraries remain dependency-exported. The debug presets keep the
## developer material and steam_appid.txt so debug builds work standalone outside Steam. macOS
## codesigning/notarisation stays ad-hoc/unset here on purpose — that's task 8.10's job, gated on
## an Apple Developer account Sequoyah doesn't have yet.

set -euo pipefail
cd "$(dirname "$0")/../.."

mkdir -p export
task_stage_dir="$(mktemp -d "$PWD/export/.release-staging.XXXXXX")"

cleanup() {
	case "$task_stage_dir" in
		"$PWD"/export/.release-staging.*)
			rm -rf -- "$task_stage_dir"
			;;
	esac
}
trap cleanup EXIT INT TERM

mkdir -p "$task_stage_dir/windows" "$task_stage_dir/macos" "$task_stage_dir/linux"

.agent/bin/agent godot --windowed --export-release "Windows Desktop (Release)" \
	"$task_stage_dir/windows/MIRE.exe"
.agent/bin/agent godot --windowed --export-release "macOS (Release)" \
	"$task_stage_dir/macos/MIRE.app"
.agent/bin/agent godot --windowed --export-release "Linux (Release)" \
	"$task_stage_dir/linux/MIRE.x86_64"

# Finder/File Provider metadata on a reused .app invalidates even an otherwise-good ad-hoc
# signature. A fresh staging directory prevents stale files, and stripping non-code extended
# attributes on macOS keeps the bundle verifiable before task 8.10 adds Developer ID signing.
if command -v xattr >/dev/null 2>&1; then
	xattr -cr "$task_stage_dir/macos/MIRE.app"
fi
if command -v codesign >/dev/null 2>&1; then
	codesign --verify --deep --strict --verbose=2 "$task_stage_dir/macos/MIRE.app"
fi

mkdir -p export/release
for platform in windows macos linux; do
	final_dir="$PWD/export/release/$platform"
	staged_dir="$task_stage_dir/$platform"
	rm -rf -- "$final_dir"
	mv "$staged_dir" "$final_dir"
done

echo "Release exports built under export/release/. Smoke-test before uploading, e.g.:"
echo "  ./export/release/macos/MIRE.app/Contents/MacOS/MIRE --headless --quit-after 15"
