extends SceneTree

## Task 3.18: is the tool ladder real, and is it gated?
##
## Two questions, and the second is the one that matters. Anyone can author five tiers of pickaxe;
## what `docs/PROGRESSION.md` §2 actually promises is that **a party cannot reach the top two rungs
## without doing the run's objectives** — the Anvil costs a Wellglass Shard, which only a Wellspring
## cap pays out, and T5 costs a Guardian Core, which only a boss drops. That is a claim about the
## shipped recipe graph, so it is checked against the shipped recipe graph and not against a fixture.
##
## Run with: .agent/bin/agent godot --script tools/progression_check.gd

const PROGRESSION := preload("res://autoload/progression_service.gd")

## The rung each tool sits on. Read as the ladder's own spec: an item here that does not exist yet is
## a failure with a name, which is exactly what the authoring pass wants to see.
const EXPECTED_TIERS: Dictionary = {
	&"wooden_axe": 1, &"wooden_pickaxe": 1, &"sling": 1, &"short_bow": 1,
	&"stone_axe": 2, &"stone_pickaxe": 2,
	&"iron_axe": 3, &"iron_pickaxe": 3, &"iron_sword": 3, &"cleaver": 3, &"skewer": 3,
	&"repair_hammer": 3, &"longbow": 3, &"crossbow": 3,
	&"bogsilver_axe": 4, &"bogsilver_pickaxe": 4,
	&"wellglass_axe": 5, &"wellglass_pickaxe": 5,
}

## Items that may only ever come out of the objective loop, never out of a recipe or a node. If any
## of these becomes craftable, the gate is gone and the ladder is back to being a mining exercise.
const OBJECTIVE_ONLY_ITEMS: Array[String] = ["wellglass_shard", "guardian_core"]

## rung -> an item id that must be transitively unreachable without one of the objective-only items
## above. Only the gated rungs appear: T1..T3 are meant to be freely craftable.
const GATED_RUNGS: Dictionary = {
	4: &"bogsilver_pickaxe",
	5: &"wellglass_pickaxe",
}

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	var progression: Node = root.get_node_or_null(^"ProgressionService")
	check(registry != null, "Registry autoload exists")
	check(progression != null, "ProgressionService autoload exists")
	if registry == null or progression == null:
		_finish()
		return

	_check_authored_tiers(registry, progression)
	_check_every_tool_has_a_tier(registry)
	_check_objective_only_items(registry)
	_check_gates(registry)
	_check_high_water_mark(progression)

	print("PROGRESSION failures=%d" % failures)
	_finish()


func _check_authored_tiers(registry: Node, progression: Node) -> void:
	for item_id: StringName in EXPECTED_TIERS:
		if not bool(registry.call("has_item", item_id)):
			check(false, "item '%s' exists (tier %d is unauthored)" % [
				item_id, int(EXPECTED_TIERS[item_id])
			])
			continue
		var expected: int = int(EXPECTED_TIERS[item_id])
		var actual: int = int(progression.call("tier_of_item", item_id))
		check(actual == expected, "'%s' is tier %d (authored %d)" % [item_id, expected, actual])


## The silent-failure guard: an unauthored `tool_tier` is 0, and a tier-0 tool advances nothing. A
## new axe that forgets the field would work perfectly and never move the ladder, which is the least
## debuggable shape a content bug can take.
func _check_every_tool_has_a_tier(registry: Node) -> void:
	var items: Dictionary = registry.get(&"items") as Dictionary
	for item_id: StringName in items:
		var item: Resource = items[item_id] as Resource
		if item == null:
			continue
		# Category 1 TOOL, 2 WEAPON — see ItemDef.Category. Resources and food are tier 0 correctly.
		var category: int = int(item.get(&"category"))
		if category != 1 and category != 2:
			check(int(item.get(&"tool_tier")) == 0,
				"non-tool '%s' is tier 0" % item_id)
			continue
		# Ammunition is a weapon-adjacent category and is not a rung; it is exempt by id rather than
		# by a new field, because two ids is cheaper than a schema.
		if item_id == &"arrow" or item_id == &"bolt":
			continue
		check(int(item.get(&"tool_tier")) > 0,
			"tool/weapon '%s' declares a tool_tier" % item_id)


func _check_objective_only_items(registry: Node) -> void:
	for raw: String in OBJECTIVE_ONLY_ITEMS:
		var item_id := StringName(raw)
		check(bool(registry.call("has_item", item_id)), "objective item '%s' exists" % item_id)
		var recipes: Dictionary = registry.get(&"recipes") as Dictionary
		var craftable: bool = false
		for recipe_id: StringName in recipes:
			var recipe: Resource = recipes[recipe_id] as Resource
			if recipe == null:
				continue
			var output: Resource = recipe.get(&"output_item") as Resource
			if output != null and StringName(String(output.get(&"id"))) == item_id:
				craftable = true
		check(not craftable, "'%s' is not craftable — it only drops from the objective loop" % item_id)


