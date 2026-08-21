extends SceneTree

## Proof for task 4.5's runtime nav baking. D-016 already measured that this is affordable; this
## check exists to prove the SHIPPED code obeys the rules that measurement depends on, and to keep
## `ARCHITECTURE.md` §6's four silent traps proven rather than merely commented.
##
##   .agent/bin/agent godot --script tools/nav_bake_check.gd
##
## Every one of those traps fails with no error and no warning, so each gets an assertion that would
## go red if the behaviour ever changed — including a NEGATIVE control for the winding trap, because
## "our bake produced polygons" does not by itself prove we understood why.
const NavBakerScript = preload("res://world/chunk/nav_baker.gd")
const MesherScript = preload("res://world/chunk/chunk_mesher.gd")
const VALIDATOR = preload("res://systems/building/placement_validator.gd")

const BiomeMapScript = preload("res://world/gen/biome_map.gd")
const BiomeDefsLib := preload("res://tools/biome_defs_lib.gd")

const WORLD_SEED: int = 20260818

## The shipped biome table and the fields `_ground()` samples through — built once in `_run()`.
var _biome_defs: Array = []
var _noise_set: BiomeMapScript.NoiseSet
var _table: BiomeMapScript.TerrainTable
const SYNC_TIMEOUT_SEC: float = 10.0

## The agent this whole system is baked for. Terrain steeper than this is not walkable, so a test
## that lands on it proves nothing.
const WALKABLE_SLOPE_DEG: float = 30.0
const MIN_LAND_HEIGHT: float = 2.0

## Chunk coords are FOUND, not hard-coded, and that is a correction rather than a flourish. The first
## version of this check used (0,0)-(1,1) "near the island centre, where the heightmap is reliably
## above water" — which was simply wrong for this seed: those chunks are steep seabed at y = -4 to
## -15. Every seam assertion failed, and it took a slope census over the whole island (82.5% of LAND
## is walkable) to establish that the terrain was fine and the test's chunk picks were not. Locating
## real ground from the heightmap makes the check seed-independent and stops it from ever again
## reporting a terrain choice as a navigation bug.

var failures: int = 0
var baker: Node
var coords: Array[Vector2i] = []
## The vertical chunk boundary the seam test uses: world x, and a z on gentle land either side.
var seam_x: float = NAN
var seam_z: float = 0.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	_biome_defs = BiomeDefsLib.load_defs(self)
	_noise_set = BiomeMapScript.make_noise_set(WORLD_SEED)
	_table = BiomeMapScript.make_terrain_table(_biome_defs)
	check(not _biome_defs.is_empty(), "the shipped biome table loaded (%d def(s))"
		% _biome_defs.size())

	_locate_walkable_terrain()
	_check_winding_trap()
	await _check_bakes_and_attaches()
	await _check_map_queryable()
	_check_seam_rules()
	await _check_buildable_obstruction()
	await _check_retire()
	await _check_enemy_world_buildable_obstruction()

	if baker != null:
		baker.free()
	# The premature-query error is PROVOKED by design (F-193): trap 2's whole method is that only a
	# real query proves readiness, so the poll's first probes necessarily fire before the map's
	# first synchronization and the engine logs each one. Declaring it beats "fixing" it, because
	# the fix would be waiting on the exact signals trap 2 exists to distrust.
	print("\nNAV_BAKE_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"before first map synchronization\"" % failures)
	finish()


## Walks the heightmap for a vertical chunk boundary with gentle, above-water land on both sides,
## then takes that pair of chunks plus the two north of them as the bake set. Pure heightmap maths —
## no navigation involved — so a failure here means the ISLAND has nowhere walkable, which is a very
## different report from "navigation is broken".
func _locate_walkable_terrain() -> void:
	print("\n== locating real walkable ground to test on ==")
	for chunk_x: int in range(-8, 8):
		var boundary: float = float(chunk_x * 32 + 32)
		for z_step: int in range(-60, 61):
			var z: float = float(z_step * 4)
			if _gentle(boundary - 6.0, z) and _gentle(boundary - 2.0, z) \
					and _gentle(boundary + 2.0, z) and _gentle(boundary + 6.0, z):
				seam_x = boundary
				seam_z = z
				var chunk_z: int = int(floor(z / 32.0))
				coords = [
					Vector2i(chunk_x, chunk_z), Vector2i(chunk_x + 1, chunk_z),
					Vector2i(chunk_x, chunk_z + 1), Vector2i(chunk_x + 1, chunk_z + 1),
				]
				break
		if not is_nan(seam_x):
			break
	check(not is_nan(seam_x),
		"found a chunk boundary with walkable land on both sides: x=%.0f z=%.0f, chunks %s"
			% [seam_x, seam_z, coords])


