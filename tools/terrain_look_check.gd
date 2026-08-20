extends SceneTree

## Focused acceptance check for task 4.13's terrain-look contract.
##
## Proves the ridged layer is confined to high ground and never carves it, the
## shipped biome table changes the direct height function, and the production
## chunk mesher uses that same biome-scaled surface rather than the 1.0/1.0
## fallback. Autoload access stays dynamic so this remains safe under --script.

const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")
const ChunkMesher := preload("res://world/chunk/chunk_mesher.gd")

const SEED: int = 20260819
const SAMPLE_LIMIT: int = 96
const SAMPLE_STEP: int = 4
const HEIGHT_EPSILON: float = 0.002

var failures: int = 0
var biome_defs: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry is registered for the production biome-table check")
	if registry == null:
		finish()
		return
	var table: Dictionary = registry.get(&"biomes")
	biome_defs = table.values()
	check(biome_defs.size() == 3, "all three shipped biome definitions load (%d)" % biome_defs.size())

	_check_ridge_layer()
	_check_biome_table()
	_check_chunk_mesher_surface()

	print("\nTERRAIN_LOOK_CHECK failures=%d" % failures)
	finish()


func _check_ridge_layer() -> void:
	print("\n== the masked ridged layer only adds on high ground ==")
	check(IslandHeightmap.ridge_mask(0.0) == 0.0,
		"the ridged layer is fully masked at sea level")
	check(IslandHeightmap.ridge_mask(IslandHeightmap.HEIGHT_SCALE) == 1.0,
		"the ridged layer reaches full strength on high ground")

	var active_samples: int = 0
	var subtractive_samples: int = 0
	var worst_delta: float = 0.0
	var worst_point := Vector2.ZERO
	for z in range(-SAMPLE_LIMIT, SAMPLE_LIMIT + 1, SAMPLE_STEP):
		for x in range(-SAMPLE_LIMIT, SAMPLE_LIMIT + 1, SAMPLE_STEP):
			var continent: float = IslandHeightmap.continent(float(x), float(z), SEED)
			if IslandHeightmap.ridge_mask(continent) <= 0.0:
				continue
			var ridged_only: float = IslandHeightmap.height(float(x), float(z), SEED, 0.0, 1.0)
			var delta: float = ridged_only - continent
			if absf(delta) > HEIGHT_EPSILON:
				active_samples += 1
			if delta < -HEIGHT_EPSILON:
				subtractive_samples += 1
				if delta < worst_delta:
					worst_delta = delta
					worst_point = Vector2(float(x), float(z))
	check(active_samples > 0,
		"the ridged layer visibly affects at least one high-ground sample (%d)" % active_samples)
	check(subtractive_samples == 0,
		"no ridged sample carves below its continent (count=%d, worst=%.3f m at %s)" % [
			subtractive_samples, worst_delta, worst_point])


func _check_biome_table() -> void:
	print("\n== authored biome amplitudes affect the direct terrain surface ==")
	var changed_samples: int = 0
	for z in range(0, SAMPLE_LIMIT + 1, SAMPLE_STEP):
		for x in range(0, SAMPLE_LIMIT + 1, SAMPLE_STEP):
			var amplitudes: Vector2 = BiomeMap.terrain_amplitudes(
				float(x), float(z), SEED, biome_defs)
			var blind: float = IslandHeightmap.height(float(x), float(z), SEED)
			var scaled: float = IslandHeightmap.height(
				float(x), float(z), SEED, amplitudes.x, amplitudes.y)
			if absf(scaled - blind) > HEIGHT_EPSILON:
				changed_samples += 1
	check(changed_samples > 0,
		"the shipped amplitude table changes direct height samples (%d)" % changed_samples)


func _check_chunk_mesher_surface() -> void:
	print("\n== the production chunk mesh uses the biome-scaled surface ==")
	var candidate_chunk := Vector2i.ZERO
	var candidate_local := Vector2i.ZERO
	var candidate_scaled: float = 0.0
	var candidate_blind: float = 0.0
	var found: bool = false
	for chunk_z in 3:
		for chunk_x in 3:
			for local_z in range(0, ChunkMesher.CHUNK_SIZE + 1):
				for local_x in range(0, ChunkMesher.CHUNK_SIZE + 1):
					var world_x: float = float(chunk_x * ChunkMesher.CHUNK_SIZE + local_x)
					var world_z: float = float(chunk_z * ChunkMesher.CHUNK_SIZE + local_z)
					var amplitudes: Vector2 = BiomeMap.terrain_amplitudes(
						world_x, world_z, SEED, biome_defs)
					var blind: float = IslandHeightmap.height(world_x, world_z, SEED)
					var scaled: float = IslandHeightmap.height(
						world_x, world_z, SEED, amplitudes.x, amplitudes.y)
					if absf(scaled - blind) <= 0.05:
						continue
					candidate_chunk = Vector2i(chunk_x, chunk_z)
					candidate_local = Vector2i(local_x, local_z)
					candidate_scaled = scaled
					candidate_blind = blind
					found = true
					break
				if found:
					break
			if found:
				break
		if found:
			break
	check(found, "found a chunk vertex where the authored biome table changes height")
	if not found:
		return

	var mesh: ArrayMesh = ChunkMesher.build_mesh(
		candidate_chunk.x, candidate_chunk.y, SEED, biome_defs, 0)
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var side: int = ChunkMesher.verts_per_side(0)
	var vertex_index: int = candidate_local.y * side + candidate_local.x
	var actual: float = vertices[vertex_index].y
	check(absf(actual - candidate_scaled) <= HEIGHT_EPSILON,
		"chunk vertex uses biome-scaled height (actual=%.3f scaled=%.3f blind=%.3f at %s/%s)" % [
			actual, candidate_scaled, candidate_blind, candidate_chunk, candidate_local])


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
