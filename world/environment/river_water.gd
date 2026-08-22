class_name RiverWater
extends Node3D

## F-478 — the water in the procedural island's river.
##
## `IslandHeightmap` has carved a river across every island since task 4.14 (D-142), and F-372 and
## F-464 spent two passes getting its banks and its gorges right. Nothing ever put water in it.
## `levels/procedural_island.tscn` draws one water mesh — the 1400 m Ocean plane at y = 0 — and the
## channel bed only drops under y = 0 in the last fifth of its run, so the other four fifths were a
## dry rock cut with a beach on the floor. Sequoyah, looking at a play capture of exactly that:
## "if we have a river i feel like there should prolly be water inside".
##
## This node is that water: one flat-shaded sheet, in the same material as the ocean, following the
## channel from the source down to where it merges with the sea.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — VFX/presentation. Every vertex is a pure
## function of `world_seed` through `IslandHeightmap`, so all peers build the same sheet without
## anybody sending anything, and the wave motion on top of it is the shader's own TIME term, which
## peers are free to disagree about. The GAMEPLAY water level is not this mesh: it is
## `ProceduralWorld.water_surface_at()`, which reads the same `IslandHeightmap.river_water_level()`
## this does, so what you see and what you wade in are one fact rather than two.
##
## WHY A MARCHED GRID AND NOT A RIBBON. The obvious build is a triangle strip walked along the
## river's polyline. It cannot be done here: the polyline lives in BENT space (see
## `IslandHeightmap.bend()`), the warp that bends world into it is a noise field, and there is no
## inverse — so there is no way to ask "what world position is this station of the river at". The
## grid inverts the question instead. It marches WORLD space and asks each sample whether it is in
## the channel, which is the one direction the warp goes.
##
## The march is bounded, and the bound is the reason it is affordable at all. A point can only be
## in the channel if its BENT position is within the corridor of the polyline, and bending moves a
## point by at most `SHAPE_WARP_AMPLITUDE` on each axis — so any world point in the water is within
## `corridor + amplitude * sqrt(2)` of the polyline measured in world coordinates, and that test is
## three segment projections with no noise sampled at all. Only points that pass it pay for a bend,
## and only points that pass THAT pay for a terrain height. See the staging comment in `build()`.
##
## CLIPPED TO THE GROUND, like `AuthoredWorld._build_water()`: a quad exists where the ground is
## under the water level, so the sheet's edge is the waterline itself rather than a fixed width that
## has to be buried in the bank to hide it. The first version did use a fixed width, and the check
## found what a fixed width cannot know — reaches where the bank beside the channel dips below the
## level, and below-sea basins where the sheet stood two thirds of a metre above the ocean covering
## the same ground.

const IslandHeightmapScript := preload("res://world/gen/island_heightmap.gd")
const BiomeMapScript := preload("res://world/gen/biome_map.gd")
const WATER_SHADER := preload("res://world/environment/water_low_poly.gdshader")

## Metres per grid cell. The narrowest the sheet ever gets is about 9.5 m across, at the source
## where the channel is 3 m wide — five cells, which is enough for a faceted surface to read as a
## surface rather than as a ribbon of two triangles. Halving it quadruples a build that is already
## the most expensive thing in this file for detail no one can see through 0.18 m of wave.
const CELL_M: float = 2.0

## Set before `build()`. Not an `@export`: this node is constructed by `ProceduralWorld`, which is
## the only thing that knows the run seed.
var world_seed: int = 0
## `Registry.biomes.values()`, handed down by `ProceduralWorld` the same way it hands them to
## `ChunkStreamer` — F-274's rule that the mesh, the collider, the navmesh and this all read ONE
## terrain table, because the whole point of the clip below is that the water agrees with the ground
## the player is standing on. Empty is legal and means the biome-blind surface, which is what a
## headless harness with no Registry gets.
var biome_defs: Array = []

## How many quads the sheet ended up with. Read by `tools/river_water_check.gd`; a zero here on a
## seed whose polyline is well-formed means the water never got built, which is the whole defect.
var quads: int = 0
## The sheet's own vertical extent, for a check that wants to assert the water never climbed.
var level_min: float = INF
var level_max: float = -INF


