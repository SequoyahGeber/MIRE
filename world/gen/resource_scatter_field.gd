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
## The restore itself is still a full `host_apply_damage()` hit through the SAME host-gated seam a
## real swing uses, never a direct poke at `active` — that is not a stylistic choice: `active` alone
## is only half of depletion's real state (`_deplete()` also arms the respawn clock), so a direct
## poke left the respawn clock at its just-constructed 0.0 and the very next physics tick
## auto-respawned the point straight back, caught by this task's own check when the bug first
## shipped (D-083). Going through `host_apply_damage()` also means the restore inherits the method's
## own authority gate for free: on a real client the call quietly no-ops, exactly as it should.
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
var _poll_accum: float = 0.0


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


func chunk_count() -> int:
	return _chunk_holders.size()


func pending_count() -> int:
	return _pending_lod0.size()


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
	if _pending_lod0.is_empty() or _streamer == null:
		return
	_poll_accum += delta
	if _poll_accum < COLLISION_POLL_INTERVAL_SEC:
		return
	_poll_accum = 0.0
	for coord: Vector2i in _pending_lod0.keys():
		if bool(_streamer.chunk_has_collision(coord)):
			_pending_lod0.erase(coord)
			_build_chunk(coord)


func _on_chunk_mesh_ready(coord: Vector2i, lod: int) -> void:
	if lod != 0:
		# Downgraded away from LOD0 (or never reached it) before this file acted on it — tear
		# down whatever scatter exists, but keep the depletion memory `_teardown_chunk` records.
		_pending_lod0.erase(coord)
		_teardown_chunk(coord)
		return
	if _chunk_holders.has(coord) or _pending_lod0.has(coord):
		return
	_pending_lod0[coord] = true


func _on_chunk_unloaded(coord: Vector2i) -> void:
	_pending_lod0.erase(coord)
	_teardown_chunk(coord)


func _build_chunk(coord: Vector2i) -> void:
	var placements: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(
		coord.x, coord.y, world_seed, scatter_defs, biome_defs
	)
	var holder := Node3D.new()
	holder.name = "Chunk_%d_%d" % [coord.x, coord.y]
	add_child(holder)
	_chunk_holders[coord] = holder

	var by_asset: Dictionary = {}
	for placement: Dictionary in placements:
		var key := "%s|%s" % [String(placement["kit"]), String(placement["asset"])]
		(by_asset.get_or_add(key, [] as Array) as Array).append(placement)

	for key: String in by_asset:
		var parts := key.split("|")
		_build_asset_group(holder, parts[0], parts[1], by_asset[key] as Array)


func _build_asset_group(holder: Node3D, kit: String, asset: String, placements: Array) -> void:
	var asset_id := StringName(asset)
	var mesh_parts: Array = _load_mesh_parts(kit, asset)
	if mesh_parts.is_empty():
		return

	var harvestable: bool = HarvestLib.is_harvestable(asset_id)
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
	var merged := AABB()
	for part: Dictionary in mesh_parts:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = part["mesh"]
		mesh_instance.transform = part["offset"] as Transform3D
		visual.add_child(mesh_instance)
		var box: AABB = (part["offset"] as Transform3D) * (part["mesh"] as Mesh).get_aabb()
		merged = box if merged.size == Vector3.ZERO else merged.merge(box)
	holder.add_child(visual)

	var body := StaticBody3D.new()
	body.name = "CollisionBody"
	var shape_node := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = maxf(maxf(merged.size.x, merged.size.z) * 0.5, 0.05)
	cylinder.height = maxf(merged.size.y, 0.1)
	shape_node.shape = cylinder
	shape_node.position = merged.get_center()
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
## peer-local memory), replays a full depletion hit through `host_apply_damage()` — the header
## explains why that, and not a direct `active` poke, is the correct and safely-gated way to restore
## it, and (b) wires the Harvestable's own `depleted`/`respawned` signals so any FUTURE change to
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
		var definition: Resource = harvestable.get(&"definition")
		if definition != null:
			harvestable.call("host_apply_damage", int(definition.get(&"max_health")), NetConfig.HOST_PEER_ID)

	harvestable.connect(&"depleted", func(_peer_id: int, _item_id: StringName, _amount: int) -> void:
		_record_point_state(point_id, true))
	harvestable.connect(&"respawned", func() -> void:
		_record_point_state(point_id, false))


func _teardown_chunk(coord: Vector2i) -> void:
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
