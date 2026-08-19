class_name NavBaker
extends Node

## Runtime NavMesh baking for streamed terrain chunks — task 4.5, implementing D-016's measured
## rules rather than rediscovering them. Pairs with a `ChunkStreamer` the way `ResourceScatterField`
## does: bind one to a streamer and it keeps a navigation map in step with whichever chunks are
## resident.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): **HOST**. Pathfinding is host-authoritative
## (D-016), enemies are host-owned bodies, and a client has nothing to path. A client peer therefore
## bakes nothing at all — `bind()` on a non-host is a no-op, which also means a six-player session
## pays this cost once rather than six times. Nothing here is ever sent over the wire: the map is
## derived from terrain every peer could regenerate anyway.
##
## WHY THIS FILE READS LIKE A LIST OF RULES. M0's R3 spike is the most expensive measurement in the
## project, and `ARCHITECTURE.md` §6's four traps all fail SILENTLY — no error, no warning, just a
## wrong result. Every constant below is one of those findings, and the comment beside it is what it
## cost to learn. Do not tune one without re-running `tools/nav_bake_check.gd`.

const Mesher := preload("res://world/chunk/chunk_mesher.gd")

## Must equal the map's cell size or region edges rasterize onto different grids and connections
## silently misbehave (§6 trap 3 — the one Godot at least warns about). One knob, used for both.
## 0.25 m is D-016's measured floor: scaling is steeply superlinear, and 0.1 m cost 80.7 ms/chunk.
const CELL_SIZE: float = 0.25
const CELL_HEIGHT: float = 0.25

const AGENT_RADIUS: float = 0.5
## A whole number of `cell_height` voxels, or Godot warns.
const AGENT_HEIGHT: float = 1.75
const AGENT_MAX_CLIMB: float = 0.5
const AGENT_MAX_SLOPE: float = 45.0

## D-016's seam fix, and the single least guessable number here. Independent per-chunk bakes leave a
## hole exactly `2 × agent_radius` wide (1.00 m measured) because Recast erodes inward from the
## geometry edge; the default 0.25 m margin cannot bridge it and agents simply cannot cross a chunk
## boundary. `filter_baking_aabb` and `border_size` both make it WORSE (§6 trap 4). A negative
## control in the spike confirmed this wide margin does not wrongly link chunks 32 m apart.
const EDGE_CONNECTION_MARGIN: float = 1.10

## One bake in flight at a time. D-016: 16 async bakes fired in one frame blocked 6.8 ms, while
## submitting one costs 0.004 ms and attaching the finished region costs 0.003 ms. The queue is what
## keeps the whole system inside its 2 ms budget, so it is not an optimization to remove later.
const MAX_BAKES_IN_FLIGHT: int = 1

## Only chunks at this LOD get a nav region. D-084 established that the collision ring IS the LOD0
## ring; navigation belongs on exactly the same ring, because an agent pathing across terrain that
## has no collider would walk on nothing.
const NAV_LOD: int = 0

signal region_ready(coord: Vector2i)
signal region_retired(coord: Vector2i)

var world_seed: int = 0

## coord -> {region: RID, nav_mesh: NavigationMesh}
var _regions: Dictionary[Vector2i, Dictionary] = {}
## Coords waiting for a bake slot, in arrival order.
var _queue: Array[Vector2i] = []
## coord -> NavigationMesh currently being baked. Keyed so a retire mid-bake can drop the result.
var _in_flight: Dictionary[Vector2i, NavigationMesh] = {}
var _map: RID
var _streamer: Node
var _owns_map: bool = false


func _exit_tree() -> void:
	_release_map()


## Binds to a `ChunkStreamer` and starts tracking it. Returns false on a non-host, where this does
## nothing by design — see the authority note in the header.
func bind(streamer: Node, seed_value: int, force_active: bool = false) -> bool:
	if not force_active and not _owns_navigation():
		return false
	_streamer = streamer
	world_seed = seed_value
	_ensure_map()
	if streamer != null:
		if streamer.has_signal(&"chunk_mesh_ready"):
			streamer.connect(&"chunk_mesh_ready", _on_chunk_mesh_ready)
		if streamer.has_signal(&"chunk_unloaded"):
			streamer.connect(&"chunk_unloaded", _on_chunk_unloaded)
	return true


func map_rid() -> RID:
	_ensure_map()
	return _map


func region_count() -> int:
	return _regions.size()


func pending_bake_count() -> int:
	return _queue.size() + _in_flight.size()


func has_region(coord: Vector2i) -> bool:
	return _regions.has(coord)


