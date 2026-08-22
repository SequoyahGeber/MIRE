extends SceneTree

## F-487: crafting stations form tiered families, and the FIRST TIER OF EVERY FAMILY MUST BE
## BUILDABLE FROM BASE GATHERED RESOURCES (Sequoyah, 2026-08-21).
##
## "Base gathered" means an item the world hands the player directly — something a HarvestableDef
## yields. Not a crafted intermediate, and above all not a loot or POI drop: the anvil once cost a
## wellglass_shard that only the wellspring dropped, and the furnace cost flint that nothing in the
## game produced, so the whole forge branch could fail to open in a run (F-485, F-487).
##
## Higher tiers are exactly where crafted intermediates belong — that is what makes them upgrades —
## so this only constrains tier 1, and separately insists every family's tiers are contiguous from 1
## and that each station has a buildable to make it.
##
## F-575 added the second half: until 2026-08-22 this file was the ONLY reader of `family`/`tier` in
## the repo. The data was authored, validated here, and then ignored by the game —
## `CraftingService` matched a recipe's station by bare id, so the Reinforced Workbench satisfied
## none of the seven workbench recipes and the tier-2 station unlocked strictly less than the tier-1
## one it upgrades. The assertions below exercise `CraftingService.station_satisfies()` directly, so
## the tier system cannot go back to being decoration that only a check can see.

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		_finish()
		return

	var base_items: Dictionary = {}
	for path: String in _tres_in("res://content/harvestables"):
		var harvestable: Resource = load(path)
		var yielded: StringName = StringName(harvestable.get("yield_item_id"))
		if yielded != &"":
			base_items[yielded] = true
	check(base_items.size() >= 4, "the world yields a set of base resources to build from")

	var families: Dictionary = {}   # family -> {tier -> Array[station id]}
	for path: String in _tres_in("res://content/stations"):
		var station: Resource = load(path)
		var id: StringName = StringName(station.get("id"))
		var family: StringName = StringName(station.get("family"))
		var tier: int = int(station.get("tier"))
		check(family != &"", "station %s names a family" % id)
		if not families.has(family):
			families[family] = {}
		if not families[family].has(tier):
			families[family][tier] = []
		families[family][tier].append(id)

	for family: StringName in families:
		var tiers: Array = families[family].keys()
		tiers.sort()
		check(tiers[0] == 1, "family %s starts at tier 1 (starts at %d)" % [family, tiers[0]])
		for i: int in tiers.size():
			check(tiers[i] == i + 1,
				"family %s has no gap in its tiers (got %s)" % [family, str(tiers)])

		for station_id: StringName in families[family][tiers[0]]:
			var buildable: Resource = registry.call("get_buildable", station_id)
			check(buildable != null,
				"tier-1 station %s has a buildable to raise it" % station_id)
			if buildable == null:
				continue
			var cost: Dictionary = buildable.get("cost")
			check(not cost.is_empty(), "tier-1 station %s costs something" % station_id)
			for item_id: StringName in cost:
				check(base_items.has(item_id),
					"tier-1 %s costs only base gathered resources — %s is %s"
						% [station_id, item_id, "gathered" if base_items.has(item_id) else "NOT gathered"])

	_check_satisfy_rule(registry, families)

	_finish()


## F-575: substitution is declared, and `upgrades_from` is constrained so it can only ever express
## an upgrade — the named station must exist, be in the same family, and sit at a strictly lower
## tier. That is what stops it becoming a back door around the progression this file guards.
func _check_satisfy_rule(registry: Node, families: Dictionary) -> void:
	var crafting: Node = root.get_node_or_null(^"CraftingService")
	check(crafting != null, "CraftingService autoload exists")
	if crafting == null:
		return

	var by_id: Dictionary = {}
	for path: String in _tres_in("res://content/stations"):
		var station: Resource = load(path)
		by_id[StringName(station.get("id"))] = station

	for id: StringName in by_id:
		var station: Resource = by_id[id]
		check(crafting.call("station_satisfies", id, id), "%s satisfies its own requirement" % id)
		var parent := StringName(String(station.get("upgrades_from")))
		if parent == &"":
			continue
		check(by_id.has(parent), "%s upgrades from %s, which exists" % [id, parent])
		if not by_id.has(parent):
			continue
		var parent_def: Resource = by_id[parent]
		check(StringName(station.get("family")) == StringName(parent_def.get("family")),
			"%s and the %s it upgrades from are the same family" % [id, parent])
		check(int(station.get("tier")) > int(parent_def.get("tier")),
			"%s (tier %d) outranks the %s it upgrades from (tier %d)"
				% [id, int(station.get("tier")), parent, int(parent_def.get("tier"))])
		check(crafting.call("station_satisfies", id, parent),
			"%s satisfies %s" % [id, parent])
		check(not crafting.call("station_satisfies", parent, id),
			"%s does NOT satisfy %s — substitution is one-way" % [parent, id])

	# Nothing substitutes for anything it did not name. This is the assertion that would have caught
	# the first attempt at this fix, which inferred substitution from family+tier and silently made
	# the anvil a smelter.
	for a: StringName in by_id:
		for b: StringName in by_id:
			if a == b:
				continue
			var declared: bool = false
			var seen: Dictionary = {}
			var cursor: StringName = a
			while cursor != &"" and not seen.has(cursor):
				seen[cursor] = true
				var next := StringName(String((by_id[cursor] as Resource).get("upgrades_from")))
				if next == b:
					declared = true
					break
				cursor = next if by_id.has(next) else &""
			check(crafting.call("station_satisfies", a, b) == declared,
				"%s satisfies %s only if it declared so (%s)" % [a, b, declared])

	# The regression that started this: the Reinforced Workbench must make what the primitive one
	# makes. Asserted on the recipe list rather than on the predicate, because the list is what the
	# player actually sees when they walk up to the bench.
	var primitive: Array = crafting.call("recipes_for_station", &"workbench")
	var upgraded: Array = crafting.call("recipes_for_station", &"workbench_upgraded")
	check(not primitive.is_empty(), "the primitive workbench has recipes at all (%d)" % primitive.size())
	var upgraded_ids: Dictionary = {}
	for recipe: Resource in upgraded:
		upgraded_ids[StringName(recipe.get("id"))] = true
	for recipe: Resource in primitive:
		check(upgraded_ids.has(StringName(recipe.get("id"))),
			"the Reinforced Workbench can still craft %s" % recipe.get("id"))

	# And the recipes that must NOT have moved. F-484 owns the full map; these two are the pair the
	# inferred rule broke, pinned here so this file fails too if substitution ever widens again.
	var anvil_ids: Dictionary = {}
	for recipe: Resource in crafting.call("recipes_for_station", &"anvil"):
		anvil_ids[StringName(recipe.get("id"))] = true
	for smelted: StringName in [&"iron_ingot", &"bogsilver_ingot"]:
		check(not anvil_ids.has(smelted),
			"%s stays at the furnace — the anvil is tier 2 of the same family and still cannot smelt"
				% smelted)


func _tres_in(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	for file_name: String in dir.get_files():
		if file_name.ends_with(".tres"):
			out.append("%s/%s" % [dir_path, file_name])
	out.sort()
	return out


func check(ok: bool, label: String) -> void:
	if ok:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func _finish() -> void:
	print("\n%s — %d failure(s)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
