extends SceneTree

## F-487: every item a recipe or a buildable consumes must be obtainable somewhere in the world.
##
## flint shipped with no source at all — no harvestable yielded it, no loot table dropped it, no
## recipe made it — while the furnace and the woodcutting block, both tier-1 stations, listed it in
## their build cost. The forge branch of progression was therefore closed in every run, and nothing
## caught it because each individual cost read as plausible. This walks the content directories and
## fails on any consumed item id that nothing in the game produces.
##
## Sources are: a HarvestableDef's yield, any loot table entry, and any recipe's output.
## Consumers are: recipe inputs and buildable costs.

const CONTENT: Dictionary = {
	"recipes": "res://content/recipes",
	"buildables": "res://content/buildables",
	"harvestables": "res://content/harvestables",
	"loot": "res://content/loot",
}

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var sources: Dictionary = {}          # item id -> Array[String] of what produces it
	var consumers: Dictionary = {}        # item id -> Array[String] of what wants it

	for path: String in _tres_in(CONTENT["harvestables"]):
		var def: Resource = load(path)
		var yielded: StringName = StringName(def.get("yield_item_id"))
		if yielded != &"":
			_add(sources, yielded, "harvestable %s" % def.get("id"))

	for path: String in _tres_in(CONTENT["loot"]):
		var table: Resource = load(path)
		for item_id: StringName in _loot_item_ids(table):
			_add(sources, item_id, "loot %s" % table.get("id"))

	for path: String in _tres_in(CONTENT["recipes"]):
		var recipe: Resource = load(path)
		var out: Resource = recipe.get("output_item")
		if out != null:
			_add(sources, StringName(out.get("id")), "recipe %s" % recipe.get("id"))
		for ingredient: Resource in recipe.get("inputs"):
			var item: Resource = ingredient.get("item")
			if item != null:
				_add(consumers, StringName(item.get("id")), "recipe %s" % recipe.get("id"))

	for path: String in _tres_in(CONTENT["buildables"]):
		var buildable: Resource = load(path)
		var cost: Dictionary = buildable.get("cost")
		for item_id: StringName in cost:
			_add(consumers, item_id, "buildable %s" % buildable.get("id"))

	for item_id: StringName in consumers:
		var wanted_by: String = ", ".join(consumers[item_id])
		check(sources.has(item_id),
			"%s is obtainable (wanted by %s)" % [item_id, wanted_by])

	# A source that is only ever its own consumer's output is a circle: charcoal used to be made
	# from coal at the furnace, whose own build cost was coal. Flag any item whose every source is a
	# recipe that also consumes it.
	for item_id: StringName in sources:
		var self_fed: bool = true
		for producer: String in sources[item_id]:
			if not producer.begins_with("recipe "):
				self_fed = false
				break
			var recipe: Resource = load("res://content/recipes/%s.tres" % producer.trim_prefix("recipe "))
			var consumes_itself: bool = false
			for ingredient: Resource in recipe.get("inputs"):
				var item: Resource = ingredient.get("item")
				if item != null and StringName(item.get("id")) == item_id:
					consumes_itself = true
			if not consumes_itself:
				self_fed = false
				break
		check(not self_fed, "%s is not produced only by a recipe that consumes it" % item_id)

	print("\n%d item(s) obtainable, %d item(s) consumed" % [sources.size(), consumers.size()])
	print("%s — %d failure(s)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)


func _loot_item_ids(table: Resource) -> Array[StringName]:
	var out: Array[StringName] = []
	for property: Dictionary in table.get_property_list():
		var value: Variant = table.get(property["name"])
		if value is Array:
			for entry: Variant in value:
				if entry is Resource and entry.get("item_id") != null:
					var id: StringName = StringName(entry.get("item_id"))
					if id != &"":
						out.append(id)
	return out


func _add(into: Dictionary, key: StringName, who: String) -> void:
	if not into.has(key):
		into[key] = []
	if not into[key].has(who):
		into[key].append(who)


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
