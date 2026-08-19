# Wiring the real depots and launch options in (task 8.11)

**Blocked until task 8.2 ships a real App ID** (`.agent/state.json`: 8.1 and 8.2 both `todo` as of
2026-08-19). Steamworks' Builds → Depots page does not exist until an App ID does, and the
Steamworks account/tax interview/$100 Direct fee behind 8.1 is Sequoyah's alone to run — no agent
has the account access (`AGENTS.md` D-039's "his accounts" exception; see `docs/DECISIONS.md`
D-132). Everything below is prepared so that once 8.2 lands, filling the real values in is a single
script run instead of a from-scratch design pass.

## What this repo already produces, per platform

`tools/steam/export_release.sh` (task 8.4) builds these three executables, and
`tools/steam/templates/depot_<platform>.vdf.template` (also 8.4) already points each depot's
`ContentRoot` at the directory holding it:

| Platform | Executable | `ContentRoot` (relative to `tools/steam/generated/`) |
|---|---|---|
| Windows | `MIRE.exe` | `../../../export/release/windows/` |
| macOS | `MIRE.app` | `../../../export/release/macos/` |
| Linux | `MIRE.x86_64` | `../../../export/release/linux/` |

No dedicated server build exists or is planned — MIRE is a host-authoritative listen server
(`ARCHITECTURE.md` §2.1, `DESIGN.md` §7 cut list) — so each platform needs exactly **one** launch
option, not a client/server pair.

## Steps, once 8.2 lands

1. **Create the three depots** — Steamworks web dashboard, App Admin → Builds → Steam Pipeline →
   Depots → New Depot, one per platform. Name them so the OS is obvious in the dashboard list (e.g.
   `MIRE Windows Depot`, `MIRE macOS Depot`, `MIRE Linux Depot`) — Steamworks assigns each a numeric
   depot ID; write the three IDs down.

2. **Set each depot's OS/arch restriction** on its own Depot page (`Depot → General`) so Steam only
   ever downloads the matching platform's depot to a given customer:
   - Windows depot → `Operating System: Windows`, `Architecture: 64-bit`
   - macOS depot → `Operating System: macOS`
   - Linux depot → `Operating System: Linux`, `Architecture: 64-bit`

3. **Set launch options** — App Admin → Installation → General Installation → Launch section, one
   entry per platform, matching the table above:

   | Field | Windows | macOS | Linux |
   |---|---|---|---|
   | Executable | `MIRE.exe` | `MIRE.app` | `MIRE.x86_64` |
   | Arguments | *(none)* | *(none)* | *(none)* |
   | Type | None (default) | None (default) | None (default) |
   | Config OS | Windows | macOS | Linux |
   | Config Arch | 64-bit | *(n/a)* | 64-bit |

   Leave "Description" and beta-only fields blank — there is exactly one launch path per platform,
   nothing to disambiguate for a player.

4. **Wire the four real IDs into this repo in one shot:**

   ```bash
   tools/steam/apply_ids.sh <app_id> <depot_windows_id> <depot_macos_id> <depot_linux_id>
   ```

   This is the **only** command that needs running — it writes all three places the App ID lives,
   which is the whole point of it existing (D-155, F-257):

   | File | What reads it |
   |---|---|
   | `tools/steam/steam_build_config.sh` | the offline `steamcmd` depot upload — App ID + all three depot IDs (task 8.4) |
   | `core/net/net_config.gd` (`const STEAM_APP_ID`) | the runtime value `steam_lobby.gd` passes to `steamInitEx()` (`ARCHITECTURE.md` §2.4) |
   | `steam_appid.txt` (repo root) | the Steam SDK, on any dev run that inits with app_id 0 — `tools/steam_check.gd` does |

   Nothing derives any of the three from another, so before D-155 it was possible to apply the real
   ID, watch `depot_wiring_check.sh` go green, and ship a build that uploads to the correct depot
   while every client still initialises against Spacewar's 480 — unjoinable, and indistinguishable
   from a fully wired release. The script refuses if any argument still looks like a placeholder,
   isn't numeric, or two depot IDs collide; it also refuses **before writing anything** if any of
   the three target lines is missing, renamed or duplicated, and rolls all three back if a value
   fails to read back. See the script's own header. It never touches `steam_upload.sh` or the
   `.vdf` templates; those were already written generically against whatever real IDs land here
   (D-132).

   **If you are an agent:** two of those three files live outside `tools/steam/`. Hold claims on
   `core/net/net_config.gd` and `steam_appid.txt` as well as `tools/steam/steam_build_config.sh`
   before you run it (D-155).

5. **Verify:** `bash tools/steam/depot_wiring_check.sh` — its §4 asserts all three App IDs agree,
   which is the check that catches a hand-edit drifting them apart. Then a real
   `tools/steam/steam_upload.sh internal-beta <username>` against the `internal-beta` branch (never
   `default` without `STEAM_ALLOW_PUBLIC=1` — `steam_upload.sh`'s own guard). `steam_upload.sh`
   independently re-reads `net_config.gd`'s constant and refuses to publish if it disagrees with
   the config's, so a drifted pair cannot reach Steam even if nobody ran the check.

6. **Task 8.2 owns the App ID swap; this runbook owns the depots.** 8.2's job is running step 4 with
   the real App ID and then verifying Steam features actually work against it (lobby create/join,
   achievements — `autoload/steam_stats.gd` has none registered under 480). It is no longer a
   second, separate file edit: step 4 does the writing. What 8.2 must still do by hand is confirm
   `depot_wiring_check.sh` §4 is green afterwards and re-run `agent godot --script
   tools/steam_check.gd` with the Steam client up, which asserts the running App ID equals
   `NetConfig.STEAM_APP_ID`.

## What is NOT scriptable from this repo

A beta branch's **password** has no steamcmd/VDF field either (D-132) — same dashboard-only
category as the launch options above, but that one has no repo-side script to hand off to, because
a password isn't a value this repo would ever hold. Launch options *do* get a script (step 4) only
because their values are fully determined by what `export_release.sh` already builds — nothing
about them depends on secrets, so writing them down and scripting the config write is safe.
