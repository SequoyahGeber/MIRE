extends SceneTree

## Focused offline proof for task 2.6: registered recipe discovery, presentation status, host-derived
## station proximity, atomic input/output mutation, explicit confirmation, and rejection invariants.

var failures: int = 0
var confirmations: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var crafting: Node = root.get_node_or_null(^"CraftingService")
	check(registry != null, "Registry autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	check(crafting != null, "CraftingService autoload exists")
	if registry == null or inventory == null or crafting == null:
		finish()
		return
	crafting.get("craft_confirmed").connect(_on_craft_confirmed)

	check(bool(registry.call("has_item", &"stone_axe")), "stone axe item is registered")
	check(bool(registry.call("has_recipe", &"stone_axe")), "stone axe recipe is registered")
	var recipes: Array = crafting.call("recipes_for_station", &"workbench")
	check(recipes.size() == 1, "workbench exposes the one vertical-slice recipe")
	var recipe: Resource = recipes[0] as Resource
	check(recipe != null and StringName(recipe.get("id")) == &"stone_axe",
		"recipe discovery is deterministic")

	var player := Node3D.new()
	player.name = "CraftingCheckPlayer"
	player.add_to_group(&"players")
	root.add_child(player)
	var workbench := Node3D.new()
	workbench.name = "CraftingCheckWorkbench"
	workbench.position = Vector3(3.0, 0.0, 0.0)
	workbench.set_meta(&"asset", "station_workbench_primitive")
	workbench.add_to_group(&"playtest_hollow_asset")
	root.add_child(workbench)

	var status: Dictionary = crafting.call("local_recipe_status", &"stone_axe")
	check(bool(status.get("known", false)), "local recipe status knows registered recipe")
	check(bool(status.get("at_station", false)), "local status finds the nearby workbench")
	check(not bool(status.get("has_ingredients", true)), "local status reports missing ingredients")
	var missing: Dictionary = status.get("missing", {}) as Dictionary
	check(int(missing.get(&"log", 0)) == 2 and int(missing.get(&"stone", 0)) == 3,
		"local status reports exact missing counts")

	check(bool(inventory.call("host_add", 1, &"log", 2)), "host grants recipe logs")
	check(bool(inventory.call("host_add", 1, &"stone", 3)), "host grants recipe stone")
	status = crafting.call("local_recipe_status", &"stone_axe")
	check(bool(status.get("can_request", false)), "recipe becomes requestable at the workbench")
	var revision_before: int = int(inventory.call("local_revision"))
	var request_id: int = int(crafting.call("request_craft", &"stone_axe"))
	check(request_id > 0, "craft request returns a request id")
	check(bool(_confirmation(request_id).get("accepted", false)), "valid craft is explicitly confirmed")
	check(int(inventory.call("local_revision")) == revision_before + 1,
		"craft commits exactly one inventory revision")
	check(int(inventory.call("local_count", &"log")) == 0, "craft removes exact log cost")
	check(int(inventory.call("local_count", &"stone")) == 0, "craft removes exact stone cost")
	check(int(inventory.call("local_count", &"stone_axe")) == 1, "craft grants one stone axe")

	revision_before = int(inventory.call("local_revision"))
	request_id = int(crafting.call("request_craft", &"stone_axe"))
	check(not bool(_confirmation(request_id).get("accepted", true)), "missing ingredients are rejected")
	check(int(inventory.call("local_revision")) == revision_before,
		"rejected ingredient check publishes no inventory revision")
	check(int(inventory.call("local_count", &"stone_axe")) == 1,
		"rejected craft neither duplicates nor removes output")

	check(bool(inventory.call("host_add", 1, &"log", 2)), "host restores logs for range check")
	check(bool(inventory.call("host_add", 1, &"stone", 3)), "host restores stone for range check")
	player.position = Vector3(7.0, 0.0, 0.0)
	status = crafting.call("local_recipe_status", &"stone_axe")
	check(not bool(status.get("at_station", true)), "local status detects an out-of-range workbench")
	revision_before = int(inventory.call("local_revision"))
	request_id = int(crafting.call("request_craft", &"stone_axe"))
	check(not bool(_confirmation(request_id).get("accepted", true)), "host rejects out-of-range craft")
	check(int(inventory.call("local_revision")) == revision_before,
		"range rejection leaves ingredients and revision untouched")
	check(int(inventory.call("local_count", &"log")) == 2, "range rejection preserves logs")
	check(int(inventory.call("local_count", &"stone")) == 3, "range rejection preserves stone")

	request_id = int(crafting.call("request_craft", &"missing_recipe"))
	check(not bool(_confirmation(request_id).get("accepted", true)), "unknown recipe is rejected")
	check(String(_confirmation(request_id).get("detail", "")).contains("unknown recipe"),
		"unknown recipe rejection is readable")

	print("CRAFTING_CHECK confirmations=%d failures=%d" % [confirmations.size(), failures])
	finish()


func _on_craft_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	confirmations.append({"request_id": request_id, "accepted": accepted, "detail": detail})


func _confirmation(request_id: int) -> Dictionary:
	for result: Dictionary in confirmations:
		if int(result.get("request_id", -1)) == request_id:
			return result
	return {}


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
