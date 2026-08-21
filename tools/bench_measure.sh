#!/bin/bash
# Three fullscreen benchmark runs, back to back, unattended (F-466).
#
# Frame times from a windowed run are worthless — a backgrounded or occluded window is throttled by
# macOS and may not be drawn at all, so what gets measured is the window manager. Everything
# structural survives that; every millisecond does not. So this takes the display, in front, and
# nobody may touch the machine while it runs.
#
#   bash tools/bench_measure.sh
#
# Leave the window in front and do not move the mouse over other apps. The benchmark now detects
# losing focus and stamps "THESE TIMINGS ARE NOT VALID" on any run that did, so an interrupted run
# announces itself rather than lying.
#
# Run 1  baseline      what the shipped benchmark reports, fullscreen and honest
# Run 2  --no-prewarm  tests F-459: does a location's FIRST visit still hitch?
# Run 3  --no-readout  tests F-462: is the live readout's cost fully corrected for?
set -u
cd "$(dirname "$0")/.."
OUT="$HOME/Library/Application Support/Godot/app_userdata"

run() {
  echo ""
  echo "=========== $1 ==========="
  .agent/bin/agent godot --display-driver macos --script tools/benchmark_check.gd -- \
    --full --fullscreen --tag "$1" "${@:2}" 2>&1 \
    | grep -E "assertion\(s\)|^  FAIL|1% low +[0-9]|^  → |focus:" || true
}

run baseline
run noprewarm --no-prewarm
run noreadout --no-readout

echo ""
echo "=========== reports ==========="
for tag in baseline noprewarm noreadout; do
  f=$(ls "$OUT"/*/benchmark_check/report_$tag.txt 2>/dev/null | head -1)
  [ -n "$f" ] && { echo ""; echo "----- $tag -----"; cat "$f"; }
done
