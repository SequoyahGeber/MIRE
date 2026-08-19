# Wiring the real achievements and stats in (task 8.3)

**Blocked until task 8.2 ships a real App ID** (`.agent/state.json`: 8.1 and 8.2 both `todo` as of
2026-08-19). Steamworks' App Admin → Stats & Achievements page does not exist until an App ID does,
and the Steamworks account/tax interview/$100 Direct fee behind 8.1 is Sequoyah's alone to run — no
agent has the account access (`AGENTS.md` D-039's "his accounts" exception).

**Unlike `tools/steam/DEPOT_SETUP.md`, there is no script to run afterward.** A depot ID is assigned
BY Steam, so `apply_ids.sh` exists to write the real value back into this repo. An achievement or
stat's API name is chosen BY US — `autoload/steam_stats.gd`'s `STAT_*`/`ACH_*` consts below already
ARE the real, final values the shipped code calls `setStatInt()`/`setAchievement()` with. Creating
the dashboard rows using the exact same strings is the entire remaining step; once they exist, the
game starts succeeding at pushes it was already silently and harmlessly failing before (an unknown
stat/achievement id just doesn't get stored — no crash, no error a player would see).

## Stats — App Admin → Stats & Achievements → Add Stat

All seven are **Integer**, default **0**, and every one is a running lifetime value — never reset
per-run. Steamworks doesn't have an "aggregation" setting to configure here; it's a description of
how `autoload/steam_stats.gd` writes them, worth knowing when reading a player's stat later.

| API Name | What it counts | How it's written |
|---|---|---|
| `CYCLES_REACHED` | Highest Cycle ever reached, any run | Running max |
| `LIFETIME_SALVAGE` | Highest lifetime Salvage balance ever seen | Running max (mirrors `SalvageService`'s own persisted total) |
| `RUNS_EXTRACTED` | Successful extractions, all-time | Increments by 1 |
| `RUNS_WIPED` | Runs ended in a team wipe, all-time | Increments by 1 |
| `WELLSPRINGS_CAPPED` | Wellsprings capped, all-time | Increments by 1 |
| `BOSSES_DEFEATED` | Bosses defeated, all-time | Increments by 1 |
| `SHIPS_REPAIRED` | Extraction ships fully repaired, all-time | Increments by 1 |

## Achievements — App Admin → Stats & Achievements → Add Achievement

Ten, not `docs/STEAM.md` §S4's ~20-aim — D-148 records why (D-146's "ship fewer real ones, not a
bulk template fill" precedent). Each API Name below must match `autoload/steam_stats.gd`'s `ACH_*`
const **exactly**, including case. Display Name and Description are suggested copy, not load-bearing
— free to punch these up, the API Name is the only string the code depends on.

| API Name | Display Name | Description |
|---|---|---|
| `ACH_FIRST_EXTRACTION` | Cast Off | Extract from the island for the first time. |
| `ACH_FIRST_WELLSPRING` | First Light | Cap your first Wellspring. |
| `ACH_FIRST_BOSS` | Trophy Hunter | Defeat your first boss. |
| `ACH_SHIPWRIGHT` | Seaworthy | Fully repair the extraction ship. |
| `ACH_CYCLE_5` | Getting Comfortable | Reach Cycle 5. |
| `ACH_CYCLE_10` | Pushing Your Luck | Reach Cycle 10. |
| `ACH_CYCLE_15` | Living On The Edge | Reach Cycle 15. |
| `ACH_SALVAGE_500` | Modest Fortune | Bank 500 lifetime Salvage. |
| `ACH_SALVAGE_2000` | Hoarder | Bank 2,000 lifetime Salvage. |
| `ACH_FIRST_UNLOCK` | Kitting Out | Purchase your first unlock. |

Each achievement also needs a locked and an unlocked icon image (Steamworks requires both before the
row saves) — no icon art exists yet; commissioning or drafting that is outside this task's claim
(same "content is authored, not bulk-generated" boundary D-073 draws), and is real work for whoever
does this dashboard pass.

## Steps, once 8.2 lands

1. Create all seven stat rows and all ten achievement rows using the exact API Name strings above.
2. Leave "achievement unlocks automatically" OFF for every achievement — the game drives every unlock
   itself via `setAchievement()`, never Steamworks' own stat-threshold auto-unlock feature.
3. Publish the change (Steamworks stages Stats & Achievements edits until you publish them).
4. **No repo change needed.** `autoload/steam_stats.gd` already calls these exact names; the next
   time a player with a real Steam session crosses a milestone, the push that was already silently
   failing starts succeeding.
5. Verify with a real Steam session: play to Cycle 5 (or run `tools/steam_stats_check.gd` for the
   local trigger logic, which needs no Steam client at all) and confirm the achievement pops in the
   Steam overlay and the stat shows in the dashboard's own "My Stats" test view.

## What this task could NOT verify

Everything above is UNTESTED against the real Steam API, because it cannot be — App ID 480 has none
of these stats/achievements defined, and won't until this page's own steps run. `tools/steam_stats_check.gd`
proves every trigger and the local `user://steam_stats.json` round trip with no Steam client at all;
it cannot prove Steam actually stores a value it was never told to expect.