## §6 trap 2, and the reason this is a query rather than a flag: a navigation map is not queryable
## until the server syncs it on a physics frame, and BOTH obvious readiness signals lie —
## `map_force_update()` does not force the sync, and `map_get_iteration_id()` reaches 1 while the
## polygon graph is still empty. Querying early fails with "query failed because it was made before
## first map synchronization". So: poll an actual query and see whether it answers.
func is_queryable() -> bool:
	if not _map.is_valid() or _regions.is_empty():
		return false
	var probe: Vector3 = _any_region_origin()
	return NavigationServer3D.map_get_closest_point(_map, probe) != Vector3.ZERO


# ── Streaming hooks ──────────────────────────────────────────────────────────────────────────────


func _on_chunk_mesh_ready(coord: Vector2i, lod: int) -> void:
	if lod != NAV_LOD:
		# A chunk that dropped OUT of the nav ring must lose its region, not merely stop gaining one
		# — otherwise a stale region sits on the map describing terrain rendered at a coarser LOD.
		_retire(coord)
		return
	if _regions.has(coord) or _in_flight.has(coord) or _queue.has(coord):
		return
	_queue.append(coord)
	_pump()


func _on_chunk_unloaded(coord: Vector2i) -> void:
	_retire(coord)


## Public so a caller driving this without a live streamer (the check, and any future non-streamed
## caller) uses the same path the signals do rather than a parallel one.
func request_bake(coord: Vector2i) -> void:
	_on_chunk_mesh_ready(coord, NAV_LOD)


func _pump() -> void:
	while _in_flight.size() < MAX_BAKES_IN_FLIGHT and not _queue.is_empty():
		_start_bake(_queue.pop_front())


func _start_bake(coord: Vector2i) -> void:
	var geometry: NavigationMeshSourceGeometryData3D = _source_geometry(coord)
	if geometry == null:
		return
	var nav_mesh: NavigationMesh = _make_nav_mesh()
	_in_flight[coord] = nav_mesh
	# Async is the ONLY bake we ever call (D-016): the blocking form costs 9.2 ms per 32 m chunk,
	# 55% of a frame. Submitting costs 0.004 ms.
	NavigationServer3D.bake_from_source_geometry_data_async(
		nav_mesh, geometry, _on_bake_finished.bind(coord))


func _on_bake_finished(coord: Vector2i) -> void:
	var nav_mesh: NavigationMesh = _in_flight.get(coord)
	_in_flight.erase(coord)
	# Retired while it was baking — a normal outcome when the player turns around, not an error.
	# Dropping the result here is what keeps a region for an unloaded chunk off the map.
	if nav_mesh != null and not _retired_during_bake(coord):
		_attach(coord, nav_mesh)
	_pump()


func _retired_during_bake(coord: Vector2i) -> bool:
	if _streamer == null:
		return false
	if not _streamer.has_method(&"is_chunk_loaded"):
		return false
	return not bool(_streamer.call("is_chunk_loaded", coord))


func _attach(coord: Vector2i, nav_mesh: NavigationMesh) -> void:
	_ensure_map()
	var region: RID = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region, _map)
	NavigationServer3D.region_set_transform(
		region, Transform3D(Basis.IDENTITY, _chunk_origin(coord)))
	NavigationServer3D.region_set_use_edge_connections(region, true)
	NavigationServer3D.region_set_navigation_mesh(region, nav_mesh)
	_regions[coord] = {"region": region, "nav_mesh": nav_mesh}
	region_ready.emit(coord)


func _retire(coord: Vector2i) -> void:
	_queue.erase(coord)
	var entry: Dictionary = _regions.get(coord, {})
	if entry.is_empty():
		return
	_regions.erase(coord)
	NavigationServer3D.free_rid(entry["region"] as RID)
	region_retired.emit(coord)


# ── Geometry ─────────────────────────────────────────────────────────────────────────────────────


## The SAME triangles the physics collider is cooked from — `ChunkMesher.collision_faces()`, which
## slices the LOD skirt off the front of the index buffer (D-084). Navigation and collision must
## describe the same surface, or an agent paths confidently across a skirt that is a vertical wall
## hanging below the seam, or onto terrain nothing can stand on.
##
## Faces are chunk-LOCAL: the region carries the world offset in its transform, so the same bake is
## valid wherever it is attached and the numbers stay small.
func _source_geometry(coord: Vector2i) -> NavigationMeshSourceGeometryData3D:
	var mesh: ArrayMesh = Mesher.build_mesh(coord.x, coord.y, world_seed, NAV_LOD)
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	var faces: PackedVector3Array = Mesher.collision_faces(mesh, NAV_LOD)
	if faces.is_empty():
		return null
	var geometry := NavigationMeshSourceGeometryData3D.new()
	geometry.add_faces(_wound_for_recast(faces), Transform3D.IDENTITY)
	return geometry


