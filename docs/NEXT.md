# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

> **2026-08-18 — the map was re-authored (2.1k).** `levels/hollowmere.tscn` is the main scene and is
> now **192 m across, not 356** (D-045): a river out of the northern rim through a gorge into the
> mere, a plateau you climb by two ramps, a quarry at its foot, a ruined village, a lumber camp, a
> hunters' camp, a stone circle, a watchtower, the Wellspring, an extraction yard — and the
> **Blight** in the north-east, an ash-and-mire bowl holding the four crawler nests that every enemy
> on this map now spawns from. **2,869 authored props** (against 1,415 on four times the area),
> **83 live harvestable trees and ore nodes**, 10,240 scattered plants, and **every one of the 218
> placeable kit assets appears somewhere** — the generator fails the run if one does not.
>
> Four things were wrong and are fixed, each with a check that would catch it again: grass grew on
> top of trees and rocks, bridge railings were mirrored across their own decks, the mere and the fen
> drew two stacked water sheets, and props sat on a bilinear guess at the ground rather than on it.
> A fifth was worse and invisible: **the map had no crawlers and no harvestables at all**, because
> `EnemyWorld` and `HarvestWorld` were keyed to Playtest Hollow's group names (F-076).
>
> `python3 tools/mapgen/hollowmere_plan.py` draws the layout as a labelled plan (SVG + PNG, pure
> stdlib) — that is how to look at the map without the editor. `docs/DELEGATION.md` has the seams;
> `agent godot --script tools/hollowmere_check.gd` verifies it and now asserts that crawlers really
> spawn, harvestables really wire, nothing floats, no plant sits on a prop and no water stacks.
> `tools/hollowmere_render_check.gd` still cannot screenshot: `agent godot` is always `--headless`
> (F-077). Playtest Hollow is deprecated but kept as a test fixture — the headless checks boot it.

**Milestone:** M2 · Vertical slice — 17/22, and everything left is either yours or dispatched.
M1 closed at 13/14 (1.12 deferred, D-030). M0 closed 11/11 plus 0.12 (orchestration).

**The game runs, and the loop is visible.** Press Play: you spawn in Playtest Hollow with a stocked
hotbar, **the held item renders and swings** (F-041), and four crawlers hunt out of the East Mire
nest. Walk, sprint, jump, harvest, craft at the workbench, fight, kill. Crawlers telegraph 0.4 s,
outrun a walk (4.4 m/s), lose to a sprint, react to hits, and their corpses sink away. **Crawler hits
now hurt you (2.13): hp hits 0 -> downed (crawl, no jump/sprint/attack) -> a teammate holds `interact`
in range to revive, or bleed-out expires and you respawn at full health after a short delay.** The
current build is no longer shadow-boxing — 2.9's playtest below is now judging danger, not just feel.
**F3** overlay · **`~`** console · **Esc** releases the mouse.

**2.9's first playtest attempt found three defects, all now fixed (F-062/063/064).** Do not read the
first attempt's impressions as a verdict on combat feel — the build was not swinging at the crawlers.

- **Every axe swing was hitting you, not the enemy** (F-062). 2.13 put the player body into the
  `&"damageable"` group so crawler hits could land; `CombatService` never excluded the swinger, and
  the attacker's own origin beat any target past 1.5 m *and* bypassed the arc test. That is the whole
  of "attacking the enemies doesn't seem to work anymore" and most of the damage taken.
- **Downed, bleeding out and dead drew nothing on screen** (F-064). Sequoyah died and respawned twice
  in one session without knowing it — the log said so, the screen did not. There is now a centre
  banner with live countdowns, plus a teammate-down prompt.
- **Solo respawn teleported to world origin instead of the level's spawn** (F-063), because the
  signal that records a spawn point only fires inside a session.

Re-run the gate on the current build. `agent godot --script tools/combat_self_hit_check.gd`,
`tools/vitals_hud_check.gd` and `tools/player_health_check.gd` are all green.
**The night sky reads as night now** (F-065): the cloud deck darkens and catches a warm sunset, a star field fades in across dusk and wheels overhead, and the sky material turns to its night colours only once the sun is actually below the horizon. Daylight is provably unchanged. `agent godot --script tools/atmosphere_night_check.gd`; pictures via `tools/hollowmere_night_render.gd`, which needs a window — see its header.

**2026-08-17 was four sessions in one day:**

- **2.13 shipped** (lp): `PlayerHealth` autoload, host-authoritative, subscribes to the
  `enemy_attack_landed` event 2.10 built with no runtime consumer until now. Downed/revive is
  host-validated; presentation (crawl, blocked input) is client-local. Protocol version is 7.
  `docs/DELEGATION.md` has the full seam.

