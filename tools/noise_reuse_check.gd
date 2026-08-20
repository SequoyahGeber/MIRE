extends SceneTree

## Verifies F-241's fix — world/gen/island_heightmap.gd's IslandHeightmap.height_from_set() /
## NoiseSet, and world/chunk/chunk_mesher.gd sampling through one NoiseSet per chunk instead of
## rebuilding six FastNoiseLite fields per vertex.
##
##   .agent/bin/agent godot --script tools/noise_reuse_check.gd
##
## Three things have to hold for this to be a real fix and not a fast-but-wrong one:
##   1. height_from_set(x, z, make_noise_set(seed), seed) is BIT-IDENTICAL to height(x, z, seed)
##      for every sample — same construction, same result, only when it happens moves.
##   2. ChunkMesher.build_mesh()'s vertex heights match BiomeMap.surface_from_set() sampled
##      directly at the same world coordinates — the actual integration, not just the two APIs in
##      isolation. (That was IslandHeightmap.height() until F-274 wired the mesher to the biome
##      seam; the mesher no longer takes the biome-blind 1.0/1.0 surface, so neither does this.)
##   3. The reuse is actually faster: sampling a LOD0 apron (1,089 points, F-241's own number)
##      through one shared NoiseSet must beat rebuilding fresh noise per sample by a wide margin.
##
## Cross-platform bit-identity of the underlying noise/float ops is tools/check_determinism.gd's
## job, not this file's — `terrain_hash` there is unchanged by this refactor (verified by hand:
## same hash before and after, recorded in DECISIONS.md), because make_noise_set() constructs the
## identical fields height() built inline before F-241.

## Preloaded rather than referenced by bare class_name — a script new to this session is not yet in
## .godot/global_script_class_cache.cfg (F-016, same fix tools/handshake_check.gd uses).
const IslandHeightmap = preload("res://world/gen/island_heightmap.gd")
const ChunkMesher = preload("res://world/chunk/chunk_mesher.gd")
const BiomeMap = preload("res://world/gen/biome_map.gd")
const BiomeDefsLib := preload("res://tools/biome_defs_lib.gd")

## The real content table. F-274 moved the mesher off bare `height()` onto
## `BiomeMap.surface_from_set()`, so point 2 below compares the mesh against the surface the game
## builds — an empty table here would compare it against a surface nothing builds, which is the
## whole shape of the bug F-274 fixed.
var _biome_defs: Array = []

