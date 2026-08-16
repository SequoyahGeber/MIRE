extends RefCounted

## SPIKE R3 probe — throwaway. Answers one question with numbers:
## can we bake navigation on runtime-generated terrain chunks without a visible hitch,
## and do adjacent chunks actually connect across the seam?
##
## Deliberately self-contained — it generates its own analytic heightmap and does NOT
## depend on world/chunk/chunk_mesher.gd. The shipping pipeline would feed the mesher's
## ArrayMesh in through `add_mesh()` instead of `add_faces()`; the bake cost is the same.
##
## Every API used here was verified against the Godot 4.7.1 class reference (--doctool),
## because the navigation API moved repeatedly across 4.x:
##   NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geom, callback)
##   NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, geom, callback)
##   NavigationServer3D.is_baking_navigation_mesh(nav_mesh) -> bool
##   NavigationServer3D.region_get_connections_count(region) -> int
##   NavigationMeshSourceGeometryData3D.add_faces(faces: PackedVector3Array, xform)

const CHUNK_SIZE: float = 32.0
const TERRAIN_STEP: float = 1.0     # 1 m terrain grid, same spacing as the R2 mesher
const DEFAULT_CELL_SIZE: float = 0.25
const DEFAULT_CELL_HEIGHT: float = 0.25
const DEFAULT_AGENT_RADIUS: float = 0.5


# --- terrain -------------------------------------------------------------------------

## Analytic, continuous everywhere, so chunks tile with no crack at the seam and no seed
## plumbing. Max gradient ~0.77 (about 38 deg) — genuinely sloped, still under the 45 deg
## walkable limit, so the seam result is not muddied by unwalkable strips.
static func height_at(wx: float, wz: float) -> float:
	return (
		3.0 * sin(wx * 0.15) * cos(wz * 0.13)
		+ 0.6 * sin((wx + wz) * 0.4)
		+ 1.2 * cos(wx * 0.07 - wz * 0.05)
	)


## Triangle soup for a square terrain patch, in coordinates LOCAL to (world_ox, world_oz).
## Local x/z run from `lo` to `lo + span`. Heights are always sampled in world space, so
## two neighbouring patches agree exactly along their shared edge.
static func build_faces(
	world_ox: float, world_oz: float, lo: float, span: float, step: float
) -> PackedVector3Array:
	var n: int = int(round(span / step))
	var faces: PackedVector3Array = PackedVector3Array()
	faces.resize(n * n * 6)
	var i: int = 0
	for gz: int in n:
		var z0: float = lo + float(gz) * step
		var z1: float = z0 + step
		for gx: int in n:
			var x0: float = lo + float(gx) * step
			var x1: float = x0 + step
			var v00: Vector3 = Vector3(x0, height_at(world_ox + x0, world_oz + z0), z0)
			var v10: Vector3 = Vector3(x1, height_at(world_ox + x1, world_oz + z0), z0)
			var v01: Vector3 = Vector3(x0, height_at(world_ox + x0, world_oz + z1), z1)
			var v11: Vector3 = Vector3(x1, height_at(world_ox + x1, world_oz + z1), z1)
			# WINDING MATTERS AND FAILS SILENTLY. Godot's Recast bridge treats a triangle as
			# up-facing when cross(v1-v0, v2-v0).y is NEGATIVE — the opposite of the usual
			# right-handed convention. Get it backwards and the bake reports success and
			# produces zero polygons, with no error. Verified empirically on 4.7.1.
			faces[i] = v11
			faces[i + 1] = v01
			faces[i + 2] = v00
			faces[i + 3] = v10
			faces[i + 4] = v11
			faces[i + 5] = v00
			i += 6
	return faces


## One chunk's terrain, local to the chunk origin. `overlap_m` pulls in the neighbours'
## terrain on all four sides — a streaming world already has that heightmap, so it is free.
## Overlap is what stops agent-radius erosion from eating a gap at the chunk boundary.
static func chunk_faces(chunk_x: int, chunk_z: int, overlap_m: float = 0.0) -> PackedVector3Array:
	return build_faces(
		float(chunk_x) * CHUNK_SIZE,
		float(chunk_z) * CHUNK_SIZE,
		-overlap_m,
		CHUNK_SIZE + 2.0 * overlap_m,
		TERRAIN_STEP,
	)


# --- bake inputs ---------------------------------------------------------------------

static func make_source_geometry(
	chunk_x: int, chunk_z: int, overlap_m: float = 0.0
) -> NavigationMeshSourceGeometryData3D:
	var geom: NavigationMeshSourceGeometryData3D = NavigationMeshSourceGeometryData3D.new()
	geom.add_faces(chunk_faces(chunk_x, chunk_z, overlap_m), Transform3D.IDENTITY)
	return geom


