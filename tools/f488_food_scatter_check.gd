extends SceneTree

## F-488 — apple trees, berry bushes and mushroom patches actually reach a procedural world, and
## reach it as live harvestables rather than as scenery.
##
## Counts placements over a block of chunks for two seeds, and asserts each food asset both appears
## and classifies to its own definition through `HarvestLibrary`.
##
##   .agent/bin/agent godot --script tools/f488_food_scatter_check.gd

const ResourceScatterLib := preload("res://world/gen/resource_scatter.gd")
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")

const SEEDS: Array[int] = [20260821, 4242]
const FOOD: Dictionary = {
	&"apple_tree_full": &"apple_tree",
	&"berry_bush_full": &"berry_bush",
	&"mushroom_patch_full": &"mushroom_patch",
}

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload is present")
	if registry == null:
		_finish()
		return

	print("== each food asset classifies as its own harvestable ==")
	for asset: StringName in FOOD:
		var want: String = "res://content/harvestables/%s.tres" % FOOD[asset]
		check(HarvestLib.definition_path_for(asset) == want,
			"%s harvests as %s" % [asset, FOOD[asset]])
		check(HarvestLib.representation_for(asset) == HarvestLib.Represent.NODE,
			"%s is placed as its own node (it has picked art)" % asset)
	for asset: StringName in [&"apple_tree_picked", &"berry_bush_harvested", &"mushroom_patch_harvested"]:
		check(HarvestLib.definition_path_for(asset).is_empty(),
			"%s stays inert scenery" % asset)

	print("\n== HarvestWorld resolves each one to a loaded definition that yields food ==")
	var harvest: Node = root.get_node_or_null(^"HarvestWorld")
	check(harvest != null, "HarvestWorld autoload is present")
	var yields: Dictionary = {
		&"apple_tree_full": &"apple", &"berry_bush_full": &"berry",
		&"mushroom_patch_full": &"mushroom",
	}
	if harvest != null:
		for asset: StringName in yields:
			var definition: Resource = harvest.call("definition_for", asset)
			check(definition != null, "%s resolves to a loaded definition" % asset)
			if definition != null:
				check(definition.get(&"yield_item_id") == yields[asset],
					"%s yields %s" % [asset, yields[asset]])

	var scatter_defs: Array = registry.get(&"scatter_tables").values()
	var biome_defs: Array = registry.get(&"biomes").values()
	for world_seed: int in SEEDS:
		print("\n== seed %d, chunks [-6,6) ==" % world_seed)
		var counts: Dictionary = {}
		var total: int = 0
		for cx in range(-6, 6):
			for cz in range(-6, 6):
				for placement: Dictionary in ResourceScatterLib.placements_for_chunk(
					cx, cz, world_seed, scatter_defs, biome_defs
				):
					total += 1
					var asset: StringName = placement["asset"]
					if FOOD.has(asset):
						counts[asset] = int(counts.get(asset, 0)) + 1
		for asset: StringName in FOOD:
			var n: int = int(counts.get(asset, 0))
			check(n > 0, "%s placed %d time(s)" % [asset, n])
			check(float(n) / float(maxi(total, 1)) < 0.05,
				"%s stays a find, not dressing (%.2f%% of %d props)"
					% [asset, 100.0 * float(n) / float(maxi(total, 1)), total])

	_finish()


func check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		failures += 1
		print("  FAIL  %s" % label)


func _finish() -> void:
	print("\n%s (%d failure(s))" % ["OK" if failures == 0 else "FAILED", failures])
	quit(0 if failures == 0 else 1)
