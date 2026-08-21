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

### 2026-08-21 — 3.18/3.19: the tool ladder has five rungs and the game has a narrator (birche6b40e)

**Spec: `docs/PROGRESSION.md`. Calls: D-200 (the ladder), D-201 (guidance).** Both tasks came from one
directive — the tools had no progression and nothing ever told a player what the game wanted.

**The code half is committed (5f115a8) and pushed. The CONTENT half is not, and is blocked on the
Godot editor being closed (D-031/D-021), not on anything else.** Everything below is the API the
authoring pass builds against.

**`ProgressionService`** (autoload, *not yet registered — see below*) owns the party's high-water tool
rung for the run:

```gdscript
ProgressionService.tier_reached() -> int          # 0..5, party-wide, high-water
ProgressionService.is_tier_reached(t) -> bool
ProgressionService.tier_of_item(id) -> int        # reads ItemDef.tool_tier
ProgressionService.tier_name(t) -> String         # "" / Wood / Stone / Iron / Bogsilver / Wellglass
ProgressionService.host_raise_tier(t, item_id)    # HOST-only; idempotent, rises only
ProgressionService.host_reset_run()
EventBus.subscribe_tier_reached(func(tier: int, item_id: StringName) -> void)
```

Host-owned, replicated through `WorldDeltaLog` under `kind = &"progression"`, re-derived on every peer
— no new RPC, so **no protocol bump**. `CraftingService._finish_craft()` is the one caller;
`SalvageService` scores `TIER_REACHED_BONUS` per rung, which is the "tiers reached" milestone
`DESIGN.md` §4.6 has always listed and never had a fact for.

**One new authored field: `ItemDef.tool_tier` (0..5).** 0 means "not a rung". `tools/progression_check.gd`
fails any TOOL/WEAPON item that leaves it at 0 — an unauthored tier is a tool that silently never
advances the ladder, which is the least debuggable content bug available.

**`GuideService`** (autoload, *not yet registered*) + `GuideHud`: the objective line, one-shot tips,
the tier fanfare. Content family `content/guide/*.tres` → `GuideStepDef`, indexed by `Registry.guide_step_defs()`.
Conditions are the `GuideStepDef.Condition` enum, never a string. `GuideService.evaluate()` is public
so a check can step a scripted run without waiting out real seconds. Off switch:
`SettingsService.guidance_mode()` (0 FULL / 1 OBJECTIVES ONLY / 2 OFF) plus `has_seen_tip()`,
`mark_tip_seen()`, `reset_seen_tips()`; settings schema is now version 3.

Two small accessors were added for it and are worth knowing about because they are the reusable half:
`CraftingService.station_count(id)` (a PARTY fact — any station anywhere, riding the F-286 cache) and
`FocusPrompt.focus_is_blocked()` (is the player looking at something their tool cannot chip).

**What is left, in order — all of it `.tres`, all of it editor-gated:**

1. **`content/guide/`** — the objective ladder `tools/guide_check.gd` already names in order
   (`gather_fibre`, `craft_first_axe`, `chop_a_tree`, `place_workbench`, then the Wellspring/anvil/
   guardian rungs) and the tips of `PROGRESSION.md` §5.2.
2. **T3's missing iron axe**, then all of T4/T5: items + `WeaponDef`s + recipes, the **anvil** station
   (tier 3, recipe costs a Wellglass Shard), the **bogsilver outcrop** harvestable and its scatter
   entries, `wellglass_shard` into the `wellspring` loot table and `guardian_core` into the `boss` one.
3. **Register three autoloads** — `agent autoload ProgressionService res://autoload/progression_service.gd`,
   same for `GuideService` (`res://autoload/guide_service.gd`) and `GuideHud` (`res://ui/hud/guide_hud.gd`).
   Order matters only in that `GuideHud` must come after `GuideService`.

`tools/progression_check.gd` and `tools/guide_check.gd` both fail today, and they fail by **naming
exactly what is unauthored** — run them first, and treat their output as the authoring worklist.

### 2026-08-21 — F-461: the placement pass is off-thread, and LOD changes retarget instead of rebuilding (quillcfd8d7)

Traversal hitches went from **172 frames / 18.7% of the wall clock to 27 frames / 2.6%**, and the
survivors are nearly all in the first 1.7 s (the settle behind the loading screen), not in traversal.
See F-461 for the measurements and D-197/D-198 for the reasoning. What the next task needs to know:

**New API.**

- `ChunkStreamer.chunk_mesh(coord) -> ArrayMesh` — the resident mesh, or null. **Use this instead of
  calling `ChunkMesher.build_mesh()` for a chunk that is already streamed in.** `NavBaker` was
  rebuilding it and paying 19-81 ms of main-thread time per chunk to do so.
- `ChunkStreamer.last_phase_costs_ms() -> [eval, drain, cook]` and `last_phase_counts() ->
  [uploads, cooks]` — the split behind `last_process_cost_ms()`. `tools/traversal_profile.gd` prints
  both; a streamer total without the split cannot tell "blew the budget" from "a signal listener did".
- `ResourceScatterField.pending_placement_job_count()` — in-flight `PlacementJob`s. **A settle
  condition that waits on `pending_group_count()` alone is now incomplete**: a chunk can be
  holder-resident with its placements still computing on a worker.

**Two invariants that are easy to break.**

1. `ResourceScatterField` chunks are built ASYNCHRONOUSLY now. `_chunk_holders.has(coord)` means
   "this chunk exists", not "this chunk is dressed" — its contents arrive over later frames.
   `_build_chunk()` owns the one-holder-per-coord rule and retargets instead of building a second.
2. `_chunk_has_proxies[coord]` is the single source of truth for which side of the proxy boundary a
   chunk is on. A landing `PlacementJob` reads it fresh rather than trusting what was requested,
   because `_retarget_chunk()` may have moved the chunk while the job ran.

**Anything reached from `chunk_mesh_ready` runs inside `ChunkStreamer._process()`'s 4 ms budget** —
the emit is synchronous. Keep new listeners off that frame or the budget stops meaning anything.

### 2026-08-21 — F-458: the benchmark suite is 9 situations x day/night, on a surveyed seed (quill895277)

Three changes on top of F-453, all from Sequoyah: a seed chosen rather than guessed, equal day and
night coverage, and a map flyover.

**`BenchmarkRunner.BENCH_SEED` is now `20260024`, and it was chosen.** `tools/bench_seed_survey.gd`
scores candidate seeds on what the suite depends on — every biome present and none vestigial, spread
evenly, POI count and variety, island size and peak height — and ranks them. Deterministic and
re-runnable, so re-make the choice whenever worldgen moves (it moved twice this month):

```bash
.agent/bin/agent godot --script tools/bench_seed_survey.gd -- --count 150 --top 8
```

Land size and peak are scored against the **median of the candidates**, not against constants — the
benchmark wants a *typical* island, and typical is a property of the distribution. The two constants
that used to be there (`IDEAL_LAND_FRACTION`, `TARGET_PEAK_M`) were already wrong when written: at
+-240 m every seed reported 83-97% land, because the sampling window sat entirely inside the
coastline. If you add a scoring term, score it against the distribution too.

**The suite is generated, not listed.** `BenchmarkSuite.situations()` holds nine situations;
`scenes()` is that crossed with {day, night} = 18 scenes, ids `<situation>_day` / `<situation>_night`.
Add a situation and you get both halves and the ids for free. `day_night_counts()` exists so the
check can assert the split rather than trust a comment (D-195).

**Motion is a three-way, not a bool.** `MOTION_STILL` / `MOTION_WALK` / `MOTION_FLY`, with
`travel` derived as `motion != still`. `SettingsAdvisor.preset_basis()` still keys off `travel`, so
the flyover is excluded from choosing a preset alongside the ground traversal — both are
streaming-dominated and neither responds to a preset (D-194).

**Camera pitch lives on the player's `CameraPivot`, not on the body.** The body owns yaw
(`PlayerCamera._rotate_view()`), so a flyover that rotated only the body flies over the island
staring at the horizon. `_set_camera_pitch()` is reset to level for every ground scene.

**`_prewarm()` visits every destination before anything is sampled, and you must not remove it
casually.** A location's first visit hitches and its second does not — `Deep forest` measured 22 fps
by day and 74 by night, same trees, minutes apart — and `settle_world()` does not cover it, because
the streamer has already reported idle. Without the warm-up the day half eats every location's
first-visit cost and the night half never does, so the pairing measures visit order instead of
lighting. That cost is real and players pay it every run: **F-459**, and disabling `_prewarm()` is
how you check whether it has been fixed.

Full run is ~4 minutes: `.agent/bin/agent godot --windowed --script tools/benchmark_check.gd --
--full` — 285 assertions, 0 failures at this commit.


### 2026-08-21 — F-453: there is an in-game benchmark, and `core/bench/` is its API (quill895277)

A player can now measure their own machine instead of being classified by
`core/render/hardware_tier.gd`'s adapter-string guess. Settings → DISPLAY → **RUN BENCHMARK** (front
end only — it never runs over a live run, D-192).

**`core/bench/` is five plain scripts and one Node.** None of them is an autoload and none needs
one:

```gdscript
FrameSampler.new()                      # record(delta_ms, gpu_ms, cpu_ms, draws, prims) -> stats()
BenchmarkSuite.scenes()                 # the nine scenes, as data. estimated_seconds(), scene_by_id()
MachineProbe.read_hardware()            # GPU/CPU/cores/RAM. read_power() -> volatile state
MachineProbe.warnings(power)            # why this machine is not fit to be benchmarked, in player words
MachineProbe.drift(before, after)       # what changed during the run (throttling, power source)
SettingsAdvisor.recommend(baseline, calibration, target_fps, current_preset)
SettingsAdvisor.worst_scene(results)    # the scene every recommendation is made against
BenchmarkReport.new().begin(signature)  # resumable JSONL ledger; returns the completed prefix
BenchmarkRunner.settle_world(world, tree)   # static; wait for the chunk streamer. USE THIS
```

`BenchmarkRunner.run(world, target_fps, resume, scene_override, calibrate)` wants a level that is
already loaded and settled — it does no scene loading, deliberately, so a check can stage its own.
`ui/frontend/benchmark_screen.gd` is the caller that owns the world.

**`BenchmarkRunner.BENCH_SEED` is `20260821`, the same island `tools/probe_scene.gd` pins.** Keep
them equal: the developer probe and the shipped benchmark describing different ground is how a
player's report stops being comparable with ours.

**Three rules are enforced in code, not by convention.** The headline metric is a **1% low**, never
a median and never an average across scenes. A preset is only ever recommended after being
*measured* on that machine — with an empty `calibration` the advisor returns verdict
`&"unmeasured"` and changes nothing, rather than predicting from `docs/PERFORMANCE.md`'s table
(D-193). And the preset is chosen against `SettingsAdvisor.preset_basis()` — the worst
**non-travelling** scene — not against the worst scene overall, because the worst scene overall is
the chunk streamer and no graphics lever touches it (D-194). `worst_scene()` is still what the
hitch diagnostic talks about; the two are different scenes on this game and conflating them
produced a report that contradicted itself.

**The player cannot die during a run, and the class picker never appears.** The runner turns on the
shipped `GodModeService` — which already gates enemy damage, Mire blight and starvation — and hands
it back on every exit path, cancelled and failed included; leaving it on would put the player into
their next real run invulnerable. It also selects `BENCH_ATTUNEMENT` (`warden`), because
`AttunementUI` re-opens itself every half second while `local_selection()` is empty, so closing the
picker does not keep it closed. Both are asserted *during* the run by `benchmark_check`, not after.

