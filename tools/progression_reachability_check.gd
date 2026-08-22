extends SceneTree

## Can a party get from bare hands to every craftable thing, on a real generated island?
##
##   .agent/bin/agent godot --script tools/progression_reachability_check.gd
##
## Sequoyah, before a playtest with a friend: *"i dont want to get hard locked in progression during
## the play test and have to do fixes then compile a new app and install."* This is the instrument
## that answers that. Nothing else in `tools/` does: `recipe_station_check` asserts recipes sit at
## sensible stations, `station_tier_check` asserts tier one of each family is buildable from base
## resources, `loot_content_check` asserts tables name real items. Every one of them checks a LOCAL
## property. A hard lock is a GLOBAL one — it is not any single recipe being wrong, it is the
## transitive closure of what a player can obtain failing to contain something the game offers.
##
## ── What it computes ─────────────────────────────────────────────────────────────────────────────
##
## A fixpoint over three sets that grow together, seeded from what the world hands you for free:
##
##     items    every item id a party can end up holding
##     tools    every HarvestLibrary.Tool class they can swing (NONE always; CHOP, MINE earned)
##     stations every station they can stand at
##
## then iterated until nothing new enters:
##
##     a harvestable placed on THIS island, whose required_tool is in `tools`  -> its yield
##     a BuildableDef of category `station` whose cost is inside `items`       -> that station
##     a RecipeDef whose station is available and whose inputs are inside      -> its output
##
## Anything outside the closure at the end is unreachable, and the report says which specific
## ingredient, tool or station is missing rather than only that it failed.
##
## ── Three things that make this catch hard locks rather than look like it does ───────────────────
##
## **1. Tool class is part of the state, not a detail.** Bare hands are `Tool.NONE` with
## `harvest_power` 1 (`CombatService._make_placeholder_weapon()`), and `HarvestableDef
## .damage_from_tool()` floors a wrong-tool swing to `floori(1 * 0.34)` = **0**. So a player with
## nothing cannot scratch anything that asks for an axe or a pickaxe, and the entire tree has to
## bootstrap through `required_tool == NONE` props. A closure over items alone would happily report
## `log` reachable while the axe that fells the tree needs a log — the classic hard lock, and the one
## `station_tier_check` cannot see because it only guards tier one of each family.
##
## **2. The starting kit is empty in a shipped build.** `core/dev/dev_loadout.gd` grants its 16-line
## loadout only when `MIRE_DEV_LOADOUT=1` or the `dev_loadout_enabled` gamerule is set, and its own
## header says "the shipped game never runs with `--script`, so players are unaffected". Sequoyah's
## friend will therefore spawn holding NOTHING. Seeding the closure with the dev loadout would make
## this check pass while the real game hard locks in its first minute, so `STARTING_KIT` is empty and
## the loadout is deliberately ignored.
##
## **3. Biome availability decides what exists at all.** A scatter table only places where its
## `biome_id` generated. If an island comes up without `highland`, everything that biome alone
## carries is absent from that run. The biome set is MEASURED per seed by sampling
## `BiomeMap.biome_at_from_set()` over the island disc through the same noise the generator uses —
## not read off the content files — so this reports what the world does rather than what the data
## implies. Today's third rule: assert the artefact, never the record of it.
##
## ── Why several seeds, and why variation is the LOUDER failure ───────────────────────────────────
##
## An item reachable on one island and not another is a run that strands SOMETIMES. That is worse
## than a consistent gap, because it is unreproducible: Sequoyah's friend hard locks, they restart,
## it works, and nothing anyone can do explains it. Per-seed variance is therefore reported as its
## own failure class, above the flat unreachable list.

