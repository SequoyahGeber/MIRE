class_name ResourceScatterField
extends Node3D

## Task 4.4 — client-local visuals + host-authoritative harvest proxies for a `ChunkStreamer`'s
## generated island (docs/ARCHITECTURE.md §4 pipeline).
##
## ## NETWORK AUTHORITY (ARCHITECTURE.md §2.2)
##
## - **WHERE something is placed: none** — same row as chunk streaming/terrain. `ResourceScatter`
##   (this file's pure half, `world/gen/resource_scatter.gd`) is deterministic from the shared
##   world seed, so every peer computes the identical field independently and nothing about
##   placement ever crosses the wire.
## - **WHETHER a placed harvestable is still standing: HOST**, inherited unchanged from
##   `Harvestable` (the world-mutation row) — this file never touches health or depletion itself.
##   It only creates or frees a holder node shaped exactly like `world/gen/authored_world.gd`'s
##   own harvestable holders (same group, same `asset`/`kit`/`batch_*` metas); the already-shipped
##   `autoload/harvest_world.gd` wiring turns that holder into a live, host-authoritative
##   `Harvestable` the instant it enters `authored_world_harvestable`. No harvest logic is
##   duplicated here.
##
## ## F-369: the PROXY boundary is the collision ring. The VISUAL boundary is not, any more.
##
## Reported from play: "theres barely any of the nature assets/plants placed around the map". The
## content was never the problem — `content/scatter/grassland_meadow.tres` asks for 3 m cells at 0.5
## coverage, which is continuous ground cover. The problem was that this file built scatter ONLY for
## chunks inside `chunk_has_collision()`, and that is `ChunkStreamer.LOD0_RADIUS_CHUNKS` = 2, or
## **64 metres**. Terrain streams to `LOAD_RADIUS_CHUNKS` = 8, or 256 m. So the player stood in a
## small dressed disc and looked out over a quarter kilometre of bare ground — exactly what the
## playtest capture shows.
##
## The paragraph below was right that proxies and visuals should not have two hand-tuned radii
## drifting apart. It was wrong to conclude they should share ONE radius: they are answering
## different questions. "Can I walk up and hit this?" is the collision ring and always was. "Can I
## see it?" is a draw-distance question, and this project already has an answer for it —
## `world/environment/draw_policy.gd`, which `world/gen/authored_world.gd` has applied to its own
## props since 4.3 and which this file never called at all.
##
## So: visuals build out to `SCATTER_VISUAL_MAX_LOD`, proxies stay on the collision ring, and every
## instance gets `DrawPolicy.apply()` so the per-prop cutoff is decided by the prop's own height and
## scaled by the graphics preset. Small flora culls at 80 m, mid at 150, trees at 260 — with the
## chunk build radius, not a bespoke constant, as the outer bound. A weak machine pulls all three in
## through `GraphicsQuality.draw_distance` without this file knowing anything about it.
##
## ## The proxy boundary IS the LOD0/collision ring, not a second radius
##
## A full `Harvestable` node per scattered tree does not survive at island scale — the spec's own
## words. 4.3 already draws exactly one "the player is near enough to stand on this" line:
## `chunk_has_collision(coord)`, true only for the nearest, full-detail ring (D-080). This file
## reuses that boundary rather than inventing a second bespoke radius/hysteresis pair that could
## drift out of step with it: scatter (visuals AND proxies together) builds only once a chunk
## crosses into that ring, and tears down the moment it leaves. `chunk_mesh_ready` can fire before
## the collider is actually cooked (collision cooks lazily) — this file polls
## `chunk_has_collision()` rather than assuming it on the same frame.
##
## ## Depletion memory: WorldDeltaLog first, peer-local best guess as the fallback
##
## Task 4.6 shipped `autoload/world_delta_log.gd`, the chunk-keyed mutation log
## `docs/ARCHITECTURE.md` §4 describes ("every mutation... replicates as deltas keyed by chunk").
## Every NODE/BATCH holder this file builds now wires its live `Harvestable`'s `depleted`/`respawned`
## signals (host-side only — see the file's own gate) into `WorldDeltaLog.host_record()`, keyed by
## the point's own chunk (parsed back out of `point_id`, never threaded as an extra parameter — see
## `world/gen/resource_scatter.gd`'s header on why `point_id` already encodes it). `is_point_depleted()`
## reads `WorldDeltaLog.latest()` first and only falls back to this file's OWN best-effort `_depleted`
## memory when the log has no opinion yet — a fresh peer between connecting and its
## `net_world_snapshot` RPC landing, or a harness that never registered `WorldDeltaLog` at all.
##
## The restore itself is `Harvestable.host_restore_depleted()`, never a direct poke at `active` —
## that is not a stylistic choice: `active` alone is only half of depletion's real state
## (`_deplete()` also arms the respawn clock), so a direct poke left the respawn clock at its
## just-constructed 0.0 and the very next physics tick auto-respawned the point straight back,
## caught by this task's own check when the bug first shipped (D-083). `host_restore_depleted()`
## reaches that same full state — but, unlike D-083's original fix of replaying a full
## `host_apply_damage()` hit, does it WITHOUT emitting `depleted`/`EVENT_BUS.emit_harvest_yielded()`.
## Replaying a real hit meant every rebuild of an already-harvested point paid the host a second,
## unearned copy of the item (F-231) — `host_apply_damage()` is the seam a swing that HASN'T happened
## yet uses to become one; a restore is remembering a swing that already fully happened and paid out
## once. `host_restore_depleted()` keeps the one property worth keeping from that seam — it still
## inherits the method family's own host/offline-only gate, so a real client's call quietly no-ops —
## without the yield side effect a memory replay never earned.
##
## `docs/FINDINGS.md` F-132 (resolved) named this exact gap and its fix: the host's `ChunkStreamer`
## must be anchored to the UNION of every connected peer's last-known position, not just its own
## local player, so a remote client's own harvestable proxy always has a host-side counterpart at the
## same NodePath to receive `Harvestable.request_hit()`'s `rpc_id(HOST_PEER_ID)`. That union-of-
## interest mechanism needed no change here or in `ChunkStreamer` — `set_anchors()` already takes an
## array, and this file already builds/tears down scatter per CHUNK, never per anchor, so any chunk
## resident because of a REMOTE peer's anchor gets a proxy exactly like one resident because of the
## host's own. `tools/chunk_stream_check.gd`'s union-of-interest section proves two independent,
## far-apart anchors each get a live, wired `Harvestable` from one streamer/field pair. What is still
## missing is a live caller that actually supplies that union — `docs/FINDINGS.md` F-139 tracks that
## nothing yet instantiates `ChunkStreamer`/`ResourceScatterField` in the shipped game at all; whichever
## task adds one must anchor the host's pair to every connected peer's position, not only its own.

