# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

> **2026-08-19 — the engineering spine is close to done; what's left is mostly play, content, and
> polish.** 89/131 tasks. M0 ✅ · M1 13/14 (only 1.12's three-machine evidence run) · M2 21/25 ·
> M3 16/21 · M4 12/14 · M5 4/10 · M6 8/11 · M7 3/12 · M8 0/12. The full check battery was swept
> on 2026-08-19 — `docs/AUDIT-2026-08-19.md` is the report; everything runnable on this machine is
> green except `boss_check`'s exit-leak diagnostic (F-193) and `lobby_menu_check` (F-170, order
> queued).

**The game is a real roguelike now.** Press Play: you spawn in **Hollowmere** with a stocked
hotbar. Walk, sprint, jump, dodge (with i-frames — Thin Step extends them), harvest with the tool
ladder, craft at stations, build (13 buildable pieces including doors that open and Ward posts),
fight crawlers and a boss with melee or bow, loot placed chests, capture the Wellspring and defend
its wave, watch it re-corrupt if unwarded, take Blight damage in the Mire as it spreads cell by
cell, go down, get revived — or wipe, see the defeat screen, and keep your Salvage into the unlock
tree. Cycles advance with modifiers; extraction is staged repairs on the shipwreck and an
all-aboard vote. **Solo death = team wipe = run over (6.7)** — 2.13's solo respawn was the stopgap
until the lose condition existed, and it is gone on purpose.

**F3** overlay · **`~`** console (typed CommandSpecs, LOCAL/HOST scopes, op-gated; selectors
`@a @p @e[...]`; gamerules; the F-130 shim is deleted) · **M** multiplayer panel (host / join by
id / Steam invite) · `--seed=` launch arg for a chosen island.

**Facts that were stale here until 2026-08-19, now current:**

- **44 autoloads** (`verify_setup` asserts a floor, not a list). Boot content line:
  23 items · 13 recipes · 2 stations · 9 melee + 1 ranged weapons · 7 loot tables · 72 powerups ·
  13 buildables · 4 attunements · 3 biomes · 2 scatter tables · 8 rules · 3 POIs · 1 cycle
  modifier · 1 unlock · 2 enemy definitions.
- **Protocol version 21** (`core/net/net_version.gd`). Any new RPC bumps it and extends
  `tools/rpc_manifest_check.gd` — the manifest check (F-161) is how a forgotten bump gets caught
  now, not code review.
- The procedural pipeline (heightmap → biomes → chunk streaming → scatter → nav → seed
  replication + delta log) is **built, tested, and not yet the shipped map** — the game still
  boots authored Hollowmere; the cutover is a full map task tracked as F-139. `--seed=` already
  feeds the pipeline's checks.
- Godot 4.7.1-stable `a13da4feb`, pinned (D-001, determinism baseline §6a). Blender pinned per
  D-038.

---

## Next, in order

| # | What | Who | State |
|---|---|---|---|
| 2.9 | **Play the combat gate.** Ten crawler kills, judge tell/arc/hitstop/kill-length, tune in the inspector, pass or fail it out loud. SPECS.md has the run-sheet. Closes F-036. | **You** | open — the oldest debt on the board |
| 2.14 | **Playtest with friends** — verbatim quotes, one full night, then re-read DESIGN §8. The build finally has enough game to judge. | You + friends | after 2.9 |
| 5.2 / 5.4 | Enemy variety (8–12 types over 5.1's framework) and weapon movesets — the biggest lever on run variety. A-023/24/25 asset batches gate the models; stats/tells are `.tres` authoring now. | lanes + tracker | ready |
| 3.2 / 6.3 | Item/recipe content over `docs/ITEMS.md` (~45 authorable now) and 20–30 Cycle Modifiers. One at a time, real attention each (D-073). | lanes | ready |
| 4.10 | Mire visuals — tint, fog, particles, audio shift over `MireGrid`'s cells. The signature system still *looks* like a debug grid. | lane | ready |
| 5.6–5.8 | Bosses 1–3 over 5.5's framework (guardian scales with Cycle; Hunt elite; Cycle 7+ threat). | lanes | after 5.2's first types |
| 1.12 | Steam cross-platform evidence run — needs the three machines, nothing else. `STEAM_CROSS_PLATFORM_TEST.md` has everything. | You + hardware | whenever the machines align |
| 3.11 / 4.12 / 6.11 | The remaining playtest gates (Attunement roles · Mire stressful-fun · the wall / extraction / deep-modifier fairness). | You + friends | as their systems finish |

**Do not start M7 polish before 2.14 has produced its quotes** — polish against unplaytested feel
is polish twice.

---

## Roles (D-020, D-036)

Sequoyah: **Integrator** — Godot editor, tuning, playtesting, the calls only a human can make.
The **director** (Claude Max chat) routes and verifies; it does not implement (D-036). **Lanes**
LC1/LC2/LP implement dispatched orders. Any interactive agent chat can still take any task the
old way — `agent start`, claim, work — the orchestration is additive.

Protocol: [AGENTS.md](../AGENTS.md) · specs: [SPECS.md](SPECS.md) · dispatch: [ORCHESTRATION.md](ORCHESTRATION.md).

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

Input map, the autoload floor (44 today), scene structure, live physics, §5a effective settings (F-003) — run it
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
