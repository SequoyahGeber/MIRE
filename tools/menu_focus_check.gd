extends SceneTree

## F-209 proof: every menu that used to require a mouse click to open/select/close
## (MainMenu/SettingsScreen/LobbyMenu/InventoryUI/CraftingUI/UnlockMenu — ChestUI needed no change,
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
## F-216 added `_check_attunement_ui()`: AttunementUI (task 3.9's run-start role picker) was not in
## F-209's own file list and shipped with no gamepad focus support at all — worse than every panel
## above, since it has no Esc/dismiss path, so a bare controller could not get past it, full stop.
##
## Run with: .agent/bin/agent godot --script tools/menu_focus_check.gd

const SettingsScreen := preload("res://ui/frontend/settings_screen.gd")
const FocusRingSlider := preload("res://ui/menu/focus_ring_slider.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	# AttunementUI runs FIRST and deliberately: its background poll timer (attunement_ui.gd's
	# _poll_for_local_player, autostart, 0.5s) opens the picker for ANY node in the "players" group
	# with authority, not just a real player — and CraftingUI's own check below adds exactly such a
	# stand-in node for its station-range test. Running AttunementUI's check after that one let its
	# timer fire mid-CraftingUI-check and steal focus (F-216's grab_focus() addition made this an
	# actual failure, not just a silent extra shade). Once this check completes,
	# AttunementService.local_selection() is permanently non-empty, so the trigger's own early-return
	# guard (`_open or local_selection() != ""`) keeps it from ever firing again for the rest of this
	# script's run — going first is what makes every later check's own "players" group node safe.
	await _check_attunement_ui()
	await _check_main_menu()
	await _check_settings_screen()
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


# ── AttunementUI ──────────────────────────────────────────────────────────────────────────────────


## F-216: unlike every other panel above, this one has no Esc/dismiss path at all (see
## ui/attunement/attunement_ui.gd's file header) — a bare controller reaching this screen with no
## gamepad focus support cannot get past it, full stop. The chain/ring assertions below prove the
## same shape as the other panels; the closing assertion after ui_accept is the one that actually
## proves a bare controller can get past this screen, which is the whole point of the finding.
func _check_attunement_ui() -> void:
	print("\n== AttunementUI: initial focus, full CHOOSE-button chain (wraps), ui_accept fires the pick ==")
	var ui: Node = root.get_node_or_null(^"AttunementUI")
	var service: Node = root.get_node_or_null(^"AttunementService")
	var powerups: Node = root.get_node_or_null(^"PowerupService")
	check(ui != null and service != null and powerups != null,
		"AttunementUI/AttunementService/PowerupService autoloads exist")
	if ui == null or service == null or powerups == null:
		return

	var stand_in := Node3D.new()
	stand_in.name = "MenuFocusCheckAttunementPlayer"
	stand_in.add_to_group(&"players")
	root.add_child(stand_in)
	await process_frame
	ui.call(&"poll_now")
	check(bool(ui.call(&"is_open")), "the picker opened for the local player's first body")

	var role_count: int = int(ui.call(&"role_button_count"))
	check(role_count > 0, "content ships at least one role to test the chain on")
	if role_count == 0:
		stand_in.queue_free()
		return

	var first_button: Control = _focused()
	check(first_button is Button, "opening grabs the first ROLE_ORDER CHOOSE button")
	check(first_button != null and first_button.has_theme_stylebox_override(&"focus"),
		"the first CHOOSE button carries a visible focus ring override")

	await _walk_loop(first_button, JOY_BUTTON_DPAD_DOWN, role_count + 2, "AttunementUI")

	# host_clear keeps this a fresh pick regardless of what earlier checks in this run granted the
	# host peer — AttunementService.request_select() refuses a second pick outright (respec is out
	# of scope, see attunement_service.gd), so a stale grant here would silently no-op ui_accept
	# below instead of proving it fires.
	powerups.call(&"host_clear", NetConfig.HOST_PEER_ID)
	await _tap(JOY_BUTTON_A)
	check(not bool(ui.call(&"is_open")),
		"ui_accept on the focused CHOOSE button fires the same request_select() a click would have, closing the picker on acceptance — this is the only way past this screen with no mouse")

	stand_in.queue_free()


# ── SettingsScreen ────────────────────────────────────────────────────────────────────────────────


## F-418 restores the coverage F-413 deleted. Retiring the legacy `SettingsMenu` panel was right;
## deleting its focus proof along with it was not, because the tabbed screen that replaced it has
## strictly MORE focus surface — six tab buttons, a scrolling page host, and a footer outside the
## scroll viewport — and `settings_screen_check.gd` only reads `menu_default_focus()` back rather
## than driving real input through it.
##
## Pushed through `MenuStack` and not parented to the root, because the stack is what calls
## `menu_default_focus()` and grabs it (`menu_stack.gd:362-367`); a screen added any other way never
## gets its initial focus and would make this whole section prove nothing.
func _check_settings_screen() -> void:
	print("\n== SettingsScreen: initial focus, tab traversal, slider ui_left/ui_right, footer reachable ==")
	var stack: Node = root.get_node_or_null(^"MenuStack")
	check(stack != null, "MenuStack autoload exists")
	if stack == null:
		return

	var screen: Control = SettingsScreen.new()
	stack.call(&"push", screen, false)
	await process_frame
	await process_frame

	var opened: Control = _focused()
	check(opened != null, "pushing the screen focuses a control rather than leaving focus nowhere")
	check(opened != null and _has_visible_focus(opened),
		"the control it lands on draws a visible focus ring")

	# ── the tab bar ──
	# `show_tab()` disables the ACTIVE tab's button, so the tab a controller can move to is always
	# one of the others; the bar is wired with `wire_row()`, i.e. left/right only.
	var tabs: Array[Button] = _settings_tab_buttons(screen)
	check(tabs.size() == SettingsScreen.TABS.size(),
		"every tab in TABS has a button (%d of %d)" % [tabs.size(), SettingsScreen.TABS.size()])

	for index: int in tabs.size():
		if tabs[index].disabled:
			continue
		tabs[index].grab_focus()
		await process_frame
		check(_focused() == tabs[index],
			"the %s tab button can hold focus" % SettingsScreen.TABS[index])
		break

	# Walking the bar with ui_right has to reach the far tab, or the last tabs are mouse-only.
	var start: Button = null
	for button: Button in tabs:
		if not button.disabled:
			start = button
			break
	if start != null:
		start.grab_focus()
		await process_frame
		var reached: Array[String] = []
		for _hop: int in tabs.size() + 2:
			var here: Control = _focused()
			if here is Button and tabs.has(here as Button):
				var name_of: String = SettingsScreen.TABS[tabs.find(here as Button)]
				if not reached.has(name_of):
					reached.append(name_of)
			await _tap(JOY_BUTTON_DPAD_RIGHT)
		check(reached.has(SettingsScreen.TABS[SettingsScreen.TABS.size() - 1]),
			"ui_right walks the tab bar as far as %s — the last tabs are not mouse-only (reached %s)"
				% [SettingsScreen.TABS[SettingsScreen.TABS.size() - 1], ", ".join(reached)])

	# ── every tab hands a controller somewhere to stand ──
	for index: int in SettingsScreen.TABS.size():
		screen.call(&"show_tab", index)
		await process_frame
		var target: Control = screen.call(&"menu_default_focus") as Control
		check(target != null and target.focus_mode != Control.FOCUS_NONE,
			"tab %s names a focusable default" % SettingsScreen.TABS[index])
		if target != null:
			target.grab_focus()
			await process_frame
			check(_focused() == target,
				"tab %s's default actually takes focus when asked" % SettingsScreen.TABS[index])

	# ── a focused slider responds to ui_left/ui_right ──
	# F-215: `Slider` has no "focus" theme item in this Godot version, so the proxy for "has a
	# visible ring" is FocusRingSlider's own _draw()-based one being wired with a real style.
	screen.call(&"show_tab", SettingsScreen.TABS.find("CONTROLS"))
	await process_frame
	var slider: HSlider = _first_of(screen, "HSlider") as HSlider
	check(slider != null, "the CONTROLS tab has a slider to drive")
	if slider != null:
		slider.grab_focus()
		await process_frame
		check(slider is FocusRingSlider and (slider as FocusRingSlider).focus_ring_style != null,
			"the slider draws its own focus ring (FocusRingSlider, F-215)")
		var before: float = slider.value
		await _tap(JOY_BUTTON_DPAD_LEFT)
		var after: float = slider.value
		check(after < before,
			"ui_left on a focused slider decrements it (%.3f -> %.3f)" % [before, after])
		await _tap(JOY_BUTTON_DPAD_RIGHT)
		check(is_equal_approx(slider.value, before),
			"ui_right restores the value ui_left just took off it")

	# ── the toggle a controller has to be able to flip (F-411/F-416) ──
	screen.call(&"show_tab", SettingsScreen.TABS.find("PLAYTESTING"))
	await process_frame
	var toggle: CheckBox = screen.find_child("GodModeToggle", true, false) as CheckBox
	check(toggle != null, "the PLAYTESTING tab has the God Mode toggle")
	if toggle != null:
		check(toggle.focus_mode != Control.FOCUS_NONE, "the God Mode toggle is focusable")
		toggle.grab_focus()
		await process_frame
		check(_focused() == toggle, "the God Mode toggle takes focus")
		var was: bool = toggle.button_pressed
		await _tap(JOY_BUTTON_A)
		check(toggle.button_pressed != was,
			"ui_accept flips the God Mode toggle the way a click would")
		if toggle.button_pressed != was:
			await _tap(JOY_BUTTON_A)

	# ── the commit step, which lives OUTSIDE the scroll viewport ──
	# A SAVE button a controller cannot land on is no commit step at all (F-386).
	var footer: Array[Button] = _settings_footer_buttons(screen)
	check(footer.size() == 2, "the footer has RESTORE DEFAULTS and SAVE (found %d)" % footer.size())
	for button: Button in footer:
		check(button.focus_mode != Control.FOCUS_NONE and not button.disabled,
			"the footer's %s can hold focus" % button.text)
		button.grab_focus()
		await process_frame
		check(_focused() == button, "the footer's %s actually takes focus when asked" % button.text)
	if footer.size() == 2:
		footer[0].grab_focus()
		await process_frame
		await _tap(JOY_BUTTON_DPAD_RIGHT)
		check(_focused() == footer[1],
			"ui_right crosses the footer from %s to %s" % [footer[0].text, footer[1].text])

	stack.call(&"pop_all")
	await process_frame
	screen.queue_free()
	await process_frame


## The tab bar's buttons, in TABS order. Found by text rather than by node path so a restyle of the
## screen's container hierarchy does not silently make this section check nothing.
func _settings_tab_buttons(screen: Node) -> Array[Button]:
	var out: Array[Button] = []
	for label: String in SettingsScreen.TABS:
		for node: Node in _descendants(screen):
			if node is Button and (node as Button).text == label:
				out.append(node as Button)
				break
	return out


func _settings_footer_buttons(screen: Node) -> Array[Button]:
	var out: Array[Button] = []
	for label: String in ["RESTORE DEFAULTS", "SAVE"]:
		for node: Node in _descendants(screen):
			if node is Button and (node as Button).text == label:
				out.append(node as Button)
				break
	return out


func _first_of(screen: Node, class_wanted: String) -> Control:
	for node: Node in _descendants(screen):
		if node.is_class(class_wanted) and node is Control and (node as Control).is_visible_in_tree():
			return node as Control
	return null


func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child: Node in node.get_children():
		out.append(child)
		out.append_array(_descendants(child))
	return out


## Every other control's proxy for "the player can see where focus is" is a focus stylebox override;
## sliders carry theirs on FocusRingSlider instead (F-215).
func _has_visible_focus(control: Control) -> bool:
	if control is FocusRingSlider:
		return (control as FocusRingSlider).focus_ring_style != null
	return control.has_theme_stylebox_override(&"focus")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
