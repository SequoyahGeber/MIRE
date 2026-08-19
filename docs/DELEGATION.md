# Delegation — the state agents start from

**A written prompt is no longer required to start a task.** Say *"start 1.6"* to a fresh chat; the
agent runs `agent brief 1.6`, which prints the task, the open findings, what recent tasks left it and
who holds which files, and points it at this file's *Current state* section below. That section is the
contract: **whatever the next task builds on gets written there by the task that produced it.**

**So the important half of this file is *Current state*, not the prompts.** Keeping it accurate is
part of closing out a task (`AGENTS.md` step 3) — a stale one is exactly what forced hand-written
prompts in the first place, because the next agent could not trust anything here.

The prompt blocks that remain are kept as worked examples, and because a hand-written brief is still
worth writing for a task that is unusually easy to get wrong — a spike with a specific measurement
protocol, or a task where the failure mode is subtle. If you do write one, set the model and effort
named under its heading. Nothing here is for Sequoyah to run.

**Each parallel chat gets its own identity automatically, and you no longer supply it (F-007).** The
name is derived from the chat's own session id, which every command carries in its environment — git
included, so the pre-commit hook resolves the same agent your `agent` commands do. Stable for a whole
session, unique per chat, nothing to pass:

```bash
.agent/bin/agent claim 1.2 autoload/net_transport.gd
```

**The archived prompt blocks below still carry `MIRE_AGENT=<name>` prefixes.** They shipped under the
old scheme and are kept verbatim as worked examples. The prefix still works — it overrides everything —
but do not copy that pattern into a new prompt, and never reintroduce `export`: each shell call is a
fresh process, which is what made the old scheme fail silently.

**Prefer `agent ship` for commits**, and it is now safe to prefer: **F-014 is fixed** (`ce8128a`), so
`ship` commits by pathspec and can no longer be blocked by, or unstage, another agent's staged work,
and **F-010 is fixed** (`60e85cc`), so it carries `.uid` sidecars along with the scripts that own them
instead of leaving them untracked.

**Roles are not fixed (D-020).** Any agent can take any task; which one gets it depends on which plan
has quota. Nothing below is reserved for a particular chat.

**Standing trap — most of `.godot/` is gitignored, and real setup can hide in it.** One task still
depends on local editor state:

| Task | What lives in `.godot/` |
|---|---|
| 1.3 | Run-instance config (Debug → Customize Run Instances) — the two-window launch args |

F-009 is fixed: `.godot/extension_list.cfg` is the sole tracked exception and registers GodotSteam in
a fresh clone or headless VM. Any prompt whose work touches other editor state should still say so
explicitly and hand back either a click-path or a committed script.

---

### Task 1.11 — version handshake is wired through `NetSession`

`core/net/net_version.gd` remains the pure version source: `PROTOCOL_VERSION: int` and
`mismatch_reason(local_version, remote_version) -> String`. Task 1.7 integrated it at the lifecycle
policy layer instead of the transport mechanism. On connection, a client calls
`NetSession.net_client_hello(PROTOCOL_VERSION)` on the host. The host compares versions, sends the
same human-readable refusal used by capacity/policy admission, waits 0.25 s for the reliable notice
to flush, then kicks the peer.

Version is necessarily checked just after ENet admits the connection, so the mismatched peer may
briefly spawn before the refusal arrives; it is then despawned and leaves no player behind. D-027
records that tradeoff and what would justify moving to `SceneMultiplayer.auth_callback`. The real
multi-process lifecycle harness verifies the complete path. `tools/handshake_check.gd` remains the
smaller pure-mechanics probe.

F-016 still applies to `NetVersion`: headless `--script` entry points should preload
`res://core/net/net_version.gd` rather than relying on the gitignored global-class cache.

Bump `NetVersion.PROTOCOL_VERSION` in the same commit as any change that would desync two builds
silently — see the constant's own doc comment for the exact list (replicated property, RPC signature,
`SceneReplicationConfig`).

---

## Current state — check `.agent/BOARD.md` before pasting anything

### 2026-08-19 — F-187 fixed: `MeshMerge.merge_instances()` bakes several placements into one static mesh — AuthoredWorld uses it for rigid, non-emitting, non-sway, never-shadow-casting props (lm)

`core/render/mesh_merge.gd` gained `merge_instances(entries: Array) -> ArrayMesh`, where `entries` is
`Array[Dictionary]` of `{"mesh": Mesh, "transform": Transform3D}` — additive next to the existing
`merged()`/`_build()` (per-source-file merge, untouched, still what F-152's pinned check exercises).
Same bucket-by-(material-appearance, vertex-attribute-mask) algorithm, generalised for a caller that
already has meshes in hand (not a `.glb` to load) and a full placement transform per entry (not a
fixed offset inside one asset's own hierarchy). **Never disk-cached** — the caller decides how
entries are grouped, so there is no one source-file mtime to key a cache entry against; cheap enough
to rebuild every load since entries are already-merged, already-indexed meshes.

**The seam the next cross-placement merge builds against — and its one real constraint:** whatever
you bake with `merge_instances()`, `DrawPolicy.apply()` needs an AABB sized from your OWN objects'
individual heights, never `combined.get_aabb()` — the merged mesh's own AABB reflects the terrain (or
whatever else) the placements are spread across as much as any object's actual height, and feeding it
to `DrawPolicy` misclassifies draw distance and, for anything tall enough to cast a shadow, causes
Godot to re-render the whole merged primitive count into every PSSM cascade its now-larger AABB
touches — measured as a 16% primitive regression on Hollowmere before this was caught
(`tools/frame_cost_check.gd` against `agent baseline`, see docs/SPECS.md's F-187 block). Build a
synthetic `AABB(Vector3.ZERO, Vector3(0, max_of_your_objects_own_heights, 0))` instead, as
`AuthoredWorld._build_props()`'s `mergeable` loop does.

`AuthoredWorld._build_props()` (`world/gen/authored_world.gd`) is the first caller: a prop merges
across assets into one static mesh per chunk only when it is simultaneously not harvestable, carries
no `AssetVfxLibrary` emitter, carries no sway, and its own mesh height stays under
`DrawPolicy.SHADOW_MIN_HEIGHT` — see F-203 for exactly what a caller wanting to include sway- or
emitter-bearing props would need to solve first (a height-encoded vertex channel for sway; per-asset
placement sub-ranges for emitters). Merged holders live under `PropVisuals` named `merged_<chunk>`,
each with one `MeshInstance3D` child named `MergedProps` and no `asset` meta (deliberate — the node
spans many assets, so `EnvironmentVfx._asset_id_for`'s meta-then-name walk correctly finds nothing
and skips it). `AuthoredWorld.merged_prop_mesh_count` counts them, separate from `multimesh_count`.

**Verified:** `agent godot --script tools/prop_chunk_merge_check.gd` (new — independently recomputes
eligibility from the layout file and asserts it matches what the scene built, plus asserts every
merged node's `cast_shadow` reads OFF), plus `hollowmere_check.gd`, `mesh_merge_check.gd`,
`environment_vfx_hollowmere_check.gd`, `harvest_batch_check.gd`, `harvest_world_check.gd`,
`resource_scatter_check.gd` — all green. `frame_cost_check.gd` against `agent baseline`: 867 → 786
authored-world visual nodes (−9.3%), draw calls unchanged on Hollowmere specifically, primitives
+1.3% (not the +16% the unfixed version measured).

### 2026-08-19 — F-158 fixed: `EnemyDef` gains a general `visual_tint`, so a stat-only variant no longer has to be visually identical to its base kind (lm)

`systems/enemies/enemy_def.gd` gained `visual_tint: Color = Color(1,1,1,1)`. Default is a true no-op
— every `EnemyDef` that never sets it (every one but `bog_crawler` today) renders bit-for-bit
unchanged. `systems/enemies/enemy.gd::_apply_visual_tint()` (called from `_build_visual()`) walks
every `MeshInstance3D` under the visual, duplicates its active material per surface (never mutates the
shared imported-GLB material), and multiplies `albedo_color` by the tint before setting it as a
`surface_override_material`. Deliberately its own mechanism, separate from the existing hit-flash/
dissolve `material_overlay` (2.9) — that slot is a transient additive layer already reused for two
effects; a permanent base tint sharing it would get clobbered the next time either ran.

**The seam task 5.2 (8-12 enemy types) and task 4.10 (Mire visuals) build against:** any future
`EnemyDef` that reuses an existing `model` for a stat-only variant can set `visual_tint` alone to read
as visually distinct — no new art required (D-73). `bog_crawler.tres` is the first and only user today:
`visual_tint = Color(0.38, 0.5, 0.34, 1)`, a murky corrupted-green.

**Trap for the next check that spawns a real enemy with a non-default `visual_tint`:** setting a
duplicated `surface_override_material` provokes the headless dummy renderer's own harmless
`ERROR: Parameter "material" is null.` (`material_get_instance_shader_parameters`) — confirmed absent
under `--windowed` (real Forward+ backend), confirmed CPU-side assertions are identical either way.
Declare `EXPECTED_ERROR_PATTERNS="Parameter \"material\" is null"` on the check's own verdict line
(standing rule 4, docs/SPECS.md) rather than being surprised by it — `tools/wave_director_check.gd`,
`tools/mire_interaction_check.gd` and `tools/enemy_lod_check.gd` all needed this once `bog_crawler`
started actually rendering tinted.

**Verified:** `agent godot --script tools/bog_crawler_check.gd` (new) → `failures=0` under both
`--headless` and `--windowed`. Full details, root cause and the sibling-check fixes are in
`docs/SPECS.md`'s F-158 block; `docs/FINDINGS.md`'s F-158 entry is now under `## Resolved`.

### 2026-08-19 — F-183 fixed: a Wellspring cap / boss kill finally rolls its loot tier — `autoload/reward_service.gd`, direct-grant, no spawned `Chest` (lm)

D-123's two calls: **direct grant, never a spawned `Chest`** (an event-timed trigger has no
established way to land a dynamically-instanced node at a matching `NodePath` on every peer — this
codebase's only two patterns that guarantee that are `MultiplayerSpawner` and
`ChestPlacementService`'s boot-deterministic marker bridge, and this fits neither), and **one
independent roll per present player**, not one shared roll — the closer analogue to "whoever gets
there first loots" a world chest already means.

```gdscript
# EventBus.subscribe_wellspring_capped() / subscribe_boss_defeated() already fire identically on
# every peer (D-107/D-108/F-168/F-181's pattern) -- RewardService._owns_mutation() (copied
# verbatim from Wellspring/Chest's own boilerplate) is what keeps a client from rolling anything.
# Per present player (RewardService._present_peers(), same "distinct multiplayer authority in the
# players group" helper DefeatService already has):
Registry.get_loot_table(tier).roll(rng, 0.0, unlock_check)   # fresh RandomNumberGenerator, never randi()
InventoryService.host_add(peer_id, item_id, amount)          # coins + items
PowerupService.host_grant(peer_id, powerup_id, count)         # powerups
```

Reuses D-111/F-173's unlock-gating `Callable` exactly as `Chest._unlock_check()` builds it (the
host's own `UnlockService`, since `_owns_mutation()` already restricts this to the host process) and
the identical three-bucket dispatch `Chest._accept_open_request()` already uses — no new grant
mechanism, just a new caller. `core/util/mire_log.gd` gained a `&"reward"` channel (`CHANNELS` array)
for the per-grant log line, same "declare it so the console/overlay can toggle it" convention every
other channel already follows.

**Registered last** in `[autoload]` via `agent autoload RewardService res://autoload/reward_service.gd`
— depends on `Registry`/`InventoryService`/`PowerupService`/`UnlockService`, all registered earlier.

**Not built — see D-123 for why, and what would change it:** no `Chest` node, no visible in-world
prop at the Wellspring/boss arena. `DESIGN.md`'s "a teammate sees a jackpot" social framing is only
served indirectly today, through `PowerupService.host_grant()`'s already-existing
`net_powerup_counts` broadcast (every teammate already learns when someone's stack count changes) —
a future task building a general "spawn a networked object outside `MultiplayerSpawner`/boot-time
content" primitive would remove the NodePath objection and make a visible reward chest
straightforward; D-123 names exactly what that primitive would need to prove.

**Verified:** `agent godot --script tools/reward_service_check.gd` → `REWARD_SERVICE_CHECK
failures=0`, run three times (the check's rolls use non-seeded `randomize()`, same as `Chest`'s own
per-instance stream) — against the REAL `content/loot/wellspring.tres` (all-POWERUP, coins 40-80)
and `boss.tres` (mixed item/powerup, coins 100-220) content, no synthetic table. `agent godot
--quit-after 60` → clean boot, no new `ERROR:` lines. No regressions: `tools/chest_check.gd`,
`tools/chest_placement_check.gd`, `tools/wellspring_check.gd`, `tools/boss_check.gd`,
`tools/unlock_check.gd`, `tools/loot_content_check.gd` all still `failures=0`.

### 2026-08-18 — Task 3.7 (second half): the doors open — host-authoritative, and the doorway really clears (slate17)

**What shipped, verified:** `systems/building/buildable_door.gd`, the three hinged piece scenes
re-authored with split colliders, `ui/building/door_prompt.gd` registered as the `DoorPrompt`
autoload, `PROTOCOL_VERSION` 19 → 20, and `tools/door_check.gd`. All green:
`door_check` 0 failures across all three doors, plus `buildable_content_check`, `build_check`,
`build_net_check`, `handshake_check` and `verify_setup` (123 checks) after the bump.

**The seam:** a door is a `BuildableDef` whose scene root carries `buildable_door.gd`, which extends
`buildable_piece.gd` — so it satisfies the `&"damageable"` contract F-085 is about and
`BuildService._net_spawn_piece()` leaves the authored root alone, exactly as that function's own
comment anticipated.

```gdscript
door.request_toggle() -> bool     # the interact seam; offline/host answer synchronously
door.open: bool                   # replicated, host authority, the ENTIRE schema
door.is_passable() -> bool        # whether the doorway is currently walkable
door.toggled(open, by_peer_id)    # local signal for presentation and prompts
```

**Two things are worth copying rather than re-deriving.** First, **the collider changes with the
state**: a door's shapes are split into the structure that always blocks (jambs, posts, header,
lintel) and one `blocking_shapes` span across the opening that is disabled while open. A door that
swings but whose collider does not is the worst version of this bug, because it looks right in
motion — `door_check` sweeps a 0.32 m player capsule through the doorway in both states rather than
trusting the transform (F-150). Second, **the swing is free** because A-010 exports every leaf with
its origin on the hinge axis and `scenes/buildables/*.tscn` places it at the catalog's
`hinge_offset_m` — opening a door is `leaf.rotation.y = angle` and there is no pivot for anyone to
find by hand (D-039, D-090).

**Owed, and blocked on a claim:** `docs/ARCHITECTURE.md` §2.2 needs the row below; the file was held
by F-183 for this whole session (the same gap F-165 records for `net_version.gd`). Paste it under
the world-mutation rows:

> `| Placed doors and gates — open/shut state (task 3.7) | **Host.** `BuildableDoor` holds `open`;
> only the host flips it, and the collider that spans the doorway follows the bool on every peer. |
> New reliable `net_request_toggle` (client → host, carries no state); a code-built
> `SceneReplicationConfig` with `open` ON_CHANGE, the same shape as `Chest.opened`. `PROTOCOL_VERSION`
> 20. | Same "harvest pattern" as Chest and Wellspring: the request carries nothing, and the host
> re-derives whether the requester is within the door's own `interact_range_m`. A client-predicted
> swing is exactly the "two clients disagree" case — a door open on your screen and shut on the host
> is a wall you can see through and walk into. |`


### 2026-08-18 — F-180 fixed: A-010's HINGE-family leaves now clear their frame at every swing angle — `HINGE_CLEARANCE` (lm)

`tools/blender/build_construction_set.py`'s `create_asset()` used to normalize every `HINGE`-family
leaf (door, both gate halves, the palisade gate) exactly flush to its own hinge axis and back-face
reference — local x=0 and y=0, no gap. Since each leaf's `hinge_offset_m` was separately authored to
place that same origin exactly on its frame's opening edge, "flush" meant a real, non-degenerate part
of the leaf sat on the identical float value as the frame's collision face, not merely close to it.
`tools/construction_check.gd`'s swing sweep (real per-triangle AABBs, not a bounding-box estimate)
catches this as a genuine overlap once F-148's masking crash is out of the way; it does not tolerate
"touching."

**New convention for any future HINGE-family export:** `HINGE_CLEARANCE = 0.008` (8 mm) in
`build_construction_set.py` is now baked into `create_asset()`'s `HINGE` branch — every hinge leaf's
geometry sits 8 mm off both its swing-side edge and its back-face reference instead of exactly on
them. `hinge_offset_m` in the catalog is unaffected (it is a separate, hand-authored frame-placement
constant, not derived from this internal normalization), so nothing that reads the catalog — task
3.7's scene wiring included — needs to change. `check()`'s own flush-origin assertions now expect
`HINGE_CLEARANCE`, not zero, for the same reason.

Verified: rebuilt via Blender 5.2.0 LTS, build contract 0 problems, only the four HINGE exports plus
previews plus the `.blend` source changed (the other 14 exports and `catalog.json` byte-identical).
`agent godot --script tools/construction_check.gd` → `CONSTRUCTION_CHECK PASS`, run twice. Full
writeup: `docs/SPECS.md` F-180 block, `docs/FINDINGS.md` `## Resolved`.

### 2026-08-19 — F-173 fixed: task 6.9's unlock tree gates its first real drop — `LootTableDef.roll()`'s POWERUP entries, wired through `Chest` (lm)

D-111's option (b): the HOST's own `UnlockService` gates the whole party's roll, no RPC. No new
network seam was needed — `LootTableDef.roll()` only ever runs inside `Chest._accept_open_request()`,
and that only ever executes in the host process (locally, or behind `net_request_open`'s own
`_transport_is_host()` guard), so `/root/UnlockService` resolved there is already, structurally,
the host's own instance, never the opening peer's.

```gdscript
LootTableDef.roll(rng: RandomNumberGenerator, luck: float = 0.0, is_unlocked: Callable = Callable()) -> Dictionary
    # New third arg. Callable(content_id: StringName) -> bool, asked only for POWERUP entries (an
    # ITEM entry is never gated). An entry it returns false for is zero-weighted for that draw —
    # not removed from the table, so it rolls again once unlocked. Default (an invalid Callable)
    # never filters anything — every pre-F-173 call site (tools/loot_content_check.gd,
    # tools/chest_check.gd, InventoryService._cmd_loot's debug `loot` command) is unaffected.
```

```gdscript
Chest._unlock_check() -> Callable
    # Private helper, _accept_open_request()'s own seam: Callable(UnlockService, "is_content_unlocked")
    # when /root/UnlockService is present, else an invalid Callable (fail-open — same posture
    # is_content_unlocked() itself already takes when its own Registry dependency is missing).
```

The worked example (`content/unlocks/unlock_deep_pocket.tres`, gating the real `deep_pocket`
PowerupDef `content/loot/bog.tres` already rolls) is now a real, live gate — a Bog Chest never
drops `deep_pocket` until the host has purchased that unlock.

**Still not built, and D-111 already says why:** POI placement and `WaveSpawner`'s in-run
enemy-roster expansion (`host_unlock_next_enemy()` — an unrelated, in-run "unlock," not this
system) both need state that is byte-identical across every peer, which a per-peer unlock set
cannot give them through the same "only ever ask the host" trick this fix uses — that needs
replicated purchases or a session-wide unlock tree first. Nothing here starts that; the next task
into either pool should read D-111 before assuming this fix's pattern extends.

Verified: `agent godot --script tools/unlock_check.gd` → `UNLOCK_CHECK failures=0`, run twice — new
coverage is a pure `LootTableDef.roll()` unit (gated POWERUP never drawn locked, rolls normally
unlocked, an ITEM entry is never gated, the no-argument call is unaffected) plus a real `Chest`-open
integration test against the worked example's own gate: locked grants nothing, the identical tier
grants the powerup once purchased. No regressions: `tools/chest_check.gd` and
`tools/loot_content_check.gd`, both re-run clean. `docs/ARCHITECTURE.md` §2.2's "Unlocks" row and
this file's own 6.9 entry below are both updated to match; `docs/FINDINGS.md` has F-173 in
`## Resolved`. F-182 filed along the way (unrelated pre-existing gap, `tools/unlock_check.gd`'s
corrupt-save test has no `EXPECTED_ERROR_PATTERNS`).

### 2026-08-19 — F-172 fixed: a `--seed=<value>` launch argument gives solo/offline play the seed entry task 6.10's menu never reached (lm)

Task 6.10 shipped `MainMenu`'s seed field, but it only ever reaches a HOST session — solo/offline
play draws its seed in `MireGrid._ready()` before the player has a single frame to open a menu
(F-172). The real boot-gate fix (a title screen the game boots INTO) is explicitly out of scope —
D-110 reserves that for a task scoped and reviewed on its own, one that updates the two-process/
`--quit-after N` check convention first. This fix instead closes the actual gap — solo players had
**no way at all** to set a seed — without moving boot order: `GameState._apply_launch_seed_arg()`
(new, first line of `_ready()`) parses a `--seed=<value>` launch argument and stages it via the
already-shipped `set_pending_seed()`, using the exact same parsing `ui/menu/main_menu.gd`'s
`request_set_seed()` already does (integer used as-is, other text hashed with `String.hash()`, 0
bumped to 1). `GameState` is last-but-one in `[autoload]` order, immediately before `MireGrid`, so
the staged value is guaranteed in place before anything can draw. **Not debug-only**, unlike
`core/dev/dev_launch.gd`'s `--host`/`--lan-join=` family — `autoload/steam_lobby.gd`'s
`STEAM_CONNECT_LOBBY_ARG` already establishes a retail-build cmdline arg reaching an autoload as
normal here, and a Steam "Launch Options" field is the one channel solo/offline play can actually
use to set this.

**Usage:** launch with `--seed=<integer>` or `--seed=<any text>` (hashed). No UI, no console command
— purely a launch-time override, same shape a player would set in Steam's Properties → Launch
Options.

**Verified:** `agent godot --script tools/seed_launch_arg_check.gd -- --seed=204060517`, twice back
to back, `SEED_LAUNCH_ARG_CHECK failures=0`, all 8 assertions PASS — including that `MireGrid`'s own
real boot-time draw (not a value the check script drew itself) used the launch-arg seed. No
regression: `tools/main_menu_check.gd` (28/28) and `tools/seed_sync_check.gd` (12/12) both stayed
clean. Full spec/rationale: `docs/SPECS.md`'s F-172 block.

### 2026-08-18 — F-164: a capped Wellspring's re-corruption clock gets an ambient HUD warning; `WellspringHud` finally gets registered (lp)

Two gaps, both closed here. The filed finding was the missing warning; reading `ui/hud/
wellspring_hud.gd` before touching it surfaced the bigger one — `WellspringHud` had **never been
added to `[autoload]`**, so the whole Wellspring HUD (the task 4.8 capping prompt included, not just
this task's addition) has been unreachable in the live game since 4.8 shipped. Fixed via `agent
autoload WellspringHud res://ui/hud/wellspring_hud.gd` — a script nothing loads isn't shipped
(AGENTS.md, D-039).

`ui/hud/wellspring_hud.gd` gained a second, top-centre panel independent of the existing bottom-centre
capping prompt: `_refresh_recorruption_warning()`, polled on the same cadence as the existing
`_refresh_nearby()`/`_refresh_panel()` pair but scanning every `wellspring`-group member rather than
just `_nearby` (which structurally only ever tracks an UNCAPPED Wellspring in range — it cannot see a
capped-and-recorrupting one). Shows once ANY capped Wellspring's `recorruption_sec` crosses
`Wellspring.RECORRUPTION_DURATION_SEC * Wellspring.RECORRUPTING_VISUAL_FRACTION` (the same fraction
the in-world mesh already swaps at) with an m:ss countdown to the nearest one and a count when more
than one is past it — deliberately NOT gated on proximity or on "Wellsprings the local player
personally capped" (no per-player cap-history exists anywhere to key that on; full reasoning in
`docs/SPECS.md`'s new F-164 block).

`agent godot --script tools/wellspring_hud_check.gd` → `WELLSPRING_HUD_CHECK failures=0`, 11/11 PASS,
run twice. No regressions: `wellspring_check.gd`, `wellspring_recorruption_check.gd` both
`failures=0`. `agent godot --quit-after 20` — zero `ERROR:` lines, `WellspringHud` present in
`project.godot`'s `[autoload]`.

**For any future Wellspring-adjacent consumer:** the ambient panel is `WellspringHud._warning_panel`/
`_warning_label`, refreshed by `WellspringHud._refresh_recorruption_warning()` — read that function
rather than re-deriving the threshold if you need the same "is anything currently recorrupting" read
elsewhere (a minimap marker, a compass ping). It has no signal of its own yet; it is a poll, the same
shape `_refresh_nearby()` already used for the in-range prompt.

### 2026-08-18 — Task 5.5: Boss framework — phases, arena leash, per-phase telegraphed moves, replicated health-bar seam, EventBus music-stinger hooks (lp)

No new §2.2 authority row (D-116, same reasoning D-112 gave 7.8) — `Boss extends Enemy`
(`systems/enemies/boss.gd`, new) and inherits the existing "Enemies: HOST" row verbatim. **No block
existed for this task; docs/SPECS.md §5.5 is new.** `systems/enemies/enemy.gd` was claimed by lane lm
(7.7) for this task's whole session — `Boss` needed zero edits to it; every extension point was
already a plain overridable method or an inherited member var (D-116 has the full list and the
general lesson).

**New content-family files, `EnemyDef`'s own shape extended, not replaced:**

```gdscript
# systems/enemies/boss_move_def.gd — class_name BossMoveDef extends Resource
# One telegraphed attack: id, damage, range_m, tell_seconds/attack_seconds/recovery_seconds,
# weight (selection odds within a phase), tell_animation/attack_animation (clip names).

# systems/enemies/boss_phase_def.gd — class_name BossPhaseDef extends Resource
# hp_threshold_fraction (author phases in DESCENDING order, phase 0 = 1.0), moves: Array[BossMoveDef]
# (empty is valid — falls back to EnemyDef's one fixed attack), move_speed_multiplier, seals_arena
# (task 5.5's "arena flag" — see D-116 point 2 for why this is a leash, not geometry), music_cue.

# systems/enemies/boss_def.gd — class_name BossDef extends EnemyDef
BossDef.phases: Array[BossPhaseDef]
BossDef.arena_radius_m: float                          # default 30.0
BossDef.engage_music_cue / defeat_music_cue: StringName # read by BossMusicDirector; unused today,
                                                         # the wiring point for a future per-boss cue
BossDef.phase_for_health_fraction(fraction: float) -> int
BossDef.validation_errors() -> PackedStringArray        # extends EnemyDef's own; also checks phase
                                                         # ordering and phases[0].hp_threshold==1.0
```

**`Boss` (`systems/enemies/boss.gd`) public API for 5.6/5.7/5.8 to build against:**

```gdscript
Boss.phase: int                    # replicated. -1 (DORMANT_PHASE) until first engagement, then an
                                    # index into BossDef.phases, monotonic (never regresses).
Boss.move_index: int                # replicated. -1 when no move in flight; else an index into the
                                    # ACTIVE phase's own `moves` array — read this, not a cached move,
                                    # for presentation on every peer.
Boss.arena_center: Vector3          # fixed at spawn position, read-only in practice.
Boss.health_fraction() -> float     # 0..1, safe against null/zero-health def.
Boss.phase_count() -> int           # 1 for a plain EnemyDef/empty-phases BossDef.
Boss.is_engaged() -> bool           # phase != DORMANT and not dead — what a HUD gates visibility on.
Boss.is_alive() -> bool             # inherited from Enemy, unchanged.
```

**`EnemyWorld` (`autoload/enemy_world.gd`) — one new branch, everything else unchanged:**
`_net_spawn_enemy()` now instantiates `Boss` (not the plain `Enemy` script) whenever the spawned def
`is BOSS_DEF` — the same replicated payload every peer already builds identically from, so this
costs no new RPC. `_load_defs()` needed no change: `res is ENEMY_DEF` already accepts a `BossDef`
since it extends `EnemyDef`.

**Three new `EventBus` events (`core/events/event_bus.gd`) — the music-stinger hooks:**

```gdscript
EventBus.subscribe_boss_engaged(listener)         # (boss_id: StringName, world_position: Vector3)
EventBus.subscribe_boss_phase_changed(listener)   # (boss_id, previous_phase: int, new_phase: int, world_position)
EventBus.subscribe_boss_defeated(listener)        # (boss_id: StringName, world_position: Vector3)
```

All three fire from a REPLICATED property's own setter (`Boss.phase`'s setter for the first two,
`Boss._play_state_animation()` — itself already invoked from `Enemy.state`'s replicated setter — for
the third), never from a host-only guard. This is the D-107/D-108 fix pattern applied from the start;
`Wellspring.capped`'s setter now applies it on both its transitions (F-168 fixed `wellspring_capped`
on false→true, F-181 fixed the identical bug on `wellspring_recorrupted`'s true→false transition).

**`BossMusicDirector` (new autoload, client-local) and `BossHealthHud` (new autoload, client-local,
`ui/hud/boss_health_hud.gd`)** subscribe to the three events / poll the `bosses` group respectively —
neither has a public API beyond `BossMusicDirector.play_cue(cue_id: StringName)` (the seam a future
per-boss cue routes through; today only `&"boss_stinger"` exists in `CUE_PATHS`). Both registered in
`project.godot` via `agent autoload` (F-051).

**New audio asset:** `assets/audio/music/boss_stinger.ogg` — `tools/audio/render_music.py`'s new
`BOSS_STINGER` config + `render_stinger()` function, a ~7.2s non-looping one-shot (impact in the
first ~1.1s, the rest its own reverb tail) built from NIGHT's own palette (D-066). Re-render with the
script's existing `main()`; **running it also re-renders `ambient_day.ogg`/`ambient_night.ogg`, which
came out numerically identical but NOT byte-identical to the committed files on this machine — F-176,
not fixed here, `git checkout --` them if `main()` is ever re-run.**

**Not built — deliberately, see `boss_def.gd`'s own header and D-116:** no worked-example `.tres`
boss content ships with this task. 5.6/5.7/5.8 own the three real bosses; `tools/boss_check.gd`
proves the whole framework against synthetic `BossDef`/`BossPhaseDef`/`BossMoveDef` trees instead, the
same shape `enemy_ai_check.gd` already established as acceptable. Also not built: any PHYSICAL arena
wall/pylons — `BossPhaseDef.seals_arena` is a data flag a boss-content task turns into real geometry
(`docs/ASSET_TRACKER.md` A-027's "arena pylons"); the framework's own arena enforcement is a
leash on the boss's own acquisition/retention only (D-116 point 2).

Verified: `agent godot --script tools/boss_check.gd` (new, 45 assertions) — `failures=0`. No
regressions: `tools/enemy_check.gd`, `tools/enemy_ai_check.gd`, `tools/enemy_net_check.gd`,
`tools/entity_check.gd`, `tools/combat_feel_check.gd` all `failures=0` unmodified;
`tools/enemy_facing_check.gd` (needs `--windowed`, F-077) still renders; `tools/enemy_crawler_check.gd`
still `ok` on every asset. `tools/audio_import_check.gd` extended with a stinger-specific assertion
group (the one-shot doesn't fit its prior "every music file is a 224s loop" assumption) —
`failures=0`. Full boot (`agent godot --quit-after 20`): 0 `ERROR:` lines, both new autoloads silent
until a boss actually engages (verified nothing plays/shows on a bare boot).

### 2026-08-19 — Task 7.5: Settings — graphics/audio/sensitivity/FOV/keybinds/accessibility, `SettingsService` autoload + real controls in 6.10's shell (lm)

No new §2.2 authority row — everything here is client-local presentation (docs/DECISIONS.md D-114
has the four scope calls: JSON persistence over `ConfigFile`, runtime-created audio buses over a
`.tres` layout, keyboard-only keybind scope, "reduce camera motion" as the one accessibility
control). `docs/SPECS.md`'s new `## 7.5` block is the full spec; this is the API surface the next
task builds against.

**`SettingsService` (new autoload, registered last via `agent autoload` — D-021 append-only) — the
one seam that owns every setting:**

```gdscript
SettingsService.graphics_preset() -> int                         # GraphicsQuality.Preset int (0/1/2)
SettingsService.set_graphics_preset(preset: int) -> void         # delegates to GraphicsQuality.apply()

SettingsService.master_volume() / music_volume() / sfx_volume() -> float   # linear 0..1
SettingsService.set_master_volume(v) / set_music_volume(v) / set_sfx_volume(v) -> void
# Drives the AudioServer "Master"/"Music"/"SFX" buses (Music+SFX created at _ready() if missing,
# both sending to Master); 0 mutes the bus, any positive value maps through linear_to_db().

SettingsService.look_sensitivity() -> float        # clamped [0.01, 1.0], default 0.12
SettingsService.set_look_sensitivity(v: float) -> void
SettingsService.invert_y() -> bool
SettingsService.set_invert_y(v: bool) -> void
SettingsService.fov_degrees() -> float              # clamped [60, 110], default 75.0
SettingsService.set_fov_degrees(v: float) -> void
SettingsService.reduce_camera_motion() -> bool      # suppresses PlayerCamera shake + sprint FOV pulse
SettingsService.set_reduce_camera_motion(v: bool) -> void

SettingsService.rebindable_actions() -> PackedStringArray   # the 10 keyboard-primary actions;
                                                             # "attack" (mouse-primary) is excluded
SettingsService.keybind_label(action: StringName) -> String
SettingsService.rebind_action(action: StringName, event: InputEventKey) -> StringName
    # "" on success; else the OTHER rebindable action already holding that physical key — two
    # actions can never share one, refused rather than silently double-bound.
SettingsService.reset_keybinds() -> void            # InputMap.load_from_project_settings()

signal SettingsService.settings_changed   # fires after every setter; PlayerCamera and SettingsMenu
                                           # both refresh from this rather than a bespoke callback
```

Persists to `user://settings.json` via `core/save/settings_save.gd` — same schema-versioned
migrate-in-place JSON shape as `SalvageSave`/`UnlockSave`, same `save_path` override +
`_persistence_enabled()` D-107 guard a check overrides to avoid touching a real save file.

**`PlayerCamera` (`entities/player/player_camera.gd`) now reads sensitivity/invert-Y/FOV/
reduce-motion from `SettingsService` if present**, applied at `_ready()` and again on every
`settings_changed` — its own `@export` values are only the fallback for a scene run without that
autoload (a check, say). `add_shake()` is a no-op while `reduce_camera_motion()` is true.

**`combat_service.gd`/`ranged_combat_service.gd`'s impact SFX now play on the `SFX` bus**
(`player.bus = &"SFX"`), the only production code that plays a sound today — the SFX slider actually
covers something. **Ambient music is still unwired** (7.1/7.2's own delegation note stands); the
`Music` bus exists and sends to `Master` so a future `MusicDirector` has somewhere to play into, but
the Music slider has no audible effect until that task lands.

**`SettingsMenu` (`ui/menu/settings_menu.gd`)** fills 6.10's shell: GRAPHICS/AUDIO/LOOK/
ACCESSIBILITY/KEYBINDS sections inside a `ScrollContainer`-wrapped `SettingsStack`, every control a
thin view calling straight into `SettingsService` — the file owns no settings state of its own.
Opening the menu (`set_open(true)`) calls a private `_refresh_from_settings()` that repopulates every
control from the live singleton. No new public API beyond 6.10's own `set_open()`/`is_open()`/
`request_close()`.

**Verified:** `agent godot --script tools/settings_check.gd` — 51 assertions, `failures=0`.
No regressions: `combat_check`, `ranged_combat_check`, `main_menu_check`, `build_check`,
`combat_feel_check`, `verify_setup` all stay `failures=0`. `agent godot --quit-after 15`: 0
`ERROR:` lines on a full boot.

### 2026-08-19 — Task 5.9: Wave director — Cycle-aware pacing, composition weighting on top of the player-count scaling and roster-unlock that already shipped (lp)

No new §2.2 row, no new RPC — `systems/waves/wave_spawner.gd` already declared "Day/night, wave
director, Cycle state, active modifiers: HOST" (task 2.12) and this task adds no new replicated
state, only a host-side read of `CycleService.current_cycle()` via the existing
`EventBus.subscribe_cycle_advanced` seam (the same one `CycleModifierService` already uses).
**No SPECS.md block existed for this task — writing one was part of it (docs/SPECS.md §5.9).**

**Public API `WaveSpawner` gained:**

```gdscript
WaveSpawner.current_cycle() -> int                       # cached from EventBus.cycle_advanced, defaults 1
WaveSpawner.cycle_count_multiplier(cycle: int = current) -> float  # 1.0 + (cycle-1)*0.15, capped 2.5 at Cycle 11
```

`host_start_wave()`'s size formula is now
`roundi((base_count + per_player * live_player_count) * cycle_count_multiplier())` — additive and
capped, deliberately NOT compounding the way `CycleService.SPREAD_ESCALATION_PER_CYCLE` does
(DESIGN.md §5.4: replayability comes from stacking Cycle Modifiers, not raw enemy volume; an
uncapped multiplicative count in an endless run is also a real performance cliff, F-144's class of
problem). At Cycle 1 the multiplier is exactly 1.0, so every pre-existing wave-size assertion in
`tools/wave_spawner_check.gd` needed no change — verify this is still true before touching the
formula again.

`_roll_roster()` (the "which archetype spawns" roll, previously flat/even odds forever) is now
weighted: `enemy_id` keeps weight 1, the Nth unlocked archetype (1-indexed, unlock order) gets weight
`N + 1` — the most-recently-unlocked archetype is always the single most common pick. `roster_order`
still ships with only `bog_crawler` (D-100 — 5.2 owns growing real content); this task only changed
the ODDS across whatever `roster_order` already contains, no new `.tres`.

`host_spawn_wave_at()` (4.8's Wellspring defense wave) is untouched — an explicit `count` and
(optionally) explicit `wave_enemy_id` bypass both the Cycle multiplier and the roster roll entirely,
same as before this task. Pass `wave_enemy_id = &""` explicitly to force a (now-weighted) roster
roll instead of the default `enemy_id` — this is how `tools/wave_director_check.gd` samples
composition without waiting for a real night.

Verified: `agent godot --script tools/wave_director_check.gd` (new, 19 assertions) failures=0 —
multiplier curve at Cycle 1/6/11(cap)/20(still capped), a real `host_start_wave()` at Cycle 1 matches
the pre-task formula exactly, a real one at Cycle 6 scales by 1.75x and the field actually holds that
many bodies, an explicit `override_count` still bypasses the multiplier, a 600-body weighted-roster
sample lands bog_crawler's observed share (0.650) inside its expected 2:3 weight — deterministic
under the fixed `DEFAULT_SEED`, not a flake-prone tolerance. No regressions: `wave_spawner_check.gd`,
`cycle_check.gd`, `cycle_modifier_check.gd` all still failures=0 unmodified. 0 `ERROR:` on a full
boot (`agent godot --quit-after 20`).

### 2026-08-19 — Task 7.8: Network robustness — audited every specific-peer `rpc_id()` in the repo against F-059's guard pattern, fixed the five that lacked it (lm)

No new autoload, no new RPC, no new §2.2 row (D-112 explains why: this task added no new simulated
state, so there is nothing new to declare authority over — same shape `net_version.gd`/`NetTransport`
already have). "Packet loss / high latency" turned out to mean auditing what already handles them
(Godot's ENet bindings expose no loss/latency injection at all — checked directly via
`ClassDB.class_get_method_list()`, D-112 has the detail) rather than building a simulator nothing else
needs. "Hostile disconnect timing" turned out to be a real, findable bug class: `docs/FINDINGS.md`
F-059 fixed one unguarded specific-peer `rpc_id()` send and left `NetTransport.has_peer(peer_id)` as
the pattern for every other one. This task grepped every `rpc_id(` call site in the repo against that
pattern and fixed the five that had not adopted it:

```gdscript
# All five gained the same one-line guard — `and NetTransport.has_peer(peer_id)` (or a private
# `_peer_connected(peer_id)` helper in the same shape PlayerHealth/PowerupService/BuildService/
# RuleService already carry) before the rpc_id() send:
autoload/combat_service.gd          CombatService._reject
autoload/ranged_combat_service.gd   RangedCombatService._reject
autoload/crafting_service.gd        CraftingService._confirm_peer
autoload/command_service.gd         CommandService.net_submit_command's reply (the `await execute()`
                                     inside the RPC handler is the disconnect window)
autoload/world_delta_log.gd         WorldDeltaLog._on_peer_admitted
```

**If you are about to write a new `rpc_id(peer_id, ...)` that targets someone other than the sender of
the RPC currently executing, it needs this guard from the start** — a reply after an `await`, a
broadcast to a specific "known peer" while iterating a roster, a snapshot sent off a lifecycle signal.
D-035's 90 s post-disconnect grace window is what makes an unguarded send a standing hazard rather than
a one-off: a departed peer id is a live dictionary key for a minute and a half in any session that
runs long enough to hit it, and Godot's answer to `rpc_id()` at an id it does not recognise is
`ERROR: Attempt to call RPC with unknown peer ID`, not a silent no-op.

**Public API for verifying this class of bug in the future:** `tools/net_robustness_check.gd` (new) —
hosts a real LOCAL session and drives each of the four directly-callable sites above against a peer id
that was never admitted (`GHOST_PEER = 999919`, outside ENet's real id range), plus checks
`CommandService._peer_connected()` answers correctly for a ghost id and a real one. The check's own
header comment shows the exact `agent baseline` invocation that reproduces the bug against a pre-fix
revision — the same before/after methodology F-059's own resolution note used.

Verified: `tools/net_robustness_check.gd` — 0 failures, and (reverting the five guards first) the exact
same run reproduces `ERROR: Attempt to call RPC with unknown peer ID: 999919` at every directly-driven
site, restored and re-ran clean three times. No regressions: `combat_net_check`, `ranged_combat_net_check`,
`crafting_check`, `command_net_check`, `seed_sync_check`, `mire_grid_check` all `failures=0`/`0
failure(s)`. (`crafting_net_check` fails 24/24 — reproduced identically against a clean `agent
baseline` checkout of HEAD, pre-existing and unrelated, F-167.) 0 `ERROR:` on a full boot (`agent godot
--quit-after 15`).

### 2026-08-19 — Task 6.9: Unlock tree + UI — full framework; the first gate is wired now, see F-173's own entry above (lm)

New content family `UnlockDef` (`systems/unlocks/unlock_def.gd`) + `content/unlocks/` (one worked
example, `unlock_deep_pocket.tres`, D-073) + `autoload/unlock_service.gd` (new) +
`ui/menu/unlock_menu.gd` (new, autoload `UnlockMenu`). Authority: new §2.2 row "Unlocks" — **None**,
same shape as Salvage (task 6.6): per-player `user://unlocks.json`, no two peers ever compare
purchased sets. "Salvage unlocks variety, never power" (DESIGN.md §4.6) is enforced by `UnlockDef`'s
schema having no stat/bonus field at all, not by a runtime check.

**Public API** (the first real gate now consumes `is_content_unlocked()` — see this file's F-173
entry above for `LootTableDef.roll()`'s new `is_unlocked` param and `Chest._unlock_check()`; D-111
still gates whoever wires POI placement or the enemy roster next):

```gdscript
UnlockService.is_purchased(unlock_id: StringName) -> bool        # this peer's own purchased set
UnlockService.purchased_ids() -> Array[StringName]
UnlockService.is_content_unlocked(content_id: StringName) -> bool
    # true if nothing gates content_id, or its UnlockDef is purchased; false if gated + not bought.
    # Matches against every UnlockDef's own `gates_id` field, NOT the unlock's own `id`.
UnlockService.purchase(unlock_id: StringName) -> bool
    # Spends via SalvageService.spend_salvage(cost) and marks purchased, as one attempt — false
    # (nothing changed either side) if already owned, unknown, persistence disabled, or too poor.
```

```gdscript
SalvageService.spend_salvage(amount: int) -> bool
    # New this task, the inverse of the existing _bank(): refuses the WHOLE thing (balance + disk
    # both untouched) on a non-positive amount, disabled persistence (D-107's guard), or a short
    # balance. The one Salvage sink other than banking; reuse this rather than writing
    # total_salvage directly for any future spend.
```

```gdscript
EventBus.subscribe_unlock_purchased(listener: Callable)   # (unlock_id, cost, total_salvage) -> void
EventBus.emit_unlock_purchased(unlock_id, cost, total_salvage)
    # Fires once per successful purchase, on the peer that made it. Same "future task's hook" role
    # salvage_banked plays for 6.8 — nothing here shows UI or gates a pool by itself.
```

```gdscript
Registry.unlock_defs() -> Dictionary        # StringName -> UnlockDef, keyed by unlock id
Registry.get_unlock(id: StringName) -> Resource
Registry.has_unlock(id: StringName) -> bool
```

`UnlockMenu` (opened only from `MainMenu`'s new UNLOCKS button, no hotkey of its own — same
"sub-panel hands off, doesn't stack" shape D-032 already gives `SettingsMenu`):

```gdscript
UnlockMenu.set_open(open: bool) -> void
UnlockMenu.is_open() -> bool
UnlockMenu.request_close() -> void
UnlockMenu.request_purchase(unlock_id: StringName) -> bool   # wraps UnlockService.purchase(), refreshes rows
UnlockMenu.status_text() -> String
UnlockMenu.balance_text() -> String
UnlockMenu.row_count() -> int
MainMenu.request_open_unlocks() -> void   # new — closes MainMenu, opens UnlockMenu
```

**Wired now, F-173 (see this file's own entry above for the shipped shape):** the worked example
gates the real `deep_pocket` PowerupDef (already rolled by `content/loot/bog.tres`) through
`LootTableDef.roll()`'s new `is_unlocked` Callable. **Still not built, D-111's other half:**
POI placement and the enemy roster need state byte-identical across every peer, which this same
"only ever ask the host" pattern cannot give them without either replicating purchases or making
unlocks session-wide — read D-111 before assuming this fix's pattern extends there directly.

Verified: `tools/unlock_check.gd` (40+ assertions, 0 failures) — schema-level "never power" via
`UnlockDef.validation_errors()`, `spend_salvage()`/`purchase()` refuse-the-whole-thing on every
failure path, a successful purchase charges once/persists/fires the event, a repeat purchase is
refused without double-charging, `is_content_unlocked()` flips false→true across a real purchase,
`UnlockMenu`'s open/close/D-032-exclusivity/BUY-button state, and `UnlockSave` versioning
(migration, corrupt-file fallback, round trip). No regressions: `salvage_check`, `main_menu_check`,
`defeat_check`, `extraction_check`, `wellspring_recorruption_check`, `crafting_check`,
`cycle_check`, `cycle_modifier_check`, `mire_grid_check`, `mire_interaction_check`,
`wave_spawner_check` all stay `failures=0`. 0 `ERROR:` on a full boot (`agent godot --quit-after
15`).

### 2026-08-19 — Task 6.10: Main menu shell, settings shell, seed entry ship — the lobby-UI slice's own handoff closed out (lm)

**What shipped, verified:** `ui/menu/main_menu.gd` (new autoload `MainMenu`, F1 to open, CanvasLayer
layer 57) and `ui/menu/settings_menu.gd` (new autoload `SettingsMenu`, layer 58, opened only from
`MainMenu`) — both registered in `project.godot`. `core/game_state.gd` gained a UI-facing seed
override. D-110 records the three scope calls (no auto-open/no Esc binding, seed stages through
`GameState` not a new field, settings ships as a shell not 7.5's content); F-172 records the one gap
left open (solo play draws its seed before any menu can stage one).

**`MainMenu` API — client-local, no authority of its own:**

```gdscript
MainMenu.set_open(open: bool) -> void         # refuses to open while another blocks_gameplay_input
                                                # node holds the group (D-032)
MainMenu.is_open() -> bool
MainMenu.request_set_seed() -> void            # stages _seed_field's text via GameState.set_pending_seed
MainMenu.request_random_seed() -> void         # clears a staged override
MainMenu.request_open_multiplayer() -> void    # closes MainMenu, opens LobbyMenu
MainMenu.request_open_settings() -> void       # closes MainMenu, opens SettingsMenu
MainMenu.seed_field_text() / set_seed_field_text(text: String)
MainMenu.status_text() -> String
```

**`SettingsMenu` API — the shell 7.5 builds its controls into:**

```gdscript
SettingsMenu.set_open(open: bool) -> void      # same D-032 exclusivity as every other panel
SettingsMenu.is_open() -> bool
```

7.5 adds its rows as children of the `VBoxContainer` named `SettingsStack` inside
`ui/menu/settings_menu.gd`'s `_build_ui()` — everything else in that file (shading, centering,
panel style, open/close, the blocking group) stays as-is.

**`GameState` seed-staging addition (4.6's `run_seed`/`host_generate_seed`/`ensure_seed`/
`set_replicated_seed`/`is_seed_ready` are all unchanged):**

```gdscript
GameState.set_pending_seed(value: int) -> void   # 0 clears; anything else stages it
GameState.has_pending_seed() -> bool
GameState.pending_seed() -> int
# host_generate_seed() now checks the staged value FIRST, consuming it once, before falling back
# to real entropy exactly as before. ensure_seed() and set_replicated_seed() are untouched.
```

A staged seed only ever affects the process that staged it, and only that process's own next
`host_generate_seed()`/`ensure_seed()` draw — it is never sent over the wire on its own (4.6's
existing `WorldDeltaLog` snapshot is still what gets a DRAWN seed to a joining peer).

**Verified:** `agent godot --script tools/main_menu_check.gd` — 29 assertions, 0 failures. No
regressions: `lobby_menu_check` (F-170 fixed 2026-08-19 — was 5 pre-existing failures on a machine
with a real Steam client running; now `failures=0` on either machine state, see F-170's Resolved
entry),
`seed_sync_check`, `mire_grid_check`, `resource_scatter_check`, `defeat_check`, `handshake_check`,
`net_check_pattern_check`, `inventory_ui_check` all `failures=0` (`crafting_ui_check`'s 19 failures
are also pre-existing per F-171, unrelated). `agent godot --quit-after 15`: 0 `ERROR:` lines.

### 2026-08-19 — Task 6.7: Lose condition — team wipe / island consumed, defeat flow (lm)

New `autoload/defeat_service.gd` (registered) + `ui/hud/defeat_hud.gd` (registered, after
`SalvageService`). Authority: new §2.2 row "Lose condition" — **Host** decides, a reliable broadcast
RPC (`net_run_defeated`) carries the verdict to every peer, not a `MultiplayerSynchronizer` (D-109).
Finally fires `EventBus.run_wiped`, the seam task 6.6 built and left waiting.

**Public API for 6.8 (run summary) and anything else that needs to know how a run ended:**

- `DefeatService.is_defeated() -> bool` — true once the verdict has landed, on every peer (the host
  decided it; a client learned it over the wire). Terminal for the session.
- `DefeatService.cause -> StringName` — `&"team_wipe"` or `&"island_consumed"`, readable directly as
  a property (`defeat_service.get(&"cause")` from a `--script` harness, `DefeatService.cause` from
  real game code). Set before `defeated` flips true, so a `run_wiped` subscriber reading it back
  never sees the old value.
- `EventBus.subscribe_run_wiped(listener)` — already existed (task 6.6); this task is what finally
  emits it, from every peer's own `defeated` setter, never a host-only guard.
- `MireGrid.consumed_fraction(threshold: float) -> float` — host-only (mirrors `corruption_at()`'s
  own peer split), what fraction of the 256x256 grid sits at/above `threshold`. `DefeatService`'s own
  consumer, but generic enough for a future HUD warning (F-164's own open gap) to poll too.
- `PlayerHealth._run_over` (private, but worth knowing about) — latches true on `run_wiped` and
  freezes `_physics_process`/`host_apply_damage`. Nothing downstream should need to read this
  directly; `DefeatService.is_defeated()` is the public answer to "is the run over".

**Not built:** any scene transition or return-to-menu flow. `ui/hud/defeat_hud.gd` shows a
full-screen overlay and blocks input, but nothing here ends the Godot session or returns to a main
menu — that infrastructure does not exist anywhere yet (a successful extraction has no win screen
either). `NetTransport.leave()` is the seam a future "return to menu" button would call.

Verified: `tools/defeat_check.gd` (24 assertions, 0 failures) — `consumed_fraction()` math, team-wipe
requires every present peer down (not just one), the verdict is terminal and freezes `PlayerHealth`
against both further damage and auto-respawn, island-consumed fires independently, and
`net_run_defeated` (the code path an actual client takes) drives the same setter and reaches
`EventBus.run_wiped` on its own — the check that actually proves D-108's requirement. No
regressions: `player_health_check`, `player_vitals_check`, `extraction_check`, `salvage_check`,
`mire_grid_check`, `mire_interaction_check`, `wellspring_recorruption_check`, `cycle_check`,
`cycle_modifier_check`, `wave_spawner_check` all stay green. 0 `ERROR:` on a full boot (`agent godot
--quit-after 15`).

### 2026-08-19 — Task 6.6: Salvage — superlinear reward curve, extract-vs-die split, persistence, save-file versioning (lm)

New `autoload/salvage_service.gd` (registered) + `core/save/salvage_save.gd` (pure data I/O, no
autoload). Authority: **None** — per-player account state, `docs/ARCHITECTURE.md` §2.2's new
"Salvage" row. `EventBus.subscribe_run_extracted()` (6.5) banks `reward_for_cycle(cycle)` in full;
a new `EventBus.subscribe_run_wiped(cycle, world_position)` counterpart banks
`DEATH_BANK_FRACTION` (0.5) of it — nothing emits `run_wiped` yet, that is 6.7's job (D-108).

**Public API for 6.7, 6.8, 6.9 to build against:**

- `SalvageService.total_salvage() -> int` — this peer's own lifetime balance, cached in memory and
  kept in sync with `user://salvage.json` on every bank.
- `SalvageService.reward_for_cycle(cycle: int) -> int` — the Cycle curve plus this run's milestone
  bonus, BEFORE any death fraction. `CYCLE_BASE = 10`, `CYCLE_EXPONENT = 1.6` (superlinear:
  Cycle 3 = 58, Cycle 9 = 336). Placeholder-tuned, no playtest yet (Q6).
- `EventBus.subscribe_run_wiped(listener: Callable)` — listener signature
  `(cycle: int, world_position: Vector3) -> void`. **6.7 must fire this exact signal** (D-108) —
  `SalvageService` is already wired to only this name, not a second lose-condition event — **and
  must fire it from a replicated property's setter**, the same fix this task made to
  `ExtractionShip.departed` (D-107's sibling), never from a host-only guard: `EventBus` is a
  per-process static, so a host-only emit never reaches a client's own local bus, and that peer's
  Salvage would never bank a death.
- `EventBus.subscribe_salvage_banked(listener: Callable)` — listener signature
  `(earned: int, total_salvage: int, cycle: int, extracted: bool) -> void`, fired once per bank on
  the peer that just banked. This is 6.8's ("run summary... Salvage earned") seam — nothing here
  shows UI.
- `core/save/salvage_save.gd` — `SalvageSave.load_data(path := SAVE_PATH)` /
  `SalvageSave.save_data(data, path := SAVE_PATH)`, `SAVE_PATH = "user://salvage.json"`,
  `SCHEMA_VERSION = 1`. Both take an explicit path override — that is how `tools/salvage_check.gd`
  proves persistence without touching a real save, and the same override point 6.9 should reuse if
  its own unlock-tree save wants a sibling file rather than a new top-level key on this one.
- **D-107's test-isolation guard — read this before writing any new `user://`-persisting
  autoload.** `SalvageService._persistence_enabled()` gates every disk write on
  `save_path != SalvageSave.SAVE_PATH or get_tree().current_scene != null`, because a `--script`
  check that legitimately fires a real `run_extracted`/`wellspring_capped` for its OWN system's
  test (confirmed with `extraction_check.gd`) reaches this autoload exactly like the shipped game
  would — it banked 116 real Salvage into a developer's actual save file before the guard existed.
  6.9's own persistence needs the identical guard shape, not a rediscovery of the bug.
- **Fixed (F-168, F-181):** `Wellspring.capped`'s setter now fires `wellspring_capped` on the
  false->true transition and `wellspring_recorrupted` on the true->false transition, same as
  `_finish_cap()`/`_finish_recorruption()` used to do from their host-only bodies — so the milestone
  bonus above no longer undercounts on non-host peers. Nothing subscribes to `wellspring_recorrupted`
  yet, so F-181 had no live undercount to fix (it closes the gap before any future subscriber, e.g. a
  recorruption Salvage penalty, would have inherited it). The Cycle-curve half of the reward was
  never affected (`CycleService.current_cycle()` already replicates correctly via `WorldDeltaLog`).

Verified: `tools/salvage_check.gd` (24 assertions, 0 failures) — curve, milestone bonus, both
banking paths, persistence round-trip, save-file versioning/migration/corruption-fallback, and that
`salvage_banked` fires with the right payload. No regressions: `extraction_check`,
`wellspring_recorruption_check`, `cycle_check`, `cycle_modifier_check`, `mire_grid_check`,
`mire_interaction_check`, `wave_spawner_check`, `crafting_check`, `handshake_check` all stay
`failures=0`. 0 `ERROR:` on a full boot (`agent godot --quit-after 15`), and no run leaves a real
`user://salvage.json` behind any more.

### 2026-08-19 — Task 6.5: Extraction — shipwreck repair, board-to-leave, group confirm hold (lm)

New `class_name ExtractionShip` (`systems/extraction/extraction_ship.gd`), the same host-authoritative
harvest-pattern shape as `Wellspring`: three repair stages consuming mid-tier resources from a
`repair_hammer`-holding player in range (`net_request_repair`), then, once fully repaired, a
presence-gated departure hold requiring the WHOLE connected session aboard together for 60s
(`net_request_toggle_departure`) — cancel forfeits progress, stepping off deck only pauses it, D-105's
exact reuse of D-092's ritual rule. New `autoload/extraction_service.gd` (registered) bridges a
`shipwreck`-kind `authored_world_marker` to a live `ExtractionShip`, identical split to
`wellspring_service.gd`. New `ui/hud/extraction_hud.gd` (registered as `ExtractionHud` — unlike
`wellspring_hud.gd`, which ships the same pattern but was never added to `[autoload]`, F-165's sibling
gap) shows the repair-cost prompt or the departure-hold bar depending on range and `repair_stage`.

**Not reachable in the live game yet.** `world/gen/authored_world.gd` has no `shipwreck` marker kind
(F-166) — it was held by another lane's claim this whole session, so this task could not add one.
`tools/extraction_check.gd` (34 assertions, 0 failures) proves the whole state machine against a
synthetic marker instead, the same shape F-139 already established as acceptable for an
unreachable-but-correct system. `PROTOCOL_VERSION` was NOT bumped for the two new RPCs — same
`net_version.gd`-locked-all-session gap F-161 recorded for task 5.3 (F-165 records this one).

No regressions: `wellspring_check`, `cycle_check`, `cycle_modifier_check`, `wave_spawner_check`,
`crafting_check`, `mire_grid_check`, `mire_interaction_check`, `handshake_check` all still
`failures=0`. 0 `ERROR:` on a full boot (`agent godot --quit-after 15`).
(`tools/crafting_net_check.gd` fails 24/24, but `agent baseline` reproduces the identical failure
against a clean checkout of HEAD — pre-existing, unrelated to this task, filed as F-167.)

**Public API for 6.6 (Salvage/persistence) and 6.7 (lose condition) to build against:**

- `EventBus.subscribe_run_extracted(listener: Callable)` — listener signature
  `(cycle: int, world_position: Vector3) -> void`, fired by the host the instant the group's
  departure hold completes. This is the ONLY seam a successful extraction fires — nothing banks
  Salvage, ends the session, or shows a summary here; 6.6/6.8 own all of that.
- `EventBus.subscribe_ship_repaired(listener: Callable)` — listener signature
  `(ship_name: StringName, world_position: Vector3) -> void`, fired once when `repair_stage` reaches
  its final stage (before boarding starts).
- **There is still no `run_wiped`/lose-condition signal anywhere in the codebase.** 6.7 ("Lose
  condition") owns building it — `run_extracted` is not a template for it, since a wipe has no
  "everyone holds a button" moment to hang an RPC off. 6.6's "extract-vs-die split" needs both
  signals to exist before its own work can start; 6.7 is listed after 6.6 on the roadmap but has no
  stated dependency on it, so doing 6.7 first would unblock 6.6 rather than the reverse.
- `ExtractionShip.REPAIR_COSTS: Array[Dictionary]` / `MIN_REPAIR_CYCLE`/`REPAIR_STAGE_COUNT` — the
  repair recipe's tuning numbers, placeholder-tuned like every other Cycle-facing constant in this
  codebase (Wellspring's ritual durations, `CycleService.SPREAD_ESCALATION_PER_CYCLE`). D-106 records
  why these are plain data on the node rather than `RecipeDef` content.

### 2026-08-18 — Task 6.4: Wellspring re-corruption over time ships — a Cycle-gated clock, Ward pause, all four A-008 condition states now live (lm)

Built ahead of 6.3 (D-099's "prerequisite, not a scope grab" shape) — no dependency either way, both
are independent consumers of 6.1's `EventBus.cycle_advanced` seam. Extends `systems/wellspring/wellspring.gd`
(no new autoload, no `project.godot` edit): a capped Wellspring's clock only starts at the NEXT real
Cycle turnover (not the instant it caps), ticks through the existing `host_tick()` seam, and PAUSES —
never resets — while any placed Ward covers its position (`BuildService.ward_radii()`, the same
source `MireGrid` already consumes; ROADMAP.md's own 6.4 line names this "unless Warded" and this
task found that written mandate waiting for it). Finishing flips `capped` back to `false` — the exact
pre-ritual state, so the existing ritual recaptures it with zero special-casing — and fires a new
`EventBus.emit_wellspring_recorrupted()`, `MireGrid`'s seam to undo the per-cap spread-rate reduction
(`_capped_wellsprings` decrements symmetrically with `_on_wellspring_capped()`'s own increment; no
hand-reseed of the cleared radius — the flood-fill regrows it on its own, D-104). All four A-008
condition-state GLBs are live now, not just two: capped below `RECORRUPTING_VISUAL_FRACTION` (0.5)
shows `wellspring_capped.glb`, at/past it shows `wellspring_recorrupting.glb`, uncapped-and-never-capped
shows `wellspring_uncapped.glb`, uncapped-via-full-recorruption shows `wellspring_corrupted.glb`.

`agent godot --script tools/wellspring_recorruption_check.gd` — 24 assertions, 0 failures. No
regressions: `wellspring_check.gd`, `mire_grid_check.gd`, `mire_interaction_check.gd`,
`build_check.gd`, `cycle_check.gd`, `cycle_modifier_check.gd`, `wave_spawner_check.gd` all still
`failures=0`. 0 `ERROR:` on a full boot (`agent godot --quit-after 20`). Full design rationale in
`docs/SPECS.md` §6.4; D-104 records the Cycle-turnover gating, the two placeholder-tuned constants,
the Ward-pause reuse of `BuildService.ward_radii()`, and the no-hand-reseed call. F-164 records the
one deliberate scope cut worth flagging: no HUD/ambient warning exists yet before a Wellspring
finishes decaying — only the in-world mesh swap signals it today.

**Public API for any future consumer (a HUD warning per F-164, an extraction-pacing tool, a future
Wellspring-adjacent system) to build against:**

- `Wellspring.recorruption_sec: float` / `Wellspring.has_recorrupted: bool` — new replicated fields,
  readable on any peer the same way `capped`/`progress_sec` already are (host's own value, or a
  client's synced copy via the existing code-built `SceneReplicationConfig`).
- `EventBus.subscribe_wellspring_recorrupted(listener: Callable)` — listener signature
  `(wellspring_name: StringName, world_position: Vector3) -> void`, fired by the host the instant a
  capped Wellspring's clock finishes. Same shape as `subscribe_wellspring_capped`.
- `MireGrid.capped_wellspring_count() -> int` (pre-existing, task 4.9) now moves in both directions —
  it no longer only grows for the life of a run.
- `Wellspring.RECORRUPTION_DURATION_SEC` / `Wellspring.RECORRUPTING_VISUAL_FRACTION` — placeholder-tuned
  constants (D-104); read these rather than hard-coding a threshold in a future consumer.

### 2026-08-18 — Task 6.2: Cycle Modifier framework ships — deck, draw, stacking, Cycle-weighted rules, incompatibility tags (lm)

New autoload `CycleModifierService` (`systems/cycle/cycle_modifier_service.gd`, registered via
`agent autoload`) draws a `CycleModifierDef` from the deck the instant `EventBus.emit_cycle_advanced()`
fires (6.1's own seam), stacking it permanently and announcing through `WorldDeltaLog` + a new
`EventBus` signal — no new RPC (D-100/D-102's pattern; `net_version.gd`/`handshake_check.gd` held all
session by another lane). `agent godot --script tools/cycle_modifier_check.gd` — 15 assertions, 0
failures. No regressions: `cycle_check.gd`, `mire_grid_check.gd`, `wave_spawner_check.gd` all still
`failures=0`. 0 `ERROR:` on a full boot (`agent godot --quit-after 20`). Full design rationale in
`docs/SPECS.md` §6.2; D-103 records the tags-vs-ids call, the Registry-first content loading (5.3
released `registry.gd` mid-session, so `CycleModifierDef` folded in as a real content family instead
of staying a workaround), and the no-seeded-RNG/no-effect-wiring scope cuts. F-163 records a real
GDScript trap hit while building this (`expr as Array[T]` silently fails to convert an untyped
Array's element type — use the constructor form `Array[T](expr)` instead).

**Public API for 6.3 (content authoring) and any future modifier-effect consumer to build against:**

- `CycleModifierService.active_modifier_ids() -> Array[StringName]` — the stacked modifiers drawn so
  far this run, in draw order, readable on any peer (host's own array, or a client's
  `WorldDeltaLog`-replicated reconstruction).
- `CycleModifierService.has_modifier(id: StringName) -> bool` — the query a future gameplay consumer
  (`DayNight`, `PowerupService`, `MireGrid`, ...) uses to check whether its own modifier is active.
  **No modifier's effect is wired to any gameplay system yet** — this is deliberate framework scope
  (D-103, same shape D-094 gave hooks); 6.3 or a later task is where a real consumer calls this.
- `CycleModifierService.def_for(id: StringName) -> Resource` — the full `CycleModifierDef` (as
  `Resource` — F-016, it is a brand-new `class_name`; read fields via `.get(&"field")`, never a bare
  `CycleModifierDef` type).
- `CycleModifierService.host_draw_modifier(cycle: int) -> StringName` — public and host-guarded so a
  console command or a future forced-draw feature can drive the identical code
  `_on_cycle_advanced()` uses. Returns `&""` on an exhausted/ineligible deck, never a crash.
- `EventBus.subscribe_cycle_modifier_drawn(listener: Callable)` — listener signature
  `(modifier_id: StringName, cycle: int) -> void`, fired by the host the instant a draw happens
  (nothing fires when the deck had no eligible modifier — check `active_modifier_ids()` size for
  that case). **This is the seam a future effect wiring hangs off**, mirroring `cycle_advanced`.
- `content/cycle_modifiers/*.tres` loads through `Registry` like every other content family —
  `Registry.cycle_modifier_defs() -> Dictionary`, `get_cycle_modifier(id) -> Resource`,
  `has_cycle_modifier(id) -> bool`. `CycleModifierService._load_defs()` asks Registry first and only
  falls back to its own direct disk scan when Registry is not under `/root` (a hand-instantiated
  harness) — the identical "front door, then a quieter seatbelt" split
  `RuleService._load_defs()`/`_load_defs_from_disk()` already establishes for rules.

### 2026-08-18 — Task 5.3: ranged combat ships — bow, host-simulated arrow flight, host-authoritative hit validation (lp)

**What shipped, verified:** the whole of `docs/SPECS.md`'s new `## 5.3` block. New content family
`RangedWeaponDef` (`systems/combat/ranged_weapon_def.gd`, `Registry.ranged_weapons` +
`get_ranged_weapon(item_id)`/`has_ranged_weapon(item_id)`, loaded from `content/ranged_weapons/*.tres`
exactly like `weapons`), one worked example (`short_bow.tres` — draw 0.55s, recovery 0.35s, 34 m/s,
4 damage, 60 m range, fires `arrow`). New autoload `RangedCombatService`
(`autoload/ranged_combat_service.gd`, registered via `agent autoload`) owns the whole host state
machine; `CombatService.request_attack()` checks `Registry.has_ranged_weapon()` on the selected
hotbar slot FIRST and hands the whole action to `RangedCombatService.request_shot()` before any melee
state is touched — melee's own `WeaponDef`/`_local_phase`/hitbox logic is completely untouched.

**The API the next ranged-content or ranged-AI task builds against:**
```gdscript
RangedCombatService.request_shot(hotbar_index: int) -> int        # request id, or -1 if locked out
RangedCombatService.ranged_weapon_for_hotbar_index(idx: int) -> RangedWeaponDef   # null if not a bow
RangedCombatService.local_phase() -> Phase                        # IDLE/WIND_UP/COMMIT/RECOVERY
RangedCombatService.local_phase_progress() -> float               # 0..1, WIND_UP/RECOVERY only
RangedCombatService.host_shot_active(peer_id: int) -> bool
signal shot_landed(peer_id, position, damage, target_name)        # host-confirmed connect
signal shot_missed(peer_id, position)                             # host-confirmed non-connect
signal shot_rejected(request_id, detail)
CombatService.placeholder_impact_sound() -> AudioStream            # shared procedural thud, new public accessor
```
Mutual exclusion with melee is two cheap cross-calls, not a shared base class: both
`CombatService.request_attack()` and `RangedCombatService.request_shot()` check the OTHER service's
`local_phase()` before starting, via `get_node_or_null(^"/root/…")` + `.call()` (never a bare
cross-reference between the two, per F-011 — see `systems/combat/aim_util.gd`'s own header for why
`CombatAim` is not shared with melee's tested `_aim_direction()` either, on purpose).

**The trap worth knowing before any future system raycasts against `&"damageable"`:** the physics
collider a raycast hits is not necessarily the damageable node. `Enemy`/`PlayerController` are
`CollisionObject3D` themselves, but `Harvestable` is a plain `Node3D` that finds a CHILD
`CollisionObject3D` for its own collider — a raycast against it returns that anonymous child, which
carries neither the `&"damageable"` group nor `host_apply_damage()`.
`RangedCombatService._damageable_owner(node)` walks UP from the hit collider (itself included,
bounded depth 8) to the nearest ancestor actually in the group; `_resolve_flight()` uses this instead
of trusting the raycast's own `collider`. This task's own first attempt at
`tools/ranged_combat_check.gd` didn't catch the bug until its `TestTarget` was reshaped to match
Harvestable's actual wrapper structure (a bare `StaticBody3D` target would have passed either way) —
worth remembering when writing the NEXT check that raycasts against this group.

**PvP is cut (DESIGN.md §7), enforced here, not (yet) on melee.** `_resolve_flight()` treats a hit
whose damageable owner is also in `&"players"` as a miss — the arrow still physically stops there (no
pass-through to whatever is behind), it simply deals no damage. `CombatService`'s own melee target
search has no equivalent exclusion; out of this task's claim, not chased.

**No `PROTOCOL_VERSION` bump — D-102, F-161 (open).** `core/net/net_version.gd`/`tools/handshake_check.gd`
were held by lane slate17's 3.7 claim all session. The three new RPCs (`net_request_shot`,
`net_shot_fired`, `net_shot_resolved`) are live and both new checks prove them over a real two-process
ENet connection; only the version-number bookkeeping is deferred.

**Verified:** `agent godot --script tools/ranged_combat_check.gd` (offline, one process) — draw/flight/
recovery timing, ammo consumed exactly once and only on release, a wall stops the flight (proving the
raycast, not a distance test), PvP exclusion (stops on a player-shaped target, damages neither it nor
whatever is behind it), a clean out-of-ammo rejection, melee/ranged mutual exclusion both directions —
`failures=0`. `agent godot --script tools/ranged_combat_net_check.gd` (real two-process ENet, one
client that sends only a hotbar index) — host-resolved connect with the host's own damage number, the
host consuming exactly the client's one granted arrow, a clean host-side out-of-ammo rejection —
`failures=0`. Regression, all unmodified and still green: `tools/combat_check.gd`,
`tools/combat_net_check.gd` (melee, both `failures=0`), `tools/harvest_tool_ladder_check.gd`
(`failures=0` — the shared tool-damage seam), `tools/command_catalog_check.gd` (`failures=0`),
`tools/verify_setup.gd` (all checks passed). Full boot (`agent godot --quit-after 20`): 0 `ERROR:`
lines. F-162 filed (not fixed, out of claim): `tools/viewmodel_check.gd` has one pre-existing,
unrelated failure (three food items with no authored viewmodel), confirmed via `agent baseline`
against HEAD before this task's changes.

### 2026-08-18 — Task 4.5: runtime nav baking ships — per-chunk `NavBaker`, D-016's rules implemented verbatim (hollow7)

**What shipped, verified:** `world/chunk/nav_baker.gd` (`class_name NavBaker extends Node`) — pairs
with a `ChunkStreamer` the way `ResourceScatterField` does and keeps one navigation map in step with
whichever LOD0 chunks are resident. **No protocol bump: this task added no RPC.** `chunk_streamer.gd`
is unchanged — the baker binds by signal, it does not need the streamer to know about it.

```gdscript
var baker := NavBaker.new()
add_child(baker)
baker.bind(streamer, world_seed)     # false on a non-host, by design — see below
baker.map_rid()                      # hand this to NavigationAgent3D.set_navigation_map()
baker.is_queryable()                 # poll THIS, not a readiness flag (see trap 2)
baker.region_count() / pending_bake_count() / has_region(coord)
```

**Host only.** Pathfinding is host-authoritative (D-016), enemies are host-owned bodies, so `bind()`
is a no-op on a client and a six-player session pays the bake cost once. Pass `force_active: true`
only from a harness with no session.

**The constants are D-016's measurements, not preferences.** `CELL_SIZE` 0.25 (0.1 cost 80.7 ms/chunk
— steeply superlinear), `EDGE_CONNECTION_MARGIN` 1.10 (must exceed 2 x agent radius or agents cannot
cross a chunk boundary at all), `MAX_BAKES_IN_FLIGHT` 1 (16 in one frame blocked 6.8 ms), async bake
only (the blocking form is 9.2 ms/chunk), `border_size` and `filter_baking_aabb` left at zero because
both make the seam WORSE. `tools/nav_bake_check.gd` asserts each of these as a value, because every
one of them fails silently.

**Two things to know before you touch this.** Nav rides the LOD0/collision ring and *leaves* it — a
chunk demoted to a coarser LOD retires its region, not just an unloaded one. And winding is measured
per bake rather than hard-coded: Recast wants `cross(v1-v0, v2-v0).y` NEGATIVE, conventional winding
bakes success-with-zero-polygons, and `ChunkMesher`'s winding is its own business that may change.
D-101 has the reasoning.

**The known gap, filed as F-159:** placed buildables are NOT in the source geometry. Agents will path
straight through a wall or a Ward. Terrain-only was the right scope here, but it is a gap, not a
design position — the finding sketches the fix.

**A trap for whoever writes the next terrain-adjacent check.** Chunks (0,0)-(1,1) are NOT "near the
island centre, above water" — for seed 20260818 they are steep seabed at y = -4 to -15. Testing nav
there failed every seam assertion in a way that looked exactly like D-016's erosion hole (the path
stopped at x = 31.0, one metre short of the boundary). A slope census settled it: **82.5% of LAND is
walkable at under 45 degrees**, and a properly-chosen boundary paths across with 0.000 m arrival
error. `nav_bake_check.gd` now LOCATES walkable ground from the heightmap rather than hard-coding
coordinates — copy that approach rather than picking coordinates by eye.

**Check:** `tools/nav_bake_check.gd` — 21 assertions: all four of §6's silent traps (including a
negative control that asserts the wrong winding bakes exactly 0 polygons), async bake + queue +
attach, real seam crossing with the endpoints asserted to be on opposite sides of the boundary,
D-016's constants as values, and region retirement on both unload and LOD demotion. 0 failures,
0 engine ERROR lines.


### 2026-08-18 — Task 6.1: Cycle state machine ships — advance, escalate spread rate, expand enemy pool, announce (lm)

New autoload `CycleService` (`systems/cycle/cycle_service.gd`, registered via `agent autoload`) counts
`DayNight.day_started` crossings and every 3 (`DAYS_PER_CYCLE`) runs `host_advance_cycle()`: escalates
`MireGrid`'s spread rate, expands `WaveSpawner`'s enemy roster, announces. `agent godot --script
tools/cycle_check.gd` — 16 assertions, 0 failures. No regressions: `mire_grid_check.gd`,
`wave_spawner_check.gd`, `mire_interaction_check.gd` all still `failures=0`. 0 `ERROR:` on a full
boot (`agent godot --quit-after 20`). Full design rationale and the "why not `game_state.gd`" call in
`docs/SPECS.md` §6.1; D-100 records the no-new-RPC/no-modifier-draw/no-new-content scope cuts.

**Public API for 6.2 (Cycle Modifier framework) and any other consumer to build against:**

- `CycleService.current_cycle() -> int` — readable on any peer (host's own int, or a client's
  `WorldDeltaLog`-replicated copy). Starts at 1, seeded into `WorldDeltaLog` on boot so even a
  pre-first-advance late joiner reads a real recorded value.
- `CycleService.host_advance_cycle() -> int` — the whole state-machine step (escalate, expand,
  announce). Host-only; returns the unchanged current cycle on a client. Public specifically so 6.2
  (or the `cycle advance` console command, already wired) can force one outside the day-count path.
- `CycleService.spread_multiplier() -> float` — the compounding `1.15^(cycles advanced)` factor
  already applied to `MireGrid`.
- `EventBus.subscribe_cycle_advanced(listener: Callable)` — listener signature `(cycle: int) -> void`,
  fired by the host the instant a Cycle advances. **This is 6.2's seam** — no Cycle Modifier is drawn
  today; whoever builds that draw subscribes here rather than adding a second call site to
  `CycleService.host_advance_cycle()`.
- `MireGrid.set_cycle_spread_multiplier(multiplier: float)` — already wired, called by
  `CycleService`; not something 6.2 needs to touch.
- `WaveSpawner.host_unlock_next_enemy() -> StringName` / `unlocked_enemy_pool() -> Array[StringName]`
  — already wired. `roster_order` (`@export`, defaults to `[&"bog_crawler"]`) is the one place 5.2
  appends new archetypes; no code change needed there.

### 2026-08-18 — Task 4.11: the Mire's four world consumers ship — rotted yields, Blight debuff, corrupted spawn tables, Ward resistance (lm)

Built directly on 4.9's `MireGrid.corruption_at()`, done immediately before this in the same
session (see that entry above and D-099 for why the two shipped out of roadmap order). `agent godot
--script tools/mire_interaction_check.gd` — 12 assertions, 0 failures, two consecutive runs. No
regressions: `build_check.gd`, `inventory_check.gd`, `player_health_check.gd`,
`wave_spawner_check.gd` and `mire_grid_check.gd` all still 0 failures.

**Rotted resource yields** (`autoload/inventory_service.gd`, `_on_harvest_yielded`): corruption at
the harvest's `world_position` scales a yield reduction, up to `ROT_LOSS_FRACTION` (0.6) of the
amount at full corruption, never below 1 for a positive yield. Reduction only, never a substitute
item — no new item exists to substitute in, and authoring one was out of this task's scope (D-073).

**Blight debuff** (`systems/health/player_health.gd`): a new `_tick_blight()`, called from the same
per-peer loop `_tick_hunger()` already runs in, applies hp drain through
`DownedState.apply_damage()` — the exact transition path starvation already uses — whenever
`MireGrid.corruption_at(body.global_position)` is at or above `BLIGHT_CORRUPTION_THRESHOLD` (0.15).
Fractional damage accumulates across ticks (`_blight_accum`, same shape as `_starvation_accum`,
cleared in every place that one is).

**Corrupted spawn tables** (`systems/waves/wave_spawner.gd` + new `content/enemies/bog_crawler.tres`):
`_spawn_one()` now routes every spawn position through `_corrupted_enemy_id_for()`, which
substitutes `bog_crawler` for the default `enemy_id` slot with probability
`corruption * CORRUPTED_SPAWN_CAP_PROBABILITY` (0.75 ceiling — never certainty). Applies to BOTH the
ambient/dusk wave and 4.8's `host_spawn_wave_at()` position-override callers, since both request the
same default slot. `bog_crawler` reuses `enemy_crawler.glb` (no new art authored — this task is
mechanics, not asset authoring) with harder stats: `max_health 20` (was 12), `move_speed 3.6` (was
4.4), `attack_damage 9` (was 6). **It looks IDENTICAL to a normal crawler today** — filed as F-158,
a real gap for 4.10 (Mire visuals) or a later VFX pass, not something this task's scope covered.

**Ward resistance** (`autoload/build_service.gd`, new `ward_radii()` + `_wire_mire_grid()`):
`BuildService` now walks its own `_placed` pieces each call, returning `{position: Vector2, radius:
float}` for every one whose def `is_ward()`, and wires itself into
`MireGrid.set_ward_circles_provider()` via a `call_deferred()` in `_ready()` — deferred because
`MireGrid` registers AFTER `BuildService` in `project.godot`, so `/root/MireGrid` does not exist yet
during `BuildService._ready()` itself; by the time a deferred call runs, every autoload's `_ready()`
has already completed. `MireGridSim`'s own ward-suppression math (`tick()`'s `ward_circles` param)
was already proven correct by `tools/mire_grid_check.gd` in 4.9 — this task's own check instead
proves the NEW wiring: a piece placed through `BuildService` really does reach the provider
`MireGrid`'s tick calls.

**Every new numeric constant here is placeholder-tuned**, same status as `MireGrid.BASE_SPREAD_RATE`
and `IslandHeightmap.HEIGHT_SCALE`: `BLIGHT_CORRUPTION_THRESHOLD`, `BLIGHT_HP_DRAIN_PER_SEC_AT_FULL_
CORRUPTION`, `ROT_LOSS_FRACTION`, `CORRUPTED_SPAWN_CAP_PROBABILITY`. None of these have a playtest
behind them yet — 4.12 is that playtest, and it now has a complete (if unskinned) Mire loop to test
against even though 4.10's visuals are still `todo`.

### 2026-08-18 — Task 4.9: the Mire grid ships — host-authoritative diffusion sim, replicated through 4.6's `WorldDeltaLog`, no new RPC (lm)

**Why this shipped now instead of when the roadmap ordered it:** the 4.11 work order assumed 4.9
was already done ("each one is a small consumer of an existing seam") — it was not
(`state.json` had it `todo`). D-092 already flagged this exact gap in advance: "Mire (4.9-4.11)
does not exist yet — there is no corruption grid to clear." All four of 4.11's consumers need a
corruption query that cannot exist without this task, so it went first, under its own claim/done/ship.

**What shipped, verified:** `world/mire/mire_grid_sim.gd` (`class_name MireGridSim`, pure — same
discipline as `IslandHeightmap`/`BiomeMap`: no nodes, no shared state, safe off the main thread) and
`world/mire/mire_grid.gd` (new autoload **MireGrid**, registered in `project.godot`), the live
256x256-cell, ~4m/cell diffusion grid `docs/ARCHITECTURE.md` §5 specifies, covering the same 1024m
`IslandHeightmap.ISLAND_RADIUS` already covers — one shared source of truth for "how big is the
island" rather than a second copy of the number. `agent godot --script tools/mire_grid_check.gd` —
23 assertions, 0 failures, two consecutive runs (pure-function determinism/mechanics, the live
autoload offline, and a real two-process ENet proof that a connected client never simulates).

**Replication reuses `WorldDeltaLog.host_record()` (task 4.6) instead of a new RPC pair.** That
file's own doc comment names the Mire grid as "this log's next intended consumer, same
per-cell-keyed-by-chunk shape, a different kind" — `MireGrid.KIND = &"mire"` is that kind. This
was the actual unblock: `core/net/net_version.gd` and `tools/handshake_check.gd` (where a new RPC
would need its `PROTOCOL_VERSION` bump) were held by another lane (3.7) for this entire session, so
a bespoke RPC pair was not just extra work, it was impossible to ship right now. No protocol bump,
no `handshake_check.gd` change — `WorldDeltaLog` already carries new peers' late-join snapshot and
live deltas for us.

**`MireGrid` public API:**

```gdscript
MireGrid.corruption_at(world_position: Vector3) -> float   # 0..1, works on host AND client
MireGrid.is_corrupted(world_position: Vector3, threshold: float = 0.05) -> bool
MireGrid.set_ward_circles_provider(provider: Callable) -> void
	# () -> Array[Dictionary]{position: Vector2, radius: float}, called once per tick.
	# Unset today — 4.9 ships with no wards wired in on purpose, see below.
MireGrid.capped_wellspring_count() -> int
MireGrid.host_set_corruption_at(world_position: Vector3, value: float) -> void   # host-only, test/debug seam
MireGrid.flush_deltas() -> void   # host-only, forces an immediate broadcast without waiting TICK_INTERVAL_SEC
```

**Deliberately split from 4.11, even though the two docs disagree about which task owns it:**
ARCHITECTURE.md §5 lists "Wards resist accumulation in a radius" as intrinsic to the grid's own
tick; SPECS.md's 4.11 block lists "Ward posts... suppress spread in radius" as that task's own
consumer. Both are honored: `MireGridSim.tick()` already takes a `ward_circles` parameter (the
mechanism can only live in one place, the tick loop itself), but `mire_grid.gd` calls it with
whatever `_ward_circles_provider` returns — empty today, so 4.9 ships with no ward awareness at
all. 4.11's own job is exactly one wire: `BuildService.ward_radii()` (new, that task's to add) into
`MireGrid.set_ward_circles_provider()`.

**Wellspring cap integration IS 4.9's own job** (SPECS.md's 4.11 list never mentions it) and ships
here: `MireGrid` subscribes to `EventBus.subscribe_wellspring_capped` (the exact seam D-092 named)
and on each cap, zeroes corruption in a 48m radius (DESIGN.md §4.2's "local corruption cleared")
and multiplies the effective spread rate by `0.85` per cap, compounding ("global spread rate
reduced" — no fixed fraction is written down anywhere else to read instead).

**Seeded spread, not random:** `MireGridSim.seed_initial(world_seed)` places 4 corruption clusters
using a `RandomNumberGenerator` seeded `world_seed ^ SEED_CLUSTER_SALT` (D-017's XOR-salt
convention) — same `world_seed` always produces the identical grid, same discipline as terrain even
though nothing here needs to be cross-platform bit-identical (this is host-only, live-simulated
state transmitted as data, never independently recomputed on a client — see below).

**"A client never simulates" is asserted structurally, not just by matching numbers.** The two-process
check's negative assertion reads the client process's own `_owns_simulation()`/`_grid` fields
directly via `Object.get()`/`.call()` (GDScript has no real privacy) rather than only checking that
`corruption_at()` returns the right value — a client that (bug) ran its OWN
`seed_initial(same_world_seed)` would produce the *identical* grid to the host's real one, since
seeding is deterministic, which would make a numbers-only check pass while masking exactly this
regression. **One trap the check had to route around deliberately:** an unconnected process is its
own "host of one" by this project's standing convention (`_owns_simulation()`, same shape as
`PlayerHealth._owns_mutation()`), so it legitimately self-seeds/ticks in the window before `join()`
completes — that is not a bug, every other host-authoritative system here does the same thing. The
assertion that matters starts from the instant `is_active()` first turns true: `_owns_simulation()`
must already read false there, and `_grid` must be byte-for-byte frozen from that instant forward no
matter how much real time passes. Asserting "`_grid` was empty for the whole process lifetime"
(the first version written) fails on a true negative for this reason — fixed before this closed.

**Spread rate (`BASE_SPREAD_RATE = 0.06`) is placeholder-tuned**, the same status as
`IslandHeightmap.HEIGHT_SCALE` — ARCHITECTURE.md §5 calls for "the current Cycle's rate" and no
Cycle Modifier system exists yet to read a real one from.

**Not wired to the live game (Hollowmere) any more than the rest of M4's procedural pipeline is** —
same situation F-139 already names for `ChunkStreamer`/`ResourceScatterField`. This is not a new gap:
`IslandHeightmap.ISLAND_RADIUS` (512m) already covers Hollowmere's real coordinate space (its
authored props sit well inside it — the Wellspring marker is at (4, -0.6, 64), for instance), so
`MireGrid.corruption_at()` returns meaningful answers for real player/harvestable/enemy positions
today regardless of which terrain mesh renders underneath. A full map-cutover (procedural terrain
replacing Hollowmere) remains a separate, later decision per F-134.

### 2026-08-18 — F-152: `tools/mesh_merge_check.gd` pins `MeshMerge`'s per-vertex-channel invariant; the bug was already fixed by F-144 (lp)

**What shipped, verified:** F-152 was filed against `e5f96b1`; by the time this task picked it up,
F-144's own in-flight rewrite (commit `76d48bc`) had already fixed it — merge buckets now key on
`_attribute_mask(arrays)` as well as material appearance (`core/render/mesh_merge.gd:103-110`), so two
parts only share a bucket when they carry the same optional vertex channels, and the mismatched-array-
length crash this finding describes can't recur. No code change was needed or made; both
`core/render/mesh_merge.gd` and `world/gen/undergrowth.gd` stayed under F-144's claim, untouched, for
this task's whole run. Wrote `tools/mesh_merge_check.gd` (none existed) since closing a finding needs a
check, not just a read of the diff: it clears `MeshMerge`'s disk cache, then calls `MeshMerge.merged()`
directly on every `.glb` under every `assets/*/exports/` kit dir (discovered from disk, not a fixed
list — new kits are covered automatically) and asserts a non-null, non-zero-surface mesh whose every
present channel carries exactly one entry per vertex (four for tangents). `agent godot --script
tools/mesh_merge_check.gd` → `MESH_MERGE_CHECK checked=337 surfaces=1287`, `MESH_MERGE_CHECK_GODOT
PASS`. Cross-checked against the finding's own repro — `agent godot --quit-after 20` on
`levels/hollowmere.tscn` (the boot scene the original stack trace came from) → zero `ERROR:` lines,
none mentioning `mesh_merge.gd`, `array.size()`, `p_idx`, or `surfaces.size()`.

**The seam the next kit-asset merge builds against:** `tools/mesh_merge_check.gd` is now the standing
regression guard for `MeshMerge` — anything that changes bucketing, the attribute mask, or what gets
appended per-channel should keep this green before shipping. It runs stand-alone (no level boot, no
scene dependency) against every kit `exports/` folder that exists today, so a brand-new kit directory
is covered the moment its `exports/` subfolder appears — nothing needs to register it.

### 2026-08-18 — F-130: a source-text guard for the DebugConsole shim's reflection call, `gfx` still not migrated (lp)

**What shipped, verified:** `tools/command_shim_check.gd` — walks every `.gd` file for the reflection
shape `.call("register", ` / `.call(&"register", ` (the call `console.get_node_or_null(^"/root/
DebugConsole").call("register", ...)` uses, which hides from a plain `grep -rn 'DebugConsole.register('`
because the verb name never sits next to the method name). `autoload/debug_console.gd` — the shim's own
implementation — is exempt; every other hit is a command still on the deprecated path.
`agent godot --script tools/command_shim_check.gd` → `COMMAND_SHIM_CHECK scripts=228 hits=1
failures=2`, the one hit being `autoload/graphics_quality.gd:197` (`gfx`). Re-verified the other three
command checks unaffected: `command_catalog_check`/`command_check`/`command_net_check` all
`failures=0`. `docs/SPECS.md` gained the `## F-130` block this finding never had.

**Still open, and what blocks it:** `gfx` itself is not migrated — `autoload/graphics_quality.gd` has
been held by F-144 (`nettle12`) across two separate sessions on this finding now (task 3.16, then
this one), so the fix (`fps_cap`'s shape in `core/dev/dev_frame_cap.gd` is the template) still needs
whoever next holds that file. **The seam whoever finishes it builds against:** once `gfx` is ported to
`CommandService.register_spec()` (LOCAL scope), `agent godot --script tools/command_shim_check.gd`
should read `failures=0` — that is F-130's actual closing condition, not just the absence of the WARN
line. Move F-130 to `## Resolved` only once that check is green.

### 2026-08-18 — F-137: `tools/construction_check.gd` now cross-checks every `content/buildables/*.tres` against the build module (lm)

**What shipped, verified:** `_check_buildable_defs()`, called from `_init()`. `wall.tres` is checked
against the file's own `MODULE`/`WALL_H` constants (it has no exported GLB); every other buildable
listed in `BUILDABLE_FRAME` (`{buildable id: catalog frame name}`) is checked against that catalog
entry's engine-measured `run_span_m`/`height_m` — depth is deliberately never compared, since a
footprint may be legitimately thinner than its art (see `buildable_def.gd`'s doc comment on `size`).
Verified `agent godot --script tools/construction_check.gd` → `CONSTRUCTION_BUILDABLE_DEFS
checked=8`, and confirmed live (not vacuous) by temporarily breaking `MODULE` and watching it fail.

**The seam the next buildable author builds against:** authoring a new module-tiled buildable (a
`content/buildables/*.tres` whose footprint is meant to tile with an exported construction-kit GLB)
means adding its `{id: frame_name}` pair to `BUILDABLE_FRAME` in `tools/construction_check.gd` —
nothing does this automatically, so a piece left out of the table is silently unchecked, exactly the
gap this task closed for the seven pieces authored since F-137 was filed. `ward.tres`/`ward_post.tres`
and `barricade.tres`/`barricade_spike.tres` are intentionally NOT in the table — none of them tile
against a module-pitch catalog frame (Ward is a radius, barricades have no catalog `run_span_m`).

**Left for whoever fixes F-148:** that finding's `AABB size is negative` error in `_check_doors()`
got much worse while verifying this task (213k+ repeats, run did not finish in 5 minutes) — raised
to medium severity in `docs/FINDINGS.md`. Not fixed here; still out of scope per F-148's own text.

### 2026-08-18 — Task 5.1: perception, alerting and an attack-slot cap land on `EnemyDef`/`Enemy` — the state machine and telegraph are unchanged (lp)

**What shipped, verified:** `docs/SPECS.md`'s new `## 5.1` block, `EnemyDef` gains four fields, and
`Enemy` gains the logic that reads them. 2.10's `IDLE -> CHASE -> TELL -> ATTACK -> RECOVER` machine
and its telegraph (hit resolves at the END of the tell) are untouched — see D-097 for why this landed
as data on the existing script rather than a swappable `enemy_brain.gd`, and why perception gates
acquisition only, never retention.

**The API 5.2's authors build against — four new `EnemyDef` fields, all with defaults that keep
`content/enemies/crawler.tres` (left unedited) behaviourally identical to before this task:**
```gdscript
vision_angle_deg: float           # default 360.0 — the full arc, centred on facing, a NEW target can
    # be acquired within. 360 = omnidirectional (2.10's original behaviour, still the common case).
    # Below 360 gives a kind a genuine blind side. Checked on acquisition only.
requires_line_of_sight: bool      # default true — acquisition additionally needs an unobstructed
    # PhysicsDirectSpaceState3D ray (world geometry only). Also acquisition-only.
alert_radius_m: float             # default 8.0 — on a NEW acquisition, every enemy of ANY kind within
    # this radius that currently has no target of its own is handed the same one directly, no
    # perception check. One hop: an alerted enemy never itself re-alerts. 0 disables it.
max_concurrent_attackers: int     # default 2 — how many of this kind may be TELL/ATTACK against the
    # same target at once; the rest hold position at range instead of piling on.
```
**One new public method:** `Enemy.alert(peer_id: int) -> void` — the entry point `_alert_nearby()`
calls on packmates; only takes the target if the enemy currently has none. Callable directly (e.g. a
future "call for help" ability), always host-only-guarded internally like every other decision on
this class.

**Both perception fields are acquisition-only by design — an already-held target never re-checks
either one.** A wall between an enemy and its ALREADY-targeted player does not un-target it; the same
wall between them BEFORE acquisition prevents it. This is what keeps the aggro/deaggro hysteresis
(2.10) meaningful rather than fighting a perception re-check every tick.

**No new replicated property, no new RPC, no `PROTOCOL_VERSION` bump.** `state`/`health`/
`hit_counter` are exactly what `Enemy._build_synchronizer()` already replicated; every new decision
(perception, alerting, the attack cap) is made and consumed entirely inside the host's own
`_physics_process`, same authority row as everything else this class does (§2.2 "Enemies: HOST").

**Verified:** `agent godot --script tools/enemy_ai_check.gd` — 19 assertions, `failures=0`: the cone
blocks/allows acquisition, an unobstructed ray gates it too, a wall placed AFTER acquisition does not
drop an already-held target, a fresh acquisition wakes an untargeted packmate within `alert_radius_m`
on the SAME tick while an enemy outside that radius and a one-hop-removed control both stay
untouched, the woken packmate actually closes distance once stepped, and the attack-slot cap holds a
third simultaneous attacker back in CHASE then lets it attack once one of the first two cycles back
through RECOVER. 2.10's own `tools/enemy_check.gd` and `tools/enemy_net_check.gd` still pass
unmodified (`failures=0` each) — that is this task's regression bar, in place of a literal
zero-behaviour-change refactor. `tools/entity_check.gd` and `tools/combat_feel_check.gd` (both read
`Enemy`/`EnemyDef` fields) also still `failures=0`. Full boot (`agent godot --quit-after 20`), with
Hollowmere's real ambient crawlers spawning and pathing: 0 `ERROR:` lines.

**F-155 filed, not fixed here:** `PlayerHealth._is_dodging()` throws on any body with no `dodging`
property (a bare test-harness player, e.g. both `enemy_check.gd`'s and `enemy_ai_check.gd`'s) — a
pre-existing `SCRIPT ERROR:` on the enemy-attack-landed path, unrelated to this task's claim.

### 2026-08-18 — F-132 resolved: host union-of-interest needed no new API, only a calling contract — recorded for whoever wires a live `ChunkStreamer`/`ResourceScatterField` session (lm)

**What shipped, verified:** F-132 (a remote client's scattered harvestable proxy may have no host
counterpart to reach, because `ChunkStreamer` streams per-peer independently) is resolved without
code changes to either system's ring or proxy mechanics — `ChunkStreamer.set_anchors()` already takes
`Array[Vector3]` and already unions correctly over an arbitrary anchor set (`_ring_distance()` takes
the NEAREST of every anchor, so a chunk stays resident as long as ANY anchor's ring reaches it), and
`ResourceScatterField` already builds/tears down scatter per CHUNK, never per anchor. D-096 records
why no new API was added.

**The contract for whoever wires 4.6+/live-session streaming (F-139, still open — nothing
instantiates either system in the shipped game yet):** anchor the HOST's `ChunkStreamer`/
`ResourceScatterField` pair to the union of every connected peer's last-known position, its own
included, not just its own local player. A host anchored only to its own local player never builds a
chunk-resident harvestable proxy for a point a remote client's own local ring covers, and that
client's `Harvestable.request_hit()` `rpc_id(HOST_PEER_ID)` call — which Godot's high-level
multiplayer RPC routes by matching NodePath between peers — then has no node on the host to receive
it. This is now a header-level doc comment on both `world/chunk/chunk_streamer.gd` and
`world/gen/resource_scatter_field.gd`, not left implicit.

**One real trap found while proving this, now documented on `attach_to_streamer()`'s own docstring:**
`ResourceScatterField` only reacts to `chunk_mesh_ready`/`chunk_unloaded` as they FIRE — it never
retroactively scans chunks already resident on the streamer at attach time. Attach the field to the
streamer BEFORE the streamer is given anchors (matching both systems' own DELEGATION usage snippets'
ordering), or every chunk resident before the attach silently gets no scatter.

**Verified:** `agent godot --windowed --script tools/chunk_stream_check.gd`'s new union-of-interest
section — a REAL `ChunkStreamer` fed two anchors chosen `>= LOAD_RADIUS_CHUNKS + HYSTERESIS_CHUNKS +
1` chunks apart (so neither anchor's own ring could reach the other's target chunk by construction,
not by luck), with a REAL `ResourceScatterField` attached, proving BOTH anchors' chunks load at LOD0
with a collider and BOTH materialize a live, `HarvestWorld`-wired `Harvestable` — `0 functional
failure(s)` across the whole file, including its pre-existing phase 1/phase 2 suites. Regression:
`agent godot --script tools/resource_scatter_check.gd` → `RESOURCE_SCATTER_CHECK failures=0`;
`agent godot --script tools/verify_setup.gd` → `all checks passed`.

### 2026-08-18 — Task 4.7: POI placement ships — seeded Poisson-disc, a `PoiDef` content family, Wellsprings and landmarks (hollow7)

**What shipped, verified:** `world/gen/poi_def.gd` (`class_name PoiDef` — the authored constraints
for one kind of POI) and `world/gen/poi_map.gd` (`class_name PoiMap` — the pure, static generator),
plus the Registry family (`Registry.poi`, `poi_defs()`/`get_poi(id)`/`has_poi(id)`, boot log now ends
`… 8 rule(s), 1 hook(s), 3 poi(s)`) and three worked examples in `content/poi/`.

```gdscript
PoiMap.sites_for_island(world_seed: int, poi_defs: Array, biome_defs: Array) -> Array[Dictionary]
# each: {def_id: StringName, site_id: String, position: Vector3, rotation_y: float,
#        biome: StringName, scene_path: String, spacing: float, clearance: float}
```

Pass `Registry.poi_defs().values()` and `Registry.biomes.values()` — the same convention
`BiomeMap.biome_at()` and `ResourceScatter.placements_for_chunk()` callers already follow.
`position.y` is the terrain height at that point, so a caller can instance straight onto it.

**Like `IslandHeightmap`/`BiomeMap`/`ResourceScatter` before it, nothing in the shipped game calls
this yet** — it is pure and tested, waiting on whoever wires a real generated world into a running
level (the F-139 cluster). Wiring it is one call plus an instancing loop.

**Authoring a new landmark is one `.tres`.** The fields that matter, and the two that are easy to get
wrong: `placement_priority` (LOWER places first and wins the good ground — the Wellspring sits at 0),
and the **two separate radii** — `min_spacing_m` between sites of the same kind, `clearance_m`
between this kind and any other. They are separate for a measured reason; see D-095.

**`scene_path` may be empty, legitimately.** `Wellspring` is script-constructed rather than a packed
scene, and a def may exist purely to reserve space. `PoiMap` returns the site either way.

**Two real bugs the check found, both worth knowing about before you author POI content.** Sorting
defs by `id` alone placed the Wellspring last (alphabetically after `shipwreck` and
`standing_stones`) and one measured seed generated an island with **zero Wellsprings** — a run with
no objective. And using one radius for both same-kind and cross-kind spacing carved four 180 m holes
out of the island and starved the landmarks. Determinism, spacing and constraint tests all passed
while both were true, because a layout that is consistently wrong is still deterministic; the
assertion that caught them is the cheap per-kind one ("does every authored kind actually land, and
does every seed get a Wellspring"). Keep that assertion when you add kinds.

**Check:** `tools/poi_check.gd` — 38 assertions over five seeds: determinism (same seed twice, and
immunity to def *order*, since `Dictionary.values()` order is not a contract), spacing under the
two-ruler rule, every constraint re-derived from the heightmap rather than trusted from the
generator, different seeds producing different islands (the dropped-salt failure no determinism test
can catch), honest counts for an unsatisfiable def, and per-kind coverage. 0 failures, 0 engine ERROR
lines, alongside `biome_check`, `command_catalog_check`, `rule_check`, `verify_setup`.
*(`chunk_stream_check` is unrunnable in the shared tree right now — a parse error in
`tools/chunk_stream_check.gd`, held by lm for F-132. `agent godot` identified it as not mine.)*


### 2026-08-18 — Task 3.17: functions, hooks, autoexec and the headless command-file runner ship — COMMANDS.md §5–6 is complete (lp)

**What shipped, verified:** the whole of `COMMANDS.md` §5–6, gated on 3.13 as specced.

**Functions (§5.1).** `content/functions/*.mcmd` — plain text, `#` whole-line comments, blank lines
ignored — are scanned into `CommandService._functions` at boot (`FunctionRunner.scan_directory()`,
`systems/commands/function_runner.gd` — a pure, node-free helper, same discipline as
`core/commands/entity_selector.gd`: text parsing and scope arithmetic only, no coroutines, so it is
testable without a live CommandService). `function <name>` runs every line of the named file through
`CommandService.execute()` itself — never a second execution path — stopping at the first failing
line. **Effective scope is the max of its lines' scopes** (`FunctionRunner.effective_scope()`,
D-086's dynamic-`scope: Callable` mechanism): a function with only LOCAL lines runs for anyone, one
with any HOST line demands op, computed by inspecting the NAMED function's own content rather than
the invocation's tokens (contrast `rule`/`time`, which only look at how many tokens were typed).
Recursion cap 4, threaded through `ctx["_fn_depth"]` (an internal-only CommandCtx field, documented at
the top of `command_service.gd`) rather than a member counter — a member counter would be shared
across concurrent invocations that interleave at `await` points, corrupting depth for unrelated
callers.

**The API the next task builds against:**
```gdscript
command_service.has_function(&"night_siege")            # -> bool
command_service.function_names()                        # -> Array[StringName], sorted
command_service.register_function(&"my_fn", PackedStringArray(["give branch 1"]))  # runtime authoring,
    # same "content reload and test setup both want that" reasoning as register_spec() — the worked
    # caller is tools/function_check.gd, proving the recursion cap and D-086 routing without ever
    # writing a throwaway content/functions/*.mcmd fixture.
command_service.is_op(peer_id)                           # -> bool, read-only mirror of _is_op()
```

**Hooks (§5.2).** `systems/rules/hook_def.gd` (`HookDef`: id, event, function, host_only, enabled) is
a content family like any other, loaded by `Registry._load_dir()` from `content/hooks/*.tres` exactly
like `RuleDef` (`Registry.hook_defs()/get_hook()/has_hook()`, same naming convention as `rule_defs()`
— the AUTHORED bindings, not whether one is wired). `CommandService._wire_hooks()` (deferred from
`_ready()` — Registry and every event source register LATER than CommandService in
`project.godot`, same `call_deferred` trick `debug_console.gd`'s own `_register_builtins()` already
uses) connects every ENABLED HookDef's named event to its real signal via `_HOOK_EVENTS`, a fixed
table mapping event name -> `{path, signal, handler}`:
```gdscript
const _HOOK_EVENTS: Dictionary[StringName, Dictionary] = {
    &"night_started": {"path": ^"/root/DayNight", "signal": &"night_started", "handler": &"_on_hook_signal_0"},
    &"day_started":   {"path": ^"/root/DayNight", "signal": &"day_started",   "handler": &"_on_hook_signal_0"},
    &"enemy_died":    {"path": ^"/root/EnemyWorld", "signal": &"enemy_died",  "handler": &"_on_hook_signal_enemy_died"},
}
```
Adding an event a future task ships a real signal for is one row here (F-154 names the two
illustrative events — `run_started`, `player_downed` — with no signal to bind to yet; naming either
in a HookDef today fails loudly at wire time, not silently). `CommandService.wire_hook(hook: Resource)`
is public on purpose: a check (or a future in-game tool) can wire a synthetic HookDef directly, no
Registry/content round trip needed — `has_wired_hook(id)` is the introspection half.
`content/hooks/night_siege.tres` + `content/functions/night_siege.mcmd` is the one worked example
(dusk -> `wave start 10`), shipped **disabled** — D-094 is why, and F-154 is what it deferred.

**Autoexec (§5.3).** Host/offline only (`_owns_execution()`), deferred alongside hook wiring.
`content/functions/autoexec.mcmd` — if present — is already in `_functions` like any other scanned
file, so it runs through the exact same `_cmd_function()` path as `function autoexec` typed by hand
(one code path, not two). `user://autoexec.mcmd` (per-install, gitignored, never content) is read and
run directly since it was never scanned into `_functions`. Project baseline runs first, personal
overrides second. Neither ships by default — not shipped content, per COMMANDS.md §5.3.

**The headless runner (§6).** `tools/run_commands.gd` —
`agent godot --script tools/run_commands.gd -- --file <path> [--json]` — boots the real project
offline and executes any `.mcmd`-shaped file (any path, not only `content/functions/`) line-by-line
through the real `CommandService.execute()`. `# expect-fail` on its own line inverts the pass/fail
grading of the ONE command line immediately after it — this directive is run_commands.gd's own, kept
deliberately separate from `FunctionRunner.parse_lines()` (which has no notion of "expected" results,
only real command lines vs. comments). Exit code is non-zero the instant any line's actual result
(post-inversion) disagrees with what was expected. `content/functions/dev_scenario.mcmd` is the
worked example — `give branch 5` / `spawn crawler 2` / `enemies`, porting `tools/command_check.gd`'s
own hand-coded give/spawn setup into a command file (verified: `agent godot --script
tools/run_commands.gd -- --file content/functions/dev_scenario.mcmd --json` → `failures=0`).
Migrating `command_check.gd` itself to consume it is deliberately NOT done here (SPECS.md 3.17: "do
not port the suite — that is opportunistic, later, per-check").

**`tools/command_catalog_check.gd`** (claimed for this task since its own header names 3.17 as the
task that finishes it): the `DEFERRED_TO_3_17`/`_check_deferred()` pair is gone; `function` is a real
`CATALOG` row now (`host_args: "night_siege"`, matching the `time`/`rule` dynamic-scope pattern —
`function`'s bare form is LOCAL, since routing depends on the NAMED function's content, so probing it
bare would assert the opposite of what D-086 promises, same reasoning already on record for `time`
and `rule`).

**Verified:** `agent godot --script tools/function_check.gd` (worked example loads off disk; a
function runs end-to-end through the real front door and a bad line fails the whole thing with the
real underlying error; D-086 dynamic scope — a LOCAL-only function runs for a non-op, one with any
HOST line is refused with the uniform wording; recursion cap refuses a self-recursive function
without hanging, a 4-deep chain under the cap still succeeds; a synthetic HookDef actually fires its
function on a REAL `DayNight.host_advance()` dusk crossing — driving the real clock, not the signal,
same discipline as `day_night_check`/`wave_spawner_check` — observed via `op 4242`, chosen because
nothing else touches that peer's op status, unlike enemy count which the real WaveSpawner ALSO moves
on every dusk crossing regardless of this hook) — `failures=0`. `tools/command_catalog_check.gd`
(42 commands now, `function` covered) — `failures=0`. `tools/command_check.gd`, `tools/day_night_check.gd`,
`tools/wave_spawner_check.gd`, `tools/rule_check.gd`, `tools/handshake_check.gd`, `tools/verify_setup.gd`
all still `failures=0` / all checks passed after the migration. Full boot (`agent godot --quit-after
15`): 0 `ERROR:` lines. No new RPC, no protocol bump — functions/hooks/autoexec/runner all execute
through CommandService's existing `execute()`, never a second mutation path.

### 2026-08-18 — Task 3.16: the command catalog is complete — every §7 verb ships, and a check now enforces that (hollow7)

**What shipped, verified:** the whole of `COMMANDS.md` §7. `commands --json` now reports **41**
registered commands, and `tools/command_catalog_check.gd` asserts every §7 row exists, at the scope
its authority implies, with every HOST verb refusing a non-op.

New verbs, each in its OWNING service and each wrapping a seam that already existed (§3.3):

| System | Verbs | Where |
|---|---|---|
| Inventory | `inv [list\|clear] [peer]`, `loot roll <table> [peer]` | `inventory_service.gd` |
| Health | `damage <selector> <n>`, `heal`, `down`, `revive`, `starve` | `player_health.gd` |
| Time | `time set\|add\|query` | `day_night.gd` |
| Waves | `wave start\|stop\|status` | `wave_spawner.gd` |
| Powerups | `powerup give\|clear\|list`, `stat` | `powerup_service.gd` |
| Crafting | `craft`, `recipes` | `crafting_service.gd` |
| Building | `build <id> <x y z>`, `demolish <selector>` | `build_service.gd` |
| Harvest | `harvest respawn\|status` | `harvest_world.gd` |
| Session | `lobby host\|join\|invite\|leave\|status` | `steam_lobby.gd` — **D-030's cross-play test, delivered** |

`spawn` gained the optional `[x y z]` §7 specified (bare `spawn crawler 3` is unchanged), and
`fps_cap`/`vsync` were migrated off `DebugConsole.register()`'s deprecation shim — they were the last
two catalog verbs still on it. **`gfx` is still on the shim**: `autoload/graphics_quality.gd` was held
by another agent (F-144) for this whole task. One `register_spec` call, same shape as `fps_cap`.

**Five new arg types**: `recipe_id`, `powerup_id`, `buildable_id`, `station_id`, `loot_table_id` —
all five share one bound parser (`_registry_parser`) rather than five near-identical functions.

**Small new host seams, all of them the kind §7 anticipated.** `PlayerHealth.host_heal(peer, amount)`
(returns hit points restored, or -1 for no such player), `host_revive(peer)` (the *admin* revive — no
reviver, no range, no hold, deliberately a separate entry point from `_process_revive_request`, which
keeps every one of those validations), `host_set_hunger(peer, value)`. `DayNight.host_set_time(f)`
crosses the day/night thresholds on the way so `time set dusk` actually starts the night rather than
skipping the signal WaveSpawner waits on. `WaveSpawner.host_start_wave([count])`/`host_stop_wave()`
are now the real implementations, with `_on_night_started`/`_on_day_started` as thin adapters over
them — so `wave start` and dusk drive identical code.

**What the coverage check is for, in practice.** It found two real defects on its first run. §7
listed `clear` under both Inventory and Meta, and `register_spec` replaces silently, so one of them
would have quietly won — resolved as D-093/F-153 (console keeps `clear`; the wipe is `inv clear`).
And the check itself was wrong about dynamic-scope verbs: `time` and `rule` are LOCAL in their bare
form, so probing them bare for the non-op refusal asserted the opposite of what D-086 promises —
catalog rows carry an optional `host_args` for exactly that. It also refuses to count a verb still on
the deprecation shim as coverage, since the shim produces an untyped LOCAL spec and a HOST mutation
behind one would pass a name-only check unprotected.

**Adding a verb after this** is: register it in its owning service, then add one row to
`CATALOG` in `tools/command_catalog_check.gd`. If you skip the second step nothing fails — the check
covers the spec, not the registry — so the row is the part to remember.

**Still open in the command track:** 3.17 (functions, hooks, autoexec, `tools/run_commands.gd`).
`function` is asserted ABSENT in the catalog check on purpose, so when 3.17 ships it fails there and
its author moves the row up into `CATALOG`.

**Checks:** `command_catalog_check` (41 assertions), plus `command_check`, `command_net_check`,
`entity_check`, `entity_net_check`, `rule_check`, `rule_net_check`, `player_health_check`,
`day_night_check`, `wave_spawner_check`, `crafting_check`, `build_check`, `inventory_check`,
`powerup_check`, `enemy_check`, `findings_numbering_check`, `verify_setup` — all 0 failures, 0 engine
ERROR lines.


### 2026-08-18 — Task 3.7 (most of it): every buildable piece now has real art and a real collider, and the ghost previews it (slate17)

**What shipped, verified:** twelve `content/buildables/*.tres` definitions, twelve piece scenes in
`scenes/buildables/`, and `systems/building/build_ghost.gd` previewing the piece's own art instead of
a grey box. `.agent/bin/agent godot --script tools/buildable_content_check.gd` is the proof (13
defs, 12 with art, ramp rays at 21/506/990 mm, 0 failures); `build_check` and `build_net_check` are
both still 0 failures.

**The set:** `palisade` `palisade_gate` `door` `gate` `ladder` `ramp` `barricade` `barricade_spike`
`dock` `bridge` `ward` `ward_post`, on A-010's construction kit and A-007's Wards. `wall_wood` is
deliberately still art-free — no plain-wall asset exists until A-013/A-018, and the check reports it
rather than failing on it.

**No change to `autoload/build_service.gd` was needed** (it was claimed by 3.16 anyway): the schema's
existing `BuildableDef.scene` seam already instantiates an authored root and only falls back to the
generated box when there is none. Each piece scene is a `StaticBody3D` on collision layer 1 with the
GLB instanced as art and hand-authored collision shapes — **not** one box per piece:

- `ramp` collides as a *slope*, seated on the art's own deck plane, because a box would be a wall
  (F-136, F-150).
- `dock` and `bridge` collide as a *deck slab* whose top face is A-010's 1.00 m `DECK_Z`, so a run of
  them is one walkable surface and you can still walk underneath. `bridge` adds two rail colliders.
- Both have `requires_support = false`: a piece that spans a gap is the point of them.

Pieces carry no script, so `BuildService` still attaches `buildable_piece.gd` for the damage contract
(F-085) exactly as before.

**What is left of 3.7, for whoever takes it next.** (1) **The door does not open** — the leaf is
placed closed as static art. A-010 ships it as a separate hinge-origin export with `hinge_offset_m`
and a verified 90° arc, so the remaining work is a host-authoritative `open` bool with its own
synchronizer plus an interact, not any art. Same for `gate` (two leaves) and `palisade_gate`.
(2) **Damaged-state art** — `buildable_piece.gd`'s doc comment assigns it here; `hp` is host-only and
unreplicated, so a visible damage state needs a replicated tier, and A-007 already has
healthy/damaged/critical/destroyed for the Ward. (3) `wall_wood`'s art. (4) The ladder is placeable
but not climbable — nothing in the controller climbs.


### 2026-08-18 — F-141: `tools/wellspring_net_check.gd` — real two-process proof of `net_request_toggle_channel` (lm)

New check only; `systems/wellspring/wellspring.gd` is unchanged. Closes the gap `tools/
wellspring_check.gd` left: that check proves the ritual FSM in one process (offline/host-of-one
path), never the RPC itself. `wellspring_net_check.gd` is the `chest_net_check.gd` shape — driver +
`-- wellspring-probe` probe arg, `user://wellspring_net_client.json` — and is the reference for any
future two-process check on a system whose in-range gate reads a *fixed* constant (`PRESENCE_RANGE_M`
here) rather than a per-instance export like `Chest.request_range_m`: since the check cannot widen
the gate, the driver instead reads the client's real `PlayerNet`-spawned position off the HOST's own
tree (`player_net.call("player_for", client_peer)`, once non-null) and snaps the tested node's
`global_position` onto it, so the check never depends on `PlayerNet.SPAWN_OFFSETS`' actual values.
`agent godot --script tools/wellspring_net_check.gd` — two consecutive runs, `failures=0` both times.

### 2026-08-18 — F-136: `PlayerController` gains step-up — a short lip or threshold no longer reads as a wall (lm)

`entities/player/player_controller.gd` gained `_apply_step_up(delta)`, called every physics tick
right before `move_and_slide()`, grounded only — client-authoritative own-movement (ARCHITECTURE.md
§2.2 row 1), same as the rest of the controller. New `@export var step_height: float = 0.4` (Step
group) is the one number that decides what counts as "a step" project-wide: any lip, threshold or
kerb up to this height is walked over automatically; anything taller is a wall on purpose. Chosen as
roughly knee height on the 1.8 m capsule — comfortably above the 60 mm door threshold / ~12 mm
ramp-toe feather A-010 authors around today (D-090), comfortably below `jump_height` (1.1 m).

**For whoever authors levels or assets against this next:** D-090's "no thresholds, ramps under 46°,
mating planes to the millimetre" workaround is no longer the only option — a lip up to `step_height`
now just works. It does not relax `floor_max_angle` (46°, unchanged) or replace ramps for anything
taller than 0.4 m; a raised platform, dock, or module seam still needs either a ramp/stair or to stay
under `step_height`.

**The landing probe is a single combined diagonal `test_move()`** (`motion + Vector3(0,
-step_height, 0)`, forward and down together), not a separate horizontal-advance-then-vertical-drop —
that two-step version was tried first and failed empirically: a real per-tick `motion` is far smaller
than the capsule's 0.4 m radius, so advancing by only that much before testing the drop leaves the
capsule straddling the lip's corner, and the next `move_and_slide()` fights that self-overlap back
out every tick, reading as the player bouncing in place at the lip. Anyone touching this function
should keep the two probes (rise, then combined forward+down) combined for that reason — re-splitting
them reintroduces the bounce.

`tools/step_up_check.gd` is the regression guard and the reference for testing this controller's
movement without real WASD input: `AttunementUI` (autoload) opens a `blocks_gameplay_input` role
picker ~0.5 s after any node joins the `players` group, so a check driving movement via real
`Input.action_press` frames starves against it. The check instead hand-drives
`_apply_gravity()` / `_apply_horizontal_movement()` / `_apply_step_up()` / `move_and_slide()` in that
exact order — the same technique `tools/dodge_check.gd` already used for `_apply_horizontal_movement`
and `_tick_dodge`, now established as the pattern for anything that needs a real physics walk in this
controller.

### 2026-08-18 — Task 4.8: the Wellspring capture ritual ships — host-owned state machine, defense wave, `EventBus.emit_wellspring_capped` is the reward seam (lm)

`systems/wellspring/wellspring.gd` (`class_name Wellspring`) is a host-authoritative Node3D built at
runtime, never in a `.tscn`. `autoload/wellspring_service.gd` finds every `authored_world_marker`
whose `kind == "objective"` (Hollowmere ships exactly one, at (4.0, -0.604, 64.0)) and adds a
`Wellspring` as that marker's child, identically on every peer — the same
marker-in/live-node-out split `autoload/harvest_world.gd` uses for harvestable holders, so no map
layout needs a gameplay-specific edit.

**API for whoever builds 4.9-4.11's Mire or a reward system:**

```
Wellspring.capped: bool                     # replicated, ON_CHANGE — swaps the state mesh
Wellspring.channeling/progress_sec/duration_sec/required_players: replicated presentation
Wellspring.request_toggle_channel()         # client-facing: press interact to start/cancel
Wellspring.is_local_player_in_range()       # presentation-only proximity check for a HUD prompt
EventBus.subscribe_wellspring_capped(listener)   # (wellspring_name: StringName, world_position: Vector3)
WaveSpawner.host_spawn_wave_at(position, count, enemy_id, scatter_m) -> int   # position-override spawn
```

**D-092 records the scope call in full** — the short version: capping does NOT clear Mire corruption,
reduce spread rate, grant a chest, or select an Attunement. None of those systems exist yet in a form
this task could wire against (Mire is 4.9-4.11; Attunement already fires at run start per D-071; a
Wellspring-tier loot chest has no `.tscn`/loot-table content authored). `EventBus.emit_wellspring_capped`
is the one seam every one of those hooks into later — `Wellspring` itself should not need to change
when they do.

**Ritual shape:** interact starts it (required 2 live players this session, or 1 with a 150s timer
instead of 60s if the session has exactly one — snapshotted once at start, `_session_player_total()`).
Progress advances only while at least `required_players` are within 4.5m
(`Wellspring.PRESENCE_RANGE_M`) — dropping below pauses it without resetting; a second interact press
cancels and resets to 0. A defense wave (`base(3) + per_player(1) x session total`, `crawler`s) spawns
once at channel start via `WaveSpawner.host_spawn_wave_at`, independent of day/night and not required
to be cleared for the ritual to finish.

`ui/hud/wellspring_hud.gd` is a small self-built CanvasLayer autoload (no `.tscn`, same pattern as
`vitals_hud.gd`) showing the interact prompt and a progress bar; it does not join
`&"blocks_gameplay_input"` since gameplay continues around a channel.

**Protocol bumped 18 -> 19** for `net_request_toggle_channel` plus Wellspring's own
`SceneReplicationConfig`. Verify: `agent godot --script tools/wellspring_check.gd` (wiring + marker
consumption + full FSM, 0 failures) and `agent godot --script tools/wave_spawner_check.gd` (the new
`host_spawn_wave_at` seam, 0 failures, no regression on the existing dusk/dawn assertions).
**F-141**: the toggle RPC itself has no two-process net check yet, only the host-side logic it calls.

### 2026-08-18 — Task 3.2 (first half): the chest economy is real — prices, keys, powerup rewards, and the Gleam pool (slate17)

**What shipped, verified:** the six remaining `docs/ITEMS.md` §5 loot tables and the eight Gleam
powerups, plus the schema they could not be written without — which `ITEMS.md` §6 had assigned to
3.5 and 3.5 closed without (F-140). `.agent/bin/agent godot --script tools/loot_content_check.gd` is
the proof: 7 tables, 94 entries, every id resolved against the real Registry, and a live chest that
charges, refuses, consumes a key and grants a powerup.

**`LootEntry` gained two fields.** `kind` (`ITEM` default, `POWERUP`) switches which namespace
`item_id` names — one id field, not two. `rarity` (0–3) is what `loot_luck` biases toward.

**`LootTableDef.roll()` takes luck and returns a third bucket:**

```gdscript
table.roll(rng, luck)  # -> {"coins": int, "items": {id: n}, "powerups": {id: n}}
```

Each line's weight is multiplied by `(1 + luck * rarity)`, so luck changes the odds and never the
contents (D-063). Existing callers that read `coins`/`items` are unaffected.

**`Chest` gained `cost_coins` and `locked_by`, both per placed instance.** The price runs through
the opener's `chest_price` stat and the key is an ordinary item id; both are charged in ONE
`InventoryService.host_transaction()` **before** the roll, so a refused open grants nothing, charges
nothing and leaves the chest re-openable. Powerup lines are granted with
`PowerupService.host_grant()` and appear in the `open_confirmed` `granted` dictionary alongside
items — `ui/loot/chest_ui.gd` now resolves a display name from either registry.

**Read percentage stats on a base of 1.0** (D-091). `stat(peer, &"loot_luck", 0.0)` returns zero
forever no matter how many stacks are held, because every authored modifier is the multiplicative
half of `(base + flat * N) * (1 + mult * N)`. `Chest._luck_for()` is the worked example, and
`coin_gain`, `harvest_yield` and `craft_seconds` all face the same call when their systems land.

**What the next task should know.** Whatever places chests owes `gilded` a spawn budget (≈1–2 per
island, `ITEMS.md` §6.4) — it is the last of §6's four items still open. The Rusted and Gilded keys
are not authored yet: they need A-044 art before an ItemDef can carry an icon, so `locked_by` is
proven against an existing item id in the check rather than against a real key. W1's remaining item
authoring stays blocked on A-011/A-012 for the same icon reason.


### 2026-08-18 — Asset batch A-010: the practical construction kit — the art task 3.7's buildable set and world-gen's river crossings both need (slate17)

**What shipped, verified:** 18 GLBs covering 14 assets in `assets/construction/exports/`
(`tools/blender/build_construction_set.py`, `assets/source/construction_set.blend`), a catalog, four
previews, `assets/construction/README.md` (the placement contract — read it before placing anything)
and `tools/construction_check.gd`. Nothing else in the repo changed except `mire_art.SCALE`, which
gained the 18 size entries the build asserts against. No scenes, no `content/`, no collision: these
are presentation meshes and the task that wires one into `content/buildables/` adds its collision
under a D-031 exact claim.

**The module contract (D-090) is the API.** Everything mates on it:

| | | |
|---|---|---|
| `MODULE` | 2.00 m | run pitch and piece width — `content/buildables/wall.tres` `size.x`, on its 1 m snap grid |
| `WALL_H` | 3.00 m | that wall's height; palisade, both gate frames, door frame and ladder all reach it |
| `DECK_Z` | 1.00 m | every bridge and dock walking surface |
| ramp | 1.00 m rise over 2.00 m | 26.57°, exactly one deck; three stack to `WALL_H` |

Godot axes: run axis **+X**, deck at **y = 1.00**, a wall's inner face at **−Z**. Verified in the
engine, not asserted: a five-module walkway, a boardwalk corner and a fence corner all close at
**worst joint 0.0000 mm**.

**Hanging a door or a gate is two lines, because the leaves are centred on their hinge axis:**

```gdscript
var frame := load("res://assets/construction/exports/door_wood_frame.glb").instantiate()
var leaf := load("res://assets/construction/exports/door_wood_leaf.glb").instantiate()
add_child(frame); add_child(leaf)
leaf.position = Vector3(-0.55, 0.0, 0.02)   # catalog hinge.hinge_offset_m, Blender (x,y,z) -> (x,z,-y)
leaf.rotate_y(deg_to_rad(90.0))             # catalog hinge.swing_deg — 90 is a real limit, see D-090
```

`gate_double_frame` takes two leaves (`_left` at −1.25, `_right` at +1.25, opening −x);
`palisade_gate_frame` takes `palisade_gate_leaf` at −0.68. `palisade_corner` is the one piece whose
origin is its corner post rather than its centre: its neighbours go at `[-2, 0, 0]` and, turned 90°,
at Godot `[0, 0, -2]`. Every one of those numbers is in `catalog.json`, so read it rather than
retyping it.

**What the next task should know.** `bridge_straight` and `bridge_broken` are a state pair with
**0.0000 mm** drift, swappable in place. The kit deliberately has no `BuildableDef` yet — task 3.7
owns `content/buildables/`, and the pieces that obviously want rows there are the door, the double
gate, the palisade straight/corner/gate, the barricades and the ramp. F-137 records the one loose
end: the 2 m module now exists as a constant in two languages with no check tying them together, and
`tools/construction_check.gd` is the natural place to add one.


### 2026-08-18 — Task 4.6: seed replication + `WorldDeltaLog` ship — the chunk-keyed delta mechanism 4.9's Mire and any future proxy system build on (lm)

**What shipped, verified:** `core/game_state.gd` (new autoload — `run_seed: int`, the seed-only
slice of the "act, day, seed, run status" home `ARCHITECTURE.md` §3 reserves; task 6.1 extends this
file rather than replacing it), `autoload/world_delta_log.gd` (new autoload — the chunk-keyed
mutation log `ARCHITECTURE.md` §4 names), a new `NetSession.peer_admitted(peer_id: int)` signal, and
`world/gen/resource_scatter_field.gd`'s depletion memory now sourcing from the log instead of being
purely peer-local best-effort. `core/net/net_version.gd` bumped 17 → 18 (world-delta RPC pair);
`tools/handshake_check.gd` updated to match. D-089 records the three design calls (GameState scope,
latest-value-wins, buildings excluded); `docs/FINDINGS.md` F-132 is unaffected and stays open — this
task closes the *state-sync* half of what it named, not the *host chunk-residency* half.

**`GameState` API — host-authoritative, one value:**

```gdscript
GameState.run_seed: int                  # 0 until drawn
GameState.host_generate_seed() -> int    # host-only; also self-fires on NetTransport.server_started
GameState.set_replicated_seed(value: int) -> void   # client-side adoption; WorldDeltaLog calls this
GameState.is_seed_ready() -> bool
GameState.ensure_seed() -> int           # lazy self-generate for offline/host-of-one, never null
```

**`WorldDeltaLog` API for anything that mutates ephemeral, chunk-scoped world state — 4.9's Mire
grid is the next intended caller, same shape, a different `kind`:**

```gdscript
WorldDeltaLog.host_record(chunk: Vector2i, kind: StringName, key: String, value: Variant) -> void
# host-only (no-ops on a real client, same gate Harvestable.host_apply_damage uses); applies locally
# AND broadcasts to every connected peer immediately when a real session is running.

WorldDeltaLog.latest(chunk: Vector2i, kind: StringName, key: String, default: Variant = null) -> Variant
WorldDeltaLog.entries_for_chunk(chunk: Vector2i, kind: StringName) -> Dictionary   # key -> value
WorldDeltaLog.entry_count() -> int   # for logs/checks
```

A newly admitted peer (host or client, first join or rebind) gets the run seed and the WHOLE
accumulated log in one reliable RPC, fired by `NetSession.peer_admitted` — no replay of individual
mutations needed. Every value recorded after that is also pushed live to every already-connected
peer. **Buildings do not use this log** — `BuildService`'s placed pieces already replicate to a late
joiner through their own `MultiplayerSpawner` (task 1.5's own mechanism); see D-089 for why adding a
second path for them would be redundant, not defense-in-depth.

**`ResourceScatterField` change for 4.4's own consumers:** `is_point_depleted(point_id)` keeps its
exact signature — reads `WorldDeltaLog.latest()` first (deriving the chunk from `point_id`'s own
`"%d:%d:..."` prefix, never a new parameter) and only falls back to the file's peer-local `_depleted`
memory when the log has no opinion yet. Every holder this file builds now wires its live
`Harvestable.depleted`/`respawned` signals into `WorldDeltaLog.host_record()` the moment the
Harvestable exists, not only at chunk-teardown — a mutation is visible to other peers immediately,
not only after this peer's own chunk happens to unload. `tools/resource_scatter_check.gd`'s full
29-assertion suite still passes unmodified against this change.

**Verified:** `agent godot --script tools/seed_sync_check.gd` (new two-process check, real ENet over
LOCAL, day_night_net_check.gd's driver/child-process pattern) — 12/12 assertions pass: host draws a
seed the instant it starts hosting; a mutation recorded before the client even exists still reaches
it via the admit-time snapshot; the client's independently-regenerated `terrain_hash` (same probe
`tools/check_determinism.gd` uses) matches the host's exactly, proving the SEED crossed the wire, not
just that the math agrees; a second mutation recorded after the client is already connected reaches
it live. `agent godot --script tools/resource_scatter_check.gd` (0 failures, no regression).
`agent godot --script tools/handshake_check.gd` and `tools/net_check_pattern_check.gd` (0 failures).
`agent godot --script tools/terrain_check.gd`, `tools/verify_setup.gd`,
`tools/session_lifecycle_check.gd` (0 failures/regressions). `agent godot --quit-after 15` (clean
boot, 0 `ERROR:` lines).

### 2026-08-18 — Task 3.15: entity addressing ships — selector grammar, `EntityDirectory`, and `entities`/`tag`/`tp`/`kill` (hollow7)

**What shipped, verified:** `core/commands/entity_selector.gd` (`class_name EntitySelector`, a pure
`RefCounted` — the whole `@s @p @a @r @e[...]` grammar, node-free and testable without a SceneTree),
`autoload/entity_directory.gd` (the live directory plus the four verbs), and two new
`CommandService` arg types: **`selector`** and **`vec3`**.

**Resolution is deliberately separate from parsing.** `_parse_selector` turns a token into a parsed
Dictionary and stops there; `EntityDirectory.resolve(selector, ctx)` turns that into actual nodes, on
whichever side is executing. That split is what lets the host re-parse a client's raw line and
resolve it against its OWN complete directory — a selector resolved on the client and shipped as a
node list would be both untrustworthy and stale on arrival.

```gdscript
var parsed := EntitySelector.parse("@e[type=enemy,r=30,limit=5,sort=nearest]")
# -> {ok: true, selector: {kind: &"entities", filters: {...}}}   (or {ok: false, error: "..."})
EntityDirectory.resolve(parsed["selector"], ctx) -> Array[Dictionary]
# each: {node: Node, id: String, kind: StringName, tags: Array, peer_id: int}
EntityDirectory.snapshot() -> Array[Dictionary]        # everything alive, same entry shape
EntityDirectory.add_tag(node, tag) / remove_tag / tags_of
```

Filters implemented in full: `type=` (kind, or a content id — `type=crawler` reads the id off the
node's `definition` resource), `tag=`, `r=`, explicit `x=,y=,z=` origin, `limit=`,
`sort=nearest|random`. Randomness uses the directory's own `RandomNumberGenerator`, never the global
one (`Array.shuffle()` is avoided for exactly that reason).

**`vec3` spans three tokens and is the one arg type that reads the ctx** — `~`, `~5` are relative to
the issuer's position. It is intercepted in `_parse_args` ahead of the per-token loop, because the
type table hands a parser one token and no context; `_parse_vec3` itself only exists to keep the
table a complete description of what `type:` accepts.

**Adding a new addressable entity kind is one line** — `EntityDirectory.KIND_GROUPS`, mapping the
kind to the group its members already join in their own `_ready()` (D-088). No registration call, no
despawn handling. `tools/entity_check.gd` asserts every group name still matches its owning script's
constant, so the one duplicated string per kind cannot rot.

**`PlayerHealth` grew one public seam: `host_place_player(peer_id, position, yaw := NAN)`.** `tp` on
a player must not write the transform — own movement is client-authoritative — so it reuses the
`net_force_respawn` path respawn already shipped, and the host asks that peer's client to place
itself. `NAN` yaw means "keep their facing"; respawn still passes a real yaw, so its behaviour is
unchanged. **No protocol bump** — this task added no RPC, it reused one.

**`kill` never grows a second death path**: an enemy goes through `Enemy.host_apply_damage`, a
player through `PlayerHealth.host_apply_damage`, and anything with no damage seam (a chest, a
haulable) is refused rather than `queue_free`d behind its owner's back.

**What 3.16 inherits.** `tp`/`kill`/`tag`/`entities` are done, including D-030's need for them in
cross-play testing. The remaining §7 catalog verbs are still open, and the `selector` type is now
available to any of them for free. `commands --json` already reports the new arg types, so the
coverage check has its data source.

**Checks:** `tools/entity_check.gd` (offline, 63 assertions — the grammar including nine malformed
inputs, the group-constant guard, stable ids across rescans, pruning, every filter, tags surviving a
rescan, `~` relative coords, and `kill` actually reaching `EnemyWorld.live_count() == 0`) and
`tools/entity_net_check.gd` (two-process ENet — a non-op client refused while a LOCAL `entities`
still answers, an opped client's `kill` resolving on the HOST's directory rather than its own partial
view, and `tp @s` moving the CLIENT's own body in the CLIENT's process, which is the only place the
authority-respecting chain can actually be proven). Both 0 failures, 0 engine ERROR lines, alongside
`command_check`, `command_net_check`, `rule_check`, `rule_net_check`, `player_health_check`,
`handshake_check`, `enemy_check`, `verify_setup`.


### 2026-08-18 — `dodging` now means "invulnerable", not "dashing" (F-125/D-087) — read this before touching the dodge or the powerup that extends it (yarrow21)

`entities/player/player_controller.gd` has **two** dodge windows now, and which one you read decides
whether your change is correct:

```gdscript
_dodge_time_remaining   # the dash MOVEMENT window == dodge_duration_sec.
                        # _apply_horizontal_movement()'s dash branch keys off THIS.
_iframe_time_remaining  # the I-FRAME window == dodge_duration_sec + PowerupService.local_stat(
                        #   &"dodge_iframe_seconds", 0.0), floored at dodge_duration_sec.
dodging                 # the replicated bool. Cleared with the I-FRAME window, so it is true for
                        # the LATER of the two. It is what the host reads.
```

**The trap, stated plainly:** `dodging` is no longer "a dash is in progress" — D-072 said it was, and
F-125/D-087 deliberately relaxed that. Anything that wants "is the player mid-dash" must read
`_dodge_time_remaining`, not the flag. Reading the flag for movement is precisely the bug F-125
fixed: it turns the i-frame powerup into a longer dash, moving where the player ends up.

**The host side is unchanged and needs no change.** `systems/health/player_health.gd`'s
`_is_dodging(peer_id)` still reads `body.get(&"dodging")`, and that is correct — it exists to answer
"should this hit be ignored", which is exactly what the flag now means. Same property, same
`REPLICATION_MODE_ALWAYS` slot, **no protocol bump**.

**Renaming `dodging` to `invulnerable` is wanted and unclaimed.** It is a pure rename with no
wire-format change (the property name is already the wire name); it was not done here only because
`player_health.gd` was held by task 3.14 all session. Whoever holds both files at once should do it —
touch `player_controller.gd`, `player_health.gd`, `tools/dodge_check.gd`, `tools/dodge_net_check.gd`,
and `core/net/net_version.gd`'s comment.

**`dodge_iframe_seconds` is live**, so `docs/POWERUPS.md` lists it under wired stats rather than
Pending. Its floor rule is not tidiness: the window may grow but never shrink below
`dodge_duration_sec`, because D-072's replication guarantee rests on the true-window comfortably
exceeding one `NetConfig.PLAYER_SYNC_INTERVAL_SEC`. A negative modifier that undercut it would
produce intermittently *missing* i-frames, not shorter ones.

**Check:** `agent godot --script tools/dodge_check.gd` — its last section grants 3 real stacks of
`content/powerups/thin_step.tres` and asserts, at one instant, that `dodging` is still true past
`dodge_duration_sec` while `_dodge_time_remaining == 0` and speed is below `dodge_impulse`. That
pair is the regression guard; assert both or the wrong fix passes.


### 2026-08-18 — Task 3.14: gamerules ship — `RuleDef` content family, host-replicated `RuleService`, `rule`/`rules`, eight knobs migrated with defaults unchanged (hollow7)

**What shipped, verified:** `systems/rules/rule_def.gd` (`class_name RuleDef`, a `Resource` — the
AUTHORED half of a knob: `id`, `display_name`, `type` (BOOL/INT/FLOAT), `default_value`,
`min_value`/`max_value`, `description`), `autoload/rule_service.gd` (the live values, host-
authoritative and replicated), and eight `content/rules/*.tres` — the exact first-wave set
`COMMANDS.md` §4.3 names. `registry.gd` gained the family the same way every other one arrives:
`Registry.rules`, `rule_defs()`/`get_rule(id)`/`has_rule(id)`, boot log now prints the count
(`… 2 scatter table(s), 8 rule(s)`). `RuleService` is registered **right after `Registry`** in
`project.godot` — it must load before the systems that adopt values in their own `_ready()`, which
`agent autoload`'s append-only placement could not do, so the line was placed by hand with the
editor confirmed closed (same exception 3.13 took for `CommandService`).

**Protocol 16 → 17**: `net_rule_snapshot` (host → one joining peer, the full id → value map) and
`net_rule_changed` (host → everyone, one id). `tools/handshake_check.gd` extended to match.

**The read seam — what a system that wants a knob does.** Two lines in `_ready()`, and the export
stays exactly where it was:

```gdscript
func _bind_rules() -> void:
    var rules: Node = get_node_or_null(^"/root/RuleService")
    if rules == null:
        return                                   # no service → the @export stands. Documented, not a bug.
    rules.connect(&"rule_changed", _on_rule_changed)
    if bool(rules.call("has_rule", &"my_knob")):
        my_knob = float(rules.call("value", &"my_knob", my_knob))

func _on_rule_changed(id: StringName, new_value: float) -> void:
    if id == &"my_knob":
        my_knob = new_value
```

Reads available on the service: `value(id, fallback)` (fallback returned untouched when the rule
does not exist — that IS the §4.3 export fallback), `value_int`, `value_bool`, `has_rule`, `def`,
`rule_ids`, `value_text`, and `is_overridden(id)` (D-085's precedence signal). Host mutation:
`host_set(id, raw) -> float` returning the value actually stored after the RuleDef coerced it, and
`host_reset(id)`.

**Adding a knob to a later wave is one `.tres` plus the block above** — that is the whole point of
the family. Nothing else needs to change, and nothing needs a protocol bump: the wire shape is
`id → float` and already carries anything you author.

**Two calls a later task should know about.** **D-085**: a rule sitting at its authored default
defers to a level-authored value; only an overridden one wins. Exactly one knob needs this today
(`day_length_seconds`, because `DayNight._level_atmosphere()` already overwrote its export from the
level's `Atmosphere` node). If a *second* knob acquires a competing authored source, the fix is an
authored `defers_to_level` flag on `RuleDef`, not another hand-written branch. **D-086**: a
`CommandSpec`'s `scope` may now be a `Callable(PackedStringArray) -> StringName`, resolved per
invocation — that is how one `rule` verb reads locally and sets on the host. **3.15 gets this for
free** if its entity verbs want the same split (a `tp` that reports a position versus one that
moves a player); `_invocation_scope()` in `command_service.gd` is the mechanism, and
`_declared_scope()` is what introspection reports (the max, `&"host"`).

**`rule_id` is now a central `CommandService` arg type**, validated against `RuleService.has_rule`
— "no such rule 'x' — try `rules`", same voice as `item_id`/`enemy_id`.

**What is deliberately NOT here.** No persistence: a run is one sitting (D-010), so rules reset to
their authored defaults every boot. 3.17's `content/functions/autoexec.mcmd` is how a dev keeps
preferred rules across boots — that is a content file, not a save system, and this task did not
build a stand-in for it. `NetConfig` and world-gen-seeded values stay out of wave 1 for the reasons
§4.3 gives.

**Checks:** `tools/rule_check.gd` (offline — coercion, the family loading through the Registry front
door rather than the service's disk fallback, defaults byte-for-byte unchanged against the numbers
the owners shipped with, `rule`/`rules`, clamps that announce themselves, the LOCAL-read /
HOST-set split, and every owner actually following its knob) and `tools/rule_net_check.gd`
(two-process ENet — snapshot on join reaching the joiner's OWNER and not just its service, host
broadcast mid-session, a non-op client reading but not setting, and an opped client's set crossing
`net_submit_command` to move the host's own `WaveSpawner`). Both 0 failures, 0 engine ERROR lines,
alongside `command_check`, `command_net_check`, `handshake_check`, `day_night_check`,
`wave_spawner_check`, `player_health_check`, `dev_loadout_check`, `enemy_check`, `verify_setup`.


### 2026-08-18 — Task 4.4: resource scatter ships — per-biome tables, MultiMesh visuals, and harvest proxies that reuse the existing wiring unmodified (lm)

**What shipped, verified:** `world/gen/scatter_entry.gd` (`class_name ScatterEntry`, a `Resource` —
one asset in a table: `asset`, `kit`, `weight`, `min_scale`/`max_scale`), `world/gen/scatter_def.gd`
(`class_name ScatterDef` — a per-biome scatter table: `id`, `biome_id`, `cell_size_m`,
`jitter_fraction`, `coverage`, `entries`), `world/gen/resource_scatter.gd` (`class_name
ResourceScatter`, a `RefCounted` — the pure deterministic placement generator, same discipline as
4.1/4.2: no nodes, no shared state), and `world/gen/resource_scatter_field.gd` (`class_name
ResourceScatterField`, a `Node3D` — the chunk-driven visual + harvest-proxy wiring layer).
`registry.gd` gained the loader: `Registry.scatter_tables: Dictionary[StringName, Resource]`,
`get_scatter_table(id)`/`has_scatter_table(id)`, boot log now prints the count. Two worked examples
in `content/scatter/`: `forest_canopy` (`tree_willow_a`, sparse, 10 m cells) and
`forest_undergrowth` (`bush_round_a`, dense, 4 m cells) — split into two tables rather than one
because canopy and understory want genuinely different densities, not one compromise number.
**Like `IslandHeightmap`/`BiomeMap`/`ChunkStreamer` before it, nothing in the shipped game
instantiates a `ResourceScatterField` yet** — it is pure and tested, waiting on 4.6 to put a real
`ChunkStreamer` (and a real world seed) into a running level. D-083 records the three real design
calls (jittered grid over Poisson-disc, the proxy boundary, depletion-memory scope); F-132 records
the one gap this task could not close (a remote client's proxy may have no host counterpart to
reach, since `ChunkStreamer` streams per-peer independently by design).

**`ResourceScatter` API for anything that wants raw placements without the field's node/proxy
policy:**

```gdscript
ResourceScatter.placements_for_chunk(
    chunk_x: int, chunk_z: int, world_seed: int, scatter_defs: Array, biome_defs: Array
) -> Array[Dictionary]
# each: {point_id: String, def_id: StringName, asset: StringName, kit: String,
#        position: Vector3, rotation_y: float, scale: float}
```

Pass `Registry.scatter_tables.values()` and `Registry.biomes.values()` — same convention
`BiomeMap.biome_at()` callers already follow. Pure and deterministic: same inputs, same output, on
every peer and platform (integer multiply/xor seed mixing only, never Godot's `hash()` — see the
file's own header). `point_id` is derived from the point's own coordinates, never from array
position, so it is stable across peers regardless of incidental `Dictionary`/directory-scan order.

**`ResourceScatterField` API for 4.6 (whoever wires a real `ChunkStreamer` into a live level):**

```gdscript
var field := ResourceScatterField.new()
field.world_seed = the_shared_run_seed          # same value the ChunkStreamer got
field.scatter_defs = Registry.scatter_tables.values()
field.biome_defs = Registry.biomes.values()
add_child(field)
field.attach_to_streamer(streamer)               # streamer: your real ChunkStreamer

field.chunk_count() -> int        # chunks currently holding scatter
field.pending_count() -> int      # chunks waiting on chunk_has_collision() to go true
field.is_point_depleted(point_id: String) -> bool   # this peer's own best-effort memory
```

- **Scatter (visuals AND harvest proxies together) builds only for a chunk once
  `chunk_has_collision(coord)` reports true** — the existing LOD0/collision ring from 4.3 (D-080),
  not a second bespoke radius. Tears down the instant the chunk leaves that ring (unload, or an LOD
  upgrade past 0) — see D-083 for why this boundary was reused rather than inventing a new one.
- **A `NODE`-represented harvestable (a tree) gets its own `MeshInstance3D` + `StaticBody3D`
  holder; a `BATCH`-represented one (a bush) gets a logic-only holder pointing at a slot in the
  chunk's shared `MultiMesh`** — `systems/harvesting/harvest_library.gd`'s own split, and the exact
  holder shape `world/gen/authored_world.gd` already builds for the hand-authored maps (same
  `authored_world_harvestable` group, same `asset`/`kit`/`batch_meshes`/`batch_index`/
  `batch_transforms` metas). **`autoload/harvest_world.gd` needed no change** — its existing
  `node_added`-driven wiring picks up a scattered holder exactly like an authored one, so no harvest
  logic was duplicated for procedural generation.
- **Depletion memory is peer-local, best-effort, and lives only as long as the process does** — see
  D-083's third call and F-132's gap. A point this peer previously saw depleted comes back depleted
  when its chunk reloads, via a replayed `host_apply_damage()` (never a direct `active` poke — D-083
  explains the bug that shipped from trying that first). A point neither this peer's host status nor
  memory can vouch for shows intact until the real sync (the `Harvestable`'s own code-built
  synchronizer) says otherwise.

**Verified:** `agent godot --script tools/resource_scatter_check.gd` (new check, fully headless —
the wiring half drives `ResourceScatterField` against a small fake streamer double instead of a real
`ChunkStreamer`, so it needs neither `--windowed` for collision timing (F-005/D-074) nor real
`MultiMesh` readback (F-103) to prove the state machine) — determinism, unique point ids, every
placement staying inside both its own chunk footprint and its table's own biome, the pending→built→
torn-down→remembered→rebuilt lifecycle, and a real `HarvestWorld`-wired `Harvestable` for both the
NODE and BATCH proxy shapes: 0 failures. `agent godot --script tools/verify_setup.gd` (no
regression from the `registry.gd` edit). `agent godot --script tools/harvest_world_check.gd` (0
failures — the shared `HarvestWorld` autoload still wires the hand-authored maps correctly).
`agent godot --quit-after 60` (clean boot, 0 `ERROR:` lines, boot log reads `..., 2 scatter
table(s)`).

### 2026-08-18 — Task 4.3: chunk streaming + LOD ships — `ChunkStreamer` is the seam 4.4/4.5 build on (lm)

**What shipped, verified:** `world/chunk/chunk_streamer.gd` (`class_name ChunkStreamer`, a
`Node3D`) and a rewritten `world/chunk/chunk_mesher.gd` (no longer a throwaway spike — it now
samples `IslandHeightmap.height()`, task 4.1). Full design rationale, the ring/LOD/hysteresis
choices, and the measured numbers are `DECISIONS.md` D-080; the LOD-boundary crack this task
deliberately did not fix is `FINDINGS.md` F-128.

**`ChunkStreamer` API for 4.4 (resource scatter) and 4.5 (nav baking):**

```gdscript
var streamer := ChunkStreamer.new()
streamer.world_seed = the_shared_run_seed   # int, caller-supplied — see the note below
add_child(streamer)                          # anywhere; it is a plain Node3D, not an autoload

streamer.set_anchors([local_player.global_position])   # call every frame (or however often you
                                                          # refresh it) — Array[Vector3], plural on
                                                          # purpose even though today's only caller
                                                          # has one anchor (the local player)

streamer.chunk_mesh_ready.connect(_on_chunk_mesh_ready)  # (coord: Vector2i, lod: int) -> void
streamer.chunk_unloaded.connect(_on_chunk_unloaded)       # (coord: Vector2i) -> void

streamer.is_chunk_loaded(coord) -> bool
streamer.chunk_lod(coord) -> int             # -1 if not loaded
streamer.chunk_has_collision(coord) -> bool  # true only for LOD0 chunks — see below
streamer.loaded_chunk_count() -> int
streamer.pending_job_count() -> int
streamer.last_process_cost_ms() -> float     # this node's OWN per-frame issuing cost, not total
                                              # frame time — see D-080 on why the distinction
                                              # matters on a machine running several agent lanes
```

- **`chunk_mesh_ready` fires on EVERY upload, including an LOD change on an already-resident
  chunk** — it is not a one-time "first time this coord appeared" event. A subscriber that cares
  whether a chunk is *newly* full-resolution (4.5's nav-baking trigger, most likely) must check
  `lod == 0` on each firing rather than assuming a coord seen once at LOD0 stays there; the same
  event with a non-zero `lod` for a coord you previously saw at `lod == 0` is your retire-nav-
  region signal, there is no separate "downgraded from LOD0" signal today.
- **Collision only ever exists for LOD0 chunks** (`chunk_has_collision()`), cooked lazily after the
  mesh uploads — a subscriber that spawns something needing to stand on the ground (4.4's
  proxy-materialization pattern) should not assume a collider is present the instant
  `chunk_mesh_ready` fires; poll `chunk_has_collision()` or wait a frame.
- **A chunk's world footprint** is `Vector3(coord.x * ChunkMesher.CHUNK_SIZE, 0.0, coord.y *
  ChunkMesher.CHUNK_SIZE)` to `+CHUNK_SIZE` on both axes (`CHUNK_SIZE = 32`) — matches
  `ChunkStreamer`'s own placement of the `MeshInstance3D`.
- **`world_seed` has no default.** No `GameState.run_seed` or equivalent exists yet (D-041 already
  flagged this gap for `Chest`; it is still open) — whoever wires this into the live game supplies
  the shared run seed explicitly, most likely 4.6's job.
- **Nothing in the shipped game instantiates a `ChunkStreamer` yet**, same as 4.1/4.2's
  `IslandHeightmap`/`BiomeMap` before it — this is a pure, tested system waiting on 4.6 (seed
  replication + client regen) to actually be added to a running level.

**`ChunkMesher` API** (`world/chunk/chunk_mesher.gd`), for anything that wants raw chunk geometry
without the streamer's ring/LOD policy:

```gdscript
ChunkMesher.build_mesh(chunk_x: int, chunk_z: int, world_seed: int, lod: int = 0) -> ArrayMesh
ChunkMesher.verts_per_side(lod) / vert_count(lod) / tri_count(lod) -> int
ChunkMesher.CHUNK_SIZE = 32   ·   LOD_STEPS = [1, 2, 4]  (metres/vertex)   ·   LOD_COUNT = 3
```

Safe to call from any thread — no shared state, same guarantee `IslandHeightmap.height()` gives
(D-075), which is what makes it safe from `WorkerThreadPool` at all.

**Heads-up for 4.4/4.5's own per-point sampling:** `IslandHeightmap.height()` deliberately builds
two fresh `FastNoiseLite` instances per call for thread safety (D-075). That cost D-080 measured
directly: a LOD0 chunk's ~1225 apron samples raised `ChunkMesher.build_mesh()` from R2's original
placeholder-noise 0.330 ms/chunk to **1.924 ms/chunk single-threaded (3.895 ms/chunk
`WorkerThreadPool`-amortized)** — fine off-thread at chunk-streaming's sampling density (confirmed
by the walk measurement below), but worth knowing before assuming per-vertex/per-scatter-point
heightmap or biome sampling is free at whatever density 4.4's scatter tables or 4.5's nav bake
resolution end up using.

**Verified:** `agent godot --windowed --script tools/chunk_stream_check.gd` (must be windowed, not
headless — F-005/D-074: the collision-cook numbers this whole system is budgeted around are
meaningless under the dummy renderer) — 9/9 functional assertions pass (LOD vertex/tri counts,
mesh determinism at non-zero LOD, correct LOD/collision per ring, both hysteresis directions), plus
the spec's own acceptance test: a full 500 m sprint-speed (6.0 m/s, D-018) walk with
`ChunkStreamer.last_process_cost_ms()` — this node's own per-frame issuing cost, isolated from
whatever else this shared machine is doing — never exceeding 7.67 ms against the 16.667 ms hitch
line (mean 0.19 ms, zero hitches, 11,218 frames, 306 chunks resident at steady state). Full numbers
in D-080. `agent godot --script tools/bench_chunks.gd` and `agent godot --windowed --script
tools/bench_chunk_gpu.gd` (D-015/D-074's own spikes) both still run clean against the rewritten
mesher, confirming no regression to the numbers those decisions already recorded. Full boot
(`agent godot --quit-after 60`): 0 `ERROR:` lines.

### 2026-08-18 — Task 4.2: biome assignment ships — `BiomeMap.biome_at()` is the seam 4.3/4.4 call (lm)

**What shipped, verified:** `world/gen/biome_def.gd` (`class_name BiomeDef`, a `Resource` — the
`.tres` schema) and `world/gen/biome_map.gd` (`class_name BiomeMap`, a `RefCounted` — pure
functions, same discipline as 4.1's `IslandHeightmap`: no nodes, no shared state, safe off-thread,
every op inside the D-017 safe set). `registry.gd` gained the loader:
`Registry.biomes: Dictionary[StringName, Resource]`, `get_biome(id)`/`has_biome(id)`, boot log now
prints the count. **Both live under `world/gen/`, not `systems/<domain>/`** — unlike every other
content family, `ARCHITECTURE.md` §3's project structure already names `world/gen/` as "island
generation, biome placement, POI scatter," so that's the fitting home rather than a new
`systems/world/` domain nothing else uses.

**API for 4.3 (chunk streaming) and 4.4 (resource scatter):**

```gdscript
BiomeMap.moisture(x: float, z: float, world_seed: int) -> float          # 0..1, own noise field
BiomeMap.assign(height: float, moisture: float, biome_defs: Array) -> StringName
BiomeMap.biome_at(x: float, z: float, world_seed: int, biome_defs: Array) -> StringName  # height+moisture+assign in one call
```

Pass `Registry.biomes.values()` as `biome_defs`. **4.3 already has `height` per-vertex from
`IslandHeightmap.height()` — call `assign()` directly with it instead of `biome_at()`, which
recomputes the height internally and would cost it twice.**

**Resolution rule, so a future biome addition doesn't silently reorder existing ones:** among every
`BiomeDef` whose `[height_min, height_max] × [moisture_min, moisture_max]` range contains the point,
the LOWEST `priority` wins; a tie breaks on `id` alphabetically — deterministic on every peer
regardless of `Dictionary` iteration order. **A point matching no def at all falls back to the
single lowest-priority def in the whole registry** (same tie-break), so `assign()`/`biome_at()`
never return `&""` for a real call as long as at least one `BiomeDef` is registered — coverage has
no holes, even before Sequoyah has authored a biome for every height/moisture combination.

**Three worked examples in `content/biomes/`** (D-073: authored, not templated — each is a real
design decision): `shore` (height ≤4m, any moisture, `priority=0` so it wins sea level regardless of
what a sloppier grassland/forest range might also claim there), `grassland` (height 4–100m, moisture
0.0–0.5), `forest` (height 4–100m, moisture 0.5–1.0 — the shared 0.5 boundary is a deliberate
adjacency, not a gap, and resolves to forest on the exact tie by the alphabetical rule above).
Heights beyond ±100m (nothing authored reaches that yet — `IslandHeightmap.HEIGHT_SCALE` is 60m)
fall back to `shore` under the same rule. **Sequoyah authors the rest** — no other biome content is
scheduled as agent work.

**Verified:** `agent godot --script tools/biome_check.gd` (new check — wiring, content pins,
`moisture()` purity/determinism/seed-sensitivity/bounds, `assign()`'s priority/tie/fallback/empty
cases, `biome_at()` determinism and full-coverage sweep — 0 failures), `agent godot --script
tools/verify_setup.gd` (no regression from the `registry.gd` edit), `agent godot --quit-after 60`
(clean boot, 0 `ERROR:` lines, boot log reads `..., 3 biome(s)`).

### 2026-08-18 — Task 3.13: CommandService is in — the front door 3.14–3.17 register specs against (lp)

**What shipped, verified:** `autoload/command_service.gd` (new autoload, registered right after
`DebugConsole` in `project.godot` — see the note at the end of this entry on why that ordering took
a hand edit). Every existing console command is migrated: `debug_console.gd`'s builtins
(`help`/`clear`/`channels`/`log`/`overlay`/`quit`), `dev_loadout.gd`'s `give`/`loadout`/`items`,
`enemy_world.gd`'s `spawn`/`killall`/`enemies`. `DebugConsole.register()` still works — it is now a
deprecation-warning shim over `CommandService.register_spec()` (docs/COMMANDS.md §2.4) — so
`graphics_quality.gd`'s `gfx` and `dev_frame_cap.gd`'s `fps_cap`/`vsync` needed no changes.

**The API the next task registers against**, all cross-autoload calls the established
`get_node_or_null(^"/root/CommandService")` + `.call()` way (never bare — see the file's own header
for why, given it loads earlier than almost everything else):

```gdscript
# Registration — call in your own _ready(), same as every DebugConsole.register() call site before:
command_service.call("register_spec", &"my_command", {
    "scope": &"local",   # or &"host"
    "args": [
        {"name": "target", "type": &"item_id", "optional": true, "default": &"foo", "min": 1, "max": 999},
        # ...
    ],
    "handler": _cmd_my_command,   # func(ctx: Dictionary, args: Dictionary) -> Dictionary|String
    "help": "my_command [target] — one-line usage, doubles as the auto usage-on-parse-failure text",
})
```

- **CommandCtx** is a plain `Dictionary` (deliberately, not a class — see the header on why crossing
  autoload boundaries never carries a custom RefCounted here): `{peer_id: int, source: StringName,
  position: Vector3, facing: Vector3}`. `source` is `&"console" | &"runner" | &"function" | &"hook" |
  &"rpc"` — only `console`/`rpc` exist today; `runner`/`function`/`hook` are reserved for 3.17.
  `position`/`facing` are the issuer's own replicated player body (`PlayerNet.player_for`), zero/
  forward if none exists (an offline harness, or a peer with no body yet).
- **CommandResult** is a plain `Dictionary`: `{ok: bool, message: String, data: Dictionary}`. A
  handler may also just return a bare `String` (compat with the old `register()` shape) — normalized
  to `{ok: true, message: <string>, data: {}}`.
- **Argument types registered today**: `string`, `int`, `float` (both support `min`/`max` — CLAMPED,
  not rejected), `bool` (`on/true/1/yes` vs `off/false/0/no`), `enum` (closed `values: Array[String]`
  set), `item_id`/`enemy_id` (Registry/EnemyWorld lookup, fails parse with the exact `no such … — try
  '…'` wording `give`/`spawn` always used), `peer` (positive int only — no display-name resolution,
  filed F-126; does NOT require the peer to currently be connected, on purpose, so `op` survives a
  D-035 reconnect gap). **3.14/3.15 add their own** (`vec3`, `selector`, `rule_id`, …) by adding one
  entry to `_register_type_parsers()`'s `_type_parsers` dict — nothing else in the file changes shape
  for a new type.
- **A parse failure never reaches a handler.** Missing a required arg → the spec's `help` text as
  `"usage: <help>"`. An arg present but invalid (bad int, unknown item, …) → the type parser's own
  message, verbatim — this distinction is load-bearing (`_parse_args`'s `kind: "missing"|"value"`),
  don't collapse it back to one generic usage string.
- **Op set**: `CommandService._ops: Dictionary[int, bool]`, host-side, peer-id keyed (not literally
  the D-035 token — `core/net/net_session.gd`'s token lookup is private and was outside this task's
  claim; peer-id + following `run_player_rebound`/`run_player_expired` is the same mechanism every
  other host service here already uses, see D-076's neighbor reasoning in the file). Host is always
  op. `op`/`deop` are HOST-scope AND separately require `ctx.peer_id == NetConfig.HOST_PEER_ID` inside
  their own handlers — an opped non-host peer cannot op anyone.
- **`commands` / `commands --json`** (LOCAL, meta) is the introspection contract 3.16's coverage check
  reads: `data.commands` is `Array[Dictionary]` of `{name, scope, help, arg_count}`.
- **Calling from OUTSIDE an autoload that can't safely `await` through `.call()`** (i.e. everyone —
  see the file header): `var handle: int = command_service.call("submit", line, ctx)`, then listen for
  `command_service.command_result(handle, result)` once, filtered by handle — `debug_console.gd`'s
  `_run()`/`_on_command_result()` is the worked example. A script that instead holds a
  **typed/preloaded** reference (`const S = preload("res://autoload/command_service.gd")`, then `node
  as S`) can `await s.execute(line, ctx)` directly — `tools/command_check.gd` is that worked example,
  and it's how every check should talk to it.

**Protocol bump 15 → 16**: `net_submit_command(request_id: int, line: String)` (client → host,
`any_peer`/reliable) and `net_command_result(request_id: int, result: Dictionary)` (host → the one
requester, `authority`/reliable). `tools/handshake_check.gd` extended.

**D-076, the one real surprise**: a client's HOST-scope submission with the console open (tree
paused) never got its RPC reply — measured, not assumed, by `tools/command_net_check.gd`.
`debug_console.gd._run()` now unpauses for exactly as long as one of its own requests is in flight
and re-pauses once they've all resolved. Any future caller that goes through `submit()` inherits this
for free; a caller that calls `execute()` directly from outside a paused tree needs nothing extra.

**`project.godot` ordering**: `agent autoload` only appends; this task hand-moved the
`CommandService=` line to right after `DebugConsole=` (editor confirmed closed first) because the
whole design depends on every autoload after it being able to `register_spec()` synchronously from
its own `_ready()`. If a future task adds another autoload that must ALSO register specs and gets
appended at the end of the list, it is safe (append order doesn't matter for anything registering
INTO CommandService, only for CommandService's own position relative to what calls it) — this note
is only for anyone tempted to "clean up" the list back into pure append order.

**Verified:** `agent godot --script tools/command_check.gd` (offline: parse/usage errors, scope
routing, op refusal/grant, `commands --json`, give/spawn exact strings) and `agent godot --script
tools/command_net_check.gd` (two real ENet processes: non-op refusal over the wire with nothing
granted, host op grants over the SAME front door, the paused round trip, cumulative inventory count
exactly matches both grants) both `failures=0`, 0 `ERROR:` lines. `tools/handshake_check.gd`,
`tools/dev_loadout_check.gd`, `tools/enemy_check.gd`, `tools/enemy_net_check.gd`,
`tools/wave_spawner_check.gd` all still green after the migration. Full boot (`agent godot
--quit-after 15`): 0 `ERROR:` lines.

### 2026-08-18 — Task 4.1: seeded island heightmap — pure `IslandHeightmap.height()`, cross-platform-safe by construction (lm)

**What shipped, verified:** `world/gen/island_heightmap.gd` — `class_name IslandHeightmap`, a
`RefCounted` with one static entry point:

```gdscript
IslandHeightmap.height(x: float, z: float, world_seed: int) -> float
```

Pure and deterministic: no nodes, no shared state, safe to call from any thread (a fresh
`FastNoiseLite` is built per call, same reasoning `chunk_mesher.gd`'s R2 spike already used). Two
layered FBM noise fields (continental 5-octave low-freq + detail 2-octave high-freq at 8% weight,
seeds XOR'd with per-layer salts off the shared `world_seed` — the seed-derivation convention for
every future noise/RNG subsystem to reuse) masked by a cubic radial island falloff, `ISLAND_RADIUS
= 512.0`m (matches the Mire grid's own 1024m coverage, `ARCHITECTURE.md` §5) with `1.0 - t*t*t`,
never `pow()`. Every operation is inside the D-017 world-gen safe set — see D-075 for the full
design rationale and measured `terrain_hash`.

**API for the next task (4.2, biome assignment):** call `IslandHeightmap.height(x, z, world_seed)`
per sample point; it returns metres of elevation, `0.0` at and beyond `ISLAND_RADIUS`, otherwise
roughly bounded by `HEIGHT_SCALE` (60.0, placeholder-tuned — expect to retune once there's biome
color/geometry to look at). A brand-new `class_name` this session is not yet in
`global_script_class_cache.cfg`, so any `--script` harness referencing it needs
`preload("res://world/gen/island_heightmap.gd")` rather than the bare name (F-016) until the editor
does a filesystem scan — `4.2`'s own check script will hit this the same way
`tools/check_determinism.gd` and `tools/terrain_check.gd` did here.

**Verified:** `agent godot --script tools/terrain_check.gd` (6/6 assertions — determinism, seed
sensitivity, island shape/falloff bounds), `agent godot --script tools/check_determinism.gd`
(extended with a fifth `terrain_hash` probe, reproduced identically across two runs, full values in
D-075), `agent godot --quit-after 60` (0 `ERROR:` lines). Not yet wired into anything that renders
— `chunk_mesher.gd`'s own placeholder noise is untouched, explicitly out of scope for this task and
still marked as R2 throwaway pending 4.3's real streamer, which is the natural place to swap it for
`IslandHeightmap.height()`.

### 2026-08-18 — Task 3.4: the powerup roster is complete, 60 defs across all six families (wick20)

**`content/powerups/` now holds the full POWERUPS.md §4 roster**, so any system that wants to test
against real content has it. Registry loads **64 powerup defs**: 59 authored under 3.4, plus
`swift_stride` (the schema's original worked example) and the four `attunement_*` grants, which are
PowerupDefs by D-070 and are indexed in the same dictionary. Ten per family — Fire, Blood, Fungal,
Cold, Void — and nine for Kinetic, where `swift_stride` already held the `move_speed` slot.

Nothing about the schema changed: `PowerupDef` is untouched, and every def validates against the
existing `KNOWN_FAMILIES` / `KNOWN_STATS` catalogs. No new stat names were invented, so
`POWERUPS.md` §2 and `powerup_def.gd` are still in step (F-078).

What a consuming task should know:

- **Most of these are inert until your system routes its base through `PowerupService.stat()`** —
  that is the expected state per 3.4's spec, not a bug. The roster is authored across the whole
  catalog, including the `pending` half, so the content is already waiting when your task arrives.
- **Duplicate effects across families are intentional.** `on_kill_heal_hp` appears on Cauter Seal
  (Fire/Blood) and Scab Feast (Blood/Fungal); `coin_gain` on Cinder Tithe (Fire/Void) and Deep
  Pocket (Void); `loot_luck` on Fruiting Call (Fungal) and Second Glance (Void); `damage_taken` on
  Sealed Veins (Blood) and Rime Shell (Cold). Do not "deduplicate" them — the point is that two
  differently-committed players reach the same effect without abandoning their family.
- **Two entries carry negative components you should not treat as bugs.** Pact Cut is
  `melee_damage` (0, +0.10) with `max_hp` (-4, 0) — additive, so the validator's zero-crossing
  bound does not apply; checked by hand against `player_health.gd`'s base `max_hp` of 100, so five
  stacks is 80 HP for +50% melee. Gaunt Frame is `move_speed` (0, +0.04) with `damage_taken`
  (0, +0.02).
- **`dodge_iframe_seconds` has no timer to extend — see F-125 before wiring it.** Thin Step authors
  the stat, but D-072 collapsed the i-frame window into `dodge_duration_sec`, so routing it is a
  design choice (lengthen the dash, or decouple via the wrappable `_execute_dodge()`), not a
  one-line hook.
- **Icons are deliberately empty** on all 59, per POWERUPS.md — the F-061 pipeline batches them and
  art must not block authoring.

Verify with `.agent/bin/agent godot --script tools/powerup_check.gd`: the registry boot line should
read `64 powerup(s)` with no validation error, and the service check reports `failures=0`.

**Authoring convention, now settled as D-073:** content is authored by agents, one asset at a time
with a design decision behind each — not swept out forty at a time. The former reading of AGENTS.md
("he builds the content") was wrong and has been reworded. 3.2 and 3.7 are open on the same basis.

### 2026-08-18 — Task 4.0a: Spike R2b measured, and 4.3's per-frame chunk budget is ~2–3, gated by collision cooking not GPU upload (lm)

**M4's gate is clear — 4.1 can start.** `tools/bench_chunk_gpu.gd` (new, throwaway spike script,
same convention as `bench_chunks.gd`/`bench_navbake.gd`) measures the two costs D-015 left open on
R2's GREEN verdict, on a real renderer: `.agent/bin/agent godot --windowed --script
tools/bench_chunk_gpu.gd`. Full numbers, methodology, and the "would change my mind" conditions are
`DECISIONS.md` D-074; the finding is closed in `FINDINGS.md` F-005.

**The one number 4.3 needs:** steady-state main-thread cost per streamed-in chunk is **1.17–1.50 ms**
across two runs (collision cook 1.15–1.48 + mesh upload 0.013–0.020 + material bind ~0.001), at R2's
own 32 m/1 m-spacing/2048-tri chunk. Against a 4 ms streaming slice of the 16.667 ms frame, that's
**2.7–3.4 chunks/frame** — use 2–3 as the working budget, not R2's original 0.330 ms mesh-only
figure.

**What 4.3 needs to know before writing the streamer:**
- **Collision cooking is the gating cost, not mesh gen or GPU upload** — it is 4.5× R2's mesh-build
  number and dominates the budget completely (upload + material bind together are under 3% of it).
  4.3's own spec line ("collision cooks lazily, nearest ring only") is exactly the right shape;
  this measurement is why it has to be that shape rather than optional polish.
- **`ConcavePolygonShape3D.set_faces()` is a synchronous PhysicsServer/Jolt call and cannot move to
  `WorkerThreadPool`** the way mesh vertex generation can (same class of constraint R3 hit with
  `NavigationServer3D` sync — D-016). Whatever schedules "how many chunks load this frame" has to
  gate on this call specifically, not on total chunk count or mesh-build time.
- **Variance matters for a streaming system**: collision cook ranged 0.819–3.903 ms across 60
  chunks (2.6× worst-to-mean) — a fixed "3 chunks per frame" quota can still occasionally cost more
  than the slice if an unlucky chunk lands. Budget with headroom, or measure actual elapsed time
  per chunk and stop early rather than trusting a fixed count.
- **Mesh upload and material bind need no special handling** — 0.020 ms and 0.002 ms/chunk are
  noise next to the collision number. A shared `StandardMaterial3D` per terrain type (the pattern
  F-097/D-060 already established for sway materials) is confirmed cheap at this frequency.

**Not measured, and worth knowing before trusting the number at scale:** all 60 chunks were flat
noise-height terrain, same triangle count, on an Apple M5 Pro (Metal 4.0) — not the eventual
minimum-spec GPU, and not chunks near cliffs/structures where geometry (and so `ConcavePolygonShape3D`
cost) could differ. D-074 names both as what would move the budget.

### 2026-08-18 — Steam's social layer now actually works from a build: joinable presence and a loadable macOS overlay (pike14)

Two defects that only a real Steam session could surface, both fixed and both prerequisites for
task 1.12's friends-list half.

**A lobby now advertises itself.** `SteamLobby` sets the `connect` rich presence key to
`+connect_lobby <lobby_id>` on lobby create *and* on lobby join, clearing it on leave. That single
key is the whole of what Steam uses to decide a friend is joinable — without it the friends-list
entry shows *In Game* with no **Join Game**, degraded to *Invite to Watch*, which is what a live test
showed (F-123). Note the receiving half was always built, so nothing else needed changing: the value
is the same command line `_check_launch_invite()` already parses on a cold start. If you touch either
side, run `tools/rich_presence_check.gd` — the advertised argument and the parsed argument must not
drift.

**macOS builds can load the overlay.** The preset now carries
`allow_dyld_environment_variables` alongside `disable_library_validation`. Steam injects its overlay
via `DYLD_INSERT_LIBRARIES`, and a hardened-runtime binary drops `DYLD_*` without that entitlement,
so the overlay was never in the process and no hotkey could summon it (F-124). Any macOS overlay or
invite result recorded before `1754bd1` is untested, not passing — `SteamLobby.open_invite_overlay()`
is the project's only invite UI, so macOS had no working invite path at all.

**Still owed by a human.** That the overlay *draws* needs one launch through Steam on macOS; a
headless run has no renderer for it to draw into. Everything upstream of the draw is verified.


### 2026-08-18 — Shippable builds exist for all three platforms, and the export pipeline is now a real check (pike14)

**`export_presets.cfg` is committed and has all three presets.** It previously held exactly one
(macOS), so the Windows and Linux builds had never been produced — there was nothing lost to find.
Windows Desktop and Linux are both x86_64 debug presets. Build any of them headlessly, never from
the editor:

```bash
.agent/bin/agent godot --headless --export-debug "Windows Desktop" export/windows/MIRE.exe
.agent/bin/agent godot --headless --export-debug "Linux" export/linux/MIRE.x86_64
.agent/bin/agent godot --headless --export-debug "macOS" export/macos/MIRE.app
```

**All three outputs go to `export/`, which is gitignored and carries a `.gdignore`.** Both halves
matter. Gitignored keeps ~165 MB per platform out of history. The `.gdignore` keeps Godot's
filesystem scanner out of that directory, which is load-bearing because `export_filter` is
`all_resources`: without it, each build is packed into the next one. The previous macOS output sat
loose in the project root (`test.app` + `test.command`) where exactly that would have happened, and
where `git add -A` would have committed the bundle.

**An exported build is now part of what "verified" means.** F-121 shipped three empty builds behind
a fully green `verify_setup` — the content loaders' `.tres` filter missed Godot's `.tres.remap`
packing, so every platform booted with zero content and no error. A source-only check is structurally
blind to that class of defect. Any change to content loading, or to a runtime `DirAccess` scan, needs
one exported-build smoke run alongside the source run:

```bash
./export/macos/MIRE.app/Contents/MacOS/MIRE --headless --quit-after 90 2>&1 | grep 'content: loaded'
```

The expected line matches the source run exactly; anything reporting `0 item(s)` is F-121 again.

**Both VMs are git-synced and hold current builds.** Windows `C:\MIRE-current` is now a real clone
of `origin/main` (it was an rsync copy with no `.git`), so refreshing it is `git pull` over SSH.
Linux `~/mire-current` has no git and no passwordless sudo, so it syncs by `git archive origin/main`
piped through `rsync --delete`, excluding `addons/godotsteam/`, `.godot/`, and the machine-local
`.agent/` state — the exclusions are not optional, they are what stops `--delete` from wiping the
95 MB gitignored addon and the import cache. **`*.import` is gitignored, so any sync must be
followed by `--import` on that machine** or every asset reference dangles; that bit us once already
this session. Runnable builds are at `~/mire-build` (Linux) and `C:\MIRE-build` (Windows).


### 2026-08-18 — Task 3.9: Attunements ship as a thin selection layer over 3.3's PowerupService — framework and all four DESIGN §4.5 roles, both shipped (lm)

**What shipped, verified:** `systems/attunement/attunement_def.gd` (content schema: id, display_name,
`better_at`/`worse_at` flavour text, `granted_powerup_id`), `autoload/attunement_service.gd`
(HOST-authoritative selection: request/lock/broadcast), `ui/attunement/attunement_ui.gd` (the D-032
picker, autoload `AttunementUI`), `Registry.get_attunement`/`has_attunement` (new `attunements`
family, `content/attunements/`, loaded after `haulables`). Content: all FOUR DESIGN §4.5 roles —
`content/attunements/{warden,forager,tinker,reaver}.tres`, each naming a backing
`content/powerups/attunement_<role>.tres` (`max_stacks=1`, no §4.4 tags), authored via
`tools/setup_attunement_content.gd` (deterministic, same pattern as `setup_haul_content.gd`/
`setup_station_content.gd`). `PROTOCOL_VERSION` 13 → 14 (`core/net/net_version.gd`,
`tools/handshake_check.gd` extended). New `ARCHITECTURE.md` §2.2 row: "Attunement selection", HOST.

**Why all four roles shipped, not one worked example (D-070):** DESIGN §4.5's roster is fixed and
named directly by design — "one of four roles" cannot be demonstrated, let alone selected from, with
one worked example the way a 40–60 entry powerup pool can. This is content in the same sense
3.1's two StationDefs were: the minimum needed for the mechanic to exist at all, not an open pool.
Only the STAT-shaped half of each role's DESIGN table row is implemented (mapped onto existing
`PowerupDef.KNOWN_STATS`, magnitudes placeholder-tuned like every other 3.x worked example); the
qualitative halves (Warden's taunts, Tinker's Ward turrets, Forager's terrain sight, Reaver's Ward
lockout) are out of scope per the task's own "zero new stat plumbing" line — D-070 names exactly
which table cells are still owed and to whom.

**Verified:**
- `agent godot --script tools/attunement_check.gd` — offline, host-of-one: all four roles load
  through the real registry with a resolvable backing powerup; picking grants through
  `PowerupService.host_grant` and the modifier resolves through the real `PowerupService.stat()`;
  a second pick is refused and does not double-grant; an unknown role id is refused; the broadcast
  signal fires with the right peer/role; D-035 rebind moves the pick, expiry drops it. **30
  assertions, 0 failures, 0 `ERROR:` lines.**
- `agent godot --script tools/attunement_net_check.gd` — real two-process ENet: the host's
  pre-existing pick reaches a joiner (mid-run join), the client's own request round-trips through
  the host and is confirmed, the host's own record and the granted powerup are checked host-side
  (not trusted from the client), and a second real request over the wire is refused. **12
  assertions, 0 failures, 0 `ERROR:` lines.**
- `agent godot --script tools/attunement_ui_check.gd` — offline: the picker stays closed with no
  local player body, opens exactly once a local-authority body appears (polled off the `&"players"`
  group, no dependency on `player_controller.gd` — see below), shows all four roles, and closes on
  an accepted pick. **8 assertions, 0 failures, 0 `ERROR:` lines.**
- `agent godot --script tools/handshake_check.gd` — protocol 14, real ENet mismatch/reject proven.
- Full boot: `agent godot --quit-after 60` — 0 ERROR, registry logs `4 attunement(s)`.

**API for the next task:**
```gdscript
AttunementService.request_select(attunement_id: StringName) -> void   # client-callable
AttunementService.selection_of(peer_id: int) -> StringName            # &"" = not yet chosen
AttunementService.has_selected(peer_id: int) -> bool
AttunementService.local_selection() -> StringName
AttunementService.all_selections() -> Dictionary                      # peer_id -> attunement_id, everyone
AttunementService.selection_changed(peer_id, attunement_id)           # signal, every peer, incl. &"" = retired
AttunementService.selection_confirmed(accepted, attunement_id, detail) # signal, requester only
AttunementUI.is_open() / poll_now() / choose(attunement_id)           # test/debug seam
```

**Design calls made and why (also in DECISIONS.md D-070/D-071):** (1) An Attunement grants exactly
one stack of an ordinary `PowerupDef` through `PowerupService.host_grant()` — no new stat plumbing,
per the task's own spec line (D-070). (2) Selection is broadcast in FULL to every peer, unlike
`PowerupService`'s owner-full/teammate-counts split — DESIGN §4.5's whole point is that the party
sees who picked what and self-organizes around it, so there is nothing to hide. (3) The trigger is
the local player's first spawn this session ("run start"), not DESIGN §4.5's unbuilt "first
Wellspring cap" (D-071) — Wellsprings are M4+ and gating a buildable M3 feature on them would strand
it. (4) `AttunementUI` polls `get_tree().get_nodes_in_group(&"players")` for a local-authority body
every 0.5s rather than adding a new signal to `player_controller.gd` — that file was mid-edit-broken
under lp's 3.8b claim for the whole of this task (missing `_execute_dodge()`, confirmed pre-existing
via the content-setup script's own boot log, not touched here) and this task does not claim it
either way; the group-membership contract (`add_to_group(&"players")` + `is_multiplayer_authority()`,
both set identically offline and online) already existed and needed no change. (5) No Escape/dismiss
path on the picker — task 3.9 already puts respec out of scope, so there is nothing to reopen TO.

**NOT done — respec, and the qualitative table halves — both by design, not oversight:** see D-070
for the exact list of what each role's row is still owed and which future task most naturally owns
it (3.6/3.7 for Ward turrets, a rendering/harvesting task for terrain-sight, homeless mechanics for
taunts and the Ward lockout).

### 2026-08-18 — Task 3.10: heavy hauling ships as a system, but `HaulService` is NOT yet a registered autoload — one command finishes it (lp)

**What shipped, verified:** `systems/hauling/haulable_def.gd` (content schema),
`systems/hauling/haul_math.gd` (pure carry-speed math — no node, no session), `systems/hauling/
haulable.gd` (the object: request_pickup/request_drop, host-validated, spawner-attached),
`autoload/haul_service.gd` (the spawner + D-035 rebind/expire fan-out), `Registry.get_haulable`/
`has_haulable` (new `haulables` family, `content/haulables/`), one worked example
(`content/haulables/heavy_ore_crate.tres`, via `tools/setup_haul_content.gd` — DESIGN §4.5's "high-tier
ore" case). `PROTOCOL_VERSION` 12 → 13 (`core/net/net_version.gd`, `tools/handshake_check.gd`
extended). `tools/interp_coverage_check.gd`'s `SMOOTHED` table gained `haulable.gd` (D-043 — it
replicates `position`, so it must be smoothed; it self-attaches `NetInterp` exactly like `enemy.gd`).
New ARCHITECTURE.md §2.2 row: "Carryable objects (heavy hauling)", HOST.

**Verified:**
- `agent godot --script tools/haul_check.gd` — offline, host-of-one: HaulMath's solo/duo math (pure,
  no PlayerNet needed), `HaulableDef.validation_errors()`, spawn/pickup/drop/2-carrier-cap/
  "already carrying something else"/D-035 rebind+expire, all against a synthetic def injected the
  way `chest_check.gd` does it. **34 checks, 0 unexpected failures**
  (`EXPECTED_ERROR_PATTERNS="unknown haulable id"` covers the one deliberately-provoked
  `HaulService.host_spawn()` rejection, same convention as `connect_retry_check.gd`).
- `agent godot --script tools/haul_net_check.gd` — real two-process ENet: a real client's pickup/drop
  round-trips through the host and back (RPC, not a call from the host's own peer id); **the spec's
  own required proof** — a client writes its own player's `global_position` 990 m away in one
  instruction (the exact primitive a speed hack already has, since own-player movement is
  client-authoritative, §2.2 row 1) and the host's crate is asserted to have moved at most its
  bounded solo-drag speed × elapsed wall-clock time, nowhere near the jump, while still measurably
  creeping toward the new target (rules out "frozen" passing by accident). **13 checks, 0 failures.**
- Full boot: `agent godot --quit-after 60` — 0 ERROR, registry logs `1 haulable(s)`.

**API for the next task (world-gen, a POI, an ore vein):**
```gdscript
HaulService.host_spawn(def_id: StringName, pos: Vector3) -> Node3D   # host-only, mirrors EnemyWorld.host_spawn
HaulService.live_count() / live_haulables() -> Array[Node]
HaulService.is_peer_hauling(peer_id: int, exclude: Node = null) -> bool   # D-069: one carry per peer
Haulable.request_pickup() / request_drop() -> int   # request id; answer via pickup_confirmed/drop_confirmed
Haulable.carriers -> PackedInt32Array   # replicated, ON_CHANGE, 0/1/2 peer ids
Haulable.carrier_count() / is_carrying(peer_id) -> bool/int
```

**NOT done — two remaining steps, both editor-closed-only, and why they're not done here:** the
editor was open (launched as `-e res://levels/hollowmere.tscn`) for the whole of this task except one
brief window, which was enough to author the worked-example content but not enough for either step
below — see F-120: `-e` is the short form of `--editor`, and the *documented* by-hand `pgrep -fl
'Godot.app.*--editor'` check misses it (though `agent autoload`'s own check correctly caught it and
refused every retry). Every check proves the system works regardless — `tools/haul_check.gd` and
`tools/haul_net_check.gd` both instantiate `HAUL_SERVICE_SCRIPT.new()` under `/root` and name it
`HaulService` by hand, the same technique `tools/day_night_check.gd` uses ahead of `agent autoload
DayNight` per that task's own spec ordering (write the check, prove it, then register) — so neither
gap below is a "does it work" question, only a "does the shipped game load it" one.

1. `content/haulables/heavy_ore_crate.tres` is on disk (authored via `tools/setup_haul_content.gd`,
   registry logs `1 haulable(s)`) but **not committed** — D-031 blocks committing any `.tres` while
   the editor is open, and it still was at close-out. `git status` shows it as the one untracked file
   this task left behind; `git add content/haulables/heavy_ore_crate.tres && git commit` once the
   editor is closed is the whole fix, no claim needed beyond that exact path.
2. `HaulService="*res://autoload/haul_service.gd"` **is now in `project.godot` on disk** — a later
   `agent autoload HaulService res://autoload/haul_service.gd` this same session returned "already
   registered" once the editor had closed (something/someone else ran it, or closed the editor long
   enough for a retry to land; either way the line is there). **`project.godot` itself is still
   uncommitted, and NOT by this task** — `git diff project.godot` shows the `HaulService` line
   alongside unrelated pre-existing edits (a `[layer_names]` reorder and a
   `textures/vram_compression/import_etc2_astc` line) that were already dirty before this task
   started (see the `M project.godot` at session start). Committing it now would attribute someone
   else's edits to this task (F-014/F-117's exact hazard) — leave it for whichever task legitimately
   claims `project.godot` next, or for Sequoyah directly. Nothing further to DO here: the
   registration line itself is correct and append-only per D-019, just riding in an otherwise-dirty
   file this task did not make dirty.

**Design calls made and why (also in DECISIONS.md D-068/D-069):** (1) The object's position update is
`move_toward` at a capped speed in EVERY carrier-count branch, never a direct assignment — "full
speed" (duo) and "slow drag" (solo) are the same bounded mechanism at two different speeds, not two
different mechanisms, because own-player movement is client-authoritative and the object must never
be able to inherit a carrier's teleport (D-068). (2) One peer can carry at most one haulable at a
time — DESIGN §4.5 reads as one pair of hands, not one slot per object (D-069). (3) Reused
`NetInterest.Class.ENEMY` (15 Hz, distance-filtered) for the haulable's synchronizer rather than
adding a new interest class — "host-simulated, moving, filtered" already describes it exactly, and
`NetConfig`/`net_interest.gd` gain no new surface. (4) The generated art-less placeholder is an
`AnimatableBody3D`, not the `StaticBody3D` `BuildService`'s own placeholder uses — this body's
transform is rewritten by script every host physics tick, and Godot's own guidance is that a
script-moved body should be Animatable so it still pushes what it touches rather than being treated
as truly static.

### 2026-08-18 — F-117: `ship` now warns when a claimed file drifted after `done()` — a lane closing a finding is not off the hook for checking (lp)

**What changed:** `st["recent"][f]` (written by `_release()`, read by `ship`'s staging logic) gained
a `"hash"` field — a sha256 of the file's bytes at the moment the task released its claim on it. `ship`
recomputes the hash for every file it's about to stage; if the file's most recent releasing task is
this one but its current bytes don't match the snapshot, it prints a **non-blocking** warning naming
the file and pointing at `git diff` — it still ships the file, because the content is usually fine,
just possibly misattributed.

**Why you'll see this:** `docs/FINDINGS.md` and `docs/SPECS.md` need no claim to *write*, only to
*commit* (F-006/F-072), and this repo runs every lane in one shared working directory (F-102) — so
two lanes closing different findings in the same window routinely both edit both files. If you
`agent done` a task, see this warning on your next `agent ship`, and did NOT expect anyone else to
have touched that file since: `git diff -- <file>` before pushing, and if another lane's prose is in
there, that's fine — it landed correctly, just under your commit's name instead of theirs (D-067).
**This is a heuristic, not a lock** — it fires only on the exact `done()`-to-`ship()` gap; it does not
catch drift that happened *before* your `done()` (that's your own edit, expected) or attribute which
lines came from whom.

**Verify a harness change against this:** `python3 tools/harness_check.py` now has two F-117 cases
(`ship warns when a claimed file drifted after done()`, `ship stays quiet when the hash matches`) —
extend those, don't write a third check file, if you touch `_release()` or the staging logic in
`cmd_ship` again.

### 2026-08-18 — F-118: `Emitter.LEAF_FALL`, and two traps in `EnvironmentVfx` registration (vane19)

**Adding an emitter class is four edits and no new machinery:** a value on `AssetVfx.Emitter`, a row
in `EMITTER_PROFILES` (`max_live`/`shadow_live`/`radius`), rows in `EMITTER_RULES`, and a branch in
`EnvironmentVfx._make_effect()`. `LEAF_FALL` is the worked example — no light, no shadow, 12 live.

**`EMITTER_RULES` is longest-prefix-first, first match wins, so exclusions come FIRST.** `tree_snag`
and `tree_bare` map to `Emitter.NONE` explicitly, above `tree_`; without that a dead snag sheds
leaves. Same shape for `harvest_tree_`'s stumps and felled trunk.

**Two things a new emitter class must know, both paid for by F-118:**

1. **`EnvironmentVfx` only hides a host mesh when `AssetVfx.replaces_host_mesh()` says so** —
   `flame_outer` and `furnace_fire`, the hand-authored placeholders. It used to hide *any*
   non-batched, non-GLOW emitter host, which since F-114 (harvestable trees are their own nodes)
   would have made 94 trees invisible.
2. **One site per PROP, via `_emitter_host()`** — the nearest ancestor carrying `ASSET_META`, marked
   with `EMITTER_HOST_META` so the prop's other ~40 GLB mesh parts do not each register their own.
   Total emitter sites on Hollowmere: 2,194 → 363.

`tools/environment_vfx_hollowmere_check.gd`'s budget ceiling is now **derived from
`EMITTER_PROFILES`**, so adding a class raises it automatically instead of turning the check red.

### 2026-08-18 — 7.1/7.2 v1: game audio is synthesized from committed recipes — toolkit, 2 ambient loops, 19 SFX (tine18)

**`tools/audio/mire_audio.py` is the instrument rack** — additive pads, Karplus-Strong plucks, FM
bells/groans, filtered-noise beds, convolution reverb, circular loop rendering, all seeded and
bit-reproducible. `render_music.py`/`render_sfx.py` hold the scores and recipes (edit the data
tables, not the engine), `audio_check.py` is the objective gate (clipping/DC/RMS/loop seams),
`tools/audio_import_check.gd` proves in-engine loading. **Read `docs/AUDIO.md` before adding any
sound** — palette rules (rewards ring in D, no percussion in ambience, mono SFX) live there.

- Assets: `assets/audio/music/ambient_{day,night}.ogg` — 3:44 seamless loops; `loop=true` lives in
  the two **force-committed `.ogg.import` sidecars** (gitignore exception, `icon.svg.import`
  precedent). `assets/audio/sfx/*.wav` — 19 mono effects, peak-normalised with mixer headroom.
- **Wiring is NOT done.** Next: a client-local MusicDirector autoload crossfading on DayNight's
  `day_started`/`night_started` (names proven in `tools/day_night_check.gd`), and sound fields on
  `weapon_def.gd`/`harvestable_def.gd` — those files sit under F-113/F-114 claims, wire after they
  clear. Audio is client-local presentation; no audio RPCs, ever (ARCHITECTURE §2.2).
- Re-render deps: system python3 + numpy, `pip install --user soundfile` (brew ffmpeg lacks
  libvorbis; ffmpeg only makes the MP3 listening copies Sequoyah auditions in chat).

### 2026-08-18 — F-115: ground mist is a fog SHADER built from code, and the look is judged from rendered PNGs (vane19)

**`world/environment/ground_fog.gd` + `.gdshader`.** `PlaytestAtmosphere._resolve_ground_fog()`
creates one for any level with an `Atmosphere` node — same reasoning as the star field, and the same
bug it fixes: the controller used to drive three `FogVolume` siblings by name and the shipped map
had none of them. **Do not add a GroundFog to a level scene**; if one is authored as a child named
`GroundFog` it is reused, otherwise it is built.

- Density is a function of `WORLD_POSITION`, so the volume is only an evaluation window. It follows
  the camera **in XZ only** — following in Y makes a plateau as foggy as a valley.
- `base_height` is measured off the terrain AABB (group `authored_world_terrain`), a quarter of the
  way up, **on the first frame that group is non-empty** — not in `_ready()`, where `Atmosphere` runs
  before `World` and the group is still empty. `NAN` means "not measured yet", never "y = 0".
- `apply_look(scale, albedo, emission, emission_energy)` is the only thing the atmosphere calls.
  Colour is passed in rather than derived in the fog so the mist, the sky and the shafts cannot
  disagree about the hour.
- `Environment.volumetric_fog_density` is now 0.00006 and must stay near there: it exists only so a
  sunbeam has a medium to be visible in. Raising it back is how the flat haze returns.
- **Anything on the `low` graphics preset is free** — it disables volumetric fog on the Environment
  and every FogVolume goes inert.

**Judging a look change: `tools/atmosphere_look_shot.gd`, run `--windowed`.** It renders the shipped
map at eight times of day plus sunward and forest-interior framings to `user://atmosphere_look/*.png`.
Two traps it already paid for: **pose the clock through `DayNight`** (`time_of_day` in 0..1), because
DayNight re-applies the hour every physics tick and overwrites `Atmosphere.set_time_of_day()` before
the frame is drawn; and the sun's elevation is `sin((hour - 6) / 24 * TAU) * 90`, so **hour 18 is
exactly sunset and 18.6 is already full night** — golden hour is only ~1.2 game-hours wide. It
renders through its own `SubViewport` because `agent godot --windowed` forces a 64×64 window (F-077).

### 2026-08-18 — `agent godot` imports before every run, so a check can no longer read a stale build (F-093, lm)

**Nothing to build against — this is a behaviour change in the shared harness itself.** Every
`agent godot <...>` call (any args other than a bare `--import`) now runs a real
`--headless --import` pass first, inside the same lock, before the caller's own run. The two-step
manual dance the F-093 finding used to recommend (`agent godot --import`, then run the check) is no
longer necessary — one `agent godot --script tools/x_check.gd` is enough, and always sees the current
build. `docs/ASSET_TRACKER.md`'s old "re-run to confirm" advice is gone for the same reason; it never
actually worked (F-093 measured three identical stale reruns), the import pass is what fixes it.

- **Cost:** roughly one extra Godot boot per `agent godot` call. Cheap when nothing changed (Godot
  only reimports what's dirty); the point of the fix is that the cost is now unconditional so no
  agent has to remember when it's needed.
- **`--import` alone still works** as its own command and is not doubled — `cmd_godot` skips the
  pre-pass when the caller's own args already ask for one.
- Test double for this lives in `tools/harness_check.py` (`fake-godot`, argv-echo pattern) — two
  cases assert the double-invocation shape. Extend those, don't write a new test double, if this
  needs more coverage later.

### 2026-08-18 — the in-game Steam lobby menu exists (6.10's lobby-UI slice, pulled forward per D-030) (moss11)

**Press M in game → the multiplayer panel.** `ui/lobby/lobby_menu.gd`, autoload `LobbyMenu`
(CanvasLayer, layer 55). Host a friends-only Steam lobby, **COPY** the lobby ID to the clipboard,
paste a friend's ID and **JOIN**, open the Steam **invite overlay**, see the member list, leave.
This is what makes 1.12's evidence run cheap: the ID travels over any chat instead of between
terminals. Sequoyah asked for it now, explicitly ahead of its roadmap slot.

- **UI over live seams only** — every button is `SteamLobby.host_session()` / `join_by_id()` /
  `open_invite_overlay()` / `leave()`, plus `NetTransport.leave()` for a non-Steam session. Network
  authority: none (client-local, §2.2's last row). Member rows render `SteamLobby.members()` — lobby
  membership, never authoritative.
- **Toggle is the raw keycode `KEY_M`** (DebugConsole's backtick pattern), so the input action map
  was not touched; A/B/D/E/S/W, Space, Tab, Shift were taken. Esc closes it, consumed in `_input`
  before `player_controller.gd`'s `_unhandled_input` mouse-release toggle can see the press. Typing
  into a focused LineEdit never toggles it.
- **D-032 honoured:** joins `blocks_gameplay_input` while open, refuses to open while any other
  node holds that group, frees the cursor and restores capture state on close.
- **Status line carries every outcome verbatim** — `lobby_failed`, `NetSession.session_ended`
  detail, connect retries/rejoins, and a mapped "Steam is not available" for `ERR_UNAVAILABLE`.
  `invite_accepted` while already in a session opens the panel with the friend's lobby ID prefilled
  rather than yanking the player out (SteamLobby's own rule).
- **Check:** `agent godot --script tools/lobby_menu_check.gd` — 24 assertions. Headless has no Steam
  client, so it proves the panel, the group interlock and every refusal path; the happy path is
  1.12's live run. Driveable from a check via `set_open()`, `request_host()`, `request_join()`,
  `set_join_field_text()`, `status_text()`, `member_row_count()`.
  **F-170 (fixed 2026-08-19):** on a machine whose own Steam client is actually running and logged
  in, the check probes `SteamLobby.initialise()`/`is_ready()` before its Steam-unavailable
  assertions and prints `SKIP:` for the four that don't apply there, instead of firing a fake-id
  join/host that would start a real request against Steam's servers. `failures=0` either way; a
  `SKIP:` line is expected on a dev machine with Steam up, not a regression.
- **Still open in 6.10:** main menu shell, settings, seed entry (feeds 4.6). The lobby slice is done.

### 2026-08-18 — F-113/F-114: harvesting is keyed to the ASSET, and health is authored in tool swings (vane19)

**`systems/harvesting/harvest_library.gd` is the new source of truth for "is this worth hitting".**
It is `AssetVfxLibrary`'s twin — asset id in, answer out, no reference to any scene, map or layout —
and both `world/gen/authored_world.gd` and `autoload/harvest_world.gd` read it, so the world builder
and the wirer can never disagree. **A generated world gets a choppable pine by stamping
`tree_pine_c` on the node it emits; that is the entire contract.** Three static calls:
`definition_path_for(asset)`, `is_harvestable(asset)`, `representation_for(asset)`.

- **`Represent.NODE` vs `Represent.BATCH`** is how density stays affordable. NODE props get their
  own holder and mesh (trees, ore, boulders — 387 on Hollowmere). BATCH props stay inside the
  chunk's `MultiMesh` and get a logic-only holder (794 bushes and saplings, zero extra draw calls);
  the builder records `batch_meshes` / `batch_index` / `batch_transforms` metas on that holder and
  `HarvestWorld` turns them into the hook that hides one instance by zeroing its transform.
  **Never read a placement back with `MultiMesh.get_instance_transform()`** — it is a
  RenderingServer round trip that answers identity under the dummy renderer every headless check
  runs on, which is why the builder records the transform instead.
- **`HarvestableDef.active_state_scenes` may be empty**, meaning "this asset is its own intact
  visual". `Harvestable` then shows/hides whatever already draws the prop through
  `set_visual_hook(Callable)` — one seam that covers both a `Node3D` and a MultiMesh slot. This is
  what lets one `wild_tree.tres` cover 62 species without a damage-state export each. A definition
  in this mode may also have **no collider**, and that is legal.
- **`CollisionBody` is still mandatory** for a definition that ships state scenes: the states swap
  under it and something has to own the shape.

**The tool axis is separate from combat damage, on purpose.** `WeaponDef.tool_class`
(`Any`/`Chop`/`Mine`, stored as the int from `HarvestLibrary.Tool` — never reorder it) and
`WeaponDef.harvest_power` (**wooden 1, stone 2, iron 3**). `HarvestableDef.required_tool` +
`wrong_tool_scale` (0.34, floored, so an under-powered wrong tool reaches exactly 0 and can never
chip a prop down). **Harvestable health is authored in tool power**, so `max_health = 6` reads
"three swings of a stone axe" and stays that sentence when enemy damage is retuned.

- `Harvestable.host_apply_tool_damage(tool_class, harvest_power, peer_id)` is the host seam combat
  now prefers, chosen by **feature test** so `&"damageable"` stays one contract and enemies are
  untouched. `harvest_damage_for()` previews the number for the broadcast.
- A wrong-tool connect returns **true with 0 damage**, not a miss.
- **`autoload/harvest_world.gd` no longer listens for `attack`.** Adding a second damage source on
  one click is how F-113 happened; `try_harvest_from_camera()` remains as an API only.

**New content:** `wild_tree`, `boulder`, `rock_cluster`, `fallen_log`, `stump`, `bush`, `sapling` in
`content/harvestables/`, plus `content/items/stick.tres`. **3.2 (ivy8) — read F-116 before authoring
`content/items/branch.tres`:** `stick` already ships the `pickup_branch` art and is what 794 bushes
yield, so the two ids must converge rather than both exist.

**New checks:** `tools/harvest_tool_ladder_check.gd` (17 weapon×harvestable swing counts against the
shipped `.tres`) and `tools/harvest_batch_check.gd` (**run `--windowed`** — MultiMesh readback needs
a real renderer, and `physics_interpolation` means a freshly written transform reads back part-way).

### 2026-08-18 — `docs/ITEMS.md` is the item/loot/chest catalog; 3.2, 3.5 and 3.8 author against it (ivy8)

The full item economy is planned: ~136 items across gathered raws, creature drops, refined
components, food, tonics, throwables, tools/weapons, keys and the **Gleam jackpot pool**, plus the
chest-tier table set (reed cache → bog chest → strongbox → wellspring → **gilded** → sunken → boss).
It is a menu in the POWERUPS.md sense — hand-authored `.tres` later, never bulk-generated (D-006).
What matters for the next tasks:

- **3.5 gained four named mechanics** (spec block updated): `LootEntry.kind ITEM|POWERUP`,
  `LootEntry.rarity` (the consumer `loot_luck` has been waiting for), chest `cost_coins` +
  `locked_by` key check, and a gilded-tier placement budget. **D-063**: jackpots are balanced by
  rarity only — never neutered.
- **Gleam powerups are stats-only with NO tags** — `PowerupDef`'s validator already allows exactly
  that, so the jackpot tier never grows `KNOWN_FAMILIES` or fakes a Resonance.
- The 2-step refinement cap, no-armor and no-durability calls are ITEMS.md §2 rules with
  reopen conditions in §10 — read before adding an item family.
- Asset queue grew A-043–A-047 (gatherables II, component pickups, creature drops, throwables +
  held lights, Gleam uniques + gilded/sunken chests), all gated; A-010 stays `NEXT`, A-011/A-012
  unchanged as the first content wave's art.

**Update, same day (`9caef22`):** the first authorable slice is SHIPPED at Sequoyah's direct
request (a recorded D-006 override — see the 3.2 journal note): items `branch` / `flint` / `coal` /
`fibre_bundle` / `berry` / `mushroom` / `raw_meat` (the last three CONSUMABLE with hunger values
3.8 will consume), plus 11 recipes — every existing tool/weapon is now craftable, charcoal (3 log →
2 coal) is the furnace's second timed recipe, and recipe costs are untuned guesses scaled off
stone_axe. Boot: **23 items, 13 recipes**. Iron gear sits at the `workbench` until an anvil
StationDef exists (one field per recipe to move). `tools/crafting_check.gd`'s exact-census asserts
became floor+membership+determinism, so authoring more recipes can't red it. F-116's convergence
holds: bushes/saplings yield `branch`. Next authorable wave needs A-011/A-012 art (icons are
mandatory on every ItemDef) or new `render_item_icons.py` SOURCES; Gleam powerups (ITEMS.md §4.9)
are art-free under 3.4 whenever Sequoyah green-lights authoring them.

### 2026-08-18 — F-105: `BuildGhost.update_aim()` takes an optional `delta`, and skips `evaluate()` on an unchanged aim

`systems/building/build_ghost.gd`'s `update_aim(from, direction, builder_position, delta: float =
0.0)` gained a 4th, optional parameter — anything already calling it with 3 args still compiles and
still works, it just doesn't get the timer's proactive re-check (see below). `PlacementValidator.
evaluate()` (5 raycasts + a shape cast) now only runs when the snapped placement or the builder
position actually changed since the last call, or `REEVALUATE_INTERVAL_S` (0.2s) has elapsed —
whichever a caller cares about should pass a real `delta` (`player_controller.gd`'s
`_tick_build_ghost()` does). **`set_piece()` invalidates the cache** — a same-spot swap to a
different piece must re-evaluate, since the def (size/mass/rules) is part of what `evaluate()`
answers, not just the transform. `evaluate_count()` is a new getter (backed by `_evaluate_count`)
that exists purely so a check can assert the skip is actually happening; not gameplay-facing.

`entities/player/player_controller.gd`'s `_apply_horizontal_movement()`, `_try_jump()` and
`_tick_build_ghost()` all gained parameters too — `_physics_process()` now resolves
`gameplay_input_allowed()`/`_is_downed()`/`_is_dead()` exactly once per tick and threads them through
as `(input_allowed: bool, downed: bool, dead: bool)`, in that order, rather than each function
re-deriving its own copy. **Any direct `.call()` into these from a check bypasses `_physics_process()`
and must now pass all three** — `tools/player_vitals_check.gd` is the existing example
(`player.call(&"_try_jump", true, false, false)` for a standing, alive, unblocked player).
`_health_node()` now caches the resolved `/root/PlayerHealth` node in a `_health` member var instead
of re-walking `/root` every call.

Full reasoning, the exact per-item fix, and everything verified: `docs/SPECS.md`'s F-105 block.

### 2026-08-18 — a map now gets a group-name-mismatch check for free (F-076/D-062): `tools/world_contract_check.gd`

Hollowmere shipped as the main scene while `EnemyWorld`/`HarvestWorld` still recognized only Playtest
Hollow's group names — zero enemies, 77 dead trees, and nothing errored, because a group matching no
node reads identically to a level that genuinely has none of that thing. `tools/hollowmere_check.gd`
caught it for that one map by hand; this is the version a THIRD map needs no new code to get.

**Run it with `agent godot --script tools/world_contract_check.gd`.** It reads `main_scene` from
`project.godot`, so — like `environment_vfx_hollowmere_check.gd` (F-097) — it always follows whatever
map is actually shipped rather than one hardcoded scene path.

**The API it's built on, for anything that needs the same "does the map actually have X" shape:**

- **`EnemyWorld.expected_nest_count(layout: Dictionary) -> int`** and
  **`HarvestWorld.expected_harvestable_count(layout: Dictionary) -> int`** are pure functions that
  read a map's raw layout JSON directly (`markers[].kind`, `props[].harvestable`) — **never** through
  a Godot group. That's what makes the comparison catch anything: the group-name blind spot that can
  break `ambient_spawn_points()`/`wired_harvestables()` cannot also hide the number they're being
  checked against, because that number never went through a group.
- **`EnemyWorld.CANONICAL_NEST_KIND = &"enemy_nest"`** (D-062) is the one marker `kind` a NEW map's
  generator should publish for its nests. `NEST_SOURCES` still separately recognizes Playtest
  Hollow's legacy `enemy_spawn` for the map that still exists, but `expected_nest_count()`
  deliberately measures against the canonical spelling only — a check reading through the same
  synonym list it's meant to audit proves nothing.
- **Where the layout comes from:** a scene's `World` node exporting `layout_path` — the same
  convention `Undergrowth` already reads generically (`docs/DELEGATION.md`'s Hollowmere section
  below). A map not built that way has nothing to compare against; the layout-shaped checks are
  skipped, not failed, so this never blocks a genuinely different kind of world generator.

**Not covered — filed as F-112:** `world/gen/undergrowth.gd`'s "don't grow on top of a prop" rule,
the third system the original F-076 named. It has no equivalent ground-truth field sitting in a
layout the way markers/`harvestable` props do — "which collider is solid" is a fact about which node
the generator tagged, not something the JSON states directly — so generalizing it needs `Undergrowth`
to expose something like `sample_ground_gaps()` first. `tools/hollowmere_check.gd`'s
`_check_undergrowth_stays_off_props` is still the only check for it, and it is Hollowmere-specific.

### 2026-08-18 — a named collision-layer convention exists now (F-075/D-061): layer 2 is terrain, and ONLY terrain

Ground and everything else used to share collision layer 1, which is why `PlacementValidator`'s
overlap query could not tell "the ground I'm resting on" from "an obstruction" and had to work around
it with a self-tuning clearance lift. That workaround is gone. The convention, and what it means for
the next system that touches colliders:

- **`PlacementValidator.TERRAIN_LAYER: int = 2`** (`systems/building/placement_validator.gd`) is the
  one source of truth — preload the file for the constant rather than hardcoding `2` anywhere.
  `project.godot`'s `[layer_names]` names both layers for the editor:
  `3d_physics/layer_1="solid"`, `3d_physics/layer_2="terrain"`.
- **Layer 1 (`solid`) is still the default for everything that is not ground** — props, harvestables,
  placed buildable pieces, players, enemies. Nothing about them changed; a `StaticBody3D`/
  `CharacterBody3D` you create today with no explicit `collision_layer` is still on layer 1, same as
  before this task.
- **Layer 2 (`terrain`) belongs to world generators, and only to the one `StaticBody3D` per map that
  carries the ground.** `world/gen/authored_world.gd`'s `TerrainCollision` body is the only thing on
  it today. A future world generator (4.x chunk streaming is the named pairing in the original
  finding) must do the same: `body.collision_layer = PlacementValidator.TERRAIN_LAYER` on its ground
  body, nothing else moved.
- **Anything that queries physics with a narrowed mask has to decide, explicitly, whether it wants
  terrain.** `PlacementValidator._probe_support()` ORs `TERRAIN_LAYER` into whatever mask the caller
  passes, so support/ground-finding works regardless of the caller's own mask; `_overlaps()`
  deliberately does not, so a piece resting on the ground never reads the ground as the obstruction.
  `build_ghost.gd`'s own aim ray needed the same OR by hand — it is a second, independent query
  outside `PlacementValidator`, finding *where* the player is pointing before `evaluate()` ever runs.
- **Anything that MOVES on terrain needs `TERRAIN_LAYER` in its `collision_mask`, or it falls through
  the ground the instant that ground leaves layer 1.** `CharacterBody3D`'s engine default
  (`collision_mask = 1`) is exactly wrong for this. Both existing movers were fixed:
  `entities/player/player.tscn`'s `Player` node and `systems/enemies/enemy.gd`'s `_build_body()`
  both now set `collision_mask = 3` (`1 | TERRAIN_LAYER`). **Any new `CharacterBody3D` or
  `RigidBody3D` that stands on the ground needs the same** — either `3`, or leave the mask at the
  engine's true default (all layers) and never narrow it to a bare `1`.
- **Not migrated, on purpose:** `world/gen/playtest_hollow.gd` (deprecated, superseded by Hollowmere)
  keeps its terrain on layer 1. Confirmed via grep to have no `PlacementValidator` caller anywhere,
  so nothing regresses; migrate it only if that map is ever un-deprecated rather than retired.
- **Nav baking is unaffected** — `EnemyWorld.bake_navigation()` never set
  `NavigationMesh.geometry_collision_mask`, whose engine default is all layers, so it already parsed
  terrain regardless of which layer it sat on. Same is true of `harvest_world.gd`'s and
  `undergrowth.gd`'s ray queries — neither sets an explicit `collision_mask`, so both already see
  every layer and needed no change.

Verify with `agent godot --script tools/build_check.gd` (the layer split lives in its own fixtures
now — read the file's header before adding a new one) and `tools/hollowmere_check.gd`.

### 2026-08-18 — the extraction ship exists (A-009), and it introduces the "ship frame" placement pattern

Fifteen exports in `assets/ships/exports/`, catalogued in `assets/ships/catalog.json`, built by
`tools/blender/build_extraction_ship_set.py`, verified by
`.agent/bin/agent godot --script tools/ship_check.gd` (green: 15 imported, 10,456 triangles,
state drift 0.0000 mm, assembly asserted). `assets/ships/README.md` is the full contract.

**The one thing to know before you place any of it.** Eleven of the fifteen are **not**
ground-centred. The mast, both sails, the rudder, the boarding ramp and the cargo hatch are authored
in the hull's own coordinate frame and exported with the hull's origin, so the whole ship assembles
with no offsets to discover:

```gdscript
for part in ["ship_hull_repaired", "ship_mast", "ship_sail_raised",
             "ship_rudder", "ship_boarding_ramp", "ship_cargo_hatch"]:
    add_child(load("res://assets/ships/exports/%s.glb" % part).instantiate())
```

Only `ship_anchor`, `ship_donation_crate`, `ship_departure_bell` and `ship_debris_cluster` use the
usual ground-centred origin and are placed independently. **A ship-framed export legitimately sits
above the ground plane** — the raised sail's lowest vertex is 1.8 m up, because that is where a sail
is — so do not "fix" it, and do not run a blanket ground-contact assertion over this family.
`ship_check.gd` already enforces the right rule per family.

**Dimension checks must measure vertices, never `transform * get_aabb()` (F-108, ported to
`flora_check.gd` by F-122).** An AABB is axis-aligned in a mesh's own local space, so any non-box
mesh's box corners are not real geometry, and rotating that box inflates it — every
`cone`/`tapered_between` primitive is affected. `ship_check.gd`'s `_check_asset()` is the worked
example: walk `Mesh.ARRAY_VERTEX`, transform each vertex to the scene root via `_transform_to_root()`,
bound the points directly. `tools/dimension_check.gd` is a synthetic-cone regression guard for the
technique itself (`agent godot --script tools/dimension_check.gd`), independent of which check
consumes it — it already covers a future regression in either `ship_check.gd`'s or
`flora_check.gd`'s copy. Copy its shape (or `flora_check.gd`'s own `_transform_to_root()`) when
porting the technique into a third check.

Numbers a gameplay task will want, all in the ship frame (Godot axes): **+X is the bow**, z=0 is the
ground under the cradle, the **deck is at y = 1.78**, the bulwark rail tops out 0.85 m above it, the
mast steps at **x = +1.15**, and the **gangway and boarding ramp are on the +Z (port) side**, 1.73 m
wide between framed posts. The hull is 10.4 m long, 3.4 m in beam, 3.8 m to the stem head.

**Repair states.** `ship_hull_wrecked` → `ship_hull_repair_1` → `ship_hull_repair_2` →
`ship_hull_repaired` swap in place; drift is 0.0000 mm, so collision authored against one fits all
four. Pair `ship_mast_broken` with the first two, `ship_mast` + `ship_sail_furled` from the third,
`ship_sail_raised` when she is ready to leave.

**What is deliberately absent:** collision, interaction volumes, and any repair-progress authority.
The extraction system owns which state is shown and when. The donation crate, the departure bell and
the boarding ramp are the three that will want interaction volumes first.

**If you build another sheet-based family** (anything made of open surfaces rather than closed
solids), copy the generator's `WINDING_LOG` proof — the all-sides audit's inside-out metric cannot
judge open sheets (F-109) and will both false-positive and miss real inversions. And measure
vertices, never `Transform3D * AABB`, on the engine side (F-108).


### 2026-08-18 — environmental VFX is asset-bound now (F-097, D-060). This is the seam every world generator inherits

**The rule, from Sequoyah:** animation and VFX bind to the **asset**, never to a scene or a map,
because release worlds are procedurally generated. D-060 records it; F-097 is what it cost to learn.

**What was actually wrong.** `EnvironmentVfx` was never registered as an autoload — the script had
existed since 2.1g and nothing loaded it. On top of that it discovered work by walking for
`MeshInstance3D` nodes with "grass" in the name, while both generators emit `MultiMeshInstance3D`
batches: 1,740 of them holding 13,026 copies, none of them matched. Hollowmere had no wind and no
firelight at all, and its check was green because it booted the map 2.1k deprecated.

**The contract, in one paragraph.** A generator stamps `asset` meta (the bare export name —
`grass_tuft_a`, `station_campfire`) on every node it emits. For assets whose presentation is
per-copy it also stamps `placements`, a `PackedVector3Array` of where each copy stands in that
node's space. `EnvironmentVfx` reads those two metas and **nothing else about the scene**. Stamp
them and every effect below works on a generated world with no further wiring.

```gdscript
holder.set_meta(&"asset", asset)                       # always
if AssetVfx.emitter_for(asset) != AssetVfx.Emitter.NONE:
    holder.set_meta(&"placements", origins)            # only when presentation is per-copy
```

**Why `placements` and not the batch's own transforms:** MultiMesh instance transforms live in the
RenderingServer and are **write-only under `--headless`** — the buffer is empty and every read is
identity (F-103, guarded by `tools/multimesh_readback_check.gd`). Reading them back put all 269 of
Hollowmere's emitters on the world origin *and passed the check*.

**Files and what each owns:**

| File | Owns |
|---|---|
| `world/environment/asset_vfx_library.gd` | Asset id -> `Sway` + `Emitter` class, and the tuning numbers. Pure classification; knows nothing about scenes. Add an asset family by adding one prefix rule. |
| `autoload/environment_vfx.gd` | Discovery, material swapping, the pooled emitter budget. Registered autoload (27 now). |
| `world/environment/foliage_wind.gdshader` | The sway itself, driven entirely by uniforms from the library. |

**Two properties worth not breaking.** Sway materials are applied to the **mesh resource**, once per
asset — so wind on 13,026 instanced plants costs one material swap, not 13,026. Emitters are served
by a **fixed pool** ranked by camera distance every 0.25 s: Hollowmere's **269 emitter sites cost 23
effect nodes**, and a generated world with ten times as many crystals costs the same. Budgets live in
`EMITTER_PROFILES.max_live` / `shadow_live` and are scaled by the `GraphicsQuality` preset
(low 0.4 / medium 0.7 / high 1.0), read through `/root/GraphicsQuality` — that file is **not**
modified here, so F-098's work on it does not conflict.

**For F-098 specifically (static chunk batching):** merging instances into one static mesh destroys
per-instance `MODEL_MATRIX`, which is where sway phase comes from. The shader already has the escape
hatch — `vertex_phase = 1` takes phase from world-space vertex position instead, and every small
asset (grass, reeds, ferns, flowers) is already set that way, so batching them keeps a per-plant
ripple. Trees are `vertex_phase = 0` and **cannot** be batched without their crowns shearing; batch
them only if you bake a per-instance phase into a vertex attribute.

**Verify with:** `agent godot --script tools/environment_vfx_hollowmere_check.gd` (reads `main_scene`
from `project.godot`, so it follows the shipped map), plus `tools/environment_vfx_check.gd` for the
hand-authored fallback path and `tools/multimesh_readback_check.gd` for the F-103 assumption.

**Untuned on purpose:** headless cannot screenshot (F-077), so the numbers prove the effects reach
the geometry, not that they look right. Sway rates, light colours and budgets are all inspector-free
constants in `SWAY_PROFILES` / `EMITTER_PROFILES` for Sequoyah to judge.

---


### 2026-08-18 — cheap read seams from the F-099 optimization sweep

Three accessors exist so per-frame code stops copying whole structures; use them in anything that
polls:

- **`InventoryService.local_slot(index) -> Dictionary`** — one confirmed local slot, copied. And
  **`local_item_id(index) -> StringName`** — allocation-light; answers `&""` for an out-of-range,
  empty, **or exhausted** (amount ≤ 0) slot, which is the answer held-item/consumable logic wants.
  `local_slots()` still exists for callers that genuinely need the whole array — but the array
  carried by `local_inventory_changed` is now the service's own snapshot: **read-only, duplicate it
  if you keep it past the handler.**
- **`NetTransport.has_peer(peer_id) -> bool`** — membership without the whole-array copy
  `peer_ids()` makes. Every F-059 `_peer_connected` guard now calls this.
- **`PlayerHealth.host_health_changed`** now declares its 5th arg (`revision`) — it was emitted all
  along, so 4-arg subscribers would have errored; there were none in-repo.
- **Downed flags travel only on change** (`PlayerHealth._broadcast_downed_flag` dedups). Late
  joiners get a one-shot flag sync in `_on_peer_joined`; run-player expiry broadcasts the flag
  clear (the ghost-"TEAMMATE DOWN" analogue of F-089). If you add a flag-shaped broadcast, copy
  this shape.

### 2026-08-18 — pixel-exact PNG comparison, without the alpha_only trap (F-079)

**`tools/png_pixels_equal.py`** — `pixel_diff_bbox(path_a, path_b) -> (l, t, r, b) | None` and
`images_pixel_equal(path_a, path_b) -> bool`, plus a CLI (`python3 tools/png_pixels_equal.py a.png
b.png`). Any batch that reruns a Blender generator and has to decide "did the pixels actually
change" should call this rather than reaching for `ImageChops.difference(a, b).getbbox()` directly —
that one-liner silently reports every RGB-only change as identical on an opaque RGBA image (Pillow's
`Image.getbbox()` defaults `alpha_only=True`, and a same-opacity diff image's alpha channel is all
zero). `pixel_diff_bbox` diffs each `Image.split()` band separately instead, so there's no combined
alpha channel for the default to key off. Verified: `python3 tools/png_pixels_equal_check.py` (pure
Python, no Godot — full detail in `docs/FINDINGS.md` F-079 and `docs/SPECS.md` F-079).

### 2026-08-18 — the harness has a test suite now, and `.agent/bin/` ships under a claim (F-081)

`python3 tools/harness_check.py` is the first automated check of `.agent/bin/agent`. It builds a
throwaway git repo, copies a real `agent` into it and drives real `ship`/`check` runs, so it needs no
Godot and takes about a second. **Run it after any harness edit**, and add a case to it rather than
testing a staging rule by hand; `--rev <sha>` runs the same cases against a past revision, which is
how a harness regression gets bisected. The behaviour it locks in: `ship` no longer stages everything
under `.agent/` — it stages the allowlist `COORDINATION_PATHS` (`BOARD.md`, `JOURNAL.md`,
`state.json`) and treats `.agent/bin/` as ordinary source. **If your task edits the harness, claim
the file before `agent done`,** or ship leaves the edit in the working tree; it now names any harness
file it declined to carry, in the "left alone" block.

`agent baseline` (F-080) is the other half: it answers "did this already fail before my change?"
without `git stash`, which is repo-wide and takes every other lane's uncommitted files with it.
`agent baseline --script tools/foo_check.gd` runs that check at HEAD in a throwaway worktree —
`--rev` for another commit, a non-`-` first argument for any other command, `--keep` to leave the
checkout behind. It grafts in everything gitignored that a checkout cannot run without —
`addons/godotsteam`, the `.godot` caches, and all 547 `*.import` sidecars — so the round trip is
about six seconds with a real engine run inside it. **Never `git stash` in this repo.**

**Render checks work now: `agent godot --windowed --script tools/x_render_check.gd` (F-077).**
Headless has no framebuffer, so every check that saves a PNG could only ever print `capture
skipped`; `--windowed` drops the injected `--headless`, keeps the lock, and parks a 64x64 window
offscreen — a `SubViewport` still renders at its full size, so nothing about the capture changes.
`agent baseline` takes it too. If you are writing a check whose output is meant for eyes, this is
how it gets run, and `tools/viewmodel_check.gd` is the pattern to copy: detect
`DisplayServer.get_name() == "headless"` and skip loudly rather than reading a dead texture (F-046).

### 2026-08-18 — performance base (F-090): the probe, the presets, and the scatter pattern the generator must inherit

**`tools/perf_probe.gd`** is the instrument: `.agent/bin/agent godot --display-driver macos --script
tools/perf_probe.gd` runs the real level fullscreen for ~50 s and prints fps / median / p95 /
draws / prims per suspect toggle plus the `gfx` presets (the trailing `--display-driver` wins over
the wrapper's `--headless`; the lock still holds; Metal's GPU timer reads 0 in this build so judge
by frame deltas). Baseline history lives in F-090.

**`GraphicsQuality` autoload (D-055)** — `apply(Preset)` / console `gfx low|medium|high`; `high`
restores per-node captured authored values, so levels need no registration. It re-applies itself on
scene change while a non-default preset is active. `undergrowth_density_scale` is read by
`world/gen/undergrowth.gd` at scatter; `Undergrowth.rescatter()` rebuilds mid-level
(deterministic — lower budgets are a prefix of the same RNG sequence). Console also has `vsync
[on|off]` and `fps_cap [n]` (DevFrameCap). 7.5's settings menu should call
`GraphicsQuality.apply()` and grow UI from there.

**Dynamic resolution (F-098):** `GraphicsQuality.set_dynamic_scale(enabled, target_fps)` /
console `gfx auto [<fps>|off]` (0 = panel refresh). Steps the 3D scale between 0.59 and the
active preset's ceiling, 0.5 s cadence, down fast/up slow, fps-steered. Off by default. The
worst-computer safety net; 7.5's settings menu should expose it as one toggle. Static chunk
batching for authored props is designed and parked in **F-100** (blocked on F-097's claim) —
read it before touching authored-world draw counts.

**World-build time (F-095):** `AUTHORED_WORLD` prints `phase_ms=[...]` — keep it honest when
adding phases. The kit-asset merge is disk-cached at `user://mesh_cache/<kit>_<asset>_<mtime>.res`;
warm loads build the world in ~117 ms (was 9,145 ms). First-ever load still pays ~2.9 s — the
export-time bake is the art pipeline's seam. Repo-wide trap fixed twice there: `get_or_add`
evaluates its default argument eagerly, so never pass an expensive call into it. Two rejected
ideas are recorded in F-095 with numbers (flora part-merge, terrain occluder) — read it before
re-proposing either. The probe's last row measures night+wave; night is currently no dearer than
day.

**The scatter pattern (reference: `world/gen/undergrowth.gd`, for the world generator):** bucket
placements into `CELL_SIZE` (48 m) cells; one MultiMeshInstance3D per (asset, cell) **positioned at
the cell centre including mean ground height** — visibility ranges measure to the node origin, and
an origin at y=0 culls a plateau's plants standing next to the player; short assets (merged AABB
< 0.75 m) get `cast_shadow = OFF` and a 60 m range, tall ones keep shadows and reach 110 m; ranges
get `+CELL_SLACK` and an 8 m `FADE_SELF` margin. Map-wide MultiMeshes are the disease this cures:
one huge AABB defeats all culling and feeds every PSSM cascade (measured 4.1 ms of a 9.3 ms frame).

`StationDef` (`systems/crafting/station_def.gd`: `id`, `display_name`, `world_scene`, `tier`) joins
`RecipeDef` as a registered content family — `content/stations/*.tres`, loaded by
`Registry._load_stations()` into `stations: Dictionary[StringName, Resource]` (untyped, F-016 —
`STATION_DEF` is a brand-new class_name this task, same reasoning as `LOOT_TABLE_DEF`/`POWERUP_DEF`/
`BUILDABLE_DEF` above it). `RecipeDef.station` already existed (default `&"workbench"`) and now
resolves through `Registry.get_station()` instead of a bare string compare — this **is** the "station-
tier check" 3.1's spec asked for: a recipe whose station id doesn't resolve to a registered `StationDef`
is rejected before the range check ever runs. `StationDef.world_scene` is **not** a `PackedScene` —
every crafting station shipped so far is baked map art (`assets/crafting_stations/catalog.json`), not
an instantiated scene, so it's the identifier `CraftingService._station_in_range` matches against a
physical station instance's name (D-051).

**`CraftingService` now finds stations on Hollowmere, not just Playtest Hollow.** The old
`_station_in_range` only ever checked `playtest_hollow_asset`-group nodes — exactly the trap
`world/gen/authored_world.gd:508` already documents for `HarvestWorld` ("only ever looked for
`playtest_hollow_asset` holders that this map never built"). It now also checks
`authored_world_marker` nodes named `"Station_<world_scene>"` (`tools/mapgen/hollowmere_layout.py`'s
`_marker(f"Station_{asset}", "station", ...)` — Hollowmere's station props are baked into a
`MultiMeshInstance3D`, so the marker is the only per-instance position that map exposes). Both group
shapes are checked so every existing offline/net check (built against the legacy group) still passes
unmodified.

**Timed crafts (the furnace worked example, `iron_ore ×2 → iron_ingot`, 2s) needed a field neither
`RecipeDef`'s nor `StationDef`'s spec'd fields had — added `RecipeDef.craft_time_sec: float = 0.0`**
(0 = instant, every pre-3.1 recipe including stone_axe is unaffected). `CraftingService` keeps a
HOST-only `_host_pending_crafts: peer_id -> (request_id -> {data, remaining_sec})`, ticked in
`_process(delta)`; a timed request pre-checks ingredients with `InventoryService.host_can_remove` (so
an already-doomed request rejects immediately instead of occupying a timer slot) but does not remove
them until the timer elapses and `host_transaction` runs — a craft that outlives its own ingredients
(spent elsewhere mid-smelt) is rejected then, same as the instant path already was.

**`CraftingService.craft_progress(request_id) -> float`** (0..1, or -1.0 if not a pending timed craft
this peer itself requested) is a **client-side estimate only** — every peer already has the identical
`RecipeDef` from `Registry`, so `request_craft()` starts the requester's own countdown the moment it
sends the request rather than waiting on a round trip (D-052). This is why 3.1 needed **no new RPC and
no protocol bump**: the wire shape is exactly what 2.6 shipped — a request carries a recipe id and a
local request id, and `craft_confirmed(request_id, accepted, detail)` is still the only completion
signal, timed or not. Proven over real ENet (not just same-process) in
`tools/crafting_net_check.gd` — the host's `_process()` timer completing and RPC-confirming a
genuinely remote peer specifically was previously untested by anything.

**`CraftingUI` no longer hardcodes `&"workbench"`.** `CraftingService.nearby_station_id()` (nearest
registered station the local player is in range of, or `&""`) drives `current_station_id()`; rows
rebuild (`_rebuild_rows`) whenever that identity changes, and the panel title/interact prompt read the
station's `display_name`. `craft_progress()` >= 0 while a request is in flight replaces "Waiting for
the host…" with a live "Crafting… NN%" line.

Checks: `Godot --headless --path . --script tools/crafting_check.gd` (offline, station registration +
tier-rejection + full timed-craft lifecycle), `tools/crafting_ui_check.gd` (station-switch + progress
readout), `agent godot --script tools/crafting_net_check.gd` (real two-process proof, both the
original stone_axe flow and the new remote furnace one). `tools/setup_station_content.gd` is the
deterministic authoring script for the two `StationDef`s plus the `iron_ingot` item/recipe — same
re-run caveat as `setup_crafting_content.gd`: it overwrites those four files, so don't re-run once
their values are being tuned in the inspector. 3.2 authors the rest of the tree against this schema.

### 2026-08-17 — first-person grips, per-weapon attack arcs, and how to get a real in-game screenshot (F-073)

**`agent godot` CAN render. This is the important one, and it answers F-077.** `cmd_godot` builds
`[binary, "--headless", "--path", ROOT] + your_args`, so an appended flag overrides an injected one:

```bash
.agent/bin/agent godot --display-driver macos --resolution 64x64 --position 2400,1400 \
  --script tools/viewmodel_check.gd
```

That keeps the import-cache lock (F-044) and still produces real 1280×720 frames of the running game
— `tools/viewmodel_check.gd` writes `/tmp/mire_viewmodel_{idle,windup,commit,recovery}.png`.
`--resolution 64x64 --position 2400,1400` shrinks the OS window and parks it offscreen; a
`SubViewport` renders at its own size regardless. Two cautions: it opens a real window, so use it for
a deliberate render run and not for every check; and a script that errors inside `_initialize()`
before its `call_deferred` hangs with no main loop to quit it, so keep `--quit-after` or a kill guard.
Every `tools/*_render_check.gd` in the repo becomes usable this way without any change to `agent`.

**`ItemDef` gained `attack_style`** (`enum AttackStyle { NONE, CHOP, SMASH, SLASH, THRUST }`,
`systems/inventory/item_def.gd`). It is presentation only — reach, arc width and damage stay on
`WeaponDef`, which is what the host reads. It is on `ItemDef` and not `WeaponDef` because `short_bow`,
`arrow` and the code-built `unarmed` fallback have no `WeaponDef` to carry it (D-050). A new tool or
weapon **must set it**; unset means CHOP, which is right for an axe and wrong for a spear.

**`entities/player/viewmodel.gd` is now table-driven.** `STYLE_POSES` holds one entry per style —
`cock` / `hit` / `follow` / `arc` — and `_apply_pose` reads the cached `_attack_style`. Adding a style
is one array entry plus one enum value; changing how a family swings is four vectors. Three
invariants that are not obvious and cost real time to rediscover:

- **The hit resolves at the WIND_UP→COMMIT boundary** (`combat_service.gd:197`,
  `elapsed >= wind_up_seconds`), not inside COMMIT. An arc must reach its contact pose at the *end of
  the wind-up* or the visible strike lands a phase after the damage.
- **A positive X rotation RAISES the weapon.** The node sits above `SWING_PIVOT`. The file used to
  claim the opposite and the old constants were signed accordingly.
- **The swing turns about `SWING_PIVOT`, not this node's origin**, via `position = pivot − R·pivot`.
  Rotating about the node origin orbits the weapon around the camera, so 30° of pitch throws a tool
  off the screen.

`PlayerViewmodel.current_attack_style()`, `swing_pose(style, phase, progress)` and
`swing_transform(position, rotation_degrees)` are all public so a check can drive any style's whole
arc **without that weapon being in the hotbar**. That is not a nicety: the dev loadout grants six of
the eleven holdable items, so assertions written against "whatever is selected" never exercise SLASH
and silently pass with an empty failure list. Walk `Registry.items` instead.

**Two generators author `content/items/stone_axe.tres`** — `setup_tool_content.gd` (the solved grips)
and `setup_crafting_content.gd` (the recipe). The second now *reads* `GRIPS` from the first instead of
repeating the numbers. If you add a third writer of any item, do the same; a second copy of these
values is a revert with a delay on it.

**Grips are solved, not nudged.** All eleven are in `tools/setup_tool_content.gd`'s `GRIPS`, so
regenerating content reproduces them. Every A-004 head runs bit-to-poll along local **+X** with the
flat cheeks on local **±Z**, and the origin is at ground level with the grip some way up the haft —
those three facts are what the solve needs. If a design's mesh is rebuilt, re-solve; hand-editing one
number here is what D-050 exists to prevent.

**`tools/viewmodel_check.gd` now asserts orientation and dispatch**, 18 assertions, and all of them
hold under a plain `--headless` run. The load-bearing one is `|cheek · view| <= 0.80` per bladed item:
the grip it replaced measured 0.92 on all seven, the solved grips measure 0.45–0.67. Extend this
check rather than writing a new harness.

**`tools/blender/render_item_icons.py` gained `ROLL_OVERRIDE_DEG`** for icons whose measured framing
picks the wrong roll. A rebuild rewrites all 25 PNGs plus the catalog and the contact sheet, but only
the genuinely changed ones should be committed — compare **per channel**, because
`ImageChops.difference(a, b).getbbox()` on RGBA defaults to `alpha_only=True` and calls every
RGB-only change identical (F-079).

---


### Hollowmere is the map now (2026-08-17, re-authored 2026-08-18 by 2.1k)

`res://levels/hollowmere.tscn` is `project.godot`'s main scene. It is **192 m across against Playtest
Hollow's 88 m** — it was 356 m and that was too big (D-045) — and it is built differently on purpose.

| | Playtest Hollow | Hollowmere |
|---|---|---|
| Source of truth | `tools/mapgen/hollow_layout.py` → JSON | `tools/mapgen/hollowmere_layout.py` → JSON |
| Visuals | baked in Blender to `assets/maps/*.glb` | built at load by `world/gen/authored_world.gd` |
| Collision | `world/gen/playtest_hollow.gd`, a **second** consumer | the same script, same loop |
| Props | placed as scene nodes | `MultiMeshInstance3D` per (chunk, asset) |

The Hollow's two-consumers-one-file rule exists to stop visuals and collision drifting apart.
Hollowmere has **one** consumer, so they cannot drift even in principle. Baking was also simply the
wrong call at this size: one mesh 356 m across cannot be culled.

**The seams, for whatever builds on this next:**

- `AuthoredWorld.height_at(x, z) -> float` — the authored ground height anywhere, without a raycast.
  Use it for placement; use a ray when you need to know what is actually *on* the ground.
- Groups: `authored_world_prop` (a prop's `StaticBody3D`, carrying `asset`/`kit` metadata),
  `authored_world_marker`, `authored_world_terrain`.
- Markers carry `kind` metadata and the map ships: `spawn` ×1, `extraction` ×1, `objective` ×1
  (the Wellspring), `enemy_nest` ×4, `landmark` ×9, `station` ×8, `loot` ×8, `bridge` ×2.
  **`enemy_nest` is now consumed**: `EnemyWorld.ambient_spawn_points()` reads
  `authored_world_marker` / kind `enemy_nest` as well as the Hollow's group, so the four nests in the
  Blight are where every crawler on this map comes from. `extraction` and `objective` are still
  unconsumed and remain host-authoritative work for whoever wires them.
- **Harvestables are live, and they are individual nodes** (D-049). A layout prop carrying
  `"harvestable": true` is built as a holder in group `authored_world_harvestable` with `asset`/`kit`
  metadata, a `Visual` child and a `CollisionBody` child — the shape `HarvestWorld._wire_holder`
  needs. `HarvestWorld.HOLDER_GROUPS` now lists both maps' groups and finds the visual either by a
  `Visual` child (Hollowmere) or by the `AuthoredVisuals` index (the Hollow). 83 wired on this map.
- **`yaw_along(dx, dz) = atan2(-dz, dx)`** is the only way the generator turns a direction into a
  yaw, with `tangent_yaw`/`radial_yaw` on top for rings (D-046). Get this wrong and every directional
  prop mirrors; the symptom that finally exposed it was bridge railings crossing their own decks.
- **Water is one unioned surface per material**, highest level wins per grid vertex, clipped to the
  ground and emitted wherever *any* corner of a quad is submerged. Bodies may be `circle`, `rect` or
  `polyline` (the river is one polyline body, not one strip per segment). Overlapping bodies can no
  longer draw two stacked sheets, and the shoreline no longer staircases.
- **Zones tile the map** by `distance - pull` (D-048). The layout's `zones` array carries `pull`, and
  `undergrowth.gd` reads it, so flora and props on a patch of ground always come from the same zone.
- `Undergrowth` (`world/gen/undergrowth.gd`) is map-agnostic: point `layout_path` at any layout with
  `zones`, `props`, `roads`, `heightfield` and `bound`, set `prop_group`, and it scatters the flora
  kit by zone. It is client-local and deterministic from the layout seed, so peers agree without
  replication. It owns every family named in its `ZONE_PALETTES` and the layout owns everything else
  (D-047). Three of its rules were silently inert on this map until 2.1k: the prop test looked at the
  collider's parent instead of the collider (grass grew on top of trees and rocks), the road test read
  a schema this map does not write (bushes grew down the middle of every road), and the probe ray ran
  between fixed world heights of 24 m and −12 m, so nothing above 24 m grew anything at all.
- **Neither node has network authority and neither may gain any.** They are presentation. Anything
  that needs to change during a run — a broken bridge, a flooded zone — is host state.

Measured 2026-08-18 by `agent godot --script tools/hollowmere_check.gd`: terrain 18,432 triangles in
one mesh, **2,869 authored props** through 1,028 multimeshes, 501 colliders, 83 live harvestables,
**10,240 scattered plants** through 78 multimeshes, 2 water surfaces, 9,486 navmesh polygons. Ground
probes at 647 points found no holes and collision **0.000 m** from the authored height — the generator
and `AuthoredWorld.height_at` now sample the same two triangles per cell rather than a bilinear
approximation of them, which is what makes "nothing floats" hold to the centimetre. 672 sampled props
float 0.00 m; 3,441 sampled plants sit on props 0 times; water samples stacked 0 times.

**To look at the map without the editor:** `python3 tools/mapgen/hollowmere_plan.py [out.svg]` draws
the layout as a labelled plan view — terrain, water, roads, every prop coloured by family, landmarks
named — and writes an SVG and a PNG. Pure stdlib. `tools/hollowmere_render_check.gd` still takes the
in-engine screenshots and still cannot, because `agent godot` is always headless (F-077).

**Playtest Hollow is deprecated, not deleted.** Nine headless checks still boot it, it is what every
existing system was tuned against, and it loads in a second — which makes it the right fixture for a
test long after it is the wrong thing to ship. Do not build new content against it; do not delete it
until those checks have somewhere else to run. `world/gen/playtest_hollow.gd` says so at the top.

**Not yet recorded as a decision.** `docs/DECISIONS.md` had uncommitted edits from another session
while this landed, so the D-number for "large maps are built at runtime, small ones are baked" still
needs writing by whoever owns that file next.


> Execution specs for every remaining roadmap task live in **`docs/SPECS.md`** — this section holds
> the *shipped* seams those specs build on.

### 2026-08-18 — a source-text regression guard for two `tools/*_net_check.gd` authoring traps (F-060)

`agent godot --script tools/net_check_pattern_check.gd` now runs alongside every other check suite and
fails if a new (or copied-from-old) `tools/*_check.gd`/`tools/*_net_check.gd` reintroduces either shape
F-060 named: a client ready-gate built from `local_peer_id() > HOST_PEER_ID` with no `is_active()`
check nearby (can read true while the connection is still CONNECTING), or a strictly-typed `Dictionary`
property mutated straight off a `some_autoload.get("prop")` reflection read with no `.set()`-back
(silently does not reach the original). It is a source scan, not a runtime one, on purpose — same
reasoning as `tools/interp_coverage_check.gd` (D-043): both bugs manifest as code that silently does
nothing, so there is nothing at runtime for a check to catch it failing against. Nobody needs to run it
by hand when writing a new net check — it walks the whole `tools/` tree itself.

### 2026-08-18 — `_peer_connected(peer_id)` is now a two-file pattern, and there's a gap it exposed (F-059/F-074)

`autoload/inventory_service.gd` gained the same `_peer_connected(peer_id)` guard
`systems/health/player_health.gd` already had: `_transport().call("peer_ids").has(peer_id)`, checked
before every `rpc_id(peer_id, ...)` send to a specific peer. **Any new host-owned per-peer system with
its own `rpc_id` sends should copy this from either file rather than reinvent it** — it's the standard
answer to D-035's grace window (a departed peer's state survives `peer_left` on purpose, so a peer id
can sit in a host dictionary with no live connection behind it).

**The gap the fix exposed, closed as F-074:** `InventoryService._valid_host_peer(peer_id)` used to
require `peer_id` to be a *currently connected* peer, so `host_add`/`host_remove`/`host_move_stack`/
`host_transaction` all silently refused to mutate a parked (mid-grace-window) peer's store — a grant
that landed for someone between a drop and a reconnect was lost, not queued. Fixed to match
`player_health.gd`'s `host_apply_damage` shape: **a live `_host_stores` entry is now valid regardless
of current connectivity** — `_valid_host_peer` returns true immediately if `_host_stores.has(peer_id)`,
before it ever asks the transport. A peer with no store yet still needs a live transport connection
(or, offline, must be the host) before one is created for it, so an unseen/spoofed peer id is still
rejected. Publishes immediately rather than waiting for rebind — safe because `_publish_snapshot`'s
`rpc_id` send is already gated on `_peer_connected` (F-059), so a parked peer's snapshot just updates
its host-side store, never an RPC to a peer id the transport doesn't recognise. Any new host-owned
per-peer system with its own mutation gate should copy this shape too: check the state dict, not the
transport, and let `_peer_connected` guard only the outbound `rpc_id` send.

### 2026-08-18 — the building system is in (3.6). This is what 3.7 authors against

`BuildService` is autoload #25, HOST-authoritative (§2.2 world mutation). Protocol is **12**. Three
files: `systems/building/buildable_def.gd`, `placement_validator.gd`, `build_ghost.gd`.

**The load-bearing idea is one validator, two callers.** The ghost calls
`PlacementValidator.evaluate()` to colour itself green or red; the host calls the *same function*
against its own space state to accept or reject. Sharing the code is not sharing the authority — the
host re-snaps and re-evaluates and believes nothing from the wire but a piece id and a transform,
both re-checked. What sharing buys is that a green ghost and an accepted placement cannot drift
apart through two subtly different rule sets, which is the bug that makes a building system feel
broken rather than strict. **Do not write placement rules anywhere else.**

`snap_transform()` is pure — no world, no builder — so two players snap to the same world-space grid
and their walls line up. `evaluate()` returns a `Reason`, and `reason_text()` gives the words, so the
ghost and a host rejection say the same thing to the player.

**Authoring (task 3.7).** Copy `content/buildables/wall.tres` (a plain piece) or `ward_post.tres` (a
Ward — `ward_radius_m > 0`; the field ships now, **4.11** is the task that makes the Mire respect it).
Fields: `size` is the footprint box in metres with the origin at its FLOOR centre, `snap_step` and
`rotation_step_degrees` drive snapping, `requires_support` / `max_ground_slope_degrees` /
`max_build_range_m` are the placement rules, `cost` is spent through `host_transaction` and
`refund_fraction` comes back on destruction. `scene` may be left null: `BuildService` generates a
box collider and mesh from `size` so a piece without art is still a real, colliding, navmesh-affecting
object — art is 3.7's job, not a blocker for testing gameplay.

**Two orderings inside the system that must not be swapped.** Support/slope is evaluated *before*
overlap, because a piece on a slope steep enough to refuse is also geometrically buried in it, so
overlap-first reports every steep placement as "something is in the way" — true and useless. And cost
is charged *last*, after every geometric rule has passed, because it is the only check with a side
effect: rejecting after a successful `host_transaction` silently eats the materials. If the spawn
then fails, the cost is explicitly refunded.

Navigation is rebaked after any placement or destruction, **debounced to one per second** in
`_physics_process`, never inline — a player dragging out a ten-piece wall would otherwise trigger ten
full-level rebakes (21,364 polygons on Hollowmere). Per-chunk baking is 4.5's problem.

**Verify:** `agent godot --script tools/build_check.gd` (59 assertions offline, against a real physics
world rather than a mock) and `tools/build_net_check.gd` (13, two real ENet processes, including the
assertion that a client running the host's own placement path forges nothing).

**A trap for the next networked harness in this area:** do not hard-code a build spot. `PlayerNet`
fans peers out from the spawn point, so a fixed spot lands on somebody's body and the host correctly
refuses it as OVERLAPS — the cost path is never reached and you measure the wrong refusal.
`build_net_check` derives the spot from the client's actual body position; copy that.

### 2026-08-18 — destruction now actually mirrors placement (F-084)

`_process_destroy` (`autoload/build_service.gd`) checked only `_placed.has(piece_name)` — sequential
node names (`Piece1`, `Piece2`, ...) meant any peer could free and refund any structure from anywhere
by guessing them. It now calls the exact same `_builder_position(peer_id)` placement already trusts
nobody about, and refuses (`VALIDATOR.Reason.OUT_OF_RANGE`, "too far away") before any refund or
`queue_free()` if that body is farther than the piece def's own `max_build_range_m`. **Ownership is
still not checked, on purpose** — "refund goes to whoever tears it down, not to whoever built it" was
already 3.6's design, so any teammate clearing a misplaced piece must keep working; the fix adds only
the range gate 3.6's own "Destruction mirrors it" line always implied. Whoever wires the gameplay
caller (F-086) or gives buildables a real damage method (F-085) should assume destroy is range-gated
identically to placement — there is no separate "destroy range" field, it reads `max_build_range_m`.

**For the next `tools/*_net_check.gd` that needs a piece of world state far from its one real
client:** you don't need a second player body. `service.call(&"_spawn_piece", id, transform)` spawns
a real, replicated piece anywhere (it skips `_process_place`'s validation, which is the point — you
are placing world state to test against, not re-testing placement); giving it a destroy-able identity
means writing to `BuildService._placed` yourself, and F-060 applies: capture `service.get(&"_placed")`
to a `Dictionary` local, mutate that, then `service.set(&"_placed", ...)` it back explicitly, or the
regression guard (`tools/net_check_pattern_check.gd`) has nothing to say about it but the mutation may
not stick anyway. `tools/build_net_check.gd`'s new destroy-range assertions are the worked example.

### 2026-08-18 — support now means ALL five probes, worst slope wins (F-082)

`PlacementValidator._probe_support()` used to skip any of its five footprint probes that missed and
return the flattest hit among whatever survived — `evaluate()` treated that as fully supported, so a
wall balanced on a pillar under its centre, or hanging three-corners-off a cliff, read `Reason.OK`.
**Contract now:** `_probe_support` returns `{}` (the same sentinel `evaluate()` already reads via
`is_empty()`) the instant any one of the five probes misses, and otherwise returns
`{"slope_degrees": <worst of the five>}` — the steepest, not the flattest. No `BuildableDef` field
distinguishes "required" from "optional" probes, so all five are required; a piece meant to bridge a
gap keeps using `requires_support = false`, unchanged. **Whoever authors more buildable content
(3.7) or touches placement rules next should know:** a flat piece run *across* a steep slope's fall
line can no longer be supported at all — its corners are metres apart vertically, well outside any
probe's 0.6 m reach — only a piece run *along* the contour, or one small enough that its whole
footprint sits within reach, can pass `requires_support` on genuinely steep ground. That is a real
behavior change (correct per the finding), not a regression: `tools/build_check.gd`'s own slope test
needed the same reorientation and is the worked example if you need another one — see its comment
in `_build_world()` for the "thin the box or a probe starts inside the solid a few cm off the exact
tuned point" trap when hand-placing tilted test geometry.

### 2026-08-18 — buildable pieces can now actually be attacked (F-085)

Joining `&"damageable"` used to be the whole story for a placed piece; now it also gets a
`host_apply_damage(amount, instigator_peer_id) -> bool` that does something, which is what
`CombatService._best_target()` actually requires via `has_method()` before it will ever pick a node
as a target — before this, every buildable was silently unreachable.

**`systems/building/buildable_piece.gd`** (new, `extends Node3D`, no `class_name` — it is attached
dynamically) is the implementation. `BuildService._net_spawn_piece()` attaches it to a piece root
**only if that root doesn't already have `host_apply_damage`** — today that's every piece (task 3.7's
art carries no scripts yet), but an authored root that brings its own richer damage handling (staged
break states, say) is left untouched rather than overwritten. `hp` is host-only and **deliberately
unreplicated** — nothing shows chip damage yet, and a piece's existence already replicates through
`MultiplayerSpawner`'s despawn the instant the host `queue_free()`s it (D-023), which is the only
state a client needs today. The method mirrors `Harvestable`/`Enemy`'s shape exactly: it re-checks
host authority itself (`_owns_world_mutation()`, same three-line pattern) rather than trusting that
`CombatService` already gated it — "someone else already checked" is how a check quietly disappears
later.

**`BuildableDef` gained `max_hp: int = 25`** (new `@export_group("Combat")`, validated `> 0` like
every other numeric field) — the source `_net_spawn_piece()` reads into a fresh piece's `hp` at spawn.
Existing content (`wall.tres`, `ward_post.tres`) needed no edit; an unauthored export field just takes
the script default, so both worked examples are HP 25 until someone tunes them in the inspector.

**`BuildService.host_piece_destroyed_by_damage(piece_name, instigator_peer_id)`** is the new host-only
entry point `BuildablePiece` calls on lethal damage. It does the same teardown `_process_destroy` does
(erase from `_placed`, `queue_free()`, request a nav rebake, emit `piece_destroyed`) **minus the range
check** (the attacker already had to pass the weapon's own reach/arc test in `CombatService`) **and
minus the refund** (a piece fought and lost pays out nothing — same as `Harvestable`/`Enemy` on
death; only a deliberate `request_destroy` teardown refunds, per the existing 3.6 design that refund
goes to whoever tears a piece down).

Whoever wires 3.7's real art (F-086) should know: dropping a script onto the scene root via
`set_script()` only works because nothing under `content/buildables/*.tres` carries one yet. The first
authored root that wants its own `host_apply_damage` (multi-stage break visuals, say) just needs to
implement the method itself — `_net_spawn_piece()` already detects and defers to it.

Verify: `agent godot --script tools/build_check.gd` (`failures=0`) — new assertions call
`host_apply_damage` directly rather than trusting the `&"damageable"` tag, then a dedicated
`_check_damage_destroys_piece()` places a second piece, kills it with a lethal hit, and confirms
`BuildService` forgets it, the node frees, no refund lands, and a nav rebake queues.
`agent godot --script tools/combat_check.gd` (`failures=0`) confirms combat's own harvestable/enemy
scenarios are unaffected.

### 2026-08-18 — placement Y is no longer snapped to the grid, only X/Z (F-083)

`PlacementValidator.snap_transform()` used to round Y onto the same `snap_step` grid as X and Z. On
Hollowmere's non-integer terrain that either buried a piece in the ground or floated it above the
surface — see F-083 in `docs/FINDINGS.md` Resolved for the exact failure and D-056 for the call.
**Now: `snap_transform()` snaps X/Z only; `origin.y` passes through untouched.** This is a contract
change anything calling `snap_transform()` or reading a placed piece's Y should know:

- The Y a piece ends up at is whatever the caller's own aim ray hit — terrain, a slope, or another
  piece's real top surface. There is no `BuildableDef` field or separate function for "anchor to a
  grid Y"; if a future piece type needs to ignore uneven ground and sit at an exact authored height,
  that is new scope (D-056's "would change my mind" line), not something this fix already covers.
- Flush stacking (a piece placed directly on top of another) needs no special-casing: a raycast
  against an existing piece already reports that piece's exact top, so the new piece's floor lands
  there with zero gap, the same way it lands flush on terrain.
- `content/buildables/wall.tres`'s own doc comment ("Snaps to the metre grid so a run of them
  actually lines up") is still true for X/Z. It is not true for Y across uneven ground — a run of
  walls built along a slope will follow the slope, not share one Y, same as it would in reality.

Verify: `agent godot --script tools/build_check.gd` — `_check_ground_height_is_preserved()` is the
new function, built against two isolated flat pads at non-integer heights (top surfaces y=0.4 and
y=0.6, the review's own `GROUND_0_4`/`GROUND_0_6` probes); `_check_ghost()` gained an end-to-end
case aiming `BuildGhost` straight down at the y=0.4 pad to prove the whole `update_aim() ->
snap_transform()` chain the finding named, not just the pure function. `failures=0`.
`tools/build_net_check.gd` `failures=0`, unaffected.

### 2026-08-18 — the 3.4 design check is done: the schema holds, and docs/POWERUPS.md is now the authoring spec (reed16)

The question that had to be answered before 3.4 hand-authors 40–60 `.tres` files: can the whole
design space live in `tags` + `max_stacks` + `(stat → Vector2)`, or is a field missing that would
force re-authoring everything? **docs/POWERUPS.md is the answer: a 60-powerup sketch spanning all
six families and every archetype (always-on, conditional, on-event, proc, capability, tradeoff,
tag-only feeder) — zero need a new field.** Conditions, triggers and capabilities are stat-name
conventions consumed at the owning system, not schema; D-050 records why that beats fields, and §5
of the doc records what evidence would reopen the question.

**For 3.4:** author against POWERUPS.md §2 (the stat catalog — names, signs, consumers) and §4
(the sketch, as a menu not a shipping list). The vocabulary is now enforced (F-078):
`PowerupDef.KNOWN_STATS`/`KNOWN_FAMILIES` back `validation_errors()`, so a typo'd stat name, a
lowercase `&"fire"` tag, a `Vector2.ZERO` no-op, or a negative multiplier that inverts its stat at
`max_stacks` (D-044 linear stacking crosses zero at `mult·N ≤ −1`) is a named boot error, never
silently dead content. Inventing a stat the catalog lacks = one row in POWERUPS.md §2 + one line in
`KNOWN_STATS`, on purpose. `tools/powerup_check.gd` carries seven F-078 assertions (42 total, 0
failures, clean error-line bar).

**For every system task that wires a stat** (movement, health, combat, stamina, Mire...): the name
your system must route through `PowerupService.stat()` is already settled in POWERUPS.md §2 —
content authored before your task exists depends on you using exactly that name. Condition-suffixed
stats (`melee_damage_low_hp`) chain onto your unconditional pass per the worked snippet in §2.

### 2026-08-18 — the powerup framework is in (3.3). This is what 3.4 and every effect task build on

`PowerupService` is autoload #23, HOST-authoritative (§2.2 "active modifiers"). Protocol is **11**.

**The one seam. Systems ASK the service; it never reaches into systems.**

```gdscript
speed = PowerupService.stat(peer_id, &"move_speed", BASE_SPEED)   # or local_stat() for yourself
```

That direction is the entire point. A powerup that pushed values into `PlayerController` would make
every new powerup a code change in the system it touches — the opposite of §4.4's "mostly data, not
code". **No system needs editing to support a new stat powerup**; it needs editing once, to route its
base value through `stat()`, and then never again. Movement, damage and health are the obvious first
three and none of them are wired yet — that is deliberate, it is each system's own task and a
one-line change when it comes.

**Authoring (task 3.4).** `content/powerups/swift_stride.tres` is the worked example; copy it.
`id`, `display_name`, `icon`, `tags`, `max_stacks`, `modifiers`. `modifiers` maps a stat name to
`Vector2(additive, multiplicative)` **per stack** — `Vector2(0, 0.08)` is +8% per stack,
`Vector2(2, 0)` is +2 flat. D-044 fixes the maths and fixes that **tags ARE the Resonance families**;
there is no separate `resonance_family` field, so do not look for one. `validation_errors()` runs at
boot and a malformed .tres is a named error and a skip, never a crash downstream.

**Resonance is a flag, not an effect.** `resonance_active(peer, &"Fire")` and
`greater_resonance_active(...)` at §4.4's 3+ and 6+. This service does not know what Blood resonance
*means* — the task that ships "kills heal you" asks the flag and implements itself, and the
`resonance_changed(peer_id, family, tier)` signal fires on crossings in both directions so an effect
can switch off as well as on.

**The replication split, which is the part to not accidentally undo.** The owner gets its full
`id -> stacks` map by `rpc_id`; *everyone* gets per-peer per-family **counts** by broadcast. So a
teammate can see you are three-deep in Fire — §4.4 makes that a decision at every chest — and cannot
name one powerup you hold. `tools/powerup_net_check.gd` asserts exactly that over two real ENet
processes, including the negative half, because broadcasting the snapshot by mistake is a change no
offline check can catch.

**D-035 is honoured**: `peer_left` drops nothing, `run_player_rebound` moves the stacks, only
`run_player_expired` deletes them. Losing a run's powerups to a reconnect would be worse than the
inventory bug that motivated D-035, because unlike an inventory they cannot be re-gathered.

**Verify:** `agent godot --script tools/powerup_check.gd` (28 assertions, offline) and
`tools/powerup_net_check.gd` (13, two processes). Writing the second one is what surfaced a real
gap — a mid-run joiner learned nothing until somebody happened to open a chest, because publishing
on mutation is only correct if every peer was present for every mutation. `_on_peer_joined` now
sends the board.

### 2026-08-18 — an obsolete peer id's family counts now actually leave the board (F-089)

D-035's rebound/expiry lifecycle above was correct on the host but incomplete on the wire: neither
`_on_run_player_rebound` nor `_on_run_player_expired` ever told teammates that an old/expired peer id
was gone, so `_family_counts[old_id]` on every client was a ghost that outlived the id forever —
`net_powerup_counts` is a broadcast with no deletion path of its own.

**The fix, if your task touches either lifecycle hook again:** both now end by calling a shared
`_retire_broadcast(peer_id, before)` on the id that is going away, BEFORE that id's `_family_counts`
entry is erased from the host's own state. It emits the downward `resonance_changed(peer_id, family,
Resonance.NONE)` transition for every family `before` was resonant in, then (guarded by
`NetTransport.is_active`, same as `_publish()`) broadcasts `net_powerup_counts.rpc(peer_id, {})` so
every client's entry for that id reads empty. **Call it with the retiring id's OWN `before` snapshot,
not the rebind target's** — `_on_run_player_rebound` still copies `_family_counts[old]` onto
`new_peer_id` first and calls `_retire_broadcast(old_peer_id, ...)` after, so `_commit(new_peer_id)`'s
before/after diff is unchanged and does not re-fire `resonance_changed` for thresholds already crossed
under the old id.

**Verify:** `agent godot --script tools/powerup_review_check.gd` (6 assertions over two real ENet
processes, both lifecycle events, `POWERUP_REVIEW_CHECK failures=0`) plus a clean rerun of
`powerup_check.gd` and `powerup_net_check.gd` for no regression.

### 2026-08-18 — night waves actually run now, and the reason they did not is worth keeping

`WaveSpawner` is registered (autoload #22, after `DayNight`, which its `_ready()` depends on). Dusk
disables `EnemyWorld.ambient_enabled`, spawns `base_count + per_player * live_players` at ambient
spawn points, and dawn clears the field and restores the exact ambient setting found at dusk. All
host-only; `EnemyWorld`'s existing `MultiplayerSpawner` replicates the bodies, so 2.12 added no RPC
and the protocol version is untouched (still 7).

**It shipped correct and did not run for a day, and the harness said it was fine.** `wave_spawner_check`
built its own `WaveSpawner` and its own node named `DayNight`, so it proved the *script* worked and
could say nothing about whether the *project* loaded it — and once 2.11 registered the real DayNight
autoload, the fake was renamed out from under it and four assertions started reading a signal nobody
had subscribed to. The generalisable rule, for anyone writing the next harness:

> **If the system under test is an autoload, the check must resolve the autoload.** Constructing a
> private instance is only defensible when the check has to pass *before* registration — which is
> `tools/day_night_check.gd`'s documented case, and it says so in its header. Everywhere else, reach
> for `/root/<Name>` and let a missing autoload fail the check on line one.

`tools/wave_spawner_check.gd` now does exactly that, and crosses thresholds by advancing the real
clock (`DayNight.host_advance()`, with `set_physics_process(false)` so nothing crosses behind your
back) rather than by emitting the signal — the claim under test is that the host's own clock reaching
0.75 causes a wave, not that a signal has a subscriber.

### 2026-08-18 — the sky has a night half now (F-065), and these are its seams

`world/environment/playtest_atmosphere.gd` is still the one place time-of-day becomes pixels, and it
is still purely client-local. It now drives two things it did not before. **If you are writing 2.12's
night waves, or anything that wants to know how dark it is, read the clock (`DayNight.time_of_day`),
not these — they are presentation, and a client may legitimately render them differently.**

- **`CloudDeck.set_sky_light(daylight: float, golden: float)`** — the cloud deck is
  `SHADING_MODE_UNSHADED`, so *no light in the scene can affect it*. Anything that wants the clouds
  to change colour has to drive `albedo_color` explicitly; this is that seam. `daylight` is 0 at
  night and 1 with the sun up; `golden` peaks at 1 with the sun exactly on the horizon. Resolved by
  method, not node name, so a level can call its deck whatever it likes.
- **`Atmosphere/StarField`** (`world/environment/star_field.gd`) — built at runtime by Atmosphere's
  `_ready()`, so **no level scene needs editing to get a night sky**, and a level with an Atmosphere
  node already has one. `set_night_amount(0..1)` fades it, `set_sky_rotation(radians)` wheels it. It
  is `top_level` and copies the active camera's position every frame while visible, and hides itself
  and stops processing entirely at `night_amount <= 0.001`.

Three curves now come off sun elevation in `apply_atmosphere()`, and they are deliberately *not* the
same curve — this was the bug, not a refinement. `daylight` (−7°..12°) is the ground-lighting curve
and reaches ~0.3 while the sun is still exactly on the horizon; driving sky colour off it made sunset
grey. `sky_night` (−1°..−14°) turns the sky material to its night colours only once the sun is
actually down. `starlight` (−1°..−16°) brings the stars in. Elevation moves ~24° per game hour at the
horizon, so a narrow window reads as a switch rather than a fade — `atmosphere_night_check.gd`
asserts the fade holds intermediate values, and it caught exactly that on the first attempt.

**Day is provably untouched.** Every day-end sky value is read off the authored resource in `_ready()`
rather than written into the script, and the check asserts full daylight restores
`rayleigh_color`/`mie_color`/`ground_color` byte-for-byte. Re-tune the sky in the `.tscn` and the
script follows.

**Two harnesses:** `agent godot --script tools/atmosphere_night_check.gd` is the headless one (33
assertions, no framebuffer needed). `tools/hollowmere_night_render.gd` is the one that produces
pictures, and it must run **windowed** — its header carries the five-line snippet that takes the same
`godot` lock `agent godot` takes, which is how any future windowed check should be run (F-044).

### 2026-08-17, from Sequoyah's 2.9 playtest — three things 2.13 broke or left dark (F-062/063/064)

The gate could not be judged as shipped. What he actually reported — hp at zero, no death, slow
movement, "attacking the enemies doesn't seem to work anymore" — decomposed into three separate
defects, all fixed and all now covered headless.

- **F-062 · every swing hit the attacker.** `CombatService._best_target()` iterated `&"damageable"`
  without excluding the swinger. Task 2.13 had put the player body into that group so crawler hits
  could land, and that alone turned every axe swing into a self-hit: the attacker's own origin sits
  `EYE_HEIGHT_M` (1.5 m) below the eye at *zero horizontal offset*, which takes the "directly on the
  axis" early branch and **skips the arc test entirely**, then wins the nearest-target contest
  against anything past 1.5 m. Most of the axe's 2.6 m reach was unusable and every swing cost 3 hp.
  **The lesson worth keeping: putting an entity into `&"damageable"` is not a local change.** Any
  future task that adds a body to that group must ask what now targets it.
  `tools/combat_self_hit_check.gd` is the regression anchor, and it exists separately from
  `tools/combat_check.gd` because *that* check's attacker is a bare `Node3D` in `&"players"` only —
  structurally incapable of catching this. New combat checks use the real `player.tscn`.

- **F-063 · offline respawn teleported to world origin.** `_spawn_transforms` was only ever written
  from `PlayerNet.player_spawned`, which fires *inside a session only* — offline PlayerNet leaves the
  level's hand-placed Player alone. So solo play, the configuration 2.9 is played in, always fell
  through to `Vector3.ZERO`. `PlayerHealth._capture_local_spawn_transform()` now latches the local
  body's transform on the first physics tick it exists, and a missing entry warns and respawns in
  place rather than silently slamming to the origin.
  **The lesson: `tools/player_health_check.gd` called `_on_player_spawned` by hand.** A check that
  simulates a signal the shipped configuration never emits proves the handler, not the wiring — it
  hid this for a whole task. That check now also runs the flow with nothing faking the signal.

- **F-064 · downed/dead were invisible.** `ui/hud/vitals_hud.gd` discarded the `state` and
  `bleed_out_remaining` its own snapshot handler received. It now draws a centre banner: **DOWNED**
  with a live bleed-out countdown and the revive line, **YOU DIED** with the respawn countdown, and
  **TEAMMATE DOWN** (with the bound interact key) for a living player, off the broadcast
  `downed_flag_changed` flag. All client-local presentation — no wire change, protocol still 7. The
  countdown re-seeds from every host snapshot and ticks locally in between, because the snapshot is
  throttled to ~1 Hz and a countdown a player watches cannot move at 1 Hz.
  `tools/vitals_hud_check.gd` drives it through the real PlayerHealth host path, not by emitting the
  HUD's own signals.

**Work can now be dispatched to three paid accounts in parallel, and you may be one of them.** If you
are `lc1`, `lc2` or `lp`, you were started by `agent dispatch` and your whole spec is the work order
piped into you — no one is going to answer a question, so decide and keep going. `docs/ORCHESTRATION.md`
is the protocol; D-036 and D-037 are the calls behind it. The commands, for a director:

```bash
agent order <id> --lane LC2 --files a.gd b.gd   # self-contained order; refuses overlapping claim sets
agent dispatch LC2 [--dry-run]                  # runs it on that account, headless
agent report | agent collect | agent reap       # who's working / what came back / free dead claims
```

Two things changed for **everyone**, agent or human, whether or not you use the lanes:

- **Launch the engine with `agent godot --script tools/x_check.gd`, never bare `Godot --headless`.**
  All ~49 checks share one 42 MB import cache and concurrent runs race on it (F-044) — the most
  likely explanation for F-038. `agent godot` takes an exclusive lock; a bare invocation bypasses it.
- **`agent ship` now takes a git lock**, so concurrent ships no longer contend on one index. Nothing
  to remember — it is automatic.

A lane that dies on a quota wall releases its claims and files its own handoff, so a dead lane never
blocks a file. If a process vanished too suddenly for that, `agent reap` is the backstop. Quota
exhaustion is detected only from a *failed* run's error text, and the pattern deliberately ignores
this project's ordinary `rate_limit`/`429` vocabulary — `lane selftest` holds that line at 14 cases,
so run it if you touch the classifier.

**Task 3.8 ships hunger/stamina/food — extending `PlayerHealth` rather than a new service.**
Three authority rows in one file, each documented in its own section of `player_health.gd`'s class
doc: hp and hunger are HOST (hunger drains every host tick, empty hunger drains hp through
`DownedState.apply_damage()` — the exact path a melee hit uses, so starving can down a player like
anything else); stamina is CLIENT-LOCAL (§2.2 row 1, "own player movement") because it gates
sprint/jump/dodge and gating a client's own movement from the host would reintroduce input lag.

**Hunger**: `_hunger`/`_starvation_accum` are host-owned `Dictionary[int, float]`, ticked in
`_physics_process` alongside the existing downed-state loop. `_tick_hunger(peer_id, downed_state,
delta)` prorates against the PREVIOUS hunger value, not the whole delta — a tick spanning both
"still had hunger" and "ran out partway through" (an oversized single step, whether a real engine
hitch or a check fast-forwarding many seconds) must only charge starvation for the fraction actually
spent at zero, or a big-enough delta applies years of accumulated damage in one frame. Found by
`tools/player_vitals_check.gd`'s own fast-forwarding, not by inspection — worth remembering next
time a `_physics_process`-driven accumulator takes an unbounded delta.

Hunger piggybacks `net_health_snapshot` (now `revision, hp, hp_max, state, bleed_out_remaining,
hunger, hunger_max` — **protocol version 9**, was 8) rather than a second RPC channel: published
immediately on a discrete event (damage, revive, consume) and otherwise throttled to
`HUNGER_SNAPSHOT_INTERVAL_SEC` (1 Hz) so a continuous per-tick drain never turns into a 60 Hz reliable
RPC — the same reasoning `day_night.gd`'s `REPLICATE_INTERVAL_SEC` exists for. Read API:
`local_hunger()`/`local_max_hunger()` (owner-only, via `local_hunger_changed`), `host_hunger(peer_id)`.

**Stamina** lives entirely outside `_states`/`_hunger` — no host dictionary, no RPC gate. The owning
client calls `local_tick_stamina(delta, draining)` every physics tick (drains at
`stamina_drain_per_sec` while `draining`, else regenerates at `stamina_regen_per_sec`) and
`local_try_spend_stamina(amount)` for a discrete cost (jump today; 3.8b's dodge is the next caller).
**Hysteresis, not a bare `stamina > 0` gate**: `local_can_sprint()` also checks a `_sprint_locked_out`
flag that `local_tick_stamina()` sets the instant stamina hits exactly zero and only clears once
stamina regenerates back above `sprint_resume_fraction` (15% by default) of max. Without it, a player
sitting at the boundary while still holding sprint flickers on and off every single physics frame —
one frame of regen reads as "> 0" and re-enables sprint, which immediately drains it back to zero.
Found the same way as the hunger prorating bug: by writing `tools/player_vitals_check.gd`'s own
`_apply_horizontal_movement` integration test, which failed until this existed.

The host keeps a **best-effort, advisory-only** copy via `host_stamina(peer_id)`, refreshed by
`net_report_local_stamina` (`any_peer`, unreliable) every `stamina_reconcile_interval_sec` (2s
default) from `local_tick_stamina()` itself. The host never derives gating from this — it exists so
3.8b's server-validated dodge i-frames (or a future teammate HUD) have something recent to read.
Losing a report changes nothing; the next one supersedes it.

**Food**: `ItemDef` gained a `Consumable` export group — `hunger_restore: float` and `hp_restore:
int`, both zero by default (a food item that doesn't heal, or doesn't fill you up, is valid). No real
food `.tres` is authored here — that is task 3.2's job (hand-authored content), not this task's
framework. `request_consume_item(item_id)` mirrors `request_revive()`'s exact shape: a local request
id immediately, completion via `consume_confirmed(request_id, accepted, detail)`. The host validates
alive + registered + `category == CONSUMABLE`, removes exactly one via
`InventoryService.host_transaction()` (reusing the crafting seam, not reinventing it — a rejected
transaction pays out nothing), then applies `hp_restore`/`hunger_restore` directly.

**A latent class of bug, found and fixed while adding hunger's periodic publish, not introduced by
it**: every `rpc_id(peer_id, ...)` send in this file (`net_health_snapshot`, `net_force_respawn`,
`net_revive_confirmed`, `net_consume_confirmed`) now goes through a new `_peer_connected(peer_id)`
guard before sending. D-035 deliberately keeps a departed peer's state alive through NetSession's
grace window rather than releasing it on `peer_left`, which means a peer id can sit in
`_states`/`_hunger` with no live transport connection behind it at all. The pre-existing RPCs here
only fired on a discrete gameplay event, rare enough that this raced silently; hunger's own ambient
1 Hz publish fires for every tracked peer regardless of any gameplay event, so it hit the grace window
within seconds in `tools/player_vitals_net_check.gd`'s own run (`Attempt to call RPC with unknown peer
ID`). **`autoload/inventory_service.gd`'s `_publish_snapshot` has the identical unguarded
`net_inventory_snapshot.rpc_id(peer_id, ...)` call and is presumed to share the bug** — not fixed here
(out of this task's claim), see F-057.

Checks: `Godot --headless --path . --script tools/player_vitals_check.gd` (offline — stamina hysteresis
and jump/sprint gating proven against a real `player.tscn`, hunger drain and prorated starvation
proven by stepping `_physics_process` directly, consume proven end to end against a synthetic
CONSUMABLE `ItemDef` injected into `Registry.items`) and
`agent godot --script tools/player_vitals_net_check.gd` (two real ENet peers — hunger rides the real
wire alongside hp, a client eats over the real RPC and the host's own inventory/hp/hunger all move,
and the client's stamina reaches the host's advisory copy).

**What is left for the playtest**: `ui/hud/vitals_hud.gd` (new autoload, `VitalsHud`, registered
last) renders three bars bottom-left and an `[G] Eat <item>` hint when the selected hotbar slot holds
a consumable — built in code like `InventoryUI`/`CraftingUI`, no `.tscn`. Eating is bound to the raw
`KEY_G` rather than a new InputMap action, the same choice `InventoryUI` already made for hotbar
slots 1-8, because `project.godot` was held by another lane's task (2.1j) when this shipped. Whether
the numbers (20-minute hunger bar, 4s of sprint, a 15% resume threshold) feel right is 3.11's job, not
this one's.

**Task 3.8b ships dodge — CLIENT-authoritative dash (§2.2 row 1, same as the rest of movement), with a
HOST-decided i-frame against enemy melee only.** `entities/player/player_controller.gd` gained a
`@export_group("Dodge")` (`dodge_stamina_cost` 30, `dodge_impulse` 10 m/s, `dodge_duration_sec` 0.25,
`dodge_cooldown_sec` 1.2) and the verb itself: `_execute_dodge() -> bool` (spends stamina through the
same `PlayerHealth.local_try_spend_stamina()` jump already uses, locks in a dash direction from
current movement input — or the player's facing if none is held — and returns false with no side
effects on cooldown/insufficient stamina) and `_tick_dodge(delta)` (counts the cooldown down always,
counts the dash window down only while `dodging`). Bound to a new InputMap action `"dodge"` (Left Ctrl
/ gamepad button 1) via a genuine `project.godot` edit, not a raw key — unlike `EAT_KEY`/
`BUILD_ROTATE_KEY` (D-058), `project.godot` was free this session, so there was no reason to take the
raw-key shortcut for a first-tier movement verb. `_execute_dodge()` is deliberately a standalone
function with no input-event dependency, called from `_unhandled_input` on `"dodge"` pressed — DESIGN
§4.4's Void Resonance "dodge blinks" is expected to wrap or replace this exact call, not reinvent the
verb.

**The i-frame flag (`dodging: bool`) is client-local state, trusted like position (D-039's "cheating
is irrelevant among friends" already covers a player lying about it, same as speed-hacking their own
position), replicated on the SAME synchronizer as position/rotation** — `_build_synchronizer()` added
`^".:dodging"` as a fourth `REPLICATION_MODE_ALWAYS` property, per the task spec's own wording ("the
player's synchronizer already carries"), not a new RPC. ALWAYS, not ON_CHANGE: ON_CHANGE only sends
when the value differs from the last value SENT, so a flag that flips true then false again between
two per-interval checks can be missed entirely — ALWAYS resends the current value every tick
regardless. This is why `dodge_duration_sec`'s export range floors at 0.1s: `NetConfig.
PLAYER_SYNC_INTERVAL_SEC` is ~0.033s (30Hz), and a dash duration too close to one sync tick risks the
host never observing `dodging == true` before it flips back — see that export's own comment for the
full reasoning. **The i-frame window is deliberately the same span as the dash (no separate timer)** —
simplest correct reading of "a dash impulse with i-frames," and it means tuning one number tunes both.

**The i-frame DECISION is the host's, scoped to enemy melee only, not the shared damage seam.**
`systems/health/player_health.gd`'s `_on_enemy_attack_landed()` — and ONLY that function, not
`host_apply_damage()` itself — now calls a new `_is_dodging(peer_id)` (resolves the peer's
`PlayerController` via the existing `_player_body()` helper and reads its replicated `dodging`
property) before ever reaching `host_apply_damage()`. A direct `host_apply_damage()` call (starvation,
melee via the shared `&"damageable"` seam, a future hazard) is untouched — task 3.8b's own spec says
"i-frames against enemy melee only," and gating the shared entry point would have silently blocked
those too.

Checks: `agent godot --script tools/dodge_check.gd` (offline — dash impulse/direction/cost, cooldown
rejection and recovery, i-frames blocking `EventBus.emit_enemy_attack_landed` while `dodging` and
letting the identical hit land once it clears, and proof that `host_apply_damage()` called directly is
NOT blocked by `dodging`) and `agent godot --script tools/dodge_net_check.gd` (two real ENet peers —
the CLIENT calls its own `_execute_dodge()`, the HOST's copy of `dodging` observably flips true over
the real synchronizer wire, and a `enemy_attack_landed` fired ON THE HOST for that remote peer is
dodged while true and lands once false). Both 0 failures, 0 engine `ERROR:` lines.

**`PROTOCOL_VERSION` bumped 14 -> 15** for the new `dodging` replicated property — `core/net/
net_version.gd` and `tools/handshake_check.gd` were held by lane `lm`/task 3.9 (attunement selection
RPCs) for most of this task's session (genuinely in flight, not stale — confirmed by re-attempting the
claim twice before it freed up); claimed and finished once 3.9 released them. `agent godot --script
tools/handshake_check.gd` is 0 failures, 0 engine errors, at 15.

**Task 2.11 ships the day/night cycle — HOST-authoritative time, replicated at 1 Hz, applied
client-local.** `DayNight` (`systems/environment/day_night.gd`) is an autoload registered last (after
`PlayerHealth`). §2.2's "day/night, wave director, Cycle state, active modifiers" row: HOST. The host
advances `time_of_day` (a **0..1 fraction of a day** — 0 midnight, 0.25 dawn, 0.5 noon, 0.75 dusk;
deliberately NOT the same scale as `playtest_atmosphere.gd`'s own 0..24 hour export) every physics
tick by `delta / day_length_seconds`, and pushes it to clients over an unreliable `@rpc("authority")`,
`net_push_time`, at ~1 Hz (`REPLICATE_INTERVAL_SEC`). **Clients never advance the clock themselves** —
`_advance_client()` only lerps between the last two host snapshots (shortest path across the 1.0->0.0
wrap, `_lerp_wrapped_unit()`, the fractional-day equivalent of `lerp_angle()`) and holds flat at the
last snapshot once `REPLICATE_INTERVAL_SEC` has passed with nothing new — proven by
`day_night_net_check.gd` pausing the HOST's own `set_physics_process` (not disconnecting: a dropped
peer correctly self-promotes to host-of-one via `_owns_mutation()`, which would make "does it free-run"
untestable that way). Offline (no session) is host-of-one through the same `_owns_mutation()` gate
every other autoload in this codebase uses.

**Every peer, host included, applies the value the same way:** `get_tree().current_scene` ->
`get_node_or_null(^"Atmosphere")` -> `call(&"set_time_of_day", time_of_day * 24.0)` — the `* 24.0` is
the one conversion point between DayNight's 0..1 and Atmosphere's 0..24h. No Atmosphere node (a
harness, a menu, a level without one) is a silent no-op, asserted directly in `day_night_check.gd`.
**`day_length_seconds` is read from the level's own `Atmosphere.day_length_seconds` export the moment
one is found** (`_resolve_day_length()`), overwriting DayNight's own matching default (900s) rather
than duplicating it as a second source of truth that could drift from the level's tuned value.

**THE TRAP THIS TASK EXISTS TO AVOID, and it is still avoided:** `playtest_atmosphere.gd`'s
`cycle_enabled` free-runs a local clock per peer from its own boot time with no error if left on. It
is untouched here and stays `false` — DayNight drives the sky by calling `set_time_of_day()` every
tick instead, which is the only path this task adds.

**Thresholds for 2.12 (already shipped and already wired against this exact contract):**
`night_started` at `night_started_at` (0.75) and `day_started` at `day_started_at` (0.25), both
exported/tunable, both **HOST-ONLY by construction** — they fire only from `_advance_host()`, which a
client never calls while connected, so "client never emits a threshold signal" is structural, not a
guard that could be forgotten. Crossing detection (`_crossed()`) is wrap-safe and half-open on the
entry side, so sitting exactly on a threshold across many ticks fires once, not every tick.
`systems/waves/wave_spawner.gd` already subscribes by path (`/root/DayNight`, night_started/
day_started, no args) exactly as built here — no change needed on that side.

**Test-only seam worth knowing about:** `host_advance(delta: float)` is the exact math of the host
branch of `_physics_process`, exposed as a public method so a harness can drive many in-game days in a
fraction of a real second. It is genuinely general-purpose (a future "skip to night" console command
could use it too), not test scaffolding bolted on.

**Protocol version is now 8** (was 7) — the new host->client push, `net_push_time`
(`@rpc("authority", "call_remote", "unreliable")`), needed the bump per the standing rule even though
this task's own `docs/SPECS.md` block didn't list `core/net/net_version.gd` /
`tools/handshake_check.gd` in its claim set (added to the claim directly — see F-056 below).
`tools/handshake_check.gd` asserts the literal value.

Checks: `agent godot --script tools/day_night_check.gd` (offline, manually instantiates the script the
same way `tools/wave_spawner_check.gd` proves `WaveSpawner` before either is an autoload — so this
passes BEFORE registration, matching the task's own required order — 9/9, 0 `ERROR:`) and
`agent godot --script tools/day_night_net_check.gd` (two real ENet processes, run AFTER
`agent autoload DayNight ...` since real replication needs the real autoload on both processes —
13/13, 0 `ERROR:`).

**Task 2.13 ships death & respawn, and crawlers are now lethal.** `PlayerHealth`
(`systems/health/player_health.gd`) is an autoload registered last, after `EnemyWorld` and
`DevLoadout`. Same shape as `InventoryService`: a host-keyed `Dictionary[peer_id, DownedState]`
(`systems/health/downed_state.gd`, a pure `ALIVE -> DOWNED -> DEAD -> ALIVE` state machine with no
node and no peer id, exactly the split `InventoryStore` has from `InventoryService`), an owner-only
reliable snapshot (hp/state/bleed-out), and a broadcast bool everyone receives — teammates have to
see who needs help, not just the downed player's own client. D-035 applies in full: state moves on
`NetSession.run_player_rebound(old, new)` and releases only on `run_player_expired(peer)`;
`_on_peer_left` is the same deliberate no-op `InventoryService` uses, comment included.

**Damage comes IN two ways, both host-only, both landing on `host_apply_damage(peer_id, amount,
instigator_peer_id) -> bool`:** `entities/player/player_controller.gd` now joins `&"damageable"`
(same seam `Harvestable` and `Enemy` already use) and forwards CombatService's call here keyed by
`get_multiplayer_authority()`; and `PlayerHealth` is the subscriber `EventBus.enemy_attack_landed`
was built for in 2.10 — `EventBus.enemy_attack_landed_subscriber_count()` is how the wiring proves
itself rather than being trusted. Returns false while downed or dead (no corpse-kicking in M2) or for
an unknown peer, so `CombatService` reads it as a miss, never a phantom hit.

**Downed presentation is client-local, read off two query methods:** `local_is_downed()` and
`local_is_dead()` gate `player_controller.gd`'s own input — crawl speed instead of walk/sprint, jump
and attack blocked outright while downed, ALL movement input blocked while dead (mid-respawn). A
teammate holds `interact` near a downed player; the hold itself is client-side prediction exactly
like D-034 splits combat's wind-up from its hit — `player_controller.gd` tracks the hold locally and
fires exactly one `PlayerHealth.request_revive(target_peer)` the instant its timer reaches
`PlayerHealth.revive_seconds`, and the HOST is what actually decides: `net_request_revive` re-checks
both peers' states and re-measures the distance itself, never trusting the client's hold duration or
a client-supplied position. A downed player respawns at the transform `PlayerNet.player_spawned`
handed `PlayerHealth` when they first joined (own player movement is CLIENT authority per §2.2, so
the host cannot just write another peer's position — `net_force_respawn` tells that peer's own client
to place itself, the same as it is the only thing ever allowed to move its own body).

**Protocol version is now 7** (was 6) — the hello gained no new argument this time, but three new
RPCs did: `net_request_revive`, `net_health_snapshot`, `net_downed_flag`, plus `net_force_respawn`.
`tools/handshake_check.gd` asserts the literal value now, on purpose, so the next wire-shape change
that forgets the bump fails loudly instead of quietly.

**F-043 decided: the iron sword stays OUT of `DevLoadout.loadout`** — see FINDINGS.md's Resolved
section for why (the hotbar is already full at 8/8, and its `WeaponDef` numbers are still 2.9's
unpassed placeholders). `give iron_sword` still reaches it.

Checks: `Godot --headless --path . --script tools/player_health_check.gd` (offline — a real
`player.tscn` instance proves the `&"damageable"` wiring end to end, then bare host-state peers drive
the downed/bleed-out/death/respawn state machine and every revive rejection rule) and
`agent godot --script tools/player_health_net_check.gd` (two real ENet peers — the host downs
*itself* so the interesting proof is a DIFFERENT peer learning about it over the broadcast; a
self-targeted revive is rejected; an out-of-range revive is rejected using the host's own copy of
both positions; a non-lethal hit survives a live disconnect+reconnect under a new peer id, proving
D-035's rebind rather than a reset).

**What is left for the playtest:** no HUD reads any of this yet — `local_health_changed` and
`downed_flag_changed` are ready for 6.x's HUD to consume, but today the only feedback a downed player
gets is the crawl and the blocked input. The revive hold has no progress indicator either. Both are
presentation gaps, not authority gaps — the host-side contract above does not change under them.

**Items now have icons, and `ItemDef.icon` is populated.** `assets/icons/exports/icon_<id>.png` holds
26 transparent 256×256 icons — every A-002 pickup, every A-004 tool/weapon, A-021S's iron sword, and
(F-061) the coin pouch backing `coins.tres` — where `<id>` matches `ItemDef.id`. **All 16 item `.tres`
files carry their icon**; a new item wires its icon by setting `icon` on its `.tres`. Icons are
renders of the shipped GLBs, not drawings (D-033), so a model
change is followed by re-running `tools/blender/render_item_icons.py`, never by editing a PNG. Adding
an icon for a new asset family means appending to `SOURCES` in that script, not starting a second
pipeline. `assets/icons/catalog.json` records each icon's source GLB and framing;
`tools/item_icons_check.gd` is the headless proof that they import and that every `ItemDef` carries
one.

**The A-004 tool and weapon exports were rebuilt (A-004R) and every mesh in them changed.** File names,
the ten design names, and the world/viewmodel pairing are unchanged, and dimensions moved by at most
about 6 cm, so anything referencing these GLBs keeps working — but a scene that was tuned against the
old silhouettes is worth re-checking. `tools/blender/build_tool_weapon_set.py` gained two reusable
builders worth knowing about before hand-modelling anything similar: `ground_profile()` (a silhouette
outline with per-point bevel *distances*, which is how a head gets a square poll and a ground edge)
and `swept_shaft()` (a tube along a polyline with a radius per point, which is how hafts get taper and
an oval section).

**You now start with gear, and the world has crawlers in it.** Both were missing when Sequoyah first
pressed Play, and both were wiring rather than logic — `EnemyWorld.host_spawn()` worked and nothing
called it; the nest marker existed and nothing read it.

`DevLoadout` (`core/dev/dev_loadout.gd`, autoload, registered last) grants a starting kit through
`InventoryService.host_add()` — a host seam with no client RPC, so a client cannot ask for one. It
hangs off `PlayerNet.player_spawned` (F-018) and, offline, off a `current_scene` gate. **That gate is
load-bearing: a `--script` harness is its own main loop and has no `current_scene`, and without it
every headless check in `tools/` boots with a full inventory** — four of them failed the moment this
autoload existed, correctly. Entries marked `hotbar: true` are moved onto the bar, because 2.4 fills
backpack slots first and a grant without that leaves you unable to swing without opening Tab.
`enabled = false` turns the whole thing off when task 3.x decides what a real run starts with.

`EnemyWorld` gained **ambient spawning** — `ambient_enabled`, `ambient_population` (4),
`ambient_respawn_seconds`, spawning at every level marker whose `kind` meta is `enemy_spawn`. **This
is not task 2.12**: no day/night gate, no Cycle scaling, no despawn at dawn. 2.12 is expected to set
`ambient_enabled = false` and drive `top_up_ambient()` / `host_despawn_all()` itself. It also
bootstraps offline: pressing Play opens no session, so nothing called `bake_navigation()` either —
now a short delay after boot bakes the level's navmesh (2,529 polygons in Playtest Hollow) and fills
the field.

Console commands — every mutating one host-only; `items` and `enemies` are read-only and answer on
any peer: `give <item_id> [count]`, `loadout`, `items`, `spawn [enemy_id]
[count]`, `killall`, `enemies`. Check: `tools/dev_loadout_check.gd`, which loads the **real main
scene** rather than a bare tree — a bare tree would have passed throughout both of these bugs.

**Content warning, in the AGENTS.md sense.** `tools/setup_tool_content.gd` bulk-generated nine
ItemDefs and seven WeaponDefs from `assets/tools_weapons/catalog.json`, which is the thing agents are
told not to do. It was done because Sequoyah asked for one of each tool and nine of the ten designs
had no ItemDef, so there was nothing to grant. **The weapon numbers are derived from one rule —
heavier swings slower, hits harder, reaches further — not tuned.** They exist so the ten weapons
differ in a way 2.9 can feel and argue with. Retune in the inspector; re-running that script
overwrites them.

**Task 2.9 is a gate, and only Sequoyah can pass it.** `ROADMAP.md` says *tune combat feel until one
enemy with one weapon feels great; do not proceed otherwise*, and no agent can judge that. What 2.9
shipped is everything that makes the judgement possible, plus the instrument to argue about numbers
instead of adjectives:

`Godot --headless --path . --script tools/combat_feel_check.gd` prints the whole picture and asserts
the *relationships* between authored values — never whether a value is fun. Current reading:

```
time-to-kill 4 swings, 2.72 s of swinging
reaction     0.28 s of the 0.40 s tell is thinking time; 0.50 m of retreat costs 0.12 s
worst case   standing at contact needs 0.50 s to clear 2.00 m — sprint or trade, do not walk
retreat      walking loses 0.40 m/s; sprinting gains 1.60 m/s
```

**The one tuning call that is a design decision, not a number: the crawler moves at 4.4 m/s, faster
than the 4.0 m/s walk and slower than the 6.0 m/s sprint.** At 2.10's original 3.4 a player could
walk backwards forever and never be caught — which is exactly the "backpedal spam" `DESIGN.md` §6
names as the thing to fix, and it makes the 0.4 s telegraph decorative. Now retreating costs 0.4 m/s
per second, sprinting still disengages, and standing your ground is sometimes correct.

2.9 also filled two feedback gaps 2.10 left. An enemy now **reacts** to being hit: a replicated
`hit_counter` (a counter, not a flag — a flag can go true and false between two snapshots and be
missed) drives A-006's `hit` clip plus a 0.12 s white overlay, so a connect is visible even when the
clip is masked by a committed attack. And a corpse **sinks and fades** over `corpse_seconds` instead
of blinking out, which is the "ragdoll or dissolve" 2.10's line asked for, done as geometry rather
than as a shader on an imported GLB.

**What is left for the playtest**, in the order it will matter: does the 0.4 s tell read at all in
first person; does the axe's 100° arc make hitting a moving crawler feel generous or sloppy; is
0.075 s of hitstop an impact or a hitch; and does 4 swings per crawler stay right when there are
three of them. **There is still no authored impact sound** — the thud is 2.8's code-built
placeholder, and it is the single biggest remaining gap in "loud, satisfying impact".

**Task 2.10 ships Enemy v1, and 2.12's wave spawner drives it through `EnemyWorld`.** `EnemyWorld`
is an autoload registered after `CombatService` (later autoloads have since followed it — the
[autoload] section of `project.godot` is the truth, not any "last" claim here). It loads `content/enemies/*.tres` into
`get_def(id)` / `has_def(id)`, owns the code-built `MultiplayerSpawner` (D-023), and exposes the
host-only seams task 2.12 needs: `host_spawn(def_id, position) -> Node3D`, `host_despawn_all()`,
`live_enemies()`, `live_count()`, and the signals `enemy_spawned(enemy)` and
`enemy_died(enemy_id, instigator_peer_id, position)`. **There is no client spawn RPC and there must
not be one.**

`Enemy` (`systems/enemies/enemy.gd`) is a `CharacterBody3D` whose every decision is the host's:
target choice, pathing, turning, when the swing lands, health and death. Its state machine is
`IDLE → CHASE → TELL → ATTACK → RECOVER`, plus `DEAD`, replicated as an int alongside position, yaw
and health. Three behaviours are deliberate and worth not "fixing":

- **The hit resolves at the END of the tell, against where the target is then.** That is what makes
  backing out of a telegraphed swing work, and it is the entire point of DESIGN.md §6's 0.4 s.
- **Damage does not interrupt a committed attack.** An enemy whose swing any chip of damage cancels
  cannot threaten a group.
- **Aggro has hysteresis** — `aggro_radius_m` to acquire, the wider `deaggro_radius_m` to drop —
  because one radius makes a target on the boundary flicker every tick.

Enemies join `&"damageable"` and implement `host_apply_damage()`, so **2.8's `CombatService` needed
no change to make them hittable**. Damage going the other way is `EventBus.emit_enemy_attack_landed(
enemy_id, peer_id, damage, world_position)` — player health does not exist yet, and **task 2.13 owns
what an enemy hit costs**; subscribe rather than adding a health field to the player.

Two things to know before building on it. **Navigation is baked once per session from the level's
static collision** by `EnemyWorld.bake_navigation()`, and `nav_polygon_count()` reports the result;
if it bakes zero polygons the enemy steers straight at its target instead of freezing, which is the
right failure but is *not* pathing — check that number before blaming the AI. And the enemy's
synchronizer is deliberately named `NetConfig.PLAYER_SYNC_NODE`, so **`NetInterp` smooths enemies
with no change (F-004)**.

Content is one authored `content/enemies/crawler.tres` over A-006's model. **Its `attack_tell_seconds`
and `attack_seconds` are both 0.4 because the authored clips are** — changing either without
re-authoring the clip desynchronises the telegraph from the hit. Checks:
`tools/enemy_check.gd` (44 assertions, steps the state machine directly rather than sleeping) and
`tools/enemy_net_check.gd` (two real ENet processes; its interesting assertions are the negative
ones — the client's copy runs no physics).

**Run-player identity is how host-owned state survives a reconnect (F-032, D-035).** An ENet client
that rejoins gets a **new peer id**, so a system that keys state by peer id sees one player leave and
a different one arrive. `NetSession` now mints an opaque token per run-player on the client hello,
hands each client only its own, and exposes two signals:

| Signal | Meaning |
|---|---|
| `run_player_rebound(old_peer_id, new_peer_id)` | Same player, new id. **Move** whatever you keyed under the old one; it is gone when this returns. |
| `run_player_expired(peer_id)` | Not coming back — its 90 s grace ran out. **Release** its state now. |

**The rule every host-owned system must follow: do NOT release peer-keyed state on `peer_left`.**
Between a drop and a rejoin the player is still a player, and `peer_left` cannot tell the two apart.
`InventoryService` is the worked example — its `_on_peer_left()` is deliberately a no-op with a
comment saying why. Health, powerups, Attunement and any peer-keyed enemy aggro inherit this by
connecting to the same two signals.

Also on `NetSession`: `run_token()` (this peer's own token, harnesses only) and
`orphaned_run_players()` (how many are parked). The registry itself is `core/net/run_identity.gd` —
pure data, no node, testable without a session. **Protocol version is now 6**: the hello gained an
argument. Checks: `tools/run_identity_check.gd` for the rules,
`tools/session_lifecycle_check.gd` for the real multi-process reconnect.

**Four standing rules, promoted out of `FINDINGS.md` so they are read before they are rediscovered.**
F-011, F-012, F-016 and F-021 were closed on 2026-08-16 not because the engine changed but because a
permanent rule does not belong on a board of unscheduled problems.

1. **A gameplay script that a harness can reach must never name an autoload as a bare identifier**
   (F-011). A `--script` main loop is compiled *before* autoloads are registered, and it compiles the
   scripts it depends on in the same pass — so the restriction reaches any script pulled in through a
   `class_name`. Use `get_node_or_null(^"/root/Thing")` and `call(&"method")`. This is not
   theoretical: 2.8 put `CombatService.request_attack()` in `player_controller.gd`, which
   `verify_setup.gd` reaches through `PlayerController`, and silently broke that harness *and*
   `interp_check.gd` — the latter reporting what looked like a netcode defect.
2. **A new `class_name` is not resolvable bare in a headless run either** (F-016) — the global class
   cache is only rebuilt by an editor scan. `const Thing = preload("res://path/thing.gd")` works
   before and after the cache catches up.
3. **Set `set_multiplayer_authority()` on a synchronizer BEFORE `add_child()`** (F-012, D-023).
   Setting it once the node is in the tree makes the replication interface reject the pending spawn on
   every client, and the symptom is error spam plus silently degraded state, not a clean failure.
4. **Grep every check run for engine errors** — `… 2>&1 | grep -c 'ERROR:'` — and treat any
   UNDECLARED error line as a failure (F-021). GDScript has no supported hook to fail a harness on
   engine-level `push_error`, so a green exit code alone is not evidence: `net_debug_panel_check`
   passed 19 assertions for weeks on top of a stream of `Multiplayer root was not initialized`.
   One refinement (F-052): a check that deliberately provokes error paths declares them by PATTERN
   in its verdict line — `EXPECTED_ERROR_PATTERNS="pat1|pat2"` — because provoked-error counts vary
   with timing (a slow run logs an extra rejoin timeout). Grade with
   `grep 'ERROR:' | grep -vE '<declared>' | wc -l` → 0. Today only `session_lifecycle_check` and
   `connect_retry_check` declare (the refusals and timeouts they exist to test, which production
   code correctly reports via `MireLog.error`).

**Task 2.8 ships melee combat v1 — and 2.9 tunes it in the inspector, not in code.** `CombatService`
is an autoload late in the load order. The split is D-034: the swing is client-predicted, the hit is host.
`request_attack()` starts the local wind-up on the press and returns a request id; the client sends
only its hotbar slot index, and the host reads its *own* `InventoryService.host_slots(peer_id)` for
that slot to decide the weapon, uses the yaw/pitch the player synchronizer already replicates for
aim, runs its own swing clock, and resolves the hitbox at the end of the wind-up.

Read/observe seams: `local_phase()` → `CombatService.Phase.{IDLE, WIND_UP, COMMIT, RECOVERY}`,
`local_swing_progress()`, `local_hitstop_remaining()`, `host_swing_active(peer_id)`,
`weapon_for_hotbar_index(i)`, and the signals `swing_started(weapon_id)`,
`swing_phase_changed(phase)`, `attack_landed(peer_id, position, damage, target_name)`,
`attack_missed(peer_id)`, `attack_rejected(request_id, detail)`. A swing cannot be cancelled or
recut: `request_attack()` returns -1 while one is running and the host separately rejects a second
request with *previous swing has not recovered*.

**The melee target seam is the group `&"damageable"` plus
`host_apply_damage(amount: int, instigator_peer_id: int) -> bool`.** Harvestable joins it and already
had that exact method; **task 2.10's enemies join the same group and `CombatService` needs no
change**. Returning false is a miss, not a phantom hit. Targeting is a horizontal arc
(`arc_degrees`) with a separate vertical band (`vertical_reach_m`) rather than a shapecast, so a prop
whose mesh origin sits on the ground is hit by a level swing.

Weapons are content: `WeaponDef` (`systems/combat/weapon_def.gd`) is a `.tres` in `content/weapons/`
**keyed by the `ItemDef.id` it belongs to**, loaded by `Registry` into `get_weapon(item_id)` /
`has_weapon(item_id)`. `content/weapons/stone_axe.tres` is the one authored weapon; an item with no
WeaponDef swings `CombatService.unarmed`, which is built in code so an empty hand is never an
authoring job. **Task 2.9 tunes `stone_axe.tres` and the `@export`s on `player_camera.gd` in the
inspector — do not re-run `tools/setup_combat_content.gd` after that, it overwrites the resource.**
Impact audio falls back to a code-built placeholder thud (seeded, deterministic) so 2.9 has something
audible before any audio asset exists; assigning `WeaponDef.impact_sound` replaces it with no code
change. **There is still no authored impact sound in the repo** — that is Sequoyah's, and it is the
one part of 2.8's "impact SFX" that is a placeholder rather than final.

Checks: `Godot --headless --path . --script tools/combat_check.gd` (offline, ~40 s — it waits out
real swing timings, so do not assume a 15 s timeout is enough) and
`tools/combat_net_check.gd` (two real ENet processes). Three traps they cost: a harness target must
`add_to_group(&"damageable")` or every swing correctly finds nothing; `node.get("method_name")`
returns **null** — `get()` resolves properties and signals, so an RPC driven from a harness needs
`Callable(node, "method").rpc_id(...)`; and these net harnesses spawn players into an empty root with
no floor, so the player falls continuously and a fixed-position target drifts out of reach between
swings.

**Task 2.7 ships the client-local crafting presentation.** `CraftingUI` is an autoload ordered
after `CraftingService`. It is opened by the `interact` action (E) and only while
`CraftingService.local_station_in_range(&"workbench")` is true; `interact` again, Escape, or walking
out of range closes it. An "E USE WORKBENCH" prompt sits above the hotbar whenever a workbench is in
range and no cursor UI is open. Rows are built once from `recipes_for_station(&"workbench")`, and each
renders `have/need` per ingredient straight off the authoritative snapshot — `2/2 Log · 3/3 Stone` —
plus READY / MISSING MATERIALS / OUT OF RANGE. The craft button is a hint, not a gate: pressing it
sends `request_craft()`, shows *Waiting for the host…*, and the panel then displays the host's
`craft_confirmed` detail verbatim. Nothing is predicted; requirement counts change only when the next
authoritative snapshot arrives.

The seams a later UI should reuse: `is_open()`, `set_open(open)`, `try_open_station()` (returns
whether it actually opened, so the caller knows if the input was consumed), `poll_station()`,
`is_station_in_range()`, `is_prompt_visible()`, `recipe_row_count()`, `displayed_recipe_id(i)`,
`is_recipe_craftable(i)`, `craft_button_disabled(i)`, `recipe_requirement_text(i)`,
`request_craft_at(i)`, and `status_text()`. `request_craft_at()` presses the real button, so a harness
exercises the shipped path. Two traps this cost: a **local** host answers *inside* `request_craft()`,
before the request id exists to compare against — hence the in-flight flag rather than an id check
(a naive id comparison silently overwrites the answer with "Waiting…"); and **GDScript lambdas capture
locals by value**, so an `_until()` poll must never assign to an outer variable it also wants to read.
The focused check is `Godot --headless --path . --script tools/crafting_ui_check.gd`; the rendered
proof at both widths is `Godot --path . --script tools/crafting_ui_render_check.gd`; the client-side
waiting/confirmed states are proven over real ENet by the extended `tools/crafting_net_check.gd`.

**Task 2.6 ships host-authoritative workbench crafting.** `CraftingService` is an autoload ordered
after `InventoryService` and exposes `recipes_for_station(station)`,
`local_recipe_status(recipe_id)`, `local_station_in_range(station)`, and
`request_craft(recipe_id)`. The first three are presentation helpers only. A request carries only a
recipe id and local request id; the host derives the sending peer, looks up that peer's authoritative
`PlayerNet` player, requires it within 3.25 m of the mapped `station_workbench_primitive`, revalidates
the registered `RecipeDef`, and commits through `InventoryService.host_transaction()`. The
`craft_confirmed(request_id, accepted, detail)` signal is the UI's accepted/rejected feedback seam;
clients do not predict inventory changes.

The one authored vertical-slice recipe is `stone_axe`: two `log` plus three `stone` produce one
non-stackable Stone Axe at `&"workbench"`. Bulk recipes remain task 3.2. The focused offline proof is
`Godot --headless --path . --script tools/crafting_check.gd`; the real two-process ownership/RPC proof
is `agent godot --script tools/crafting_net_check.gd`. The new RPCs made the protocol version 5 at
the time; later additions have moved it on — `core/net/net_version.gd` is the single source of
truth (6 as of F-032's hello argument).

**Task 2.5 ships the client-local inventory presentation.** `InventoryUI` is an autoload ordered after
`InventoryService`. The hotbar always renders its own stable slots 24–31; Tab opens the separate
24-slot field pack at slots 0–23, and Escape or Tab closes it. Drag/drop sends a full-stack
`request_move_stack()` and renders only the
next authoritative snapshot — there is no optimistic mutation. `operation_confirmed` supplies the
accepted/rejected status line. Number keys 1–8 and clicking a hotbar cell change the local highlight;
held-item behavior is deliberately not invented before its gameplay system exists. Item icons render
when an `ItemDef.icon` exists, with compact names as the current content fallback.

Opening the inventory makes the cursor visible and joins `&"blocks_gameplay_input"`; the local player
gates movement and jump while any UI owns that group. This does not pause the tree, so a network client
continues processing. Closing removes the blocker and restores prior mouse capture. The focused check
is `Godot --headless --path . --script tools/inventory_ui_check.gd`; the rendered desktop and narrow
proof is `Godot --path . --script tools/inventory_ui_render_check.gd`.

**Task 2.4 ships the host-owned inventory seam that 2.5 and 2.6 build against.** `InventoryService`
is an autoload after `Registry`, with one 32-slot `InventoryStore` per peer: backpack slots 0–23 and
separate hotbar slots 24–31. New grants use backpack empties before hotbar overflow, and removals use
backpack stacks before equipped hotbar stacks. Slots are stable dictionaries shaped as
`{"item_id": StringName, "amount": int}`; empty slots are `{}`. UI reads `local_slots()` and
`local_revision()`, listens to `local_inventory_changed(slots, revision)`, and sends drag/drop through
`request_move_stack(from_index, to_index, amount = 0)`. Destructive requests return a request id and
finish through `operation_confirmed(request_id, accepted, detail)`. Callers never mutate returned
snapshots.

Only trusted host systems can grant items: `host_add(peer_id, item_id, amount)` is all-or-nothing,
and no client add RPC exists. Harvest yields are already subscribed and grant the yielded item to the
validated instigator peer. Crafting should use
`host_transaction(peer_id, removals: Dictionary, additions: Dictionary)`, which rolls back the exact
slot layout unless every removal and addition fits. `host_count`, `host_can_add`, `host_can_remove`,
`host_remove`, and `host_slots` are host-only seams. Owner-only reliable snapshots carry full stable
slots plus a monotonic revision; a client request carries no peer id, so the host always derives the
inventory owner from `multiplayer.get_remote_sender_id()`. The 32-slot snapshot introduced protocol
version 4; later RPC additions moved it on — `core/net/net_version.gd` is the single source of
truth. Inventories are keyed by transport peer id but are **NOT released on `peer_left`** — F-032
is fixed (D-035): `_on_peer_left` is a deliberate no-op, state moves on
`NetSession.run_player_rebound(old, new)` and is released only on `run_player_expired(peer)`. Any
system that copies the old released-on-peer_left behaviour reintroduces the bug F-032 describes.

**Asset batches A-001 through A-008 plus A-004R, A-042a and A-021S are complete; A-009 is next.**
Harvest states live under `assets/harvestables/` (12 GLBs), basic pickups under `assets/pickups/`
(14 GLBs), the eight vertical-slice stations under `assets/crafting_stations/`, and eleven
tool/weapon designs under `assets/tools_weapons/` as 22 paired `*_world` and `*_viewmodel` exports.
Each family has its own
catalog, previews, editable source, and deterministic generator. Pickups, stations, and tools are
horizontally centred and ground-origin normalized. The paired tool exports deliberately share
geometry and materials so Godot scenes can tune world and first-person transforms without silhouette
drift. None contain collision or authority: harvest mutation, pickup grants, station placement/use,
crafting validation, fuel, repairs, attacks, hits, and inventory changes remain host-owned. Static
fire meshes are cosmetic placeholders for later client-local VFX. A-005 added ten loot meshes under
`assets/loot/`, A-006 the first rigged family under `assets/enemies/`, A-007 eight Ward condition and
support meshes under `assets/wards/`, and A-008 twelve Wellspring landmark, modular, condition,
ritual, boundary and arena meshes under `assets/wellsprings/`. The Ward condition meshes share the
exact same 2.48 m foundation bounds with 0.00 mm centre/size drift; author collision from
`ward_foundation.glb` and do not expand it around damaged debris. The four Wellspring condition
meshes likewise share the exact 4.6 m foundation with 0.00 mm centre/size drift; author collision
from `wellspring_base.glb`, not roots or state-specific crystals. The distant monolith is 7.245 m
tall. Wellspring meshes contain no objective, ritual, corruption, reward, guardian or network
authority; the host owns those states. Sequoyah's supplied tree and rock were adapted separately
under `assets/environment_additions/` rather than counted in A-007. The next asset run takes the
single `NEXT` row in `docs/ASSET_TRACKER.md` — currently A-009, the extraction ship set — and should
use a separate generator per family.

**A-021S added the iron sword, and the tool/weapon generator gained a primitive for it.**
`lofted(name, rings, mat, apex)` in `tools/blender/build_tool_weapon_set.py` builds a solid through
explicit cross-sections and optionally closes it on a point. Reach for it instead of
`ground_profile()` whenever a shape is much longer than it is wide: a ground profile insets its walls
toward the profile's *centroid*, so on a metre-long blade the pull near the point is almost entirely
downward and leaves a square wall where the edge should be. The sword is the set's only design that
spends real budget — 421 polygons / 1,000 triangles against 114–348 for the ten tools.

A-021S is also the first batch to author its own content resources under D-031:
`content/items/iron_sword.tres` and `content/weapons/iron_sword.tres`, written while a parallel
session held the other nine item `.tres` files. The boundary that made that safe was claiming the two
files by exact path, not by directory. The `WeaponDef` numbers (0.19 / 0.11 / 0.26 s, 2.9 m, 95°,
6 damage) are placeholders chosen to sit between the cleaver and the axe — **task 2.9 owns them** and
its gate is unpassed. `ItemDef.grip_scale` is 0.32 rather than the axes' 0.55 because the sword is
1.72 m tall and at 0.55 its blade leaves the top of the screen; per-item grip data exists for exactly
this. F-043 records that nothing puts the sword in a player's hand: it is not in
`core/dev/dev_loadout.gd`, so only `give iron_sword` reaches it.

**Environmental animation is automatic in `playtest_hollow`.** `world/gen/playtest_hollow.gd`
creates the client-local `EnvironmentVfx` controller. It discovers grass, fern, reed and sedge mesh
parts in the authored GLB and applies the shared height-masked wind shader; new placements inherit
motion without material wiring. It also replaces authored outer/furnace flame placeholders with
procedural flame, spark and smoke particles plus a flickering local light. None of this carries
gameplay state or network authority. Verify with
`Godot --headless --path . --script tools/environment_vfx_check.gd` and visually tune the constants
in `autoload/environment_vfx.gd` or `world/environment/foliage_wind.gdshader`.

**A-006 is the first rig, and combat code needs three facts from it.** `assets/enemies/exports/`
holds `enemy_crawler.glb` (skinned, 17 bones, 6 clips) plus static `enemy_crawler_nest`,
`enemy_crawler_fragment_shell` and `enemy_crawler_fragment_leg`.

1. **Ask the `AnimationPlayer` for `idle`, `locomotion`, `attack_tell`, `attack`, `hit`, `death`.**
   The GLB names the first two `idle-loop` and `locomotion-loop`; Godot 4 reads that suffix as
   "loop this clip" and then strips it. The exported name will not resolve at runtime.
2. **`attack_tell` (0.4 s) and `attack` (0.4 s) chain.** The attack's first frame is the tell's last,
   so they play back to back without a pop, and the tell can be held or cancelled on its own. The
   0.4 s tell is `docs/DESIGN.md` §6's readable-telegraph target, not an arbitrary length.
3. **`death` (1.0 s) ends settled and flat**, so a corpse mesh, ragdoll or fragment burst can take
   over from its final pose.

The crawler is 1.10 m long, 0.59 m tall, origin at the ground between its feet, facing -Z. It carries
no collision, health, AI, aggro, or authority; spawning, targeting, attack timing, hit registration
and death stay host-authoritative. Rebuild with Blender 5.2 via `tools/blender/build_enemy_crawler.py`;
verify with `Godot --headless --path . --script tools/enemy_crawler_check.gd`, which asserts the
skeleton, the skin, all six clip names and exactly which two loop.

**Blender generator naming trap:** never put raw float values in object or datablock names. Blender
5.2 treats the text after the last `.` as a numeric duplicate suffix; a coordinate such as
`.30600000000000005` aborts background Blender in libc++ with `stoi: out of range`. Use integer
indices in procedural names.

**The Hollow is the only map, as of 2.1j.** `playtest_map` was removed at Sequoyah's request —
generator, source, GLB, preview, scene, check, and the `TestMapProps` autoload that loaded it.
`levels/playtest_hollow.tscn` is `main_scene`. Its editable source is
`assets/source/playtest_hollow.blend`, exported as `assets/maps/playtest_hollow.glb`, and both it and
the Godot collision are generated from one frozen layout at
`world/gen/layouts/playtest_hollow.json`. The open ground is a heightfield in that layout:
`build_playtest_hollow.py` meshes it flat-shaded, `world/gen/playtest_hollow.gd` builds a collider
from the same triangles. Rebuild with Blender 5.2 via
`tools/blender/build_playtest_hollow.py`; verify with
`.agent/bin/agent godot --script tools/playtest_hollow_check.gd`.

**`playtest_hollow` is the playtest level, and it is now the project's main scene.** Its **88 × 88 m**
layout — **783 prop placements and 33 terrain records**, of which 20 collide — lives in the single
deterministic `world/gen/layouts/playtest_hollow.json`. Blender consumes that file to produce
`assets/source/playtest_hollow.blend`, the **6,256-mesh** `assets/maps/playtest_hollow.glb`, and its
preview; `world/gen/playtest_hollow.gd` consumes the same records to build **359 terrain and prop
collision shapes**. The scene has six zones, a camp with two swung-open gate leaves and four verified
1.8 m-clear egress routes, clear roads, a lowered Mire basin, two ridge terraces, five traversable
ramps, a closed boundary, loot/pickup/tool placements, and the crawler nest marker.

*(F-031: this paragraph described the superseded 2.1f layout — 463 props, 4,102 meshes, 68 × 68 m —
long after 2.1h replaced it, so tasks were planning against a map that no longer existed. The figures
above are `tools/playtest_hollow_check.gd`'s own output, re-run 2026-08-16:
`zones=6 props=783 terrain=20 colliders=359 visuals=6256 failures=0`. Re-read them from that check
rather than editing this paragraph by hand.)* Rebuild with `tools/mapgen/hollow_layout.py` then
`tools/blender/build_playtest_hollow.py`; verify with `tools/playtest_hollow_check.gd`. Static map
collision remains client-local; harvesting, inventory, loot, enemies, damage, and mutation remain
host-authoritative. `world/environment/playtest_atmosphere.gd` controls its physical sky, sun, and
localized volumetric light shafts; `world/environment/low_poly_clouds.gd` builds deterministic,
faceted mesh-cloud clusters that drift locally. Blanket fog is disabled; the only readable fog
volumes are Mire haze, forest-floor mist, and a thin ruins layer. The optional local clock
defaults off; task 2.11 must drive `set_time_of_day()` from replicated host time rather than letting
peers advance it independently.

**1.5, 1.9 and 1.10 shipped earlier** (`8d6ddab`, `ef1bc16`, `4f17bcd`), and 1.10 is now actually
*wired* (`9f56451`). **1.6, 1.7, 1.8 and 1.11 are now implemented and headlessly verified** — read
the table and the per-task sections below rather than assuming a clean slate. The only remaining M1
task is 1.12, whose three-machine Steam transport has now worked but whose formal evidence run is
still incomplete.

**Task 1.12 live state (2026-08-16):** all three `tools/steam_check.gd` preflights passed on stock
Godot `4.7.1.stable.official.a13da4feb`, GodotSteam 4.21 and App ID 480. The accounts are macOS
`TheQuoy`, Windows `quoygeber`, and Linux `sequoyahgeber`, and they are mutual friends. The Windows
current test checkout is `C:\MIRE-main` with Godot at `C:\Tools\Godot\Godot_v4.7.1-stable_win64.exe`;
the stale `C:\MIRE` copy still predates D-029 and must not be used. The Linux
checkout is `/home/ubuntu/mire-task-1.12` with Godot at `/home/ubuntu/.local/bin/godot-4.7.1`.
Windows Steam IPC is unavailable to an OpenSSH service session, so launch Steam checks and the game
in the signed-in interactive console session (an interactive scheduled task is suitable).

A Mac-hosted lobby reached three peers and displayed all three spawned players after
`player_controller.gd` gained code-built coloured remote debug capsules and `players` group
registration. Linux movement visibly replicated on the Mac host. Windows first join remains flaky:
it twice hit `connect to steam:<lobby_id> timed out after 10.0s`, then connected on an immediate
retry to the same lobby; one of those first-attempt failures occurred with Windows Firewall already
fully disabled, so F-023 tracks the brittle timeout independently of firewall configuration.
Windows Firewall was restored and verified enabled on all three profiles before a later two-platform
rerun. That rerun used a fresh `origin/main` archive at `C:\MIRE-main`: Windows peer `579922246`
joined a Mac-hosted lobby, showed `STEAM client`, peers `[1, 579922246]`, and two players in F3, and
the host despawned it on exit. The old checkout's 10-second timeout was retained as failure evidence;
the fresh checkout used D-029's 20-second budget. Remaining 1.12 work is a fresh run on
the shipped revision with the firewall enabled, 60 seconds of movement by every player, one F3
screenshot and complete log per platform, then clients exiting before the host.
The retained evidence logs are in `/Users/sequoyahgeber/Desktop/MIRETestLogs`; the final diagnostic
run ended host-first, so both client logs correctly record `CONNECTION_LOST` and are not pass evidence.

**F-023's mechanism is fixed as of 2026-08-16 (vane, D-029) — 1.12's rerun inherits new behaviour and
one job.** A Steam client no longer gets one 10 s attempt and a dead end:

| API | What it is |
|---|---|
| `NetConfig.STEAM_CONNECT_TIMEOUT_SEC` | Steam's own connect budget, **provisionally 20 s**, separate from ENet's `CONNECT_TIMEOUT_SEC` |
| `NetTransport.connect_timeout_sec(mode)` | static; the budget for a mode. Anything that waits on a connect must derive its own deadline from this, never hard-code one |
| `NetTransport.EndKind.CONNECT_TIMEOUT` | split from `CONNECT_FAILED`. A refusal is an answer; a timeout is the absence of one, and only the second is retried |
| `NetTransport.last_connect_msec()` | how long the last successful join took, or -1. Also logged as `connected … in N.NNs` |
| `NetSession.connect_retry_attempted(attempt, of)` | a first join is being retried. **Not** `rejoin_attempted` — nothing has been lost yet, so a UI must not say "Reconnecting…" |
| `NetSession.connect_failed(detail)` | the first join gave up. `session_ended` does not fire; there was never a session |
| `NetSession.is_connect_retrying()` / `auto_connect_retry` | state, and the off switch for probes |

Retries are **STEAM-only** and that is load-bearing: a timed-out attempt tears down without announcing,
so SteamLobby never leaves the lobby and the retry is a plain `join()`. That is why this is not F-020,
which is the rejoin-*after-drop* case where the lobby genuinely was left. LOCAL/LAN first joins are
still DevLaunch's — F-024 records the gap that leaves in a shipped LAN join.

**The one job 1.12's rerun inherits:** every join now prints its own duration, so the run produces the
first-join latency nobody has ever measured. Collect the `connected … in N.NNs` line from all three
platforms, then set `STEAM_CONNECT_TIMEOUT_SEC` from the observed tail — 20 s is an allowance, not
evidence. A Windows timeout that the automatic retry recovers is the fix working, and is still not a
clean PASS. Verify the mechanism first with
`Godot --headless --path . --script tools/connect_retry_check.gd` (PASS, 0 failures on macOS).

**Three open findings were closed this session, all of them process rather than game code:** F-013
(the `&"synced"` convention, D-024 — 1.8 inherits it), F-015 (an F-number is a task id, so a finding
is startable exactly like a roadmap task), and F-007 (agents name themselves from their chat; no
`MIRE_AGENT`, no prefix, commits included). Practical effect on starting work: *"start 1.6"* and
*"fix F-004"* are now the same shape of instruction, and neither needs a name attached.

**Reading the table.** *Agent name* `auto` means the chat names itself on `agent start` (F-007) —
the named ones are historical, hand-assigned under the old scheme. *Model* and *Effort* are the only
things left for you to set, because they are set in the client before the chat starts and no script
can choose them: **Opus 5 · high** for anything that reasons about replication or lifecycle,
**Sonnet 5 · medium** where the work is mechanical and well-specified. The rows below are ordered by
what to start next, not by task number.

| # | Task | Agent name | Model | Effort | Status |
|---|---|---|---|---|---|
| **1.8** | Interest management — visibility filters, per-class intervals | `birch` | Opus 5 | high | **done and verified over a real wire.** `NetInterest` is the seam every replicated entity goes through — see below |
| **1.6** | Remote-player interpolation | `ash` | Opus 5 | high | **done and verified.** F-004's question answered as D-026: engine `physics_interpolation` does *not* cover it. See below |
| **1.7** | Connection lifecycle — mid-session join, disconnect, host quit, timeout | `reed` | Opus 5 | high | **done and verified over real multi-process ENet.** `NetSession` owns host admission and client-local LOCAL/LAN rejoin — see below |
| **1.11** | Protocol/build version handshake | auto | Sonnet 5 | medium | **done and wired through `NetSession`.** A mismatched build gets a readable refusal and leaves no player behind |
| 1.5 | Networked player — spawner + synchronizer | `spawn` | Opus 5 | high | **done** — runs; prompt kept for reference |
| 1.9 | Spike R1 — replication load | `load` | Opus 5 | high | **done — AMBER.** Read the verdict below before writing 1.8 |
| 1.10 | Network debug panel | `netui` | Sonnet 5 | medium | **done, wired, and reading real numbers** — F-013 closed, entity count live |
| 1.1 · 1.2 · 1.3 · 1.4 | GodotSteam · NetTransport · LOCAL loop · Steam lobby | | | | done and verified |
| 2.2 | Content framework | `content` | Sonnet 5 | medium | done — prompt kept for reference |

**1.6 took `project.godot`** and registered `NetInterp` with it; it is free again once 1.6 ships. It is
still the one file only one task at a time may hold, so claim it by name and check `agent board`
first. **Keep `NetInterp` after `PlayerNet` in `[autoload]`** (not "last" — eight gameplay autoloads
legitimately follow it now) — it resolves `PlayerNet` at `_ready()`, and autoload
order is load order. Two things wiring one cost us
already (`9f56451`): **an autoload script may not carry a `class_name` equal to its own singleton
name** — Godot rejects it as hiding the singleton and the autoload never registers — and **autoload
order is load order**: a script whose `_ready()` resolves `DebugOverlay`/`NetTransport`/`PlayerNet` by
bare identifier must be registered *after* them.

### What 1.7 shipped — one lifecycle policy above every transport

**`NetSession` is registered** between `NetTransport` and `DevLaunch`. `NetTransport` remains the
pipe; `NetSession` owns host-authoritative admission, player-facing end reasons, clean host shutdown,
and client-local rejoin policy. Mid-session roster replay remains `MultiplayerSpawner`'s job.

```gdscript
NetSession.end_session()                         # awaitable clean close; tells clients first
NetSession.refuse_peer(peer_id, detail)          # host-only readable refusal
NetSession.free_slots() -> int                   # host-side capacity remaining
NetSession.is_rejoining() -> bool
NetSession.capacity · accepting_joins · auto_rejoin

session_opened(is_host)
connection_interrupted(detail)
rejoin_attempted(attempt, of) · rejoined()
session_ended(reason, detail)                    # LOCAL_LEAVE / HOST_CLOSED / CONNECTION_LOST / REFUSED
peer_refused(peer_id, detail)                    # host-side
```

`NetTransport` gained the mechanism needed underneath: `last_end_kind()`, `has_rejoin_target()`,
`rejoin_last_target()`, `set_admission_gate()`, and `kick_peer()`. ENet accepts two short-lived
connections beyond game capacity so the host can say *why* it refused them (D-027), and dead-peer
timeouts are capped at 8 s. The lifecycle harness measured a killed client being detected and
despawned in **2.6 s** on this machine.

`tools/session_lifecycle_check.gd` is the real-process regression command. Its eight sections cover
autoload registration, host capacity, ordinary admission, over-capacity refusal without a spawn,
late joining with the complete roster, version mismatch cleanup, automatic rejoin after an unclean
drop, dead-process timeout, and clean host close without a rejoin loop. It completed 8/8 with zero
failures. LOCAL and LAN can retry their retained direct address; Steam requires asynchronous lobby
re-entry and deliberately does not pretend otherwise (F-020).

### What 1.6 leaves you — the smoothing seam, and the rule about who may read it

**`NetInterp` is registered** (`autoload/net_interp.gd`, last in the `[autoload]` list because it
resolves `PlayerNet`). It watches PlayerNet's `Players` container and gives every player this peer
does **not** own a `RemoteInterpolator`. Nothing else has to do anything: spawn a body under that
container and it is smoothed, or is skipped because it is yours. Offline it does nothing.

```gdscript
NetInterp.attach_to(body) -> bool        # give it an interpolator; false if it owns it / has no NetSync
NetInterp.interpolator_for(body) -> RemoteInterpolator
NetInterp.is_watching() -> bool          # false means "wiring is broken", not "netcode is broken"
NetInterp.debug_snapshot() -> Array[Dictionary]   # {peer, lag_ms, buffered} — 1.10's panel can read this
```

**`RemoteInterpolator` (`core/net/remote_interp.gd`) is entity-agnostic on purpose** — it is the
whole of F-004's answer for enemies (2.10) and props too, and it needs no new numbers for them
because it derives its delay from the *observed* arrival interval rather than being told the class
rate. 30 Hz players settle at ~67 ms, 15 Hz enemies at ~133 ms, automatically.

```gdscript
configure(target: Node3D, pitch_target: Node3D = null, sync: MultiplayerSynchronizer = null)
push_snapshot(position: Vector3, yaw: float, pitch: float)   # for a source that is not a synchronizer
reset()                                                       # after a teleport/respawn/level swap
lag_seconds() · buffered() · debug_stats()
```

Three things it would be expensive to rediscover:

1. **Nothing gameplay-authoritative may read an interpolated transform.** The interpolator overwrites
   `position`/`rotation.y` every rendered frame with a value ~67 ms in the past. It is attached only
   on the *receiving* side, so `player_net.gd`'s host speed check is unaffected today — but a future
   host-side check that runs on a client's copy of another client would be reading fiction. Read the
   synchronizer's value, or read it on the peer that owns it.
2. **It hooks `MultiplayerSynchronizer.synchronized`** and samples the node right after the engine
   writes to it, which is why 1.6 needed *no* change to `player_controller.gd` and added **nothing to
   the wire** — velocity is still deliberately absent (1.5's call stands; interpolation did not need
   it, and extrapolation derives it from the last two snapshots).
3. **`physics_interpolation_mode` is forced OFF on the subtree it drives**, and restored in
   `_exit_tree()`. D-026 says why: leaving it on makes the engine resample our per-frame output onto
   the 60 Hz grid and adds a tick of lag. If 1.7 ever detaches an interpolator on an authority change,
   free the node — don't just stop it — or that restore never runs.

`RemoteInterpolator` is a new `class_name`, so **F-016 applies to it**: both call sites `preload()`
the script instead of naming the class bare, and anything run via `--script` must keep doing that
until Sequoyah has opened the editor once since this landed.

**`tools/interp_check.gd`** is the fourth headless harness (`Godot --headless --path .
--script tools/interp_check.gd`, exits non-zero on failure, currently green). It measures judder as
*% of frames where the node visibly stopped*, and its control stream is read through
`get_global_transform_interpolated()` so the engine's own smoothing is included rather than being
handicapped. Numbers on this machine: **engine interpolation alone 67% still frames / CV 1.64 → plus
snapshot interpolation 1.5% / CV 0.21**, at a cost of ~67-84 ms of drawn latency. Extend it rather
than writing a fifth: phase A drives the interpolator directly with jitter and 6% loss (loopback has
neither), phase B checks a 100 m teleport snaps instead of smearing, phase C is two real ENet peers
and a real `player.tscn`.

### What 1.9 measured — 1.8 is now mandatory, and this is the budget it has to hit

**AMBER.** 6 real ENet peers, 200 host-authoritative entities, 60Hz paced:

| Configuration | Host up |
|---|---|
| Unfiltered, 30Hz | **918 KB/s** — 7.3× the 125 KB/s ceiling |
| §2.5 interest management, 30Hz | 105 KB/s |
| §2.5 interest management, 15Hz | 57 KB/s |

CPU never exceeded 1.18 ms of a 16.67 ms frame on any peer, so replication is **bandwidth-bound, not
CPU-bound** — do not optimize 1.6/1.8 for CPU. Wire cost is 30.5 B per entity per update per client
to carry 16 B of real state, so §6 R1's hand-rolled-binary fallback could buy at most 1.9× where
filtering buys 8.8–16×: **the fallback is not needed, and 1.8 is what makes M1 fit.**

One unexplained result 1.8 must budget for: filtering was *cheaper* with players clustered (100 KB/s)
than spread (180 KB/s) at an identical 11.6% visible fraction, and the extra cost is reliable-channel
traffic (~2× host ACK volume). That points at visibility churn — an entity crossing the 120 m boundary
forces a despawn+respawn per peer. Not isolated. **1.8 should assume churn is real and consider
hysteresis** (leave-radius larger than enter-radius) so boundary-hugging entities don't flap.

**F-013 is closed, and 1.8 inherits its answer.** The convention is settled as **D-024**: the
`&"synced"` group holds *every `MultiplayerSynchronizer`, one member each* — it counts update streams,
because that is what maps to the bandwidth budget above. The name lives once as
`NetConfig.SYNCED_GROUP` and is joined at construction, next to the authority assignment; 1.8's
per-class synchronizers just do the same and the panel's count stays meaningful.

### What 1.8 shipped — every replicated entity from here on goes through one call

`core/net/net_interest.gd`, `class_name NetInterest`. **Not an autoload**, so it costs nobody a
`project.godot` claim, and the observer registry is `static` because the filter runs once per entity
per peer per physics tick — 1.9's shape is 1000 calls a tick, which must not resolve a singleton or
walk the tree to answer.

```gdscript
# In the entity's _ready(), where authority is set, BEFORE add_child() (F-012):
sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
NetInterest.configure(sync, self, NetInterest.Class.ENEMY)   # returns the filter, or null
add_child(sync)
```

`configure()` is the only seam, and it does three things so a construction site cannot half-opt-in:
sets `replication_interval` and `delta_interval` from the class, joins `NetConfig.SYNCED_GROUP`
(D-024 — nothing else joins it any more, including `PlayerController`), and installs the distance
filter for the filtered classes. The numbers live in `NetConfig`, not in `NetInterest`.

| `NetInterest.Class` | interval | delta | filtered | for |
|---|---|---|---|---|
| `PLAYER` | 30 Hz | 30 Hz | **no** | six of them; a teammate vanishing at 121 m is a bug report |
| `ENEMY` | 15 Hz | 15 Hz | yes | host-simulated, many, 15 Hz + interpolation is indistinguishable |
| `PROP` | 1 s | 100 ms | yes | on-change only — the 1 s interval is a cheap ceiling on a mistake, not a rate |

Observers — where each peer looks from — are pushed by `autoload/player_net.gd:_publish_observers()`,
every physics tick, **host only**, because every filtered row of §2.2 is host-authoritative. If a
client ever owns something filtered, that is the line to move. `NetInterest.clear_observer(peer)` on
despawn and `clear_observers()` on disconnect are already wired.

**D-025 settles the two calls that look like tuning and aren't:** two radii instead of one (enter
120 m / leave 144 m, so a boundary-hugging entity does not pay a despawn+respawn per peer per tick —
this is the churn 1.9 could only infer from reliable-channel volume), and
`VISIBILITY_PROCESS_PHYSICS` instead of `IDLE`, because re-evaluation rate *is* bandwidth and §5a
forbids hanging that off the render frame. `RadiusFilter.transitions` counts churn if you want to
measure rather than infer it.

**Two API facts worth not rediscovering.** `MultiplayerSynchronizer` in 4.7.1 has **no**
`is_visible_to()`; `get_visibility_for()` reads back only the *manual* `set_visibility_for()`
override, never the filter's answer, and `update_visibility()` pushes straight into the replicator,
which needs a live session. So there is no offline way to ask the engine what a filter decided —
proving the engine calls your filter at all requires real peers. And `replication_interval = 0.0`
means *every frame*, not "never", which is why `PROP` is 1 s.

### Headless verification you inherit — extend these rather than writing a fourth harness

All three run without an editor, exit non-zero on failure, and are the pattern 1.6/1.7/1.8 should
copy. **Verify your own work with them; do not ask Sequoyah to press Play and report back.**

| Tool | What it proves | Command |
|---|---|---|
| `tools/synced_group_check.gd` | Every synchronizer construction site joins `&"synced"` — builds both for real and reads the live tree back | `Godot --headless --path . --script tools/synced_group_check.gd` |
| `tools/net_debug_panel_check.gd` | The panel's 19 checks, including a real ENet host+client session with genuine RTT and bandwidth | same form |
| `tools/bench_replication.gd` | 1.9's spike: 6 peers, 200 entities, interest management on and off | same form |
| `tools/interest_check.gd` | 1.8's 40 checks: per-class intervals, hysteresis in both directions, and a live 1-host/2-client ENet session where moving one observer makes the entity appear and disappear on that client only | same form |

Two process notes that cost time when they were learned: a `--script` main loop compiles before
autoloads register, so `load()` them at runtime rather than preloading at class scope (**F-011**); and
nodes added in `_initialize()` have not run `_ready()` yet, so anything a node builds for itself must
be checked on the next frame via `call_deferred`.

Three more, all paid for on 2026-08-16:

- **A new `class_name` resolves nowhere until you rebuild the class cache** (**F-016**, hit
  independently by 1.8 and 1.11). `.godot/global_script_class_cache.cfg` is gitignored and only the
  editor's project scan writes it, so a brand-new global class is "not declared in the current scope"
  in every headless run *and* in the game itself. Fix, once, no editor window:
  `Godot --headless --path . --import`. It also generates the new script's `.uid` (**F-017**).
- **Do not pace a two-process game run with `--fixed-fps`.** It pins the *delta*, not the wall clock,
  so 420 "seconds" of simulation elapse in a fraction of a real one and the ENet handshake never gets
  time to happen — the client just sits on "connecting" and quits. `--max-fps 60 --quit-after 900`
  paces against the real clock and connects reliably.
- **A script error inside an `await`ed harness coroutine kills only that coroutine.** The run
  continues and prints `PASS` over whatever checks happened to have already run. `interest_check.gd`
  guards against that with a section counter asserted at the end; copy it.

### What 1.5 established — write 1.6, 1.7 and 1.8 against this, not against a guess

Node layout, built in code by `autoload/player_net.gd` and identical on every peer. The names are
load-bearing: the high-level API matches nodes by path.

```
/root/PlayerNet
  ├── Players                 Node3D                 every networked player lives here
  │     ├── "1"               PlayerController       named for the peer id that OWNS it
  │     │     ├── CollisionShape3D
  │     │     ├── CameraPivot  ├── Camera3D
  │     │     └── NetSync      MultiplayerSynchronizer — authority = owning peer, 30Hz
  │     └── "1210651288"      PlayerController       (ENet ids are random, not 2/3/4)
  └── PlayerSpawner           MultiplayerSpawner, spawn_path → ../Players
```

Replicated today, and nothing else: `.:position`, `.:rotation:y` (body yaw),
`CameraPivot:rotation:x` (head pitch). **Velocity is deliberately absent** — if 1.6 needs it for
interpolation, 1.6 adds it and pays for it.

Read the tree through `PlayerNet`'s public API rather than by path, so the paths stay ours to change:
`player_for(peer_id) -> Node3D` · `spawned_peers() -> PackedInt32Array` ·
`debug_snapshot() -> Array[Dictionary]`. `PlayerController` exposes `net_sync` and `is_local_authority`.

**Authority is derived from the node's NAME, not replicated.** The spawn function names each player
for its peer and sets authority before `add_child()`; `PlayerController._ready()` re-derives the same
value from that name. Both sides therefore agree with nothing extra on the wire — and a player node
named anything non-numeric (the level's hand-placed `Player`, or anything offline) is left alone,
which is why "press Play and walk around" still works with no session.

Three traps 1.6/1.8 will hit, all of them already paid for once: **F-012** (a synchronizer's authority
must be set *before* `add_child()`, or every client logs "no network ID" and state degrades silently),
**F-011** (autoloads are not compile-time identifiers in a `--script` harness), and **F-013** (spawned
synchronizers are not yet in group `&"synced"`, so 1.10's entity count reads 0).

### 1.5–1.8 were unblocked by D-023

They sat here for three sessions as *"Scene work, which only Sequoyah can wire — a spec conversation,
not a prompt."* That was wrong, and the correction is **D-023**: `MultiplayerSpawner`,
`MultiplayerSynchronizer` and `SceneReplicationConfig` all have complete script APIs, so they get
**built in code**, never authored in a scene. Task 1.9's prompt had already been requiring exactly that
for months of calendar-free session time — a headless benchmark can't author scenes either — so the
technique was proven in this repo before it was ever written down as a rule.

Consequence for the prompts below: **1.5 needs no `.tscn` change at all.** Read D-023 before writing
any further replication prompt, and don't reintroduce "tell Sequoyah to add a synchronizer node".

### Blocked, and why — so nobody writes a prompt that gets rejected at commit

| # | Blocked on | Clears when |
|---|---|---|
| 1.6 · 1.7 · 1.8 · 1.11 | ~~1.5~~ **Nothing. All four are writable now** against the layout above | cleared by `8d6ddab` |
| 1.12 | ~~Windows guest~~ **Nothing technical.** The physical Windows PC passed the pinned determinism probes; the Linux KVM guest exists. | Run the simultaneous Steam session in `docs/STEAM_CROSS_PLATFORM_TEST.md` |
| 4.0b | ~~A Windows guest existing at all~~ **done** | closed by `aa2efb2` |

The foundation is settled: `NetTransport` (1.2), `DevLaunch` (1.3), `SteamLobby` (1.4) and GodotSteam
4.21 (1.1) are all registered, booting and verified, so every prompt here is written against a real API
rather than a proposed one.

**1.12 test driver:** `DevLaunch` accepts debug-only `--steam-host` and
`--steam-join=<lobby_id>` arguments. They call the normal asynchronous `SteamLobby` flow, not
`NetTransport` directly, so lobby membership and Steam P2P start in the only supported order. The
complete three-machine commands, fresh-clone addon/import prerequisite, observed-state checks, and
PASS/FAIL/BLOCKED criteria are in `docs/STEAM_CROSS_PLATFORM_TEST.md`.

M0 is closed. The 0.7 and 0.8 spike prompts that used to live here shipped in `9a1bc19` / `9ebe47b` —
their results are D-015 and D-016 in `DECISIONS.md`. The unmeasured half of R2 is now task `4.0a`.

### 2026-08-18 — F-058/F-059/F-060 renumbered to F-092/F-093/F-094 (F-087); the originals are unchanged

If you're reading an old note (or a commit message) that cites **F-059** or **F-060** for something
art-pipeline-shaped — `mire_art.mat()`'s cache, or a headless `--script` run not re-importing changed
assets, or `mire_art.world_bounds` — that finding is now **F-093** and **F-094** respectively
(`mire_art.mat()`'s cache is **F-092**, was F-058). Nothing about **the originals** changed: F-059 is
still `InventoryService._publish_snapshot`'s unguarded `rpc_id` (cited by `983da6c`), F-060 is still
the two-process net-check authoring traps (cited by `adfaa78`, `abcf9bd`) — every mention of F-059/
F-060 elsewhere in this file is about those and needed no edit.

Three lanes had each read `agent brief`'s "next number" before another had written, so those three
numbers each named two unrelated findings — one Resolved and cited by a shipped commit, one still
Open. `agent brief`/`claim` picked one arbitrarily and `agent start`/`board` reported the Open one as
already closed. Full writeup and verification: `docs/FINDINGS.md` F-087 (Resolved).

New standing check: `agent godot --script tools/findings_numbering_check.gd` source-scans
`docs/FINDINGS.md` and fails if any F-number heads two different `## Open` entries, or heads an
`## Open` entry and a different `## Resolved` entry — the two collision shapes this finding fixed.
It does not flag same-number entries that are both Resolved (no routing risk, left as historical
record on purpose per F-087/F-052).

### 2026-08-18 — `mire_art.mat()`'s cache guard has a regression check now (F-092)

New standing check: `/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/mat_cache_check.py` — the first focused check for `tools/blender/mire_art.py`. It is a
Blender background script, not a Godot one; `mire_art` is never Godot-reachable, so `agent godot`
does not apply and there is no shared lock to take (Blender's own process is the whole run). Exercises
`mat(token)` called repeatedly from inside a loop rather than hoisted into a `mats = {...}` dict once
per build — the shape that hid F-092 in the four originally migrated kits and the shape any new
generator will naturally reach for — and asserts one material minted per token no matter how many
times it's asked for, a `suffix` variant is an independent cache entry, and a datablock removed out
from under `_MATERIAL_CACHE` (e.g. a scene wipe that didn't call `reset_materials()`) is rebuilt
rather than returned dangling or raised. Any new `build_*.py` generator that calls `mat()` inside a
loop can lean on this instead of writing its own cache-hit assertion. Full writeup and verification:
`docs/FINDINGS.md` F-092 (Resolved), `docs/SPECS.md` F-092.

### 2026-08-18 — `CommandService`'s `peer` arg stays id-only; no display-name registry exists anywhere yet (F-126/D-098/F-157)

`autoload/command_service.gd`'s `_parse_peer()` is still exactly what it was: a positive-int
validator, deliberately not requiring the id to be currently connected (D-078). `docs/COMMANDS.md`
§2.2's "or player display name" half has nothing to resolve against — **no system in the project
tracks a peer id → display name map**, checked project-wide while closing F-126 (`NetTransport`
tracks bare ids only; `SteamLobby._persona()` resolves a Steam persona name per lobby *member*,
keyed by Steam id, which is a different key than the in-session net peer id every other system uses,
and it doesn't exist in LOCAL/LAN at all). D-098 records why this was not built inside F-126: the
finding's own text says `_parse_peer` should consume a registry another system owns, not invent one,
and building the LOCAL/LAN name source honestly needs a new client→host RPC — which per this file's
own standing rule requires bumping `PROTOCOL_VERSION` in `core/net/net_version.gd`.

**If your task is the one that adds player display names for its own reasons** (a lobby roster
label, a kill-feed name, or finally making `give bob 5` work) — F-157 has the shape already scoped:
own a single canonical peer id → name map in `NetTransport` (it already has the right lifecycle hooks
— `_peers`, `_track_peer`/`_add_peer`, `peer_joined`/`peer_left` — and the right key, unlike
`SteamLobby`), thread `SteamLobby._persona()` through for STEAM mode, add a client→host RPC for
LOCAL/LAN (bump the protocol, extend `tools/handshake_check.gd` per the standing rule), then give
`_parse_peer()` a two-line addition to resolve a non-numeric token against it before failing.
`tools/command_check.gd`'s "peer arg type" section already pins the id-only behavior you'd be
changing, so failing assertions there tell you exactly what moved.

Full writeup: `docs/FINDINGS.md` F-126 (Resolved) and F-157 (Open), `docs/DECISIONS.md` D-098,
`docs/SPECS.md` F-126.

### 2026-08-18 — enemy render LOD (task 7.7): a visibility-range self-fade, `Enemy.VISIBILITY_RANGE_END_M`/`VISIBILITY_RANGE_FADE_MARGIN_M`

`systems/enemies/enemy.gd`'s `_build_visual()` now sets `visibility_range_end = 90.0`,
`visibility_range_end_margin = 8.0`, and `visibility_range_fade_mode =
GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF` on every `MeshInstance3D` it finds under an enemy's
instantiated visual — both constants live on `Enemy` (`VISIBILITY_RANGE_END_M`,
`VISIBILITY_RANGE_FADE_MARGIN_M`) as the single place to retune them. This is deliberately separate
from F-144's prop/harvestable/undergrowth LOD+batching work: an enemy's mesh is per-instance and
independently animated, so it can never be merged the way F-144 merges static props — visibility-range
fade is the only lever that applies here. D-115/F-174/`docs/SPECS.md` §7.7 have the full reasoning
and the 90 m choice's justification against `EnemyDef.deaggro_radius_m`.

**For whoever tunes graphics presets next:** this is currently a fixed constant, not wired into
`GraphicsQuality`'s low/medium/high presets the way undergrowth density and shadow distance are
(`autoload/graphics_quality.gd`, held by F-144 for the whole of this task's session so it could not be
touched here). A preset-aware enemy LOD range (tighter on `low`, per D-055's pattern) is a natural
follow-up once F-144 releases that file — there is no finding number for this because it is a nice-to-
have, not a gap, but the seam (`Enemy.VISIBILITY_RANGE_END_M`) is public and ready for a setter.

**Verify:** `tools/enemy_lod_check.gd` (new) spawns every enemy def in `content/enemies/` through the
real `EnemyWorld.host_spawn()` and asserts the three properties above on every mesh found. `.agent/
bin/agent godot --script tools/enemy_lod_check.gd` → 0 failures. `tools/wave_spawner_check.gd`
(exercises the same spawn/despawn path heavily) stays green — no regression.

### 2026-08-19 — F-159 fixed: `NavBaker` now bakes placed buildables around, not through — but the LIVE game does not run `NavBaker` yet

`world/chunk/nav_baker.gd` — task 4.5's per-chunk baker — now connects directly to `BuildService`'s
`piece_placed`/`piece_destroyed` signals inside `bind()` (autoload-to-autoload, the same pattern
`BuildService._wire_mire_grid()` already uses) and tracks every placed piece as `{coord, position,
yaw, size}` (`size` read from its `BuildableDef` via `/root/Registry` — the same field `BuildService.
_generated_piece()` builds its physics collider from). `_source_geometry(coord)` folds each tracked
piece into the SAME `NavigationMeshSourceGeometryData3D` as that chunk's terrain faces before baking —
has to be one combined pass, since Recast carves a hole around solid geometry by seeing it alongside
whatever it's carving; two independently-baked regions cannot composite into that result.

**New public surface:**

```gdscript
baker.tracked_piece_count() -> int          # how many pieces NavBaker currently has geometry for
NavBaker._box_faces(local_origin, yaw, size) -> PackedVector3Array   # static; 12 Recast-wound
                                                                       # triangles for one piece's box
```

`_box_faces()` builds a closed box with one consistent outward-normal winding across all six faces,
then runs the WHOLE buffer through the file's own `_wound_for_recast()` (now `static`, so this can
call it) — reusing that function is what keeps every face correctly wound without re-deriving §6 trap
1's inverted convention by hand per face. Copy this shape for any future non-terrain source geometry
this file grows.

**Invalidation:** placing/destroying a piece calls new `_rebake_chunk(coord)`, which re-queues a chunk
that already has a region — the opposite of `request_bake()`'s existing dedupe guard, which exists to
ignore a REDUNDANT `chunk_mesh_ready` for a chunk whose region is already correct. `_attach()` now
frees a stale region before replacing it, so a rebake targeting an already-attached coord cannot leak
the old RID or leave two regions on the map at once.

`autoload/build_service.gd`'s `piece_destroyed` signal widened from `(def_id, owner_peer_id)` to
`(def_id, owner_peer_id, piece_name, position)` — its node is already freed by the time the signal
fires, so a listener that needs to find the piece's chunk (this one) needs both handed over rather
than looked up. No existing listener connected to the old signature.

**The gap this does NOT close:** `NavBaker` is not wired into the live game — nothing instantiates a
`ChunkStreamer` in the actual playable level yet (F-139), so `bind()` is only ever called from `tools/
nav_bake_check.gd`. The baker the shipped game runs today is `EnemyWorld.bake_navigation()`, which
still has F-159's original gap untouched — filed separately as **F-177**, since fixing it needs
`autoload/enemy_world.gd`, held by another lane (`lp`, task 5.5) for this entire session. Whoever wires
a live `ChunkStreamer`/`NavBaker` pair (F-139) retires `EnemyWorld.bake_navigation()` in `NavBaker`'s
favor and F-177 closes as a side effect — this fix is already sitting there waiting. Full reasoning:
`docs/SPECS.md`'s F-159 block, `docs/DECISIONS.md` D-118.

**Verify:** `tools/nav_bake_check.gd`, new `_check_buildable_obstruction()` — 0 failures, run twice.
No regressions: `build_check.gd`, `build_net_check.gd`, `combat_check.gd` all `failures=0`.

---

### 2026-08-19 — Player display names: `NetTransport` owns the registry, `CommandService._parse_peer()` consumes it (F-157, closes F-126/D-098's deferred half)

`NetTransport` now holds the canonical peer id → display name map F-126/D-098 said belonged there.
Public API, all on the `NetTransport` autoload:

- `display_name(peer_id: int) -> String` — that peer's name, or a `"Player N"` placeholder if it has
  none yet (in flight, or nobody ever named it — offline/solo included).
- `display_names() -> Dictionary` — the whole map as this process currently knows it. The HOST's copy
  is authoritative; every other peer's is a mirror kept current by the two RPCs below, so a caller
  wanting a snapshot for its own UI (a lobby roster, a kill-feed) can read this on ANY peer, not just
  the host.
- `submit_display_name(name: String) -> void` — set/change THIS process's own name. `host()`/the
  client's `connected_to_host` handler already call it once with a computed default (STEAM: threads
  through `SteamLobby.local_persona_name()`, new this task, `_persona(local_steam_id())` under a
  not-yet-initialised guard; LOCAL/LAN: `OS.get_environment("USERNAME")`/`"USER"`). **No name-entry UI
  exists yet** — a future settings/lobby screen calls this again with whatever the player typed; there
  is nothing else to wire.
- `display_name_changed(peer_id: int, display_name: String)` signal — fires on every peer whenever an
  entry in the map changes, same shape as the existing `peer_joined`/`peer_left`.

Wire shape: `net_request_display_name` (client → host, one raw String — sanitized ONLY on the host,
`_sanitize_display_name()`: strip control chars, trim, cap at 24, empty → `"Player N"`),
`net_display_name_changed` (host → every remote peer, one id + its sanitized result — reaches the
peer being renamed too, since its own mirror needs the SANITIZED value, which may differ from what it
sent), `net_display_name_snapshot` (host → one newly admitted peer, the full map, sent from `_add_peer`
right when the host admits them — so a joiner sees existing names without waiting on a resubmit).

**Two peers may share a name — the registry does not dedupe.** `CommandService._resolve_peer_by_name()`
(new, the name half of `_parse_peer()` docs/COMMANDS.md §2.2 always specified) does an exact
case-insensitive match; zero matches refuses `"no peer named '<x>'"`, more than one refuses and lists
every candidate peer id (`"'<x>' matches more than one peer (1, 4821771) — use their peer id"`), never
guesses. Full reasoning: `docs/DECISIONS.md` D-120.

**Ships without a `PROTOCOL_VERSION` bump** — `core/net/net_version.gd`/`tools/handshake_check.gd` were
held by another lane's claim (`slate17`, 3.7) for this task's whole session, the same recurring gap
D-102/F-161/F-165/F-169 already hit. Filed as **F-178**, continuing that chain.

**Also touched:** `ui/debug/net_debug_panel.gd` — the session line and join/left log lines now show
`id(name)` instead of a bare id, one of the two consumers F-157's own text named as still printing raw
ids with nothing to resolve against.

**Verify:** `agent godot --script tools/display_name_check.gd` — new file, real two-process ENet round
trip (submission → sanitized broadcast → snapshot → name-based `op` resolution, case-insensitive →
ambiguous-match refusal), 11/11 PASS. `tools/command_check.gd`'s "peer arg type" section updated for
the new refusal wording, `COMMAND_CHECK failures=0`. Regression: `command_net_check.gd`,
`net_debug_panel_check.gd`, `verify_setup.gd` all clean.

### 2026-08-19 — F-177 fixed: `EnemyWorld.bake_navigation()` (the LIVE nav baker) now also sees placed buildables

`autoload/enemy_world.gd`'s `bake_navigation()` still parses `get_tree().current_scene` first, exactly
as before. It now ALSO parses `/root/BuildService/Buildings` (`BuildService`'s placed-piece
container — a sibling of the level under `/root`, never a descendant of `scene_root`, which is the
whole reason this was invisible before) into a second `NavigationMeshSourceGeometryData3D`, and
`.merge()`s that into the first BEFORE the one `bake_from_source_geometry_data()` call. No new public
API — same `bake_navigation() -> Node` signature, same call sites (`_physics_process()`'s bootstrap
path, `BuildService._request_nav_rebake()`'s debounced re-trigger). `world/chunk/nav_baker.gd`
(F-159/task 4.5) is untouched and still carries its own independent fix for whenever F-139 wires a
live `ChunkStreamer` and retires this file's bake in `NavBaker`'s favor — `docs/DECISIONS.md` D-121
has the full reasoning for why this fix is a second parse-and-merge rather than a port of `NavBaker`'s
per-piece box-tracking approach.

**For whoever adds the next non-scene-tree geometry source to this bake:** the pattern is `parse_source_
geometry_data(nav_mesh, a_fresh_geometry_object, some_other_root)` then `first_geometry.merge(a_fresh_
geometry_object)`, repeated once per extra root, all before the single `bake_from_source_geometry_data()`
call — never a second bake, and never feed a second root into the SAME geometry object `scene_root`
already populated (untested here whether `parse_source_geometry_data` clears an already-populated
target; `merge()` is the documented way two separately-parsed sets combine).

**A general Recast/Godot caveat this task's own check ran into, worth knowing before trusting a
`map_get_closest_point()` assertion near a newly-placed obstacle:** a box resting exactly flush on a
perfectly flat surface (its bottom face height coincident with the floor's top) can leave a tiny
disconnected walkable "island" polygon surviving at the box's own centre — reproduced with both a
two-parse-and-merge bake and a single combined parse over one shared root, so it is a property of the
coincident-height geometry Recast rasterizes, not of how this fix merges source data. The island
shares no polygon edge with the rest of the map, so `NavigationServer3D.map_get_path()` never actually
routes across it — a path-based assertion (query a route from one side of the obstacle to the other,
assert it detours) is the reliable proof; a point-snap query at the obstacle's exact centre is not.

**Verify:** `agent godot --script tools/nav_bake_check.gd` → `NAV_BAKE_CHECK failures=0`, run twice.
New `_check_enemy_world_buildable_obstruction()`: a real `BuildService.request_place()` round trip
puts a `ward` across a route the live baker just baked; `map_get_path()` between the same two points
goes from a straight 6.000 m / 3 waypoints to a 7.525 m / 5-waypoint detour once the piece lands, and
back to the straight line after `request_destroy()`. No regressions: `build_check.gd`,
`build_net_check.gd` (real two-process ENet), `combat_check.gd`, `enemy_check.gd`, all `failures=0`.

---

### 2026-08-19 — F-146 fixed: `ChestPlacementService` gives every authored `loot` marker a live `Chest`, and the gilded tier finally has its 1-2/island budget

**What shipped, verified:** `autoload/chest_placement_service.gd` — a runtime bridge, same split
`wellspring_service.gd`/`crafting_service.gd` already use for `authored_world.gd`'s other marker
kinds. Registered via `agent autoload` (F-051), append-only in `project.godot`.

```gdscript
# authored_world_marker (kind == "loot"), name-keyed — the ONLY input this bridge reads:
#   "Cache_<n>"        -> Chest.tier = &"small",  cost_coins = 0,  locked_by = &""
#   "Chest_<tier>_<n>" -> Chest.tier = &"<tier>",  cost_coins/locked_by from _ECONOMY_FOR_TIER
# Any other loot marker, or any other marker kind, is left alone.
```

**The 8 shipped `Cache_` markers now do something.** They have existed since task 4.7-era authoring
(`tools/mapgen/hollowmere_layout.py`'s "waymarks and loot worth walking to" loop) as a decorative
`loot_chest_small_closed` prop plus an inert marker — this bridge is their first live gameplay
consumer, no map content changed to get it.

**The gilded budget:** `tools/mapgen/hollowmere_layout.py` gained `build_gilded_chests()` — 2 new
`"Chest_gilded_<n>"` markers, `SouthMarsh` and `StoneMoor`, placed through the ordinary
slope/water/clearance/road rules (not forced). `validate()` re-derives the count from `markers`
itself and fails the generator build outside 1-2 — `world/gen/layouts/hollowmere.json` regenerated,
deterministic (byte-identical on a second run). No gilded-tier mesh exists yet (A-047 still queued,
`docs/ITEMS.md` §7), so these placeholder as `loot_chest_reinforced_closed` until real art lands —
swap the asset in the JSON, nothing about the marker or the bridge needs to change.

**Economy per tier — `D-122` has the full reasoning:** `Chest` charges `cost_coins` AND
`locked_by` together in one transaction, never either/or, so a placed instance can only express ONE
gate even where `docs/ITEMS.md` describes two. Gilded is key-only (`gilded_key`, no coin price — the
item catalog's own line is unambiguous). Bog (25 coins) and strongbox (60 coins) are coin-gated —
their own key alternative (a Rusted Key opening a strongbox for free) is a legitimate SECOND
placed instance for whoever gives those tiers real map markers, not a mode this table needs to also
support. Sunken has neither (unpriced, unlocked) — it is "risk-priced rather than coin-priced" per
ITEMS.md §5, and this bridge does not place sunken chests at all yet; no hazard-placement pass picks
real coordinates for it.

**What the next task builds against:** placing a NEW chest tier in Hollowmere (bog, strongbox,
sunken, or a second landmark of an existing tier) needs exactly one marker,
`_marker(f"Chest_{tier}_{n}", "loot", x, y, z, zone)`, added anywhere in
`tools/mapgen/hollowmere_layout.py` and a regenerated `hollowmere.json` — `ChestPlacementService`
picks it up automatically, no autoload/script change required. A tier with no entry in
`_ECONOMY_FOR_TIER` still builds (falls back to free/unlocked), so a new marker is never silently
dropped; it is just unpriced until its economy is added to the table.

**Left open, filed as F-183:** `wellspring`/`boss` tier chests are event-granted (a Wellspring cap, a
boss kill), not world-scattered — a Wellspring cap does not currently spawn or open any `Chest` at
all, and neither does a boss kill. Genuinely a different owner than "placement", and out of F-146's
scope, but still nobody's job today.

**Verify:** `agent godot --script tools/chest_placement_check.gd` → `failures=0`, run twice, against
the REAL `main_scene` boot (not a synthetic scene) — all 8 `Cache_` markers bridged, gilded count
in budget, a live free chest opens end to end, a live gilded chest is refused without the key.
`python3 tools/mapgen/hollowmere_layout.py` → `HOLLOWMERE_VALIDATE PASS`. `agent godot --quit-after
120` → clean boot, no new `ERROR:` lines. `tools/chest_check.gd`, `tools/loot_content_check.gd`,
`tools/entity_check.gd` unaffected (`chest.gd` itself was not touched).

---

> **Historical documents — every task prompt from here down.** They predate D-021 (agents register
> their own autoloads), D-031 (agents may edit Godot-authored files under exact claim), D-039 (do it
> yourself rather than handing it back) and the D-036 lane system. Where a prompt says
> `.tscn`/`.tres`/`project.godot` are human-only or hook-blocked — and several do, in those words —
> that was true when it ran and is **not policy now**. `AGENTS.md` Hard rules and `docs/SPECS.md`
> are current. The disclaimer used to sit further down, below three prompts that make exactly that
> stale claim (F-045/F-053).

## Task 1.5 — Networked player: spawner + synchronizer, client-auth movement ✅ **DONE**

> **Model: Opus 5 · effort high** · agent name `spawn`
> **Shipped 2026-08-16 in `8d6ddab`. Do not paste this.** It runs — `PlayerNet` registered
> itself, no scene work was needed, and D-023 held: every replication node is built in code.
> The layout it established, and the traps it paid for, are in *Current state* above; the
> prompt is kept as the worked example of a replication-shaped brief, since 1.6, 1.7 and 1.8
> are all the same shape.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first — it is
the protocol every agent here follows. Then read docs/DECISIONS.md D-023, which is the
decision this task exists under. Then:

    MIRE_AGENT=spawn .agent/bin/agent start spawn
    MIRE_AGENT=spawn .agent/bin/agent claim 1.5 autoload/player_net.gd entities/player/player_controller.gd core/net/net_config.gd project.godot

Keep the MIRE_AGENT=spawn prefix on EVERY .agent/bin/agent command AND on `git commit`. Do
not use `export` — each shell call is a fresh process, so the value is lost and your claims
get filed under the wrong agent with no error. `agent ship` handles this itself.

TASK: One player per peer, spawned by the host, moving under its owner's control, visible to
everyone else. Two windows, two players, each drives their own and sees the other move.

AUTHORITY (docs/ARCHITECTURE.md §2.2, rows 1 and 2):
  Own player movement      → CLIENT-authoritative. The owning peer simulates locally and
                             sends its transform. Responsiveness beats anti-cheat here; these
                             are friends.
  Other players' movement  → host relays, MultiplayerSynchronizer + interpolation. Remote
                             copies run NO input and NO physics — they are moved purely by
                             replication. (Interpolation itself is task 1.6, not yours.)
  Spawning                 → HOST. Only the host decides a player exists. Clients receive.

WHAT ALREADY EXISTS — use it, do not rebuild it:

  NetTransport, a registered verified autoload (task 1.2). Query it; never touch
  multiplayer.multiplayer_peer yourself:
    func is_host() -> bool              # NOT multiplayer.is_server() — read that method's note
    func local_peer_id() -> int         # 0 when offline
    func peer_ids() -> PackedInt32Array # everyone INCLUDING us, ascending, host first
    func is_active() -> bool
    signal peer_joined(peer_id: int) / peer_left(peer_id: int)
    signal server_started() / connected_to_host() / disconnected()
  Contract worth knowing: the local peer never produces peer_joined. You learn you are in a
  session from server_started (host) or connected_to_host (client), and peer_joined is remote
  peers only. disconnected fires exactly once when an established session ends, any reason.

  NetConfig — a class_name, NOT an autoload. NetConfig.MAX_PLAYERS = 6,
  NetConfig.HOST_PEER_ID = 1, NetConfig.LOG_CHANNEL = &"net".

  PlayerController (entities/player/player_controller.gd) — CharacterBody3D, first-person
  walk/sprint/jump, already written and tuned. It ALREADY has the authority seam you need:
    var is_local_authority: bool = true      # set from is_multiplayer_authority() in _ready()
    @onready var camera: PlayerCamera = $CameraPivot
  and _ready() already gates camera.set_active(), set_physics_process() and
  set_process_unhandled_input() on it. Do not restructure that. Body yaw is on the
  CharacterBody3D; only pitch is on CameraPivot (see player_camera.gd) — so a remote player
  facing the right way needs the body's rotation, and its head angle needs the pivot's.

  entities/player/player.tscn — root "Player" (CharacterBody3D) > CollisionShape3D,
  CameraPivot (Node3D) > Camera3D. That is the whole scene.

  DevLaunch (core/dev/dev_launch.gd, task 1.3) — `--host` / `--client` user args auto-host or
  auto-join a LOCAL session at startup, with a bounded retry. This is how you test. Read it;
  it is one of the two files worth opening.

  MireLog statics: MireLog.info/warn/error/debug(channel: StringName, message: String).

WRITE / EDIT EXACTLY THESE:

1. autoload/player_net.gd — NEW. The spawner. Register it in project.godot as PlayerNet
   (see AUTOLOAD below). It owns:
     - a MultiplayerSpawner built IN CODE, plus a container node, at fixed paths
       /root/PlayerNet/PlayerSpawner and /root/PlayerNet/Players. Fixed because the high-level
       API matches nodes by path across peers, and because M4 swaps levels underneath this.
     - spawn on session start: host spawns one player per peer in NetTransport.peer_ids(),
       then one more on each peer_joined; frees on peer_left; clears everything on
       disconnected. (Mid-session join edge cases, host-quit and timeouts are task 1.7 — do
       the obvious signal handling, don't build a lifecycle system.)
     - a public read API for 1.6/1.7/1.10 to use rather than reaching into the tree:
       something like player_for(peer_id: int) -> Node3D and spawned_peers() -> PackedInt32Array.
     - offline behaviour: does NOTHING. No session, no spawning. "Open the project and press
       Play and walk around" must still work exactly as it does today.

2. entities/player/player_controller.gd — EDIT. Build its MultiplayerSynchronizer and
   SceneReplicationConfig in code in _ready(), identically on every peer, so the paths match.
   Replicate the minimum that makes a remote player look right:
       position, body rotation (yaw), CameraPivot rotation (pitch)
   and NOTHING else. Per §2.5, players sync at 30Hz — set replication_interval accordingly,
   and put the number in NetConfig as a named constant rather than a literal. Do NOT replicate
   velocity "for 1.6" — if 1.6 needs it, 1.6 adds it and pays for it then.

3. core/net/net_config.gd — EDIT, constants only. The sync rate, and the spawn-node names if
   you want them named once. Nothing with logic; read that file's header.

4. project.godot — EDIT, to register PlayerNet. Append only.

THE FOUR THINGS THAT WILL BITE YOU — all four are the actual content of this task:

  a) AUTHORITY MUST BE SET BEFORE add_child(). PlayerController._ready() reads
     is_multiplayer_authority() and immediately decides whether to run physics, capture the
     mouse and activate the camera. Set the owning peer as authority on the instance BEFORE it
     enters the tree, or every client runs input on every player and captures the mouse for
     six of them. If a spawn path makes that impossible, make the controller re-evaluate on an
     authority-changed signal rather than papering over it.

  b) THE LEVEL HAS A PLAYER IN IT ALREADY. levels/greybox_test.tscn hard-instances one
     "Player" at the scene root. In a session that node is a SPAWN POINT, not a player: read
     its global transform, use it as the spawn origin, free it, then spawn per-peer. You may
     NOT edit that scene (D-007, hook-enforced) and you do not need to. Offline, leave it
     completely alone.

  c) BOTH PEERS MUST BUILD THE SAME TREE. A synchronizer created only on the authority, or
     named differently on the two sides, fails as "node not found" or as silence. Construction
     runs unconditionally in _ready(); only the CONFIGURATION (who has authority) differs.

  d) SIX MICE. Only the local player's camera is current and only the local player captures
     the mouse. The controller already gates this correctly — verify it still holds once nodes
     are spawned rather than placed, because that changes when _ready() sees authority.

HOST SPEED SANITY CHECK — in scope, deliberately small. §2.2 row 1 says the host
sanity-checks speed, and player_controller.gd's own header promises it lands in this task. On
the host only: watch each remote player's replicated position between samples, and if the
implied horizontal speed exceeds sprint_speed by a clear margin for several consecutive
samples, log a WARN naming the peer. Do NOT correct, rubber-band, kick or teleport — that is a
later decision and the wrong one to make silently now. A warning that fires on a real speed
hack and never fires during normal play is the entire deliverable here.

CONSTRAINTS:
- .gd and project.godot only. NEVER create or edit .tscn/.tres — human-only, hook-enforced.
- project.godot: check `pgrep -fl Godot` FIRST. If the editor is running it rewrites that file
  on save and silently discards your edit — stop and say so rather than racing it. Append
  only; never reorder, reformat, or hand-write a setting equal to the engine default (D-019).
- Typed GDScript throughout. Networked functions prefixed net_.
- Do not build interpolation (1.6), visibility filters or per-class intervals beyond players
  (1.8), reconnection handling (1.7), or a version handshake (1.11). Each is someone's task.
- Don't explore beyond core/dev/dev_launch.gd, entities/player/player_camera.gd and the files
  you claimed. Everything else you need is above.

VERIFY IT, DON'T ASSERT IT. Two real processes, headless, using DevLaunch:

    /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- host
    /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- client

Show that on BOTH processes there are two players under /root/PlayerNet/Players, that each
process has authority over exactly one of them, and that moving the local one changes the
remote copy's position on the other process. Print positions from both sides; a log line
saying "spawned" proves nothing. If you cannot drive input headlessly, move the authoritative
player from code and show the far side following.

FINISH WITH:
    MIRE_AGENT=spawn .agent/bin/agent done 1.5 "<what replicates, what you measured on both sides>"
    MIRE_AGENT=spawn .agent/bin/agent ship 1.5 "M1: networked player — spawner, synchronizer, client-auth movement"

`ship` commits only this task's files. Never `git add -A` — other agents work in this same
directory and you would commit their half-written files.

THEN, as your final chat message, tell me:
  - the exact commands you ran and what the two processes actually printed
  - whether it RUNS or only compiles — and say plainly if anything still needs wiring
  - the node layout you settled on, as a path tree, since 1.6/1.7/1.8 get written against it
  - what the speed check fires on, and what it does NOT do
  - whether it is safe for me to start the next task
```

---

## Task 1.9 — Spike R1: 6 peers, 200 synced entities

> **Model: Opus 5 · effort high** · agent name `load`
> `ARCHITECTURE.md` §6 R1. If this is red, the fallback is hand-rolled binary state packets
> over raw ENet — a rewrite of how every replicated system is written. Worth knowing before
> 1.5–1.8 build on the assumption it's fine.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first — it is
the protocol every agent here follows. Then:

    MIRE_AGENT=load .agent/bin/agent start load
    MIRE_AGENT=load .agent/bin/agent claim 1.9 core/net/dummy_replicant.gd tools/bench_replication.gd

Keep the MIRE_AGENT=load prefix on EVERY .agent/bin/agent command AND on `git commit`. Do
not use `export` — each shell call is a fresh process, so the value is lost and your claims
get filed under the wrong agent with no error. `agent ship` handles this itself.

TASK: Spike R1. Answer one question with measurements, not opinion:
"Can Godot's high-level multiplayer carry 6 peers and 200 synced entities?"

This is a SPIKE — throwaway code that produces a number. Do not build the real replication
layer. Do not make it pretty. Measure, report, stop.

WHAT ALREADY EXISTS — use it, do not rebuild it:

  NetTransport is a registered, verified autoload (task 1.2). Relevant API:
    func host(mode: NetConfig.Mode, port: int = -1) -> Error
    func join(mode: NetConfig.Mode, address: String, port: int = -1) -> Error
    func leave() -> void
    func peer_ids() -> PackedInt32Array
    func local_peer_id() -> int
    signal peer_joined(peer_id: int) / peer_left(peer_id: int)
    signal server_started() / connected_to_host() / connection_failed(reason: String)

  NetConfig is a class_name, NOT an autoload. NetConfig.MAX_PLAYERS = 6,
  NetConfig.DEFAULT_PORT = 27515, NetConfig.LOG_CHANNEL = &"net".
  join(Mode.LOCAL, "") resolves to loopback and the default port.

  DevLaunch (core/dev/dev_launch.gd, task 1.3) already does headless multi-instance
  host/join via `--host` / `--client` user args, with a bounded retry. Read it — it is the
  one file worth opening — and drive your peers the same way rather than inventing a second
  launch mechanism.

  MireLog statics: MireLog.info/warn/error/debug(channel: StringName, message: String).

WRITE EXACTLY TWO FILES:

1. core/net/dummy_replicant.gd — a minimal host-authoritative entity that moves and
   replicates. Position plus a couple of small fields, nothing else. Build its
   MultiplayerSynchronizer and SceneReplicationConfig IN CODE — you cannot create .tscn
   files, and this must run headless with no scene authoring.

2. tools/bench_replication.gd — extends SceneTree, headless. Spawns 1 host + 5 clients
   (six peers total, the real MAX_PLAYERS) and 200 dummy replicants under host authority.

MEASURE AND PRINT:
   - bytes/sec up and down at the host, and at one client
   - bytes/sec per entity, so the number scales to other entity counts
   - host CPU: ms/frame spent in replication
   - client CPU: same
   - how all of the above change at replication_interval 0 (every frame) vs 30Hz vs 15Hz
   - packet loss / delivery failures, if the peer reports any

  Run it yourself:
    /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/bench_replication.gd

SUCCESS CRITERIA — state clearly which the measurements support. The budget that matters is
a typical home upload, so treat ~1 Mbit/s (125 KB/s) at the host as the ceiling for 5
clients, and remember real gameplay adds far more than 200 dummies:
   GREEN : host up < 60 KB/s at 15-30Hz and CPU under ~2 ms/frame → §2.5 interest management
           is enough; 1.5-1.8 proceed as designed
   AMBER : fits only with aggressive intervals or culling → say exactly which knobs bought
           it, because 1.8 then has to ship them rather than treat them as optional
   RED   : cannot fit → the §6 R1 fallback (hand-rolled binary state packets over raw ENet)
           is on the table. Do not just report red: sketch what that costs us, since it
           changes how every replicated system in the project gets written.

IMPORTANT — measure interest management too. §2.5 says enemies/props replicate only within
~120m and replication_interval is set per class (players 30Hz, enemies 15Hz, props
on-change). Task 1.8 implements that. Your job is to produce the numbers that tell 1.8
whether visibility filtering is optional or mandatory, so measure with filters OFF and ON.

AUTHORITY: host-authoritative, per docs/ARCHITECTURE.md §2.2 — the host owns every dummy
and clients only receive. Do not give clients authority over anything here.

CONSTRAINTS:
- .gd only. NEVER create or edit .tscn/.tres/project.godot — another agent holds
  project.godot right now (task 1.5) and you would be blocked at commit. You need no
  autoload for this; if you conclude you do, STOP and ask rather than claiming that file.
- Typed GDScript throughout.
- Deterministic movement for the dummies: seeded RandomNumberGenerator only, never global
  randi(), so two runs are comparable.
- Don't explore beyond core/dev/dev_launch.gd. Everything else you need is above.

FINISH WITH:
    MIRE_AGENT=load .agent/bin/agent done 1.9 "<the numbers, and which of GREEN/AMBER/RED>"
    MIRE_AGENT=load .agent/bin/agent ship 1.9 "M1: replication load spike (R1)"

`ship` commits only this task's files. Never `git add -A` — other agents work in this same
directory and you would commit their half-written files.

THEN, as your final chat message, tell me:
  - the actual numbers and the exact command that produced them
  - which of GREEN/AMBER/RED they support, and if AMBER, exactly which knobs task 1.8 now
    has to ship as mandatory rather than optional
  - whether anything you measured was simulated rather than real (six peers on one machine
    over loopback is NOT a network — say plainly what that does and does not tell us)
  - the text to paste into docs/DECISIONS.md as the R1 verdict
```

---

## Task 1.10 — Network debug panel ✅ **DONE**

> **Model: Sonnet 5 · effort medium** · agent name `netui`
> **Shipped 2026-08-16 in `4f17bcd`. Do not paste this.** Live readout through
> `DebugOverlay.watch()` (F3, FULL mode): session line, per-peer RTT, host bandwidth, event
> log. RTT and bandwidth read `n/a` in STEAM mode, stated rather than invented. Its
> entity-count line reads 0 until **F-013** is closed.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first. Then:

    MIRE_AGENT=netui .agent/bin/agent start netui
    MIRE_AGENT=netui .agent/bin/agent claim 1.10 ui/debug/net_debug_panel.gd

Keep the MIRE_AGENT=netui prefix on EVERY .agent/bin/agent command AND on `git commit`.
Do not use `export` — each shell call is a fresh process, so the value is lost and your
claims get filed under the wrong agent silently. `agent ship` handles this itself.

TASK: A live network readout, so that when 1.5–1.8 misbehave you can see WHY instead of
guessing. Every later M1 task is easier to debug because this exists.

Show, updating a few times a second (NOT every frame):
  - current mode (OFFLINE / LOCAL / LAN / STEAM) and whether we are host or client
  - our own peer id, and the list of connected peer ids
  - ping/RTT per peer
  - bandwidth in and out, per second, human-readable (KB/s)
  - total synced node count
  - a short rolling log of the last few connection events (joined / left / failed)

WHAT ALREADY EXISTS — do not rebuild any of it:

  NetTransport, a registered working autoload. Query it, never touch
  multiplayer.multiplayer_peer directly:
    func is_host() -> bool
    func local_peer_id() -> int
    func peer_ids() -> PackedInt32Array
    func current_mode() -> NetConfig.Mode
    func is_active() -> bool
    func is_connecting() -> bool
    static func mode_name(mode: NetConfig.Mode) -> String
  Signals to subscribe to for the event log:
    peer_joined(peer_id: int), peer_left(peer_id: int),
    connection_failed(reason: String), connected_to_host(),
    server_started(), disconnected()

  NetConfig is a class_name, not an autoload. NetConfig.LOG_CHANNEL = &"net".

  MireLog statics: MireLog.info/warn/error/debug(channel: StringName, message: String).

  DebugOverlay is an existing registered autoload at autoload/debug_overlay.gd, with the
  F3 overlay. READ THAT FILE — it is the one file worth opening — and follow whatever
  pattern it already uses for registering a panel or a line of readout. Match it rather
  than inventing a second, parallel overlay system. If it has no extension point, say so
  and propose the smallest one rather than editing that file (you do not hold its claim).

REQUIREMENTS:
- Typed GDScript throughout.
- Poll on a timer, not in _process. This is a debug readout; costing frames to display
  performance data is self-defeating.
- Get RTT and bandwidth from the real Godot APIs. VERIFY WHAT 4.7.1 ACTUALLY EXPOSES
  before writing against it — ENetPacketPeer and the MultiplayerPeer statistics surface
  changed across 4.x and your training data may be stale. If a figure genuinely is not
  available, display "n/a" and say so in your writeup. Do NOT invent a plausible number:
  a debug panel that lies is worse than one that admits a gap.
- Degrade cleanly when offline. Not connected is the normal state, not an error.
- No allocations per update where you can avoid them.

AUTHORITY: none — display only. This panel must never mutate game state, and must never
be the only thing calling something (if it is the sole caller of an API, that API is
about to be dead code in a release build).

CONSTRAINTS:
- .gd only. Scene files (.tscn/.tres) are human-only (D-007, hook-enforced).
- You did NOT claim project.godot and this needs no autoload of its own — it is a panel
  owned by DebugOverlay. If you conclude it genuinely must be an autoload, stop and ask
  before claiming that file.
- Don't explore beyond autoload/debug_overlay.gd.

FINISH WITH:
    MIRE_AGENT=netui .agent/bin/agent done 1.10 "<what it shows, what is n/a and why>"
    MIRE_AGENT=netui .agent/bin/agent ship 1.10 "M1: network debug panel"

`ship` commits only this task's files. Never `git add -A`.

THEN, as your final chat message, tell me:
  - what you verified and how, including which figures are real and which are "n/a"
  - whether it RUNS or only compiles
  - exactly what I must wire in the editor, if anything
  - whether it is safe for me to start the next task
```

---

## Already shipped — kept for reference

## Task 1.3 — LOCAL mode: two windows, one keypress ✅ **DONE**

> **Model: Opus 5 · effort high** · agent name `local`
> **Completed 2026-08-16. Do not paste this.** Shipped `core/dev/dev_launch.gd`: `--host` /
> `--client` auto-host or auto-join a LOCAL session, no args does nothing, gated on
> `OS.is_debug_build()`, bounded retry (6 × 0.4s) for a client that starts before its host.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first — it
is the protocol every agent here follows. Then:

    MIRE_AGENT=local .agent/bin/agent start local
    MIRE_AGENT=local .agent/bin/agent claim 1.3 core/dev/dev_launch.gd project.godot

Keep the MIRE_AGENT=local prefix on EVERY .agent/bin/agent command AND on `git commit`.
Do not use `export` — each shell call is a fresh process, so an exported value is gone by
your next command and your claims get filed under the wrong agent with no error. `agent
ship` handles this itself.

TASK: Make "two windows, host and client, already connected" cost one keypress. Today
testing multiplayer means launching twice by hand and wiring a connection each time; this
task removes that and is the reason every later M1 task is cheap to verify.

WHAT ALREADY EXISTS — do not rebuild any of it:

  NetTransport is a registered, working autoload (task 1.2, verified booting). API:

    signal peer_joined(peer_id: int)
    signal peer_left(peer_id: int)
    signal connection_failed(reason: String)
    signal connected_to_host()
    signal server_started()
    signal disconnected()

    func host(mode: NetConfig.Mode, port: int = -1) -> Error
    func join(mode: NetConfig.Mode, address: String, port: int = -1) -> Error
    func leave() -> void
    func is_host() -> bool
    func local_peer_id() -> int
    func peer_ids() -> PackedInt32Array
    func current_mode() -> NetConfig.Mode
    func is_active() -> bool
    func is_connecting() -> bool

  NetConfig is a class_name (NOT an autoload — do not register it). Constants you need:
    NetConfig.Mode.{OFFLINE, LOCAL, LAN, STEAM}
    NetConfig.DEFAULT_PORT = 27515
    NetConfig.LOOPBACK_ADDRESS = "127.0.0.1"
    NetConfig.MAX_PLAYERS = 6
    NetConfig.LOG_CHANNEL = &"net"

  join(Mode.LOCAL, "") resolves the address to loopback and port -1 to DEFAULT_PORT, so
  the LOCAL call needs no literals at the call site.

  MireLog (core/util/mire_log.gd, class_name) has statics:
    MireLog.info(channel: StringName, message: String)
    MireLog.warn / .error / .debug, same shape.

WRITE ONE FILE: core/dev/dev_launch.gd — an autoload, and register it yourself.

Behaviour, driven by user command-line args (OS.get_cmdline_user_args(), the args after
a bare `--`):

    -- host      host a LOCAL session on startup
    -- client    join a LOCAL session on startup
    (no args)    DO NOTHING AT ALL

THE NO-ARGS CASE IS THE IMPORTANT ONE. This autoload ships in the retail build. If it
ever auto-hosts without being asked, every player who launches the game opens a socket
they did not ask for. Guard it: no args means return immediately from _ready(), touching
nothing. Also gate the whole thing on OS.is_debug_build() so it is inert in an export.

Beyond that:
- Log every transition through MireLog on NetConfig.LOG_CHANNEL, prefixed so the two
  windows are tellable apart at a glance (peer id, and host/client role).
- Connect to connection_failed and log the reason. A client that starts a half-second
  before the host WILL fail to connect; if that happens, retry a small number of times
  with a short delay before giving up, and say so in the log. Do not retry forever.
- Typed GDScript throughout.

VERIFY THE LAUNCH MECHANISM BEFORE YOU DESIGN AROUND IT. Godot 4.x has a built-in
"Run Multiple Instances" feature (Debug menu → Customize Run Instances) that launches N
instances with per-instance arguments. Check what actually exists in 4.7.1 and how args
are passed, rather than assuming — the feature moved and changed across 4.x releases.

IMPORTANT CONSTRAINT ON THAT: run-instance configuration lives under `.godot/`, which is
in .gitignore. So you CANNOT commit that config, and it is not reproducible for anyone
else from the repo. Therefore:
  - the .gd side is yours and must work from args alone
  - the editor-side setup is Sequoyah's, and you must write him the exact click-path
    (menu, field, and the literal arg strings to type into each instance slot)
  - if you find a way to make this work that does NOT depend on gitignored editor state,
    say so and explain the tradeoff — a committed tools/ launcher script that spawns two
    OS processes is a legitimate alternative. Recommend one, do not build both.

AUTHORITY: none of its own. It only calls NetTransport, which is infrastructure. The
session it opens is host-authoritative per docs/ARCHITECTURE.md §2.2.

CONSTRAINTS:
- Scene files (.tscn/.tres) stay human-only (D-007, hook-enforced).
- project.godot IS yours — your claim names it (D-021). Register the autoload yourself.
  Append one line to [autoload]; do not reorder or reformat the file, and never write a
  setting equal to the engine default (Godot prunes those on save — D-019).
- BEFORE editing project.godot, run `pgrep -fl -i godot`. If the editor is running, STOP
  and tell Sequoyah — the editor rewrites that file on save and will silently discard
  your change. Check immediately before the write, not at the start of your session.
- Don't explore the codebase. Everything you need is above.

FINISH WITH:
    MIRE_AGENT=local .agent/bin/agent done 1.3 "<what works, and how you verified it>"
    MIRE_AGENT=local .agent/bin/agent ship 1.3 "M1: LOCAL two-window dev loop"

`ship` commits only this task's files and pushes. Never `git add -A` — other agents work
in this same directory and you would commit their half-written files.

THEN, as your final chat message, tell me:
  - what you verified, with the actual command and its output. You cannot press F5 in the
    editor; if the only real test is a manual two-window run, say so plainly and give me
    the exact steps and the log lines I should expect to see in each window
  - whether the feature RUNS now or only compiles
  - the exact editor click-path and arg strings I must enter, if any
  - whether it is safe for me to start the next task
```

---

## Task 1.2 — NetTransport autoload ✅ **DONE**

> **Model: Opus 5 · effort xhigh** · agent name `net`
> **Completed 2026-08-16, registered and verified booting. Do not paste this.** Kept as the
> worked example of an interface-first prompt — 1.5–1.8 are all written against what it defined.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md and
docs/ARCHITECTURE.md §2 (all of §2 — it defines the networking model) before writing
code. Then:

    MIRE_AGENT=net .agent/bin/agent start net
    MIRE_AGENT=net .agent/bin/agent claim 1.2 autoload/net_transport.gd core/net/net_config.gd project.godot

Keep the MIRE_AGENT=net prefix on EVERY .agent/bin/agent command you run, including
done and ship. Do not use `export` — each shell call is a fresh process, so an
exported value is gone by your next command and your claims get filed under the
wrong agent without any error.

TASK: Build the NetTransport autoload — one interface that swaps between transports so
no gameplay code ever knows which one is live. This is the foundation of milestone M1;
everything else in the milestone plugs into it.

Three modes (docs/ARCHITECTURE.md §2.3):
  LOCAL  — ENetMultiplayerPeer on 127.0.0.1. Daily development: two windows, one
           machine, no Steam client, ~3 second iteration loop.
  LAN    — ENetMultiplayerPeer on a real address.
  STEAM  — SteamMultiplayerPeer via GodotSteam.

SCOPE FOR THIS TASK: implement LOCAL and LAN fully. For STEAM, define the code path
and leave it behind a clean seam that returns a clear "not yet installed" error —
GodotSteam isn't installed yet (that's task 1.1, and it's mine to do). Task 1.4 fills
in the Steam implementation. Design the seam so 1.4 is a drop-in, not a refactor.

Write exactly two files:

1. core/net/net_config.gd — class_name NetConfig, extends RefCounted
   Mode enum, default port, max players (6), timeouts. No logic.

2. autoload/net_transport.gd — the autoload. Public API, exactly this shape so the
   rest of M1 can be written against it:

     signal peer_joined(peer_id: int)
     signal peer_left(peer_id: int)
     signal connection_failed(reason: String)
     signal connected_to_host()
     signal server_started()
     signal disconnected()

     func host(mode: NetConfig.Mode, port: int = -1) -> Error
     func join(mode: NetConfig.Mode, address: String, port: int = -1) -> Error
     func leave() -> void
     func is_host() -> bool
     func local_peer_id() -> int
     func peer_ids() -> PackedInt32Array
     func current_mode() -> NetConfig.Mode

REQUIREMENTS:
- Wrap Godot's MultiplayerAPI; do not make callers touch multiplayer.multiplayer_peer.
- Handle the full lifecycle: host quits, client times out, join fails, leave and rejoin
  in the same process without restarting. That last one matters — it's what makes the
  two-window loop fast.
- Emit signals rather than requiring polling.
- Log through the existing MireLog class (core/util/mire_log.gd, class_name MireLog).
  Read that file to match its API — it's the one file worth opening.
- Typed GDScript, all of it.

AUTHORITY: this is infrastructure, not simulated state. But read the authority table
in docs/ARCHITECTURE.md §2.2 and note in a file-header comment which rows this enables.

CONSTRAINTS:
- Scene files (.tscn/.tres) stay human-only (D-007, hook-enforced).
- project.godot IS yours here: your claim names it, which D-012/D-021 permit. Register
  the autoload yourself rather than handing me a checklist. Append one line to the
  [autoload] section; do not reformat or reorder the file, and do not add settings that
  equal the engine default — Godot's editor prunes those on its next save (D-019).
- BEFORE editing project.godot, confirm the Godot editor is not running (pgrep -fl Godot).
  If it is, STOP and tell me — the editor rewrites that file on save and will silently
  discard your change. This is the one condition that makes wiring not yours.
- Don't explore the codebase beyond mire_log.gd. Everything else you need is here.

DELIVERABLE: also give me a 5-line snippet showing how task 1.3 (the two-window LOCAL
launcher) will call this, so I can sanity-check the interface before we build on it.

FINISH WITH:
    MIRE_AGENT=net .agent/bin/agent done 1.2 "<what works, what's stubbed>"
  (or handoff, if something is genuinely unfinished)
    MIRE_AGENT=net .agent/bin/agent ship 1.2 "M1: NetTransport autoload"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified, with the actual command you ran and its output. If you
    could not run it, say so — do not describe unrun code as working
  - whether the feature actually RUNS now, or only compiles. You registered the
    autoload yourself, so "shipped" and "working" should finally be the same
    thing; if they aren't, say which one this is
  - anything still needing a .tscn/.tres change, which is genuinely mine
  - whether it is safe for me to start the next task

```

---

## Task 2.2 — Content resource framework ✅ **DONE**

> **Model: Sonnet 5 · effort medium** · agent name `content`
> **Completed 2026-08-16. Do not paste this.** Kept only as a worked example of a
> framework-shaped prompt, since M2 has several more of them.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first.
Then:

    MIRE_AGENT=content .agent/bin/agent start content
    MIRE_AGENT=content .agent/bin/agent claim 2.2 core/content/item_def.gd core/content/recipe_def.gd autoload/registry.gd

Keep the MIRE_AGENT=content prefix on EVERY .agent/bin/agent command you run,
including done and ship. Do not use `export` — each shell call is a fresh process,
so an exported value is gone by your next command and your claims get filed under
the wrong agent without any error.

TASK: Build the content resource framework — the thing that makes adding the 60th
powerup cost the same as the 2nd (docs/DECISIONS.md D-006).

Three files:

1. core/content/item_def.gd — class_name ItemDef, extends Resource
   @export'd: id (StringName), display_name, description, icon (Texture2D),
   max_stack (int), tags (Array[StringName]), tier (int).
   All @export so items are authored in the Godot inspector, not in code.

2. core/content/recipe_def.gd — class_name RecipeDef, extends Resource
   @export'd: id, inputs (Dictionary of item id -> count), output item id,
   output count, required station (StringName), craft_time (float).

3. autoload/registry.gd — loads every .tres under content/ at boot into typed
   dictionaries keyed by id. Public API:
     func item(id: StringName) -> ItemDef
     func recipe(id: StringName) -> RecipeDef
     func recipes_for_station(station: StringName) -> Array[RecipeDef]
     func all_items() -> Array[ItemDef]
   Fail loudly at boot on a duplicate or missing id — a silent content bug found at
   runtime costs far more than a hard startup error.

REQUIREMENTS:
- Typed GDScript throughout, including typed Arrays and Dictionaries.
- Registry must be deterministic: iterate directory entries in SORTED order. Load
  order must not vary between machines (docs/ARCHITECTURE.md §4 — we ship on macOS,
  Windows and Linux and their filesystems enumerate differently).
- Do NOT author any actual item or recipe content. Framework only. I author content
  by hand in the inspector — that's free, and it's the whole point of this design.

AUTHORITY: none — this is static content loaded identically on every peer. Nothing
here is replicated; nothing here is mutable at runtime.

CONSTRAINTS:
- .gd files only. NEVER touch .tscn/.tres/project.godot (D-007, hook-enforced).
  You cannot register the autoload — tell me what to register.
- Don't explore. Everything you need is in this prompt.

FINISH WITH:
    MIRE_AGENT=content .agent/bin/agent done 2.2 "<what you built>"
    MIRE_AGENT=content .agent/bin/agent ship 2.2 "M2: content resource framework"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified, with the actual command you ran and its output. If you
    could not run it, say so — do not describe unrun code as working
  - whether the feature actually RUNS now, or only compiles. You registered the
    autoload yourself, so "shipped" and "working" should finally be the same
    thing; if they aren't, say which one this is
  - anything still needing a .tscn/.tres change, which is genuinely mine
  - whether it is safe for me to start the next task

```

---

## Not yet — M4 gate, written down now while the context is fresh

## Task 4.0a — Spike R2b: chunk collision cooking + GPU upload

> **Model: Opus 5 · effort high** · agent name `collide`
> **Do not start this during M1.** It's parked here so the reasoning behind it doesn't have to be
> rebuilt from `FINDINGS.md` F-005 in three milestones' time. Run it immediately before task 4.1.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first —
it's the protocol every agent here follows. Then:

    MIRE_AGENT=collide .agent/bin/agent start collide
    MIRE_AGENT=collide .agent/bin/agent claim 4.0a tools/bench_chunk_collide.gd

Keep the MIRE_AGENT=collide prefix on EVERY .agent/bin/agent command you run,
including done and ship. Do not use `export` — each shell call is a fresh process,
so an exported value is gone by your next command and your claims get filed under
the wrong agent without any error.

TASK: Spike R2b. Close the half of spike R2 that was never measured.

BACKGROUND — read this carefully, it is the whole point of the task:
R2 (task 0.7) benchmarked chunk mesh generation at 0.330 ms/chunk and came back GREEN.
It ran HEADLESS against the dummy renderer, so it measured noise sampling and vertex
array construction and NOTHING ELSE — no GPU buffer upload, no material, no collision
shape. R3 (task 0.8) measured NAVIGATION baking, which people assume covers this. It
does not: physics collision cooking is a different code path from Recast navmesh
generation. So the chunk streaming budget for task 4.3 is currently derived from a
number that excludes two costs that could each dominate it.

This is recorded as FINDINGS.md F-005 and as the standing caveat on DECISIONS.md D-015.

Reuse world/chunk/chunk_mesher.gd — it exists and is the real mesher from R2. Do not
rewrite it.

Write one file: tools/bench_chunk_collide.gd — extends SceneTree.

Measure, per 32x32m chunk (33x33 verts), averaged over 100 chunks:
  - ms to cook a ConcavePolygonShape3D from the chunk mesh
  - ms to cook the same as a HeightMapShape3D instead — heightfield chunks may not
    need a trimesh at all, and if the heightfield is much cheaper that is the finding
  - whether cooking is threadable (does it block the main thread? try WorkerThreadPool)
  - memory per cooked shape

CRITICAL: this benchmark must NOT run headless with --headless / the dummy renderer.
That is exactly the mistake that made R2 incomplete. Run it windowed against the real
Forward+ renderer so GPU upload is actually exercised:
  /Applications/Godot.app/Contents/MacOS/Godot --path . --script tools/bench_chunk_collide.gd
Measure mesh upload separately from cooking — instance the ArrayMesh into the live scene
tree and time to first rendered frame, so upload cost lands somewhere real.
If you cannot separate upload from cook cleanly, say so and report the combined number
with that stated plainly. A number with an honest caveat is worth more than a clean
number that quietly measures the wrong thing — that is how we got here.

SUCCESS CRITERIA — state which the measurements support, and remember the budget is
shared with meshing (0.330 ms) and nav baking (0.034 ms main-thread block):
   GREEN : cook + upload < 4 ms/chunk, or cook is threadable → 4.3 streams as designed
   AMBER : 4-15 ms → 4.3 needs a chunk budget per frame; say how many chunks/frame fit
   RED   : >15 ms and not threadable → chunk size or collision strategy must change
           before 4.1 is written. Evaluate HeightMapShape3D-only as the fallback.

AUTHORITY: none — offline generation, no networking.

CONSTRAINTS:
- .gd files only. NEVER create or edit .tscn/.tres/project.godot (D-007, hook-enforced).
- Typed GDScript.
- Deterministic: seeded RandomNumberGenerator / FastNoiseLite.seed only, never global
  randi(). And per D-017 + ARCHITECTURE.md §7, no sin/cos/tan/exp/log/pow anywhere in
  seed-derived generation — those diverge ~1 ULP across platforms.
- Don't explore the codebase beyond chunk_mesher.gd. Ask if genuinely blocked.

FINISH WITH:
    MIRE_AGENT=collide .agent/bin/agent done 4.0a "<the numbers, and which of GREEN/AMBER/RED they support>"
    MIRE_AGENT=collide .agent/bin/agent ship 4.0a "M4: chunk collision + upload spike (R2b)"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified and the actual numbers/command
  - whether it is safe for me to start 4.1
  - the text to amend onto DECISIONS.md D-015, since this either confirms or
    overturns its GREEN verdict
```

---

## When they finish

Each agent ends with `agent done` or `agent handoff`, which releases its claims and writes
`.agent/JOURNAL.md` itself. `ship` commits and pushes its own files. So there's usually nothing for you
to run — read `.agent/BOARD.md` to see what landed, or ask any chat to summarise it.

What *is* yours: the wiring. Agents can't touch `.tscn`/`.tres`/`project.godot` (D-007), so a shipped
script is often not a working feature until you register an autoload or add a node. Every prompt here
ends by demanding the agent state plainly whether the thing works yet — believe that section over the
word "done".

For 1.2 specifically: **sanity-check the interface snippet it gives you before starting 1.3.** Seven
tasks get written against that shape, so changing it afterwards isn't a fix, it's a refactor across the
milestone. Paste the snippet into a fresh chat and ask whether the API holds up, if you want a second
read on it.
