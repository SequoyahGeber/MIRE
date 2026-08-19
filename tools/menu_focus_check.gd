extends SceneTree

## F-209 proof: every menu that used to require a mouse click to open/select/close
## (MainMenu/SettingsMenu/LobbyMenu/InventoryUI/CraftingUI/UnlockMenu — ChestUI needed no change,
## see its own note below) now supports real gamepad/keyboard focus navigation: an initial
## grab_focus() on open, a focus_neighbor_* chain reachable by ui_up/ui_down/ui_left/ui_right, and
## ui_accept doing what a click would have.
##
## Events go through Input.parse_input_event() rather than being called directly against a node's
## own _input()/_gui_input() the way gamepad_check.gd drives gameplay actions. That style doesn't
## apply here: focus movement on ui_up/down/left/right is not something any of these panel scripts
## implement — it is Godot's own Viewport GUI input handling walking focus_neighbor_* for whichever
## Control currently holds keyboard focus. The only way to prove that actually works end to end is
## to put a real event through the real pipeline and read get_viewport().gui_get_focus_owner() back.
##
## ChestUI is untouched: it has no interactive Control at all (no buttons, nothing to drag) — E opens
## it and E/Esc closes it, both already gamepad-bound actions before this task, so there is nothing
## for a check here to prove.
##
## Run with: .agent/bin/agent godot --script tools/menu_focus_check.gd

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	await _check_main_menu()
	await _check_settings_menu()
	await _check_lobby_menu_idle()
	await _check_unlock_menu()
	await _check_crafting_ui()
	await _check_inventory_ui()

	print("\nMENU_FOCUS_CHECK failures=%d" % failures)
	finish()


# ── input helpers ─────────────────────────────────────────────────────────────────────────────────


func _tap(button_index: int) -> void:
	var press := InputEventJoypadButton.new()
	press.button_index = button_index
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	await process_frame
	var release := InputEventJoypadButton.new()
	release.button_index = button_index
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame


func _focused() -> Control:
	return root.get_viewport().gui_get_focus_owner()


## Taps `button_index` repeatedly, checking every landing is a control never seen before, until
## focus returns to `start` (a closed loop, proving every focus_neighbor_* link in the chain is
## correct in that direction) or `max_hops` is exceeded (a broken/missing link).
func _walk_loop(start: Control, button_index: int, max_hops: int, label: String) -> void:
	var visited: Array = [start]
	var current: Control = start
	var hops: int = 0
	while hops < max_hops:
		await _tap(button_index)
		current = _focused()
		hops += 1
		if current == start:
			break
		check(not visited.has(current), "%s: hop %d does not revisit an earlier control" % [label, hops])
		visited.append(current)
	check(current == start, "%s: chain forms one closed loop back to the start within %d hops" % [label, max_hops])


# ── MainMenu ──────────────────────────────────────────────────────────────────────────────────────


func _check_main_menu() -> void:
	print("\n== MainMenu: initial focus, D-pad chain, seed row hop, visible focus ring, ui_accept ==")
	var menu: Node = root.get_node_or_null(^"MainMenu")
	check(menu != null, "MainMenu autoload exists")
	if menu == null:
		return

	menu.call(&"set_open", true)
	await process_frame
	var seed_field: Control = _focused()
	check(seed_field != null and seed_field.name == "SeedField", "opening grabs the seed field")
	check(seed_field != null and seed_field.has_theme_stylebox_override(&"focus"),
		"the seed field carries a visible focus ring override")

	# ui_accept on SET (a real nonzero seed) is the one seed-row action whose resulting status_text()
	# is stable regardless of _refresh()'s own overwrite (its "Seed staged: N" is what _refresh()
	# recomputes from GameState too, since a nonzero value makes has_pending_seed() true) — RANDOM's
	# "Seed cleared" message gets immediately clobbered back to "This run's seed: N" by that same
	# _refresh() once mire_grid.gd has drawn a boot-time seed, which it already has by now.
	menu.call(&"set_seed_field_text", "12345")
	await _tap(JOY_BUTTON_DPAD_RIGHT)
	var set_button: Control = _focused()
	check(set_button is Button and (set_button as Button).text == "SET",
		"D-pad right from the seed field reaches the SET button")
	await _tap(JOY_BUTTON_A)
	check(String(menu.call(&"status_text")).begins_with("Seed staged: 12345"),
		"ui_accept on SET fires the same request_set_seed() a click would have")

	await _tap(JOY_BUTTON_DPAD_LEFT)
	check(_focused() == seed_field, "D-pad left returns to the seed field")

	await _tap(JOY_BUTTON_DPAD_UP)
	var quit_button: Control = _focused()
	check(quit_button is Button and (quit_button as Button).text == "QUIT",
		"D-pad up from the seed field wraps to QUIT (the chain's last entry)")
	check(quit_button.has_theme_stylebox_override(&"focus"), "QUIT carries a visible focus ring override")
	await _tap(JOY_BUTTON_DPAD_DOWN)
	check(_focused() == seed_field, "D-pad down from QUIT wraps back to the seed field")

	await _walk_loop(seed_field, JOY_BUTTON_DPAD_DOWN, 8, "MainMenu")

	menu.call(&"set_open", false)
	await process_frame