var _failures: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	_biome_defs = BiomeDefsLib.load_defs(self)
	const SEED_A: int = 20260819
	const SEED_B: int = 71406

	print("\n-- height_from_set() matches height() bit-for-bit --")
	_check_equivalence(SEED_A)
	_check_equivalence(SEED_B)

	print("\n-- ChunkMesher.build_mesh() vertex heights match IslandHeightmap.height() directly --")
	# Chunks over LAND. F-274 found these were (3,-7) and (-2,5) — 243 m and 172 m from origin,
	# both well outside `ISLAND_RADIUS` (118 m) since the 4.13 retuning, so every vertex in them was
	# exactly 0.0 and the comparison below was two zeroes agreeing. The same trap F-251 found in
	# `chunk_stream_check.gd`, in a second file. `_check_mesh_matches_direct` now also asserts the
	# chunk has real relief in it, so it cannot go quietly vacuous again.
	_check_mesh_matches_direct(1, 0, SEED_A, 0)
	_check_mesh_matches_direct(0, -1, SEED_B, 1)

	print("\n-- reuse is actually faster (F-241's whole point) --")
	_check_speedup(SEED_A)

	print("")
	if _failures == 0:
		print("PASS — 0 failures")
	else:
		print("FAIL — %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)


## A grid wide enough to cross the falloff edge and the river corridor, not just flat interior.
func _check_equivalence(world_seed: int) -> void:
	var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
	var mismatches: int = 0
	var samples: int = 0
	for gx in range(-8, 9):
		for gz in range(-8, 9):
			var x: float = float(gx) * 19.0
			var z: float = float(gz) * 19.0
			var direct: float = IslandHeightmap.height(x, z, world_seed)
			var via_set: float = IslandHeightmap.height_from_set(x, z, set, world_seed)
			samples += 1
			if direct != via_set:
				mismatches += 1
	_check("seed %d: %d/%d samples bit-identical" % [world_seed, samples - mismatches, samples],
		mismatches == 0, "%d mismatched" % mismatches)

	# Non-default amplitudes too — the parameters height_from_set() forwards, not just the defaults.
	var amp_direct: float = IslandHeightmap.height(41.0, -63.0, world_seed, 0.4, 1.6)
	var amp_via_set: float = IslandHeightmap.height_from_set(41.0, -63.0, set, world_seed, 0.4, 1.6)
	_check("seed %d: non-default detail/ridge amplitudes still bit-identical" % world_seed,
		amp_direct == amp_via_set, "%f vs %f" % [amp_direct, amp_via_set])


## The integration proof: a real chunk's terrain vertices, read back out of the mesh and compared
## against IslandHeightmap.height() called directly at the same world coordinates. If chunk_mesher's
## NoiseSet plumbing ever drifted from height()'s own definition, this is what would catch it —
## the two check functions above only prove the two APIs agree with EACH OTHER.
func _check_mesh_matches_direct(chunk_x: int, chunk_z: int, world_seed: int, lod: int) -> void:
	var mesh: ArrayMesh = ChunkMesher.build_mesh(
		chunk_x, chunk_z, world_seed, _biome_defs, lod)
	var noise_set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed)
	var table: BiomeMap.TerrainTable = BiomeMap.make_terrain_table(_biome_defs)
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var step: int = ChunkMesher.LOD_STEPS[lod]
	var side: int = ChunkMesher.verts_per_side(lod)
	var origin_x: float = float(chunk_x * ChunkMesher.CHUNK_SIZE)
	var origin_z: float = float(chunk_z * ChunkMesher.CHUNK_SIZE)
	var mismatches: int = 0
	var checked: int = 0
	var lowest: float = 1.0e30
	var highest: float = -1.0e30
	# Every terrain vertex, not just a corner or two — the border rows are exactly where an apron
	# off-by-one would show up. Sampled at the vertex's OWN stored XZ, not the grid point: interior
	# vertices carry 4.18/D-184's deterministic jitter, and "this vertex sits on the analytic
	# ground at its own position" is the same contract with the same strength — a vertex anywhere
	# off the surface still fails. Border-on-grid is asserted by tools/biome_terrain_check.gd.
	for z in side:
		for x in side:
			var v: int = z * side + x
			var world_x: float = origin_x + verts[v].x
			var world_z: float = origin_z + verts[v].z
			var expected: float = BiomeMap.surface_from_set(
				world_x, world_z, noise_set, world_seed, table)
			checked += 1
			lowest = minf(lowest, expected)
			highest = maxf(highest, expected)
			# Through a float32 round-trip: the mesher's apron is a `PackedFloat32Array` and its
			# vertices are `Vector3`s, so the reference double has to be narrowed the same way or
			# the comparison fails on storage precision rather than on a real divergence.
			if verts[v].y != PackedFloat32Array([expected])[0]:
				mismatches += 1
	_check("chunk (%d,%d) lod%d: %d/%d vertices match surface_from_set() directly" % [
		chunk_x, chunk_z, lod, checked - mismatches, checked,
	], mismatches == 0, "%d mismatched" % mismatches)
	_check("chunk (%d,%d) lod%d has real relief in it (%.1f m .. %.1f m)" % [
		chunk_x, chunk_z, lod, lowest, highest,
	], highest - lowest > 1.0, "a flat chunk agrees with anything")


## Times sampling a LOD0-sized apron (33x33 = 1,089 points, the exact number F-241 cites) two ways:
## one fresh height() call per sample (the pre-fix shape) against one NoiseSet built once and
## height_from_set() per sample (the fix). Both must be run on this same process/machine for the
## comparison to mean anything — this is a relative, not an absolute, measurement.
func _check_speedup(world_seed: int) -> void:
	const SIDE: int = 33
	const REPEATS: int = 20

	var t0: int = Time.get_ticks_usec()
	for r in REPEATS:
		for gz in SIDE:
			for gx in SIDE:
				var _h: float = IslandHeightmap.height(float(gx), float(gz), world_seed)
	var per_sample_us: float = float(Time.get_ticks_usec() - t0) / float(REPEATS * SIDE * SIDE)

	var t1: int = Time.get_ticks_usec()
	for r in REPEATS:
		var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
		for gz in SIDE:
			for gx in SIDE:
				var _h: float = IslandHeightmap.height_from_set(float(gx), float(gz), set, world_seed)
	var shared_us: float = float(Time.get_ticks_usec() - t1) / float(REPEATS * SIDE * SIDE)

	print("  per-call height():        %.3f us/sample" % per_sample_us)
	print("  shared NoiseSet:          %.3f us/sample" % shared_us)
	print("  speedup:                  %.2fx" % (per_sample_us / shared_us))
	# Threshold deliberately well under what six-constructions-to-one suggests: most of a sample's
	# cost is the noise SAMPLING itself (fractal octaves, domain warp, the river polyline walk),
	# not construction, and that part is identical in both paths. 1.3x is a safe floor that still
	# catches a broken reuse (e.g. NoiseSet rebuilt per sample by accident) on a busy shared machine
	# — measured 1.88x on a quiet run of this same script during F-241.
	_check("shared NoiseSet is meaningfully faster per sample than rebuilding noise every call",
		shared_us * 1.3 < per_sample_us,
		"%.3f us vs %.3f us" % [shared_us, per_sample_us])