const ResourceScatterLib := preload("res://world/gen/resource_scatter.gd")
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")
const DrawPolicy := preload("res://world/environment/draw_policy.gd")
## F-434: one collider fitter for both world builders — see `_collider_for()` below.
const PROP_COLLIDER := preload("res://world/gen/prop_collider.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

## Same group `world/gen/authored_world.gd` puts its own harvestable holders in — this is the
## contract `autoload/harvest_world.gd` already wires against, not a new one.
const HARVESTABLE_HOLDER_GROUP: StringName = &"authored_world_harvestable"
const COLLISION_POLL_INTERVAL_SEC: float = 0.1
## Bounds the deferred retry loop that waits for `HarvestWorld` to wire a freshly built holder
## before this file reapplies persisted depletion state to it — self-terminating, not a real
## timeout: in every context that wires a `ResourceScatterField` at all, `HarvestWorld` is already
## running and wires a holder within one or two deferred calls of it entering the tree.
const WIRE_WAIT_ATTEMPTS: int = 30
## `WorldDeltaLog`'s `kind` for this file's one mutation family — always recorded with a `bool`
## value (depleted or not).
const DEPLETION_KIND: StringName = &"harvest_depleted"
## Above this height (metres, in the prop's own unscaled space) geometry is scenery, not an
## obstacle — a branch you walk under is not a wall. Cuts the SOLID surfaces only; foliage is
## already gone by then (see `FOLIAGE_MATERIAL_PREFIXES`). Together the two rules give a tree its
## trunk and root flare, while a boulder, a stump or a fallen log — solid all over, and widest down
## low anyway — keeps its true full width (F-348).
const COLLIDER_OBSTACLE_HEIGHT_M: float = PROP_COLLIDER.COLLIDER_OBSTACLE_HEIGHT_M
## F-390: the trunk band. Solid geometry is measured from here up to
## [constant COLLIDER_OBSTACLE_HEIGHT_M], NOT from the ground up, because the widest solid wood on a
## tree below head height is the ROOT FLARE at its very base — and taking the max over the whole
## sub-1.8 m column meant the flare, not the trunk, set the radius. Measured on the shipped willows:
## `tree_willow_a` came out at 1.29 m against a trunk nearer 0.3, so the player was stopped over a
## metre from bark they were walking at. Reported as "the collision box doesnt let you get close to
## the tree".
##
## 0.5 m is chosen as clearly above a root flare and clearly below the waist. Everything under it
## stays walk-through, which is the right trade: brushing an ankle through a root is invisible, being
## held a metre off a tree is not.
## F-369: the outermost `ChunkStreamer` LOD whose chunks still get dressed with scatter VISUALS.
##
## 1, i.e. `ChunkStreamer.LOD1_RADIUS_CHUNKS` = 5 chunks = **160 m**, against the 64 m the collision
## ring gave. Not the full `LOAD_RADIUS_CHUNKS` (8 / 256 m): the outer tier exists to put a silhouette
## on the horizon, its meshes are already the coarsest, and building three times the scatter to dress
## ground the player reads as distance is the wrong trade for the machines this game targets. The
## per-prop cutoff inside that band is `DrawPolicy`'s to make, not this constant's.
const SCATTER_VISUAL_MAX_LOD: int = 1

## How many VISUAL-band chunks may be dressed per frame.
##
## F-369: extending the visual radius from 64 m to 160 m is 2.4x the scatter, and building a chunk's
## worth of it is synchronous. Unbudgeted, that work competes with chunk streaming itself and the
## world settles visibly slower — measured on `world_contract_check`, whose settled chunk count fell
## 289 -> 121 and whose wired harvestables fell with it, purely because fewer chunks finished loading
## inside the same frame window. Nothing was broken; the frames were just spent elsewhere.
##
## So the visual band takes a queue and this is its per-frame allowance. Chunks inside the COLLISION
## ring skip the queue entirely — they are underfoot, they carry the harvest proxies, and making the
## player wait for them to appear is the one case where the budget would cost more than it saves.
const SCATTER_VISUAL_BUILDS_PER_FRAME: int = 2

## F-454. The collision ring used to have NO per-frame cap at all: the poll loop below walked every
## coord in `_pending_lod0` and fully dressed each one whose collider had cooked, in a single frame.
## That is fine standing still, where chunks become collision-ready one at a time. Under motion it
## is the traversal hitch — `tools/traversal_profile.gd`, walking at 7 m/s on an M5 Pro:
##
##     5,254 frames over 45 s | median 7.23 ms | worst 217.25 ms
##     frames >= 25 ms: 126 — 2.4% of the frames, 15.4% of the wall clock
##     nodes added: 215 per hitch frame vs 0 per quiet frame
##
## Perfectly bimodal: the slow frames are exactly the frames that add nodes, and the worst of them
## added 1,488. The streamer's own reported cost accounted for only 20% of that time — it was
## inside its budget while this file spent the frame.
##
## The exemption above was right about ONE chunk and wrong about the ring. Making the player wait
## for the ground under their feet to be dressed would indeed cost more than it saves; making them
## wait a frame or two for a chunk five metres to the left does not, and a 217 ms stall is not a
## trade anyone chose. So the poll is now budgeted nearest-first: the chunk the anchor is standing
## in is still built the instant its collider exists, and everything else queues behind this
## allowance.
##
## 1, not 2 like the visual band: a collision-ring chunk carries harvest proxies and colliders as
## well as visuals, so one of these is several times the work of one of those.
const SCATTER_LOD0_BUILDS_PER_FRAME: int = 1

## F-454, second pass. Budgeting by CHUNK turned out to be budgeting the wrong unit. A chunk is not
## a quantum of work: `_build_chunk()` groups its placements by asset and dresses every group
## synchronously, and one chunk is 200-500 nodes. So "2 visual chunks per frame" was a licence to
## add 542 nodes in one frame, and re-profiling after the LOD0 cap showed exactly that — the worst
## frame fell 217 ms -> 142 ms and the hitch RATE did not move at all (15.4% -> 16.0% of the wall
## clock), because the frames were never bounded by chunk count in the first place.
##
## The budget unit is now milliseconds, and the work item is the ASSET GROUP — the natural seam
## `_build_chunk()` already had. A chunk's groups queue up and drain across as many frames as they
## need; the chunk the anchor stands in still builds whole, immediately, because that is the one
## case where waiting is worse than the stall.
##
## 2.0 ms out of the 16.667 ms frame, sitting alongside `ChunkStreamer.FRAME_BUDGET_MS`'s 4 ms
## (D-074). The deadline is checked BETWEEN groups, so a single pathological group can still
## overrun it — the cap on that is the size of one asset group, not this number.
const SCATTER_BUILD_BUDGET_MS: float = 2.0

## F-407: how many GLB warm-up requests may be in flight, and how many completed ones may be turned
## into cached mesh parts, per frame.
##
## `_load_mesh_parts()` calls `load()` on the MAIN THREAD the first time each asset is seen, and
## caches it afterwards. That was survivable when the island referenced 57 assets across 9 scatter
## tables. F-401/F-395 took it to 31 tables and ~100 assets, and the first-touch cost stopped being
## amortised into the noise: `chunk_stream_check` measured the **worst frame at 1009 ms**, against
## 29 ms before, while its own streaming attribution stayed at 3.5 ms — because the cost is not
## streaming, it is a synchronous disk read and scene import landing inside a gameplay frame.
##
## So the loads are moved off the main thread and started up front.
## `ResourceLoader.load_threaded_request()` does the disk and import work on a worker; by the time a
## chunk actually needs the asset, `load()` returns from the resource cache. Four in flight keeps the
## worker busy without thrashing, and turning at most two COMPLETED loads into mesh parts per frame
## bounds the one piece that genuinely has to be on the main thread — `instantiate()`.
const WARM_REQUESTS_IN_FLIGHT: int = 4
const WARM_COMPLETIONS_PER_FRAME: int = 2

const COLLIDER_TRUNK_BAND_MIN_M: float = PROP_COLLIDER.COLLIDER_TRUNK_BAND_MIN_M
## F-390: nothing shorter than this gets a collider at all. You step over it, so a cylinder there can
## only ever be something to trip on.
const COLLIDER_MIN_HEIGHT_M: float = PROP_COLLIDER.COLLIDER_MIN_HEIGHT_M
## Material-name prefixes that mark a surface as leaves, fronds, grass, moss or blossom — the parts
## of a prop a player walks straight through.
##
## `tools/blender/mire_art.py` names every material `"MIRE_" + CamelCase(palette_token)`
## (docs/SPECS.md, F-092), and its palette groups these tokens under one `-- foliage` heading, so
## these prefixes are the foliage family as the art pipeline itself defines it rather than a list
## guessed from the assets that happen to exist today. A willow carries its trunk on `MIRE_WoodBark`
## and its crown on `MIRE_Leaf`/`MIRE_LeafDeep`/`MIRE_LeafLight`: four surfaces of one mesh, which is
## what makes "collide the trunk, not the leaves" answerable at all without hand-authored shapes.
const FOLIAGE_MATERIAL_PREFIXES: PackedStringArray = PROP_COLLIDER.FOLIAGE_MATERIAL_PREFIXES

@export var world_seed: int = 0
## Keep the run's arrival point readable and traversable. The procedural world assigns this after
## choosing its deterministic spawn and before streaming begins, so every peer rejects the same
## placements without adding network state.
var spawn_clear_center: Vector3 = Vector3.ZERO
var spawn_clear_radius_m: float = 10.0
## `Registry.scatter_tables.values()`, assigned by whoever builds this field.
var scatter_defs: Array = []
## `Registry.biomes.values()`, same convention `BiomeMap.biome_at()` callers already follow.
var biome_defs: Array = []

var _streamer: Node = null
var _chunk_holders: Dictionary[Vector2i, Node3D] = {}
var _pending_lod0: Dictionary[Vector2i, bool] = {}
## point_id -> was depleted (not `active`) the last time this peer saw it. See the header.
var _depleted: Dictionary[String, bool] = {}
var _mesh_cache: Dictionary[String, Array] = {}
## "kit|asset" -> the cylinder `_build_node_holder()` gives every instance of that asset. Computed
## once per asset, not once per prop: `_collider_for()` walks every vertex of the mesh, which is
## affordable for the handful of NODE assets a biome scatters and is not affordable a few hundred
## times per chunk.
var _collider_cache: Dictionary[String, Dictionary] = {}
var _poll_accum: float = 0.0
## F-454. Asset groups waiting to be dressed, oldest first: `{coord, kit, asset, placements,
## with_proxies}`. Drained against [constant SCATTER_BUILD_BUDGET_MS] every frame. A chunk's holder
## exists as soon as the chunk is built; only its contents arrive over the following frames.
var _group_queue: Array[Dictionary] = []
## F-369: coord -> whether the chunk was built WITH harvest proxies. A chunk can be built twice over
## its life — visual-only when it reaches LOD1, then rebuilt with proxies when collision cooks — and
## this is what keeps those transitions from stacking or from silently skipping the upgrade.
var _chunk_has_proxies: Dictionary[Vector2i, bool] = {}
## F-369: visual-band chunks awaiting their turn under SCATTER_VISUAL_BUILDS_PER_FRAME. Insertion
## order is streaming order, which is near-to-far, so draining it in order dresses inward-out.
var _visual_queue: Array[Vector2i] = []
## F-461. coord -> that chunk's placements grouped "kit|asset" -> Array, as its `PlacementJob`
## computed them. Kept for as long as the chunk is resident (freed in `_teardown_chunk()`) so a
## proxy-boundary transition can re-dress one asset group without recomputing the whole chunk's
## placement pass — the very cost this finding exists to get off the main thread.
var _chunk_placements: Dictionary[Vector2i, Dictionary] = {}
## F-461. coord -> the in-flight worker task computing that chunk's placements.
var _placement_jobs: Dictionary[Vector2i, PlacementJob] = {}
## F-407 warm-up state. `_warm_pending` is [kit, asset] not yet requested; `_warm_active` is
## [kit, asset, path] currently loading on a worker thread. Both drain to empty and stay there.
var _warm_pending: Array = []
var _warm_active: Array = []
var _warm_queued: bool = false


## F-461. One chunk's placement pass, on a `WorkerThreadPool` thread.
##
## `ResourceScatter.placements_for_chunk()` is a pure static function — the file's own header opens
## by saying so — but it was being called on the MAIN thread, from inside `_build_chunk()`, which is
## reached synchronously from `ChunkStreamer`'s `chunk_mesh_ready` emit. `tools/traversal_profile.gd`
## caught the consequence: the streamer reported 31-56 ms frames against its own 4 ms budget while
## uploading as little as ONE chunk, and the time was not the streamer's at all. Per chunk:
##
##     placements_for_chunk (11, 8) = 10.62 ms (111 placements)
##     placements_for_chunk (13, 8) = 10.29 ms (4 placements)
##
## Ten milliseconds to decide the position of four bushes, because the cost is not the placements
## that survive — it is the ~3,750 candidates a chunk offers (31 scatter tables x 121 cells) and the
## biome/surface noise each surviving one samples. It does not shrink with the answer, so no budget
## downstream of it can help: `SCATTER_BUILD_BUDGET_MS` was metering the cheap half.
##
## It is also exactly the shape `ChunkStreamer.ChunkJob` already moved off-thread for mesh building,
## for the same reason, so this is that pattern applied to the other pure pass in the pipeline.
## Self-contained on purpose — `run()` touches only its own fields, never the field node.
class PlacementJob extends RefCounted:
	var coord: Vector2i
	var world_seed: int = 0
	## Read-only content shared across every in-flight job, on the same reasoning
	## `ChunkStreamer.ChunkJob` documents for its own `biome_defs`: nothing sampling these mutates
	## them (`placements_for_chunk()` duplicates before sorting, `make_terrain_table()` before its own).
	var scatter_defs: Array = []
	var biome_defs: Array = []
	var spawn_clear_center: Vector3 = Vector3.ZERO
	var spawn_clear_radius_m: float = 0.0
	var task_id: int = -1
	var finished: bool = false
	## Set when the main thread has already dressed this chunk synchronously while the job ran.
	## A running WorkerThreadPool task cannot be cancelled, so the result is discarded on landing —
	## the same supersede-rather-than-cancel shape `ChunkStreamer.ChunkJob` uses.
	var superseded: bool = false
	## "kit|asset" -> Array of placements. Grouped on the worker too: it is pure string work, and
	## doing it here keeps the main-thread half of a chunk down to appending queue entries.
	var grouped: Dictionary = {}

	func run() -> void:
		grouped = PlacementJob.group(ResourceScatterLib.placements_for_chunk(
			coord.x, coord.y, world_seed, scatter_defs, biome_defs),
			spawn_clear_center, spawn_clear_radius_m)

	## Shared with `_build_chunk()`'s synchronous path so both produce the identical grouping.
	static func group(
		placements: Array, clear_center: Vector3 = Vector3.ZERO, clear_radius_m: float = 0.0
	) -> Dictionary:
		var by_asset: Dictionary = {}
		for placement: Dictionary in placements:
			var position: Vector3 = placement["position"]
			if clear_radius_m > 0.0 and Vector2(position.x - clear_center.x,
				position.z - clear_center.z).length_squared() < clear_radius_m * clear_radius_m:
				continue
			var key := "%s|%s" % [String(placement["kit"]), String(placement["asset"])]
			(by_asset.get_or_add(key, [] as Array) as Array).append(placement)
		return by_asset


## Connects to a running `ChunkStreamer` — a plain `Node3D`, per its own DELEGATION note, so this
## takes the general `Node` type and reaches its signals dynamically rather than depending on the
## class statically.
##
## **Call this before the streamer is given anchors to stream around, not after.** This file only
## reacts to `chunk_mesh_ready`/`chunk_unloaded` as they FIRE — it never scans chunks already
## resident on `streamer` at attach time — so attaching once `set_anchors()` has already settled a
## ring leaves every one of those chunks without scatter until something forces them to reload.
## `tools/chunk_stream_check.gd`'s union-of-interest section (F-132) hit exactly this ordering trap
## while proving the multi-anchor case, which is why it's called out here rather than left to be
## rediscovered.
func attach_to_streamer(streamer: Node) -> void:
	_streamer = streamer
	streamer.chunk_mesh_ready.connect(_on_chunk_mesh_ready)
	streamer.chunk_unloaded.connect(_on_chunk_unloaded)


## F-258's sweep. `_depleted` is peer-local memory that SHADOWS `WorldDeltaLog` — `is_point_depleted()`
## above falls back to it whenever the log has no answer. A restart now draws a fresh world seed
## (D-161) and `WorldDeltaLog.host_reseed()` wipes the log, so from that instant every lookup takes
## the fallback branch — and a `point_id` encodes (chunk, grid cell, def), none of which is
## seed-derived, so the SAME id exists on the new island describing a different tree. Left alone,
## the second run would boot with a scatter of already-harvested stumps inherited from the first.
##
## Today `ProceduralWorld.rebuild_for_seed()` frees this whole node and builds a new one, so the
## dictionary would go with it anyway. That is a fact about the current caller, not a property of
## this file: anything that reuses a field across runs (an in-place rebuild, a second composer)
## silently gets the bug back. Subscribing here makes the invariant belong to the file that owns the
## dictionary, and costs one signal. Unconditional on authority, like every other `run_restarted`
## handler in this codebase — `_depleted` is this peer's own memory, so every peer clears its own.
func clear_depletion_memory() -> void:
	_depleted.clear()


func _ready() -> void:
	EVENT_BUS.subscribe_run_restarted(clear_depletion_memory)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(clear_depletion_memory)
	# F-461: a WorkerThreadPool task must be waited on to release its slot even when it has already
	# finished — the same rule `ChunkStreamer._exit_tree()` follows, and for the same reason (F-005:
	# an unreleased task id is a leak, not a no-op).
	for coord: Vector2i in _placement_jobs:
		var job: PlacementJob = _placement_jobs[coord]
		if not job.finished:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
	_placement_jobs.clear()


func chunk_count() -> int:
	return _chunk_holders.size()


func pending_count() -> int:
	return _pending_lod0.size()


## F-369: how many built chunks carry harvest proxies, as opposed to visuals alone. `chunk_count()`
## no longer answers "can I hit anything here" now that the two boundaries differ, and a check that
## conflates them is a check that cannot see the difference this separation exists to make.
func proxy_chunk_count() -> int:
	var total: int = 0
	for coord: Vector2i in _chunk_has_proxies:
		if _chunk_has_proxies[coord]:
			total += 1
	return total


## `WorldDeltaLog` is the shared, cross-peer answer when it has one; this file's own peer-local
## `_depleted` memory is only the fallback for the window before a fresh peer's snapshot lands (or a
## harness that never registered `WorldDeltaLog` at all — see the header).
func is_point_depleted(point_id: String) -> bool:
	var log: Node = _delta_log()
	if log != null:
		var recorded: Variant = log.call("latest", _chunk_from_point_id(point_id), DEPLETION_KIND, point_id)
		if recorded != null:
			return bool(recorded)
	return _depleted.get(point_id, false)


func _process(delta: float) -> void:
	if _streamer == null:
		return
	_pump_asset_warm()
	_drain_placement_jobs()
	_drain_group_queue()
	_drain_visual_queue()
	if _pending_lod0.is_empty():
		return
	_poll_accum += delta
	if _poll_accum < COLLISION_POLL_INTERVAL_SEC:
		return
	_poll_accum = 0.0
	_drain_lod0_pending()


## Dresses the collision-ring chunks whose colliders have cooked, nearest to the anchor first, up
## to [constant SCATTER_LOD0_BUILDS_PER_FRAME] per poll — plus the chunk the anchor is standing in,
## which is exempt from the allowance and always built the moment it is ready. See that constant
## for the measurement this budget exists to fix (F-454).
func _drain_lod0_pending() -> void:
	var ready: Array[Vector2i] = []
	for coord: Vector2i in _pending_lod0.keys():
		if bool(_streamer.chunk_has_collision(coord)):
			ready.append(coord)
	if ready.is_empty():
		return

	# Nearest-first, in chunk-grid space, against whichever anchor is closest. A Chebyshev distance
	# rather than Euclidean, to match how `ChunkStreamer` itself defines its rings.
	var anchor_chunks: Array[Vector2i] = _anchor_chunks()
	ready.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _chunk_distance(a, anchor_chunks) < _chunk_distance(b, anchor_chunks))

	var built: int = 0
	for coord: Vector2i in ready:
		var underfoot: bool = _chunk_distance(coord, anchor_chunks) == 0
		if not underfoot and built >= SCATTER_LOD0_BUILDS_PER_FRAME:
			break
		_pending_lod0.erase(coord)
		# F-461: the chunk may already carry visual-only scatter from its LOD1 pass. It used to be
		# torn down and rebuilt whole here, which is what made an already-dressed chunk 64 m ahead
		# of the player go bare and refill over the following second. Upgrade it in place instead:
		# only its harvest groups differ between the two builds.
		if _chunk_holders.has(coord):
			_retarget_chunk(coord, true)
		else:
			# Underfoot builds whole and now; everything else queues its groups (F-454).
			_build_chunk(coord, true, underfoot)
		if not underfoot:
			built += 1


