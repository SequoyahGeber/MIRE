# SPECS — per-task execution specs for the whole roadmap

**Purpose: an agent given a task id reads its block here and needs zero exploration.** These specs
exist so the cheapest lane can execute without figuring out what "done" means, which files to claim,
or which existing seam to build on. The director's work orders point at this file; `agent brief <id>`
plus the block here is the whole briefing.

Written 2026-08-17 by flint5 from the shipped code and the audit (`AUDIT-2026-08-17.md`). Specs for
M2–M3 are execution-ready. M4+ specs are complete on architecture, files, seams and acceptance, but
each names the **GATE** it must not start before — a gate line is a hard stop, not advice.
**If a spec is missing or stale, fixing it here is part of the task that discovers it.**

---

## How to execute any spec (the preamble every block assumes)

1. `.agent/bin/agent start`, then `agent brief <id>`. Read this file's block for the task, plus the
   four docs the brief names. Nothing else — never explore.
2. `agent claim <id> <every file the block lists>` — exact paths. If the claim fails, `agent drop`
   and stop; another agent holds it.
   **`project.godot` is never in a claim set (F-051).** Registering an autoload is one locked,
   atomic append: `agent autoload <Name> res://<path>.gd` — it checks the editor is closed and takes
   the lock itself, so D-021's "the task that ships an autoload registers it" holds without any lane
   ever holding the file. Autoload load order = registration order, so register only after every
   autoload yours depends on already appears in `project.godot`.
3. Godot runs go through **`agent godot --script tools/<check>.gd`** (never bare `Godot --headless`
   — one shared import cache, D-037/F-044).
4. Every new system's script header declares its `ARCHITECTURE.md` §2.2 authority row, verbatim.
5. New RPCs ⇒ bump `PROTOCOL_VERSION` in `core/net/net_version.gd`, extend
   `tools/handshake_check.gd`, and say so in your close-out.
6. Close out (AGENTS.md step 3–5): findings → `FINDINGS.md`, settled calls → `DECISIONS.md`, new
   seams → `DELEGATION.md` *Current state*, then `done`/`handoff` + `ship`.
7. **Disposition (D-039): if you can do it, do it.** Never end a task with "Sequoyah must
   wire/attach/set X" when you could — wire it under the proper claim, verify headlessly, report
   what you DID. Hand-off is only for visual/taste/playfeel judgment, his accounts or hardware, or
   work he is significantly faster at. Per-task commits make bold edits one revert from safe.

### The four standing rules (they have already cost real sessions)

1. **Never name an autoload as a bare identifier in any script a `--script` harness can reach at
   compile time** — that is any script pulled in through a `class_name` or `preload` chain (F-011,
   F-046). Use `get_node_or_null(^"/root/Thing")` + `call(&"method")`, and mirror enums as local
   consts. Autoload scripts themselves and scenes `load()`ed at runtime may use bare names.
2. A brand-new `class_name` is not bare-resolvable in a fresh headless clone — `preload` it (F-016).
3. `set_multiplayer_authority()` on a synchronizer **before** `add_child()` (F-012, D-023).
4. Grep every check run for engine errors and treat any UNDECLARED error line as failure even when
   the exit code is 0 (F-021). A check that deliberately provokes error paths (refusals, timeouts,
   bad input) declares them by PATTERN in its verdict line —
   `EXPECTED_ERROR_PATTERNS="pat1|pat2"` — because provoked-error *counts* vary with timing. Grade
   with `grep 'ERROR:' | grep -vE '<declared patterns>' | wc -l` → must be 0. Only
   `session_lifecycle_check` and `connect_retry_check` declare patterns today (F-052). A check
   with no declaration gets zero allowance, and never "fix" a declared error by silencing the
   production log call that emits it.

### Seams that already exist (build on these, never reinvent)

| Seam | Where | The contract |
|---|---|---|
| Damage | `&"damageable"` group | `host_apply_damage(amount: int, instigator_peer_id: int) -> bool`; false = miss. Harvestables + enemies implement it. |
| Enemy world | `autoload/enemy_world.gd` | `host_spawn(def_id, pos)`, `host_despawn_all()`, `live_enemies()`, `live_count()`, `top_up_ambient()`, `ambient_enabled/population/respawn_seconds`, `bake_navigation()`, `nav_polygon_count()`, signals `enemy_spawned(enemy)`, `enemy_died(enemy_id, instigator_peer_id, position)`. **No client spawn RPC, ever.** |
| Combat | `autoload/combat_service.gd` | client sends hotbar index only; host reads its own inventory (D-034). Signals `attack_landed/missed/rejected`, `swing_started`, `swing_phase_changed`. |
| Inventory | `autoload/inventory_service.gd` | trusted host writes via `host_add`/`host_transaction`; clients request + `operation_confirmed`. **Never release peer-keyed state on `peer_left`** — move on `NetSession.run_player_rebound(old,new)`, drop on `run_player_expired(peer)` (D-035). `InventoryService._on_peer_left` is the worked no-op example. |
| Enemy→player damage | `core/events/event_bus.gd` | `emit_enemy_attack_landed(enemy_id, peer_id, damage, world_position)`, host-side, fired at the end of the tell. `subscribe_/unsubscribe_/enemy_attack_landed_subscriber_count()`. 2.13 is the intended subscriber. |
| Interpolation | `autoload/net_interp.gd` | name a replicated body's synchronizer `NetConfig.PLAYER_SYNC_NODE` and smoothing is free (F-004's enemy half proved it). |
| Atmosphere | `world/environment/playtest_atmosphere.gd` | `set_time_of_day(v)` (0..1, fposmod-safe), `set_cycle_enabled(b)`, `set_weather_haze(v)`. `cycle_enabled` is **false on purpose** — see 2.11. |
| UI interlock | group `&"blocks_gameplay_input"` | one cursor-owning UI at a time (D-032). Any new panel joins it. |
| Two-process checks | `tools/inventory_net_check.gd` et al. | driver `OS.create_process` with a `--` probe arg; talk through a `user://` JSON file. Copy that pattern; never fake a second peer in-process (F-037). |

---

# M2 — what remains

## 2.9 · Combat-feel gate — SEQUOYAH ONLY (T0)

Everything is shipped; this is the verdict. **How to run the gate:**

1. Open the project, press Play. You spawn armed; four crawlers hunt from the East Mire nest.
2. Fight with the stone axe only, ten kills minimum, at least once against 2–3 at once.
3. Judge four things, in this order: does the 0.4 s tell read in first person before the hit lands;
   does the 100° arc feel generous or sloppy against a strafing crawler; is 0.075 s hitstop an
   impact or a hitch; is 4 swings per kill right when three crawlers press you.
4. Tune in the **inspector only**: `content/weapons/stone_axe.tres` (timings, reach, hitstop,
   shake), `content/enemies/crawler.tres` (hp, speed, reach, telegraph — keep
   `attack_tell_seconds`/`attack_seconds` at 0.4 unless the clip is re-authored),
   `entities/player/player_camera.gd` exports (shake frequency/roll).
   `agent godot --script tools/combat_feel_check.gd` reprints the relationship numbers after every
   change — argue with numbers, not adjectives. **Never re-run `tools/setup_combat_content.gd`,
   `setup_enemy_content.gd` or `setup_tool_content.gd` after tuning (F-048).**
5. Verdict: pass ⇒ close F-036 (`agent done F-036 "<the values that passed>"`) and note the verdict
   in `NEXT.md`. Fail after honest tuning ⇒ file a finding naming what cannot be tuned around.
6. Known gap going in: the impact thud is 2.8's code-built placeholder; a real authored impact sound
   is the single biggest missing feel ingredient. Judge around it or source one first.

## F-036 · Task 2.9's gate cannot be met in its roadmap position — the enemy it tunes against lands in 2.10

**Claim:** none. No file to edit — the ordering half is already resolved on disk, and the half that
remains is a human verdict, not code.