## The SHIPPED ground at (x, z) — `BiomeMap.surface_from_set()`, the same surface the mesher builds
## the faces this navmesh is baked from (F-274). Bare `IslandHeightmap.height()` would be the
## biome-blind 1.0/1.0 surface, which on a forest ridge is metres away from the baked mesh, and
## every "is this point on the navmesh" assertion below would then be measuring the wrong point.
func _ground(x: float, z: float) -> float:
	return BiomeMapScript.surface_from_set(x, z, _noise_set, WORLD_SEED, _table)


func _gentle(x: float, z: float) -> bool:
	var height: float = _ground(x, z)
	if height < MIN_LAND_HEIGHT:
		return false
	var dx: float = _ground(x + 1.0, z) - height
	var dz: float = _ground(x, z + 1.0) - height
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz))) < WALKABLE_SLOPE_DEG


## §6 trap 1, both directions. The positive case (our real terrain bakes polygons) is necessary but
## not sufficient — it would also pass if we had the winding right by luck. The negative control is
## what proves the trap is real and that the flip in `_wound_for_recast` is doing something.
func _check_winding_trap() -> void:
	print("\n== trap 1: winding is inverted, and getting it wrong bakes silence ==")
	var mesh: ArrayMesh = MesherScript.build_mesh(
		coords[0].x, coords[0].y, WORLD_SEED, _biome_defs, 0)
	var faces: PackedVector3Array = MesherScript.collision_faces(mesh, 0)
	check(not faces.is_empty(), "the mesher produced collision faces to bake (%d)" % faces.size())

	var correct: NavigationMesh = _bake_blocking(faces, true)
	check(correct.get_polygon_count() > 0,
		"correctly-wound terrain bakes %d polygon(s)" % correct.get_polygon_count())

	var inverted: NavigationMesh = _bake_blocking(faces, false)
	check(inverted.get_polygon_count() == 0,
		"and the OPPOSITE winding bakes %d — success with zero polygons, exactly as §6 warns"
			% inverted.get_polygon_count())


## Blocking on purpose, and ONLY here: the shipped path never calls the sync form (D-016 measured it
## at 9.2 ms, 55% of a frame). A check that has to compare two bakes wants them finished.
func _bake_blocking(faces: PackedVector3Array, recast_winding: bool) -> NavigationMesh:
	var prepared := PackedVector3Array()
	prepared.resize(faces.size())
	for i: int in range(0, faces.size(), 3):
		var up_facing: bool = (faces[i + 1] - faces[i]).cross(faces[i + 2] - faces[i]).y < 0.0
		var flip: bool = up_facing != recast_winding
		prepared[i] = faces[i]
		prepared[i + 1] = faces[i + 2] if flip else faces[i + 1]
		prepared[i + 2] = faces[i + 1] if flip else faces[i + 2]

	var geometry := NavigationMeshSourceGeometryData3D.new()
	geometry.add_faces(prepared, Transform3D.IDENTITY)
	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = NavBakerScript.CELL_SIZE
	nav_mesh.cell_height = NavBakerScript.CELL_HEIGHT
	nav_mesh.agent_height = NavBakerScript.AGENT_HEIGHT
	nav_mesh.agent_radius = NavBakerScript.AGENT_RADIUS
	nav_mesh.agent_max_climb = NavBakerScript.AGENT_MAX_CLIMB
	nav_mesh.agent_max_slope = NavBakerScript.AGENT_MAX_SLOPE
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geometry)
	return nav_mesh


