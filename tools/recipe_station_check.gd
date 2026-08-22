extends SceneTree

## F-484: every recipe sits at the station that should make it. Smelting at the furnace, smithed
## iron-and-up goods at the anvil, wood/stone/fibre goods at the workbench — and every station a
## recipe names must be a registered StationDef, so nothing is stranded at a station that does not
## exist.

const EXPECTED: Dictionary = {
	&"charcoal": &"furnace",
	&"iron_ingot": &"furnace",
	&"bogsilver_ingot": &"furnace",
	&"iron_axe": &"anvil",
	&"iron_pickaxe": &"anvil",
	&"iron_sword": &"anvil",
	&"cleaver": &"anvil",
	&"repair_hammer": &"anvil",
	&"skewer": &"anvil",
	&"bogsilver_axe": &"anvil",
	&"bogsilver_pickaxe": &"anvil",
	&"wellglass_axe": &"anvil",
	&"wellglass_pickaxe": &"anvil",
	&"wooden_axe": &"workbench",
	&"wooden_pickaxe": &"workbench",
	&"stone_axe": &"workbench",
	&"stone_pickaxe": &"workbench",
	&"short_bow": &"workbench",
	&"arrow": &"workbench",
}

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	var crafting: Node = root.get_node_or_null(^"CraftingService")
	check(registry != null, "Registry autoload exists")
	check(crafting != null, "CraftingService autoload exists")
	if registry == null or crafting == null:
		finish()
		return

	for recipe_id: StringName in EXPECTED:
		var expected: StringName = EXPECTED[recipe_id]
		check(bool(registry.call("has_recipe", recipe_id)), "%s is registered" % recipe_id)
		var ids: Array[StringName] = _ids(crafting.call("recipes_for_station", expected))
		check(ids.has(recipe_id), "%s is craftable at the %s" % [recipe_id, expected])
		for other: StringName in [&"workbench", &"furnace", &"anvil"]:
			if other == expected:
				continue
			check(not _ids(crafting.call("recipes_for_station", other)).has(recipe_id),
				"%s is NOT offered at the %s" % [recipe_id, other])

	# No recipe may name a station that has no StationDef, or the player can never reach it.
	for recipe_id: StringName in EXPECTED:
		var station: StringName = EXPECTED[recipe_id]
		check(bool(registry.call("has_station", station)),
			"station %s is registered" % station)

	finish()


func _ids(recipes: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for r: Object in recipes:
		out.append(StringName(r.get("id")))
	return out


func check(ok: bool, label: String) -> void:
	if ok:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func finish() -> void:
	print("\n%s — %d failure(s)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
