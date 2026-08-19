#!/usr/bin/env bash
## Verifies task 8.11's depot-wiring tooling without a real Steam App ID (none exists yet — 8.1/8.2
## are still todo, see DEPOT_SETUP.md). Three things:
##
##   1. Every tools/steam/*.sh script parses (`bash -n`).
##   2. apply_ids.sh, run against a scratch copy of steam_build_config.sh, rewrites exactly the
##      four placeholder defaults and leaves every other line byte-identical; and refuses on each
##      of: wrong arg count, a non-numeric argument, the 480/0 placeholders themselves, and two
##      equal depot IDs.
##   3. DEPOT_SETUP.md's documented per-platform executable names agree with what
##      export_release.sh actually builds and what each depot_<platform>.vdf.template's
##      ContentRoot points at, so the runbook can't silently drift from the pipeline it describes.
##
## Run with: bash tools/steam/depot_wiring_check.sh

set -uo pipefail
cd "$(dirname "$0")/../.."

FAIL=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAIL=1; }

echo "1. bash -n on every tools/steam/*.sh script"
for f in tools/steam/*.sh; do
	if bash -n "$f" 2>/tmp/depot_check_syntax_err; then
		pass "$f"
	else
		fail "$f: $(cat /tmp/depot_check_syntax_err)"
	fi
done
rm -f /tmp/depot_check_syntax_err

echo "2. apply_ids.sh behaviour, against a scratch copy"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cp tools/steam/steam_build_config.sh "$SCRATCH/steam_build_config.sh"

LAST_FAKE_CONFIG=""
run_apply() {
	# Runs apply_ids.sh against a scratch config by copying it + the script into an isolated fake
	# repo (apply_ids.sh always cds to its own repo root). Returns apply_ids.sh's own exit code —
	# callers must check $? (via `if run_apply ...`), not just that the function returned.
	local fake="$SCRATCH/fakerepo"
	rm -rf "$fake"
	mkdir -p "$fake/tools/steam"
	cp tools/steam/apply_ids.sh "$fake/tools/steam/apply_ids.sh"
	cp "$SCRATCH/steam_build_config.sh" "$fake/tools/steam/steam_build_config.sh"
	LAST_FAKE_CONFIG="$fake/tools/steam/steam_build_config.sh"
	local rc=0
	(cd "$fake/tools/steam" && bash apply_ids.sh "$@") >"$SCRATCH/last_stdout" 2>"$SCRATCH/last_stderr" || rc=$?
	return "$rc"
}

# 2a. wrong arg count -> refuse
if run_apply 111 222 333; then
	fail "wrong arg count should have been refused"
else
	pass "refuses wrong arg count"
fi

# 2b. non-numeric -> refuse
if run_apply abc 222 333 444; then
	fail "non-numeric App ID should have been refused"
else
	pass "refuses non-numeric input"
fi

# 2c. placeholder App ID (480) -> refuse
if run_apply 480 222 333 444; then
	fail "placeholder App ID 480 should have been refused"
else
	pass "refuses the 480 App ID placeholder"
fi

# 2d. placeholder depot (0) -> refuse
if run_apply 111222 0 333 444; then
	fail "placeholder depot ID 0 should have been refused"
else
	pass "refuses a 0 depot ID placeholder"
fi

# 2e. two equal depot IDs -> refuse
if run_apply 111222 555 555 444; then
	fail "two equal depot IDs should have been refused"
else
	pass "refuses two equal depot IDs"
fi

# 2f. valid distinct numeric IDs -> succeeds and rewrites exactly the four defaults
if run_apply 111222 333001 333002 333003; then
	RESULT_FILE="$LAST_FAKE_CONFIG"
	if grep -q 'STEAM_APP_ID:-111222' "$RESULT_FILE" \
		&& grep -q 'STEAM_DEPOT_WINDOWS:-333001' "$RESULT_FILE" \
		&& grep -q 'STEAM_DEPOT_MACOS:-333002' "$RESULT_FILE" \
		&& grep -q 'STEAM_DEPOT_LINUX:-333003' "$RESULT_FILE"; then
		pass "valid IDs are written correctly"
	else
		fail "valid IDs were not all written correctly — got:\n$(grep STEAM_ "$RESULT_FILE")"
	fi
	# Every non-placeholder line (comments, STEAM_BRANCH, blank lines) must be untouched.
	DIFF_OTHER="$(diff <(grep -v 'STEAM_APP_ID\|STEAM_DEPOT_' tools/steam/steam_build_config.sh) \
		<(grep -v 'STEAM_APP_ID\|STEAM_DEPOT_' "$RESULT_FILE"))"
	if [[ -z "$DIFF_OTHER" ]]; then
		pass "every other line is byte-identical"
	else
		fail "apply_ids.sh changed a line it shouldn't have:\n$DIFF_OTHER"
	fi
else
	fail "apply_ids.sh with valid distinct IDs was refused: $(cat "$SCRATCH/last_stderr" 2>/dev/null)"
fi

echo "3. DEPOT_SETUP.md agrees with the pipeline it describes"
for exe in MIRE.exe MIRE.app MIRE.x86_64; do
	if grep -q "$exe" tools/steam/DEPOT_SETUP.md; then
		pass "DEPOT_SETUP.md documents $exe"
	else
		fail "DEPOT_SETUP.md does not mention $exe"
	fi
	if grep -q "$exe" tools/steam/export_release.sh; then
		pass "export_release.sh builds $exe"
	else
		fail "export_release.sh does not build $exe — DEPOT_SETUP.md is stale"
	fi
done
for plat_tmpl_exe in "depot_windows:windows/" "depot_macos:macos/" "depot_linux:linux/"; do
	tmpl="${plat_tmpl_exe%%:*}"
	frag="${plat_tmpl_exe#*:}"
	if grep -q "export/release/${frag}" "tools/steam/templates/${tmpl}.vdf.template"; then
		pass "${tmpl}.vdf.template's ContentRoot points at export/release/${frag}"
	else
		fail "${tmpl}.vdf.template's ContentRoot does not point at export/release/${frag}"
	fi
done

echo
if [[ "$FAIL" -eq 0 ]]; then
	echo "depot_wiring_check.sh: ALL CHECKS PASSED"
	exit 0
else
	echo "depot_wiring_check.sh: FAILED"
	exit 1
fi
