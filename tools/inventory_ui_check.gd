extends SceneTree

## @verify windowed — this check renders both inventory views and measures them at a phone width,
## so `agent verify` must launch it with a framebuffer instead of the `--headless` it injects by
## default (F-556).

## Focused task 2.5 proof: the autoload renders both views, follows authoritative snapshots,
## routes moves through InventoryService, restores cursor ownership, and fits a phone-width viewport.

var failures: int = 0
var confirmations: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var ui: Node = root.get_node_or_null(^"InventoryUI")
	check(inventory != null, "InventoryService autoload exists")
	check(ui != null, "InventoryUI autoload exists")
	if inventory == null or ui == null:
		finish()
		return

	inventory.get("operation_confirmed").connect(_on_confirmed)
	check(int(ui.call("inventory_slot_view_count")) == 24, "inventory grid renders 24 backpack slots")
	check(int(ui.call("hotbar_slot_view_count")) == 8, "hotbar renders eight additional slots")
	check(not bool(ui.call("is_inventory_open")), "inventory panel starts closed")
	check((ui.get_node(^"InventoryUIRoot/HotbarCenter") as Control).visible,
		"hotbar remains visible while the inventory is closed")

	# F-382: a grant lands in the HOTBAR first (store slot 24 = hotbar view 0), not the backpack.
	check(bool(inventory.call("host_add", 1, &"log", 3)), "host grants test logs")
	check(ui.call("displayed_item_id", 0, true) == &"log", "grid follows authoritative item id")
	check(int(ui.call("displayed_amount", 0, true)) == 3, "grid follows authoritative amount")
	check(ui.call("displayed_item_id", 0, false) == &"",
		"hotbar grants do not alias into backpack zero")

	# Drag it out of the hotbar and into the backpack. `request_slot_move` speaks absolute store
	# indices, so the source is 24 (hotbar view 0) and the destination is backpack view 10.
	var revision_before: int = int(inventory.call("local_revision"))
	var request_id: int = int(ui.call("request_slot_move", 24, 10))
	check(request_id > 0, "drag/drop seam returns an InventoryService request id")
	check(_confirmation(request_id).get("accepted", false), "offline authority confirms the UI move")
	check(int(inventory.call("local_revision")) == revision_before + 1,
		"accepted UI move advances the authoritative revision once")
	check(ui.call("displayed_item_id", 0, true) == &"", "source view clears after snapshot")
	check(ui.call("displayed_item_id", 10, false) == &"log", "destination view updates after snapshot")
	check(int(ui.call("displayed_amount", 10, false)) == 3, "destination preserves the stack amount")

	revision_before = int(inventory.call("local_revision"))
	request_id = int(ui.call("request_slot_move", 0, 1))
	check(not bool(_confirmation(request_id).get("accepted", true)), "invalid UI move is rejected explicitly")
	check(int(inventory.call("local_revision")) == revision_before,
		"rejected UI move does not predict or publish a revision")
	check(String(ui.call("status_text")) == "move rejected", "rejection is visible in the inventory")
	var hotbar_views: Array = ui.get("_hotbar_slots") as Array
	var drag_payload: Dictionary = {
		"kind": &"inventory_slot", "from_index": 10, "item_id": &"log"
	}
	check(
		bool((hotbar_views[0] as Control).call("_can_drop_data", Vector2.ZERO, drag_payload)),
		"separate hotbar slot accepts the backpack drag payload"
	)
	(hotbar_views[0] as Control).call("_drop_data", Vector2.ZERO, drag_payload)
	check(ui.call("displayed_item_id", 10, false) == &"", "hotbar drop clears the backpack source")
	check(ui.call("displayed_item_id", 0, true) == &"log", "hotbar drop targets authoritative slot 24")
	var authoritative_slots: Array = inventory.call("local_slots")
	check((authoritative_slots[0] as Dictionary).is_empty(), "backpack slot zero remains independent")
	check(StringName(String((authoritative_slots[24] as Dictionary).get("item_id", ""))) == &"log",
		"hotbar zero owns a distinct stable dictionary")

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	ui.call("set_open", true)
	check(bool(ui.call("is_inventory_open")), "inventory panel opens")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "opening releases the cursor")
	check(ui.is_in_group(&"blocks_gameplay_input"), "open inventory blocks local gameplay input")
	ui.call("select_hotbar_slot", 6)
	check(int(ui.call("selected_hotbar_slot")) == 6, "number-key selection seam is stable")
	ui.call("set_open", false)
	check(not ui.is_in_group(&"blocks_gameplay_input"), "closed inventory releases gameplay input")
	check(
		Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or DisplayServer.get_name() == "headless",
		"closing completes (headless backends cannot retain captured mouse mode)"
	)

	ui.call("_apply_layout_for_width", 375.0)
	await process_frame
	check(int(ui.call("inventory_columns")) == 6, "phone-width inventory reflows to six columns")
	var hotbar_panel := ui.get_node(^"InventoryUIRoot/HotbarCenter/HotbarPanel") as Control
	check(hotbar_panel.size.x <= 375.0, "phone-width hotbar keeps all eight slots on screen")

	print("INVENTORY_UI_CHECK confirmations=%d failures=%d" % [confirmations.size(), failures])
	finish()


func _on_confirmed(request_id: int, accepted: bool, detail: String) -> void:
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
