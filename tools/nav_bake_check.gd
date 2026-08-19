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

const HeightmapScript = preload("res://world/gen/island_heightmap.gd")

const WORLD_SEED: int = 20260818
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

	_locate_walkable_terrain()
	_check_winding_trap()
	await _check_bakes_and_attaches()
	await _check_map_queryable()
	_check_seam_rules()
	await _check_retire()

	if baker != null:
		baker.free()
	print("\nNAV_BAKE_CHECK failures=%d" % failures)
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


func _gentle(x: float, z: float) -> bool:
	var height: float = HeightmapScript.height(x, z, WORLD_SEED)
	if height < MIN_LAND_HEIGHT:
		return false
	var dx: float = HeightmapScript.height(x + 1.0, z, WORLD_SEED) - height
	var dz: float = HeightmapScript.height(x, z + 1.0, WORLD_SEED) - height
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz))) < WALKABLE_SLOPE_DEG


## §6 trap 1, both directions. The positive case (our real terrain bakes polygons) is necessary but
## not sufficient — it would also pass if we had the winding right by luck. The negative control is
## what proves the trap is real and that the flip in `_wound_for_recast` is doing something.
func _check_winding_trap() -> void:
	print("\n== trap 1: winding is inverted, and getting it wrong bakes silence ==")
	var mesh: ArrayMesh = MesherScript.build_mesh(coords[0].x, coords[0].y, WORLD_SEED, 0)
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
		HeightmapScript.height(seam_x - 6.0, seam_z, WORLD_SEED), seam_z)
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(map, centre)
	check(closest != Vector3.ZERO, "a point on located land resolves onto the mesh (%s)" % closest)

	# THE seam test, and the reason D-016's edge-connection-margin finding exists. Independent
	# per-chunk bakes leave a hole exactly 2 x agent_radius wide at every boundary; the default
	# 0.25 m margin cannot bridge it and an agent simply cannot cross. Both endpoints are snapped
	# on-mesh first and then asserted to be on OPPOSITE sides of the boundary — without that check
	# the pair can silently snap to the same side and the test proves nothing.
	var left: Vector3 = NavigationServer3D.map_get_closest_point(map,
		Vector3(seam_x - 6.0, HeightmapScript.height(seam_x - 6.0, seam_z, WORLD_SEED), seam_z))
	var right: Vector3 = NavigationServer3D.map_get_closest_point(map,
		Vector3(seam_x + 6.0, HeightmapScript.height(seam_x + 6.0, seam_z, WORLD_SEED), seam_z))
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
