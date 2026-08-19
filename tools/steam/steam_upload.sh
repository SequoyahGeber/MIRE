#!/usr/bin/env bash
## Uploads the current export/release/ build to Steam via steamcmd (task 8.4).
##
##   tools/steam/steam_upload.sh [branch] [steam_username]
##
## branch          Steam beta branch to publish to. Defaults to STEAM_BRANCH (steam_build_config.sh,
##                 currently "internal-beta" — S4's password-protected friends branch). Refuses
##                 "default" (the public branch) unless STEAM_ALLOW_PUBLIC=1 is also set: a bad
##                 branch argument here is a live, hard-to-reverse Steam publish, not a local mistake
##                 you can just re-run. A branch's PASSWORD is set once in the Steamworks web
##                 dashboard (App Admin -> Builds -> Steam Pipeline -> Branches) — steamcmd/steampipe
##                 has no VDF field for it, so this script can only push builds to a branch that
##                 already exists there, never create or password one.
## steam_username  Defaults to STEAM_USERNAME. steamcmd caches the login session after one
##                 interactive run (including any Steam Guard prompt), so later runs from the same
##                 machine/account don't re-prompt.
##
## Reads STEAM_APP_ID / STEAM_DEPOT_* / STEAM_BRANCH from tools/steam/steam_build_config.sh — never
## edit those values here. Also cross-checks STEAM_APP_ID against core/net/net_config.gd's runtime
## constant and refuses if they disagree (F-257) — this script is the last gate before a live
## publish, and the two copies of the App ID have no other thing keeping them in step. Renders tools/steam/templates/*.vdf.template into
## tools/steam/generated/*.vdf (gitignored — depot IDs aren't secret, but a generated file with a
## stale render from a previous config is exactly the kind of thing that shouldn't sit in git and
## silently go stale) and hands the app build script to `steamcmd +run_app_build`.
##
## Guard order matters: config placeholders and the branch check are what protects Steam itself,
## so they run before anything that costs time (steamcmd presence, the export/release/ smoke check).

set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/steam/steam_build_config.sh

BRANCH="${1:-$STEAM_BRANCH}"
STEAM_USER="${2:-${STEAM_USERNAME:-}}"

if [[ "$STEAM_APP_ID" == "480" || "$STEAM_APP_ID" == "0" ]]; then
	echo "steam_upload.sh: STEAM_APP_ID is still task 8.4's placeholder (${STEAM_APP_ID})." >&2
	echo "  Fill in the real values in tools/steam/steam_build_config.sh once task 8.2 lands." >&2
	exit 1
fi
# The App ID lives in two independent places and nothing derives one from the other: this config
# (build-time depot upload) and core/net/net_config.gd's runtime constant, which steam_lobby.gd
# passes to steamInitEx() (ARCHITECTURE.md §2.4, D-008). apply_ids.sh writes both, but a hand-edit
# of either can still drift them apart, and a build uploaded to the right depot whose clients still
# init against Spacewar's 480 looks fully wired and is unjoinable (F-257, D-155). Refuse here —
# this is the last gate before a live, hard-to-reverse Steam publish.
NET_APP_ID="$(sed -n 's/^const STEAM_APP_ID: int = \([0-9]*\)$/\1/p' core/net/net_config.gd)"
if [[ -z "$NET_APP_ID" ]]; then
	echo "steam_upload.sh: could not read core/net/net_config.gd's 'const STEAM_APP_ID' — it was renamed" >&2
	echo "  or reformatted. That constant is the runtime App ID; fix it (and apply_ids.sh's matching" >&2
	echo "  pre-flight) before uploading anything (F-257)." >&2
	exit 1
fi
if [[ "$NET_APP_ID" != "$STEAM_APP_ID" ]]; then
	echo "steam_upload.sh: App ID mismatch — the two places disagree (F-257)." >&2
	echo "  tools/steam/steam_build_config.sh : ${STEAM_APP_ID}   (depot upload)" >&2
	echo "  core/net/net_config.gd            : ${NET_APP_ID}   (runtime steamInitEx)" >&2
	echo "  Run tools/steam/apply_ids.sh <app_id> <depot_win> <depot_mac> <depot_linux> — it writes both." >&2
	exit 1
fi
if [[ "$STEAM_DEPOT_WINDOWS" == "0" || "$STEAM_DEPOT_MACOS" == "0" || "$STEAM_DEPOT_LINUX" == "0" ]]; then
	echo "steam_upload.sh: one or more STEAM_DEPOT_* values in steam_build_config.sh are still the 8.4 placeholder (0)." >&2
	echo "  Create the three depots in the Steamworks dashboard and fill their IDs in (task 8.11)." >&2
	exit 1
fi
if [[ "$BRANCH" == "default" && "${STEAM_ALLOW_PUBLIC:-0}" != "1" ]]; then
	echo "steam_upload.sh: refusing to publish to the 'default' (PUBLIC) branch." >&2
	echo "  Set STEAM_ALLOW_PUBLIC=1 if this is genuinely a public release upload." >&2
	exit 1
fi
if [[ -z "$STEAM_USER" ]]; then
	echo "steam_upload.sh: no Steam username given (arg 2 or STEAM_USERNAME env var)." >&2
	exit 1
fi
if ! command -v steamcmd >/dev/null 2>&1; then
	echo "steam_upload.sh: steamcmd not found on PATH." >&2
	echo "  Install it: https://developer.valvesoftware.com/wiki/SteamCMD" >&2
	exit 1
fi
for path in \
	"export/release/windows/MIRE.exe" \
	"export/release/macos/MIRE.app" \
	"export/release/linux/MIRE.x86_64"; do
	if [[ ! -e "$path" ]]; then
		echo "steam_upload.sh: $path missing — run tools/steam/export_release.sh first." >&2
		exit 1
	fi
done

GEN_DIR="tools/steam/generated"
mkdir -p "$GEN_DIR"
for tmpl in app_build depot_windows depot_macos depot_linux; do
	sed \
		-e "s/@STEAM_APP_ID@/${STEAM_APP_ID}/g" \
		-e "s/@STEAM_BRANCH@/${BRANCH}/g" \
		-e "s/@STEAM_DEPOT_WINDOWS@/${STEAM_DEPOT_WINDOWS}/g" \
		-e "s/@STEAM_DEPOT_MACOS@/${STEAM_DEPOT_MACOS}/g" \
		-e "s/@STEAM_DEPOT_LINUX@/${STEAM_DEPOT_LINUX}/g" \
		"tools/steam/templates/${tmpl}.vdf.template" > "$GEN_DIR/${tmpl}.vdf"
done

echo "Uploading MIRE to Steam app ${STEAM_APP_ID}, branch '${BRANCH}'..."
steamcmd +login "$STEAM_USER" +run_app_build "$(pwd)/$GEN_DIR/app_build.vdf" +quit