## The chunk coordinates the world is streaming around. Empty when the streamer has no anchors yet,
## in which case `_chunk_distance()` answers a constant and the sort degenerates to arbitrary order
## — which is correct: with nothing to be near, no pending chunk is nearer than another.
func _anchor_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if _streamer == null or not _streamer.has_method(&"anchors"):
		return result
	for anchor: Vector3 in _streamer.call(&"anchors") as Array:
		result.append(_streamer.call(&"chunk_of", anchor) as Vector2i)
	return result


## True when [param coord] is the chunk an anchor is standing in — the one case where a partly
## dressed chunk is worse than a stalled frame, so it skips every budget.
func _is_underfoot(coord: Vector2i) -> bool:
	return _chunk_distance(coord, _anchor_chunks()) == 0


## Chebyshev distance in chunks to the nearest anchor; a large constant when there are no anchors.
func _chunk_distance(coord: Vector2i, anchor_chunks: Array[Vector2i]) -> int:
	var best: int = 1 << 30
	for anchor_chunk: Vector2i in anchor_chunks:
		best = mini(best, maxi(
			absi(coord.x - anchor_chunk.x), absi(coord.y - anchor_chunk.y)))
	return best


func _on_chunk_mesh_ready(coord: Vector2i, lod: int) -> void:
	if lod > SCATTER_VISUAL_MAX_LOD:
		# Too far out to dress at all — tear down whatever scatter exists, but keep the depletion
		# memory `_teardown_chunk` records.
		_pending_lod0.erase(coord)
		_visual_queue.erase(coord)
		_teardown_chunk(coord)
		return

	if lod == 0:
		if _chunk_has_proxies.get(coord, false):
			return
		# Underfoot: skip the visual queue's budget. See SCATTER_VISUAL_BUILDS_PER_FRAME.
		_visual_queue.erase(coord)
		# Collision usually cooks before this fires on a chunk that has been resident a while. Take
		# that path when it is available: building visual-only first and rebuilding a moment later
		# would dress this chunk TWICE for no visible difference.
		if bool(_streamer.chunk_has_collision(coord)):
			_pending_lod0.erase(coord)
			if _chunk_holders.has(coord):
				_retarget_chunk(coord, true)      # F-461, as in `_drain_lod0_pending()`
				return
			# Immediate only for the chunk actually underfoot. This fires for every chunk
			# entering the collision ring, and under motion that is several per second —
			# dressing each one whole, in the frame it arrives, is most of F-454's hitch.
			_build_chunk(coord, true, _is_underfoot(coord))
			return
		# Otherwise dress it now and poll for collision (see the class doc) — a visible chunk with
		# nothing on it is worse than one whose props are briefly not yet hittable.
		_pending_lod0[coord] = true
		if not _chunk_holders.has(coord):
			_build_chunk(coord, false, _is_underfoot(coord))
		return

	# F-369: in the visual band. Dress it, without proxies. A chunk arriving here WITH proxies has
	# been downgraded away from the collision ring, so its proxies must go even though its visuals
	# stay — that is the whole point of separating the two boundaries.
	_pending_lod0.erase(coord)
	# F-461: a chunk arriving here already dressed is one that has just LEFT the collision ring
	# walking outward. Its visuals are the same at LOD1 as they were at LOD0 — only the proxies have
	# to go — so it is downgraded in place. Tearing it down and re-queuing a visual-only rebuild was
	# the second of the two full rebuilds every chunk used to pay for on a single pass.
	# `_retarget_chunk()` is a no-op when the flag already matches, so a re-fired LOD1 costs nothing.
	if _chunk_holders.has(coord):
		_retarget_chunk(coord, false)
		return
	if not _visual_queue.has(coord):
		_visual_queue.append(coord)


