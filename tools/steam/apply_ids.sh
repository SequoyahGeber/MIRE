#!/usr/bin/env bash
## Writes the real Steam App ID + three depot IDs into BOTH places the App ID lives (tasks 8.11,
## 8.2 / F-257).
##
##   tools/steam/apply_ids.sh <app_id> <depot_windows> <depot_macos> <depot_linux>
##
## Run this once tools/steam/DEPOT_SETUP.md's dashboard steps are done and you have four real
## Steamworks IDs in hand. It rewrites:
##
##   1. tools/steam/steam_build_config.sh — all four placeholder defaults. These feed the offline
##      steamcmd upload pipeline only (export_release.sh / steam_upload.sh / the .vdf templates),
##      task 8.4 / D-132. Never touches steam_upload.sh or the templates; those were already
##      written generically against whatever real IDs eventually land here.
##   2. core/net/net_config.gd's `const STEAM_APP_ID` — the RUNTIME constant steam_lobby.gd passes
##      to steamInitEx(), which ARCHITECTURE.md §2.4 / D-008 name as the one-line swap point.
##   3. steam_appid.txt at the repo root — what the Steam SDK reads when steamInitEx() is called
##      with app_id 0, i.e. every editor/headless dev run (tools/steam_check.gd does exactly this).
##      D-022 keeps it out of release builds via each preset's exclude_filter, so it is a dev-only
##      file — but a dev-only file that says 480 while the other two say the real ID means every
##      local Steam check is exercising Spacewar, not the game.
##
## The three are independent (build-time depot upload / runtime lobby init / dev-run SDK bootstrap)
## and nothing derives any of them from another, so before D-155 it was possible to apply the real
## ID here, watch depot_wiring_check.sh go green, and ship a build that uploads to the right depot
## while every client still calls steamInitEx() against Spacewar's 480 — a silently broken release
## that looks fully wired (F-257). This script now writes all three, so that partial swap cannot
## happen by omission; steam_upload.sh additionally refuses to upload if they ever disagree.
##
## CLAIM NOTE (D-155): this script edits core/net/net_config.gd and steam_appid.txt, both outside
## tools/steam/. An agent running it must hold claims on those too, not just steam_build_config.sh.
##
## Refuses to run if any argument still looks like a placeholder (480, or 0), isn't a plain
## positive integer, or two depot IDs collide — a typo here would write a config that silently
## un-refuses steam_upload.sh's guard with the WRONG real-looking ID, which is a worse failure
## than the placeholder it replaces. It also refuses BEFORE writing anything if either target line
## is missing or ambiguous, and rolls both files back if either fails to read back the new ID: a
## partial application is the exact failure this script exists to make impossible.

set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ $# -ne 4 ]]; then
	echo "usage: tools/steam/apply_ids.sh <app_id> <depot_windows> <depot_macos> <depot_linux>" >&2
	exit 1
fi

APP_ID="$1"
DEPOT_WIN="$2"
DEPOT_MAC="$3"
DEPOT_LINUX="$4"
CONFIG="tools/steam/steam_build_config.sh"
NET_CONFIG="core/net/net_config.gd"
APPID_TXT="steam_appid.txt"

for pair in "APP_ID:$APP_ID" "DEPOT_WIN:$DEPOT_WIN" "DEPOT_MAC:$DEPOT_MAC" "DEPOT_LINUX:$DEPOT_LINUX"; do
	name="${pair%%:*}"
	val="${pair#*:}"
	if ! [[ "$val" =~ ^[0-9]+$ ]]; then
		echo "apply_ids.sh: $name='$val' is not a plain positive integer — Steam IDs are numeric." >&2
		exit 1
	fi
done
if [[ "$APP_ID" == "480" ]]; then
	echo "apply_ids.sh: refusing — 480 is the D-008 dev placeholder (Spacewar), not a real App ID." >&2
	exit 1
fi
if [[ "$DEPOT_WIN" == "0" || "$DEPOT_MAC" == "0" || "$DEPOT_LINUX" == "0" ]]; then
	echo "apply_ids.sh: refusing — a depot ID of 0 is task 8.4's placeholder, not a real depot." >&2
	exit 1
fi
if [[ "$DEPOT_WIN" == "$DEPOT_MAC" || "$DEPOT_WIN" == "$DEPOT_LINUX" || "$DEPOT_MAC" == "$DEPOT_LINUX" ]]; then
	echo "apply_ids.sh: refusing — two depot IDs are identical; Steamworks assigns each depot its own id." >&2
	exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
	echo "apply_ids.sh: $CONFIG not found — run from a checkout with tools/steam/ intact." >&2
	exit 1
fi
if [[ ! -f "$NET_CONFIG" ]]; then
	echo "apply_ids.sh: $NET_CONFIG not found — this script writes the runtime App ID too (F-257)." >&2
	echo "  Run it from a full checkout, not from tools/steam/ alone." >&2
	exit 1
fi
if [[ ! -f "$APPID_TXT" ]]; then
	echo "apply_ids.sh: $APPID_TXT not found — this script writes the dev-run App ID too (F-257)." >&2
	echo "  Run it from a full checkout, not from tools/steam/ alone." >&2
	exit 1
fi
if ! [[ "$(cat "$APPID_TXT")" =~ ^[0-9]+$ ]]; then
	echo "apply_ids.sh: $APPID_TXT does not hold a bare numeric App ID — refusing to overwrite it blind." >&2
	echo "  Nothing was written. Steam's SDK reads this file verbatim; fix it by hand first (F-257)." >&2
	exit 1
