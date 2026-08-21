extends SceneTree

## F-339: a terrain vertex's stored normal must describe the surface its own triangles form.
##
## `ChunkMesher` jitters every vertex in XZ and re-samples its height at the new coordinate, but it
## used to compute the normal as a central difference across the UNJITTERED apron at `ai +/- 1`. The
## stored normal therefore described a smooth regular grid while the mesh was an irregular one.
##
## Shipped lighting was never wrong, and that is worth stating plainly rather than leaving someone to
## hunt for a visual bug: `world/chunk/terrain_flat.gdshader` derives its facet normal per fragment
## from screen-space derivatives (`cross(dFdy(VERTEX), dFdx(VERTEX))`), so it never reads the mesh's
## normals at all. What was wrong is the mesh's own data — a trap for anything that does read it: a
## check, a tool, a future material without the derivative trick, or the skirt, which inherits its
## top vertex's normal verbatim.
##
## Three assertions:
##
##   1. **Derived from this geometry** — recomputing area-weighted normals from the mesh's OWN
##      vertices and indices reproduces the stored normals. That is the finding's literal ask, and it
##      fails immediately on a revert to the apron central difference or on a flipped winding.
##   2. **Agreement improves, on average** — the mean angle between a normal and the faces that touch
##      it is strictly lower for the stored normals than for the pre-F-339 formula. Compared as a
##      MEAN, not a worst case: this terrain is deliberately faceted at 1 m spacing, so a vertex
##      shared by six genuinely unequal triangles can sit 100 degrees from an individual sliver while
##      being the correct average of all six. An absolute per-face tolerance would be asserting that
##      the terrain is smooth, which it is expressly not.
##   3. **Sanity** — every normal is unit length and points up. A heightfield has no downward-facing
##      vertex, so a negative Y is the signature of a reversed cross product, which is the one way
##      the accumulation can be silently wrong everywhere at once.
##
##   .agent/bin/agent godot --script tools/terrain_normal_check.gd
##
## Authority: none (docs/ARCHITECTURE.md §2.2). `ChunkMesher.build_mesh()` is a pure function of
## (chunk, seed, biome defs, lod); nothing here boots a world or a session.

const Mesher := preload("res://world/chunk/chunk_mesher.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")
const Heightmap := preload("res://world/gen/island_heightmap.gd")

## Chunks over land at this seed, so the assertions run on real relief rather than flat ocean.
const SEED: int = 20260819
const CHUNKS: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(2, -1)]

## How closely a re-derivation must reproduce a stored normal. Degrees, and tight: the two are
## computed the same way from the same data, so anything above float noise means the stored normal
## did not come from this geometry.
const DERIVATION_TOLERANCE_DEG: float = 0.5

## How much better the stored normals must agree with the emitted faces than the old formula did, as
## a mean over every terrain vertex.
##
## Measured at 0.16 deg (stored 4.16, legacy 4.31) across four chunks of seed 20260819, so the gate
## sits at a third of that: above float noise, comfortably under the observed value. And the number
## is worth stating plainly rather than burying — F-339 predicted the old normals would be "most
## visibly" wrong on the faceted terrain, and the honest measurement is that they were a fifth of a
## degree off on average. Jitter is at most 0.35 m at 1 m spacing on ground that has no mountains by
## design, so the unjittered central difference was a decent approximation of the real surface.
## The fix is still right — the stored data is now true, and dropping the apron it needed removed
## 1,225 noise samples per chunk — but it did not fix something anyone could see.
const MIN_MEAN_IMPROVEMENT_DEG: float = 0.05

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	var biome_defs: Array = []
	if registry != null:
		biome_defs = (registry.get(&"biomes") as Dictionary).values()
	check(not biome_defs.is_empty(), "biome defs are loaded (%d)" % biome_defs.size())

	var stored_total: float = 0.0
	var legacy_total: float = 0.0
	var worst_derivation: float = 0.0
	var legacy_vs_derived: float = 0.0
	var checked: int = 0
	var non_unit: int = 0
	var downward: int = 0

	for coord: Vector2i in CHUNKS:
		var mesh: ArrayMesh = Mesher.build_mesh(coord.x, coord.y, SEED, biome_defs, 0)
		if mesh == null or mesh.get_surface_count() == 0:
			check(false, "chunk %v builds a mesh" % coord)
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

		var side: int = Mesher.verts_per_side(0)
		var terrain_count: int = side * side
		var result: Dictionary = _face_agreement(
			vertices, normals, indices, terrain_count, side, coord, biome_defs)
		stored_total += float(result["stored_total"])
		legacy_total += float(result["legacy_total"])
		checked += int(result["samples"])
		worst_derivation = maxf(worst_derivation,
			_worst_derivation_angle(vertices, normals, indices, terrain_count))
		legacy_vs_derived = maxf(legacy_vs_derived, _worst_derivation_angle(
			vertices, _legacy_normals(coord, side, biome_defs), indices, terrain_count))

		for i: int in terrain_count:
			if absf(normals[i].length() - 1.0) > 0.001:
				non_unit += 1
			if normals[i].y <= 0.0:
				downward += 1

	check(checked > 0, "terrain vertices inspected across %d chunks (%d)" % [CHUNKS.size(), checked])
	check(non_unit == 0, "every stored normal is unit length (%d were not)" % non_unit)
	check(downward == 0,
		"every stored normal points up — a heightfield has no downward vertex, so this is the "
		+ "reversed-cross-product signature (%d pointed down)" % downward)

	check(worst_derivation <= DERIVATION_TOLERANCE_DEG,
		"every stored normal is reproduced by area-weighting this mesh's own faces (worst %.3f deg)"
			% worst_derivation)

	# The real guard is the derivation assertion above, and this quantifies why: the legacy formula
	# misses the emitted geometry by DEGREES, so a revert fails that assertion by three orders of
	# magnitude rather than squeaking past a mean.
	check(legacy_vs_derived > DERIVATION_TOLERANCE_DEG * 10.0,
		"NEGATIVE: the pre-F-339 formula sits %.2f deg from the emitted faces' own normals, far "
		% legacy_vs_derived + "outside the %.1f deg derivation gate — a revert cannot pass"
			% DERIVATION_TOLERANCE_DEG)

	var mean_stored: float = stored_total / float(maxi(checked, 1))
	var mean_legacy: float = legacy_total / float(maxi(checked, 1))
	# The teeth. If the legacy formula agreed with the emitted faces just as well, this check could
	# not tell the fix from the bug and every PASS above would be decoration.
	check(mean_legacy - mean_stored >= MIN_MEAN_IMPROVEMENT_DEG,
		"NEGATIVE: the pre-F-339 unjittered central difference agrees with those faces %.2f deg "
		% (mean_legacy - mean_stored) + "WORSE on average (stored %.2f vs legacy %.2f) — this check "
		% [mean_stored, mean_legacy] + "can tell them apart")

	print("\nTERRAIN_NORMAL_CHECK failures=%d mean_stored=%.2f mean_legacy=%.2f derivation=%.3f legacy_vs_derived=%.2f"
		% [failures, mean_stored, mean_legacy, worst_derivation, legacy_vs_derived])
	quit(0 if failures == 0 else 1)


