#!/usr/bin/env bash
## Single source of truth for the Steam identifiers the build pipeline needs (task 8.4).
##
## Sourced by export_release.sh and steam_upload.sh — never hardcode these values in either
## script. All four values below are still the D-008 placeholder: task 8.1 (Steamworks account,
## $100 Direct fee) and 8.2 (App ID swap) have not run yet, so there is no real App ID or depot
## set to put here. Fill these in as part of 8.2, not before — a real App ID with no matching
## Steamworks depots configured just turns this file into a link to something that doesn't work
## yet. Depot IDs themselves get created in the Steamworks web dashboard once the App ID exists;
## wiring the real ones in per-platform is task 8.11's job, not this file's.
##
## Everything here is public once the store page exists (an App ID is visible in the store URL) —
## nothing in this file is a secret. steamcmd's own login session (cached under ~/Steam/config/
## after one interactive `+login`) is what actually gates who can publish.

export STEAM_APP_ID="${STEAM_APP_ID:-480}"          # 480 = Spacewar, D-008's dev placeholder
export STEAM_DEPOT_WINDOWS="${STEAM_DEPOT_WINDOWS:-0}"
export STEAM_DEPOT_MACOS="${STEAM_DEPOT_MACOS:-0}"
export STEAM_DEPOT_LINUX="${STEAM_DEPOT_LINUX:-0}"

# Never "default" (the public branch) from this pipeline — see steam_upload.sh's guard.
export STEAM_BRANCH="${STEAM_BRANCH:-internal-beta}"