**Every scene waits on the streamer, never on a clock.** `_run_scene()` calls `settle_world()` after
each teleport before it samples. A fixed two-second wait was the first version and it reported
`Deep forest` at a 21 fps 1% low against a 113 fps median while standing still — it was measuring
the teleport. The check now fails any stationary scene whose 1% low drops below a fifth of its own
median, and any scene drawing under a quarter of the suite's median draw calls (which caught `The
Mire` pointing out to sea at 632 draws).

**`MachineProbe` is macOS-only** and says so (`{supported: false, reason: ...}`) everywhere else —
F-455 has the Windows/Linux APIs and what to assert. No temperature is reported on any platform;
SMC access needs root, so `pmset -g therm`'s `CPU_Speed_Limit` stands in for it.

**Watch out for GDScript closure capture.** `runner.finished.connect(func(v): my_local = v)` assigns
to the lambda's own copy and the outer local never changes — this hung `tools/benchmark_check.gd`
for ten minutes on a run that had completed perfectly. Use a member variable.

Verify with `.agent/bin/agent godot --windowed --script tools/benchmark_check.gd` (add
`-- --full` for the whole suite plus calibration, ~3 minutes). Headless still runs the pure half and
prints `SKIPPED` for the live one rather than passing vacuously.


### 2026-08-21 — F-450: the hills are flat-topped uplands, and the terrain is three times as tall (birchcf39ce)

Reported from play: *"taller hills please the map is wayy too flat, i do like big flat areas but i
also like higher areas, i dont like narrow hills that make the map always go up and down"* — and,
mid-pass, *"it doesnt need to be perfectly flat"*.

**The island's peak is now 30-50 m, up from ~21.** Anything holding a metre count against the old
terrain is holding a number against a different island — see D-191 for the four that broke.
`IslandHeightmap.MAX_HEIGHT` is the constant to derive from; it includes the uplands' crown lift,
which `HEIGHT_SCALE` does not.

**`IslandHeightmap.Hill` changed shape again.** A hill is a flat top plus a ramp:

```gdscript
hill.top_radius   # radius of the FLAT TOP — not the footprint
hill.height       # crown lift, derived from top_radius
hill.lee_run      # gentle side: metres of run per metre of rise
hill.scarp_run    # steep side, same unit; never longer than lee_run
hill.cliff_direction, hill.sharpness
hill.footprint()  # top_radius + height * max(lee_run, scarp_run) — the whole landform
```

`hill.radius` and `hill.flat_fraction` are gone. Anything measuring an upland's extent wants
`footprint()`; anything measuring its summit wants `top_radius`.

**Biome bands moved** (`content/biomes/*.tres`): marsh 3.1-5.2, forest 5.2-20.0, birchwood
3.1-20.0, highland 20.0+. Shore, grassland and heath are unchanged. If you author a biome or a
scatter table against an elevation, these are the current numbers.

**`ChunkMesher.SKIRT_DEPTH`** is `MAX_HEIGHT * 0.65` (33.2 m), no longer a fraction of
`HEIGHT_SCALE`.


### 2026-08-21 — F-447: the island doubled, its lobes are ellipses, its hills are asymmetric (birchcf39ce)

Reported from play: *"the island should be maybe twice as big and id like the shape to be a bit more
random rather than usually mostly round... also hills can be a bit taller maybe 25%, with some more
variety in steepness, like one side of the hill could be more steep than the other kinda making a
cliff type area."*

`world/gen/island_heightmap.gd` — `ISLAND_RADIUS` is **590 m** (was 295). Anything holding a number
in metres against the old island is now holding a fraction of a different one; anything authored as
a fraction of `ISLAND_RADIUS` scaled for free.

**Three signatures changed. Nothing outside the file called any of them, but tools do now:**

```gdscript
IslandHeightmap.lobes(seed)  -> Array[Vector4]   # (centre.x, centre.y, radius, stretch) — was Vector3
IslandHeightmap.hills(seed)  -> Array[Hill]      # a class now, six fields — was Vector4
IslandHeightmap.bend(x, z, seed) -> Vector2      # NEW, public: the shape warp, for instruments only
```

**`Hill`** carries `centre`, `radius`, `height`, `cliff_direction`, `scarp_run` (metres of run per
metre of rise on the steep face — the gradient itself) and `sharpness` (how far that face
front-loads its rise). Hills are placed inside a chosen LOBE rather than at a bearing from the
island's middle, because the island does not fill the disc `ISLAND_RADIUS` names and hills placed
that way landed in the sea.

**`NoiseSet` now carries the seed's landform lists** — `lobe_list`, `islet_list`, `hill_list` —
built once in `make_noise_set()`. If you sample many points for one seed, go through the set:
`shape_into()` used to rebuild all three per sample, and with asymmetric hills that is 5-8 object
allocations per vertex. Same threading rule as the noise fields: one set per `WorkerThreadPool`
task, never shared.

**Every landform coordinate is in BENT space.** `lobes()`, `hills()` and `river_polyline()` return
points the shape warp has already been applied to, and the warp's amplitude is ~67 m at this radius.
A tool that walks "outward from this hill along its cliff bearing" in world coordinates is walking
some other bearing entirely — `tools/hill_slope_check.gd` measured steep flanks as gentler than lee
flanks until it inverted `bend()` by fixed-point iteration. If you write an instrument against any
of these, un-bend first.

**New check:** `tools/hill_slope_check.gd` — per-hill flank asymmetry and island-wide walkability.


### 2026-08-21 — F-432/F-434/F-442: a tree's collider is its trunk, and felling one leaves its own stump (kiln384569)

Reported from play: *"harvest states of trees are not working, and the collision boxs of willows are
huge, i want no collision box on the leaves of tree period."*

**One collider fitter, for both world builders.** The measurement moved out of
`ResourceScatterField` into its own file, because an authored map's Python mapgen cannot open a
`.glb` and had been sizing tree colliders off a CANOPY footprint table.

```gdscript
const PROP_COLLIDER := preload("res://world/gen/prop_collider.gd")

PROP_COLLIDER.fit(mesh_parts) -> Dictionary       # {} = "this must not collide at all"
                                                  # {shape: &"cylinder", radius, height, center_y}
                                                  # {shape: &"box", size: Vector3, center: Vector3, ...}
PROP_COLLIDER.fit_cached(cache, key, mesh_parts)  # same, behind a cache YOU own (per-vertex walk)
PROP_COLLIDER.has_foliage(mesh_parts) -> bool
```

`mesh_parts` is the `[{"mesh": Mesh, "offset": Transform3D}, ...]` shape both world builders already
pass around. **Always check `shape`** — a prop that lies down (a felled trunk, an uprooted tree) now
gets a box along its own length instead of a disc as wide as it is long.

`AuthoredWorld._shapes_for()` re-measures any prop whose layout collider is a plain cylinder and
leaves authored BOXES alone; a prop with no `cols` still collides with nothing.

**Harvestable presentation.** A prop that keeps the world builder's own geometry now hands its node
over as well as a way to hide it:

```gdscript
harvestable.set_visual_hook(func(shown: bool) -> void: ...)   # unchanged; the only seam a BATCHED prop has
harvestable.set_presentation(node: Node3D)                    # NEW — the node that draws it
```

With a presentation node, `Harvestable` shakes the prop on every landed hit and leans it further as
it goes down (client-local, off replicated `health`, no new RPC), and on depletion draws a stump cut
from that tree's own trunk by `systems/harvesting/stump_builder.gd` in preference to the
definition's one authored `depleted_scene`. Both are automatic — a new world builder gets them by
calling `set_presentation()`.

**Material names are load-bearing.** `_is_foliage()` classifies a surface by `Material.resource_name`
(`"MIRE_" + CamelCase(palette_token)`). Anything that REPLACES a material at runtime must carry that
name across, or every consumer downstream reads a tree's canopy as solid wood — which is what
`EnvironmentVfx`'s sway dressing was doing (F-442).

Gates: `agent godot --script tools/tree_collider_check.gd` (asserts over every asset the 29 scatter
tables place) and `agent godot --script tools/harvest_tree_states_check.gd`. For a look:
`agent godot --windowed --script tools/harvest_tree_states_shot.gd` -> `assets/audit/harvest/`.

### 2026-08-21 — F-435: the Mire is visible on the ground (hollow80855f)

**D-190.** The corruption grid is published to the GPU. Anything that wants to know where the Mire is
per-fragment reads the texture; nothing calls back into the simulation per frame.

```gdscript
MireGrid.corruption_field_texture() -> Texture2D   # R8, 256x256, one texel per cell, world XZ.
                                                   # RID is STABLE — bind once, never re-read.
                                                   # Never null; black (clean) until a grid exists.
MireGrid.corruption_field_half_extent() -> float    # world X/Z at the texture's edge; uv = (xz + h) / 2h

WorldDeltaLog.snapshot_applied                      # signal: the log replaced itself wholesale
                                                    # (late-join snapshot, or a run reseed).
                                                    # Any incremental mirror of the log must rebuild here.

GroundFog.place_window(eye: Vector3) -> void        # test seam: position the fog volume without a
                                                    # main-viewport camera
```

Two consumers, both binding once: `ChunkStreamer._bind_mire_field()` (terrain, purple ground) and
`GroundFog._push_mire_field()` (low yellow-green fog). Both shaders expose `mire_field`,
`mire_field_half_extent` and a `blight_strength` A/B dial that is bit-for-bit the pre-F-435 look at 0,
and both fall back to `hint_default_black` — a level with no `MireGrid` renders exactly as before.

**If you add a third consumer:** the two-stage ramp constants (`BLIGHT_SEEN_AT` / `BLIGHT_HURTS_AT` /
`BLIGHT_DEEP_AT` / `BLIGHT_HURTS_WEIGHT`) are duplicated in both shaders and the middle one tracks
`PlayerHealth.BLIGHT_CORRUPTION_THRESHOLD`. Copy the set; do not invent a third ramp.

`GroundFog` also now builds a coarse 64x64 terrain height map (`terrain_height_field`,
`terrain_field_half_extent`, `terrain_field_ready`) from whatever node answers `height_at()`, so a
ground-hugging layer works on any terrain. **The ordinary mist does not use it yet — F-444.**

Gate: `agent godot --windowed --script tools/blight_ground_check.gd` (renders; needs `--windowed`).

### 2026-08-21 — F-433: enemies carry an overhead health bar and every landed hit prints its number (pike3c5846)

**D-189.** Two new client-local HUD autoloads, both registered and both proved headless. Neither
touches the crosshair: the third half of Sequoyah's report — a progress bar next to the crosshair
while harvesting — is F-431's `ui/hud/focus_prompt.gd`, which already draws it off
`Harvestable.health` and hides it at full health. Duplicating it was the whole thing D-189 refused.

```gdscript
TargetHealthHud.tracked_bars() -> Array          # what is drawn right now; a check reads this, not pixels
TargetHealthHud.refresh_now()                    # force one rebuild + projection, for checks

DamageNumbers.show_damage(world_position: Vector3, damage: int) -> void
DamageNumbers.active_indicators() -> Array       # same idea
```

`TargetHealthHud` (`ui/hud/target_health_hud.gd`, layer 3) polls the `enemies` group at 10 Hz,
skipping anything in `bosses` (task 5.5's top-centre bar already reads those), and shows a bar when
the enemy is damaged, is not IDLE, or is inside `ALWAYS_RANGE_M` — within `MAX_RANGE_M`, unoccluded
by a world ray, capped at the `MAX_BARS` nearest. Projection runs per frame; the group scan, the
rules and the rays do not (F-099). Head height is **measured off the model's own mesh AABB and cached
per definition**, not taken from `EnemyDef.height_m`: that is a movement capsule and is routinely
taller than what you can see, which parks the bar in empty sky.

`DamageNumbers` (`ui/hud/damage_numbers.gd`, layer 3) binds `CombatService.attack_landed` and
`RangedCombatService.shot_landed` — identical `(peer_id, position, damage, target_name)` shape, one
handler — and draws only the LOCAL peer's hits. A hit that applied 0 prints a muted "0" rather than
nothing, because `Harvestable.host_apply_tool_damage()` reports a wrong-tool bounce as exactly that
and it is the clearest tool hint in the game.

Anything that wants a world-anchored readout of its own should copy this file's shape rather than add
a node per entity: one `Control` whose `_draw()` calls back into the HUD, one array of projected
entries, and the scan on a timer with the projection per frame.

Verification: `tools/target_feedback_check.gd` (`failures=0`) covers every selection rule, the
nearest-first cap, the `blocks_gameplay_input` blackout, bar geometry (above the head, centred,
narrower and fainter with distance, nothing behind the camera), and the number's text, colour,
spread, fade, lifetime and local-peer filter — the last driven through the real signals.
`tools/target_feedback_shot.gd` renders `/tmp/mire_target_bars.png` and `/tmp/mire_damage_numbers.png`
for the half of this that only pixels can answer.

### 2026-08-21 — F-431 resolved: one look-at prompt for the world, one hover card for the inventory (wickc3d79c)

`FocusPrompt` is the only thing that draws an interaction prompt (D-187). It raycasts from the active
camera at 15 Hz, falls back to an aim cone when the ray misses, and renders a crosshair plus a panel
naming the target, the verb, a hint, and — for a chipped harvestable — a health bar.

```gdscript
FocusPrompt.describe(node: Node3D, kind: int = -1) -> Dictionary  # {title, action, hint, ratio, blocked, key}
FocusPrompt.focus_kind() -> int          # FocusPrompt.Kind.{NONE,HARVESTABLE,HAULABLE,CHEST,DOOR}
FocusPrompt.focus_node() -> Node3D
FocusPrompt.focus_title() / focus_action() / focus_hint() -> String
FocusPrompt.focus_ratio() -> float       # 0..1 remaining health, or -1 when there is none to show
FocusPrompt.refresh_now() -> void        # re-target immediately instead of waiting out the poll
FocusPrompt.try_carry_focus() -> bool    # [E] on a haulable: pick up, or put down what you carry
```

**`describe()` takes no camera and no viewport on purpose** — the wording is a pure function of the
prop's own state, so a headless check can assert it. Add an interactable kind by adding a `Kind`
entry and a `_describe_*()` case; do not add another CanvasLayer.

Three things changed around it:

- **`HarvestableDef.display_name`** is new, authored on all eleven `content/harvestables/*.tres`, with
  a humanised-id fallback in `label()`. `tools/focus_prompt_check.gd` fails if a new definition ships
  without one.
- **Haulables became reachable.** `Haulable.request_pickup()` shipped with no caller anywhere in the
  game — every crate was scenery. `FocusPrompt._input()` owns that verb now. Doors and chests keep
  their own `_input()`, because duplicating it would send two requests per press.
- **`ui/inventory/item_tooltip.gd`** replaces the two-line `tooltip_text` with a card that reads
  `ItemDef`/`WeaponDef`/`RangedWeaponDef`: category and attack style, description, damage, reach,
  swing time, tool class and power, hunger/hp restore, and held/capacity for a stack.

Verification: `tools/focus_prompt_check.gd` (0 failures — wording, the wrong-tool branch against the
host's own `damage_from_tool()`, and a card built for all 27 shipped items),
`tools/focus_prompt_shot.gd --windowed` (three PNGs), plus a live probe of the procedural island that
resolved a real prop end to end: `focus_kind=1 title="Fallen Log" action="Needs an axe"`.


### 2026-08-21 — F-411/F-413 resolved: live Settings has runtime God mode; the duplicate legacy panel is retired (flinta92725)

`GodModeService` is the one extension seam for playtesting powers. The single live tabbed screen,
`ui/frontend/settings_screen.gd`, owns every Settings route (title, pause and the remaining legacy
MainMenu's SETTINGS handoff); the obsolete `SettingsMenu` autoload/script was removed. Its
PLAYTESTING tab calls `request_local_enabled()`, which submits the same HOST-scope/op-gated `god
[on|off]` command the console exposes. There is no privileged UI-only path and the value is
deliberately not persisted: every new process starts safe/off.

```gdscript
GodModeService.is_enabled(peer_id: int) -> bool        # canonical on host; health/host consumers
GodModeService.is_local_enabled() -> bool              # approved owning-client presentation/move
GodModeService.request_local_enabled(enabled: bool)    # Settings-safe request + completion signal
GodModeService.host_set_enabled(peer_id, enabled)      # host/solo mutation seam
```

`PlayerHealth` rejects shared/direct, starvation and Blight damage for the host-approved set.
Enabling while downed revives and fully heals through its existing host seams. `PlayerController`
keeps collision and applies flight only on the owning movement authority: camera-relative movement,
Jump up, Dodge down, Sprint x2. Future God-mode powers query this service rather than adding another
cheat flag. The one new reliable RPC bumped protocol 21 -> 22 and the recorded manifest 55 -> 56.

Verification: `tools/god_mode_check.gd` instantiates the live tabbed screen and covers its checkbox,
op refusal, recovery, immunity,
flight entry/exit and restored ordinary damage/gravity; `tools/god_mode_net_check.gd` proves a real
client is refused before op, approved after op, immune on the host, and cleanly disabled. Both print
`failures=0`.

### 2026-08-20 — F-307 resolved: a terminal run-summary overlay is no longer a dead end when the host quits (lp)

**D-185.** F-243's two terminal overlays (`ui/hud/defeat_hud.gd`, `ui/hud/extraction_hud.gd`) read
"am I the host" exactly once, when they opened, and never again. A client whose host quit was left on
a disabled "Waiting on the host…" label, and because the overlay stays in `blocks_gameplay_input`,
D-032's interlock refused every menu over the top of it — zero operable controls, no route out,
kill the process. Both files now do this, identically:

```gdscript
# _ready(): by path, never a bare NetSession (standing rule 1 — these are autoloads a --script run compiles)
var session: Node = get_node_or_null(^"/root/NetSession")
if session != null:
    session.connect(&"session_ended", Callable(self, "_on_session_ended"))
```

**The API the next task builds against**, if you are adding a third screen of this kind or taking
F-321 (which is exactly this bug in `ui/attunement/attunement_ui.gd`):

- **`_session_over: bool`** — set only by `session_ended`, cleared on every showing
  (`_on_run_wiped()` / `_on_run_extracted()`) and on the un-terminal path (`_on_run_restarted()`).
  **Scope it to the showing, never to the process.** Transport state cannot tell a solo host from an
  orphaned client — both answer `_is_host_or_solo()` with `true`, and a solo run never opens a session
  at all — so a process-scoped flag makes every later solo run wear the orphan's label. This is the
  detail D-185 exists to stop you rediscovering.
- **`_refresh_restart_button()`** branches on `_session_over` **first**, ahead of the host predicate,
  because an orphan satisfies both. It yields an enabled `FOCUS_ALL` control reading `LEAVE_LABEL`
  (`"Leave to Menu"`), not `RESTART_LABEL`.
- **`_on_session_ended(_reason, _detail)`** refreshes the button, calls
  `remove_from_group(BLOCKING_UI_GROUP)`, then `_grab_restart_focus()` — F-275's bare-controller rule,
  re-applied after the flip. Dropping the group is half the fix, not garnish: without it the button
  works and still nothing can open over the screen. It is legal *because the session is dead*
  (`PlayerNet` has cleared the local player, so no live world gets input back) and on no other grounds
  — see D-185 §2 before reusing the permission.
- **`_leave_to_menu()`** → `get_node_or_null(^"/root/MainMenu").call(&"set_open", true)`. The overlay
  stays visible behind it; `MainMenu` is `CanvasLayer` 57 against `DefeatHud`'s 20.

**The harness for any of this is `tools/terminal_focus_check.gd` phase 3**, not a new file. Its driver
already builds the host+client pair; `_check_orphaned_client(which)` and `_run_orphan_client(which)`
are parameterised by overlay, and adding a third is a `ORPHAN_PORTS` entry plus a branch in
`_open_terminal_overlay()`. Two things it will teach you the hard way otherwise: wait on
`session_ended` itself rather than polling `is_active()`/`is_connecting()` — the signal fires only
*after* the rejoin ladder is exhausted, so a poll trips while getting back in is still possible — and
budget `ORPHAN_TIMEOUT_SEC = 60.0`, not the file's 20 s, because the **shipped** host-leave path sends
no notice and costs the client ~19 s of rejoin attempts (that is F-322).

`.agent/bin/agent godot --script tools/terminal_focus_check.gd` → `TERMINAL_FOCUS_CHECK failures=0`,
54 PASS.


### 2026-08-20 — 4.18: the coast is a beach, not a cliff — and WHY a gentle falloff curve is not enough on its own (quill5fa5c7)

Sequoyah, after walking the sea-level island: "make the slope down to the water much more
gradual, it's way too steep." Measured before touching anything, across 5 seeds: the whole
transition from +2 m to −1 m happened in **under 4 m** of ground, at up to **71 degrees** — past
the player's own 46-degree walkable limit (F-136), so stretches of coast could not be walked at
all. After: worst 48 degrees, typical coast 32–37, and the shore run widened to ~12 m.

**Four things were stacking, and only one of them was the obvious one.** If you ever retune a
coast, this is the list to check, because fixing the curve alone got barely a third of the way:

1. **The falloff CURVE.** `_radial_mask` returned `inv^3`, which leaves the plateau at three times
   the average gradient and then flattens — every metre of relief was spent in the first stride of
   the band. It is an S-curve now (`inv*inv*(3-2*inv)`, hand-written per this file's no-`pow()`
   rule): flat leaving the plateau, flat arriving at the water.
2. **The falloff WIDTH.** `FALLOFF_START_FRACTION` 0.70 → 0.48. Widening it does not shrink the
   island — land ends where the surface crosses sea level, and the curve change moves that point
   outward (~0.75 → ~0.79 of each lobe's radius) even though the taper starts earlier.
3. **The SEA FLOOR term.** `OCEAN_FLOOR_DEPTH * (1 - mask)` is linear, so the seabed fell away at
   full rate at the same place the land was already falling, and the two summed into the wall. It
   is CUBED now — a shelf: shallow wade near shore, deep water offshore where depth is scenery.
4. **The coast JITTER's frequency** (`COAST_FREQUENCY` halved, `SHAPE_WARP_FREQUENCY` eased). This
   is the non-obvious one and it was worth ~20 degrees on its own: the jitter displaces the
   shoreline radially, so where that field changes fast it COMPRESSES the taper into less ground.
   A perfectly gentle curve still stands a wall up inside a fast-wobbling jitter. Amplitudes are
   untouched, so the coastline is exactly as ragged — the wobbles are just longer.

**And one structural rule replaced two special cases.** `_radial_mask`'s band is a fraction of the
landmass's own radius, but now never narrower than `MIN_FALLOFF_BAND_M` (30 m) of real ground,
capped at `MAX_FALLOFF_RADIUS_FRACTION` of it. Without that floor a small lobe or an islet gets a
proportionally small horizontal budget while owing the same absolute relief — which is why, after
the curve fix, every remaining steep shore the probe found was on an islet or the smallest lobe. A
beach is a distance a player walks, not a percentage. (This subsumed a short-lived
`ISLET_FALLOFF_FRACTION`; do not reintroduce per-landmass constants for this.)

**How to re-measure.** The throwaway probe is not committed (deliberately — it is 60 lines and the
numbers are here), but its shape is worth repeating: walk radial transects on several seeds, find
the +2 m and −1 m crossings, report the worst per-metre gradient and the run width between them,
and flag whether the worst sample sits inside `_river_channel()`'s corridor — a stream bank at 45
degrees is terrain doing its job, a beach at 45 degrees is the bug, and without that flag you will
chase the wrong one.

**Knock-on, already handled:** `chunk_stream_check`'s recorded seam divergence collapsed 1.2134 →
0.2196 m (its recorded chunk is a coast chunk, so this is the intended effect, not drift);
island-wide worst 1.76 m against a 10.2 m skirt. Everything else green: terrain, biome, poi,
resource_scatter, procedural_world, noise_reuse, biome_terrain all 0, world_contract PASS both
arms.


### 2026-08-20 — 4.18 playtest round: sea-level island, a real ocean, streams not gorges, dressed biomes (quill5fa5c7)

Sequoyah's first real playtest verdicts, all landed in one pass. If you touch terrain or scatter,
this is the current shape of the world:

**The land sits just over the water now.** `HEIGHT_SCALE` 6, `LAND_BIAS` 0.55 (meadow ~3.3 m),
hills 2.5–4.5 m over 30–60 m radii, ridge texture 1.2 m on hilltops only. The river is a STREAM —
bed 1.2 → -1.2 m, banks you walk down (`RIVER_BANK_RISE` 2.2) — his "weird pits and aggressive
valleys" was the old gorge carving a flat island.

**There is an ocean.** `IslandHeightmap.OCEAN_FLOOR_DEPTH` (5 m): the mask's outside settles onto
a seabed BELOW the waterline instead of a plain at exactly y=0 — before this the shipped map had
no visible water at all. The surface is `levels/procedural_island.tscn`'s `Ocean` node — a
subdivided plane on `world/environment/water_low_poly.gdshader` (sine-bobbed, facet-lit,
client-local paint; gameplay water level is still `water_surface_at()`'s flat 0). Checks that
encoded "open water == height 0.0" were updated (`terrain_check`'s island-shape and river phases:
the monotonic-bed contract now ENDS at the waterline, because a polyline crossing a bay's seabed
is not the bed climbing).

**Biome boundary moved with the land**: `content/biomes/*` shore/grass/forest boundary 4.0 → 1.6
continental metres. POI bands retuned to the low island (`standing_stones` 4.2+ so they crown the
hills, `wellspring` 2.5+, nests/stations 2.2+) — several were dead or starved at the old 8 m+
bands, which is where poi_check's "0 sites across 5 seeds" failure came from.

**All three biomes are dressed now** ("wheres all the plants?"): six scatter tables in
`content/scatter/` — grassland_meadow (grass/tussock/flowers/clover, cell 3 m),
grassland_shrubs, forest_floor (bracken/litter/moss/nettle), forest_canopy (3 willows + snag),
forest_undergrowth, shore_beach (marsh grass/sedge/bog flowers). `ScatterDef` grew an optional
`min_height`/`max_height` band and `resource_scatter.gd` gates on it AFTER the surface sample
(per-point rng, so the gate shifts nothing) — needed because the `shore` biome classifies the
SEABED too, and a beach table without a floor would carpet the ocean bottom. Keep authoring
tables against the band.

**Seam lines and striations** (his other two reports): border vertices now jitter too, at a FIXED
LOD0 amplitude so any two chunks sharing a world point compute the identical offset — the
straight un-jittered rows every 32 m are gone (`biome_terrain_check` asserts the cross-chunk
border agreement directly, to 0.1 mm; the old border-on-grid assertion is retired). The
striations were shadow acne on flat-shaded facets: the scene's Sun bias went 0.045/1.3 →
0.06/2.4.

**Verified:** terrain/biome/poi/resource_scatter/noise_reuse/biome_terrain/procedural_world 0
failures, world_contract PASS both arms, chunk_stream 0 (seam worst re-measured: 2.58 m
island-wide, skirt 10.2 m clears ~4x), windowed boot 0 ERROR. Renders in
`assets/audit/terrain/` (seed 3493587347) show ocean, beach, stream and dressed meadows.


### 2026-08-20 — 4.18 tuning applied: the island is Muck-shaped now — mostly flat, gentle rolls, no mountains (quill5fa5c7)

**D-184.** Sequoyah's verdict off the first shipped renders: "mostly flat, some gentle rolling
hills is nice but no mountains, look at muck for reference." Three constants in
`world/gen/island_heightmap.gd` moved, nothing structural: `HEIGHT_SCALE` 26 → **11**, `LAND_BIAS`
0.54 → **0.75** (the pair moves together — bias sets where the interior sits, scale sets how much
it rolls; dropping scale alone pushed ordinary noise dips under the 4 m shore/grassland biome
boundary and scattered sand through the meadows), `RIDGE_WEIGHT` 8.5 → **2.0** (the D-144 ridge
machinery — only-add, highland mask, biome amplitudes — all still holds; it is texture now, not a
skyline). `MAX_HEIGHT` follows automatically.

**Verified:** `terrain_check` 0, `biome_check` 0, `poi_check` 0, `procedural_world_check` 0,
`world_contract_check` PASS both arms. Fresh evidence renders in `assets/audit/terrain/`
(island_orbit / island_spawn_view / island_shore_look, seed 1744425603) — the orbit shows a flat
lobed island with the river still cutting through; the spawn view is a sprintable meadow.

**If a later walk wants more verticality back**, D-184 names the reversal: it is those three
constants, cheap to move.

**Second pass, same day.** His next verdict: "still wayyy too steep… like 3-5 hills on the whole
island." That is a STRUCTURE, so the fBm interior is gone: `BASE_NOISE_WEIGHT 0.25` flattens the
plateau to ~±1 m and `IslandHeightmap.hills()` places 3–5 seeded smooth mounds (26–52 m radius,
5–8 m lift, `maxf`-merged, lobes-style integer mixing) added into `raw_continent` in
`shape_into()` — so biomes, ridge mask, scatter and the navmesh all see them as ordinary
continent. Ridge window moved to 0.95–1.30 x HEIGHT_SCALE: cresting only on hill tops, the
plateau stays clean. Same check suite green; fresh renders (seed 1856316070) in
`assets/audit/terrain/`.

**Third pass, same day — flat shading.** He linked the target look (r/Unity3D rvr9ca: flat-shaded
low-poly terrain, no mountains, no height coloring). Shipped as
`world/chunk/terrain_flat.gdshader` on `ChunkStreamer`'s shared material: per-facet normals from
screen-space derivatives, zero mesh change — do NOT "improve" this into non-indexed per-face
meshes, that triples resident vertex counts against the low-end target.

**Fourth pass — interior-vertex jitter (call delegated to the agent).** Uniform grid triangles
flat-shade into a visibly regular pattern; the reference's facets are irregular. `ChunkMesher` now
jitters INTERIOR vertices by a deterministic integer hash (`VERTEX_JITTER_FRACTION` 0.35 x step),
re-sampling the true surface at each jittered, float32-narrowed position — so every vertex still
sits exactly on the analytic ground and the mesh/surface agreement checks pass by construction.
Borders stay on-grid (tiling/seams/skirt untouched). If you write a check against chunk vertices,
read the vertex's OWN stored XZ off the mesh — never assume grid placement; three checks
(`biome_terrain`, `noise_reuse`, `chunk_stream`) were updated to that form and
`biome_terrain_check` now also asserts border-on-grid. Extra cost is one additional surface sample
per interior vertex, on the worker thread. The D-184 flattening also
collapsed the worst LOD seam divergence 12.44 m → 3.10 m; `chunk_stream_check`'s recorded
spot-check constant is re-measured accordingly (the island-wide sweep assertion is what carries
the skirt guarantee; the constant only catches drift). Skirt is 18.7 m now via MAX_HEIGHT and
clears the worst by ~6x.


### 2026-08-20 — 4.19 DONE: the shipped map is procedural. Press Play and you get a generated island (quill5fa5c7)

**What ships.** `run/main_scene` is **`levels/procedural_island.tscn`**: `world/gen/
procedural_world.gd` on the scene ROOT (so `PlayerNet._claim_spawn_point()` finds `current_scene/
Player` exactly as before), under Hollowmere's environment shell copied node for node —
`WorldEnvironment`/`Sun`/`Atmosphere`/`CloudDeck`, the sibling names `playtest_atmosphere.gd`
requires. No `Undergrowth`, no authored `Player`, no `World` child: the composer builds its own.
Hollowmere (`levels/hollowmere.tscn`) stays as the authored fixture/reference, exactly as the
roadmap said it would.

**`--procedural` is now a no-op on a default boot** — `DevLaunch._swap_to_procedural()` returns
early when the current scene root already runs the composer script. It still swaps when the main
scene is authored (a Hollowmere comparison run).

**Where checks moved.**
* `tools/world_contract_check.gd` — the matrix is now *authored fixture (pinned, FIRST)* then
  *shipped map (kind-detected by root script)*. The fixture arm runs first on purpose: the
  live-spawn phase watches EnemyWorld's first ambient top-up, which happens once per process right
  after the first navmesh bake — reorder it and you get "no crawler ever actually spawned" (this
  session measured exactly that). The code-built composer arm only runs when the shipped map is
  authored, since otherwise the shipped arm just booted the identical script.
* Pinned to the Hollowmere fixture (they grade Hollowmere's *authored content*):
  `chest_placement_check`, `harvest_batch_check`, `environment_vfx_hollowmere_check`.
* Still following `main_scene` (they grade *the shipped map*): `ground_fog_check`,
  `dev_loadout_check`, `verify_setup` (its player-body check now accepts the composer's
  `build_player == true` as "provides a player"), `atmosphere_look_shot`.
* NEW `tools/procedural_look_probe.gd` (`--windowed`) — three framed PNGs of the shipped island
  into `assets/audit/terrain/` (spawn view, orbit, shore look). The camera positions in
  `atmosphere_look_shot` are Hollowmere-authored coordinates; on a generated island they face
  cliffs, so use the probe for island-look evidence.

**Two real fixes that rode along.**
* `ChunkStreamer._upload_chunk()` adds each chunk `MeshInstance3D` to `authored_world_terrain` —
  the same group `authored_world.gd` puts its terrain visuals in — so AABB-measuring presentation
  (ground fog) sees streamed terrain at all.
* `ground_fog.gd._measure_base_height()` clamps the measured datum to `water_surface_at() +
  WATER_CLEARANCE_M` when a TERRAIN_GROUP member can answer (F-284's pair): streamed islands carry
  seabed geometry, and the quarter-height datum landed at y≈-25 — mist rendered underwater where
  nobody sees it. Authored maps with no water at the terrain centre answer -INF and are unchanged.
  `ground_fog_check`'s "low half of the terrain" band got the same dry-floor correction.

**Verified:** `world_contract_check` PASS both arms (authored: 1156/1156 harvestables, live=4
crawlers, stations=2; shipped: wellspring+ship+chests+station, standable dry spawn, mire seeded
and receding); `procedural_world_check` 0; `ground_fog_check` 0 (base_height 0.75, was NaN);
`dev_loadout_check` 0; `verify_setup` all pass; **windowed full boot 0 ERROR lines**. Headless
full boot prints ~10 known dummy-renderer RID lines from threaded chunk meshes — that is **F-317**,
windowed is clean, do not chase it as a streamer bug.

**Open and now more important than it was: F-301** — some seeds publish no station marker, and the
station is the shipped map's crafting access. It was an intermittent check failure when procedural
was a side arm; it is a playtest-facing gap now that procedural ships.


### 2026-08-20 — F-283 resolved: three duplicated D-numbers renumbered, and `decision_ref_check.py` now fails on a repeated heading (lp)

**The numbers moved. If you cite one of these, cite the new one.** `docs/DECISIONS.md` had three
numbers each heading two unrelated decisions, all hand-allocated before F-260 put `agent decision`
behind a lock:

| was | is now | which decision |
|---|---|---|
| `D-050` (2nd) | **D-179** | the powerup stat vocabulary — conditions/triggers/capabilities are stat names, not schema fields |
| `D-144` (2nd) | **D-180** | keep file claims, fix claim STALENESS instead of moving to per-agent worktrees (resolved F-189) |
| `D-150` (2nd) | **D-181** | the LM lane runs Opus at high effort and second-passes its own work |

`D-050` now means **only** attack style / solved grips, `D-144` **only** task 4.13's terrain split,
and `D-150` **only** `chunk_stream_check.gd`'s union-of-interest sizing. Every in-repo citation was
read and moved with its meaning; each renumbered entry carries a breadcrumb naming its old number, so
an old journal line or an old commit still resolves. `.agent/JOURNAL.md` and git history were
deliberately not rewritten.

**The rule for the next one is D-182:** renumber the **later** member — the earlier entry keeps the
number it was correctly allocated — and classify every citation by reading its prose, never by `sed`.
The numbers are ambiguous by construction, so a blind rewrite is guaranteed to break the half that
meant the entry which kept its number. Three `D-050` sites in this file and `tools/build_check.gd`
look like the powerup entry and are the attack-style one; they were left alone for that reason.

**The API to build against — `tools/decision_ref_check.py` gained a second assertion:**

```python
duplicate_decisions(decisions_text) -> [(ref, [line_no, ...]), ...]
# every D-NNN heading more than one entry, with BOTH heading lines. Hard failure, not a warning:
# the allocator makes a new collision impossible, so a duplicate means a hand-written heading.
```

`report(repo=ROOT)` takes a `repo` argument, which is how the pre-fix negative test runs — point it
at a scratch tree holding `git show <sha>:docs/DECISIONS.md` and it names all three pairs. Extend
this check rather than writing a new one; `--self-test` is at 7/7 and is where a new case goes.

**Still open, filed from this sweep: F-316** — the same shape in `docs/SPECS.md`, where `## F-226`
heads two blocks that disagree about the claim set. `docs/FINDINGS.md`'s three duplicate `### F-NNN`
headings (`F-012`, `F-055`, `F-056`) are **deliberate** and must stay a named exception in any
generalised check, not a failure.

### 2026-08-20 — F-281 resolved: the run-scoped reset enumeration is `tools/run_scope_audit_check.gd`, and it is TOTAL over `project.godot` (lp)

**If you add an autoload, you must classify it here or the check fails.** That is the whole point of
the file, not a side effect of it.

`tools/run_scope_audit_check.gd` holds the live answer to "what resets when a run restarts?" — the
question D-149 answered in prose and got wrong four times in five days (F-259, F-268, F-277, F-278;
three of the four found twice over, by two lanes each). Two tables:

- `AUTOLOAD_SCOPE` — **every** entry in `project.godot`'s `[autoload]` section, mapped to either
  `RESETS` (the file must call `EventBus.subscribe_run_restarted`) or a one-line reason why it does
  not (the file must NOT call it). Both directions are asserted, because a reason that has quietly
  become false is how F-259 and F-277 were each missed on a first pass. Currently 17 resetting, 43
  reasoned.
- `SCENE_SCOPE` — the 5 run-scoped nodes that are not autoloads and that an autoload sweep therefore
  cannot see: `Chest`, `Wellspring`, `ExtractionShip` (D-149 gave each its own
  `host_reset_for_new_run()` rather than reloading the level), `ProceduralWorld` (D-161) and
  `ResourceScatterField`.

    .agent/bin/agent godot --script tools/run_scope_audit_check.gd   # RUN_SCOPE_AUDIT_CHECK failures=0

**What it does not do, so you do not mistake green for safe:** it asserts only that the subscription
*exists*, never that the handler resets the right things. F-303 is a subscriber whose handler resets
the wrong quantity and this check passes it. Behaviour stays with `run_restart_check`,
`day_night_restart_check`, `attunement_restart_check`, `harvest_restart_check`,
`run_restart_spawn_check`, `run_restart_net_check`. D-178 records why the split is drawn there, and
why the check reads source text instead of introspecting `EventBus` (its `Callable` registry has no
listing API, and a booted probe sees only what is in that tree).

**Reading the reasons is cheaper than re-deriving them.** Each row is the recorded answer to "was
this considered?", which is the question every one of the four rediscoveries above re-asked from
scratch. `dev_loadout.gd`'s row, for instance, is a known gap pointing at F-300 rather than a
justification.

### 2026-08-20 — F-273 resolved: `GameState.seed_ready`'s contract is written down at the signal, and `tools/seed_ready_contract_check.gd` enforces it (lp)

**Rule: D-177.** Read it before you write a `seed_ready` handler. Short form: **it is a RUN boundary
on every peer, and it can fire twice for one boundary — your handler must be idempotent.**

**If you are adding a `seed_ready` subscriber, this is the whole briefing.**

```gdscript
# core/game_state.gd
signal seed_ready(value: int)   # read the block comment above it — that is the contract
```

- **Who emits it.** Host: `host_generate_seed()` (session start via `NetTransport.server_started`,
  plus `MireGrid`'s lazy `ensure_seed()` at boot) and `host_redraw_seed()`
  (`CycleService.host_restart_run()`). Client: `set_replicated_seed()`, from
  `WorldDeltaLog.net_world_snapshot()` (joining mid-run) and `_on_world_delta_applied()` (a reseed
  reaching a peer already here).
- **It fires TWICE on the host for one restart**, same value both times —
  `_host_redraw_world_seed()`, then `WorldDeltaLog.host_reseed()` → `_reseed_local()` →
  `set_replicated_seed()`, which runs on the sending side by design (D-161). So: zero, assign or
  re-derive. Never increment, toggle, advance a phase, or count boundaries.
- **`GameState.reset()` does not fire it.** That is a session end (`NetTransport.disconnected`). For
  session end, listen to `NetSession.session_ended`. To re-derive your *world* rather than a per-run
  tally, use `EventBus.run_restarted`, which lands immediately after the reseed on the same reliable
  channel.
- **Adding a subscriber turns `tools/seed_ready_contract_check.gd` red on purpose.** Its phase 1 is
  an exact census — `["MainMenu", "RewardService", "SalvageService"]` today. Confirm your handler is
  idempotent and run-scoped, then add yourself to `EXPECTED_SUBSCRIBERS`. That failure is the only
  mechanism in the repo that makes an author read the contract, so do not weaken it to a
  "contains" test.

**The check is also the place to extend seed-contract coverage.** Six phases (census, every emitter,
the run boundary through the real producers, the client-adoption half, idempotence on a repeated
value, and `reset()` being silent), solo, one process, no scene load —
`.agent/bin/agent godot --script tools/seed_ready_contract_check.gd` → `failures=0`, 30 PASS. The
full restart with a real defeat, an island rebuild and the delta-log wipe stays
`tools/run_reseed_check.gd`'s job; the two are deliberately separate contracts.

**`ARCHITECTURE.md` §2.2 now has a `Run world seed` row.** `core/game_state.gd` had always declared
"NETWORK AUTHORITY (§2.2)" against a table with no row for it. Host draws, client adopts, carried by
`WorldDeltaLog`'s existing RPCs with no RPC of its own (D-161).


### 2026-08-20 — F-266 resolved: `state.json` writes are transactional and atomic; `tools/agent_state_lock_check.py` is where harness concurrency gets tested (lp)

**Rule: D-176.** Read it before touching any `load()`/`save()` pair in `.agent/bin/agent`. Short
form: **bracket the load→save window, never a subprocess.**

**1. What changed for anyone editing the harness.** `load()` and `save()` are no longer bare
`json.load`/`json.dump`. Three things now hold:

```python
with state_txn("label"):        # flock .agent/locks/state.lock; re-entrant; silent under 2s
    st = load()                 # records the rev it read
    ...check, mutate...
    save(st)                    # CAS on that rev, then atomic write + render_board

COMMANDS = {"claim": in_state_txn(cmd_claim), ...}   # whole-command form, for short local commands

_atomic_write(path, text)       # mkstemp -> fsync -> os.replace; used for state.json and BOARD.md
```

- **Adding a command that writes state?** Either wrap it with `in_state_txn` in `COMMANDS` (if its
  whole body is local and milliseconds long) or open `state_txn()` around just its load→save window
  (if it shells out, dispatches a lane, or prints a git summary). `save()` self-locks when it is not
  already inside one, so a forgotten bracket still writes atomically — but the *read-check* it
  followed is unprotected, which is exactly where F-266 lived. Bracket the window.
- **`save()` can now `die()`.** "refusing to write .agent/state.json — it changed under this
  command" means some path reached `save()` with a state loaded before another process's write.
  Nothing is written and the command is safe to re-run. Fix the path; do not loosen the check.
- **`state.json` carries a `rev` integer.** It is bumped by every `save()`. Do not hand-edit it, and
  do not add it to a fixture's expected output — `tools/harness_check.py`'s fixtures omit it and
  still pass, because `_disk_rev()` treats absent as 0.
- **Readers stay lock-free and that is intentional.** `.agent/bin/lane`, the pre-commit hook and
  `tools/findings_hygiene_check.py` all `json.load` `state.json` without the lock; the atomic write
  is what makes that safe. Do not add a lock to a reader — add it to whatever writes.

**2. The check, and the technique it establishes.** `python3 tools/agent_state_lock_check.py` →
`AGENT_STATE_LOCK_CHECK failures=0`, 6/6. It takes `--rev <sha>` like `tools/harness_check.py`, and
`--rev HEAD` before this commit gives `failures=5`.

**This is the file to extend for any harness concurrency question**, and the reason is the
technique: subprocess-launched racers get smeared apart by interpreter startup, so a microsecond
window reproduces one run in fifty and a green result proves nothing. Instead it builds a throwaway
repo, **imports** that repo's copy of the harness as a module (`import_harness()`), and `fork()`s N
children that block on a pipe barrier before dispatching — so every racer is warm at the gun and
only the window itself separates them. `race(mod, jobs, command="claim")` is the reusable primitive;
it dispatches through `mod.COMMANDS[...]`, not the bare `cmd_*`, so a harness whose transaction
wrapper was never wired into `COMMANDS` fails rather than passes.

Use `tools/harness_check.py` for *behaviour* (staging rules, claims, hooks) and this one for
*concurrency*. Both take `--rev`; neither needs Godot.

**3. `.agent/JOURNAL.md` entries are written in one `f.write()`** rather than six. Output is
byte-identical to before — verified against entries with and without a file list — but a >8 KB
handoff body no longer flushes mid-entry, so two writers cannot interleave inside one entry.


### 2026-08-20 — F-286 resolved: `EventBus.world_rebuilt` + `world_generation()`, the seam for anything cached off the world (lp)

**Rule: D-175.** Read it before adding any consumer that caches something derived from the world
scene. Short form: **state to reset subscribes; a cache derived from the scene pulls a counter.**

**1. The new API.** `core/events/event_bus.gd`:

```gdscript
EventBus.subscribe_world_rebuilt(callable)     # () -> void
EventBus.unsubscribe_world_rebuilt(callable)
EventBus.emit_world_rebuilt()                  # producers only
EventBus.world_rebuilt_subscriber_count() -> int
EventBus.world_generation() -> int             # monotonic count of the emits above
```

Meaning: *a world composer just re-derived its contract nodes IN PLACE.* Emitted at the **end** of
`ProceduralWorld.rebuild_for_seed()`, after `PoiSites`/`SpawnMarker`/every marker group is
published — so a handler that re-reads the tree sees the NEW island, never the torn-down one. The
counter is bumped **before** the dispatch, so a subscriber consulting a generation-keyed cache from
inside its own handler sees the new value. **Boot does not emit**: a first build changes
`current_scene`, which scene-keyed consumers already watch. One producer today, and
`rebuild_for_seed()` is the only in-place world rebuild in the repo.

**2. Which half to use.** Hold state that must be reset → subscribe. Hold only a cache derived from
the scene → fold `world_generation()` into the cache key and subscribe to nothing. The worked
example is `CraftingService._station_positions_for()`, whose key is now
`(scene_id, census, generation)`:

```gdscript
var generation: int = EVENT_BUS.world_generation()
if scene_id != _station_scene_id or census != _station_census \
        or generation != _station_generation:
```

The pull half is not a micro-optimisation. A handler is **ordered against every other subscriber**
and `ProceduralWorld` is itself one of them — an autoload's `run_restarted` handler runs while the
ended island is still standing, so clearing there lets the very next query re-cache the dead
coordinates. A counter read at the query has no ordering to lose. It also covers `rebuild_for_seed()`
called directly (console reroll, a `--script` check), which fires no `run_restarted` at all.

**3. Do not reach for `run_restarted` for this.** It fires on both maps, the authored one tears
nothing down (D-170 records what a blanket reaction costs there), its dispatch precedes the rebuild,
and it misses the direct call entirely. Three separate failures, one wrong event.

**4. Before you choose clear-or-prune (D-170 vs D-175).** Ask whether your re-derivation is
*unconditional*. `_station_positions_for()` re-walks the live groups every time, so clearing is
always recoverable — pull the counter and clear. `EnvironmentVfx`'s re-walk is blocked by
`VFX_META` early-returns, so clearing leaves the authored map permanently dark — prune by source
instead. Same class of bug, opposite fixes, and the mechanism decides.

**5. Checking a reseed defect without depending on the seed.** `tools/crafting_reseed_check.gd` is
the pattern for the next one. Two things it does that a naive version cannot: it **constructs** the
census collision (a fixed pad of kind-less markers planted inside `PoiSites`, then exactly the
shortfall replanted after the rebuild frees them) rather than waiting for a lucky seed pair; and it
**plants its own probe stations at y = 500** on the real marker contract, because **F-301 is open —
some seeds publish no station marker at all**, so nothing in a procedural check may assume the
island has one. Any new procedural fixture check should assume the same.


### 2026-08-20 — F-282 resolved: a `cycle_advanced` consumer must not read the modifier stack from its own listener (lp)

**Rule: D-174.** Read it before adding any subscriber that both listens to an event and reads state
another subscriber of that same event produces. Short form: react to the **second** event, and be
idempotent, so autoload order stops being a gameplay input.

**1. The seam that was wrong, and is the template for the next one.** `EventBus` invokes listeners in
append order and autoloads append in `project.godot` order, so `WaveSpawner` (line 44) asked
`CycleModifierService.has_modifier(&"the_hunt")` before `CycleModifierService` (line 61) had drawn
that Cycle's modifier. The Hunt's elite entered one Cycle late, every time. The fixed shape:

```gdscript
# _ready()
EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)          # the trigger
EVENT_BUS.subscribe_cycle_modifier_drawn(_on_cycle_modifier_drawn)  # the completed action

func _on_cycle_advanced(cycle: int) -> void:
    _current_cycle = cycle
    _maybe_spawn_hunt_elite(cycle)

func _on_cycle_modifier_drawn(_modifier_id: StringName, cycle: int) -> void:
    _maybe_spawn_hunt_elite(cycle)     # the draw's OWN cycle, not the cache

func _maybe_spawn_hunt_elite(cycle: int = -1) -> void:
    var target_cycle: int = cycle if cycle >= 0 else _current_cycle
    if _hunt_spawned_cycle == target_cycle:
        return                          # whichever event got here first already acted
    ...
    _hunt_spawned_cycle = target_cycle   # stamped only on a spawn that SUCCEEDED
```

Three details are load-bearing and none are obvious:

- **Both seams, not just the draw.** A modifier is drawn once per run; The Hunt spawns an elite every
  Cycle for the rest of it. Moving the trigger to `cycle_modifier_drawn` alone would have traded "one
  Cycle late" for "exactly one elite, ever".
- **Stamp with the event's `cycle`, never `_current_cycle`.** If the autoloads are ever reordered,
  the drawn handler runs before the cache is refreshed and a cached stamp would be off by one.
- **Stamp only on success.** A Cycle whose spawn was refused (no `EnemyWorld`, no ambient spawn
  point) stays unstamped, so the other seam can still satisfy it a moment later.

**2. `WaveSpawner`'s API, as it now stands.** `_maybe_spawn_hunt_elite(cycle: int = -1)` — the `-1`
sentinel reads the cached `_current_cycle` (a GDScript default cannot be a method call, same
convention as `cycle_count_multiplier(cycle: int = -1)`). New state `_hunt_spawned_cycle: int = 0`,
where `0` means "never this run" because a Cycle is always >= 1; `host_reset_for_new_run()` clears it
to **0, not 1** — a restarted run is Cycle 1 again, and a stamp left at 1 would swallow its first
spawn. `_exit_tree()` now drops `cycle_advanced` (missing since task 5.9) as well as the new
`cycle_modifier_drawn`.

**3. `cycle_modifier_drawn` has its first shipped subscriber.** Until now only
`tools/cycle_modifier_net_check.gd` listened, so `core/events/event_bus.gd`'s header claim that this
is "the seam for a REACTION to a draw" was untested in shipped code. It holds. On a client both this
and `cycle_advanced` are re-derived from `WorldDeltaLog` and may land in either order — the
idempotence above is what makes that safe, though `WaveSpawner`'s own `_owns_wave_director()` gate
means a client never reaches the spawn anyway.

**4. Proving a fan-out bug needs the real fan-out — pokes cannot see it.**
`tools/cycle_modifier_effects_check.gd` had proved this exact feature green while it was broken,
because `_check_the_hunt()` forced `_active_ids` and called `_maybe_spawn_hunt_elite()` by hand. Its
new `_check_the_hunt_on_the_drawn_cycle()` phase is the pattern to copy: narrow
`CycleModifierService._defs` to the one def under test, set `CycleService._current_cycle` to
`min_cycle - 1`, call the real `host_advance_cycle()` once, assert on `live_count()` deltas. Note the
`min_cycle` step — `the_hunt` is `min_cycle = 6`, so a check advancing from Cycle 1 draws nothing and
passes vacuously. **Nine other `tools/` checks still poke handlers directly on events with two or
three subscribers each: the list is in F-310, and `tools/run_identity_check.gd:113` shows the
one-line conversion (`session.emit_signal(...)`).**

### 2026-08-20 — F-279/F-298/F-308 resolved: a run restart teleports each peer CLIENT-side, and the two `run_restarted` handlers that gated on authority now split (lp)

**Rule: D-173.** Two things the next task in this area builds against.

**1. `PlayerHealth._on_run_restarted()` is split, and so is `InventoryService`'s.** The pattern, in
both files:

```gdscript
func _on_run_restarted() -> void:
    _reset_local_cache()          # EVERY peer — the fields nothing replicates back
    _teleport_local_to_spawn()    # PlayerHealth only; own movement is §2.2 row 1
    if _owns_mutation():
        host_reset_for_new_run()  # the host's world rebuild, unchanged
```

`run_restarted` reaches every peer (a client re-derives it from `WorldDeltaLog` through
`CycleService._on_world_delta_applied()`), so an authority gate at the top of one of these handlers
is correct only for state the host pushes back down afterwards. It was not, twice:
`_local_stamina`/`_sprint_locked_out` are client-simulated (F-298) and `_local_revision` is the
peer's private snapshot staleness guard (F-308). **If you add a `run_restarted` subscriber that gates
on authority, say in a comment which replicated field justifies it** — `grep -rn --include='*.gd'
subscribe_run_restarted .` and read each handler's first line; 22 subscribing files outside `tools/`, and
the only three that gate are the two above plus `CycleModifierService` (F-254), which already does.

**2. Never move a remote player's body from the host on a restart.** `PlayerHealth` now has two
teleports and they are not interchangeable:

| Call | Who runs it | When to use it |
|---|---|---|
| `_teleport_to_spawn(peer_id)` (private) | host, `rpc_id`s `net_force_respawn` to the owner | a **bleed-out respawn** — host-timed, the client cannot predict it |
| `_teleport_local_to_spawn()` (private) | every peer, on its own `run_restarted` | a **run restart** — the client already receives the event |
| `rebind_local_spawn(position, yaw)` (public, F-258) | every peer, for itself | a **new island** — moves the body *and* re-anchors the spawn record, both halves together |
| `host_place_player(peer_id, pos, yaw)` (public) | host | the `tp` console verb (COMMANDS.md §3.3) |

The host-driven form on a restart races the `run_restarted` delta on an unordered second reliable
stream, and on the procedural map it carries the **previous** island's shore to a remote peer (D-161
draws a fresh seed per run). Client-local makes the ordering intra-process: `PlayerHealth`'s handler
runs before `ProceduralWorld._replace_players()`, which then overwrites both body and spawn record
with the new island's, in the same synchronous emit.

**`tools/run_restart_spawn_check.gd` is new, and phase 2 is the reusable part.** Proving anything
about §2.2 row 1 needs a second process *and* a deliberate disagreement: the probe moves its **own**
spawn record 40 m with `rebind_local_spawn()` before the restart, so a host-driven fix would land it
on the host's stale copy and fail. Two traps it encodes, both of which make a naive check report a
clean HEAD as fixed:

- **Sample client-simulated state inside your own `run_restarted` handler, not by polling after it.**
  `PlayerController._physics_process()` ticks `local_tick_stamina(delta, false)` at 18/sec, so a
  drained probe is back to full in five seconds on its own. Subscribe after the autoload (any scene
  node is) and read in the handler; and re-drain every loop so the pre-restart state is real.
- **A GDScript lambda captures locals BY VALUE.** `await _until(func(): body = _local_player_body()
  …)` sets the copy; the outer `body` is still null. Re-fetch after the wait.

### 2026-08-20 — F-290 resolved: a `user://` file two processes share is written by RENAME, and the race now has a deterministic check (lp)

**The API to copy into any new two-process `--script` check.** Every driver/probe pair in `tools/`
shares one `user://` JSON file: child rewrites it in a loop, parent polls every 50 ms. The old
`FileAccess.open(RESULT_PATH, FileAccess.WRITE)` is truncate-then-refill, so a poll landing in that
window read an empty or half document, `JSON.parse_string()` `ERR_PRINT`ed `Parse JSON failed`, and
the run still printed `failures=0` and exited 0 — an undeclared `ERROR:` line, SPECS standing rule
4, invisible because the check passed. D-172. Write it this way instead:

```gdscript
func _write_result(result: Dictionary) -> void:
    var staging: String = RESULT_PATH + ".part"          # a SIBLING path, then rename over
    var file := FileAccess.open(staging, FileAccess.WRITE)
    if file == null:
        return
    file.store_string(JSON.stringify(result))
    file.close()
    DirAccess.rename_absolute(                            # rename(2) — one step, never torn
        ProjectSettings.globalize_path(staging), ProjectSettings.globalize_path(RESULT_PATH))


func _read_result() -> Dictionary:
    if not FileAccess.file_exists(RESULT_PATH):
        return {}
    var raw: String = FileAccess.get_file_as_string(RESULT_PATH)
    if raw.is_empty():                                    # belt to the rename's braces
        return {}
    var parsed: Variant = JSON.parse_string(raw)
    return parsed if parsed is Dictionary else {}
```

And the driver's startup cleanup removes `RESULT_PATH + ".part"` alongside `RESULT_PATH` — a run
killed mid-write leaves one behind. Where the same helper backs two paths (a probe result AND a
driver control file, as in `powerup_review_check`), derive `staging` from the `path` argument, not a
constant; both directions race.

**`tools/json_result_race_check.gd` is new, and it is the reusable artefact.** It spawns a child that
hammers one path for 2 s with a 256 KB payload — wide enough to make the truncate window
milliseconds instead of microseconds — while the parent samples every 1 ms and counts torn reads,
once per write strategy. Measured: plain truncate 25 and 16 torn per 284 samples across two runs;
`.part` + rename 0 and 0. The `atomic_torn == 0` assertion is the gate; the plain count prints as
evidence and is deliberately not a gate, because the window is load-dependent and a check that fails
on an idle machine is worse than the bug. **Authority: none** — it starts no `NetTransport` and
declares no §2.2 row.

**The one trap inside it, which is D-172's second half:** it reads with `JSON.new().parse()`, the
instance method, never the static `JSON.parse_string()`. The instance method returns an `Error`
silently; the static one prints. A check that counts malformed reads must not log an engine ERROR
per one it finds, or it fails its own standing-rule-4 grep exactly when its measurement succeeds.
This applies to any check exercising a corrupt-save or bad-payload path where the count is the
assertion.

**Swept and fixed under this claim** — `cycle_advanced_net_check`, `cycle_modifier_net_check`,
`enemy_net_check`, `run_restart_net_check`, `command_resolved_requests_check`,
`powerup_review_check`: every `tools/*.gd` whose writer runs inside a loop body. Already atomic and
left alone: `harvest_restart_check`, `attunement_restart_check`, `terminal_focus_check`. **Still
outstanding: F-304** carries the exact 27-file list of transports that write a handful of times
rather than in a loop — same defect, narrower window, mechanical fix, left unshipped because 27
two-process net checks is hours of engine-lock time and unverified transport edits are the worse
trade.

**Two pre-existing failures you will meet re-running these, neither introduced here.**
`run_restart_net_check` fails 1 on "restart returns the local player to the run spawn" — reproduced
identically by `agent baseline --rev HEAD`, and that is the already-open **F-279**.
`wave_spawner_check` emitted 6x `ERROR: Parameter "material" is null.` on one run and 0 on the next
in the same tree, with `agent baseline --rev HEAD` clean — intermittent, filed as **F-305**, and it
is F-290's own shape in a second check: an undeclared engine ERROR inside `failures=0`, exit 0.

### 2026-08-20 — F-288 resolved: `run_reseed_check` phase 5 asserts the FULL ordered POI layout, and the comparator proves itself before the parity is trusted (lp)

**What was wrong.** F-258's spec said phase 5 proved a rebuild is indistinguishable from a boot on
the same seed. What it asserted was `poi_sites.size() == poi_sites.size()`, labelled "...and the
identical POI count", under a preceding assertion labelled "byte-identical" that sampled the terrain
function at four points. No site's id, def, position, rotation, biome or scene path was compared in
either direction. A `rebuild_for_seed()` that kept every POI transform from the ended run reported
`RUN_RESEED_CHECK failures=0` — which is how F-286's marker consumers ended up inside a green result.

**The pattern to copy, in any check comparing two derivations** (D-171, and see F-287's entry below
for the same blind spot in `EnvironmentVfx`):

```gdscript
# 1. flatten the ordered record; read fields by explicit key, never compare Dictionaries wholesale
func _poi_layout(world: Node3D) -> Array:      # tools/run_reseed_check.gd
    # -> [[site_id, def_id, position, rotation_y, biome, scene_path, spacing, clearance], ...]

# 2. compare with deep Array `==` — exact floats, no fingerprint string to round drift away
check(rebuilt_layout == fresh_layout, "...field for field — %s" % _layout_diff(a, b))

# 3. and FIRST, prove the comparator can see a 0.001 rotation change on a duplicate
check(_layout_detects_perturbation(before_layout), "...a match below means something")
```

Step 3 is not ceremony. The bug class here is an assertion that proves nothing while printing PASS,
so a replacement that also proves nothing closes the finding and changes no facts. It is also the
standing substitute for pre-fix sabotage when the file you would need to break is held by another
lane — as `world/gen/procedural_world.gd` was for all of this task.

**Swept siblings, both fixed under this claim.** `tools/procedural_world_check.gd`'s "same seed
reproduces every POI site, position and order" compared `position` and `def_id` only, so a spun
landmark or a swapped scene path read as identical — now `_same_site()` over
id/def/position/rotation/biome/scene path. `tools/command_check.gd`'s "the printed message is the
same dump" was an entry-count compare — now one `JSON.stringify`/`parse_string` round-trip on both
sides (which normalises `StringName` and int-vs-float on the `data` side) and then a deep compare.
`atmosphere_night_check.gd` and `resource_scatter_check.gd` already walk every element and were left
alone; `poi_check.gd`'s rounding `_fingerprint()` is correct for the same-process determinism
question it asks, and is the thing NOT to copy for a cross-peer derivation guard.

**Verify:** `agent godot --script tools/run_reseed_check.gd` → `failures=0`, ending
`PASS: ...and an IDENTICAL POI layout, field for field — no field differs`. Siblings:
`tools/procedural_world_check.gd` → `failures=0`, `tools/command_check.gd` → `failures=0`.


### 2026-08-20 — F-287 resolved: `EnvironmentVfx` retires emitter sites with the props they came from, so an in-place reseed REPLACES its site set (lp)

**What was wrong.** F-258 rebuilds the island inside the existing current scene. `EnvironmentVfx`
invalidated only on a change of `current_scene`'s instance id, which that rebuild deliberately does
not cause, so every restart appended a whole island's emitter sites to the previous one's: 22 sites
→ 38 after one restart (all 21 old ones still registered) → 52 after a second. The fixed pools then
ranked ghosts against real props, so effects burned where nothing stood and new sites lost
nearest-first slots.

**The API you build against.** One new introspection call, alongside the existing
`site_counts()` / `pool_counts()` / `live_count()`:

```gdscript
EnvironmentVfx.site_positions() -> Dictionary   # AssetVfx.Emitter -> PackedVector3Array, copies
```

Use it in preference to `site_counts()` in any check about world *identity*. A count cannot tell a
replaced site set from an appended one — that blind spot is exactly what let this ship, and it is
the same blind spot `F-288` records in `run_reseed_check`'s POI phase.

**The invariant now maintained,** and what it costs you: a site lives exactly as long as the node it
was registered from is valid AND inside the tree. Pruned on `EventBus.run_restarted` (deferred) and
again on the existing quarter-second budget tick, so a teardown that announces nothing —
`ProceduralWorld.rebuild_for_seed()` driven straight from a check or a console reroll, a scatter
chunk streaming out, a prop freed mid-run — is retired within a tick without any new signal.
`emitter_site_count`, `fire_source_count` and `sway_asset_count` are therefore a **census of what
exists**, not running totals; assert on them accordingly. `foliage_mesh_count` is the exception and
still accumulates — it is a per-node tally with no per-node record behind it (36 → 62 across one
reseed). That is **F-303**; do not read it as a world census.

**Do not "simplify" this into a clear on `run_restarted` (D-170).** The authored map fires the same
signal and rebuilds nothing; its props all carry `VFX_META`, `_apply_node()` early-returns on that
meta, so a clear-and-re-walk skips every one of them and Hollowmere goes dark with no error.
`tools/environment_vfx_reseed_check.gd` plants a survivor prop outside the rebuilt subtree
specifically so that mistake fails a check instead of shipping.

**If you write a headless check against a procedural island, anchor the streamer yourself.** With
`build_player = false` (what `run_reseed_check` and this check both use) nothing calls
`ChunkStreamer.set_anchors()`, so no chunk reaches LOD0-with-collision, `ResourceScatterField` builds
no holder, and the island produces **zero** scatter — no harvestables, no emitter sites, no props.
This check measured exactly that on its first run and every island assertion in it was vacuous. Call
`streamer.set_anchors(PackedVector3Array([world.spawn_position]))` every frame and wait; the first
sites land in ~45 frames, a fresh ring after a rebuild in ~31.

**Verified:** `.agent/bin/agent godot --script tools/environment_vfx_reseed_check.gd` →
`ENVIRONMENT_VFX_RESEED_CHECK failures=0` (`RESTART before=22 after=17 shared=0 sway_assets=2`,
unchanged from the boot's 2); three siblings
re-run green — `ENVIRONMENT_VFX_CHECK foliage=8103 failures=0`,
`ENVIRONMENT_VFX_HOLLOWMERE_CHECK failures=0`, `RUN_RESEED_CHECK failures=0`.


### 2026-08-20 — F-284 resolved: both world builders answer `water_surface_at()`, and the contract matrix asserts a standable spawn on BOTH maps (lp)

**The new API you build against.** Both world scripts now answer the same *pair* of pure, read-only
questions, so anything asking "is this point dry, solid land" works on either map kind without
knowing which one it holds:

```gdscript
world.height_at(x, z)         # already existed on both — where the ground is
world.water_surface_at(x, z)  # NEW on both — where the water over it is
```

* `world/gen/authored_world.gd` — the public half of `_water_level`: every body in the layout's
  `water` array is tested and the highest covering surface wins, which is exactly the rule
  `_build_water()` meshes the surfaces with. Returns **`-INF`** where the map declares no water at
  that point, so guard with `is_finite()` rather than comparing against a sentinel.
* `world/gen/procedural_world.gd` — returns the new `SEA_LEVEL` const (`0.0`), the datum
  `IslandHeightmap` already measured every height against and which was written as a bare literal
  everywhere before. A generator that later grows inland lakes changes this one function, not its
  callers.

Use the pair, not `height_at()` alone, for any "above the waterline" question. A caller that treats
"no answer" as "no water" has rebuilt F-076's blind spot.

**What else shipped.** `tools/world_contract_check.gd`'s spawn assertion moved out of
`_check_procedural_specifics()` — where `if procedural:` meant the SHIPPED map asserted no spawn at
all — into a shared `_check_spawn_standable()` that runs on both arms. The authored map's spawn
source is the level's `Player` node (what `PlayerNet._claim_spawn_point()` reads), cross-checked
against the layout's own `spawn` record.

**The trap, if you write any check that reads a level's `Player` node (D-169).** It is a real
`CharacterBody3D` and it FALLS. Read after the usual 16 warm-up frames it reports where it *settled*
— Hollowmere's authored 2.423 measures as 2.023 — so a vertical assertion against it grades gravity,
not the map. Capture the transform off `packed.instantiate()` **before `add_child()`**.
`tools/hollowmere_check.gd` and `tools/playtest_hollow_check.gd` were both one vertical assertion
away from this and now capture pre-`add_child` too.

**Live and NOT yours to inherit as a regression:** the procedural arm of that matrix fails
intermittently at a clean HEAD with *"no REGISTERED station marker"* — seeds 3503374054 and
3803646258 genuinely publish zero station markers. That is **F-301**, filed with the measurement.


### 2026-08-20 — F-280 resolved: `run_started` is a per-RUN public hook event, not a per-process one (lp)

**What shipped.** `CycleService._run_started_emitted` is now RUN-scoped. `host_restart_run()` clears
it and re-emits, so the public `run_started` HookDef event (`CommandService._HOOK_EVENTS`) fires at
the start of EVERY run in a lobby. It shipped one-shot under F-154 — correctly for its own time, a
run's lifetime was the process lifetime — and F-243's play-again flow made that silently wrong: an
enabled user-authored `run_started` hook ran on boot and then never again, with no error and no log
line.

**The API, unchanged in shape and now correct in lifetime:**

```gdscript
CycleService.run_started                  # signal(); host/solo only; fires once per RUN
CycleService._emit_run_started() -> void  # the SINGLE emit site; _owns_cycle()-gated; idempotent
                                          # within a run. Never emit `run_started` anywhere else.
```

**Do not relitigate the two seams (D-168).** They are different events, not two names for one:

- **`CycleService.run_started`** — PUBLIC vocabulary for scenario authors, in `_HOOK_EVENTS`, fires
  at the START of every run. Bind hooks to this.
- **`EventBus.run_restarted`** — PRIVATE service-to-service, fires only on a RESTART, means "throw
  the ENDED run's state away". Nothing in `_HOOK_EVENTS` binds it and nothing should — it has no
  first-run counterpart, so a hook on it would miss the first run and a service on `run_started`
  would try to clear state that does not exist yet.

**Emit order inside `host_restart_run()` is contract.** `run_restarted` FIRST (its subscribers tear
the ended run down), then `_announce()`, then `run_started` LAST — a hook body is arbitrary user
command script and has to observe the run it is named after: Cycle 1 recorded, modifiers cleared,
inventories empty, the new seed live. If you add anything to that method, it goes ABOVE the
`_run_started_emitted = false` line. `tools/run_started_hook_check.gd` asserts this as a property
(the listener snapshots `current_cycle()`, `host_count()` and `defeated` at emit time), so reordering
fails a check rather than quietly changing what every shipped hook sees.

**New check to build on:** `tools/run_started_hook_check.gd` — 28 PASS, `failures=0`. Boots the
shipped map, wires a synthetic `HookDef` through the real `wire_hook()` front door bound to a
function that ops a sentinel peer, then drives TWO real defeat-and-restart cycles (`deop`ping the
sentinel in between) and asserts the hook body ran for each new run. It is the pattern to copy for
any future per-run public event: assert the HOOK ran, not just that the signal fired. The
guard-still-holds cases are in there too — a Cycle advance and a refused mid-run restart must not
fire it.


### 2026-08-20 — F-277 resolved: an Attunement selection is run-scoped, and every peer re-arms its own picker for the new run (lm)

**What shipped.** `AttunementService` had no `run_restarted` subscription at all, while the
`PowerupService` stack its pick grants was already cleared by that event (F-243). Run two therefore
began with the Attunement's effect gone and `_process_selection()` still refusing every new pick as
"already selected", on a picker that never reopened because `AttunementUI` stops its D-071 poll timer
permanently after the first pick. Both halves are fixed; D-167 settles that the lock is run-scoped.
This closes item 1 of F-281 — its enumeration is now empty.

**Seams the next task builds against.**

```gdscript
AttunementService.host_clear_selection(peer_id: int) -> bool  # erase + broadcast &"" + emit; host-only
AttunementService.host_clear_all() -> int                     # every peer, on run_restarted; D-164's name
AttunementUI.is_picking() -> bool
AttunementUI.operable_button_count() -> int                   # what decides whether a no-dismiss panel is stuck
AttunementUI.pending_request_seconds_left() -> float          # F-297's bounded wait, 0.0 when idle
AttunementUI.expire_pending_request_now() -> void             # debug seam, like the existing poll_now()
```

`host_clear_selection()` is the erase + `net_attunement_selected(peer, &"")` broadcast +
`selection_changed` emit that `_on_run_player_expired()` used to open-code; that handler now calls it.
**Clear per peer, never by wiping `_selections`** — the per-peer `selection_changed` is what re-arms
each peer's picker, and a bulk wipe emits nothing.

**The rule beyond this file — a UI that re-arms on a run boundary must not key on the run event
alone.** `AttunementUI` re-arms from **both** `EventBus.run_restarted` and
`AttunementService.selection_changed`, because on a client the host's clearing broadcast and the
client-side re-derived `run_restarted` ride different channels and land in either order. The re-arm
is guarded on the local selection actually being empty, so whichever arrives second is a no-op.
Keying only on `run_restarted` passes a single-process check and loses the race on a real client
about half the time. D-167.

**And it must open DEFERRED.** `run_restarted` subscribers run synchronously in autoload registration
order; `AttunementUI` sits ahead of `DefeatHud`/`ExtractionHud` in `project.godot`, both of which
restore `Input.mouse_mode` to `CAPTURED` in their own handler. Opening inside that emit samples the
terminal overlay's VISIBLE cursor as "what to restore afterwards" and then loses the mouse to the HUD
— on a panel whose only mouse control is a CHOOSE button. `_rearm_for_new_run()` therefore calls
`_poll_for_local_player.call_deferred()`.

**F-297 fixed in the same file** (its own text named F-277's owner): `_picking` is now a bounded wait
— `choose()` arms a one-shot 8-second Timer, any `selection_confirmed` disarms it, an expiry
re-enables every CHOOSE button and says why. A mandatory panel — no Esc, in `blocks_gameplay_input` —
must never be able to reach zero operable controls. Panels with a dismiss path (`chest_ui.gd`,
`crafting_ui.gd`) do not need this; the dismiss path is the bound.

**New check — `tools/attunement_restart_check.gd`** (`ATTUNEMENT_RESTART_CHECK failures=0`, 49 PASS).
Phase 1 solo on the shipped map drives the real `DefeatService.defeated` → `host_restart_run()` path
and asserts run two is genuinely pickable, focus included. Phase 2 is a real second process because
the host-clears/each-peer-re-arms split is invisible to one: a joined client picks over the wire, the
host restarts three times, and the client reports its own selection and its own picker each time,
then picks a *different* role over the wire — the assertion that proves the host's lock lifted for a
remote peer. Its F-297 sub-phase sends a request and really `leave()`s so the answer can never
arrive, rather than simulating a timeout.

**Harness lesson worth copying.** A check that calls a seam the fix *adds* aborts its own coroutine
on a pre-fix build, so the pre-fix proof stops after three assertions instead of showing the bug.
Wrap those calls in `has_method` guards and let them degrade to a sentinel: this check goes from
`failures=18` at HEAD to `failures=0` after, and those 18 are exactly the finding's symptoms on both
sides of the wire.

### 2026-08-20 — F-278 resolved: the day/night clock is run-scoped, and a client SNAPS to a host jump instead of interpolating backwards through it (lp)

**What shipped.** `systems/environment/day_night.gd` subscribes `run_restarted` and resets
`time_of_day` to the authored run-start morning. The clock was the last unreset item in D-149's
enumeration with a live gameplay consequence: a run ends at night, so the next run started mid-night,
the day COUNT (`CycleService._days_elapsed`, zeroed by `host_restart_run()`) disagreed with the clock
from frame one, and `WaveSpawner` got no fresh `night_started` edge because that crossing happened
during the PREVIOUS run — F-259 cleared the latch, and clearing a latch cannot re-fire a signal.

**Two seams the next task builds against.**

```gdscript
DayNight.run_start_time_of_day() -> float   # the authored morning, captured in _ready() before
                                            # anything moved the clock. Assert against this rather
                                            # than re-typing 0.348.
DayNight.CLIENT_SNAP_THRESHOLD: float = 0.1 # a push this far from the last one is a JUMP, not a tick
```

**The rule that matters beyond this file — an unreliable state push can overtake the reliable event
that explains it.** `net_push_time` is unreliable; `run_restarted` reaches a client over
`WorldDeltaLog`'s reliable ordered channel, which is head-of-line blocked behind everything else in
it. So the reset push routinely lands FIRST, while `_client_target_time` still holds the ended run's
night, and `_lerp_wrapped_unit()` takes the shortest way round — backwards through dusk and the
afternoon the player just played. Snapping the interpolation source from the `run_restarted` handler
is therefore necessary but **not sufficient**; measured at 5 smeared frames with that handler already
in place. The receiver has to infer the discontinuity from the value itself. Do not design a system
whose correctness depends on the reliable event winning that race. D-166.

Adding a "this is a jump" parameter to the RPC would not have worked *and* would have cost a
`PROTOCOL_VERSION` bump — `core/net/rpc_manifest.gd` scans RPC shape. `core/net/remote_interp.gd`
already carried this exact pattern for player transforms as `TELEPORT_DISTANCE_M`; DayNight was the
outlier, so the shape is house style, not an invention.

**Do not route the reset through `host_set_time()`** (D-166). That seam crosses thresholds on
purpose, and `day_started_at` (0.25) sits between a night-time run end and the 0.348 morning, so it
would fire `day_started` and hand `CycleService` a phantom elapsed day against the counter
`host_restart_run()` just zeroed. `tools/day_night_restart_check.gd` asserts the ABSENCE of both
signals across two restarts, so that regression fails loudly.

**New check — `tools/day_night_restart_check.gd`** (`DAY_NIGHT_RESTART_CHECK failures=0`, 23 PASS).
Phase 1 solo: two restarts from 0.80, clock back to 0.348 each time, no threshold signal fired,
`days_elapsed_this_cycle()` still 0, and a forward advance then crosses `night_started` exactly once.
Phase 2 is a real second process, because the host branch of `_physics_process()` never touches the
interpolation fields and no single process can observe a smear at all: the client samples its own
clock EVERY FRAME across the restart and reports any frame inside a band only backwards
interpolation can reach.

**One existing check was wrong, not just incomplete.** `tools/run_restart_net_check.gd`'s F-278
assertion was `is_equal_approx` on a RUNNING clock two awaited frames after the restart — a
900-second day advances ~1.9e-5 per tick, twice `CMP_EPSILON`, so it could never have passed against
any correct fix. Now a 0.001 band with the value printed. **If you are writing an assertion about a
value some system advances every tick, a tolerance is not sloppiness — exact equality is the bug.**

**F-281 is now down to one item.** Its enumeration listed `DayNight.time_of_day` (this, item 3),
`HaulService`'s haulables (F-268's commit, item 2) and `AttunementService._selections` (item 1, still
open and now F-277's). Only item 1 remains.

**Filed: F-298**, from this task's sweep of every `"unreliable"` RPC —
`PlayerHealth._on_run_restarted()` is gated on `_owns_mutation()`, so a client never reaches
`_reset_local_cache()` and carries its own client-simulated stamina and sprint lockout into the next
run. Same file and same handler as F-279; best fixed together.

### 2026-08-20 — F-275 resolved: both terminal run-summary overlays are operable from a bare controller, and the non-host's waiting label is inert rather than dead-focused (lm)

**What shipped.** F-243's "Start Next Run" button existed on both terminal screens
(`ui/hud/defeat_hud.gd`, `ui/hud/extraction_hud.gd`) and neither screen focused it. Both are
mandatory panels — no Esc, no dismiss, that button is the only way off — so with no mouse the run
loop ended there. The same trap F-216 fixed for `AttunementUI`, now closed for the pair.

**The convention the next UI task builds against — `disabled` is not `FOCUS_NONE`.** A disabled
`Button` in Godot still answers `grab_focus()`, still draws a focus ring, and still lands in a
`focus_neighbor_*` walk. Any panel that shows a control only *some* peers may act on needs both:

```gdscript
_restart_button.disabled = not is_local_host
_restart_button.focus_mode = Control.FOCUS_ALL if is_local_host else Control.FOCUS_NONE
```

and the grab itself goes **after** `visible = true`, never before — Godot force-releases focus from a
Control that is not visible in the tree, so an earlier grab is silently thrown away. Every panel in
`ui/` already orders it that way; this is the house pattern, not a new one.

**The check to extend, not to re-derive:** `tools/terminal_focus_check.gd` →
`TERMINAL_FOCUS_CHECK failures=0` (24 PASS). Phase 1 drives both overlays solo through their real
triggers and taps a real `InputEventJoypadButton` through `Input.parse_input_event()`, asserting
`run_restarted` actually fires — the assertion that proves a controller can leave the screen. Phase 2
spawns a second process that joins this one, because `_is_host_or_solo()` reads live `NetTransport`
state and the only honest way to test the non-host branch is to be a non-host. Its result file is
written to a temp path and renamed into place, so a polling driver cannot read a torn document
(F-290's failure mode, not repeated). Any later task touching either overlay's button, or adding a
third terminal screen, extends this file rather than writing a fourth restart check.

### 2026-08-20 — F-274 resolved: a biome now shapes its own ground everywhere the game builds it, and the amplitude pair crossfades instead of stepping (lm)

**What shipped.** D-144's seam had been built and never crossed: `BiomeMap.terrain_amplitudes()` had
no shipped caller, so `chunk_mesher.gd`, `poi_map.gd`, `resource_scatter.gd` and
`ProceduralWorld.height_at()` all took `height()`'s 1.0/1.0 defaults and every biome got the same
biome-blind ground. `shore.tres`'s six authored numbers moved the audit PNG and nothing else. They
now move the mesh, the collider, the navmesh, a landmark's feet, a tree's feet and a spawn query.

**The API the next task builds against.**

```gdscript
# world/gen/island_heightmap.gd — the biome-INDEPENDENT half, computed once and reused.
class Shape:  # bent: Vector2, mask: float, raw_continent: float, channel: float
static func shape_into(x, z, set: NoiseSet, world_seed: int, out: Shape) -> void
static func continent_from_shape(shape: Shape) -> float
static func height_from_shape(x, z, shape, set, detail_amp := 1.0, ridge_amp := 1.0) -> float
# Neither `_from_shape` takes a `world_seed` — everything seed-derived that finishing a sample
# needs (the mask, and `channel`, the cached river ceiling) is already in the Shape. `channel` is
# that cache; it is why the carve costs one polyline walk per sample instead of two, and it is the
# field the cost note at the bottom of this entry tells you not to remove.
# `continent()`, `continent_from_set()`, `height()`, `height_from_set()` all funnel through these
# now, so there is exactly one body of the formula. `_continent_with()` is gone.

# world/gen/biome_map.gd — THE surface. Every shipped "how high is the ground" call goes here.
class TerrainTable            # the authored defs flattened to plain floats, sorted by id
static func make_terrain_table(biome_defs: Array) -> TerrainTable
static func blend_amplitudes(continent_height, moisture_value, table) -> Vector2
static func surface_from_set(x, z, set: NoiseSet, world_seed, table, shape := null) -> float
static func surface_at(x, z, world_seed, biome_defs) -> float        # one-shot, builds both

# world/chunk/chunk_mesher.gd — biome_defs is REQUIRED, and sits BEFORE the optional lod.
static func build_mesh(chunk_x, chunk_z, world_seed, biome_defs: Array, lod := 0) -> ArrayMesh
static func build_mesh_surface_tool(chunk_x, chunk_z, world_seed, biome_defs: Array) -> ArrayMesh
```

**Where the table comes from.** `ProceduralWorld._load_biome_defs()` reads `Registry.biomes` ONCE
per world build into `_biome_defs`, and hands the same Array to `ChunkStreamer.biome_defs` (which
`ChunkJob` carries into the worker task), `PoiMap`, `ResourceScatter` and `height_at()`. `NavBaker`
adopts the streamer's in `bind()` rather than being given one, so it cannot be baking a different
island from the one the collider describes. If you add a consumer of ground height, take the table
from `ProceduralWorld`; never read the Registry again for it.

**For a tool or check:** `tools/biome_defs_lib.gd` → `load_defs(self)`. Registry first, a scan of
`content/biomes/*.tres` as the fallback for a harness with no autoloads (F-011). A tool that
deliberately wants the biome-blind surface passes `[]` and says why.

**Two rules D-165 settles, so they do not get relitigated.** The pair is a weighted BLEND across
biome boundaries, not the winning biome's own — picking puts a ~7.7 m vertical wall along the
`moisture = 0.5` contour where forest meets grassland. And `build_mesh()`'s `biome_defs` has no
default, because a default that silently yields a real-looking wrong surface is precisely what
F-274 was; `tools/biome_terrain_check.gd` asserts on the signature itself.

**What it costs.** `tools/bench_chunks.gd` single-threaded mean: 5.956 ms/chunk before, 8.077 ms
after (1.36x) — one moisture sample and a table scan per vertex. If you are about to "optimise" this
by not caching the river channel on `Shape`, do not: without it the carve walks the polyline twice
per sample and the number is 10.697 ms. The remaining per-sample allocation (`lobes()`,
`islet_centres()`, `river_polyline()` rebuilt per point) is F-294. Streaming is unaffected — this is
`WorkerThreadPool` work and the streamer's own per-frame cost is still 0.2007 ms mean.

**Proof.** `agent godot --script tools/biome_terrain_check.gd` → `BIOME_TERRAIN failures=0`.
Neighbours green: `worldgen_noise_reuse_check` 0 (with `GOLDEN_BIOME` and `terrain_hash
c20eed19b44270a1` deliberately UNCHANGED, and POI/amplitude/scatter goldens re-captured),
`noise_reuse_check` PASS, `terrain_look_check` 0, `terrain_check` 0, `poi_check` 0, `biome_check` 0,
`resource_scatter_check` 0, `procedural_world_check` 0, `world_contract_check` PASS,
`chunk_stream_check --windowed` 0 functional failures. Audit render:
`assets/audit/terrain/island_f274_20260819.png`.


### 2026-08-20 — F-268 resolved: the restart actually clears placed buildables, and HaulService gets the same wiring it had been missing alongside it (lp)

**Claim:** `autoload/build_service.gd`, `autoload/haul_service.gd`, `tools/run_restart_check.gd`,
`docs/SPECS.md`, `docs/DELEGATION.md`. Authority unchanged — §2.2 "world mutation" and "Carryable
objects", both HOST. No new RPC, no `PROTOCOL_VERSION` bump, no new check tool.

**Two new public methods, same name on purpose.** A third spawner-backed autoload should be findable
by grepping one spelling, not by reading three files for three ideas:

```gdscript
BuildService.host_clear_all() -> void   # frees every placed piece node, then clears `_placed`
HaulService.host_clear_all()  -> void   # frees every haulable in the replicated container
```

Both are host-guarded on their file's existing `_owns_mutation()` and both are called
unconditionally from a new `_on_run_restarted()`, so every peer's copy may run and only the host's
frees anything — the convention every other `run_restarted` subscriber follows. Subscribe in
`_ready()`, unsubscribe in `_exit_tree()`.

**The rule the next such service inherits, now D-164: free the nodes, do not merely forget them.** F-243's own
check had been failing at a clean HEAD since the feature shipped, on `every placed buildable was
cleared`, because `BuildService` had no `run_restarted` subscription at all while three separate
places asserted it did. Emptying `_placed` would have made that assertion pass and left the bug: the
pieces are `MultiplayerSpawner` children, and a spawner replays every LIVE spawn to a newly connected
peer (`core/net/net_session.gd`) — so the despawn replicates because the host frees the node, not
because the host stopped tracking it. `host_clear_all()` also emits `piece_destroyed` per piece,
because `NavBaker` tracks placed geometry off that signal (F-159) and has no `run_restarted`
subscription of its own. Neither method refunds, matching `host_piece_destroyed_by_damage()`:
`InventoryService` empties every inventory off the same signal.

**F-281 is now one third smaller.** Its enumeration lists `DayNight.time_of_day`, `HaulService`'s
haulables and `AttunementService._selections`; the haulables third is done here, found independently
by F-268's own sweep. The other two are untouched and still that finding's. HaulService's fix is
**latent, not live** — `host_spawn()` still has no shipped gameplay caller (only `tools/haul_check.gd`
and `tools/haul_net_check.gd`), so nothing in a real run strands a crate yet. It is wired anyway
because the wiring is precisely the half that gets forgotten.

**Audited and genuinely wired**, so nobody re-walks this list: MireGrid, CycleModifierService,
PowerupService, InventoryService, PlayerHealth, EnemyWorld, DefeatService, Wellspring, Chest,
ExtractionShip, plus WaveSpawner / ProceduralWorld / ResourceScatterField, which
`cycle_service.gd`'s F-243 header does not name. All 15 `subscribe_run_restarted` sites have their
matching `unsubscribe`. `CraftingService._station_positions` and `EnvironmentVFX._sites` are NOT the
same shape — both self-invalidate on a scene-id/census change, so a regenerated island rebuilds them
with no subscription. `UnlockService._purchased` persists across runs by design (meta-progression).

**`tools/run_restart_check.gd` gained four assertions, not a new tool.** Two of them exist because
`placed_count() == 0` cannot tell a freed piece from a forgotten one: the replicated `Buildings`
container's own child count is 0, and no `&"buildable_piece"` node survives anywhere in the tree.
The other two seed and clear a haulable. `.agent/bin/agent godot --script tools/run_restart_check.gd`
-> `RUN_RESTART_CHECK failures=0` (was `failures=1` at HEAD). Regression: `tools/build_check.gd` and
`tools/haul_check.gd`, `failures=0` each.

**`tools/nav_bake_check.gd` fails 4 and it is not this — filed as F-285.** `agent baseline --script
tools/nav_bake_check.gd` at `a28f346` yields the byte-identical four FAIL lines. Compare the FAIL
LINES, not the count: a matching count across two runs of a check with a dozen assertions is not
evidence that the same things failed.

### 2026-08-20 — F-271 resolved: biome classification obeys D-144 in scatter too, and worldgen gained a fourth layout tripwire (lm)

**Claim:** `world/gen/resource_scatter.gd`, `tools/resource_scatter_check.gd`,
`tools/worldgen_noise_reuse_check.gd`, `world/gen/biome_def.gd`, `world/gen/poi_def.gd`.

**The rule, if you are writing anything that needs a point's biome (D-163):**

```gdscript
# Yes — the ONE correct way, in both flavours.
BiomeMap.biome_at(x, z, world_seed, biome_defs)
BiomeMap.biome_at_from_set(x, z, set, world_seed, biome_defs)   # many points, one set

# No. `assign()` is a primitive; outside biome_map.gd and biome_check.gd's unit tests
# nothing should call it, and NEVER with height().  D-144: a biome is decided from the
# CONTINENT, the biome-independent half of the surface.
BiomeMap.assign(IslandHeightmap.height_from_set(...), moisture, biome_defs)
```

Having the surface height already in a local is not a reason to reuse it — that is exactly how F-271
happened. `resource_scatter.gd` now samples both, side by side, so the distinction is visible at the
call site: `biome_at_from_set()` decides the biome, `height_from_set()` supplies `position.y` only.
The biome gate also moved above the height sample, so a rejected candidate no longer pays for a
surface sample it discards; neither test touches `rng`, so the per-point stream is unchanged.

**`PoiDef.height_min`/`height_max` are the deliberate exception** and stay on `height()` — a
landmark's height constraint is about the ground its feet land on. `BiomeDef`'s bounds are
CONTINENTAL metres. Both doc comments now say which surface they mean and point at the other; before
F-271 both said "Metres, in IslandHeightmap.height()'s units" and one of them was wrong.

**`tools/worldgen_noise_reuse_check.gd` now carries a fourth golden, `GOLDEN_SCATTER`** — the
placement id / asset / position hash over an 8x8 chunk block, for the same five seeds as the other
three. Scatter had no layout witness of its own, which is why this defect survived F-252 and F-261
rewriting the file around it. Treat it exactly like `GOLDEN_POI`/`GOLDEN_BIOME`/`GOLDEN_AMPLITUDES`:
a refactor that claims to move nothing must leave it alone, and one that deliberately moves scatter
re-captures it and says so. It is captured POST-F-271; the pre-fix values are recorded in the
constant's own comment.

Checks: `agent godot --script tools/resource_scatter_check.gd` → `failures=0`;
`--script tools/worldgen_noise_reuse_check.gd` → `failures=0` (the other three goldens UNCHANGED,
which is the proof this task moved scatter and only scatter); `--script tools/check_determinism.gd`
→ `terrain_hash c20eed19b44270a1`, unchanged.
Spec: `docs/SPECS.md` F-271. Decision: **D-163**.

### 2026-08-20 — F-269 resolved: the findings queue has a failing check now, not a warning — `tools/findings_hygiene_check.py`, plus D-162's bar for what "resolved" means (lp)

- **`python3 tools/findings_hygiene_check.py`** → `FINDINGS_HYGIENE_CHECK failures=N`, exit 1 on any
  failure. Add it to any docs-touching task's verification; it takes no lock and needs no engine, so
  it costs nothing to run next to whatever else you were running.
  `--self-test` proves both detectors on synthetic docs (4 cases) instead of scanning the repo.
- **It calls the harness's own detectors, imported, not reimplemented** —
  `.agent/bin/agent`'s `_findings_drift()` (marked done in `state.json`, still under `## Open`) and
  `_self_resolved_findings()` (the entry's own prose says fixed and nothing moved). `agent start`
  has always *printed* both; this fails on them. If you extend either rule, extend it in
  `.agent/bin/agent` and both readers move together — a second copy here is the two-records-of-one-fact
  bug (F-071) that this whole area exists to fix. The import uses an explicit `SourceFileLoader`
  because `.agent/bin/agent` has no `.py` suffix.
- **Duplicate F-numbers stay with `tools/findings_numbering_check.gd`**, and duplicate *D*-numbers
  are unowned by anything. The three live collisions this line named are resolved (F-283).

**D-162 — the bar for closing a finding, and the thing to read before you argue about one:** a
finding resolves when the defect *its own text asserts* is false at HEAD, not when the area is
perfect. Gaps found while fixing it live as their own findings, cited by number in the resolution
note. Corollaries: a finding whose own text says part of it is unfixed does **not** resolve
(F-236 — `content/ranged_weapons/` is still one file), and neither does one whose fix was
deliberately deferred to design (F-267 — `cmd_ship` still stages claimed files in full). Both were
**reopened**, which clears the drift by correcting the status rather than by moving the section
(F-131). `agent done` is routinely used to mean "my session ended"; that is not the same fact.

**Closing a finding, mechanically** — neither `docs/FINDINGS.md` nor `docs/DECISIONS.md` should ever
appear in your claim set:

    agent resolve F-NNN <<'EOF'   # note on stdin: what you did AND how you verified it
    agent reopen  F-NNN "why it is not actually resolved"
    agent decision "title" <<'EOF'   # allocates the next D-NNN under a lock

`docs/FINDINGS.md` is deliberately unclaimed (F-006) and all three commands take their own lock;
`agent decision` additionally refuses while someone holds an exact claim on `docs/DECISIONS.md`.
Claiming either file for a task's length is F-262's bug. **File before you cite:** this task's
resolution note cited `F-282` for a finding the allocator then numbered **F-283**, because a
concurrent lane took 282 in the same window.

**After any batch of moves, run `agent godot --script tools/findings_numbering_check.gd`.** F-134's
failure mode is a move that eats the `## Resolved` heading and silently flips every resolved finding
to open; at HEAD the healthy numbers are `open=26 resolved=259 failures=0`.

**F-243 is resolved and its residue is not** — if you are working anywhere near the run restart, the
open follow-ups are F-268, F-275, F-276, F-277, F-278, F-279, F-280, F-281. At HEAD
`tools/run_restart_check.gd` fails 1 (F-268, buildables) and `tools/run_restart_net_check.gd` fails
8, all eight mapping to that list. Those two numbers are the current baseline: a check of yours that
reports them is not regressing anything.


### 2026-08-20 — F-259 resolved: WaveSpawner joins F-243's restart — the roster, the night latch, and the ambient field it suppressed (lp)

- **`WaveSpawner.host_reset_for_new_run() -> void`** — host-guarded, already wired to
  `EventBus.run_restarted`. Clears `_unlocked_pool` (so `host_unlock_next_enemy()` can widen the
  roster again — a stale full pool froze it permanently), clears `_night_active` **and restores the
  `EnemyWorld.ambient_enabled` value the night wave suppressed**, drops the `the_hunt` elite ref, and
  re-seeds `_rng` from `GameState.ensure_seed() ^ DEFAULT_SEED`. `roster_order` is an export and is
  NOT touched: exports are Gamerule/inspector values, never run state.
- **If you add run-scoped state to a service, add it to the restart in the same commit.** F-243's
  enumeration (D-149) has now been short three separate times — F-258 (seed), F-259 (this),
  F-268 (buildables) — and F-281 lists three more still open (`DayNight.time_of_day`,
  `HaulService`'s haulables, `AttunementService._selections`, that last one a real desync: the pick
  survives, the `PowerupService` stack it granted does not). The seam is one line:
  `EVENT_BUS.subscribe_run_restarted(_on_run_restarted)` in `_ready()`, `unsubscribe` in
  `_exit_tree()`.
- **Restoring beats re-running.** The reset puts `ambient_enabled` back by hand instead of calling
  the existing `host_stop_wave()`, because that path also queues a `_refill_daytime()` that both
  races `EnemyWorld._on_run_restarted()`'s despawn (subscriber order = autoload registration order)
  and does a job the ambient loop already does on its own cadence. A reset should undo what it
  suppressed, not re-drive the systems it sat on top of.
- **`tools/run_restart_check.gd` is the restart's one check** and now covers WaveSpawner; it fails
  `failures=1` at HEAD on `every placed buildable was cleared` (F-268, another lane's, pre-existing).
  Seed your state in phase 2, assert it cleared in phase 4, and assert it is USABLE again in phase 5
  — "reset to empty" and "reset to working" are different claims, and the second is the one that
  catches a frozen unlock path.

### 2026-08-20 — F-258 resolved: a run restart draws a FRESH world seed and re-broadcasts it to already-connected peers, over the delta channel that was already there (lp)

**The APIs the next task builds on** (all host-only unless noted):

- **`GameState.host_redraw_seed() -> int`** — mid-run draw of the next run's seed. Fires `seed_ready`.
  Does not re-consume a staged `--seed=`/menu override. **Whoever calls it owns the broadcast** —
  in practice, always call `WorldDeltaLog.host_reseed()` with the result.
- **`WorldDeltaLog.host_reseed(seed_value: int) -> void`** — clears the whole delta log (every record
  in it is keyed to the ended island's chunks) and broadcasts the new seed to every ALREADY-connected
  peer on the existing `net_delta_applied`. **No new RPC, no `PROTOCOL_VERSION` bump** — the record is
  `(SEED_CHUNK = Vector2i.ZERO, SEED_KIND = &"world", SEED_KEY = "seed")`, and `net_delta_applied`
  routes exactly that triple to `_reseed_local()` instead of `_apply()`. `rpc_manifest_check` stays
  green at v21/55 RPCs. **If you add a `kind` to this log, do not use `&"world"`.**
- **`PlayerHealth.rebind_local_spawn(position: Vector3, yaw: float = NAN) -> void`** — CLIENT-LOCAL
  (§2.2 row 1), not host. Places this peer's own body AND rebinds the respawn transform F-063
  captures, in one call because either alone is a bug. `NAN` keeps current facing.
- **`ProceduralWorld.rebuild_for_seed(seed_value: int) -> void`** — re-derives streamer, nav, scatter,
  POI and spawn in place; already wired to `run_restarted`. Public so a future "reroll" console verb
  can drive it without faking a restart. A rebuilt island is byte-identical to one BOOTED on that
  seed (asserted).
- **`ResourceScatterField.clear_depletion_memory() -> void`** — already wired to `run_restarted`.

**The ordering contract inside `CycleService.host_restart_run()`, do not reorder:** reseed →
`emit_run_restarted()` → `RUN_KIND`/`KIND` records → `_announce()`. The wipe must precede this file's
own records or it eats them; the reseed must precede `run_restarted` or every subscriber that
re-derives from the seed reads the run that just ended. On a client the same order arrives free —
one reliable ordered channel, seed then run.

**What did NOT need changing, and why that matters if you touch worldgen:** anything reading the seed
through `GameState.ensure_seed()` at CALL time (`CycleModifierService`, `RewardService`, `MireGrid`)
or taking it as a parameter (every `world/gen` pure function) re-derives for free. Cache the seed in a
member at `_ready()` and you have re-created the bug — the three that do (`ChunkStreamer`, `NavBaker`,
`ResourceScatterField`) are only safe because `ProceduralWorld` rebuilds all three.

**Still true:** the shipped map is authored (`levels/hollowmere.tscn`), so no seed moves its terrain
or markers. The fresh-island half is live only on `ProceduralWorld` until 4.19's cutover (F-139).

Check: `.agent/bin/agent godot --script tools/run_reseed_check.gd` → `RUN_RESEED_CHECK failures=0`.
Spec: `docs/SPECS.md` F-258. Decision: **D-161**.

### 2026-08-19 — F-261 resolved: `BiomeMap.NoiseSet` closes the last three per-sample noise rebuilds — POI placement, moisture, and the terrain render (lm)

**Claim:** `world/gen/biome_map.gd`, `world/gen/island_heightmap.gd`, `world/gen/poi_map.gd`,
`world/gen/resource_scatter.gd`, `tools/terrain_map_render.gd`, `tools/worldgen_noise_reuse_check.gd`
(new).

**The API a worldgen caller now builds against.** F-241 gave the heightmap a `NoiseSet`; F-261 gives
the biome layer its own, which NESTS the heightmap's rather than folding into it (**D-160**):

```gdscript
# One set per island / per chunk / per render — NEVER one per sample, and never shared
# across WorkerThreadPool tasks (a FastNoiseLite is not safe to sample from two at once).
var set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed)
BiomeMap.moisture_from_set(x, z, set)                                  # no world_seed — the set is enough
BiomeMap.biome_at_from_set(x, z, set, world_seed, biome_defs)
BiomeMap.terrain_amplitudes_from_set(x, z, set, world_seed, biome_defs)
BiomeMap.amplitudes_for(biome_id, biome_defs)                          # for a caller holding a resolved id
IslandHeightmap.continent_from_set(x, z, set.island, world_seed)       # set.island is the F-241 set
IslandHeightmap.height_from_set(x, z, set.island, world_seed)          # reach through for heights

# Already holding an IslandHeightmap.NoiseSet? Hand it over — it is ADOPTED, not copied,
# so a chunk still constructs each field exactly once (resource_scatter.gd does this).
var set2: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed, existing_island_set)
```

**One caveat on `terrain_amplitudes*` / `amplitudes_for` before you build on them: they have no
shipped caller.** `chunk_mesher.gd`, `poi_map.gd` and `resource_scatter.gd` all take `height()`'s
1.0/1.0 defaults, so every biome's authored `detail_amplitude`/`ridge_amplitude` is currently inert
and only `tools/terrain_map_render.gd` applies them. The functions are correct — they are just a seam
nothing crosses yet. Filed as **F-274**; wiring it moves every seed's surface and wants F-271 fixed
in the same task.

Every `*_from_set` call is bit-identical to its bare sibling; bare and set-backed paths funnel
through one shared private body so they cannot drift. The bare `moisture()`/`continent()`/
`biome_at()` calls remain and are still correct — they are the right choice for a one-shot sample and
for a check script that wants an independent witness.

**Threaded through:** `PoiMap.sites_for_island()` builds one set for the whole island (the dart loop
was rebuilding every field six times per dart, up to 720 darts per def); `_slope_at()` now takes the
already-computed centre height instead of resampling it, and an accepted dart resolves its biome once
instead of twice. `resource_scatter.gd` adopts its existing island set. `tools/terrain_map_render.gd`
builds one set per render and resolves each pixel's biome once — at 22 constructions per pixel it
was building roughly 7.9 million `FastNoiseLite` fields for a default 600 px image, 23 million at
`--size 1024`.

**The world did not move, and that is the assertion that matters.** A POI layout is never replicated
(ARCHITECTURE.md §4), so a silently-shifted island reads as a new seed, not as a bug.
`tools/worldgen_noise_reuse_check.gd` carries `GOLDEN_POI`/`GOLDEN_BIOME`/`GOLDEN_AMPLITUDES` —
hashes captured from the pre-fix code at 17bacba, **before the first edit**, because `agent baseline`
cannot run a check that does not exist at that revision. **If your task deliberately changes worldgen
output, re-capture those constants the same way and say so in your close-out** (D-160): they are a
tripwire, not a specification.

**Verified:**

```bash
.agent/bin/agent godot --script tools/worldgen_noise_reuse_check.gd   # WORLDGEN_NOISE_REUSE failures=0
```

Equivalence (361 samples x 5 seeds), adoption, layout identity against the golden hashes, and a
1.43x measured per-sample speedup against a >=1.3x floor. Neighbours all at `failures=0` with 0
undeclared `ERROR:` lines: `poi_check`, `biome_check`, `resource_scatter_check`, `noise_reuse_check`,
`terrain_check`, and `check_determinism` reproducing `terrain_hash c20eed19b44270a1` byte-identically
to F-241's recorded value. A 512 px terrain render is MD5-identical to the same render at HEAD.
Full spec: `docs/SPECS.md` F-261.

**Found broken along the way, filed not fixed:** `ResourceScatter._placement_at()` classifies a
point's biome from `height()` while `BiomeMap.biome_at()` classifies from `continent()`, so the same
world point resolves to two different biomes depending on which system asks — D-144's circularity,
still live in one caller, and `resource_scatter_check.gd` re-derives it the same wrong way so it
cannot catch it. Out of this claim because the fix moves scatter output on every seed. **F-271.**

### 2026-08-19 — F-255 resolved: asset scoping against the 2D heightfield is now a check, not a habit — `tools/asset_scope_check.gd` (lm)

**The check the next asset batch runs:**

```bash
.agent/bin/agent godot --script tools/asset_scope_check.gd
```

**What it asserts (D-159).** D-142 left the world a 2D heightfield with nothing below grade, so an
asset may show a void it CONTAINS (`giant hollow tree`'s trunk) but never one the terrain would have
to own (`cave entrance`). The check scans every file where an asset gets named before it gets a mesh
— `docs/ASSET_TRACKER.md`, every `assets/*/README.md`, every `tools/blender/build_*.py` — and fails
any line naming a below-grade interior (`cave`, `cellar`, `tunnel`, `catacomb`, `crypt`, `basement`,
`dungeon`, `undercroft`, `mine shaft`) or an `entrance` **unless that same line cites an `F-NNN` or
`D-NNN`**. Second rule: no exported GLB in any kit may be named for one. Currently 19,175 lines
across 41 files, 0 failures.

**If you are writing a new asset batch, this is what it means for you.** Naming a cut asset is fine
and encouraged — cite the finding on the same line and the check passes, which is exactly how
A-016a/A-016b record `cave entrance`. What fails is naming one with no reason attached, because that
is indistinguishable from proposing to build it. `entry` is deliberately not matched (`catalog
entry`, `SIZE entry`, `carpentry`); `doorway` is not matched either, since an authored opening
through an authored wall leads somewhere that genuinely exists.

**Two rows re-scoped, both before anyone opened Blender:** A-020's `flooded cellar entrance` ->
**`flooded cellar ruin`** (a sunken half-collapsed structure at or near grade, at most a token few
steps into ankle-deep water that visibly bottoms out), and A-016b's `burrow entrance` ->
**`burrow mound`** (animal-sized mouth, hollow contained in the prop's own mesh). A-016b is `NEXT`,
so that second one was the live risk. `corrupted crater` needs nothing — a depression IN the
heightfield is the one below-grade shape it can express, and is what `sinkhole` was re-scoped to.

### 2026-08-19 — F-254 resolved: `EventBus.cycle_modifier_drawn` now fires on every peer, not just the host (lp)

**The API the next task builds on:**

- `EventBus.subscribe_cycle_modifier_drawn(listener)` is now safe to use from a client. Before this
  it was silently host-only — a client's listener never fired at all — so any HUD/toast/audio
  reaction to a Modifier draw can now just subscribe instead of polling
  `CycleModifierService.active_modifier_ids()` on a timer. This is the same correction F-250 made for
  `cycle_advanced`; between them, every Cycle-family signal now reaches every peer.
- **Two contracts a subscriber must respect**, both written on the signal's own doc comment in
  `core/events/event_bus.gd`:
  1. On a client, a draw and its Cycle advance are independent replicated records and may land in
     **either order**. A listener that needs the pairing reads `CycleService.current_cycle()` rather
     than assuming `cycle_modifier_drawn` fired second. (On the host they are still synchronous, so a
     check that only runs host-side will not catch a violation of this — see the net check.)
  2. A **late joiner gets no backlog**. `WorldDeltaLog.net_world_snapshot` replaces state wholesale
     without going through `_apply()`, so it fires no `delta_applied` and therefore no re-derived
     draw signals for anything drawn before the join. Subscribe for "a modifier was JUST drawn";
     build the current stack from `active_modifier_ids()`, which is correct on every peer.
- `CycleModifierService`'s `WorldDeltaLog` schema gained one additive key per slot:
  `"<slot>:cycle"` (`CYCLE_KEY_SUFFIX`) holding the Cycle that slot was drawn on, beside the existing
  `"<slot>" -> def_id` and `"count"`. `_replicated_active_ids()`'s parsing is unchanged — it only
  ever asks for `str(index)` and `COUNT_KEY`, so the new key is invisible to it.
  **`_announce()` writes `COUNT_KEY` LAST and that ordering is load-bearing** (D-158): the client
  only announces slots below the recorded count, which is what stops a post-restart draw from being
  paired with the previous run's stale `def_id`. Anything that adds a fourth record to a draw must
  keep `COUNT_KEY` the final write.
- `tools/cycle_modifier_net_check.gd` (new) — the two-process ENet pattern for "does this signal
  actually reach a client". Any future Cycle-family signal should add a phase here rather than a new
  file. Its phase 2 (restart twice, identical redrawn pair each time) is the shape to copy for
  testing any per-peer dedupe, since a single run cannot distinguish a working reset from a broken
  one.

**Gotcha for anyone writing a Cycle Modifier check:** no shipped `CycleModifierDef` has a positive
`weight_at(1)`, so Cycle 1 — including the one a restart lands on — draws nothing by design. Advance
the Cycle first if your check needs a real draw.


### 2026-08-19 — F-245 resolved: all seven Cycle Modifiers now have a real gameplay consumer — `has_modifier()`/`drought_active()` finally get called (lm2)

**The API the next task builds on:**

- `CycleModifierService.drought_active() -> bool` — `has_modifier(&"drought")` narrowed to the
  window `drought.tres` actually promises ("yield half until the next Wellspring cap"). Any future
  modifier whose effect is not simply "as long as it's drawn" should follow this shape (a
  `_<id>_cleared`-style private flag, reset at draw time in `host_draw_modifier()`, flipped by
  whichever `EventBus` signal ends the window) rather than inventing a second one.
- `PowerupService.total_stacks(peer_id: int) -> int` — every stack a peer holds, summed across
  families. Same host-answers-for-anybody/client-answers-for-itself split every other query on that
  file already follows (`_held_for()`).
- `Enemy.host_force_target(peer_id: int) -> void` — unlike `alert()`, overrides a target this enemy
  already holds. Built for `the_hunt`'s tracking elite; any future "this enemy ignores normal
  aggro/perception and beelines for X" effect should call this rather than poking `_target_peer`
  directly.
- `Enemy.mark_as_bloom_child() -> void` — the cross-instance setter for `_bloom_child`, the guard that
  stops a `bloom`-spawned child from splitting again. Same shape as `alert()`: a public method, not a
  poked private field, even though GDScript would allow the latter.
- `tools/cycle_modifier_effects_check.gd` (new) — forces one modifier active at a time by writing
  `CycleModifierService._active_ids` directly and exercises its real effect end to end. A future
  8th modifier's own effect-wiring task should add a subtest here, not a new file.

**Design calls made while wiring this, recorded as D-156** so they are not relitigated: `tithe`
exempts solo sessions from its extra `required_players` (co-op only); `the_hunt`'s roaming elite
reuses `tusker` rather than authoring new content.

**Left for a later task, not this one's scope:** the roadmap's remaining 14–24 un-authored Cycle
Modifiers (6.3's own close-out note, still true) and F-236's sibling gap in the unlock tree and
ranged weapon rack — F-245 only closed the wiring hole in the seven that already existed.

### 2026-08-19 — F-257 resolved: `tools/steam/apply_ids.sh` now writes every home of the Steam App ID, and a partial swap is refused rather than performed (lm3)

**The API the next task builds on — task 8.2, this is your whole repo-side swap:**

```bash
tools/steam/apply_ids.sh <app_id> <depot_windows> <depot_macos> <depot_linux>
```

One command, three files: `tools/steam/steam_build_config.sh` (offline `steamcmd` depot upload),
`core/net/net_config.gd`'s `const STEAM_APP_ID` (the runtime value `steam_lobby.gd` passes to
`steamInitEx()`), and `steam_appid.txt` at the repo root (what the Steam SDK reads on any dev run
that inits with app_id 0). Nothing derives any of the three from another, so before this they could
silently disagree — 8.2 could apply the real ID, watch `depot_wiring_check.sh` go green, and ship a
build that uploads to the correct depot while every client still initialised against Spacewar's 480.
D-155 records why one command was chosen over documenting three edits, and answers the claim-boundary
question: a `tools/` script may write into `core/` and the repo root, and the agent running it holds
the claims. **Claim `core/net/net_config.gd` and `steam_appid.txt` alongside the `tools/steam/` files
before you run it.**

It pre-flights all three targets before writing to any (each target line must exist exactly once, or
it refuses having written nothing) and rolls all three back if a value fails to read back. Placeholder
values (480, 0) are still refused as arguments, so it stays inert until 8.1 produces a real App ID.

**Two backstops, for a hand-edit that bypasses the script:** `steam_upload.sh` re-reads
`net_config.gd`'s constant itself and refuses to publish if it disagrees with the config's — the last
gate before a live Steam publish. `depot_wiring_check.sh` grew §4 (all three App IDs agree in the
repo right now) and §5 (that upload guard fires both ways), and its §2 now exercises `apply_ids.sh`'s
three-file write and its three refusal paths in an isolated fake repo. `tools/steam_check.gd`'s
`app_id == 480` literal became `app_id == NetConfig.STEAM_APP_ID`, so it stays a true assertion
across the swap instead of needing an edit at 8.2.

**Verified:** `bash tools/steam/depot_wiring_check.sh` — ALL CHECKS PASSED (five sections).
Mutation-tested, since a check that cannot fail proves nothing: restoring HEAD's `apply_ids.sh`
fails §2 with three FAILs, and drifting `net_config.gd` or `steam_appid.txt` fails §4. Plus
`agent godot --script tools/steam_check.gd` against a live Steam client (all pass — "running as App
ID 480 (steam_appid.txt agrees with NetConfig)") and `agent godot --quit-after 120`, 0 `ERROR:`
lines. No placeholder value was changed; `steam_build_config.sh` was not claimed or edited.

### 2026-08-19 — F-253 resolved: `tools/seed_sync_check.gd`'s 3 failures were the check gating on the wrong signal, not a `WorldDeltaLog` bug (lp)

**Claim:** `tools/seed_sync_check.gd` only — no production code changed.

**What shipped, verified:** the finding's own hypothesis (a real snapshot-delivery bug in
`WorldDeltaLog.net_world_snapshot`/`_on_peer_admitted`) was wrong. Print-debugging (reverted, no
trace left) showed the client's `GameState.is_seed_ready()` flips true well before the host's real
`net_world_snapshot` RPC lands, because `MireGrid` (autoload, always ticking) draws itself a
throwaway local seed on any not-yet-connected peer — intentional, decided behavior (D-110/D-119/F-172:
solo play seeds instantly at boot; see D-153 for why this is not something to fix at the source). The
check was gating its "snapshot arrived" proof on that ambiguous flag. Fixed by gating on
`before_delta` instead — it can only read true once `net_world_snapshot()`'s RPC body has actually run
(seed + state decode happen sequentially in it), so it is unambiguous proof the whole snapshot landed.
`SEED_SYNC_CHECK failures=0`, three consecutive runs (real-entropy seeds differ each run).

**For the next agent touching seed/replication checks:** `GameState.is_seed_ready()` proves "some
value has been drawn," never "the replicated value has arrived" — a not-yet-joined client's own
`MireGrid` can and will draw one first. Gate on `WorldDeltaLog`'s `before_delta`/`delta_applied` (or
an equivalent fact only the replication path itself produces) when the thing under test is
specifically "did the network deliver this," not "is there a seed at all."

**Docs:** `docs/SPECS.md` new F-253 block, `docs/DECISIONS.md` D-153, `docs/FINDINGS.md` F-253 moved
to Resolved.

### 2026-08-19 — Task 4.16: map-contract parity ships — the both-map fixture matrix, the kind+name marker contract, and required POIs that land on every seed (hollow7)

**What shipped, verified:** `tools/world_contract_check.gd` is now the BOTH-MAP MATRIX — one
process boots the shipped authored scene and then a code-built `ProceduralWorld` (the same
composer `--procedural` uses) and asserts the LOOP FIXTURES on each: Wellspring ≥1, exactly one
extraction ship, chests with resolvable tiers, at least one REGISTERED station (a marker whose
asset matches a `StationDef.world_scene` — six of Hollowmere's eight station props are scenery, so
"a station marker exists" proves nothing), nest spawn points, a standable spawn, wired harvest
proxies around it, and a MireGrid that seeded inside the island and recedes from a cap. **Three
runs on three random seeds: three PASS.** F-076's layout-shaped phases still run where a layout
exists; F-112's Undergrowth phase is REQUIRED on the authored map and asserted ABSENT on the
procedural one.

**The marker contract is kind AND name (D-152).** `PoiDef.marker_name` (empty = composer default)
exists because ChestPlacementService tiers from a `Cache_*`/`Chest_<tier>_*` NAME and
CraftingService resolves stations from an exact `Station_<asset>` NAME — kind-only markers built
zero of both on procedural. Three defs authored: `loot_cache` (8, `Cache_poi`), `enemy_nest` (5),
`station_camp` (1, the primitive workbench). **Adding a POI kind that a name-keyed service must
discover means authoring `marker_name` to that service's convention — the matrix fails if you
forget.**

**`PoiDef.required` + the relax ladder (D-152).** Real seeds on the 118 m island produce ZERO
Wellsprings under authored constraints. A `required` def that places nothing gets two deterministic
relax passes (terrain-fit dropped, then any-land) — spacing is never relaxed. Wellspring and
shipwreck are `required = true`; shipwreck is also `target_count = 1, placement_priority = 5` now
(it was 3× scenery from 4.7, which gave procedural islands two exits). `tools/poi_check.gd` proves
the ladder both directions plus a 64-seed objective sweep.

**MireGrid binding needed no code** — bounds derive from `IslandHeightmap.ISLAND_RADIUS`; the
matrix asserts seeded-and-recedes on both maps rather than trusting the derivation.

**For 4.19 (default cutover):** the parity bar WORLDGEN.md set is met at the fixture level and
enforced by one check. What the matrix deliberately does not cover: island *feel* (4.18's walk),
and per-service netted behaviour on procedural (the service net checks all run on synthetic/
authored scenes; nothing suggests map-dependence, but it is unproven).

**Checks:** `world_contract_check` (×3 seeds), `poi_check` (ladder + sweep),
`procedural_world_check`, `verify_setup` — all green, 0 engine ERROR lines.

### 2026-08-19 — F-252 resolved: resource_scatter.gd's `_placement_at()` now samples height through F-241's `NoiseSet`, not a bare `height()` per point (lp)

**Claim:** `world/gen/resource_scatter.gd`, `tools/resource_scatter_check.gd` (unchanged).

`placements_for_chunk()` builds one `IslandHeightmap.NoiseSet` via `make_noise_set(world_seed)` right
alongside the `origin_x`/`origin_z` it already computes once per chunk, and passes it down through
`_placement_at()`'s new trailing parameter. `_placement_at()` calls `height_from_set(world_x, world_z,
noise_set, world_seed)` instead of the bare `height()` — exact same F-241 API `chunk_mesher.gd`
already uses, no change to any function outside this file.

`BiomeMap.moisture()` on the next line is untouched — different noise field, no `NoiseSet`-equivalent
exists for it (F-261).

**Verified:** `agent godot --script tools/resource_scatter_check.gd` — `RESOURCE_SCATTER_CHECK
failures=0`, including the purity/determinism assertions and the full `ResourceScatterField` LOD0
harvest-lifecycle suite. Full spec: `docs/SPECS.md` F-252.

**Found broken along the way, filed not fixed:** `world/gen/poi_map.gd`'s dart-throwing loop has the
identical bare-`height()` shape, and `BiomeMap.moisture()` has no `NoiseSet`-equivalent despite three
per-sample callers — both world-gen-time cost rather than F-241's per-frame case, so lower severity.
**F-261.**

### 2026-08-19 — F-241 resolved: IslandHeightmap.NoiseSet — sample many points per seed without rebuilding noise per point (lp)

**Claim:** `world/gen/island_heightmap.gd`, `world/chunk/chunk_mesher.gd`, `tools/noise_reuse_check.gd`
(new).

**The API for anything sampling many points per `world_seed`** — `world/chunk/chunk_mesher.gd`'s
`_sample_heights()` is the first caller, now using it for a LOD0 apron's 1,089 points:

```gdscript
var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)   # once
var h: float = IslandHeightmap.height_from_set(x, z, set, world_seed, detail_amp, ridge_amp)  # per point
```

Bit-identical to calling `IslandHeightmap.height(x, z, world_seed, detail_amp, ridge_amp)` per
point — `height()` is now a thin wrapper around `height_from_set(x, z, make_noise_set(world_seed),
world_seed, ...)`, unchanged in behavior or per-call cost, so nothing that already calls `height()`
needs to change. `NoiseSet` bundles the six `FastNoiseLite` fields a sample needs
(base/coast/warp_x/warp_z/detail/ridge); build ONE per `WorkerThreadPool` task (e.g. once per chunk)
and never share it across tasks — same thread-safety rule the bare per-call construction always
documented, just paid once instead of once per sample now.

**Measured win:** `agent godot --script tools/bench_chunks.gd`, same machine, before/after —
single-threaded 9.863 -> 5.877 ms/chunk, `WorkerThreadPool`-amortized 15.519 -> 4.495 ms/chunk.
`tools/noise_reuse_check.gd`'s own micro-benchmark: ~1.9x per sample (lower than "6 fields to 1"
suggests, because most of a sample's cost is the actual noise/domain-warp/river-corridor math, which
`NoiseSet` reuse does not touch — only the six construction calls per sample are eliminated).

**`continent()` was NOT changed** — it still builds `base_noise`/`coast_noise` inline per call. Not
in `chunk_mesher.gd`'s hot path (only `height()`/now `height_from_set()` is), so out of F-241's
scope; a future caller sampling `continent()` at density would want the same treatment.

**Sibling gap found here, fixed by F-252:** `world/gen/resource_scatter.gd`'s `_placement_at()`
called `IslandHeightmap.height()` once per scattered point — same shape, lower call count than the
mesher. Now uses `height_from_set()` against a per-chunk `NoiseSet`, see F-252's own entry below.
Two more siblings found while closing F-252, still open: `world/gen/poi_map.gd`'s dart-throwing loop
(same bare-`height()` shape) and `BiomeMap.moisture()` (a different noise field, no `NoiseSet`-
equivalent exists for it yet) — **F-261**.

**Verified:** `tools/noise_reuse_check.gd` (new, 10/10 assertions — bit-identical equivalence,
`ChunkMesher.build_mesh()`'s real output matched against `height()` directly, and the speedup
itself); `tools/check_determinism.gd`'s `terrain_hash` and all seven other hashes byte-identical
before/after; `tools/terrain_check.gd` 0 failures; `tools/bench_chunks.gd`/`tools/bench_chunk_gpu.gd`
still run clean. Full boot 0 `ERROR:` lines. Full spec: `docs/SPECS.md` F-241.

**Found broken while verifying, filed not fixed:** `tools/chunk_stream_check.gd` (windowed) has 5
pre-existing failures, confirmed present on unmodified `main` — terrain retuned since F-128 left the
LOD skirt and that check's own reference constants stale (F-251, unrelated to this task).
**Fixed 2026-08-19 — see this section's own F-251 entry below and `docs/SPECS.md` F-251:** all 5
failures resolved, `ChunkMesher.SKIRT_DEPTH_FRACTION` now 1.70 (was 0.10) against the current
`HEIGHT_SCALE`.

### 2026-08-19 — F-238 resolved: a successful extraction now has its own run summary (lp)

**Claim:** `ui/hud/extraction_hud.gd`, `ui/hud/extraction_hud.gd.uid`, `tools/run_summary_check.gd`,
plus `ui/hud/defeat_hud.gd`/`.uid` (one stale comment, added mid-task — see below). No
`project.godot` change: `ExtractionHud` is already registered after `CycleModifierService` and
before `SalvageService`.

Task 6.8 built the run-summary screen ROADMAP.md names only for the death path
(`ui/hud/defeat_hud.gd`), explicitly filing F-238 for the success path. That gap is now closed:
`ExtractionHud` (already the client-local presentation owner for `ExtractionShip`, task 6.5) gained
a second, terminal, full-screen overlay — its own `CanvasLayer` at layer 20 (matching `DefeatHud`'s
terminal priority; the existing bottom-centre repair/departure prompt panel stays at this file's own
layer 5, deliberately below other gameplay UI) — shown on `EventBus.subscribe_run_extracted`. Same
three-line shape as `DefeatHud`'s: headline (`"CYCLE %d"`), a fixed subtitle (`"EXTRACTED SAFELY"` —
extraction has only the one cause, unlike defeat's `team_wipe`/`island_consumed` split, so no
`CAUSE_HEADLINES`-style dictionary was needed), "Modifiers drawn: …"
(`CycleModifierService.active_modifier_ids()`, read-only, nothing to subscribe to — identical to
`DefeatHud._modifiers_drawn_summary()`), and "Salvage earned: N (M total)" from
`EventBus.subscribe_salvage_banked`'s `extracted == true` branch (the branch `DefeatHud` has always
explicitly ignored). Joins `blocks_gameplay_input` (D-032) the moment it shows, same as `DefeatHud`.

**`_salvage_known` tracked independently of `_summary_shown`**, mirroring `DefeatHud`'s own F-235
fix — `run_extracted` and the `salvage_banked` it triggers can legitimately land in either order
depending on autoload registration, so neither handler may assume the other already ran. (In the
shipped autoload order `ExtractionHud` actually subscribes to `run_extracted` before `SalvageService`
does, so in practice `_on_run_extracted` always runs first here — opposite of `DefeatHud`'s F-235
case — but the guard is written order-independent anyway rather than relying on that.)

**Not shared with `DefeatHud`:** F-238's own note suggested factoring the "modifiers drawn"
formatting into a shared `ui/hud/run_summary_format.gd` helper. Not done — this task's claim did not
originally include `defeat_hud.gd`, so `_modifiers_drawn_summary()` is duplicated verbatim in both
files rather than shared. `defeat_hud.gd` WAS claimed mid-task, but only to fix one now-stale
comment (`_on_salvage_banked`'s doc said "`extracted == true` ... a screen this task does not own
(nothing shows one yet)" — no longer true). A future task touching both files can still lift the
duplicated formatter out.

**Verified:** `tools/run_summary_check.gd` (extended, not new — task 6.8 had already claimed this
exact filename for the death-path proof) now drives BOTH real chains in one process:
`DefeatService.net_run_defeated()` -> `run_wiped` -> `SalvageService` -> `salvage_banked` ->
`DefeatHud`, and `EventBus.emit_run_extracted()` (the same direct-emit shortcut `salvage_check.gd`
already uses, since a real `ExtractionShip` departure needs a live scene this bare `--script`
harness doesn't have) -> `SalvageService` -> `salvage_banked` -> `ExtractionHud`. 27 assertions, 0
failures — includes the terminal no-repaint proof (a second `emit_run_extracted` doesn't touch the
already-shown screen) and the cross-guard proof (`ExtractionHud._on_salvage_banked` ignores an
`extracted == false` bank, and vice versa for `DefeatHud`). No regressions: `extraction_check.gd`,
`salvage_check.gd`, `defeat_check.gd`, `cycle_modifier_check.gd` all `failures=0`. 0 `ERROR:` on a
full boot (`agent godot --quit-after 20`).

### 2026-08-19 — Task 8.3: achievements, stats, rich presence — full framework shipped now, Steamworks dashboard registration blocked on 8.1/8.2 (lp)

**Unlike 8.4/8.11, nothing here is blocked from actually running.** F-248 predicted 8.3 would hit the
same "needs the real App ID" wall 8.11 did — it does, but only for the Steamworks DASHBOARD side, not
the code: `setStatInt()`/`setAchievement()` fail harmlessly against an id no dashboard has registered
(App ID 480 has none of ours defined), so every trigger/persistence/push path below is fully shipped,
verified, and needs zero follow-up code change once the dashboard rows exist — there is no
placeholder value to swap the way 8.4/8.11's App ID/depot IDs are.

**`autoload/steam_stats.gd` (new autoload `SteamStats`)** — achievements + stats. Ten
`ALL_ACHIEVEMENTS` (D-148: hand-picked, not the ~20 `docs/STEAM.md` names as an aim), seven `STAT_*`
counters. Every trigger rides an existing `EventBus` signal — `run_extracted`/`run_wiped`/
`wellspring_capped`/`boss_defeated`/`ship_repaired`/`salvage_banked`/`unlock_purchased` — except
Cycle milestones, which poll `CycleService.current_cycle()` on a 2s timer instead of subscribing to
`cycle_advanced` (F-250: that signal never reaches a client). Local tally persists to
`user://steam_stats.json` via `core/save/steam_stats_save.gd` (same shape as `SalvageSave`/
`UnlockSave`); `save_path` override for `tools/steam_stats_check.gd`, same guard pattern
`SalvageService` uses. Pushes to the real Steam API only once `SteamLobby.is_ready()` AND
`user_stats_received` has answered (`steam_sync_ready()`) — see D-148 for why this file never calls
`SteamLobby.initialise()` itself. `steamstats` console command (LOCAL scope) prints this peer's own
tally + sync status.

