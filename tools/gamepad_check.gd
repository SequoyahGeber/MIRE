extends SceneTree

## Offline proof for task 7.6: every action gamepad support relies on actually carries a joypad
## event in project.godot's own InputMap (a hand-edited .ini is exactly the kind of place a typo'd
## button/axis index hides — F-021's "grep every check run for engine errors" catches a crash, not a
## silently-wrong index), PlayerCamera's analog-stick look turns yaw/pitch through the real
## `apply_look_gamepad()` path, and every raw-key/raw-mouse handler this task promoted to an InputMap
## action (`build`, `build_rotate`, `build_destroy`, `eat`, `hotbar_prev`, `hotbar_next`) still fires
## through the real PlayerController/VitalsHud/InventoryUI handler when fed a real
## InputEventJoypadButton/InputEventJoypadMotion — the same "feed the real _unhandled_input()" shape
## tools/build_check.gd already uses for mouse/key. SettingsService's rebind API is
## tools/settings_check.gd's job, not this file's.
##
## Run with: .agent/bin/agent godot --script tools/gamepad_check.gd

var failures: int = 0
var level: Node3D
var service: Node
var inventory: Node
var _confirmations: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	_check_input_map_wiring()
	_check_gamepad_look()
	await _check_hotbar_cycle()
	await _check_eat()
	await _check_build_cycle_via_gamepad()
	await _check_build_bar_slot_focus()

	print("\nGAMEPAD_CHECK failures=%d" % failures)
	finish()


# ── InputMap wiring ───────────────────────────────────────────────────────────────────────────────