func _check_bakes_and_attaches() -> void:
	print("\n== chunks bake asynchronously, one at a time, and attach ==")
	baker = NavBakerScript.new()
	# Set BEFORE bind: `bind()` adopts the streamer's table (F-274) and this harness has no
	# streamer, so a baker left at the default would bake the biome-blind surface while every
	# assertion below probes the real one.
	baker.set(&"biome_defs", _biome_defs)
	root.add_child(baker)
	# force_active: this harness has no session, and `bind()` is a no-op on a non-host by design.
	check(bool(baker.call("bind", null, WORLD_SEED, true)), "baker binds")

	for coord: Vector2i in coords:
		baker.call("request_bake", coord)

	# D-016's queue rule. Four requests submitted in one go must not become four concurrent bakes —
	# 16 in one frame blocked 6.8 ms, and the whole 0.034 ms budget depends on this staying serial.
	check(int(baker.call("pending_bake_count")) == coords.size(),
		"all %d requests are tracked" % coords.size())

	var settled: bool = await _until(func() -> bool:
		return int(baker.call("pending_bake_count")) == 0, SYNC_TIMEOUT_SEC)
	check(settled, "every queued bake finished (%d still pending)" % baker.call("pending_bake_count"))
	check(int(baker.call("region_count")) == coords.size(),
		"all %d chunks attached a region (%d)" % [coords.size(), baker.call("region_count")])


## §6 trap 2: neither `map_force_update()` nor `map_get_iteration_id()` tells the truth about
## readiness. The only honest test is whether a real query answers, which is what `is_queryable()`
## does — so this asserts against real queries too, not against the helper alone.
func _check_map_queryable() -> void:
	print("\n== trap 2: the map is only ready when a real query answers ==")
	var ready: bool = await _until(func() -> bool: return bool(baker.call("is_queryable")),
		SYNC_TIMEOUT_SEC)
	check(ready, "the map became queryable within %ds" % SYNC_TIMEOUT_SEC)
	if not ready:
		return

	var map: RID = baker.call("map_rid")
	var centre: Vector3 = Vector3(seam_x - 6.0,
		_ground(seam_x - 6.0, seam_z), seam_z)
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(map, centre)
	check(closest != Vector3.ZERO, "a point on located land resolves onto the mesh (%s)" % closest)

	# THE seam test, and the reason D-016's edge-connection-margin finding exists. Independent
	# per-chunk bakes leave a hole exactly 2 x agent_radius wide at every boundary; the default
	# 0.25 m margin cannot bridge it and an agent simply cannot cross. Both endpoints are snapped
	# on-mesh first and then asserted to be on OPPOSITE sides of the boundary — without that check
	# the pair can silently snap to the same side and the test proves nothing.
	var left: Vector3 = NavigationServer3D.map_get_closest_point(map,
		Vector3(seam_x - 6.0, _ground(seam_x - 6.0, seam_z), seam_z))
	var right: Vector3 = NavigationServer3D.map_get_closest_point(map,
		Vector3(seam_x + 6.0, _ground(seam_x + 6.0, seam_z), seam_z))
	var crosses: bool = signf(left.x - seam_x) != signf(right.x - seam_x)
	check(crosses, "the two endpoints really are on opposite sides of x=%.0f (%.1f | %.1f)"
		% [seam_x, left.x, right.x])
	if not crosses:
		return

	var path: PackedVector3Array = NavigationServer3D.map_get_path(map, left, right, true)
	check(path.size() >= 2, "a path exists across the chunk boundary (%d waypoints)" % path.size())
	if path.size() >= 2:
		var arrived: float = path[path.size() - 1].distance_to(right)
		check(arrived < 0.5,
			"and it ARRIVES — %.3fm from the target, so the seam is genuinely connected" % arrived)


## The three constants D-016 fixed by measurement. Asserted as VALUES, because the failure mode for
## each is silent and the next person to "tidy" one will not have re-run the spike.
func _check_seam_rules() -> void:
	print("\n== D-016's measured constants are still what shipped ==")
	check(NavBakerScript.EDGE_CONNECTION_MARGIN > 2.0 * NavBakerScript.AGENT_RADIUS,
		"edge connection margin (%.2f) exceeds 2 x agent radius (%.2f) — the seam fix"
			% [NavBakerScript.EDGE_CONNECTION_MARGIN, 2.0 * NavBakerScript.AGENT_RADIUS])
	check(is_equal_approx(NavBakerScript.CELL_SIZE, 0.25),
		"cell size is still 0.25 m — scaling is steeply superlinear, 0.1 m cost 80.7 ms/chunk")
	check(NavBakerScript.MAX_BAKES_IN_FLIGHT == 1,
		"one bake in flight at a time — 16 in one frame blocked 6.8 ms")

	# §6 trap 3: a region's cell size must equal the map's, or edges rasterize onto different grids.
	# One constant feeds both in nav_baker.gd; this is the assertion that keeps it that way.
	var map: RID = baker.call("map_rid")
	check(is_equal_approx(NavigationServer3D.map_get_cell_size(map), NavBakerScript.CELL_SIZE),
		"trap 3: the map's cell size matches the region meshes' (%.3f)"
			% NavigationServer3D.map_get_cell_size(map))
	check(is_equal_approx(
		NavigationServer3D.map_get_edge_connection_margin(map),
		NavBakerScript.EDGE_CONNECTION_MARGIN),
		"the map actually received the wide margin")


