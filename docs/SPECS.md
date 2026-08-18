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

**Claim:** `systems/loot/chest.gd`, `systems/loot/loot_table_def.gd`, `ui/loot/chest_ui.gd`,
`autoload/registry.gd`, checks. Chests are placed props (A-005 loot assets exist) with tiers;
opening is a host-validated interact (harvest pattern: request → host rolls seeded RNG per-chest →
`InventoryService.host_add` grants → broadcast). Coins are an item (stack 999), not a parallel
currency system. Loot rolls host-side from a per-run seeded `RandomNumberGenerator` — never
`randi()`. UI joins the D-032 group.

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
| F-037 | Rewrite `net_debug_panel_check`'s fake second peer as a real process (copy `inventory_net_check`'s scaffold); acceptance = 0 expected errors. |
| F-038 | Re-run the four two-process checks 10× back-to-back **under `agent godot`'s lock** (F-044 landed after this was filed); if it still fires, fix the subscribe-before-grant ordering, never the timeout. |
| F-042 | Habit recorded in the tracker; optional tool `tools/png_pixels_equal.py` if it bites again. |
| F-043 | Decision spec'd under M2 above. |
| F-049 | Two named fixes in `.agent/bin/agent` (`_sync_findings` closes departed findings; start/board call it); ship with a before/after board diff. |

# Maintaining this file

One block per task, same shape: **Goal / Authority / Claim / Build / Verify / Done means / Traps.**
When a task ships, its block stays (it documents intent the code now embodies) but gains a one-line
`✅ shipped — see DELEGATION` header. When a design decision invalidates a block, rewrite the block
in the same commit as the decision. The specs for a milestone get their final polish when the
previous milestone's playtest lands — never spec against a design that playtest is about to change.