func _check_input_map_wiring() -> void:
	print("\n== every gamepad-support action carries the joypad event it needs ==")
	_check_button(&"jump", JOY_BUTTON_A)
	_check_button(&"dodge", JOY_BUTTON_B)
	_check_button(&"interact", JOY_BUTTON_X)
	_check_button(&"inventory", JOY_BUTTON_Y)
	_check_button(&"sprint", JOY_BUTTON_LEFT_STICK)
	_check_button(&"build", JOY_BUTTON_DPAD_UP)
	_check_button(&"eat", JOY_BUTTON_DPAD_DOWN)
	_check_button(&"build_rotate", JOY_BUTTON_DPAD_RIGHT)
	_check_button(&"hotbar_prev", JOY_BUTTON_LEFT_SHOULDER)
	_check_button(&"hotbar_next", JOY_BUTTON_RIGHT_SHOULDER)
	_check_axis(&"attack", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_check_axis(&"build_destroy", JOY_AXIS_TRIGGER_LEFT, 1.0)
	_check_axis(&"move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_check_axis(&"move_back", JOY_AXIS_LEFT_Y, 1.0)
	_check_axis(&"move_left", JOY_AXIS_LEFT_X, -1.0)
	_check_axis(&"move_right", JOY_AXIS_LEFT_X, 1.0)
	_check_axis(&"look_left", JOY_AXIS_RIGHT_X, -1.0)
	_check_axis(&"look_right", JOY_AXIS_RIGHT_X, 1.0)
	_check_axis(&"look_up", JOY_AXIS_RIGHT_Y, -1.0)
	_check_axis(&"look_down", JOY_AXIS_RIGHT_Y, 1.0)

	# Every rebindable action (keyboard or gamepad) has to actually exist in the InputMap, or
	# SettingsService's conflict scan silently no-ops against an action that was never registered.
	var settings: Node = root.get_node_or_null(^"SettingsService")
	if settings != null:
		for action_name: String in settings.call("rebindable_actions") as PackedStringArray:
			check(InputMap.has_action(StringName(action_name)),
				"keyboard-rebindable action '%s' exists in the InputMap" % action_name)
		for action_name: String in settings.call("rebindable_actions_joypad") as PackedStringArray:
			check(InputMap.has_action(StringName(action_name)),
				"gamepad-rebindable action '%s' exists in the InputMap" % action_name)


func _check_button(action: StringName, expected_button: int) -> void:
	if not InputMap.has_action(action):
		check(false, "action '%s' exists" % action)
		return
	for event: InputEvent in InputMap.action_get_events(action):
		var joy := event as InputEventJoypadButton
		if joy != null and joy.button_index == expected_button:
			check(true, "'%s' carries JoyButton %d" % [action, expected_button])
			return
	check(false, "'%s' carries JoyButton %d" % [action, expected_button])


func _check_axis(action: StringName, expected_axis: int, expected_value: float) -> void:
	if not InputMap.has_action(action):
		check(false, "action '%s' exists" % action)
		return
	for event: InputEvent in InputMap.action_get_events(action):
		var motion := event as InputEventJoypadMotion
		if motion != null and motion.axis == expected_axis \
				and is_equal_approx(motion.axis_value, expected_value):
			check(true, "'%s' carries JoyAxis %d @ %.1f" % [action, expected_axis, expected_value])
			return
	check(false, "'%s' carries JoyAxis %d @ %.1f" % [action, expected_axis, expected_value])


# ── Camera look (the core fix — no path rotated the camera from a gamepad before this task) ────────


func _check_gamepad_look() -> void:
	print("\n== PlayerCamera: right-stick look through the real apply_look_gamepad() path ==")
	var camera_script := preload("res://entities/player/player_camera.gd")
	var body := Node3D.new()
	body.name = "GamepadCheckBody"
	root.add_child(body)
	var pivot: Node3D = camera_script.new()
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	pivot.add_child(camera)
	body.add_child(pivot)

	var yaw_before: float = body.rotation.y
	var pitch_before: float = pivot.rotation.x

	Input.action_press(&"look_right", 1.0)
	pivot.call(&"apply_look_gamepad", 1.0 / 60.0, true)
	Input.action_release(&"look_right")
	check(not is_equal_approx(body.rotation.y, yaw_before),
		"right stick X rotates the body yaw through the real path")

	Input.action_press(&"look_down", 1.0)
	pivot.call(&"apply_look_gamepad", 1.0 / 60.0, true)
	Input.action_release(&"look_down")
	check(not is_equal_approx(pivot.rotation.x, pitch_before),
		"right stick Y pitches the camera through the real path")

	var yaw_locked: float = body.rotation.y
	Input.action_press(&"look_right", 1.0)
	pivot.call(&"apply_look_gamepad", 1.0 / 60.0, false)
	Input.action_release(&"look_right")
	check(is_equal_approx(body.rotation.y, yaw_locked),
		"gamepad look is suppressed while input_allowed is false (a blocking UI is open)")

	body.queue_free()


# ── Hotbar cycle (LB/RB) ──────────────────────────────────────────────────────────────────────────


func _check_hotbar_cycle() -> void:
	print("\n== InventoryUI: hotbar_prev/hotbar_next through the real _input() path ==")
	var ui: Node = root.get_node_or_null(^"InventoryUI")
	check(ui != null, "InventoryUI autoload exists")
	if ui == null:
		return
	await process_frame

	ui.call(&"select_hotbar_slot", 3)
	check(int(ui.call(&"selected_hotbar_slot")) == 3, "starts at slot 3")

	ui.call(&"_input", _joy_button_event(JOY_BUTTON_RIGHT_SHOULDER, true))
	check(int(ui.call(&"selected_hotbar_slot")) == 4, "hotbar_next (RB) advances one slot")

	ui.call(&"_input", _joy_button_event(JOY_BUTTON_LEFT_SHOULDER, true))
	ui.call(&"_input", _joy_button_event(JOY_BUTTON_LEFT_SHOULDER, true))
	check(int(ui.call(&"selected_hotbar_slot")) == 2, "hotbar_prev (LB) steps back, twice in a row")

	ui.call(&"select_hotbar_slot", 0)
	ui.call(&"_input", _joy_button_event(JOY_BUTTON_LEFT_SHOULDER, true))
	check(int(ui.call(&"selected_hotbar_slot")) == 7,
		"hotbar_prev wraps from slot 0 to the last slot (7)")

	ui.call(&"select_hotbar_slot", 7)
	ui.call(&"_input", _joy_button_event(JOY_BUTTON_RIGHT_SHOULDER, true))
	check(int(ui.call(&"selected_hotbar_slot")) == 0,
		"hotbar_next wraps from the last slot back to 0")

	ui.call(&"select_hotbar_slot", 0)


# ── Eat (D-pad down) ──────────────────────────────────────────────────────────────────────────────


func _check_eat() -> void:
	print("\n== VitalsHud: 'eat' through the real _input() path (gamepad D-pad down) ==")
	var hud: Node = root.get_node_or_null(^"VitalsHud")
	var inventory_service: Node = root.get_node_or_null(^"InventoryService")
	var health: Node = root.get_node_or_null(^"PlayerHealth")
	var registry: Node = root.get_node_or_null(^"Registry")
	check(hud != null and inventory_service != null and health != null and registry != null,
		"VitalsHud/InventoryService/PlayerHealth/Registry autoloads exist")
	if hud == null or inventory_service == null or health == null or registry == null:
		return

	# A consumable in the currently-selected hotbar slot, and enough hunger room that the request is
	# meaningful (host_add/request_consume_item are already proven elsewhere — this only proves the
	# gamepad button reaches PlayerHealth.request_consume_item at all).
	var consumable_id: StringName = &""
	var items: Dictionary = registry.get(&"items") as Dictionary
	for item_id: StringName in items:
		var item: ItemDef = items[item_id] as ItemDef
		if item != null and item.category == ItemDef.Category.CONSUMABLE:
			consumable_id = item_id
			break
	check(consumable_id != &"", "content ships at least one CONSUMABLE item to eat")
	if consumable_id == &"":
		return

	var hotbar_start: int = int(inventory_service.call(&"hotbar_start_index"))
	inventory_service.call(&"host_add", 1, consumable_id, 1)
	await process_frame

	# host_add() fills the first available slot, which may not be the hotbar slot InventoryUI has
	# selected — find it in the local snapshot and move it there so this check does not depend on
	# inventory layout order.
	var from_index: int = -1
	for i: int in int(inventory_service.call(&"slot_count")):
		if StringName(inventory_service.call(&"local_item_id", i)) == consumable_id:
			from_index = i
			break
	check(from_index >= 0, "the added consumable appears in the local snapshot")
	if from_index < 0:
		return
	if from_index != hotbar_start:
		inventory_service.call(&"host_move_stack", 1, from_index, hotbar_start)
		await process_frame
	var ui: Node = root.get_node_or_null(^"InventoryUI")
	if ui != null:
		ui.call(&"select_hotbar_slot", 0)

	var count_before: int = int(inventory_service.call(&"local_count", consumable_id))
	hud.call(&"_input", _joy_button_event(JOY_BUTTON_DPAD_DOWN, true))
	await process_frame
	var count_after: int = int(inventory_service.call(&"local_count", consumable_id))
	check(count_after < count_before,
		"gamepad D-pad down consumes the selected hotbar item (%d -> %d)" % [count_before, count_after])


# ── Build mode: toggle / rotate / confirm / destroy, all through gamepad events ─────────────────────


func _check_build_cycle_via_gamepad() -> void:
	print("\n== PlayerController: the full build cycle through real gamepad events ==")
	var player_net: Node = root.get_node_or_null(^"PlayerNet")
	var players_root: Node = player_net.call(&"players_root") as Node if player_net != null else null
	var registry: Node = root.get_node_or_null(^"Registry")
	service = root.get_node_or_null(^"BuildService")
	inventory = root.get_node_or_null(^"InventoryService")
	check(players_root != null and registry != null and service != null and inventory != null,
		"PlayerNet/Registry/BuildService/InventoryService all exist")
	if players_root == null or registry == null or service == null or inventory == null:
		return

	level = Node3D.new()
	level.name = "GamepadCheckLevel"
	root.add_child(level)
	current_scene = level
	_add_floor(Vector3(0.0, -0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	await physics_frame
	await physics_frame

	# name "1" matters, not just an id: _adopt_spawn_authority() reads the node name as the peer this
	# body belongs to, and offline (no active session) the local unique id defaults to 1 too — any
	# other name makes is_multiplayer_authority() false, which is_local_authority gates the WHOLE
	# local-only build presenting (BuildGhost/BuildBar) and _unhandled_input processing behind, so the
	# gamepad events below would silently reach a node that is not even listening (caught empirically:
	# name "2" left BuildGhost null and _unhandled_input never fired).
	var player: CharacterBody3D = \
		preload("res://entities/player/player.tscn").instantiate() as CharacterBody3D
	player.name = "1"
	player.position = Vector3(0.0, 0.0, 0.0)
	players_root.add_child(player)
	await process_frame
	await process_frame

	var camera_pivot: Node3D = player.get(&"camera")
	check(camera_pivot != null, "the real player has a camera pivot")
	if camera_pivot == null:
		player.queue_free()
		return
	camera_pivot.rotation.x = deg_to_rad(-40.0)

	inventory.call(&"host_transaction", 1, {} as Dictionary, {&"log": 10} as Dictionary)

	# Toggle build mode on through the real gamepad "build" binding (D-pad up).
	player.call(&"_unhandled_input", _joy_button_event(JOY_BUTTON_DPAD_UP, true))
	check(bool(player.call(&"is_build_mode_active")), "gamepad D-pad up (build) enters build mode")

	await physics_frame
	await physics_frame

	var ghost: Node = player.get_node_or_null(^"BuildGhost")
	check(ghost != null, "a real BuildGhost is attached")
	if ghost == null:
		player.queue_free()
		return

	# A bare toggle-on auto-selects Registry's first buildable (build_bar.gd's own doc note) which is
	# not necessarily "wall_wood" or affordable with only the log this check funded — pin the piece
	# explicitly through the real selection API (the same one BuildBar's slot click uses) so the
	# confirm below is testing gamepad wiring, not fighting Registry iteration order.
	check(bool(player.call(&"set_selected_build_piece", &"wall_wood")),
		"the real selection API accepts wall_wood")

	var yaw_before: float = (ghost.call(&"placement") as Transform3D).basis.get_euler().y
	player.call(&"_unhandled_input", _joy_button_event(JOY_BUTTON_DPAD_RIGHT, true))
	await physics_frame
	await physics_frame
	var yaw_after: float = (ghost.call(&"placement") as Transform3D).basis.get_euler().y
	check(not is_equal_approx(yaw_before, yaw_after),
		"gamepad D-pad right (build_rotate) rotates the ghost through the real input path")

	_confirmations.clear()
	service.connect(&"build_confirmed", _on_build_confirmed)
	player.call(&"_unhandled_input", _joy_axis_event(JOY_AXIS_TRIGGER_RIGHT, 1.0))
	await process_frame
	check(_confirmations.size() == 1 and bool(_confirmations[0]["accepted"]),
		"the right trigger (attack) confirms a real placement while building")

	await physics_frame
	await physics_frame

	_confirmations.clear()
	player.call(&"_unhandled_input", _joy_axis_event(JOY_AXIS_TRIGGER_LEFT, 1.0))
	await process_frame
	check(_confirmations.size() == 1 and bool(_confirmations[0]["accepted"]),
		"the left trigger (build_destroy) destroys the aimed-at piece through the real path")
	service.disconnect(&"build_confirmed", _on_build_confirmed)

	player.call(&"_unhandled_input", _joy_button_event(JOY_BUTTON_DPAD_UP, true))
	check(not bool(player.call(&"is_build_mode_active")),
		"gamepad D-pad up (build) exits build mode again")

	player.queue_free()


# ── Build mode: BuildBar piece-slot selection via gamepad focus (F-217) ────────────────────────────


## F-217: unlike every other assertion in this file, slot focus movement is not something
## player_controller.gd's _unhandled_input implements — it is Godot's own Viewport GUI input handling
## walking PieceSlot's focus_neighbor_left/_right, the same "put a real event through the real
## pipeline and read gui_get_focus_owner() back" shape tools/menu_focus_check.gd already uses for
## every other panel's chain. So this check uses Input.parse_input_event() (via _tap_focus below)
## rather than calling _unhandled_input directly like the rest of this file.
func _check_build_bar_slot_focus() -> void:
	print("\n== BuildBar: piece-slot selection through real gamepad focus navigation (F-217) ==")
	var player_net: Node = root.get_node_or_null(^"PlayerNet")
	var players_root: Node = player_net.call(&"players_root") as Node if player_net != null else null
	var registry: Node = root.get_node_or_null(^"Registry")
	service = root.get_node_or_null(^"BuildService")
	inventory = root.get_node_or_null(^"InventoryService")
	check(players_root != null and registry != null and service != null and inventory != null,
		"PlayerNet/Registry/BuildService/InventoryService all exist")
	if players_root == null or registry == null or service == null or inventory == null:
		return

	level = Node3D.new()
	level.name = "GamepadCheckBuildBarLevel"
	root.add_child(level)
	current_scene = level
	_add_floor(Vector3(0.0, -0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	await physics_frame
	await physics_frame

	# Same "name must be '1'" requirement _check_build_cycle_via_gamepad's own comment explains —
	# is_local_authority gates BuildBar's own construction, not just _unhandled_input.
	var player: CharacterBody3D = \
		preload("res://entities/player/player.tscn").instantiate() as CharacterBody3D
	player.name = "1"
	player.position = Vector3(0.0, 0.0, 0.0)
	players_root.add_child(player)
	await process_frame
	await process_frame

	var camera_pivot: Node3D = player.get(&"camera")
	if camera_pivot == null:
		check(false, "the real player has a camera pivot")
		player.queue_free()
		return
	camera_pivot.rotation.x = deg_to_rad(-40.0)

	inventory.call(&"host_transaction", 1, {} as Dictionary, {&"log": 10} as Dictionary)

	var build_bar: Node = player.get_node_or_null(^"BuildBar")
	check(build_bar != null, "the real player has a BuildBar")
	if build_bar == null:
		player.queue_free()
		return

	# Pin the piece explicitly (same real selection API the click/gamepad-cycle checks use) rather
	# than trusting the auto-selected first buildable, so the slot lookup below is deterministic.
	check(bool(player.call(&"set_selected_build_piece", &"wall_wood")),
		"the real selection API accepts wall_wood")
	await process_frame

	var slot_total: int = int(build_bar.call(&"slot_count"))
	check(slot_total > 1,
		"content ships more than one buildable, enough to prove focus actually moves across slots")
	if slot_total <= 1:
		player.queue_free()
		return

	var wall_index: int = -1
	for i: int in slot_total:
		if build_bar.call(&"slot_piece_id", i) == &"wall_wood":
			wall_index = i
			break
	check(wall_index >= 0, "wall_wood is one of BuildBar's registered slots")
	if wall_index < 0:
		player.queue_free()
		return

	var focused: Control = root.get_viewport().gui_get_focus_owner()
	check(focused != null and focused.name == "BuildSlot_wall_wood",
		"selecting wall_wood through the real API also grabs its BuildBar slot's keyboard/gamepad focus")

	var next_piece_id: StringName = StringName(build_bar.call(&"slot_piece_id", (wall_index + 1) % slot_total))
	await _tap_focus(JOY_BUTTON_DPAD_RIGHT)
	var focused_right: Control = root.get_viewport().gui_get_focus_owner()
	check(focused_right != null and focused_right.name == "BuildSlot_%s" % String(next_piece_id),
		"D-pad right moves focus to the next slot in the row through focus_neighbor_right")

	await _tap_focus(JOY_BUTTON_DPAD_LEFT)
	var focused_left: Control = root.get_viewport().gui_get_focus_owner()
	check(focused_left != null and focused_left.name == "BuildSlot_wall_wood",
		"D-pad left returns focus to wall_wood's slot through focus_neighbor_left")

	var ghost: Node = player.get_node_or_null(^"BuildGhost")
	check(ghost != null, "a real BuildGhost is attached")
	if ghost == null:
		player.queue_free()
		return

	await _tap_focus(JOY_BUTTON_DPAD_RIGHT)
	await _tap_focus(JOY_BUTTON_A)
	await process_frame
	check(StringName(ghost.call(&"current_piece_id")) == next_piece_id,
		"ui_accept (A) on a focused BuildBar slot selects that piece through the real seam, not just a mouse click")
	check(bool(build_bar.call(&"is_active")),
		"BuildBar stays active — a gamepad-driven selection is not mistaken for closing the bar")

	player.queue_free()


func _add_floor(centre: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = centre
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	level.add_child(body)


func _on_build_confirmed(request_id: int, accepted: bool, reason: String) -> void:
	_confirmations.append({"request_id": request_id, "accepted": accepted, "reason": reason})


# ── Event helpers ─────────────────────────────────────────────────────────────────────────────────


func _joy_button_event(button_index: int, pressed: bool) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	event.pressed = pressed
	return event


func _joy_axis_event(axis: int, value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = value
	return event


## F-217: tools/menu_focus_check.gd's own `_tap` — focus navigation only happens through the real
## Viewport GUI input pipeline (Input.parse_input_event), not a node's own _input()/_unhandled_input,
## so `_check_build_bar_slot_focus()` needs this instead of `_joy_button_event` + a direct call.
func _tap_focus(button_index: int) -> void:
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


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