# ── SettingsMenu ──────────────────────────────────────────────────────────────────────────────────


func _check_settings_menu() -> void:
	print("\n== SettingsMenu: initial focus, slider ui_left/ui_right, full chain, CLOSE reachable ==")
	var menu: Node = root.get_node_or_null(^"SettingsMenu")
	check(menu != null, "SettingsMenu autoload exists")
	if menu == null:
		return

	menu.call(&"set_open", true)
	await process_frame
	var graphics: Control = _focused()
	check(graphics is OptionButton, "opening grabs the graphics preset OptionButton")

	await _tap(JOY_BUTTON_DPAD_DOWN)
	var master_slider: Control = _focused()
	check(master_slider is HSlider, "D-pad down from graphics reaches the master volume slider")
	var value_before: float = (master_slider as HSlider).value
	await _tap(JOY_BUTTON_DPAD_LEFT)
	var value_after: float = (master_slider as HSlider).value
	check(value_after < value_before,
		"ui_left on a focused HSlider decrements it through Godot's own Slider.gui_input (%.3f -> %.3f)"
			% [value_before, value_after])
	await _tap(JOY_BUTTON_DPAD_RIGHT)
	check(is_equal_approx((master_slider as HSlider).value, value_before),
		"ui_right restores the value ui_left just took off it")

	await _walk_loop(graphics, JOY_BUTTON_DPAD_DOWN, 40, "SettingsMenu")

	await _tap(JOY_BUTTON_DPAD_UP)
	var close_button: Control = _focused()
	check(close_button is Button and (close_button as Button).text == "CLOSE",
		"D-pad up from graphics (the chain's first entry) wraps to CLOSE (the chain's last entry)")
	check(close_button.has_theme_stylebox_override(&"focus"), "CLOSE carries a visible focus ring override")

	menu.call(&"set_open", false)
	await process_frame


# ── LobbyMenu (idle box only — see file header) ──────────────────────────────────────────────────


func _check_lobby_menu_idle() -> void:
	print("\n== LobbyMenu (idle): initial focus, join-row hop, host/join-field loop ==")
	var menu: Node = root.get_node_or_null(^"LobbyMenu")
	check(menu != null, "LobbyMenu autoload exists")
	if menu == null:
		return
	if bool(menu.call(&"is_open")):
		menu.call(&"set_open", false)
		await process_frame

	menu.call(&"set_open", true)
	await process_frame
	var join_field: Control = _focused()
	check(join_field != null and join_field.name == "JoinField", "opening grabs the join field (idle box)")
	check(join_field.has_theme_stylebox_override(&"focus"), "the join field carries a visible focus ring override")

	await _tap(JOY_BUTTON_DPAD_RIGHT)
	var paste_button: Control = _focused()
	check(paste_button is Button and (paste_button as Button).text == "PASTE",
		"D-pad right from the join field reaches PASTE")
	await _tap(JOY_BUTTON_DPAD_RIGHT)
	var join_button: Control = _focused()
	check(join_button is Button and (join_button as Button).text == "JOIN",
		"D-pad right from PASTE reaches JOIN")
	await _tap(JOY_BUTTON_DPAD_LEFT)
	await _tap(JOY_BUTTON_DPAD_LEFT)
	check(_focused() == join_field, "D-pad left twice returns to the join field")

	await _walk_loop(join_field, JOY_BUTTON_DPAD_DOWN, 4, "LobbyMenu idle box")

	menu.call(&"set_open", false)
	await process_frame