**`autoload/rich_presence_service.gd` (new autoload `RichPresenceService`)** — the "status" rich
presence key (distinct from `SteamLobby`'s existing "connect" key, which controls the Join Game
button, not display text). `compute_status_text()` is pure — "Cycle N", or "Cycle N · P players"
once `NetTransport.peer_ids().size() > 1` — polled the same way and for the same reason as
`SteamStats`'s Cycle tracking. No menu/in-run state machine (D-148: the game has no menu phase to
distinguish, D-110). Pushes via a new `SteamLobby.set_status(text)` method — the one call site; route
any other status-text producer through it rather than a second `setRichPresence` call site.

**`autoload/steam_lobby.gd`** — one addition (`set_status()`, next to `_advertise_joinable`/
`_clear_joinable`), one comment update (the "not initialised at boot" paragraph now also explains why
`RichPresenceService`/`SteamStats` don't call `initialise()` either, and what was tried and reverted).
No behavior change to anything that shipped before this task.

**F-249 (fixed, same task) — sweep finding, not part of the original spec:** `ExtractionShip.
repair_stage`'s `EventBus.emit_ship_repaired()` lived inside the host-only `_process_repair()`, the
exact F-168 host-only-emit-call trap, unfixed on this one signal until `SteamStats` needed it
client-side. Moved into `repair_stage`'s own setter (matching `departed`'s existing pattern),
`is_inside_tree()`-guarded (a real `ExtractionShip` is always in the tree; the one caller that isn't,
`tools/extraction_check.gd`'s departure-FSM setup, never emitted under the old code either, so
behavior for that pre-existing check is unchanged).

