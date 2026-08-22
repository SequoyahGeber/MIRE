extends SceneTree

## F-490 — every nature asset the repo ships is actually reachable in a generated world.
##
## Sequoyah's rule: "we shouldnt have any nature assets not being used during map generation". This
## check is what keeps that true as kits grow. It reads each nature kit's own `catalog.json` and
## asserts every export is either
##
##  · placed by a `content/scatter/*.tres` table, or
##  · a damage/depleted STATE that a `content/harvestables/*.tres` definition swaps in (those are
##    never scattered themselves — they appear when the intact prop is worked), or
##  · assembled into a POI structure by `world/gen/poi_structures.gd` (the ruins, F-493), or
##  · placed by a hand-authored layout in `world/gen/layouts/` — which is where the architecture
##    inside the `environment` kit lives (ruins, the wood and stone building sets, fences). Those
##    are reported separately: they are shipped, but only the authored maps place them, so a
##    procedural run never shows one. Growing that list is a signal, not a pass.
##
##   .agent/bin/agent godot --script tools/nature_asset_coverage_check.gd

const NATURE_KITS: PackedStringArray = [
	"environment", "environment_additions", "flora", "gatherables",
	"harvestables", "terrain_accents", "wetland", "wetland_nature",
]

## Assets that legitimately never appear in a world by themselves. Keep this list short and give
## every line a reason — an empty exemption is how an unused asset hides.
const EXEMPT: Dictionary = {}

const SCATTER := preload("res://world/gen/resource_scatter.gd")
const STRUCTURES := preload("res://world/gen/poi_structures.gd")
const SEEDS: Array[int] = [20260821, 4242]
const CHUNK_RADIUS: int = 7
## How many props a table must have placed in the sample before "this entry never landed" is an
## accusation about the ENTRY rather than about how little of that biome the sample contained.
const TABLE_RAN_THRESHOLD: int = 40

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	if registry == null:
		print("  FAIL  Registry autoload is missing")
		_finish()
		return

	var scattered: Dictionary = {}
	for def: Resource in registry.get(&"scatter_tables").values():
		for entry: Resource in def.get(&"entries"):
			if entry != null:
				scattered[StringName(String(entry.get(&"asset")))] = def.get(&"id")

	var state_art: Dictionary = _states_used_by_definitions()
	var authored: Dictionary = _assets_named_by_layouts()
	var structural: Dictionary = _assets_used_by_structures()

	for kit: String in NATURE_KITS:
		var names: PackedStringArray = _catalog_names(kit)
		var missing := PackedStringArray()
		var authored_only := PackedStringArray()
		for name: String in names:
			var asset := StringName(name)
			if scattered.has(asset) or state_art.has(asset) or structural.has(asset) or EXEMPT.has(name):
				continue
			if authored.has(asset):
				authored_only.append(name)
				continue
			missing.append(name)
		if missing.is_empty():
			print("  PASS  %s: all %d export(s) reach a world" % [kit, names.size()])
		else:
			failures += 1
			print("  FAIL  %s: %d unused export(s): %s" % [kit, missing.size(), ", ".join(missing)])
		if not authored_only.is_empty():
			print("        (%d placed only by an authored layout: %s)"
				% [authored_only.size(), ", ".join(authored_only)])

	_check_placements(registry)
	_finish()