**What was wrong:** `ROADMAP.md` originally ordered 2.9 (tune combat feel against "one enemy, one
weapon") before 2.10 (the enemy itself). Tuning the gate would have meant tuning against a
harvestable tree — every symptom the gate exists to catch (telegraph read, backpedal pressure, a hit
that reads as a *kill*) is invisible against something that doesn't fight back, and it would have
been easy to pass the gate without noticing the tree wasn't exercising it.

**Fix, already shipped (dusk3, 2026-08-17):** option 1 of the two the original filing offered — 2.10
was built first. `ROADMAP.md`'s 2.9/2.10 rows both say so in-line, and `tools/combat_feel_check.gd`
(2.9's own instrument) measures the swing against the crawler `2.10` shipped, not a tree. The
ordering concern this finding was filed for is spent; nothing here needs code.

**What is still open, and why this task cannot close it:** 2.9's gate is a human playtest verdict —
`DECISIONS.md` D-039 names it the canonical example of work that stays with Sequoyah (genuine
playfeel judgment, not a wiring task an agent is declining). `tools/combat_feel_check.gd` deliberately
stops short of a verdict: it prints relationships ("a kill takes more than one swing," "the telegraph
leaves a readable window") and refuses to call any of them fun. `docs/SPECS.md`'s own 2.9 block is
the run-sheet: ten crawler kills, judge tell/arc/hitstop/kill-length, tune in the inspector only, then
`agent done F-036 "<the values that passed>"` on a pass, or a new finding naming what cannot be tuned
around on a fail. This block exists so `agent brief F-036` stops landing on nothing — it is not a
second place to re-litigate 2.9's run-sheet, only a pointer to it.

**Verified 2026-08-18 (lp):** `agent godot --script tools/combat_feel_check.gd` — `failures=0`, all
nine relationship checks PASS, output still correctly labelled "these are relationships, not
verdicts." `docs/ROADMAP.md` 2.9/2.10 rows read correctly (order swapped, F-036 cited in both). No
production file needed a change. `docs/FINDINGS.md` F-036 stays **open** — closing it here would be
exactly the F-086 failure mode (a doc claiming a human gate passed before it did); it closes only when
Sequoyah runs 2.9's run-sheet and says pass or fail.

## 2.11 · Day/night cycle (T1) — HOST-authoritative time, client-local sky — ✅ shipped, see DELEGATION

**Authority:** §2.2 row 7 (day/night: HOST). The sky rendering stays client-local.
**Claim:** `systems/environment/day_night.gd`, `tools/day_night_check.gd`,
`tools/day_night_net_check.gd`, and `core/net/net_version.gd` + `tools/handshake_check.gd` (F-056 —
the replication mechanism this block asks for is necessarily a new wire item, so preamble rule 5's
protocol bump applies; the original list omitted these two). Registration via `agent autoload`
(preamble rule, F-051) — never claim `project.godot`.
**THE TRAP THIS SPEC EXISTS FOR:** do **not** set `cycle_enabled = true` on
`playtest_atmosphere.gd`. That flag free-runs a local clock per peer from its own boot time —
divergent time-of-day with no error. It stays false forever; the host **pushes** time.

Build:
- `DayNight` autoload — when the script exists and its check passes, register with
  `agent autoload DayNight res://systems/environment/day_night.gd` (it must land after `EnemyWorld`
  in the list; `agent autoload` appends, so just register at the end of the task as the preamble
  says). Host owns `time_of_day: float` (0..1), advancing `delta / day_length_seconds` (default 900
  — read the atmosphere node's export, don't duplicate the constant). Offline runs host-of-one,
  same code.
- Replicate host→clients at 1 Hz (code-built synchronizer per D-023, or an unreliable RPC push);
  clients lerp locally between updates and **never advance time themselves**.
- Every peer (host included) applies received/owned time via the level's Atmosphere node:
  `get_tree().current_scene` lookup for the `Atmosphere` node, `call(&"set_time_of_day", t)`.
  Level without one ⇒ no-op, no error (harnesses).
- Thresholds + signals for 2.12: `night_started` at 0.75, `day_started` at 0.25 (exported, tunable).
  Fire on host only — consumers are host-side systems.
- Standing rule 1 applies to every file here.

Verify: `day_night_check` (host advances; thresholds fire once per crossing; atmosphere receives the
value; a fake harness tree without Atmosphere doesn't error). `day_night_net_check` — two real
processes: client's `time_of_day` follows host within one update interval; killing the flow of
updates freezes the client's sky instead of free-running; client never emits threshold signals.
Done means: both checks 0 failures, 0 `ERROR:` lines; autoload registered and boot log clean;
DELEGATION *Current state* gains the `DayNight` seam block (time, signals, how 2.12 subscribes).

## 2.12 · Night wave spawner (T1) — HOST-only, drives EnemyWorld

**Authority:** §2.2 row 7 (wave director: HOST).
**Claim:** `systems/waves/wave_spawner.gd` (dir exists, `.gitkeep` only),
`tools/wave_spawner_check.gd`. Registration via `agent autoload` (preamble rule, F-051).
**GATE: needs 2.11's `night_started`/`day_started` signals.**

Build:
- `WaveSpawner` autoload — `agent autoload WaveSpawner res://systems/waves/wave_spawner.gd` at task
  end (after `DayNight` is already registered). On `night_started`: set
  `EnemyWorld.ambient_enabled = false` (waves own the field at night; DELEGATION says 2.12 is
  expected to do exactly this), then spawn `base_count + per_player × player_count` crawlers across
  the `enemy_spawn` markers (`EnemyWorld.ambient_spawn_points()`), host-only, seeded RNG for scatter.
- `player_count`: live bodies under `PlayerNet`'s players container; offline = 1. Resolve PlayerNet
  by path (rule 1).
- On `day_started`: `EnemyWorld.host_despawn_all()`, restore `ambient_enabled` to its prior value,
  `top_up_ambient()` so the daytime field refills.
- Night waves escalate later (6.1 Cycle hooks) — export `base_count`/`per_player` now, no Cycle code.
- Death mid-night does not respawn a wave enemy; the wave is a one-shot population per night.

Verify: `wave_spawner_check` drives the signals directly (no 15-minute waits): fake night ⇒ N
spawned, matches formula for 1 and for 3 players; fake dawn ⇒ field empty, ambient restored. Assert
`live_count()` through EnemyWorld's own seam. Extend `enemy_net_check`'s pattern only if an RPC is
added (none should be — spawning is already replicated by EnemyWorld's spawner).
Done means: check green with 0 `ERROR:`; DELEGATION notes the ambient handshake
(`ambient_enabled` save/restore contract).

## 2.13 · Death & respawn (T2) — downed → bleed-out → revive

**Authority:** §2.2 row: player health is HOST; the downed/revive interaction is HOST-validated;
death/downed presentation is client-local.
**Claim:** `systems/health/player_health.gd`, `systems/health/downed_state.gd`,
`entities/player/player_controller.gd` (input gating while downed), `tools/player_health_check.gd`,
`tools/player_health_net_check.gd`, and `core/net/net_version.gd` if any new RPC lands (it will —
the revive request). Registration via `agent autoload` (preamble rule, F-051). **Also decide F-043 here** (see its block below) — the loadout file is
`core/dev/dev_loadout.gd`.

Build:
- `PlayerHealth` autoload (host-keyed `Dictionary[peer_id, {hp, downed, bleed_out_remaining}]`).
  Subscribes `EventBus.enemy_attack_landed` on the host — today that event has **zero** runtime
  subscribers and crawler hits cost nothing; this task is the intended consumer. Use
  `enemy_attack_landed_subscriber_count()` in the check to prove the wiring exists (the
  dev_loadout_check lesson: test the wiring, not just the logic).
- **D-035 is law here:** key state by peer id but move it on `run_player_rebound(old,new)` and
  release only on `run_player_expired(peer)`. Copy `InventoryService`'s deliberate no-op
  `_on_peer_left` pattern, comment included.
- Flow (DESIGN §4.5): hp ≤ 0 ⇒ `downed` (not dead): input-gated crawl, `bleed_out_seconds`
  (export, ~30) ticking on host. A living teammate within `revive_radius_m` holds interact for
  `revive_seconds` ⇒ host restores at `revive_hp_fraction`. Bleed-out expires ⇒ dead ⇒ respawn at
  the level's player spawn (where `PlayerNet` already spawns) after `respawn_seconds`, full hp —
  **M2 rule: solo death = respawn, no run-fail state yet; 6.7 owns the lose condition.**
- Replication: hp/downed to the owner (full) and a downed flag to everyone (teammates must see who
  needs help) — snapshot pattern like inventory (owner-only revisioned full state + broadcast bool),
  not per-frame sync.
- The player body joins `&"damageable"` with `host_apply_damage(amount, instigator) -> bool`
  returning false while downed (no corpse-kicking in M2) — this makes future enemy types and
  friendly-fire decisions data, not new plumbing.
- New client→host RPC: `net_request_revive(target_peer)` validated by range + both alive/downed
  states on the host. Bump `PROTOCOL_VERSION` (6 → 7), extend `handshake_check`.

Verify: offline check steps damage → downed → bleed-out → death → respawn, and revive path;
subscriber-count assertion; two-process check: client cannot heal itself, host rejects out-of-range
revive, downed flag replicates, rebind moves state (reuse `session_lifecycle_check`'s reconnect
scaffolding if practical — otherwise assert via `run_identity_check` patterns).
Done means: both checks green, protocol 7 handshake green, DELEGATION gains the health seam
(who reads hp, what an enemy hit costs, the revive RPC contract), and NEXT's playtest note updated —
after this task, crawlers are lethal.

## 2.14 · Playtest with friends (T0) — the milestone gate

Protocol, so the signal survives the evening: before playing, write down the current
`combat_feel_check` numbers. Play 3+ players, 20+ minutes, at least one full night. Capture
**verbatim quotes**, not interpretations — the roadmap's own wording. Structured questions after:
what did you want to do that you couldn't (Q5 ceiling), when were you scared, when bored, did anyone
understand the workbench without being told, did the night feel like an event. File every defect as
a finding the same evening; DESIGN §8's open questions get their first real answers appended.
**After: stop and re-read DESIGN §8 before starting anything in M3** — the roadmap says so and it
is the cheapest re-plan point in the project.

## 2.1d · Asset batches (rolling) — governed by `ASSET_TRACKER.md`

The tracker is the spec; A-009 (extraction ship, 15 models) is NEXT. Two additions binding from
this audit: record the Blender version in the verification contract with the next batch (D-038),
and the P1/P2 gates now live in the tracker's rows — a batch whose `After` names an unpassed gate is
not promotable, full stop.

## F-043 · Put the iron sword in someone's hand (decide inside 2.13 or by Sequoyah note)

Options, pick one and record it: (a) dev loadout gains the sword for playtest reach, accepting a
trivialised first weapon choice; (b) it stays console-only until 3.x loot places it in the world
(the design-pure answer); (c) it seeds chest loot in 3.5. One line in `core/dev/dev_loadout.gd`
either way; the decision is the deliverable, not the line.

## F-059 · InventoryService's specific-peer `rpc_id` sends were unguarded against a departed peer

Same shape as task 3.8's `player_health.gd` fix. `_publish_snapshot`'s `net_inventory_snapshot.rpc_id()`
and `_confirm_peer`'s `net_operation_confirmed.rpc_id()` each sent to whatever peer id owned the store
or request, gated only on `_transport().call("is_active")` — never on whether that specific peer id was
still connected. Reachable whenever `_commit(peer_id)` fires for a peer D-035's grace window is still
parking (a harvest yield landing, a crafting response). **Claim:** `autoload/inventory_service.gd`,
`tools/inventory_net_check.gd`. **Fix:** a `_peer_connected(peer_id)` helper
(`_transport().call("peer_ids").has(peer_id)`) gating both sends — mirror `player_health.gd`'s own
guard (`_peer_connected`) rather than reinventing it; `net_request_remove`/`net_request_move_stack`
need no guard, they always target `NetConfig.HOST_PEER_ID`, which is never parked.
**Shipped 2026-08-18** (`docs/FINDINGS.md` Resolved has the full verification). Re-verify with
`agent godot --script tools/inventory_net_check.gd`, which calls `_commit()` directly on a parked peer
to exercise the exact path — the public `host_add`/`host_transaction` API cannot reach it today
(F-074, open).

## F-060 · Two `tools/*_net_check.gd` authoring traps: a false-positive ready gate, and a `.get()` mutation that doesn't stick

Two shapes worth knowing before writing the next two-process check. **(1)** `local_peer_id() >
HOST_PEER_ID` (optionally `and local_revision >= 0`) can read true before the connection is actually
established — ENet hands a client its own unique id locally the instant `create_client()` succeeds,
before the host<->client handshake completes. Always gate on `bool(transport.call("is_active"))` too.
**(2)** mutating what `some_autoload.get("prop")` returns for a strictly-typed `Dictionary` property
(`registry.get("items")[id] = x`, or `.erase(x)` chained straight off it) does not reliably reach the
original — capture it to a `Dictionary` local and `.set()` it back explicitly afterward.
**Claim:** none — already fixed everywhere it existed (`tools/player_health_net_check.gd`,
`tools/combat_net_check.gd`, `tools/crafting_net_check.gd`, `tools/inventory_net_check.gd`,
`tools/harvest_world_net_check.gd`, `tools/enemy_net_check.gd`, `tools/harvestable_net_check.gd`,
`tools/harvestable_check.gd`, `tools/chest_check.gd`; `tools/player_vitals_net_check.gd`,
`tools/player_vitals_check.gd` and `tools/chest_net_check.gd` were already correct).
**Shipped 2026-08-18** (`docs/FINDINGS.md` Resolved has the full verification). `agent godot --script
tools/net_check_pattern_check.gd` is a standing regression guard — it source-scans every `.gd` file for
both shapes and fails if either reappears, so a new `tools/*_net_check.gd` copied from an old file
before this fix cannot silently reintroduce either trap.

---

## F-061 · `content/items/coins.tres` has no icon — the `render_item_icons.py` pipeline needs a SOURCES entry

**Claim:** `tools/blender/render_item_icons.py`, `assets/icons/catalog.json`,
`content/items/coins.tres`, `assets/icons/exports/`, `assets/icons/preview/`, `assets/icons/README.md`.
No `ARCHITECTURE.md` §2.2 authority row — presentation-only, same as the rest of A-042a; item
*instances* stay host-authoritative under the existing Inventory/crafting row regardless of icon.

3.5 added `coins.tres` with `icon` left null — 3.5's own claim set (`systems/loot/`, `ui/loot/`,
`autoload/registry.gd`) didn't reach the art pipeline, and neither InventoryUI nor ChestUI breaks on a
null icon, so nothing was broken, just unfinished.

**Fix:** appended `("coins", "loot/exports/loot_coin_pouch.glb")` to `SOURCES` — keep the id plural,
matching `coins.tres`'s own `id`, distinct from the pickup icons already named `coin`/`coin_stack`.
Reran `/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/render_item_icons.py`; default azimuth/elevation framed the pouch without a new
`AZIMUTH`/`ROLL_OVERRIDE_DEG` entry. Wired `coins.tres`'s `icon` to
`res://assets/icons/exports/icon_coins.png`. The rerun re-stamps all 25 pre-existing PNGs with new
Blender metadata (F-042) with zero pixel change — confirmed with `tools/png_pixels_equal.py` against
each file's committed `HEAD` copy — so those 25 were reverted with `git checkout --` before
committing; only the new PNG, the regenerated contact sheet, and the catalog/README updates are real
diffs.

**Shipped 2026-08-18.** Verified: `.agent/bin/agent godot --script tools/item_icons_check.gd` →
`item_icons_check: PASS`, run twice consecutively. (The first run immediately after the new PNG
appeared on disk reported 2 failures before any rerun — F-093's shape, a headless `--script` pass
doesn't reimport an asset that appeared mid-session; not a regression, confirmed clean on rerun.)

---

# M3 — systems depth (start only after 2.14's re-read of DESIGN §8)

**Milestone-wide rules.** Every new player-facing state keys by peer id under D-035 discipline.
Every new UI joins `&"blocks_gameplay_input"` (D-032). Every content family gets: a `*Def` resource
script under `systems/`, a loader in `Registry` (extend `autoload/registry.gd`, keep the boot-log
count line honest), a `content/<family>/` directory, and one focused check. Content *values* are
authored by Sequoyah in the inspector (D-006); agents ship the framework plus ONE worked example.

## 3.1 · Crafting tree & stations (T2)

**Claim:** `systems/crafting/station_def.gd`, `systems/crafting/recipe_def.gd`,
`autoload/crafting_service.gd`, `autoload/registry.gd`, `ui/crafting/crafting_ui.gd`,
`tools/crafting_check.gd`, `tools/crafting_net_check.gd`, `content/stations/workbench.tres`.
- `StationDef` (`id`, `display_name`, `world_scene`, `tier: int`); `RecipeDef` gains
  `station: StringName` (default `&"workbench"` — the shipped recipe keeps working) and
  `output_count: int = 1`.
- `CraftingService.host_validate` adds the station-tier check to its existing range check; the UI
  filters recipes by the station being used. RPC payload unchanged if possible (recipe id + request
  id already suffice — station is derived host-side from proximity, never trusted from the client).
  No payload change ⇒ no protocol bump; say which way it went in the close-out.
- Furnace introduces **timed crafts**: host-side timer per request, `craft_progress(request_id)`
  poll seam for the UI, confirmation on completion. Client shows progress, predicts nothing.
- Worked example: workbench StationDef + one furnace recipe (`iron_ore → iron_ingot`) to prove the
  timer path; the rest of the tree is 3.2's authoring.

## 3.2 · Author item/recipe content (T0)

**The authoring catalog is `docs/ITEMS.md`** — the same relationship 3.4 has to `POWERUPS.md`. Its
§4 tables are the menu (~136 items with sources, recipes and jobs), §8's wave plan says which ~45
are authorable the day 3.1 lands versus gated on later systems, and §2's rules (2-step refinement
cap, no armor items, no durability, stack conventions) are the calls not to relitigate mid-batch.
Inspector work against 3.1's schema. Icons via `tools/blender/render_item_icons.py` (append to
`SOURCES`, re-render, compare **decoded pixels not file hashes** — F-042). Keep ids snake_case,
stack sizes 99 for resources / 1 for tools. `Registry` prints the count; `item_icons_check` and
`crafting_check` are the proof. No agent bulk-generates values (D-006).

## 3.3 · Powerup framework (T2)

**Claim:** `systems/powerups/powerup_def.gd`, `autoload/powerup_service.gd`,
`autoload/registry.gd`, `tools/powerup_check.gd`, `content/powerups/` (one worked example).
Registration via `agent autoload` (preamble rule, F-051).
- `PowerupDef`: `id`, `display_name`, `icon`, `tags: Array[StringName]`, `max_stacks`,
  `modifiers: Dictionary[StringName, Vector2]` (stat → per-stack `Vector2(additive, multiplicative)`).
  **SHIPPED 2026-08-18 — there is NO `resonance_family` field, and 3.4 must not author one.** This
  block originally asked for one "for §4.4 thresholds", but §4.4 keys its thresholds off the tags
  themselves ("holding 3+ of a tag"), so a second field would be a second name for one concept — and
  its failure mode is silent: set `tags`, leave `resonance_family` empty, and the powerup shows its
  icon while contributing to no Resonance at all. **Tags ARE the families.** See D-044, which also
  fixes the stacking maths as `(base + additive*N) * (1 + multiplicative*N)`, linear in N rather than
  compounding.
- HOST-auth: `PowerupService` holds per-run-player stacks (D-035 discipline), applies stat queries
  via one seam: `stat(peer_id, &"move_speed", base) -> float` — systems ASK the service, the service
  never reaches into systems. Owner gets full replication; teammates get counts only.
- Resonance: crossing a family's stack threshold toggles a named effect flag systems can query
  (`resonance_active(peer, family)`); the flag is data, effects hook it in their own tasks.
- Worked example: one speed powerup + one Resonance family with a 3-stack threshold, exercised in
  the check offline and in a 2-line extension to an existing net check for the replication.

## F-089 · Powerup lifecycle never removed obsolete family counts from clients

`net_powerup_counts` is a broadcast, and the only way a client's `_family_counts[peer_id]` entry ever
changes is another broadcast for that same `peer_id` — there was no deletion path. `_on_run_player_rebound`
moved `_stacks`/`_family_counts` from the old peer id to the new one and erased the old key **locally
on the host only**, then `_commit(new_peer_id)` published the new id; nothing ever told teammates the
old id was gone. `_on_run_player_expired` erased locally and published nothing at all. Either way
every teammate kept the last nonzero count they'd heard for an id that no longer existed — a ghost
Resonance that outlived a reconnect or survived forever past an expiry. **Claim:**
`autoload/powerup_service.gd`, `tools/powerup_review_check.gd`. **Fix:** a shared `_retire_broadcast(peer_id,
before)` — called for the *old* id in `_on_run_player_rebound` (before the family-count key moves to
the new id) and for the expiring id in `_on_run_player_expired` — that emits the downward
`resonance_changed(peer_id, family, Resonance.NONE)` transition for every family that id was resonant
in, then (guarded by `NetTransport.is_active`) broadcasts `net_powerup_counts.rpc(peer_id, {})` so
`_family_counts[peer_id]` reads empty everywhere before the host erases its own entry. The rebound
path still moves the pre-rebind counts onto the new id *before* calling `_retire_broadcast`, so
`_commit(new_peer_id)`'s before/after diff sees no change and does not spuriously re-fire
`resonance_changed` for thresholds the player already crossed under the old id.
**Shipped 2026-08-18** (`docs/FINDINGS.md` Resolved has the full verification). Re-verify with
`agent godot --script tools/powerup_review_check.gd` (both lifecycle events, over two real ENet
processes) plus `tools/powerup_check.gd` and `tools/powerup_net_check.gd` for no regression.

## 3.4 · Author 40–60 powerups (T0) — inspector, against 3.3's worked example. Never agent-generated.

3.3 shipped 2026-08-18. **The authoring spec is `docs/POWERUPS.md`** (the pre-3.4 design check,
reed16): §2 is the stat catalog — the ONLY names `modifiers` may use, enforced at boot by
`PowerupDef.KNOWN_STATS`/`KNOWN_FAMILIES` (F-078) — and §4 is a 60-powerup sketch spanning the
design space to pick from or replace. Also read **D-044** (tags ARE the Resonance families — there
is no `resonance_family` field; and the stacking maths), **D-050** (conditions/triggers/capabilities
are stat-name conventions, not fields), and `docs/DELEGATION.md` *Current state* for the replication
split. Copy **`content/powerups/swift_stride.tres`**; it is the one worked example and it loads
through the real registry. `PowerupDef.validation_errors()` runs at boot, so a malformed `.tres` is a named error and
a skip in the boot log, never a silent omission — check that log after a batch. `modifiers` maps a
stat name to `Vector2(additive, multiplicative)` **per stack**: `Vector2(0, 0.08)` is +8% per stack,
`Vector2(2, 0)` is +2 flat per stack.

Two things worth knowing while balancing. `max_stacks` caps ONE powerup; a Resonance counts a whole
**family across different powerups**, so three different Fire powerups resonate at one stack each —
a family threshold is not reachable-only-by-stacking-one-thing. And no system reads a stat until its
own task routes its base value through `PowerupService.stat()`; movement, damage and health are not
wired yet, so a `move_speed` powerup authored today is correct data that nothing consumes until then.
That is expected, not a bug to chase.

## 3.5 · Coins, chests, opening flow (T1)

**Claim:** `systems/loot/chest.gd`, `systems/loot/loot_entry.gd`, `systems/loot/loot_table_def.gd`,
`ui/loot/chest_ui.gd`, `autoload/registry.gd`, `content/loot/`, checks. Chests are placed props
(A-005 loot assets exist) with tiers; opening is a host-validated interact (harvest pattern:
request → host rolls seeded RNG per-chest → `InventoryService.host_add` grants → broadcast). Coins
are an item (stack 999), not a parallel currency system. Loot rolls host-side from a per-run seeded
`RandomNumberGenerator` — never `randi()`. UI joins the D-032 group.

**The content design is `docs/ITEMS.md` §5–6** (chest tier set + the four mechanics it asks of this
task — each a noticed decision, F-078 style, not a surprise field):
`LootEntry.kind: ITEM | POWERUP` (DESIGN §4.4 says powerups drop from chests; POWERUP entries grant
through PowerupService's host seam) · `LootEntry.rarity: int` (the consumer the shipped `loot_luck`
stat is waiting for) · chest `cost_coins` (routed through the `chest_price` stat) + `locked_by:
StringName` key check · a placement budget for the `gilded` tier (≈1–2 per island). **D-063 governs
the Gilded/Gleam tier:** jackpots are content, rarity is the only balance lever.

## F-105 · Per-frame costs found by the F-099 review in files claimed by F-086/F-097

**Claim:** the finding's own work order named `autoload/build_service.gd` — wrong file, kept as an
F-105 note rather than corrected there. `build_service.gd` has no per-frame cost (it only runs off
host RPCs); the three items are in `systems/building/build_ghost.gd`,
`entities/player/player_controller.gd`, `autoload/environment_vfx.gd`, so those are what got claimed
and fixed, plus `tools/build_check.gd` and `tools/player_vitals_check.gd` for the call-site/assertion
changes below.

**Item 1 — `build_ghost.gd:update_aim()` ran the full validator every physics tick.**
`PlacementValidator.evaluate()` (5 support raycasts + a shape cast, fresh query/shape allocations)
now only runs when the snapped `_placement` or the `builder_position` range input actually differ
from the last evaluated call, OR `REEVALUATE_INTERVAL_S` (0.2 s) has passed since the last real
answer — the timer is what still catches a world change (someone else builds where you're aiming)
under a ghost that never moves. `set_piece()` resets the cache (`_has_evaluated = false`): a same-spot
piece swap must not read the OLD piece's verdict, since `evaluate()` also depends on the def (size,
mass, rules), not just the transform. `update_aim()` gained a 4th optional `delta: float = 0.0`
param to pace the timer; every existing 3-arg caller (`tools/build_check.gd`) still compiles and still
gets correct (if less proactively refreshed) behaviour, since each of its calls already varies the aim
or the piece between assertions. `player_controller.gd`'s `_tick_build_ghost()` now takes and forwards
its own `delta`. A new `evaluate_count()` getter (backed by `_evaluate_count`, incremented only on a
real `evaluate()` call) exists so a check can prove the skip is real instead of trusting the comment.

**Item 2 — `player_controller.gd`'s physics tick re-derived downed/dead/input-allowed 3x each.**
`_apply_horizontal_movement()`/`_try_jump()`/`_tick_revive_hold()` each independently called
`gameplay_input_allowed()` (a group scan) and `_is_downed()`/`_is_dead()` (a `get_node_or_null(/root/
PlayerHealth)` plus a `.call()`), none of which can change mid-tick. `_physics_process()` now resolves
all three exactly once and threads them through as parameters; the three functions' signatures gained
`input_allowed: bool, downed: bool, dead: bool` (in that call order) instead of re-deriving them.
Separately, `_health_node()` now caches the resolved `/root/PlayerHealth` node in a `_health` member
var (autoloads outlive the whole session once resolved) rather than walking `/root` on every call —
this is what `_tick_revive_hold()`'s own direct `get_node_or_null` call was doing outside the shared
helper; it now goes through `_health_node()` like everything else. **Two test call sites needed
updating** (`tools/player_vitals_check.gd` calls `_try_jump()`/`_apply_horizontal_movement()`
directly, bypassing `_physics_process()`): both now pass `true, false, false` explicitly — a standing,
undowned, alive, unblocked player, the same values `_physics_process()` would have computed.

**Item 3 — `autoload/environment_vfx.gd`'s `_fire_lights`/unscaled-shadow description no longer
matches the file.** F-097 (landed same day, before this task) fully replaced fire-light discovery
with the `_sites`/`_pools` budget system: pools are capped at `profile.max_live * preset_scale` and
reused in place (`_assign_slots()`), never appended past that cap, and `_reset()` clears them on every
scene change — the append-only growth the finding described does not exist in the current file.
`shadow_enabled` is already `index < shadow_live * preset_scale` (`_assign_slots()`), not
unconditionally true — `GraphicsQuality` presets already scale it, confirmed against
`AssetVfx.EMITTER_PROFILES`' `shadow_live` values (2/6 campfires, 1/4 forges, 1/4 embers, 0 for
crystal/spore). The one genuinely still-true part — `_process()` runs its scene-change check every
frame regardless of fire count — now short-circuits before the budget timer and light-flicker pass
when `_sites` and `_pools` are both empty, since neither loop can do anything in that state.

**Verified 2026-08-18:** `agent godot --script tools/build_check.gd` (failures=0, including four new
F-105 assertions: an unchanged aim ray does not re-evaluate, a moved one does, moving back does, and
the re-evaluate timer alone trips it under an unmoved ray); `tools/player_vitals_check.gd` (0
failures); `tools/environment_vfx_check.gd` / `tools/environment_vfx_hollowmere_check.gd` (failures=0,
pools stay within budget on both maps); `tools/verify_setup.gd` (all checks passed);
`tools/combat_self_hit_check.gd`, `tools/build_net_check.gd`, `tools/player_health_net_check.gd`,
`tools/player_vitals_net_check.gd` (all 0 failures) — full-path coverage of every function this task
changed the signature of.

## F-107 · `chest_net_check`'s two host-side grant assertions fail at HEAD; client side is green

**Claim:** `tools/chest_net_check.gd`. No production file — `systems/loot/chest.gd` and
`InventoryService.host_add()`/`host_count()` were all read and are correct as committed.

**Root cause: the check, not the grant.** `_run_driver()` derived `client_peer` inside the `_until()`
poll's lambda (`client_peer = peer_id; return true`) and read it in the outer scope afterward. A
GDScript lambda captures an outer local **by value**, not by reference, so the assignment only ever
updated the closure's own copy — the outer `client_peer` stayed at its `-1` sentinel even once
`got_peer` reported success. `host_count(-1, ...)` then hit `_valid_host_peer()`'s `peer_id <= 0`
guard and read back `0` unconditionally, regardless of what the host had actually granted — which the
adjacent "client's grant reply carries the rolled coins/item" PASSes already proved was correct.

**Fix:** keep the closure boolean-only (does a non-host peer exist yet), then re-scan
`transport.call("peer_ids")` directly in the outer scope once `got_peer` is true, assigning
`client_peer` there instead of inside the lambda.

**Verified 2026-08-18:** `agent godot --script tools/chest_net_check.gd`, two consecutive runs,
`failures=0` both times, all 12 assertions PASS including the two that were red at HEAD.

## F-103 · MultiMesh instance transforms are write-only under `--headless`, so anything that reads them back silently gets the origin

**Claim:** `tools/multimesh_readback_check.gd`. No production file — the fix already shipped inside
F-097 (`4919d26`); this task is the missing spec, the verify pass, and closing the finding.

**Root cause:** `MultiMesh` instance transforms live in the RenderingServer, not in the resource. The
`--headless` dummy driver retains nothing, so `multimesh.buffer` comes back empty and
`get_instance_transform(i)` returns `Transform3D()` identity for every `i` regardless of what was
written — no error, no warning. F-097's first firelight pass read emitter positions back out of the
prop batches and every one of Hollowmere's 99 mire crystals, 163 tendrils and 5 fires collapsed onto
the world origin; a count-based assertion ("≥ 1 site per class") could not see it, only a check that
compares the count against what the layout file actually holds can.

**Fix (already shipped, F-097):** never read placement back from a `MultiMesh`. The generator that
writes the transforms already has them, so it publishes them instead: `world/gen/authored_world.gd`
and `world/gen/undergrowth.gd` stamp a `placements: PackedVector3Array` meta on the holder for any
asset whose presentation is per-copy (`Represent.BATCH`), and `EnvironmentVfx` reads that meta
instead of the batch. See `docs/DELEGATION.md` *Current state* (F-113/F-114 entry) for the
`Represent.NODE`/`Represent.BATCH` split this sits on.

**This task's file**, `tools/multimesh_readback_check.gd`, is the regression guard: it asserts the
*trap itself* (headless readback is identity, buffer is empty) rather than the fix, on purpose — if a
future Godot ever starts retaining instance data headlessly, this check fails and that is the signal
to revisit every `placements`-meta workaround built around the limitation. It also asserts the
replacement contract (a `placements` meta survives a holder round-trip where MultiMesh transforms do
not).

**Verified 2026-08-18:** `agent godot --script tools/multimesh_readback_check.gd`:

```
MULTIMESH_READBACK distinct_origins=1 buffer=0
PASS: headless MultiMesh readback is still write-only (F-103 assumption holds)
PASS: published placements survive where MultiMesh transforms do not
MULTIMESH_READBACK_CHECK failures=0
```

## F-111 · `enemy_check.gd`'s telegraph/swing assertions fail at HEAD, unrelated to F-075

**Claim:** `tools/enemy_check.gd`. No production file — `systems/enemies/enemy.gd` was read and is
correct as committed.

**Root cause: the check, not the AI.** The telegraph scenario (`enemy_check.gd:79-89`) first pins the
enemy at the origin, holds a target between the aggro/deaggro radii, then moves the player to 400 m
and steps once — the target is dropped and `_resolve_target()` falls through to an immediate rescan,
which finds nobody and, on the way out, sets `_rescan_wait = RESCAN_INTERVAL_SEC` (0.2 s; F-099's
throttle — an untargeted enemy scans the `players` group at most once per interval, by design, not a
bug). The very next lines teleport the player to 1 m away and took a **single** 0.05 s step expecting
`state == TELL` immediately. That step lands inside the freshly-reset 0.2 s cooldown, so
`_resolve_target()` returns null without ever looking at the group, the enemy stays `IDLE`, and every
downstream assertion (swing, damage, target, commit-to-swing) fails as a chain reaction from that one
miss — exactly `enemy_check.gd:92-106` per the finding. `_step_until_state()` a few lines further down
(the *second* telegraph, line ~112) already steps until the state actually changes rather than
assuming one tick suffices, and that one was always green — confirming the throttle, not the state
machine, was the mismatch.

**Fix:** the first telegraph assertion now uses the same `_step_until_state(enemy, 2, 0.05, 20)`
pattern as the second one, instead of one bare `_step(enemy, 0.05)`. 20 steps at 0.05 s is 1 s of
margin over the 4 steps (0.2 s) the cooldown actually needs — generous on purpose since
`_rescan_wait` is a float subtraction and the exact step count it clears on is not worth pinning.

**Verified 2026-08-18:** `agent godot --script tools/enemy_check.gd` against the pre-fix tree
reproduces the finding's exact 5 failures (`ENEMY_CHECK attacks=0 failures=5`) — same set the
original F-075 baseline against `e028365` reported, confirming HEAD hadn't drifted from the repro.
After the fix (`tools/enemy_check.gd` only): all 44 assertions PASS, `ENEMY_CHECK attacks=0
failures=0`. `systems/enemies/enemy.gd` untouched.

## 3.6 · Building system (T2)

**Claim:** `systems/building/` (ghost, placement validator, buildable_def) and its checks.
Registration via `agent autoload` (preamble rule, F-051).
- Ghost is client-local presentation (last §2.2 row): grid snap, rotate, red/green validity preview.
- Placement is a host request carrying piece id + transform; **host revalidates from scratch**
  (overlap, support, range, cost via `host_transaction`) — the client's green ghost is a hint, not
  authority. Destruction mirrors it. Placed pieces replicate through a code-built spawner (D-023)
  and join `&"damageable"`.
- After any placement/destruction, call `EnemyWorld.bake_navigation()` **debounced** (one rebake per
  second max) — full-level rebake is the M2-scale answer; per-chunk is 4.5's problem.
- Ward structures are buildables with a `ward_radius_m` field — the field ships, the Mire reads it
  in 4.11. Worked example: wall + Ward post.

## 3.7 · Buildable pieces + Wards (T0) — content over 3.6's def, A-013/A-007 assets.

## F-084 · `net_request_destroy` freed and refunded any piece by name alone, with no range check

3.6's spec line above already says "Destruction mirrors it" (placement's host-revalidates-from-
scratch contract) but the shipped `_process_destroy` only checked `_placed.has(piece_name)` —
`autoload/build_service.gd:165` at the time of the 3.6 review. Piece names are sequential
(`Piece1`, `Piece2`, ...), so any connected peer could free and refund every structure on the map
by enumerating names, from anywhere. **Claim:** `autoload/build_service.gd`,
`tools/build_net_check.gd`. **Fix:** resolve the requester's own host-known body via the same
`_builder_position(peer_id)` placement already uses, and refuse (`Reason.OUT_OF_RANGE`, "too far
away") before any refund or `queue_free()` if it is farther than the piece def's own
`max_build_range_m`. **Ownership is deliberately not checked** — 3.6 already made "refund goes to
whoever tears it down, not to whoever built it" an intentional design choice (any teammate may
clear a misplaced piece), so the fix adds only the range gate, not an owner gate. Line of sight is
out of scope too: nothing else in the building system checks it (placement doesn't either), and
inventing a new rule class for destroy alone would stop it mirroring placement.
**Shipped 2026-08-18** (`docs/FINDINGS.md` Resolved has the full verification). Re-verify with
`agent godot --script tools/build_net_check.gd`, which now proves both directions over real ENet: a
piece planted 100 m from the client is refused by name alone, and the piece the client actually
built and stands beside still destroys and refunds correctly.

## F-082 · Placement support succeeded when only one of five footprint probes hit

`PlacementValidator._probe_support()` (`systems/building/placement_validator.gd`) probed all five
footprint points (four corners + centre) but skipped any that missed and returned the flattest hit
among whatever survived. `evaluate()` then treated any non-empty result as supported: a 2 m wall
resting on a 20 cm pillar under its centre, with all four corner rays finding nothing, still read
`Reason.OK`, because the lone centre hit was "the flattest thing found." A cliff-edge piece with
three of four corners hanging off was accepted the same way. **Claim:**
`systems/building/placement_validator.gd`, `tools/build_check.gd`. **Fix:** `_probe_support` now
returns `{}` — the same "unsupported" sentinel `evaluate()` already checked via `is_empty()` — the
moment any one of the five probes misses, and otherwise returns the WORST (steepest) slope among
the five hits rather than the flattest, so one grounded corner can no longer hide three ungrounded
ones. There is no authored field distinguishing "required" from "optional" probes on `BuildableDef`,
so the decision (recorded, not a new `D-0NN` — it follows directly from the finding's own wording)
is that all five are required; a piece meant to bridge a gap already has the escape hatch,
`requires_support = false`. **A trap for the next geometry added to `tools/build_check.gd`:** the
existing "on a slope" test used to rely on a single centre-only hit and broke under the stricter
rule — a flat piece run *across* a steep slope's fall line genuinely cannot have all five probes in
reach of the ground (its corners are metres apart vertically), so that placement now correctly reads
`NO_SUPPORT`, not `TOO_STEEP`. The fixed test turns the piece 90° so its width runs *along* the
slope's contour instead, and thins the test bank from 1 m to 0.1 m — a full-thickness box tilted 55
degrees is ~1.7 m of solid through a world-vertical line, so a probe tuned to start just clear of the
face still starts INSIDE the solid a few centimetres either side of that exact point and silently
reads as no hit. **Shipped 2026-08-18.** Verify with `agent godot --script tools/build_check.gd`
(66 assertions, `failures=0`) and `tools/build_net_check.gd` (13 assertions, `failures=0`, confirms
the host's real placement path — same validator, same rule — is unaffected).

## F-075 · World statics and props shared collision layer 1, so a placement overlap query could not tell ground from obstruction

`PlacementValidator._overlaps()` (`systems/building/placement_validator.gd`) and terrain both queried
collision layer 1, so the ground a piece rested on registered as the very obstruction the overlap
check was refusing — every sloped placement read "something is in the way" until the query box was
lifted by a clearance derived from the piece's steepest permitted slope, a workaround that made any
real obstruction below that clearance (up to 0.58 m for a 2 m wall permitting 30°) invisible to the
check. **Claim:** `systems/building/placement_validator.gd`, `systems/building/build_ghost.gd`,
`world/gen/authored_world.gd`, `tools/build_check.gd`, `entities/player/player.tscn`,
`systems/enemies/enemy.gd`, `project.godot`. **Fix:** a dedicated ground layer,
`PlacementValidator.TERRAIN_LAYER = 2` (named in `project.godot`'s new `[layer_names]` as
`3d_physics/layer_2="terrain"`; layer 1 renamed `"solid"`). `authored_world.gd`'s terrain
`StaticBody3D` is the only body that layer 2 — every other collider this task touched (props,
harvestables, placed buildable pieces, players, enemies) stays on the engine-default layer 1.
`_probe_support()` now ORs `TERRAIN_LAYER` into whatever mask the caller passes, so ground is always
found for support regardless of the caller's own "solid" mask; `_overlaps()` never adds it, so the
overlap query no longer sees the ground a piece is resting on and its clearance collapses to the flat
`MIN_GROUND_CLEARANCE_M` floor — the blind band is gone for anything built on this generator.
`build_ghost.gd`'s own aim ray (finding *where* the player is pointing, independent of
`evaluate()`) needed the same OR, or it could no longer find bare ground to aim at. Both
`entities/player/player.tscn`'s `CharacterBody3D` and `systems/enemies/enemy.gd`'s
`_build_body()` needed an explicit `collision_mask = 3` — the engine default (`1`) would otherwise
have both walking straight through Hollowmere's terrain the moment it moved off layer 1; this was the
"whatever masks the player and enemies use" cost the finding named as project-wide. Deliberately
**not** migrated: `world/gen/playtest_hollow.gd` — deprecated (superseded by Hollowmere), locked by
another lane's claim at the time, and confirmed by grep to have no `PlacementValidator` caller, so its
terrain staying on layer 1 costs nothing today. Any future generator that emits terrain must put it on
`PlacementValidator.TERRAIN_LAYER` or inherit the same blind band this task removed.
**Shipped 2026-08-18.** Verify with `agent godot --script tools/build_check.gd` (0 failures, includes
the F-075 layer split in its own fixtures — ground fixtures default to `TERRAIN_LAYER`, the one true
obstruction is pinned to `WORLD_LAYER`), `agent godot --script tools/hollowmere_check.gd` (terrain,
grounding and nav probes all clean against the real map), `agent godot --script tools/enemy_check.gd`
/ `tools/combat_check.gd` / `tools/enemy_net_check.gd` / `tools/harvest_world_check.gd` (no new
failures — `enemy_check.gd`'s 5 telegraph failures reproduce identically via `agent baseline` at HEAD,
confirmed pre-existing and unrelated, filed separately as F-111), and
`agent godot --quit-after 120` (Hollowmere boots, navmesh bakes 9,486 polygons, no errors).

## F-076 · A new map inherits none of the systems keyed to the old map's group names

`autoload/enemy_world.gd` and `autoload/harvest_world.gd` each keep a hand-maintained list of legacy
group names to recognize a map's content (`NEST_SOURCES`, `HOLDER_GROUPS`) — necessary for backward
compatibility, but a check built by re-reading the same lists inherits the exact blind spot it exists
to catch: Hollowmere shipped with zero crawlers and 77 dead trees because both lists only knew
Playtest Hollow's names, and nothing errored. **Claim:** `autoload/enemy_world.gd`,
`autoload/harvest_world.gd`, `tools/world_contract_check.gd` (new). **Fix:** two new pure functions —
`EnemyWorld.expected_nest_count(layout: Dictionary) -> int` and
`HarvestWorld.expected_harvestable_count(layout: Dictionary) -> int` — read ground truth straight off
a map's raw layout JSON (`markers[].kind == EnemyWorld.CANONICAL_NEST_KIND` i.e. `&"enemy_nest"`,
`props[].harvestable == true`) rather than through any group, so they cannot go blind to the same
group name their own consumer does. `tools/world_contract_check.gd` boots whatever
`project.godot`'s `main_scene` is, finds the layout the way `Undergrowth` already does generically (a
`World` node exporting `layout_path`), and fails if `expected_nest_count() > 0` but
`ambient_spawn_points()` comes back empty or no crawler ever spawns, or if
`expected_harvestable_count() > 0` but `wired_harvestables()` comes back empty. A map not built on
the `AuthoredWorld` layout convention has nothing to compare against and the layout-shaped checks are
skipped, not failed — this is deliberately not a hard requirement on every future world generator.
`enemy_nest` is now the one canonical marker kind a new generator should publish (D-062);
`NEST_SOURCES` keeps its legacy `enemy_spawn` synonym for Playtest Hollow but ground truth
deliberately does not read through it. **Not attempted:** `world/gen/undergrowth.gd`'s prop-avoidance
rule (the third system the original finding named) — it has no clean ground-truth field in a layout
the way markers/harvestable-props do, and generalizing it needs a claim outside this task's files;
filed as **F-112**. **Shipped 2026-08-18.** Verify with `agent godot --script
tools/world_contract_check.gd` (`WORLD_CONTRACT_CHECK PASS`, `layout_nests=4 spawn_points=4 live=4`,
`layout_props=83 wired=83`) — regression-proved by temporarily commenting out
`NEST_SOURCES`' Hollowmere entry and confirming the same run fails with `spawn_points=0` and the
expected message, then reverting — plus `agent godot --script tools/hollowmere_check.gd` /
`tools/harvest_world_check.gd` (no change, still green) and `tools/enemy_check.gd` (`failures=5`,
identical to the pre-existing F-111 telegraph failures, confirmed unrelated).

## F-085 · Buildables joined `damageable` without implementing its required damage method

`BuildService._net_spawn_piece()` (`autoload/build_service.gd`) added every spawned piece to
`&"damageable"`, but neither the generated fallback box nor an authored scene root gained
`host_apply_damage(amount: int, instigator_peer_id: int) -> bool` — the group's actual contract,
which `CombatService._best_target()` requires via `has_method()` before it will ever consider a node
a target (`autoload/combat_service.gd:251`). The shipped check asserted only group membership and
called that proof the piece could be attacked, so it passed green while every buildable was
invisible to combat. **Claim:** `autoload/build_service.gd`, `tools/build_check.gd`,
`systems/building/buildable_def.gd`, `systems/building/buildable_piece.gd` (new). **Fix:** a new
`systems/building/buildable_piece.gd` implements the contract — host-only (re-checks authority
itself, same `_owns_world_mutation()` shape as `Harvestable`/`Enemy`, never trusts that
`CombatService` already gated it), tracks `hp`, and on lethal damage calls a new
`BuildService.host_piece_destroyed_by_damage(piece_name, instigator_peer_id)`, which removes the
piece the same way `_process_destroy` does — minus the range check (the attacker already had to pass
the weapon's own reach/arc test) and minus the refund (a piece fought and lost pays out nothing,
matching `Harvestable`/`Enemy` on death). `_net_spawn_piece()` attaches this script only to a piece
root that doesn't already bring its own `host_apply_damage`, so a future authored root with staged
damage states (task 3.7) is never clobbered. `BuildableDef` gained `max_hp: int = 25` (new `Combat`
export group, validated non-positive like every other numeric field) — host-only and deliberately
unreplicated: nothing shows chip damage yet, and a piece's existence already replicates through
`MultiplayerSpawner`'s despawn the instant the host `queue_free()`s it (D-023), which is the only
state a client needs. **Shipped 2026-08-18.** Verify with `agent godot --script tools/build_check.gd`
(`failures=0`) — asserts `has_method(&"host_apply_damage")` directly rather than trusting the tag,
exercises a nonlethal hit (piece survives, still tracked), then a fresh piece taken to a lethal hit
(`_check_damage_destroys_piece`: `BuildService` forgets it, the node frees, no refund lands, a nav
rebake is queued) — and `agent godot --script tools/combat_check.gd` (`failures=0`, unaffected: its
own scenarios never place a buildable).

## F-087 · Three open findings shared their F-number with a different finding

`docs/` is deliberately unclaimed (F-006), so concurrent lanes filing a finding in the same window can
both read `agent brief`'s "next number" and both append as it — F-058's failure mode, recurring: F-058,
F-059 and F-060 each named two unrelated findings, one Resolved (cited by shipped commits) and one
still Open. `agent brief`/`claim` picked one arbitrarily, and `agent start`/`board` reported the Open
one as "closed but still under '## Open'" because it matched the Resolved twin by number — the natural
fix (move it to Resolved) would have buried a live bug. **Claim:** `docs/FINDINGS.md` (the only file
this needed). **Fix:** renumbered the three *later*-arriving, still-Open entries to fresh numbers above
the prior high-water mark — F-058→**F-092**, F-059→**F-093**, F-060→**F-094** — leaving the three
original, commit-cited entries untouched. Repointed every `docs/`/`.agent/` reference that meant a
renumbered entry (`docs/ASSET_TRACKER.md`, `.agent/state.json`'s stale task titles); left references
that meant an original alone, including `docs/SPECS.md`'s own `## F-059`/`## F-060` blocks above and
`docs/DELEGATION.md`'s F-059/F-060 notes — both are about the originals and needed no change.
Code-comment references (`tools/*.gd`, `tools/blender/mire_art.py`) are deliberately out of scope, per
F-071's prior finding that renumbering there is its own cross-cutting pass. Policy for any future
collision recorded in **D-053**.
**Shipped 2026-08-18** (`docs/FINDINGS.md` Resolved has the full verification). Re-verify with
`agent board`: no more "F-number(s) used by more than one open finding" or "closed but still under
'## Open'" warnings. `agent godot --script tools/findings_numbering_check.gd` is the standing
regression guard — source-scans `docs/FINDINGS.md` and fails if either shape reappears.

## F-058 · `docs/FINDINGS.md` carried two F-055s and two F-056s at once — concurrent lanes both used `agent brief`'s "next number"

**Claim:** `tools/findings_numbering_check.gd` (verify only — F-087 already wrote and shipped it;
nothing here needed a change).

**What was wrong:** `docs/` is deliberately unclaimed (F-006) so no lane blocks on it, which also
means two lanes filing in the same window can both read the same "highest number so far" off `agent
brief` and both append as the next id. lp filed F-055/F-056 during 2.11/2.13; flint5 separately filed
an unrelated F-055/F-056 during the three-platform LAN run. Both pairs landed in the doc with no git
conflict (plain text), so it was silent until someone read the numbers in order.

**Already fixed, by a later pass — read the surrounding text, not the number, to see why this one is
different from F-092/F-093/F-094:** this finding's own text is what named the risk, and the *routing*
half of it was fixed by **F-087**, which renumbered the *Open*-side collisions this same failure mode
produced next (F-058/F-059/F-060 each headed two unrelated findings, one Open, one Resolved) to
F-092/F-093/F-094. The F-055/F-056 pairs this finding was actually filed about are a different shape:
**every entry under both numbers is already `## Resolved`.** `_duplicate_findings()` (the live check
`agent board`/`start` run) and `tools/findings_numbering_check.gd` (the standing regression guard,
same rule) only flag a number shared by two **Open** entries, or an Open/Resolved split that could
make `board` hide a live bug as done — neither applies here, since nothing routes *to* a resolved
finding. **D-053** records the policy this generalizes to: a colliding number is renumbered only in a
dedicated cross-cutting pass, never inline, because doing it right means reading every citing file's
surrounding sentence to know which finding it meant (real collision risk against whoever holds those
files) — and a Resolved-only pair has no routing payoff to justify that cost. F-087's fix note says
so explicitly for this exact pair, and `findings_numbering_check.gd`'s docstring (Trap comments,
"Deliberately NOT checked") documents the same exclusion in code. Cosmetic dedup only: F-087 also
removed one literal double-paste of F-052 under Resolved.

**What this task closes:** the one piece F-087 didn't — F-058's own section was never moved, and its
text called for an audit of `agent sync`/`agent brief` under an ambiguous number that nobody had
actually run. Ran it: `agent brief F-055` (two Resolved entries share the number) reports `already
done` off `state.json`'s single merged entry and shows no finding text at all, let alone the wrong
one — there is no live-routing failure mode for a Resolved/Resolved pair to audit, confirming D-053's
reasoning rather than finding a new gap.

**Verified 2026-08-18 (lp):** `agent godot --script tools/findings_numbering_check.gd` →
`FINDINGS_NUMBERING_CHECK open=22 resolved=91 failures=0`, both traps PASS. `agent board` prints no
"F-number(s) used by more than one open finding" warning (only the unrelated F-036 human-gate
warning, tracked on its own). `agent brief F-055` behaves as described above. No production or tool
file needed a change; this block and the `docs/FINDINGS.md` move to `## Resolved` are the whole task.

## F-092 · `mire_art.mat()`'s cache never hits, so a generator that calls it in a loop mints a material per call

*Renumbered from F-058 (a different F-058 than the one immediately above — see F-087) on 2026-08-18.*

**Claim:** `tools/blender/mire_art.py` (verify only — the fix was already committed, in the same pass
that migrated the flora kit; nothing here needed a code change), `tools/blender/mat_cache_check.py`
(new — no focused check existed for this module before this task).

**What was wrong:** `mat()`'s cache guard read `if cached is not None and key in bpy.data.materials`.
`key` is a palette token (`"wood_bark"`); the datablock `mat()` creates is named `"MIRE_WoodBark"`.
Membership-testing the token string against `bpy.data.materials` — which is keyed by datablock name —
was therefore always False, so the cache dict populated but was never read back: every `mat()` call
minted another material. It hid behind how the four originally migrated generators happen to be
written — each hoists its `mat()` calls into a `mats = {...}` dict once per build, so each token is
only ever asked for once and a cache that never hits costs nothing observable. `mat("leaf")` called
from *inside* the loop that builds leaves — the natural way to write a generator, and the shape the
flora kit's `bracken_a` used — is what surfaced it: 22 near-identical `MIRE_Bracken.0NN` materials for
one token.

**Already fixed, before this task existed:** committed as part of `c0cced0` (the flora-kit build that
found it). The guard now tests the datablock itself, not the key —
`bpy.data.materials.get(cached.name) is cached`, wrapped in `try/except ReferenceError` so a cache
entry left dangling by a scene wipe (something removed the datablock without going through
`reset_materials()`) is silently rebuilt instead of crashing. `tools/blender/mire_art.py`'s own
`mat()` docstring/comment already narrates this; no kit needed a rebuild because none of the four
fully migrated kits ever exercised the broken cache path.

**What this task closes:** the fix had no regression guard and no `docs/SPECS.md` block. Wrote
`tools/blender/mat_cache_check.py` — runs under
`/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/mat_cache_check.py` (this module isn't Godot-reachable, so `agent godot` does not apply;
Blender background scripts are their own single-process run with no shared lock to race, unlike
`agent godot`'s import cache). It exercises the bug's exact repro shape — the same token requested 22
times from inside a loop, not hoisted into a dict — and asserts: one material minted, every call
returns the identical datablock; a second token mints its own material; a `suffix` variant is an
independent, itself-cached, entry; and a cache entry orphaned by removing its datablock out from under
`_MATERIAL_CACHE` is rebuilt rather than returned dangling or raised.

**Verified 2026-08-18 (lp):** `MAT_CACHE_CHECK PASS`, no failures, against HEAD. Regression-proved the
check itself by temporarily reverting `mat()`'s guard to the pre-fix `key in bpy.data.materials` line
and rerunning: `MAT_CACHE_CHECK FAIL (20)` — all 22 loop calls minted a distinct material and three
other assertions failed with it — then restored `mire_art.py` to its committed state (`git diff` clean)
and reran clean. No production file needed a change; this block, `mat_cache_check.py`, and the
`docs/FINDINGS.md` move to `## Resolved` are the whole task.

## F-094 · `mire_art.world_bounds` measured rotated objects through their local bounding box, so grounded assets float

*Renumbered from F-060 on 2026-08-18 (F-087) — that number collided with the original F-060 (two-process
net-check authoring traps, spec above). See F-087 for the full renumbering.*

**Claim:** `tools/blender/mire_art.py` (verify only — the fix was already committed, in the same pass
that migrated the flora kit and fixed F-092's material cache; nothing here needed a code change),
`tools/blender/world_bounds_check.py` (new — no focused check existed for this module's grounding
logic before this task).

**What was wrong:** `world_bounds()` transformed the eight corners of each object's `bound_box` through
`matrix_world`. `bound_box` is axis-aligned in the object's **local** space, so for any rotated object —
every cone `cylinder_between()`/`tapered_between()` produce is one — the transformed corners enclose a
volume strictly larger than the geometry inside it. `ground_and_centre()` then sat that inflated box on
z=0 and left the real mesh floating above it: up to 76 mm on the flora kit, and it would have shipped
calling itself grounded, because the only check available was made with the same wrong ruler. A cone
rotated straight off the world origin can hide the effect on its z-axis specifically (`to_track_quat("Z",
"Y")` keeps that cone's local X exactly horizontal, cancelling the corner-inflation on z alone) — the
float only shows once a second rotation composes on top, which is exactly the shape `fork()`'s branch
hierarchy has. The finding also reports `bound_box` staying stale immediately after
`bpy.ops.object.join()`, even through a depsgraph update, on the Blender version that found it — that
variant put a willow at 6.97 m tall and 800 mm underground.

**Already fixed, before this task existed:** committed as part of `c0cced0` (the same flora-kit build
that found and fixed F-092's material cache). `world_bounds()` now measures every mesh vertex through
`obj.matrix_world` directly, never `bound_box` — vertices are exact and never stale. Confirmed
`git diff tools/blender/mire_art.py` against HEAD is clean; no kit needed a rebuild for this task.

**What this task closes:** the fix had no regression guard and no `docs/SPECS.md` block. Wrote
`tools/blender/world_bounds_check.py` — runs under `/Applications/Blender.app/Contents/MacOS/Blender
--background --python tools/blender/world_bounds_check.py` (this module isn't Godot-reachable, so
`agent godot` does not apply; Blender's own background process is the whole run, same as F-092's
`mat_cache_check.py`). It (1) builds a `tapered_between()` cone rotated diagonally off every axis and
asserts the old bound_box-corners measurement, reconstructed inline in the check (never imported —
`mire_art.py` no longer has it), gives a strictly larger box than vertex measurement; (2) asserts
`world_bounds()` matches the true vertex extent exactly, not merely "smaller than the buggy box"; (3)
composes a second rotation onto a `tapered_between()` object (reproducing the parented-branch shape that
defeats the single-rotation z-axis cancellation) and asserts `ground_and_centre()` seats its real lowest
vertex at z=0; (4) asserts `world_bounds()` reads a `bpy.ops.object.join()`-merged mesh's true extent
immediately after the join.

**Verified 2026-08-18 (lp):** `WORLD_BOUNDS_CHECK PASS`, no failures, against HEAD. Regression-proved by
temporarily reverting `world_bounds()` to the pre-fix bound_box-corners measurement and rerunning:
`WORLD_BOUNDS_CHECK FAIL (4)` — the rotated-cone comparison, both exact-vertex-match assertions, and
`ground_and_centre()` (floated the composed-rotation object **101 mm** above z=0, the same scale as the
finding's 76 mm) all failed — then restored `mire_art.py` to its committed state (`git diff` clean) and
reran clean. **Note:** assertion (4)'s specific bound_box-after-join staleness could not be reproduced on
Blender 5.2.0 (this repo's pinned version) even with the buggy measurement — `bound_box` already reads
the merged geometry correctly immediately after `join()` here, no update call needed. Left in as a direct
ground-truth check of the documented failure shape rather than dropped, since `world_bounds()` measuring
vertices costs nothing extra and defends against a future Blender version regressing there. No production
file needed a change; this block, `world_bounds_check.py`, and the `docs/FINDINGS.md` move to
`## Resolved` are the whole task.

## F-108 · A Godot-side dimension check built on `Transform3D * AABB` reports every rotated asset as oversized

**Claim:** `tools/ship_check.gd` (verify only — the fix was already committed, in the same pass that
added the A-009 export batch; nothing here needed a code change), `tools/dimension_check.gd` (new —
no focused check existed for the vertex-vs-AABB measurement technique itself before this task).

**What was wrong:** `ship_check.gd` measured each export's size as `instance.transform *
instance.get_aabb()`, merged over the scene's mesh instances. `get_aabb()` returns a mesh's AABB in
its own local space; for any non-box mesh the corners of that box are not real geometry, and pushing
them through a rotation returns the box around the rotated box — strictly larger than the true
extent, and by more the more the part is turned. Every `cone`/`tapered_between` primitive in the
A-009 kit is built this way, so the inflated ruler reported seven of the fifteen exports as oversized:
all four hull states 50 mm long, the broken mast 72 mm, the debris cluster 38 mm, and the broken
mast's origin 23 mm low. This is F-094 (`mire_art.world_bounds` in Blender) on the engine side of the
fence, worth stating separately because the Blender fix does not travel — the two codebases learn it
independently.

**Already fixed, before this task existed:** committed alongside the A-009 export batch (`3beb6b0`).
`_check_asset()` now walks every mesh instance's `Mesh.ARRAY_VERTEX` array, transforms each vertex to
the scene root via `_transform_to_root()`, and bounds those points directly — vertices are exact and
never inflate under rotation. Confirmed `git diff tools/ship_check.gd` against HEAD is clean; no asset
needed a rebuild for this task.

**What this task closes:** the fix had no regression guard and no `docs/SPECS.md` block. Wrote
`tools/dimension_check.gd` — runs under `.agent/bin/agent godot --script tools/dimension_check.gd`. It
builds a synthetic cone (`CylinderMesh`, top radius 0, bottom radius 0.5, height 2) rotated 45° about
Z — its apex is a single point, so two of its local AABB's eight corners are empty space, the same
shape as the batch's cone primitives — and asserts (1) the naive `transform * get_aabb()` construction
this check exists to catch measures a hand-computed x-extent of ~2.1213, (2) the vertex-transform
method measures ~1.7678, and (3) the two must diverge by more than 100 mm, so a future edit that
reintroduces the naive construction in either method fails here before it ever misreads a real asset.

**Verified 2026-08-18 (lm):** `agent godot --script tools/dimension_check.gd` → `DIMENSION_CHECK
naive_x=2.1213 vertex_x=1.7678`, `DIMENSION_CHECK_GODOT PASS` — both figures land within 0.001 of the
hand-computed values, confirming the fixture itself is correct, not just internally consistent.
`agent godot --script tools/ship_check.gd` → `SHIP_CHECK_GODOT PASS`, all fifteen A-009 exports agree
with the catalog to the millimetre. Regression-proved the check's fix directly: temporarily reverted
`_check_asset()`'s vertex loop to `instance.transform * instance.get_aabb()` (no `to_root`, no
per-vertex walk) and reran — `SHIP_CHECK_GODOT FAIL (8)`, reporting the exact failure shape the
finding describes (`ship_debris_cluster` 35 mm long and off-centre, all three drift-linked hull states
+50 mm, `ship_mast` +34 mm across, `ship_mast_broken` +72 mm long and its origin 23 mm low) — then
`git checkout -- tools/ship_check.gd` restored the committed fix (`git diff` clean) and the PASS rerun
above confirmed it.

**Follow-up, not in this task's claim:** `tools/flora_check.gd:126` (`box = instance.transform * box`)
has the identical construction and is currently green only because its tolerance is 20 mm and it
compares height alone, where the error happens to stay under that. It belongs to A-000V's file set.
Filed as **F-122** — port the vertex measurement across using `ship_check.gd`'s `_check_asset()` as
the worked example, and expect the flora kit's reported heights to move slightly when it lands.

---

## F-122 · `tools/flora_check.gd`'s dimension check used the same inflated `Transform3D * AABB` ruler as F-108

**Claim:** `tools/flora_check.gd` only. No autoload, no `project.godot`, no `.tscn`/`.tres`.

**What was wrong:** same construction as F-108, in the sibling check for a different asset family.
`_check_asset()` measured each flora export's height as `instance.get_aabb()` pushed through
`instance.transform` and merged across mesh instances — an AABB is axis-aligned in the mesh's own
local space, so a rotated instance's box is the box around the rotated box, not the rotated geometry.
It read as passing only because the flora kit's tolerance is 20 mm and the check compares height
alone; F-108 already established this is not evidence the ruler is correct, only that the kit's
current rotations aren't steep enough to trip that threshold.

**Fix:** ported `ship_check.gd`'s `_check_asset()` vertex-measurement technique verbatim — added
`_transform_to_root()` (accumulates a `Node3D` chain's transform from a mesh instance up to the
imported scene's root, since `global_transform` is unavailable on a scene never added to the tree),
then replaced the AABB-transform with a per-surface walk of `Mesh.ARRAY_VERTEX`: each vertex is
carried to the scene root via `_transform_to_root()` and folded into a running min/max, which bounds
the real geometry directly instead of a local box.

**Verified 2026-08-18 (lm):** `agent godot --script tools/flora_check.gd` → `FLORA_IMPORT checked=84
triangles=30984`, `FLORA_CHECK_GODOT PASS` — all 84 flora exports agree with `catalog.json` to within
the 20 mm tolerance, measured against the corrected vertex-based numbers rather than assumed.
Regression-proved the change is real: temporarily reverted `_check_asset()` to the naive
`instance.transform * instance.get_aabb()` construction and reran — still `FLORA_CHECK_GODOT PASS`,
confirming the finding's own claim that this kit's rotations are currently mild enough that neither
ruler trips the tolerance. The vertex-based measurement is still the correct fix on principle (F-108's
rotated-cone case shows the naive construction inflates by tens of millimetres once a rotation is
steep enough, and nothing stops a future flora asset from being that steep) — this kit just hasn't
authored one yet. `git checkout -- tools/flora_check.gd` after the temporary revert, then re-ran to
confirm the restored fix is byte-identical to what's committed and still `PASS`.

No new regression guard was written here: `tools/dimension_check.gd` (added by F-108) already asserts
the vertex-vs-naive divergence on a synthetic rotated cone, independent of which check consumes the
technique — it is a guard on the *measurement method*, not on `ship_check.gd` specifically, so it
already covers a future regression in `flora_check.gd`'s copy of the same code shape.

## F-109 · The all-sides audit's inside-out test cannot judge an open sheet, and this is the first batch made of them

**Claim:** `tools/blender/audit_all_sides.py` (the fix), `tools/blender/audit_all_sides_check.py`
(new — no focused check existed for the inside-out metric before this task), `docs/FINDINGS.md`,
`docs/ASSET_TRACKER.md`.

**What was wrong:** `geometry_report()` detects inverted normals by the divergence theorem — sum
`(n . c) * area` over an object, positive when a *closed* shell faces outward. It ran every object
through this test with no guard on whether the object actually was a closed shell. A-009 is the first
batch built mostly of open surfaces — a hull is a planked shell, a sail a thin panel, a cap rail a
ribbon — and for those the sum has no enclosed volume to measure; it is dominated by where the sheet
sits relative to the world origin instead. A bottom-strake patch board with a correct downward normal
and a positive z centre scored negative and read as a defect; a genuinely inverted sheet on the far
side of the origin would score positive and read as fine. On the finished, verified A-009 set this
misread 96 correct `panel()`/`ribbon()` back, rim and underside faces on `ship_hull_repaired` alone
(94 on an earlier snapshot, per the finding) as "inside out" — a number that reads as a defect count
but is not one.

**Fix:** `is_closed_shell(bm)` welds vertices by position (the same rounding key the duplicate-vertex
count already used — these meshes are unwelded face soup, so bmesh's own `edge.is_manifold` reads
every edge as non-manifold regardless of whether the surface is a closed shell or a flat sheet) and
counts how many faces border each welded edge. A closed shell's every edge borders exactly two faces;
an open sheet has at least one boundary edge that borders only one. `geometry_report()` now runs the
signed-volume test only when `is_closed_shell()` is true, and files everything else under a new
`open_surface_objects` list instead of `inside_out_objects` — so the count a human reads as "defects"
no longer includes objects the test was never able to judge. An open sheet's actual winding is still
judged, just not by this audit: `WINDING_LOG` in `build_extraction_ship_set.py` is the worked example
a future sheet-built family should copy, per the finding and per `docs/ASSET_TRACKER.md`'s existing
"Sheet-built assets need their own winding proof" note.

**Verified 2026-08-18 (lm):**
- `/Applications/Blender.app/Contents/MacOS/Blender --background --python
  tools/blender/audit_all_sides_check.py` → `AUDIT_ALL_SIDES_CHECK PASS`. Six assertions: (1) a
  single downward-facing quad placed at z=+2 — the exact false-positive shape the finding
  describes — scores negative under the pre-fix naive sum (reimplemented inline, proving the old
  test really would have flagged it) but the fixed `geometry_report()` reports it as an
  `open_surface_object` and does NOT put it in `inside_out_objects`; (2) a correctly-wound closed
  cube is recognised by `is_closed_shell()` and is flagged neither way; (3) the same cube with every
  face reversed is still caught in `inside_out_objects` and NOT reported as an open surface — the fix
  changes what happens to open sheets, not the audit's ability to catch a real inversion.
  Regression-proved by reverting `tools/blender/audit_all_sides.py` to HEAD (`git stash`) and
  rerunning: the check fails on import (`is_closed_shell` does not exist pre-fix), confirming the
  guard is load-bearing; restored via `git stash pop`.
- Re-ran the real instrument against the shipped A-009 batch: `Blender --background --python
  tools/blender/audit_all_sides.py -- --only ships/exports --outdir <scratch>`. `inside_out_objects`
  is **0 across all fifteen exports** (down from 96 on `ship_hull_repaired` alone), and the 504
  sheet-back/rim/underside faces the old test misread now land in `open_surface_objects` instead. No
  asset needed a rebuild; this is a tooling-only fix.

## F-110 · `audit_all_sides.py` silently resumes, so a re-run after fixing an asset re-reports the old defect

**Claim:** `tools/blender/audit_all_sides.py` (the fix), `tools/blender/audit_all_sides_check.py`
(extended — F-109's guard already lived here; this task adds the mtime-staleness assertions,
no second focused-check file needed), `docs/FINDINGS.md`, `docs/SPECS.md` (this block).

**What was wrong:** the resume ledger (`geometry_report.jsonl`) is keyed on the asset's repo-relative
path, and a second run with the same `--outdir` skipped every path already present regardless of
whether the GLB at that path still matched what was recorded. AGENTS.md's own killability rule is the
right design — checkpoint per item, skip what's already done on resume — but "already in the ledger"
and "still current" are different claims, and the ledger conflated them. During A-009 this produced a
full contact-sheet report describing geometry that had already been fixed and re-exported minutes
earlier, including an inverted transom the rebuild had already corrected. Nothing warned; the run
just finished fast, because from the ledger's point of view every asset was already done.

**Fix:** every ledger entry now carries `_source_mtime`, the GLB's `os.stat().st_mtime` at the moment
it was rendered. `pending_glbs(glbs, assets_root, report)` — pulled out of `main()` into its own
function so it's directly testable without rendering anything — compares each on-disk GLB's *current*
mtime against the mtime its ledger entry (if any) was recorded under; a mismatch (no entry, or an
entry recorded under a different mtime) puts the asset back in the pending list. A re-export into the
same path therefore gets re-rendered on the very next run instead of being silently reused, and the
run prints which paths it's re-rendering and why (`"N asset(s) changed since their last audit;
re-rendering: ..."`) so the behaviour is visible, not just correct. mtime, not a content hash, per the
finding's own two options — cheap, no dependency added, and every asset in this pipeline is a fresh
Blender export whose mtime always moves on a real re-export; a hash would only earn its cost if some
future path rewrote a GLB byte-identically, which nothing here does.

**Build:** `pending_glbs()` takes plain `Path` objects and a `report` dict — no `bpy` in its own logic
— so the check exercises it against real temp files (mtime comparison needs a real filesystem, not a
mock) rather than real GLBs, keeping the regression guard fast and independent of the asset tree.

**Verified 2026-08-18 (lm):**
- `/Applications/Blender.app/Contents/MacOS/Blender --background --python
  tools/blender/audit_all_sides_check.py` → `AUDIT_ALL_SIDES_CHECK PASS`, F-109's six assertions plus
  seven new ones: an unrecorded asset is pending; an asset recorded with a matching mtime is skipped;
  an asset whose mtime moved since it was recorded is pending again and is the one reported as a
  stale re-render (not the unrecorded or unchanged ones); and a re-recorded entry round-trips its
  mtime exactly through JSON.
- Real end-to-end run against a shipped asset, scratch `--outdir`, `--only ship_departure_bell`:
  run 1 renders it; run 2 prints `resuming: 1 assets already done` / `nothing to do; every asset is
  already in the ledger and unchanged` and re-renders nothing; `touch`ing the GLB (mtime only, no
  content change — confirmed via `git status --porcelain` staying clean) and running again prints
  `1 asset(s) changed since their last audit; re-rendering: ships/exports/ship_departure_bell.glb`
  and re-renders exactly that one asset. Matches the finding's exact failure mode in reverse.

## F-093 · A headless `--script` run never re-imports changed assets, so a check can validate the previous build

*Renumbered from F-059 on 2026-08-18 (F-087) — that number collided with the original F-059
(`InventoryService`'s unguarded `rpc_id`, spec above). See F-087 for the full renumbering.*

**Claim:** `.agent/bin/agent` (the fix — `cmd_godot`'s import pre-pass), `tools/harness_check.py`
(the regression guard — no focused check existed for `cmd_godot`'s import behaviour before this
task, though the file already tested other `cmd_godot`/`ship`/`baseline` behaviours), `docs/FINDINGS.md`.

**What was wrong:** `cmd_godot` builds an argv and hands it straight to the engine. `--script`
(and any other non-`--import` invocation) loads whatever `.godot/imported/` already holds — Godot
only re-imports on an explicit `--import` pass or an editor scan, neither of which a `--script` run
performs. Measured on the flora kit: after rebuilding all 84 GLBs, three consecutive
`agent godot --script tools/flora_check.gd` runs reported the same stale triangle counts and
heights. `docs/ASSET_TRACKER.md`'s existing advice ("re-run to confirm") does not help — nothing on
disk changes between runs, so a check that read stale once reads stale forever, silently validating
art that no longer exists.

**Fix:** `cmd_godot` now runs a synchronous `<godot> --headless --path <ROOT> --import` pass before
the caller's own run, inside the same `file_lock("godot", ...)` acquisition — so the import and the
run it protects are atomic against another lane racing the shared cache (F-044), not two separate
lock windows. The pre-pass is skipped when the caller's own args already contain `--import` (an
explicit `agent godot --import` doesn't need to import twice), and its output is always relayed
(never swallowed) — both because a silent subprocess reads identically to a hung one (F-104) and
because that relay is the only signal an engine test double has to prove the pre-pass ran. A failed
pre-pass prints a warning and still runs the caller's command, rather than blocking it outright, since
an import failure orthogonal to the check being verified (e.g. one unrelated broken asset) shouldn't
make every other check unrunnable.

**Verify:** `python3 tools/harness_check.py` — two new cases against the existing `fake-godot` test
double (which echoes its own argv, the same mechanism the file already used for the `--windowed`
cases): `agent godot --script tools/x_check.gd` must invoke the engine **twice**, first with
`--import` and no `--script`, second with the caller's own `--script` args and no `--import`;
`agent godot --import` must invoke it exactly **once** (no doubled import). Regression-proved:
`python3 tools/harness_check.py --rev HEAD` (tests the new cases against the pre-fix committed
`.agent/bin/agent`) fails the new case with a single-invocation argv list, exactly the bug; the
working-tree run with the fix passes all 12 cases.

**Done means:** `python3 tools/harness_check.py` green (12/12), plus one real end-to-end run —
`agent godot --quit-after 5` — confirming the double invocation completes cleanly against the real
engine and the project still boots (content load, world gen, harvest wiring all logged normally,
exit 0). No focused `.gd` asset check was written for this task: the bug and the fix both live
entirely in the harness (`agent godot` itself), not in any one asset pipeline, so `tools/harness_check.py`
— the project's existing harness-regression file, same one F-081 used — is the correct and
sufficient home for its guard, not a new `tools/*_check.gd`.

## F-083 · Snapping the aim hit's Y coordinate rejects or floats pieces on ordinary terrain heights

`BuildGhost.update_aim()` (`systems/building/build_ghost.gd`) fed the surface hit from its aim ray
straight into `PlacementValidator.snap_transform()`, and `snap_transform()`
(`systems/building/placement_validator.gd`) rounded Y to the same metre grid as X/Z. The support
probe then began only `SUPPORT_PROBE_LIFT_M` (0.15 m) above that rounded origin. On flat ground at
Y=0.4 the rounded origin was Y=0, so the probe started inside the terrain and every ray read as a
miss → `Reason.NO_SUPPORT`; on ground at Y=0.6 the rounded origin was Y=1, so the piece read `OK`
floating 0.4 m above the real surface. Hollowmere's terrain is not restricted to whole-metre
elevations, so this broke ordinary ground placement across the shipped map, not an edge case.
**Claim:** `systems/building/placement_validator.gd`, `tools/build_check.gd`. **Fix:**
`snap_transform()` now snaps X and Z to `snap_step` as before but leaves Y untouched (**D-056**).
`origin.y` is never an arbitrary value needing rounding here — it is wherever the caller's physics
ray actually hit, so preserving it seats the piece flush with the real surface it was aimed at,
whether that surface is terrain or the top of an already-placed piece. That second case is why no
separate "stacked piece anchor" rule was needed to close the finding fully: a ray against an
existing piece already reports that piece's own exact top, so flush stacking falls out of the same
raycast for free. **A trap for whoever authors more building content (3.7) or reads `wall.tres`'s
doc comment about "a run of them actually lin[ing] up":** that guarantee is X/Z only now — a run of
walls built across sloped or uneven ground will not share a Y any more than the ground itself does;
see D-056 for what would change that (an explicit level/anchor rule is new scope, not a defect).
**Shipped 2026-08-18.** Verify with `agent godot --script tools/build_check.gd`
(`_check_ground_height_is_preserved` reproduces the review's exact `GROUND_0_4`/`GROUND_0_6` probes
against isolated flat pads and asserts both read `OK` with Y unchanged; `_check_ghost` adds an
end-to-end case — `BuildGhost.update_aim()` aimed straight down at a y=0.4 pad keeps the ghost at
0.4, not 0 — since the finding named that exact call chain, not just `snap_transform()` in
isolation). `failures=0`, reran twice. `tools/build_net_check.gd` (13 assertions, two real ENet
processes) also `failures=0`, unaffected — its scenarios never place on non-integer ground.

## F-086 · The building system has no gameplay caller, so no player can place, rotate, or destroy anything

3.6 shipped `BuildGhost`/`BuildService`/`PlacementValidator` with no production caller — every API
(`update_aim()`, `rotate_step()`, `confirm()`, `BuildService.request_destroy()`) was reachable only
from `tools/build_check.gd`'s own private ghost, so the entire feature was unreachable in a real
session. **Claim:** `entities/player/player_controller.gd`, `systems/building/build_ghost.gd`,
`ui/building/build_bar.gd` (new), `tools/build_check.gd`. **Fix:** both `BuildGhost` and a new
`BuildBar` (a piece-picker + status bar, same visual family as `CraftingUI`/`InventoryUI`) are built
directly by `player_controller.gd` in `_ready()` for the local player only — **not** autoloads,
because `project.godot` was held by another lane's task (F-095) when this shipped and because both
are strictly per-local-player presentation regardless (**D-058**). The existing "build" InputMap
action (3.6) toggles the mode; `is_build_mode_active()` reads `BuildGhost.visible` directly rather
than a second flag. Piece rotate (`R`) and destroy (right-click) are raw input, not new InputMap
actions — `ui/hud/vitals_hud.gd`'s EAT_KEY precedent, for the same "project.godot is locked" reason.
Confirm reuses the existing "attack" action, checked for build mode FIRST, in the same function,
before the existing combat routing, so a click can never both swing and place regardless of node
traversal order. `BuildGhost` gained `aim_destroy_target()`, a SECOND ray independent of whichever
piece is selected to place, so destroy targets whatever is aimed at regardless of the current
placement selection. **F-101 filed, not fixed here:** build-mode confirm and
`autoload/harvest_world.gd`'s own independent "attack" listener are not mediated against each
other — the fix touches a file outside this task's claim.
**Shipped 2026-08-18** (`docs/FINDINGS.md` Resolved has the full verification). Re-verify with
`agent godot --script tools/build_check.gd` — `_check_player_integration()` drives a real
`entities/player/player.tscn` through the exact input events a player sends (the real "build"
action, a real `BuildBar` slot click, a real `R` keypress, the real "attack" action, a real
right-click), proving the wiring rather than constructing a private ghost. `failures=0`.
`tools/build_net_check.gd` `failures=0`, unaffected.

## F-037 · `net_debug_panel_check` fakes its second peer in-process, so host and client share one tree

**Claim:** `tools/net_debug_panel_check.gd`. No production file — the bug was entirely in the check's
own scaffolding (`ui/debug/net_debug_panel.gd` is unchanged and correct).

The old `_check_real_session()` built a second `MultiplayerAPI` in the same process, `root_path`
pointed at `/root` per F-021's fix so autoload-addressed RPCs would resolve — but `/root` is the
host's tree too, so when `PlayerNet` spawned a body for the fake peer, `MultiplayerSpawner` replicated
it right back into the same container under a name already taken:
`ERROR: Condition "parent->has_node(name)" is true.` Harmless (the panel's RTT/bandwidth/peer-list
numbers were all correct) but it was the one thing between this harness and a genuinely clean run.

**Fix:** real second process, the shape every other `tools/*_net_check.gd` uses (docs/SPECS.md's
"Two-process checks" seam, `tools/inventory_net_check.gd` copied almost verbatim). No args ⇒ driver:
hosts via `NetTransport`, spawns itself again with `OS.create_process` and a trailing `-- panel-probe`
argument, waits for the peer to join, then reads its own `NetDebugPanel` instance's readouts off the
real connection. `panel-probe` arg ⇒ the child: joins, waits on a ready gate, writes its own readouts
to `user://net_debug_panel_client.json`, and the driver asserts both sides independently. Each process
gets its own real tree, so there is no shared-name collision to trigger the error in the first place.
The boot/registration/offline-readouts/event-log-ring-buffer sections above it are unchanged — they
never touched networking.

Ready gate follows F-060's rule rather than reintroducing its trap: `is_active() and
local_peer_id() > NetConfig.HOST_PEER_ID`, `is_active()` on the same line as the `local_peer_id()`
read, not a separate check somewhere else that could be dropped later.

**Verified 2026-08-18:** `agent godot --script tools/net_debug_panel_check.gd`, twice back to back —
`0 failure(s)` both runs, `0` lines matching `ERROR:` in either (no `EXPECTED_ERROR_PATTERNS`
allowance needed — the whole point was getting to zero, not declaring an allowance). `agent godot
--script tools/net_check_pattern_check.gd` stays clean with the new file included in its scan
(`gate_reads=9`, `failures=0`) — confirms the ready gate is recognised as correctly guarded, not
missed by the scanner.

## F-038 · `inventory_net_check`'s grant timeout, and `combat_net_check`'s sibling flake, both wait-ordering races in the harness

**Claim:** `tools/inventory_net_check.gd`, `tools/combat_net_check.gd`. No production file — both
roots live entirely in the checks (**D-059** has the full mechanism for each).

**(1) The grant race, both checks.** The driver granted (`EVENT_BUS.emit_harvest_yielded` /
`inventory.host_add`) as soon as the CLIENT self-reported "connected," which can precede the HOST's
`InventoryService` creating that peer's store — `_publish_snapshot()`'s `rpc_id` send is one-shot and
gated on `_peer_connected()`, so a grant landing in that window never reaches the client and the wait
times out at `TIMEOUT_SEC`. **Fix:** poll `(inventory.call("host_slots", peer_id) as Array).size() ==
32` before granting, in both checks — `host_slots()` reads `[]` before the store exists, a real
32-entry array after, so this is a poll of the actual precondition rather than `host_count() == 0`,
which reads identically for "no store yet" and "store exists and is empty" and proved nothing.

**(2) `combat_net_check`'s own flake, found retesting both checks together per the finding's own
request.** Unrelated to (1) — reproduces with (1)'s fix already applied. `TestTarget` trails an
unfloored, permanently-falling player two metres along its forward; by the check's *second* swing the
player's fall speed has grown enough that `TestTarget._process()`'s one-frame-stale copy of
`follow.global_position` can clear the swung weapon's `vertical_reach_m` — an intermittent miss with
nothing wrong in `CombatService`. **Fix:** `_build_ground()`, same shape as
`tools/build_net_check.gd`'s, built in both processes (a floor only one side has is its own desync)
before the driver/client branch. Removes the unbounded fall instead of loosening any reach tolerance.

**Verified 2026-08-18:** `agent godot --script tools/net_check_pattern_check.gd` clean (no F-060
trap reintroduced). Two full back-to-back sequences of
`inventory_net_check`/`harvestable_net_check`/`crafting_net_check`/`combat_net_check` (the original
repro shape), `failures=0` and 0 undeclared `ERROR:` lines every check, every pass.
`combat_net_check` alone: 8 consecutive runs post-fix, `missed_count: 0` every time, against a
baseline that reproduced a miss within 2–6 runs pre-fix. `inventory_net_check` alone: 3 consecutive
runs, `failures=0`.

## F-042 · Rendered PNGs can never be byte-identical, so every rebuild reads as a broken one

**Claim:** none — closed by habit + a tool. No production file; this is asset-pipeline tooling, not a
runtime system, so it declares no `ARCHITECTURE.md` §2.2 authority row.

Blender stamps non-deterministic metadata into every PNG it renders — `RenderTime`/`Date` `tEXt`
chunks from EEVEE, `cycles.ViewLayer.total_time` from Cycles — so two renders of unchanged geometry
are never byte-identical even when every pixel matches. A-021S hit this for real: adding one icon to
`render_item_icons.py` re-rendered all 24 existing ones, `git status` reported 24 modified, and
decompressing `IDAT` showed 0 pixels changed — a false alarm that costs a whole session chasing a bug
that doesn't exist, or worse, gets committed as 24 meaningless binary diffs.

**Fix:** two parts, both already in the repo before this task started.
1. **Habit**, in `docs/ASSET_TRACKER.md`'s verification contract: compare rendered PNGs by decoded
   pixels, never file hash or raw `git status`.
2. **Tool**, `tools/png_pixels_equal.py` — built by F-079 (which, along the way, fixed a real trap in
   the naive `ImageChops.difference().getbbox()` one-liner on opaque RGBA images). `images_pixel_equal(a,
   b)` / the CLI is the concrete thing to run instead of decompressing `IDAT` by hand.

**Verified 2026-08-18 by lp**, against the live pipeline rather than only F-079's synthetic unit test:
re-ran `Blender --background --python tools/blender/render_item_icons.py` unchanged (26 icons at the
current `SOURCES` count — grew from 24 since this finding was filed). `item_icons_sheet.png` hashed
identical; all 26 individual `assets/icons/exports/*.png` came back file-modified per `git status`,
reproducing the exact original false alarm. `tools/png_pixels_equal.py` against each file's HEAD copy:
26/26 `identical`, 0 real changes. Working tree restored (`git checkout -- assets/icons/exports/`)
rather than committing the churn, per the contract. `python3 tools/png_pixels_equal_check.py` still
green. `docs/ASSET_TRACKER.md`'s contract now names the tool directly instead of describing manual
`IDAT` decompression.

The second-order EEVEE anti-aliasing jitter on thin diagonal silhouettes (A-021S's viewmodel preview:
9 bytes different in 4,992,780, max delta 3/255) stays as documented, accepted noise floor — Cycles
(used for shipped icons) doesn't have it, and `png_pixels_equal.py` does exact comparison with no
tolerance, so a preview still rendered in EEVEE can flag this as a real diff. Nothing to fix: it's a
known false-positive shape now written into the contract, not a determinism bug.

## F-079 · The obvious way to "compare decoded pixels" silently reports every RGB-only change as identical

**Claim:** `tools/png_pixels_equal.py`, `tools/png_pixels_equal_check.py`. No production file — this
is asset-pipeline tooling, not a runtime system, so it declares no `ARCHITECTURE.md` §2.2 authority
row (nothing here runs in-game or over the network).

`ImageChops.difference(a, b).getbbox()`, the obvious way to compare two decoded PNGs, is wrong for
RGBA input: Pillow >= 9.2 defaults `Image.getbbox()` to `alpha_only=True`, so a difference image's
alpha channel — zero wherever both inputs are equally opaque — is all the bbox is computed from. A
change that moves only colour on an opaque image (`item_icons_sheet.png`'s shape) reads as
"identical." It cost F-073's task a re-render of both axe cells, reverted as byte-only churn, twice.

**Fix:** `tools/png_pixels_equal.py` — `pixel_diff_bbox(a, b)` diffs each `Image.split()` band on its
own and unions the boxes (a single-band image has no alpha to default to, so the trap has nothing to
key off); `images_pixel_equal(a, b)` wraps it as a bool. Also runnable directly as a CLI
(`python3 tools/png_pixels_equal.py a.png b.png`) for ad hoc use outside a batch script. Handles
differing canvas size (reports a full-canvas box rather than raising) and RGB-vs-RGBA of the same
colour (normalizes mode before `split()` rather than raising on a band-count mismatch).

**Verified:** `python3 tools/png_pixels_equal_check.py` → `PNG_PIXELS_EQUAL_CHECK ok`. Reproduces the
exact regression — one RGB-only pixel changed on an otherwise-opaque RGBA image — and asserts the
tool reports the correct 1×1 bbox; also covers an alpha-only change (already worked, must keep
working), identical pixels under different `tEXt` metadata (F-042's case — must read identical), a
self-compare, a size mismatch, and RGB-vs-RGBA of the same colour. No Godot involved: this is a
pure-Python tool bug, so — same precedent as `tools/harness_check.py` (F-081) and `agent baseline`
(F-080) — the check is plain Python run directly, not a `tools/*_check.gd` through `agent godot`.

## 3.8 · Hunger/health/stamina (T1) — **GATE: 2.13 shipped (PlayerHealth exists).**

Extends `PlayerHealth` rather than a new service: hunger drains on host tick, empty hunger drains
hp; stamina is **client-local for responsiveness** (sprint/jump/dodge gating happens on the owning
client — movement is client-auth) with periodic host reconciliation to keep HUD honest. Food =
consumable items whose use is a host request consuming via `host_transaction` and applying via
PlayerHealth. Claim the health files, `ui/hud/vitals_hud.gd`, checks.

## 3.8b · Dodge (T1) — **GATE: 3.8's stamina.**

Client-auth own movement (§2.2 row 1): a stamina-costed dash impulse with i-frames **against enemy
melee only** (host checks a `dodging` flag the player's synchronizer already carries before applying
`enemy_attack_landed` damage — the flag is replicated state, the i-frame decision is host's).
Exports: cost, impulse, duration, cooldown. Void Resonance's "dodge blinks" (§4.4) hooks this verb
later — keep the dash a function (`_execute_dodge`) a powerup can wrap, not inline input code.

## 3.9 · Attunement system + UI (T2)

Selection at run start (UI in the D-032 group), one of four roles (DESIGN §4.5), HOST-recorded per
run-player (D-035), broadcast to all. Effects are PowerupService modifiers granted at selection —
attunement is *data over 3.3*, zero new stat plumbing. Locked after selection; respec is out of
scope (parking lot). Check: selection replicates, modifiers apply, second selection refused.

## 3.10 · Heavy hauling (T1)

Host-owned carryable object (spawner-replicated body): request_pickup/request_drop host-validated;
while carried by two players it follows the midpoint at full speed; **solo = slow drag** (DESIGN §5
solo rule — one carrier moves at `solo_drag_multiplier` ~0.4). Movement of carriers stays
client-auth; the OBJECT is host-positioned from the carriers' replicated positions. Check covers
solo and duo math offline; net check proves a client cannot teleport the object.

## 3.11 · Playtest (T0) — Q4: roles or resentment. Same protocol as 2.14; ask specifically whether
anyone felt forced into an Attunement. Update DESIGN §8.

## 3.12 · Balance pass (T0) — inspector numbers only; re-run `combat_feel_check` and record the
before/after table in the close-out.

## 3.13 · Command core (T2) — **read `docs/COMMANDS.md` §1–2 first; it is the spec, this block is the claim sheet**

**Exempt from the M3 gate** (recorded in ROADMAP's M3 note — encodes no design answers, helps run
2.14 itself). **Claim:** `autoload/command_service.gd` (new), `autoload/debug_console.gd`,
`core/dev/dev_loadout.gd`, `autoload/enemy_world.gd` (its console registrations — grep
`register(` for any others and claim them too), `core/net/net_version.gd`,
`tools/handshake_check.gd`, `tools/command_check.gd`, `tools/command_net_check.gd`.
Registration via `agent autoload CommandService autoload/command_service.gd` — order it right
after `DebugConsole` so every later autoload can register specs in `_ready()`.
- `CommandSpec` (typed args per COMMANDS.md §2.2), `CommandResult {ok, message, data}`,
  `CommandCtx {peer, source, position}`. `Scope.LOCAL` runs where typed; `Scope.HOST` executes on
  the host — client submission via new reliable `net_submit_command(line)` /
  `net_command_result(...)` pair, **host re-parses the raw line from scratch**. Protocol bump +
  `handshake_check` literal, same commit.
- Op set: host always op; `op`/`deop` restricted to the host peer; keyed by run-player token
  (D-035) so ops survive the grace window. Non-op HOST submission → structured refusal.
- Migrate every existing registration to specs (console builtins, DevLoadout's
  give/loadout/items, EnemyWorld's spawn/killall/enemies); the old `register()` stays as a
  deprecation-warning shim. `give` keeps its exact output strings where checks read them.
- Add the §2.2 authority-table row to `ARCHITECTURE.md` (text in COMMANDS.md §1.2); file the
  D-numbers for COMMANDS.md §9 items 1–2.
- Checks: `tools/command_check.gd` offline (parse/validate/usage errors, scope routing, op
  refusal, `commands --json` dump); `tools/command_net_check.gd` two real ENet processes (client
  `give` lands via host and returns a result; non-op refused; **console open + tree paused while
  the RPC round-trips** — the wrinkle at the end of COMMANDS.md §10).

## 3.14 · Gamerules (T2) — COMMANDS.md §4. **GATE: 3.13.**

**Claim:** `systems/rules/rule_def.gd` (new), `autoload/rule_service.gd` (new),
`autoload/registry.gd`, `content/rules/` (worked examples for the §4.3 table only — the family is
then Sequoyah's, D-006), `systems/environment/day_night.gd`, `autoload/enemy_world.gd`,
`systems/waves/wave_spawner.gd`, `systems/health/player_health.gd`, `core/dev/dev_loadout.gd`,
`core/net/net_version.gd`, `tools/handshake_check.gd`, `tools/rules_check.gd`,
`tools/rules_net_check.gd`. Registration via `agent autoload`.
- `RuleDef` per §4.1; `Registry._load_rules()` with the same duplicate/validation/boot-count
  discipline as the other families. `RuleService` HOST-authoritative: broadcast on change,
  snapshot on peer join, `value()/value_bool()/value_int()` + `rule_changed` signal.
- **Export-fallback pattern per knob** (§4.3): the `@export` stays as default; the system reads
  the rule only when its RuleDef exists. Defaults byte-identical to today — this task changes no
  tuning.
- `rule <id> [value]` (HOST to set, clamped to min/max), `rules` (LOCAL list). File §9 item 3.
- Checks: offline (defaults, clamp, fallback-when-no-def, each migrated system reads a changed
  rule); net (client sets via command → both peers read the new value; joiner snapshot).

## 3.15 · EntityDirectory + selectors (T2) — COMMANDS.md §3. **GATE: 3.13.**

**Claim:** `core/entity/entity_directory.gd` (new), `autoload/command_service.gd` (selector arg
type), `autoload/player_net.gd`, `autoload/enemy_world.gd`, `autoload/harvest_world.gd`,
`autoload/build_service.gd`, `systems/loot/chest.gd`, `tools/entity_directory_check.gd`,
`tools/selector_net_check.gd`, plus `systems/health/player_health.gd` if `tp` reuses its
place-yourself RPC (bump + handshake if any new RPC). Registration via `agent autoload`.
- Host-side registry, unreplicated (v1): `<kind>:<serial>` ids, NodePath, tags. Register at the
  seams named in §3.1; unregister on despawn — the check asserts no leaks after kill/despawn.
- Selector grammar per §3.2; a dedicated `RandomNumberGenerator` for `@r`/`sort=random`.
- Verbs: `entities`, `tag <sel> add|remove|list`, `kill <sel>` (players via
  `PlayerHealth.host_apply_damage`, enemies via their damage path — never a second mutation
  path), `tp <sel> <vec3|sel>` (enemies directly; players only via their own client, §3.3).
  File §9 item 4.

## 3.16 · Command catalog sweep (T1) — COMMANDS.md §7. **GATE: 3.13 (+3.15 for selector verbs).**

**Claim:** `autoload/command_service.gd` plus the owning service file per verb wired (derive the
exact set from §7 at claim time), `autoload/steam_lobby.gd`, `tools/command_coverage_check.gd`.
- Every §7 row lands as a spec wrapping the named existing seam; where a row says *(new seam)*,
  add the host method to the owning service first, command second.
- `lobby host/join/invite` over `SteamLobby.host_session()/join_by_id()/open_invite_overlay()` —
  close the loop with D-030 by noting in FINDINGS/NEXT that the cheap cross-play test now exists.
- `tools/command_coverage_check.gd`: asserts every §7 verb is present in `commands --json` and
  every HOST-scope command refuses a non-op. A missing verb is a red check, not a review comment.

## 3.17 · Functions, hooks, runner (T1) — COMMANDS.md §5–6. **GATE: 3.13.**

**Claim:** `systems/rules/hook_def.gd` (new), function loading inside
`autoload/command_service.gd` (or `systems/commands/function_runner.gd` if it wants its own
file), `content/functions/` + `content/hooks/` (ONE worked example each: `night_siege`,
disabled-by-default per §5.2), `autoload/registry.gd` (hook loading), `tools/run_commands.gd`,
`tools/function_check.gd`.
- `.mcmd` format per §5.1 (`#` comments, recursion cap 4, effective scope = max of lines).
  `function <name>` command; `user://autoexec.mcmd` + `content/functions/autoexec.mcmd` at boot,
  host/offline only.
- `tools/run_commands.gd` per §6: `--file`, `--json`, `# expect-fail`, non-zero exit on failure;
  F-016 preloads. Prove it by porting ONE existing check's setup to a command file as the worked
  example (do not port the suite — that is opportunistic, later, per-check).
- File §9 item 5. Checks: function parse/run/recursion-cap offline; a hook firing on a real
  `DayNight.host_advance()` dusk crossing (the 2.12 pattern — drive the real clock, not the
  signal).

---

# M4 — world & the Mire

**GATE for the whole milestone: 4.0a measured.** (4.0b is DONE — D-028.)
**Milestone-wide rules:** world gen uses ONLY the §7 safe set (seeded `RandomNumberGenerator`,
FastNoiseLite simplex/perlin, `+−×÷`, `sqrt`, comparisons; **no transcendentals** — D-017). Every
subsystem gets its own named seed derived from the run seed. Nothing in world gen reads wall-clock
or `randi()`.

## 4.0a · Spike R2b (T2): cook `ConcavePolygonShape3D` + GPU upload per chunk on a real renderer
(not headless — F-005). Measure ms/chunk for collision cooking, mesh upload, material bind at the
1.5 m voxel scale R2 used; publish a per-frame chunk budget (how many chunks fit in 4 ms). The
number goes in DECISIONS as the 4.3 design input. **Everything else in M4 waits for this.**

## 4.1 · Seeded island heightmap (T2)
`world/gen/island_heightmap.gd`: layered simplex + radial falloff via safe ops; pure function
`height(x, z, seed) -> float`, deterministic, no nodes. Check: hash a fixed sample grid, assert it
matches a recorded value on every platform (extend `check_determinism.gd`'s pattern with a
`terrain_hash` — this becomes the cross-platform terrain probe).

## 4.2 · Biome assignment (T2)
`BiomeDef` `.tres` family (`content/biomes/` exists, empty, loaderless — give Registry the loader);
biome = f(height, moisture-noise) via safe ops. Worked example: 3 biomes. Sequoyah authors the rest.

## 4.3 · Chunk streaming + LOD (T2) — **GATE: 4.0a's budget.**
`WorkerThreadPool` generates mesh data off-thread; main thread uploads within 4.0a's per-frame
budget; ring-buffer around players; hysteresis on load/unload radii (D-025's lesson). Collision
cooks lazily (nearest ring only). This is the hardest task in M4 — the spec's acceptance is
"walk 500 m in a straight line at sprint speed with zero hitches over 16 ms on the test Mac".

## 4.4 · Resource scatter (T2)
Per-biome scatter tables (`.tres`), seeded Poisson/jittered-grid per chunk, `MultiMeshInstance3D`
for visuals + harvestable proxies activating on proximity (a full `Harvestable` node per tree at
island scale will not survive; the proxy pattern — visual in the multimesh, node materialized when a
player is near — is the design).

## 4.5 · Runtime nav baking per chunk (T2)
R3 said runtime baking stays (D-016). Bake per chunk on its own thread at generation, stitch via
NavigationServer regions; enemies far from players don't need nav (interest — despawn or dormant).

## 4.6 · Seed replication + client regen + delta sync (T2)
Host sends run seed in the session hello (protocol bump); clients regenerate terrain locally
(identical by D-017/D-028); every *mutation* (harvest depletion, building, Mire) replicates as
deltas keyed by chunk — `ARCHITECTURE.md` §4 is the design, this task is its first real payload.
Late joiner gets seed + compressed delta log. Two-process check: client-regenerated `terrain_hash`
equals host's; a mid-run mutation reaches a late joiner.

## 4.7 · POI placement (T2) — seeded Poisson-disc over the island, min-distance constraints,
Wellsprings + landmarks; deterministic from seed (same check pattern as 4.1).

## 4.8 · Wellspring scene + capture ritual (T1) — interact-driven channel with 2-player requirement
and **solo fallback: one player, longer timer** (DESIGN §5); host-owned ritual state machine;
defense wave via 2.12's spawner given a position override. A-008 assets exist.

## 4.9 · Mire grid simulation + delta replication (T2)
`ARCHITECTURE.md` §5 verbatim: host-only cell grid ticking spread on a timer, corruption levels per
cell, delta broadcast (changed cells only, quantized), client applies to visuals. Seeded spread.
This is the signature system — its check asserts determinism of spread for a fixed seed AND that a
client never simulates (negative assertions, `enemy_net_check` style).

## 4.10 · Mire visuals (T0) — shader tint by corruption, fog volumes, particles, audio shift.
## 4.11 · Mire ↔ world interaction (T1) — rotted resource yields, Blight debuff via PlayerHealth,
corrupted spawn tables for the wave director, Ward posts (3.6's `ward_radius_m`) suppress spread in
radius — each one is a small consumer of an existing seam; no new authority anywhere.
## 4.12 · Playtest (T0) — Q1/Q2 go/no-go on the Mire. The protocol from 2.14; specifically: did
anyone route AROUND the Mire on purpose, and did anyone have fun IN it.

---

# M5 — combat, enemies & bosses

**GATE: 2.9 passed (the never-cut rule: no second weapon before one feels great) and M3's
frameworks.** Content-heavy: agents ship frameworks + one worked example each; enemies/bosses/
movesets are then T0 authoring + A-023..A-026 asset batches (tracker gates align).

- **5.1 AI framework (T2):** generalize `Enemy` into `systems/enemies/enemy_brain.gd` states
  (perception with aggro hysteresis — D-025's lesson applies to senses too; telegraphed attacks
  with tell/commit data from the def; flee/pack flags). The crawler becomes worked example #1
  re-expressed in the framework with **zero behavior change** (its check must still pass verbatim —
  that is the refactor's acceptance).
- **5.2 Enemy types (T0+A-023/24/25):** stats/tells in `.tres`, models via the tracker.
- **5.3 Ranged combat (T2):** bow = client-predicted tracer, host-simulated projectile from the
  shooter's replicated yaw/pitch at fire tick (D-034's split applied to projectiles); arrows are
  inventory items consumed by `host_transaction`; hit applies through `&"damageable"`.
- **5.4 Movesets (T0/T1):** per-fork `WeaponDef` extensions (combo windows, alt-attack flag) —
  data first, one T1 task for the combo state machine, then T0 tuning.
- **5.5 Boss framework (T2):** phases as an array of `BossPhaseDef` (hp threshold, moveset id,
  arena flags), health bar UI seam, music stinger hook via EventBus.
- **5.6/5.7/5.8 Bosses (T0 over 5.5):** Wellspring guardian scales with Cycle; Hunt elite spawned
  by modifier 6.2; deep-Cycle threat gated Cycle 7+.
- **5.9 Wave director (T1):** 2.12's spawner gains composition tables (per-Cycle enemy pools,
  weights) — the file already has the seams; this is its planned growth, not a rewrite.
- **5.10 Balance (T0):** across the Cycle curve, not at one difficulty; record tables.

---

# M6 — cycles, extraction & meta

**GATE: M4's world (extraction ship is a POI; Cycle escalation reads the Mire).**

- **6.1 Cycle state machine (T2):** `core/game_state.gd` autoload — `ARCHITECTURE.md` §3 already
  reserves it (act, day, seed, run status, HOST-auth). Cycle advances on Wellspring/extraction
  events, escalates Mire spread rate + wave director pools, announces via EventBus. 2.11's DayNight
  feeds it days; it does not own time.
- **6.2 Modifier framework (T2):** `CycleModifierDef` (`id`, `weight_by_cycle`, `incompatible_with:
  Array[StringName]`, effect hooks over PowerupService/wave tables/Mire rates). Host draws seeded
  at each Cycle boundary; broadcast; UI announce. **Never-cut item.**
- **6.3 Author 20–30 modifiers (T0).**
- **6.4 Re-corruption (T1):** captured Wellsprings decay on a host timer unless Warded — a consumer
  of 4.9 + 3.6's fields.
- **6.5 Extraction (T2):** shipwreck POI (A-009 assets), staged repair via recipes (3.1's timed
  crafts), board-to-leave with group confirm UI (all-aboard-or-cancel flow, host-arbitrated,
  60 s window). **Never-cut item.**
- **6.6 Salvage & persistence (T2):** superlinear Salvage curve on extraction, split on death;
  local per-player save `user://salvage.json` with an explicit `schema_version: 1` and a migration
  switch from day one — versioning is this task's real deliverable. Runs stay unsaved (D-010).
- **6.7 Lose condition (T1):** team wipe (all dead with zero bleed-out revives pending) or island
  consumed ⇒ defeat flow through GameState; solo death already respawns until then (2.13's rule).
- **6.8 Run summary (T0):** headline Cycle number; stats GameState already accumulated.
- **6.9 Unlock tree (T1):** Salvage spends into **variety only, never power** (D-009/DESIGN §4.6 —
  refuse any stat unlock in review); data-driven nodes, local persistence beside 6.6's file.
- **6.10 Main menu + lobby UI (T0 shell + T1 wiring):** `SteamLobby.host_session()`,
  `join_by_id()`, `open_invite_overlay()` already exist and are proven — this is UI over live seams,
  plus seed entry feeding 4.6. **Unblocks the deferred 1.12 evidence run (D-030) — schedule it
  immediately after.**
- **6.11 Long playtests (T0):** Q3 (the wall), Q6 (does anyone extract), Q7 (deep-modifier
  fairness). Protocol per 2.14; multiple evenings.

---

# M7 / M8 — polish & ship (T0-heavy; agent tasks called out)

M7 agent tasks, spec'd when their milestone opens (each is self-contained): **7.5 settings**
(`user://settings.cfg` via ConfigFile: graphics/audio/sensitivity/keybinds/FOV + accessibility
basics; a `SettingsService` autoload applying on boot); **7.6 gamepad** (input map additions +
UI focus-neighbor audit + Steam Input glyphs); **7.7 performance** (profile → LOD/draw-call passes;
target 60 fps mid-range on the physical Windows PC from D-028); **7.8 network robustness**
(packet-loss/latency injection knobs in `NetTransport`, hostile-disconnect timing matrix — extends
`session_lifecycle_check`). The rest of M7 is Sequoyah's craft (audio/music/VFX/UI polish/bug bash/
exports 7.11 with per-platform Steam redistributables + case-sensitivity audit, 7.12 real-OS tests).

M8 follows `STEAM.md`'s S-steps in order, starting at **8.0 name search (blocking)**. Agent tasks:
8.3 achievements/stats/rich presence over GodotSteam; 8.4 depot/build pipeline (`steamcmd` upload
script, branches); 8.11 three depots wired to one app. Everything else is accounts, store assets,
review, and the mandatory Coming-Soon clock — human, sequenced, checklisted in STEAM.md.

---

## F-117 · F-072's docs-file claim enforcement blocks the second lane's commit, but the first lane's `ship` still sweeps the second lane's uncommitted edits into its own commit

**Claim:** `.agent/bin/agent`, `tools/harness_check.py`. No production/runtime file — this is
coordination tooling, not a networked system, so it declares no `ARCHITECTURE.md` §2.2 authority row.

**Root cause:** F-072 enforces an exact claim on a `docs/` path once one exists, but `docs/FINDINGS.md`
and `docs/SPECS.md` are exempt from needing a claim to *write* (F-006) — only to *commit*. Two lanes
closing out different findings in the same shared working directory (F-102: one working tree, not
worktrees per lane) routinely both edit both files in the same window. `ship` stages the files a
task's claim named by reading their **current working-tree bytes**, not a per-task diff, so if lane A
finishes with `docs/FINDINGS.md` (`done()`) and lane B edits the same file before lane A calls
`ship()`, lane A's `ship` silently carries lane B's prose into lane A's commit. Not data loss — the
content lands intact — but misattribution: the commit claims authorship it doesn't have.

**Fix:** `_release()` (fires on `done`/`handoff`/`drop`) now snapshots a sha256 of each released
file's bytes into `st["recent"][f]["hash"]`. `cmd_ship` recomputes that hash for every file about to
be staged and, when the file's most recent releasing task is this one but its current bytes no longer
match the snapshot, prints a **non-blocking** warning naming the file(s) and suggesting `git diff --
<files>` before trusting the commit. Chose a done-time content hash over the finding's own
claim-time/hunk-range sketch — see **D-067** for why. Full mitigation (F-102's generated
`docs/FINDINGS.md`) remains future work; this is the cheap partial one the finding asked for.

**Verified 2026-08-18:** `python3 tools/harness_check.py` — 14/14, including two new cases (`ship
warns when a claimed file drifted after done() (F-117)`, `ship stays quiet when a claimed file's hash
matches its done()-time snapshot`). `python3 tools/harness_check.py --rev HEAD` (pre-fix harness)
fails exactly the new drift-warning case, 13/14 — confirms the test is a real regression guard, not a
vacuous pass. No Godot involved. Also restored `docs/FINDINGS.md`'s orphaned `### F-112` heading,
overwritten by an earlier hand-edit that filed this finding — see the F-117 Resolved entry.

---

## F-119 · `agent godot`'s own `--import` pre-pass logs two UNDECLARED `ERROR:` lines on every single invocation

**Claim:** `tools/godot_prepass_check.py`. No production/runtime file — this is coordination tooling,
not a networked system, so it declares no `ARCHITECTURE.md` §2.2 authority row.

**Root cause:** not repo state — the shared per-user editor settings
(`~/Library/Application Support/Godot/editor_settings-4.7.tres` on macOS, outside the repo and outside
`.godot/`) had `text_editor/external/use_external_editor = true` with an empty
`text_editor/external/exec_path`. F-093's `--import` pre-pass boots the editor headlessly, which
reaches `loading_editor_layout`'s "Reopening scenes..." step and tries to reopen every script the last
real editor session had open through the configured external editor; an empty `exec_path` fails that
open every time, twice (two scripts were in the last saved layout), and Godot falls back to the
internal editor rather than failing the boot — hence exit 0 with two undeclared `ERROR:` lines.
SPECS.md's own standing rule 4 (F-021, "grep every check run for `ERROR:`") was going unenforced
against exactly this section, because an agent's own check greps its own `--script` output, printed
after the pre-pass already ran.

**Fix:** flip `text_editor/external/use_external_editor` to `false` in that `.tres`. Nothing on this
machine had `exec_path` configured, so the external-editor path was dead weight already, not a live
feature being removed. **This fix is per-user/per-machine, not per-repo** — it does not travel with
`git clone` (the file lives outside the repo entirely) and a differently-configured machine could
reintroduce the same two lines; `tools/godot_prepass_check.py` exists to catch that on whichever
machine runs it, not to prove it fixed everywhere.

**Build:** `tools/godot_prepass_check.py` — plain Python, run directly (`python3
tools/godot_prepass_check.py`), not through `agent godot --script` (there is nothing for a `.gd`
script to observe: the bug fires in the pre-pass boot, before any `--script` file is even loaded, so
only a wrapper around the `agent godot` *invocation itself* can see it). It shells out to
`.agent/bin/agent godot --import` for real — `--import` already in argv means `cmd_godot` does not
double it into two passes (F-093) — and fails if any `ERROR:` line appears anywhere in the combined
stdout/stderr. No `fake-godot` double (unlike `tools/harness_check.py`'s F-093 cases): the bug lives
in real per-user global state a double can't reproduce, so this runs the real engine through the real
wrapper.

**Verified 2026-08-18:**

```
python3 tools/godot_prepass_check.py
GODOT_PREPASS_CHECK ok (0 ERROR: lines from `agent godot --import`)
```

Confirmed the check is a real regression guard, not a vacuous pass: flipped
`use_external_editor` back to `true` by hand and reran — `GODOT_PREPASS_CHECK FAIL (2 undeclared
ERROR: line(s))`, both lines exactly the ones this finding describes — then flipped it back to
`false` and confirmed green again.

---

## F-136 · The player controller has no step-up, so any lip in a walkable surface is a wall

**Claim:** `entities/player/player_controller.gd`, `tools/step_up_check.gd` (new).

**What was wrong:** `CharacterBody3D` has no built-in step-up. `player.tscn` sets `floor_max_angle`
46° and `floor_snap_length` 0.3, but nothing tested forward for a short lip and lifted the body over
it — a 60 mm door threshold, a dock deck edge, a kerb, or a bridge module sitting a centimetre proud
of its neighbour all read as a flat wall, not a step. A-010 authored entirely around this absence
(DECISIONS.md D-090) rather than fixing it, which is exactly the workaround this finding says not to
keep leaning on forever.

**Fix:** `_apply_step_up(delta)`, called every physics tick right before `move_and_slide()`, grounded
only. Three `test_move()` probes: (1) is this tick's flat horizontal motion actually blocked — if not,
there is no lip, do nothing; (2) is there room to rise `step_height` (new `@export`, default 0.4 m)
with nothing overhead — a low doorway must still refuse the player; (3) from the raised height, sweep
`motion + Vector3(0, -step_height, 0)` — forward AND down — in **one** `test_move()` call and take its
first point of contact as the landing. That third probe is not the obvious two-step "advance then
drop": a real per-tick `motion` (~0.067 m at 4 m/s / 60 Hz) is far smaller than the capsule's own 0.4 m
radius, so advancing horizontally by only that much and then testing a separate vertical drop lands
the capsule still straddling the lip's corner — the very next `move_and_slide()` then fights that
self-overlap back out, which reads as the player bouncing in place at the lip rather than climbing it.
A single combined diagonal sweep uses Godot's own shape-sweep (which already accounts for the whole
capsule, not its centre point) to find the true first contact, so the result can never leave the body
embedded in the step. If the sweep falls (almost) the full probe depth without contact, it is a wall
or a gap, not a lip — bail and let `move_and_slide()` resolve the frame normally, which is also what
naturally refuses a wall taller than `step_height` (the raised sweep still collides with it).

**Verify:** `tools/step_up_check.gd` (new) — a real `player.tscn` instance against code-built
`StaticBody3D` geometry, same technique as `tools/build_check.gd`'s boxes crossed with
`tools/spawn_ground_probe.gd`'s real-gravity settle. Ground settle uses real `physics_frame` stepping;
the walk itself hand-drives `_apply_gravity()` / `_apply_horizontal_movement()` /
`_apply_step_up()` / `move_and_slide()` in that exact order instead of relying on real WASD input,
because `AttunementUI` (autoload) polls for any node joining the `players` group and opens a
`blocks_gameplay_input` role picker ~0.5 s after spawn — a check that waits real frames for real input
starves against that picker before it ever reaches the lip. Same hand-drive technique
`tools/dodge_check.gd` already established for this controller.

**Done means:** a 0.15 m lip (`step_height` default 0.4 m) is climbed without a stall, landing at the
lip's own height, not a flat `step_height` higher; a 0.6 m wall (above `step_height`) is refused —
the walk stops at the wall's face, and while `CharacterBody3D`'s own rounded-capsule collision
response can still ride a short way up any corner under ordinary `move_and_slide()` (the ordinary
"scuff" the finding's own text names — independent of this fix), it must never come anywhere near
mounting a wall taller than `step_height`; and a `step_height = 0` control proves the SAME low lip
that the fix climbs now blocks, so the suite is a real regression guard, not a pass-by-construction.

**Verified 2026-08-18 (lm):** `agent godot --script tools/step_up_check.gd` → `0 failure(s)` across
all three cases. Regression-checked against the two existing controller suites that exercise the same
`_physics_process()` path: `agent godot --script tools/dodge_check.gd` → `0 failure(s)` (dodge/i-frame
behaviour unaffected), `agent godot --script tools/spawn_ground_probe.gd` → `failures=0` (the real
main-scene terrain spawn/settle, which runs `_apply_step_up()` every tick once grounded, is
unaffected on ordinary flat terrain), `agent godot --script tools/verify_setup.gd` → `all checks
passed`.

---

## F-135 · A modular piece can measure its module exactly and still leave a seam: the bounding box is not the walking surface

**Claim:** none — verification-only task, no code needed editing (see below).

**What was wrong:** `build_construction_set.py`'s `deck_field()` laid each deck plank centred in its
slot and shrank it by the plank gap, leaving half a gap of nothing at both ends of every field. Every
affected piece still measured exactly 2.000 m wide overall — the beams, kerbs and bearers reach the
module edge — so the Blender build contract, which checks the piece's overall run span, passed 18/18
with a 12 mm stripe of daylight at every joint in a run. Nothing that looks at one asset can see it;
it only showed up once `tools/construction_check.gd` assembled multiple modules in the engine and
measured the gap between consecutive **deck** bounds rather than piece bounds. **The general rule:**
when a kit's contract is "these tile", measure the surface that does the tiling (deck planks, rail
run, wall face), never the asset's bounding box — the box is decided by whatever sticks out furthest,
which is exactly the geometry a player never touches.

**Fix (already landed, this task only verified it):** `deck_field()` runs its outer planks to the
field edge and puts gaps only between planks — `index > 0` / `index < count - 1` guard the two ends,
so the first and last plank's outer edge lands exactly on the field's edge. It shipped in the same
commit (`63cc37c`, task 2.1d/A-010) the finding itself was filed from, so by the time this task
picked it up the fix was already in the tree; what was missing was the closing verification and this
spec block. Checked every other candidate seam in the kit for the same bug class: `palisade_logs()`'s
mating plane is its rail boxes (`Rail_0`/`Rail_1`), which are each a single box already spanning the
full `MODULE` width rather than a gapped field, so palisade runs were never exposed to this.

**Verify:** `agent godot --script tools/construction_check.gd`. No new script — the file already IS
the focused check this bug needs: `_check_walkway()` assembles a five-module run (ramp, two docks, a
straight bridge, a broken bridge) and diffs consecutive `_deck_box()` results; `_check_dock_corner()`
and `_check_palisade_corner()` do the same across a 90-degree turn. All three measure the tiling
surface (`_deck_box`/`_rail_box` filter parts by name prefix, e.g. `"Deck"`/`"Rail"`), never the
piece AABB — exactly the general rule this finding states. A prior work order for this task assumed
no such check existed; it does, from the same 2.1d commit, so writing a second one would only
duplicate it.

**Done means:** `CONSTRUCTION_WALKWAY`/`CONSTRUCTION_DOCK_CORNER`/`CONSTRUCTION_PALISADE_CORNER`
each report their worst joint at 0.0000 mm.

**Verified 2026-08-18 (lm):** `agent godot --script tools/construction_check.gd` →
`CONSTRUCTION_WALKWAY modules=5 worst_joint=0.0000 mm deck=1.000 m`,
`CONSTRUCTION_DOCK_CORNER arms=0.0000 mm / 0.0000 mm`,
`CONSTRUCTION_PALISADE_CORNER arms=0.0000 mm / 0.0000 mm`, `CONSTRUCTION_CHECK PASS`. Note: that same
run logs an unrelated UNDECLARED `ERROR: AABB size is negative` from `_check_doors()` — filed as
F-148, out of scope here (it never touches deck/gap measurement; the three joint numbers above are
unaffected by it).

## F-141 · `Wellspring.net_request_toggle_channel` had no two-process net check — only the host-side logic it calls into was proven

**Claim:** `tools/wellspring_net_check.gd` (new), `systems/wellspring/wellspring.gd` (read only, no
change needed).

**What was missing:** `tools/wellspring_check.gd` proves the ritual state machine directly —
`wellspring.call(&"request_toggle_channel")` and `host_tick()` in a single process, exactly the
offline/host-of-one path. It never proved the RPC itself: that a REMOTE client's
`net_request_toggle_channel.rpc_id()` actually reaches `_process_toggle(multiplayer.
get_remote_sender_id())` on a real second ENet process. `chest_net_check.gd` is the sibling shape
for exactly this gap on `Chest.net_request_open`.

**Fix:** `tools/wellspring_net_check.gd`, the "Two-process checks" seam (driver + `--
wellspring-probe` probe arg, talk through `user://wellspring_net_client.json`, per this file's
preamble table). Both processes build the same bare `Wellspring` at `WellspringNetWorld/Wellspring`
before branching, identical to how `chest_net_check.gd` builds its `Chest`. The client calls
`request_toggle_channel()` twice (start, then cancel); the driver asserts the HOST's own `Wellspring`
flips `channeling` true then false from the remote RPC alone, that `required_players`/`duration_sec`
land on the co-op values (host + client both spawn a real `PlayerNet` body this session, so the count
is deterministic at exactly 2), and separately asserts — via the client's own written result file —
that the client only ever learns either state through replication, never a direct reply (this RPC has
none, unlike Chest's `net_open_result`). `PRESENCE_RANGE_M` is a fixed constant on `Wellspring` the
check cannot override, so the driver snaps the HOST's `Wellspring.global_position` onto the client's
*actual* `PlayerNet`-spawned position (read off the host's own tree once `player_net.call
("player_for", client_peer)` is non-null) rather than assuming a `SPAWN_OFFSETS` value, so this stays
correct if that table ever changes.

**Trap paid for again:** hit F-107's exact lambda-by-value bug on a second variable in the same file
its fix already documents — a first draft assigned `client_player` inside the `_until()` poll's
lambda (`client_player = player_net.call(...); return client_player != null`), which only ever wrote
the closure's own copy. The outer `client_player` stayed null even after the poll's `spawned` came
back true, and the driver crashed on `client_player.global_position` against Nil. Fixed the same way
F-107 fixed `client_peer`: poll a boolean only, re-fetch the real value from the outer scope once the
poll succeeds.

**Done means:** two consecutive clean runs, `failures=0`, all 12 assertions PASS.

**Verified 2026-08-18 (lm):** `agent godot --script tools/wellspring_net_check.gd`, twice back to
back — `WELLSPRING_NET_CHECK failures=0` both times, every PASS line present including the RPC-start,
RPC-cancel, and both replication-observed-not-direct-reply assertions.

---

## F-132 · A remote client's scattered harvestable proxy may have no host counterpart to reach, because `ChunkStreamer` streams per-peer independently

**Claim:** `world/chunk/chunk_streamer.gd`, `world/gen/resource_scatter_field.gd`,
`tools/chunk_stream_check.gd`.

**What was wrong:** task 4.4's `ResourceScatterField` builds a harvestable proxy's real,
host-authoritative `Harvestable` state only for chunks inside `ChunkStreamer`'s LOD0/collision ring
(D-083). Task 4.3's `ChunkStreamer` streams independently per peer by design (`ARCHITECTURE.md`
§2.2) — a host and a client resolving different chunk sets around their own local players is
correct, not a desync, for TERRAIN. But a client's own `Harvestable.request_hit()` sends
`rpc_id(NetConfig.HOST_PEER_ID)` at a specific NodePath, and Godot's high-level multiplayer RPC
routes by matching tree path between peers — if the host's own player is far enough that the host's
`ChunkStreamer` never loaded that chunk, the host has no node at that path to receive the call at
all. Not reachable in practice until 4.6+ wires `ChunkStreamer`/`ResourceScatterField` into a real
session (still true — F-139).

**Fix:** none needed in either file's ring/proxy mechanics — they already generalize correctly.
`ChunkStreamer.set_anchors()` already takes `Array[Vector3]`, and `_ring_distance()` already takes
the NEAREST of every anchor, so a chunk stays resident as long as ANY anchor's ring reaches it,
independent of how many anchors there are. `ResourceScatterField` builds/tears down scatter per
CHUNK, never per anchor, so a chunk resident because of a remote peer's anchor gets a proxy exactly
like one resident because of the host's own. **The fix is the calling contract, not new code:**
whichever task first wires these into a live session (F-139) must anchor the HOST's
`ChunkStreamer`/`ResourceScatterField` pair to the union of every connected peer's last-known
position, its own included — not just its own local player — so any point a remote client can
locally reach always has a host-resident, host-authoritative `Harvestable` waiting for its RPC.
Documented as a header-level contract in both files rather than guessed at in code, since the actual
wire format (or whether a live caller even keeps calling `set_anchors()` once per peer vs. computing
a single merged position list) is still F-139's own open design space. D-095 records why no new API
was added.

**One real trap found while proving this:** `ResourceScatterField.attach_to_streamer()` only reacts
to `chunk_mesh_ready`/`chunk_unloaded` as they FIRE — it never retroactively scans chunks already
resident on the streamer at attach time. A live caller that attaches the field AFTER the streamer's
anchors have already settled a ring gets zero proxies for that ring until something forces a reload.
Documented directly on `attach_to_streamer()`'s own docstring so the next caller doesn't rediscover
it by a silent `chunk_count() == 0`.

**Verify:** `agent godot --windowed --script tools/chunk_stream_check.gd`'s new union-of-interest
section — a REAL `ChunkStreamer` fed two independent anchors (chosen `>= LOAD_RADIUS_CHUNKS +
HYSTERESIS_CHUNKS + 1` chunks apart, so neither anchor's own ring could possibly reach the other's
target by construction, not by luck) with a REAL `ResourceScatterField` attached, proving BOTH
anchors' chunks load at LOD0 with a collider and BOTH materialize a live, `HarvestWorld`-wired
`Harvestable` — the exact node an `rpc_id(HOST_PEER_ID)` call from either position would need to
reach. Must run `--windowed` (F-005/D-074): real collision cooking is part of what's being proven.

**Done means:** the union-of-interest section passes as part of `tools/chunk_stream_check.gd`'s
existing suite, with zero regressions to its own phase 1/2 or to `tools/resource_scatter_check.gd`.

**Verified 2026-08-18 (lm):** `agent godot --windowed --script tools/chunk_stream_check.gd` →
`0 functional failure(s)`, every phase including the new union-of-interest section (`ok` on both
anchors' LOD0/collision residency and both anchors' live wired `Harvestable`). Regression-checked:
`agent godot --script tools/resource_scatter_check.gd` → `RESOURCE_SCATTER_CHECK failures=0`;
`agent godot --script tools/verify_setup.gd` → `all checks passed`.

---

# Open findings worth dispatching as tasks (claim by F-number)

| # | One-line spec |
|---|---|
| F-004 | Enemy half fixed; remaining: interpolate *props* if any replicated prop ever moves (none do today — close it when 2.13 ships if still true). |
| F-005 | Becomes task 4.0a — do not fix separately. |
| F-006 | Windows/Linux machines exist now (D-028 PC, Unraid KVM) — rewrite the finding's premise or close it against those facts. |
| F-020 | Steam auto-rejoin: on `run_player_rebound` support over Steam transport, reuse SteamLobby membership (the lobby is NOT left on timeout — D-029 explains the invariant); needs the D-028 PC to verify. |
| F-023 | Measure Steam first-join latency on the physical PC, then set `STEAM_CONNECT_TIMEOUT_SEC` from evidence (currently 20 s by judgment). |
| F-024 | Move dev_launch's bounded LAN retry into `NetSession` as policy (D-029 already did it for STEAM; mirror for ENet first joins). |
| F-025 | Pump Steam callbacks from a timer, not `_process`, so a slow frame can't slow the handshake; verify no reentrancy on the lobby callbacks. |
| F-043 | Decision spec'd under M2 above. |
| F-049 | Two named fixes in `.agent/bin/agent` (`_sync_findings` closes departed findings; start/board call it); ship with a before/after board diff. |

# Maintaining this file

One block per task, same shape: **Goal / Authority / Claim / Build / Verify / Done means / Traps.**
When a task ships, its block stays (it documents intent the code now embodies) but gains a one-line
`✅ shipped — see DELEGATION` header. When a design decision invalidates a block, rewrite the block
in the same commit as the decision. The specs for a milestone get their final polish when the
previous milestone's playtest lands — never spec against a design that playtest is about to change.