func _on_chunk_unloaded(coord: Vector2i) -> void:
	_pending_lod0.erase(coord)
	_visual_queue.erase(coord)
	_teardown_chunk(coord)


## F-407: starts background loads for every asset the scatter tables can place, and folds completed
## ones into `_mesh_cache` so no chunk build ever pays a first-touch `load()`.
##
## Enumerated lazily rather than in `_ready()` because `scatter_defs` is assigned by the world after
## this node exists, so there is nothing to enumerate at ready time.
func _pump_asset_warm() -> void:
	if not _warm_queued:
		if scatter_defs.is_empty():
			return
		_warm_queued = true
		var seen: Dictionary = {}
		for def: Resource in scatter_defs:
			for entry: Resource in (def.get(&"entries") as Array):
				var kit := String(entry.get(&"kit"))
				var asset := String(entry.get(&"asset"))
				var key := "%s|%s" % [kit, asset]
				if seen.has(key) or _mesh_cache.has(key):
					continue
				seen[key] = true
				_warm_pending.append([kit, asset])

	while _warm_active.size() < WARM_REQUESTS_IN_FLIGHT and not _warm_pending.is_empty():
		var pair: Array = _warm_pending.pop_front()
		var path := "res://assets/%s/exports/%s.glb" % [pair[0], pair[1]]
		if ResourceLoader.load_threaded_request(path) == OK:
			_warm_active.append([pair[0], pair[1], path])

	var folded: int = 0
	for index: int in range(_warm_active.size() - 1, -1, -1):
		if folded >= WARM_COMPLETIONS_PER_FRAME:
			break
		var active: Array = _warm_active[index]
		var status: int = ResourceLoader.load_threaded_get_status(active[2])
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_warm_active.remove_at(index)
		if status != ResourceLoader.THREAD_LOAD_LOADED:
			continue
		# Retrieving it is what puts the resource in the cache; `_load_mesh_parts` then only has to
		# instantiate, which is the part that cannot leave the main thread.
		ResourceLoader.load_threaded_get(active[2])
		_load_mesh_parts(active[0], active[1])
		folded += 1