## §6 trap 1, the single most expensive one: Godot's Recast bridge treats a triangle as up-facing
## when `cross(v1 - v0, v2 - v0).y` is **NEGATIVE** — the opposite of the usual convention. Feed it
## conventionally-wound faces and the bake returns SUCCESS with ZERO polygons. No error, no warning.
## It looks exactly like "navigation is broken".
##
## `ChunkMesher`'s faces are wound for RENDERING, so rather than assume which way that is, this
## measures the first triangle and flips the whole buffer only if it needs it. Measuring beats
## asserting here: the mesher's winding is its own business and may legitimately change, and this way
## a change there produces correct navigation instead of an empty map nobody notices until an enemy
## stands still. `tools/nav_bake_check.gd` asserts both that the result is non-empty AND that a
## deliberately mis-wound buffer bakes nothing, so the trap stays proven rather than assumed.
func _wound_for_recast(faces: PackedVector3Array) -> PackedVector3Array:
	if faces.size() < 3:
		return faces
	if _is_up_facing_for_recast(faces[0], faces[1], faces[2]):
		return faces
	var flipped := PackedVector3Array()
	flipped.resize(faces.size())
	for i: int in range(0, faces.size(), 3):
		flipped[i] = faces[i]
		flipped[i + 1] = faces[i + 2]
		flipped[i + 2] = faces[i + 1]
	return flipped


static func _is_up_facing_for_recast(v0: Vector3, v1: Vector3, v2: Vector3) -> bool:
	return (v1 - v0).cross(v2 - v0).y < 0.0


func _make_nav_mesh() -> NavigationMesh:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = CELL_SIZE
	nav_mesh.cell_height = CELL_HEIGHT
	nav_mesh.agent_height = AGENT_HEIGHT
	nav_mesh.agent_radius = AGENT_RADIUS
	nav_mesh.agent_max_climb = AGENT_MAX_CLIMB
	nav_mesh.agent_max_slope = AGENT_MAX_SLOPE
	# border_size and filter_baking_aabb are deliberately left at zero — §6 trap 4 measured both
	# making the seam WORSE (a 4 m border produced an 8 m hole). The seam fix is the edge margin.
	return nav_mesh


func _chunk_origin(coord: Vector2i) -> Vector3:
	var size: float = float(Mesher.CHUNK_SIZE)
	return Vector3(float(coord.x) * size, 0.0, float(coord.y) * size)


func _any_region_origin() -> Vector3:
	for coord: Vector2i in _regions:
		return _chunk_origin(coord) + Vector3(float(Mesher.CHUNK_SIZE) * 0.5, 0.0,
			float(Mesher.CHUNK_SIZE) * 0.5)
	return Vector3.ZERO


# ── Map lifecycle ────────────────────────────────────────────────────────────────────────────────


func _ensure_map() -> void:
	if _map.is_valid():
		return
	_map = NavigationServer3D.map_create()
	_owns_map = true
	NavigationServer3D.map_set_up(_map, Vector3.UP)
	NavigationServer3D.map_set_cell_size(_map, CELL_SIZE)
	NavigationServer3D.map_set_cell_height(_map, CELL_HEIGHT)
	NavigationServer3D.map_set_edge_connection_margin(_map, EDGE_CONNECTION_MARGIN)
	NavigationServer3D.map_set_use_edge_connections(_map, true)
	# D-016: with async iterations on, the map's own sync — rebuilding the polygon graph after a
	# region is added — runs off the main thread. This is a large part of why the measured
	# main-thread cost across a 24-chunk streaming episode was 0.034 ms.
	NavigationServer3D.map_set_use_async_iterations(_map, true)
	NavigationServer3D.map_set_active(_map, true)


func _release_map() -> void:
	for coord: Vector2i in _regions:
		NavigationServer3D.free_rid(_regions[coord]["region"] as RID)
	_regions.clear()
	_queue.clear()
	_in_flight.clear()
	if _owns_map and _map.is_valid():
		NavigationServer3D.free_rid(_map)
	_map = RID()
	_owns_map = false


## Same `_owns_*` shape as every other host-authoritative system in this codebase.
func _owns_navigation() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
