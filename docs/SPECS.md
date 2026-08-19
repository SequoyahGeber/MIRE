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

### The five standing rules (they have already cost real sessions)

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
5. `expr as Array[T]` does **not** perform an element-wise runtime conversion of an already-untyped
   `Array` — it silently leaves the array untyped, and `Object.set()` onto a strictly-typed
   `Array[T]` `@export` then no-ops with no error (F-163). `Array[T](expr)` is **not** a fix in real
   `.gd` code either — that bracket-generic call syntax is only valid inside a `.tres` text
   resource's own literal parser; written as an executable statement in a `.gd` script it is a parse
   error (`Cannot call on an expression`), confirmed with `tools/_probe_typed_array_convert.gd`. The
   forms that actually work in script code: the 4-arg builtin constructor,
   `Array(expr, TYPE_STRING_NAME, &"", null)` (what `tools/cycle_modifier_check.gd` uses), or
   declare-then-`assign()`, `var typed: Array[T] = []; typed.assign(expr)`. A plain array literal
   assigned directly to a typed-array-declared local (`var x: Array[T] = [...]`) still converts
   correctly at declaration time — the failure is specific to converting an already-untyped `Array`
   *value*.

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

## F-224 · `CommandService`'s per-client `_resolved_requests` dictionary never shrank over a session

`_resolved_requests[request_id] = true` is written by `net_command_result` (a real reply landed) and
by `_on_submit_timeout` (nothing came back in time) — client-side only, one entry per HOST-scope
command a client ever submits over `net_submit_command`. Its only job is to stop whichever of those
two fires SECOND from emitting a duplicate, stale `_rpc_result_received`. Nothing ever erased an
entry, so the dictionary grew for the life of the client process — not a correctness bug (the guard's
read is O(1) regardless of size), but MIRE's runs are explicitly endless (CLAUDE.md) and 3.17's
functions/hooks can submit HOST-scope commands programmatically in a loop, so a long session had no
bound on it. **Claim:** `autoload/command_service.gd`, `tools/command_resolved_requests_check.gd`
(new).

**Fix:** `_submit_to_host()` is the one place that consumes a request's matching
`_rpc_result_received` — erase `_resolved_requests[request_id]` there, right after the match, instead
of never. That alone would have reopened the race the dictionary exists to prevent: the pending
`SceneTreeTimer.timeout` connection to `_on_submit_timeout` is still armed at that point, so if the
real reply won the race, the timer would fire later anyway, find no entry, and re-add one that
nothing would ever clean up again — silently defeating the fix on every request that resolves before
its timeout (which is the common case). So the timeout connection is disconnected first (stored as a
named `Callable` local so `is_connected`/`disconnect` target the exact bound instance), and only then
is the entry erased. Added `resolved_request_count()`, a read-only mirror of the dictionary's size,
the same "assert on real private state" reasoning `is_op()` already gives for its own mirror — the
new check's only way to observe the dictionary from outside the file.

**Shipped 2026-08-19.** Verified: `.agent/bin/agent godot --script
tools/command_resolved_requests_check.gd` (new, real two-process ENet, `command_net_check.gd`'s own
driver/probe shape — F-037) drives a non-op client through 5 HOST-scope round trips and asserts
`resolved_request_count() == 0` after each one individually, not just at the end, so the check would
have caught the "erase without disconnecting the timer" near-miss above. 0 failures, no undeclared
`ERROR:` lines. `tools/command_net_check.gd` (the existing 3.13 suite) re-run clean, 0 failures,
confirming the timer-cancel path doesn't change behavior for an opped client's normal round trip.

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

**GATE: M3's frameworks only. 2.9 no longer gates anything (D-125** — "tuning can be done at any
time don't let it hold things up"; combat feel stays never-cut *work*, folded in whenever Sequoyah
plays**).** Content-heavy: agents ship frameworks + one worked example each; enemies/bosses/
movesets are then T0 authoring + A-023..A-026 asset batches (tracker gates align).

## 5.1 · Enemy AI framework: state machine, perception, telegraphed attacks, group behaviour (T2)

**Authority:** §2.2 row "Enemies (spawn, AI, damage): HOST" — unchanged; every decision below is
still made once, on the host, inside the existing `Enemy._physics_process()`.
**Claim:** `systems/enemies/enemy.gd`, `systems/enemies/enemy_def.gd`, `tools/enemy_ai_check.gd`
(+ its `.uid`).

2.10 already shipped a real `IDLE -> CHASE -> TELL -> ATTACK -> RECOVER` state machine and a
telegraphed attack (the hit resolves at the END of the tell, against where the target IS then) —
this task does not rebuild either. What it generalises, **as data on `EnemyDef` rather than by
extracting a swappable brain class** (D-095 — one shape is still the only shape any content needs; a
real second AI shape, not a guess, is what should trigger that split), is:

- **Perception** (`vision_angle_deg`, `requires_line_of_sight`) — acquisition-only. A facing cone
  (360° = omnidirectional, 2.10's original behaviour) plus an optional
  `PhysicsDirectSpaceState3D.intersect_ray` gate whether a NEW target can be acquired. An
  already-held target is kept on distance alone (2.10's existing aggro/deaggro hysteresis) — losing
  perception never drops a target already being chased.
- **Alerting** (`alert_radius_m`) — a fresh (not re-affirmed) acquisition hands the same target
  directly to every untargeted enemy within range (`Enemy.alert()` is the public entry point).
  **One hop only** — an alerted enemy never itself alerts further, so a spotted player draws the
  local pack without a chain reaction across the map.
- **Attack-slot cap** (`max_concurrent_attackers`) — at most this many of one kind may be
  TELL/ATTACK against the same target at once; the rest hold position at range instead of piling
  on, rechecked every tick as slots free up (`Enemy._engaged_attackers()`).

Build: all three land as new `@export` fields on `EnemyDef` plus the matching logic in
`_resolve_target()`/`_tick_pursuit()`/`_aggro_on()` (now routed through one `_acquire_target()` so
alerting can only fire from the two places a target is actually newly acquired). Defaults are chosen
so `content/enemies/crawler.tres` — left unedited — keeps every `enemy_check.gd` assertion passing
verbatim (`vision_angle_deg = 360` is a no-op cone check) while LOS/alerting/the attack cap are live
at sensible defaults: an unused capability is a shipped-but-dead one (Hollowmere's own
zero-crawlers-in-the-game history, `docs/DELEGATION.md`, is the standing example of why). No new
replicated property, no new RPC — `state`/`health`/`hit_counter` are unchanged, and every new
decision is made and consumed entirely inside the host's own simulation step.

Verify: `tools/enemy_ai_check.gd` — the cone blocks/allows acquisition, an unobstructed ray gates it
too, a wall placed AFTER acquisition does not drop an already-held target, alerting wakes an
untargeted packmate in range one hop and no further (a two-hop control enemy stays untouched), and
the attack-slot cap holds a third attacker back then lets it in once a slot frees. 2.10's
`tools/enemy_check.gd` and `tools/enemy_net_check.gd` must still be `failures=0`, unmodified — that
is this task's real "zero regression" bar, in place of a literal no-behaviour-change refactor.
Done means: all four checks green, 0 `ERROR:` on a full boot (`agent godot --quit-after 20`), and
`docs/DELEGATION.md`'s Current state carries the new `EnemyDef` fields and `Enemy.alert()` for 5.2's
authors to build against.

- **5.2 Enemy types (T0+A-023/24/25):** stats/tells in `.tres`, models via the tracker.
- **5.3 Ranged combat:** done — see the `## 5.3` block below.
- **5.4 Movesets (T0/T1):** per-fork `WeaponDef` extensions (combo windows, alt-attack flag) —
  data first, one T1 task for the combo state machine, then T0 tuning.
- **5.5 Boss framework:** done — see the `## 5.5` block below.
- **5.6/5.7/5.8 Bosses (T0 over 5.5):** Wellspring guardian scales with Cycle; Hunt elite spawned
  by modifier 6.2; deep-Cycle threat gated Cycle 7+.
- **5.9 Wave director (T1):** 2.12's spawner gains composition tables (per-Cycle enemy pools,
  weights) — the file already has the seams; this is its planned growth, not a rewrite.
- **5.10 Balance (T0):** across the Cycle curve, not at one difficulty; record tables.

## 5.3 · Ranged combat: bow, projectiles, host-authoritative hit validation (T2)

**Authority:** new §2.2 row, "Ranged weapons (bow + arrow)": **Host.** Same three-way split melee
(2.8) established, plus a fourth piece melee never needed — an actual flight. The draw is the
shooter's own client-local prediction; the shot (aim, ammo, hit) is host-only, derived from the
shooter's own already-replicated transform, never a client-sent vector; the flight VISUAL is
cosmetic prediction identical on every peer, driven off one broadcast; the impact is host-broadcast
once, authoritative.
**Claim:** `systems/combat/ranged_weapon_def.gd`, `systems/combat/aim_util.gd`,
`autoload/ranged_combat_service.gd` (+ every file's own `.uid`), `autoload/combat_service.gd`,
`autoload/registry.gd`, `content/ranged_weapons/short_bow.tres`, `content/items/short_bow.tres`,
`tools/ranged_combat_check.gd`, `tools/ranged_combat_net_check.gd` (+ their `.uid`s).
`project.godot` registers `RangedCombatService` via `agent autoload` (F-051) — never claimed.

**Why a separate content family and host state machine, not a mode of `WeaponDef`/`CombatService`:**
a bow fires an ammo item through a variable-length flight (however long the arrow actually takes to
connect or run out of range) rather than colliding a fixed-duration swing arc — `WeaponDef`'s whole
shape (`wind_up`/`commit`/`recovery` as fixed authored durations) does not fit. `RangedWeaponDef`
(`item_id`, `ammo_item_id`, `draw_seconds`, `recovery_seconds`, `projectile_speed_m_s`,
`gravity_scale`, `max_range_m`, `damage`, feel fields) lives beside `WeaponDef` in
`systems/combat/`, loaded into a new `Registry.ranged_weapons` family exactly like `weapons`
(`get_ranged_weapon`/`has_ranged_weapon`). `CombatService.request_attack()` checks
`Registry.has_ranged_weapon()` on the selected hotbar slot FIRST and hands the whole action to
`RangedCombatService.request_shot()` before any melee state is touched, so `attack` stays the one
input both weapon families answer. Both directions of a mutual-exclusion check (each service asks
the other's `local_phase()`) keep a melee swing and a bow draw from ever overlapping regardless of
which hotbar slot triggers first.

**The host's own shot simulation, per peer, per physics tick (`RangedCombatService._advance_host_shots`):**
WIND_UP (the draw; host re-validates ammo at both accept and release, so a dry stack between the two
is a clean dry-fire, not a phantom arrow) → on release, `CombatAim.direction()`/`eye_position()`
(`systems/combat/aim_util.gd`, the same yaw+pitch formula melee's own private `_aim_direction()`
uses, factored out for this task but NOT retrofitted onto melee's tested code — the two stay
independent copies on purpose) derive the aim from the shooter's replicated transform, ammo is
consumed (`InventoryService.host_remove`), and the arrow begins COMMIT (flight) → one
`PhysicsDirectSpaceState3D.intersect_ray()` per tick between last and current position (mask
`1 | PlacementValidator.TERRAIN_LAYER`, same shape as `Enemy._has_line_of_sight()`), swept so a fast
arrow cannot skip a thin collider between two frames → a hit, a wall, or `max_range_m` ends the
flight and starts RECOVERY.

**The raycast's own collider is not necessarily the `&"damageable"` node — this is the one trap
worth knowing before any future system raycasts against this group.** `Enemy`/`PlayerController` are
`CollisionObject3D` themselves, but `Harvestable` is a plain `Node3D` that finds a CHILD
`CollisionObject3D` for its own collider. `RangedCombatService._damageable_owner()` walks UP from
whatever the raycast hit (itself included, bounded depth) to the nearest ancestor actually in the
group — skipping this is a silent "arrows can hit enemies/players but never a Harvestable" bug that
a check aimed only at CharacterBody3D-shaped targets would never catch (this task's own first attempt
didn't, until its check's `TestTarget` was reshaped to match Harvestable's actual wrapper structure).

**PvP is cut (DESIGN.md §7).** `_resolve_flight()` excludes any hit whose damageable owner is also
in `&"players"` — an arrow that reaches another player's own body still physically stops there (it
does not pass through to whatever is behind), it simply deals no damage. Melee's own target search
has no such exclusion today (out of this task's claim; not chased here).

**The flight visual is client-local prediction on every peer, including the shooter and the host
itself**, reusing the ammo item's OWN authored `world_model` (`arrow_world.glb`) as the flying mesh —
no new asset. One broadcast (`net_shot_fired`: origin, direction, speed, `gravity_scale`, both the
bow's and the ammo's item id) is enough for every peer to run the identical kinematic formula
independently; there is no per-tick position sync (ARCHITECTURE.md §2.5). `net_shot_resolved` (hit,
position, damage, target name) is the one authoritative broadcast that despawns/snaps the visual and
starts every peer's own feel consequences — hitstop/shake for the shooter, a positional impact sound
for everyone, reusing `CombatService.placeholder_impact_sound()` when a bow has no authored one
rather than a second procedural-audio copy.

**No `PROTOCOL_VERSION` bump — D-102, F-161.** SPECS.md's own standing rule 5 requires one for any
new RPC; `core/net/net_version.gd` and `tools/handshake_check.gd` were held all session by lane
slate17's 3.7 claim, the same situation D-100 recorded for task 6.1. Unlike 6.1, this task could not
route around needing a real RPC (a variable-length flight has no existing generic seam to piggyback
on the way `WorldDeltaLog` did), so three new RPCs (`net_request_shot`, `net_shot_fired`,
`net_shot_resolved`) ship un-versioned rather than the task stalling on a file another lane held.

Verify: `tools/ranged_combat_check.gd` (offline, one process) — draw/flight/recovery timing, ammo
consumed only on release (not on draw, not twice), a wall stops the flight (proving the raycast, not
a distance test), PvP exclusion (the arrow stops on a player-shaped target but never damages it, and
nothing behind it is reached either), an out-of-ammo draw is rejected cleanly, melee/ranged mutual
exclusion both directions. `tools/ranged_combat_net_check.gd` (real two-process ENet, `combat_net_check.gd`'s
own shape) — a client that only ever sends a hotbar index gets a host-resolved connect with the
host's own damage number, a host-consumed arrow, and a clean host-side rejection once it is out.
Both `failures=0`. Regression: `tools/combat_check.gd`, `tools/combat_net_check.gd`,
`tools/harvest_tool_ladder_check.gd`, `tools/command_catalog_check.gd`, `tools/verify_setup.gd` all
still `failures=0` / all checks passed, unmodified — melee's own local phase and hitbox logic are
untouched. Full boot (`agent godot --quit-after 20`): 0 `ERROR:` lines.
Done means: both new checks green, the five regression checks green, 0 `ERROR:` on a full boot, and
`docs/DELEGATION.md`'s Current state carries `RangedWeaponDef`'s fields, `RangedCombatService`'s
public API, and the `_damageable_owner()` gotcha for whatever system next raycasts against
`&"damageable"`.

## 5.5 · Boss framework: phases, arena, telegraphs, health bar, music stinger (T2)

**No block existed for this task** — SPECS.md's own preamble rule applies again: fixing a missing
spec belongs to the task that discovers it. The M5 overview's own look-ahead (just above, in this
file) sketched the shape correctly: "phases as an array of `BossPhaseDef` (hp threshold, moveset id,
arena flags), health bar UI seam, music stinger hook via `EventBus`" — this block is that sketch made
concrete, plus the "arena" split it left implicit.

**Authority:** no new §2.2 row (D-116, same reasoning D-112 gave task 7.8). A boss IS an `Enemy` —
`Boss extends Enemy` — so it inherits the existing "Enemies (spawn, AI, damage): **Host**" row
verbatim. `phase`/`move_index` are two more `REPLICATION_MODE_ALWAYS` properties added to the same
code-built `SceneReplicationConfig` `Enemy._build_synchronizer()` already builds; no new RPC.

**Claim:** `core/events/event_bus.gd`, `autoload/enemy_world.gd`, `systems/enemies/boss_move_def.gd`,
`systems/enemies/boss_phase_def.gd`, `systems/enemies/boss_def.gd`, `systems/enemies/boss.gd`,
`autoload/boss_music_director.gd`, `ui/hud/boss_health_hud.gd`, `tools/boss_check.gd`,
`tools/audio_import_check.gd`, `tools/audio/render_music.py` (+ every new file's own `.uid`).
`project.godot` registers `BossMusicDirector`/`BossHealthHud` via `agent autoload` (F-051) — never
hand-edited. **`systems/enemies/enemy.gd` was NOT claimed** — held all session by lane lm's 7.7
(perf/LOD); see below for how `Boss` builds on it without touching a line.

**Boss extends Enemy through ordinary GDScript overriding, not new hooks on the base class.** Every
extension point this task needed already existed as a plain overridable method or an inherited
member var — `_can_perceive()`, `_acquire_target()`, `host_apply_damage()`, `_enter_tell()`,
`_tick_attack()`, `_resolve_attack()`, `_play_state_animation()`, `_build_synchronizer()`, and the
raw `_target_peer`/`_target_node`/`_sync`/`_anim` fields — so `Boss` (`systems/enemies/boss.gd`)
reaches everything it needs via `super()` and inheritance, with zero edits to `enemy.gd`. Worth
recording as the general pattern: a subclass that needs to extend ONE decision an existing host-owned
state machine makes rarely needs the base file touched at all in GDScript — try overriding first,
before claiming the file everyone else is also reaching for.

**Phases (`BossDef.phases: Array[BossPhaseDef]`).** Each `BossPhaseDef` carries an
`hp_threshold_fraction` (descending order, phase 0 = 1.0 = full health), a `moves` array
(`BossMoveDef`, see Telegraphs below), a `move_speed_multiplier`, a `seals_arena` flag (see Arena
below), and an optional `music_cue` id. `BossDef.phase_for_health_fraction(fraction)` scans for the
last index whose threshold the fraction still satisfies — monotonic by construction when authored in
order, and `BossDef.validation_errors()` (extends `EnemyDef`'s own) catches an out-of-order array at
author time. `Boss.phase` is `-1` (`DORMANT_PHASE`) until the boss takes its first target
(`_acquire_target()`'s override calls `_update_phase()` on the was-dormant transition), then advances
— never regresses — as `host_apply_damage()`'s override recomputes it after every accepted hit.

**Telegraphs (`BossPhaseDef.moves: Array[BossMoveDef]`).** `EnemyDef` gives an ordinary enemy exactly
one fixed attack (`attack_damage`/`attack_range_m`/three durations); a boss needs several per phase,
so those same five numbers (plus a weight and two animation clip names) become one `BossMoveDef`
array element instead. `Boss._enter_tell()` picks a move by weighted random
(`_pick_move_index()`, a seeded `RandomNumberGenerator` — `WaveSpawner`'s own convention for a
host-only decision nobody else needs to agree with) and replicates the choice via `move_index` so
every peer's `_play_state_animation()` renders the SAME move's clip, not just the host's own. **An
empty `moves` array (or an entirely phase-less `BossDef`) falls through to `EnemyDef`'s single fixed
attack at every override site** — this is deliberate: it is what makes a `BossDef` with nothing
authored beyond a `BossPhaseDef` behave exactly like a plain `Enemy` with a health bar and a stinger,
the framework's own minimal-boss path.

**Arena — a data flag in this task, not geometry.** `BossDef.arena_radius_m` plus
`BossPhaseDef.seals_arena` are the framework's whole contribution: `Boss` never ACQUIRES a target
outside its own arena (`_can_perceive()`'s override, on top of 5.1's cone/LOS checks) and, unless the
active phase seals the arena, drops an already-held target the instant it leaves the radius
(`_enforce_arena_leash()`, run each tick before `_tick_pursuit()`'s own logic). **The physical wall or
pylons a player actually sees are boss-specific content** (`docs/ASSET_TRACKER.md` A-027's "arena
pylons"), left to whichever task authors the real fight (5.6/5.7/5.8) — building procedural collision
geometry in code was considered and rejected for this task: it would need coordinating with
`EnemyWorld`'s navmesh bake order for no framework-level payoff, since nothing yet needs a boss fight
players can physically be sealed inside. `seals_arena` exists now so a boss author can decide "no
leash-drop this phase" today and wire the visible wall later without touching this file again.

**Health bar (`ui/hud/boss_health_hud.gd`, new autoload `BossHealthHud`).** Client-local, same
"poll a group, not a signal" shape `wellspring_hud.gd` uses — `Boss.health_fraction()`/
`phase_count()`/`is_engaged()` are the three public reads it needs, all safe against a plain
`EnemyDef` (no `BossDef` to read) or a dormant/dead boss. Shows nothing until a boss is engaged, same
"hide until relevant" rule `wellspring_hud.gd` already established for its own bar.

**Music stinger (`autoload/boss_music_director.gd`, new autoload `BossMusicDirector`).** The seam
`docs/AUDIO.md`'s own "Not done yet" list already named this task for. Subscribes to the three new
`EventBus` events below and plays `assets/audio/music/boss_stinger.ogg`
(`tools/audio/render_music.py`'s new `BOSS_STINGER` — one non-looping ~7 s cue, impact in the first
~1.1 s then its own reverb tail, built from NIGHT's own palette per D-066) through whichever
`AudioStreamPlayer` in a round-robin pair is free, on the "Music" bus if `SettingsService` (task 7.5)
has created one by the time it plays, else "Master". **No per-boss/per-phase cue ships** —
`BossDef.engage_music_cue`/`BossPhaseDef.music_cue` exist as the wiring point, but `CUE_PATHS` holds
only the one shared id today (AGENTS.md: framework, not content).

**Three new `EventBus` events — `boss_engaged`, `boss_phase_changed`, `boss_defeated` — all fired from
a REPLICATED property's own setter, never a host-only guard.** `boss_engaged`/`boss_phase_changed`
come from `Boss.phase`'s setter directly; `boss_defeated` comes from `_play_state_animation()`
(itself already called from `Enemy.state`'s existing replicated setter) the instant `state` first
reaches DEAD. This is the D-107/D-108 fix pattern applied from the start — `docs/FINDINGS.md` F-168
is the standing example of a system that got this wrong (`Wellspring._finish_cap()` still emits from
a host-only `if`) and undercounts on non-host peers as a result. Every consumer here (the stinger, a
future HUD flourish) reaches every peer's own local emit with no RPC of its own.

**No worked-example boss content ships with this task.** 5.6/5.7/5.8 own the three real bosses;
authoring a placeholder one here (with no model, to "prove the framework") would still be content per
D-073's own rule, and a fake boss is a worse use of that authoring slot than three real ones.
`tools/boss_check.gd` proves the framework against synthetic `BossDef`/`BossPhaseDef`/`BossMoveDef`
trees instead — the same shape `enemy_ai_check.gd` already established as acceptable for a
data-driven framework task.

Verify: `tools/boss_check.gd` (new, 45 assertions) — content validation and
`phase_for_health_fraction()`'s scan rule, engage/phase-transition/defeat firing exactly once each at
the right moment with the right previous/new phase, the arena leash both directions (acquisition
gated, retention dropped, sealed retention held), weighted move selection landing its expected 9:1
share deterministically, a real TELL→ATTACK→RECOVER cycle using the CHOSEN move's own timings and
damage rather than `EnemyDef`'s fixed ones, the empty-moves fallback matching `EnemyDef`'s fixed
attack exactly, `EnemyWorld.host_spawn()` instantiating `Boss` (not plain `Enemy`) for a `BossDef`,
and `BossMusicDirector` actually starting playback on all three `EventBus` hooks. `failures=0`.
Regression: `tools/enemy_check.gd`, `tools/enemy_ai_check.gd`, `tools/enemy_net_check.gd`,
`tools/entity_check.gd`, `tools/combat_feel_check.gd` all still `failures=0` unmodified;
`tools/enemy_facing_check.gd` (needs `--windowed` for its render capture, F-077) still renders
correctly; `tools/enemy_crawler_check.gd`'s import checks still pass. `tools/audio_import_check.gd`
extended (not touched in a regression sense — it needed a new assertion group for the one-shot
stinger alongside its existing looped-music assertions) — `failures=0`. Full boot (`agent godot
--quit-after 20`): 0 `ERROR:` lines, both new autoloads silent until a boss actually engages.
Done means: all checks above green, 0 `ERROR:` on a full boot, and `docs/DELEGATION.md`'s Current
state carries `BossDef`/`BossPhaseDef`/`BossMoveDef`'s fields and `Boss`'s public API for 5.6/5.7/5.8
to author their three real bosses against.

## 5.9 · Wave director: Cycle-aware pacing, composition, player-count scaling (T1)

**No block existed for this task** — SPECS.md's own preamble ("fixing a missing spec belongs to the
task that discovers it") makes writing this part of 5.9 itself. Written from the shipped
`systems/waves/wave_spawner.gd` (2.12/3.16/4.8/4.11/6.1) rather than a stale ROADMAP line.

**Authority:** §2.2 row "Day/night, wave director, Cycle state, active modifiers: HOST" — unchanged,
already declared in `wave_spawner.gd`'s header. This task adds no new replicated state and no new
RPC: everything below is derived host-side from `CycleService.current_cycle()` (read through the
existing `EventBus.subscribe_cycle_advanced` seam 6.2 already proved) at the moment a wave starts, the
same "read once, at dusk" rule `base_count`/`per_player` already follow.

**Claim:** `systems/waves/wave_spawner.gd`, `tools/wave_director_check.gd` (+ its `.uid`).

**What already shipped, before this task, under other tasks' names — read this before adding
anything:**
- **Player-count scaling** — `host_start_wave()` already sizes a wave at
  `base_count + per_player * _live_player_count()` (task 2.12/3.14). Nothing to add.
- **Composition (the roster growing)** — `CycleService.host_advance_cycle()` already calls
  `WaveSpawner.host_unlock_next_enemy()` once per Cycle (task 6.1/D-100), appending the next
  `roster_order` entry to `_unlocked_pool`. Nothing to add to the unlock mechanism itself.

**What was actually missing, and what this task adds:**

1. **Cycle-aware pacing (new).** Nothing before this task read `current_cycle()` for anything but the
   roster unlock — a Cycle-9 wave and a Cycle-1 wave were sized identically. `WaveSpawner` now
   subscribes `EventBus.subscribe_cycle_advanced` (mirroring `CycleModifierService`'s own `_ready()`
   line) and caches the number into `_current_cycle`. `host_start_wave()`'s size formula becomes
   `roundi((base_count + per_player * _live_player_count()) * cycle_count_multiplier())`, where
   `cycle_count_multiplier(cycle) = min(1.0 + max(cycle - 1, 0) * CYCLE_COUNT_STEP_PER_CYCLE,
   CYCLE_COUNT_CAP_MULTIPLIER)` — **additive and capped, deliberately not compounding like
   `CycleService`'s own `SPREAD_ESCALATION_PER_CYCLE`.** DESIGN.md §5.4 is explicit that endless
   replayability "comes from stacking modifiers... not from content volume" — an uncapped
   multiplicative enemy count would both contradict that and be a real performance cliff in a run
   with no upper Cycle bound (F-144's render-cost findings are exactly this class of problem). The
   cap (2.5x at Cycle 11, placeholder-tuned like every other Cycle constant in this file — "nothing
   tunes this until a real playtest measures the wall," same status `SPREAD_ESCALATION_PER_CYCLE`
   carries) lands the count curve's own saturation right where DESIGN.md §5.3 already draws "the
   wall": Cycle 8–12. At Cycle 1 the multiplier is exactly 1.0, so this changes no existing behavior
   before a Cycle has ever advanced — `tools/wave_spawner_check.gd`'s assertions, which never fire
   `cycle_advanced`, need no change.
2. **Composition weighting (new).** `_roll_roster()` was flat odds across `enemy_id` plus every
   unlocked archetype forever — a Cycle-9 roster with two archetypes unlocked still rolled them
   50/50/50, so nothing about the MIX read as "the fight changes" the way DESIGN.md §5.1 claims for
   the roster expanding. Weighted now: `enemy_id` keeps weight 1, and the Nth unlocked archetype (1
   indexed, in unlock order) gets weight `N + 1` — the most-recently-unlocked archetype is always the
   single most common pick, so composition keeps shifting for the life of the run instead of diluting
   toward a flat average. No new content (`roster_order` still ships with only `bog_crawler`, per
   D-100/AGENTS.md's ban on bulk-generated `.tres` content — 5.2 is still the task that grows it).
3. **`current_cycle() -> int`** — new public getter, same naming convention as
   `CycleService.current_cycle()`, so a future HUD/debug consumer (or `tools/*_check.gd`) can read
   what pacing tier a wave spawned under without reaching into a private var.

**What this task deliberately leaves alone:** night length/frequency (`DayNight.day_length_seconds`)
already has a Cycle-facing lever — the *Long Night* Cycle Modifier (DESIGN.md §5.1 example table,
6.2's framework) — and duplicating that here would be two systems reaching for the same knob.
`host_spawn_wave_at()` (4.8's Wellspring defense wave) keeps taking an explicit count and bypasses
both the size formula and the roster roll entirely, unchanged — an authored one-shot override, not a
population this task's pacing curve should touch.

Verify: `tools/wave_director_check.gd` — `cycle_count_multiplier()` at Cycle 1 (1.0, unchanged),
mid-curve (Cycle 6), and past the cap (Cycle 20, clamped at 2.5); a real `host_start_wave()` at
Cycle 1 matches the pre-existing formula exactly (regression anchor); a real one at a mid/high Cycle
scales `live_count()` by the expected multiplier; `EventBus.emit_cycle_advanced()` actually reaches
`current_cycle()` (not a private copy — the same F-068 lesson `wave_spawner_check.gd`'s own header
already recorded, applied to this seam); a large weighted roll (`host_spawn_wave_at` with an explicit
empty `wave_enemy_id` to force `_roll_roster()`, one archetype unlocked) lands the newer archetype's
observed share inside a wide statistical tolerance of its 2:1 weight, deterministic under the fixed
`DEFAULT_SEED` so the check never flakes. `tools/wave_spawner_check.gd` must stay `failures=0`
unmodified — this task's real regression bar, since nothing before a Cycle ever advances should
change. `tools/cycle_check.gd`, `tools/cycle_modifier_check.gd` must also stay `failures=0`.
Done means: `wave_director_check.gd` plus the three regression checks all green, 0 `ERROR:` on a full
boot (`agent godot --quit-after 20`), and `docs/DELEGATION.md`'s Current state carries
`cycle_count_multiplier()`/`current_cycle()` for 5.10's balance pass (T0, "across the Cycle curve")
to read and tune against.

---

# M6 — cycles, extraction & meta

**GATE: M4's world (extraction ship is a POI; Cycle escalation reads the Mire).**

## 6.1 · Cycle state machine: advance, escalate spread rate, expand enemy pool, announce (`DESIGN.md` §5.1)

**Authority:** §2.2 row "Day/night, wave director, Cycle state, active modifiers: HOST" — a Cycle is
a single global int, and only the host advances it; every other peer reads a replicated copy.
**Claim:** `systems/cycle/cycle_service.gd` (+ its `.uid`), `core/events/event_bus.gd`,
`world/mire/mire_grid.gd`, `systems/waves/wave_spawner.gd`, `tools/cycle_check.gd` (+ its `.uid`).
`project.godot` is registered via `agent autoload CycleService systems/cycle/cycle_service.gd`
(F-051) — never claimed.

DESIGN.md §5.1: "A Cycle is roughly 3 in-game days... at the end of each Cycle, three things happen:
1. Mire base spread rate increases, permanently. 2. A Cycle Modifier is drawn. 3. Enemy roster
expands." Then it announces. New autoload `CycleService` counts `DayNight.day_started` crossings
(the same subscription `WaveSpawner` already holds) and every `DAYS_PER_CYCLE` (3) of them runs
`host_advance_cycle()`, which does all three named steps plus announce:

1. **Escalate spread rate** — `_spread_multiplier *= SPREAD_ESCALATION_PER_CYCLE` (1.15,
   placeholder-tuned like every other Cycle-facing constant here), passed to a new
   `MireGrid.set_cycle_spread_multiplier()` seam that multiplies `BASE_SPREAD_RATE` in `_tick()`,
   alongside the existing per-Wellspring-cap reduction. Compounds permanently across the run, per
   DESIGN.md.
2. **Draw a Cycle Modifier** — OUT OF SCOPE (D-100). `docs/ROADMAP.md` gives the deck/draw/stacking
   framework its own task, 6.2, which does not exist yet; building a draw here would duplicate it
   against nothing to draw from. `EventBus.emit_cycle_advanced(cycle)` (new subscriber list, same
   shape as `wellspring_capped`) is the seam 6.2 hangs its draw off.
3. **Expand enemy roster** — new `WaveSpawner.host_unlock_next_enemy()` appends the next id from a
   new `@export var roster_order: Array[StringName]` (default `[&"bog_crawler"]`, task 4.11's
   corrupted-spawn archetype — no new content authored per D-073/AGENTS.md's ban on bulk-generating
   `.tres` content; 5.2 grows the real list) into a new `_unlocked_pool`. `_spawn_one()`'s default
   `spawn_enemy_id` changed from `enemy_id` to `&""`, meaning "roll `_roll_roster()`" — even odds
   across `enemy_id` plus every unlocked archetype. An explicit id (4.8's Wellspring defense wave)
   still bypasses the roll entirely.
4. **Announce** — `WorldDeltaLog.host_record(Vector2i.ZERO, &"cycle", "current", cycle)`, the same
   generic-log reuse `MireGrid` proved in 4.9 (D-099), so a late joiner reads the real Cycle number
   instead of the class default. No new RPC (D-100) — `net_version.gd`/`handshake_check.gd` were held
   all session by another lane's task 3.7 claim. Plus `EVENT_BUS.emit_cycle_advanced()` and a
   `MireLog.info` line.

`host_advance_cycle()` is public and host-guarded (`_owns_cycle()`, same shape as
`MireGrid._owns_simulation()`) so both the real day-count path and a new `cycle status|advance`
console command (docs/COMMANDS.md §7 convention) drive the identical code.

**Where this deviates from the M6 gate bullet that used to sit here:** that bullet (written before
this task, now superseded by this block) named `core/game_state.gd` as the autoload and "Wellspring/
extraction events" as the advance trigger. Neither survived contact with the actual source of truth,
`DESIGN.md` §5.1, which is explicit about "~3 in-game days" as the trigger and does not mention
Wellsprings or extraction advancing a Cycle at all (Wellspring caps recede the Mire locally and
reduce its spread rate — §4.2/4.9 — a separate mechanic from the Cycle clock). `game_state.gd`'s own
header comment ("task 6.1 is where the rest of that slot gets built") reserved the *file path*, not a
mandate to grow that specific file — `game_state.gd` is scoped to run-seed authority (task 4.6) and
mixing an unrelated state machine into it would blur that scope for no benefit; a dedicated
`systems/cycle/cycle_service.gd` matches the one-file-per-system pattern every other Cycle-adjacent
autoload here already uses (`MireGrid`, `WaveSpawner`, `DayNight`).

Verify: `tools/cycle_check.gd` — the autoload is registered and really subscribed to the real
`DayNight`'s signal (not a fake harness-built one — the F-068 lesson `wave_spawner_check.gd` already
records), `host_advance_cycle()` increments the Cycle, escalates `MireGrid`'s multiplier, expands
`WaveSpawner`'s pool with real content, and is a no-op (not a crash) past `roster_order`'s end; three
`day_started` crossings advance exactly one Cycle and one or two crossings do not; the announce reaches
both an `EventBus` subscriber and `WorldDeltaLog`'s late-joiner snapshot. `mire_grid_check.gd`,
`wave_spawner_check.gd` and `mire_interaction_check.gd` must stay `failures=0` — this task's real
regression bar, since none of their own behavior should change when `_cycle_spread_multiplier`/
`roster_order` sit at their unchanged defaults (1.0 / one entry never yet unlocked).
Done means: `cycle_check.gd` plus the three regression checks all green, 0 `ERROR:` on a full boot
(`agent godot --quit-after 20`), and `docs/DELEGATION.md`'s Current state carries `CycleService`'s
public API (`current_cycle()`, `host_advance_cycle()`, `spread_multiplier()`) for 6.2's Cycle
Modifier framework to build against.

## 6.2 · Cycle Modifier framework: deck, draw, stacking, Cycle-weighted rules, incompatibility tags (`DESIGN.md` §5.1 item 2)

**Authority:** §2.2 row "Day/night, wave director, Cycle state, active modifiers: HOST" — only the
host draws and stacks; every other peer reads a replicated copy.
**Claim:** `systems/cycle/cycle_modifier_def.gd` (+ its `.uid`), `systems/cycle/cycle_modifier_service.gd`
(+ its `.uid`), `content/cycle_modifiers/long_night.tres`, `core/events/event_bus.gd`,
`autoload/registry.gd`, `tools/cycle_modifier_check.gd` (+ its `.uid`). `project.godot` is registered
via `agent autoload CycleModifierService systems/cycle/cycle_modifier_service.gd` (F-051) — never
claimed. **If `autoload/registry.gd` is held by another lane when you start**, build
`CycleModifierService`'s own content loader first (see the content-loading paragraph below for the
exact fallback shape) and fold it into Registry the moment the file frees up, in the same session if
possible — it did for this task (lane lp's 5.3 claim released mid-session).

DESIGN.md §5.1 item 2, deferred out of task 6.1 by D-100: "A Cycle Modifier is drawn from a deck and
announced." New autoload `CycleModifierService` subscribes to `EventBus.subscribe_cycle_advanced()`
(the seam 6.1 built for exactly this) and draws one modifier from the deck the instant a Cycle
advances, stacking it permanently for the rest of the run (DESIGN.md: "modifiers stack across a
run").

**`CycleModifierDef`** (`systems/cycle/cycle_modifier_def.gd`) is the content Def, authored one at a
time in `content/cycle_modifiers/*.tres` (AGENTS.md — never bulk-generate content data; this task
ships one worked example, `long_night.tres`, matching DESIGN.md's own first illustration):
- `id`, `display_name`, `description` — same shape as every other content family.
- `min_cycle: int` + `base_weight: float` + `weight_growth_per_cycle: float` — Cycle-weighted rules.
  `weight_at(cycle)` returns 0 below `min_cycle`, else `base_weight + weight_growth_per_cycle *
  (cycle - min_cycle)`, floored at 0. Linear, not a `Curve` resource — simpler to author for a first
  framework pass; a `Curve`-based version is a compatible follow-up if linear proves too blunt.
- `tags: Array[StringName]` + `incompatible_tags: Array[StringName]` — incompatibility tags
  (DESIGN.md Q7's own mitigation: "tag modifiers as incompatible"), checked **symmetrically**: a
  candidate is excluded if its own `incompatible_tags` names a tag already active, OR if an
  already-active modifier's `incompatible_tags` names a tag the candidate carries. Either author can
  declare the exclusion once.
- `incompatible_with: Array[StringName]` — explicit id-level exclusion for a pair with no natural
  shared tag. D-103 records why tags are primary and this is the escape hatch, not the reverse.

**`CycleModifierService`** (`systems/cycle/cycle_modifier_service.gd`) is the deck/draw/stacking
engine:
- `_on_cycle_advanced(cycle)` (host-only, via the real `EventBus` subscription) calls
  `host_draw_modifier(cycle)`, which is also public so a console command can force one, mirroring
  `CycleService.host_advance_cycle()`'s own split.
- Eligibility: not already drawn this run (a modifier draws **at most once per run** — the deck
  depletes), `weight_at(cycle) > 0`, and passes both the tag check and the explicit
  `incompatible_with` check against every currently-active modifier.
- Selection: a plain weighted-random pick (`RandomNumberGenerator.randomize()`, not seeded) over the
  eligible set — D-041's precedent for `Chest`'s loot roll applies verbatim: the draw happens once,
  host-only, and no peer ever recomputes it, so real entropy is correct and a fixed seed would buy
  nothing.
- An empty eligible set is a no-op (`MireLog.info`, no crash, no duplicate) — same convention
  `WaveSpawner.host_unlock_next_enemy()` already uses past `roster_order`'s end.
- Announce: **no new RPC** (D-100/D-102's pattern — `core/net/net_version.gd`/`tools/handshake_check.gd`
  were held all session by lane slate17's 3.7 claim). Reuses `WorldDeltaLog` under `kind =
  &"cycle_modifier"`, one key per draw slot (`"0"`, `"1"`, ...) holding that slot's modifier id, plus
  a `"count"` key so a late joiner knows how many slots to read — `active_modifier_ids()` reconstructs
  the ordered stack from these on a client. Plus `EventBus.emit_cycle_modifier_drawn(id, cycle)` (new
  subscriber list, same shape as `cycle_advanced`) and a `MireLog.info` line.
- Public queries: `active_modifier_ids() -> Array[StringName]`, `has_modifier(id) -> bool`,
  `def_for(id) -> Resource`.
- Console command `modifiers` (docs/COMMANDS.md §7 convention, `scope = &"local"`) lists the active
  stack by display name.

**Content loads through `autoload/registry.gd` first**, same as every sibling Def — `CYCLE_MODIFIERS_PATH`
+ `CYCLE_MODIFIER_DEF` + `cycle_modifiers: Dictionary[StringName, Resource]` + one `_load_dir(...)`
call in `Registry._ready()`, with `cycle_modifier_defs()`/`get_cycle_modifier(id)`/
`has_cycle_modifier(id)` as its accessors (D-006's usual boot loader for every content family).
`CycleModifierService._load_defs()` asks Registry (`get_node_or_null(^"/root/Registry")` +
`.call("cycle_modifier_defs")`) and only falls back to its own direct disk scan
(`_load_defs_from_disk()`, quieter and duplicating `Registry._load_dir`'s exact contract) when
Registry is not present under `/root` — the identical "front door, then a seatbelt for a
hand-instantiated harness" split `RuleService._load_defs()`/`_load_defs_from_disk()` already
establishes for rules. `registry.gd` was held all session by lane lp's 5.3 claim when this task
started, so the fallback shipped first and the fold happened once 5.3 released it — see D-103.

**F-016 discipline throughout:** `CycleModifierDef` is a brand-new `class_name` this same commit —
never referenced as a bare static type anywhere outside its own file. Every def is stored and passed
as `Resource`, read via `.get(&"field")`/`.call("method")`, and identity-checked against the
preloaded `CYCLE_MODIFIER_DEF` script constant, exactly the split `RuleDef`/`RuleService` and
`HookDef`/`CommandService` already establish.

**No modifier EFFECT is wired to any gameplay system.** `long_night.tres`'s description names what it
should eventually do (double night length); nothing here touches `DayNight`. This is the identical
scope cut D-094 made for `HookDef`/gameplay-by-hook and D-100 made for the draw itself: a framework
task deciding what the first piece of modifier-driven gameplay actually IS would be scope creep
against a task titled "framework." `EventBus.subscribe_cycle_modifier_drawn()` and
`CycleModifierService.has_modifier(id)` are the seam a future consumer hangs a real effect off.

Verify: `tools/cycle_modifier_check.gd` — wiring (the shipped autoload really loaded
`long_night.tres`, not a fake harness-built def), `CycleModifierDef.weight_at()`'s Cycle-weighted
math (below/at/past `min_cycle`, negative growth floors at 0), a REAL `CycleService.host_advance_cycle()`
→ `EventBus` → draw → `WorldDeltaLog` chain (not a synthetic emission), deck exhaustion as a no-op,
and both directions of the symmetric tag check plus the explicit `incompatible_with` check via
injected synthetic defs (same "read/write an autoload's private state directly" convention
`cycle_check.gd` already uses). `tools/cycle_check.gd`, `tools/mire_grid_check.gd` and
`tools/wave_spawner_check.gd` must stay `failures=0` — this task's regression bar, since `EventBus`
gained a new signal list but no existing one changed shape. `agent godot --quit-after 20` must show
0 `ERROR:` lines.
Done means: `cycle_modifier_check.gd` at `failures=0` (15 assertions), the three regression checks
green, 0 `ERROR:` on a full boot, and `docs/DELEGATION.md`'s Current state carrying
`CycleModifierService`'s public API for 6.3 (content authoring) and any future modifier-effect
consumer to build against.

## 6.4 · Wellspring re-corruption over time (`DESIGN.md` §5.1 item 1; `ROADMAP.md`'s own line: "decay on a host timer unless Warded")

Built ahead of 6.3 (content authoring) — the same "prerequisite, not a scope grab" shape D-099 already
named for 4.11 building ahead of 4.9's completion order. 6.3's Cycle Modifiers and this task's clock
are independent consumers of the same `EventBus.cycle_advanced` seam; neither blocks the other.

**Authority:** §2.2 row "Wellspring ritual" (extended this task to cover the re-corruption clock) —
**Host**. Only the host ticks `recorruption_sec`, checks Ward coverage, and decides when the clock
finishes; every other peer reads the replicated result.
**Claim:** `systems/wellspring/wellspring.gd`, `core/events/event_bus.gd`, `world/mire/mire_grid.gd`,
`tools/wellspring_recorruption_check.gd` (+ its `.uid`). No new autoload, no `project.godot` edit —
this extends the existing `Wellspring` node task 4.8 already ships.

DESIGN.md §5.1: "at the end of each Cycle, three things happen: 1. Mire base spread rate increases,
permanently. Capped Wellsprings begin re-corrupting. 2. A Cycle Modifier is drawn... 3. Enemy roster
expands." Items 2 and 3 are 6.2's and 6.1's own jobs; this task is the first sentence of item 1's
second half, which neither 6.1 nor 6.2 touched.

**The clock.** `Wellspring._on_cycle_advanced()` subscribes to `EventBus.cycle_advanced` (6.1's seam)
and, the first time it fires while `capped == true`, sets host-only `_recorruption_active = true` and
resumes `set_process(true)`. From then on `host_tick()` — the same method the ritual already exposes
so a check can cross a whole 60-150s attempt in one call — also advances a new replicated
`recorruption_sec: float` toward `RECORRUPTION_DURATION_SEC` (900s, placeholder-tuned; D-104) each
frame, UNLESS `_is_warded()` reports a placed Ward covers this Wellspring's position, in which case
the clock pauses (not resets) for that frame — ROADMAP.md's own "unless Warded" line, D-104.
`_is_warded()` reuses `BuildService.ward_radii()`, the identical source `MireGrid`'s own
`_ward_circles_provider` already consumes for spread resistance (task 4.11), rather than adding a
second Ward-reading seam. Reaching `RECORRUPTION_DURATION_SEC` runs `_finish_recorruption()`: `capped`
flips back to `false` — the Wellspring's exact pre-ritual state, so `request_toggle_channel()`
recaptures it with zero special-casing — a new replicated `has_recorrupted: bool` becomes (and stays)
`true`, `recorruption_sec` resets to 0, and `EventBus.emit_wellspring_recorrupted(name,
global_position)` fires (new subscriber list, same shape as `wellspring_capped`).

**The visual.** Both new replicated fields feed `_mesh_path_for_state()`, which now picks among all
four A-008 condition-state GLBs (`assets/wellsprings/README.md`'s state-swap contract), not just two:
capped below `RECORRUPTING_VISUAL_FRACTION` (0.5) of the clock shows `wellspring_capped.glb`; capped
at or past it shows the visibly-decaying `wellspring_recorrupting.glb`; uncapped and never capped
shows the original `wellspring_uncapped.glb`; uncapped via `has_recorrupted == true` shows the worse
`wellspring_corrupted.glb`. Every replicated field's setter funnels through `_maybe_refresh_visual()`,
which recomputes the target path and only schedules the (deferred) rebuild when it actually changed —
`recorruption_sec` changes every tick while the clock runs, so this is the difference between one
mesh swap per state crossing and one per frame.

**`MireGrid` is the finish event's real consumer.** `_on_wellspring_recorrupted()` — the symmetric
half of the existing `_on_wellspring_capped()` — decrements `_capped_wellsprings`, undoing the
per-cap spread-rate reduction (`SPREAD_REDUCTION_PER_CAP`) the cap granted. It does NOT hand-reseed
the 48m cleared radius: `MireGridSim.tick()`'s flood-fill already regrows a zeroed circle from its
still-corrupted edge inward once the multiplier lifts, the same mechanic every other cleared cell on
the map uses (D-104 records why a second SIM function would just duplicate that by hand).

Verify: `tools/wellspring_recorruption_check.gd` (24 assertions) — a capped Wellspring does not
degrade absent a Cycle turnover, however long `host_tick()` runs; a turnover starts the clock without
instantly finishing it; the mesh crosses into the re-corrupting state at the visual threshold while
still capped; a full clock flips `capped` false, sets `has_recorrupted`, fires
`emit_wellspring_recorrupted` exactly once, and shows the corrupted (not original uncapped) mesh; a
placed Ward pauses accrual entirely and accrual resumes the instant it is gone; `MireGrid`'s capped
count goes up on cap and back down on full re-corruption; and a recaptured Wellspring waits for its
OWN next Cycle turnover rather than resuming a stale clock. `tools/wellspring_check.gd`,
`tools/mire_grid_check.gd`, `tools/mire_interaction_check.gd`, `tools/build_check.gd`,
`tools/cycle_check.gd`, `tools/cycle_modifier_check.gd` and `tools/wave_spawner_check.gd` all stay
`failures=0` — the regression bar, since `Wellspring`'s existing ritual fields, `MireGrid`'s existing
tick, and `EventBus`'s existing signal lists all keep their prior shape. `agent godot --quit-after 20`
shows 0 `ERROR:` lines.
Done means: `wellspring_recorruption_check.gd` at `failures=0`, all seven regression checks green,
0 `ERROR:` on a full boot, and `docs/DELEGATION.md`'s Current state carrying the new replicated
fields and `EventBus.subscribe_wellspring_recorrupted()` for whatever future task adds a HUD warning
before a Wellspring finishes decaying (F-164 — no such warning exists yet; the in-world mesh swap is
the only signal today).

---

## 6.5 · Extraction: shipwreck POI, repair recipe, board-to-leave, group confirm flow (`DESIGN.md` §5.2)

Written retroactively by the task that executed it (lm) — no block existed here beforehand; SPECS.md's
own preamble makes writing one part of the task that discovers the gap.

**Authority:** new §2.2 row "Extraction" — **Host**. `ExtractionShip` holds
`repair_stage`/`departure_channeling`/`departure_progress_sec`/`departure_required_players`/`departed`;
only the host advances or resolves any of them, same "harvest pattern" as Wellspring's ritual and
Chest's open.
**Claim:** `systems/extraction/extraction_ship.gd` (new), `autoload/extraction_service.gd` (new),
`ui/hud/extraction_hud.gd` (new), `tools/extraction_check.gd` (new), `core/events/event_bus.gd`,
`project.godot` (two `agent autoload` registrations: `ExtractionService`, `ExtractionHud`).

DESIGN.md §5.2: repairable "from Cycle 3" with "mid-tier resources"; boarding "ends the run
successfully: you bank your full Salvage." No Salvage economy exists yet (6.6's job) and no lose
condition exists yet (6.7's job) — this task's whole scope is the mechanic up to and including the
moment the crew departs, ending in one `EventBus` signal those two later tasks build on.

**Assembly.** `ExtractionShip` follows `assets/ships/README.md`'s ship-frame contract exactly: hull,
mast and sail swap per `repair_stage` (0 wrecked .. 3 repaired) using the README's own state->rig
pairing (`mast_broken` for stages 0-1, `mast` + `sail_furled` at stage 2, `sail_raised` only once
fully repaired); rudder, boarding ramp and cargo hatch are always present. A `BoxShape3D` collider
approximates the repaired hull's footprint (state drift across all four hull states is 0.0000mm per
the asset's own README, so one box covers every stage).

**Repair.** `net_request_repair()` (client → host, no payload) is accepted only when: `CycleService.
current_cycle() >= 3`; the requester is within `REPAIR_RANGE_M` (5m); the requester holds a
`repair_hammer` (its own item description: "For mending wards. Also for endings."); and
`InventoryService.host_can_remove()` passes for every entry in `REPAIR_COSTS[repair_stage]`. On
success, `InventoryService.host_transaction()` consumes them atomically and `repair_stage` advances
by exactly one — one call per stage, not a timer. `REPAIR_COSTS` is plain tuning data on the node
(D-106 records why this is NOT a `RecipeDef`/`CraftingService` station, despite an earlier look-ahead
note in this file suggesting "via recipes" — checked and rejected: `CraftingService`'s station model
is a static content registry granting items, and this both needs a runtime-built "station" and grants
no item at all). Reaching the final stage fires `EventBus.emit_ship_repaired()`.

**Board-to-leave / group confirm.** Reachable only once `repair_stage == REPAIR_STAGE_COUNT`.
`net_request_toggle_departure()` reuses Wellspring's own channel FSM verbatim (D-105): an in-range
press starts a hold, `host_tick()` advances `departure_progress_sec` toward `DEPARTURE_HOLD_SEC` (60s)
only while `_present_count(BOARD_RANGE_M) >= departure_required_players` (snapshotted at start to the
WHOLE connected session, not Wellspring's 1-2), a second press cancels and forfeits progress outright,
and merely stepping off deck only pauses it. Completion sets `departed = true` (terminal) and fires
`EventBus.emit_run_extracted(cycle, world_position)` — the ONE seam a successful run fires. Nothing
banks Salvage, tears down the session, or shows a summary here.

**The marker bridge.** `autoload/extraction_service.gd` mirrors `wellspring_service.gd` exactly: it
watches `&"authored_world_marker"` for a `kind == "shipwreck"` child and builds a live `ExtractionShip`
there. `world/gen/authored_world.gd` has no such marker yet (F-166) — it was held by another lane's
claim this task's entire session, so this system is complete and tested but not reachable in the live
Hollowmere map today, the same shape F-139/F-146 already established as acceptable for an
unreachable-but-correct system. `content/poi/shipwreck.tres` (task 4.7's procedural PoiMap, target
3/island) is NOT the placement source here, on purpose — F-139 already recorded that the live game
ships the authored map, not the procedural pipeline, so building against PoiMap would not have made
this any more reachable today.

**PROTOCOL_VERSION was not bumped.** `core/net/net_version.gd` and `tools/handshake_check.gd` were
both held by another lane's claim this task's entire session — F-165 records the two new RPCs that
need it whenever that file frees up, alongside F-161's still-open 5.3 entry.

Verify: `tools/extraction_check.gd` (34 assertions) — autoload wiring; a `shipwreck` marker builds
exactly one `ExtractionShip`, a non-matching marker builds none; repair is rejected before Cycle 3,
out of range, without the hammer, or without the stage's resources, and consumes exactly what it
costs on success, advancing one stage per call through all three; the departure hold is unreachable
before repair completes, toggles start/cancel the same way Wellspring's does, pauses under-presence
and resumes once the whole crew is aboard, and fires `run_extracted` exactly once on completion.
`wellspring_check`, `cycle_check`, `cycle_modifier_check`, `wave_spawner_check`, `crafting_check`,
`mire_grid_check`, `mire_interaction_check`, `handshake_check` all stay `failures=0`. `agent godot
--quit-after 15` shows 0 `ERROR:` lines.
Done means: `extraction_check.gd` at `failures=0`, the eight regression checks green, 0 `ERROR:` on a
full boot, and `docs/DELEGATION.md`'s Current state carrying `EventBus.subscribe_run_extracted()` /
`subscribe_ship_repaired()` for 6.6 and 6.7 to build against — and naming that 6.7 (lose condition)
has no stated dependency on 6.6, so it can go first and unblock 6.6's "extract-vs-die split" rather
than waiting on it.

---

## 6.6 · Salvage: superlinear reward curve, extract-vs-die split, persistence, save-file versioning (`DESIGN.md` §4.6, §5.2)

Written retroactively by the task that executed it (lm) — no block existed here beforehand;
SPECS.md's own preamble makes writing one part of the task that discovers the gap. The bullet this
replaces (below the old M6 remaining-tasks list) named the shape correctly — `user://salvage.json`,
`schema_version: 1`, migration from day one — and this block follows it rather than relitigating it.

**Authority:** new §2.2 row "Salvage" — **None**. Salvage is per-player account state, not
simulation state: no two peers ever compare balances, so the authority table's "would two clients
disagree" test never applies. Every peer runs the identical autoload and banks only into its own
`user://salvage.json`, reacting only to events it received on its own process-local `EventBus`.

**Claim:** `autoload/salvage_service.gd` (new), `core/save/salvage_save.gd` (new),
`tools/salvage_check.gd` (new), `core/events/event_bus.gd`, `systems/extraction/extraction_ship.gd`,
`project.godot` (one `agent autoload` registration: `SalvageService`).

**The reward curve.** `SalvageService.reward_for_cycle(cycle)` returns
`CYCLE_BASE * cycle^CYCLE_EXPONENT + milestone_bonus`, `CYCLE_BASE = 10`, `CYCLE_EXPONENT = 1.6` —
superlinear by construction (an exponent > 1), satisfying DESIGN.md §5.2's "Cycle 9 worth much more
than 3x Cycle 3" (measured: Cycle 3 = 58, Cycle 9 = 336, ~5.8x for 3x the Cycle). Placeholder-tuned,
same unplaytested status as every other Cycle-facing constant in this codebase
(`CycleService.SPREAD_ESCALATION_PER_CYCLE`, `ExtractionShip.REPAIR_COSTS`) — nothing here survives
contact with Q6 ("does anyone ever actually extract") yet.

**Milestone bonus.** DESIGN.md §4.6 names three secondary factors: "Wellsprings capped, bosses
killed, tiers reached." Only the first is real and trackable today (`EventBus.wellspring_capped`
already exists, +20 Salvage per cap this run via `WELLSPRING_CAP_BONUS`) — no boss enemy concept
exists anywhere in the codebase, and nothing announces a crafting tier as "reached" this run. D-108
records this as a deliberate scope cut, not an oversight: adding either later is one more
`EventBus` subscription and one more counter, the same shape `_wellsprings_capped_this_run` already
is, not a reward-formula change.

**Extract-vs-die split.** `EventBus.subscribe_run_extracted()` (task 6.5) banks
`reward_for_cycle(cycle)` in full. A new `EventBus.subscribe_run_wiped(cycle, world_position)`
counterpart — DESIGN.md §5.2's "dying instead banks a fraction" — banks
`round(reward_for_cycle(cycle) * DEATH_BANK_FRACTION)`, `DEATH_BANK_FRACTION = 0.5`. **Nothing emits
`run_wiped` yet.** Task 6.7 ("Lose condition") owns deciding when a run has actually ended in
defeat (team wipe with no bleed-out revive pending, or the island consumed —
`docs/SPECS.md`'s own 6.7 look-ahead); 6.6 only builds the seam and the consumer, the same "future
task's hook" shape D-092 established for `wellspring_capped`. D-108 records why 6.7 must call this
exact signal rather than inventing a second one, and why its emitter MUST fire from a replicated
property's setter (reaching every peer's own local `EventBus`) rather than a host-only guard —
`event_bus.gd`'s own doc comment on `run_wiped` spells out the exact trap this task found and fixed
for `run_extracted`.

**The `run_extracted` host-only gap, fixed.** `ExtractionShip._finish_departure()` used to call
`EVENT_BUS.emit_run_extracted()` directly, inside a host-only code path — harmless for the host's
own Salvage, but a NON-host peer's local `EventBus` never received the event at all, so that
player's own save would never bank. Moved the emit into `departed`'s property setter instead (the
same pattern `repair_stage`'s setter already used for `_maybe_refresh_visual()`): the setter fires
identically whether this process just set `departed = true` itself (the host) or received it over
the wire via the existing `SceneReplicationConfig` (a client) — no new RPC, no protocol bump.
`Wellspring._finish_cap()` still has the identical host-only shape for `wellspring_capped`, which
means the milestone bonus above undercounts on non-host peers today; F-168 records that as a
separate, smaller gap rather than expanding this task into a second system's file.

**Persistence.** `core/save/salvage_save.gd` is pure data I/O — `load_data(path)` /
`save_data(data, path)`, both defaulting to `user://salvage.json`, both taking an explicit `path`
override so `tools/salvage_check.gd` never touches a real save. `schema_version: 1` is stamped on
every write; `_migrate()` is the switch DESIGN wants "from day one" — today it only backfills a
missing/old version to defaults (there is no real prior schema to migrate FROM yet), and every
future bump adds one more `if version < N:` block rather than a reader that has to understand every
historical shape. A missing or corrupt file resolves to a safe default instead of an error.

**Test-harness persistence isolation (D-107) — the trap 6.9 must reuse, not rediscover.**
`EventBus` is a per-process static: any `--script` check that legitimately fires a real
`run_extracted`/`wellspring_capped` for ITS OWN system's test (confirmed with
`tools/extraction_check.gd`'s departure-hold tests, which banked 116 real Salvage into this
developer's actual save before the guard existed) reaches `SalvageService` exactly like the shipped
game would. `SalvageService._persistence_enabled()` gates every disk write on
`save_path != SalvageSave.SAVE_PATH or get_tree().current_scene != null` — a `--script` harness
never loads `project.godot`'s `run/main_scene`, so `current_scene` stays null for its whole run,
while the real game (and a `--quit-after N` full-boot check) always has one. `salvage_check.gd`
opts back in by overriding `save_path` to a throwaway file before banking, which both isolates its
writes AND proves persistence for real. Task 6.9 ("Unlock tree... local persistence beside 6.6's
file") inherits this exact trap the moment it writes to `user://` from an event handler — reuse
this guard shape, don't re-derive it.

Verify: `tools/salvage_check.gd` (24 assertions) — autoload wiring; the curve is superlinear and
convex and floors at Cycle 1; each Wellspring capped this run adds the same flat bonus and the
tally resets once a run ends; extraction banks the reward in full while a wipe banks exactly
`DEATH_BANK_FRACTION` of it, both writing through to disk and firing `salvage_banked` once with the
right payload; `SalvageSave`'s versioning migrates an old/missing schema up, round-trips data
losslessly, and resolves a missing or corrupt file to a safe default without crashing.
`extraction_check`, `wellspring_recorruption_check`, `cycle_check`, `cycle_modifier_check`,
`mire_grid_check`, `mire_interaction_check`, `wave_spawner_check`, `crafting_check`,
`handshake_check` all stay `failures=0` (or `confirmations=N failures=0`), and none of them leaves a
real `user://salvage.json` behind any more. `agent godot --quit-after 15` shows 0 `ERROR:` lines.
Done means: `salvage_check.gd` at `failures=0`, the nine regression checks green, 0 `ERROR:` on a
full boot, no real save-file pollution from an unrelated check, and `docs/DELEGATION.md`'s Current
state carrying `SalvageService.total_salvage()` / `EventBus.subscribe_salvage_banked()` for 6.8's
run summary and 6.9's unlock tree to build against.

---

## 6.7 · Lose condition: team wipe / island consumed, defeat flow (`DESIGN.md` §5.3)

No block existed here beforehand; SPECS.md's own preamble makes writing one part of the task that
discovers the gap. DESIGN.md §5.3 is the actual source of truth: "Losing = all players down
simultaneously with no revive available, or the Mire consumes the island." The old M6
remaining-tasks bullet this replaces named `game_state.gd` as the destination — superseded; see
D-109 for why that reservation does not survive contact the same way task 6.1 already found for
`CycleService`.

**Authority:** new §2.2 row "Lose condition — team wipe / island consumed" — **Host** decides the
verdict; a reliable broadcast RPC carries it to every peer, not a `MultiplayerSynchronizer` (D-109
explains why a synchronizer, D-023's usual mechanism, is the wrong tool for a one-shot terminal
event with no late joiner to catch up).

**Claim:** `autoload/defeat_service.gd` (new), `ui/hud/defeat_hud.gd` (new),
`world/mire/mire_grid.gd`, `systems/health/player_health.gd`, `systems/health/downed_state.gd`
(doc-only), `tools/defeat_check.gd` (new). `project.godot` — two `agent autoload` registrations,
`DefeatService` then `DefeatHud` (the latter after `SalvageService`, for the reason its own header
comment gives).

**Team wipe.** `DefeatService._physics_process` polls, every host tick, whether every peer in the
`&"players"` group (the same "who is actually here right now" signal `ExtractionShip`'s own
presence checks already use, not `NetTransport.peer_ids()` — see that method's own note on why) reads
`PlayerHealth.host_is_alive() == false`. DESIGN's "no revive available" needs no separate check: a
revive requires an ALIVE reviver, so the instant nobody is alive, nobody could revive anyone either.
"Down" (not full DEAD/bled-out) is already enough — D-109 spells out why.

**Island consumed.** New `MireGrid.consumed_fraction(threshold)` (host-only, mirrors
`corruption_at()`'s own peer split) walks the 256x256 grid and returns what fraction sits at or
above `threshold`. `DefeatService` polls it on a 5s accumulator (the only one of the two triggers
worth throttling — it is a 65536-cell walk) and fires once `ISLAND_CONSUMED_FRACTION = 0.97` of the
grid sits at or above `ISLAND_CONSUMED_CORRUPTION = 0.95`. Both numbers are placeholder-tuned; D-109
explains why a fraction, not "every cell."

**Firing the verdict without a host-only guard (D-108's actual requirement).** `defeated`'s setter
fires `EventBus.emit_run_wiped(cycle, world_position)` — the exact seam `SalvageService` (task 6.6)
already consumes and was waiting on. The host calls `_apply_defeat()` directly (which sets `cause`
then `defeated = true`, firing the emit on the host's own process) and broadcasts `net_run_defeated`
to every connected peer; each client's own `net_run_defeated` handler calls the SAME `_apply_defeat()`,
so the emit reaches that peer's own local `EventBus` too — never a host-only `if` around the emit
call, the shape `Wellspring._finish_cap()` still has (F-168) and D-108 named as the trap to avoid.
No `PROTOCOL_VERSION` bump for `net_run_defeated` — `core/net/net_version.gd` was held by lane
slate17's 3.7 claim all session (F-169, same gap F-161/F-165 already recorded).

**Freezing `PlayerHealth` — the trap this task exists to close.** Before this task, `DownedState`'s
own FSM (DEAD -[respawn_remaining expires]-> ALIVE) ran unconditionally: a real team wipe would
bleed everyone out to DEAD and then auto-respawn them all a few seconds later, silently undoing the
verdict. `PlayerHealth` now subscribes `EventBus.subscribe_run_wiped` and latches `_run_over = true`
the instant it fires (on every peer — the fix above means every peer's own subscription actually
receives it); `_physics_process` and `host_apply_damage` both early-return while `_run_over` is set,
so no timer advances and no further hit lands. Cleared alongside every other session-scoped flag in
`_on_session_opened()`/`_on_disconnected()`.

**The defeat flow.** `ui/hud/defeat_hud.gd` (new autoload, code-built `CanvasLayer` — same reasoning
`extraction_hud.gd` gives for not needing a hand-authored scene) reacts to `run_wiped` client-locally:
a full-screen overlay names the cause (`CAUSE_HEADLINES`, keyed off `DefeatService.cause`) and the
Cycle reached, joins `blocks_gameplay_input` (D-032, same group `inventory_ui.gd`/`lobby_menu.gd`
use) so `player_controller.gd`'s `gameplay_input_allowed()` stops the local player without pausing
the tree, and updates its detail line with the actual banked Salvage once `salvage_banked` arrives
(filtered on `extracted == false`, so a later successful extraction's own bank never overwrites a
death screen that is not showing). No scene transition / return-to-menu — that infrastructure does
not exist anywhere yet, not even for a successful extraction (6.5/6.6 shipped no win screen either);
building one is out of scope here and belongs with 6.8/6.10's UI work.

Verify: `tools/defeat_check.gd` (24 assertions) — `consumed_fraction()` reports the real fraction at
a fully seeded, fully saturated, and half-saturated grid; one peer down out of two is never a wipe,
both down fires exactly one `run_wiped` carrying the real Cycle, a second tick after defeat fires no
more, an empty player roster is never read as a wipe; the verdict latches `PlayerHealth._run_over`,
rejects further damage, and survives a 100-second `_physics_process` tick without auto-respawning a
downed peer; a saturated grid trips `island_consumed` independently of team-wipe; and — the check
that actually proves D-108's requirement — calling `net_run_defeated` directly (the code path a real
client takes, not the host's own trigger) drives `defeated`/`cause` and fires `run_wiped` on its own.
No regressions: `player_health_check`, `player_vitals_check`, `extraction_check`, `salvage_check`,
`mire_grid_check`, `mire_interaction_check`, `wellspring_recorruption_check`, `cycle_check`,
`cycle_modifier_check`, `wave_spawner_check` all stay `failures=0` / `0 failure(s)`. `agent godot
--quit-after 15` shows 0 `ERROR:` lines.
Done means: `defeat_check.gd` at `failures=0`, the ten regression checks green, 0 `ERROR:` on a full
boot, and `docs/DELEGATION.md`'s Current state carrying `DefeatService.is_defeated()`/`cause` for
6.8's run summary to build against.

---

## 6.9 · Unlock tree + UI. Variety only, never power (`DESIGN.md` §4.6)

No block existed here beforehand; SPECS.md's own preamble makes writing one part of the task that
discovers the gap. DESIGN.md §4.6 is the actual source of truth: "Salvage unlocks variety, never
power. Unlockable: new powerups in the pool, new Attunements, new POI types, new enemy types, new
Cycle Modifiers, new island modifiers, cosmetics, new starting loadout options (sidegrades). Never
unlockable: +damage, +health, permanent stat boosts." Builds directly on task 6.6's Salvage —
`SalvageService.total_salvage()`/a new `spend_salvage()` this task adds.

**Authority:** new §2.2 row "Unlocks" — **None**, identical reasoning and shape to Salvage's own row
(task 6.6, D-107): per-player account state in `user://unlocks.json`, no two peers ever compare
purchased sets, every peer runs the same autoload reacting only to its own local calls.

**Claim:** `systems/unlocks/unlock_def.gd` (new), `content/unlocks/` (new dir, one worked example),
`core/save/unlock_save.gd` (new), `autoload/unlock_service.gd` (new), `ui/menu/unlock_menu.gd`
(new), `tools/unlock_check.gd` (new), `autoload/registry.gd`, `autoload/salvage_service.gd`,
`core/events/event_bus.gd`, `ui/menu/main_menu.gd`. `project.godot` — two `agent autoload`
registrations, `UnlockService` (anywhere after `Registry`/`SalvageService`) and `UnlockMenu`
(before `MainMenu`, same "opened by node path" convention `SettingsMenu` already uses).

**"Never power" is a schema fact, not a runtime check.** `UnlockDef` (id, `category` — a closed
§4.6 vocabulary: `powerup`/`attunement`/`poi`/`enemy`/`cycle_modifier`/`island_modifier`/
`cosmetic`/`loadout` — `display_name`, `description`, `cost`, `gates_id`) has no numeric stat/bonus
field anywhere on it, the same D-044 shape that already makes a stray stat impossible to author
onto `PowerupDef`. There is no code path by which spending Salvage here could raise a number; the
only thing a purchase can ever do is flip one boolean.

**`UnlockService`** (autoload, `user://unlocks.json` via `core/save/unlock_save.gd` — a sibling
save file to `SalvageSave`, not a second top-level key on it, per 6.6's own delegation note) tracks
which ids this peer has purchased. `purchase(unlock_id)` spends through
`SalvageService.spend_salvage(cost)` and marks the id purchased as one attempt — a refusal (already
owned, unknown id, persistence disabled, insufficient Salvage) changes nothing on either side, the
same "price and grant as one transaction" shape `Chest._accept_open_request()` already uses for
coins. `is_content_unlocked(content_id)` is the gate seam a future consumer calls before adding
something to a pool: true when nothing gates `content_id`, true once the UnlockDef that gates it is
purchased, false otherwise. Same D-107 `_persistence_enabled()` guard as `SalvageService` — a
`--script` check that forgets to override `save_path` cannot write a real player's save.

**`SalvageService.spend_salvage(amount)`** (new) is the inverse of the existing `_bank()`: refuses
the whole thing — balance and disk both untouched — rather than partially applying it, on a
non-positive amount, disabled persistence, or a short balance. The one Salvage sink other than the
existing banking path; any future spend reuses this rather than writing `total_salvage` itself.

**`EventBus.emit_unlock_purchased(unlock_id, cost, total_salvage)`** (new) fires once per purchase,
the same "future task's hook" role `salvage_banked` plays for 6.8's run summary — nothing here
shows UI or gates a pool on its own.

**The worked example does not wire a live gameplay gate — see F-173.** DESIGN.md's own list leads
with "new powerups in the pool," and a real gate exists to prove against
(`content/loot/bog.tres` already rolls the `deep_pocket` PowerupDef). `content/unlocks/
unlock_deep_pocket.tres` gates it (D-073: one worked example, Sequoyah authors the rest). But
`LootTableDef.roll()` is called once, host-side, for whichever peer opened the chest — and
`is_content_unlocked()` only ever answers for the CALLING peer's own local `user://unlocks.json`.
Wiring the check into that roll would gate the whole party's odds off whichever peer's save
happens to be asked, or off the host's own save regardless of who opened the chest — neither is
"the opener's own progress," and POI placement/enemy-roster expansion have the identical problem
one level worse (§2.2 requires those to be BYTE-IDENTICAL across every peer, which a per-peer
unlock set cannot give them without a design decision on how). F-173 records the gap and the
options (replicate purchases; or let only the host's own unlock state gate a session, like a
gamerule) for whichever task wires the first real consumer.

**`UnlockMenu`** (new autoload `CanvasLayer`, code-built like `MainMenu`/`SettingsMenu`) lists every
`Registry.unlock_defs()` row (sorted by id, built once — content is boot-time-static, D-073) with a
BUY button that disables once owned or unaffordable. Opened only from `MainMenu`'s new UNLOCKS
button, no hotkey of its own (same "hand off, don't stack" shape D-032 already gives
`SettingsMenu`) — `MainMenu.request_open_unlocks()` closes `MainMenu` first, mirroring
`request_open_settings()`.

Verify: `tools/unlock_check.gd` (40+ assertions) — the worked example loads and indexes through
`Registry`; `UnlockDef.validation_errors()` rejects a blank def, an out-of-vocabulary category, and
a zero-cost row; `spend_salvage()`/`purchase()` both refuse-the-whole-thing on every failure path
and leave balance/disk untouched; a successful purchase charges exactly once, persists, and fires
`unlock_purchased` with the right payload; a repeat purchase of the same id is refused without a
double-charge; `is_content_unlocked()` reads locked before purchase and unlocked after (and true by
default for anything ungated); `UnlockMenu` opens/closes, joins `blocks_gameplay_input`, refuses to
stack with `MainMenu` (D-032), and its BUY button state matches `is_purchased()`; `UnlockSave`
migrates a missing-version file, falls back safely on a corrupt one, and round-trips. No
regressions: `salvage_check`, `main_menu_check`, `defeat_check`, `extraction_check`,
`wellspring_recorruption_check`, `crafting_check`, `cycle_check`, `cycle_modifier_check`,
`mire_grid_check`, `mire_interaction_check`, `wave_spawner_check` all stay `failures=0`. `agent
godot --quit-after 15` shows 0 `ERROR:` lines.
Done means: `unlock_check.gd` at `failures=0`, the eleven regression checks green, 0 `ERROR:` on a
full boot, and `docs/DELEGATION.md`'s Current state carrying `UnlockService.is_content_unlocked()`
for whichever future task resolves F-173 and wires a real gate.

---

## 6.10 · Main menu, lobby UI, settings, seed entry

The old look-ahead bullet below this heading covered only the lobby-UI half, shipped ahead of the
rest under D-030 (`ui/lobby/lobby_menu.gd`, press M — host/join/invite/leave over the already-proven
`SteamLobby` seams). This block is the full spec for what that slice's own handoff left open: "the
main menu shell, settings, and seed entry feeding 4.6." No block existed here beforehand; SPECS.md's
own preamble makes writing one part of the task that discovers the gap.

**Authority:** client-local UI, `ARCHITECTURE.md` §2.2's free last row — same row `LobbyMenu` already
declared. Seed entry stages a value through `GameState.set_pending_seed()`, which is itself
host-only-consumed (only `GameState.host_generate_seed()`/`ensure_seed()` ever read it, and only on
the process that called them) — typing a seed grants a client no new power.

**Claim:** `core/game_state.gd`, `ui/menu/main_menu.gd` (new), `ui/menu/settings_menu.gd` (new),
`tools/main_menu_check.gd` (new). `project.godot` — two `agent autoload` registrations,
`SettingsMenu` then `MainMenu` (load order doesn't actually matter here — both call the panels they
open by node path at request time, not at `_ready` — but this keeps registration order reading the
same way the panels nest).

**Main menu shell.** `ui/menu/main_menu.gd` (new autoload `MainMenu`, code-built `CanvasLayer`,
layer 57 — same construction pattern as `LobbyMenu`: a `Control` root, a shading `ColorRect`, a
`CenterContainer`'d panel). Toggled with **F1** (raw keycode, LobbyMenu's-M/DebugConsole's-backtick
convention), closed with Esc, consumed in `_input` before it reaches anything else. Esc was
deliberately NOT used to open it: `entities/player/player_controller.gd`'s own comment on its
`ui_cancel` handler already reserves that role — "Replaced by the pause menu in M7" — and a menu that
also auto-opens on `ui_cancel` now would be relitigating that reservation four milestones early. Joins
`blocks_gameplay_input` while open and refuses to stack on another cursor UI (D-032); opening the
lobby or settings panel from here calls `set_open(false)` on itself FIRST, then the target panel's
`set_open(true)` — a hand-off, never a stack, the same shape D-032's own note asks of "a future build
menu, ward panel or map."

**Deliberately does not auto-open at boot.** `world/mire/mire_grid.gd` already draws the run seed
inside its own `_ready()` (`GameState.ensure_seed()`) the instant the main scene loads, so there is no
"before the game starts" moment left to gate for solo play — see F-172 for the follow-up this leaves
open. Auto-opening was also rejected on its own merits: every panel already in this game
(`LobbyMenu`/`InventoryUI`/`CraftingUI`/`DebugConsole`/…) opens on a keypress, never automatically,
and this project's verification method leans hard on two-process checks and full-boot smoke runs that
expect to act on the world immediately (D-023) — an auto-shown blocking overlay is exactly the kind of
change that breaks those silently, for every lane, not just this task's own checks.

**Seed entry.** A `LineEdit` + SET button on `MainMenu`. Pure-integer text is staged as-is; anything
else is hashed with `String.hash()` (a fixed algorithm — same result for the same string on every
platform) so a seed can be shared as a memorable word the same way a numeric one gets shared. Empty
text clears a staged override. `core/game_state.gd` gains `set_pending_seed(value)` /
`has_pending_seed()` / `pending_seed()`; `host_generate_seed()` now checks the pending value first and
consumes it once (falling back to real entropy exactly as before when nothing is staged) — `reset()`
is untouched, so a pending seed survives a failed connect attempt for the retry to use. This is the
"seed entry feeding 4.6" the 6.10 look-ahead bullet named: 4.6 (`core/game_state.gd`,
`WorldDeltaLog`) already owns how a drawn seed reaches every peer; this task only changes WHICH value
gets drawn, never who's authoritative for it or how it travels.

**Settings — shell only, not content.** `ui/menu/settings_menu.gd` (new autoload `SettingsMenu`,
same construction pattern, layer 58): the D-032 exclusivity, open/close, and visual frame every future
control needs, with a placeholder label and a `stack` node future rows attach to. Holds no real
settings on purpose — `autoload/graphics_quality.gd`'s own header comment already reserves "Task
7.5's settings menu gets three buttons now," and `docs/SPECS.md`'s own M7 look-ahead names task 7.5 as
the one that ships `user://settings.cfg` persistence and a `SettingsService` autoload for
graphics/audio/sensitivity/keybinds/FOV/accessibility. Building any of that here would be 6.10
designing 6.10's own content ahead of 7.5's own task — the same trap D-089 named for `game_state.gd`
and D-109 named again for `defeat_service.gd`. Opened only from `MainMenu`; no keybind of its own yet,
since nothing inside it needs one.

Verify: `tools/main_menu_check.gd` (29 assertions) — both panels exist, open/close, own the cursor and
the blocking group while open; numeric seed text is staged verbatim, non-numeric text hashes
deterministically (the same word twice stages the same value), empty text clears a staged seed, and a
staged seed provably wins `host_generate_seed()`'s very next draw and is then consumed (not reused);
opening MULTIPLAYER or SETTINGS from `MainMenu` closes it first and opens the target; none of
`MainMenu`/`SettingsMenu`/`LobbyMenu` will open while either of the other two holds the blocking
group. No regressions: `lobby_menu_check` (see F-170 — 5 pre-existing failures on a machine with a
real Steam client running, reproduced on a clean `agent baseline` checkout, unrelated to this task),
`seed_sync_check`, `mire_grid_check`, `resource_scatter_check`, `defeat_check`, `handshake_check`,
`net_check_pattern_check`, `inventory_ui_check` all `failures=0`. `agent godot --quit-after 15` shows
0 `ERROR:` lines.
Done means: `main_menu_check.gd` at `failures=0`, the regression set green, 0 `ERROR:` on a full boot,
and `docs/DELEGATION.md`'s Current state carrying the `MainMenu`/`SettingsMenu`/`GameState` API
surface for 1.12's evidence run and task 7.5 to build against.

---

- **6.3 Author 20–30 modifiers (T0).**
- **6.8 Run summary (T0):** headline Cycle number; stats GameState already accumulated.
- **6.9 Unlock tree (T1):** Salvage spends into **variety only, never power** (D-009/DESIGN §4.6 —
  refuse any stat unlock in review); data-driven nodes, local persistence beside 6.6's file.
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

## F-137 · The build module lives in one `.tres` and nothing else knows it

**Claim:** `tools/construction_check.gd`.

**What was wrong:** `content/buildables/wall.tres` states MIRE's build module as data (`size =
Vector3(2, 3, 0.25)`), and `tools/blender/build_construction_set.py` re-declares the same two numbers
by hand as Python constants (`MODULE = 2.00`, `WALL_H = 3.00`, the latter's own comment naming
`wall.tres` as its source). By the time this task picked it up, task 3.7 had also authored `door.tres`,
`gate.tres`, `palisade.tres`, `palisade_gate.tres`, `dock.tres`, `bridge.tres` and `ladder.tres` —
each restating a footprint that is supposed to tile with the exported construction kit
(`assets/construction/catalog.json`) — so the "two copies of a number, no check between them" problem
the finding named had already grown past the one buildable it was filed against. Nothing anywhere
compared any `BuildableDef.size` to the numbers the engine actually measures off the kit.

**Fix:** `tools/construction_check.gd` gained `_check_buildable_defs()`, called from `_init()` after
`_check_state_drift()`. `wall.tres` has no exported GLB in the kit at all, so it is compared directly
to this file's own `MODULE`/`WALL_H` constants (the same numbers the Blender script hand-declares on
its side). Every other buildable that has a real catalog counterpart is looked up through a small
`id -> frame name` table (`BUILDABLE_FRAME`) and compared to that catalog entry's engine-measured
`run_span_m` (size.x) and `height_m` (size.y) instead — no new hardcoded expectation needed, since
the catalog numbers are already cross-checked against the real GLBs by `_check_asset()` earlier in
the same run. **Depth (size.z) is deliberately never compared** — `buildable_def.gd`'s own doc
comment on `size` says a footprint may be thinner than its art on purpose (confirmed on `gate.tres`:
footprint depth 0.4 m vs. the frame's art depth 0.464 m, an intentional gap, not a bug), so asserting
it would misreport a design choice as drift.

**Trap hit while verifying:** F-148 (already filed, `_check_doors()`'s degenerate-AABB error) has
gotten much worse since it was filed — today's run logged 213,000+ `AABB size is negative` lines and
did not finish inside a 5-minute budget, likely aggravated by task 3.7's in-progress door/gate/
palisade-gate authoring adding more thin triangles to swing-check. Verified this task's own change in
isolation by temporarily commenting out the `_check_doors()` call for one local run only (reverted
before commit, never part of the shipped diff); `_check_doors()` itself is untouched. F-148 raised
from low to medium severity with this update, since it can now make the whole check unusable as a
gate, not just log a spurious error. Not fixed here — still task 3.7's own `.tres`/`.tscn`-adjacent
territory per F-148's original scope note.

**Done means:** `CONSTRUCTION_BUILDABLE_DEFS checked=8` reports zero failures on a clean tree, and
deliberately perturbing the module (e.g. `MODULE = 2.5`) makes `wall.tres`'s check — and only that
class of check — fail, proving the assertion is live rather than vacuous.

**Verified 2026-08-18 (lm):** `agent godot --script tools/construction_check.gd` (with
`_check_doors()` temporarily skipped for this one run to route around F-148's unrelated hang) →
`CONSTRUCTION_BUILDABLE_DEFS checked=8`, `CONSTRUCTION_CHECK PASS`. Sanity-checked the check itself
is not a no-op: temporarily set `MODULE = 2.5` → `FAIL wall.tres: size.x is 2.000 m, the kit's module
is 2.50 m` (plus the pre-existing dock/palisade-corner/ramp checks that already used `MODULE`, as
expected), then reverted to `MODULE = 2.0` and `_check_doors()` re-enabled — `git diff` against the
shipped file shows only the intended `_check_buildable_defs()` addition, no leftover debug edits.

---

## F-138 · Rotating an AABB's corners is still the wrong ruler when the thing you are rotating is a moving part

**Claim:** `tools/construction_check.gd` (none, if only verifying — see below).

**What was wrong:** F-094 already established that `Transform3D * AABB` inflates a rotated object's
measured bounds, and both `tools/ship_check.gd` and `mire_art.world_bounds` measure vertices instead
for that reason. The first draft of `tools/construction_check.gd`'s door-swing test (`_check_doors()`)
reintroduced the same error in a third form — not to measure a static asset, but to *move* one: it
rotated each part's eight AABB corners at ten angles and took the AABB of the result. The box around a
rotated box grows with the angle, so the test reported four innocent leaves colliding with their own
frames at 60–90°, and the frames' own diagonal knee braces (themselves rotated boxes) were inflated
into obstacles on the other side of the same comparison.

**Fix (already shipped by the time this task picked it up — no code change was needed):**
`_measure()` expands each mesh through its index buffer into a triangle soup once (`"points":
vertices` on every measured part, doc comment at `tools/construction_check.gd:125`), and `_check_doors()`
rotates leaf **vertices** through that soup (`basis * vertex + hinge_at`, line 419) and tests them
against frame **per-triangle** bounds built the same way (`solids`, built per-triangle from the
frame's own `points` at lines 395–408) — never `transform * get_aabb()` on either side.

**Trap hit while verifying:** a bare `agent godot --script tools/construction_check.gd` run logs
4.8M+ repeats of F-148's unrelated `AABB size is negative` error (1.4 GB log) because task 3.7's
door/gate/palisade-gate scenes are still uncommitted in the working tree, same trigger F-137 hit. The
run still completes and reaches `_finish()` — F-148 degrades signal-to-noise, it does not hang the
process — so unlike F-137 this task did not need to route around it to get a trustworthy result.

**Done means:** `CONSTRUCTION_DOORS swung=4` with zero door-swing failures on a clean tree, and the
swing test is demonstrably live (not vacuous) — deliberately breaking the leaf's rotation origin makes
it report a collision.

**Verified 2026-08-18 (lm):** `agent godot --script tools/construction_check.gd` → `CONSTRUCTION_DOORS
swung=4`, `CONSTRUCTION_STATE_DRIFT 0.0000 mm`, `CONSTRUCTION_BUILDABLE_DEFS checked=8`,
`CONSTRUCTION_CHECK PASS` — zero door-swing failures, confirming all four hinged leaves (`door`,
`gate`, `palisade_gate_leaf` and one more) swing their full documented arc with no false-positive
contact from an inflated ruler. Confirmed the test is not a no-op: temporarily changed line 419's `+
hinge_at` to `+ hinge_at * 0.0` (rotating each leaf about the world origin instead of its real hinge
post, so it swings straight into geometry it was never aligned with) — re-ran and got
`FAIL palisade_gate_leaf: Gate_Bar_3 is inside the frame at 0 degrees`, `CONSTRUCTION_CHECK
FAIL failures=1`, proving the per-triangle vertex test actually fires. Reverted immediately after;
`git diff tools/construction_check.gd` shows no changes.

---

## F-126 · `CommandService`'s `peer` argument type has no display-name resolution — peer ids only

**Claim:** `autoload/command_service.gd`, `tools/command_check.gd`.

**What was wrong:** `docs/COMMANDS.md` §2.2 specifies `peer` as "peer id int or player display name —
resolves against connected peers." `_parse_peer()` only ever implemented the int half; there is no
per-player display-name registry anywhere in the project for the name half to resolve against.
Nothing was broken — `op <peer_id>` and every `peer`-typed command already work fine with the raw id,
which is what `NetDebugPanel` and the lobby roster already surface — but the gap had no test pinning
it, so a future edit to `_parse_peer` could silently regress the D-078 "unconnected id still accepted"
allowance, or half-implement name resolution, with nothing catching it.

**Fix:** none needed in `_parse_peer()` itself — see D-098. Building the display-name registry inside
this claim would have been both wrong (F-126's own text says `_parse_peer` should consume a registry
another system owns, not invent one for itself) and impossible regardless (the honest version needs a
new client→host RPC for LOCAL/LAN, which `docs/SPECS.md`'s own standing rule requires bumping
`PROTOCOL_VERSION` in `core/net/net_version.gd` for — held all task by another lane's exact-file claim
for 3.7). Filed F-157 to carry the actual registry forward, since F-126's own pointer at task 3.16 is
now stale (3.16 shipped without adding one). Updated `_parse_peer()`'s doc comment to point at F-157
instead of a now-closed F-126. Added `tools/command_check.gd` coverage that pins the current, honestly-
documented behavior: a display-name token is refused with the exact message, not silently mis-resolved
or silently accepted; 0/negative/non-integer tokens are refused; an int that has never connected is
still accepted (D-078, previously only exercised incidentally via `NON_OP_PEER = 999`, never asserted
as its own case).

**Verify:** `agent godot --script tools/command_check.gd`'s new "peer arg type" section.

**Done means:** `COMMAND_CHECK failures=0` including the new section, docs/FINDINGS.md carries F-126
under `## Resolved` and the new F-157 under `## Open`, D-098 records why no registry was built here.

**Verified 2026-08-18 (lp):** `agent godot --script tools/command_check.gd` → `COMMAND_CHECK
failures=0`, all 7 new assertions PASS including the exact refusal strings (`'bob' is not a peer id`,
`'0' is not a valid peer id`) and the D-078 unconnected-id-accepted case (`opped peer 424242`). Zero
`ERROR:` lines in the run. Regression-checked: `agent godot --script tools/verify_setup.gd` → `all
checks passed`, unaffected pre-existing `gfx` deprecation warning (F-130, unrelated) still the only
warning printed.

---

## F-157 · No system tracks a player's display name anywhere in the project — F-126's `peer` name resolution has nothing to resolve against

**Claim:** `autoload/net_transport.gd`, `autoload/steam_lobby.gd`, `autoload/command_service.gd`,
`ui/debug/net_debug_panel.gd`, `tools/command_check.gd`, `tools/net_debug_panel_check.gd`, plus a new
`tools/display_name_check.gd` (needs a `.uid` sidecar claimed too, F-010). Check `agent brief F-157`'s
"held by someone else" list for `core/net/net_version.gd`/`tools/handshake_check.gd` before claiming —
if still held, this spec's own precedent (D-102/F-161/F-165/F-169) is: build the RPCs anyway, file the
`PROTOCOL_VERSION` bump as its own finding, do not wait on it.

**What was wrong:** confirmed project-wide (F-126's original text, re-confirmed here): no file defines
a peer id → display name map. `NetTransport` tracked bare ids only; `SteamLobby._persona()` resolves a
name per lobby *member*, keyed by Steam id, a different key than the in-session net peer id every other
system uses, and does not exist in LOCAL/LAN at all. `CommandService._parse_peer()` implemented only
the int half of docs/COMMANDS.md §2.2's `peer` type spec ("peer id int or player display name").

**Fix, four pieces:**

1. **Registry, in `NetTransport`** (D-098 named this file as the natural owner — it already has the
   right lifecycle hooks and the right key): `_display_names: Dictionary` (peer id → sanitized
   String), `display_name(id)`/`display_names()`/`submit_display_name(name)` public, `signal
   display_name_changed(peer_id, display_name)`. HOST-authoritative (new `ARCHITECTURE.md` §2.2 row):
   only `_host_apply_display_name()` writes the map, and it is the only place `_sanitize_display_name()`
   runs — never trust a client's raw string, same stance every other write RPC in the project takes.
2. **Wire shape, all new, no existing seam to reuse** (a display name has no per-cell/per-chunk shape
   the way Mire deltas or the Cycle counter did for D-99/D-100's `WorldDeltaLog` reuse):
   `net_request_display_name` (client → host, one raw String), `net_display_name_changed` (host →
   every remote, one id + result — reaches the renamed peer too, since it needs the SANITIZED value),
   `net_display_name_snapshot` (host → one newly admitted peer, sent from `_add_peer` at admission
   time, the full map so far). `host()`/the client's `connected_to_host` handler each call
   `submit_display_name()` once with a computed default — STEAM threads through a new
   `SteamLobby.local_persona_name()` (`_persona(local_steam_id())`, guarded on `_initialised`);
   LOCAL/LAN falls back to `OS.get_environment("USERNAME")`/`"USER"`. No name-entry UI exists or is in
   scope — a future one just calls `submit_display_name()` again.
3. **`CommandService._parse_peer()` consumes it**: a non-numeric token now resolves against
   `NetTransport.display_names()` (exact, case-insensitive) instead of failing outright. Two peers
   sharing a name is allowed, not deduped — an ambiguous match refuses and lists every candidate peer
   id rather than guessing (`docs/DECISIONS.md` D-120). `tools/command_check.gd`'s "peer arg type"
   section (F-126's own coverage) updates for the new refusal wording; its offline harness never calls
   host()/join(), so it can only prove the "no match" refusal — the real round trip needs a second
   real peer, hence (4).
4. **`tools/display_name_check.gd`**, new — two real ENet processes (same driver/probe shape as
   `command_net_check.gd`): submission → host sanitizes and broadcasts → the sender's own mirror
   reflects the sanitized result → a peer that connects AFTER a name is already set receives it via
   the snapshot, not a resubmit → `op <name>` resolves to the right peer id, case-insensitively → two
   peers sharing a name refuse `op <name>` with both ids listed. Also touched: `net_debug_panel.gd`'s
   session line and join/left log now show `id(name)` — one of the two consumers F-157's own text
   named as still printing a bare id.

**Verify:** `agent godot --script tools/display_name_check.gd` (new, 11/11 PASS). Regression:
`tools/command_check.gd`, `tools/command_net_check.gd`, `tools/net_debug_panel_check.gd`,
`tools/verify_setup.gd` all `failures=0` / all checks passed.

**Done means:** the four files above changed, `docs/ARCHITECTURE.md` §2.2 carries the new authority
row, `docs/DECISIONS.md` carries D-120, `docs/FINDINGS.md` moves F-157 to `## Resolved` and adds F-178
(the `PROTOCOL_VERSION` gap, continuing D-102's chain) under `## Open`, `docs/DELEGATION.md` *Current
state* carries the public API the next task (a lobby roster label, a kill-feed, a name-entry UI) builds
against.

**Verified 2026-08-19 (lp):** `agent godot --script tools/display_name_check.gd` → `DISPLAY_NAME_CHECK
failures=0`, all 11 assertions PASS (submission round trip, sanitization of a padded/control-character/
overlong name, snapshot delivery to a peer that joined after the name was already set, case-insensitive
`op <name>` resolving to the correct peer id, ambiguous-name refusal naming both candidate ids).
`tools/command_check.gd` → `COMMAND_CHECK failures=0` (24 assertions, including the updated peer-arg
section). Regression: `tools/command_net_check.gd` → `COMMAND_NET_CHECK failures=0`;
`tools/net_debug_panel_check.gd` → `0 failure(s)`; `tools/verify_setup.gd` → `all checks passed`. Zero
unexpected `ERROR:` lines across all four runs — only the pre-existing `gfx` deprecation warning
(F-130, unrelated).

---

## F-130 · Three console commands never migrated to CommandService — `console.call("register", ...)` reflection calls hide from a name grep

**Claim:** `core/dev/dev_frame_cap.gd`, `autoload/graphics_quality.gd`, plus whichever new guard
file the regression check lands in. **`autoload/graphics_quality.gd` needs an exact claim**, and as
of this writing (two sessions running) it has been held the entire time by another task (F-144) —
check `agent brief F-130`'s "held by someone else" list before claiming; if it's still there, you
cannot finish this without waiting it out or picking a different task meanwhile.

**What was wrong:** `f9cb6f7` ("CommandService front door: ... migrate every console command") swept
every call site that referenced `DebugConsole` (or its shim) directly, via
`grep -rn 'DebugConsole.register('`. Three commands resolved the autoload at runtime instead and
invoked it by name — `var console: Node = get_node_or_null(^"/root/DebugConsole"); console.call(
"register", &"gfx", ...)` — so the verb name never sits next to the method name in the source text
and no grep for the call site can match it. Cost: a `[WARN] dev: DebugConsole.register(...) uses the
deprecated shim` line on every headless run per unmigrated verb, against a repo whose audit standard
is 0 error lines read by eye.

**Fix, in two parts:**
1. Port each command to `CommandService.register_spec()` with a typed spec and a declared scope.
   `fps_cap`/`vsync` (`core/dev/dev_frame_cap.gd`) are LOCAL — a frame cap/vsync toggle is this
   peer's own rendering, nothing about it belongs to the host. `gfx`
   (`autoload/graphics_quality.gd:181`, `_register_commands()`/`_cmd_gfx()`) is LOCAL for the same
   reason — see its own header's AUTHORITY line.
2. Build the regression guard this finding proposed, since the same call shape will hide the next
   migration too: a SOURCE-TEXT check asserting no `.gd` outside `autoload/debug_console.gd` (the
   shim's own implementation) contains the reflection shape `.call("register", ` /
   `.call(&"register", ` — modeled on `tools/net_check_pattern_check.gd` (F-060). A name-based
   check (like `tools/command_catalog_check.gd`'s shim-coverage assertion) cannot catch this: it only
   checks names already in its own table, so a *new* verb someone forgets to migrate slips past it
   silently, which is exactly how these three were missed the first time.

**Verify:** `agent godot --script tools/command_shim_check.gd` → `failures=0` (zero reflection-shim
call sites outside the shim's own file); `agent godot --script tools/command_catalog_check.gd` →
`failures=0`; `agent godot --script tools/command_check.gd` and
`agent godot --script tools/command_net_check.gd` → `failures=0` each, to confirm the ported specs
still behave under the same coverage the catalog sweep already exercises.

**Done means:** all four checks above at `failures=0`, no `[WARN] ... uses the deprecated shim` line
in a headless run, docs/FINDINGS.md's F-130 moved to `## Resolved` with the verifying commands' output.

**Progress so far, still not done:**
- **2026-08-18, task 3.16 (lp):** `fps_cap`/`vsync` migrated — `core/dev/dev_frame_cap.gd` now
  registers both through `register_spec()`. `gfx` left on the shim: `autoload/graphics_quality.gd`
  was held under F-144's claim for the task's entire run.
- **2026-08-18, this task (lp):** `autoload/graphics_quality.gd` still held by F-144 (`nettle12`) —
  same block, unchanged since the prior session; confirmed via `agent claim F-130
  autoload/graphics_quality.gd` failing with "claimed by nettle12 for task F-144". Wrote and shipped
  the regression guard (part 2 above) as `tools/command_shim_check.gd`: it walks every `.gd` file for
  the reflection-call shape and currently reports exactly one hit —
  `autoload/graphics_quality.gd:197`, the `gfx` registration — which is correct: the guard is meant
  to fail until `gfx` is actually migrated, and this is the first real signal (a check FAIL, not a
  WARN buried in scrollback) that the next holder of that file has something to finish. Re-verified
  `fps_cap`/`vsync` still clean: `command_catalog_check` (`COMMAND_CATALOG_CHECK failures=0`),
  `command_check` (`COMMAND_CHECK failures=0`), `command_net_check` (`COMMAND_NET_CHECK failures=0`).
  Did not touch `autoload/graphics_quality.gd` — no workaround, no forced claim. Finding stays
  `## Open`; whoever next holds that file finishes part 1 for `gfx` (same shape as the `fps_cap`
  example already in the file) and then `tools/command_shim_check.gd` should read `failures=0` too.

---

## F-152 · `core/render/mesh_merge.gd` builds an invalid surface at boot, so merged undergrowth silently draws nothing

**Claim:** `tools/mesh_merge_check.gd` (none in `core/render/mesh_merge.gd` — see below).

**What was wrong:** at the finding's HEAD (`e5f96b1`) a merge that concatenated an optional vertex
channel (UV/UV2/colour/tangent) without first checking every merged part carried it produced arrays of
mismatched length. `mesh_create_surface_data_from_arrays` rejects that silently
(`"array.size() != p_vertex_array_len"`), the merge fell back to a mesh with zero surfaces, and the
caller's next `surface_get_material(-1)` went out of bounds — loud in the log, invisible on screen.

**Fix (already shipped by the time this task picked it up — no code change was needed):** F-144's own
mesh-merging work (commit `76d48bc`, in flight under a separate claim the whole time this task ran)
rewrote the bucketing to key on `_attribute_mask(arrays)` as well as material appearance
(`mesh_merge.gd:103-110`), so two parts can only land in the same bucket if they carry the *same* set
of optional channels — and each channel is appended only when the whole bucket declares it
(`mesh_merge.gd:136-160`). The mismatched-length case F-152 describes cannot occur any more: a part
missing a channel its bucket-mates have starts a bucket of its own instead of being concatenated into
one that doesn't fit it.

**Verify:** `agent godot --script tools/mesh_merge_check.gd` — new check, since none existed. Clears
`MeshMerge`'s disk cache first (so it exercises `_build()`, not a cached mesh from a previous good
run), then calls `MeshMerge.merged()` directly on every `.glb` under every `assets/*/exports/` kit
directory (discovered, not a fixed list) and asserts a non-null, non-zero-surface mesh whose every
present channel has exactly one entry per vertex (four for tangents) — the exact invariant the bug
broke. A source that legitimately has no mesh parts is allowed to merge to null; one that has parts and
still merges to null or to zero surfaces is the F-152 failure mode and fails the check.

**Done means:** `MESH_MERGE_CHECK_GODOT PASS` with `checked` equal to every kit `.glb` on disk, and a
plain boot (`agent godot --quit-after N`) shows zero `mesh_merge.gd`-attributed `ERROR:` lines.

**Verified 2026-08-18 (lp):** `agent godot --script tools/mesh_merge_check.gd` →
`MESH_MERGE_CHECK checked=337 surfaces=1287`, `MESH_MERGE_CHECK_GODOT PASS` — every kit export
(environment, harvestables, flora, crafting_stations, wards, wellsprings, tools_weapons, construction,
enemies, loot, pickups, ships, environment_additions) merges to a mesh with matching per-vertex channel
lengths on every surface. Cross-checked against the finding's own repro:
`agent godot --quit-after 20` on the real boot scene (`levels/hollowmere.tscn`, which is what the
finding's stack trace came from) → zero `ERROR:` lines total, none mentioning `mesh_merge.gd`,
`array.size()`, `p_idx`, or `surfaces.size()`. Did not touch `core/render/mesh_merge.gd` or
`world/gen/undergrowth.gd` — both remained under F-144's claim for this task's entire run; nothing to
fix there once verified.

---

## F-150 · An authored collider is unverifiable by eye, and a .tscn's Transform3D floats are basis ROWS

**Claim:** `docs/SPECS.md`, `docs/FINDINGS.md` (none in `scenes/buildables/ramp.tscn` or
`tools/buildable_content_check.gd` — see below).

**What was wrong:** task 3.7's ramp piece needs a sloped collider, not a box (the controller has no
step-up, F-136) and authoring the slope's `Transform3D` in the `.tscn` by hand hit two traps that a
still-frame screenshot cannot catch: the file's basis floats are rows, so the naive rotation reads as
the transpose and sends the ramp the wrong way; and the slab's centre has to be offset along the
slope's own tilted normal (an x component as well as y) to seat its top face on the deck plane,
because offsetting along y alone leaves a lip under the deck — exactly the wall F-136 describes.

**Fix (already shipped by the time this task picked it up — no code change was needed):** the same
3.7 commit (`2012b44`) that authored `ramp.tscn`'s collider also wrote
`tools/buildable_content_check.gd`'s `_check_ramp_is_walkable()`, which drops three rays on a placed
ramp instead of reading the transform: toe, middle, and head. That is the fix this finding actually
asks for — verification by physics query, never by eyeballing basis floats — and it was already in
place when this task started.

**Done means:** `BUILDABLE_RAMP toe≈0.02 middle≈0.51 head≈0.99 angle≈26.3`, all three rays landing on
the ramp, the head within `RAMP_TOLERANCE_M` (0.12 m) of the kit's 1.00 m deck, and
`BUILDABLE_CONTENT_CHECK failures=0` overall (every def, not just the ramp).

**Verified 2026-08-18 (lm):** `agent godot --script tools/buildable_content_check.gd` →
`BUILDABLE_CONTENT defs=13 with_art=12 without_art=["wall_wood"]` (art-free `wall_wood` is expected,
DELEGATION.md already records why), `BUILDABLE_RAMP toe=0.021 middle=0.506 head=0.990 angle=26.3`,
`BUILDABLE_CONTENT_CHECK failures=0` — the exact numbers this finding's own text cites. Did not touch
`ramp.tscn` or `buildable_content_check.gd`; both were correct on disk already. `docs/DELEGATION.md`
*Current state* (2026-08-18 — Task 3.7) already cites this same check and credits the ramp's slope
collider to F-150, so no delegation entry was missing — only this spec block and the finding's
resolution were.

---

## F-155 · `PlayerHealth._is_dodging()` throws "Nonexistent 'bool' constructor" against any body with no `dodging` property

**Claim:** `systems/health/player_health.gd`, `docs/SPECS.md`, `docs/FINDINGS.md` (no check file —
the existing `tools/enemy_check.gd` and `tools/enemy_ai_check.gd` already reproduce it, see below).

**Root cause:** `_is_dodging(peer_id)` (`player_health.gd:347-349`) read `bool(body.get(&"dodging"))`.
A real player body (`entities/player/player_controller.gd`) always carries `dodging` (task 3.8b), so
this is silent in a real session. But `.get()` on a node with no such property returns Variant NIL,
and `bool(NIL)` is not a valid conversion in Godot 4 — it throws `Invalid call. Nonexistent 'bool'
constructor` instead of degrading to `false`. Both `tools/enemy_check.gd` (task 2.10) and
`tools/enemy_ai_check.gd` (task 5.1) stand in a bare `Node3D` for a player, so every
`_resolve_attack()` that reaches `EventBus.emit_enemy_attack_landed` hit this — a `SCRIPT ERROR:` line
on an otherwise-passing check. Neither check's own `failures` tally caught it: it is an engine-level
crash inside a signal handler, not a `check()` assertion, so it was only visible by reading console
output, not the printed verdict line.

**Fix:** `body != null and body.get(&"dodging") == true` — `==` against a bool literal degrades NIL to
"not equal" instead of attempting a constructor call. One-line change, exactly as the finding
predicted.

**Verify:** `agent godot --script tools/enemy_check.gd` and `agent godot --script tools/enemy_ai_check.gd`,
grep the output for `SCRIPT ERROR`; also `agent godot --script tools/player_health_check.gd` and
`agent godot --script tools/player_health_net_check.gd` for the health system's own regression bar.

**Verified 2026-08-18 (lm):** all four green after the fix —
`ENEMY_CHECK attacks=0 failures=0` with zero `SCRIPT ERROR` lines (previously one, at
`player_health.gd:349` on every attack), `ENEMY_AI_CHECK failures=0`, `player_health_check.gd` → `0
failure(s)`, `player_health_net_check.gd` → `PLAYER_HEALTH_NET_CHECK client=1358131636->830238352
failures=0`.

---

## F-167 · `tools/crafting_net_check.gd` fails (24/24) against a clean checkout of HEAD, independent of any in-flight change

**Claim:** `tools/crafting_net_check.gd`, `autoload/crafting_service.gd`, `ui/crafting/crafting_ui.gd`,
`docs/SPECS.md`, `docs/FINDINGS.md` (existing check reproduces it, no new one needed).

**Root cause, two layers.** `CraftingService.recipes_for_station()` builds a `RecipeDef` row list for
a station by collecting every `Registry.recipes` key into `Array[StringName]` and calling `.sort()`,
meant to give the workbench panel a stable, alphabetical order. `StringName`'s comparison operator
compares interned identity, not string content, so `Array[StringName].sort()` does **not** sort
lexicographically — confirmed with a throwaway probe script: sorting
`["iron_sword","stone_pickaxe","arrow","cleaver","wooden_axe"]` as `Array[String]` gives the expected
`[arrow, cleaver, iron_sword, stone_pickaxe, wooden_axe]`; the identical values as `Array[StringName]`
give `[iron_sword, stone_pickaxe, wooden_axe, cleaver, arrow]`. The row order was therefore never
alphabetical — it silently tracked `Registry.recipes`' Dictionary insertion order, itself just whatever
order `DirAccess` happened to enumerate `content/recipes/*.tres` in.

That was invisible while the workbench had a single recipe (`stone_axe`, task 2.6). As tasks 3.2–3.4
authored more workbench recipes, the station's recipe count grew to 11, and `tools/crafting_net_check.gd`
hardcoded index `0` for "the recipe the client crafts" — an assumption that broke the moment insertion
order stopped agreeing with `stone_axe` being first. The client-side coroutine pressed row 0's craft
button (which, depending on load order, resolved to `iron_sword` — 1 log + 4 iron ingot, ingredients
the check never grants), the host correctly rejected it for missing ingredients, and every downstream
assertion that depended on the axe actually completing (`craft_applied`, panel requirement text, the
furnace phase gated behind the first phase's `complete` flag) failed or stalled on its own 15s timeout —
that stacking of unrelated 15s waits is why the failing run visibly took far longer than the passing one.

**Fix, two parts:**
1. `autoload/crafting_service.gd` — `recipes_for_station()` now sorts with
   `ids.sort_custom(func(a, b): return String(a) < String(b))`, comparing the string values instead of
   the `StringName` handles. This is a real UX fix independent of the check: the workbench panel is
   now genuinely alphabetical, which it never actually was.
2. `tools/crafting_net_check.gd` — the client coroutine no longer assumes row 0. It scans
   `crafting_ui.displayed_recipe_id(i)` for `&"stone_axe"` and uses that row index everywhere a recipe
   row is read or the craft button is pressed. If the recipe is ever removed or renamed, every row call
   below degrades gracefully (empty requirement text, `craftable = false`, `request_craft_at()` returns
   `-1`), and the existing assertions against `"2/2 Log · 3/3 Stone"` etc. already fail loudly on that —
   no separate guard needed.

**Verify:** `agent godot --script tools/crafting_net_check.gd` →
`CRAFTING_NET_CHECK ... axe_count=1 failures=0`, all 24 assertions PASS. Re-ran twice to rule out
flakiness in the two-process ENet timing; both green.

**Verified 2026-08-19 (lm):** confirmed via a standalone probe script that `Array[StringName].sort()`
does not sort lexicographically on the pinned 4.7.1 build (see root cause above); the same content
growth affects at least two other `Array[StringName].sort()` call sites elsewhere in the codebase —
filed as F-175 rather than fixed here, since neither file is in this task's claim set.

---

## F-171 · `tools/crafting_ui_check.gd` fails 19/22 independent of task 6.10 — reproduced on a clean HEAD checkout

**Claim:** `tools/crafting_ui_check.gd` only — no production code changed.

**Root cause:** the same hardcoded-index-0 shape F-167 already fixed in `tools/crafting_net_check.gd`,
this time in the sibling check that F-167's own fix did not touch. `tools/crafting_ui_check.gd` was
written for task 2.7's vertical slice, when the workbench had exactly one recipe (`stone_axe`) and the
furnace exactly one (`iron_ingot`), and it asserted `recipe_row_count() == 1` plus
`displayed_recipe_id(0) == <that recipe>` for each station. Content authoring in tasks 3.2–3.4 legitimately
grew the workbench to 11 recipes and the furnace to 2 (`content/recipes/*.tres` — every non-smelting
recipe defaults `RecipeDef.station` to `&"workbench"`; only `charcoal` and `iron_ingot` are explicitly
`&"furnace"`), and `CraftingService.recipes_for_station()` orders rows alphabetically by id (already
fixed for `StringName` vs `String` comparison under F-167). Alphabetically, `stone_axe` is not row 0 of
the workbench (`arrow` is) and `iron_ingot` is not row 0 of the furnace (`charcoal` is), so every
row-0-indexed assertion from "workbench renders the one registered recipe" onward failed — 19 of them,
matching the finding. This is a stale check, not a content or UI bug: the workbench legitimately hosts
every finished-good recipe, and the furnace legitimately hosts only the two smelting recipes.

**Fix:** added a `_row_for(ui, recipe_id)` helper (same shape as F-167's fix in `crafting_net_check.gd`)
that scans `displayed_recipe_id(i)` for the target recipe and returns its row index, or -1 if absent.
Both stations' `recipe_row_count() == 1` assertions became `> 0` ("renders its registered recipes"),
each gained a `check(row >= 0, ...)` assertion that the expected recipe is present, and every downstream
`0` used as a row index (craft button presses, requirement text reads, craftable checks) became the
resolved `axe_row` / `ingot_row`.

**Verify:** `agent godot --script tools/crafting_ui_check.gd` → `CRAFTING_UI_CHECK confirmations=3
failures=0`, all 34 assertions PASS. Ran twice to rule out timing flakiness in the timed-craft phase;
both green.

---

## F-162 · `tools/viewmodel_check.gd` fails independently of task 5.3 — three food items have no authored viewmodel

**Claim:** `content/items/mushroom.tres`, `content/items/berry.tres`, `content/items/raw_meat.tres`,
plus a throwaway probe (`tools/_probe_food_grip.gd`) — no production script needed a change.

**Root cause:** `mushroom`, `berry` and `raw_meat` are `ItemDef.Category.CONSUMABLE`, so
`tools/viewmodel_check.gd`'s `item.category != RESOURCE and item.view_model == null` assertion
requires them to carry one, same as every tool/weapon. Nobody had ever set one — A-002 (task-era asset
batch) shipped only `world_model` pickups for these three, and A-004's paired `*_viewmodel.glb` exports
only ever covered the ten tools/weapons. Equipping a food item showed an empty hand.

**Decision — reuse the existing pickup GLB as the view_model, don't commission new art.** A-002's
2.1j pass ("Legibility by quantity, not inflation") already built these three at true, honest scale
for a 1.8 m player — 0.17 m mushroom pair, 0.08 m berry cluster, 0.30 m meat cut — so the same
`PackedScene` used for `world_model` is set as `view_model` too, with hand-computed per-item
`grip_offset`/`grip_rotation_degrees`/`grip_scale` instead of a dedicated first-person export.
**Recorded as D-117** because the alternative — a new Blender batch through `docs/ASSET_TRACKER.md`'s
2.1d pipeline, with its own build script, GLB validation and orbit inspection — is what every other
holdable item's viewmodel went through, and is out of proportion to this finding's severity
(`low`) and to what a Findings-tier task should take on; `AGENTS.md`/`CLAUDE.md` both bar bulk-authoring
new content, and reusing shipped, hand-authored geometry isn't that. A future asset batch MAY still
give these three dedicated FP-framed exports; this fix does not block that, it only stops the empty
hand today.

**Grip values, derived from measured geometry, not guessed:** `tools/_probe_food_grip.gd` (a scratch
probe in the shape of `tools/_probe_lods.gd`/`tools/_probe_merge.gd`) instantiates each pickup GLB and
walks its `MeshInstance3D`s to print a composed local-space AABB — `mushroom` 0.169 m, `berry` 0.080 m,
`raw_meat` 0.300 m across their longest axis, all ground-centred per the art contract. `grip_scale`
is `1.0` for mushroom and raw_meat (their true size already reads fine held), `1.8` for berry (a
true-scale 0.08 m cluster is unreadable at arm's length — the one deliberate deviation from "true
size", for legibility). `attack_style = NONE` on all three: they are never swung, and `NONE` is the
`ItemDef.AttackStyle` documented for "bows, arrows, carried things" — it also keeps them out of
`viewmodel_check.gd`'s `CHOP_ITEMS`/`BLADE_PLANE_ITEMS` tables, which stay tools/weapons-only.
`raw_meat` needed a tilt (`rot = (-25, 20, 0)`) and a pulled-back, scaled-down grip (`0.55` at
`z = -0.55`) because its native pose is a flat slab whose broad face reads as an oversized flat plane
face-on to the camera at native scale and distance — confirmed by screenshotting the change through
`agent godot --windowed --script tools/_probe_food_grip.gd`, saving `/tmp/mire_food_*.png`, and
reading them back before and after.

**Verify:** `agent godot --script tools/viewmodel_check.gd` → `VIEWMODEL_CHECK failures=0`, all 21
assertions PASS including `every tool and weapon has a viewmodel ()` (empty = nothing missing) and
`every item with a viewmodel was measured (14)` (11 tools/weapons + these 3). Ran twice, both clean.
Windowed screenshots via `tools/_probe_food_grip.gd` confirm all three render on-screen, correctly
sized, non-clipping, matching their hotbar icons.

---

## F-164 · A capped Wellspring's re-corruption clock (task 6.4) has no HUD or ambient warning before it finishes

**Claim:** `ui/hud/wellspring_hud.gd`, `tools/wellspring_hud_check.gd` (new), plus `project.godot`
via `agent autoload` (never a hand-claim, D-021/F-051).

**Two gaps, not one.** The finding as filed is about the missing warning, but reading
`ui/hud/wellspring_hud.gd` before touching anything surfaced a second, larger gap the finding text
never mentions: `WellspringHud` was **never added to `[autoload]`** — task 6.5's DELEGATION.md entry
flags this in passing ("unlike `wellspring_hud.gd`, which ships the same pattern but was never added
to `[autoload]`") but it was never filed or fixed. The whole Wellspring HUD — the existing capping
prompt/progress bar included, not just this task's new warning — has been unreachable in the live
game since task 4.8 shipped it. A warning built into a HUD nothing loads is not shipped (AGENTS.md,
D-039), so fixing the registration is part of closing this finding, not a separate task: `agent
autoload WellspringHud res://ui/hud/wellspring_hud.gd`.

**Decision — an ambient, map-wide banner, not a proximity-gated one, and not scoped to "Wellsprings
the local player has capped".** The finding's own suggested closure floated both "any Wellspring the
local player has ever capped" and a plain threshold poll; the former needs a per-player cap-history
table that does not exist anywhere in the codebase today (no system tracks "which player capped
which Wellspring" — inventing one to gate a single warning line is out of proportion to a `low`
severity finding). DESIGN.md's framing — the Mire's state should be "visible on the horizon" — argues
for the SIMPLER shape being the more correct one anyway: every peer already reads the same replicated
`recorruption_sec`/`capped` fields this HUD polls for the in-range prompt, so a second poll over every
member of the `wellspring` group, independent of the local camera's position, costs nothing new and
warns every player, not just whoever capped it. A second top-centre panel (the existing prompt stays
bottom-centre) shows once ANY capped Wellspring's `recorruption_sec` crosses
`Wellspring.RECORRUPTION_DURATION_SEC * Wellspring.RECORRUPTING_VISUAL_FRACTION` — the exact fraction
the in-world mesh already swaps at, so the HUD text and the visual agree — with a `m:ss` countdown to
the nearest one, and a count when more than one Wellspring is past it at once. Reads the constants off
`Wellspring` (global `class_name`) directly rather than hard-coding the threshold, per the guidance
task 6.4 already left for this exact consumer in DELEGATION.md.

**Fix:** `ui/hud/wellspring_hud.gd` gains `_build_warning_panel()` (built alongside the existing
bottom prompt in `_build_ui()`) and `_refresh_recorruption_warning()`, polled on the same `POLL_SEC`
cadence as `_refresh_nearby()`/`_refresh_panel()` but reading every `wellspring`-group member, not
just `_nearby` (which by design only ever tracks an UNCAPPED Wellspring in range — the pair that
drives the capping prompt, and structurally cannot see a capped-and-recorrupting one).

**Verify:** new `tools/wellspring_hud_check.gd` — spawns real `Wellspring` nodes (same construction
`wellspring_recorruption_check.gd` uses) 5000m from the origin with no `Camera3D` in the tree at all,
proving the warning is not a proximity read; drives `capped`/`recorruption_sec` directly and calls
`_refresh_recorruption_warning()` inline rather than waiting on real poll timing. `agent godot
--script tools/wellspring_hud_check.gd` → `WELLSPRING_HUD_CHECK failures=0`, all 11 assertions PASS.
Ran twice, both clean. No regressions: `wellspring_check.gd` and `wellspring_recorruption_check.gd`
both still `failures=0`. `agent godot --quit-after 20` boots with zero `ERROR:` lines and
`WellspringHud` present in the autoload list.

---

## F-159 · Placed buildables are invisible to the nav map — agents path straight through walls

**Claim:** `world/chunk/nav_baker.gd`, `autoload/build_service.gd`, `tools/nav_bake_check.gd`.

**Scoping decision, made explicit because it is not what the finding's own wording implies at a
glance.** `EnemyWorld.bake_navigation()` (`autoload/enemy_world.gd`) is the nav baker the SHIPPED
game actually runs — called once at session bootstrap and re-triggered by
`BuildService._request_nav_rebake()` on every placement/destroy. `NavBaker` (task 4.5, this file) is
not: nothing instantiates a `ChunkStreamer` in the live level yet (F-139), so `NavBaker.bind()` is
never called outside its own check script. Folding buildable geometry into a bake correctly requires
ONE combined parse+bake pass — Recast carves a hole around solid geometry by seeing it in the SAME
source data as the terrain it's carving, so two independently-baked regions cannot composite into the
same result no matter how they're layered. That means the sound fix lives in whichever file owns the
actual `parse_source_geometry_data` + `bake_from_source_geometry_data` call, and `autoload/
enemy_world.gd` was held by another lane (`lp`, task 5.5, boss framework) for this task's entire
session. F-159 itself is scoped explicitly against `NavBaker`/`ChunkMesher` and names `tools/
nav_bake_check.gd`'s shape as the verification path, so that is where this task lands the fix — zero
claim contention, and correct-by-construction for whenever F-139 eventually wires a live
`ChunkStreamer` and `NavBaker` becomes the system of record. `EnemyWorld.bake_navigation()` itself is
untouched; it still has the same gap this finding describes, tracked as F-177 since fixing it means
editing a file this task could not claim.

**Fix, three parts, all in `world/chunk/nav_baker.gd` unless noted:**

1. `bind()` now also connects directly to `BuildService`'s `piece_placed`/`piece_destroyed` signals
   (autoload-to-autoload, the same pattern `BuildService._wire_mire_grid()` already uses) — a no-op
   in any harness with no `BuildService`, same tolerance every other autoload lookup here already has.
2. Every tracked piece is stored as `{coord, position, yaw, size}` (`size` read from the piece's own
   `BuildableDef` via `/root/Registry` — the same field `BuildService._generated_piece()` builds its
   physics collider from, so nav agrees with physics for exactly the geometry that exists in the game
   today). `_source_geometry(coord)` now folds every piece whose stored `coord` matches into the SAME
   `NavigationMeshSourceGeometryData3D` as the chunk's terrain faces, via a new static `_box_faces()`
   that builds a closed 12-triangle box and runs it through the file's existing `_wound_for_recast()`
   (now `static`, so `_box_faces()` can call it) — reusing that function is what keeps a box's winding
   correct without re-deriving Recast's inverted convention by hand for six differently-facing faces.
3. Placing or destroying a piece calls a new `_rebake_chunk(coord)`, which re-queues that chunk if it
   already has a region (or is on its way to one) — the OPPOSITE case from `request_bake()`'s existing
   dedupe guard, which exists to ignore a redundant `chunk_mesh_ready` for a chunk that already has a
   CORRECT region. `_attach()` gained a free-the-stale-region-first step for this: re-attaching a
   coord that already has one would otherwise leak the old region RID and leave both sitting on the
   map at once, describing geometry that no longer agrees with itself.

`autoload/build_service.gd`: `piece_destroyed` widened from `(def_id, owner_peer_id)` to `(def_id,
owner_peer_id, piece_name, position)` — the piece's node is already freed by the time it fires, so
`NavBaker` needs its name (to erase the tracked entry) and last position (to find its chunk) handed
over rather than looked up. No existing listener connected to the old 2-arg signature (checked by
grep), so this is not a breaking change to anything shipped.

**Verify:** `tools/nav_bake_check.gd`, new `_check_buildable_obstruction()` — queries a real,
on-mesh point, places a real registered `ward` piece (`content/buildables/ward.tres`) with its centre
exactly there through `NavBaker._on_piece_placed()`, and asserts the SAME query now resolves
measurably farther away (baseline snap distance + 1.0 m, polled rather than snapshotted once — the
map's own async iteration sync can lag `_attach()` by a frame or two, same reason `is_queryable()`
polls rather than trusts a flag). Destroys it and asserts the query returns close to its own
baseline — proving the fix does not just add cruft that never clears. Baseline is measured, not
assumed near-zero: an analytic heightmap point is not guaranteed to sit exactly on the baked mesh's
own vertex grid, so `map_get_closest_point` legitimately snapped 0.663 m away before any piece was
ever involved on this seed — asserting a fixed small tolerance instead would have been exactly the
kind of silent trap this file otherwise warns against (an earlier draft of this check did that and
both new assertions passed for the wrong reason, on a piece that had failed to attach at all).

`agent godot --script tools/nav_bake_check.gd` → `NAV_BAKE_CHECK failures=0`, all assertions PASS
including the four pre-existing sections. Ran twice, both clean. No regressions: `build_check.gd`
(`failures=0`), `build_net_check.gd` (`failures=0`, real two-process ENet), `combat_check.gd`
(`failures=0` — exercises `BuildService.host_piece_destroyed_by_damage`'s new signal arity).
`agent godot --quit-after 20`: no new `ERROR:`/`SCRIPT ERROR:` lines. The "Navigation region
synchronization had 4 edge error(s)" warning during the initial 4-chunk bake is pre-existing —
reproduced identically against a clean `agent baseline` checkout of HEAD, unrelated to this task.

**Done means:** `docs/FINDINGS.md`'s F-159 section moved to `## Resolved` with this same summary.

---

## F-177 · `EnemyWorld.bake_navigation()` — the LIVE nav baker — still ignores placed buildables; only `NavBaker` (task 4.5, unreachable per F-139) got F-159's fix

No block existed here beforehand; this file's own preamble makes writing one part of the task that
discovers the gap.

**Claim:** `autoload/enemy_world.gd`, `tools/nav_bake_check.gd`.

**What this is.** F-159's own fix landed in `world/chunk/nav_baker.gd` (task 4.5's per-chunk baker),
not `EnemyWorld.bake_navigation()` (`autoload/enemy_world.gd`) — the baker a real LOCAL/LAN/Steam
session actually runs, at bootstrap and on every `BuildService._request_nav_rebake()`. D-118 records
why: `enemy_world.gd` was held by another lane's claim for that task's entire session. This finding is
the tracked consequence. `docs/DECISIONS.md` D-121 has the full reasoning for the fix shape below.

**Fix, in `autoload/enemy_world.gd`'s `bake_navigation()` only:**

`NavigationServer3D.parse_source_geometry_data(nav_mesh, geometry, scene_root)` still runs exactly as
before — that half of the bug was never real; terrain and any level-authored static geometry were
always seen. What was missing: `BuildService`'s placed-piece container (`Buildings`, holding every
piece `request_place()` has spawned) is a child of the `BuildService` autoload, not of `scene_root` —
a SIBLING under `/root`, invisible to a walk rooted at the level. A second
`parse_source_geometry_data()` call, rooted at `get_node_or_null(^"/root/BuildService/Buildings")`
(a no-op skip if the node is absent or empty, same tolerance every other cross-autoload lookup in this
file already has), fills a second `NavigationMeshSourceGeometryData3D`, which `.merge()`s into the
first BEFORE the one `bake_from_source_geometry_data()` call — same "has to be one combined pass"
requirement F-159/D-118 already established, still true here: Recast carves a hole around solid
geometry only by seeing it in the same source data as whatever it's carving.

**Verify:** `tools/nav_bake_check.gd`, new `_check_enemy_world_buildable_obstruction()` — a REAL
`BuildService.request_place()` round trip (funded inventory, the actual host-decides path, not a
piece dropped in by hand) puts a `ward` (`content/buildables/ward.tres`) across a two-point route
`EnemyWorld.bake_navigation()` has just baked over a flat synthetic floor, and asserts
`NavigationServer3D.map_get_path()` between those same two points goes from the straight line
(6.000 m, 3 waypoints) to a real detour (7.525 m, 5 waypoints) once the piece lands, then back to the
straight line after `request_destroy()`. Deliberately a PATH assertion, not F-159's own
`map_get_closest_point()`-at-the-piece's-centre shape: that point-snap query is provably unreliable
for a piece resting exactly flush on a perfectly flat test floor — a Recast/Godot rasterization quirk
leaves a tiny disconnected walkable "island" polygon surviving at the exact centre in that specific
case (reproduced identically whether via this fix's two-parse-and-merge or a single combined parse
over one shared root, so it is a property of coincident-height geometry, not of how this fix merges
data) — snappable despite sharing no edge with the rest of the map, and therefore never actually
walkable in practice, since `map_get_path()` only ever routes across connected edges. Real heightmap
terrain does not reliably dodge the same setup either, at least at this seed (a 2.4 m `ward` footprint
routinely fails the placement validator's own support probes on it before slope ever enters the
picture), which is why the check fixture is a flat synthetic floor — same shape `build_check.gd`'s
own `_build_world()` already uses — rather than a real terrain chunk.

`agent godot --script tools/nav_bake_check.gd` → `NAV_BAKE_CHECK failures=0`, all assertions PASS
including the five pre-existing sections. Ran twice, both clean. No regressions: `build_check.gd`,
`build_net_check.gd` (real two-process ENet), `combat_check.gd`, `enemy_check.gd`, all `failures=0`.

**Done means:** `docs/FINDINGS.md`'s F-177 section moved to `## Resolved` with this same summary.

---

## 7.8 · Network robustness: packet loss, high latency, hostile disconnect timing

No block existed here beforehand; this file's own preamble makes writing one part of the task that
discovers the gap.

**Authority:** none of its own. Like `net_version.gd` and `NetTransport`, this task is infrastructure
and verification, not simulated state — it adds no new replicated property and no new RPC, so it adds
no new §2.2 row. What it does is audit and hold the line on a pattern §2.2's own host-authoritative
rows already depend on: every specific-peer `rpc_id()` send has to check the target is still there.

**Claim:** `autoload/combat_service.gd`, `autoload/ranged_combat_service.gd`,
`autoload/crafting_service.gd`, `autoload/command_service.gd`, `autoload/world_delta_log.gd`,
`tools/net_robustness_check.gd` (new).

**What "packet loss" and "high latency" turn out to mean here.** Godot's `ENetMultiplayerPeer` /
`ENetConnection` / `ENetPacketPeer` bindings expose no loss- or latency-injection API (checked by
listing `ClassDB.class_get_method_list()` for all three at the pinned 4.7 build — the only match
anywhere in the set is `ENetPacketPeer.throttle_configure`, which shapes ENet's own outgoing
bandwidth throttle, not a fault injector) and there is no cross-platform, no-sudo way to fake loss/RTT
on a raw socket from a headless macOS dev box either. So "handles packet loss and high latency"
resolves to two things this codebase already had to get right for unrelated reasons, both re-verified
rather than rebuilt:

1. **Every state-mutating RPC in the project is reliable** (`@rpc(..., "reliable")` — confirmed by
   grepping every `@rpc(` declaration in the repo; the only two `"unreliable"` RPCs are
   `PlayerHealth.net_report_local_stamina`, explicitly advisory per its own header note (D-072's
   sibling reasoning), and `DayNight`'s ~1 Hz time-of-day push, which is self-healing by construction
   — a dropped tick is corrected by the next one a second later). A lost packet on any of those two
   degrades gracefully by design; a lost packet on anything else would silently desync two peers,
   which is exactly what "reliable" prevents at the transport level regardless of how bad the loss
   gets.
2. **`NetTransport._tune_peer_timeout` already treats "high latency" as the normal case, not the
   exception**: ENet's dead-peer ceiling is lowered from 30 s to 8 s (`_PEER_TIMEOUT_MAX_MSEC`), but
   the floor stays at 2.5 s (`_PEER_TIMEOUT_MIN_MSEC`) specifically so a connection that has merely
   gotten slow — not dead — is not evicted for it. This task did not change either number; it read the
   reasoning already on file there and confirmed it is still the right shape for "degraded, not gone."

**What "hostile disconnect timing" turned out to be: a real bug class, found by audit.** `docs/
FINDINGS.md`'s F-059 fixed one instance of a specific shape — `InventoryService._publish_snapshot`
sent `rpc_id(peer_id, ...)` to a peer id that D-035's grace window keeps alive in a dictionary for 90 s
after it disconnects, with no check that the peer is still actually connected — and left the fix
(`NetTransport.has_peer(peer_id)` before the send) as a pattern for every other specific-peer `rpc_id`
call in the codebase. `PlayerHealth`, `PowerupService`, `BuildService`, `RuleService`,
`AttunementService`, `Chest`, `Haulable`, `RuleService` all already carried it. This task greped every
`rpc_id(` call site in the repo against that pattern and found **five that did not**, all sharing the
same shape — a request lands, the host does host-authoritative work (sometimes across an `await`), and
replies with `rpc_id()` to whoever asked, with no check that "whoever asked" hasn't disconnected in the
meantime:

- `CombatService._reject` — a melee attacker that disconnects between `net_request_attack` and the
  host's rejection.
- `RangedCombatService._reject` — same shape, a shooter mid-draw.
- `CraftingService._confirm_peer` — a crafter that disconnects while a timed craft is resolving.
- `CommandService.net_submit_command`'s reply — the `await execute(line, ctx)` inside the RPC handler
  itself is the window; a sender that drops during a slow command's execution was never checked before
  the reply.
- `WorldDeltaLog._on_peer_admitted` — fires synchronously off `NetSession.peer_admitted`, so the window
  is a single instant rather than an `await`, but the same unguarded send was there.

Each got the same one-line fix: gate the `rpc_id()` on `NetTransport.has_peer(peer_id)` (`command_
service.gd` and `world_delta_log.gd` gained a small private helper in the same shape every other file
with this guard already has; `combat_service.gd`/`ranged_combat_service.gd`/`crafting_service.gd`
already referenced `NetTransport` directly, so the fix is inline). `net_session.gd`'s own
`net_run_identity.rpc_id()` was checked and deliberately left alone — it answers synchronously inside
the very RPC handler the sender's hello arrived through, so there is no gap between receipt and reply
for a disconnect to land in, unlike every site above.

**Verify:** `tools/net_robustness_check.gd` (new) — hosts a real LOCAL session, then drives
`CombatService._reject`, `RangedCombatService._reject`, `CraftingService._confirm_peer`, and
`WorldDeltaLog._on_peer_admitted` directly against a peer id that was never admitted (`GHOST_PEER`,
chosen outside ENet's real id range), and checks `CommandService._peer_connected` answers correctly for
both a ghost id and a real one. Reproduced first: with the five guards reverted, the exact same run
prints `ERROR: Attempt to call RPC with unknown peer ID: 999919` at every directly-driven site — the
verbatim wording F-059 already established for this bug class. Restored the fix, re-ran three times:
0 `ERROR:` lines, 0 failures every time. No regressions: `combat_net_check`, `ranged_combat_net_check`,
`crafting_check`, `command_net_check`, `seed_sync_check` (exercises `WorldDeltaLog`'s snapshot RPC),
`mire_grid_check` all stay `failures=0`/`0 failure(s)`. (`crafting_net_check` fails 24/24 — reproduced
identically against a clean `agent baseline` checkout of HEAD, pre-existing and unrelated, F-167.)
`agent godot --quit-after 15`: 0 `ERROR:` lines on a full boot.

**Done means:** `net_robustness_check.gd` at 0 failures with the bug-then-fix reproduction shown above,
the six regression checks green, 0 `ERROR:` on a full boot, and the five fixed call sites are the last
ones in the repo carrying this shape — confirmed by the same repo-wide `rpc_id(` audit this task ran,
not by inspection of the five files alone.

**Traps for the next task that touches a host-authoritative service:** any new `rpc_id(peer_id, ...)`
that targets someone other than the sender of the RPC currently executing — a broadcast to a specific
"known peer" while iterating a roster, a reply after an `await`, a snapshot sent off a lifecycle signal
— needs the same `has_peer()` guard from the moment it is written, not as a follow-up finding. D-035's
90 s grace window is what makes this a standing hazard rather than a one-time bug: a departed peer id
is a live dictionary key for a minute and a half in every session that runs long enough to hit it.

---

## 7.7 · Performance pass: profile, LOD tuning, draw calls, target 60fps mid-range

No block existed here beforehand; this file's own preamble makes writing one part of the task that
discovers the gap.

**Authority:** none of its own — client-local rendering detail (ARCHITECTURE.md §2.2, "VFX, audio,
camera, UI" row: never networked, no two peers can disagree about it).

**Claim:** `systems/enemies/enemy.gd`, `tools/enemy_lod_check.gd` (new).

**The scope decision, and why it's narrower than the title.** `agent brief 7.7` showed F-144 ("Props
have no LOD and no cross-asset batching") already 6h in flight under `nettle12`, holding every file
this task's title would otherwise touch: `autoload/graphics_quality.gd`, `core/render/mesh_merge.gd`,
`systems/harvesting/harvestable.gd`, `world/environment/draw_policy.gd`,
`world/gen/authored_world.gd`, `world/gen/undergrowth.gd`, plus F-144's own probes and checks. F-144's
own text is literally this task's headline ("no mesh LOD anywhere", "cross-asset batching") for
everything that IS mergeable — props, harvestables, undergrowth, ~2,900 renders total. Working the
same surface here would mean either editing files under someone else's claim (AGENTS.md: "two agents
in one file is the failure mode this whole system exists to prevent") or blocking on a 6-hour claim
with no ETA, which the work order's own header forbids ("never end your turn to wait").

So 7.7 took the one performance surface F-144 does not and cannot cover: **enemies**. `Enemy` is a
`CharacterBody3D` with an independently-animated skeletal `MeshInstance3D` per instance — it can never
be merged into a static batched mesh the way a static prop can, so F-144's lever (merge + batch) does
not apply here at all; the only lever available is a **visibility-range LOD**. This matters on its own
timeline: `WaveSpawner.cycle_count_multiplier()` scales wave size every Cycle with no cap on run length
(DESIGN.md: "Endless escalating runs, no win condition"), so the enemy-count contribution to frame cost
grows over the course of a run in a way the (fixed-count) world's props never do.

**What shipped.** `Enemy._build_visual()` (`systems/enemies/enemy.gd`) now sets, on every
`MeshInstance3D` found under an enemy's instantiated visual: `visibility_range_end = 90.0` m,
`visibility_range_end_margin = 8.0` m, `visibility_range_fade_mode =
GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF`. 90 m was chosen against `EnemyDef.deaggro_radius_m`
(26 m default, 120 m export ceiling) and DESIGN.md §6's readable-telegraph requirement: past 90 m an
enemy is already well outside both aggro and any attack a player could be reacting to, so nothing
gameplay-relevant is lost by not drawing it. The 8 m margin dithers the fade instead of a hard pop —
the same `FADE_SELF` pattern `docs/DELEGATION.md`'s undergrowth-scatter section already uses for the
same reason. Two constants (`Enemy.VISIBILITY_RANGE_END_M`, `Enemy.VISIBILITY_RANGE_FADE_MARGIN_M`)
hold the numbers so a future tuning pass has one place to change them.

**Profiling.** `tools/perf_probe.gd` (F-090) was re-run to get a current baseline
(`.agent/bin/agent godot --display-driver macos --script tools/perf_probe.gd`) — see `docs/
FINDINGS.md` F-174 for the numbers and why this dev machine (Apple M5 Pro) cannot itself stand in for
"mid-range": it hits 120fps+ "as shipped" with vsync on, so the 60fps mid-range target can only be
reasoned about through the existing preset/dynamic-resolution levers (F-098), not measured directly
here.

**Verify:** `tools/enemy_lod_check.gd` (new) — spawns one of every enemy def currently in
`content/enemies/` through the real, registered `EnemyWorld.host_spawn()` (F-068's lesson: a private
harness copy tests nothing real), and asserts every `MeshInstance3D` under each spawned enemy's visual
carries a nonzero `visibility_range_end`, a nonzero fade margin, and `FADE_SELF` mode. `.agent/bin/
agent godot --script tools/enemy_lod_check.gd` → 0 failures. No regressions:
`tools/wave_spawner_check.gd` (exercises `host_spawn`/`host_despawn_all` heavily) stays
`failures=0`.

**Done means:** `enemy_lod_check.gd` green, `wave_spawner_check.gd` still green, and the scope split
against F-144 recorded so neither side re-derives it — see `docs/DECISIONS.md` D-115.

**Traps / what's left for whoever picks this up next.** F-144 is the rest of this task's title (props/
harvestables/undergrowth LOD + batching) and is still in flight — do not re-open that surface here or
duplicate it; read F-144's own resolution when it lands instead. This task did not attempt a
mid-range hardware measurement (no such machine is available locally, same gap F-090 already
recorded) — if F-006's "no Windows/Linux machine" gap is ever closed, re-running `perf_probe.gd`
there is the first real "target 60fps mid-range" verification this project will have had.

---

## 7.5 · Settings: graphics, audio, sensitivity, keybinds, FOV, accessibility basics

No block existed here beforehand; SPECS.md's own preamble makes writing one part of the task that
discovers the gap. The old M7 look-ahead bullet for this task named a `ConfigFile`-backed
`user://settings.cfg`; this task instead followed the JSON `core/save/<name>_save.gd` +
`autoload/<name>_service.gd` shape `SalvageSave`/`SalvageService` (6.6) and `UnlockSave`/
`UnlockService` (6.9) already established, for consistency with every other per-player persisted
state in the repo rather than introducing a second save format — see D-114.

**Authority:** none of its own (`ARCHITECTURE.md` §2.2, "VFX, audio, camera, UI" row) — every knob
here is per-player presentation, applied locally, never sent to another peer.

**Claim:** `core/save/settings_save.gd` (new), `autoload/settings_service.gd` (new),
`ui/menu/settings_menu.gd`, `entities/player/player_camera.gd`, `autoload/combat_service.gd`,
`autoload/ranged_combat_service.gd`, `tools/settings_check.gd` (new). `project.godot` — one
`agent autoload SettingsService res://autoload/settings_service.gd`, appended last (D-021
append-only; everything it reads at `_ready()` is either an engine singleton or an autoload already
earlier in the list, and every consumer looks it up lazily by node path rather than assuming boot
order, so where in the list it sits does not matter).

**`SettingsService` (new autoload) owns every knob, `SettingsMenu` is a thin view over it.**
Persists to `user://settings.json` via `SettingsSave`, same schema-versioned migrate-in-place shape
`SalvageSave`/`UnlockSave` use, same `save_path` override + `_persistence_enabled()` D-107 guard
(`current_scene == null` in a `--script` harness means no real save file is ever touched by a check).
API: `graphics_preset()`/`set_graphics_preset(int)` (delegates to `GraphicsQuality.apply()`);
`master_volume()`/`music_volume()`/`sfx_volume()` and their setters (drive the `Master`/`Music`/`SFX`
`AudioServer` buses — `Music` and `SFX` are created at `_ready()` if missing, both sending to
`Master`, so a 0 slider mutes the bus and any positive value maps through `linear_to_db()`);
`look_sensitivity()`/`invert_y()`/`fov_degrees()` and their setters, clamped to
`[0.01, 1.0]`/bool/`[60, 110]`; `reduce_camera_motion()`/`set_reduce_camera_motion(bool)`;
`rebindable_actions()` (the ten keyboard-primary actions — `attack` stays mouse-bound and out of
scope, D-114), `keybind_label(action)`, `rebind_action(action, InputEventKey) -> StringName` (`&""`
on success, else the other rebindable action already holding that key — two actions never share a
key), `reset_keybinds()` (`InputMap.load_from_project_settings()`). Every setter emits
`settings_changed`.

**`PlayerCamera` reads sensitivity/invert-Y/FOV/reduce-motion from `SettingsService`** if present,
overriding its own `@export` fallbacks, applied once at `_ready()` and again on every
`settings_changed` — the menu can open mid-run, and a first-person camera should not need a scene
reload for a slider to take effect. "Reduce Camera Motion" suppresses exactly the two things this
class moves the camera on its own without player input: impact shake (`add_shake()` becomes a no-op)
and the sprint FOV pulse — everything else (pitch, yaw, the FOV slider's own resting value) is
unaffected, so a motion-sensitive player loses only the two known migraine triggers, not first-person
control.

**Melee/ranged impact SFX (`combat_service.gd`/`ranged_combat_service.gd`) route through the new
`SFX` bus** — one `player.bus = &"SFX"` line each, so the settings menu's SFX slider actually covers
the only SFX the game plays through code today. Ambient music is still unwired (7.1/7.2's own
delegation note) — the `Music` bus exists and sends to `Master` so a future `MusicDirector` has
somewhere to play into, but nothing plays through it yet, and the Music slider has no audible effect
until that task lands.

**`SettingsMenu`** builds its rows into the `SettingsStack` VBoxContainer task 6.10's shell already
named (now wrapped in a `ScrollContainer` — five sections' worth of controls does not fit the panel's
original height), same code-built `Control`/`ColorRect`/`PanelContainer` construction pattern every
other menu in this game uses. Sections: GRAPHICS (an `OptionButton`, Low/Medium/High), AUDIO (three
volume `HSlider`s), LOOK (sensitivity/FOV sliders + an Invert-Y `CheckBox`), ACCESSIBILITY (the
Reduce Camera Motion `CheckBox`), KEYBINDS (one row per rebindable action — click a button, it reads
"PRESS A KEY…", the next physical key press (or Esc to cancel) calls `rebind_action()`; a status
label surfaces a conflict by naming the action already holding that key — plus a Reset Keybinds
button). Opening the menu calls `_refresh_from_settings()`, which repopulates every control from the
live `SettingsService` values with `set_block_signals(true)` around each write so refreshing never
re-triggers the setter it's reading from. D-032 exclusivity, open/close, Esc-to-close and the visual
frame are all unchanged from 6.10's shell.

**Verify:** `tools/settings_check.gd` (51 assertions) — `SettingsSave`'s missing/corrupt/
missing-version/round-trip contract; `set_graphics_preset` visibly moving `GraphicsQuality.preset`;
`Music`/`SFX` buses exist and send to `Master`; volume setters reaching the right bus in dB and
muting at zero; sensitivity/FOV clamping at both ends; `reduce_camera_motion` read back;
`rebindable_actions` excluding `attack`; a rebind succeeding, a conflicting rebind refused and naming
the conflict, a non-rebindable action refused, `reset_keybinds` restoring the authored default; a
freshly-readied `PlayerCamera` picking up live sensitivity/invert-Y/FOV and suppressing shake under
reduce-motion, and an already-readied one live-updating on `settings_changed`; `SettingsMenu`
opening/closing/D-032-refusing exactly as 6.10's shell did, its slider values matching
`SettingsService` on open, and its dropdown/keybind-row counts. No regressions:
`combat_check`/`ranged_combat_check`/`main_menu_check`/`build_check`/`combat_feel_check`/
`verify_setup` all stay `failures=0`. `agent godot --quit-after 15`: 0 `ERROR:` lines on a full boot.

**Done means:** `settings_check.gd` at `failures=0`, the six regression checks green, 0 `ERROR:` on a
full boot, and `docs/DELEGATION.md`'s *Current state* carrying the `SettingsService`/`SettingsMenu`
API surface for 7.6 (gamepad) and any future system that wants its own presentation setting to build
against, rather than inventing a second settings store.

**Traps for the next task that adds a setting:** add it to `SettingsSave._default_data()` and
`SettingsService`'s load/save/getter/setter triad, not a parallel file — `_migrate()`'s backfill loop
already handles an old save missing the new key. A setting a gameplay system reads every frame
(sensitivity, FOV, reduce-motion) should be pulled once and cached on `settings_changed`, the way
`PlayerCamera._apply_settings()` does, never read live off the autoload in a hot path.

---

## 7.6 · Gamepad support + Steam Deck compatibility (not verification)

No block existed here beforehand; SPECS.md's own preamble makes writing one part of the task that
discovers the gap. Steam Deck hardware remains unprovisioned (D-028) and stays that way — "not
verification" in the title means this task ships and headlessly proves the CODE, not an on-device
playtest, which is Sequoyah's to do once he owns a unit or borrows one.

**Authority:** none of its own (`ARCHITECTURE.md` §2.2, "VFX, audio, camera, UI" row) — every input
binding is per-player presentation/control, applied locally, never sent to another peer. GodotSteam's
`SteamMultiplayerPeer` remaps any controller — including a Steam Deck's own — to a standard
Xbox-layout gamepad via Steam Input before Godot's `Input` singleton ever sees an event (§2.4), so
this task is entirely about giving that already-normalized device full coverage, not about detecting
Deck hardware specifically.

**Claim:** `project.godot` (InputMap only — see below), `entities/player/player_camera.gd`,
`entities/player/player_controller.gd`, `ui/hud/vitals_hud.gd`, `ui/inventory/inventory_ui.gd`,
`ui/building/build_bar.gd` (doc comment only), `autoload/settings_service.gd`,
`core/save/settings_save.gd`, `ui/menu/settings_menu.gd`, `tools/settings_check.gd`,
`tools/gamepad_check.gd` (new).

**The gap that mattered most: nothing rotated the camera from a gamepad at all.** Every other verb
(move, jump, sprint, interact, inventory, dodge, `attack`'s right-trigger axis) already had a joypad
`InputMap` event from earlier tasks, but `PlayerCamera.apply_look()` only ever ran from
`_unhandled_input`'s `InputEventMouseMotion` branch — a gamepad player could walk but never look
around. Fixed by four new axis-bound actions (`look_left`/`look_right`/`look_up`/`look_down`, right
stick, `JOY_AXIS_RIGHT_X`/`JOY_AXIS_RIGHT_Y`) and a new `PlayerCamera.apply_look_gamepad(delta:
float, input_allowed: bool) -> void`, polled every tick from `PlayerController._physics_process()`
(a HELD analog value, unlike mouse's one-shot motion event, so it has to scale by `delta` itself) —
new `@export var gamepad_look_sensitivity: float = 180.0` (degrees/SECOND, not degrees/pixel).
`input_allowed` (`gameplay_input_allowed()`, already resolved once per tick, F-105) is the gamepad
equivalent of mouse look's own `Input.mouse_mode == MOUSE_MODE_CAPTURED` gate — both `apply_look()`
and `apply_look_gamepad()` now share a `_rotate_view(yaw_delta, pitch_delta)` helper so the
clamp/invert-Y logic exists exactly once.

**Every raw-key/raw-mouse handler this project had accumulated for "no InputMap action, `project.godot`
was held elsewhere" reasons (F-095-era) is now a real action, keyboard/mouse PLUS gamepad-bound:**
`eat` (was `vitals_hud.gd`'s `EAT_KEY` = G; now G / gamepad D-pad down), `build_rotate` (was
`player_controller.gd`'s `BUILD_ROTATE_KEY` = R; now R / gamepad D-pad right), `build_destroy` (was a
raw right-click in the same file; now right-click / gamepad left trigger). `build` itself (existing
action, mode toggle) gained the gamepad button it was missing (D-pad up) — every other action already
had one; this was a plain gap, not a promotion. New gamepad-only `hotbar_prev`/`hotbar_next`
(shoulder buttons LB/RB) cycle `InventoryUI`'s hotbar selection with wraparound — the 1-8 number-row
keys stay keyboard-only on purpose, D-131, no sane single gamepad button per slot.

**`SettingsService`/`SettingsMenu` (task 7.5's own extension point, D-114's forward pointer —
"gamepad rebinding is task 7.6's own scope"):** `REBINDABLE_ACTIONS` (keyboard) grew by two (`eat`,
`build_rotate`) now that they are real actions; `build_destroy` stays out for the same mouse-primary
reasoning `attack` already had (D-131). A parallel `JOYPAD_REBINDABLE_ACTIONS` (10 button-bound
actions only — every axis/trigger-bound action, including movement/look/`attack`/`build_destroy`,
has no single-button capture flow, D-131) backs a new `rebind_action_joypad(action,
InputEventJoypadButton) -> StringName` / `keybind_label_joypad(action) -> String` pair, same
never-share-a-button conflict refusal `rebind_action()` already has for keyboard.
`gamepad_look_sensitivity()`/`set_gamepad_look_sensitivity(float)` joins the LOOK section (clamped
`[30, 720]` degrees/sec) next to mouse `look_sensitivity`. `SettingsMenu` gained a "GAMEPAD BINDS"
section (one row + capture button per `JOYPAD_REBINDABLE_ACTIONS` entry) alongside the existing
KEYBINDS section, and a second `_rebinding_joypad_action`/`_rebinding_joypad_button` capture-state
pair so a keyboard-row capture and a gamepad-row capture can never race each other. `reset_keybinds()`
now clears both keyboard AND gamepad overrides in one call (`InputMap.load_from_project_settings()`
already restores both). Persisted via a `joypad_binds` dict + `gamepad_look_sensitivity` scalar added
to `SettingsSave`'s schema — `_migrate()`'s existing backfill loop covers an old save missing either.

**Verify:** `tools/gamepad_check.gd` (new) — every action this task's gamepad support relies on
actually carries the joypad event `project.godot`'s hand-edited `[input]` section claims (a hand-typed
`.ini` is exactly where a typo'd button/axis index hides silently); `PlayerCamera.apply_look_gamepad()`
turning yaw/pitch from a real right-stick `Input.get_vector()` read, and being suppressed while
`input_allowed` is false; `InventoryUI`'s `hotbar_prev`/`hotbar_next` cycling with wraparound through
the real `_input()` path; `VitalsHud`'s `eat` action consuming a real hotbar item through the real
`_input()` path; the full build cycle — toggle / rotate / confirm / destroy — fired entirely through
real `InputEventJoypadButton`/`InputEventJoypadMotion` events into `PlayerController`'s real
`_unhandled_input()`, the same "feed the real handler" shape `tools/build_check.gd` already uses for
keyboard/mouse. `tools/settings_check.gd` extended for the joypad rebind API, `gamepad_look_sensitivity`
clamping, and the grown `REBINDABLE_ACTIONS`/new `JOYPAD_REBINDABLE_ACTIONS` counts.
No regressions: `verify_setup`/`build_check`/`combat_check`/`ranged_combat_check`/`inventory_ui_check`/
`net_robustness_check` all stay `failures=0`. `agent godot --quit-after 20`: 0 `ERROR:` lines on a
full boot.

**Done means:** `gamepad_check.gd` and `settings_check.gd` both at `failures=0`, the six regression
checks green, 0 `ERROR:` on a full boot, and `docs/DELEGATION.md`'s *Current state* carrying the full
gamepad `InputMap` action list + `PlayerCamera`/`SettingsService` API surface for whatever future task
touches input next.

**Explicitly NOT this task (see `docs/FINDINGS.md` F-209):** in-engine gamepad UI FOCUS navigation
(Tab/D-pad moving a highlight between `Button`s) for the menu shell — `MainMenu`/`SettingsMenu`/
`LobbyMenu`/`InventoryUI`/`CraftingUI`/`ChestUI`/`UnlockMenu` all still expect a mouse click. On a real
Steam Deck this is normally covered by Steam Input's own trackpad-as-virtual-mouse layer (the same
reason D-013 called Deck support "nearly free"), not by anything this codebase provides — a bare
gamepad with no Steam Input translation (a desktop Xbox controller, or a `--windowed` dev build) genuinely
cannot open these menus today.

---

## F-163 · `expr as Array[T]` silently fails to convert an untyped Array's element type — a `.set()` onto a typed-array `@export` then no-ops with no error

**Claim:** `docs/SPECS.md`, `docs/FINDINGS.md`, `tools/_probe_typed_array_convert.gd` (new, throwaway
— no production or check script needed a change; `tools/cycle_modifier_check.gd`, the file the
finding was filed against, already used the correct constructor form throughout).

**Root cause, confirmed by probe:** `expr as Array[StringName]` does not perform an element-wise
runtime conversion of an already-untyped `Array` — `get_typed_builtin()` on the result is still `0`
(untyped), and a subsequent `Object.set()` onto a strictly-typed `Array[StringName]` `@export`
property silently stores an empty array, no error either direction.

**The finding's own suggested fix needed a correction before it went into the standing rules.** It
named `Array[StringName](expr)` (bracket-generic constructor call) as *the* fix. That syntax is valid
inside a `.tres` text resource's own literal parser (`content/powerups/*.tres` already uses it), but
written as an executable statement in real `.gd` script code it is a **parse error** —
`Cannot call on an expression. Use ".call()" if it's a Callable.` — confirmed directly with
`tools/_probe_typed_array_convert.gd`. The forms that actually compile and work in script code: the
4-arg builtin constructor `Array(expr, TYPE_STRING_NAME, &"", null)` (what
`tools/cycle_modifier_check.gd` already uses, and the correct fix reference now), or declare-then-
`assign()`: `var typed: Array[T] = []; typed.assign(expr)`. Both confirmed round-tripping correctly
through `.set()`/`.get()` on a real `Array[StringName]` `@export`. A plain array literal assigned
directly to a typed-array-declared local (`var x: Array[T] = [...]`) still converts correctly at
declaration time — the failure is specific to converting an already-untyped `Array` *value*.

**Fix:** no code fix — `tools/cycle_modifier_check.gd` was already correct. This task added
`tools/_probe_typed_array_convert.gd` (a permanent regression-flavored probe, kept for whenever this
rule needs re-confirming against a future engine version) and promoted the corrected rule into
`docs/SPECS.md`'s standing-rules list (now five; see above), since the finding's own "what closes
this" said the note belongs there, one tier with F-016's `class_name` rule.

**Verify:** `agent godot --script tools/cycle_modifier_check.gd` → `CYCLE_MODIFIER_CHECK failures=0`,
0 engine `ERROR:`/`SCRIPT ERROR` lines, confirming the premise (files this finding named had already
changed since filing, and the fix was already in place). `agent godot --script
tools/_probe_typed_array_convert.gd` reproduces the trap and both working alternatives directly.

**Verified 2026-08-18 (lm):** both commands above ran clean; probe output confirmed `as Array[T]`
stores `[]`, both alternative forms store the full 2-element array.

---

## F-172 · Seed entry (task 6.10) only reaches the host-session path — solo/offline play draws its seed before any menu can be opened

**Claim:** `core/game_state.gd`, `tools/seed_launch_arg_check.gd` (new).

**Why the boot-gate fix is out of scope here:** the finding's own "why not fixed here" and D-110's
own "would change my mind" both reserve "gate world-gen behind a start screen" for a task scoped and
reviewed on its own — one that explicitly updates the two-process/full-boot check convention
(`--quit-after N`, the two-process driver/probe shape) to dismiss the gate first. That is not this
task: it is materially bigger, touches `run/main_scene`/`MireGrid` boot ordering, and no such task
exists on `docs/ROADMAP.md`. Relitigating D-110 as a side effect of closing a low-severity finding
would be the same mistake D-110 itself named and rejected for task 6.10.

**What actually closes it:** the finding's real complaint, underneath "only reaches the host-session
path," is narrower than a boot gate — **solo players have no way to set a seed at all**, full stop.
`GameState.set_pending_seed()`/`host_generate_seed()`/`ensure_seed()` (4.6, 6.10) already solve the
mechanism; the only gap is that nothing can call `set_pending_seed()` before `MireGrid._ready()`
consumes it on the solo path. A launch argument closes exactly that gap without moving boot order at
all: `core/dev/dev_launch.gd` already establishes the precedent of a debug-only `--host`/`--lan-join=`
family, and `autoload/steam_lobby.gd`'s `STEAM_CONNECT_LOBBY_ARG` establishes the precedent of a
**non-debug** cmdline arg reaching a real autoload in retail builds (Steam rich-presence join) — a
`--seed=<value>` arg for solo/offline play is the second case, not the first: it is a real
player-facing feature (the same one `MainMenu`'s seed field already offers hosts), reachable the one
way solo play can reach it before world-gen ever runs — Steam's own "Launch Options" field, or a
desktop shortcut, both of which already exist for players on any Steam title.

**Fix:** `GameState._ready()` gains `_apply_launch_seed_arg()` as its very first line (before the
existing `NetTransport` wiring), reading `OS.get_cmdline_user_args()` (falling back to
`OS.get_cmdline_args()`, same two-step `dev_launch.gd` already uses) for a `--seed=<text>` argument
and staging it via the existing `set_pending_seed()`. Parsing mirrors `ui/menu/main_menu.gd`'s own
`request_set_seed()` exactly — a pure integer is used as-is (`String.is_valid_int()` /`to_int()`),
any other text is hashed with `String.hash()` so a shared word-seed behaves identically whether typed
in the menu or passed on the command line, and a hashed/typed value that lands on exactly 0 is bumped
to 1 (0 means "no override" in `set_pending_seed`'s own contract). `GameState` is last-but-one in
`[autoload]` order, immediately before `MireGrid` — every other autoload the file already depends on
(`NetTransport`) is registered earlier, and nothing downstream of `GameState` can consume the seed
before its own `_ready()` finishes, so the staged value is guaranteed to be in place before
`MireGrid.ensure_ready()`'s `GameState.ensure_seed()` call ever runs, solo or hosted.

**Done means:** `tools/seed_launch_arg_check.gd` proves, in a real headless process launched with
`--seed=<int>`, that `GameState.run_seed` after boot equals that exact integer — i.e. `MireGrid`'s
own real, automatic boot-time draw (not a value the check script drew itself) used the launch-arg
seed instead of real entropy. A spawned child process with no `--seed=` arg proves the default (no
override) path is unchanged, and a spawned child with a non-integer `--seed=` text proves the
`String.hash()` parity with `MainMenu.request_set_seed()`.

**Verified 2026-08-19 (lm):** `agent godot --script tools/seed_launch_arg_check.gd -- --seed=204060517`,
twice back to back — `SEED_LAUNCH_ARG_CHECK failures=0` both times, all 8 assertions PASS. No
regression: `agent godot --script tools/main_menu_check.gd` (28/28 PASS, including the pre-existing
seed-staging assertions) and `agent godot --script tools/seed_sync_check.gd` (host/client seed
replication, 12/12 PASS) both stayed clean after this change to `GameState._ready()`.

---

## F-175 · `Array[StringName].sort()` does not sort lexicographically — at least two other call sites besides F-167's rely on it anyway

**Claim:** `ui/loot/chest_ui.gd`, `autoload/rule_service.gd`, `systems/inventory/inventory_store.gd`,
`tools/stringname_sort_check.gd` (new), `docs/FINDINGS.md`, `docs/SPECS.md`.

**Root cause:** already established under F-167 — `StringName`'s `<` compares interned identity, not
string content, so `Array[StringName].sort()` silently tracks whatever order the values happened to
be interned in rather than alphabetical order. F-167 fixed the one site it hit
(`CraftingService.recipes_for_station()`) and filed F-175 naming two more sites it found by grep but
did not touch, since neither file was in its claim set.

**Fix, three sites, same shape as F-167's:**
1. `autoload/rule_service.gd` — `rule_ids()` now sorts with
   `ids.sort_custom(func(a, b): return String(a) < String(b))`. Feeds the `rules` console command's
   listing order and `RuleService`'s own doc comment's "stable order" promise, which plain `.sort()`
   never actually delivered.
2. `ui/loot/chest_ui.gd` — `_populate_rewards()`'s reward-row order gets the same fix. Not yet
   player-visible (F-151: chest UI has no in-game caller), but the panel now genuinely orders its
   rows alphabetically once one exists.
3. `systems/inventory/inventory_store.gd` — `_sorted_ids()` gets the same fix. Feeds
   `apply_transaction()`'s removal/addition order for the crafting seam; order doesn't change
   transaction correctness (removals fully precede additions either way) but was silently not the
   stable alphabetical order the function's contract implies.

**Swept for more:** grepped every `Array[StringName]` declaration in the codebase against every
plain `.sort()` call site. Found one more pair — `autoload/command_service.gd`'s
`spec_names()`/`function_names()` — not fixed here because that file was held by lane lp's F-157
claim for this session's entire duration; filed as F-179 rather than left undiscovered for the next
lane to re-find from scratch. No other site pairs an `Array[StringName]` with a plain `.sort()` as of
this session.

**Verify:** new `tools/stringname_sort_check.gd` boots the real project and proves all three fixes
directly: `RuleService.rule_ids()` returns its 8 shipped rules in lexicographic order;
`InventoryStore._sorted_ids()` (called via `.call()`, same pattern other checks use for
underscore-named methods) sorts a 3-key out-of-order dict correctly; `ChestUI._populate_rewards()`
renders three granted items (`wooden_axe`, `arrow`, `mushroom`) as reward rows in `Arrow, Mushroom,
Wooden Axe` order rather than dictionary-insertion order.

**Verified 2026-08-19 (lm):** `agent godot --script tools/stringname_sort_check.gd` →
`STRINGNAME_SORT_CHECK failures=0`, all 8 assertions PASS, run twice back to back to rule out
flakiness.

---

## F-179 · `CommandService.spec_names()`/`function_names()` are the fourth and fifth `Array[StringName].sort()` sites F-175 found — not fixed there, `autoload/command_service.gd` was held all session by another lane's claim

**Claim:** `autoload/command_service.gd`, `tools/stringname_sort_check.gd`, `docs/FINDINGS.md`,
`docs/SPECS.md`.

**No spec existed for this finding** (filed 2026-08-19, the same session as this file's last sweep)
— writing it is this task's own first step, per this file's preamble.

**Root cause:** the same one F-167 and F-175 already established — `StringName`'s `<` compares
interned identity, not string content, so `Array[StringName].sort()` silently tracks interning order
instead of alphabetical order. F-175 swept the codebase for every remaining `Array[StringName]` +
plain `.sort()` pair and found two more sites in `autoload/command_service.gd`, but could not fix
them there — the file was claimed by lane lp for F-157 for that entire session — so it filed this
finding instead of leaving the pair undiscovered for the next lane to re-find from scratch.

**Fix, two sites in `autoload/command_service.gd`, same shape as F-167/F-175's:**
1. `spec_names()` (line ~143) — `names.sort_custom(func(a, b): return String(a) < String(b))`.
   Backs the `help` console command's listing (see the function's own doc comment: "a caller … that
   wants to list commands without going through execute()/submit()"), so plain `.sort()` was silently
   ordering `help`'s output by registration order, not alphabetically.
2. `function_names()` (line ~469) — identical fix. Same shape, no live caller found beyond
   `tools/stringname_sort_check.gd`'s own new coverage and `debug_console.gd:299`'s display use,
   neither of which depended on the broken order, so this is a latent-bug fix, not a behavior change
   any existing check had baked an assumption around.

**Verify:** extended `tools/stringname_sort_check.gd` with `_check_command_service()`, same shape as
its existing `RuleService.rule_ids()` case. Registers three throwaway specs
(`register_spec()`, a public API) and three throwaway functions (`register_function()`, also public)
with names chosen out of alphabetical order on purpose — `zz_…`, `aa_…`, `mm_…` — so a regression
back to plain `.sort()` would have to coincidentally re-produce alphabetical order to slip past.
Asserts `spec_names()`/`function_names()` include all three test entries and equal their own
`sort_custom`-sorted duplicate.

**Verified 2026-08-19 (lm):** `agent godot --script tools/stringname_sort_check.gd` →
`STRINGNAME_SORT_CHECK failures=0`, all 14 assertions PASS (the prior 9 from F-175 plus 5 new), run
twice back to back. No regression: `tools/command_check.gd` (`COMMAND_CHECK failures=0`) and
`tools/command_catalog_check.gd` (`COMMAND_CATALOG_CHECK failures=0`) both stayed clean.

---

## F-147 · F-145's fix protects new sessions only — already-collided identities stay live for up to SESSION_KEEP_DAYS

**Claim:** `.agent/bin/agent`, `tools/harness_check.py`, `docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** (it was filed 2026-08-18, the same day as this file's last
sweep) — writing it is this task's own first step, per this file's preamble.

**Root cause:** F-145 fixed `_auto_name()` — a chat's assigned name is now unique among live
sessions going forward — but left the *comparison* untouched everywhere a claim's ownership is
checked (`agent claim`, `agent brief`, the pre-commit `agent check`, `_blame_foreign_break`): every
one of them read `claim["agent"] != me`, a bare name compare. That is exactly the property that had
already failed once: F-147's own live example recorded two different chat sessions both auto-named
`nettle12` in one working tree, one of them holding five live `F-144` claims. Nothing in F-145's fix
helps that pair — `whoami()` returns each session's *already-registered* name from `sessions.json`
before `_auto_name()` is ever consulted again — and nothing stops a third chat from colliding with
either of them the same way for up to `SESSION_KEEP_DAYS` (14 days) after the older session's last
activity. A name-only claim can't tell such sessions apart, so `agent claim` grants a claim its
holder never made, and the pre-commit `check` waves the resulting commit through.

**Fix — do the durable part F-145 deliberately deferred:** store the claiming session's token
(`_session_token()`, e.g. `"CLAUDE_CODE_SESSION_ID:<uuid>"`) beside `agent` in every claim record,
and prefer it over the name wherever ownership is decided.

- New `whoami_token()`: the current chat's session token, or `None` for a lane (`MIRE_AGENT` is
  fixed and unique by construction, so a lane claim intentionally carries no token) or a shell with
  no session id at all.
- New `_is_mine(record, me, me_token)`: if the record has a stored `token` *and* the caller has one,
  compare tokens; otherwise fall back to the name compare, which is what a lane claim and every
  claim written before this change still need.
- `cmd_claim` now writes `"token": whoami_token()` into both the `in_flight` entry and every file's
  `claims` entry; `_release()` carries it into the `recent` snapshot `check`'s grace window reads.
- Every ownership comparison in `cmd_claim`, `cmd_brief`, `cmd_check` (including its `in_grace`
  closure), and `_blame_foreign_break` now calls `_is_mine()` instead of comparing `["agent"]`
  directly. `agent order`'s own conflict check (line ~2140, comparing a live claim against a
  *target lane's* fixed name before dispatch, not against the caller's own identity) is deliberately
  untouched — there is no "my session" to prefer a token for there, and lane names don't collide.

**Does not touch the residual window itself:** already-collided `sessions.json` entries still exist
and still resolve to shared names until `_prune_sessions()` drops them at `SESSION_KEEP_DAYS`. That
was F-145's deliberate, documented tradeoff (renaming a live session would orphan its claims
mid-task) and this task doesn't relitigate it. What changes is the *consequence* of a collision
happening: two sessions sharing a name can no longer walk into each other's claims, because the
schema no longer depends on the name being unique to prove ownership.

**Verify:** two new `tools/harness_check.py` cases build on its existing sandboxed-repo harness.
Both rig `sessions.json` so two different session tokens resolve to the *same* auto-name
(`nettle12`), reproducing the finding's live example without depending on `crc32` luck:
- `check blocks a colliding SESSION TOKEN even when the auto-assigned NAME matches` — a claim
  written under token A's name+token; `agent check` run as token B (same name, different token)
  over the same file must be refused.
- `check still allows the SAME session token to commit its own harness claim` — the no-regression
  control: the exact same setup run as token A itself must pass clean.

Confirmed the first case is a real regression test, not a vacuous one: run against the pre-fix
harness at `HEAD` (`python3 tools/harness_check.py --rev HEAD`) it fails (`21/22`); against the
fixed working tree it passes (`22/22`).

**Verified 2026-08-18 (lm):** `python3 tools/harness_check.py` → `22/22 passed`, including both new
cases. `python3 -m py_compile .agent/bin/agent` clean. Also exercised `_is_mine()` and the
claim-write path directly (loaded the real module, repointed its state paths at a scratch
directory so the live shared board was never touched) to confirm: a same-name/different-token
claim is blocked, a legacy claim with no `token` field still falls back to name comparison for its
own session, and a lane's (`MIRE_AGENT`) claim stores no token and is still recognized as its own.

---

## F-148 · `construction_check.gd`'s door-swing solids AABB goes negative-size on thin per-triangle bounds, throwing an UNDECLARED engine error on every run

**Claim:** `tools/construction_check.gd`, `docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause:** `_check_doors()` builds a per-triangle collision solid as `AABB(low, high -
low).grow(-0.004)`, shrinking every face 4 mm inward so a near-touch between a swinging leaf and its
frame doesn't misreport. A triangle is planar, so its bounding box is routinely near-zero on at least
one axis; shrinking an axis already thinner than 8 mm by 4 mm on each side drives that axis negative,
and `AABB.has_point()` refuses a negative-size box with an UNDECLARED `ERROR: AABB size is negative`
— logged once per vertex-vs-solid comparison that hits a degenerate solid (213,000+ times on the
`.tscn` state that first surfaced it, per the finding's 2026-08-18 update).

**Fix — clamp the shrink per axis instead of growing past zero:** new `_shrunk_solid(low, high,
margin)` computes the triangle's center and half-extent directly and clamps each axis's half-extent
at `0.0` (`maxf(half.axis - margin, 0.0)`) before reconstructing the `AABB`, replacing the
`AABB(low, high - low).grow(-0.004)` call at the single site in `_check_doors()`. A degenerate axis
collapses to zero width (no tolerance left to shrink) instead of inverting past zero.

Rejected the finding's other suggested fix, `.abs()`: called *before* `grow()` it's a no-op (`AABB(low,
high - low)` is already non-negative by construction, since `high`/`low` come from `.max()`/`.min()`).
Called *after* `grow()` it produces a valid-but-wrong box — `AABB.abs()` normalizes a negative axis by
shifting `position` by the full negative `size`, which on a degenerate axis (already smaller than the
8 mm total shrink) flips the box to extend *outside* the original triangle's bounds on that axis
rather than collapsing to it, silently loosening the door-swing check's tolerance exactly on the
triangles most likely to matter.

**Verify:** `agent godot --script tools/construction_check.gd`, grep for `ERROR:` — must be zero
regardless of `CONSTRUCTION_CHECK`'s own PASS/FAIL verdict (the check's functional door-swing result
is orthogonal to this finding, which is scoped to the crash only).

**Verified 2026-08-18 (lm):** `agent godot --script tools/construction_check.gd` run twice —
`grep -c 'ERROR:'` → `0` both times (previously 213,000+, or 4.8M+ on a heavier `.tscn` state per
the finding's own note). `CONSTRUCTION_DOORS swung=4` prints both runs; the check now completes and
reports `CONSTRUCTION_CHECK FAIL failures=3` deterministically — three real strap-vs-frame overlaps
that the crash was previously masking (`AABB.has_point()` errors and returns `false` on an invalid
box rather than throwing, so every comparison against a degenerate solid was silently skipped, not
evaluated). Those three failures are a genuine, separate issue in task 3.7's in-progress door/gate/
palisade-gate geometry — filed as F-180 rather than fixed here, since `door.tscn`/`gate.tscn`/
`palisade_gate.tscn` are outside this task's claim and held by task 3.7 for the session.

---

## F-168 · `Wellspring._finish_cap()` still emits `wellspring_capped` from a host-only guard, so a non-host peer's `SalvageService` milestone bonus silently undercounts

**Claim:** `systems/wellspring/wellspring.gd`, `tools/wellspring_check.gd`, `docs/FINDINGS.md`,
`docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause:** `EventBus` is a per-process static (its own header comment says so), so an emit call
that only runs inside a host-only `if` branch never reaches a client's own local bus — only the
host's ever fires. `_finish_cap()` had `EVENT_BUS.emit_wellspring_capped(name, global_position)`
sitting directly in that host-only branch, the exact shape task 6.6 already fixed once for
`ExtractionShip.departed` (`systems/extraction/extraction_ship.gd`). `capped`/`channeling`/
`progress_sec`/etc. are the only state that crosses the wire, through a code-built
`MultiplayerSynchronizer` — a non-host peer only ever learns `capped` went true from a replicated
property delta, which never runs `_finish_cap()` at all. Consequence: on a non-host peer, capping a
Wellspring correctly updates the replicated `capped`/mesh state, but that peer's own
`SalvageService` never sees `wellspring_capped` and its Salvage payout is short by
`WELLSPRING_CAP_BONUS` per cap it didn't personally trigger as host.

**Fix — the same move `extraction_ship.gd`'s `departed` setter already made:** moved
`EVENT_BUS.emit_wellspring_capped(name, global_position)` out of `_finish_cap()`'s body and into
`capped`'s setter, guarded on the false→true transition. The setter now fires identically whether
this process just set `capped = true` itself (the host, via `_finish_cap()`) or received it over the
wire (a client, via `_sync`).

**Not fixed in the same pass:** `_finish_recorruption()` has the identical host-only-guard shape for
`emit_wellspring_recorrupted` (`capped = false` there is likewise inside a body only `host_tick()`
— itself gated on `_owns_mutation()` — ever calls). Left alone: nothing subscribes to
`wellspring_recorrupted` yet (`core/events/event_bus.gd`'s own comments call it a seam for a future
system, same role D-092 gives `wellspring_capped`), so there is no live undercount to fix, and
folding it in here would be scope creep on a task whose claim is `wellspring.gd` for the
`wellspring_capped` bug specifically. Filed as F-181 for whichever task first gives
`wellspring_recorrupted` a real subscriber.

**Verify:** `agent godot --script tools/wellspring_check.gd` (new `_check_capped_event_via_replication()`
proves the fix directly — a bare `capped = true` write with no ritual and no `host_tick()` in the
call stack, the exact shape a client's synchronizer delta takes, now fires the event), plus
`tools/wellspring_recorruption_check.gd` and `tools/salvage_check.gd` to confirm the host-side
ritual/recorruption/milestone-bonus behavior is unchanged.

**Verified 2026-08-18 (lm):** all three green — `WELLSPRING_CHECK failures=0`,
`WELLSPRING_RECORRUPTION_CHECK failures=0`, `SALVAGE_CHECK failures=0`.

---

## F-173 · `UnlockService.is_content_unlocked()` (task 6.9) has no caller anywhere in the game — wiring the first real gate needs a cross-peer design decision, not just a call site

**Claim:** `autoload/unlock_service.gd`, `systems/loot/loot_table_def.gd`, `systems/loot/chest.gd`,
`tools/unlock_check.gd`, `content/unlocks/unlock_deep_pocket.tres`, `docs/FINDINGS.md`,
`docs/DECISIONS.md`, `docs/DELEGATION.md`, `docs/SPECS.md`, `docs/ARCHITECTURE.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**The cross-peer question, and why it wasn't a missing line of code:** `is_content_unlocked()`
answers only for the CALLING peer's own `user://unlocks.json` (§2.2's "Unlocks" row is **None** —
per-player, unreplicated, the same shape Salvage already has). `LootTableDef.roll()` runs once,
host-side, for whichever peer opened the chest. Checking the gate there meant picking one of D-111's
two options: gate the whole party's roll off the HOST's own unlock set regardless of who opened the
chest, or ask the OPENING peer's own save — for which no seam exists, since Salvage/Unlocks were
built with no RPC of their own on purpose. D-111 settled on the first: **the HOST's own unlock tree
gates the run for everyone**, needing no RPC at all.

**Fix — no new seam, just the call site D-111 unblocked:**
1. `systems/loot/loot_table_def.gd`: `roll()` gains a third, optional `is_unlocked: Callable`
   (default an invalid Callable). In the existing per-entry weight loop, a POWERUP entry whose
   `is_unlocked.call(item_id)` returns false is zero-weighted for that draw — the same "weight <=
   0.0 is skipped" path `_weighted_pick()` already had. ITEM entries are never gated (kind check
   guards it). An unset Callable never filters anything, so every pre-existing call site
   (`tools/chest_check.gd`, `tools/loot_content_check.gd`, `InventoryService._cmd_loot`'s debug
   `loot` command) is unaffected.
2. `systems/loot/chest.gd`: new private `_unlock_check()` returns
   `Callable(unlock_service, "is_content_unlocked")` when `/root/UnlockService` is present, else an
   invalid Callable (fail-open, matching `is_content_unlocked()`'s own posture when ITS dependency,
   Registry, is missing). `_accept_open_request()` passes it as `roll()`'s third argument. Because
   `_accept_open_request()` only ever executes in the host process (called directly when this peer
   IS the host, or from `net_request_open` behind its own `_transport_is_host()` guard), the
   `UnlockService` instance `_unlock_check()` resolves is always the host's own — never the opening
   peer's — with no RPC required to guarantee that.
3. `autoload/unlock_service.gd`: header + `is_content_unlocked()` doc record the one rule this
   design leans on — only ever call it from a codepath that runs in the asking process's OWN host,
   never trust a value carried in from another peer.
4. `content/unlocks/unlock_deep_pocket.tres`: description no longer claims "no pool checks this."

**What this does NOT close:** POI placement and `WaveSpawner.host_unlock_next_enemy()` (an
unrelated, in-run "unlock," not this system) both need state that is byte-identical across every
peer — D-111's "one level worse" case, which a per-peer unlock set cannot satisfy through this same
"only ever ask the host" trick without either replicating purchases or making unlocks session-wide.
Not attempted here; F-173's own "what closes this" scoped the first consumer to the loot roll only.

**Verify:** `agent godot --script tools/unlock_check.gd`. New coverage: a pure `LootTableDef.roll()`
unit test (no UnlockService involved — a gated POWERUP entry with `is_unlocked() -> false` is never
drawn even as the table's only entry; the same entry with `true` rolls normally; an ITEM entry is
never gated; a bare `roll(rng, luck)` call with no third argument is unaffected) plus a real
`Chest`-open integration test against the worked example's own gate (`deep_pocket`, matching
`content/loot/bog.tres`'s real line): a locked open grants nothing, and the identical
Registry-indexed tier grants the powerup once `unlock_deep_pocket` is purchased through the real
purchase flow — same `UnlockService` instance both times. Regression: `tools/chest_check.gd`,
`tools/loot_content_check.gd`.

**Verified 2026-08-19 (lm):** `agent godot --script tools/unlock_check.gd` → `UNLOCK_CHECK
failures=0`, run twice. `tools/chest_check.gd` → `CHEST_CHECK failures=0`. `tools/loot_content_check.gd`
→ `LOOT_CONTENT_CHECK failures=0`. `tools/findings_numbering_check.gd` → `failures=0` after moving
this finding to `## Resolved`. F-182 filed along the way for an unrelated pre-existing gap this
verification surfaced (`tools/unlock_check.gd`'s corrupt-save test has no
`EXPECTED_ERROR_PATTERNS` declaration) — not fixed here.

---

## F-146 · Nothing in the game places a chest, so the gilded tier's 1-2/island budget has no owner

**Claim:** `autoload/chest_placement_service.gd`, `tools/mapgen/hollowmere_layout.py`,
`world/gen/layouts/hollowmere.json`, `tools/chest_placement_check.gd` (+ its `.uid`), `project.godot`
(autoload registration only, via `agent autoload`), `docs/FINDINGS.md`, `docs/SPECS.md`,
`docs/DECISIONS.md`, `docs/DELEGATION.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause:** two gaps, not one. `systems/loot/chest.gd` was a complete, net-authoritative,
headlessly-proven chest that nothing in `world/` ever instantiated — `grep -rn chest --include='*.gd'
world/` returned zero hits, exactly as F-146 recorded. But `tools/mapgen/hollowmere_layout.py`
already had HALF the content: 8 `Cache_<n>` markers (`kind == "loot"`) sitting next to 8
already-shipped `loot_chest_small_closed` decorative props (the "waymarks and loot worth walking to"
loop, task 4.7-era authoring) — a marker with no code that ever read it. The gilded tier had neither
half: no marker, no budget, no owner, matching F-140's own note while resolving 3.5's other three
items ("a placement budget for gilded is still open and belongs to whatever places chests in the
world").

**Fix, two parts:**

1. **`autoload/chest_placement_service.gd`** — a runtime bridge, same shape
   `wellspring_service.gd`/`crafting_service.gd` already use for `authored_world.gd`'s other marker
   kinds: watches `authored_world_marker` (`kind == "loot"`), reads a tier out of the marker's own
   NAME (`"Cache_<n>"` → `small`; `"Chest_<tier>_<n>"` → `<tier>` verbatim), and instances a live
   `Chest` there with per-tier `cost_coins`/`locked_by` from a small economy table. Authority: none
   of its own (deterministic, identical build on every peer — see docs/ARCHITECTURE.md §2.2's new
   row). This alone gives the 8 shipped `Cache_` markers their first live gameplay consumer — they
   have been decorative-only since task 4.7.
2. **`tools/mapgen/hollowmere_layout.py`** gained `build_gilded_chests()`: two `"Chest_gilded_<n>"`
   markers (`SouthMarsh` and `StoneMoor`, picked because both cleared the ordinary
   slope/water/clearance/road placement rules with room to spare — `force` stays False, unlike the
   waymark loop's, because a rare chest should not need to be forced through a wall to exist), using
   `loot_chest_reinforced_closed` as a placeholder mesh (no gilded-tier asset exists yet, A-047 is
   still queued per ITEMS.md §7 — swap the asset the day it ships, nothing else about the placement
   changes). `validate()` now re-derives the count from `markers` itself and fails the generator
   build if it is ever outside 1-2 — the budget is enforced at content-generation time, not just
   documented. `world/gen/layouts/hollowmere.json` regenerated; byte-identical on a second run
   (determinism preserved, D-017/D-028).

**Design calls this task made, not re-litigated elsewhere — see D-122:** gilded is **key-only**
(`locked_by = &"gilded_key"`, `cost_coins = 0`) — ITEMS.md's item catalog is unambiguous ("Gilded Key
... opens the Gilded Chest", line 243) even though the chest-table column's "≈1-2/island **or** a
Gilded Key" phrasing reads more loosely. Bog/strongbox get the coin-gate half of their own
"or a key" economy (`Chest._accept_open_request()` charges `cost_coins` AND `locked_by` in ONE
transaction — it has no either/or mode, so a single placed instance can only express one gate); no
map content places either tier yet, so this is the table ready for whoever does. Sunken stays
unpriced ("risk-priced rather than coin-priced", ITEMS.md §5) — the hazard IS the price, not
something `Chest`'s two gates can express, so this bridge does not place sunken chests at all
pending a real hazard-placement pass.

**Not fixed here, on purpose:** `wellspring`/`boss` tier chests are event-granted (a Wellspring cap,
a boss kill), not world-scattered — genuinely a different owner, out of this finding's "placement"
scope; filed as F-183 since neither currently has one either. Sunken/bog/strongbox get the bridge's
economy table but no map markers yet — the finding named gilded's budget specifically, and adding
map content for tiers nobody asked to place yet would be scope creep past what F-146 actually found
broken.

**Verify:** `agent godot --script tools/chest_placement_check.gd` — boots the REAL `main_scene`
(Hollowmere), not a synthetic stand-in: all 8 shipped `Cache_` markers get a live, free, openable
`small`-tier `Chest`; the gilded markers land within the 1-2 budget, locked by `gilded_key`, no coin
price; a live free chest actually opens end to end (roll → grant → `InventoryService`); a live gilded
chest is actually refused without the key, with a "locked" detail naming it. A fourth section adds
synthetic markers to cover what a fixed live map cannot: wrong `kind`, an unrecognised name prefix,
and idempotency across a second rescan. Plus `tools/mapgen/hollowmere_layout.py` itself —
`HOLLOWMERE_VALIDATE PASS`, its own budget assertion included.

**Verified 2026-08-19 (lp):** `python3 tools/mapgen/hollowmere_layout.py` → `HOLLOWMERE_VALIDATE PASS`,
JSON byte-identical on a second run. `agent godot --script tools/chest_placement_check.gd` →
`failures=0`, run twice. `agent godot --quit-after 120` → clean boot, no new `ERROR:` lines.
`tools/chest_check.gd`, `tools/loot_content_check.gd`, `tools/entity_check.gd` all still
`failures=0` — this task's bridge does not touch `chest.gd` itself, and none regressed.

---

## F-176 · `tools/audio/render_music.py`'s ambient tracks are not byte-identical on re-render, contradicting `docs/AUDIO.md`'s "reproduces the committed files bit-for-bit" claim

**Claim:** `tools/audio/render_music.py`, `tools/audio/repro_check.py`, `docs/AUDIO.md`,
`docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause — two, not one, and neither is what the finding guessed.** The finding suspected the
divergence lived entirely in the OGG encode step. Re-rendering twice on this machine showed the
master **WAVs themselves** differ between runs (not just the OGGs), which the fixed-seed synthesis
should never allow. `pad_note_spans()` in `render_music.py` builds `wanted = set(notes)` and then
does `for note in wanted: active.setdefault(note, t)` — Python randomizes a `set`'s string
iteration order per process (`PYTHONHASHSEED`), and `render_track()`'s pad loop draws from a single
shared seeded `rng` once per span, in the order `pad_note_spans` yields them. A hash-randomized
iteration order silently reordered those `rng` draws every run, so the fixed seed never actually
pinned the output — this is real, and predates this finding; F-176 just mis-attributed the symptom
to encoding. Separately, and unrelated to the above, the OGG **container** is never going to be
byte-identical even given byte-identical PCM input: libsndfile's OGG writer stamps a random 32-bit
per-stream serial number into every page's header on each encode (part of the OGG container spec,
not a MIRE bug), which also perturbs each page's CRC. Decoded audio content is unaffected either
way.

**Fix:** `pad_note_spans()` now iterates `sorted(wanted)` instead of the raw `set`, making note
insertion order (and therefore every downstream `rng` draw) independent of the process hash seed.
`docs/AUDIO.md`'s claim is reworded to say precisely what's true: the PCM synthesis/master `.wav`
files are bit-for-bit reproducible; the shipped `.ogg` files are not byte-identical across encodes
(container serial number/CRC only) but decode to bit-identical PCM.

**Verify:** new `tools/audio/repro_check.py` renders `render_music.py` twice into throwaway temp
dirs (never touching `assets/audio/music/`) and asserts (a) the two runs' master `.wav` files are
byte-identical, (b) the two runs' `.ogg` files decode (via `soundfile`) to bit-identical PCM.
Fixed a copy-paste exit-code inversion while writing it — see F-184.

**Verified 2026-08-18 (lm):** `python3 tools/audio/repro_check.py` → `REPRO_CHECK failures=0`, all
6 checks (3 tracks × wav+ogg) PASS, exit 0, run twice. Also reproduced the pre-fix bug directly:
before the `sorted()` change, `ambient_day.wav` and `ambient_night.wav` differed byte-for-byte
across two consecutive re-renders on this machine (peak dBFS drifted ±0.5 dB run to run); after the
fix, identical across repeated runs both with a forced `PYTHONHASHSEED=0` and with Python's default
randomized hash seed. Did not regenerate the committed `assets/audio/music/*.ogg` files — they were
rendered under the pre-fix code and remain valid audio; this task only makes *future* re-renders
reproducible. `git status assets/audio/music/` confirmed clean throughout.

---

## F-180 · `construction_check.gd`'s door-swing check now finds real strap-vs-frame overlaps at 0 degrees, previously hidden by F-148's crash

**Claim:** `tools/blender/build_construction_set.py`, `assets/construction` (catalog, exports,
previews, README), `assets/source/construction_set.blend`. No `.tscn`/`.tres`/`.import` — the three
scenes task 3.7 (slate17) had in flight (`door.tscn`, `gate.tscn`, `palisade_gate.tscn`) reference
these GLBs but never needed editing; the fix is entirely upstream, in the art.

**What was wrong:** F-148 fixed a crash in `_check_doors()`'s per-triangle `AABB.grow(-0.004)` going
negative on near-planar triangles. With the crash gone, the swing check actually ran to completion
and found `door_wood_leaf`, `gate_double_leaf_left` and `gate_double_leaf_right` each had a hinge
strap sitting exactly on the frame's collision face at 0 degrees (closed) rather than clear of it.

Root cause, once traced through `tools/blender/build_construction_set.py`'s `create_asset()`: every
`HINGE`-family leaf (door, both gate halves, the palisade gate) is normalized so its swing-side edge
lands at exactly local x=0 and its back-most extent lands at exactly local y=0 (Blender axes) — "the
leaf's outer back corner," per `assets/construction/README.md`'s origin-rules section, chosen so
`position = hinge_offset_m; rotate_y()` is the whole placement API (D-039). Separately,
`hinge_offset_m` for each leaf was authored to place that same local origin exactly at its frame's
opening edge (`half_width` from centre) — a real doorway, not a gap. Both constants are individually
correct; together they put a genuinely-touching, non-degenerate leaf edge on the exact float value of
the frame jamb/post's inner collision face. `Leaf_Strap_0`/`Gate_{L,R}_Strap_0` are the parts whose
geometry reaches x=0 (the near end of the hinge strap plate), so they were the first thing the sweep
caught, but they were not the only ones: fixing just the straps unmasked further parts touching the
same face by the same mechanism — `Leaf_Board_0` at 0° (its near edge is also at x=0), and
`Leaf_Ledge_0/1`, `Leaf_Brace`, and both gates' `Rail_*`/`Brace_*` at 90° (their back edge is at the
leaf's own y=0/z=0 reference, which a 90° rotation maps onto the same x=0 frame face). This is a
systemic authoring pattern, not three isolated strap placements, so per-part nudges would have kept
surfacing new failures one at a time (confirmed by trying it: fixing the straps alone revealed the
board; a wider fix was needed).

**The fix:** `HINGE_CLEARANCE = 0.008` (new constant), applied inside `create_asset()`'s `HINGE`
branch so the whole leaf is shifted a real 8 mm off both reference planes instead of exactly onto
them — `offset.x` becomes `-low.x + HINGE_CLEARANCE` (or `-high.x - HINGE_CLEARANCE` for a
leaf that opens `-x`), and `offset.y` becomes `-high.y - HINGE_CLEARANCE`. `hinge_offset_m` itself is
untouched (it is a separate, hand-authored frame-placement constant, not derived from this internal
normalization), so nothing downstream that reads the catalog changes. `check()`'s own two flush-origin
assertions (`hangs behind its hinge axis`, `hinge edge at x=...`) were updated in lockstep — they now
assert `HINGE_CLEARANCE`, not zero, since the zero-tolerance version is exactly the assumption that
turned out to be wrong. Left `check()`'s existing 90°-swing sweep and its 5 mm jamb tolerance alone;
that check already tolerated a small real gap; it just never had one to check against before.

**Verified 2026-08-18 (lm):** `/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/build_construction_set.py` → build contract passes (0 problems), only the four HINGE
exports changed (`door_wood_leaf`, `gate_double_leaf_left`, `gate_double_leaf_right`,
`palisade_gate_leaf`) plus the four preview PNGs and the `.blend` source; the other 14 GROUND/JOINT
exports and `catalog.json` are byte-identical, confirming the fix is contained to the leaf
normalization. `.agent/bin/agent godot --script tools/construction_check.gd` → `CONSTRUCTION_CHECK
PASS`, run twice. Also wrote a throwaway probe (not committed) that replicates `_check_doors()`'s
overlap test without its stop-at-first-failure behaviour, to confirm zero touches remain across the
full 0–90° sweep for all four hinge leaves, not just the one failure `CONSTRUCTION_CHECK` happens to
report first.

---

## F-181 · `Wellspring._finish_recorruption()` has the same host-only-guard `EventBus` emit bug F-168 fixed for `wellspring_capped` — `wellspring_recorrupted` still only fires on the host

**Claim:** `systems/wellspring/wellspring.gd`, `tools/wellspring_check.gd`, `docs/FINDINGS.md`,
`docs/SPECS.md`, `docs/DELEGATION.md`, `docs/ARCHITECTURE.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Check the finding before editing, per its own instruction — it was still real.**
`tools/wellspring_recorruption_check.gd` passed at HEAD (`failures=0`), but that check runs entirely
single-process with no transport active, so `_owns_mutation()` is unconditionally true and
`_finish_recorruption()` always runs — it cannot distinguish "the emit fires on every peer" from "the
emit fires only because this process happens to be host." Reading `_finish_recorruption()` directly
confirmed the bug F-168's own spec block (above) predicted when it filed this finding: `capped = false`
sat alongside `EVENT_BUS.emit_wellspring_recorrupted(name, global_position)` inside a body only
`host_tick()` — itself gated on `_owns_mutation()` — ever calls. A non-host peer never runs
`_finish_recorruption()` at all, so it never fired the event, even though its own replicated `capped`
correctly flips to `false` via the synchronizer.

**Fix — the identical move F-168 made for the true→true transition, applied to the true→false one:**
moved `EVENT_BUS.emit_wellspring_recorrupted(name, global_position)` out of `_finish_recorruption()`'s
body and into `capped`'s setter's `else` branch (the setter already special-cased the `true` branch for
`wellspring_capped`; `capped` only ever transitions to `false` from `_finish_recorruption()` — checked
every assignment site in the file — so the `else` branch is exactly the recorruption case, no extra
guard needed). The setter now fires `wellspring_recorrupted` identically whether this process just set
`capped = false` itself (the host, via `_finish_recorruption()`) or received it over the wire (a
client, via `_sync`) — `capped` is one of the seven properties `_build_synchronizer()` replicates, so
both paths run this same setter.

**Consequence this closes:** `docs/ARCHITECTURE.md`'s Wellspring row already flagged "no live
undercount yet, since nothing subscribes to it" — still true today (`event_bus.gd` calls it a seam for
a future system, same role D-092 gives `wellspring_capped`), so this fix has no behavior change to
verify beyond the event itself; it exists so the FIRST future subscriber (a Salvage milestone bonus,
an ambient audio cue, `MireGrid`'s own count — the seam already has three candidate consumers named in
comments) doesn't inherit a silent per-peer undercount the way F-168's `wellspring_capped` did before
its own fix.

**Verify:** `agent godot --script tools/wellspring_check.gd` — added
`_check_recorrupted_event_via_replication()`, the exact symmetric proof
`_check_capped_event_via_replication()` already gave F-168: a bare `capped = false` write with no
clock and no `host_tick()` in the call stack, the shape a client's synchronizer delta takes, fires the
event exactly once and names the right Wellspring; re-setting to the same value does not re-fire it.
Also re-ran `tools/wellspring_recorruption_check.gd` (unaffected — still `failures=0`, confirms the
host-side ritual/clock/visual-state behavior is unchanged) and a full headless boot
(`agent godot --quit-after 60`, clean).

**Verified 2026-08-18 (lm):** `WELLSPRING_CHECK failures=0` (new F-181 section passes),
`WELLSPRING_RECORRUPTION_CHECK failures=0`, full boot clean.

---

## F-182 · `tools/unlock_check.gd`'s corrupt-save test provokes two engine ERROR lines with no `EXPECTED_ERROR_PATTERNS` declaration

**Claim:** `tools/unlock_check.gd`, `docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause:** `_check_save_versioning()` deliberately writes `"{not valid json"` to
`TEST_CORRUPT_PATH` and calls `UNLOCK_SAVE.load_data()` on it, to prove the safe-default fallback
(`purchased_ids == []`) rather than a crash. That fallback path is real production code
(`core/save/unlock_save.gd:35-37`) and logs two engine lines on the way there: the engine's own
`ERROR: Parse JSON failed. Error at line 0: Expected key` from `JSON.parse_string()`, then
`unlock_save.gd`'s own `push_error("UnlockSave: %s did not contain a JSON object, starting fresh")`.
Standing rule 4 (this file, preamble) requires either line to be declared by pattern in the check's
verdict line; `finish()`'s print at `tools/unlock_check.gd:97` (pre-fix) had none, unlike
`tools/chest_check.gd`'s own provoked-error case (`references unknown loot tier` →
`EXPECTED_ERROR_PATTERNS`). `failures` itself was never miscounted — `check()` only increments on a
failed assertion, never on a `push_error` — so this was a paperwork gap in the grep-graded verdict
line, not a correctness bug hiding a real failure.

**Fix:** added `· EXPECTED_ERROR_PATTERNS="Parse JSON failed|did not contain a JSON object"` to the
`finish()` print at `tools/unlock_check.gd:94-98` (formerly line 97), same shape
`tools/chest_check.gd:150` already uses, with a comment naming why the two lines are expected instead
of silenced.

**Verify:** `agent godot --script tools/unlock_check.gd`, grep for `ERROR:` and exclude the declared
patterns — must be zero: `grep 'ERROR:' <log> | grep -vE 'Parse JSON failed|did not contain a JSON
object' | wc -l`.

**Verified 2026-08-19 (lm):** `UNLOCK_CHECK failures=0` both runs; both engine `ERROR:` lines present
each run (`Parse JSON failed`, `did not contain a JSON object`) and both match the declared pattern;
undeclared-`ERROR:` count is `0` both runs.

---

## F-190 · HEAD registers the RewardService autoload but does not contain its script, so a clean checkout fails to boot

**Claim:** `docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Already fixed by the time this task read the finding — the brief's own staleness warning was
right.** F-183 (`agent ship`, commit `c860a3f`) committed `autoload/reward_service.gd` itself; the
`project.godot` registration line landed in a separate, earlier commit (`bdb8562`, an unrelated
"Doors that open" ship whose commit swept up the `agent autoload`-appended line — the exact race the
finding names, not a new bug). Both are ancestors of the current `main` tip, so at HEAD the two acts
are reconciled: the registration and the script it points at are both tracked. This task's job was to
verify that rather than assume it, then close the finding.

**Verify:** `git ls-files autoload/reward_service.gd` → tracked. `grep RewardService project.godot` →
`RewardService="*res://autoload/reward_service.gd"` present. `.agent/bin/agent godot --script
tools/reward_service_check.gd` → `REWARD_SERVICE_CHECK failures=0` (all 9 assertions pass, run
against the real `content/loot/wellspring.tres`/`boss.tres` content). `.agent/bin/agent godot
--quit-after 60` → clean boot, zero `ERROR:` lines — the exact failure the finding reproduces
(`Failed to instantiate an autoload, can't load from path: ...`) does not occur.

**Sweep for the same shape elsewhere:** every `res://` path named in every `[autoload]` line of
`project.godot` (52 entries) is tracked at HEAD (`git ls-files --error-unmatch` on each, zero
misses) — F-190's specific failure has no other live instance right now.

**What is NOT fixed, and stays open as F-200:** the finding proposed two mechanisms that would catch
a *future* instance of this same race — a check that every autoload/preload target is tracked at
HEAD, and `agent check` judging the git INDEX instead of the working tree when `project.godot` is
part of a commit. Neither exists yet; building them is out of this task's scope (verifying and
closing an already-self-resolved bug) and is filed separately so the prevention work isn't lost.

---

## F-200 · No check verifies that `project.godot`'s `[autoload]` targets are tracked at HEAD, so F-190's failure mode can recur

**Claim:** `tools/autoload_tracked_check.py`, `docs/FINDINGS.md`, `docs/SPECS.md`,
`docs/DELEGATION.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble. Its brief carried a staleness warning (`autoload/graphics_quality.gd` had a commit since
filing) — checked first per that warning: the commit was F-154's unrelated hook wiring, nothing
touching the autoload/preload shape this finding is about, so the finding was still live and the
work was still to build.

**Built mechanism #1 of the finding's own two proposals** (not #2 — see below): a standalone,
Godot-free check, `tools/autoload_tracked_check.py`. For a given revision (`--rev`, default `HEAD`)
it reads `project.godot`'s `[autoload]` block, verifies every `res://` target resolves to a git blob
tracked **at that revision** (`git cat-file -e <rev>:<path>`, never a working-tree/`os.path.exists`
check — the whole point, since F-190 and F-144 both self-resolved on a dirty tree that looked fine
locally), then recurses into every static `preload("res://...")` string literal reachable from a
tracked `.gd` file, transitively, checked the same way — closing F-144's variant of the bug, where
the AUTOLOAD's own script was tracked but something *it* preloaded was not.

**Verify:**
- `python3 tools/autoload_tracked_check.py` (HEAD) →
  `AUTOLOAD_TRACKED_CHECK rev=HEAD autoloads=58 paths_checked=111` / `failures=0`.
- `python3 tools/autoload_tracked_check.py --self-test` → `3/3 passed`, in a throwaway git repo it
  builds and discards itself: a clean tree (must pass), F-190's exact shape — an autoload target
  itself never committed (must fail, and does), and F-144's exact shape — the autoload script
  tracked but its `preload()` target not (must fail, and does, naming the transitive path). This is
  what proves the check catches the failure rather than merely running without crashing.
- `.agent/bin/agent godot --quit-after 120` → clean boot, zero `ERROR:` lines — the finding's own
  reproduction (`Failed to instantiate an autoload, can't load from path: ...`) does not occur.
- `.agent/bin/agent godot --script tools/findings_numbering_check.gd` →
  `FINDINGS_NUMBERING_CHECK open=22 resolved=186 failures=0` after moving F-200 to `## Resolved`
  and filing F-205 under `## Open` — no heading damage (F-134's trap).

**Sweep for the same shape elsewhere:** the check itself IS the sweep — it walks all 58 live
`[autoload]` entries and every path transitively reachable from one (111 total), not just the two
historical incidents (`reward_service.gd`, `graphics_quality.gd`/`draw_policy.gd`). Zero misses at
current HEAD.

**What is NOT built, and stays open as F-205:** the finding's mechanism #2 — `agent check` (the
pre-commit hook) refusing a commit outright when it would register or carry an untracked autoload
target, judging the STAGED/INDEX view rather than catching it after the fact. That needs editing the
shared `.agent/bin/agent` harness, a separate and larger claim than this task's scope; filed
separately with the exact reuse path (this file's regex/BFS) so the prevention work isn't lost twice.

---

## F-183 · Wellspring caps and boss kills never grant a Chest — `wellspring`/`boss` tier loot tables are authored and reachable, but nothing ever rolls them

**Claim:** `autoload/reward_service.gd`, `tools/reward_service_check.gd`, `core/util/mire_log.gd`,
`project.godot` (autoload registration only, via `agent autoload`), `docs/FINDINGS.md`,
`docs/DECISIONS.md`, `docs/DELEGATION.md`, `docs/SPECS.md`, `docs/ARCHITECTURE.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause:** F-146 gave every WORLD-PLACED chest tier a real owner (`ChestPlacementService`), but
`wellspring` and `boss` (`docs/ITEMS.md` §5) were never meant to sit in the world at all — a
Wellspring cap and a boss kill are events, not positions. Neither `Wellspring._finish_cap()` (only
ever flips `capped`) nor `Boss._play_state_animation()` (only ever flips `state`) ever called
`LootTableDef.roll()` against either table. Both tables pass `tools/loot_content_check.gd`'s
id-resolution sweep — the content was never the gap, same shape F-146 itself was before its own fix,
just for an event trigger instead of a placement marker.

**Two design calls the finding itself left open, both decided here — see D-123:**
1. **Direct grant, not a spawned `Chest`.** A world-placed chest's NodePath is safe across peers
   because `ChestPlacementService` builds it deterministically, identically, from boot-time content
   (the map layout) — nothing about WHEN a marker's `node_added` signal fires changes what gets
   built. A Wellspring-cap/boss-kill trigger has no such guarantee: it fires at a moment that
   depends on real-time gameplay and network latency, not shared boot-time content, so a
   dynamically-instanced `Chest` at that moment has no established way to land at a matching
   NodePath on every peer — this codebase's only two node-creation patterns that *do* guarantee
   that are `MultiplayerSpawner` (enemies/players) and `ChestPlacementService`'s own boot-deterministic
   bridge, and an event-timed trigger fits neither. A direct grant through the already-networked
   `InventoryService.host_add()`/`PowerupService.host_grant()` seam (each already reaches a remote
   peer through its own snapshot RPC) needs no new node and no new RPC at all.
2. **One independent roll per present player, not one shared roll.** A world chest is already
   "whoever gets there first loots it, nobody else does" — granting every present player their OWN
   independent roll is the closer analogue (nobody is shut out because a teammate happened to be the
   one who capped/landed the kill), and matches ITEMS.md's "the objective's paycheck" framing better
   than a single split reward would.

**Fix:** `autoload/reward_service.gd` (new autoload, registered last via `agent autoload
RewardService res://autoload/reward_service.gd`). Subscribes to
`EventBus.subscribe_wellspring_capped()`/`subscribe_boss_defeated()` — both already fire identically
on every peer, straight from a replicated property's own setter (the D-107/D-108/F-168/F-181
pattern), so no new RPC is needed to reach every peer's own copy of this autoload. HOST-only
(`_owns_mutation()`, copied verbatim from `Wellspring`/`Chest`'s own boilerplate): resolves the
trigger's tier through `Registry.get_loot_table()`, then for every currently-present player
(`_present_peers()`, the same "distinct multiplayer authority in the `players` group" helper
`DefeatService` already uses) rolls that table once with a fresh `RandomNumberGenerator` (never
`randi()`) and the same D-111/F-173 unlock-gating `Callable` `Chest._unlock_check()` already builds,
then grants coins/items through `InventoryService.host_add()` and powerups through
`PowerupService.host_grant()` — the identical three-bucket dispatch `Chest._accept_open_request()`
already uses. `core/util/mire_log.gd` gained a `&"reward"` channel so the per-grant log line is
toggleable like every other system's.

**Not attempted here:** no `Chest` node, no visible in-world prop at the Wellspring/boss arena — see
call 1 above. A future task revisiting DESIGN.md's "teammates see a jackpot" social framing (already
served indirectly here: `PowerupService.host_grant()`'s existing `net_powerup_counts` broadcast
already tells every teammate when someone's stack count changes) should re-read D-123 before
assuming a spawned-`Chest` version is a small follow-up — the NodePath-sync problem call 1 names is
real engineering, not a stylistic choice.

**Verify:** `agent godot --script tools/reward_service_check.gd` — proves, against the REAL
`content/loot/wellspring.tres`/`boss.tres` content (no synthetic table, same choice
`tools/chest_placement_check.gd` made for Hollowmere's real chest tiers): wiring (RewardService
registered and actually subscribed to both hooks), a real Wellspring's `capped` transitioning true
(a bare property write — the F-168 replication shape) grants the present player wellspring.tres's
coin range plus at least one of its all-POWERUP rolls, `EventBus.emit_boss_defeated()` does the
same against boss.tres's mixed item/powerup table, and `_present_peers()` returns every distinct
authority in the `players` group (not just the first one) — a live multi-peer INVENTORY grant needs
a real connected transport (`chest_net_check.gd`'s own two-process pattern), already-proven plumbing
this file does not re-test.

**Verified 2026-08-19 (lm):** `agent godot --script tools/reward_service_check.gd` →
`REWARD_SERVICE_CHECK failures=0`, run three times (non-seeded `randomize()` rolls). `agent godot
--quit-after 60` → clean boot, no new `ERROR:` lines, `RewardService` present in `project.godot`'s
`[autoload]`. No regressions: `tools/chest_check.gd`, `tools/chest_placement_check.gd`,
`tools/wellspring_check.gd`, `tools/boss_check.gd`, `tools/unlock_check.gd`,
`tools/loot_content_check.gd` all still `failures=0`.

---

## F-184 · `tools/audio/audio_check.py`'s exit code is inverted — it exits 0 when checks FAIL and 1 when they PASS

**Claim:** `tools/audio/audio_check.py`, `docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause:** F-176 wrote `tools/audio/repro_check.py` alongside this finding and copy-paste
started it from `audio_check.py`'s own `main()`. `audio_check.py:122` was `sys.exit(0 if failures
else 1)` — Python's conditional expression evaluates the truthy branch first, so this exits `0`
(success, by every shell/CI convention) exactly when `failures` is nonzero, and `1` (failure) exactly
when `failures == 0`, backwards from every other check script in the repo (`*_check.gd`,
`repro_check.py`, and every `tools/blender/*_check.py`, all of which already use the correct `1 if
failures else 0` shape). F-176's own fix caught and corrected the copy, leaving only the original
`audio_check.py` site broken.

**Fix:** one line — `sys.exit(1 if failures else 0)`.

**Sweep (per the F-185 close-out requirement):** `grep -rn "sys.exit(0 if\|sys.exit(1 if" --include="*.py" .`
across the whole repo found five `sys.exit(N if failures else M)` sites total — this one, plus
`repro_check.py` and all three `tools/blender/*_check.py` scripts — and only this one was inverted.
No sibling bug found.

**Verify:** run `tools/audio/audio_check.py` and confirm the printed `PASS`/`FAIL` lines agree with
the process exit code in both directions — a real PASS run must exit `0`, and a forced FAIL (no SFX
files present) must exit `1`.

**Verified 2026-08-18 (lm):** `python3 tools/audio/audio_check.py` → all 19 SFX files `PASS`,
`AUDIO_CHECK failures=0`, exit `0`. Copied the script into a throwaway repo layout with an empty
`assets/audio/sfx/` to force `FAIL: found 0 sfx wavs` → `AUDIO_CHECK failures=1`, exit `1`. Both
directions now agree with the printed result, where before the fix a real PASS run exited `1`.

---

## F-057 · A-003's deterministic-rebuild claim is false: two crafting-station GLBs differ byte-wise across identical rebuilds

**Claim:** `tools/blender/build_crafting_stations.py`, `tools/blender/crafting_stations_repro_check.py`,
`assets/crafting_stations` (catalog, exports, previews), `assets/source/crafting_stations.blend`,
`docs/ASSET_TRACKER.md`, `docs/FINDINGS.md`, `docs/SPECS.md`, `docs/DECISIONS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause, confirmed rather than assumed.** The finding's own hypothesis — Blender's bevel
modifier changing a few float bytes between otherwise identical background exports on Apple Silicon,
the mechanism `build_ward_set.py` first found — was real but unverified for this kit specifically. A
baseline rebuild of the pre-fix script (`agent baseline`-style: two separate, real `Blender
--background --python build_crafting_stations.py` process invocations, exactly how the script's own
docstring says to run it) reproduced it directly: `station_stone_furnace.glb` differed byte-for-byte
across two clean rebuilds on this machine, `catalog.json` staying identical both times (dimensions
round to the same value; only the bevel geometry's raw floats drift). It does not reproduce on every
run — three earlier rebuilds in this session came back byte-identical before one caught it — matching
the finding's own "four float bytes" characterization of how small and how intermittent the drift is.

Separately, and probably the bigger reason A-003's tracker row read as passing: the GLBs actually
checked in at `HEAD` did not match a clean rebuild of the current script *at all* — different
dimensions, a duplicate `MIRE_Ember`/`MIRE_Ember.001` material pair, a fully different polygon count.
`git log --follow` on `station_campfire.glb` shows its last real change landed in `14ead00`, "Art:
tools/weapons migrated; palette re-anchored to measured base colours" — a commit about a different
asset family entirely, whose message never mentions crafting stations. This is the F-149/F-191 class
of bug (a concurrent agent's commit sweeping up another lane's dirty files) reaching **generated
asset files**, not just `docs/`, which is a new instance of that pattern — filed separately as F-197
rather than folded in here, since fixing *this* finding does not fix the mechanism that produced it.

**Fix:** `build_crafting_stations.py` now overrides `mire_art.box()` with a bevel-free version, the
same pattern `build_ward_set.py`, `build_construction_set.py`, `build_flora_set.py` and
`build_extraction_ship_set.py` already carry for exactly this reason — all four already cite F-057 in
their own comments while this kit, the family that *found* the bug, had never applied its own fix.
`bevel` stays an accepted-and-ignored parameter so the 23 existing call sites read unchanged. Cost:
2,731 → 1,651 total polygons (a bevel's one-segment modifier roughly doubles a box's face count) and
slightly squared-off chamfers on drawer fronts, the furnace mouth and the vise — visually confirmed
against both preview renders, still reads correctly at the kit's scale. Then rebuilt clean and
committed the correct exports/catalog/previews/`.blend` source, closing the F-195 staleness gap at
the same time.

**Verify:** new `tools/blender/crafting_stations_repro_check.py` — a plain-Python driver (no `bpy`
needed) that shells out to two separate `Blender --background --python build_crafting_stations.py`
processes, exactly the real invocation, and diffs every `exports/*.glb` plus `catalog.json` byte-for-
byte between them. Deliberately does NOT call `build_crafting_stations.main()` twice inside one
Blender process — that leaves the first run's mesh datablocks alive in `bpy.data` (Blender purges
orphans on file reload, not on `object.delete()`), so the second in-process call collides with
leftover names like `Leg_1_1_Mesh` and gets auto-suffixed `.001`, a real effect but one the actual
pipeline never hits because it always launches a fresh process per rebuild. An earlier draft of this
check made exactly that mistake and reported all 8 GLBs failing; the two-process version is what
actually matches the contract being verified.

**Verified 2026-08-19 (lm):** `python3 tools/blender/crafting_stations_repro_check.py` →
`CRAFTING_STATIONS_REPRO_CHECK PASS`, all 8 GLBs plus `catalog.json` byte-identical across two
real rebuilds, run twice more directly (six total rebuilds, all pairwise identical). Reproduced the
pre-fix bug directly first: with the bevel-free override reverted (`git stash push -- <path>`, scoped
to this one file), the same check failed — `station_stone_furnace.glb` differed across two rebuilds,
everything else and the catalog matched — then restored the fix and re-confirmed `PASS`. Both preview
renders visually inspected post-fix: all eight stations still read correctly with the slightly harder
edges.

Also ran a fresh Godot import — these GLBs are loaded by name (`content/stations/*.tres`'s
`world_scene`, matched against `world/gen/authored_world.gd`'s Hollowmere markers), not just sitting
unreferenced, so this is a real downstream consumer. First attempt hit **F-196** directly: repeated
Blender rebuilds interleaved with `agent godot` checks during this session's own testing left all 8
`.glb.import` files at `valid=false` (no `path=` line, so nothing to load), and the running game
threw 16 `Failed loading resource`/`MeshMerge could not load` errors for `authored_world.gd`'s prop
pass. A single explicit `agent godot --import` after deleting the stale `.import` files and their
`.godot/imported/` cache entries cleared it, exactly F-196's own documented remedy. Re-ran `agent
godot --quit-after 30`: zero `ERROR` lines, `AUTHORED_WORLD id=hollowmere ... props=2880` (up from
2869 before the fix — the crafting stations now actually load into the prop pass instead of silently
no-opping), clean boot.

---

## F-158 · `bog_crawler` (task 4.11's corrupted spawn-table variant) is visually identical to a normal crawler

**Claim:** `content/enemies/bog_crawler.tres`, `systems/enemies/enemy_def.gd`, `systems/enemies/enemy.gd`,
`tools/bog_crawler_check.gd`, `tools/wave_director_check.gd`, `tools/mire_interaction_check.gd`,
`tools/enemy_lod_check.gd`, `docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause:** task 4.11 wired corrupted-ground spawns to substitute `bog_crawler` for `crawler`
(`systems/waves/wave_spawner.gd::_corrupted_enemy_id_for()`), but `bog_crawler.tres` reuses
`enemy_crawler.glb` with no material change, no VFX, and `EnemyDef` had no field to carry one. The
substitution is mechanically real (tankier/slower/harder-hitting) but invisible: a player sees the
exact same model. Task 4.10 (Mire visuals — shader tint, fog, particles) is the natural long-term
owner, but hasn't shipped, and this task's own scope doesn't require waiting for it — a stat-only
variant needing *some* visual marker is a general shape, not specific to 4.10's atmosphere work.

**Fix — a general per-`EnemyDef` cosmetic tint, not a `bog_crawler`-specific hack:**

1. `systems/enemies/enemy_def.gd` gains `visual_tint: Color`, defaulting to `Color(1,1,1,1)` — a
   true no-op, so every other authored `EnemyDef` (currently just `crawler`) renders bit-for-bit
   unchanged. Cosmetic only, no replication needed: every peer loads the same `.tres` and computes
   the same tint from it (ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row).
2. `systems/enemies/enemy.gd::_build_visual()` calls a new `_apply_visual_tint()` after collecting
   `_overlay_meshes`. It walks every `MeshInstance3D`'s surfaces, duplicates the *active* material
   (so the original imported GLB material — shared across every instance of that model — is never
   mutated), multiplies its `albedo_color` by `definition.visual_tint`, and sets it as a
   `surface_override_material`. Skipped entirely when the tint is the default identity, so untinted
   enemies (every one but `bog_crawler` today) never pay for a material duplicate. Deliberately a
   separate mechanism from the existing hit-flash/dissolve `material_overlay` (2.9) — that slot is a
   transient additive layer already reused for two different effects on the same field; a permanent
   base tint sharing it would be clobbered the next time either effect ran.
3. `content/enemies/bog_crawler.tres` sets `visual_tint = Color(0.38, 0.5, 0.34, 1)` — a murky,
   desaturated green that reads as diseased/bog-corrupted at a glance, still recognizably the same
   crawler silhouette and animation. No new art authored (D-073 — content is hand-authored, this
   task is mechanics-adjacent VFX, not a new model).

**New focused check, `tools/bog_crawler_check.gd`** (none existed): spawns one `crawler` and one
`bog_crawler` through the real `EnemyWorld.host_spawn()`, and asserts at the material level, not just
that the field round-trips — `crawler` carries no surface override at all (`_apply_visual_tint()` is
a true no-op for it), `bog_crawler` carries a tinted one on every surface, the tint equals the
original albedo times `visual_tint` exactly, and both still reference the same `model` resource (no
new art).

**Trap found while verifying — three existing checks provoke new engine noise:** `set_surface_
override_material()` with a duplicated material triggers the headless dummy renderer's own
`ERROR: Parameter "material" is null.` (`material_get_instance_shader_parameters`) — harmless CPU-side
noise with no GPU backend to query, confirmed absent under `--windowed` (real Forward+ backend) with
byte-identical assertion results either way. Standing rule 4 (this file's preamble) treats any
undeclared `ERROR:` line as a failure regardless of exit code, so every check that spawns a real
`bog_crawler` needed its verdict line to declare the pattern: `tools/wave_director_check.gd` (samples
30 corrupted spawns, deterministically reproduces it), `tools/mire_interaction_check.gd` (spawns
`bog_crawler` at full corruption — the roll makes it flaky per-run, so declared unconditionally rather
than relying on a specific run producing it), and `tools/enemy_lod_check.gd` (walks every authored def
including `bog_crawler` — observed intermittently, declared defensively for the same reason). None of
the three needed a logic change; each only gained `EXPECTED_ERROR_PATTERNS="Parameter \"material\" is
null"` on its own `finish()` print, the same shape `tools/chest_check.gd` already established.

**Sibling sweep:** `bog_crawler` is currently the only `EnemyDef` that reuses another kind's `model`
with stats-only differentiation — `crawler.tres` is the only other authored def, and no `BossDef`
`.tres` exists yet (task 5.2's 8-12 enemy types and any boss content haven't shipped). Nothing else to
fix under this class today.

**Verify:** `agent godot --script tools/bog_crawler_check.gd`, plus the three re-verified siblings —
`agent godot --script tools/wave_director_check.gd`, `tools/mire_interaction_check.gd`,
`tools/enemy_lod_check.gd` — each graded by `grep 'ERROR:' <log> | grep -vE 'Parameter "material" is
null' | wc -l`, must be zero.

**Verified 2026-08-19 (lm):** `BOG_CRAWLER_CHECK failures=0` under both `--headless` and `--windowed`;
zero ERROR lines at all under `--windowed`; zero *undeclared* ERROR lines under plain `--headless`
(engine noise present, matches the declared pattern). `wave_director_check.gd`,
`mire_interaction_check.gd`, `enemy_lod_check.gd` all re-run three times each after their declaration
fix: `failures=0` and zero undeclared ERROR lines on every run. Full boot clean:
`agent godot --quit-after 120` — no ERROR lines, only the pre-existing benign navmesh-precision
WARNINGs from `enemy_world.gd::bake_navigation()`.

---

## F-170 · `tools/lobby_menu_check.gd` fails (5/24) whenever the dev machine's own Steam client is actually running

**Claim:** `tools/lobby_menu_check.gd`, `docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause, confirmed by running the check on this machine with Steam actually running and
logged in:** the check's SAD-path assertions paste a fake lobby id (`109775242382594016`) and call
`request_join()`/`request_host()` expecting `SteamLobby` to refuse before touching the network. That
assumption only holds when Steam is unreachable. When it is reachable, `join_by_id()` sets
`SteamLobby._lobby_id` to the fake id *immediately* — before Steam's async callback ever answers —
so `in_lobby()` goes true right away and the state machine sits in `JOINING`. The next call,
`request_host()`, is then rejected with `"already joining a lobby"` instead of a Steam-unavailable
reason, and every assertion after that cascades off the same stuck state (`copy with no lobby` also
fails, since a lobby id is technically set). All 5 observed failures trace to this one state
corruption, not five independent bugs.

**Fix, the finding's second proposed shape (skip rather than mock):** before the SAD-path
assertions, the check now calls `SteamLobby.initialise()` itself and reads `is_ready()` — the same
call `request_join()`/`request_host()` would make anyway, so probing it early changes nothing on a
Steam-less machine (idempotent — "safe to call repeatedly"). If Steam answers, the check never fires
the fake-id join/host at all (that would start a REAL async request against Steam's servers, which
is worse than untestable — `request_host()` would create an actual friends-only lobby); it prints
which branch it took and calls a new `skip(description)` helper for the four Steam-dependent
assertions instead of `check()`, so they show as `SKIP:` and do not count toward `failures`. Every
other assertion (menu open/close, D-032 stacking, the two Steam-independent join/copy refusals) is
unchanged and still runs and counts in both branches.

**Sibling sweep (this task's own scan):** every other `tools/*_check.gd` referencing Steam —
`steam_lobby_check.gd`, `steam_check.gd`, `rich_presence_check.gd`, `connect_retry_check.gd`,
`display_name_check.gd` — already either requires Steam by design and documents that requirement in
its header (`steam_lobby_check.gd`: "Requires the Steam client running and signed in"), or already
branches gracefully on Steam's absence/presence (`steam_check.gd` prints a note rather than asserting
success when the client isn't running; `rich_presence_check.gd` prints `skip` and returns when the
`Steam` singleton is absent). None of them fire a real mutating Steam request while assuming Steam is
unreachable — `lobby_menu_check.gd` was the only one making that specific mistake.

**Verify:** `.agent/bin/agent godot --script tools/lobby_menu_check.gd`, run twice on this machine —
once with the real Steam client running (`ps aux | grep steam_osx` confirmed it live) and once with
it quit. Both runs: `LOBBY_MENU_CHECK failures=0`. With Steam running: the four Steam-dependent
assertions print `SKIP:` and the branch line reads `STEAM AVAILABLE on this machine — skipping...`.
With Steam absent: all 24 assertions run and pass, branch line reads `STEAM UNAVAILABLE on this
machine — running...` — byte-identical assertion behaviour to the pre-fix code path (the `else`
branch is untouched, just newly conditional). Steam was relaunched (`open -a Steam`) immediately
after the Steam-absent run to restore the machine to its prior state.

**Verified 2026-08-19 (lm):** both runs above, `failures=0` each. `.agent/bin/agent godot --script
tools/steam_lobby_check.gd` also run per this task's own work order (step 2) — see `docs/FINDINGS.md`
for its result, since a pre-existing failure there is unrelated to this finding's fix and is filed
separately rather than silently folded into this close-out.

---

## F-187 · Props are 1,057 MultiMesh groups averaging 2.7 copies — F-100's cross-asset chunk merge is still not built

**Claim:** `world/gen/authored_world.gd`, `core/render/mesh_merge.gd`, `tools/prop_chunk_merge_check.gd`,
`docs/FINDINGS.md`, `docs/SPECS.md`, `docs/DELEGATION.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause:** `AuthoredWorld._build_props()` grouped every prop by `(chunk, kit, asset)` — one
`MultiMeshInstance3D` per group — so a chunk holding six DIFFERENT rock/log/ruin assets built six
draw calls even though every one of them was static, unanimated scenery that could have shared one.
F-100 designed a real fix and F-144 filed it forward as F-187 with three specific constraints a
naive "coarsen the grouping key" attempt would miss (see the original finding text, still in
`## Resolved` history): batch-harvestables' depletion hook, `EnvironmentVfx`'s per-asset sway/emitter
contracts, and `visibility_range`'s node-origin distance measurement.

**Fix — merge only the props none of those three contracts touch, one static mesh per chunk:**

1. `core/render/mesh_merge.gd` gains `merge_instances(entries: Array) -> ArrayMesh`, additive next to
   the existing `merged()`/`_build()` (untouched, still what F-152's pinned invariant check exercises).
   Same bucket-by-(material-appearance, vertex-attribute-mask) algorithm as `_build`, but for a caller
   that already has meshes in hand (not a `.glb` to walk) and a full placement `Transform3D` per entry
   (not a fixed offset within one asset's own hierarchy) — vertices are baked with `transform * v`,
   normals with `basis * n`. Never disk-cached: the caller decides how entries are grouped, so there is
   no single source-file mtime to key a cache entry against, and rebuilding from already-merged,
   already-indexed meshes is cheap regardless.

2. `AuthoredWorld._build_props()` classifies each prop while it groups them (not after): a prop is
   `mergeable` — folded into one `merge_instances()` call per chunk — only when it is simultaneously
   **not harvestable** (BATCH depletion hides one instance by zeroing its transform inside that asset's
   OWN `MultiMesh`; NODE harvestables were already excluded upstream), **carries no `AssetVfxLibrary`
   emitter** (`EnvironmentVfx._register_emitter` keys `PLACEMENTS_META` off one asset id per holder — a
   merged node spanning several assets would misattribute or drop their sites), **carries no sway**
   (`_apply_sway` dresses a mesh once with ONE profile for every surface, and the wind shader's height
   mask reads `VERTEX.y` in MODEL space against that mesh's own AABB — correct for one asset's local
   frame, wrong once several placements' absolute heights are baked into one static mesh), **and** its
   own mesh AABB height (scaled) is below `DrawPolicy.SHADOW_MIN_HEIGHT` (1.2 m) — see the shadow trap
   below for why. Everything else keeps the original per-(chunk, kit, asset) `MultiMesh` path,
   byte-for-byte unchanged. The merged holder is centroid-rebased exactly like the existing grouped
   holders (`visibility_range` measures from the node's own origin, and a real `ArrayMesh`'s AABB is
   exact once its vertices are relative to that origin), and carries no `asset` meta at all — deliberate,
   since it spans many assets by construction and `EnvironmentVfx._asset_id_for`'s meta-then-name walk
   correctly finds nothing and skips it.

**Trap found while verifying — coarsening the grouping key without fixing draw distance made frame
cost WORSE, not better:** the first version merged every rigid/non-emitting/non-sway prop regardless of
height, sized with `DrawPolicy.apply(instance, combined.get_aabb(), 1.0)` — the MERGED mesh's own AABB,
whose vertical span reflects the chunk's terrain relief (routinely several metres on Hollowmere) as much
as any object's actual height. That misclassified nearly every merge as TALL (`DrawPolicy.
TALL_MIN_HEIGHT` = 4 m ⇒ 260 m draw distance) regardless of what was actually in it, and a still-large
merged AABB that DOES cast a shadow routinely spans more than one of the four PSSM cascade splits, so
Godot re-renders its whole primitive count into every cascade it touches. Measured with
`tools/frame_cost_check.gd` against `agent baseline`: draw calls fell as expected (867 → 645 authored-
world visual nodes) but shadow-pass PRIMITIVES ROSE 16% (1,143,574 → 1,356,306) — draw-call counting
alone would have shipped a regression. Fixed two ways: (a) `DrawPolicy.apply` is now given a synthetic
AABB built from the MAX of each individual object's own scaled height, not the merged mesh's own AABB;
(b) the eligibility rule additionally requires that per-object height stay under `SHADOW_MIN_HEIGHT`, so
every merged node's `cast_shadow` reads OFF by construction and the cascade-crossing question never
arises. The remaining sway/emitter cases are real further work, not solved here — filed as F-203 with
the exact mechanism each one would need (height-encoded vertex channel for sway; per-asset placement
sub-ranges for emitters).

**New check, `tools/prop_chunk_merge_check.gd`** (none existed): boots Hollowmere and (1) walks every
`PropVisuals/merged_*` holder, asserting it carries exactly one `MergedProps` `MeshInstance3D` with real
geometry, a draw distance, and — the load-bearing invariant from the trap above — `cast_shadow ==
SHADOW_CASTING_SETTING_OFF`; (2) independently recomputes eligibility straight from the layout file and
the same three libraries `_build_props` classifies against (`HarvestLibrary`, `AssetVfxLibrary`,
`DrawPolicy`, `MeshMerge`), and asserts the number of distinct eligible chunks matches the number of
`merged_*` holders actually built — a drift between the two classifications (an eligibility rule edited
in one place and not the other) fails loudly instead of silently merging, or failing to merge, the wrong
props.

**Sibling sweep:** grepped every `DrawPolicy.apply` call site (`world/gen/authored_world.gd` twice more,
`systems/harvesting/harvestable.gd` once) for the same shape — an aggregate AABB standing in for a
single object's height. The other three all pass a single asset's or a single harvestable instance's own
`mesh.get_aabb()`, never a cross-placement bake, so none share the bug; this merge is the first code in
the repo that bakes more than one placement into one mesh, so there was no pre-existing sibling to find.

**Verify:** `.agent/bin/agent godot --script tools/hollowmere_check.gd`,
`tools/mesh_merge_check.gd`, `tools/environment_vfx_hollowmere_check.gd`, `tools/harvest_batch_check.gd`,
`tools/harvest_world_check.gd`, `tools/resource_scatter_check.gd`, `tools/prop_chunk_merge_check.gd`
(new); measure with `agent godot --windowed --script tools/frame_cost_check.gd` against `agent baseline
--windowed --script tools/frame_cost_check.gd`.

**Verified 2026-08-19 (lm):** every check above `PASS`/`failures=0`. `AUTHORED_WORLD` at HEAD:
`multimeshes=867` → `multimeshes=761 merged_meshes=25` (786 total visual nodes, −9.3%).
`prop_chunk_merge_check.gd`: `eligible_props=218 eligible_chunks=25`, matching the 25 `merged_*` holders
built — zero drift. `frame_cost_check.gd` "as shipped": draw calls 4,943 → 4,943 (unchanged — the
eligible subset's material diversity roughly cancels the node-count win on Hollowmere specifically),
primitives 1,143,574 → 1,158,264 (+1.3%, not the +16% the unfixed version measured), vram 242.9 MB →
247.2 MB. A real, verified, conservatively-scoped fix — not the full draw-call win F-100 originally
modelled, because that win lives in the sway/emitter cases F-203 now owns.

---

## F-203 · AuthoredWorld's F-187 chunk merge excludes sway- and emitter-bearing props — a second attempt needs per-vertex height encoding or per-asset placement metadata inside a merged mesh

**Claim:** `world/gen/authored_world.gd`, `autoload/environment_vfx.gd`,
`tools/prop_chunk_merge_check.gd`, `tools/environment_vfx_hollowmere_check.gd`, `docs/FINDINGS.md`,
`docs/SPECS.md`, `docs/DELEGATION.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Scope decided here: emitters, not sway.** F-203's own title names two mechanisms, one per case.
The emitter case (per-asset/per-class placement metadata) is the one this task builds; the sway
case (per-vertex height encoding) needs a shader change this task does not attempt, and is spun out
to **F-208** with the exact remaining work rather than left silently unfinished inside a "closed"
finding.

**Fix — a second merge bucket, keyed by class instead of by nothing:**

1. `AuthoredWorld._build_props()` classifies each non-harvestable, non-sway, sub-`SHADOW_MIN_HEIGHT`
   prop a third way: `AssetVfx.emitter_for(asset) == NONE` still goes to the existing
   asset-agnostic `mergeable` bucket (keyed `"<chunk_x>_<chunk_z>"`); an emitter class other than
   `GLOW` goes to a new `emitter_mergeable` bucket keyed `"<chunk_x>_<chunk_z>|e<emitter_int>"`
   instead — every instance feeding one merged mesh this way already agrees on which class to
   register as, so the merge itself resolves the ambiguity F-187 couldn't. `GLOW` stays in the
   plain bucket: `AssetVfxLibrary.Emitter.GLOW` is documented "emissive material only — no light,
   no particles, no per-instance node", and nothing in `EnvironmentVfx` reads a class or a position
   for it, so it needs none of the new bookkeeping.
2. `emitter_mergeable`'s keys fold into `mergeable` before the build loop runs, so one loop handles
   both buckets — the key's `"|e<N>"` suffix (absent for a plain chunk key) is parsed back into an
   `AssetVfx.Emitter` at the top of each iteration. Every other line (grouping into `entries`,
   computing the centroid, calling `MeshMerge.merge_instances()`, sizing `DrawPolicy.apply()` from
   the max individual object height) is unchanged and shared.
3. When the parsed key carries an emitter class, the built holder gets two new things a plain
   merged holder does not: `EnvironmentVfx.PLACEMENTS_META` (`&"placements"`, unchanged contract —
   local, centroid-relative positions, exactly like a per-asset `MultiMesh` holder already
   publishes) and a new `EnvironmentVfx.EMITTER_META` (`&"vfx_emitter"`, an `AssetVfxLibrary.Emitter`
   int) declaring the class directly, since no single asset id survives the bake to resolve one
   from.
4. `EnvironmentVfx._apply_node()` checks a new `_merged_emitter_for()` ancestor walk (parallel to
   the existing `_asset_id_for()`) BEFORE the asset-id path, so a merged holder is routed straight
   to `_register_emitter()` with its declared class and never falls through to the (fruitless)
   asset-id lookup. `_register_emitter()` itself needed no change: it is called with an empty
   `asset_id` (only used for the hand-authored-placeholder `replaces_host_mesh()` check, which is
   never true for real authored-world geometry), and takes the same "read `PLACEMENTS_META` off an
   ancestor, multiply by `global_transform`" path a per-asset holder already exercises.

**Correctness-preserving, not a behaviour change.** Every emitter-bearing prop that reaches this
new bucket was ALREADY getting an emitter site registered before this fix — F-187 routed it through
the per-asset `MultiMesh` path, which already carried `ASSET_META` + `PLACEMENTS_META` and already
worked. What changes is which node structure builds the geometry (fewer draw calls, same final
`EnvironmentVfx` site count and behaviour), not whether the fire/crystal/spore effect exists.

**On Hollowmere specifically, the emitter-class win is small: two props** (`ward_activation_crystal`
and one `mire_crystal_f` instance, both CRYSTAL and both barely under 1.2 m). Every other
emitter-bearing asset on this map sits just over `DrawPolicy.SHADOW_MIN_HEIGHT` and still routes
through the original per-asset path. The bulk of the actual draw-call win on THIS map comes from
folding `GLOW` (`mushroom_cluster_*`, 52 instances) into the plain bucket — a mechanism this fix
also newly enables, since `GLOW` was excluded from the old rule purely because `emitter_for() !=
NONE`, with no distinction for what a class actually needs at runtime. The mechanism itself is
untied to Hollowmere's specific asset heights: a future map, or a shorter crystal/campfire mesh,
gets the full per-class merge for free.

**`tools/prop_chunk_merge_check.gd` updated in step:** its independent eligibility recompute now
buckets by `(chunk)` or `(chunk, emitter class)` the same way `_build_props` does (GLOW excepted),
so a drift between the two classifications still fails loudly rather than silently.

**`tools/environment_vfx_hollowmere_check.gd`'s `_check_placement_space` widened:** the existing
per-asset match (a merged holder's `placements`, read back through `global_transform`, must land on
a real prop position from the layout) cannot apply to an `EMITTER_META`-only holder — no single
asset id survives the merge to look up in the per-asset expected-sites table. A parallel
`expected_by_emitter` grouping and a second branch validate an emitter-class holder against every
layout site sharing its declared class instead — looser than the per-asset match (it cannot catch
two same-class props swapping identities within one merge), but it is the check that would catch
F-144's actual bug class (a stale or wrongly-rebased centroid), and without it this widened merge
would silently stop being covered by the one check built to catch exactly that.

**Verify:** `agent godot --script tools/prop_chunk_merge_check.gd`,
`tools/environment_vfx_hollowmere_check.gd`, `tools/hollowmere_check.gd`,
`tools/harvest_batch_check.gd`, `tools/harvest_world_check.gd`, `tools/resource_scatter_check.gd`,
`tools/mesh_merge_check.gd`; measure with `agent godot --windowed --script
tools/frame_cost_check.gd` against `agent baseline --windowed --script tools/frame_cost_check.gd`.

**Verified 2026-08-19 (lp):** every check above `PASS`/`failures=0`. `AUTHORED_WORLD` at HEAD:
`multimeshes=761 merged_meshes=25` → `multimeshes=734 merged_meshes=28`.
`prop_chunk_merge_check.gd`: `eligible_props=263 eligible_chunks=28`, matching the 28 `merged_*`
holders built — zero drift. `environment_vfx_hollowmere_check.gd`: `CRYSTAL sites=101` unchanged
from pre-fix (confirms the refactor is behaviour-preserving), new
`MERGED_EMITTER_PLACEMENTS checked=2 stray=0`. `frame_cost_check.gd` "as shipped" vs `agent
baseline` (HEAD, pre-fix): draw calls 4,942 → 4,931, primitives 1,155,236 → 1,159,310 (+0.35%,
nowhere near the +16% shadow-cascade regression F-187/F-203's own history warns about — every
merged holder, plain or emitter-class, still passes through the same sub-`SHADOW_MIN_HEIGHT`
eligibility gate and still reads `cast_shadow == SHADOW_CASTING_SETTING_OFF`), vram 251.4 MB →
253.2 MB. Sway spun out to F-208 with the mechanism it still needs.

---

## F-208 · F-203's sway case is still unsolved — `_apply_sway`'s per-mesh height mask needs a per-vertex baked channel before sway-bearing props can join the cross-asset chunk merge

**Claim:** `world/gen/authored_world.gd`, `core/render/mesh_merge.gd`, `autoload/environment_vfx.gd`,
`world/environment/foliage_wind.gdshader`, `tools/prop_chunk_merge_check.gd`,
`tools/environment_vfx_hollowmere_check.gd`, `tools/mesh_merge_check.gd`, `docs/FINDINGS.md`,
`docs/SPECS.md`, `docs/DELEGATION.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Scope decided here, matching F-203's own precedent:** an asset carrying BOTH sway and an emitter
(`mire_tendril`: TENDRIL + SPORE, the only one on Hollowmere) stays excluded from every merge
bucket. Solving that combination would need one merged holder to carry `EMITTER_META` (a class to
register per-instance sites for) AND a baked sway mask at once — a real extension, but not what
F-208's own title names, and not a regression: F-187 already excluded every sway-bearing asset from
any merge bucket, so narrowing the new mechanism to sway-only assets loses nothing that worked
before this task.

**Fix — a per-vertex baked height mask (option 1 from `docs/FINDINGS.md`'s own list), plus a third
merge bucket keyed by class the same way F-203's emitter bucket is:**

1. `core/render/mesh_merge.gd`'s `merge_instances()` gained a `bake_height_mask: bool = false`
   parameter. Computed once per entry (not per surface — `mesh.get_aabb()` already spans every
   surface of one entry's own mesh): `mask_root_y`/`mask_inv_height` from that entry's own local
   AABB, exactly what `EnvironmentVfx._apply_sway` would have read for that asset un-merged. Every
   output vertex's UV2.x is overwritten with `clamp((source_v.y - mask_root_y) * mask_inv_height,
   0, 1)` — computed from the SOURCE vertex, before `transform` moves it into the merged holder's
   shared space, which is what lets two different source assets in one bucket keep two different,
   individually-correct masks. Forces `ATTR_UV2` on for every bucket in a call that sets the flag,
   since the caller (`sway_mergeable`) is always a sway-only merge and mixed UV2 presence would
   leave some vertices with a stale mask.
2. `world/environment/foliage_wind.gdshader` gained `uniform bool use_baked_mask = false`. The
   vertex shader's height-mask base is `use_baked_mask ? clamp(UV2.x, 0, 1) : clamp((VERTEX.y -
   wind_root_y) * wind_inv_height, 0, 1)` — everything downstream (smoothstep, `mask_power`,
   `sway_strength`, phase) is unchanged and shared between both paths. Default false, so every
   existing per-asset `MultiMesh`/loose-mesh sway material — the large majority of swaying
   instances on any map — is byte-for-byte unaffected.
3. `world/gen/authored_world.gd`'s `_build_props()` gained `sway_mergeable`, keyed
   `"<chunk>|s<sway_int>"`, exactly parallel to `emitter_mergeable`'s `"<chunk>|e<emitter_int>"`.
   Eligibility: non-harvestable, sub-`DrawPolicy.SHADOW_MIN_HEIGHT` (the unchanged guard — the
   F-203 shadow-cascade trap cannot recur, since nothing entering any merge bucket ever changed
   height-eligibility), `sway_for() != NONE`, and `emitter_for() == NONE` (see Scope above).
   `sway_mergeable` folds into `mergeable` before the build loop the same way `emitter_mergeable`
   does, so one loop still handles all three buckets — the key's `"|s<N>"` suffix (parsed
   alongside the existing `"|e<N>"`) is the only new branch. `MeshMerge.merge_instances(entries,
   sway != Sway.NONE)` passes the bake flag only for a sway-class bucket.
4. The built holder for a sway-class bucket gets `EnvironmentVfx.SWAY_META` (`&"vfx_sway"`, an
   `AssetVfxLibrary.Sway` int) declaring the profile directly — no `PLACEMENTS_META`, since nothing
   downstream reads a per-instance position for pure sway, unlike the emitter case. A new
   `AuthoredWorld.merged_sway_instance_count` stat records how many placements moved into this
   bucket, purely for verification — the holder itself needs no live count.
5. `EnvironmentVfx` gained `SWAY_META` and `_merged_sway_for()` (parallel to `EMITTER_META`/
   `_merged_emitter_for()`), checked in `_apply_node()` before the asset-id walk — same ordering
   rationale as F-203's emitter check. A merged sway holder routes to new `_apply_baked_sway()` /
   `_baked_sway_material()`: same dressing shape as `_apply_sway`/`_sway_material` (dress the MESH
   once, keyed by `get_instance_id()`, cached in the same `_dressed_meshes`/`_sway_materials`
   dictionaries with a `"baked:"`-prefixed cache key so a baked and non-baked material sharing the
   same colour/profile numbers never collide), but sets only the profile parameters plus
   `use_baked_mask = true` — no `wind_root_y`/`wind_inv_height`, meaningless once several
   placements share one mesh's AABB.

**Correctness-preserving for every prop NOT newly eligible.** Every sway asset that stays on the
per-asset `MultiMesh` path (too tall, or carrying an emitter too) is byte-for-byte unaffected —
`_apply_sway`/`_sway_material` and the shader's non-baked branch are untouched by this fix.

**On Hollowmere specifically:** `merged_meshes` 28 → 67 (39 new sway-class buckets across the
map's ground-cover/frond/flower/bush/reed/flower/sapling types), `merged_sway_instance_count=456`
individual placements baked into them. `frame_cost_check.gd` "as shipped" vs `agent baseline`
(HEAD, pre-fix): draw calls 4,936 → 4,864 (a further win), primitives 1,147,078 → 1,171,296 (+2.1%,
the same small LOD-boundary shift F-203 saw splitting its own buckets — nowhere near the +16–18%
shadow-cascade regression F-187/F-203's history warns about), vram 253.2 → 278.2 MB (+9.9%, the
real and expected cost of the new UV2 channel plus 39 more merge buckets, traded for the draw-call
win). `frame_ms` "as shipped" is noisy on this shared machine — two back-to-back runs of the SAME
built code read 17.86 ms and 9.43 ms — confirmed as scheduler noise from other agent lanes, not a
regression: every `preset` row (high/medium/low, sampled independently of "as shipped") stayed flat
or improved across both runs.

**Verify:** `agent godot --script tools/mesh_merge_check.gd` (includes a new synthetic
`bake_height_mask=true` test), `tools/prop_chunk_merge_check.gd`,
`tools/environment_vfx_hollowmere_check.gd`, `tools/hollowmere_check.gd`,
`tools/harvest_batch_check.gd`, `tools/harvest_world_check.gd`, `tools/resource_scatter_check.gd`;
measure with `agent godot --windowed --script tools/frame_cost_check.gd` against `agent baseline
--windowed --script tools/frame_cost_check.gd`.

**Verified 2026-08-19 (lm):** every check above `PASS`/`failures=0`. `prop_chunk_merge_check.gd`:
`eligible_props=719 eligible_chunks=67`, matching the 67 `merged_*` holders built — zero drift, and
its own independent eligibility recompute now excludes a sway+emitter combo the same way
`_build_props` does. Every merged holder's `cast_shadow` still reads OFF (F-203's own invariant).
`environment_vfx_hollowmere_check.gd`: `merged_sway_instances=456` folded into the
`swaying_copies > 1000` coverage assertion (which would otherwise undercount, since a sway holder
publishes no live per-instance data to read a copy count back from), plus a new
`merged_sway_instances > 0` assertion proving the bucket actually engaged on this map. Full
writeup and numbers: `docs/FINDINGS.md` F-208.

---

## F-154 · Two events in COMMANDS.md §5.2's own illustrative hook vocabulary — `run_started`, `player_downed` — had no shipped signal to bind to

**Claim:** `systems/health/player_health.gd`, `systems/cycle/cycle_service.gd`,
`autoload/command_service.gd`, `tools/hook_events_check.gd` (new), `docs/FINDINGS.md`,
`docs/SPECS.md`, `docs/DELEGATION.md`, `docs/COMMANDS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**The gap, per the finding:** `CommandService._HOOK_EVENTS` bound three of the five events
COMMANDS.md §5.2 names illustratively (`night_started`, `day_started`, `enemy_died`); `run_started`
and `player_downed` had no real signal, so naming either in a HookDef failed loudly (a MireLog error
at wire time) rather than silently never firing — not a bug, but not a closed finding either.

**Fix — one real signal each, on the system that already owns the lifecycle in question:**

1. **`player_downed`** (`systems/health/player_health.gd`): a new `signal player_downed(peer_id: int)`,
   host/solo-only, emitted at the exact three call sites `DownedState.apply_damage()` can return
   `Transition.WENT_DOWN` from — `host_apply_damage()` (melee/enemy hits), `_tick_hunger()`
   (starvation), `_tick_blight()` (Blight corruption) — a sibling sweep per F-185's own lesson, not
   just the first site found. Deliberately distinct from the existing broadcast `downed_flag_changed`
   bool: that one also fires `true->false` on revive, which is exactly the wrong shape for "just went
   down" hook content (an author's `.mcmd` firing again on every successful revive). `apply_damage()`
   already no-ops once `state != ALIVE`, so this can never double-fire for one down.
2. **`run_started`** (`systems/cycle/cycle_service.gd`): a new `signal run_started()`, fired exactly
   once per process from a new guarded `_emit_run_started()`, called right after `_ready()`'s existing
   `_announce()`. Gated on the same `_owns_cycle()` host/solo check `_announce()` already uses — a
   client joining someone else's run never fires its own copy, same split `night_started`/
   `day_started` already establish. **Decision, recorded here rather than a new D-number** (no
   cross-cutting API contract, this file already owns Cycle lifecycle per its ARCHITECTURE.md §2.2
   row): a "run" is the whole process lifetime, not a session — `_current_cycle` already has no
   session-open/close reset anywhere in this file (task 6.1's existing, unchanged behavior), so "fires
   once per process" is the correct definition of "once per run" here, not an approximation forced by
   convenience. A future hub-loop/"play again" flow that restarts a run without restarting the process
   would need to revisit this guard — it does not exist today.
3. **`autoload/command_service.gd`**: one `_HOOK_EVENTS` row each (`run_started` -> `/root/CycleService`
   + the existing zero-arg `_on_hook_signal_0` handler; `player_downed` -> `/root/PlayerHealth` + a new
   `_on_hook_signal_player_downed(peer_id, function_name, host_only)`), plus the stale class-doc comment
   above the table (it named F-154 as still-open) rewritten to describe the now-real bindings.

**Verify:** new `tools/hook_events_check.gd` — `agent godot --script tools/hook_events_check.gd`,
`HOOK_EVENTS_CHECK failures=0`. Proves, per event: `wire_hook()` connects without an "unknown event"
error; firing the real signal actually runs the bound function through `CommandService`'s real front
door (the same proof `tools/function_check.gd` already gives `night_started`'s dusk crossing);
`player_downed` additionally proves the edge shape directly against `PlayerHealth` (fires once on
down, not again while still down, NOT on revive, fires again on a second down) and `run_started`
proves its own one-shot boot emission already happened and a repeat call is a no-op. A deliberate
negative case (an event still genuinely absent from the table) confirms the loud-failure path this
finding relied on the whole time still works. Also re-ran `tools/function_check.gd`,
`tools/cycle_check.gd`, `tools/player_health_check.gd`, `tools/command_catalog_check.gd` (all
`failures=0`, unaffected) and a full headless boot (`agent godot --quit-after 60`) with zero `ERROR:`
lines outside the deliberate negative-case one.

**Verified 2026-08-19 (lp):** `HOOK_EVENTS_CHECK failures=0`; `FUNCTION_CHECK failures=0`;
`CYCLE_CHECK failures=0`; `PLAYER_HEALTH_CHECK` `0 failure(s)`; `COMMAND_CATALOG_CHECK failures=0`;
full boot clean.

---

## F-149 · F-141's docs edits got committed under F-144's message — a concurrent agent's plain `git commit` absorbs another lane's staged-but-uncommitted files

**Claim:** `tools/harness_check.py`, `docs/FINDINGS.md`, `docs/SPECS.md`, `docs/DELEGATION.md`. No
production/runtime file — this is coordination tooling, not a networked system, so it declares no
`ARCHITECTURE.md` §2.2 authority row.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Checked before touching anything, per the brief's own instruction.** `python3
tools/harness_check.py` (29/29 before this task's own additions) already carries F-199's case, which
covers a *related* but narrower shape: a bare commit blocked because every offending file is another
lane's exact **claim**. F-149's actual incident shape is different and that case does not exercise
it — `docs/` is exempt from claims entirely (F-006/F-072), so two lanes' unclaimed docs edits sitting
staged together produce **no error and no warning** from `agent check`; there was nothing here for the
existing suite to have caught.

**Root cause, confirmed rather than re-derived:** `git commit` with no pathspec commits the whole
index, not just the committing agent's own staged files. This is pure git behavior, not a harness bug
— nothing in `.agent/bin/agent` issues a bare `git commit` (`cmd_ship` already pathspecs, F-014,
2026-08-16, predates this finding), so there was no code defect to fix. The hazard is entirely in
*hand-typed* commits for `docs/` — the one class of commit the harness cannot perform for you, because
`ship` deliberately leaves claim-exempt docs files for hand-commit (F-006).

**Fix already landed by the time this finding was picked up, via F-199's work the day after F-149 was
filed:** `AGENTS.md`'s ship section now mandates pathspec on every hand-commit of docs (`git commit -m
"..." -- docs/FINDINGS.md docs/DECISIONS.md`), naming F-149 and F-199 as the motivating incidents. A
pathspec commit builds its tree from HEAD plus only the named paths' current worktree bytes — it does
not touch, read, or depend on whatever else happens to be sitting in the shared index, which is
exactly the isolation F-149's incident needed and did not have. This finding's own two suggested
closes were (a) a new atomic stage+commit helper, or (b) document and accept as known/low-severity
since content is never lost, only misattributed — (b) is what actually shipped, one day after filing,
as part of the sibling F-199 fix.

**This task's contribution: a regression test proving (b) is real, not just written prose.** Three new
`tools/harness_check.py` cases:

1. Two lanes' unclaimed docs edits staged together — `agent check` passes with no output, confirming
   F-149's premise (docs/ is silently exempt) still holds and nothing here would ever be caught by the
   hook.
2. The incident, reproduced with plain git: a bare `git commit` after that setup carries **both**
   lanes' files under one lane's message — proves the hazard is real, not hypothetical, without
   needing `--rev` against a "broken" harness (there is no broken harness; the break is a missing
   `--`).
3. The fix, same setup, one flag different: `git commit -m "..." -- docs/SPECS.md` commits only the
   named file, and the other lane's staged `docs/FINDINGS.md` survives — still staged, still
   uncommitted, ready for its own lane to commit separately. Matches how `cmd_ship`'s own pathspec
   commit already behaves for claimed files (F-014); this proves the hand-typed form AGENTS.md tells a
   docs-closer to type by hand gives the identical guarantee.

**Verified 2026-08-19 (lp):** `python3 tools/harness_check.py` — 32/32 (29 prior + 3 new). No Godot
involved — this is a git-behavior question, not an engine one, so `agent godot --quit-after 120`
would have exercised nothing this finding is about; skipped for that reason, not skipped by omission.

**Swept for siblings:** `grep -n '"commit"' .agent/bin/agent tools/*.py` — the only `git commit` call
site anywhere in the harness or its checks is `cmd_ship`'s own, already pathspec'd. No second
un-pathspec'd commit call exists to be the next incident.

---

## F-191 · Staging and committing as two steps lets a concurrent agent's commit sweep up your staged work

**Claim:** `.agent/bin/agent`, `tools/harness_check.py`. No production/runtime file — coordination
tooling, not a networked system, so it declares no `ARCHITECTURE.md` §2.2 authority row.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Checked before touching anything, per the brief's own instruction.** `python3
tools/harness_check.py` was 29/29 at HEAD, already covering F-149 (docs/ is claim-exempt, so two
lanes' unclaimed docs staged together produce silence) and F-199 (a bare commit blocked ONLY by
foreign *active* claims). Neither covers F-191's own incident shape: the two swept files
(`.agent/bin/agent`, `tools/harness_check.py`) were **claimed and already released** (nettle12's F-186
work, `done()` had run) by the time the other session's bare commit landed. Nothing in the existing
suite exercised a released claim sitting staged under a different, current committer.

**Root cause, the part F-191 itself left "untested":** the finding's own text asked "why did the hook
admit the sweep instead of blocking it", listing `--no-verify` and a check/commit race as untested
candidates. Neither — it's `in_grace()` (`.agent/bin/agent:1473`). `in_grace(f)` calls `_is_mine(r, me,
me_token)` where `me` is **whoever is running the check right now**, i.e. the committer, not the agent
who released the file. Once nettle12's F-186 task called `done()`, the claim was released (`c = None`
in `cmd_check`) and nettle12's *own* next commit would correctly see `in_grace(f) == True` and skip
straight to a quiet pass. But the actual incident's committer was a **different** session — for that
committer, `_is_mine` compares nettle12's `recent` record against the wrong identity and returns
`False`, so `in_grace` is `False` too, and the file falls to the generic `elif not c and not human and
not in_grace(f)` branch: a plain `"edited without a claim"` **warning**, which does not block. F-072
deliberately keeps unclaimed files free to commit, so this was never going to be a hard block — but the
warning gave no hint that the file wasn't ownerless, it was another session's very-recent work about
to be swept.

**Fix, two parts:**

1. **`.agent/bin/agent`'s `cmd_check`:** the `elif not c and not human and not in_grace(f)` branch now
   checks `st["recent"][f]` directly (not through `in_grace`, which is scoped to the wrong identity for
   this case) — if a record exists, belongs to a **different** agent, and is younger than
   `RECENT_GRACE_HOURS`, the warning names that agent, cites F-191, and prints the pathspec fix instead
   of the generic "edited without a claim" line. Still a warning, not an error — an unclaimed file
   really is free to commit (F-072); the fix is naming the mechanism, not blocking, matching F-199's
   same choice for the sibling active-claim case.
2. **`AGENTS.md`'s F-081/D-057 harness section:** it told a task fixing the harness to claim
   `.agent/bin/agent` before `done`, and separately that `ship` won't stage it — but never said HOW to
   commit it afterward. That silent gap is what actually produced F-191's incident: nettle12 followed
   the documented claim step, then had nothing telling them the hand-commit needed a pathspec (the
   `docs/` hand-commit section already got this instruction from F-199; the harness-source section,
   filed one day *before* F-199, never did). Added the same pathspec-commit instruction there, naming
   F-191 as the incident.

**This task's contribution: two new `tools/harness_check.py` cases**, plus the hook and doc fix above:

1. A file released by a **different** agent (`beta`) 1h ago, staged under the current committer
   (`alpha`) — `check` passes (still a warning, not a block) but names `beta`, `F-191`, and the
   pathspec form.
2. The same shape at 7h — past `RECENT_GRACE_HOURS` (6) — falls back to the plain "edited without a
   claim" warning, proving the new branch is scoped to the actual race window and not a blanket
   rename of every unclaimed-file warning.

**Verified 2026-08-19 (lm):** `python3 tools/harness_check.py` — 31/31 (29 prior + 2 new).
`python3 tools/harness_check.py --rev HEAD` (pre-fix harness) — 30/31, failing exactly the new
sweep-naming case and nothing else, confirming it is a real regression guard. No Godot involved — this
is a git/coordination-tooling question, not an engine one; `agent godot --quit-after 120` would have
exercised nothing this finding is about.

**Swept for siblings:** `grep -n '"commit"' .agent/bin/agent tools/*.py` — still only `cmd_ship`'s own
pathspec'd call. Also grepped every other `AGENTS.md` hand-commit instruction (`grep -n "git commit"
AGENTS.md`) — the `docs/` one already has the pathspec form (F-199); the harness one didn't until this
task. No third hand-commit instruction exists in the doc to be the next gap.

---

## F-196 · An asset rebuild concurrent with `agent godot`'s auto-import pass poisons the import cache — 8 station GLBs stayed unloadable across 40 minutes of checks until a forced `--import`

**Claim:** `tools/blender/godot_import_lock.py` (new), `tools/blender/mire_art.py`,
`tools/blender/build_adapted_nature_set.py`, `build_crafting_stations.py`, `build_construction_set.py`,
`build_enemy_crawler.py`, `build_food_set.py`, `build_extraction_ship_set.py`, `build_flora_set.py`,
`build_gatherable_plants.py`, `build_harvestable_resources.py`, `build_mire_map_kit.py`,
`build_loot_set.py`, `build_playtest_hollow.py`, `build_pickup_kit.py`, `build_ward_set.py`,
`build_tool_weapon_set.py`, `build_wellspring_set.py`, `render_item_icons.py`,
`tools/audio/render_music.py`, `tools/audio/render_sfx.py`, `tools/import_cache_guard_check.py` (new).
Pure tooling — no production/runtime file, no `ARCHITECTURE.md` §2.2 authority row.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause, confirmed rather than re-derived:** `agent godot` (`cmd_godot` in `.agent/bin/agent`)
already serialises every Godot process against every other one via `.agent/locks/godot.lock`
(F-044), and forces an import pre-pass under that same lock before every run (F-093). But a Blender
asset writer is not a Godot process — it never took that lock, so nothing stopped one lane's
`agent godot` import pass from reading a GLB mid-write. F-196's incident: 8 crafting-station GLBs
rebuilt in the working tree while the 2026-08-19 audit battery cycled `agent godot` runs; one import
pass caught a torn read, stamped `.godot/`'s cache against it, and — because nothing on disk changes
after the writer finishes — every later pass, including the writer's own trailing checks, kept
reading "already imported" and skipped it. 16 ERROR lines per run, 40+ minutes, until a human ran
`agent godot --import` by hand.

**The fix — chosen from the finding's own two candidates (a hash-verify failure ledger inside
`agent godot`, or making the writer coordinate):** a new dependency-free module,
`tools/blender/godot_import_lock.py`, exposes `import_cache_guard(label, force_import=True)` — a
context manager that `fcntl.flock`s the exact same `.agent/locks/godot.lock` file, writes/clears a
holder-record JSON in the same shape `.agent/bin/agent`'s own `file_lock` writes (so a lane waiting
on `agent godot` sees "held by ... running <label>", not "holder unknown"), and on release shells
out to `agent godot --import` once — the same manual step the finding already verified clears a
poisoned cache. Held for the writer's **entire** export, not just a trailing import call: that is
what makes the race structurally impossible (no `agent godot` run can even start while the guard is
held) rather than merely narrower. Kept `bpy`-free so `tools/import_cache_guard_check.py` can drive
it with a bare `python3` interpreter.

Every `build_*.py` writer's `if __name__ == "__main__":` block now reads:

```python
if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
```

**Swept for siblings — this is where the finding's real scope turned out to be:** grepped for every
script that writes into an `assets/` path Godot imports through `EditorFileSystem` (anything that
gets a `.import` sidecar — `.glb`/`.png`/`.ogg`/`.wav`), not just the one family that happened to
trip the incident. Found and fixed 19 total: the 16 `build_*.py` GLB exporters,
`render_item_icons.py` (PNG icons), and `tools/audio/render_music.py`/`render_sfx.py` (OGG/WAV) —
all newly claimed and wrapped the same way. `tools/mapgen/hollow_layout.py`/`hollowmere_layout.py`
write JSON layouts that Godot reads directly at runtime, never through the import pipeline, so they
carry no `.import` sidecar and correctly need no guard (recorded as `D-126`, so nobody re-litigates
it against a future JSON writer).

**Verified 2026-08-19 (lp):**

- `python3 tools/import_cache_guard_check.py --godot` → 4/4. The fourth case is the one that
  actually proves the fix rather than re-deriving its own lock path and calling that proof: it holds
  the guard in a subprocess, launches a REAL `agent godot --quit-after 5` concurrently, asserts it
  has not exited 2.5s in (still holding), then asserts it completes cleanly only after the guard
  releases — direct evidence the two resolve to the identical `.agent/locks/godot.lock`, not two
  paths that happen to look alike.
- `agent godot --quit-after 120` → clean boot, world content (crafting stations included) loads with
  0 new `ERROR:`/`Failed loading resource` lines — the exact symptom F-196 reported.
- `python3 -m py_compile` on all 19 edited writers plus the two new modules — all clean.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-201 · `tools/steam_lobby_check.gd` prints "all checks passed" (exit 0) but always emits one undeclared engine `ERROR:` line, violating this project's own SPECS.md standing rule 4

**Claim:** `tools/steam_lobby_check.gd`, `docs/FINDINGS.md`, `docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble. Its brief carried a staleness warning (`docs/SPECS.md` had commits since filing) — checked
first per that warning: unrelated blocks added by other findings, nothing touching
`tools/steam_lobby_check.gd` or the standing-rule-4 mechanism, so the finding was still live.
Re-ran the check against a real, logged-in Steam client before touching anything, per its own "may
already be fixed" note — it reproduced the identical undeclared line, so the fix was still needed.

**Root cause, confirmed rather than re-derived:** the finding's own theory was right. This script
connects its `_on_server_started` to `NetTransport.server_started` in `_initialize()` (line 77),
which under a `--script` main loop runs *before* `NetSession`'s own autoload `_ready()` gets to
connect its `_on_session_opened` to the same signal — so this script's handler fires first on that
emission and calls `lobby.leave()` synchronously inside it, tearing the peer down. `NetSession.
_on_session_opened()` then runs second against the same emission, reads `NetTransport.is_host()`
as already false, and calls `net_client_hello.rpc_id(...)` with no active peer — the observed
`ERROR: Trying to call an RPC while no multiplayer peer is active.`

**Decided (a), not (b), from the finding's own two options:** grepped every `server_started`
connection site in the repo (`ui/debug/net_debug_panel.gd`, `core/game_state.gd`,
`core/dev/dev_launch.gd`, `autoload/enemy_world.gd`, `autoload/inventory_service.gd`,
`autoload/defeat_service.gd`, `autoload/player_net.gd`, `systems/health/player_health.gd`,
`core/net/net_session.gd`) — none of them call `leave()` (or any teardown) synchronously from
inside their `server_started`/`session_opened` handler the way this check does. The race only
exists because this `--script` harness's own handler registers ahead of the autoloads' `_ready()`;
no real host-disconnect-mid-session path can hit this window during actual play. So: declared the
error by pattern rather than restructuring the check's `leave()` to be deferred, which would stop
testing what task 1.4 actually needs proven — that a real, synchronous `lobby.leave()` this soon
after hosting starts leaves a clean lobby/session.

**Fix:** `_finish()` now prints `EXPECTED_ERROR_PATTERNS="Trying to call an RPC while no
multiplayer peer is active"` on its verdict line, the same shape `session_lifecycle_check.gd`/
`connect_retry_check.gd` already use per standing rule 4. A comment on the `-- leave --` section
explains the mechanism so nobody "fixes" it again by silencing `NetSession`'s production log call
(rule 4's own explicit warning against that).

**Verified 2026-08-19 (lp):** `.agent/bin/agent godot --script tools/steam_lobby_check.gd`, twice,
against a real logged-in Steam client — both exit 0, all 17 `ok` assertions print, "all checks
passed", then the one `ERROR:` line still appears (the harness-shape race is unchanged, as decided
above) but is now declared. Graded exactly per standing rule 4:
`grep 'ERROR:' <run.log> | grep -vE 'Trying to call an RPC while no multiplayer peer is active' | wc -l`
→ `0`.

**Swept for the same shape elsewhere:** grepped every `tools/*_check.gd` for `.leave()` and for
`server_started`/`session_opened` connections. Three other checks call `.leave()`
(`connect_retry_check.gd`, `net_robustness_check.gd`, `net_debug_panel_check.gd`) but each does so
after an `await process_frame`/`await create_timer(...)`, well outside any signal-connection-order
window, not synchronously inside a handler racing an autoload's own `_ready()`. `session_lifecycle_
check.gd` connects to `NetSession.session_opened` (emitted only after `NetSession`'s own handler has
already run), not `NetTransport.server_started` directly, so it cannot race the same way — and its
own header already documents the adjacent "nothing may touch autoloads from `_initialize`" trap,
deferred correctly. No sibling instance of this specific ordering bug found.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-112 · `world/gen/undergrowth.gd`'s prop-avoidance still has no map-agnostic check — F-076's third system

**Claim:** `world/gen/undergrowth.gd`, `tools/world_contract_check.gd`, `tools/hollowmere_check.gd`.
No new networked system — `Undergrowth` already declares `None` authority (presentation-only,
client-local, deterministic from the layout seed) and this task adds a check plus a read-only export,
neither of which changes that.

**Root cause / what's missing:** F-076 generalized `EnemyWorld`/`HarvestWorld`'s group-name blind
spot into `tools/world_contract_check.gd`, map-agnostic, but explicitly left `Undergrowth`'s "don't
grow on top of a prop" rule uncovered — it has no equivalent ground-truth field sitting directly in a
layout the way `markers[].kind`/`props[].harvestable` do. `tools/hollowmere_check.gd`'s
`_check_undergrowth_stays_off_props` was the only check for it, and it is Hollowmere-specific.

**Fix:** `Undergrowth.sample_ground_gaps() -> Array[float]` (new), stride-sampling this run's
`_placements` — the world-space `Transform3D`s `_scatter()` already computed — and reporting each
sampled plant's height above the layout's own heightfield (`_layout_height()`, already generic).
`world_contract_check.gd` gained `_check_undergrowth(level)`: finds the map's `Undergrowth` node, and
if it exposes `sample_ground_gaps()`, flags a FAIL when more than 2% of sampled plants sit more than
0.6 m above ground — the same tuning `hollowmere_check.gd`'s function already proved (a handful
legitimately stand on bridge decks/camp floors; a genuine "grass on the boulders" bug reads as
hundreds). No layout `Dictionary` needed for this half — `Undergrowth` already read its own, so it
runs whether or not `_layout_for()` found a `World.layout_path` on the map at all.

**Found while verifying (folded into this task, not filed separately — see D-127):**
`hollowmere_check.gd`'s existing function had two compounding bugs, invisible to each other. It read
`MultiMesh.get_instance_transform()`'s origin bare, with no `to_global()` — that origin is
CELL-LOCAL (rebased around each MultiMesh's own centre in `undergrowth.gd::_emit()`), so
`height_at(origin.x, origin.z)` sampled terrain near world (0,0) for every plant regardless of where
it actually stood. That went unnoticed because `MultiMesh` instance transforms live on the
RenderingServer and the `--headless` dummy renderer this check has always run under
(`agent godot --script`, never `--windowed`) answers every read with identity, no error (F-103,
`tools/multimesh_readback_check.gd`) — `worst=0.00 m` every run wasn't this check passing, it was
`get_instance_transform()` returning the same near-origin coordinate for every sample. **This check
had asserted nothing since it shipped.** Fixed by having it delegate to the new
`sample_ground_gaps()` too, which reads `_placements` directly and needs no renderer at all — one
correct implementation instead of two, and no `--windowed` requirement anywhere in this task.

**Verified 2026-08-19:** `agent godot --script tools/world_contract_check.gd` on the live Hollowmere
boot: `WORLD_CONTRACT_UNDERGROWTH sampled=10342 perched=4 worst=0.65m`, `WORLD_CONTRACT_CHECK PASS`
(0.04%, well under the 2% tolerance — confirms Hollowmere's real prop-avoidance is fine, not just
that the check runs). `agent godot --script tools/hollowmere_check.gd` reports the identical
`sampled=10342 perched=4 worst=0.65 m`, `HOLLOWMERE_CHECK PASS` — both checks now agree because both
call the same method. **Regression-proved the check catches the actual bug shape**: temporarily
stubbed `_is_prop()` to always return `false` (reintroducing F-076's exact defect) —
`world_contract_check.gd` correctly failed loudly (`851/11297 perched, 7.5%`, `WORLD_CONTRACT_CHECK
FAIL`) before the stub was reverted and a clean re-run confirmed `perched=4` again. Full boot clean
(`agent godot --quit-after 120`, no new ERROR lines). `tools/multimesh_readback_check.gd`,
`tools/harvest_world_check.gd`, `tools/enemy_check.gd` unaffected (`failures=0`).

**Resolved** — see `docs/FINDINGS.md`.

---

## F-198 · Three DONE asset batches (A-004, A-005, A-006) still call `mire_art.box()`'s bevel-capable version with no override

**Claim:** `tools/blender/build_tool_weapon_set.py`, `tools/blender/build_loot_set.py`,
`tools/blender/build_enemy_crawler.py`, `tools/blender/asset_repro_check.py` (new),
`docs/ASSET_TRACKER.md`. No networked system — pure offline art tooling.

**Root cause / what's missing:** D-124 established the rule (F-057's four sibling families already
followed it independently): a family whose tracker row claims a byte-identical rebuild must not pass
`bevel=` through to `mire_art.box()`'s live BEVEL modifier, because the modifier changes float bytes
between otherwise identical background exports on Apple Silicon. Three `DONE` batches never got the
fix: `build_tool_weapon_set.py` (one site, `Cleaver_Bolster`), `build_loot_set.py` (thirteen sites
across chest bodies/locks/cloth/bag parts), and `build_enemy_crawler.py` (five sites — its local
`box()` override existed but copied `mire_art.box()`'s bevel-applying body verbatim, so it looked
like the ward-set pattern without ever changing behavior).

**Fix:** Added a bevel-free local `box()` override to each of the first two files (same shape as
`build_ward_set.py`'s: accepts `bevel` for call-site compatibility, never applies the modifier), and
fixed `build_enemy_crawler.py`'s existing override to actually drop the `if bevel > 0.0: apply
modifier` branch instead of reproducing it. Wrote `tools/blender/asset_repro_check.py`, generalizing
`crafting_stations_repro_check.py` (F-057's single-family original) into a CLI tool any family can
call: `--script <builder> --export-dir <dir> --catalog <path> --label <id>` runs the builder as two
separate Blender processes and diffs every GLB plus the catalog byte-for-byte.

**Verified 2026-08-19:** Each family rebuilt and reverified —
`asset_repro_check.py --script tools/blender/build_tool_weapon_set.py --export-dir
assets/tools_weapons/exports --catalog assets/tools_weapons/catalog.json --label A-004` (22/22
byte-identical GLBs + catalog across two clean separate-process rebuilds), same for `build_loot_set.py`
→ A-005 (10/10) and `build_enemy_crawler.py` → A-006 (4/4). Polygon totals drop as expected from the
missing chamfers: A-004R's cleaver 174→154 (only design touched), A-005 2,542→1,542 (all thirteen
sites), A-006 1,172→972 (crawler 794→634, shell fragment 59→19; nest and leg fragment carry no
`bevel=` of their own and are unaffected). Footprints (`width_m`/`depth_m`) are unchanged on every
export except 4–6 mm depth drift on `stone_axe` and `arrow` — neither calls `box(bevel=...)` — plus a
handful of `.001`/`.002` material-name suffixes silently disappearing from the catalog (e.g.
`MIRE_ClothRed.002` → `MIRE_ClothRed`). Both are one script run's ripple, not noise: all eleven
designs build inside one Blender process, and `Cleaver_Bolster`'s old `modifier_apply` call (which
sets `view_layer.objects.active`) was perturbing Blender's shared session state for whatever design
built after it — removing that call also removed the perturbation, incidentally cleaning up spurious
duplicate material datablocks the old bevel-applying run was creating. Confirmed stable, not new
nondeterminism, by this task's own two-clean-rebuild proof (byte-identical both times); well inside
the "~6 cm of A-004" tolerance the A-004R docstring already allows. Each family's own engine check
still passes clean post-rebuild: `agent godot --script tools/item_icons_check.gd` (A-004),
`agent godot --script tools/loot_content_check.gd` (A-005), `agent godot --script
tools/enemy_crawler_check.gd` (A-006) — all PASS, no ERROR lines, fresh import clean.

**Sweep (required before close-out):** `grep -c bevel= tools/blender/build_*.py` against every family
with a local `box()` override found one more live gap outside this task's three: **F-206**,
`build_gatherable_plants.py` (A-011) has six `bevel=` sites and no override, but its tracker row does
not currently claim a byte-identical rebuild, so it is not in D-124 violation today — filed rather
than fixed here, since fixing it means rebuilding and reverifying A-011's own contract, out of this
claim's scope. `build_food_set.py` (A-012) DOES claim byte-identical rebuild but has zero `bevel=`
sites (built entirely from `paint_faces` colour differences) — clean by construction, no action
needed. `build_crafting_stations.py` and `build_ward_set.py` already carry the fix from F-057/D-124's
original close-out.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-188 · Runtime-merged meshes have no shadow mesh, though every imported .glb gets one

**Claim:** `core/render/mesh_merge.gd`, `tools/mesh_merge_check.gd`, `docs/FINDINGS.md`,
`docs/SPECS.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble. Its brief carried a staleness warning (`core/render/mesh_merge.gd` and
`world/gen/undergrowth.gd` had commits since filing) — checked first per that warning: the
`mesh_merge.gd` commit was F-187 adding `merge_instances()`, which still built through the same
`ImporterMesh` path with no shadow mesh; the `undergrowth.gd` commit was F-112's unrelated
prop-avoidance check. Read `core/render/mesh_merge.gd` in full — confirmed no `shadow_mesh` write
anywhere in the file, so the finding was still live in both of its two mesh-building functions.

**Root cause, confirmed rather than re-derived:** every kit `.glb` imports with
`meshes/create_shadow_meshes=true`, so the import pipeline hands every `MeshInstance3D` a
position-only, welded shadow mesh the shadow pass renders instead of the full vertex format. Both
`MeshMerge._build()` (backing `merged()`/`collapse()`) and `MeshMerge.merge_instances()` assemble
their output through `ImporterMesh` at runtime and never touch `shadow_mesh` — `ArrayMesh.
create_shadow_mesh()` is not exposed to scripting, so nothing ever built one, and every merged prop
or harvestable rendered its full vertex format (normals, UVs, tangents) into every shadow-pass
draw a `.glb`-imported sibling would have skipped.

**Fix:** added `MeshMerge._shadow_mesh(order, buckets)`, built from the same per-bucket vertex/index
data `_build()` and `merge_instances()` already collect — one surface per visible surface, in the
same order, stripped to `ARRAY_VERTEX` and `ARRAY_INDEX` only (unwelded, since the dedup
`create_shadow_mesh()` would have done is not available to scripting; correctness over that last bit
of vertex reuse). Assigned to `combined.shadow_mesh` at the end of both functions. `CACHE_VERSION`
bumped 5 → 6 so `_build()`'s disk cache — keyed by source mtime and this constant — cannot serve a
pre-fix entry with no shadow mesh back to a caller.

**`merge_instances()` fixed unconditionally, not just where it is used today:** every current caller
(`AuthoredWorld._build_props()`'s `mergeable` path) restricts itself to props under
`DrawPolicy.SHADOW_MIN_HEIGHT`, which already turns `cast_shadow` off via `DrawPolicy.apply()` — so
today's callers see no visible change. F-203 is open on lifting that restriction for sway- and
emitter-bearing props; when it does, `merge_instances()` already has a shadow mesh rather than
silently reintroducing this finding for taller merged content.

**Verified:** `.agent/bin/agent godot --script tools/mesh_merge_check.gd` — extended with
`_check_shadow_mesh()` (asserts `shadow_mesh` is non-null, carries the same surface count as the
visible mesh, matching index counts per surface, and no channel beyond position/index) called
against every one of 361 checked kit assets (1372 surfaces), plus a new
`_check_merge_instances_shadow()` exercising `merge_instances()` directly with two synthetic boxes
(`merged()`'s own coverage never calls it). `MESH_MERGE_CHECK_GODOT PASS`. Also reran
`tools/prop_chunk_merge_check.gd` (`PROP_CHUNK_MERGE_CHECK PASS`) and `tools/hollowmere_check.gd`
(`HOLLOWMERE_CHECK PASS`) to confirm the `CACHE_VERSION` bump and the additional `shadow_mesh`
resource on cached meshes didn't disturb world generation or its existing assertions.

**Swept for the same shape elsewhere:** `grep -rn "ImporterMesh\|generate_lods\|shadow_mesh"
--include="*.gd" .` outside the two files this task touched returned nothing — `mesh_merge.gd` is
the only runtime mesh assembler in the repo, so there is no sibling site building a mesh through
`ImporterMesh` without a shadow mesh.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-204 · A Blender preview that moves assets between renders draws the layout it had at the first render

**Claim:** `tools/blender/build_gatherable_plants.py`, `tools/blender/build_flora_set.py`,
`docs/FINDINGS.md`, `docs/SPECS.md`, `docs/DECISIONS.md`, `docs/DELEGATION.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**What was wrong:** every `tools/blender/build_*.py` generator builds its assets once, then renders
several preview sheets from ONE `--background` Blender process by repositioning objects between
`bpy.ops.render.render()` calls. That does not work: `object.location`/`.rotation_euler` assigned
after the process's FIRST render never takes effect on any later render in the same process — only
camera moves and `hide_render` toggles do (F-204's own probe table, `docs/FINDINGS.md`). DELEGATION.md
already flagged `build_gatherable_plants.py` and `build_flora_set.py` as having this shape when A-012
fixed it for the food kit. Confirmed both, concretely:

- `build_gatherable_plants.py`: a single `figure` (scale-reference cube) was moved between all three
  renders — only the first sheet's position ever took effect, so `gatherable_deposits_preview.png`
  silently shipped missing its reference cube. The berry-decision shot also relocated three bush
  roots to a hand-picked tight layout that never applied, so it drew the bushes at their real grid
  positions instead.
- `build_flora_set.py`: the same one-figure-moved-between-renders bug across all SIX family sheets
  (only "shrubs", the first family, ever showed a reference cube), plus a "hero" shot
  (`flora_set_preview.png`) that relocates 18 named assets from six family grids spaced 26 m apart —
  never applied, so it would have drawn them scattered at positions the hero camera can't frame.

Neither generator's `check()` caught this — both assert geometry (bounds, triangles, materials), and
F-204's whole point is that the geometry is fine; only the preview pixels are wrong.

**Fix — two techniques, both now the standing pattern (D-128):**

1. **One object per position it will ever occupy, built before the first render, hidden/shown
   thereafter.** `make_reference(tag, location)` in both files builds a scale-reference cube per
   sheet up front; the render loop only flips `hide_render`.
2. **Where the composition needs assets from far-apart grids (the flora hero shot):**
   `hero_duplicate(record, location)` makes a linked-mesh-data copy of the asset's single joined
   export mesh (`record["root"].children[0]`), placed via `dup.matrix_world =
   Matrix.Translation(delta) @ source.matrix_world` before any render, then only hidden/shown.
3. **Where the composition doesn't actually need relocation at all:** `build_gatherable_plants.py`'s
   `SPECS` list was reordered so `berry_bush_full`, `poison_berry_bush`, `berry_bush_harvested` build
   adjacently — their real grid position then already reads left-to-right the way the decision shot
   wants, so that shot only ever moves the camera.

**Verified:** both scripts run standalone
(`/Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_X.py`) —
`GATHERABLES_CHECK PASS`, `FLORA_CHECK PASS`, geometry/catalog numbers unchanged from HEAD.
`tools/blender/asset_repro_check.py` run against both scripts: every exported GLB and both
`catalog.json` byte-identical across two fresh rebuilds (the one HEAD-vs-rebuild byte diff on
`berry_bush_harvested.glb` is the SPECS reorder shifting Blender's internal material-interning order,
confirmed harmless by the repro check, not a geometry change). Visually inspected the previously-
broken tiles after rebuild — `berry_decision_preview.png`, `gatherable_deposits_preview.png`,
`small_trees_preview.png`, `ground_cover_preview.png` (flora families 2 and 6), and
`flora_set_preview.png` — all now show their reference cube / intended composition.

**Swept for the same shape elsewhere:** `grep -n "bpy.ops.render.render\|\.location = "
tools/blender/build_*.py` over every generator with more than one render call found the identical
mechanism live in eight more files, none previously flagged. Not fixed here — each needs the same
bespoke treatment against its own hand-authored scene (one, `build_enemy_crawler.py`, duplicates an
armature rather than a plain mesh). Filed as **F-207** with the exact file/line list.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-205 · `agent check`/the pre-commit hook still lets a commit register or carry an untracked autoload target — F-200's mechanism #2 is still unbuilt

**Claim:** `.agent/bin/agent`, `tools/autoload_tracked_check.py`, `tools/harness_check.py`,
`docs/FINDINGS.md`, `docs/SPECS.md`, `docs/DELEGATION.md`.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble. Its brief carried a staleness warning (`tools/autoload_tracked_check.py` had a commit
since filing) — checked first per that warning: that one commit is `d77c061`, F-200 itself landing
`autoload_tracked_check.py` for the first time, in the same session that then filed this finding
against it. Not a fix of the gap — `--self-test` still ran 3/3 with zero pre-commit integration, so
the finding was still live and the work was still to build.

**What was wrong:** F-200 built `tools/autoload_tracked_check.py` — proves, for a given revision,
that every `project.godot` `[autoload]` target and everything it transitively `preload()`s is a git
blob that revision actually has — but nothing called it before a commit landed.
`.agent/bin/agent:cmd_check` (the pre-commit hook) only ever judged claims and the closed-editor rule;
a commit registering `Thing="*res://autoload/thing.gd"` while `thing.gd` was neither staged alongside
it nor already in `HEAD` still went through clean — F-190's and F-144's exact shape, still possible.

**Fix:** `cmd_check` now calls a new `_autoload_tracked_missing(changed)` (`.agent/bin/agent`) that,
when `changed` includes `project.godot` or any `.gd` file, imports `autoload_tracked_check` and calls
`sweep("")`. The empty-string `--rev` was already free: `autoload_tracked_check.py`'s `tracked_at`/
`read_at` build `"%s:%s" % (rev, path)`, and an empty `rev` collapses that to git's own `:path`
syntax — the INDEX, which for any tracked path already IS "staged content if there is any, HEAD's
otherwise": exactly the overlay a pre-commit hook needs, with no new revision-diffing logic and no
edit to `autoload_tracked_check.py`'s checking code at all (only its docstring, documenting the
`--rev ""` form). Anything `sweep("")` reports missing becomes a `cmd_check` error — blocking the
commit — independent of the per-file claim loop, since ownership and "does this boot" are unrelated
questions. Never fails a commit closed over a broken checker: an import/`sweep()` exception returns
`[]` (fails open on the checker's own failure, the one place in `cmd_check` that fails open on
purpose — this gate is pure upside over F-200's after-the-fact check, never the sole guard).

**Verify:**
- `python3 tools/autoload_tracked_check.py --self-test` → `4/4 passed` (new case
  `catches_staged_precommit_f205_shape`: stages an autoload registration, never `git add`s its
  target, checks `--rev ""` — no commit exists yet to name by sha, proving the INDEX view is what a
  real pre-commit hook needs, not `--rev HEAD`).
- `python3 tools/harness_check.py` → `34/34 passed`, three new cases exercising `cmd_check` itself
  through a simulated git hook (`run(..., as_hook=True)`, sets `GIT_INDEX_FILE` so `cmd_check` takes
  the STAGED/INDEX branch, F-001): registers an autoload whose script is staged nowhere (blocked,
  names the path, cites F-200/F-205); a staged autoload script whose own `preload()` target is
  untracked (blocked, names the transitive path); and the sanctioned path — a new autoload's script
  staged in the SAME commit (passes silently, `F-051`'s existing warning only — proves no
  false-positive on the one case this whole mechanism must never block).
- `python3 tools/autoload_tracked_check.py` (real repo, HEAD) →
  `AUTOLOAD_TRACKED_CHECK rev=HEAD autoloads=58 paths_checked=111` / `failures=0`.
- `.agent/bin/agent check` on the real working tree at close-out → clean pass, confirming the new
  gate doesn't fire on an ordinary commit that never touches project.godot/`.gd` files it shouldn't.

**Swept for the same shape elsewhere:** `grep -rln "cat-file -e\|tracked_at\|res://" tools/*.py` —
only `autoload_tracked_check.py` (and now `harness_check.py`, which imports it for the new test
cases) does git-blob-tracked-at-rev checking. The repo's other `tools/*_check.py` files
(`godot_prepass_check.py`, `import_cache_guard_check.py`, `png_pixels_equal_check.py`) verify
unrelated mechanisms (import ordering, cache-lock interop, pixel-identical reproduction) and are
already wired into the checks that use them — no other "a checker exists but nothing calls it
pre-commit" instance found.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-206 · `build_gatherable_plants.py` (A-011) has six `bevel=` sites with no local override — the same D-124 exposure, latent rather than live

**Claim:** `tools/blender/build_gatherable_plants.py`, `assets/gatherables/catalog.json`,
`assets/gatherables/exports/*.glb` (10), `assets/gatherables/preview/*.png` (3),
`assets/source/gatherable_plants.blend`, `docs/ASSET_TRACKER.md`, `docs/FINDINGS.md`,
`docs/SPECS.md`, `docs/DELEGATION.md`. No networked system — pure offline art tooling.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause / what's missing:** F-198's own sweep found this exact gap — `build_gatherable_plants.py`
imports `box` straight from `mire_art` and calls it with `bevel=` at six sites (terrain path, peat
bank, and four plant/deposit details) with no local override — but filed it as F-206 instead of fixing
it there, because A-011's `docs/ASSET_TRACKER.md` row made no byte-identical-rebuild claim at the time,
so D-124's trigger condition wasn't met: today's row still isn't a live violation. `docs/DELEGATION.md`'s
F-198 entry named this explicitly as "for whoever adds that claim to A-011 later."

**Decision made here:** rather than leave the gap open until some future task happens to add that
claim, fix it now — the mechanical cost is identical either way (one override, one rebuild, one
`asset_repro_check.py` run) and doing it here converts a standing "must remember to fix this later"
trap into nothing, rather than leaving it for a task that has no reason to know it's expected of them.
Since the rebuild already proves determinism, this task also adds the byte-identical claim to A-011's
row, bringing it in line with A-012's — there is no reason to prove determinism and then not record it.

**Fix:** added a local bevel-free `box()` override to `build_gatherable_plants.py` (same shape as
`build_ward_set.py`'s and every other family's — `assign()` the cube, no `BEVEL` modifier, `bevel`
kwarg accepted and ignored so all six call sites read unchanged). Rebuilt clean.

**Verified 2026-08-19:** `agent claim` the generator plus every generated file it writes (exports,
catalog, previews, source `.blend`) before editing. Standalone rebuild —
`/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/build_gatherable_plants.py` — gives `GATHERABLES_CHECK PASS`, 10/10 assets, triangle
total 5,472 → 5,184 (chamfers square off, D-124's accepted tradeoff), every catalog dimension
unchanged at 3-decimal precision. `python3 tools/blender/asset_repro_check.py --script
tools/blender/build_gatherable_plants.py --export-dir assets/gatherables/exports --catalog
assets/gatherables/catalog.json --label A-011` → byte-identical GLBs and catalog across two clean
separate-process rebuilds (10/10). `agent godot --script tools/gatherables_check.gd` → 41 assertions,
0 failures, clean. `docs/ASSET_TRACKER.md`'s A-011 row carries the new triangle count and the
byte-identical claim.

**Swept for the same shape elsewhere (AGENTS.md §3):** `grep -rln "bevel=" tools/blender/build_*.py`
found six callers total (`build_crafting_stations.py`, `build_enemy_crawler.py`,
`build_gatherable_plants.py`, `build_loot_set.py`, `build_tool_weapon_set.py`, `build_ward_set.py`);
cross-checked each for a local `def box` override — all six now have one. This was the last gap of
this exact shape in the repo.

**Resolved** — see `docs/FINDINGS.md`.

---

## 8.4 · Depots, build pipeline, `steamcmd` upload script, branches ✅ shipped — see DELEGATION

No block existed here beforehand; this task wrote one per SPECS.md's own preamble. **Task 8.1
(Steamworks account/$100 fee/real App ID) and 8.2 (App ID swap) have not run** — `.agent/state.json`
still shows both `todo` — so there is no real App ID or Steamworks depot set to wire up yet. This
task therefore builds the pipeline generically, against placeholders, ready for 8.2/8.11 to fill in.
**8.11 ("three depots wired to one app, per-platform launch options") is the task that puts real IDs
in and sets launch options in the Steamworks web dashboard — this task does not overlap it.**

**Authority:** none (`ARCHITECTURE.md` §2.2) — this is offline build/release tooling, not a
networked runtime system. Nothing here runs inside the game process.

**Claim:** `export_presets.cfg` (Godot-authored, exact claim, editor closed — D-031), `.gitignore`,
`tools/steam/steam_build_config.sh`, `tools/steam/export_release.sh`, `tools/steam/steam_upload.sh`,
`tools/steam/templates/{app_build,depot_windows,depot_macos,depot_linux}.vdf.template`.

**Release export presets:** three new presets in `export_presets.cfg` — `"macOS (Release)"`,
`"Windows Desktop (Release)"`, `"Linux (Release)"` (`preset.3`/`.4`/`.5`) — deliberately a
near-duplicate of the existing three debug presets rather than a flag-swap on the same preset
object, so debug export behaviour is untouched. The one substantive diff: `exclude_filter=
"steam_appid.txt"`, satisfying D-022's "must not ship in a release build." **Verified empirically
that this is defense in depth, not the load-bearing fix:** exporting either a debug or a release
preset never emits a `Storing File: res://steam_appid.txt` line in the first place — Godot's
`all_resources` export filter does not pick up a bare non-imported `.txt` sitting at the project
root, so the file was never packed into any `.pck`, debug or release, before this task either.
Output lands in `export/release/<platform>/`, parallel to the existing gitignored `export/`.
macOS codesign/notarisation stays ad-hoc/unset (same as the debug preset) — real signing is task
8.10's job, gated on an Apple Developer account that doesn't exist yet.

**Build script:** `tools/steam/export_release.sh` — `--export-release` for all three platforms,
always through `agent godot` (F-044's shared import-cache lock).

**steamcmd upload pipeline:** `tools/steam/steam_build_config.sh` is the single source of the four
Steam identifiers (`STEAM_APP_ID`, `STEAM_DEPOT_WINDOWS/MACOS/LINUX`, `STEAM_BRANCH`) — all still
task 8.4's placeholder values (`480`/`0`/`0`/`0`/`"internal-beta"`) until 8.2/8.11 land. `.vdf`
templates live in `tools/steam/templates/` with `@TOKEN@` placeholders; `steam_upload.sh` renders
them into `tools/steam/generated/*.vdf` (gitignored — a stale render is worse than no render) and
runs `steamcmd +login <user> +run_app_build <rendered app_build.vdf> +quit`.

**Branches (S4's "password-protected beta branch"):** `steamcmd`/steampipe VDFs have no field for a
branch *password* — that's set once in the Steamworks web dashboard (App Admin → Builds → Steam
Pipeline → Branches), not scriptable from this repo. What this task's script DOES own: which branch
a given upload's `SetLive` targets, and refusing to ever target `"default"` (the public branch)
unless `STEAM_ALLOW_PUBLIC=1` is explicitly set — an accidental public Steam release is a
hard-to-reverse action worth a guard clause, not just a doc note.

**Verify:** `bash -n` on all three scripts. All five of `steam_upload.sh`'s guard clauses fire, in
order, against deliberately-wrong inputs: placeholder `STEAM_APP_ID` (480) → refuses; real App ID
but placeholder depot IDs (0) → refuses; `branch=default` with no override → refuses; no Steam
username → refuses; `steamcmd` missing from `PATH` → refuses with an install pointer. With a fake
`steamcmd` stub on `PATH`, real App ID/depot IDs, a non-default branch and a username, the script
renders all four templates with the correct substituted values (checked by `cat`), invokes the stub
with the expected `+login <user> +run_app_build <path> +quit` argument line, and every template's
relative `ContentRoot`/depot-file path resolves correctly from `tools/steam/generated/` back to the
repo root and `export/release/<platform>/` (checked with `realpath`/`ls -d`). Real exports: `agent
godot --headless --export-release` succeeded for all three platforms; the macOS release binary was
smoke-run headless (`--quit-after 15`) and logged a fully-loaded `AUTHORED_WORLD` (props=2880,
harvestable=1156) with 0 `ERROR:` lines, the same bar `DELEGATION.md`'s existing debug-build smoke
test uses.

**Swept for the same shape elsewhere (AGENTS.md §3):** grepped the repo for any existing
`steamcmd`/`depot`/`.vdf` tooling before writing this — none existed (confirmed against
`docs/DELEGATION.md`, `docs/FINDINGS.md`, `docs/DECISIONS.md`, and a repo-wide `find`), so there was
no sibling instance of this gap to fix. This task is new tooling, not a bug fix, so the sweep found
nothing to widen.

**Done means:** the three release presets export cleanly and boot with real content loaded, the
upload script's guard clauses all verified against a fake `steamcmd`, and `docs/DELEGATION.md`'s
*Current state* carries the placeholder values and file layout task 8.2/8.11 build against.

**Explicitly NOT this task:** real App ID/depot IDs (8.2/8.11 — they don't exist yet), macOS
codesign/notarisation (8.10), setting a branch's actual password (Steamworks web dashboard only,
no CLI/VDF surface exists for it), per-platform Steam launch options (8.11).

---

## F-211 · Task 8.4's work order named the wrong verification scripts — `build_check.gd`/`build_net_check.gd`/`buildable_content_check.gd` test the buildable/crafting placement system (task 3.6/3.7), not the Steam export build pipeline

**Claim:** `.agent/bin/agent`. No networked system, no `ARCHITECTURE.md` §2.2 row — this is offline
director tooling, not game code.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Root cause — not a one-off authoring slip:** `agent order` generates the "Verify it yourself,
headless" section from `checks = _spec_verify(spec) or _suggest_check(tid, t["title"])`
(`.agent/bin/agent:2307`); 8.4 had no `docs/SPECS.md` block yet at dispatch time, so it fell to
`_suggest_check()` (`.agent/bin/agent:1906`), which scores each `tools/*_check.gd` by fuzzy-matching
the task title's words against the filename's underscore-split parts and suggests any file scoring
`>= 2` — a deliberate noise floor, per its own comment: "one shared word is noise, not a match." The
bug: it counted matching WORDS, not distinct PARTS. 8.4's title contains both "build" and "builds" —
two different tokens in `_tokens()`'s dedup set — and both fuzzy-match the single part `"build"`. One
real signal doubled itself past the `>= 2` floor and pulled in `build_check.gd`, `build_net_check.gd`
and `buildable_content_check.gd`, whose actual subject (task 3.6/3.7's in-game buildable/crafting
placement system) shares nothing with 8.4's Steam export pipeline but the word "build" itself.

**Decision made here:** fix the heuristic rather than leave this as "a one-time work-order-authoring
trap" (the finding's own first-pass read, filed before the generator's source was traced) — it is a
reachable bug in shared dispatch tooling that every future `agent order` call goes through, not a
mistake by whoever wrote 8.4's order text (nobody wrote it by hand; `agent order` generated it). Any
task with no SPECS.md block yet, whose title contains a word alongside its own plural/inflected form,
was exposed to the identical false match.

**Fix:** `_suggest_check()` now scores by the number of DISTINCT PARTS matched, not the number of
matching words — a filename is suggested only when at least two of its own underscore-split parts
each find independent evidence in the title, so two spellings of the same word (build/builds,
command/commands, session/sessions, craft/crafting, ship/shipwreck, unlock/unlocked, …) can satisfy
at most one part between them and can no longer manufacture a second, fake one.

**Verified:** loaded `.agent/bin/agent` as a module and called `_suggest_check("8.4", <8.4's real
title from .agent/state.json>)` directly — returns `[]` instead of the three wrong scripts. Ran both
the old and new scoring logic against every title in `.agent/state.json` (344 tasks + findings): 29
titles changed. Read all 29 diffs by hand — every dropped suggestion traces to the identical
single-word-doubling bug, including cases with zero code relevance (0.12, a pure orchestration-harness
task, was suggesting `lan_launch_check.gd`; 8.1, a Steamworks-account/paperwork task with no code
component at all, was suggesting `steam_check.gd`). None of the 29 diffs dropped a suggestion the
title gave genuine two-part evidence for — where a title does name two distinct check-name parts
(3.16's "catalog", F-68's "spawner", F-179's "stringname"/"sort"), that check is still suggested.
`python3 -c "import ast; ast.parse(open('.agent/bin/agent').read())"` → syntax OK. No `agent godot`
check applies: this is pure offline director tooling with no game-engine surface, and running the
three scripts this finding is *about* would repeat 8.4's exact mistake rather than verify the fix.

**Swept for the same shape elsewhere (AGENTS.md §3):** grepped `.agent/bin/agent` for the same
per-word (rather than per-distinct-signal) scoring pattern (`hits >=`, `sum(1 for`) — `_suggest_check()`
was the only site with this shape. The 344-title sweep above stands in for "fix the siblings": there
was one code path, already fixed, whose effect had silently shown up in 29 places.

**Resolved** — see `docs/FINDINGS.md`.

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

---

## F-165 · Task 6.5's two new extraction RPCs shipped with no `PROTOCOL_VERSION` bump — `net_version.gd` was held all session by another lane's claim

**Claim:** `core/net/net_version.gd`, `tools/handshake_check.gd` — claimed to hold them stable while
verifying, but neither needed an edit; see below. Network authority: none of its own (infrastructure,
not simulated state) — `core/net/net_version.gd`'s own header already states the one authority fact
that matters, that the host is the arbiter of a version mismatch.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Turned out already fixed on disk.** F-161 (task 5.3), F-165 (task 6.5, this one), F-169 (task 6.7)
and F-178 (F-157) are the same omission four times over — `net_version.gd`/`handshake_check.gd` held
by lane slate17's task 3.7 claim across all four sessions, so each shipped its RPCs un-versioned and
filed a finding instead (D-100/D-102/D-120 cover why that was an acceptable transient risk). Between
F-165 being filed and this task picking it up, hollow7's F-161 session fixed all four in one pass:
`PROTOCOL_VERSION` 20 → 21 (folded into one bump rather than four retroactive numbers, because the
intermediate versions never existed as a build anyone ran), `net_version.gd`'s `## 21` history block
naming all four RPC sets by task, `handshake_check.gd`'s assertion raised to match, and a new
mechanism — `core/net/rpc_manifest.gd` + `tools/rpc_manifest_check.gd` — that scans every `@rpc` in
game code into one canonical signature and fails when the wire surface moves without `PROTOCOL_VERSION`
moving with it, so a fifth omission is a red check instead of a fifth finding. D-133 records that
decision.

**What was actually left for this task:** hollow7's own close-out said so explicitly — "DOCS NOT
WRITTEN: lm holds docs/DECISIONS.md and docs/DELEGATION.md for F-183 for the whole session." F-183
closed two minutes after F-161's `done`, so both files were free again by the time this task started.
The remaining work was the bookkeeping close: record D-133, add the manifest API to DELEGATION.md
*Current state*, and move F-161/F-165/F-169/F-178 to `## Resolved` — `docs/FINDINGS.md`'s own board
had flagged F-161 as DONE-in-state-but-still-Open, exactly this drift.

**Verified (this task, independently, not just trusting hollow7's note):**
`agent godot --script tools/handshake_check.gd` → 0 failures, `PROTOCOL_VERSION == 21` assertion
passes, real two-peer ENet hello/reject exchange passes both the matching- and mismatched-version
cases. `agent godot --script tools/rpc_manifest_check.gd` → `RPC_MANIFEST_CHECK failures=0`, 55 RPCs
scanned, signature and count both match `RECORDED_SIGNATURE`/`RECORDED_ENTRY_COUNT`. That check is
itself the sweep for a fifth un-bumped RPC (AGENTS.md §3) — a mechanical PASS stands in for a manual
grep across the whole `@rpc` surface.

**Swept for the same shape elsewhere:** the four un-bumped-RPC findings *are* the "same shape
elsewhere" this sweep would have found — already folded into one fix by hollow7. One new, unrelated
bug surfaced while verifying: `rpc_manifest.gd`'s FNV-1a seed literal overflows signed 64-bit int and
prints engine `ERROR:` lines on every run (though the check's PASS/FAIL is unaffected, since the error
is deterministic). Filed as F-213 rather than fixed here — it's a distinct defect in code this task
didn't write, and re-deriving `RECORDED_SIGNATURE` deserves its own verification pass, not a rider on
a bookkeeping close-out.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-166 · `world/gen/authored_world.gd` has no `shipwreck` marker kind, so task 6.5's ExtractionShip is built but never reachable in the live Hollowmere map — same shape as F-146's chest gap

**Claim:** `world/gen/layouts/hollowmere.json`, `tools/hollowmere_check.gd`. The finding names
`world/gen/authored_world.gd` as the file to hold, but that script only *reads* `markers` out of the
layout — the actual data lives in `world/gen/layouts/hollowmere.json`, and that is the file the fix
edits. Network authority: none — `authored_world.gd` builds identically on every peer (D-023's usual
determinism argument for world gen), and `autoload/extraction_service.gd`'s own header already states
the bridge it feeds has no authority of its own either.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Fix — one marker, not a code change.** `autoload/extraction_service.gd` was already correct; it
just had nothing to find. The layout already carried the evidence for exactly where: an `"Extraction"`
landmark marker (`kind: "extraction"`, used only as a UI/label requirement by
`tools/hollowmere_check.gd`'s `_check_markers`, not consumed by any live-object bridge) sits at
`MereShore [62.0, 1.54, 29.0]`, and the props array already has a whole authored dock built around
that exact point — four `extraction pad`s in a square, plus `extraction cache`/`ward`/`rail`/`markers`
— with no gameplay object ever placed on it. That is task 6.5's own unfinished half. Added one new
marker, `{"name":"Shipwreck","kind":"shipwreck","zone":"MereShore","pos":[62.0,1.54,29.0]}`, at the
same point — `extraction_service.gd` picks it up automatically, no gameplay-side change needed, same
recipe `wellspring_service.gd`'s `"objective"` marker already proves. Edited the (minified, single-
line) JSON with a small Python script rather than hand-editing 550 KB of text on one line.

**Second gap the check surfaced, not in the finding text.** Building the real `ExtractionShip` at
that marker for the first time exposed that `tools/hollowmere_check.gd`'s `_probe_ground` — which
drops random rays and compares against the authored heightfield — only excludes hits on colliders in
the `authored_world_prop` group. `ExtractionShip._build_collision()` (and `Wellspring._build_collision()`,
same shape, same latent gap, never tripped because no probe happened to land on it) drop a solid
`StaticBody3D` on top of the terrain at runtime, built by a bridge service rather than the layout, so
neither is in that group. A probe landing on the new ship's hull read as a 3.9 m collision error and
failed the check. Fixed by skipping any hit whose collider's parent is in `&"wellspring"` or
`&"extraction_ship"` — the same groups those two `_ready()`s already call `add_to_group()` with — right
alongside the existing `authored_world_prop` skip.

**Verify:** `.agent/bin/agent godot --script tools/hollowmere_check.gd` → `HOLLOWMERE_MARKERS` now
includes `"shipwreck": 1`, new `HOLLOWMERE_SHIPWRECK marker=Shipwreck ship_built=true` line (added to
the check specifically to prove the bridge fires against the *real* map, not just
`tools/extraction_check.gd`'s synthetic marker), `HOLLOWMERE_GROUND … worst_delta=0.000 m`,
`HOLLOWMERE_CHECK PASS`. `.agent/bin/agent baseline --script tools/hollowmere_check.gd` against HEAD
confirms the pre-fix state passed too (the ground-probe gap was invisible until this task's own
marker gave it something to hit) — not a regression this task introduced into a previously-red check.
`.agent/bin/agent godot --script tools/extraction_check.gd` still `failures=0`, unaffected.

**Swept for the same shape elsewhere:** the other two marker-fed bridges in `autoload/` —
`chest_placement_service.gd` (`"loot"`, F-146) and `wellspring_service.gd` (`"objective"`) — both
already have markers in `hollowmere.json`; neither has this gap. `world/gen/layouts/playtest_hollow.json`
has no `"shipwreck"` marker either, but `wellspring_service.gd`'s own header already documents that
map as deprecated for new content (it predates POI placement) and it is not the map the live game
ships, so it was left alone.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-209 · No menu in the game supports gamepad UI focus navigation — a bare controller with no Steam Input translation cannot open any panel

**Claim:** `ui/menu/main_menu.gd`, `ui/menu/settings_menu.gd`, `ui/menu/unlock_menu.gd`,
`ui/lobby/lobby_menu.gd`, `ui/inventory/inventory_ui.gd`, `ui/crafting/crafting_ui.gd`,
`tools/menu_focus_check.gd`, `tools/bind_ui_gamepad_actions.gd`, and `project.godot` (claimed by
name, D-021 — appended two new `[input]` entries, not exact-claim). `ui/loot/chest_ui.gd` was
deliberately NOT touched — see below. Network authority: none for every file above — all client-local
UI (the authority table's free last row), matching each file's own existing header.

**No spec existed for this finding** — writing it is this task's own first step, per this file's preamble.

**Real gap #1 (the finding's own ask): every menu lacked initial focus and a `focus_neighbor_*`
chain.** None of the seven set an initial `Control` focus on open or wired `focus_neighbor_*`/
`focus_next`/`focus_previous`, so a D-pad press had nothing on screen to move between even though the
underlying actions carried joypad bindings. Fixed identically in five files (MainMenu/SettingsMenu/
LobbyMenu/CraftingUI/UnlockMenu): `set_open(true)` now calls `grab_focus()` on the first interactive
control, and every Button/LineEdit/OptionButton/HSlider/CheckBox got `focus_neighbor_top`/`_bottom`
(and, where a row has a horizontal sibling — MainMenu's SET, LobbyMenu's PASTE/JOIN — `_left`/
`_right`) wired via a small `_wire_vertical_chain(controls: Array)` helper duplicated per file
(matching this codebase's existing per-file `_button()`/`_panel_style()` duplication rather than a
shared base class). Dynamic row lists (SettingsMenu's keybind/gamepad-bind rows, CraftingUI's
per-station recipe rows) rewire the chain every time the row list rebuilds, not just once at
`_build_ui()` time. A visible focus ring — none of these controls overrode the engine default focus
style, easy to miss against the dark panel background — is a `StyleBoxFlat` with `bg_color` alpha 0
and a bright accent border, applied via `add_theme_stylebox_override("focus", ...)`; Button-derived
controls (Button/OptionButton/CheckBox) and LineEdit draw this natively — `HSlider` does not, filed as
F-215 rather than solved here, since a slider is still fully operable by gamepad without one.

**InventoryUI is the one file that needed something more than the chain.** Its 24-slot grid (8 or 6
columns depending on `_apply_layout_for_width`'s responsive breakpoint) and its 8-slot hotbar live in
two separate container trees, so Godot's automatic geometric neighbor search has no guarantee of
picking the intended row/column across that boundary — wired explicitly instead, in
`_wire_focus_neighbors()`, re-run every time the column count can change. `INVENTORY_SLOT_COUNT` (24)
divides evenly by both column counts, so there is no ragged last row to special-case. Its drag-and-drop
slot move (`_get_drag_data`/`_drop_data`) has no keyboard/gamepad equivalent at all — added a
pick-up-and-drop flow: `ui_accept` on an occupied `InventorySlot` "picks it up"
(`InventoryUI._on_slot_activated` tracks `_carrying_index`, exposed as `carrying_slot_index()` for
checks), `ui_accept` on a different slot drops it there through the same `request_slot_move()` a mouse
drop already used, `ui_accept` on the same slot cancels. A carried slot gets its own persistent
highlight (`COLOUR_CARRY`), independent of focus (the source slot usually isn't focused any more by
the time you navigate to the destination and drop).

**Real gap #2, not in the finding text: `ui_accept`/`ui_cancel` carry NO gamepad binding in this
Godot version at all.** D-131 (which scoped this finding out of task 7.6) and the finding itself both
assumed "Godot's default `ui_up`/`ui_down`/`ui_accept`/`ui_cancel` actions already carry joypad D-pad/
A-button bindings out of the box" — true for the four direction actions (confirmed live via
`InputMap.action_get_events()`: D-pad buttons 11–14 plus the left stick), **false** for
`ui_accept`/`ui_cancel`, which ship with only Enter/Kp Enter/Space and Escape respectively. Every
`focus_neighbor_*` chain in this task would have been reachable by D-pad but nothing on it activatable
or cancelable by a bare controller without this. Fixed in `project.godot` by
`tools/bind_ui_gamepad_actions.gd`, a one-shot script (not a recurring check — same reasoning
`setup_project.gd`'s own header gives for scripting an input-map write rather than hand-editing the
Resource literal) that reads each action's CURRENT event list via `InputMap.action_get_events()`,
appends a `JOY_BUTTON_A`/`JOY_BUTTON_B` event, and writes back through `ProjectSettings.set_setting()`
+ `.save()` — idempotent, so re-running it is harmless. `JOY_BUTTON_A` is already bound to this
project's own `jump` action too; that overlap is inert while a blocking UI owns GUI focus (the
Viewport consumes the event via the focused Button's `gui_input` before it ever reaches
`_unhandled_input`, the same reason clicking a menu button never also fires `jump` today) and is not
something this task changed.

**`ui/loot/chest_ui.gd` needed no change.** Re-reading it against the finding's own claim that all
seven "still require a real mouse click to open, select an item, or close": ChestUI has no interactive
`Control` at all — no buttons, nothing to drag, only a title, non-interactive reward rows, a status
label, and a close hint. `[E]` (the `interact` action, already gamepad-bound) opens it, `[E]`/`[Esc]`
(both already gamepad-bound) close it. There was nothing to wire.

**Verify:** `.agent/bin/agent godot --script tools/menu_focus_check.gd` → `MENU_FOCUS_CHECK
failures=0`. Drives real `InputEventJoypadButton` presses through `Input.parse_input_event()` (not a
node's own `_input()`/`_gui_input()` the way `gamepad_check.gd` drives gameplay actions — focus
movement on `ui_up`/`down`/`left`/`right` is not something any of these panel scripts implement, it is
Godot's own Viewport GUI input handling walking `focus_neighbor_*`, so the only way to prove it works
is the real pipeline) for every menu: initial focus on open, a closed-loop D-pad walk through the full
chain with no dead-end/short-loop, a functional `ui_accept` press (SET stages a seed, a CRAFT button
actually crafts, an `InventorySlot` actually picks up and drops), and an `HSlider`'s `ui_left`/`right`
actually moving its value. Also reran the pre-existing `tools/gamepad_check.gd`,
`tools/main_menu_check.gd`, `tools/lobby_menu_check.gd`, `tools/settings_check.gd`,
`tools/inventory_ui_check.gd`, `tools/crafting_ui_check.gd`, `tools/unlock_check.gd` — all green,
confirming the focus/pick-up-and-drop additions didn't regress the mouse/keyboard paths those checks
already prove.

**Swept for the same shape elsewhere:** grepped every `ui/**/*.gd` for `Control.new()`/`Button.new()`/
`OptionButton.new()`/`HSlider.new()`/`CheckBox.new()`/`LineEdit.new()` outside the six touched files.
Found two real siblings this task did not claim and so filed rather than fixed: F-216
(`ui/attunement/attunement_ui.gd`, task 3.9's mandatory run-start role picker — real Buttons, no
gamepad focus support, and by its own header comment no Esc/dismiss path at all, which makes it
*worse* than this finding's own scope) and F-217 (`ui/building/build_bar.gd`'s `PieceSlot` — mouse-
click-only piece selection; build mode itself already toggles via gamepad since task 7.6). Also
grepped `focus_neighbor\|grab_focus` project-wide beforehand — the only pre-existing hits were
`debug_console.gd` (dev console, out of scope) and `lobby_menu.gd`'s own pre-existing
`_join_field.grab_focus()`, confirming no other file already had partial wiring to reconcile with.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-210 · `Chest`'s loot roll still seeds from boot-time `randomize()` even though `GameState.run_seed` now exists — D-041's own reversal trigger has fired

**Claim:** `systems/loot/chest.gd`, `tools/chest_seed_check.gd` (new). Network authority: HOST, same
row `chest.gd`'s own header already declares — this task changes what feeds the roll's RNG, not who
rolls it.

**No spec existed for this finding** — writing it is this task's own first step, per this file's preamble.

**The fix:** `Chest._ready()` called `_rng.randomize()` (real boot-time entropy) unconditionally on
the host. D-041 (2026-08-17) chose that deliberately as a **provisional** stand-in, and named its own
exact reversal trigger: "the moment a real per-run seed authority exists ... `Chest` should switch to
deriving its seed from `(run_seed, a stable per-chest id)` instead of `randomize()`." Task 4.6 shipped
that authority (`GameState.run_seed`) on 2026-08-18; nobody wired the two together until now. `_ready()`
now calls `_rng.seed = _seed_for_run(_run_seed(), String(name))`. `_run_seed()` reads
`GameState.ensure_seed()` through `get_node_or_null(^"/root/GameState")` (GameState is a project-wide
autoload — no null path exists in the shipped game, only a defensive `return 0` for a hypothetical
scene missing it). The stable per-chest id is the chest's own `name`: `ChestPlacementService`
(`autoload/chest_placement_service.gd:98`) already sets `chest.name = "Chest_%s" % marker.name` from
the authored map layout **before** `add_child()`, so it is fixed, deterministic, and identical on
every peer — never generated, never dependent on load order. `_seed_for_run(run_seed, chest_id)` mixes
the two with integer multiply/xor only (never Godot's `hash()`, whose cross-platform/cross-version
stability for `String`/`StringName` is not a documented guarantee) — the exact convention
`world/gen/poi_map.gd`'s `_kind_seed()`/`_hash_id()` and `world/gen/resource_scatter.gd`'s
`_point_seed()`/`_hash_id()` already established for the same reason; `_SEED_SALT: int = 0xC4E57`
keeps this file's mix distinct from those two files' own salts (`0x9017A11`, `0x5CA77E5`).
`Chest.host_seed_rng(seed_value)` — the existing debug/test override seam D-041's own text pointed
at — is untouched; every existing check that calls it (`chest_check.gd`, `loot_content_check.gd`)
still overrides the seed explicitly after `_ready()` runs, so this change does not alter their
behavior.

**Not a desync/correctness bug, then or now** — the roll is host-only and granted directly, so no
peer ever needs to agree on the value, only the host's own two runs sharing a `run_seed` need to agree
with EACH OTHER. What changes is reproducibility: a deliberate replay, a bug-repro `--seed=` launch
(`core/game_state.gd`'s `_apply_launch_seed_arg()`), or F-172's solo seed entry now gets the same
chest loot every time instead of a fresh roll from real entropy.

**Verify:** `.agent/bin/agent godot --script tools/chest_seed_check.gd` → `CHEST_SEED_CHECK
failures=0`, zero undeclared `ERROR:` lines. New check (same synthetic-Registry-injection pattern
`tools/chest_check.gd` already uses — content stays hand-authored, this only proves the framework):
builds real `Chest` nodes under fixed names via `CHEST_SCRIPT.new()` + `root.add_child()`, forces a
specific `run_seed` with `GameState.set_replicated_seed()`, opens them offline (host-of-one, same path
`chest_check.gd` proves), and checks granted loot from a wide (1..999) amount range: same
`(run_seed, chest name)` grants identically twice; changing either the name or the `run_seed` changes
the grant. `remove_child()` + `free()` (not `queue_free()`) between spawns reusing the same name — a
still-pending deferred free would make the next `add_child()` silently uniquify the name instead of
reusing it, which would quietly break the "same id" premise the check exists to prove.

**Swept for the same shape elsewhere:** grepped every `.randomize()` call site project-wide.
`autoload/inventory_service.gd:599` is an intentional exception, commented in place ("a debug roll
must never advance a run's shared or world-gen streams" — the console `loot` command).
`autoload/entity_directory.gd:57` seeds a cosmetic entity-id/tag RNG with no reproducibility claim on
it anywhere. Two real siblings found and filed rather than fixed (outside this task's claim, and each
needs its own id-derivation design rather than a copy-paste of `_seed_for_run`): F-219
(`autoload/reward_service.gd:76`, `RewardService`'s Wellspring-cap/boss-kill party loot roll — no
placement id to key off, needs a per-run reward-event counter) and F-220
(`systems/cycle/cycle_modifier_service.gd:56`, `CycleModifierService`'s per-cycle modifier draw —
already has `cycle: int` as a ready-made stable id, so its fix is close to mechanical).

**Resolved** — see `docs/FINDINGS.md`.

---

## F-212 · `ARCHITECTURE.md` §5 still describes the Mire grid's replication as a bespoke batched `PackedByteArray` RPC — task 4.9 shipped a different, permanent mechanism and never updated it

**Claim:** `docs/ARCHITECTURE.md` only — docs are exempt from claims (F-006). No code, no check to
run: this finding is a stale doc, not a stale behavior. `world/mire/mire_grid.gd`'s own header
already describes the real mechanism correctly, and every runtime consumer already reads it right.

**No spec existed for this finding** — writing it is this task's own first step, per this file's preamble.

**The fix:** `ARCHITECTURE.md:203-204` said Mire replication batches changed `(index, value)` pairs
into a `PackedByteArray` RPC. Task 4.9 shipped `WorldDeltaLog.host_record(chunk, kind, key, value)`
(task 4.6's generic per-cell-keyed-by-chunk log) instead, once per changed cell, never a bespoke byte
array — D-099 (2026-08-18) records why and is explicit that this is permanent, not provisional:
"there is no future world in which a bespoke RPC becomes the better answer" (a new RPC pair needs a
`PROTOCOL_VERSION` bump in `core/net/net_version.gd`, which was held by another lane's claim the whole
session 4.9 shipped, and `WorldDeltaLog` was the strictly better fit regardless of file availability).
§5's replication bullet now names `WorldDeltaLog.host_record()`, same shape as the sentence D-099
already wrote once, and states clients only ever read corruption back through the replicated log.

**Verify:** read-only — confirm `docs/ARCHITECTURE.md` §5 no longer mentions `PackedByteArray` and
matches `world/mire/mire_grid.gd:3-19`'s doc comment and D-099's own text.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-218 · Decisions write their own reversal triggers and nothing ever re-checks them — two fired unnoticed in one session

**Claim:** `tools/decision_trigger_check.py` (new). No network authority row — this is a docs/process
tool, not a runtime system.

**No spec existed for this finding** — writing it is this task's own first step, per this file's preamble.

**The fix:** every `docs/DECISIONS.md` entry ends with a **Would change my mind:** clause and nothing
ever re-read them, so a fired trigger sat unnoticed until an agent tripped over its consequence by
accident — D-011's (file claims becoming a bottleneck, caught by F-189) and D-041's (a real per-run
seed authority existing, caught by F-210). The finding itself ranked a mechanical check above "just
surface everything in `agent start`" because most trigger clauses are prose judgement calls with no
concrete referent (D-011's "often enough" among them) — genuinely not automatable. The buildable
subset is the one D-041 is: a clause naming a concrete symbol or file. `tools/decision_trigger_check.py`
parses every `### D-0NN` heading and its trigger clause, pulls backtick-quoted tokens out of the
clause, and for each resolves where it's actually *declared* in the tracked tree today — a
`class_name`/`func`/`signal`/`const`/`var` line in a script, or a `Name="*res://..."` autoload
registration in `project.godot` (autoload singletons like `GameState` are never `class_name`'d, so
this second shape is required — the first version of this check missed D-041 entirely without it).
A plain grep-for-mentions was tried first and rejected: `MultiMesh`/`SceneReplicationConfig`/
`ConcavePolygonShape3D` are Godot engine types referenced as parameter/return types in a dozen
scripts since day one, and would have fired on nearly every decision that names an engine class —
only a declaration site is real evidence the *codebase* introduced something new. If the resolved
declaration's earliest commit postdates the decision's own heading date, the trigger has mechanical
evidence it fired. A decision annotated `*Superseded by ...*`, `*Amended by ...*`, or `*Reviewed
...*` right under its heading is skipped — this task adds `*Reviewed <date> — <why>.*` as a new
one-line convention (alongside the retro-edit markers the file's preamble already permits) so a fired
trigger that's still the right call can be silenced without rewriting the reasoning body, instead of
re-flagging forever on every future run.

Running it cold against the real `docs/DECISIONS.md` found exactly one live case: D-041, the finding's
own worked example. It has since been annotated `*Reviewed 2026-08-19*` (this task) recording that
F-210 already did the switch D-041's trigger asked for, so a re-run now reports `fired=0`.

**Verify:** `python3 tools/decision_trigger_check.py --self-test` → `7/7 passed`, exit 0. Builds a
throwaway repo (same pattern as `tools/harness_check.py`/`tools/autoload_tracked_check.py`) with five
synthetic decisions covering every branch: a `class_name` symbol added after its decision (must
FIRE), one that predates its decision (must NOT), a prose-only trigger with no backtick token (not
mechanically checkable — must NOT), a fired trigger already annotated `*Reviewed ...*` (must NOT
re-fire), and a `project.godot` autoload registration added after its decision (must FIRE — the
D-041/`GameState` shape). `python3 tools/decision_trigger_check.py` (no flag) scans the real
`docs/DECISIONS.md` and prints `DECISION_TRIGGER_CHECK decisions=135 checkable=57 fired=0`.

**Not wired into `agent start`.** The finding ranked the standalone mechanical check above that
fallback, and a real-repo timing run came back at ~5s (multiple `git log`/`git grep` calls per
backtick token across 57 checkable decisions) — a tax on every session across every lane, for a
signal that changes only when `docs/DECISIONS.md` or the source tree changes. Run it by hand
periodically, or whenever a task's own work touches `docs/DECISIONS.md`.

**Swept for the same shape elsewhere:** grepped `tools/*.py` and `.agent/bin/agent` for the same
markdown-heading-parsing bug this task's own first draft had (a regex that matches only the heading's
*prefix* — `### D-\d+ · date` — then reads body from `match.end()`, which lands mid-title-line rather
than at the next newline, so a `*Reviewed ...*`-style marker on the line right under the heading is
silently never seen). `.agent/bin/agent`'s `_self_resolved_findings()` parses `### F-\d+` headings the
same general way but captures the *whole* line (`^(### F-\d+ · .+)$`) before splitting, so it does not
have this exposure. No other file in `tools/` parses markdown headings by regex at all. No sibling
instances found.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-219 · `RewardService`'s Wellspring/boss-kill loot roll is the same boot-time-`randomize()` bug F-210 just fixed in `Chest`

**Claim:** `autoload/reward_service.gd`, `tools/reward_service_seed_check.gd` (new). Network
authority: HOST, same "Event-granted loot" row `docs/ARCHITECTURE.md` §2.2 already declares — this
task changes what feeds the roll's RNG, not who rolls it.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**The fix:** `_grant_tier_to_party()` created one `RandomNumberGenerator` per trigger and called
`.randomize()` on it (real boot-time entropy), shared across every present peer's roll. `Chest` had
an obvious stable id to seed from instead (its own node `name`, authored by
`ChestPlacementService`) — a Wellspring cap / boss kill has no placement, so this task mints a
different id: a monotonic per-run counter (`_next_reward_event_id`), incremented once per trigger
call, combined with the receiving peer's id so two peers' independent rolls from the SAME trigger
never coincide. Each peer now gets its own `RandomNumberGenerator`, seeded with
`_seed_for_run(_run_seed(), "%s:%d:%d" % [tier, event_id, peer_id])` — `_seed_for_run()`/`_run_seed()`
are direct copies of `Chest`'s own (own `_SEED_SALT = 0x9E3779B9`, distinct from `chest.gd`'s
`0xC4E57`, `poi_map.gd`'s `0x9017A11`, `resource_scatter.gd`'s `0x5CA77E5`). The counter resets to 1
on `GameState.seed_ready` — the same "a run has begun" hook `autoload/salvage_service.gd` already
uses to zero its own per-run milestone tally — so a deliberate same-seed replay (a bug repro, F-172's
seed entry) started from a fresh boot reproduces the same sequence of grants rather than drifting
because a previous boot in the same process had granted a different number of rewards first.

**Not a desync/correctness bug, then or now** — same reasoning F-210's own spec block gives: the
roll is host-only and granted directly, so no peer ever needs to agree on the value, only the host's
own two runs sharing a `run_seed` need to agree with each other. What changes is reproducibility.

**Verify:** `.agent/bin/agent godot --script tools/reward_service_seed_check.gd` →
`REWARD_SERVICE_SEED_CHECK failures=0`, zero undeclared `ERROR:` lines. New check, same
synthetic-content-avoidance choice `tools/reward_service_check.gd` already made (proves against the
REAL `content/loot/wellspring.tres`, not a synthetic table): fires `EventBus.emit_wellspring_capped()`
against a fixed `GameState.run_seed`, diffs the check player's coin/powerup-stack state before and
after each trigger to get a comparable roll fingerprint, and checks three cases — (1) the same
`run_seed`, replayed from a fresh `seed_ready` reset, rolls identically; (2) a second trigger in the
SAME run (no reset) does not repeat the first roll; (3) a different `run_seed` at the same trigger
position rolls differently. `.agent/bin/agent godot --script tools/reward_service_check.gd` →
`REWARD_SERVICE_CHECK failures=0` still, unchanged (the existing wiring/grant-amount check has no
determinism assertion to break).

**Swept for the same shape elsewhere:** grepped every `.randomize()` call site project-wide (four
total, project-wide). `core/game_state.gd:56` is the run_seed entropy source itself — must stay real
entropy. `autoload/inventory_service.gd:599` and `autoload/entity_directory.gd:57` are the same two
intentional exceptions F-210's own sweep already documented (a debug console `loot` roll, and a
cosmetic entity-selector RNG with no reproducibility claim). `systems/cycle/cycle_modifier_service.gd:56`
is F-220, already filed by F-210's sweep — not touched here; it needs its own fix under its own claim.
No new sibling instances found.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-220 · `CycleModifierService`'s per-cycle modifier draw is the same boot-time-`randomize()` bug — and already has the stable id `Chest` needed

**Claim:** `systems/cycle/cycle_modifier_service.gd`, `tools/cycle_modifier_seed_check.gd` (new).
Network authority: HOST, same row `docs/ARCHITECTURE.md` §2.2 already declares for "Day/night, wave
director, Cycle state, active modifiers" — this task changes what feeds the draw's RNG, not who
draws.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**The fix:** `_ready()` called `_rng.randomize()` once at boot (real entropy), so every
`host_draw_modifier(cycle)` call drew from that same boot-seeded stream — two runs sharing a
`GameState.run_seed` still stacked different modifiers. Unlike F-219's `RewardService`, no new id
scheme was needed: `host_draw_modifier` already receives `cycle: int` as a parameter, and a Cycle
only ever advances forward with each cycle drawing at most once, so `cycle` is already the stable
per-draw id `Chest`'s node `name` and `RewardService`'s minted counter play the equivalent role for.
`host_draw_modifier()` now seeds `_rng.seed = _seed_for_run(_run_seed(), str(cycle))` immediately
before `_weighted_pick()`, instead of relying on `_ready()`'s boot-time seed (removed).
`_seed_for_run()`/`_run_seed()` are direct copies of `Chest`'s own (own `_SEED_SALT = 0xB16B00B5`,
distinct from `chest.gd`'s `0xC4E57`, `reward_service.gd`'s `0x9E3779B9`, `poi_map.gd`'s
`0x9017A11`, `resource_scatter.gd`'s `0x5CA77E5`). `WorldDeltaLog`'s existing replication of the
drawn-modifier stack is unaffected — replication carries the result, never the roll.

**Not a desync/correctness bug, then or now** — same reasoning F-210/F-219's own spec blocks give:
the draw is host-only and its result is broadcast through `WorldDeltaLog`, so no peer ever needs to
agree on the roll itself, only the host's own two runs sharing a `run_seed` need to agree with each
other. What changes is reproducibility.

**Verify:** `.agent/bin/agent godot --script tools/cycle_modifier_seed_check.gd` →
`CYCLE_MODIFIER_SEED_CHECK failures=0`, zero undeclared `ERROR:` lines. New check: real content ships
only one Cycle Modifier so far (`long_night.tres`), so a weighted pick over a single candidate can
never show variation regardless of seed — the check injects three equally-weighted synthetic
candidates directly into `CycleModifierService._defs`, the same "GDScript has no real access
control" seam `tools/cycle_modifier_check.gd`'s own incompatibility tests already use, and checks:
(1) the same `run_seed` + same `cycle` draws identically; (2) replaying a `run_seed` across a
sequence of cycles reproduces the exact same per-cycle draws; (3) a different `run_seed` at the same
cycles draws a different sequence. `.agent/bin/agent godot --script tools/cycle_modifier_check.gd` →
`CYCLE_MODIFIER_CHECK failures=0` still, unchanged (the existing wiring/eligibility check has no
determinism assertion to break).

**Swept for the same shape elsewhere:** grepped every `.randomize()` call site project-wide (three
remaining after this fix, four before it — this file was the fourth). `core/game_state.gd:56` is the
`run_seed` entropy source itself — must stay real entropy. `autoload/inventory_service.gd:599` and
`autoload/entity_directory.gd:57` are the same two intentional exceptions F-210/F-219's own sweeps
already documented (a debug console `loot` roll, and a cosmetic entity-selector RNG with no
reproducibility claim — confirmed again by reading both call sites: `entity_directory.gd`'s `_rng` only
drives `@r`/random-sort console selectors, never a gameplay roll). No new sibling instances found —
F-220 was the last of the four.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-213 · `core/net/rpc_manifest.gd`'s FNV-1a seed literal overflows signed 64-bit int, erroring on every scan even though the check itself stays deterministic

**Claim:** `core/net/rpc_manifest.gd`. Network authority: none — this is a source scanner and a
constant, same row the file's own header already states.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**The fix:** `RpcManifest.signature()` opened with `var h: int = 0xCBF29CE484222325`, FNV-1a's
standard 64-bit offset basis. GDScript's `int` is signed 64-bit; that literal is 14695981039346656037
unsigned, past the signed max of 9223372036854775807, so `hex_to_int` errored on every run and left
`h` at a fallback value — the check kept passing/failing deterministically, but the algorithm running
was never actually FNV-1a. Rewrote the literal as its signed two's-complement reading of the identical
64 bits, `-3750763034362895579`, with a comment pointing at why (mirrors the reasoning the existing
output mask, `h & 0x7FFFFFFFFFFFFFFF`, already documents for the far end of the same function).

**Re-recording, not a wire change:** the corrected seed changed `signature()`'s output
(`"621c8ba008c3520f"` → `"46487d0ba06e8e31"`), which `rpc_manifest_check.gd` treats as drift requiring
a `PROTOCOL_VERSION` bump. It isn't one here — `RECORDED_ENTRY_COUNT` stayed at 55 and every known RPC
was still found; only the hash of an always-broken seed changed once the seed became correct. This
file's entire git history is the one commit that introduced both `PROTOCOL_VERSION` 21 and this bug
simultaneously, so `RECORDED_SIGNATURE` was never produced by a real run of the tool in the first
place — recorded as D-137, the one case where re-recording without a version bump is the correct call
rather than the omission the checker exists to catch.

**Verify:** `.agent/bin/agent godot --script tools/rpc_manifest_check.gd` →
`RPC_MANIFEST_CHECK failures=0`, zero stray engine `ERROR:` lines (previously three `hex_to_int`
failures every run, per this finding's original report).

**Swept for the same shape:** `grep -rn "0x[0-9A-Fa-f]\{16,\}" --include='*.gd'` project-wide — the
only literal long enough to exceed signed int64 range anywhere in the codebase was this one. No
sibling instances.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-215 · `HSlider` draws no visible focus ring in this Godot version — F-209's gamepad focus work left it the one control type still hard to tell is focused

**Claim:** `ui/menu/settings_menu.gd`, `ui/menu/focus_ring_slider.gd` (new), `tools/menu_focus_check.gd`.
Network authority: none — client-local UI presentation, same as every other file F-209 touched.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**The fix:** `Slider` (`scene/gui/slider.cpp`, `HSlider`'s base) has no `"focus"` theme stylebox
item in Godot 4.7.1, unlike `Button`/`OptionButton`/`CheckBox`/`LineEdit` — confirmed live before
touching anything: `_build_slider_row()` in `settings_menu.gd` never called
`add_theme_stylebox_override("focus", ...)` on its sliders at all (its own comment recorded the gap
as a deliberate follow-up rather than an oversight), so there was no dead override to remove, only a
ring to add. New `ui/menu/focus_ring_slider.gd` adds `class_name FocusRingSlider extends HSlider`: a
public `focus_ring_style: StyleBoxFlat` the caller sets, connected `focus_entered`/`focus_exited`
signals that call `queue_redraw()`, and a `_draw()` override that paints `focus_ring_style` over the
control's own rect when `has_focus()` is true — additive on top of `Slider`'s native C++ drawing, the
same "script `_draw()` layers over the engine's own NOTIFICATION_DRAW" mechanism
`InventoryUI.InventorySlot` relies on to fake a focus stylebox for `PanelContainer` (a different
technique there — a stylebox swap on `"panel"`, since `PanelContainer` has no ring-shaped native
element to draw over) for the identical "no built-in focus stylebox" gap. `_build_slider_row()` now
constructs `FocusRingSlider` instead of `HSlider` and sets `focus_ring_style = _focus_style()` — the
same `StyleBoxFlat` factory every other control in the menu already uses, so the ring matches without
a new colour constant.

**Verify:** `.agent/bin/agent godot --script tools/menu_focus_check.gd` →
`MENU_FOCUS_CHECK failures=0`. New assertion in `_check_settings_menu()`: since
`has_theme_stylebox_override(&"focus")` (every other control's proxy for "has a visible ring") does
not apply to a `Slider`, the check instead asserts `master_slider is FocusRingSlider and
focus_ring_style != null` — the plumbing proxy for "this slider actually draws one". Ran the check
BEFORE any edit per the finding's own warning (its target file had one commit since filing): it
passed at 0 failures then too, but only because it asserted nothing about slider focus at all — read
`settings_menu.gd` to confirm the gap was still real rather than trusting the green run.

**Swept for the same shape:** `grep -rn 'stylebox_override(&\?"focus"'` project-wide — every other
hit targets a `Button`/`OptionButton`/`CheckBox`/`LineEdit`, all of which do have a native `"focus"`
theme item, so none are the same bug. `grep -rn 'HSlider\|VSlider\|Slider\.new\|extends Slider'`
project-wide — the only other hits are `tools/settings_check.gd`'s `as HSlider` casts on the same two
sliders this task already touches (an existing check reading them, not a second construction site).
`settings_menu.gd`'s six sliders (master/music/sfx volume, mouse and gamepad look sensitivity, FOV)
all route through the one `_build_slider_row()` this task changed, so no sibling instance exists
anywhere else in the project.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-216 · `AttunementUI` (task 3.9's mandatory run-start role picker) has no gamepad focus support — worse than F-209's original scope, since this panel has no Esc/dismiss path at all

**Claim:** `ui/attunement/attunement_ui.gd`, `tools/menu_focus_check.gd`. Network authority: none —
client-local presentation over `AttunementService`'s real seam, same as every other F-209 file.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**The fix:** the same recipe F-209 gave `UnlockMenu`'s BUY-button rows
(`unlock_menu.gd`'s `_wire_vertical_chain()`/`_focus_style()`), copied onto `attunement_ui.gd`'s
per-role CHOOSE buttons: a `_focus_style()` helper (transparent-fill outline `StyleBoxFlat`) applied
via `add_theme_stylebox_override("focus", ...)` on every CHOOSE button as it is built, a
`_wire_vertical_chain()` call over `_role_buttons` in `ROLE_ORDER` (wrapping top<->bottom) run at the
end of `_rebuild_role_rows()` since the row set is torn down and rebuilt every open, and a new
`_grab_initial_focus()` that grabs the first `ROLE_ORDER` button's focus, called from `_open_picker()`
after the rebuild. `ui_accept` already carries a gamepad binding project-wide
(`tools/bind_ui_gamepad_actions.gd`, F-209) so CHOOSE itself needed no further wiring — Button's
native `pressed` fires on a focused `ui_accept` for free. Unlike every other F-209 panel, this one has
no Esc/dismiss path (task 3.9's own design, respec out of scope) — grabbing initial focus is not a
convenience here, it is what makes the panel reachable at all with no mouse.

**Verify:** `.agent/bin/agent godot --script tools/menu_focus_check.gd` →
`MENU_FOCUS_CHECK failures=0`. New `_check_attunement_ui()`: spawns a stand-in `"players"`-group
node, confirms the picker auto-opens and grabs the first CHOOSE button with a visible focus ring,
walks the D-pad chain to confirm it closes into one loop, then taps `ui_accept` and asserts
`is_open()` goes false — the one assertion that actually proves a bare controller can get past this
screen at all, since there is nothing else to check against (no Esc path to also prove). Ran the
check BEFORE any edit per the finding's own warning (three named files had commits since filing): it
failed on exactly the missing-focus assertions, confirming the finding was still live, not stale.

**Trap found while verifying, not from the finding itself:** `AttunementUI`'s background poll timer
(`_poll_timer`, autostart, 0.5s) opens the picker for **any** `"players"`-group node with authority,
not only a real player body — and `_check_crafting_ui()` (already in `menu_focus_check.gd`) adds
exactly such a stand-in node for its own station-range setup. Before this fix, an unrelated mid-run
auto-open was harmless (an extra shade nobody asserted against); once `_grab_initial_focus()` existed,
that same auto-open stole keyboard focus mid-`_check_crafting_ui()` and broke it. Fixed by moving
`_check_attunement_ui()` to run **first** in `_run()` — once it completes,
`AttunementService.local_selection()` is permanently non-empty, so the trigger's own guard
(`_open or local_selection() != ""`) keeps the timer from ever firing again for the rest of the
script's run, making every later check's own `"players"`-group node safe. Recorded here because nothing
about this collision was in the finding, and the next agent extending this file needs to know
`_check_attunement_ui()` is order-dependent and must stay first.

**Swept for the same shape:** grepped `ui/` for `Button.new()\|OptionButton.new()\|LineEdit.new()\|HSlider.new()`
against `grab_focus\|focus_neighbor\|stylebox_override(&\?"focus"` — every other runtime-built panel
already carries this wiring from F-209 or F-215, or is the already-filed F-217
(`ui/building/build_bar.gd`'s piece-selection slots, a real gap but not a hard block like this one
since build mode toggle/rotate/confirm/destroy are already gamepad-bound). No new instance of this bug
found outside F-216/F-217.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-217 · `BuildBar`'s piece-selection slots are still mouse-click-only — task 7.6 gave build mode toggle/rotate/confirm/destroy real gamepad bindings but never touched which piece gets selected

**Claim:** `ui/building/build_bar.gd`, `tools/gamepad_check.gd`. Network authority: none — client-local
UI presentation, same as every other F-209/F-215/F-216 file; a slot selection only ever emits
`piece_selected`, and `BuildService` remains the only thing that actually places or destroys anything.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**The fix:** `PieceSlot` (`ui/building/build_bar.gd`'s inner class) already had
`focus_mode = Control.FOCUS_ALL` but its `_gui_input()` only handled `InputEventMouseButton` — the
exact gap the finding named. Three additions, all copied from an existing seam in this project rather
than invented:
1. **Selection** — `_gui_input()` gained the same `event.is_action_pressed(&"ui_accept")` branch
   `InventoryUI.InventorySlot` uses for its own pick-up/drop flow (F-209), calling
   `select_requested.call(piece_id)` directly since selecting a build piece is a single action, not a
   two-step move.
2. **Chain** — a new `_wire_horizontal_chain()` on `BuildBar` itself, run once at the end of
   `_populate_slots()` (slots are built once at boot, never rebuilt — see that function's own doc
   comment). Same wrap-around recipe `UnlockMenu._wire_vertical_chain()`/`AttunementUI`'s copy of it
   use (F-209/F-216), but horizontal (`focus_neighbor_left`/`_right`) since the slots sit in one
   `HBoxContainer` row, not a stacked column.
3. **Focus ring** — `PieceSlot extends PanelContainer`, which (like `Slider`, F-215) has no native
   `"focus"` theme stylebox item, so `add_theme_stylebox_override("focus", ...)` would be silently
   inert. Used the *other* existing technique for this same gap on this same control type —
   `InventoryUI.InventorySlot`'s own `"panel"` stylebox swap — rather than F-215's `_draw()`-override
   technique, since `PieceSlot` already swaps its `"panel"` stylebox for `present(selected)` and
   adding a third swapped style (`_focus_style`, new `COLOUR_FOCUS` constant matching
   `InventoryUI`'s own hue) needed no new drawing code. `_update_style()` centralises the
   selected/focus priority (focus wins, so navigating off the active piece is never mistaken for
   still standing on it) the same way `InventorySlot._update_style()` already does for its own four
   states.

**Initial focus** is the one piece this finding's own "what closes this" note didn't fully spell out:
`player_controller.gd`'s `set_selected_build_piece()` always calls `BuildBar.set_active(true)`
immediately followed by `set_selected_piece(piece_id)` — there is no "activate with nothing selected"
path (its own doc comment). So `set_selected_piece()` doubles as the initial-focus grab
(`_grab_focus_for_selected()`, called at its end) without needing a separate open hook the way
`AttunementUI._grab_initial_focus()` needed one (F-216) — every entry into build mode already funnels
through this one method, click or gamepad alike.

**Verify:** `.agent/bin/agent godot --script tools/gamepad_check.gd` → `GAMEPAD_CHECK failures=0`.
New `_check_build_bar_slot_focus()`: spawns a real player and enters build mode exactly like the
existing `_check_build_cycle_via_gamepad()`, then proves — through the real Viewport GUI input
pipeline (`Input.parse_input_event()`, not a direct `_unhandled_input()` call, since focus movement
is Godot's own GUI focus walk, the same reason `tools/menu_focus_check.gd` uses that mechanism for
every other panel) — that selecting `wall_wood` grabs its slot's focus, D-pad right/left move focus
across the row and back through `focus_neighbor_right`/`_left`, and `ui_accept` (gamepad A) on a
focused slot actually changes `BuildGhost.current_piece_id()` through the real selection seam, not
just a simulated click. Ran the check BEFORE any edit per the finding's own warning (all three named
files had commits since filing): the assertions did not exist yet to fail, so confirmed the gap was
still real by reading `build_bar.gd` directly first — `PieceSlot._gui_input()` had no `ui_accept`
branch, `BuildBar` had no `focus_neighbor_*`/`grab_focus` call anywhere, matching F-215's "read the
file, don't trust a green run that asserts nothing" precedent.

**Swept for the same shape:** `grep -rn 'focus_mode = Control.FOCUS_ALL'` across `ui/`/`entities/` —
only two runtime-construction sites in the whole project, `build_bar.gd` (this task) and
`inventory_ui.gd` (already fixed, F-209). Every panel with `grab_focus`/`focus_neighbor` wiring
(`attunement_ui.gd`, `crafting_ui.gd`, `inventory_ui.gd`, `lobby_menu.gd`, `main_menu.gd`,
`settings_menu.gd`, `unlock_menu.gd`, now `build_bar.gd`) already carries it. F-216's own sweep had
already named F-217 as the one remaining gap of this shape; this task closes it and finds no further
sibling.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-197 · A generated-asset commit swept up another lane's dirty crafting-station GLBs under an unrelated message — the F-149/F-191 sweep hazard reaching art files, not just docs/

**Claim:** none — this task found no code defect to fix, only two already-shipped fixes to verify and
a finding to close. Coordination/verification only, so no `ARCHITECTURE.md` §2.2 authority row.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Checked before touching anything, per the brief's own instruction.** The finding's own text already
said the F-057 fix (`a0d0d46`) "closes this specific instance" and only left the *mechanism* open. Two
commits had landed against `tools/blender/build_crafting_stations.py` since F-197 was filed
(`a0d0d46` F-057, `ddea946` F-196), so both halves needed re-checking rather than assuming the prose
still held:

1. **The specific instance** — does `assets/crafting_stations/exports/*.glb` at HEAD still match a
   clean rebuild? Ran `python3 tools/blender/crafting_stations_repro_check.py` (F-057's own
   determinism check, two separate Blender processes, byte diff): `CRAFTING_STATIONS_REPRO_CHECK
   PASS`, all 8 GLBs and `catalog.json` byte-identical across both runs. More to the point for *this*
   finding: `git status --porcelain` after the run showed **no diff on any export or catalog file** —
   only `assets/crafting_stations/preview/*.png` (expected, F-042: renders are never byte-identical
   even when correct) and `assets/source/crafting_stations.blend` (Blender's own save-state noise),
   both discarded with `git checkout --` since they're not part of this task and not evidence of
   anything. Zero diff on the files that matter means HEAD's exports are exactly what a clean rebuild
   produces today — the specific staleness this finding reported is still fixed.
2. **The mechanism** — F-197's own text left this open on the grounds that "the mechanism … is
   unfixed and will recur … unless `ship`'s per-task staging is what everyone actually uses." F-191
   (resolved chronologically *after* F-197 was filed — 10:14 vs. F-057's 07:07 the same day) added
   exactly this: `cmd_check`'s `elif not c and not human and not in_grace(f)` branch now warns by name
   when a file about to be swept into a bare commit was released by a *different*, still-recent agent,
   citing F-191 and the pathspec fix, instead of a silent generic "edited without a claim." This is
   not docs-scoped or harness-scoped code — the check loop (`for f in changed:` in `cmd_check`) runs
   over every file in the commit, and `tools/harness_check.py`'s own F-191 regression case already
   proves this on a plain non-docs path (`world/thing.gd`, not `.agent/bin/` or `docs/`), so
   `assets/crafting_stations/exports/*.glb` gets the identical protection the moment it is claimed
   through `agent claim` like any other non-free-prefix file. No new code needed — the generalization
   already happened as a side effect of F-191's own fix, it was just never connected back to F-197 in
   the docs.

**This task's contribution is entirely in the docs the two originating fixes skipped:** neither
F-057's nor F-191's resolution note in `docs/FINDINGS.md` cross-references F-197, so despite both
halves being fixed, F-197 itself was still sitting open on the board. Verified both halves hold today
(above), then moved F-197 to `## Resolved` with this reasoning and both commit citations, and wrote
this spec block since none existed.

**Verify:** `python3 tools/blender/crafting_stations_repro_check.py` → `CRAFTING_STATIONS_REPRO_CHECK
PASS`, zero diff on `exports/`/`catalog.json`. `python3 tools/harness_check.py` → full pass, including
the two F-191 cases run against `world/thing.gd`, proving the sweep-naming warning is general-purpose.

**Swept for the same shape:** no code changed, so no sibling call sites to check — this task's sweep
is documentary: grepped `docs/FINDINGS.md` for every other `## Resolved` entry citing F-149 or F-191
to confirm none of them left a similar unresolved cross-reference (F-149 and F-191 themselves are
already `## Resolved`; nothing else names either as its own fix).

**Resolved** — see `docs/FINDINGS.md`.

---

## F-207 · F-204's same bug — an object repositioned between renders that never takes effect — is live in 8 more Blender generators, one of them twice

**Claim:** none — this task found no code defect to fix, only nine already-correct renders to verify
and a finding to close. Coordination/verification only, so no `ARCHITECTURE.md` §2.2 authority row.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**What F-207 claimed:** a mechanical `grep -n "bpy.ops.render.render\|\.location = " tools/blender/build_*.py`
found the same code SHAPE F-204 fixed (`object.location` reassigned between two `bpy.ops.render.render()`
calls in one process) live in `build_enemy_crawler.py`, `build_crafting_stations.py`,
`build_harvestable_resources.py`, `build_mire_map_kit.py`, `build_wellspring_set.py`,
`build_loot_set.py`, `build_ward_set.py`, and `build_tool_weapon_set.py` (twice) — nine renders total,
never verified against actual pixels.

**What this task found:** none of the nine are actually broken. For each, disabled the reposition line
in a throwaway copy of the script (`pass` in place of the `.location =`/`.rotation_euler =` line),
rebuilt standalone, and diffed the resulting preview PNG against the real script's output:

| File | Broken render(s) claimed | Actually broken? |
|---|---|---|
| `build_crafting_stations.py` | scale preview (2nd of 2) | No — diff test shows real reposition takes effect |
| `build_harvestable_resources.py` | scale preview (2nd of 2) | No — same masked shape, visual match to showcase |
| `build_mire_map_kit.py` | hero shot (8th of 8) | No — diff test shows real reposition takes effect |
| `build_wellspring_set.py` | scale preview (2nd of 2) | No — same masked shape, visual match to showcase |
| `build_loot_set.py` | scale preview (2nd of 2) | No — same masked shape, visual match to showcase |
| `build_ward_set.py` | scale preview (2nd of 2) | No — same masked shape, visual match to showcase |
| `build_tool_weapon_set.py` | viewmodel preview (2nd of 3) | No — real render shows the intended grid+tilt |
| `build_tool_weapon_set.py` | scale preview (3rd of 3) | No — diff test shows real reposition takes effect |
| `build_enemy_crawler.py` | scale preview (2nd of 2) | No — exaggerated-offset test shows real reposition takes effect |

`docs/DECISIONS.md` D-138 has the mechanism: F-204's diagnosis is still correct in general (reproduced
verbatim by rebuilding the pre-fix `build_gatherable_plants.py` from `2330435^` under today's Blender —
the reference cube froze exactly as originally described), but in every one of these nine cases
something else between the reposition and the render — new scale-reference geometry via
`bpy.ops.mesh.primitive_*_add`, a `camera.data.type` flip, or the object simply never having appeared
in an earlier render — happens to force Blender to re-evaluate the stale transform too. The grep sweep
that filed F-207 could only see the code shape, not this side effect, so it over-flagged all nine.

**Not fixed here**, because there is no actual bug: none of these files' pixels need to change, and
rewriting already-correct hand-authored generator code "to be safe" is exactly the unnecessary-churn
AGENTS.md warns against. Filed **F-222** for the real residual risk: correctness here depends on
incidental code (the scale prop, the camera-type flip) that a future edit could remove without any
check noticing.

**Verify:** every file rebuilt standalone
(`/Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_X.py`) and
run through `tools/blender/asset_repro_check.py` (`A-001` through `A-009` labels) — all nine
`*_ASSET_REPRO_CHECK PASS`, every exported GLB and catalog.json byte-identical across two fresh
rebuilds. Working tree left clean afterward (`git checkout -- assets/`); no `assets/` files needed to
change since no code changed.

**Swept for the same shape elsewhere:** this task's whole scope was F-204's already-completed sweep;
no further generators outside the nine named above match the pattern (confirmed by F-204's own grep,
re-run and unchanged in file list).

**Resolved** — see `docs/FINDINGS.md`.

---

## F-214 · Undergrowth scatters through the new ExtractionShip's hull at MereShore — the offline plant pass has no way to know about a marker-bridge's runtime-built geometry

**Claim:** `world/gen/undergrowth.gd`, `tools/hollowmere_check.gd`. Network authority: none —
`Undergrowth` is presentation-only and deterministic per its own file header; this fix reads two other
systems' constants but adds no new state and no RPC.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Ran the check before touching anything** (per the finding's own warning — `tools/hollowmere_check.gd`
had 2 commits since filing): `HOLLOWMERE_FLORA_GROUND sampled=10338 perched=23 worst=4.26 m`, identical
to the finding's own numbers. Not fixed by either of those two commits; the gap was still real.

**The fix — finding's option (a):** `Undergrowth._collect_marker_exclusions()` reads the layout's own
`markers` array once per scatter (`_scatter()`, and cleared/rebuilt in `rescatter()` alongside its
sibling collections) and builds a keep-out disc for every `shipwreck`/`objective` marker — the two kinds
`autoload/extraction_service.gd`/`autoload/wellspring_service.gd` turn into a live, solid
`ExtractionShip`/`Wellspring` after this pass has already run. Each disc's radius comes from the object's
own script, preloaded the same way `AssetVfx` already is in this file (a brand-new `class_name` is not
bare-resolvable in a fresh headless `--script` run, F-016): `ExtractionShip.HULL_HALF_EXTENTS`
circumscribed in the XZ plane (`sqrt(5.6² + 2.2²) ≈ 6.02 m`, not the box itself, so it stays correct if
either bridge ever gives its marker a rotation — neither does today) and `Wellspring.FOUNDATION_RADIUS_M`
(2.4 m) directly, since that shape is already a circle. `_in_marker_exclusion()` rejects a scatter attempt
inside any disc, checked once per attempt right after the map-bound check, before the ray probe or the
zone/family roll — cheaper to reject early than to raycast a point that was always going to be thrown out.

**Why a static disc and not waiting on the bridge:** `Undergrowth._ready()` already only waits two
physics frames for the terrain's own colliders to exist; the marker-bridge autoloads build their objects
via `call_deferred`, with no ordering guarantee relative to that wait, and creating one would couple a
presentation-only, no-network-authority system to two host-authoritative gameplay systems for a purely
cosmetic gap. Reading each object's known, already-`const` footprint at generation time — the finding's
own option (a) — needs no such coupling and stays correct as long as those constants do.

**Verify:** `.agent/bin/agent godot --script tools/hollowmere_check.gd` →
`HOLLOWMERE_FLORA_GROUND sampled=10243 perched=0 worst=0.00 m`, `HOLLOWMERE_CHECK PASS`. `sampled`
dropping by 95 (10338 → 10243) is the attempts now rejected by the two discs before a plant is ever
placed; `perched` dropping from 23 to 0 is the fix. No new failures elsewhere in the same run.

**Swept for the same shape:** every `authored_world_marker` consumer —
`autoload/chest_placement_service.gd` (`loot` markers → `Chest`) and `autoload/crafting_service.gd`
(`station` markers) — builds only a logic node against a marker whose visual/collision already exists as
an ordinary authored prop or baked `MultiMeshInstance3D` (Hollowmere bakes station props with no
per-instance node of their own, per that file's own header). Neither bridge constructs new runtime
geometry the way `extraction_service.gd`/`wellspring_service.gd` do, so neither is exposed to this bug;
`shipwreck`/`objective` were the only two marker kinds that needed a disc.

**Resolved** — see `docs/FINDINGS.md`.

---

## F-223 · CommandService's synchronously-resolved commands never print in the console — result signal fires before the pending-handle guard is armed

**Claim:** `autoload/debug_console.gd`, `autoload/command_service.gd`, `tools/command_console_check.gd`.
Network authority: none of its own — this is a same-process signal-ordering bug in the CLIENT-LOCAL
console presentation layer over CommandService's existing authority row (docs/ARCHITECTURE.md §2.2,
"Command execution"); no new state, no RPC.

**No spec existed for this finding** — writing it is this task's own first step, per this file's
preamble.

**Ran the check before touching anything** (per the finding's own warning — `autoload/debug_console.gd`
had 1 commit since filing): read the diff (`2c86ed9`, F-130 — deletes the `register()` shim, migrates
handler return shapes to `{ok, message, data}`) and confirmed it never touches `_run()`'s ordering.
`_pending_handles[handle] = true` was still the line immediately AFTER `submit()`, unchanged. The bug
was still live.

**The fix:** the root cause is that `CommandService.submit()` allocates its handle AND runs the
command to completion (for anything that does not need a real network `await` — the entire
single-player/host-typed path) inside the same call, emitting `command_result` before returning the
handle to the caller. A caller that arms a `handle`-keyed guard on the line after `submit()` returns is
always one step too late for that synchronous case. Split allocation from execution:
`CommandService.reserve_handle()` (just `_take_id()`) and `CommandService.submit_with_handle(handle,
line, ctx)` (just `_run_submission(handle, line, ctx)`) are the new two-step form; `submit()` itself is
now a thin `reserve_handle()` + `submit_with_handle()` pair, unchanged for a caller that never needs to
filter by handle. `DebugConsole._run()` calls `reserve_handle()`, arms `_pending_handles[handle]` (and
`_unpaused_for_handles[handle]` when applicable, D-076), and only THEN calls `submit_with_handle()` —
so the guard is armed before execution can possibly complete, for every path, not just the ones that
happen to suspend.

**Verify:** wrote `tools/command_console_check.gd` — no prior check drove `DebugConsole._on_submitted()`
for the synchronous path and read its own output buffer back (`command_check.gd` bypasses `submit()`
entirely via `execute()`; `command_net_check.gd` phase C only exercises the genuinely async
client-over-RPC path). `.agent/bin/agent godot --script tools/command_console_check.gd` →
`COMMAND_CONSOLE_CHECK failures=0`: typing `help` into the console now prints the full command listing
(not just the `> help` echo), typing `give branch 5` (HOST scope, host-typed, still fully synchronous)
prints `gave 5 x branch`, and `_pending_handles` is empty again after both resolve (the guard did real
work and drained, rather than never mattering). Re-ran `tools/command_check.gd`
(`COMMAND_CHECK failures=0`) and `tools/command_net_check.gd` (`COMMAND_NET_CHECK failures=0`,
including the paused-console RPC round trip D-076 fixed) to confirm neither regressed.

**Swept for the same shape:** grepped for every caller of `CommandService.submit()` — `debug_console.gd`
is the only one in the codebase, so there was no sibling call site to fix. Grepped for the broader
pattern (a function that returns a request/handle id which a caller then uses to arm a dictionary-keyed
guard, where the underlying call might resolve before the guard is armed) — `func submit(`/`func
request(`/`func reserve` and every other `request_id`/`_pending_*` dictionary in the repo belongs to a
genuine cross-process RPC round trip (host/client, always a real network `await`, never resolves
synchronously inside the call that returns the id), which is not this bug's shape. CommandService's
`submit()` was the only place a request could resolve synchronously inside the same call that hands
back its own id.

**Resolved** — see `docs/FINDINGS.md`.

---

# Maintaining this file

One block per task, same shape: **Goal / Authority / Claim / Build / Verify / Done means / Traps.**
When a task ships, its block stays (it documents intent the code now embodies) but gains a one-line
`✅ shipped — see DELEGATION` header. When a design decision invalidates a block, rewrite the block
in the same commit as the decision. The specs for a milestone get their final polish when the
previous milestone's playtest lands — never spec against a design that playtest is about to change.
