extends SceneTree

## F-522: a run must be able to open with nothing in hand.
##
## `tools/resource_reachability_check.gd` asks whether *something* in the game produces each
## consumed item. That is not enough to catch a circular lock, and one shipped: the workbench cost
## `log`, every `log` source is `required_tool = 1`, and the axe that satisfies CHOP is a workbench
## recipe. Every ingredient had a source; the run still could not start.
##
## This walks the progression graph forward from an EMPTY inventory instead. Bare hands can harvest
## anything whose definition is `required_tool = 0`; that opens the buildables you can afford, which
## stand up stations, which unlock recipes, whose outputs are tools that open harvestables gated on
## a higher tool class — repeat until the frontier stops growing. Anything outside the closure is
## unreachable in a real run no matter how plausible its cost reads.

const HARVESTABLES_DIR: String = "res://content/harvestables"
const RECIPES_DIR: String = "res://content/recipes"
const BUILDABLES_DIR: String = "res://content/buildables"
const WEAPONS_DIR: String = "res://content/weapons"

## The rung the report is about: what a party with nothing must be able to reach unaided.
const BOOTSTRAP: Array[StringName] = [&"workbench", &"wooden_axe", &"wooden_pickaxe"]

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	# tool class -> the item ids that grant it, so holding one opens that class of harvestable.
	var tool_grants: Dictionary[int, Array] = {}
	for path: String in _tres_in(WEAPONS_DIR):
		var weapon: Resource = load(path)
		var tool_class: int = int(weapon.get(&"tool_class"))
		if tool_class <= 0:
			continue
		if not tool_grants.has(tool_class):
			tool_grants[tool_class] = []
		tool_grants[tool_class].append(StringName(weapon.get(&"item_id")))

	# required_tool -> the item ids harvesting it yields.
	var harvest_yields: Dictionary[int, Array] = {}
	for path: String in _tres_in(HARVESTABLES_DIR):
		var definition: Resource = load(path)
		var required: int = int(definition.get(&"required_tool"))
		var yielded := StringName(definition.get(&"yield_item_id"))
		if yielded == &"":
			continue
		if not harvest_yields.has(required):
			harvest_yields[required] = []
		harvest_yields[required].append(yielded)

	var recipes: Array[Resource] = _load_all(RECIPES_DIR)
	var buildables: Array[Resource] = _load_all(BUILDABLES_DIR)

	# The frontier. Bare hands are tool class 0 from the first frame (CombatService's `unarmed`).
	var held_tools: Dictionary[int, bool] = {0: true}
	var items: Dictionary[StringName, bool] = {}
	var stations: Dictionary[StringName, bool] = {}
	var built: Dictionary[StringName, bool] = {}

	var order: Array[String] = []
	var growing: bool = true
	while growing:
		growing = false

		for tool_class: int in harvest_yields:
			if not held_tools.has(tool_class):
				continue
			for item_id: StringName in harvest_yields[tool_class]:
				if _gain(items, item_id):
					order.append("harvest (tool %d) -> %s" % [tool_class, item_id])
					growing = true

		for buildable: Resource in buildables:
			var buildable_id := StringName(buildable.get(&"id"))
			if built.has(buildable_id):
				continue
			var cost: Dictionary = buildable.get(&"cost")
			if not _all_present(items, cost.keys()):
				continue
			built[buildable_id] = true
			order.append("build -> %s" % buildable_id)
			growing = true
			# A station buildable stands up the station its recipes name. The two share an id
			# throughout `content/`, which is what `systems/crafting` already relies on.
			if StringName(buildable.get(&"category")) == &"station":
				stations[buildable_id] = true

		for recipe: Resource in recipes:
			var output: Resource = recipe.get(&"output_item")
			if output == null:
				continue
			var output_id := StringName(output.get(&"id"))
			if items.has(output_id):
				continue
			var station := StringName(recipe.get(&"station"))
			if station != &"" and not stations.has(station):
				continue
			var inputs: Array[StringName] = []
			for ingredient: Resource in recipe.get(&"inputs"):
				var item: Resource = ingredient.get(&"item")
				if item != null:
					inputs.append(StringName(item.get(&"id")))
			if not _all_present(items, inputs):
				continue
			items[output_id] = true
			order.append("craft%s -> %s" % [" at %s" % station if station != &"" else "", output_id])
			growing = true

		for tool_class: int in tool_grants:
			if held_tools.has(tool_class):
				continue
			for item_id: StringName in tool_grants[tool_class]:
				if items.has(item_id):
					held_tools[tool_class] = true
					order.append("hold %s -> tool class %d opens" % [item_id, tool_class])
					growing = true
					break

	for step: String in order:
		print("  %s" % step)

	for id: StringName in BOOTSTRAP:
		check(items.has(id) or built.has(id),
			"a party holding nothing can reach '%s'" % id)

	# The whole tool ladder has to open, not only the first rung — a later tier locked behind an
	# ingredient nothing reachable produces is the same class of bug one step further along.
	for tool_class: int in tool_grants:
		check(held_tools.has(tool_class),
			"tool class %d is reachable (granted by %s)"
				% [tool_class, ", ".join(_to_strings(tool_grants[tool_class]))])

	print("\nreached %d item(s), %d buildable(s), %d station(s)"
		% [items.size(), built.size(), stations.size()])
	print("%s — %d failure(s)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)


func _gain(items: Dictionary[StringName, bool], item_id: StringName) -> bool:
	if items.has(item_id):
		return false
	items[item_id] = true
	return true


func _all_present(items: Dictionary[StringName, bool], wanted: Array) -> bool:
	for item_id: Variant in wanted:
		if not items.has(StringName(item_id)):
			return false
	return true


func _to_strings(ids: Array) -> Array[String]:
	var out: Array[String] = []
	for id: Variant in ids:
		out.append(String(id))
	return out


func _load_all(dir_path: String) -> Array[Resource]:
	var out: Array[Resource] = []
	for path: String in _tres_in(dir_path):
		var resource: Resource = load(path)
		if resource != null:
			out.append(resource)
	return out


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


func check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
		return
	failures += 1
	printerr("FAIL: %s" % label)