## ── Negative controls: proof this check can actually fail ────────────────────────────────────────
##
## A reachability check that only ever reports the gaps already present is indistinguishable from one
## that reports nothing. Three deliberate breaks were run against it, each reverted afterwards, and
## each had to go red naming the exact severed link:
##
##   1. **Ingredient severed.** `content/recipes/stone_axe.tres` re-pointed from `stone` to the
##      known-unreachable `sling`. Reported: "stone_axe — recipe 'stone_axe' is missing
##      ingredient(s): sling", plus the recipe itself. Correctly did NOT cascade further, because
##      `wooden_axe` still provides Chop — which is the check declining to over-report.
##   2. **Bootstrap severed at the tool.** `bush` and `sapling` changed from `required_tool = 0` to
##      `1` (Chop). This one is the interesting failure: **it stayed green**, because the loose-loot
##      pool hands out `branch`, `stone`, `flint` and `iron_ore` directly, so the tool tree never
##      touched bare-hand gathering. Not a hole in the check — a fact about the game, and the reason
##      control 3 exists.
##   3. **Bootstrap severed with loot disabled too.** Same harvestable break, plus
##      `REACHABLE_LOOT_TIERS` and `LOOSE_LOOT_POOL` emptied. Reported `tools reachable: bare-hands`
##      and named the root cause exactly: "branch — yielded by harvestable 'sapling', which needs a
##      Chop tool", cascading correctly into every station and recipe downstream of it. This is the
##      control that proves the tool-class modelling works.
##
## ── One result worth keeping, found by control 3 ─────────────────────────────────────────────────
##
## With loot disabled entirely but harvestables intact, the tree still bootstraps completely: all
## three tool classes, all 8 stations, 40 of 46 items. **Progression does not depend on loot.** The
## six that need it are `bolt`, `coins`, `crossbow`, `longbow`, `raw_meat` and `sling`. That is a
## robustness result rather than a passing grade — if chest or loose-loot placement ever regresses,
## a player can still climb the whole tool ladder by hand.

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
const HARVEST_LIBRARY := preload("res://systems/harvesting/harvest_library.gd")

## Fixed rather than random: a failing run has to be reproducible by the person reading it, and
## `Math.random()` in a check is how a red run becomes a coin flip. Five is enough to expose biome
## variance (the island only carries a handful of biomes at a time) without a five-minute check.
const SEEDS: Array[int] = [11, 20260822, 777001, 4242, 98765]

## Metres between biome samples across the island disc. 24 m is finer than the smallest authored
## biome band and coarse enough to keep the sweep under a second per seed.
const BIOME_SAMPLE_STEP_M: float = 24.0

## A shipped player starts with nothing. See the header — this is deliberately empty and is not an
## oversight; `dev_loadout.gd` is a debug affordance that never runs for a player.
const STARTING_KIT: Array[StringName] = []

## Loot tiers a run can actually open. `gilded` is excluded on purpose: `ChestPlacementService`
## refuses to build a gilded chest while its key item does not exist (F-574), so its table's contents
## are NOT a source today. If that changes, this list is the one line to update.
const REACHABLE_LOOT_TIERS: Array[StringName] = [
	&"basic", &"common", &"rare", &"epic", &"legendary",
	# Granted on a Wellspring cap and a boss kill respectively (RewardService). Both are objectives
	# every island carries, so both are genuine sources.
	&"wellspring", &"boss",
]

## Items `LooseLootService` scatters directly at loot markers, independent of any chest.
const LOOSE_LOOT_POOL: Array[StringName] = [
	&"berry", &"mushroom", &"wild_onion", &"fibre_bundle", &"flint", &"stone",
	&"branch", &"resin", &"arrow", &"bolt", &"iron_ore", &"coal",
]

var failures: int = 0
var registry: Node
## seed -> { item_id: true } reachable, for the cross-seed variance pass.
var _per_seed_items: Dictionary[int, Dictionary] = {}
var _per_seed_biomes: Dictionary[int, PackedStringArray] = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	registry = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry is registered as an autoload")
	if registry == null:
		_finish()
		return

	for world_seed: int in SEEDS:
		_analyse_seed(world_seed)
	_check_cross_seed_consistency()

	print("\nPROGRESSION_REACHABILITY_CHECK failures=%d" % failures)
	_finish()


# ── One island ───────────────────────────────────────────────────────────────────────────────────