## F-159: a placed buildable is a real physics collider the terrain-only source geometry never saw,
## so `NavigationAgent3D` steering drove straight through a wall or a Ward. Proof, not just "a signal
## fired": query a point that is real, on-mesh, walkable ground BEFORE a piece exists there, place a
## real registered piece (`ward`, content/buildables/ward.tres) with its centre exactly on that
## point, and assert the SAME query now resolves MEASURABLY farther away — the exact spot the
## pathfinder used to think was open ground is no longer part of the mesh. Then destroy it and assert
## the query comes back close to its own baseline, proving the fix does not just add cruft that never
## clears. Baseline is measured, not assumed zero: an analytic heightmap point is not necessarily ON
## the baked mesh's own vertex grid, so `map_get_closest_point` can legitimately snap half a metre or
## more away from it before any piece is involved — asserting a fixed small tolerance here would be
## exactly the kind of silent-trap test this file otherwise warns against.
func _check_buildable_obstruction() -> void:
	print("\n== F-159: a placed piece carves the navmesh, a destroyed one un-carves it ==")
	var map: RID = baker.call("map_rid")
	var spot: Vector3 = Vector3(seam_x - 6.0,
		_ground(seam_x - 6.0, seam_z), seam_z)
	var baseline: float = NavigationServer3D.map_get_closest_point(map, spot).distance_to(spot)
	print("   baseline snap distance at %s: %.3fm" % [spot, baseline])

	# Must be inside the tree: Node3D.global_position/global_rotation error (and silently read as
	# zero) on an orphan node, which is exactly the kind of failure that would have made this check
	# pass for the wrong reason — the piece tracked at the WORLD ORIGIN instead of `spot`.
	var piece := Node3D.new()
	piece.name = "F159TestWard"
	root.add_child(piece)
	piece.global_position = spot
	piece.global_rotation.y = 0.0
	var piece_name: StringName = StringName(piece.name)

	baker.call("_on_piece_placed", piece, &"ward", 1)
	check(int(baker.call("tracked_piece_count")) == 1, "the piece is tracked")

	# Poll the real query, not just bake-queue drain: map_set_use_async_iterations(true) means the
	# server's own polygon graph sync can lag a frame or two behind _attach() returning — §6 trap 2
	# again, same reason is_queryable() polls rather than trusts a flag.
	var pushed_away: bool = await _until(func() -> bool:
		return NavigationServer3D.map_get_closest_point(map, spot).distance_to(spot) > baseline + 1.0,
		SYNC_TIMEOUT_SEC)
	check(pushed_away,
		"placing a piece dead centre on that spot pushes the closest walkable point measurably "
		+ "farther away (%.3fm, baseline %.3fm)"
			% [NavigationServer3D.map_get_closest_point(map, spot).distance_to(spot), baseline])

	baker.call("_on_piece_destroyed", &"ward", 1, piece_name, spot)
	check(int(baker.call("tracked_piece_count")) == 0, "destroying it un-tracks it")

	var restored: bool = await _until(func() -> bool:
		return NavigationServer3D.map_get_closest_point(map, spot).distance_to(spot) < baseline + 0.3,
		SYNC_TIMEOUT_SEC)
	check(restored, "and the spot returns close to its own baseline (%.3fm, baseline %.3fm)"
		% [NavigationServer3D.map_get_closest_point(map, spot).distance_to(spot), baseline])

	root.remove_child(piece)
	piece.free()


func _check_retire() -> void:
	print("\n== an unloaded chunk loses its region ==")
	var before: int = int(baker.call("region_count"))
	baker.call("_on_chunk_unloaded", coords[0])
	check(int(baker.call("region_count")) == before - 1,
		"unloading a chunk retires its region (%d -> %d)" % [before, baker.call("region_count")])
	check(not bool(baker.call("has_region", coords[0])), "and it is gone from the directory")

	# A chunk that drops to a coarser LOD is not "still fine" — its region would describe terrain the
	# streamer is no longer rendering or colliding at that resolution.
	baker.call("_on_chunk_mesh_ready", coords[1], 1)
	check(not bool(baker.call("has_region", coords[1])),
		"a chunk demoted below LOD0 also loses its region")