## True once every scatter asset is loaded and cached — the point after which no chunk build can
## stall on a first-touch load. Test seam for tools/chunk_stream_check.gd.
func assets_warm() -> bool:
	return _warm_queued and _warm_pending.is_empty() and _warm_active.is_empty()


## Dresses up to [constant SCATTER_VISUAL_BUILDS_PER_FRAME] queued visual-band chunks. Coords that
## went stale while queued (unloaded, downgraded, or since built with proxies) are dropped without
## consuming the frame's allowance — a stale entry is not work, so it should not displace work.
func _drain_visual_queue() -> void:
	var built: int = 0
	while built < SCATTER_VISUAL_BUILDS_PER_FRAME and not _visual_queue.is_empty():
		var coord: Vector2i = _visual_queue.pop_front()
		if _chunk_holders.has(coord):
			continue
		_build_chunk(coord, false)
		built += 1


func visual_queue_count() -> int:
	return _visual_queue.size()


## Builds a chunk's holder and either dresses it now or queues its asset groups to be dressed
## across the following frames (F-454).
##
## `immediate` is for the two cases where a partly-dressed chunk is worse than a stalled frame: the
## chunk the anchor is standing in, and the synchronous world prime behind a loading screen. Every
## other caller queues — see [constant SCATTER_BUILD_BUDGET_MS].
func _build_chunk(coord: Vector2i, with_proxies: bool, immediate: bool = false) -> void:
	# F-461: one holder per coord, always. Every caller already guards on `_chunk_holders.has()`
	# before reaching here, but the invariant is worth owning in one place now that a chunk can be
	# HOLDER-RESIDENT WITH ITS CONTENTS STILL IN FLIGHT — a second holder would orphan the first and
	# the landing job would dress the wrong one.
	if _chunk_holders.has(coord):
		_retarget_chunk(coord, with_proxies)
		return

	var holder := Node3D.new()
	holder.name = "Chunk_%d_%d" % [coord.x, coord.y]
	add_child(holder)
	_chunk_holders[coord] = holder
	_chunk_has_proxies[coord] = with_proxies

	# F-461. `immediate` is the loading-screen/underfoot case: the caller has said a partly dressed
	# chunk is worse than a stalled frame, so it pays for the placement pass here and now.
	if immediate:
		# A job for this coord may already be in flight from an earlier, non-immediate request that
		# has since been overtaken (a chunk queued at LOD1 that the player walked onto). It cannot be
		# cancelled, so mark its result to be discarded rather than dressing this chunk twice.
		if _placement_jobs.has(coord):
			_placement_jobs[coord].superseded = true
		var grouped: Dictionary = PlacementJob.group(ResourceScatterLib.placements_for_chunk(
			coord.x, coord.y, world_seed, scatter_defs, biome_defs),
			spawn_clear_center, spawn_clear_radius_m)
		_chunk_placements[coord] = grouped
		for key: String in grouped:
			var parts := key.split("|")
			_build_asset_group(holder, parts[0], parts[1], grouped[key] as Array, with_proxies)
		return

	# Everything else computes its placements on a worker thread. See PlacementJob for the
	# measurement — this call was 8-10 ms of main-thread time per chunk, paid inside
	# `ChunkStreamer`'s own `chunk_mesh_ready` emit, and it is what made SCATTER_BUILD_BUDGET_MS a
	# budget over the cheap half of the work.
	if _placement_jobs.has(coord):
		return
	var job := PlacementJob.new()
	job.coord = coord
	job.world_seed = world_seed
	job.scatter_defs = scatter_defs
	job.biome_defs = biome_defs
	job.spawn_clear_center = spawn_clear_center
	job.spawn_clear_radius_m = spawn_clear_radius_m
	job.task_id = WorkerThreadPool.add_task(job.run)
	_placement_jobs[coord] = job


