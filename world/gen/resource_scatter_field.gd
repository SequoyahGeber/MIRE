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
const COLLIDER_OBSTACLE_HEIGHT_M: float = 1.8
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

const COLLIDER_TRUNK_BAND_MIN_M: float = 0.5
## F-390: nothing shorter than this gets a collider at all. You step over it, so a cylinder there can
## only ever be something to trip on.
const COLLIDER_MIN_HEIGHT_M: float = 0.4
## Material-name prefixes that mark a surface as leaves, fronds, grass, moss or blossom — the parts
## of a prop a player walks straight through.
##
## `tools/blender/mire_art.py` names every material `"MIRE_" + CamelCase(palette_token)`
## (docs/SPECS.md, F-092), and its palette groups these tokens under one `-- foliage` heading, so
## these prefixes are the foliage family as the art pipeline itself defines it rather than a list
## guessed from the assets that happen to exist today. A willow carries its trunk on `MIRE_WoodBark`
## and its crown on `MIRE_Leaf`/`MIRE_LeafDeep`/`MIRE_LeafLight`: four surfaces of one mesh, which is
## what makes "collide the trunk, not the leaves" answerable at all without hand-authored shapes.
const FOLIAGE_MATERIAL_PREFIXES: PackedStringArray = [
	"MIRE_Leaf", "MIRE_Pine", "MIRE_Grass", "MIRE_Moss",
	"MIRE_Reed", "MIRE_Sedge", "MIRE_Bracken", "MIRE_Flower",
]

@export var world_seed: int = 0
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
## F-369: coord -> whether the chunk was built WITH harvest proxies. A chunk can be built twice over
## its life — visual-only when it reaches LOD1, then rebuilt with proxies when collision cooks — and
## this is what keeps those transitions from stacking or from silently skipping the upgrade.
var _chunk_has_proxies: Dictionary[Vector2i, bool] = {}
## F-369: visual-band chunks awaiting their turn under SCATTER_VISUAL_BUILDS_PER_FRAME. Insertion
## order is streaming order, which is near-to-far, so draining it in order dresses inward-out.
var _visual_queue: Array[Vector2i] = []


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
	_drain_visual_queue()
	if _pending_lod0.is_empty():
		return
	_poll_accum += delta
	if _poll_accum < COLLISION_POLL_INTERVAL_SEC:
		return
	_poll_accum = 0.0
	for coord: Vector2i in _pending_lod0.keys():
		if not bool(_streamer.chunk_has_collision(coord)):
			continue
		_pending_lod0.erase(coord)
		# F-369: the chunk may already carry visual-only scatter from its LOD1 pass. Replace it
		# rather than adding a second copy on top.
		if _chunk_holders.has(coord):
			_teardown_chunk(coord)
		_build_chunk(coord, true)


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
				_teardown_chunk(coord)
			_build_chunk(coord, true)
			return
		# Otherwise dress it now and poll for collision (see the class doc) — a visible chunk with
		# nothing on it is worse than one whose props are briefly not yet hittable.
		_pending_lod0[coord] = true
		if not _chunk_holders.has(coord):
			_build_chunk(coord, false)
		return

	# F-369: in the visual band. Dress it, without proxies. A chunk arriving here WITH proxies has
	# been downgraded away from the collision ring, so its proxies must go even though its visuals
	# stay — that is the whole point of separating the two boundaries.
	_pending_lod0.erase(coord)
	if _chunk_has_proxies.get(coord, false):
		_teardown_chunk(coord)
	if not _chunk_holders.has(coord) and not _visual_queue.has(coord):
		_visual_queue.append(coord)


func _on_chunk_unloaded(coord: Vector2i) -> void:
	_pending_lod0.erase(coord)
	_visual_queue.erase(coord)
	_teardown_chunk(coord)


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


func _build_chunk(coord: Vector2i, with_proxies: bool) -> void:
	var placements: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(
		coord.x, coord.y, world_seed, scatter_defs, biome_defs
	)
	var holder := Node3D.new()
	holder.name = "Chunk_%d_%d" % [coord.x, coord.y]
	add_child(holder)
	_chunk_holders[coord] = holder
	_chunk_has_proxies[coord] = with_proxies

	var by_asset: Dictionary = {}
	for placement: Dictionary in placements:
		var key := "%s|%s" % [String(placement["kit"]), String(placement["asset"])]
		(by_asset.get_or_add(key, [] as Array) as Array).append(placement)

	for key: String in by_asset:
		var parts := key.split("|")
		_build_asset_group(holder, parts[0], parts[1], by_asset[key] as Array, with_proxies)


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