# ── UnlockMenu ────────────────────────────────────────────────────────────────────────────────────


func _check_unlock_menu() -> void:
	print("\n== UnlockMenu: initial focus, full BUY-button chain, CLOSE reachable ==")
	var menu: Node = root.get_node_or_null(^"UnlockMenu")
	check(menu != null, "UnlockMenu autoload exists")
	if menu == null:
		return
	check(int(menu.call(&"row_count")) > 0, "content ships at least one unlock to test the chain on")
	if int(menu.call(&"row_count")) == 0:
		return

	menu.call(&"set_open", true)
	await process_frame
	var first_buy: Control = _focused()
	check(first_buy is Button, "opening grabs the first BUY button")
	check(first_buy.has_theme_stylebox_override(&"focus"), "the first BUY button carries a visible focus ring override")

	await _walk_loop(first_buy, JOY_BUTTON_DPAD_DOWN, int(menu.call(&"row_count")) + 2, "UnlockMenu")

	await _tap(JOY_BUTTON_DPAD_UP)
	var close_button: Control = _focused()
	check(close_button is Button and (close_button as Button).text == "CLOSE",
		"D-pad up from the first BUY button wraps to CLOSE")

	menu.call(&"set_open", false)
	await process_frame


# ── CraftingUI ────────────────────────────────────────────────────────────────────────────────────


func _check_crafting_ui() -> void:
	print("\n== CraftingUI: initial focus on row 0, full recipe-row chain, ui_accept fires the craft ==")
	var ui: Node = root.get_node_or_null(^"CraftingUI")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(ui != null and inventory != null, "CraftingUI/InventoryService autoloads exist")
	if ui == null or inventory == null:
		return

	# Same stone_axe/workbench setup crafting_ui_check.gd uses to prove task 2.7's real seams — a
	# station registered in Registry, close enough for CraftingService.nearby_station_id() to find,
	# funded with exactly what stone_axe needs so its CRAFT button is enabled: ui_accept on a
	# DISABLED button correctly no-ops (Button's own gui_input skips activation while disabled), so
	# proving the accept path actually fires means testing it on a row that is not disabled.
	var player := Node3D.new()
	player.name = "MenuFocusCheckPlayer"
	player.add_to_group(&"players")
	root.add_child(player)
	var workbench := Node3D.new()
	workbench.name = "MenuFocusCheckWorkbench"
	workbench.position = Vector3(3.0, 0.0, 0.0)
	workbench.set_meta(&"asset", "station_workbench_primitive")
	workbench.add_to_group(&"playtest_hollow_asset")
	root.add_child(workbench)
	inventory.call(&"host_add", 1, &"log", 2)
	inventory.call(&"host_add", 1, &"stone", 3)
	await process_frame

	ui.call(&"poll_station")
	check(bool(ui.call(&"is_station_in_range")), "the workbench registers as in range")
	check(bool(ui.call(&"try_open_station")), "interact opens the panel at the workbench")
	await process_frame

	var recipe_count: int = int(ui.call(&"recipe_row_count"))
	check(recipe_count > 0, "the workbench renders at least one recipe row")
	if recipe_count == 0:
		player.queue_free()
		workbench.queue_free()
		return

	var first_row: Control = _focused()
	check(first_row is Button and (first_row as Button).text == "CRAFT",
		"opening the panel grabs row 0's CRAFT button")

	await _walk_loop(first_row, JOY_BUTTON_DPAD_DOWN, recipe_count + 2, "CraftingUI recipe rows")

	# recipes_for_station() orders alphabetically by id, not insertion order (F-167 hit the identical
	# trap in crafting_net_check.gd) — find stone_axe's row rather than assuming it is row 0.
	var stone_axe_row: int = -1
	for i: int in recipe_count:
		if ui.call(&"displayed_recipe_id", i) == &"stone_axe":
			stone_axe_row = i
			break
	check(stone_axe_row >= 0, "stone_axe is one of the workbench's registered recipes")
	if stone_axe_row < 0:
		player.queue_free()
		workbench.queue_free()
		return
	check(not bool(ui.call(&"craft_button_disabled", stone_axe_row)),
		"stone_axe's CRAFT button is enabled now that its materials are funded")

	# _walk_loop left focus back at row 0 (first_row) — step down to stone_axe's row.
	for i: int in stone_axe_row:
		await _tap(JOY_BUTTON_DPAD_DOWN)
	var stone_axe_before: int = int(inventory.call(&"local_count", &"stone_axe"))
	await _tap(JOY_BUTTON_A)
	check(int(inventory.call(&"local_count", &"stone_axe")) > stone_axe_before,
		"ui_accept on the enabled CRAFT button fires the same request_craft() a click would have")

	ui.call(&"set_open", false)
	await process_frame
	player.queue_free()
	workbench.queue_free()