## Folds finished placement jobs back onto the main thread, queueing each chunk's asset groups for
## the budgeted dressing pass. Uploading a result is pure bookkeeping — the expensive part already
## happened on the worker — so unlike `_drain_group_queue()` this is not itself budgeted.
func _drain_placement_jobs() -> void:
	if _placement_jobs.is_empty():
		return
	for coord: Vector2i in _placement_jobs.keys():
		var job: PlacementJob = _placement_jobs[coord]
		if not job.finished:
			if not WorkerThreadPool.is_task_completed(job.task_id):
				continue
			WorkerThreadPool.wait_for_task_completion(job.task_id)
			job.finished = true
		_placement_jobs.erase(coord)
		if job.superseded:
			continue
		# Torn down while the job was in flight, and not rebuilt since. The result is simply dropped
		# — a WorkerThreadPool task cannot be cancelled (the constraint `ChunkStreamer._retire()`
		# works around too). A chunk that WAS rebuilt meanwhile is dressed from this result rather
		# than recomputing it: placements are a pure function of (coord, seed), so it is still exact.
		var holder: Node3D = _chunk_holders.get(coord)
		if holder == null:
			continue
		_chunk_placements[coord] = job.grouped
		# `_chunk_has_proxies` is the single source of truth for which side of the proxy boundary
		# this chunk is on, and `_retarget_chunk()` may well have moved it while the job ran.
		var with_proxies: bool = bool(_chunk_has_proxies.get(coord, false))
		for key: String in job.grouped:
			var parts := key.split("|")
			_group_queue.append({
				"coord": coord,
				"kit": parts[0],
				"asset": parts[1],
				"placements": job.grouped[key],
				"with_proxies": with_proxies,
			})


func pending_placement_job_count() -> int:
	return _placement_jobs.size()


## Dresses queued asset groups until the frame's allowance is spent. Groups whose chunk has since
## been torn down or rebuilt are dropped without consuming the budget — a stale entry is not work,
## so it should not displace work (the same rule `_drain_visual_queue()` follows for coords).
func _drain_group_queue() -> void:
	if _group_queue.is_empty():
		return
	var deadline_usec: int = Time.get_ticks_usec() + int(SCATTER_BUILD_BUDGET_MS * 1000.0)
	while not _group_queue.is_empty():
		var item: Dictionary = _group_queue[0]
		var holder: Node3D = _chunk_holders.get(item["coord"] as Vector2i)
		if holder == null or bool(item["with_proxies"]) \
				!= bool(_chunk_has_proxies.get(item["coord"] as Vector2i, false)):
			_group_queue.pop_front()
			continue
		if Time.get_ticks_usec() >= deadline_usec:
			return
		_group_queue.pop_front()
		if bool(item.get("retarget", false)):
			_retarget_asset_group(holder, String(item["kit"]), String(item["asset"]),
				item["placements"] as Array, bool(item["with_proxies"]))
			continue
		_build_asset_group(holder, String(item["kit"]), String(item["asset"]),
			item["placements"] as Array, bool(item["with_proxies"]))


## How many asset groups are still waiting to be dressed. Zero means every resident chunk is fully
## dressed — the condition `tools/chunk_stream_check.gd` and the renderer instruments settle on.
func pending_group_count() -> int:
	return _group_queue.size()


## F-461. Moves an ALREADY-DRESSED chunk across the proxy boundary without destroying its scatter.
##
## The report this fixes: "when a new chunk does get loaded the assets in currently generated and
## loaded chunks get reloaded". They were. A chunk crossing into the collision ring was torn down
## and rebuilt whole, and so was the same chunk crossing back out — so one pass past a chunk built
## it three times (visual in, full, visual out) and the player watched 200-500 props vanish and
## refill through `_group_queue`'s 2 ms/frame allowance while standing next to them.
##
## Two of those three builds produce IDENTICAL geometry. What actually differs across the boundary
## is narrow:
##
##   · decorative scatter — the overwhelming majority of every chunk's placements — is one MultiMesh
##     per mesh part either way. Nothing about it depends on the boundary, so it is never touched.
##   · a BATCH harvestable is also the same MultiMesh either way (`_build_asset_group()` batches it
##     in both branches). Only its invisible proxy holders differ, so only those are added or freed.
##   · a NODE harvestable genuinely changes representation — individual meshes with proxies, one
##     MultiMesh without — and is the one family that has to be rebuilt at all.
##
## The rebuilds are queued through the same `_group_queue` budget as any other work, so a transition
## cannot spike a frame either. Nothing visible moves for the first two cases, which is the point.
func _retarget_chunk(coord: Vector2i, with_proxies: bool) -> void:
	var chunk_holder: Node3D = _chunk_holders.get(coord)
	if chunk_holder == null:
		return
	if bool(_chunk_has_proxies.get(coord, false)) == with_proxies:
		return
	_chunk_has_proxies[coord] = with_proxies

	# Groups still waiting their turn have not been built yet, so they should simply be built the
	# NEW way when it comes. Retargeting them in place matters: `_drain_group_queue()` drops an item
	# whose `with_proxies` disagrees with the chunk's flag, so leaving them would silently discard
	# every undrained group of a chunk that changed tier while its queue was backed up.
	for item: Dictionary in _group_queue:
		if (item["coord"] as Vector2i) == coord:
			item["with_proxies"] = with_proxies

	for key: String in _grouped_placements(coord):
		var parts := key.split("|")
		if not HarvestLib.is_harvestable(StringName(parts[1])):
			continue                                  # decorative: identical either way
		if _group_holder_for(chunk_holder, StringName(parts[1])) == null:
			continue                                  # not built yet — retargeted in the loop above
		_group_queue.append({
			"coord": coord,
			"kit": parts[0],
			"asset": parts[1],
			"placements": (_grouped_placements(coord)[key] as Array),
			"with_proxies": with_proxies,
			"retarget": true,
		})


## This chunk's placements, keyed "kit|asset", as its `PlacementJob` computed them. Empty for a
## chunk whose job has not landed yet, which is the correct answer: `_retarget_chunk()` has nothing
## built to retarget in that case, and `_drain_placement_jobs()` reads the current
## `_chunk_has_proxies` when the result does arrive.
func _grouped_placements(coord: Vector2i) -> Dictionary:
	return _chunk_placements.get(coord, {})


## The child of [param chunk_holder] holding one asset's instances, matched on the `asset` meta
## `_build_asset_group()` stamps rather than on the node name — a name can be uniquified by the
## engine, the meta cannot.
func _group_holder_for(chunk_holder: Node3D, asset_id: StringName) -> Node3D:
	for child: Node in chunk_holder.get_children():
		if child is Node3D and StringName(child.get_meta(&"asset", &"")) == asset_id:
			return child as Node3D
	return null