## The cylinder a NODE harvestable collides as: as tall as the prop, as wide as the widest SOLID
## thing a walking body could hit.
##
## F-348: this used to be the union AABB of every mesh part, which for a tree is the LEAF CROWN —
## a willow ended up with a 1.89 m-radius invisible wall around a trunk about 0.9 m across at the
## root flare, so the player was stopped a metre short of every tree on the island with nothing on
## screen to explain it. Leaves are not an obstacle; the trunk is.
##
## Two rules get there, and both are needed. Surfaces painted with a foliage material contribute
## nothing — that removes the crown outright. Of what is left, only vertices below
## [constant COLLIDER_OBSTACLE_HEIGHT_M] count — that removes the bark BRANCHES, which are solid
## wood spreading twice as wide as the trunk they grow from and are still something you walk under.
## Radius is measured from the prop's own vertical axis rather than off an AABB corner: props are
## authored around their origin, and a radial measure is what a cylinder actually needs. Height
## stays the FULL height, so an arrow still hits a trunk forty feet up.
##
## **Returns an EMPTY dictionary for a prop that should not collide at all**, and `_build_node_holder`
## emits no body for one. Two ways to get there, both added by F-390:
##
##  · **It is foliage all the way down.** The old code treated that as a content bug and fell back to
##    measuring the foliage, then to the full AABB — "a collider that is too wide beats one that is
##    missing". That is right for an UNRECOGNISED material and exactly wrong for a recognised one:
##    every surface being known foliage is not ambiguity, it is the answer. What it actually shipped
##    was a solid cylinder around every blade of grass, every flower and every clover patch on the
##    island — `grass_short_c` measured r=0.89 h=0.27, `flowers_meadow_a` r=0.84 — invisible, in the
##    thousands, and directly against the standing rule for this project that leaves and canopy never
##    collide. A player walking over a field of ankle-high cylinders bounces, which is what was
##    reported.
##  · **It is shorter than [constant COLLIDER_MIN_HEIGHT_M].** You step over it.
##
## A prop with geometry the material table does not recognise still gets the old benefit of the
## doubt — `_is_foliage()` treats an unnamed material as SOLID, so this only ever drops props whose
## surfaces are all POSITIVELY identified as leaves, grass, moss, reed, sedge, bracken or blossom.
func _collider_for(kit: String, asset: String, mesh_parts: Array) -> Dictionary:
	var cache_key := "%s|%s" % [kit, asset]
	if _collider_cache.has(cache_key):
		return _collider_cache[cache_key]

	var merged := AABB()
	# The old measure: widest solid geometry anywhere below the cut. Still the fallback for props
	# with nothing in the band at all — a fallen log, a low boulder, a stump.
	var solid_radius: float = 0.0
	for part: Dictionary in mesh_parts:
		var mesh: Mesh = part["mesh"] as Mesh
		var offset: Transform3D = part["offset"] as Transform3D
		var box: AABB = offset * mesh.get_aabb()
		merged = box if merged.size == Vector3.ZERO else merged.merge(box)
		if box.position.y > COLLIDER_OBSTACLE_HEIGHT_M:
			continue
		for surface: int in mesh.get_surface_count():
			if _is_foliage(mesh.surface_get_material(surface)):
				continue
			# Vertices, not the surface's bounds: a willow's crown hangs down past head height, so a
			# bounds test would call the whole canopy "below the cut" and change nothing.
			solid_radius = maxf(solid_radius, _surface_reach(mesh, surface, offset, 0.0))

	var height: float = maxf(merged.size.y, 0.1)
	# Nothing solid anywhere, or too short to matter: no body at all.
	if solid_radius <= 0.0 or height < COLLIDER_MIN_HEIGHT_M:
		_collider_cache[cache_key] = {}
		return {}

	var fit: Dictionary = {
		"radius": maxf(_band_radius(mesh_parts, solid_radius), 0.05),
		"height": height,
		"center_y": merged.get_center().y,
	}
	_collider_cache[cache_key] = fit
	return fit