## A table entry can be listed and still be unplaceable — a height band under the sea floor, a slope
## band no ground in that biome has. Being in a `.tres` is not the same as being in a world, so this
## generates real chunks and counts what actually lands.
func _check_placements(registry: Node) -> void:
	var scatter_defs: Array = registry.get(&"scatter_tables").values()
	var biome_defs: Array = registry.get(&"biomes").values()
	var listed: Dictionary = {}  # asset -> table id
	for def: Resource in scatter_defs:
		for entry: Resource in def.get(&"entries"):
			if entry != null:
				listed[StringName(String(entry.get(&"asset")))] = StringName(String(def.get(&"id")))

	var seen: Dictionary = {}
	var per_table: Dictionary = {}
	var total: int = 0
	for world_seed: int in SEEDS:
		for cx in range(-CHUNK_RADIUS, CHUNK_RADIUS):
			for cz in range(-CHUNK_RADIUS, CHUNK_RADIUS):
				for placement: Dictionary in SCATTER.placements_for_chunk(
					cx, cz, world_seed, scatter_defs, biome_defs
				):
					total += 1
					seen[placement["asset"]] = int(seen.get(placement["asset"], 0)) + 1
					var table: StringName = placement["def_id"]
					per_table[table] = int(per_table.get(table, 0)) + 1

	# An entry that never lands while its OWN table placed plenty is gated out — a height band under
	# the sea floor, a slope band no ground in that biome has, a weight rounded into nothing. An
	# entry that never lands because its table barely ran at all is just a small biome in this
	# sample, and failing on that would only teach the next author to widen the sample.
	var never := PackedStringArray()
	var thin := PackedStringArray()
	for asset: StringName in listed:
		if seen.has(asset):
			continue
		if int(per_table.get(listed[asset], 0)) >= TABLE_RAN_THRESHOLD:
			never.append("%s (%s)" % [asset, listed[asset]])
		else:
			thin.append("%s (%s)" % [asset, listed[asset]])
	never.sort()
	thin.sort()
	if never.is_empty():
		print("  PASS  every scatter entry in a table that ran placed at least once "
			+ "(%d props over %d chunks x %d seeds)" % [total, 4 * CHUNK_RADIUS * CHUNK_RADIUS, SEEDS.size()])
	else:
		failures += 1
		print("  FAIL  %d scatter entr(ies) never placed while their table did: %s"
			% [never.size(), ", ".join(never)])
	if not thin.is_empty():
		print("        (%d entr(ies) unseen only because their table barely ran here: %s)"
			% [thin.size(), ", ".join(thin)])


## Every GLB a harvestable definition points at, by asset id. These are the damaged and depleted
## presentations; a scatter table places the INTACT asset and the definition swaps to these.
func _states_used_by_definitions() -> Dictionary:
	var used: Dictionary = {}
	var dir := DirAccess.open("res://content/harvestables")
	if dir == null:
		return used
	for file: String in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var definition: Resource = load("res://content/harvestables/" + file)
		if definition == null:
			continue
		var scenes: Array = definition.get(&"active_state_scenes")
		var all: Array = scenes.duplicate()
		all.append(definition.get(&"depleted_scene"))
		for scene: Variant in all:
			var packed := scene as PackedScene
			if packed == null:
				continue
			used[StringName(packed.resource_path.get_file().get_basename())] = file
	return used


## Every asset a POI structure builds with, sampled across enough site seeds that a piece used only
## occasionally still shows up (F-493).
func _assets_used_by_structures() -> Dictionary:
	var used: Dictionary = {}
	for structure_id: StringName in STRUCTURES.BUILDERS:
		var builder: Script = STRUCTURES.BUILDERS[structure_id]
		for site_seed: int in range(200):
			for piece: Dictionary in builder.call(&"pieces_for_site", site_seed * 131):
				used[StringName(String(piece["asset"]))] = structure_id
	return used


## Every asset id a hand-authored layout names. The layouts are big, so this scans them as text for
## the exact `"asset": "<name>"` field rather than parsing the whole document per kit.
func _assets_named_by_layouts() -> Dictionary:
	var used: Dictionary = {}
	var dir := DirAccess.open("res://world/gen/layouts")
	if dir == null:
		return used
	for file: String in dir.get_files():
		if not file.ends_with(".json"):
			continue
		var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://world/gen/layouts/" + file)
		)
		if parsed is Dictionary:
			_collect_asset_fields(parsed, used)
		elif parsed is Array:
			for row: Variant in parsed:
				_collect_asset_fields(row, used)
	return used


func _collect_asset_fields(value: Variant, out: Dictionary) -> void:
	if value is Dictionary:
		var row: Dictionary = value
		if row.has("asset"):
			out[StringName(String(row["asset"]))] = true
		for key: Variant in row:
			_collect_asset_fields(row[key], out)
	elif value is Array:
		for item: Variant in value:
			_collect_asset_fields(item, out)


func _catalog_names(kit: String) -> PackedStringArray:
	var out := PackedStringArray()
	var text: String = FileAccess.get_file_as_string("res://assets/%s/catalog.json" % kit)
	if text.is_empty():
		failures += 1
		print("  FAIL  %s: catalog.json is missing or empty" % kit)
		return out
	var parsed: Variant = JSON.parse_string(text)
	var rows: Array = []
	if parsed is Array:
		rows = parsed
	elif parsed is Dictionary and (parsed as Dictionary).has("assets"):
		var assets: Variant = (parsed as Dictionary)["assets"]
		rows = assets if assets is Array else (assets as Dictionary).values()
	for row: Variant in rows:
		if row is Dictionary and (row as Dictionary).has("name"):
			out.append(String((row as Dictionary)["name"]))
	return out


func _finish() -> void:
	print("NATURE_ASSET_COVERAGE_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
