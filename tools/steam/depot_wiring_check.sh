#!/usr/bin/env bash
## Verifies task 8.11's depot-wiring tooling without a real Steam App ID (none exists yet — 8.1/8.2
## are still todo, see DEPOT_SETUP.md). Five things:
##
##   1. Every tools/steam/*.sh script parses (`bash -n`).
##   2. apply_ids.sh, run against a scratch copy of steam_build_config.sh, core/net/net_config.gd
##      AND steam_appid.txt, rewrites exactly the four placeholder defaults plus the runtime
##      STEAM_APP_ID constant plus the dev-run App ID file, leaving every other line of each
##      byte-identical; and refuses on each of: wrong arg count, a non-numeric argument, the 480/0
##      placeholders themselves, two equal depot IDs, a missing net_config.gd, a net_config.gd
##      whose constant line has been renamed, and a missing steam_appid.txt — the refusals without
##      writing anything to steam_build_config.sh (F-257: a partly-applied App ID is the failure
##      this whole check exists for).
##   3. DEPOT_SETUP.md's documented per-platform executable names agree with what
##      export_release.sh actually builds and what each depot_<platform>.vdf.template's
##      ContentRoot points at, so the runbook can't silently drift from the pipeline it describes.
##   4. All THREE App IDs in this repo right now agree: steam_build_config.sh's STEAM_APP_ID
##      default, core/net/net_config.gd's runtime constant, and steam_appid.txt. Nothing derives
##      any of them from another, so this is the only thing that notices drift (F-257, D-155).
##   5. steam_upload.sh's own mismatch guard fires — a repo whose two shipped App IDs disagree
##      cannot upload, and a repo where they agree gets past that guard.
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
LAST_FAKE_NET=""
LAST_FAKE_APPID=""
# Set before a run_apply call to alter the fake repo's core/net/net_config.gd:
#   ""        — a faithful copy (the normal case)
#   "absent"  — no core/net/ at all
#   "renamed" — present, but the `const STEAM_APP_ID` declaration line no longer matches
FAKE_NET_MODE=""
# Set to "absent" before a run_apply call to leave steam_appid.txt out of the fake repo.
FAKE_APPID_MODE=""
run_apply() {
	# Runs apply_ids.sh against a scratch config by copying it + the script + core/net/net_config.gd
	# into an isolated fake repo (apply_ids.sh always cds to its own repo root, and since F-257 it
	# writes BOTH files). Returns apply_ids.sh's own exit code — callers must check $? (via
	# `if run_apply ...`), not just that the function returned.
	local fake="$SCRATCH/fakerepo"
	rm -rf "$fake"
	mkdir -p "$fake/tools/steam"
	cp tools/steam/apply_ids.sh "$fake/tools/steam/apply_ids.sh"
	cp "$SCRATCH/steam_build_config.sh" "$fake/tools/steam/steam_build_config.sh"
	LAST_FAKE_CONFIG="$fake/tools/steam/steam_build_config.sh"
	LAST_FAKE_NET="$fake/core/net/net_config.gd"
	LAST_FAKE_APPID="$fake/steam_appid.txt"
	if [[ "$FAKE_APPID_MODE" != "absent" ]]; then
		cp steam_appid.txt "$LAST_FAKE_APPID"
	fi
	if [[ "$FAKE_NET_MODE" != "absent" ]]; then
		mkdir -p "$fake/core/net"
		cp core/net/net_config.gd "$LAST_FAKE_NET"
		if [[ "$FAKE_NET_MODE" == "renamed" ]]; then
			sed -i.bak 's/^const STEAM_APP_ID: int = /const STEAM_APPID_RENAMED: int = /' "$LAST_FAKE_NET"
			rm -f "$LAST_FAKE_NET.bak"
		fi
	fi
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
	# ...and the SECOND place the App ID lives — the runtime constant (F-257).
	if grep -qx 'const STEAM_APP_ID: int = 111222' "$LAST_FAKE_NET"; then
		pass "the runtime constant in core/net/net_config.gd is rewritten too"
	else
		fail "net_config.gd's STEAM_APP_ID was not rewritten — got: $(grep -n '^const STEAM_APP_ID' "$LAST_FAKE_NET" 2>/dev/null)"
	fi
	DIFF_NET="$(diff <(grep -v '^const STEAM_APP_ID: int = ' core/net/net_config.gd) \
		<(grep -v '^const STEAM_APP_ID: int = ' "$LAST_FAKE_NET"))"
	if [[ -z "$DIFF_NET" ]]; then
		pass "every other line of net_config.gd is byte-identical"
	else
		fail "apply_ids.sh changed a net_config.gd line it shouldn't have:\n$DIFF_NET"
	fi
	# ...and the THIRD place — the dev-run file Steam's SDK reads verbatim. Byte-exact: it must
	# stay a bare number with no trailing newline, or steamInitEx() reads a different App ID.
	APPID_BYTES="$(od -An -c "$LAST_FAKE_APPID" 2>/dev/null | tr -s ' ')"
	if [[ "$(cat "$LAST_FAKE_APPID" 2>/dev/null)" == "111222" && "$APPID_BYTES" != *"\\n"* ]]; then
		pass "steam_appid.txt is rewritten, still a bare number with no trailing newline"
	else
		fail "steam_appid.txt is wrong — content '$(cat "$LAST_FAKE_APPID" 2>/dev/null)', bytes:$APPID_BYTES"
	fi
else
	fail "apply_ids.sh with valid distinct IDs was refused: $(cat "$SCRATCH/last_stderr" 2>/dev/null)"
fi

# 2g. net_config.gd missing -> refuse, and write NOTHING to steam_build_config.sh. A run that
#     rewrote the depot config and then bailed on the runtime constant is precisely F-257's
#     half-applied App ID, just reached by a different route.
FAKE_NET_MODE="absent"
if run_apply 111222 333001 333002 333003; then
	fail "a missing core/net/net_config.gd should have been refused"
else
	if grep -q 'STEAM_APP_ID:-480' "$LAST_FAKE_CONFIG"; then
		pass "refuses a missing net_config.gd without touching steam_build_config.sh"
	else
		fail "refused, but steam_build_config.sh was already rewritten — half-applied (F-257)"
	fi
fi

# 2h. net_config.gd present but its constant line renamed/reformatted -> same deal.
FAKE_NET_MODE="renamed"
if run_apply 111222 333001 333002 333003; then
	fail "a renamed STEAM_APP_ID constant should have been refused"
else
	if grep -q 'STEAM_APP_ID:-480' "$LAST_FAKE_CONFIG"; then
		pass "refuses a renamed net_config.gd constant without touching steam_build_config.sh"
	else
		fail "refused, but steam_build_config.sh was already rewritten — half-applied (F-257)"
	fi
fi

# 2i. steam_appid.txt missing -> refuse, again without writing anything.
FAKE_APPID_MODE="absent"
if run_apply 111222 333001 333002 333003; then
	fail "a missing steam_appid.txt should have been refused"
else
	if grep -q 'STEAM_APP_ID:-480' "$LAST_FAKE_CONFIG"; then
		pass "refuses a missing steam_appid.txt without touching steam_build_config.sh"
	else
		fail "refused, but steam_build_config.sh was already rewritten — partly applied (F-257)"
	fi
fi
FAKE_NET_MODE=""
FAKE_APPID_MODE=""

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

echo "4. the repo's three App IDs agree right now (F-257)"
CONFIG_APP_ID="$(sed -n 's/^export STEAM_APP_ID="${STEAM_APP_ID:-\([0-9]*\)}".*/\1/p' tools/steam/steam_build_config.sh)"
NET_APP_ID="$(sed -n 's/^const STEAM_APP_ID: int = \([0-9]*\)$/\1/p' core/net/net_config.gd)"
TXT_APP_ID="$(cat steam_appid.txt 2>/dev/null)"
if [[ -z "$CONFIG_APP_ID" ]]; then
	fail "could not read STEAM_APP_ID out of steam_build_config.sh — apply_ids.sh's regex is stale too"
elif [[ -z "$NET_APP_ID" ]]; then
	fail "could not read 'const STEAM_APP_ID' out of core/net/net_config.gd — apply_ids.sh's regex is stale too"
elif ! [[ "$TXT_APP_ID" =~ ^[0-9]+$ ]]; then
	fail "steam_appid.txt does not hold a bare numeric App ID — Steam's SDK reads it verbatim; got '${TXT_APP_ID}'"
elif [[ "$CONFIG_APP_ID" == "$NET_APP_ID" && "$CONFIG_APP_ID" == "$TXT_APP_ID" ]]; then
	pass "steam_build_config.sh, net_config.gd and steam_appid.txt all say App ID ${CONFIG_APP_ID}"
else
	fail "App ID drift: steam_build_config.sh=${CONFIG_APP_ID} vs net_config.gd=${NET_APP_ID} vs steam_appid.txt=${TXT_APP_ID} — run apply_ids.sh, which writes all three"
fi

echo "5. steam_upload.sh refuses a mismatched pair"
# Guard order in steam_upload.sh puts the config checks ahead of anything that costs time, so this
# runs with no steamcmd, no export/, and no Steam account. Both cases use a real-looking App ID so
# the 480-placeholder guard above it doesn't fire first and mask the result.
upload_guard() {
	local fake="$SCRATCH/uploadrepo" net_id="$1" cfg_id="$2"
	rm -rf "$fake"
	mkdir -p "$fake/tools/steam" "$fake/core/net"
	cp tools/steam/steam_upload.sh "$fake/tools/steam/steam_upload.sh"
	sed -e "s/^export STEAM_APP_ID=\"\${STEAM_APP_ID:-[0-9]*}\"/export STEAM_APP_ID=\"\${STEAM_APP_ID:-${cfg_id}}\"/" \
		-e 's/^export STEAM_DEPOT_\(.*\)="${STEAM_DEPOT_\(.*\):-0}"/export STEAM_DEPOT_\1="${STEAM_DEPOT_\2:-333001}"/' \
		tools/steam/steam_build_config.sh >"$fake/tools/steam/steam_build_config.sh"
	sed "s/^const STEAM_APP_ID: int = [0-9]*$/const STEAM_APP_ID: int = ${net_id}/" \
		core/net/net_config.gd >"$fake/core/net/net_config.gd"
	(cd "$fake/tools/steam" && bash steam_upload.sh internal-beta someuser) >"$SCRATCH/up_stdout" 2>"$SCRATCH/up_stderr" || true
	cat "$SCRATCH/up_stderr"
}
if upload_guard 480 111222 | grep -q "App ID mismatch"; then
	pass "refuses when net_config.gd still says 480 and the config says a real ID"
else
	fail "steam_upload.sh did not refuse a mismatched App ID pair — got: $(cat "$SCRATCH/up_stderr" 2>/dev/null | head -3)"
fi
if upload_guard 111222 111222 | grep -q "App ID mismatch"; then
	fail "steam_upload.sh refused a MATCHING App ID pair — the guard is misreading one of the two files"
else
	pass "lets a matching pair past the mismatch guard"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
	echo "depot_wiring_check.sh: ALL CHECKS PASSED"
	exit 0
else
	echo "depot_wiring_check.sh: FAILED"
	exit 1
fi
