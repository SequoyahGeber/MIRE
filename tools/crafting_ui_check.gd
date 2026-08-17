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

	check(int(ui.call("recipe_row_count")) == 1, "workbench renders the one registered recipe")
	check(ui.call("displayed_recipe_id", 0) == &"stone_axe", "row is keyed by the registered recipe id")
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
	check(bool(ui.call("is_prompt_visible")), "interact prompt appears in range")
	check(ui.call("recipe_requirement_text", 0) == "0/2 Log  ·  0/3 Stone",
		"requirements render have-over-need from the authoritative snapshot")
	check(not bool(ui.call("is_recipe_craftable", 0)), "recipe is not craftable without materials")
	check(bool(ui.call("craft_button_disabled", 0)), "craft button is disabled without materials")

	check(bool(ui.call("try_open_station")), "interact opens the panel at the workbench")
	check(bool(ui.call("is_open")), "crafting panel opens")
	check(ui.is_in_group(&"blocks_gameplay_input"), "open workbench blocks local gameplay input")
	check(not bool(ui.call("is_prompt_visible")), "prompt hides while the panel owns the screen")

	var revision_before: int = int(inventory.call("local_revision"))
	var request_id: int = int(ui.call("request_craft_at", 0))
	check(request_id > 0, "craft button returns a CraftingService request id")
	check(not bool(_confirmation(request_id).get("accepted", true)),
		"host rejects a craft the disabled button only discouraged")
	check(int(inventory.call("local_revision")) == revision_before,
		"rejected craft publishes no inventory revision")
	check(String(ui.call("status_text")).contains("missing ingredients"),
		"host rejection detail is shown verbatim")

	check(bool(inventory.call("host_add", 1, &"log", 2)), "host grants recipe logs")
	check(bool(inventory.call("host_add", 1, &"stone", 3)), "host grants recipe stone")
	check(ui.call("recipe_requirement_text", 0) == "2/2 Log  ·  3/3 Stone",
		"snapshot signal refreshes requirements without a reopen")
	check(bool(ui.call("is_recipe_craftable", 0)), "recipe becomes craftable at the workbench")
	check(not bool(ui.call("craft_button_disabled", 0)), "craft button enables with materials")

	revision_before = int(inventory.call("local_revision"))
	request_id = int(ui.call("request_craft_at", 0))
	check(bool(_confirmation(request_id).get("accepted", false)), "valid craft is explicitly confirmed")
	check(int(inventory.call("local_revision")) == revision_before + 1,
		"accepted craft commits exactly one authoritative revision")
	check(int(inventory.call("local_count", &"stone_axe")) == 1, "craft grants one stone axe")
	check(String(ui.call("status_text")).contains("crafted"), "acceptance is visible in the panel")
	check(ui.call("recipe_requirement_text", 0) == "0/2 Log  ·  0/3 Stone",
		"spent ingredients are re-read from the host snapshot")
	check(not bool(ui.call("is_recipe_craftable", 0)), "spent recipe is no longer craftable")

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

	print("CRAFTING_UI_CHECK confirmations=%d failures=%d" % [confirmations.size(), failures])
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