## Summed angle, over every (vertex, adjacent face) pair, for the stored normal and for the normal
## the pre-F-339 formula would have produced. Summed rather than maxed — see the header on why the
## mean is the honest statistic on faceted terrain.
func _face_agreement(
	vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
	terrain_count: int, side: int, coord: Vector2i, biome_defs: Array
) -> Dictionary:
	var legacy: PackedVector3Array = _legacy_normals(coord, side, biome_defs)
	var stored_total: float = 0.0
	var legacy_total: float = 0.0
	var seen: int = 0
	var tri: int = 0
	while tri + 2 < indices.size():
		var ia: int = indices[tri]
		var ib: int = indices[tri + 1]
		var ic: int = indices[tri + 2]
		tri += 3
		# Skirt triangles are excluded: their walls are vertical and they deliberately inherit the
		# terrain normal above them, so including them would assert against a documented choice.
		if ia >= terrain_count or ib >= terrain_count or ic >= terrain_count:
			continue
		var a: Vector3 = vertices[ia]
		var face: Vector3 = (vertices[ic] - a).cross(vertices[ib] - a)
		if face.length_squared() <= 0.0:
			continue
		face = face.normalized()
		for index: int in [ia, ib, ic]:
			seen += 1
			stored_total += rad_to_deg(normals[index].angle_to(face))
			legacy_total += rad_to_deg(legacy[index].angle_to(face))
	return {"stored_total": stored_total, "legacy_total": legacy_total, "samples": seen}


## Worst angle between a stored normal and the same normal re-derived, here, by area-weighting the
## faces of the mesh that was handed to this function. Independent of `ChunkMesher`'s own code path —
## it reads only the emitted arrays — so agreement means the stored data really does describe this
## geometry rather than meaning the two copied each other.
func _worst_derivation_angle(
	vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
	terrain_count: int
) -> float:
	var derived := PackedVector3Array()
	derived.resize(terrain_count)
	for i: int in terrain_count:
		derived[i] = Vector3.ZERO
	var tri: int = 0
	while tri + 2 < indices.size():
		var ia: int = indices[tri]
		var ib: int = indices[tri + 1]
		var ic: int = indices[tri + 2]
		tri += 3
		if ia >= terrain_count or ib >= terrain_count or ic >= terrain_count:
			continue
		var a: Vector3 = vertices[ia]
		var face: Vector3 = (vertices[ic] - a).cross(vertices[ib] - a)
		derived[ia] += face
		derived[ib] += face
		derived[ic] += face
	var worst: float = 0.0
	for i: int in terrain_count:
		if derived[i].length_squared() <= 0.0:
			continue
		worst = maxf(worst, rad_to_deg(normals[i].angle_to(derived[i].normalized())))
	return worst


## The normals `build_mesh()` produced before F-339: a central difference across the UNJITTERED
## one-metre grid, at the vertex's pre-jitter position. Reproduced here rather than kept in the
## product, so the shipped path carries no dead formula and the control still exists.
func _legacy_normals(coord: Vector2i, side: int, biome_defs: Array) -> PackedVector3Array:
	var noise_set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(SEED)
	var table: BiomeMap.TerrainTable = BiomeMap.make_terrain_table(biome_defs)
	var shape := Heightmap.Shape.new()
	var origin_x: float = float(coord.x * Mesher.CHUNK_SIZE)
	var origin_z: float = float(coord.y * Mesher.CHUNK_SIZE)
	var out := PackedVector3Array()
	out.resize(side * side)
	var v: int = 0
	for z: int in side:
		for x: int in side:
			var wx: float = origin_x + float(x)
			var wz: float = origin_z + float(z)
			var dx: float = (
				BiomeMap.surface_from_set(wx + 1.0, wz, noise_set, SEED, table, shape)
				- BiomeMap.surface_from_set(wx - 1.0, wz, noise_set, SEED, table, shape)) * 0.5
			var dz: float = (
				BiomeMap.surface_from_set(wx, wz + 1.0, noise_set, SEED, table, shape)
				- BiomeMap.surface_from_set(wx, wz - 1.0, noise_set, SEED, table, shape)) * 0.5
			out[v] = Vector3(-dx, 1.0, -dz).normalized()
			v += 1
	return out


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