- **2.10 + 2.9's code shipped** (dusk3): host-authoritative Enemy v1, the combat-feel instrument
  (`agent godot --script tools/combat_feel_check.gd`), hit reactions, corpse fade. F-036 resolved by
  swapping 2.9/2.10; **2.9's human gate is the one thing still open in it.**
- **The audit + remediation landed** (flint5): `docs/AUDIT-2026-08-17.md` is the full report. Every
  single-process harness now runs at **0 failures and 0 engine-error lines** (F-046/F-047 fixed the
  three that were green-over-errors and the one red one); the content generators warn before
  overwriting tuned values and can no longer strip icons or revert the main scene (F-048);
  `verify_setup` checks all 19 autoloads; the governing docs agree with D-031 again; and
  **`docs/SPECS.md` now holds an execution spec for every remaining roadmap task** — lanes and
  agents read their task's block there and should need zero exploration.
- **The director/lane system shipped** (yarrow21, task 0.12, D-036/D-037): one director routes work
  orders to three subscription lanes (2× Codex, 1× Claude Pro) via `agent order/dispatch/collect`;
  lanes claim, verify through the shared `agent godot` lock (F-044), and ship under the same
  protocol as everyone else. `docs/ORCHESTRATION.md` is the manual.

**Twenty-five autoloads live**, `verify_setup` scans the `[autoload]` section and asserts a floor rather than a list, so adding one cannot red it (and dropping one still can). Boot log:
`content: loaded 14 item(s), 1 recipe(s), 9 weapon(s)` + `1 enemy definition(s)` +
`net: NetTransport ready (offline)`. `NetConfig` is a `class_name`, **not** an autoload; don't add it.
Protocol version lives in `core/net/net_version.gd` (**currently 12** — 3.6's three build RPCs were
the last bump); any new RPC bumps it and extends `tools/handshake_check.gd`.

Godot 4.7.1-stable `a13da4feb`, pinned (D-001) — also the determinism baseline (§6a), so upgrading
invalidates R6. Blender is pinned the same way now (D-038); the next asset batch records the version.

---

## Roles (D-020, D-036)

Sequoyah: **Integrator** — Godot editor, tuning, playtesting, the calls only a human can make.
The **director** (Claude Max chat) routes and verifies; it does not implement (D-036). **Lanes**
LC1/LC2/LP implement dispatched orders. Any interactive agent chat can still take any task the
old way — `agent start`, claim, work — the orchestration is additive.

Protocol: [AGENTS.md](../AGENTS.md) · specs: [SPECS.md](SPECS.md) · dispatch: [ORCHESTRATION.md](ORCHESTRATION.md).

---

## Next, in order

| # | What | Who | State |
|---|---|---|---|
| 2.9 | **Play the combat gate — RE-RUN IT, the first attempt was judging a broken build.** SPECS.md has the run-sheet: ten crawler kills, judge tell/arc/hitstop/kill-length, tune in the inspector only, then pass or fail it out loud. Passing closes F-036. | **You** | open, unblocked |
| 2.11 | Day/night — host-authoritative clock, sky client-local. `cycle_enabled` stays false forever; DayNight pushes the time instead. | lane | **done** |
| 2.12 | Night waves over `EnemyWorld` seams. Shipped in `915c881` and **never registered**, so it did not run for a day (F-068); the autoload and the harness are fixed. | lane + gale6 | **done** |
| 2.13 | Death & respawn — player health, downed→bleed-out→revive, the `enemy_attack_landed` subscriber that makes crawlers matter. | lp | **done** |
| 3.3 | Powerup framework — tags, stacks, Resonance thresholds, one `stat()` query seam. **Done**; D-044 fixes the authoring shape 3.4 uses. | gale6 | **done** |
| 2.14 | **Playtest with friends** — protocol in SPECS.md: verbatim quotes, one full night, then re-read DESIGN §8 before anything in M3. | You + friends | after the above |
| 2.1d | A-009 extraction ship (15 models) — the asset queue's NEXT; tracker governs. | asset agent | ready |