**F-250 (fixed 2026-08-19, lp) — the bigger sibling named above, now closed:**
`CycleService._announce()`'s `EventBus.emit_cycle_advanced()` was gated behind `_owns_cycle()`, so
the signal never reached a client. `SteamStats`/`RichPresenceService` (this task) worked around it by
polling `CycleService.current_cycle()` instead of subscribing — that poll is left in place (it
already works, needs no upkeep), but a NEW client-side Cycle consumer no longer needs to copy it: see
`WorldDeltaLog.delta_applied` below. Same-shape sibling found unfixed in `CycleModifierService`,
filed separately as F-254.

**`tools/steam/ACHIEVEMENTS.md` (new)** — the Steamworks dashboard runbook, `DEPOT_SETUP.md`'s own
shape: exact API-name/display-name/description text for all ten achievements and all seven stats,
ready to paste in once task 8.2 lands a real App ID. No script analogous to `apply_ids.sh` — achievement/
stat API names are OURS to choose, not Valve's to assign, so there is nothing to write back into the
repo afterward.

**Verified:** `agent godot --script tools/steam_stats_check.gd` — 33 checks, 0 failures, 0 undeclared
`ERROR:` lines (one declared pattern, `"resources still in use"` — `BossMusicDirector` reacting to
this check's own synthetic `boss_defeated` event exactly like the shipped game would, same
`--script`-harness-reaches-every-real-subscriber trap `tools/salvage_check.gd`'s own header already
documents; orthogonal to this task). `agent godot --script tools/rich_presence_check.gd` (F-123/F-127,
named by this task's own work order) still passes unchanged. `agent godot --script
tools/extraction_check.gd` (pre-existing, not owned by this task, exercises the F-249 fix's file)
still passes with 0 undeclared errors. `agent godot --headless --quit-after 15` — full real-game boot,
both new autoloads ticking, 0 `ERROR:` lines.

### 2026-08-19 — Task 8.11: three depots wired to one app, per-platform launch options — genuinely blocked on 8.1/8.2, prep tooling shipped instead (lp)

**Cannot complete this session.** 8.11's actual deliverable — real Steamworks depots and real
per-platform launch options — needs a real App ID, which needs task 8.1 (Steamworks
account/tax/banking/$100 fee) and 8.2 (App ID swap), both still `todo`. Steamworks' Depots and
Launch Options pages don't exist until an App ID does, and 8.1 is Sequoyah's account/payment to run
alone (`AGENTS.md` D-039). D-132 called this split in advance; this is that prediction landing.

**What shipped instead — the most this task could do without an App ID:**
- `tools/steam/DEPOT_SETUP.md` — the exact Steamworks dashboard runbook: create 3 depots, set each
  one's OS/arch restriction, set each platform's launch option (Executable/Arguments/Type/Config
  OS/Arch). The per-platform executable table (`MIRE.exe`/`MIRE.app`/`MIRE.x86_64`) is
  cross-checked against `export_release.sh` (task 8.4) and each `depot_<platform>.vdf.template`'s
  `ContentRoot`, so it can't silently drift from the pipeline it describes. One launch option per
  platform — no dedicated server build exists (`ARCHITECTURE.md` §2.1).
- `tools/steam/apply_ids.sh <app_id> <depot_windows> <depot_macos> <depot_linux>` — writes the four
  real IDs into `steam_build_config.sh` in one command, refusing wrong arg count, non-numeric
  input, either placeholder reappearing (480/0), or two depot IDs colliding.
- `tools/steam/depot_wiring_check.sh` — verifies all of the above; passes at HEAD (see SPECS.md).

**Next agent to pick this up (only after 8.2 lands a real App ID):** follow `DEPOT_SETUP.md` step
by step in the Steamworks dashboard, run `apply_ids.sh` with the four real IDs — **since D-155 that
one command is the whole repo-side swap: it writes `steam_build_config.sh`, `core/net/net_config.gd`'s
runtime `STEAM_APP_ID` constant and `steam_appid.txt`, and refuses rather than applying any of them
partially (F-257)** — re-run `depot_wiring_check.sh` (its §4 asserts the three agree), then a real
`steam_upload.sh internal-beta <username>`. Claim `core/net/net_config.gd` and `steam_appid.txt`
alongside the `tools/steam/` files before running it; the script writes outside its own directory by
design. Don't redesign the runbook or the script — D-132's addendum and `docs/SPECS.md`'s
`## 8.11 ·` block both point here.

**Re-dispatched same day, still blocked:** re-checked `.agent/state.json` (8.1/8.2 still `todo`) and
re-ran `depot_wiring_check.sh`, `tools/roadmap_dependency_check.gd`, and a full headless boot — all
clean, no drift. Widened the sweep from "another hand-edited placeholder config" to "another
hardcoded copy of the same value" and found F-257 above; that's the only change this round.

### 2026-08-19 — Task 4.14: every island gets its river — analytic, carved, monotonically downhill (yarrow21)

**What shipped, verified:** the river layer in `world/gen/island_heightmap.gd` (D-142's recipe,
final terrain item before the erosion spike). One river per island, guaranteed: a **seeded
polyline** (source pulled inside the farthest-reaching lobe, two seeded bends, mouth overshot past
the coast), carved into BOTH `continent()` and `height()` by `min(surface, channel)` — so a ridge
crossing the corridor becomes a gorge, and biomes resolve the valley floor as low ground with no
special casing (D-144 holds). Bed runs linear source→below-sea; the carve rides a **steepened**
island mask (`smoothstep(0, 0.35, mask)`).

**The trap that steepened the mask, worth remembering:** blending the carve by the RAW mask let
every interior mask dip (a warped-inland coastal notch, a lobe seam) weaken the channel mid-river —
the bed popped up over the notch, i.e. water flowed uphill. `terrain_check`'s monotonic-bed walk
caught it on the first run. If you add a landform that blends by mask, ask what happens where the
mask dips *inland*.

**APIs:**
```gdscript
IslandHeightmap.river_polyline(world_seed) -> PackedVector2Array   # 4 design-space points
# the carve itself is internal to continent()/height() — callers see only the carved surface
```
Per-sample cost: zero new noise builds (`continent()`/`height()` now bend the point once and share
it between mask and river; the polyline is integer/table arithmetic).

**Checks:** `terrain_check` grew a river section — polyline determinism + divergence, 4 control
points, **the bed never climbs on its way down** (2-axis warp-aware probe), reaches the sea,
corridor-is-a-valley. `check_determinism` grew `river` (geometry + carved samples hashed
separately, so a platform drift names its half). macOS baseline: `river a70d5139ac9a9a0d`,
`terrain_hash c20eed19b44270a1` — **re-run on the D-028 Windows box next time it is out**, same as
every §6a row. Regressions: `biome_check`, `poi_check`, `procedural_world_check` all 0.

**Render:** `agent godot --script tools/terrain_map_render.gd -- --seed 20260819` —
`assets/audit/terrain/island_20260819.png` regenerated (it was stale: 4.13's follow-up reshaping
never re-rendered it; the committed PNG now shows lobes + islets + the river).


### 2026-08-19 — Task 6.3: six Cycle Modifier `.tres` files ship, against 6.2's deck (lm)

**What shipped, verified:** `content/cycle_modifiers/{drought,tithe,static,rooted,bloom,the_hunt}.tres`
— six hand-authored modifiers alongside 6.2's `long_night.tres`, each chosen to change a run's
priorities on a different system (harvesting yield, Wellspring presence, chest loot, mire recession,
enemy death, enemy targeting), not to move a difficulty number. D-146 records the full design
rationale (why six and not the roadmap's 20–30, the `min_cycle` staggering, why no
`incompatible_tags` pairs were authored) and `docs/SPECS.md` §6.3 has the per-modifier table. No code
or schema change — 6.2's `Registry`/`CycleModifierService` directory scan already picks up any
`.tres` dropped into `content/cycle_modifiers/`.

**`tools/cycle_modifier_check.gd` rewritten, not just re-run.** 6.2's own
`_check_deck_depletes_no_duplicate()` assumed a 1-modifier deck exhausts on the Cycle immediately
after `long_night` draws — with 7 real modifiers now, that assumption breaks. The rewrite drops the
old hardcoded-id assumption entirely and instead advances Cycles until every authored id has been
drawn (bounded by a `total + 5` safety cap, never a tuned number), asserting only invariants that
hold regardless of which candidate a weighted pick selects: no single Cycle advance stacks more than
one modifier, the full deck is drawn with no duplicates, and further advances past a full deck are a
no-op. `_check_wiring()` and `_check_real_draw_via_cycle_advance()` are untouched and still pass
unmodified — every new modifier's `min_cycle >= 3` was chosen specifically so Cycle 2 still draws
`long_night` alone, matching 6.2's original assertion exactly (D-146).

**Verified:** `agent godot --script tools/cycle_modifier_check.gd` → `CYCLE_MODIFIER_CHECK
failures=0` (27 assertions, up from 15 — the deck-exhaustion rewrite added the rest). `agent godot
--script tools/cycle_modifier_seed_check.gd` → `CYCLE_MODIFIER_SEED_CHECK failures=0`, unaffected by
this task (it injects its own synthetic content, never reads real `.tres` files). Regressions
`tools/cycle_check.gd`, `tools/mire_grid_check.gd`, `tools/wave_spawner_check.gd` all still
`failures=0`. `agent godot --quit-after 20` — 0 `ERROR:` lines.

**Schema gap, not worked around:** `CycleModifierDef` has no field for a numeric effect magnitude
(yield multiplier, required-player delta, split-health fraction) — only `id`/`display_name`/
`description` plus the weighting/tag fields 6.2 shipped. Every one of the six therefore states its
intended effect as prose in `description` only, naming the exact future consumer and seam
(`CycleModifierService.has_modifier(id)` against a named field/method — e.g. `drought` names
`Harvestable.yield_amount`, `tithe` names `Wellspring.required_players`), the identical pattern
`long_night.tres` already established. **What a future effect-wiring task builds against:** whether
to add per-modifier typed fields to `CycleModifierDef`, or have each consuming system hardcode its
own modifier's magnitude by id, is an open design choice this task deliberately left undecided rather
than approximating with a stat field that doesn't fit every system's effect shape.

**What's left of the roadmap's 20–30 (not done here, by design — D-146):** the six ship real
variety across harvesting/wellspring/loot/mire/enemy-death/enemy-targeting, but several DESIGN.md
§5.1-adjacent axes are still untouched by any modifier — day/night pacing beyond `long_night` itself,
crafting/building cost pressure, extraction-stage pressure, and anything that reads
`PowerupService`'s Resonance families. A later content-authoring task should read this list before
picking its next few, so it reaches for an untouched axis rather than a fourth `scarcity`-tagged
modifier.

### 2026-08-19 — Task 4.13: terrain look — a warped, ridged, biome-scaled island, and the tool that lets you see one (slate17)

**What shipped, verified:** `world/gen/island_heightmap.gd` (domain warp, masked ridged layer,
continental lift, jittered coastline, tighter falloff), two new fields on `world/gen/biome_def.gd`
authored into all three shipped biomes, `world/gen/biome_map.gd` rewired to the continent,
`tools/check_determinism.gd` extended with both new operations, and `tools/terrain_map_render.gd`.
`biome_check`, `procedural_world_check` and `world_contract_check` are all 0 failures.

**The API split is the thing to build against (D-144):**

```gdscript
IslandHeightmap.continent(x, z, seed)                  # biome-INDEPENDENT landmass; what decides biomes
IslandHeightmap.height(x, z, seed, detail_amp, ridge_amp)   # the surface; amplitudes come from the biome
IslandHeightmap.ridge_mask(continent_height)           # how much ridged layer applies at that height
# Sampling MANY points per seed? Build one set, reuse it — every bare call below rebuilds every
# FastNoiseLite field it touches. See the F-241 and F-261 entries in 'Current state' above:
#   IslandHeightmap.make_noise_set(seed) -> NoiseSet    # heights only
#   BiomeMap.make_noise_set(seed[, island_set]) -> NoiseSet   # heights + moisture; adopts island_set
# then height_from_set / continent_from_set / moisture_from_set / biome_at_from_set /
# terrain_amplitudes_from_set — each bit-identical to its bare sibling.
BiomeMap.terrain_amplitudes(x, z, seed, defs) -> Vector2    # (detail, ridge) for a point, (1,1) if no def
```

A `BiomeDef`'s `height_min`/`height_max` are **continental** heights from now on. Every shipped def
reads the same as before, because the rough layers only ever add metres on top — but a def tuned
against the old combined surface would sit a few metres low.

**See the island before judging it.** `.agent/bin/agent godot --script tools/terrain_map_render.gd
-- --seed 12345` writes a top-down PNG under `assets/audit/terrain/`: height-shaded, biome-tinted,
sea level marked. Three shape defects that are invisible from a chunk at ground level were obvious
in the first render — an archipelago instead of an island, a perfectly circular sand ring, and a
230 m band of near-sea-level ground round the whole edge. 4.18's island-feel walk should start here
rather than in the engine.

**The cost is real and named.** Chunk build went 1.99 → 3.85 ms single-threaded (3.92 → 8.35 ms
amortized on the pool) for the new layers. F-241 holds the remaining win: the mesher rebuilds three
`FastNoiseLite` objects per vertex, 1,089 vertices per chunk, and a per-chunk `NoiseSet` would remove
that without giving up the thread-safety property. Whoever takes it: hashes identical before and
after is what proves an optimisation changed no output — that is how 4.13's own refactor was cleared.


### 2026-08-19 — Task 5.2 (partial — 3 of the roadmap's "8-12"): three enemy kinds ship as `.tres` data, each proven to fight differently, not just to add up differently (lm)

**What shipped, verified:** `docs/SPECS.md`'s new `## 5.2` block, and three new
`content/enemies/*.tres` beside `crawler`/`bog_crawler` — no code changed, `EnemyDef`/`Enemy` needed
no new field. **Deliberately 3, not 8-12** (D-073/AGENTS.md "never bulk-generate content data") —
see the SPECS.md block for why, and the roadmap line still needs 5-9 more kinds from whoever picks
this back up.

```
strider      — move_speed 7.5 (player sprint is 6.0) — cannot be kited on foot; only breaking line of
               sight or spending a dodge's burst speed creates separation. 7 HP, 4 dmg: a decision to
               fight it fast, not a war of attrition.
tusker       — attack_range_m 3.4 (crawler's is 2.0) — a distance that reads as safe against a
               crawler is already inside a tusker's telegraph. attack_recovery_seconds 1.3 (crawler's
               0.5) is the reward for standing and punishing instead of retreating and re-approaching.
               45 HP, 16 dmg, move_speed 2.6: slow enough to still be kiteable, so its pressure has to
               come from range and the recovery payoff, not from denying distance.
broodcaller  — alert_radius_m 28 (default 8), max_concurrent_attackers 5 (default 2) — planting and
               fighting the one that found you wakes the whole local brood and lets more of them pile
               on than a crawler pack ever could, punishing standing and slugging over falling back to
               a chokepoint. 9 HP, 5 dmg individually: the pack is the threat, not any one of them.
```

All three reuse `enemy_crawler.glb` via `visual_tint` (F-158/D-073 — no new art for a stats task):
strider pale yellow-tan, tusker dark rust red, broodcaller violet.

**F-240 filed, not fixed here — a real limit on what "distinct to fight" can mean from `EnemyDef`
alone:** the hit always resolves at the END of a tell against the target's THEN-current position, and
`Enemy._tick_attack()` zeroes velocity for the whole TELL/ATTACK/RECOVER span — so **any nonzero
player movement during a tell beats it, regardless of `attack_range_m` or `attack_tell_seconds`.**
There is no field that makes "take one step back" stop working; that would need either the enemy
still closing ground during its own tell/attack (a lunge) or an attack that samples the target's
position at tell START, and neither exists today. Ruled out `tusker`'s original design ("denies
backpedal") for exactly this reason before it shipped — see SPECS.md `## 5.2` for the full reasoning,
kept there rather than only in the finding so the next author reads it before repeating the attempt.

**The harness trap this task's own check tripped over, worth knowing before writing another
speed-comparison check:** stepping `Enemy._physics_process(delta)` directly (the standard pattern —
see `enemy_check.gd`'s header) makes `delta` a no-op for MOVEMENT specifically —
`CharacterBody3D.move_and_slide()` reads the engine's own fixed physics delta, not the argument
passed to the function that called it. Two `Enemy` instances stepped this way stay comparable to each
other (confirmed empirically: measured per-call displacement ÷ `move_speed` agreed to four decimal
places across two different kinds), but a bare `Node3D` "player" moved by hand at a literal
`speed * delta` is on a different clock, and a naive comparison silently fails in the direction that
looks plausible (both distances grow, just by different amounts) rather than erroring loudly.
`tools/enemy_content_check.gd::_measure_effective_step_seconds()` calibrates a probe's own measured
per-call displacement against its `move_speed` first, then scales the player's retreat off that same
number instead of assuming one. Any future check that moves a plain node against a stepped `Enemy`
and compares real-world distances needs the same calibration, not a literal m/s constant.

**Verified:** `agent godot --script tools/enemy_content_check.gd` — 27/27 assertions pass, each new
kind's identity proven behaviourally against the `crawler` baseline under an identical test (outracing
a continuously retreating player at sprint speed; triggering a telegraph at a distance that leaves the
baseline still chasing; waking a packmate/committing more attackers than the baseline's own defaults
reach), not read back off its own stat block. Regression: `tools/enemy_check.gd` and
`tools/enemy_ai_check.gd` both still `failures=0`, unmodified. Full boot
(`agent godot --quit-after 20`): boot log confirms `loaded 5 enemy definition(s)`, 0 stray `ERROR:`
lines.

### 2026-08-19 — Task 6.8: Run summary — headline Cycle number, modifiers drawn, Salvage earned (lp)

Extends `ui/hud/defeat_hud.gd` (task 6.7's terminal death overlay) rather than building a second
screen — no new autoload, no `project.godot` change (`CycleModifierService` already registers
before `DefeatHud`). Authority: no new §2.2 row, same "VFX, audio, camera, UI" client-local row 6.7
already used — every field shown reads an already-authoritative value. No new stat-tracking system
was built (no kill counter, no elapsed-time clock — neither exists anywhere in the codebase); D-039
scope call recorded in `docs/SPECS.md`'s new §6.8 block: the roadmap line is one screen with one
headline (Cycle number) and a two-row stats block (modifiers drawn, Salvage earned), not four
separate elements.

**What changed on screen:** the Cycle number moved from the old detail line into the headline
(`"CYCLE %d"`, 48pt); the old cause text (`CAUSE_HEADLINES`) is now a secondary line; a new
"Modifiers drawn: …" line reads `CycleModifierService.active_modifier_ids()` + `def_for(id)` for
each `display_name` directly (task 6.2's deck is already stacked for the run's whole life — nothing
to subscribe to), falling back to the raw id if a def failed to load and to "none" on an empty deck;
the Salvage line is now labelled "Salvage earned: N (M total)" from the same `salvage_banked`
payload task 6.6 already fires.

**F-235 found and fixed in the same file, same task.** `_on_salvage_banked`'s old `not _shown` guard
assumed `_on_run_wiped` always ran first. Backwards: `SalvageService` subscribes to `run_wiped`
before `DefeatHud` does (autoload order), so its `salvage_banked` emit fires synchronously *inside*
`EventBus.emit_run_wiped()`, before `_shown` is set — the real banked number was silently dropped
every time, with nothing to re-fire it, so the death screen's Salvage line never actually updated in
the live game. Fixed by tracking `_salvage_known` independently of `_shown`: whichever of the two
arrives first wins, the second never clobbers it.

**Public surface (nothing new for other tasks to build against — this task is a pure consumer):**
`DefeatHud._modifiers_drawn_summary() -> String` is private but worth knowing about if a future task
extends this same screen further; everything it reads (`DefeatService.cause`,
`CycleModifierService.active_modifier_ids()`/`def_for()`, `salvage_banked`'s payload) was already
public from tasks 6.2/6.6/6.7.

**Not built:** a summary for a successful extraction — F-238 (open, filed by this task) records the
gap; the roadmap's "run summary" line is written against the death path only (`ui/hud/defeat_hud.gd`
is the only file this task's claim named).

Verified: `tools/run_summary_check.gd` (19 assertions, 0 failures) — drives the REAL chain
(`DefeatService.net_run_defeated()` -> `EventBus.run_wiped` -> `SalvageService` banks ->
`salvage_banked` -> `DefeatHud`), not a mock (F-068's convention); the F-235 assertion is a genuine
regression test, confirmed to fail against the reverted guard before the fix landed. No regressions:
`defeat_check.gd`, `salvage_check.gd`, `cycle_modifier_check.gd` all `failures=0`. 0 `ERROR:` on a
full boot (`agent godot --quit-after 15`).

### 2026-08-19 — Task 4.15: the ProceduralWorld composer ships — a generated island is now a playable level behind `--procedural` (yarrow21)

**What shipped, verified:** `world/gen/procedural_world.gd` (`class_name ProceduralWorld`, a
`Node3D`) — the composer F-139 was waiting for. It derives everything from `GameState.ensure_seed()`
and composes the shipped pipeline: `ChunkStreamer` (4.3) + `NavBaker.bind()` (4.5) +
`ResourceScatterField.attach_to_streamer()` (4.4) + `PoiMap.sites_for_island()` (4.7) — then
**publishes the authored maps' own marker contract** (`authored_world_marker` + `kind` metas,
`authored_world_terrain`, `height_at()` passthrough). D-143 recorded the claim; the check now
proves it: **WellspringService built 4 live Wellsprings from the composer's `objective` markers
with zero service changes.**

**Boot it:** `agent godot --quit-after 25 -- --procedural --seed=20260819` (DevLaunch flag,
debug-only; combines with `--seed=`/host/join flags). The default map is still Hollowmere until
4.19.

**Seams the next tasks build on:**

```gdscript
world.world_seed / world.poi_sites / world.spawn_position   # set by _ready()
world.height_at(x, z) -> float                              # authored-world call shape
world.build_player = false                                  # harness switch, like authored props
PoiDef.marker_kind: StringName                              # "" = scenery; else the service kind
```

- **`PoiDef.marker_kind` is how content joins the world** (D-143): `objective`, `shipwreck`,
  `enemy_nest`, chest kinds, `station` — the composer is a dumb loop. `wellspring.tres` and
  `shipwreck.tres` carry theirs; `standing_stones` is deliberately scenery.
- **Spawn rule (WORLDGEN.md §3.1):** rings probed outermost-first for standable beach
  (height 1–5 m, slope ≤ 0.45, clear of every POI's `clearance_m` + 8 m), scored toward the
  Wellspring centroid — landfall faces the game. Deterministic; published as a `spawn` marker
  (kind is new, no consumer yet — F-063's Player-node capture still handles the session).
- **The trap that cost this task its only red:** markers must join groups and get their `kind`
  meta **BEFORE `add_child`** — services discover on `node_added`, which fires during add_child
  (F-012's mechanism, new consumer). Configured-after markers are invisible to every service.
- **What 4.16 owes:** MireGrid binding, EnemyWorld `enemy_nest` PoiDefs, chest/station kinds,
  the both-map `world_contract_check` matrix, F-112's fold-in.

**Verified:** `agent godot --script tools/procedural_world_check.gd` → **failures=0** (composition,
marker census {objective:4, shipwreck:3, spawn:1} on seed 20260819, service light-up, spawn rule
band/slope/clearance, same-seed exact reproduction of every site and the spawn, different-seed
divergence). Live boot with the flag: **0 ERROR lines**. Regressions: `poi_check`,
`resource_scatter_check`, `world_contract_check`, `verify_setup` all green.


### 2026-08-19 — Asset batch A-014: roads, and the piece that joins two kits (slate17)

**What shipped, verified:** 13 GLBs in `assets/paths/exports/` (`tools/blender/build_path_set.py`,
`assets/source/path_set.blend`), a catalog, three contact sheets, `tools/path_check.gd`. One palette
token appended (`water_still`).

**The catalog now carries the module, not just the sizes:** `module_m` (2.00, A-010's),
`deck_z_m` (`boardwalk` 0.22 and `construction_kit` 1.00), `plank_thickness_m` (0.055) and a
`run_span_m` map naming which pieces tile and on which axes. Anything that lays roads should read
those rather than re-deriving them — and anything that adds a road piece should join that map, or
the tiling contract cannot see it.

**Two gauges of timber, deliberately.** A-013's camp kit is 32 mm board stock; A-010's construction
kit and this kit's boardwalk are 55 mm plank. The rule is *camp furniture is board stock, anything
structural or walked on is plank stock* — worth stating because the two kits look like they
disagree until you know which is which.

**`boardwalk_stairs` is the only piece in either kit that changes level between them**, climbing
0.22 → 1.00 m over one module at 21.3°. If a level or a generator wants a low walkway to meet a
dock, that is the piece; nothing else in A-010 or A-014 does it.

**A path tile's verge is assigned by position, not by `paint_faces`.** The slab's total height range
is 28 mm, so height-based face selection — which is how every other kit paints moss and char —
selects most of the tile and paints blocky patches down the middle of the road. Where a surface is
nearly flat, decide the material while you still know where the quad IS.


### 2026-08-19 — Asset batch A-013: the camp kit, built off one stock list (slate17)

**What shipped, verified:** 16 GLBs in `assets/camp/exports/` (`tools/blender/build_camp_set.py`,
`assets/source/camp_set.blend`), a catalog, three contact sheets, `tools/camp_check.gd`. No palette
changes — the kit is made entirely of tokens A-010 through A-012 already added.

**The stock list is the API.** `catalog.json` carries a `stock` block: plank 32 mm thick and 145 mm
wide, post radius 46 mm, rail radius 28 mm, band 13 mm, stave 22 mm. Anything added to this kit
later — and A-018's settlement shell, which is the same carpentry at building scale — should use
those numbers rather than new ones, and should go through `plank()`/`post()`/`rail()`/`band()`/
`lashing()` so the build contract can see it. A structural part built with a raw `box()` fails the
build; genuinely non-timber parts are declared per asset in `FREEFORM`.

**Two shared frames, named in the catalog's `frames` map.** `rack` (storage, weapon, tool, drying)
and `crate` (intact, broken). Frame drift is **0.0000 mm**, asserted in the generator where the parts
still have names. The engine cannot see those parts — a GLB is one joined mesh — so
`tools/camp_check.gd` asserts the consequence instead: the four racks stand the same height and
width however differently they are loaded, and a smashed crate may only grow past the crate it was,
never shrink. That distinction is worth copying: **assert the named geometry at build time and the
visible consequence at import time**, rather than repeating an assertion the importer cannot make.

**For whoever wires these up:** every asset is ground-centred with no node transform, so it drops in
at `Transform3D.IDENTITY`. None carry collision — presentation meshes, per the tracker's contract —
and the pieces that obviously want a `BuildableDef` row eventually (task 3.7 owns
`content/buildables/`) are the barrels, the crate, the table, the bench, the shelf and the four racks.


### 2026-08-19 — F-233 resolved: the residual `@rpc("any_peer")` surface F-232 left unfixed now has a standing audit check instead of a hand-written list (lm)

**What shipped, the seam the next new `@rpc("any_peer")` handler builds on:**
`tools/rpc_surface_audit_check.gd` (new) — buckets every `any_peer` entry `RpcManifest.scan()` finds
(the same scanner `tools/rpc_manifest_check.gd` uses for wire-signature drift) into `RATE_LIMITED`,
`SELF_GUARDED`, or `BOUNDED_O1`, and fails if any entry is in none of the three (new, untriaged) or if
a bucketed entry has disappeared (stale list). Run it with `.agent/bin/agent godot --script
tools/rpc_surface_audit_check.gd`. **When you add a new `@rpc("any_peer")` handler:** if it does real
per-request work (a physics/space query, a tree or group scan — anything beyond a `Dictionary`
lookup or a bounds-checked write), wire it through `RpcRateLimiter` per the rule in the F-232 entry
below and add its key to `RATE_LIMITED`; if it already has its own cooldown or in-flight guard, add it
to `SELF_GUARDED`; otherwise add it to `BOUNDED_O1`. The check fails loudly either way if you forget —
that's the point.

**Found while re-deriving the list, not by inspection:** `AttunementService.net_request_attunement`,
`InventoryService.net_request_remove`/`net_request_move_stack`, and `Harvestable.net_request_hit` were
missing from both F-232's `docs/SPECS.md` audit enumeration and F-233's original `docs/FINDINGS.md`
list. All four turned out to be the same shape as an already-triaged handler in their bucket (no fix
needed) — the gap was in the audit trail, not the code. `docs/FINDINGS.md`'s F-233 entry carries a
dated correction rather than a new finding number, since nothing was broken.

**Verify:** `.agent/bin/agent godot --script tools/rpc_surface_audit_check.gd` →
`RPC_SURFACE_AUDIT_CHECK failures=0`. Full boot (`agent godot --quit-after 120`) — 0 stray `ERROR:`
lines. Full write-up: `docs/FINDINGS.md` F-233 (Resolved), `docs/SPECS.md` F-233 block.

### 2026-08-19 — F-232 resolved: hostile-client audit across every `net_request_*`/`net_submit_*` entry point — new `RpcRateLimiter` closes the one real gap it found (lm)

**What shipped, the seam the next host RPC with real per-request cost builds on:**
`core/net/rpc_rate_limiter.gd` — `RpcRateLimiter` (`RefCounted`), a per-peer minimum-interval gate:
`allow(peer_id: int, min_interval_msec: int) -> bool` returns true (and records "now") at most once
per `min_interval_msec` per peer, false otherwise; `reset(peer_id: int)` clears one peer's entry (F-059
shape — call it from a peer-departure hook if a caller ever needs the timestamp not to carry across a
reused peer id, though neither current caller bothers, since a stale timestamp only ever costs a new
connection's first request up to `min_interval_msec` of extra latency, never a correctness bug). Wired
into `BuildService.net_request_place`/`net_request_destroy` and
`CommandService.net_submit_command` (`RATE_LIMIT_INTERVAL_MSEC = 100` in each, one `RpcRateLimiter`
instance per autoload — never share one instance across files, since peer ids collide meaninglessly
across unrelated request kinds). A throttled request gets an ordinary rejection reply through the
handler's own existing confirm/result seam (`"requests too frequent — slow down"` /
`"commands too frequent — slow down"`), never a silent drop.

**The rule for the next `@rpc("any_peer")` handler that turns out to do real per-request host work**
(a physics query, a tree scan, anything beyond O(1) dictionary/state lookups): `preload("res://
core/net/rpc_rate_limiter.gd")`, one `var _rate_limiter := RATE_LIMITER.new()` per autoload/script, one
`RATE_LIMIT_INTERVAL_MSEC` constant, and gate the RPC handler itself (not the local/offline call path
— `_rate_limiter.allow(multiplayer.get_remote_sender_id(), RATE_LIMIT_INTERVAL_MSEC)` before doing any
real work, replying with the ordinary rejection shape on false. `docs/FINDINGS.md` F-233 names every
handler already checked and found NOT to need this yet — check there before assuming a new one does.

**A second, unrelated fix the audit's own check surfaced:** `CommandService._parse_args()` now runs a
`selector`-typed optional argument's default through `_parse_selector()` when the stored default is a
raw String, instead of handing an unparsed string straight to a handler expecting the parsed Dictionary
shape — the trap the `entities` command's own `"default": "@e"` had fallen into (its documented bare
form, `entities` with no argument, crashed before this). Any future selector-typed optional arg gets
this for free; no per-spec fix needed.

**Verify:** `agent godot --script tools/hostile_client_check.gd` (new — real two-process ENet flood,
`HOSTILE_CLIENT_CHECK failures=0`), `tools/build_net_check.gd` (0 failures, ordinary sequential
requests unaffected), `tools/rpc_manifest_check.gd` (RPC count/PROTOCOL_VERSION unchanged — only
handler bodies changed, no new wire shape), `tools/entity_check.gd`/`tools/command_check.gd`/
`tools/function_check.gd`/`tools/command_console_check.gd` (all 0 failures). Full writeup:
`docs/FINDINGS.md` F-232 (Resolved) and F-233 (residual, low severity), `docs/DECISIONS.md` D-141,
`docs/SPECS.md` F-232 block.

### 2026-08-19 — F-231 resolved: `ResourceScatterField`'s depletion-restore no longer replays a real harvest yield — new `Harvestable.host_restore_depleted()` reaches the same state without the side effect (lm)

**What shipped, the seam the next "restore remembered state" caller builds on:**
`systems/harvesting/harvestable.gd` gained `host_restore_depleted() -> bool`, host-only (same
`_owns_world_mutation()`/`_configuration_valid`/`active` gate `host_apply_damage()` uses). It reaches
the identical final state a lethal `host_apply_damage()` hit does — `health` zeroed, `active` off,
`_respawn_remaining` armed at `respawn_seconds` — but never emits `depleted` or
`EVENT_BUS.emit_harvest_yielded()`. `world/gen/resource_scatter_field.gd`'s `_wire_point_state()`
calls this instead of replaying `host_apply_damage()` when a rebuilt point's depletion memory
(`WorldDeltaLog`, falling back to the field's own peer-local `_depleted`) says it was already
harvested — the old path paid the host a second, unearned copy of the item on every chunk
unload/reload of an already-harvested point, since reaching 0 health through `host_apply_damage()`
always runs the same `_deplete()` a real swing does.

**The rule for the next system that needs to restore remembered state through an existing
mutation seam:** never replay a method that both changes state AND fires a signal another system
reacts to, purely to reach its state outcome. `Harvestable` now has two explicitly separate host
methods for this — `host_apply_damage()` for a hit that is happening right now and should be seen,
`host_restore_depleted()` for remembering one that already happened and already paid out. Recorded
as D-139 (narrows D-083, which was right that a direct `active` poke is wrong but picked the wrong
mechanism to fix it).

**Verify:** `agent godot --script tools/resource_scatter_check.gd` (27/27, new inventory-count
assertions across harvest → teardown → rebuild), `tools/harvestable_check.gd` (29/29),
`tools/harvestable_net_check.gd` (`yields=1 failures=0`). Full writeup: `docs/FINDINGS.md` F-231
(Resolved), `docs/DECISIONS.md` D-139, `docs/SPECS.md` F-231 block.

### 2026-08-19 — F-208 resolved: sway-bearing props can now join `AuthoredWorld`'s cross-asset chunk merge — a per-vertex baked height mask replaces the per-mesh AABB `_apply_sway` needs (lm)

**What shipped, the seam the next merge-eligibility widening builds on:**

- `core/render/mesh_merge.gd`'s `merge_instances(entries, bake_height_mask: bool = false)` — the
  new parameter bakes a per-vertex normalised height into `UV2.x`, computed from EACH entry's own
  source mesh's local AABB before that entry's placement `transform` is applied. Any future caller
  that needs a per-vertex value surviving a cross-instance bake (not just sway) can reuse this
  exact shape: compute the per-entry quantity from the entry's own local frame, write it before
  `transform`, force the attribute bit on for the whole call.
- `world/environment/foliage_wind.gdshader`'s `use_baked_mask` uniform — `false` (default) reads
  the mask from `wind_root_y`/`wind_inv_height` against `VERTEX.y` exactly as before; `true` reads
  it from `UV2.x` instead. Every existing per-asset sway material is unaffected; only a merged
  holder's material sets the new uniform.
- `world/gen/authored_world.gd`'s `_build_props()` gained `sway_mergeable`, a third bucket next to
  `mergeable`/`emitter_mergeable`, keyed `"<chunk>|s<sway_int>"`. **Scope:** an asset with BOTH
  sway and an emitter (`mire_tendril`) is excluded from every bucket — not attempted here, see
  `docs/SPECS.md` F-208 for why. A merged sway holder carries `EnvironmentVfx.SWAY_META`
  (`&"vfx_sway"`) and no `PLACEMENTS_META` (nothing reads a per-instance position for pure sway).
- `autoload/environment_vfx.gd` gained `SWAY_META`, `_merged_sway_for()`, `_apply_baked_sway()`,
  `_baked_sway_material()` — the same shape as F-203's `EMITTER_META`/`_merged_emitter_for()`/
  `_register_emitter()`. A future third VFX category on a merged holder should follow this same
  `*_META` constant + ancestor-walk + dedicated apply function pattern rather than inventing a new
  one.
- `AuthoredWorld.merged_sway_instance_count` — a plain stat, not read by any runtime system, that
  exists only because a sway holder publishes no live per-instance data; any check that wants
  "total swaying prop coverage" must add this to whatever it counts from live `MultiMeshInstance3D`
  nodes (`tools/environment_vfx_hollowmere_check.gd` does this already).

**Verify:** `agent godot --script tools/mesh_merge_check.gd`, `tools/prop_chunk_merge_check.gd`,
`tools/environment_vfx_hollowmere_check.gd`. Full writeup: `docs/FINDINGS.md`/`docs/SPECS.md` F-208.

---

### 2026-08-19 — F-214 resolved: `Undergrowth` now carves a keep-out disc for every `shipwreck`/`objective` marker, so grass no longer scatters through `ExtractionShip`'s hull or `Wellspring`'s foundation (lm)

**What shipped:** `world/gen/undergrowth.gd`'s scatter pass (`_scatter()`) can now reject an attempt
before the ray probe if it falls inside a marker-bridge live object's own footprint —
`_collect_marker_exclusions()` reads the layout's `markers` array once per scatter/rescatter and builds
one disc per `shipwreck`/`objective` marker, `_in_marker_exclusion()` tests a candidate point against
all of them. Each disc's radius is read from the object's own script — `ExtractionShip.HULL_HALF_EXTENTS`
circumscribed in XZ (`≈6.02 m`) and `Wellspring.FOUNDATION_RADIUS_M` (`2.4 m`) — preloaded by path the
same way `AssetVfx` already is in this file (F-016: a brand-new `class_name` is not bare-resolvable in a
fresh headless `--script` run), not hard-coded, so the exclusion tracks either object's real size if it
ever changes.

**The pattern for the next marker-bridge object that needs this:** add its kind to the `match` in
`_collect_marker_exclusions()` with a radius pulled from that object's own script the same way — nothing
else in `Undergrowth` needs to change. This only matters for a bridge that builds genuinely new runtime
collision from a marker (`autoload/extraction_service.gd`/`autoload/wellspring_service.gd`'s shape); a
bridge that only adds a logic node onto an already-authored prop's existing mesh/collision — the shape
`autoload/chest_placement_service.gd` and `autoload/crafting_service.gd` both use — was checked and does
not need an entry, because the offline scatter pass already sees that geometry through the ordinary
`prop_group` ray-avoidance path.

**Verify:** `agent godot --script tools/hollowmere_check.gd` →
`HOLLOWMERE_FLORA_GROUND sampled=10243 perched=0 worst=0.00 m`, `HOLLOWMERE_CHECK PASS` (was
`sampled=10338 perched=23 worst=4.26 m` before the fix, matching the finding's own numbers exactly).
Full writeup: `docs/SPECS.md` F-214 block.

### 2026-08-19 — F-197 resolved: both halves were already fixed by F-057 and F-191, neither cross-referenced this finding back — closing it needed no code (lm)

No defect found: F-057 (`a0d0d46`) had already rebuilt and re-committed the crafting-station
exports/catalog that this finding reported as stale, and F-191 (resolved chronologically *after*
F-197 was filed) had already generalized `cmd_check`'s sweep-naming warning to every file in a commit,
not a docs/harness-scoped subset — see that finding's own entry above for the mechanism. Neither
resolution note in `docs/FINDINGS.md` linked back to F-197, so it sat open on the board despite both
causes being fixed. Re-verified rather than trusted: `python3
tools/blender/crafting_stations_repro_check.py` PASS with zero diff on `exports/`/`catalog.json`
after the run (only the non-deterministic preview PNGs and `.blend` save-state changed, both
expected and discarded), and `tools/harness_check.py`'s F-191 cases already exercise a plain
non-docs path (`world/thing.gd`), proving the warning isn't scoped to the two file categories its
own writeup discusses. **If you resolve a finding by pointing at another finding's fix, add the
cross-reference in the same commit** — that's the gap this task closes, not a code change.

**The general shape worth knowing about:** `agent brief <F-id>` already flags "this finding may
already be fixed — files it names have changed since it was filed" for roughly two-thirds of the
findings still open on the board (2026-08-19 snapshot: F-023, F-024, F-044, F-139, F-174, F-189,
F-207, F-214). That flag only means the named files moved, not that the fix landed — each one still
needs its own targeted re-check like this task did, not a blanket close. Not swept here: verifying
eight unrelated findings across netcode, worldgen and tooling is eight separate tasks' worth of work,
each needing its own repro, not a mechanical grep.

### 2026-08-19 — F-217 resolved: `BuildBar`'s piece-selection slots now support gamepad focus navigation — the last gap F-209/F-216's sweeps had already named (lm)

`ui/building/build_bar.gd`'s `PieceSlot` (inner class of `BuildBar`) is the pattern to copy for any
future runtime-built `PanelContainer` row that needs keyboard/gamepad selection: `focus_mode =
Control.FOCUS_ALL` was already there, but `_gui_input()` only reacted to a mouse click. Three pieces,
each reused from an existing seam rather than invented:

- **Selection:** `_gui_input()` gained `event.is_action_pressed(&"ui_accept")` calling
  `select_requested.call(piece_id)` — the same branch `InventoryUI.InventorySlot` uses for its own
  pick-up/drop (F-209), minus the carry-state tracking since selecting a build piece is one action.
- **Chain:** new `BuildBar._wire_horizontal_chain()`, run once at the end of `_populate_slots()`
  (slots are boot-static, never rebuilt). Same wrap-around recipe as
  `UnlockMenu._wire_vertical_chain()`/`AttunementUI`'s copy (F-209/F-216), but `focus_neighbor_left`/
  `_right` instead of `_top`/`_bottom` since the slots sit in one `HBoxContainer` row.
- **Focus ring:** `PieceSlot extends PanelContainer`, which has no native `"focus"` theme item — same
  gap F-215 hit on `Slider`. Used `InventoryUI.InventorySlot`'s technique for this same control type
  (a `"panel"` stylebox swap via `_update_style()`) rather than F-215's `_draw()`-override technique,
  since `PieceSlot` already swaps `"panel"` for its selected-piece indicator and a third swapped style
  (new `_focus_style`, `COLOUR_FOCUS` matching `InventoryUI`'s own hue) needed no new drawing code.
  Priority when both are true: focus beats selected.

**Initial focus needed no separate open hook.** `player_controller.gd`'s `set_selected_build_piece()`
always calls `BuildBar.set_active(true)` immediately followed by `set_selected_piece(piece_id)` — there
is no "activate with nothing selected" path. So `set_selected_piece()` itself grabs focus for the
matching slot (`_grab_focus_for_selected()`), and every entry into build mode — click or gamepad —
already funnels through that one method.

**Verified:** `.agent/bin/agent godot --script tools/gamepad_check.gd` → `GAMEPAD_CHECK failures=0`.
New `_check_build_bar_slot_focus()` drives real gamepad D-pad/`ui_accept` events through
`Input.parse_input_event()` (focus movement is Godot's own Viewport GUI focus walk, not something
`_unhandled_input()` implements — the same reason `tools/menu_focus_check.gd` uses that mechanism for
every other panel) and reads `gui_get_focus_owner()` back, proving selection grabs focus, D-pad right/
left move it across the row and back through the real `focus_neighbor` chain, and gamepad `ui_accept`
on a focused slot changes `BuildGhost.current_piece_id()` through the real seam.

**Swept, not found:** `grep -rn 'focus_mode = Control.FOCUS_ALL'` across `ui/`/`entities/` — only two
runtime-construction sites exist in the project, `build_bar.gd` (this task) and `inventory_ui.gd`
(already fixed, F-209); every panel with `grab_focus`/`focus_neighbor` wiring already carries it.
F-216's own sweep had already named F-217 as the one remaining gap of this shape. Full writeup:
`docs/SPECS.md` F-217 block.

### 2026-08-19 — F-215 resolved: `HSlider` now draws a real focus ring via `FocusRingSlider` (lm)

`Slider` (`HSlider`'s base, `scene/gui/slider.cpp`) has no `"focus"` theme stylebox item in Godot
4.7.1, unlike `Button`/`OptionButton`/`CheckBox`/`LineEdit` — `add_theme_stylebox_override("focus",
...)` on an `HSlider` is silently inert. **New `ui/menu/focus_ring_slider.gd`,
`class_name FocusRingSlider extends HSlider`, is the seam for this now:** set its public
`focus_ring_style: StyleBoxFlat` to whatever `StyleBoxFlat` the menu already uses for its other
controls' focus rings, and it draws that style over its own rect on `_draw()` whenever
`has_focus()` is true, repainting via `queue_redraw()` on `focus_entered`/`focus_exited`. Any future
task adding an `HSlider`/`VSlider` to a gamepad-navigable panel should construct `FocusRingSlider`
instead of a bare `HSlider` and set `focus_ring_style` — don't re-add a dead `"focus"` stylebox
override, and don't re-derive this fix. `settings_menu.gd`'s `_build_slider_row()` is the one real
call site so far; all six of its sliders (master/music/sfx volume, mouse and gamepad look
sensitivity, FOV) already route through it.

**Verified:** `.agent/bin/agent godot --script tools/menu_focus_check.gd` → `MENU_FOCUS_CHECK
failures=0`, including a new assertion that the master volume slider `is FocusRingSlider` with a
non-null `focus_ring_style` — the plumbing proxy every other control's
`has_theme_stylebox_override(&"focus")` check can't reach here.

**Swept, not found:** every other `add_theme_stylebox_override("focus", ...)` call site targets a
control type that does have a native `"focus"` item (Button/OptionButton/CheckBox/LineEdit); no
other `HSlider`/`VSlider` construction site exists anywhere in the project.

### 2026-08-19 — F-220 resolved: `CycleModifierService`'s per-cycle modifier draw derives its seed from `GameState.run_seed`, not boot-time entropy (lm)

Same fix shape as F-210/F-219 below, and the simplest of the three: no new id scheme needed.
**`CycleModifierService` (`systems/cycle/cycle_modifier_service.gd`) gained the identical private
pair `Chest`/`RewardService` carry** — `_run_seed() -> int` and `_seed_for_run(run_seed: int, draw_id:
String) -> int` (own salt `_SEED_SALT = 0xB16B00B5`, distinct from every other file's). `cycle: int`
was already `host_draw_modifier()`'s own parameter and is a Cycle's stable per-draw id on its own (a
Cycle only advances forward, and each cycle draws at most once) — no counter to mint, unlike
`RewardService`. `_ready()`'s `_rng.randomize()` is gone; `host_draw_modifier()` now sets `_rng.seed =
_seed_for_run(_run_seed(), str(cycle))` immediately before `_weighted_pick()`.

**Verified:** new `tools/cycle_modifier_seed_check.gd` — `agent godot --script
tools/cycle_modifier_seed_check.gd` → `CYCLE_MODIFIER_SEED_CHECK failures=0`. Real content ships only
one Cycle Modifier (`long_night.tres`), too few for a weighted pick to show seed-dependent variation,
so the check injects three synthetic equally-weighted candidates straight into `_defs` (same seam
`tools/cycle_modifier_check.gd`'s own incompatibility tests use) and checks: same `run_seed` + same
`cycle` draws identically; replaying a `run_seed` across a cycle sequence reproduces the exact same
per-cycle draws; a different `run_seed` at the same cycles draws a different sequence.
`tools/cycle_modifier_check.gd` (the existing wiring/eligibility check, unchanged) still
`CYCLE_MODIFIER_CHECK failures=0`.

**Swept, not found:** all `.randomize()` call sites project-wide re-checked (three remain, all
previously-confirmed intentional exceptions — see F-219's own sweep note below). F-220 was the last
of the four live sites F-210's original sweep found.

### 2026-08-19 — F-219 resolved: `RewardService`'s Wellspring/boss-kill loot roll derives its seed from `GameState.run_seed`, not boot-time entropy (lm)

Same fix shape as F-210's `Chest` entry below, adapted for a trigger with no placement id of its own.
**`RewardService` (`autoload/reward_service.gd`) gained the identical private pair `Chest` has** —
`_run_seed() -> int` and `_seed_for_run(run_seed: int, event_key: String) -> int` (own salt
`_SEED_SALT = 0x9E3779B9`, distinct from every other file's) — plus one thing `Chest` didn't need: a
`_next_reward_event_id: int` counter, since a Wellspring cap / boss kill has no stable node name to
key off. It increments once per `_grant_tier_to_party()` call (once per TRIGGER, not per peer — two
caps in one run must not roll the same) and resets to 1 on `GameState.seed_ready`, the same "a run
has begun" hook `autoload/salvage_service.gd` already subscribes to for its own per-run tally reset —
copy that file's `_ready()`/`_exit_tree()` connect/disconnect pair for any other per-run counter that
needs the same reset. Each present peer's roll now seeds from `_seed_for_run(run_seed, "%s:%d:%d" %
[tier, event_id, peer_id])` — a fresh `RandomNumberGenerator` per peer, replacing the one shared
`.randomize()`d generator the whole trigger used to loop over.

**Verified:** new `tools/reward_service_seed_check.gd` — `agent godot --script
tools/reward_service_seed_check.gd` → `REWARD_SERVICE_SEED_CHECK failures=0`. Fires
`EventBus.emit_wellspring_capped()` against the REAL `content/loot/wellspring.tres` (no synthetic
table — same choice `tools/reward_service_check.gd` already made) and diffs the check player's
coin/powerup-stack state around each trigger to get a comparable fingerprint: same `run_seed`
replayed from a fresh `seed_ready` reset rolls identically; a second trigger in the same run (no
reset) does not repeat the first roll; a different `run_seed` at the same trigger position rolls
differently. `tools/reward_service_check.gd` (the existing wiring/grant-amount check, unchanged) still
`REWARD_SERVICE_CHECK failures=0` — its own "non-seeded `randomize()`" caveat in the F-183 entry below
is now stale; this entry supersedes it.

**Swept, not found:** all four `.randomize()` call sites project-wide checked again. Only
`systems/cycle/cycle_modifier_service.gd:56` is a live sibling of this bug shape, and it was already
filed as F-220 by F-210's own sweep — left open, outside this task's claim.

### 2026-08-19 — F-218 resolved: `tools/decision_trigger_check.py` mechanically flags fired `docs/DECISIONS.md` reversal triggers (lm)

**Run `python3 tools/decision_trigger_check.py` any time you're about to add a decision, or touch
one already there** — no claim needed, it's read-only and reads `docs/DECISIONS.md` off disk. Prints
`DECISION_TRIGGER_CHECK decisions=N checkable=M fired=K` then one `FIRED D-0NN ...` line per hit,
naming the backtick token, the file it's declared in, and the date. It is **not** wired into `agent
start` — a real-repo run costs ~5s (many small `git log`/`git grep` calls), which is a tax on every
session for a signal that only changes when `docs/DECISIONS.md` or the source tree does. Run it by
hand.

**What it can and can't see:** only a **Would change my mind:** clause that names a backtick-quoted
file or symbol which now exists (declared via `class_name`/`func`/`signal`/`const`/`var`, or
registered as a `project.godot` autoload — the `GameState`-style singleton shape) but didn't on the
decision's own date. Most clauses are prose judgement calls (D-011's "often enough" among them) with
nothing concrete to check — those stay silent, on purpose, not a bug.

**If it flags a decision that's still the right call, don't argue with the fired evidence — annotate
it.** D-135 (this task) settled the convention: a one-line `*Reviewed <date> — <why>.*` right under
the decision's heading, same place `*Superseded by ...*`/`*Amended by ...*` already live, stops the
check from re-flagging that decision on every future run without touching the append-only reasoning
body. D-041 got exactly this treatment as the worked example — F-210 had already done the switch its
trigger asked for; the annotation just records that the check now agrees.

**`--self-test` proves the fire/no-fire distinction on synthetic history** (throwaway repo, same
pattern as `tools/harness_check.py`) — run it after touching the script, before trusting a real scan.

### 2026-08-19 — F-210 resolved: `Chest`'s loot roll derives its seed from `GameState.run_seed`, not boot-time entropy (lm)

**`Chest` (`systems/loot/chest.gd`) now has two private helpers anything deriving a host-only,
run-reproducible seed can copy the shape of:** `_run_seed() -> int` (reads `GameState.ensure_seed()`
through the standard `get_node_or_null(^"/root/GameState")` + `.call()` seam) and
`_seed_for_run(run_seed: int, chest_id: String) -> int` (integer multiply/xor mixing, `_SEED_SALT =
0xC4E57`, same convention `world/gen/poi_map.gd`/`world/gen/resource_scatter.gd` already use — pick a
fresh, distinct salt if you copy this into a new file rather than reusing `0xC4E57`). `_ready()` calls
`_rng.seed = _seed_for_run(_run_seed(), String(name))` — `name` works as the stable per-chest id only
because `ChestPlacementService` sets it (`"Chest_<marker name>"`) before `add_child()`; a system with
no equivalent authored-and-fixed id (F-219's `RewardService` trigger events) needs to invent one
before this pattern applies. `Chest.host_seed_rng(seed_value)` (the debug/test override seam) is
unchanged and still wins over whatever `_ready()` computed, for any caller that invokes it afterward.

**Filed rather than fixed, same bug shape:** F-219 (`RewardService`'s Wellspring/boss-kill party
roll) and F-220 (`CycleModifierService`'s per-cycle modifier draw — already has `cycle: int` as a
ready-made stable id, so its fix is the closest to a direct copy of this one).

**Verified:** new `tools/chest_seed_check.gd` — `agent godot --script tools/chest_seed_check.gd` →
`CHEST_SEED_CHECK failures=0`. Proves same `(run_seed, chest name)` grants identical loot twice, and
that changing either input changes the grant (1..999 amount range, so a coincidental match is not a
realistic false-pass).

### 2026-08-19 — F-209 resolved: every menu supports gamepad focus navigation; `ui_accept`/`ui_cancel` now carry gamepad bindings project-wide (lm)

**For anyone touching `MainMenu`/`SettingsMenu`/`LobbyMenu`/`InventoryUI`/`CraftingUI`/`UnlockMenu`
next:** each now builds its focus chain with a per-file `_wire_vertical_chain(controls: Array)` helper
(top/bottom `focus_neighbor_*` with wraparound — copy the pattern rather than re-deriving it) and a
`_focus_style() -> StyleBoxFlat` helper (transparent-fill, bright-border outline, applied via
`add_theme_stylebox_override("focus", ...)`). Both are duplicated per file on purpose, matching this
codebase's existing `_button()`/`_panel_style()` duplication rather than a shared base class — if a
future task adds an eighth menu, copy the shape rather than importing from one of these six.
`set_open(true)` grabs focus on the first interactive control in every one of them; a dynamic row list
(a keybind row, a per-station recipe row) has to call its own wiring helper again on rebuild, not just
once at `_build_ui()` time — `SettingsMenu._build_keybind_rows()`/`_build_gamepad_bind_rows()` and
`CraftingUI._rebuild_rows()` are the worked examples.

**`InventoryUI` gained two things worth knowing before extending it:**
1. `_wire_focus_neighbors()` — explicit grid/hotbar `focus_neighbor_*` wiring, re-run from
   `_apply_layout_for_width()` every time the column count changes (8 desktop / 6 narrow). Explicit,
   not automatic-geometric-search, because the grid and hotbar live in separate container trees.
   Depends on `INVENTORY_SLOT_COUNT` (24) dividing evenly by both column counts — if either constant
   ever changes to break that, this function's row-math needs a ragged-last-row case it does not have.
2. A gamepad/keyboard equivalent to the mouse-only `_get_drag_data`/`_drop_data`: `ui_accept` on an
   `InventorySlot` (added to `InventorySlot._gui_input`) calls `activate_requested`, which
   `InventoryUI._on_slot_activated` turns into a pick-up-then-drop flow through the same
   `request_slot_move()` a mouse drag already used. `carrying_slot_index()` exposes the in-progress
   pick for checks (mirrors every other public accessor already on this file). `InventorySlot.setup()`
   grew a required 6th `activate_callback: Callable` parameter — both call sites in
   `InventoryUI._build_ui()` (backpack grid, hotbar row) already pass `_on_slot_activated`.

**`ui_accept`/`ui_cancel` now carry `JOY_BUTTON_A`/`JOY_BUTTON_B` project-wide** (D-134) —
`project.godot`'s `[input]` section, written by the one-shot `tools/bind_ui_gamepad_actions.gd`. Any
future check or menu can now assume a focused `Button`/`OptionButton`/`CheckBox` responds to a real
gamepad A press; before this task, only `ui_up`/`down`/`left`/`right` did.

**Verification pattern for future menu/focus work:** `tools/menu_focus_check.gd` is the worked
example for proving `focus_neighbor_*` actually works, not just that it's set — inject a real
`InputEventJoypadButton` via `Input.parse_input_event()`, `await process_frame` a couple of times, and
read `get_viewport().gui_get_focus_owner()` back. Calling a panel's own `_input()`/`_gui_input()`
directly (`gamepad_check.gd`'s usual style) does NOT exercise focus movement — that's Godot's own
Viewport GUI handling, not something any of these scripts implement themselves. Its `_walk_loop()`
helper (tap one direction repeatedly until focus returns to the start, asserting no repeat visit along
the way) is a reusable way to prove an entire chain is one correct closed loop without hardcoding how
many controls are in it — useful again for F-216/F-217's eventual fixes.

Not fixed here, filed instead: F-215 (`HSlider` has no `"focus"` theme item in Godot 4.7.1, so its
ring override is inert — still fully operable, just invisible which one has focus), F-216
(`AttunementUI`, the mandatory no-Esc run-start picker, has no gamepad focus support at all — higher
severity than F-209 itself, since there's no way past it without a mouse), F-217 (`BuildBar`'s
`PieceSlot` piece selection is still mouse-only; build mode toggle/rotate/confirm/destroy already work
by gamepad since task 7.6). Full writeup: `docs/SPECS.md` F-209 block.

### 2026-08-19 — F-166 resolved: the Hollowmere map now has a `shipwreck` marker, so task 6.5's `ExtractionShip` is reachable in the live game (lm)

**Supersedes** task 6.5's "Not reachable in the live game yet" note (below, ~line 1278) and the
world-gen seams note that `extraction`/`objective` markers are "still unconsumed" (further below,
~line 3852) — `extraction` is still unconsumed (it's a UI/label-only landmark kind,
`tools/hollowmere_check.gd`'s `_check_markers` just requires it exist), but `shipwreck` is now live.

`world/gen/layouts/hollowmere.json` gained one marker —
`{"name":"Shipwreck","kind":"shipwreck","zone":"MereShore","pos":[62.0,1.54,29.0]}` — at the exact
point the layout's own `extraction pad`/`cache`/`ward`/`rail`/`markers` props already built a dock
around, with nothing ever placed on it. `autoload/extraction_service.gd` needed no change; it builds
a live `ExtractionShip` there automatically the next time the scene constructs, same as
`wellspring_service.gd`'s `"objective"` marker already proves.

**For whoever next touches `world/gen/layouts/hollowmere.json`:** it is single-line minified JSON,
~550 KB. Editing it by hand in an editor is impractical — load it with `json.load`, mutate the
Python structure, and `json.dumps(data, separators=(",", ":"))` back out; that reproduces the file's
existing compact formatting byte-for-byte apart from your actual change; diff it before committing.

**`tools/hollowmere_check.gd` gained two things**, both worth knowing before extending it further:
1. `_check_shipwreck_becomes_ship()` — finds the `shipwreck`-kind marker in the live scene and
   asserts it has an `ExtractionShip_*` child, so the marker→live-object bridge is proven against the
   *real* map, not just `tools/extraction_check.gd`'s synthetic one.
2. `_probe_ground()`'s prop-collider skip now also skips any collider whose parent is in group
   `&"wellspring"` or `&"extraction_ship"` — both drop a runtime-built `StaticBody3D` on the terrain
   (`_build_collision()` in `wellspring.gd`/`extraction_ship.gd`) that was never in
   `authored_world_prop` because it isn't a layout prop. This was a latent gap in the check itself
   (Wellspring had the same exposure and just never got unlucky with the probe's seeded RNG) —
   **any future live object built by a marker-bridge service with its own solid collision needs the
   same group added here**, or a ground probe that happens to land on it will read as a false
   terrain-collision failure.

Verified: `agent godot --script tools/hollowmere_check.gd` → `HOLLOWMERE_CHECK PASS`,
`HOLLOWMERE_SHIPWRECK marker=Shipwreck ship_built=true`. `agent godot --script tools/extraction_check.gd`
→ `failures=0`, unaffected. Full writeup: `docs/SPECS.md` F-166 block.

### 2026-08-19 — F-161/F-165/F-169/F-178 closed: `PROTOCOL_VERSION` catch-up bump (20 → 21) plus `core/net/rpc_manifest.gd`, the mechanical check that replaces "remember to bump it" (lm)

**The re-record workflow, for the next task that adds/removes/reshapes an RPC:** bump
`NetVersion.PROTOCOL_VERSION` in `core/net/net_version.gd` as always, add your own `## N (task X)`
history comment naming what changed, then run `agent godot --script tools/rpc_manifest_check.gd`. It
now fails on purpose — your new RPC changed the scanned signature but `core/net/rpc_manifest.gd`'s
`RECORDED_SIGNATURE`/`RECORDED_ENTRY_COUNT`/`RECORDED_PROTOCOL_VERSION` still hold the old values —
and it prints the exact block to paste over those three constants. Paste it, re-run, confirm green.
Skipping the version bump and only re-recording is the one thing the check exists to catch: recording
a new signature against an unchanged `PROTOCOL_VERSION` fails loudly rather than silently accepting it.
`tools/handshake_check.gd`'s own `PROTOCOL_VERSION == N` assertion still needs raising by hand to
match — the manifest check doesn't touch that file.

`RpcManifest.scan()` walks every `.gd` file under `res://` except `SKIP_DIRS`
(`.godot`, `.git`, `assets`, `docs`, `.agent`, `addons`, `tools` — `tools/` is excluded so a harness
script's own `@rpc` declarations, like `handshake_check.gd`'s three, never force a version bump for
adding a test) and reduces every `@rpc`-annotated function to one line:
`<script path>::<func name>(<arg types>)|<rpc config>`, sorted. Argument names are dropped (renaming a
parameter changes no bytes); argument types, order and the `@rpc` config (`any_peer`/`authority`,
`reliable`/`unreliable`) are kept, because those are exactly what `net_version.gd`'s own header already
names as desync risks.

**Known gap, filed separately (F-213), not blocking:** `RpcManifest.signature()`'s FNV-1a seed literal
overflows signed 64-bit int and prints engine `ERROR:` lines every run — the hash it produces is still
deterministic (so `RECORDED_SIGNATURE` still matches correctly and the check's PASS/FAIL is sound),
just not actually the FNV-1a offset basis the comment claims. Whoever fixes F-213 will need to
re-record `RECORDED_SIGNATURE` once, since correcting the seed changes the hash's *value* (not its
determinism) even though nothing about the RPC surface itself changes.

Verified (this task): `agent godot --script tools/handshake_check.gd` → 0 failures.
`agent godot --script tools/rpc_manifest_check.gd` → `RPC_MANIFEST_CHECK failures=0`, 55 RPCs, all
four findings' RPC sets present in the scanned signature.

### 2026-08-19 — F-211 fixed: `agent order`'s `_suggest_check()` no longer lets a word/plural pair (build/builds, command/commands, …) double-count into a fake second match (lm)

`.agent/bin/agent`'s `_suggest_check(tid, title)` — the function that fills a work order's "Verify it
yourself, headless" section whenever `docs/SPECS.md` has no block yet for the task — matched
`tools/*_check.gd` filenames against a task title by fuzzy-word overlap, requiring `>= 2` hits before
suggesting a file. It counted matching WORDS, not distinct filename PARTS, so two different spellings
of one word (e.g. "build" and "builds", both real tokens in `_tokens()`'s dedup set) could satisfy the
`>= 2` floor by themselves, with no second genuine signal. This is what put
`build_check.gd`/`build_net_check.gd`/`buildable_content_check.gd` (task 3.6/3.7's buildable/crafting
placement system) into task 8.4's Steam-export work order — 8.4's title has "build" and "builds", none
of which have anything to do with those scripts' actual subject.

**Fixed:** now requires two of a filename's own underscore-split parts to each independently match a
title word — a plural/inflection pair can only ever satisfy one part between them. Verified against
every title in `.agent/state.json` (344 tasks/findings): 29 changed, all 29 read by hand, every one a
dropped false positive of the identical shape (`session`/`sessions`, `command`/`commands`,
`craft`/`crafting`, and others) — full detail in `docs/SPECS.md`'s `## F-211 ·` block.

**What this means for future `agent order` calls:** a task with no SPECS.md block yet now gets a
*correct* suggestion or none at all — never falls back to `.agent/bin/agent godot --quit-after 120 #
no focused check exists yet`, same as before, but no longer risks pointing a lane at a green check
that proves nothing about its actual deliverable. If `agent order` still suggests the wrong check for
some other task, that is real signal the title-matching heuristic needs more than this fix, not
something to work around by hand-editing the generated order.

### 2026-08-19 — Task 8.4: Steam release export presets, `steamcmd` upload pipeline, branch guard — built against D-008's placeholder App ID, ready for 8.2/8.11 to fill in (lm)

**What shipped:** three new release export presets in `export_presets.cfg` — `"macOS (Release)"`,
`"Windows Desktop (Release)"`, `"Linux (Release)"` (`preset.3`/`.4`/`.5`) — a near-duplicate of the
existing three debug presets, differing only by `exclude_filter="steam_appid.txt"` (D-022) and an
`export/release/<platform>/` output path; the debug presets are byte-for-byte untouched.
`tools/steam/export_release.sh` runs all three through `agent godot --headless --export-release`.
`tools/steam/steam_build_config.sh` holds the four Steam identifiers (`STEAM_APP_ID`,
`STEAM_DEPOT_WINDOWS/MACOS/LINUX`, `STEAM_BRANCH`) as the single place to edit once real ones exist.
`tools/steam/templates/{app_build,depot_windows,depot_macos,depot_linux}.vdf.template` are steampipe
build scripts with `@TOKEN@` placeholders; `tools/steam/steam_upload.sh` renders them into
`tools/steam/generated/*.vdf` (gitignored) and runs `steamcmd +login <user> +run_app_build <vdf>
+quit`.

**Every value is still task 8.4's own placeholder** — `STEAM_APP_ID=480` (D-008), all three depot
IDs `0`, branch `"internal-beta"`. `steam_upload.sh` refuses to run for real while any of these are
still placeholders, naming which of 8.2 (App ID) or 8.11 (depot IDs, per-platform launch options)
supplies the real value. It also refuses `branch=default` (the public branch) unless
`STEAM_ALLOW_PUBLIC=1` is explicitly set — a public Steam publish is not something a wrong CLI arg
should be able to trigger silently. D-132 records the full 8.4/8.11 split and why the branch
password itself has no scriptable surface (Steamworks web dashboard only).

**Verified:** all three release presets export cleanly through `agent godot --headless
--export-release`; the macOS release binary boots headless (`--quit-after 15`) with `AUTHORED_WORLD`
reporting real content (props=2880, harvestable=1156) and 0 `ERROR:` lines. Confirmed empirically —
not just via `exclude_filter` — that `steam_appid.txt` was never packed into either the debug or the
release `.pck` in the first place (`all_resources` doesn't pick up a bare non-imported `.txt` at the
project root); the new `exclude_filter` is defense in depth, not the sole fix. `steam_upload.sh`'s
five guard clauses (placeholder App ID, placeholder depot IDs, `default` branch without override, no
username, `steamcmd` missing) each verified to fire correctly and in order; with a fake `steamcmd`
stub, real-looking IDs, a non-default branch and a username, the script renders all four templates
with correct substitutions and every template's relative `ContentRoot` path resolves to the right
`export/release/<platform>/` directory from `tools/steam/generated/`.

**Not this task, and why:** real App ID/depot IDs (8.1/8.2/8.11 — `.agent/state.json` still shows
both `todo`), macOS codesign/notarisation (8.10, needs an Apple Developer account nobody has yet),
setting a branch's password (Steamworks dashboard only). Full spec: `docs/SPECS.md`'s `## 8.4 ·`
block.

### 2026-08-19 — Task 7.6: Gamepad support — every core-gameplay action now has a joypad `InputMap` binding, `PlayerCamera` gained analog-stick look (the one gap that mattered), and `SettingsService`/`SettingsMenu` gained gamepad-button rebinding (lm)

**What shipped:** `project.godot`'s `[input]` section gained nine new actions and one missing
binding on an existing one — full list below — and `entities/player/player_camera.gd` gained the
piece that was actually missing: `apply_look_gamepad(delta: float, input_allowed: bool) -> void`,
polled every tick from `PlayerController._physics_process()`, turning yaw/pitch from a real
`Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")` read (right stick) scaled
by a new `@export var gamepad_look_sensitivity: float = 180.0` (degrees/SECOND — a held analog value,
unlike mouse look's one-shot per-pixel motion event). `apply_look()` (mouse) and
`apply_look_gamepad()` now share a `_rotate_view(yaw_delta, pitch_delta)` helper.

**InputMap actions, for anyone adding a new player verb — every action below now needs BOTH a
keyboard/mouse event and a gamepad event, or it silently loses gamepad players:**

| Action | Keyboard/mouse | Gamepad |
|---|---|---|
| `build` | B | D-pad up (was missing a gamepad event entirely — plain gap, not new) |
| `eat` | G | D-pad down (was `vitals_hud.gd`'s raw `EAT_KEY`) |
| `build_rotate` | R | D-pad right (was `player_controller.gd`'s raw `BUILD_ROTATE_KEY`) |
| `build_destroy` | Right-click | Left trigger, `JOY_AXIS_TRIGGER_LEFT` (was a raw right-click check) |
| `hotbar_prev` / `hotbar_next` | — (1-8 number keys stay direct-select) | LB / RB, `InventoryUI` wraps at both ends |
| `look_left` / `look_right` | — (mouse only) | Right stick X, `JOY_AXIS_RIGHT_X` |
| `look_up` / `look_down` | — (mouse only) | Right stick Y, `JOY_AXIS_RIGHT_Y` |

`eat`/`build_rotate`/`build_destroy` replace the raw-key/raw-mouse reads `vitals_hud.gd`/
`player_controller.gd` carried since the F-095-era "`project.godot` was held by another lane" excuse
— that excuse no longer applies to anything; a future raw-key handler should not cite it as
precedent. `eat`/`build_rotate` joined `SettingsService.REBINDABLE_ACTIONS` (keyboard rebind);
`build_destroy` did not, same mouse-primary reasoning `attack` already had (D-131).

**`SettingsService` new surface:** `gamepad_look_sensitivity()`/`set_gamepad_look_sensitivity(float)`
(clamped `[30, 720]`, same shape as `look_sensitivity`). `rebindable_actions_joypad()` ->
`JOYPAD_REBINDABLE_ACTIONS` (10 button-bound actions: `jump`, `sprint`, `interact`, `inventory`,
`build`, `dodge`, `eat`, `build_rotate`, `hotbar_prev`, `hotbar_next` — deliberately excludes every
axis/trigger-bound action, D-131). `keybind_label_joypad(action) -> String` (Xbox-layout label:
A/B/X/Y/LB/RB/L3/R3/BACK/GUIDE/START/D-PAD UP/DOWN/LEFT/RIGHT, via new `JOYPAD_BUTTON_LABELS`).
`rebind_action_joypad(action, InputEventJoypadButton) -> StringName` (`&""` on success, else the
conflicting action — same never-share-a-button contract `rebind_action()` has for keyboard).
`reset_keybinds()` now restores gamepad bindings too, not just keyboard. Persisted via a new
`joypad_binds` dict + `gamepad_look_sensitivity` scalar in `SettingsSave`'s schema (still schema
version 1 — `_migrate()`'s existing backfill loop covers an old save missing either key, no version
bump needed).

**`SettingsMenu`** gained a "GAMEPAD BINDS" section (one row + capture button per
`JOYPAD_REBINDABLE_ACTIONS` entry, `_gamepad_keybind_buttons` dict) below the existing KEYBINDS
section, a "Gamepad Look Sensitivity" slider in LOOK, and a second capture-state pair
(`_rebinding_joypad_action`/`_rebinding_joypad_button`) so a keyboard-row and a gamepad-row capture
can never be started at once — `_input()` now branches on `InputEventJoypadButton` (when a gamepad
capture is pending) before its existing `InputEventKey` branch, and Esc still cancels either kind.

**`InventoryUI`** gained `hotbar_prev`/`hotbar_next` handling in its existing `_input()` (LB/RB,
`wrapi()` wraparound at both ends) — the 1-8 number-row keys are untouched and still the only
keyboard path; there is no gamepad equivalent for the number keys, only the cycle.

**Explicitly not built:** gamepad UI FOCUS navigation for any menu (D-131, filed as F-209) — every
menu still needs a real mouse click (or Steam Input's own trackpad-as-cursor emulation on a real
Deck) to open or interact with. Full-stick/axis gamepad rebinding (swap which stick drives
look/movement) — D-131's other half.

**Verified:** `tools/gamepad_check.gd` (new) — every action above carries the exact joypad
event/axis it claims (a hand-edited `project.godot` `[input]` .ini is exactly where a typo'd
button/axis index hides silently); the gamepad look integration test rotates yaw/pitch through the
real `apply_look_gamepad()` and confirms it is suppressed while `input_allowed` is false; the full
build cycle (toggle/rotate/confirm/destroy) fires entirely through real
`InputEventJoypadButton`/`InputEventJoypadMotion` events fed into `PlayerController`'s real
`_unhandled_input()`, same "feed the real handler" shape `tools/build_check.gd` uses for
keyboard/mouse; hotbar cycle and `eat` likewise through `InventoryUI`/`VitalsHud`'s real `_input()`.
`failures=0`. `tools/settings_check.gd` extended (joypad rebind API, gamepad sensitivity clamping,
grown action counts), `failures=0`. No regressions: `verify_setup`/`build_check`/`combat_check`/
`ranged_combat_check`/`inventory_ui_check`/`net_robustness_check` all `failures=0`. `agent godot
--quit-after 20`: 0 `ERROR:` lines. Full writeup: `docs/SPECS.md` 7.6 block.

### 2026-08-19 — F-203 fixed (emitter case): `AuthoredWorld`'s chunk merge now includes emitter-bearing props too, split by `(chunk, emitter class)`; `EnvironmentVfx.EMITTER_META` is the seam that made it need no change to `_register_emitter` (lp)

**What shipped:** `AuthoredWorld._build_props()` gained a second merge bucket,
`emitter_mergeable` — keyed `"<chunk_x>_<chunk_z>|e<emitter_int>"` instead of the plain bucket's
`"<chunk_x>_<chunk_z>"` — for any non-harvestable, non-sway, sub-`DrawPolicy.SHADOW_MIN_HEIGHT`
prop whose `AssetVfxLibrary.emitter_for()` is not `NONE` and not `GLOW`. It folds into the plain
`mergeable` dictionary before the build loop runs, so **one loop bakes both buckets** — the key's
`"|e<N>"` suffix (parsed at the top of each iteration) is the only thing that branches behaviour: an
emitter-keyed holder additionally publishes `EnvironmentVfx.PLACEMENTS_META` (`&"placements"`,
local/centroid-relative — unchanged contract) and a new `EnvironmentVfx.EMITTER_META`
(`&"vfx_emitter"`, an `AssetVfxLibrary.Emitter` int) declaring its class directly.

**The seam other callers build against:** a merged, multi-asset holder that needs `EnvironmentVfx`
to do something per-instance (a light, a particle site — anything keyed off `PLACEMENTS_META`) but
has no single asset id to resolve a class from can declare `EMITTER_META` instead of relying on
`ASSET_META`. `EnvironmentVfx._apply_node()` checks a new `_merged_emitter_for()` ancestor walk
(same shape as the existing `_asset_id_for()`) BEFORE the asset-id path and routes straight to
`_register_emitter()` with the declared class — `_register_emitter()` itself needed **zero** changes;
it already reads `PLACEMENTS_META` off an ancestor and multiplies by `global_transform`, exactly what
a per-asset `MultiMesh` holder already exercises. **`GLOW`-class props were also newly folded into
the existing metadata-free `mergeable` bucket** (not the new one) — `AssetVfxLibrary.Emitter.GLOW`
is "emissive material only, no light, no particles, no per-instance node," so it needs neither
`PLACEMENTS_META` nor `EMITTER_META`; anything reaching for a similarly inert future emitter class
should check whether it too needs zero runtime bookkeeping before assuming it needs the new bucket.

**Not built: the sway case.** F-203's title named two mechanisms (per-vertex height encoding for
sway, per-asset placement metadata for emitters); only the emitter one shipped here. Spun out to
**F-208** with the exact remaining shader/vertex-channel work — `_apply_sway`'s per-mesh height mask
still cannot survive several placements' absolute heights being baked into one static mesh.

**Verified:** `agent godot --script tools/prop_chunk_merge_check.gd` (its independent eligibility
recompute updated to bucket by `(chunk, emitter class)` too, GLOW excepted) →
`eligible_props=263 eligible_chunks=28` matching 28 built holders, `PASS`. `tools/
environment_vfx_hollowmere_check.gd` (widened `_check_placement_space` to validate an
`EMITTER_META` holder's placements against every layout site sharing its class, since no asset id
survives to match per-asset) → `CRYSTAL sites=101` unchanged from pre-fix,
`MERGED_EMITTER_PLACEMENTS checked=2 stray=0`, `PASS`. `tools/hollowmere_check.gd`, `tools/
harvest_batch_check.gd`, `tools/harvest_world_check.gd`, `tools/resource_scatter_check.gd`, `tools/
mesh_merge_check.gd` all `PASS`, unaffected. `agent godot --windowed --script
tools/frame_cost_check.gd` against `agent baseline --windowed --script tools/frame_cost_check.gd`
(HEAD, pre-fix): draw calls 4,942 → 4,931, primitives 1,155,236 → 1,159,310 (+0.35% — nowhere near
the +16% shadow-cascade regression F-187/F-203's own history warns about; every merged holder still
passes the same sub-`SHADOW_MIN_HEIGHT` gate and still reads `cast_shadow ==
SHADOW_CASTING_SETTING_OFF`). Full writeup: `docs/SPECS.md` F-203 block.

### 2026-08-19 — F-205 fixed: `cmd_check` (the pre-commit hook) now refuses a commit that would register or carry an untracked autoload target — F-200's mechanism #2 (lp)

**What changed, for anyone touching `.agent/bin/agent`'s `cmd_check` or `tools/autoload_tracked_check.py`:**
a new `_autoload_tracked_missing(changed)` helper in `.agent/bin/agent` (just above `cmd_check`)
imports `tools/autoload_tracked_check` and calls its `sweep("")` whenever `changed` (the set
`cmd_check` is about to judge) includes `project.godot` or any `.gd` file. Anything `sweep` reports
missing is appended to `cmd_check`'s `errors` list — same list the claim/D-031 checks feed — so it
blocks the commit the same way a foreign claim does, independent of and in addition to the ownership
checks in the per-file loop.

**The trick that made this a same-file, zero-new-logic change:** `autoload_tracked_check.py`'s
`tracked_at`/`read_at` already build their git paths as `"%s:%s" % (rev, path)`. Pass `rev=""` and
that collapses to git's own `:path` syntax — the INDEX. For any tracked path the index already IS
"staged content if there is any, HEAD's otherwise", which is exactly the overlay a pre-commit hook
needs (there's no commit sha yet to name). So `--rev ""` reaches the right revision for free — no new
git-diffing code, and `autoload_tracked_check.py`'s checking code (`sweep`/`tracked_at`/`read_at`/the
two regexes) is untouched; only its docstring changed, to document the `--rev ""` form, and its
self-test gained one case (`catches_staged_precommit_f205_shape`) proving that form catches a target
that was never even `git add`ed.

**Fails open on its own breakage, on purpose:** an import or `sweep()` exception inside
`_autoload_tracked_missing` returns `[]` (no missing targets found) rather than blocking the commit —
this gate is pure upside over F-200's after-the-fact `--self-test`-verified check, never the only
thing standing between a bad commit and the tree, so a bug in the gate itself must never be the thing
that blocks an unrelated commit.

**Test harness gained a hook-simulation mode:** `tools/harness_check.py`'s `run()` took a new
`as_hook=True` kwarg — sets `GIT_INDEX_FILE` before invoking `.agent/bin/agent check`, which is what
flips `cmd_check`'s own `staged_only` branch to the STAGED/INDEX code path (F-001) instead of its
working-tree fallback. Every case before F-205 called `check` bare, so all of them exercise only the
fallback path; a future case that needs to test the real pre-commit-hook behavior (STAGED view, not
working tree) should pass `as_hook=True` rather than adding a second ad hoc env dance. `build_repo()`
also now seeds a real `project.godot` (one clean `[autoload]` entry pointing at the fixture's
`world/thing.gd`) and copies the real `tools/autoload_tracked_check.py` into the fixture's `tools/`
dir, so every existing case doubles as a no-false-positive proof for this gate for free.

**Verified:** `python3 tools/autoload_tracked_check.py --self-test` → 4/4. `python3
tools/harness_check.py` → 34/34 (3 new F-205 cases). `python3 tools/autoload_tracked_check.py` (real
repo, HEAD) → `autoloads=58 paths_checked=111 failures=0`. `.agent/bin/agent check` on the real
working tree → clean pass. `agent godot --script tools/findings_numbering_check.gd` → structure
intact after moving F-205 to `## Resolved`.

**What's NOT built:** nothing — F-200's finding named exactly two mechanisms and both now exist.

### 2026-08-19 — F-206 resolved: `build_gatherable_plants.py` (A-011) gets the bevel-free `box()` override, closing the D-124 exposure F-198 left latent and adding the byte-identical claim A-012 already carries (lm)

**The gap:** F-198 fixed three live D-124 violations (families whose tracker rows already claimed a
byte-identical rebuild while still calling `mire_art.box()`'s bevel-capable version) and, in the same
sweep, found a fourth site with the same six-call shape — `build_gatherable_plants.py` — that wasn't
live only because A-011's row made no byte-identical claim yet. That was filed as F-206 "for whoever
adds that claim to A-011 later" (`docs/DELEGATION.md`'s F-198 entry, and `docs/FINDINGS.md`).

**The fix:** added a local bevel-free `box()` override to `build_gatherable_plants.py`, identical in
shape to `build_ward_set.py`'s and every other family's (`assign()` the cube, no `BEVEL` modifier,
`bevel` kwarg accepted and ignored so all six call sites read unchanged). Rebuilt clean.

**Verified:** `python3 tools/blender/asset_repro_check.py --script tools/blender/build_gatherable_plants.py
--export-dir assets/gatherables/exports --catalog assets/gatherables/catalog.json --label A-011` gives
byte-identical GLBs and catalog across two clean separate-process rebuilds (10/10) — so this task also
added the byte-identical claim to A-011's `docs/ASSET_TRACKER.md` row, matching A-012's. `agent godot
--script tools/gatherables_check.gd` still passes clean, 41 assertions / 0 failures. Triangle total
drops from 5,472 to 5,184 (chamfers square off, D-124's accepted tradeoff); every catalog dimension is
unchanged at 3-decimal precision, so nothing downstream (placement, collision, the `poison_berry_bush`
near-copy pairing) needed a second look.

**Swept for siblings (AGENTS.md §3):** grepped every `tools/blender/build_*.py` for `bevel=` call
sites and cross-checked each hit for a local `def box` override. All six current callers
(`build_crafting_stations.py`, `build_enemy_crawler.py`, `build_gatherable_plants.py`,
`build_loot_set.py`, `build_tool_weapon_set.py`, `build_ward_set.py`) now have one — this was the last
gap of this exact shape in the repo.

### 2026-08-19 — F-191 resolved: `cmd_check` now names a different session's just-released, still-staged claim instead of the generic "edited without a claim" warning (lm)

**What changed, for anyone touching `.agent/bin/agent`'s `cmd_check`:** the `elif not c and not human
and not in_grace(f)` branch (around line 1524) no longer prints a flat "edited without a claim" for
every unclaimed file. It first checks `st["recent"][f]` — if a record exists, its `agent` differs from
the current committer, and it is younger than `RECENT_GRACE_HOURS` (6h), the warning instead names that
agent, cites F-191, and prints the pathspec commit form. `in_grace()` itself is unchanged and still only
recognizes the CLOSING session's own bare commit (`_is_mine` checked against the current committer) —
this is a second, independent check alongside it, not a rewrite of it. Both are warnings, never errors:
an unclaimed file is legitimately free to commit (F-072); this only changes what the warning says.

**The other half, for anyone writing a new "hand-commit these files afterward" instruction in
AGENTS.md:** every one of them now needs the pathspec form (`git commit -m "..." -- <files>`), not just
the `docs/` one F-199 already covers. The harness-source section (F-081/D-057, "claim `.agent/bin/agent`
before `done`") had exactly this gap until this task — it told you to claim the file and left the commit
step undocumented, which is what actually produced F-191's real incident. If a future task adds a third
category of file that `ship` deliberately won't stage (there are currently exactly two: `docs/` and
`.agent/bin/`), give its hand-commit instruction a pathspec example too, in the same task that adds it.

**Verify a change to either half against `python3 tools/harness_check.py`'s two F-191 cases** — a
different agent's release inside the grace window (must name it), and the same shape past the window
(must fall back to the generic warning) — so a future edit to `cmd_check` or `RECENT_GRACE_HOURS` gets
caught in either direction. Full writeup: `docs/SPECS.md` F-191 block.

### 2026-08-19 — F-204 resolved: `build_gatherable_plants.py`/`build_flora_set.py`'s previews no longer draw the layout they had at the first render, and D-128 names the pattern for the 8 more generators F-207 found with the same bug (lp)

**The seam the next multi-render preview builds on (D-128):** if a generator's preview section needs
an asset or a reference prop at more than one position across its renders, give each position its own
object, built before the FIRST `bpy.ops.render.render()` call, toggled only with `hide_render` after
that — never write `object.location`/`.rotation_euler` a second time for an object that has already
appeared in a render; it silently does nothing.

- `make_reference(tag, location)` (both files): a scale-reference cube per sheet, hidden by default,
  shown only for its own render. Copy this whenever a sheet needs a prop the others don't share.
- `hero_duplicate(record, location)` (`build_flora_set.py` only): a linked-mesh-data copy of an
  asset's single joined export mesh (`record["root"].children[0]`), placed via `dup.matrix_world =
  Matrix.Translation(delta) @ source.matrix_world` — for a composition that pulls specific assets
  together from grids spaced many metres apart, where camera reframing alone can't reach.
- Cheaper than either, when it applies: `build_gatherable_plants.py` reordered its `SPECS` list so
  three states that needed to read left-to-right in a close-up shot were already adjacent on the
  grid — the shot then only ever moves the camera, no duplicate object at all. Check this first.

**Verified:** both scripts rebuilt standalone (`Blender --background --python
tools/blender/build_X.py`) — `GATHERABLES_CHECK PASS`, `FLORA_CHECK PASS` — and
`tools/blender/asset_repro_check.py` confirms every exported GLB and both `catalog.json`
byte-identical across two fresh rebuilds (no geometry drift from the fix). Previously-broken tiles
(`berry_decision_preview.png`, `gatherable_deposits_preview.png`, `small_trees_preview.png`,
`ground_cover_preview.png`, `flora_set_preview.png`) visually confirmed correct after rebuild.

**Not fixed here:** the identical bug is live in `build_enemy_crawler.py`, `build_crafting_stations.py`,
`build_harvestable_resources.py`, `build_mire_map_kit.py`, `build_wellspring_set.py`,
`build_loot_set.py`, `build_ward_set.py`, and `build_tool_weapon_set.py` (twice) — filed as **F-207**
with the exact file/line list. Whoever picks it up should copy the two helpers above rather than
re-deriving them; `build_enemy_crawler.py`'s showcase duplicates an **armature**, not a plain mesh, so
its fix needs pose/bone data considered, not just `hero_duplicate()` as-is.

### 2026-08-19 — F-188 resolved: `MeshMerge` output now carries a shadow mesh, matching what every imported .glb already gets (lm)

`core/render/mesh_merge.gd` gained a private `_shadow_mesh(order, buckets) -> ArrayMesh`, built from
the same per-bucket vertex/index data `_build()` and `merge_instances()` already collect — one
surface per visible surface, same order, stripped to `ARRAY_VERTEX`/`ARRAY_INDEX` only (unwelded:
`ArrayMesh.create_shadow_mesh()`, which would additionally dedupe shared-position vertices, is not
exposed to scripting). Both public entry points (`merged()`/`collapse()` via `_build()`, and
`merge_instances()`) now assign it to `combined.shadow_mesh` before returning. `CACHE_VERSION` bumped
5 → 6 so `_build()`'s disk cache can't serve a pre-fix entry with no shadow mesh.

**The seam the next `MeshMerge` caller gets for free:** anything that reaches `merged()`,
`collapse()`, or `merge_instances()` now gets a shadow mesh automatically — no caller-side change
needed, and no new gap to remember when F-203 lifts `merge_instances()`'s current restriction to
sub-`DrawPolicy.SHADOW_MIN_HEIGHT` props (the only reason today's one caller, `AuthoredWorld.
_build_props()`'s `mergeable` path, never visibly needed this: `DrawPolicy.apply()` already turns
`cast_shadow` off for everything short enough to qualify).

**Verified:** `agent godot --script tools/mesh_merge_check.gd` — extended with `_check_shadow_mesh()`
(shadow_mesh non-null, surface count and per-surface index count match the visible mesh, no channel
beyond position/index), run against all 361 checked kit assets (1372 surfaces) plus a new synthetic
`merge_instances()` case. `MESH_MERGE_CHECK_GODOT PASS`. `prop_chunk_merge_check.gd` and
`hollowmere_check.gd` both still PASS post-bump. Full writeup: `docs/SPECS.md` F-188 block.

### 2026-08-19 — F-149 resolved: docs/ hand-commits stay attributable IF you pathspec them — no harness bug existed, the finding needed a regression test, not code (lp)

No `.agent/bin/agent` defect: `cmd_ship` already commits by pathspec (F-014, predates this finding),
so the only place the F-149 hazard can still occur is a **hand-typed** `docs/` commit — the one commit
`ship` deliberately leaves for you (F-006 exempts `docs/` from claims). `agent check` stays silent on
two lanes' unclaimed docs edits sitting staged together — there is no claim to have violated — so the
only thing between that state and a misattributed commit is whether you type `git commit -m "..." --
docs/FINDINGS.md docs/DECISIONS.md` (AGENTS.md's mandated form, closes it) or a bare `git commit`
(sweeps whatever else is staged, exactly like the original nettle12/e5f96b1 incident).

**Verify this class of fix, or write a new one, against `python3 tools/harness_check.py`'s three F-149
cases** — the silent-pass setup, the bare-commit repro, and the pathspec-commit fix, in that order, so
a future change to `agent check`'s `docs/` handling gets caught either direction (going quiet on a
shape it should flag, or starting to flag a shape F-006 means to leave alone).

### 2026-08-19 — Asset batch A-012: the food kit — and the art that unblocks `ITEMS.md`'s food and tonic rows (slate17)

**What shipped, verified:** 13 GLBs in `assets/food/exports/` (`tools/blender/build_food_set.py`,
`assets/source/food_set.blend`), a catalog, three contact sheets, and `tools/food_check.gd`.
Nine palette tokens appended to `mire_art.PALETTE` — append-only, so nothing downstream rebuilt.

**Names, so nobody re-derives them:** `cooked_meat` `raw_fish` `cooked_fish` `bog_loaf`
`meat_skewer` `hearty_stew` `healing_stew` `honey_jar` `fired_flask` `healing_draught`
`pale_draught` `stamina_tonic` `suspicious_sludge`. Two are deliberate: the food skewer is
**`meat_skewer`**, because `skewer` is already the weapon (`ITEMS.md` §4.4 flags the collision by
name), and the tracker's "water flask" ships as **`fired_flask`** because §9 cut thirst and made that
asset the container every tonic is made in.

**Three shared frames, and the catalog names them.** `catalog.json` carries a `frames` map:
`flask` (the five tonics), `bowl` (the two stews), `fish` (raw and cooked). Siblings measure
**identically** — same bounds, same triangle count, 0.0000 mm drift asserted in Blender AND
re-asserted in the engine — so gameplay can swap a raw fish for a cooked one, or an empty flask for a
full one, with no mesh jump and no second collision shape. Anything that adds a tonic should add a
colour to the existing flask, not a new bottle.

**What this unblocks.** `ITEMS.md` W1/W3's food and tonic rows were blocked on art because
`item_icons_check` requires every `ItemDef` to carry a real icon. These GLBs are what
`tools/blender/render_item_icons.py` renders icons from: append them to its `SOURCES`, re-render, and
compare **decoded pixels, not file hashes** (F-042). Task 3.2's remaining W1 slice and 3.8's food work
can then be authored. `content/loot/` already references none of these ids, so nothing breaks in the
meantime.

**Read F-204 before writing another generator's preview code.** A Blender contact sheet that moves
assets between renders draws the layout it had at the FIRST render — the objects probe as present,
visible and correctly placed, and a tile still comes out blank. A-012 places every asset once through
a `LAYOUT` table and only ever aims the camera. `build_gatherable_plants.py` and `build_flora_set.py`
still have the moving shape.


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
no sway, and its own mesh height stays under `DrawPolicy.SHADOW_MIN_HEIGHT`. **F-203 lifted the
emitter exclusion**: an emitter-bearing prop (other than `GLOW`) merges too, into its own
per-(chunk, emitter class) bucket rather than the plain per-chunk one — see that entry above for the
mechanism (`EnvironmentVfx.EMITTER_META`). Sway is still excluded; F-208 has what it would take.
Merged holders live under `PropVisuals` named `merged_<chunk>` (a plain bucket) or
`merged_<chunk>_e<N>` (an emitter-class bucket, `|` sanitized to `_` for the node name), each with
one `MeshInstance3D` child named `MergedProps`. A plain holder carries no `asset` meta (deliberate —
the node spans many assets, so `EnvironmentVfx._asset_id_for`'s meta-then-name walk correctly finds
nothing and skips it); an emitter-class holder carries no `asset` meta either, but DOES carry
`EMITTER_META` + `PLACEMENTS_META`. `AuthoredWorld.merged_prop_mesh_count` counts both kinds,
separate from `multimesh_count`.

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
WaveSpawner.current_cycle() -> int                       # readable on any peer (F-226) — host/solo's own cached int, or a client's WorldDeltaLog-replicated read; defaults 1 before any Cycle has advanced
WaveSpawner.cycle_count_multiplier(cycle: int = -1) -> float  # -1 sentinel reads current_cycle(); 1.0 + (cycle-1)*0.15, capped 2.5 at Cycle 11
```

**F-226 (2026-08-19, lm):** at ship, `current_cycle()` only ever read the local `_current_cycle`
cache `_on_cycle_advanced()` fills from `EventBus.cycle_advanced` — but `CycleService._announce()`
only fires that event host-side (`_owns_cycle()`), so a real client's cache never left `1` despite
the getter's own doc comment claiming "readable on any peer." Fixed to take the identical
host-int-or-`WorldDeltaLog`-fallback split `CycleService.current_cycle()` already uses, keyed on the
file's existing `_owns_wave_director()` guard. Any future HUD/debug consumer built on this getter
(the reason 5.9 added it) can now trust the doc comment on a real client, not just the host. Verified
by a real two-process check, `tools/wave_spawner_cycle_net_check.gd` — see docs/SPECS.md F-226.

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

**2026-08-19 — F-236: six more rows shipped** (`unlock_loping_gait`/`unlock_coin_worm`/
`unlock_bottomless_quiver`/`unlock_thin_step`/`unlock_night_pyre`/`unlock_cauter_seal`, all
`category = "powerup"`, gating an existing `PowerupDef` already live in a real loot table —
`docs/SPECS.md`'s F-236 block has the per-row table and reasoning). The tree is 7 rows, no longer
just the worked example. `tools/unlock_check.gd` gained `_check_authored_content()`, which validates
EVERY `content/unlocks/*.tres` file generically — schema-clean, no two rows share a `gates_id`, and
every `powerup`-row's `gates_id` resolves to a real `PowerupDef` that actually appears as a POWERUP
entry in an authored loot table. Run it after adding any new row; it catches a decorative gate
(one that sells but nothing rolls against) before it ships.

**Still true, unchanged by this task:** `is_content_unlocked()` has exactly one live consumer
(`LootTableDef.roll()`'s POWERUP gate). A row in any of the other seven §4.6 categories
(`attunement`/`poi`/`enemy`/`cycle_modifier`/`island_modifier`/`cosmetic`/`loadout`) will sell and
persist but gate nothing until that category gets its own consumer — D-111's 2026-08-19 addendum in
`docs/DECISIONS.md`.

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
- `CycleService.run_started` (signal, no args) — F-154 (2026-08-19, lp): fires exactly once per
  process, host/solo-only, the instant Cycle 1 is live. `CommandService._HOOK_EVENTS`' own row is the
  intended consumer (COMMANDS.md §5.2's `run_started` hook event); a run's lifetime is the whole
  process lifetime here (no session-close reset exists for `_current_cycle`), so "once per process"
  is this signal's actual, permanent contract, not a placeholder.
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

**F-230 (2026-08-19, lm):** `effective_scope()` originally judged each line by
`CommandService.scope_of(head)` — a dynamic-scope command's (`time`/`rule`/`function`/entity verbs)
*declared* maximum, always `&"host"`. A function line reading `time query` (LOCAL, D-086) was
misjudged HOST purely because `time set ...` (the same command, a different invocation) can mutate.
Fixed: `CommandService.line_invocation_scope(head: StringName, raw_args: PackedStringArray) ->
StringName` resolves the SAME per-line way top-level `execute()` does — through `_invocation_scope()`
against that line's own raw args — and is what `_function_scope()` now passes into
`effective_scope()`. `effective_scope()`'s `scope_of_command` callable contract changed accordingly:
it is called as `scope_of_command.call(head, raw_args)`, not `scope_of_command.call(head)` — any new
caller must pass a two-arg resolver, not `scope_of()`. Regression coverage:
`tools/function_check.gd`'s dynamic-scope section wraps `time query` (must stay LOCAL) and
`time set 0.5` (must still demand HOST) in functions and executes both as a non-op.

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
    &"run_started":   {"path": ^"/root/CycleService", "signal": &"run_started", "handler": &"_on_hook_signal_0"},
    &"night_started": {"path": ^"/root/DayNight", "signal": &"night_started", "handler": &"_on_hook_signal_0"},
    &"day_started":   {"path": ^"/root/DayNight", "signal": &"day_started",   "handler": &"_on_hook_signal_0"},
    &"player_downed": {"path": ^"/root/PlayerHealth", "signal": &"player_downed", "handler": &"_on_hook_signal_player_downed"},
    &"enemy_died":    {"path": ^"/root/EnemyWorld", "signal": &"enemy_died",  "handler": &"_on_hook_signal_enemy_died"},
}
```
Adding an event a future task ships a real signal for is one row here — F-154 (resolved,
`docs/SPECS.md`'s own block) filled the last two of the five COMMANDS.md §5.2 names illustratively:
`CycleService.run_started` (fires once per process, the instant Cycle 1 is live — host/solo-only,
same `_owns_cycle()` gate `night_started`/`day_started` use) and `PlayerHealth.player_downed` (the
real ALIVE→DOWNED edge — fired from all three sites `DownedState.apply_damage()` can return
`Transition.WENT_DOWN` from: `host_apply_damage`, `_tick_hunger`, `_tick_blight` — distinct from the
existing broadcast `downed_flag_changed` bool, which also fires `true->false` on revive). Naming an
event still genuinely absent from this table still fails loudly at wire time, not silently.
`CommandService.wire_hook(hook: Resource)` is public on purpose: a check (or a future in-game tool)
can wire a synthetic HookDef directly, no Registry/content round trip needed — `has_wired_hook(id)`
is the introspection half. `content/hooks/night_siege.tres` + `content/functions/night_siege.mcmd`
is the one worked example (dusk -> `wave start 10`), shipped **disabled** — D-094 is why.

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
- **`world_seed` has no default.** Written before task 4.6 shipped `GameState.run_seed` — that
  authority now exists and `Chest` derives its own seed from it (F-210) — but nothing in the shipped
  game instantiates a `ChunkStreamer` yet (next bullet), so whoever does still supplies `world_seed`
  explicitly; `GameState.run_seed`/`ensure_seed()` is the value to pass.
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

**Heads-up for 4.4/4.5's own per-point sampling (UPDATED by F-241, 2026-08-19):** `IslandHeightmap.
height()` still builds fresh `FastNoiseLite` instances per call for thread safety (D-075, now six
fields, not two — 4.13/4.14 added the warp/coast/ridge layers). That cost D-080 measured directly
before F-241: a LOD0 chunk's ~1225 apron samples raised `ChunkMesher.build_mesh()` from R2's
original placeholder-noise 0.330 ms/chunk to 1.924 ms/chunk single-threaded (3.895 ms/chunk
`WorkerThreadPool`-amortized) — the number that made per-sample cost visible in the first place.
**`chunk_mesher.gd` no longer pays it**: F-241 gave `IslandHeightmap` a `NoiseSet` (build once via
`make_noise_set(world_seed)`, sample many points via `height_from_set()`) and `_sample_heights()`
now uses it. Anything else sampling many points per seed — 4.4's scatter tables (F-252 names the
exact call site still on the old per-call path), 4.5's nav bake resolution, or a future biome-map
hot loop — should build one `NoiseSet` per seed/task and call `height_from_set()` rather than
assuming a bare per-call `height()`/`continent()` is free at density. See F-241's entry above this
one for the full API and the measured win.

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
  see the file header), **when the caller needs to recognize its OWN handle inside a `command_result`
  listener** (F-223): a LOCAL command, or a HOST command typed by the machine that owns execution,
  resolves and emits `command_result` SYNCHRONOUSLY — before a plain `submit()` call would even return
  the handle to arm a guard against. Use the two-step form instead: `var handle: int =
  command_service.call("reserve_handle")`, arm whatever `handle`-keyed state the listener checks, THEN
  `command_service.call("submit_with_handle", handle, line, ctx)` — `debug_console.gd`'s `_run()`/
  `_on_command_result()` is the worked example, and `tools/command_console_check.gd` is the regression
  guard proving the synchronous path actually reaches the listener now. Plain `command_service.call(
  "submit", line, ctx)` still works and still returns a handle — it's just not safe to arm a filter
  against after the fact; fine for a caller that only wants the eventual result and never filters by
  handle. A script that instead holds a **typed/preloaded** reference (`const S =
  preload("res://autoload/command_service.gd")`, then `node as S`) can `await s.execute(line, ctx)`
  directly — `tools/command_check.gd` is that worked example, and it's how every check should talk to
  it.

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

**Now covered too (F-112, 2026-08-19):** `world/gen/undergrowth.gd`'s "don't grow on top of a prop"
rule, the third system the original F-076 named. `Undergrowth.sample_ground_gaps() -> Array[float]`
stride-samples this run's `_placements` — the world-space transforms `_scatter()` already computed,
read directly rather than through `MultiMesh.get_instance_transform()` (D-127: that call answers
identity under `--headless` with no error, F-103) — and reports each one's height above the layout's
own heightfield. `_check_undergrowth()` in `world_contract_check.gd` flags it if more than 2% of
sampled plants sit more than 0.6 m above ground (a few legitimately stand on bridge decks/camp
floors; a genuine "grass on the boulders" bug reads as hundreds, not a handful — same tuning
`tools/hollowmere_check.gd::_check_undergrowth_stays_off_props` already proved, which now calls
`sample_ground_gaps()` too instead of its own now-removed, always-broken readback). No layout
Dictionary needed — `Undergrowth` reads its own ground truth internally, so this runs whether or not
`_layout_for()` found a `World.layout_path` on the map at all.

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
  `sample_ground_gaps() -> Array[float]` (F-112) exposes its ground-truth check the same way —
  see the F-076/F-112 section above for what reads it.
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
conventions consumed at the owning system, not schema; D-179 records why that beats fields, and §5
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

### 2026-08-19 — F-196 fixed: every asset-writer script now holds `agent godot`'s own lock for its whole export, `tools/blender/godot_import_lock.import_cache_guard`

**The bug:** a crafting-station GLB rebuild raced the audit battery's `agent godot` runs (each of
which forces an import pre-pass, F-093, under `.agent/locks/godot.lock`, F-044). The writer never
touched that lock, so a concurrent import pass read a GLB mid-write, stamped the shared `.godot/`
cache against the torn content, and every later pass — including the writer's own trailing checks —
kept reading "already imported" and skipped it. 16 ERROR lines per run for 40 minutes; self-healing
never triggered until a human ran `agent godot --import` by hand. Full account in `docs/FINDINGS.md`
(Resolved) and the decision made about the fix shape in `D-126`.

**The fix, and the API the next writer builds against:**

```python
sys.path.append(str(Path(__file__).resolve().parent))   # tools/blender scripts already do this
from godot_import_lock import import_cache_guard         # dependency-free, no bpy import

if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):         # label, for anyone waiting on the lock
        main()
```

`tools/blender/godot_import_lock.py` is new and carries no `bpy` dependency on purpose — it is
importable by a bare `python3` interpreter (`tools/import_cache_guard_check.py` does exactly that)
as well as from inside a Blender-embedded one. `import_cache_guard(label, force_import=True)`:
`fcntl.flock`s the exact file `.agent/bin/agent`'s own `file_lock("godot", ...)` uses
(`.agent/locks/godot.lock`), writes/clears the same holder-record JSON shape so a lane waiting on
`agent godot` sees "held by ... running <label>" rather than "holder unknown", and — on a clean
release — shells out to `agent godot --import` once to force a definitive import against the
now-finished files. Wrap the **whole** write (every `main()` call that touches `assets/`), not just
the final export line — a narrower wrap still leaves the mid-write window open to the exact race
F-196 found.

**Landed in all 19 existing writers:** the 16 `tools/blender/build_*.py` GLB exporters,
`tools/blender/render_item_icons.py` (PNG), `tools/audio/render_music.py` and
`tools/audio/render_sfx.py` (OGG/WAV) — every script that writes into an `assets/` path Godot
imports through `EditorFileSystem`. `tools/mapgen/hollow_layout.py`/`hollowmere_layout.py` write
JSON that Godot reads directly at runtime (never through the import pipeline), so they carry no
`.import` sidecar and were correctly left out — see D-126 for why.

**What the next writer builds against:** any NEW `build_*.py`, icon/audio renderer, or other script
that writes a `.glb`/`.png`/`.ogg`/`.wav`/anything-with-a-`.import`-sidecar under `assets/` must
import and wrap with `import_cache_guard` the same way — copy any of the 19 sites above. Nothing
enforces this at review time; `tools/import_cache_guard_check.py` proves the guard mechanism itself
works, not that a new script remembered to call it.

**Verified:** `python3 tools/import_cache_guard_check.py --godot` — 4/4, including the real interop
case (a genuine `agent godot --quit-after 5`, launched concurrently while a held guard is live in a
second process, blocks until release and only then runs clean — proof the two lock paths actually
resolve to the same file, not two that happen to look alike). `agent godot --quit-after 120` — clean
boot, `world_contract_check`-relevant assets (crafting stations included) load with 0 new ERROR
lines. All 19 edited writers pass `python3 -m py_compile`.

---

### 2026-08-19 — F-200 fixed: `tools/autoload_tracked_check.py` verifies every `project.godot` `[autoload]` target — and everything it transitively `preload()`s — is tracked in git at a given revision

**The bug it closes:** `agent autoload` appends the `project.godot` registration line while the
script itself is committed separately by whatever claim covers it — two acts that are not atomic.
F-190 hit this for `autoload/reward_service.gd`; F-144 hit the same shape one level deeper,
`autoload/graphics_quality.gd` (itself tracked) preloading an untracked `draw_policy.gd`. Both
self-resolved by luck, and nothing caught either at commit time. Full account in `docs/FINDINGS.md`
(Resolved) and `docs/SPECS.md`.

**The API the next check/hook builds against:**

```python
python3 tools/autoload_tracked_check.py               # checks HEAD
python3 tools/autoload_tracked_check.py --rev <sha>    # checks any revision
python3 tools/autoload_tracked_check.py --self-test    # proves it catches F-190's/F-144's shapes
```

No Godot dependency — pure `git` + stdlib, so it is cheap enough to run on every commit that touches
`project.godot` or a `.gd` autoload. Importable pieces for whoever builds F-205 (wiring this into
`agent check`'s STAGED/INDEX view rather than running it as a separate pass):

- `autoload_targets(rev)` — every `res://` path in `project.godot`'s `[autoload]` block at `rev`.
- `tracked_at(rev, respath)` — `True` iff `res://path` is a git blob tracked at `rev`
  (`git cat-file -e`, never a working-tree/`os.path.exists` check — the working tree is exactly what
  self-resolved both historical incidents while looking fine).
- `sweep(rev)` → `(missing, checked)` — BFS from every autoload target through every static
  `preload("res://...")` string literal reachable from a tracked `.gd`, reading each file's content
  at `rev` (`git show`), not off disk. `missing` is `[(path, autoload_root), ...]`.
- `AUTOLOAD_LINE` / `PRELOAD_CALL` — the two regexes; reuse rather than re-deriving them.

**Verified:** `python3 tools/autoload_tracked_check.py` → `autoloads=58 paths_checked=111
failures=0` at current HEAD. `python3 tools/autoload_tracked_check.py --self-test` → 3/3 passed,
against a throwaway git repo built and torn down per run — proves detection of both a bare untracked
autoload target (F-190's shape) and a tracked autoload preloading an untracked dependency (F-144's
shape), not just a clean pass. `agent godot --quit-after 120` → clean boot, 0 `ERROR:` lines.

**What is NOT built:** wiring this into `agent check` (the pre-commit hook) so the bad commit is
refused rather than caught after the fact — filed as **F-205**, since it means editing the shared
`.agent/bin/agent` harness under its own claim and `harness_check.py` verification loop, out of
scope for the read-only check this task built.

---

### 2026-08-19 — F-198 fixed: A-004/A-005/A-006 rebuilt bevel-free (D-124), and `tools/blender/asset_repro_check.py` generalizes F-057's single-family repro proof to any builder

**The bug it closes:** `build_tool_weapon_set.py`, `build_loot_set.py` and `build_enemy_crawler.py`
each shipped `DONE` claiming a byte-identical rebuild while still passing `bevel=` through to (or, for
the crawler, copying verbatim) `mire_art.box()`'s live BEVEL modifier — the exact float-byte-drift
exposure D-124 exists to prevent. Fixed each with a bevel-free local `box()` override (`build_ward_set.py`'s
shape), rebuilt, and reverified. Full account in `docs/FINDINGS.md` (Resolved) and `docs/SPECS.md`.

**The API the next art family builds against — no more per-family repro scripts:**

```bash
python3 tools/blender/asset_repro_check.py \
    --script tools/blender/build_<family>.py \
    --export-dir assets/<family>/exports \
    --catalog assets/<family>/catalog.json \
    --label <tracker-id>
```

Runs the builder as two separate Blender processes (never in-process — Blender doesn't purge orphan
datablocks on `object.delete()`, so a second in-process call collides with the first run's leftover
names) and diffs every `*.glb` plus `catalog.json` byte-for-byte. `crafting_stations_repro_check.py`
(F-057's original, `build_crafting_stations.py`-only) still exists and still works; new families
should use the generic one instead of copying it a fourth time.

**Verified:** all three families PASS — A-004 (22/22 GLBs + catalog), A-005 (10/10), A-006 (4/4),
each across two clean separate-process rebuilds. Each family's own engine check still passes clean
post-rebuild: `tools/item_icons_check.gd`, `tools/loot_content_check.gd`, `tools/enemy_crawler_check.gd`.
`docs/ASSET_TRACKER.md`'s A-004R/A-005/A-006 rows carry the new polygon counts and the verification
command.

**What is NOT fixed:** `build_gatherable_plants.py` (A-011) has the same six-site gap, but its
tracker row makes no byte-identical claim today so it isn't a live D-124 violation — filed as
**F-206** for whoever adds that claim to A-011 later.

---

### 2026-08-19 — F-228 fixed: `craft`/`build`/`demolish` console commands now charge/credit the ISSUING peer, never the host's own, when a non-host op runs them

**The bug it closes:** `_cmd_craft`/`_cmd_build`/`_cmd_demolish` all called
`request_craft()`/`request_place()`/`request_destroy()` — the local-actor-assuming entry points the
crafting UI / placement ghost / demolish tool use on their OWN process — from inside a HOST-scope
command handler, which always executes ON THE HOST regardless of who typed the line. So
`_local_peer_id()` inside the handler was always the host's own id, and a non-host op's
`craft`/`build`/`demolish` silently mutated the HOST's own inventory/build ledger, with the
confirmation never even reaching the real issuer. Full account in `docs/FINDINGS.md` (Resolved) and
`docs/SPECS.md`'s new F-228 block.

**The rule the next implicit-actor HOST-scope command must follow — D-140:** read the actor off
`ctx.peer_id`, never a local-actor entry point. `give`/`loadout`/`inv`/`loot` already did this
correctly and are the worked reference.

**Verified:** new `tools/command_craft_build_net_check.gd`, a real two-process ENet check — an op'd
non-host client runs `craft`/`build`/`demolish` over the actual console-command RPC path and every
inventory/ownership/refund effect is asserted to land on the CLIENT, never the host. 27/27 assertions
pass; reverting the fix locally reproduces 14/27 failures, confirming the check actually catches the
regression. Every existing crafting/build/command check (offline and net) stays green, full boot 0
stray `ERROR:`.

### 2026-08-19 — F-250 fixed: `WorldDeltaLog` grows a generic `delta_applied` signal, and `EventBus.cycle_advanced` finally reaches a real connected client (lp)

**New API for the next `WorldDeltaLog`-backed system that needs a real-time (not polled) cross-peer
change notification:** `WorldDeltaLog.delta_applied(chunk: Vector2i, kind: StringName, key: String,
value: Variant)` — a signal, fired from `_apply()` (the one place a value is actually stored,
whether locally on the host via `host_record()` or on a client via the `net_delta_applied` RPC
handler). It does NOT fire for a late joiner's `net_world_snapshot` catch-up (that replaces `_state`
wholesale, not through `_apply()`) — a joiner still reads its caught-up value directly through
`latest()`. Filter on `(chunk, kind, key)` yourself; the signal is generic across every `kind` this
log carries, same shape `EventBus`'s own per-event subscribe/unsubscribe pairs use, just node-signal
flavored since `WorldDeltaLog` is a real autoload rather than a static dispatcher.

**`CycleService` is the worked example consuming it:** `_on_world_delta_applied()` re-emits
`EventBus.emit_cycle_advanced(int(value))` on a client whenever the delta matches its own
`(GLOBAL_CHUNK, KIND, KEY)` address, guarded on `_owns_cycle()` so the host (which already emits
directly from `_announce()`, and whose own `host_record()` call also fires this same signal) never
double-emits. Full account in `docs/FINDINGS.md` F-250 (Resolved) and `docs/SPECS.md`'s F-250 block.

**Fixed one real, unfixed sibling in the same sweep is NOT this task's — filed as F-254:**
`CycleModifierService._announce()` has the identical `EVENT_BUS.emit_cycle_modifier_drawn()`-never-
reaches-a-client shape, but its `WorldDeltaLog` record never stores which Cycle a Modifier was drawn
on, so a `delta_applied`-based re-derivation needs a schema addition first — see F-254 for the two
fix options it names.

**Verified:** new `tools/cycle_advanced_net_check.gd` — a real two-process ENet check, host advances
the Cycle three times for real, client's own `EventBus.subscribe_cycle_advanced()` listener (never
polling) must actually fire with the right number each time. `CYCLE_ADVANCED_NET_CHECK failures=0`.
Regression: `cycle_check.gd`, `wave_director_check.gd`, `cycle_modifier_check.gd`,
`wave_spawner_cycle_net_check.gd` (one stale assertion updated — see SPECS.md Traps),
`steam_stats_check.gd`, `rich_presence_check.gd`, `wellspring_check.gd`, `mire_grid_check.gd` — all
green. Full boot (`agent godot --quit-after 120`) 0 stray `ERROR:`.

### 2026-08-19 — F-251 fixed: `tools/chunk_stream_check.gd`'s 5 pre-existing failures were all stale terrain-retuning fallout, not real bugs — now 0 (lp)

**`ChunkMesher.SKIRT_DEPTH_FRACTION` is now 1.70, not 0.10** — the constant anything sizing the LOD
skirt (or anyone re-measuring the seam margin) should read. A 12-seed island-wide sweep found the
worst LOD-boundary divergence is now 12.805 m (seed 4242, chunk `(3,-4)`) under the current terrain
(D-142's domain warp + ridged layer + carved river), not the 1.78 m F-128 originally sized against.
`SKIRT_DEPTH` (`= HEIGHT_SCALE * SKIRT_DEPTH_FRACTION`) is 44.2 m. Purely visual — `collision_faces()`
still slices it out before Jolt ever sees it (D-084) — and free at runtime, since skirt vertex/tri
COUNT doesn't scale with depth, only where the bottom ring sits in Y.

**`tools/chunk_stream_check.gd`'s reference constants (`WORST_KNOWN_SEED`/`WORST_KNOWN_CHUNK`/
`WORST_KNOWN_DIVERGENCE_M`) now point at that same seed-4242/chunk-(3,-4) spot-check**, and
`ISLAND_CHUNK_RADIUS` (the sweep/search bound) shrunk 17→10 chunks to match `IslandHeightmap.
ISLAND_RADIUS` (118 m, down from the 512 m these were sized against). The union-of-interest section's
`min_separation` is now `LOD0_RADIUS_CHUNKS + HYSTERESIS_CHUNKS + 1` (4 chunks), not
`LOAD_RADIUS_CHUNKS`-based (10 chunks, unreachable on the shrunk island — see D-150 for the full
reasoning anyone touching that section again should read first).

**None of this was a real gameplay bug** — full root-cause breakdown (why each of the 5 failures was
stale test math, not broken code) is in `docs/SPECS.md`'s F-251 block. `docs/FINDINGS.md` F-253 had
named this finding as its own hypothesis #1; ruled out there too (`check_determinism.gd` is clean,
terrain generator is not non-deterministic) — F-253 is a real, separate snapshot-delivery bug.

**Verified:** `agent godot --windowed --script tools/chunk_stream_check.gd` — 0 functional failures
(was 5). Regression: `check_determinism.gd` (`terrain_hash` unchanged from F-241's recorded value),
`terrain_check.gd` (0 failures), `bench_chunks.gd` (4.497 ms/chunk threaded, unchanged shape — skirt
depth doesn't affect vertex/tri counts).

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

### 2026-08-21 — Task 3.7 closed: the buildable set has a floor, and all six building checks are green (coil26)

3.6 shipped the mechanics (BuildService / BuildGhost / PlacementValidator) and 3.7 had already
authored twelve of its thirteen pieces plus both Ward structures. Auditing the set against the task's
own wording — "walls/floors/ramps/doors" — found exactly one hole: **there was no floor**, and no
floor art in the A-010 construction kit to make one from.

**What shipped**

| File | What it is |
| --- | --- |
| `tools/blender/build_construction_set.py` | `build_floor_wood()` plus its rows in `EXPECTED_NAMES`/`FAMILY`/`RUN_SPAN`/`DECK_PIECES`, and the piece staged into two of the four preview renders |
| `assets/construction/exports/floor_wood.glb` | 2.00 x 2.00 x 1.00 m, 420 tris, 6 materials — at the GROUND family's material cap, under its 1400-tri budget |
| `assets/icons/exports/icon_build_floor.png` | rendered by `render_item_icons.py`, forced upright with the other buildables (F-427) |
| `scenes/buildables/floor.tscn` | `StaticBody3D` on layer 1, art + a deck-only collider |
| `content/buildables/floor.tres` | `id = &"floor_wood"`, 6 logs, 35 hp, snaps to the metre grid |
| `tools/construction_check.gd` | `BUILDABLE_FRAME` gains `"floor" -> "floor_wood"`, so the `.tres` is held to the engine-measured module span rather than being the one piece exempt from it |

The design call — why a deck piece at `DECK_Z` rather than a ground slab — is **D-199**.

**Current state, verified this session at HEAD.** All six checks that touch building pass, and they
are the answer to "is it working in game", so re-run these rather than re-deriving:

```
agent godot --script tools/buildable_content_check.gd       # 14 defs, 14 with art, 0 failures
agent godot --script tools/construction_check.gd            # PASS, BUILDABLE_DEFS checked=9
agent godot --script tools/build_check.gd                   # 0 failures
agent godot --script tools/build_net_check.gd               # 0 failures — host-authoritative place/destroy
agent godot --script tools/command_craft_build_net_check.gd # 0 failures
agent godot --script tools/gamepad_check.gd                 # 0 failures — D-pad up enters build mode with a real ghost
agent godot --script tools/loop_audit_check.gd              # 0 failures — a piece is placed inside the real loop
```

`ui/building/build_bar.gd` builds its slots from `Registry.buildables` at boot with no cap, so the
fourteenth piece needed no HUD change and none was made.

**What 3.7 does not cover, so nobody looks for it here.** There is still no stone/iron tier of the
same pieces (`wall.tres`'s id is `wall_wood` in anticipation, but no stone variant is authored), and
no roof or half-height piece. Both are content, not mechanics — the module contract and the placement
path take either without change.

### 2026-08-21 — F-472: snapping is a toggle that mates pieces to each other (coil26)

Raised by Sequoyah while reviewing 3.7: *"they should be able to be placed anywhere but when
building pieces near each other I want there to be a snapping toggle so that it's easy to build
structures without little gaps and stuff."* The system had a fixed 1 m world grid, always on, and no
piece-to-piece mating at all — F-472 has the account, **D-202** has the design and the reasoning.

**The API the next task builds against.** One function turns an aim point into a transform, and it
is the only one either side should call:

```gdscript
PlacementValidator.resolve_placement(
    def: Resource, origin: Vector3, yaw_radians: float, snapping: bool,
    space: PhysicsDirectSpaceState3D = null, collision_mask: int = 1) -> Transform3D
```

`snap_transform()` still exists and is unchanged — it is now the *grid fallback* inside the above,
not something to call directly. `space` may be null (pure callers, harnesses): neighbour mating is
skipped and the grid answer comes back, exactly the old behaviour.

`resolve_placement` is **idempotent by construction**, and anything built on it must keep it that
way — `BuildService._process_place()` re-resolves every client request, so a non-idempotent rule
makes pieces jump on confirmation. D-202 explains the trap that already caught this once.

Other seams:

| Seam | Shape |
| --- | --- |
| `BuildService.request_place(piece_id, placement, snapping := true)` | the bool travels to the host |
| `net_request_place(piece_id, placement, snapping, request_id)` | `PROTOCOL_VERSION` **22 → 23**, manifest re-recorded |
| `BuildGhost.toggle_snapping() / is_snapping() / set_snapping(bool)` | client-local mode, ON by default |
| `BuildBar.set_snapping(bool) / is_snapping()` | display only, pushed by the player, never polled |
| InputMap `build_snap_toggle` | **V** on keyboard, **D-pad left** on gamepad |
| `PlacementValidator.SNAP_TOLERANCE_M` (0.75) / `SNAP_SEARCH_RADIUS_M` (4.0) | the two numbers worth tuning |

Neighbours are found through the **physics world**, not `BuildService._placed`, and that is
load-bearing: `_placed` is host-only, so a client ghost reading it would find nothing to mate to in a
real session and would behave like the host's single-player case. A piece's definition comes from the
`buildable_id` metadata `_net_spawn_piece()` already stamps on every peer.

**Verified headless at HEAD, ten checks, 0 failures each:**

```
agent godot --script tools/build_snap_check.gd   # NEW — free placement, the five mate faces, a
                                                 # turned neighbour, and idempotence over 400 seeded aims
agent godot --script tools/build_check.gd
agent godot --script tools/build_net_check.gd
agent godot --script tools/buildable_content_check.gd
agent godot --script tools/construction_check.gd
agent godot --script tools/command_craft_build_net_check.gd
agent godot --script tools/gamepad_check.gd      # the toggle through the real input path, ghost + bar
agent godot --script tools/rpc_manifest_check.gd
agent godot --script tools/handshake_check.gd    # was RED at HEAD on a stale version literal — F-473
agent godot --script tools/loop_audit_check.gd
```

**Known limits, so nobody looks for them here.** Mate points are whole faces plus the top — no
thirds, no corner posts, no staggered half-offsets; `_mate_points()` is where those go and D-202
records what that costs. Snapping does not yet mate to terrain features or to world-gen props, only
to placed pieces. And `SNAP_TOLERANCE_M` has had no playtest: 0.75 m against a 2.00 m module is a
reasoned starting value, not a tuned one.
