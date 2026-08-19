extends SceneTree

## Focused task 2.7 proof: the workbench panel only opens in range, renders authoritative
## requirements, routes crafts through CraftingService, never predicts an inventory change, shows the
## host's rejection verbatim, and gives the cursor back when it closes.

var failures: int = 0
var confirmations: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var crafting: Node = root.get_node_or_null(^"CraftingService")
	var ui: Node = root.get_node_or_null(^"CraftingUI")
	check(inventory != null, "InventoryService autoload exists")
	check(crafting != null, "CraftingService autoload exists")
	check(ui != null, "CraftingUI autoload exists")
	if inventory == null or crafting == null or ui == null:
		finish()
		return
	crafting.get("craft_confirmed").connect(_on_craft_confirmed)

	check(int(ui.call("recipe_row_count")) == 0, "no rows are built for a station nobody is near yet")
	check(ui.call("current_station_id") == &"", "no station is identified at boot")
	check(not bool(ui.call("is_open")), "crafting panel starts closed")
	check(not bool(ui.call("is_station_in_range")), "no station is in range at boot")
	check(not bool(ui.call("is_prompt_visible")), "interact prompt is hidden away from a workbench")
	check(not bool(ui.call("try_open_station")), "interact cannot open a panel with no station")
	check(not bool(ui.call("is_open")), "refused interact leaves the panel closed")

	var player := Node3D.new()
	player.name = "CraftingUICheckPlayer"
	player.add_to_group(&"players")
	root.add_child(player)
	var workbench := Node3D.new()
	workbench.name = "CraftingUICheckWorkbench"
	workbench.position = Vector3(3.0, 0.0, 0.0)
	workbench.set_meta(&"asset", "station_workbench_primitive")
	workbench.add_to_group(&"playtest_hollow_asset")
	root.add_child(workbench)

	ui.call("poll_station")
	check(bool(ui.call("is_station_in_range")), "range poll finds the mapped workbench")
	check(ui.call("current_station_id") == &"workbench", "range poll identifies it as the workbench")
	# The workbench carries 11 recipes now (tasks 3.2-3.4 grew it past task 2.6's original one), and
	# recipes_for_station() orders them alphabetically by id, not insertion order — so stone_axe is
	# not necessarily row 0 (F-167 hit the identical trap in crafting_net_check.gd). Find its row by
	# id instead of hardcoding an index.
	check(int(ui.call("recipe_row_count")) > 0, "workbench renders its registered recipes")
	var axe_row: int = _row_for(ui, &"stone_axe")
	check(axe_row >= 0, "stone_axe is one of the workbench's registered recipes")
	check(bool(ui.call("is_prompt_visible")), "interact prompt appears in range")
	check(ui.call("recipe_requirement_text", axe_row) == "0/2 Log  ·  0/3 Stone",
		"requirements render have-over-need from the authoritative snapshot")
	check(not bool(ui.call("is_recipe_craftable", axe_row)), "recipe is not craftable without materials")
	check(bool(ui.call("craft_button_disabled", axe_row)), "craft button is disabled without materials")

	check(bool(ui.call("try_open_station")), "interact opens the panel at the workbench")
	check(bool(ui.call("is_open")), "crafting panel opens")
	check(ui.is_in_group(&"blocks_gameplay_input"), "open workbench blocks local gameplay input")
	check(not bool(ui.call("is_prompt_visible")), "prompt hides while the panel owns the screen")

	var revision_before: int = int(inventory.call("local_revision"))
	var request_id: int = int(ui.call("request_craft_at", axe_row))
	check(request_id > 0, "craft button returns a CraftingService request id")
	check(not bool(_confirmation(request_id).get("accepted", true)),
		"host rejects a craft the disabled button only discouraged")
	check(int(inventory.call("local_revision")) == revision_before,
		"rejected craft publishes no inventory revision")
	check(String(ui.call("status_text")).contains("missing ingredients"),
		"host rejection detail is shown verbatim")

	check(bool(inventory.call("host_add", 1, &"log", 2)), "host grants recipe logs")
	check(bool(inventory.call("host_add", 1, &"stone", 3)), "host grants recipe stone")
	check(ui.call("recipe_requirement_text", axe_row) == "2/2 Log  ·  3/3 Stone",
		"snapshot signal refreshes requirements without a reopen")
	check(bool(ui.call("is_recipe_craftable", axe_row)), "recipe becomes craftable at the workbench")
	check(not bool(ui.call("craft_button_disabled", axe_row)), "craft button enables with materials")

	revision_before = int(inventory.call("local_revision"))
	request_id = int(ui.call("request_craft_at", axe_row))
	check(bool(_confirmation(request_id).get("accepted", false)), "valid craft is explicitly confirmed")
	check(int(inventory.call("local_revision")) == revision_before + 1,
		"accepted craft commits exactly one authoritative revision")
	check(int(inventory.call("local_count", &"stone_axe")) == 1, "craft grants one stone axe")
	check(String(ui.call("status_text")).contains("crafted"), "acceptance is visible in the panel")
	check(ui.call("recipe_requirement_text", axe_row) == "0/2 Log  ·  0/3 Stone",
		"spent ingredients are re-read from the host snapshot")
	check(not bool(ui.call("is_recipe_craftable", axe_row)), "spent recipe is no longer craftable")

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	ui.call("set_open", false)
	ui.call("set_open", true)
	check(bool(ui.call("is_open")), "panel reopens after being closed")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "opening releases the cursor")

	player.position = Vector3(9.0, 0.0, 0.0)
	ui.call("poll_station")
	check(not bool(ui.call("is_open")), "walking out of range closes the panel")
	check(not ui.is_in_group(&"blocks_gameplay_input"), "closed workbench releases gameplay input")
	check(not bool(ui.call("is_prompt_visible")), "prompt stays hidden out of range")
	check(String(ui.call("status_text")).contains("stepped away"), "leaving the station explains itself")
	check(
		Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or DisplayServer.get_name() == "headless",
		"closing completes (headless backends cannot retain captured mouse mode)"
	)

	player.position = Vector3.ZERO
	ui.call("poll_station")
	var inventory_ui: Node = root.get_node_or_null(^"InventoryUI")
	check(inventory_ui != null, "InventoryUI autoload exists")
	if inventory_ui != null:
		inventory_ui.call("set_open", true)
		check(not bool(ui.call("try_open_station")), "interact is ignored while another UI owns the cursor")
		ui.call("poll_station")
		check(not bool(ui.call("is_prompt_visible")), "prompt yields to another cursor-owning UI")
		inventory_ui.call("set_open", false)
		ui.call("poll_station")
		check(bool(ui.call("is_prompt_visible")), "prompt returns once the other UI closes")

	ui.call("_apply_layout_for_width", 375.0)
	await process_frame
	check(bool(ui.call("try_open_station")), "panel reopens after the other UI closed")
	await process_frame
	var panel := ui.get_node(^"CraftingUIRoot/CraftingCenter/CraftingPanel") as Control
	check(panel.size.x <= 375.0, "phone-width workbench panel stays on screen")
	ui.call("set_open", false)

	# --- Task 3.1: switching stations rebuilds rows, and a timed craft shows live progress ---
	var furnace := Node3D.new()
	furnace.name = "CraftingUICheckFurnace"
	furnace.position = Vector3(40.0, 0.0, 0.0)
	furnace.set_meta(&"asset", "station_stone_furnace")
	furnace.add_to_group(&"playtest_hollow_asset")
	root.add_child(furnace)

	player.position = Vector3(40.0, 0.0, 0.0)
	ui.call("poll_station")
	check(ui.call("current_station_id") == &"furnace",
		"walking up to the furnace switches the identified station")
	# The furnace carries two recipes (charcoal, iron_ingot) since task 3.3 added charcoal; sorted
	# alphabetically, iron_ingot is not row 0. Same F-167-shaped find-by-id as the workbench above.
	check(int(ui.call("recipe_row_count")) > 0, "furnace panel renders its registered recipes")
	var ingot_row: int = _row_for(ui, &"iron_ingot")
	check(ingot_row >= 0, "iron_ingot is one of the furnace's registered recipes")

	check(bool(inventory.call("host_add", 1, &"iron_ore", 2)), "host grants iron ore for the furnace")
	ui.call("poll_station")
	check(bool(ui.call("is_recipe_craftable", ingot_row)), "furnace recipe becomes craftable with ore in hand")
	check(bool(ui.call("try_open_station")), "interact opens the panel at the furnace")

	var timed_request_id: int = int(ui.call("request_craft_at", ingot_row))
	check(timed_request_id > 0, "timed craft button returns a request id")
	await create_timer(0.3).timeout
	check(String(ui.call("status_text")).contains("Crafting"), "panel shows live progress for a timed craft")
	check(_confirmation(timed_request_id).is_empty(),
		"timed craft has not confirmed yet at 0.3s of a 2s timer")

	await create_timer(2.3).timeout
	check(not _confirmation(timed_request_id).is_empty(), "timed craft confirms once its timer elapses")
	check(bool(_confirmation(timed_request_id).get("accepted", false)), "timed craft is accepted")
	check(String(ui.call("status_text")).contains("crafted"), "panel shows the completed craft")
	check(int(inventory.call("local_count", &"iron_ingot")) == 1, "furnace craft grants one iron ingot")
	ui.call("set_open", false)

	print("CRAFTING_UI_CHECK confirmations=%d failures=%d" % [confirmations.size(), failures])
	finish()


func _on_craft_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	confirmations.append({"request_id": request_id, "accepted": accepted, "detail": detail})


## Row index for `recipe_id` among whatever is currently displayed, or -1 if it is not shown.
## Content grows the row list over time and recipes_for_station() orders alphabetically by id, so a
## recipe's row index is never assumed — this is the only thing that finds it (F-171/F-167).
func _row_for(ui: Node, recipe_id: StringName) -> int:
	for i in range(int(ui.call("recipe_row_count"))):
		if StringName(ui.call("displayed_recipe_id", i)) == recipe_id:
			return i
	return -1


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
