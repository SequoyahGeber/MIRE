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
##
## **Positioned as a FRACTION of the island, not in absolute chunks (F-372).** These four coordinates
## were authored when `IslandHeightmap.ISLAND_RADIUS` was 118 m, where two chunks from the origin
## (64 m) was a bit over half way out — sloping ground. F-368 raised the radius to 295 m and the same
## absolute coordinates became a tight cluster around the island's flattest point, which quietly
## gutted this check's own teeth: the NEGATIVE margin below fell 0.15 -> 0.07 -> 0.05 deg across two
## terrain changes and tripped the gate, with nothing wrong with the normals at all.
##
## That is worth naming because it is the THIRD instance of one mistake found in a single session —
## a constant in metres or chunks that was implicitly a fraction of the island, left behind when the
## island moved. The others were the river half-widths and `MireGrid.BASE_SPREAD_RATE`. Deriving the
## sample location keeps this check measuring the same KIND of ground at any radius.
const SEED: int = 20260819


## The four chunks over land with the MOST relief, found by measuring rather than by guessing
## coordinates.
##
## Guessing is what broke: `_BASE_CHUNKS` are the coordinates this check shipped with, and scaling
## them by the radius ratio still lands wherever that ratio happens to point — which on a bigger,
## flatter island was flatter ground again. Relief is the property the NEGATIVE assertions actually
## need, so relief is what this selects on. It is also self-correcting: retune the terrain however
## you like and this keeps finding the roughest ground that exists to measure on.
##
## Cheap: a 5x5 grid of height probes per candidate over a band of chunks, which is a few thousand
## surface samples once, against the 24,576 vertices the check goes on to inspect.
static func sample_chunks(biome_defs: Array) -> Array:
	var noise_set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(SEED)
	var table: BiomeMap.TerrainTable = BiomeMap.make_terrain_table(biome_defs)
	var shape := Heightmap.Shape.new()

	# Candidates span the island out to the taper. Anything past that is ocean, which has no relief
	# to measure and would be picked for exactly the wrong reason if the metric were noise.
	var reach: int = int(Heightmap.ISLAND_RADIUS * Heightmap.FALLOFF_START_FRACTION) \
		/ Mesher.CHUNK_SIZE
	var scored: Array = []
	for cz: int in range(-reach, reach + 1):
		for cx: int in range(-reach, reach + 1):
			var heights: Array[float] = []
			var lowest: float = 1.0e9
			for pz: int in 5:
				for px: int in 5:
					var wx: float = float(cx * Mesher.CHUNK_SIZE + px * (Mesher.CHUNK_SIZE / 4))
					var wz: float = float(cz * Mesher.CHUNK_SIZE + pz * (Mesher.CHUNK_SIZE / 4))
					var h: float = BiomeMap.surface_from_set(wx, wz, noise_set, SEED, table, shape)
					heights.append(h)
					lowest = minf(lowest, h)
			# Skip anything with a vertex at or under the waterline: a half-submerged chunk's range
			# is dominated by the shoreline drop, not by the surface detail under test.
			if lowest <= 0.5:
				continue
			var mean: float = 0.0
			for h: float in heights:
				mean += h
			mean /= float(heights.size())
			var variance: float = 0.0
			for h: float in heights:
				variance += (h - mean) * (h - mean)
			scored.append([variance / float(heights.size()), Vector2i(cx, cz)])

	scored.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	var out: Array = []
	for index: int in mini(4, scored.size()):
		out.append((scored[index] as Array)[1])
	return out

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
##
## F-372: that 0.16 deg observation is the calibration story, not the gate. An ABSOLUTE degree gate
## turned out to be the wrong shape for this measurement entirely.
##
## How far the legacy formula sits from the truth scales with how much the surface curves, so the
## margin between the two formulas scales with terrain roughness. Measured across this session's
## terrain work, on identical, correct normals:
##
##     island 118 m, pre-softening   mean_stored 4.16   margin 0.15 deg   (gate calibrated here)
##     island 295 m                  mean_stored 2.25   margin 0.07 deg
##     island 295 m, softened river  mean_stored 1.57   margin 0.03 deg   FAILS the 0.05 gate
##
## Nothing was wrong with the normals in any of those runs — `worst 0.005 deg` derivation passed
## throughout. The terrain simply got gentler, which is the deliberate art direction for this
## project (mostly flat, gentle rolling hills, no mountains), so the gate was on a collision course
## with the roadmap.
##
## The question this assertion actually asks is scale-free — "can this check tell the fix from the
## bug?" — so the gate is now scale-free too: the improvement must be at least this FRACTION of the
## stored error. The three runs above read 3.6%, 3.1% and 1.9%; the gate sits at 1.2%, which is
## under all of them and still far above float noise. The absolute floor is kept as a second
## condition so a hypothetical near-flat island cannot satisfy a percentage of almost nothing.
const MIN_MEAN_IMPROVEMENT_FRACTION: float = 0.012
## Float-noise floor for that fraction, in degrees. Well under the 0.03 the gentlest terrain
## measured, and far above the ~0.005 the derivation check reports as noise.
const MIN_MEAN_IMPROVEMENT_FLOOR_DEG: float = 0.015

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

	var chunks: Array = sample_chunks(biome_defs)
	for coord: Vector2i in chunks:
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

	check(checked > 0, "terrain vertices inspected across %d chunks %s (%d)" % [chunks.size(), chunks, checked])
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
	var margin: float = mean_legacy - mean_stored
	var required: float = maxf(
		mean_stored * MIN_MEAN_IMPROVEMENT_FRACTION, MIN_MEAN_IMPROVEMENT_FLOOR_DEG)
	check(margin >= required,
		"NEGATIVE: the pre-F-339 unjittered central difference agrees with those faces %.3f deg "
		% margin + "(%.1f%% of the stored error, gate %.3f) " % [
			margin / maxf(mean_stored, 0.0001) * 100.0, required]
		+ "WORSE on average (stored %.2f vs legacy %.2f) — this check "
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