## Walks the recipe graph upward from a rung's tool and asserts an objective-only item is somewhere
## in its ancestry. This is the gate, stated as a property of the shipped content rather than as a
## comment nobody re-reads.
func _check_gates(registry: Node) -> void:
	for tier: int in GATED_RUNGS:
		var item_id: StringName = GATED_RUNGS[tier]
		if not bool(registry.call("has_item", item_id)):
			check(false, "tier %d tool '%s' exists" % [tier, item_id])
			continue
		var ancestry: Dictionary = _ingredient_closure(registry, item_id)
		var gated: bool = false
		for raw: String in OBJECTIVE_ONLY_ITEMS:
			if ancestry.has(StringName(raw)):
				gated = true
		check(gated, "tier %d ('%s') cannot be reached without an objective drop" % [tier, item_id])


## Every item that feeds, directly or transitively, into crafting `item_id` — including the stations
## its recipes require, because a station is itself a gate with its own recipe. Cycle-safe.
func _ingredient_closure(registry: Node, item_id: StringName) -> Dictionary:
	var seen: Dictionary = {}
	var frontier: Array[StringName] = [item_id]
	var recipes: Dictionary = registry.get(&"recipes") as Dictionary
	while not frontier.is_empty():
		var current: StringName = frontier.pop_back()
		if seen.has(current):
			continue
		seen[current] = true
		for recipe_id: StringName in recipes:
			var recipe: Resource = recipes[recipe_id] as Resource
			if recipe == null:
				continue
			var output: Resource = recipe.get(&"output_item") as Resource
			if output == null or StringName(String(output.get(&"id"))) != current:
				continue
			for ingredient: Resource in recipe.get(&"inputs") as Array:
				if ingredient == null:
					continue
				var input_item: Resource = ingredient.get(&"item") as Resource
				if input_item != null:
					frontier.append(StringName(String(input_item.get(&"id"))))
			# The station this recipe needs is part of the gate: an Anvil recipe that costs a shard
			# is what makes every Anvil product gated, not the product's own ingredient list.
			var station_id := StringName(String(recipe.get(&"station")))
			if station_id == &"" or not bool(registry.call("has_station", station_id)):
				continue
			# A station is a gate with its own price. The Anvil is not crafted — it is BUILT, and its
			# `BuildableDef.cost` is where the Wellglass Shard is actually spent, so the closure has
			# to walk into the buildable of the same id or it would conclude the Anvil is free.
			if bool(registry.call("has_buildable", station_id)):
				var buildable: Resource = registry.call("get_buildable", station_id) as Resource
				if buildable != null:
					var cost: Dictionary = buildable.get(&"cost") as Dictionary
					for cost_id: StringName in cost:
						if not seen.has(cost_id):
							frontier.append(cost_id)
	return seen


## The mark is a HIGH-WATER mark, and that is the whole of its contract: it rises once per rung and
## never falls inside a run. A `host_raise_tier` that let a lower rung overwrite a higher one would
## make the fanfare fire twice and the Salvage milestone score wrong.
func _check_high_water_mark(progression: Node) -> void:
	progression.call("host_reset_run")
	check(int(progression.call("tier_reached")) == 0, "a fresh run starts at tier 0")

	var raises: Array[int] = []
	var listener: Callable = func(tier: int, _item_id: StringName) -> void:
		raises.append(tier)
	EventBus.subscribe_tier_reached(listener)

	progression.call("host_raise_tier", PROGRESSION.TIER_STONE, &"stone_axe")
	check(int(progression.call("tier_reached")) == 2, "crafting a stone tool reaches tier 2")
	progression.call("host_raise_tier", PROGRESSION.TIER_WOOD, &"wooden_axe")
	check(int(progression.call("tier_reached")) == 2, "a lower rung cannot pull the mark back down")
	progression.call("host_raise_tier", PROGRESSION.TIER_STONE, &"stone_pickaxe")
	check(int(progression.call("tier_reached")) == 2, "the same rung twice announces once")
	progression.call("host_raise_tier", PROGRESSION.TIER_WELLGLASS, &"wellglass_pickaxe")
	check(int(progression.call("tier_reached")) == 5, "the ladder tops out at tier 5")
	progression.call("host_raise_tier", 9, &"nonsense")
	check(int(progression.call("tier_reached")) == 5, "a tier above the ladder is clamped to 5")

	EventBus.unsubscribe_tier_reached(listener)
	var expected_raises: Array[int] = [2, 5]
	check(raises == expected_raises,
		"exactly one announcement per rung reached (got %s)" % str(raises))

	progression.call("host_reset_run")
	check(int(progression.call("tier_reached")) == 0, "a new run puts the ladder back to 0")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	quit(1 if failures > 0 else 0)
