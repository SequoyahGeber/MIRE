extends SceneTree

## F-445 · The Mire's own growth is scattered in the Mire, and nowhere else.
##
## Two failures this guards, both of which shipped:
##
## 1. `mushroom_cluster_a..f` are `mire_growth` assets — purple corruption, not woodland toadstools —
##    and they were entries in `forest_deadwood`, `birchwood_deadwood` and `marsh_deadwood`, so
##    corruption grew out of clean birch woodland. Any `mire_growth` asset in a biome-gated table is
##    that bug returning.
## 2. `mire_crystal_*` and `mire_tendril_*` were built, catalogued and committed, and then referenced
##    by nothing at all — ten nature assets no run of the game could show (F-439's class of defect).
##    Every `mire_growth` export must be reachable from some scatter table.
##
## The category is read from `assets/environment/catalog.json` rather than listed here, so an asset
## added to the Mire kit later is covered by this check the day it is built.
##
## Run: .agent/bin/agent godot --script tools/mire_scatter_check.gd

const MireGridSimLib := preload("res://world/mire/mire_grid_sim.gd")
const ResourceScatterLib := preload("res://world/gen/resource_scatter.gd")
const ScatterDefLib := preload("res://world/gen/scatter_def.gd")
const ChunkMesherLib := preload("res://world/chunk/chunk_mesher.gd")
const IslandLib := preload("res://world/gen/island_heightmap.gd")

const CATALOG_PATH: String = "res://assets/environment/catalog.json"
const MIRE_CATEGORY: String = "mire_growth"

var _failures: int = 0


func check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   %s" % message)
	else:
		_failures += 1
		print("  FAIL %s" % message)