func _analyse_seed(world_seed: int) -> void:
	print("\n═══ seed %d ═══" % world_seed)
	var biomes: Dictionary[StringName, bool] = _biomes_for_seed(world_seed)
	var biome_list := PackedStringArray()
	for id: StringName in biomes:
		biome_list.append(String(id))
	biome_list.sort()
	_per_seed_biomes[world_seed] = biome_list
	print("biomes generated: %s" % ", ".join(biome_list))

	var closure: Dictionary = _closure(biomes)
	var items: Dictionary = closure["items"]
	var tools: Dictionary = closure["tools"]
	var stations: Dictionary = closure["stations"]
	_per_seed_items[world_seed] = items

	var tool_names := PackedStringArray()
	for tool_class: int in tools:
		tool_names.append(_tool_name(tool_class))
	tool_names.sort()
	print("tools reachable:   %s" % ", ".join(tool_names))
	print("stations reachable: %d of %d" % [stations.size(), (registry.get(&"stations") as Dictionary).size()])
	print("items reachable:    %d of %d" % [items.size(), (registry.get(&"items") as Dictionary).size()])

	_report_unreachable_items(world_seed, items, tools, stations)
	_report_unreachable_stations(world_seed, items, stations)
	_report_unreachable_recipes(world_seed, items, stations)


## The fixpoint. Grows `items`, `tools` and `stations` together until a full pass adds nothing.
func _closure(biomes: Dictionary) -> Dictionary:
	var items: Dictionary[StringName, bool] = {}
	var tools: Dictionary[int, bool] = {HARVEST_LIBRARY.Tool.NONE: true}
	var stations: Dictionary[StringName, bool] = {}

	for item_id: StringName in STARTING_KIT:
		items[item_id] = true
	# Chest and event tables, and the loose piles. These need no tool and no station — they are what
	# the island hands you for walking up to it, which is what makes the whole tree bootstrappable.
	for tier: StringName in REACHABLE_LOOT_TIERS:
		for item_id: StringName in _loot_table_items(tier):
			items[item_id] = true
	for item_id: StringName in LOOSE_LOOT_POOL:
		if _item_exists(item_id):
			items[item_id] = true

	var harvestables: Array[Resource] = _placed_harvestables(biomes)

	var changed: bool = true
	var guard: int = 0
	while changed:
		changed = false
		guard += 1
		if guard > 256:
			# Cannot happen — every pass only ever ADDS to three finite sets, so the fixpoint is
			# reached in at most (items + stations + tools) passes. Guarded anyway, because a check
			# that hangs is worse than one that fails: it takes the shared godot lock with it.
			check(false, "closure did not converge in 256 passes — this is a bug in the check")
			break

		# Tools first: a newly crafted axe is what makes the next harvestable reachable.
		for item_id: StringName in items:
			var tool_class: int = _tool_class_of(item_id)
			if tool_class > 0 and not tools.has(tool_class):
				tools[tool_class] = true
				changed = true

		for definition: Resource in harvestables:
			var required: int = int(definition.get(&"required_tool"))
			if not tools.has(required) and required != HARVEST_LIBRARY.Tool.NONE:
				continue
			var yield_id := StringName(String(definition.get(&"yield_item_id")))
			if yield_id != &"" and not items.has(yield_id):
				items[yield_id] = true
				changed = true

		for buildable: Variant in (registry.get(&"buildables") as Dictionary).values():
			var station_id := StringName(String(buildable.get(&"id")))
			if stations.has(station_id) or not _is_station_buildable(buildable):
				continue
			if _affordable(buildable.get(&"cost") as Dictionary, items):
				stations[station_id] = true
				changed = true

		for recipe: Variant in (registry.get(&"recipes") as Dictionary).values():
			var output: Resource = recipe.get(&"output_item") as Resource
			if output == null:
				continue
			var output_id := StringName(String(output.get(&"id")))
			if items.has(output_id):
				continue
			if not _station_available(StringName(String(recipe.get(&"station"))), stations):
				continue
			if _inputs_satisfied(recipe, items):
				items[output_id] = true
				changed = true

	return {"items": items, "tools": tools, "stations": stations}


# ── Reporting: every failure names the specific missing link ─────────────────────────────────────