## Builds the sheet. Separate from `_ready()` so the caller sets `world_seed` first and so a check
## can build one without a scene tree around it.
func build() -> void:
	var set: IslandHeightmap.NoiseSet = IslandHeightmapScript.make_noise_set(world_seed)
	var line: PackedVector2Array = IslandHeightmapScript.river_polyline(world_seed)
	if line.size() < 2:
		return

	# The world-space bound derived in the header comment. `RIVER_WIDTH_MOUTH` is the widest the
	# channel ever is, so its corridor is the widest the water can be anywhere on the line.
	var reach_m: float = IslandHeightmapScript.RIVER_WIDTH_MOUTH \
		* IslandHeightmapScript.RIVER_WATER_REACH
	var margin: float = reach_m + IslandHeightmapScript.SHAPE_WARP_AMPLITUDE * sqrt(2.0)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for point: Vector2 in line:
		lo = lo.min(point)
		hi = hi.max(point)
	lo -= Vector2(margin, margin)
	hi += Vector2(margin, margin)

	var nx: int = int(ceil((hi.x - lo.x) / CELL_M)) + 1
	var nz: int = int(ceil((hi.y - lo.y) / CELL_M)) + 1
	if nx < 2 or nz < 2:
		return

	# One pass over the grid VERTICES first, then one over the cells between them. Sampling per
	# cell instead would sample every interior point four times, and the samples are the whole cost.
	#
	# THREE STAGES, cheapest first, and the ordering is what makes this affordable. Stage 1 is the
	# polyline gate above — no noise at all, and nearly every point in the bounding box dies there.
	# Stage 2 bends the survivor and tests the corridor: two noise samples, and it culls the wide
	# warp margin down to the channel. Only stage 3 pays for a full terrain surface, on the ~10k
	# points that are actually over the channel, which is the difference between a tenth of a second
	# and several.
	var biome_set: BiomeMap.NoiseSet = BiomeMapScript.make_noise_set(world_seed, set)
	var table: BiomeMap.TerrainTable = BiomeMapScript.make_terrain_table(biome_defs)
	# Reused across every sample, exactly as `ChunkMesher` reuses one per chunk — this is the
	# allocation-free form `surface_from_set()` documents.
	var shape: IslandHeightmap.Shape = IslandHeightmap.Shape.new()
	var levels := PackedFloat32Array()
	levels.resize(nx * nz)
	var margin_sq: float = margin * margin
	for iz in nz:
		for ix in nx:
			var here := Vector2(lo.x + ix * CELL_M, lo.y + iz * CELL_M)
			var level: float = -INF
			if _distance_sq_to_line(here, line) <= margin_sq:
				var bent: Vector2 = IslandHeightmapScript.bend_from_set(here.x, here.y, set)
				if IslandHeightmapScript.river_water_band_on(line, bent).x >= 0.0:
					var ground: float = BiomeMapScript.surface_from_set(
						here.x, here.y, biome_set, world_seed, table, shape)
					level = IslandHeightmapScript.river_water_level_on(line, shape, ground)
			levels[iz * nx + ix] = level

	var vertices := PackedVector3Array()
	for iz in nz - 1:
		for ix in nx - 1:
			var corners: Array[int] = [
				iz * nx + ix, iz * nx + ix + 1, (iz + 1) * nx + ix + 1, (iz + 1) * nx + ix
			]
			# Emitted when ANY corner has water, exactly as `AuthoredWorld._build_water()` does and
			# for the same reason: requiring all four is what leaves a gap between the sheet and the
			# bank it is supposed to meet, because the quads that straddle the waterline are
			# precisely the ones that draw it. The overhang past the true waterline is at most one
			# cell and is under the bank, because the bank is above the water — that is exactly what
			# made the dry corner dry.
			var top: float = -INF
			for index: int in corners:
				top = maxf(top, levels[index])
			if top == -INF:
				continue
			var points: Array[Vector3] = []
			for slot in 4:
				var index: int = corners[slot]
				var level: float = levels[index]
				points.append(Vector3(
					lo.x + (ix + (1 if slot == 1 or slot == 2 else 0)) * CELL_M,
					top if level == -INF else level,
					lo.y + (iz + (1 if slot >= 2 else 0)) * CELL_M
				))
			for triangle: Array in [[0, 1, 2], [0, 2, 3]]:
				for slot: int in triangle:
					vertices.append(points[slot])
			quads += 1
			level_min = minf(level_min, top)
			level_max = maxf(level_max, top)

	if vertices.is_empty():
		return

	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	# The SAME shader the ocean uses, with no parameters overridden. That is deliberate and it is
	# not laziness: the wave phase in `water_low_poly.gdshader` is driven by WORLD position, so an
	# identical material makes the river's surface and the sea's continuous across the estuary,
	# where the two sheets are both at exactly y = 0 and sit edge to edge. A separate tint would
	# draw a line across the mouth showing where one ends.
	material.shader = WATER_SHADER
	mesh.surface_set_material(0, material)

	var instance := MeshInstance3D.new()
	instance.name = "Surface"
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


## Squared distance from `point` to the polyline, in whatever space both are in. Inlined rather than
## reusing `IslandHeightmap.river_track()` because this is the gate that runs on every one of the
## grid's points and `river_track()` rebuilds the polyline — and therefore `lobes()` — per call.
func _distance_sq_to_line(point: Vector2, line: PackedVector2Array) -> float:
	var best: float = INF
	for index in range(line.size() - 1):
		var a: Vector2 = line[index]
		var span: Vector2 = line[index + 1] - a
		var length_sq: float = span.length_squared()
		var t: float = 0.0 if length_sq < 0.0001 \
			else clampf((point - a).dot(span) / length_sq, 0.0, 1.0)
		best = minf(best, (a + span * t).distance_squared_to(point))
	return best