## Source geometry for an N-chunk-square region, still one bake. Used to price the
## "bake a bigger region less often" mitigation.
static func make_region_source_geometry(chunks_per_side: int) -> NavigationMeshSourceGeometryData3D:
	var geom: NavigationMeshSourceGeometryData3D = NavigationMeshSourceGeometryData3D.new()
	geom.add_faces(
		build_faces(0.0, 0.0, 0.0, CHUNK_SIZE * float(chunks_per_side), TERRAIN_STEP),
		Transform3D.IDENTITY,
	)
	return geom


## `clip_span_m > 0` sets filter_baking_aabb so the baked mesh is trimmed back to exactly
## the chunk footprint after being baked with the neighbours' terrain included.
static func make_nav_mesh(
	cell_size: float = DEFAULT_CELL_SIZE,
	agent_radius: float = DEFAULT_AGENT_RADIUS,
	clip_span_m: float = 0.0,
	border_size: float = 0.0,
) -> NavigationMesh:
	var nm: NavigationMesh = NavigationMesh.new()
	nm.cell_size = cell_size
	nm.cell_height = DEFAULT_CELL_HEIGHT
	nm.agent_height = 1.75      # a whole number of cell_height voxels, else Godot warns
	nm.agent_radius = agent_radius
	nm.agent_max_climb = 0.5
	nm.agent_max_slope = 45.0
	nm.border_size = border_size
	if clip_span_m > 0.0:
		nm.filter_baking_aabb = AABB(
			Vector3(0.0, -500.0, 0.0), Vector3(clip_span_m, 1000.0, clip_span_m)
		)
	return nm


# --- baking --------------------------------------------------------------------------

## Blocking bake. Returns milliseconds spent on the calling thread — all of them.
static func bake_sync(nav_mesh: NavigationMesh, geom: NavigationMeshSourceGeometryData3D) -> float:
	var t0: int = Time.get_ticks_usec()
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geom)
	return float(Time.get_ticks_usec() - t0) / 1000.0


## Threaded bake. Returns the ms the SUBMITTING thread spends inside the call — i.e. the
## part of an "async" bake that is not actually async, and therefore still a hitch.
## `on_done` is invoked (deferred, main thread) when the bake finishes.
static func bake_async(
	nav_mesh: NavigationMesh, geom: NavigationMeshSourceGeometryData3D, on_done: Callable = Callable()
) -> float:
	var t0: int = Time.get_ticks_usec()
	NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, geom, on_done)
	return float(Time.get_ticks_usec() - t0) / 1000.0


static func is_baking(nav_mesh: NavigationMesh) -> bool:
	return NavigationServer3D.is_baking_navigation_mesh(nav_mesh)


# --- map / regions -------------------------------------------------------------------

## NOTE: a region's NavigationMesh.cell_size must match the map's cell size or the server
## snaps region edges to different grids and refuses to connect them. Kept as one knob.
##
## `async_iterations` is new in 4.x and directly relevant to hitching: with it on, the map's
## own sync (rebuilding the polygon graph after a region is added) runs off the main thread.
static func make_map(
	cell_size: float = DEFAULT_CELL_SIZE,
	edge_margin: float = 0.25,
	async_iterations: bool = true,
) -> RID:
	var map: RID = NavigationServer3D.map_create()
	NavigationServer3D.map_set_up(map, Vector3.UP)
	NavigationServer3D.map_set_cell_size(map, cell_size)
	NavigationServer3D.map_set_cell_height(map, DEFAULT_CELL_HEIGHT)
	NavigationServer3D.map_set_edge_connection_margin(map, edge_margin)
	NavigationServer3D.map_set_use_edge_connections(map, true)
	NavigationServer3D.map_set_use_async_iterations(map, async_iterations)
	NavigationServer3D.map_set_active(map, true)
	return map


static func add_region(map: RID, nav_mesh: NavigationMesh, origin: Vector3) -> RID:
	var region: RID = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region, map)
	NavigationServer3D.region_set_transform(region, Transform3D(Basis.IDENTITY, origin))
	NavigationServer3D.region_set_use_edge_connections(region, true)
	NavigationServer3D.region_set_navigation_mesh(region, nav_mesh)
	return region


# --- inspection ----------------------------------------------------------------------

## Local-space X extent of the baked polygons. This is the number that decides whether a
## seam closes: if chunk A ends at 31.5 and chunk B starts at 0.5, there is a 1 m hole.
static func extent_x(nav_mesh: NavigationMesh) -> Vector2:
	var verts: PackedVector3Array = nav_mesh.get_vertices()
	if verts.is_empty():
		return Vector2(NAN, NAN)
	var lo: float = INF
	var hi: float = -INF
	for v: Vector3 in verts:
		lo = minf(lo, v.x)
		hi = maxf(hi, v.x)
	return Vector2(lo, hi)