func _report_unreachable_items(
	world_seed: int, items: Dictionary, tools: Dictionary, stations: Dictionary
) -> void:
	var unreachable := PackedStringArray()
	for item_id: StringName in (registry.get(&"items") as Dictionary):
		if items.has(item_id):
			continue
		unreachable.append("%s — %s" % [item_id, _why_item_unreachable(item_id, items, tools, stations)])
	unreachable.sort()
	for line: String in unreachable:
		push_error("FAIL: seed %d: %s" % [world_seed, line])
	failures += unreachable.size()
	if unreachable.is_empty():
		print("PASS: every registered item is obtainable on seed %d" % world_seed)


## The actionable half. Walks back one step from the item to the reason it is not in the closure.
func _why_item_unreachable(
	item_id: StringName, items: Dictionary, tools: Dictionary, stations: Dictionary
) -> String:
	var makers: Array[Resource] = _recipes_producing(item_id)
	if makers.is_empty():
		var harvest_source: String = _harvest_source_for(item_id)
		if not harvest_source.is_empty():
			return harvest_source
		return "produced by nothing on this island: no recipe outputs it, no placed harvestable yields it, no reachable loot table drops it"

	var reasons := PackedStringArray()
	for recipe: Resource in makers:
		var recipe_id := StringName(String(recipe.get(&"id")))
		var station_id := StringName(String(recipe.get(&"station")))
		if not _station_available(station_id, stations):
			reasons.append("recipe '%s' needs station '%s', which is not buildable here (%s)" % [
				recipe_id, station_id, _why_station_unreachable(station_id, items)
			])
			continue
		var missing := PackedStringArray()
		for ingredient: Variant in (recipe.get(&"inputs") as Array):
			if ingredient == null:
				continue
			var ingredient_item: Resource = ingredient.get(&"item") as Resource
			if ingredient_item == null:
				continue
			var ingredient_id := StringName(String(ingredient_item.get(&"id")))
			if not items.has(ingredient_id):
				missing.append(String(ingredient_id))
		reasons.append("recipe '%s' is missing ingredient(s): %s" % [recipe_id, ", ".join(missing)])
	return " | ".join(reasons)


## Whether a harvestable yields this item at all, and if so why it cannot be worked here — the
## difference between "the game never produces this" and "you cannot reach the tool for it", which
## are different bugs with different fixes.
func _harvest_source_for(item_id: StringName) -> String:
	for path: String in HARVEST_LIBRARY.definition_paths():
		var definition: Resource = load(path)
		if definition == null:
			continue
		if StringName(String(definition.get(&"yield_item_id"))) != item_id:
			continue
		var required: int = int(definition.get(&"required_tool"))
		return ("yielded by harvestable '%s', which needs a %s tool — either no %s tool is craftable "
			+ "from what this island offers, or the harvestable is not placed by any scatter table "
			+ "whose biome generated here") % [
				definition.get(&"id"), _tool_name(required), _tool_name(required)
			]
	return ""


func _report_unreachable_stations(world_seed: int, items: Dictionary, stations: Dictionary) -> void:
	var unreachable := PackedStringArray()
	for station_id: StringName in (registry.get(&"stations") as Dictionary):
		if stations.has(station_id):
			continue
		unreachable.append("station '%s' — %s" % [station_id, _why_station_unreachable(station_id, items)])
	unreachable.sort()
	for line: String in unreachable:
		push_error("FAIL: seed %d: %s" % [world_seed, line])
	failures += unreachable.size()
	if unreachable.is_empty():
		print("PASS: every registered station is buildable on seed %d" % world_seed)


func _why_station_unreachable(station_id: StringName, items: Dictionary) -> String:
	var buildable: Variant = (registry.get(&"buildables") as Dictionary).get(station_id)
	if buildable == null:
		return "no BuildableDef with this id, so nothing can ever place it"
	var missing := PackedStringArray()
	for cost_item: Variant in (buildable.get(&"cost") as Dictionary):
		if not items.has(StringName(String(cost_item))):
			missing.append(String(cost_item))
	if missing.is_empty():
		return "cost is affordable — if this still reports, the closure has a bug"
	return "its cost needs %s, which is unreachable" % ", ".join(missing)