## F-177: `EnemyWorld.bake_navigation()` is the LIVE nav baker — the one a real session bootstraps
## at start and `BuildService._request_nav_rebake()` re-triggers on every placement/destroy
## (docs/DECISIONS.md D-118). Only `NavBaker` (task 4.5, unreachable in the live game per F-139) got
## F-159's original fix; this proves the same fix now also lands where the live game actually calls
## in. A REAL `BuildService.request_place()`, not a synthetic body dropped by hand — build_check.gd
## already proved that round trip works, this proves the SIDE EFFECT of it (a rebaked live navmesh)
## now actually happens. A placed piece's container lives under the `BuildService` autoload
## (`/root/BuildService/Buildings`), a SIBLING of the level under `/root`, never a descendant of
## `current_scene` — the bug was never "the bake can't see solid geometry", it never walked into the
## container that holds it.
##
## Proof is a PATH, not a point-snap distance: `map_get_closest_point()` at the piece's own centre
## is unreliable evidence here, and provably so, not just cautiously avoided — a piece resting flush
## on a perfectly flat floor (the simplest, most controllable test fixture) hits a Recast/Godot
## rasterization quirk where the piece's coincident-height bottom face and the floor's top can leave
## a tiny disconnected "island" polygon surviving at the exact centre, which a nearest-point query
## snaps onto despite it having no edge shared with anything else on the map (confirmed with a direct
## polygon dump: probed both through `parse_source_geometry_data()` walking the scene tree, as this
## file does, AND through a single-object combined parse the way NavBaker builds its own source data
## — same island either way, so it is a property of the geometry, not of how the fix merges data).
## `NavigationServer3D.map_get_path()` sidesteps it cleanly: pathfinding only ever walks CONNECTED
## polygon edges, so a disconnected island cannot be routed through even where it can be snapped
## onto, and a path from one side of the piece to the other is the thing this fix actually needs to
## be true for an enemy in the live game.
func _check_enemy_world_buildable_obstruction() -> void:
	print("\n== F-177: EnemyWorld.bake_navigation() (the LIVE baker) also sees a placed buildable ==")

	# F-351: `EnemyWorld.bake_navigation()` now declines when a `NavBaker` owns the level, because on
	# a streamed island baking here would only produce a stale rival to the regions the baker is
	# already maintaining per chunk. This section tests the OTHER world shape — an authored level
	# with no baker, where EnemyWorld is the only nav baker there is — so the standalone baker every
	# section above drove has to be gone before it starts, not merely unused. Every one of those
	# sections is finished with it (its last use is `_check_retire()`), and `_exit_tree()` takes it
	# back out of the owner group as it goes.
	if baker != null:
		baker.free()
		baker = null
		await process_frame

	var enemy_world: Node = root.get_node_or_null(^"EnemyWorld")
	var build_service: Node = root.get_node_or_null(^"BuildService")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(enemy_world != null and build_service != null and inventory != null,
		"EnemyWorld, BuildService and InventoryService are all registered autoloads")
	if enemy_world == null or build_service == null or inventory == null:
		return

	# A flat synthetic floor, same shape as build_check.gd's own `_build_world()` fixture — plenty
	# of clear, gentle ground on every side of the piece for the validator's support probes to find,
	# which real heightmap terrain at any one spot is not guaranteed to offer (this seed's is hilly
	# enough that a 2.4 m Ward footprint routinely fails support well before it fails slope).
	var level := Node3D.new()
	level.name = "F177TestLevel"
	root.add_child(level)
	current_scene = level

	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = VALIDATOR.TERRAIN_LAYER  # F-082's ground-support layer
	floor_body.position = Vector3(300.0, -0.5, 300.0)
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(20.0, 1.0, 20.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	level.add_child(floor_body)
	# A freshly-added collider needs the physics server to sync before a space-state query (the
	# validator's support probe, below) can see it — build_check.gd's own `_build_world()` waits the
	# same two physics frames for the same reason.
	await physics_frame
	await physics_frame

	var spot := Vector3(300.0, 0.0, 300.0)

	enemy_world.call(&"bake_navigation")
	var region: NavigationRegion3D = enemy_world.call(&"nav_region") as NavigationRegion3D
	check(region != null, "the live baker attaches a NavigationRegion3D")
	if region == null:
		return
	var map: RID = region.get_navigation_map()

	var queryable: bool = await _until(
		func() -> bool: return NavigationServer3D.map_get_closest_point(map, spot) != Vector3.ZERO,
		SYNC_TIMEOUT_SEC)
	check(queryable, "the terrain-only bake is queryable at the test spot")
	if not queryable:
		return

	# Two points either side of where the piece is about to go — snapped onto the mesh FIRST, so
	# comparing before/after lengths is not itself contaminated by the piece nudging where either
	# endpoint snaps.
	var left: Vector3 = NavigationServer3D.map_get_closest_point(map, spot + Vector3(-3.0, 0.0, 0.0))
	var right: Vector3 = NavigationServer3D.map_get_closest_point(map, spot + Vector3(3.0, 0.0, 0.0))
	var path_before: PackedVector3Array = NavigationServer3D.map_get_path(map, left, right, true)
	var len_before: float = _path_length(path_before)
	check(path_before.size() >= 2 and is_equal_approx(len_before, left.distance_to(right)),
		"before any piece exists, the path from one side to the other is the straight line (%.3fm)"
			% len_before)

	var confirmations: Array[Dictionary] = []
	var on_confirmed := func(request_id: int, accepted: bool, reason: String) -> void:
		confirmations.append({"request_id": request_id, "accepted": accepted, "reason": reason})
	build_service.connect(&"build_confirmed", on_confirmed)

	# `ward` (content/buildables/ward.tres): a real registered piece with a real authored scene
	# (`scenes/buildables/ward.tscn`, a `StaticBody3D` + `BoxShape3D`), not a generated stand-in —
	# the same fixture F-159's own NavBaker check above already uses. Same host-of-one shape
	# build_check.gd's own `_check_host_placement()` already proved: fund the cost, then place for
	# real through the real request/host-decides round trip.
	inventory.call(&"host_transaction", 1, {} as Dictionary,
		{&"log": 10, &"stone": 8, &"iron_ingot": 2} as Dictionary)
	build_service.call(&"request_place", &"ward", Transform3D(Basis(), spot))
	await process_frame
	check(confirmations.size() == 1 and bool(confirmations[0]["accepted"]),
		"a real BuildService.request_place() dead centre on the test spot is accepted (%s)"
			% (String(confirmations[0]["reason"]) if confirmations.size() == 1 else "no confirmation"))
	check(int(build_service.call(&"placed_count")) == 1, "and exactly one piece exists")

	enemy_world.call(&"bake_navigation")
	var detoured: bool = await _until(func() -> bool:
		var path: PackedVector3Array = NavigationServer3D.map_get_path(map, left, right, true)
		return path.size() > 2 and _path_length(path) > len_before + 1.0,
		SYNC_TIMEOUT_SEC)
	var path_after: PackedVector3Array = NavigationServer3D.map_get_path(map, left, right, true)
	check(detoured,
		("re-baking after a REAL host placement forces the same path to detour around it (%.3fm, was "
			+ "%.3fm straight, %d waypoints) — the live baker now sees BuildService's own placed pieces")
			% [_path_length(path_after), len_before, path_after.size()])

	var pieces: Array = get_nodes_in_group(&"buildable_piece")
	check(pieces.size() == 1, "the piece is findable through its usual group")
	if not pieces.is_empty():
		var piece_name := StringName((pieces[0] as Node).name)
		build_service.call(&"request_destroy", piece_name)
		await process_frame
		enemy_world.call(&"bake_navigation")
		var restored: bool = await _until(func() -> bool:
			var path: PackedVector3Array = NavigationServer3D.map_get_path(map, left, right, true)
			return is_equal_approx(_path_length(path), len_before),
			SYNC_TIMEOUT_SEC)
		check(restored, "and destroying it un-carves the path back to a straight line (%.3fm, was %.3fm)"
			% [_path_length(NavigationServer3D.map_get_path(map, left, right, true)), len_before])

	build_service.disconnect(&"build_confirmed", on_confirmed)


func _path_length(path: PackedVector3Array) -> float:
	var total: float = 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