func _init() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"/root/Registry")
	if registry == null:
		push_error("Registry autoload missing")
		quit(1)
		return

	var defs: Array = (registry.get(&"scatter_tables") as Dictionary).values()
	var biome_defs: Array = (registry.get(&"biomes") as Dictionary).values()
	var mire_assets := _mire_growth_assets()

	print("-- mire_growth kit --")
	check(mire_assets.size() >= 16,
		"catalog lists %d %s assets" % [mire_assets.size(), MIRE_CATEGORY])

	print("-- no Mire growth in a biome table --")
	_check_no_mire_in_biome_tables(defs, mire_assets)

	print("-- every Mire growth asset is placed by something --")
	_check_all_mire_assets_referenced(defs, mire_assets)

	print("-- corruption-gated tables place only inside their band --")
	_check_placements_respect_band(defs, biome_defs)

	print("-- initial_corruption_at agrees with the grid it replaces --")
	_check_field_matches_grid()

	print("%s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)


## Asset stems in the Mire growth category, from the kit's own catalog.
func _mire_growth_assets() -> Dictionary:
	var out: Dictionary = {}
	var text := FileAccess.get_file_as_string(CATALOG_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Array:
		check(false, "could not parse %s" % CATALOG_PATH)
		return out
	for record: Variant in parsed as Array:
		var entry := record as Dictionary
		if String(entry.get("category", "")) == MIRE_CATEGORY:
			out[String(entry.get("name", ""))] = true
	return out


func _check_no_mire_in_biome_tables(defs: Array, mire_assets: Dictionary) -> void:
	var offenders := PackedStringArray()
	for def: Resource in defs:
		if String(def.get(&"biome_id")) == String(ScatterDefLib.ANY_BIOME):
			continue
		if bool(def.call(&"reads_corruption")):
			continue
		for entry: Resource in (def.get(&"entries") as Array):
			if entry != null and mire_assets.has(String(entry.get(&"asset"))):
				offenders.append("%s in %s" % [String(entry.get(&"asset")), String(def.get(&"id"))])
	check(offenders.is_empty(),
		"no %s asset sits in an ungated biome table%s"
		% [MIRE_CATEGORY, "" if offenders.is_empty() else " — found " + ", ".join(offenders)])


func _check_all_mire_assets_referenced(defs: Array, mire_assets: Dictionary) -> void:
	var referenced: Dictionary = {}
	for def: Resource in defs:
		for entry: Resource in (def.get(&"entries") as Array):
			if entry != null:
				referenced[String(entry.get(&"asset"))] = true
	var orphans := PackedStringArray()
	for asset: String in mire_assets:
		if not referenced.has(asset):
			orphans.append(asset)
	orphans.sort()
	check(orphans.is_empty(),
		"every %s export is reachable from a scatter table%s"
		% [MIRE_CATEGORY, "" if orphans.is_empty() else " — orphaned: " + ", ".join(orphans)])


## Generate a band of real chunks and confirm that (a) the Mire tables place something at all —
## a gate nothing survives is indistinguishable from the assets still being unreferenced — and
## (b) nothing they place sits outside the corruption band the table declares.
func _check_placements_respect_band(defs: Array, biome_defs: Array) -> void:
	var world_seed: int = 20260821
	var gated: Dictionary = {}
	for def: Resource in defs:
		if bool(def.call(&"reads_corruption")):
			gated[String(def.get(&"id"))] = def
	check(not gated.is_empty(), "at least one scatter table gates on Mire corruption")
	if gated.is_empty():
		return

	var centres := MireGridSimLib.seed_cluster_centres(world_seed)
	var counts: Dictionary = {}
	var outside: int = 0
	var half: int = ceili(IslandLib.ISLAND_RADIUS / float(ChunkMesherLib.CHUNK_SIZE))
	for chunk_x: int in range(-half, half + 1):
		for chunk_z: int in range(-half, half + 1):
			for placement: Dictionary in ResourceScatterLib.placements_for_chunk(
					chunk_x, chunk_z, world_seed, defs, biome_defs):
				var def_id := String(placement["def_id"])
				if not gated.has(def_id):
					continue
				counts[def_id] = int(counts.get(def_id, 0)) + 1
				var position: Vector3 = placement["position"]
				var corruption: float = MireGridSimLib.initial_corruption_from_centres(
					position.x, position.z, centres)
				var def: Resource = gated[def_id]
				if corruption < float(def.get(&"min_corruption")) \
						or corruption > float(def.get(&"max_corruption")):
					outside += 1
	for def_id: String in gated:
		check(int(counts.get(def_id, 0)) > 0,
			"%s placed %d prop(s) across the island" % [def_id, int(counts.get(def_id, 0))])
	check(outside == 0, "%d gated placement(s) landed outside their corruption band" % outside)


## `seed_cluster_centres()`/`initial_corruption_from_centres()` were carved out of `seed_initial()`;
## the grid is what MireGrid replicates, so the two must still describe the same field. Sampled at
## cell centres, where the quantized grid and the continuous field are defined to agree exactly.
func _check_field_matches_grid() -> void:
	var world_seed: int = 991
	var grid: PackedFloat32Array = MireGridSimLib.seed_initial(world_seed)
	var centres := MireGridSimLib.seed_cluster_centres(world_seed)
	check(centres.size() == MireGridSimLib.SEED_CLUSTER_COUNT,
		"%d cluster centre(s)" % centres.size())
	var worst: float = 0.0
	var corrupted_cells: int = 0
	for cell_z: int in range(0, MireGridSimLib.CELLS_PER_SIDE, 3):
		for cell_x: int in range(0, MireGridSimLib.CELLS_PER_SIDE, 3):
			var world: Vector2 = MireGridSimLib.cell_to_world_center(cell_x, cell_z)
			var from_field: float = MireGridSimLib.initial_corruption_from_centres(
				world.x, world.y, centres)
			var from_grid: float = grid[MireGridSimLib.cell_index(cell_x, cell_z)]
			if from_grid > 0.0:
				corrupted_cells += 1
			worst = maxf(worst, absf(from_field - from_grid))
	check(corrupted_cells > 0, "the sampled grid has %d corrupted cell(s)" % corrupted_cells)
	check(worst < 0.0001, "largest field/grid disagreement is %.6f" % worst)
