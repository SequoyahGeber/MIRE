#!/usr/bin/env bash
## Writes real Steam App ID + three depot IDs into tools/steam/steam_build_config.sh (task 8.11).
##
##   tools/steam/apply_ids.sh <app_id> <depot_windows> <depot_macos> <depot_linux>
##
## Run this once tools/steam/DEPOT_SETUP.md's dashboard steps are done and you have four real
## Steamworks IDs in hand. Rewrites steam_build_config.sh's four placeholder defaults in place —
## the same four values steam_upload.sh's guard clauses check for and refuse to run against
## (task 8.4, D-132). Never touches steam_upload.sh or the .vdf templates; those were already
## written generically against whatever real IDs eventually land here.
##
## Does NOT touch core/net/net_config.gd's STEAM_APP_ID — the runtime constant steam_lobby.gd
## actually passes to steamInitEx() (ARCHITECTURE.md §2.4 names that the swap point). That is a
## separate edit task 8.2 must also make; running this script alone does not mean the App ID is
## swapped everywhere (F-257).
##
## Refuses to run if any argument still looks like a placeholder (480, or 0), isn't a plain
## positive integer, or two depot IDs collide — a typo here would write a config that silently
## un-refuses steam_upload.sh's guard with the WRONG real-looking ID, which is a worse failure
## than the placeholder it replaces.

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

sed -i.bak \
	-e "s/^export STEAM_APP_ID=\"\${STEAM_APP_ID:-[0-9]*}\"/export STEAM_APP_ID=\"\${STEAM_APP_ID:-${APP_ID}}\"/" \
	-e "s/^export STEAM_DEPOT_WINDOWS=\"\${STEAM_DEPOT_WINDOWS:-[0-9]*}\"/export STEAM_DEPOT_WINDOWS=\"\${STEAM_DEPOT_WINDOWS:-${DEPOT_WIN}}\"/" \
	-e "s/^export STEAM_DEPOT_MACOS=\"\${STEAM_DEPOT_MACOS:-[0-9]*}\"/export STEAM_DEPOT_MACOS=\"\${STEAM_DEPOT_MACOS:-${DEPOT_MAC}}\"/" \
	-e "s/^export STEAM_DEPOT_LINUX=\"\${STEAM_DEPOT_LINUX:-[0-9]*}\"/export STEAM_DEPOT_LINUX=\"\${STEAM_DEPOT_LINUX:-${DEPOT_LINUX}}\"/" \
	"$CONFIG"
rm -f "$CONFIG.bak"

echo "Wrote real IDs into $CONFIG:"
grep -E "STEAM_APP_ID|STEAM_DEPOT_" "$CONFIG"
echo
echo "Next: tools/steam/export_release.sh, then tools/steam/steam_upload.sh <branch> <username>."