fi

# Pre-flight: every line we are about to rewrite must exist exactly once, in BOTH files, before we
# write to either. Writing one file and then discovering the other's line has been renamed is the
# half-applied state this script exists to prevent.
count_matches() { grep -cE "$1" "$2" || true; }
PREFLIGHT_FAIL=0
for pair in \
	"^export STEAM_APP_ID=\"\\\$\\{STEAM_APP_ID:-[0-9]+\\}\"|$CONFIG" \
	"^export STEAM_DEPOT_WINDOWS=\"\\\$\\{STEAM_DEPOT_WINDOWS:-[0-9]+\\}\"|$CONFIG" \
	"^export STEAM_DEPOT_MACOS=\"\\\$\\{STEAM_DEPOT_MACOS:-[0-9]+\\}\"|$CONFIG" \
	"^export STEAM_DEPOT_LINUX=\"\\\$\\{STEAM_DEPOT_LINUX:-[0-9]+\\}\"|$CONFIG" \
	"^const STEAM_APP_ID: int = [0-9]+$|$NET_CONFIG" \
; do
	re="${pair%%|*}"
	file="${pair#*|}"
	n="$(count_matches "$re" "$file")"
	if [[ "$n" -ne 1 ]]; then
		echo "apply_ids.sh: $file has $n line(s) matching /$re/, expected exactly 1." >&2
		PREFLIGHT_FAIL=1
	fi
done
if [[ "$PREFLIGHT_FAIL" -ne 0 ]]; then
	echo "  Nothing was written. Someone renamed or duplicated a target line — fix that first," >&2
	echo "  and update this script and tools/steam/depot_wiring_check.sh together (F-257)." >&2
	exit 1
fi

sed -i.bak \
	-e "s/^export STEAM_APP_ID=\"\${STEAM_APP_ID:-[0-9]*}\"/export STEAM_APP_ID=\"\${STEAM_APP_ID:-${APP_ID}}\"/" \
	-e "s/^export STEAM_DEPOT_WINDOWS=\"\${STEAM_DEPOT_WINDOWS:-[0-9]*}\"/export STEAM_DEPOT_WINDOWS=\"\${STEAM_DEPOT_WINDOWS:-${DEPOT_WIN}}\"/" \
	-e "s/^export STEAM_DEPOT_MACOS=\"\${STEAM_DEPOT_MACOS:-[0-9]*}\"/export STEAM_DEPOT_MACOS=\"\${STEAM_DEPOT_MACOS:-${DEPOT_MAC}}\"/" \
	-e "s/^export STEAM_DEPOT_LINUX=\"\${STEAM_DEPOT_LINUX:-[0-9]*}\"/export STEAM_DEPOT_LINUX=\"\${STEAM_DEPOT_LINUX:-${DEPOT_LINUX}}\"/" \
	"$CONFIG"
sed -i.bak \
	-e "s/^const STEAM_APP_ID: int = [0-9]*$/const STEAM_APP_ID: int = ${APP_ID}/" \
	"$NET_CONFIG"
# No trailing newline: Steam's SDK reads this file verbatim, and the checked-in file has none.
cp "$APPID_TXT" "$APPID_TXT.bak"
printf '%s' "$APP_ID" >"$APPID_TXT"

# Read both back. If either did not take, put both files back exactly as they were — a rolled-back
# pair is recoverable; a half-applied pair ships a build nobody can join.
READBACK_FAIL=0
grep -q "STEAM_APP_ID:-${APP_ID}}" "$CONFIG" || READBACK_FAIL=1
grep -q "STEAM_DEPOT_WINDOWS:-${DEPOT_WIN}}" "$CONFIG" || READBACK_FAIL=1
grep -q "STEAM_DEPOT_MACOS:-${DEPOT_MAC}}" "$CONFIG" || READBACK_FAIL=1
grep -q "STEAM_DEPOT_LINUX:-${DEPOT_LINUX}}" "$CONFIG" || READBACK_FAIL=1
grep -qx "const STEAM_APP_ID: int = ${APP_ID}" "$NET_CONFIG" || READBACK_FAIL=1
[[ "$(cat "$APPID_TXT")" == "$APP_ID" ]] || READBACK_FAIL=1
if [[ "$READBACK_FAIL" -ne 0 ]]; then
	mv -f "$CONFIG.bak" "$CONFIG"
	mv -f "$NET_CONFIG.bak" "$NET_CONFIG"
	mv -f "$APPID_TXT.bak" "$APPID_TXT"
	echo "apply_ids.sh: a value did not read back after writing — all three files rolled back, nothing changed." >&2
	exit 1
fi
rm -f "$CONFIG.bak" "$NET_CONFIG.bak" "$APPID_TXT.bak"

echo "Wrote real IDs into $CONFIG:"
grep -E "STEAM_APP_ID|STEAM_DEPOT_" "$CONFIG"
echo
echo "Wrote the runtime App ID into $NET_CONFIG (F-257):"
grep -n "^const STEAM_APP_ID" "$NET_CONFIG"
echo
echo "Wrote the dev-run App ID into $APPID_TXT (F-257): $(cat "$APPID_TXT")"
echo
echo "Next: tools/steam/depot_wiring_check.sh, then export_release.sh, then steam_upload.sh <branch> <username>."
