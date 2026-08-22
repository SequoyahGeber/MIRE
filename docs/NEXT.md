# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

> The counts below are **generated** — `python3 tools/next_gen.py --write` rewrites them from
> `.agent/state.json` and `docs/FINDINGS.md`, and `tools/next_gen.py` fails when the committed file
> has drifted. They used to be hand-maintained, and two different reviewers corrected the same
> numbers in one night before that was filed as F-306. Everything outside the generated block is
> judgement and stays hand-written.

<!-- BEGIN GENERATED — python3 tools/next_gen.py --write. Do not hand-edit. -->

**Tasks: 135/171 done.** M0 12/12 · M1 13/14 · M2 21/25 · M3 26/29 · M4 28/32 · M5 10/15 · M6 18/19 · M7 5/13 · M8 2/12

**Findings: 116 under `## Open`.** 2 in flight · 3 externally gated · **98 available to pick up now** · 13 marked done but still under `## Open`

Externally gated — do not route these to a lane:

- **F-023** — needs the physical Windows PC and a real Steam lobby
- **F-025** — needs a first-join latency measured on real hardware
- **F-174** — no dev machine here stands in for mid-range

Marked done but still under `## Open` — read the entry before claiming; `agent board` hides these while `agent brief` still offers them:

- F-012 · F-521 · F-550 · F-573 · F-574 · F-576 · F-579 · F-589 · F-591 · F-594 · F-597 · F-605 · F-609

Available now, oldest first: F-296, F-300, F-304, F-305, F-309, F-310, F-317, F-319, F-320, F-322, F-323, F-325, F-344, F-352, F-358, F-359, F-360, F-362, F-364, F-371, F-388, F-389, F-393, F-394, F-412, F-420, F-422, F-424, F-425, F-426, F-427, F-428, F-429, F-436, F-437, F-438, F-439, F-441, F-444, F-446, F-454, F-455, F-457, F-463, F-465, F-466, F-467, F-468, F-470, F-474, F-476, F-479, F-481, F-495, F-497, F-498, F-499, F-515, F-523, F-524, F-544, F-545, F-546, F-548, F-557, F-567, F-569, F-572, F-582, F-587, F-595, F-600, F-603, F-607, F-612, F-613, F-614, F-615, F-616, F-617, F-618, F-619, F-620, F-621, F-622, F-623, F-624, F-625, F-626, F-627, F-628, F-629, F-630, F-631, F-632, F-633, F-634, F-635

<!-- END GENERATED -->

> **The engineering spine is close to done; what is left is mostly play, content, and polish.**
> The full check battery was swept on 2026-08-19 — `docs/AUDIT-2026-08-19.md` is the report.
>
> Clusters worth knowing before routing any finding:
>
> - **Procedural reseed leftovers**, all from F-258's fresh-seed restart — F-279, F-281, F-282,
>   F-286, F-298.
> - **The terminal run-summary screens still have one way to strand a player** — F-307: a client
>   whose host quits while the defeat/extraction overlay is up keeps a disabled "waiting on the
>   host" button and cannot open any menu over it, because the overlay holds
>   `blocks_gameplay_input`. Reproduced two-process. Severity high; the fix needs a decision
>   about what a terminal screen offers a peer with no host.
> - **Worldgen performance and correctness** — F-294 (per-sample Array rebuilds under every surface
>   sample, doubled by F-274), F-295, F-296, F-300..F-303.
> - **The tooling suite is unwatched** — F-293: nothing enumerates and runs the `tools/` suite, so a
>   red check sits at HEAD unnoticed. This is the one that makes the others possible.
>
> Count open findings from `docs/FINDINGS.md`'s `## Open` section, not from `state.json` or
> `agent report`: the two disagree, which is what F-269 and F-270 are about — and the generated
> block above takes FINDINGS as the authority for exactly that reason.
>
> **The content, not the engine, is the thin part.** 5.2 (enemy types) and 6.3 (cycle modifiers) are
> where the game gets deeper, and both are authoring tasks — one asset at a time, with attention,
> never a batch of stat blocks generated in one pass (D-073).


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
  13 buildables · 1 haulable · 4 attunements · 3 biomes · 2 scatter tables · 8 rules · 1 hook ·
  6 POIs · 7 cycle modifiers · 7 unlocks · 5 enemy definitions (re-read off a 2026-08-20 boot).
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

> **Standing focus (Sequoyah, 2026-08-19): procedural generation, until it is flawless.** The
> plan is `docs/WORLDGEN.md` (method D-142, composer D-143) + `docs/GAMELOOP.md`; the work is ROADMAP
> 4.13–4.19. Route lanes here first; content/asset tasks yield to this track.


| # | What | Who | State |
|---|---|---|---|
| 2.14 | **Playtest with friends** — verbatim quotes, one full night, then re-read DESIGN §8. The build finally has enough game to judge. | You + friends | whenever an evening aligns |
| 5.2 / 5.4 | Enemy variety (8–12 types over 5.1's framework) and weapon movesets — the biggest lever on run variety. A-023/24/25 asset batches gate the models; stats/tells are `.tres` authoring now. | lanes + tracker | ready |
| 3.2 / 6.3 | Item/recipe content over `docs/ITEMS.md` (~45 authorable now) and 20–30 Cycle Modifiers. One at a time, real attention each (D-073). | lanes | ready |
| 4.10 | Mire visuals — tint, fog, particles, audio shift over `MireGrid`'s cells. The signature system still *looks* like a debug grid. | lane | ready |
| 5.6–5.8 | Bosses 1–3 over 5.5's framework (guardian scales with Cycle; Hunt elite; Cycle 7+ threat). | lanes | after 5.2's first types |
| 1.12 | Steam cross-platform evidence run — needs the three machines, nothing else. `STEAM_CROSS_PLATFORM_TEST.md` has everything. | You + hardware | whenever the machines align |
| 3.11 / 4.12 / 6.11 | The remaining question-answering playtests (Attunement roles · Mire stressful-fun · the wall / extraction / deep-modifier fairness). | You + friends | as their systems finish |
| 2.9 | Combat-feel tuning — **not a gate any more (D-125)**: ten crawler kills, judge tell/arc/hitstop, tune in the inspector, whenever. SPECS.md keeps the run-sheet. | You | anytime, blocks nothing |

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

`python3 tools/next_gen.py` fails when this file's generated Status block has drifted from
`.agent/state.json` and `docs/FINDINGS.md`; `--write` regenerates it (F-306). Run it before you trust
a count here, and after closing anything out.

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