## The collider radius, measured as the prop's HORIZONTAL CROSS-SECTION through the trunk band.
##
## Three approaches were tried against the shipped assets and the first two both failed on real
## content, so the reasoning is worth keeping:
##
## 1. **Widest solid geometry below head height** (what shipped). Set by the ROOT FLARE at the very
##    base, so `tree_willow_a` measured 1.29 m around a trunk nearer 0.3 and the player was stopped
##    over a metre from bark they were walking at.
## 2. **A percentile of solid VERTEX radii inside the band.** Correct in principle and blind in
##    practice: these are low-poly meshes, and a willow's trunk is a cylinder with a vertex ring at
##    its base and the next one above head height. Nothing at all lands between 0.5 m and 1.8 m, so
##    two of the three willows contributed zero samples and silently fell back to (1).
##
## 3. **Slice it.** For each of [constant COLLIDER_BAND_SLICES] heights across the band, find every
##    triangle EDGE that crosses that height, interpolate the crossing point, and take the widest —
##    a true silhouette at that height, independent of where the vertices happen to sit. Then take
##    the MEDIAN across the slices.
##
## The median across slices is what separates a trunk from a rock without knowing which it is. A
## tree is a narrow column at almost every height in the band, with at most a couple of slices
## catching a branch — outliers the median drops. A boulder is wide at every height, so its median
## IS its width. Content that is neither still gets a defensible answer rather than a special case.
const COLLIDER_BAND_SLICES: int = 9

func _band_radius(mesh_parts: Array, fallback: float) -> float:
	var slice_radii := PackedFloat32Array()
	var span: float = COLLIDER_OBSTACLE_HEIGHT_M - COLLIDER_TRUNK_BAND_MIN_M
	for slice: int in COLLIDER_BAND_SLICES:
		var height: float = COLLIDER_TRUNK_BAND_MIN_M \
			+ span * (float(slice) + 0.5) / float(COLLIDER_BAND_SLICES)
		var widest: float = _cross_section_radius(mesh_parts, height)
		if widest > 0.0:
			slice_radii.append(widest)
	if slice_radii.is_empty():
		# The band is above the whole prop, or below nothing solid. Its widest solid geometry below
		# the cut is the honest answer and always was — a fallen log, a stump, a low rock.
		return fallback
	slice_radii.sort()
	return slice_radii[slice_radii.size() / 2]


## Widest solid point on the horizontal plane at [param height], found by interpolating every
## triangle edge that crosses it. Returns 0.0 when nothing solid reaches that height.
func _cross_section_radius(mesh_parts: Array, height: float) -> float:
	var widest_sq: float = 0.0
	for part: Dictionary in mesh_parts:
		var mesh: Mesh = part["mesh"] as Mesh
		var offset: Transform3D = part["offset"] as Transform3D
		for surface: int in mesh.get_surface_count():
			if _is_foliage(mesh.surface_get_material(surface)):
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var count: int = indices.size() if indices.size() > 0 else verts.size()
			for i: int in range(0, count - 2, 3):
				for edge: int in 3:
					var ia: int = i + edge
					var ib: int = i + (edge + 1) % 3
					var a: Vector3 = offset * verts[indices[ia] if indices.size() > 0 else ia]
					var b: Vector3 = offset * verts[indices[ib] if indices.size() > 0 else ib]
					if (a.y - height) * (b.y - height) > 0.0:
						continue
					if is_equal_approx(a.y, b.y):
						continue
					var t: float = (height - a.y) / (b.y - a.y)
					var x: float = a.x + (b.x - a.x) * t
					var z: float = a.z + (b.z - a.z) * t
					widest_sq = maxf(widest_sq, x * x + z * z)
	return sqrt(widest_sq)


## How far one surface reaches from the prop's vertical axis, counting only vertices between
## [param min_y] and [constant COLLIDER_OBSTACLE_HEIGHT_M].
func _surface_reach(mesh: Mesh, surface: int, offset: Transform3D, min_y: float) -> float:
	var arrays: Array = mesh.surface_get_arrays(surface)
	if arrays.is_empty():
		return 0.0
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var worst_sq: float = 0.0
	for vertex: Vector3 in verts:
		var point: Vector3 = offset * vertex
		if point.y > COLLIDER_OBSTACLE_HEIGHT_M or point.y < min_y:
			continue
		worst_sq = maxf(worst_sq, point.x * point.x + point.z * point.z)
	return sqrt(worst_sq)


## True for a surface a player walks straight through. An unnamed or missing material counts as
## SOLID: silently dropping an unrecognised surface from the collider is how a prop ends up with no
## collision at all, and being too wide is the safer failure.
func _is_foliage(material: Material) -> bool:
	if material == null:
		return false
	var name: String = material.resource_name
	for prefix: String in FOLIAGE_MATERIAL_PREFIXES:
		if name.begins_with(prefix):
			return true
	return false


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