func _report_unreachable_recipes(world_seed: int, items: Dictionary, stations: Dictionary) -> void:
	var unreachable := PackedStringArray()
	for recipe: Variant in (registry.get(&"recipes") as Dictionary).values():
		var recipe_id := StringName(String(recipe.get(&"id")))
		var station_id := StringName(String(recipe.get(&"station")))
		if not _station_available(station_id, stations):
			unreachable.append("recipe '%s' — station '%s' is not buildable here" % [recipe_id, station_id])
			continue
		if not _inputs_satisfied(recipe, items):
			var missing := PackedStringArray()
			for ingredient: Variant in (recipe.get(&"inputs") as Array):
				if ingredient == null:
					continue
				var ingredient_item: Resource = ingredient.get(&"item") as Resource
				if ingredient_item == null:
					continue
				var ingredient_id := StringName(String(ingredient_item.get(&"id")))
				if not items.has(ingredient_id):
					missing.append(String(ingredient_id))
			unreachable.append("recipe '%s' — never craftable, missing %s" % [recipe_id, ", ".join(missing)])
	unreachable.sort()
	for line: String in unreachable:
		push_error("FAIL: seed %d: %s" % [world_seed, line])
	failures += unreachable.size()
	if unreachable.is_empty():
		print("PASS: every registered recipe is craftable on seed %d" % world_seed)


## The louder failure. An item reachable on one island and not another is a run that strands
## SOMETIMES, which is the unreproducible version of this bug and the worst one to meet in a
## playtest — you restart, it works, and nothing explains what happened.
func _check_cross_seed_consistency() -> void:
	print("\n═══ cross-seed consistency ═══")
	var every_item: Dictionary[StringName, bool] = {}
	for world_seed: int in _per_seed_items:
		for item_id: StringName in _per_seed_items[world_seed]:
			every_item[item_id] = true

	var varying := PackedStringArray()
	for item_id: StringName in every_item:
		var have := PackedStringArray()
		var lack := PackedStringArray()
		for world_seed: int in SEEDS:
			if (_per_seed_items[world_seed] as Dictionary).has(item_id):
				have.append(str(world_seed))
			else:
				lack.append(str(world_seed))
		if not lack.is_empty() and not have.is_empty():
			varying.append("'%s' is reachable on seed(s) %s but NOT on %s — biomes: %s" % [
				item_id, ", ".join(have), ", ".join(lack),
				" / ".join(_biome_summary_for(lack))
			])
	varying.sort()
	for line: String in varying:
		push_error("FAIL: SEED-DEPENDENT REACHABILITY: %s" % line)
	failures += varying.size()
	if varying.is_empty():
		print("PASS: every reachable item is reachable on ALL %d seeds — no run strands by luck" % SEEDS.size())


func _biome_summary_for(seed_labels: PackedStringArray) -> PackedStringArray:
	var summaries := PackedStringArray()
	for label: String in seed_labels:
		var world_seed: int = int(label)
		summaries.append("%d has [%s]" % [world_seed, ", ".join(_per_seed_biomes.get(world_seed, PackedStringArray()))])
	return summaries


# ── The world half: what this island actually offers ─────────────────────────────────────────────


## Every biome the generator really produces for this seed, sampled through the SAME noise functions
## the world builds from rather than assumed from the content files.
func _biomes_for_seed(world_seed: int) -> Dictionary[StringName, bool]:
	var biome_defs: Array = (registry.get(&"biomes") as Dictionary).values()
	var noise_set: Variant = BiomeMap.make_noise_set(world_seed)
	var found: Dictionary[StringName, bool] = {}
	var radius: float = IslandHeightmap.ISLAND_RADIUS
	var x: float = -radius
	while x <= radius:
		var z: float = -radius
		while z <= radius:
			if x * x + z * z <= radius * radius:
				var id: StringName = BiomeMap.biome_at_from_set(x, z, noise_set, world_seed, biome_defs)
				if id != &"":
					found[id] = true
			z += BIOME_SAMPLE_STEP_M
		x += BIOME_SAMPLE_STEP_M
	return found