## One group's half of `_retarget_chunk()`. See that function for which of the three cases each
## branch is.
func _retarget_asset_group(
	chunk_holder: Node3D, kit: String, asset: String, placements: Array, with_proxies: bool
) -> void:
	var asset_id := StringName(asset)
	var group_holder: Node3D = _group_holder_for(chunk_holder, asset_id)
	if group_holder == null:
		return

	if HarvestLib.representation_for(asset_id) == HarvestLib.Represent.NODE:
		# The only family whose GEOMETRY differs across the boundary, so the only one rebuilt.
		# Removed from the tree before the replacement is added, so the new group holder cannot
		# collide with the old one's name and `_group_holder_for()` cannot find the corpse.
		_capture_depletion(group_holder)
		chunk_holder.remove_child(group_holder)
		group_holder.queue_free()
		_build_asset_group(chunk_holder, kit, asset, placements, with_proxies)
		return

	# BATCH: the MultiMesh stays exactly as it is, including any slot a depleted prop has zeroed —
	# which is strictly better than the rebuild this replaces, where a harvested bush grew back the
	# moment its chunk changed tier.
	if with_proxies:
		_add_batch_holders(group_holder, kit, asset, placements)
	else:
		_drop_batch_holders(group_holder)


## Gives an existing batched group its harvest proxies, reusing the MultiMeshes already under it.
func _add_batch_holders(
	group_holder: Node3D, kit: String, asset: String, placements: Array
) -> void:
	var mesh_parts: Array = _load_mesh_parts(kit, asset)
	if mesh_parts.is_empty():
		return
	var slots: Array[MultiMesh] = []
	for part_index: int in mesh_parts.size():
		var instance := group_holder.get_node_or_null(
			NodePath("%s_%d" % [asset, part_index])) as MultiMeshInstance3D
		if instance == null:
			return                     # not the shape `_build_asset_group()` builds; leave it alone
		slots.append(instance.multimesh)
	var asset_id := StringName(asset)
	for index: int in placements.size():
		_build_batch_holder(group_holder, placements[index], asset_id, kit, slots, mesh_parts,
			_transform_for(placements[index]), index)


## Takes a batched group's harvest proxies away, leaving its MultiMeshes untouched. Depletion state
## is captured first — it is the proxies that carry it, and out here they are what is going away.
func _drop_batch_holders(group_holder: Node3D) -> void:
	_capture_depletion(group_holder)
	for child: Node in group_holder.get_children():
		if not child.is_in_group(HARVESTABLE_HOLDER_GROUP):
			continue
		group_holder.remove_child(child)
		child.queue_free()


func _build_asset_group(
	holder: Node3D, kit: String, asset: String, placements: Array, with_proxies: bool
) -> void:
	var asset_id := StringName(asset)
	var mesh_parts: Array = _load_mesh_parts(kit, asset)
	if mesh_parts.is_empty():
		return

	# F-369: outside the collision ring nothing is harvestable, because nothing there can be reached.
	# A NODE harvestable therefore batches like any other scenery out at distance, which is also the
	# cheaper representation — the reason HarvestLibrary gives for batching in the first place.
	var harvestable: bool = with_proxies and HarvestLib.is_harvestable(asset_id)
	var represent: int = HarvestLib.representation_for(asset_id)

	var group_holder := Node3D.new()
	group_holder.name = asset
	group_holder.set_meta(&"asset", asset_id)
	holder.add_child(group_holder)

	# NODE harvestables get their own mesh (HarvestLibrary's own reasoning: a few hundred at
	# most, and you stand right next to them) — never batched.
	if harvestable and represent == HarvestLib.Represent.NODE:
		for placement: Dictionary in placements:
			_build_node_holder(group_holder, placement, asset_id, kit, mesh_parts)
		return

	# Decorative scatter, or a BATCH harvestable: one MultiMesh per mesh part for the whole group.
	var transforms: Array[Transform3D] = []
	for placement: Dictionary in placements:
		transforms.append(_transform_for(placement))

	var slots: Array[MultiMesh] = []
	for part_index: int in mesh_parts.size():
		var part: Dictionary = mesh_parts[part_index]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = part["mesh"]
		multimesh.instance_count = transforms.size()
		for index: int in transforms.size():
			multimesh.set_instance_transform(index, transforms[index] * (part["offset"] as Transform3D))
		var instance := MultiMeshInstance3D.new()
		instance.name = "%s_%d" % [asset, part_index]
		instance.multimesh = multimesh
		instance.set_meta(&"asset", asset_id)
		# F-369: the per-prop draw distance the authored map has always had and this one never did.
		# Decided from the prop's own height, then scaled by the graphics preset — so a grass tuft
		# stops drawing at 80 m and a willow at 260, and a weak machine pulls all of it in.
		DrawPolicy.apply(instance, (part["mesh"] as Mesh).get_aabb(), _max_scale(placements))
		group_holder.add_child(instance)
		slots.append(multimesh)

	if not harvestable:
		return
	for index: int in placements.size():
		_build_batch_holder(
			group_holder, placements[index], asset_id, kit, slots, mesh_parts, transforms[index], index
		)


func _transform_for(placement: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, placement["rotation_y"]), placement["position"]) \
		.scaled_local(Vector3.ONE * float(placement["scale"]))


## Shape and layout exactly mirror `world/gen/authored_world.gd`'s own `_build_harvestables()`
## holders, so `autoload/harvest_world.gd`'s existing `_wire_node_holder()` needs no change to
## pick these up.
func _build_node_holder(
	parent: Node3D, placement: Dictionary, asset_id: StringName, kit: String, mesh_parts: Array
) -> void:
	var point_id: String = placement["point_id"]
	var holder := Node3D.new()
	holder.name = "Harvest_%s" % point_id.replace(":", "_")
	holder.transform = _transform_for(placement)
	holder.set_meta(&"asset", asset_id)
	holder.set_meta(&"kit", kit)
	holder.set_meta(&"point_id", point_id)
	holder.add_to_group(HARVESTABLE_HOLDER_GROUP)

	var visual := Node3D.new()
	visual.name = "Visual"
	for part: Dictionary in mesh_parts:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = part["mesh"]
		mesh_instance.transform = part["offset"] as Transform3D
		DrawPolicy.apply(mesh_instance, (part["mesh"] as Mesh).get_aabb(),
			float(placement.get("scale", 1.0)))
		visual.add_child(mesh_instance)
	holder.add_child(visual)

	# F-390: an empty fit means "this prop does not collide" — ground flora, and anything you step
	# over. It is not a failure to be defended against with a fallback shape; see `_collider_for`.
	var fit: Dictionary = _collider_for(kit, String(asset_id), mesh_parts)
	if not fit.is_empty():
		var body := StaticBody3D.new()
		body.name = "CollisionBody"
		var shape_node := CollisionShape3D.new()
		# F-434: a prop that lies down gets a box along its own length, not a disc as wide as it is
		# long. `_collider_for()` decides which; both keys are authored in the prop's own space, so
		# the holder's yaw and scale carry the shape with the mesh either way.
		if StringName(fit.get("shape", &"cylinder")) == &"box":
			var box := BoxShape3D.new()
			box.size = fit["size"] as Vector3
			shape_node.shape = box
			shape_node.position = fit["center"] as Vector3
		else:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = float(fit["radius"])
			cylinder.height = float(fit["height"])
			shape_node.shape = cylinder
			shape_node.position.y = float(fit["center_y"])
		body.add_child(shape_node)
		holder.add_child(body)

	parent.add_child(holder)
	call_deferred("_wire_point_state", holder.get_path(), point_id, WIRE_WAIT_ATTEMPTS)