**1.12 is unblocked (2026-08-18):** the in-game lobby join D-030 was waiting for now exists —
press **M** in game for the multiplayer panel (host / copy the lobby ID / paste-and-join / Steam
invite overlay; 6.10's lobby-UI slice, `ui/lobby/lobby_menu.gd`, seams in DELEGATION.md). The
evidence run still needs the three machines; everything to resume is in
`STEAM_CROSS_PLATFORM_TEST.md`. **Do not start M3** before 2.14's DESIGN §8 re-read.

**2026-08-18 — the command track is planned and queued (3.13–3.17).** Sequoyah asked for the game
to be data-driven the way Minecraft's commands reach every system. `docs/COMMANDS.md` is the full
spec: one `CommandService` front door, typed args, host-routed mutations behind an op set,
selectors over a new EntityDirectory, a replicated gamerule family, command files + hooks, and a
headless scenario runner the check suite gets to reuse. 3.13 gates the rest and is **exempt from
the M3 gate** (recorded call, ROADMAP M3 note — it encodes no design answers and would actively
help run 2.14 and D-030's cross-play test). Dispatchable to lanes as written.

**2026-08-18 — the item/loot/chest economy is planned (`docs/ITEMS.md`).** Sequoyah asked for the
full loot plan — resources, crafting components, chest rewards, the assets they need — with a lot of
items and real jackpots: *something crazy good from a chest, even if it makes the game too easy
sometimes* (now D-063). ITEMS.md is the catalog 3.2/3.5/3.8 author against, the way 3.4 reads
POWERUPS.md: ~136 items + the existing 60-powerup sketch, chest tiers from free reed caches up to
the Gilded Chest's Gleam pool, and five new gated asset batches (A-043–A-047). ~45 items are
authorable the day 3.1 lands; everything else waits on its named gate. Inspiration researched
(Muck, RoR2, Valheim, Lethal Company — patterns only, provenance table in the doc §1).

---

## M0 debts — booked as M4 gates, don't lose them

| # | What's actually unmeasured | Who | Est |
|---|---|---|---|
| 4.0a | `ConcavePolygonShape3D` cooking + GPU mesh upload per chunk, on a real renderer. R2 ran headless — no upload, no material, no collision; R3 measured *navigation* baking, a different code path. F-005, and the standing caveat on D-015. **Gates all of M4.** | agent | 1.5h |
| 4.0b | Determinism on Windows x86_64 — **DONE** on a physical Ryzen 5 5600 (D-028). | done | ✅ |

Nothing in M2/M3 depends on 4.0a. Don't pull it forward; just don't start 4.1 without it.

---

## Cross-platform (D-013)

Shipping macOS + Windows + Linux with cross-play. Steam P2P makes cross-play nearly free; the real
risk is shared-seed regeneration, and it is **measured and closed on all three platforms**:
macOS↔Linux (D-017) and Windows (D-028) agree bit-for-bit on `rng_sequence`, both noise hashes, and
the four safe-operation hashes; raw transcendentals differ as predicted and are banned from world
gen (§7 safe set). M4 builds on seeded generation under that rule.

The D-028 run also exposed the fresh-clone trap: a raw clone lacks the intentionally gitignored
GodotSteam binaries and the global class cache — install the D-022-pinned addon and run one headless
editor import before treating startup errors as game defects.

---

## Tools

**Agents run these, not you** — and they run them through the lock:

```bash
.agent/bin/agent godot --script tools/verify_setup.gd
```

Input map, all 19 autoloads, scene structure, live physics, §5a effective settings (F-003) — run it
after anything structural. `agent godot` serialises engine runs against the lanes (F-044); a bare
`Godot --headless` is how two engines corrupt one import cache.

`tools/setup_project.gd` regenerates the input map and both scenes — its header now tells the truth
about re-running (F-048): destructive once tuning starts, and it no longer touches an existing
`main_scene`. The content generators (`setup_*_content.gd`) all warn in-file before overwriting
tuned `.tres` values. **Never re-run a generator after 2.9 tuning begins.**

---

## Open questions waiting on playtests

First real answers arrive at **2.14**. Tracked in `DESIGN.md` §8 — and 2.14's protocol (SPECS.md)
ends with re-reading that section against the verbatim quotes.

---

## Cold-start ritual

**Yours, coming back after a break:**

1. Read this file — *Next, in order* is the answer
2. `.agent/bin/agent board` for the full picture; `agent report` for lane status
3. Either play (2.9 / 2.14 are yours) or dispatch: the director chat writes orders from
   `docs/SPECS.md` blocks

**An agent's, in a fresh chat:** `agent start` → `agent brief <id>` → read the task's SPECS.md
block → claim → work → verify via `agent godot` → close out per AGENTS.md → ship.

---

## Parking lot

- Seed sharing / daily seed with a friends leaderboard by Cycle depth
- Spectator mode for dead players
- A "Cycle 1 speedrun" mode
- Cosmetic hats. There must be hats. (A-041 queues them; §4.6 says variety, never power.)