# ── InventoryUI ───────────────────────────────────────────────────────────────────────────────────


func _check_inventory_ui() -> void:
	print("\n== InventoryUI: initial focus, cross-container D-pad hop, ui_accept pick-up/drop ==")
	var ui: Node = root.get_node_or_null(^"InventoryUI")
	var inventory_service: Node = root.get_node_or_null(^"InventoryService")
	var registry: Node = root.get_node_or_null(^"Registry")
	check(ui != null and inventory_service != null and registry != null,
		"InventoryUI/InventoryService/Registry autoloads exist")
	if ui == null or inventory_service == null or registry == null:
		return

	var item_id: StringName = &""
	var items: Dictionary = registry.get(&"items") as Dictionary
	for id: StringName in items:
		item_id = id
		break
	check(item_id != &"", "content ships at least one item to test carrying with")
	if item_id == &"":
		return

	inventory_service.call(&"host_add", 1, item_id, 1)
	await process_frame
	var hotbar_start: int = int(inventory_service.call(&"hotbar_start_index"))
	var from_index: int = -1
	for i: int in int(inventory_service.call(&"slot_count")):
		if StringName(inventory_service.call(&"local_item_id", i)) == item_id:
			from_index = i
			break
	check(from_index >= 0, "the added item appears in the local snapshot")
	if from_index < 0:
		return
	if from_index != hotbar_start:
		inventory_service.call(&"host_move_stack", 1, from_index, hotbar_start)
		await process_frame
	ui.call(&"select_hotbar_slot", 0)

	ui.call(&"set_open", true)
	await process_frame
	var hotbar_zero: Control = _focused()
	check(hotbar_zero != null and String(hotbar_zero.get(&"accessibility_name")).contains("Hotbar slot 1"),
		"opening the panel grabs hotbar slot 0 (the currently selected one)")

	await _tap(JOY_BUTTON_DPAD_UP)
	var grid_hop: Control = _focused()
	check(grid_hop != null and String(grid_hop.get(&"accessibility_name")).contains("Inventory slot"),
		"D-pad up from the hotbar crosses into the backpack grid (separate container tree)")
	await _tap(JOY_BUTTON_DPAD_DOWN)
	check(_focused() == hotbar_zero, "D-pad down from the grid returns to the same hotbar slot")

	check(int(ui.call(&"carrying_slot_index")) == -1, "nothing is carried yet")
	await _tap(JOY_BUTTON_A)
	check(int(ui.call(&"carrying_slot_index")) == hotbar_start,
		"ui_accept on an occupied slot picks it up (the gamepad equivalent of _get_drag_data)")

	await _tap(JOY_BUTTON_DPAD_RIGHT)
	var hotbar_one: Control = _focused()
	check(hotbar_one != null and String(hotbar_one.get(&"accessibility_name")).contains("Hotbar slot 2"),
		"D-pad right moves focus to the next hotbar slot while still carrying")
	await _tap(JOY_BUTTON_A)
	check(int(ui.call(&"carrying_slot_index")) == -1,
		"ui_accept on the destination slot drops it (the gamepad equivalent of _drop_data)")
	check(ui.call(&"displayed_item_id", 1, true) == item_id, "the carried stack actually landed in slot 1")
	check(ui.call(&"displayed_item_id", 0, true) == &"", "slot 0 is empty after the move")

	ui.call(&"set_open", false)
	await process_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