## Shape and metas exactly mirror `world/gen/authored_world.gd`'s own `_build_batch_harvestables()`
## holders — see that function's header for why a batched prop carries no collider and no mesh of
## its own, only the coordinates of its slot inside the group's MultiMesh.
func _build_batch_holder(
	parent: Node3D, placement: Dictionary, asset_id: StringName, kit: String,
	slots: Array[MultiMesh], mesh_parts: Array, instance_transform: Transform3D, index: int
) -> void:
	var point_id: String = placement["point_id"]
	var holder := Node3D.new()
	holder.name = "HarvestBatch_%s" % point_id.replace(":", "_")
	holder.transform = instance_transform
	holder.set_meta(&"asset", asset_id)
	holder.set_meta(&"kit", kit)
	holder.set_meta(&"point_id", point_id)
	holder.set_meta(&"batch_meshes", slots)
	holder.set_meta(&"batch_index", index)
	var intact: Array[Transform3D] = []
	for part: Dictionary in mesh_parts:
		intact.append(instance_transform * (part["offset"] as Transform3D))
	holder.set_meta(&"batch_transforms", intact)
	holder.add_to_group(HARVESTABLE_HOLDER_GROUP)
	parent.add_child(holder)
	call_deferred("_wire_point_state", holder.get_path(), point_id, WIRE_WAIT_ATTEMPTS)


## Waits for `HarvestWorld`'s deferred wiring to give this holder a live `Harvestable` child, then
## (a) if this point is already known depleted (`WorldDeltaLog`, falling back to this file's own
## peer-local memory), restores that state through `host_restore_depleted()` — the header explains
## why that, and not a direct `active` poke or a replayed `host_apply_damage()` hit, is the correct
## and safely-gated way to restore it, and (b) wires the Harvestable's own `depleted`/`respawned`
## signals so any FUTURE change to
## this point is recorded live, not only remembered at teardown. Called unconditionally for every
## holder this file builds, not just ones already believed depleted — a point that has never
## mutated still needs its future watched.
func _wire_point_state(holder_path: NodePath, point_id: String, attempts_left: int) -> void:
	var holder := get_node_or_null(holder_path) as Node3D
	if holder == null:
		return
	var harvestable := holder.get_node_or_null(^"Harvestable")
	if harvestable == null:
		if attempts_left > 0:
			call_deferred("_wire_point_state", holder_path, point_id, attempts_left - 1)
		return

	if is_point_depleted(point_id):
		harvestable.call("host_restore_depleted")

	harvestable.connect(&"depleted", func(_peer_id: int, _item_id: StringName, _amount: int) -> void:
		_record_point_state(point_id, true))
	harvestable.connect(&"respawned", func() -> void:
		_record_point_state(point_id, false))


## Largest instance scale in this group, so DrawPolicy grades a MultiMesh by the biggest copy in it
## rather than by the unscaled source mesh — the same `scale_hint` argument authored_world.gd passes.
func _max_scale(placements: Array) -> float:
	var largest: float = 1.0
	for placement: Dictionary in placements:
		largest = maxf(largest, float(placement.get("scale", 1.0)))
	return largest


func _teardown_chunk(coord: Vector2i) -> void:
	# F-369: erased unconditionally, before the null guard. Leaving a stale `true` here is what makes
	# a chunk that comes back into the collision ring skip its proxy rebuild entirely — the LOD0
	# branch reads this flag to decide whether to start polling, so a lie here is silent and
	# permanent for that coord. Caught by resource_scatter_check's "the same point rebuilds a live
	# Harvestable again".
	_chunk_has_proxies.erase(coord)
	# F-461: this chunk's placement list is only wanted while the chunk is resident. Any in-flight
	# `PlacementJob` is deliberately LEFT alone: it cannot be cancelled, its result is still exactly
	# right for this coord if the chunk comes back, and `_drain_placement_jobs()` drops it if not.
	_chunk_placements.erase(coord)
	# F-454: anything still queued for this coord is now work on a holder that is about to be
	# freed. `_drain_group_queue()` would drop it on its own, but leaving it in the queue lets a
	# chunk that unloads and reloads accumulate dead entries ahead of live ones.
	for index: int in range(_group_queue.size() - 1, -1, -1):
		if (_group_queue[index]["coord"] as Vector2i) == coord:
			_group_queue.remove_at(index)
	var holder: Node3D = _chunk_holders.get(coord)
	if holder == null:
		return
	_capture_depletion(holder)
	_chunk_holders.erase(coord)
	holder.queue_free()


func _capture_depletion(holder: Node3D) -> void:
	for node: Node in holder.find_children("*", "", true, false):
		if not node.is_in_group(HARVESTABLE_HOLDER_GROUP):
			continue
		var point_id: String = String(node.get_meta(&"point_id", ""))
		if point_id.is_empty():
			continue
		var harvestable := node.get_node_or_null(^"Harvestable")
		if harvestable != null:
			_depleted[point_id] = not bool(harvestable.get("active"))


func _delta_log() -> Node:
	return get_node_or_null(^"/root/WorldDeltaLog")


## `point_id`'s own format (`world/gen/resource_scatter.gd`): `"%d:%d:%s:%d:%d" % [chunk_x, chunk_z,
## def_id, gx, gz]` — the chunk coordinate is always its first two fields, so this file never needs
## to thread a `coord` parameter down through the builder call chain just to key `WorldDeltaLog`.
func _chunk_from_point_id(point_id: String) -> Vector2i:
	var parts: PackedStringArray = point_id.split(":")
	return Vector2i(int(parts[0]), int(parts[1]))


## Updates both the peer-local fallback memory and, when this peer owns world mutation, the shared
## log — `WorldDeltaLog.host_record()` is itself gated to no-op on a real client, so this is safe to
## call unconditionally from a signal that (per the header) only ever actually fires host-side.
func _record_point_state(point_id: String, depleted_now: bool) -> void:
	_depleted[point_id] = depleted_now
	var log: Node = _delta_log()
	if log != null:
		log.call("host_record", _chunk_from_point_id(point_id), DEPLETION_KIND, point_id, depleted_now)


## The collider a NODE prop gets, delegated to `world/gen/prop_collider.gd` (F-434).
##
## The measurement itself moved out of this file when `world/gen/authored_world.gd` needed the same
## answer: an authored map's layout stores a collider per PLACEMENT, computed by a Python mapgen
## that has never been able to look at the mesh, so Hollowmere's trees carry cylinders sized from
## their CANOPY footprint — the exact "leaves collide" defect F-348 removed from this path. One
## fitter now answers for both worlds.
##
## Cached per (kit, asset) rather than per prop: the fitter walks every vertex of the mesh, which is
## affordable for the handful of NODE assets a biome scatters and is not affordable a few hundred
## times a chunk.
func _collider_for(kit: String, asset: String, mesh_parts: Array) -> Dictionary:
	return PROP_COLLIDER.fit_cached(_collider_cache, "%s|%s" % [kit, asset], mesh_parts)


func _load_mesh_parts(kit: String, asset: String) -> Array:
	var cache_key := "%s|%s" % [kit, asset]
	if _mesh_cache.has(cache_key):
		return _mesh_cache[cache_key]
	var path := "res://assets/%s/exports/%s.glb" % [kit, asset]
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("ResourceScatterField could not load %s" % path)
		_mesh_cache[cache_key] = []
		return []
	var sample := packed.instantiate()
	var found: Array[MeshInstance3D] = []
	_collect_meshes(sample, found)
	var parts: Array = []
	for part: MeshInstance3D in found:
		if part.mesh == null:
			continue
		parts.append({"mesh": part.mesh, "offset": _global_offset(part, sample)})
	sample.free()
	_mesh_cache[cache_key] = parts
	return parts


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_meshes(child, out)


func _global_offset(node: Node3D, root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result
