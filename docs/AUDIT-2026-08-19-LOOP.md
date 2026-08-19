# MIRE — game-loop audit, 2026-08-19

Audit by `hollow7`. Scope, per Sequoyah's ask: **the game loop first, then the whole project.**
Companion to the same day's `AUDIT-2026-08-19.md` (yarrow21 — the check battery and performance)
and 08-17's (flint5 — the paperwork). Neither traced the loop as a player arc; this one does
nothing else. Method unchanged: **everything in §1 was verified by running it** — one instrument,
`tools/loop_audit_check.gd`, boots the SHIPPED scene (`levels/hollowmere.tscn`, the exact
`run/main_scene`) and drives every link through the real front doors, with a second invocation
(`-- defeat`) for the ending the first one can't reach. Both runs: **0 failures, 0 engine ERROR
lines** after the fixes below.

Headline: **the run arc is real. Every link of DESIGN.md §5 works on the shipped map, both endings
included — and then the loop stops being a loop.** There is no path from the defeat screen or the
departed ship back to a fresh run short of relaunching the process (F-243). Second structural
fact: the entire generated-world stack still has zero non-tool callers (F-139's cluster, now four
systems deep), so everything verified here is verified on the interim authored island only.

---

## 1 · The loop, link by link — verified by driving it

| # | Link | Verdict | Evidence (from the run transcript) |
|---|---|---|---|
| 1 | Boot & spawn | ✅ | scene loads clean; player at y=2.02; **1 Wellspring, 10 chests, 1 extraction ship** all materialize from layout markers via their placement services |
| 2 | Harvest | ✅ | a wired prop hit through `host_apply_tool_damage` yielded stone into the real inventory |
| 3 | Craft | ✅ | standing at the workbench marker, `CraftingService.nearby_station_id()` → `workbench`; `skewer` requested and arrived. **Caveat:** 6 of 8 authored station markers (anvil, cooking spit, campfire, woodcutting block, repair bench, upgraded workbench) have no `StationDef` — scenery until 3.2 authors them |
| 4 | Build | ✅ | `build gate <grounded coords>` placed after costs paid. Two warts: raw player-height coords refuse everything ('nothing underneath it', F-244), and `dock`/`bridge`/`ramp` legitimately refuse open ground ('something is in the way' — big footprints in a clearing) |
| 5 | Eat | ✅ | `starve 1 10` then `request_consume_item(mushroom)` → hunger 10.0 → 16.0 |
| 6 | Night | ✅ | `time set dusk` → wave 4→10 live; `time set dawn` → cleared. The command drives the same threshold path as the real clock (3.16's adapter design paying off) |
| 7 | Chests | ✅ | free cache opened through `request_open()`: paid 9 coins + ore + stone; `inv` renders it (after F-239's fix) |
| 8 | Wellspring → rewards | ✅ | cap event → `SalvageService` counts it; `RewardService` granted the wellspring tier (items 40 → 100 — F-183's fix is live and generous) |
| 9 | Mire | ✅ | seeded corruption 0.88 found by sampling; a cap AT that point cleared it to 0.000 within one tick |
| 10 | Cycle | ✅ | `host_advance_cycle` → 1→2, modifier `long_night` drawn, spread ×1.15. Only **1 modifier is authored** (6.3 in flight; spec wants 20–30) |
| 11 | Extraction | ✅ | from Cycle 3: three staged repairs (costs read live and paid), 60 s departure hold at `Engine.time_scale = 8` (safe because §5a keeps everything delta-accumulated — a system that broke under time_scale would be frame-coupled, its own bug), `run_extracted` fired, salvage 504→602, `user://salvage.json` written |
| 12 | Defeat (run 2) | ✅ | `damage @s 1000000` → solo down IS team wipe (6.7's contract), death fraction banked 602→617, DefeatHud present |
| 13 | **Next run** | 🔴 | **does not exist.** No control on the defeat/extraction surfaces, no `reset_run()` on any service, no scene-reload path anywhere in `ui`/`autoload`/`core`/`systems`. **F-243**, the audit's headline |

Notes on method, so the next audit can repeat it: verbs went through `CommandService` wherever a
verb exists — auditing the loop through the console audits the console (it caught F-239 and F-244
exactly this way). The Wellspring *channel* (presence hold) was not re-proven here — 4.8's checks
own it; the audit drove the cap's downstream chain, which is what the loop cares about.

## 2 · Defects — found by this audit

| # | What | State |
|---|---|---|
| **F-239** | `inv` read slot keys that don't exist (`item`/`count` vs the store's `item_id`/`amount`) — it printed "carrying nothing" over a full inventory, and `inv clear` cleared nothing while reporting success. My own 3.16 verb; three layers of checks missed it because none asserted the command's *rendering* of a non-empty inventory | **fixed this session**, regression guard now inside the loop audit at the one moment the inventory is provably non-empty |
| **F-243** | the missing next-run edge (above). 6.8 and 6.10 are both *done* and no D-number records "relaunch to restart" as a decision — a gap, not a choice. Worst in co-op: a wiped six-player lobby is a full six-process relaunch and Steam re-invite, at exactly the "one more run" moment §5.2 is designed around. Finding sketches the shape: HOST-scope `run restart` through the existing command door + the per-service reset inventory | **filed**, open |
| **F-244** | `build <id> ~ ~ ~` — the natural spelling — refuses everything: nothing grounds a command placement's y, so the base floats above the support probe. All 13 pieces refused at player height; grounded coords placed first try | **filed**, open |

## 3 · The whole project, from where the loop audit stands

- **The generated-world stack is still parked (F-139, grown).** `ChunkStreamer`, `NavBaker`,
  `PoiMap`, `ResourceScatterField` — pure, tested, and with **zero callers outside `tools/`**.
  Everything §1 verifies is verified on the interim authored island; the release game is
  procedurally generated (Sequoyah's standing directive), so the single biggest unwired seam in
  the project is still "a live level that streams a generated world". 4.6 shipped seed
  replication; the runway from seed to standing-on-generated-terrain remains unbuilt.
- **Content vs framework.** Boot census: 23 items, 13 recipes, 2 stations, 9 weapons + 1 ranged,
  7 loot tables, 72 powerups, 13 buildables, 1 haulable, 4 attunements, 3 biomes, 2 scatter
  tables, 8 rules, 1 hook, 3 POIs, **1 cycle modifier**, 7 unlocks. The frameworks outnumber
  their content almost everywhere — 3.2 (items/recipes), 6.3 (modifiers, in flight), 5.2 (enemy
  roster, in flight) are the debts, all already on the board. The loop is sound; what it loops
  *over* is thin.
- **Wire surface held overnight.** `rpc_manifest_check` green at protocol 21 through a night of
  five lanes shipping — the F-161 mechanism is doing its job. `command_catalog_check` and
  `verify_setup` green alongside.
- **Oldest debts unchanged:** 2.9 (combat feel gate) and the playtest chain (2.14, 3.11, 4.12,
  6.11) are human-gated and untouched by any of the three audits. Every fix this audit and
  yesterday's landed makes the build those gates judge *more* worth judging.

## 4 · What this audit leaves open, deliberately

- **F-243 is not fixed here.** The reset inventory touches a dozen services owned across recent
  tasks; it deserves its own task, not an audit's side-commit.
- The loop audit asserts nothing about *feel* — pacing, threat, fun are 2.9/2.14/4.12's human
  gates. This audit only proves the machine those playtests need is actually assembled.
- `tools/loop_audit_check.gd` stays in the tree as a rerunnable end-to-end harness: any future
  "did we break the loop?" is one command, two runs, ~4 minutes.