## Every HarvestableDef a scatter table can place on an island carrying these biomes. Deduplicated by
## definition, because many assets share one (`HarvestLibrary`'s prefix rules map three pinecone
## exports onto one definition, for instance).
func _placed_harvestables(biomes: Dictionary) -> Array[Resource]:
	var paths: Dictionary[String, bool] = {}
	for table: Variant in (registry.get(&"scatter_tables") as Dictionary).values():
		var biome_id := StringName(String(table.get(&"biome_id")))
		# An empty biome_id is a table with no biome restriction — it places anywhere.
		if biome_id != &"" and not biomes.has(biome_id):
			continue
		for entry: Variant in (table.get(&"entries") as Array):
			if entry == null:
				continue
			var path: String = HARVEST_LIBRARY.definition_path_for(StringName(String(entry.get(&"asset"))))
			if not path.is_empty():
				paths[path] = true
	var definitions: Array[Resource] = []
	for path: String in paths:
		var definition: Resource = load(path)
		if definition != null:
			definitions.append(definition)
	return definitions


func _loot_table_items(tier: StringName) -> Array[StringName]:
	var table: Resource = registry.call(&"get_loot_table", tier)
	var found: Array[StringName] = []
	if table == null:
		return found
	# Both arrays, and ITEM entries only: a POWERUP entry grants a powerup, not an item, so counting
	# it as a source would report powerup ids as reachable items and mask a real gap.
	for group: String in ["entries", "guaranteed"]:
		for entry: Variant in (table.get(StringName(group)) as Array):
			if entry == null:
				continue
			if int(entry.get(&"kind")) != 0:
				continue
			var item_id := StringName(String(entry.get(&"item_id")))
			if item_id != &"" and _item_exists(item_id):
				found.append(item_id)
	return found


# ── Small shared queries ─────────────────────────────────────────────────────────────────────────


## The tool class holding this item lets you swing, or 0. Reads WeaponDef, which is where
## `CombatService` reads it from, so this cannot disagree with what a swing actually does.
func _tool_class_of(item_id: StringName) -> int:
	var weapon: Variant = (registry.get(&"weapons") as Dictionary).get(item_id)
	if weapon == null:
		return 0
	if int(weapon.get(&"harvest_power")) <= 0:
		# Power zero deals zero damage whatever its class (HarvestableDef.damage_from_tool), so it
		# is not a tool for reachability purposes however it is labelled.
		return 0
	return int(weapon.get(&"tool_class"))


func _tool_name(tool_class: int) -> String:
	match tool_class:
		1: return "Chop"
		2: return "Mine"
	return "bare-hands"


func _is_station_buildable(buildable: Variant) -> bool:
	return StringName(String(buildable.get(&"category"))) == &"station"


func _affordable(cost: Dictionary, items: Dictionary) -> bool:
	for item_id: Variant in cost:
		if not items.has(StringName(String(item_id))):
			return false
	return true


## D-217: an upgraded station satisfies its predecessor's requirement, so a recipe asking for
## `workbench` is served by a Reinforced Workbench too. Asked of CraftingService rather than
## reimplemented, so this check and the game cannot disagree about what counts.
func _station_available(required: StringName, stations: Dictionary) -> bool:
	if required == &"":
		return true
	if stations.has(required):
		return true
	var crafting: Node = root.get_node_or_null(^"CraftingService")
	if crafting == null:
		return false
	for station_id: StringName in stations:
		if bool(crafting.call(&"station_satisfies", station_id, required)):
			return true
	return false


func _inputs_satisfied(recipe: Variant, items: Dictionary) -> bool:
	for ingredient: Variant in (recipe.get(&"inputs") as Array):
		if ingredient == null:
			continue
		var ingredient_item: Resource = ingredient.get(&"item") as Resource
		if ingredient_item == null:
			continue
		if not items.has(StringName(String(ingredient_item.get(&"id")))):
			return false
	return true


func _recipes_producing(item_id: StringName) -> Array[Resource]:
	var found: Array[Resource] = []
	for recipe: Variant in (registry.get(&"recipes") as Dictionary).values():
		var output: Resource = recipe.get(&"output_item") as Resource
		if output != null and StringName(String(output.get(&"id"))) == item_id:
			found.append(recipe as Resource)
	return found


func _item_exists(item_id: StringName) -> bool:
	return (registry.get(&"items") as Dictionary).has(item_id)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	quit(0 if failures == 0 else 1)
