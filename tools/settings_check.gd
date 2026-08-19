extends SceneTree

## Offline proof for tasks 7.5/7.6: SettingsSave's own load/corrupt/migrate/round-trip contract (same
## shape `unlock_check.gd`/`salvage_check.gd` already prove for their save files), SettingsService's
## live setters — graphics preset delegation, audio bus volume/mute, mouse/gamepad sensitivity/
## invert-Y/FOV clamping, the "reduce camera motion" accessibility toggle, keyboard keybind
## rebind/conflict/reset, gamepad button rebind/conflict/reset (7.6) — and that
## `PlayerCamera`/`SettingsMenu` actually read those values back. Gamepad GAMEPLAY behaviour (the
## right-stick look actually turning the camera, "eat"/"build_rotate"/hotbar-cycle firing through
## real InputEventJoypad* events) is `tools/gamepad_check.gd`'s job, not this file's.
##
## Run with: .agent/bin/agent godot --script tools/settings_check.gd

const SETTINGS_SAVE := preload("res://core/save/settings_save.gd")
const PLAYER_CAMERA_SCRIPT := preload("res://entities/player/player_camera.gd")

const TEST_PATH: String = "user://settings_check.json"
const TEST_CORRUPT_PATH: String = "user://settings_check_corrupt.json"
const TEST_MISSING_VERSION_PATH: String = "user://settings_check_missing_version.json"
const TEST_ROUNDTRIP_PATH: String = "user://settings_check_roundtrip.json"
const TEST_MISSING_PATH: String = "user://settings_check_does_not_exist.json"

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	_cleanup_test_paths()
	_check_settings_save()

	var settings: Node = root.get_node_or_null(^"SettingsService")
	var menu: Node = root.get_node_or_null(^"SettingsMenu")
	var gfx: Node = root.get_node_or_null(^"GraphicsQuality")
	check(settings != null, "SettingsService autoload exists")
	check(menu != null, "SettingsMenu autoload exists")
	check(gfx != null, "GraphicsQuality autoload exists")
	if settings == null or menu == null or gfx == null:
		_cleanup_test_paths()
		finish()
		return

	settings.set(&"save_path", TEST_PATH)

	_check_graphics(settings, gfx)
	_check_audio_buses(settings)
	_check_look_and_accessibility(settings)
	_check_keybinds(settings)
	_check_joypad_keybinds(settings)
	await _check_player_camera(settings)
	_check_menu(settings, menu)

	var on_disk: Dictionary = SETTINGS_SAVE.load_data(TEST_PATH)
	check(int(on_disk.get(&"graphics_preset", -1)) == int(settings.call("graphics_preset")),
		"the last graphics preset write reached disk")
	check(is_equal_approx(float(on_disk.get(&"fov_degrees", -1.0)), float(settings.call("fov_degrees"))),
		"the last FOV write reached disk")

	_cleanup_test_paths()
	print("SETTINGS_CHECK failures=%d" % failures)
	finish()


func _check_settings_save() -> void:
	print("\n== SettingsSave ==")
	var missing: Dictionary = SETTINGS_SAVE.load_data(TEST_MISSING_PATH)
	check(int(missing.get(&"graphics_preset", -1)) == 2, "a missing file resolves to the default preset (high)")
	check(is_equal_approx(float(missing.get(&"look_sensitivity", -1.0)), 0.12),
		"a missing file resolves to the default sensitivity")

	var corrupt_file: FileAccess = FileAccess.open(TEST_CORRUPT_PATH, FileAccess.WRITE)
	corrupt_file.store_string("{ not json")
	corrupt_file.close()
	var corrupt: Dictionary = SETTINGS_SAVE.load_data(TEST_CORRUPT_PATH)
	check(int(corrupt.get(&"schema_version", -1)) == 1, "a corrupt file falls back to fresh defaults, not a crash")

	var missing_version_file: FileAccess = FileAccess.open(TEST_MISSING_VERSION_PATH, FileAccess.WRITE)
	missing_version_file.store_string(JSON.stringify({"graphics_preset": 0}))
	missing_version_file.close()
	var migrated: Dictionary = SETTINGS_SAVE.load_data(TEST_MISSING_VERSION_PATH)
	check(int(migrated.get(&"graphics_preset", -1)) == 0, "migration preserves a field the old file already had")
	check(is_equal_approx(float(migrated.get(&"master_volume", -1.0)), 1.0),
		"migration backfills a field the old file never had")
	check(int(migrated.get(&"schema_version", -1)) == 1, "migration stamps the current schema version")

	SETTINGS_SAVE.save_data({
		"graphics_preset": 1, "master_volume": 0.3, "music_volume": 0.4, "sfx_volume": 0.5,
		"look_sensitivity": 0.2, "gamepad_look_sensitivity": 240.0, "invert_y": true, "fov_degrees": 95.0,
		"reduce_camera_motion": true, "keybinds": {"jump": 74}, "joypad_binds": {"jump": 2},
	}, TEST_ROUNDTRIP_PATH)
	var round_trip: Dictionary = SETTINGS_SAVE.load_data(TEST_ROUNDTRIP_PATH)
	check(int(round_trip.get(&"graphics_preset", -1)) == 1, "round trip: graphics preset")
	check(is_equal_approx(float(round_trip.get(&"sfx_volume", -1.0)), 0.5), "round trip: sfx volume")
	check(bool(round_trip.get(&"invert_y", false)) == true, "round trip: invert_y")
	check(bool(round_trip.get(&"reduce_camera_motion", false)) == true, "round trip: reduce_camera_motion")
	check(int((round_trip.get(&"keybinds", {}) as Dictionary).get("jump", -1)) == 74,
		"round trip: a keybind override")
	check(is_equal_approx(float(round_trip.get(&"gamepad_look_sensitivity", -1.0)), 240.0),
		"round trip: gamepad_look_sensitivity")
	check(int((round_trip.get(&"joypad_binds", {}) as Dictionary).get("jump", -1)) == 2,
		"round trip: a joypad button rebind override")


func _check_graphics(settings: Node, gfx: Node) -> void:
	print("\n== SettingsService: graphics ==")
	settings.call("set_graphics_preset", 0)
	check(int(settings.call("graphics_preset")) == 0, "set_graphics_preset(0) is read back")
	check(int(gfx.get(&"preset")) == 0, "set_graphics_preset delegates to GraphicsQuality.apply()")
	settings.call("set_graphics_preset", 2)
	check(int(gfx.get(&"preset")) == 2, "restoring HIGH re-applies through the same seam")


func _check_audio_buses(settings: Node) -> void:
	print("\n== SettingsService: audio buses ==")
	var master_idx: int = AudioServer.get_bus_index("Master")
	var music_idx: int = AudioServer.get_bus_index("Music")
	var sfx_idx: int = AudioServer.get_bus_index("SFX")
	check(music_idx >= 0, "SettingsService creates a Music bus")
	check(sfx_idx >= 0, "SettingsService creates an SFX bus")
	check(AudioServer.get_bus_send(music_idx) == "Master", "Music bus sends to Master")
	check(AudioServer.get_bus_send(sfx_idx) == "Master", "SFX bus sends to Master")

	settings.call("set_master_volume", 0.5)
	check(is_equal_approx(float(settings.call("master_volume")), 0.5), "set_master_volume(0.5) is read back")
	check(is_equal_approx(AudioServer.get_bus_volume_db(master_idx), linear_to_db(0.5)),
		"master volume reaches the Master bus in dB")
	check(not AudioServer.is_bus_mute(master_idx), "a nonzero master volume leaves Master unmuted")

	settings.call("set_master_volume", 0.0)
	check(AudioServer.is_bus_mute(master_idx), "zero master volume mutes the Master bus")
	settings.call("set_master_volume", 1.0)

	settings.call("set_music_volume", 0.25)
	check(is_equal_approx(AudioServer.get_bus_volume_db(music_idx), linear_to_db(0.25)),
		"music volume reaches the Music bus in dB")
	settings.call("set_sfx_volume", 0.75)
	check(is_equal_approx(AudioServer.get_bus_volume_db(sfx_idx), linear_to_db(0.75)),
		"sfx volume reaches the SFX bus in dB")


func _check_look_and_accessibility(settings: Node) -> void:
	print("\n== SettingsService: look + accessibility ==")
	settings.call("set_look_sensitivity", 5.0)
	check(is_equal_approx(float(settings.call("look_sensitivity")), 1.0),
		"sensitivity clamps to its max (1.0)")
	settings.call("set_look_sensitivity", -5.0)
	check(is_equal_approx(float(settings.call("look_sensitivity")), 0.01),
		"sensitivity clamps to its min (0.01)")
	settings.call("set_look_sensitivity", 0.3)
	check(is_equal_approx(float(settings.call("look_sensitivity")), 0.3), "an in-range sensitivity is read back")

	settings.call("set_gamepad_look_sensitivity", 1000.0)
	check(is_equal_approx(float(settings.call("gamepad_look_sensitivity")), 720.0),
		"gamepad sensitivity clamps to its max (720)")
	settings.call("set_gamepad_look_sensitivity", 1.0)
	check(is_equal_approx(float(settings.call("gamepad_look_sensitivity")), 30.0),
		"gamepad sensitivity clamps to its min (30)")
	settings.call("set_gamepad_look_sensitivity", 200.0)
	check(is_equal_approx(float(settings.call("gamepad_look_sensitivity")), 200.0),
		"an in-range gamepad sensitivity is read back")

	check(bool(settings.call("invert_y")) == false, "invert_y defaults false")
	settings.call("set_invert_y", true)
	check(bool(settings.call("invert_y")) == true, "set_invert_y(true) is read back")

	settings.call("set_fov_degrees", 200.0)
	check(is_equal_approx(float(settings.call("fov_degrees")), 110.0), "FOV clamps to its max (110)")
	settings.call("set_fov_degrees", 10.0)
	check(is_equal_approx(float(settings.call("fov_degrees")), 60.0), "FOV clamps to its min (60)")
	settings.call("set_fov_degrees", 90.0)

	settings.call("set_reduce_camera_motion", true)
	check(bool(settings.call("reduce_camera_motion")) == true, "reduce_camera_motion is read back")


func _check_keybinds(settings: Node) -> void:
	print("\n== SettingsService: keybinds ==")
	var actions: PackedStringArray = settings.call("rebindable_actions") as PackedStringArray
	check(actions.has("jump") and actions.has("dodge"), "rebindable_actions names the keyboard-primary actions")
	check(actions.has("eat") and actions.has("build_rotate"),
		"eat/build_rotate (promoted from raw keys by 7.6) are rebindable")
	check(not actions.has("attack"), "attack (mouse-primary) is not rebindable")
	check(not actions.has("build_destroy"),
		"build_destroy (mouse-primary, same D-131 reasoning as attack) is not keyboard-rebindable")

	var original_label: String = String(settings.call("keybind_label", &"jump"))
	var to_j := InputEventKey.new()
	to_j.physical_keycode = KEY_J
	var conflict: StringName = settings.call("rebind_action", &"jump", to_j) as StringName
	check(conflict == &"", "rebinding jump to J succeeds (no prior conflict)")
	check(String(settings.call("keybind_label", &"jump")) == OS.get_keycode_string(KEY_J),
		"jump's label now reads J")

	var also_j := InputEventKey.new()
	also_j.physical_keycode = KEY_J
	var second_conflict: StringName = settings.call("rebind_action", &"sprint", also_j) as StringName
	check(second_conflict == &"jump", "rebinding sprint onto jump's own key is refused, naming jump")
	check(String(settings.call("keybind_label", &"sprint")) != OS.get_keycode_string(KEY_J),
		"the refused rebind left sprint's own binding untouched")

	var not_rebindable: StringName = settings.call("rebind_action", &"attack", to_j) as StringName
	check(not_rebindable != &"", "rebinding a non-rebindable action is refused, not silently accepted")

	settings.call("reset_keybinds")
	check(String(settings.call("keybind_label", &"jump")) == original_label,
		"reset_keybinds restores jump's authored default")


func _check_joypad_keybinds(settings: Node) -> void:
	print("\n== SettingsService: gamepad button keybinds (task 7.6) ==")
	var actions: PackedStringArray = settings.call("rebindable_actions_joypad") as PackedStringArray
	check(actions.has("jump") and actions.has("hotbar_prev") and actions.has("hotbar_next"),
		"rebindable_actions_joypad names the button-bound actions")
	check(not actions.has("attack") and not actions.has("move_forward") and not actions.has("build_destroy"),
		"axis/trigger-bound actions (movement, look, attack, build_destroy) are not joypad-rebindable")

	var original_label: String = String(settings.call("keybind_label_joypad", &"jump"))
	check(original_label == "A", "jump's authored gamepad default reads as A")

	var to_lb := InputEventJoypadButton.new()
	to_lb.button_index = JOY_BUTTON_LEFT_SHOULDER
	var conflict: StringName = settings.call("rebind_action_joypad", &"jump", to_lb) as StringName
	check(conflict == &"hotbar_prev", "rebinding jump onto hotbar_prev's own button is refused, naming it")
	check(String(settings.call("keybind_label_joypad", &"jump")) == original_label,
		"the refused rebind left jump's own binding untouched")

	var to_dpad_left := InputEventJoypadButton.new()
	to_dpad_left.button_index = JOY_BUTTON_DPAD_LEFT
	var second_conflict: StringName = \
		settings.call("rebind_action_joypad", &"jump", to_dpad_left) as StringName
	check(second_conflict == &"", "rebinding jump to an unused button (D-pad left) succeeds")
	check(String(settings.call("keybind_label_joypad", &"jump")) == "D-PAD LEFT",
		"jump's gamepad label now reads D-PAD LEFT")

	var not_rebindable: StringName = \
		settings.call("rebind_action_joypad", &"attack", to_dpad_left) as StringName
	check(not_rebindable != &"", "rebinding a non-joypad-rebindable action is refused, not silently accepted")

	settings.call("reset_keybinds")
	check(String(settings.call("keybind_label_joypad", &"jump")) == original_label,
		"reset_keybinds restores jump's authored gamepad default too")


func _check_player_camera(settings: Node) -> void:
	print("\n== PlayerCamera reads SettingsService ==")
	settings.call("set_look_sensitivity", 0.42)
	settings.call("set_gamepad_look_sensitivity", 300.0)
	settings.call("set_invert_y", true)
	settings.call("set_fov_degrees", 88.0)
	settings.call("set_reduce_camera_motion", true)

	var body := Node3D.new()
	body.name = "SettingsCheckPlayerBody"
	root.add_child(body)
	var pivot: Node3D = PLAYER_CAMERA_SCRIPT.new()
	pivot.name = "SettingsCheckCameraPivot"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	pivot.add_child(camera)
	body.add_child(pivot)
	await process_frame

	check(is_equal_approx(float(pivot.get(&"look_sensitivity")), 0.42),
		"a freshly-readied PlayerCamera picks up the live sensitivity")
	check(is_equal_approx(float(pivot.get(&"gamepad_look_sensitivity")), 300.0),
		"a freshly-readied PlayerCamera picks up the live gamepad sensitivity")
	check(bool(pivot.get(&"invert_y")) == true, "a freshly-readied PlayerCamera picks up invert_y")
	check(is_equal_approx(float(pivot.get(&"_base_fov")), 88.0),
		"a freshly-readied PlayerCamera picks up the live FOV")
	check(is_equal_approx(camera.fov, 88.0), "the FOV reaches the actual Camera3D node")

	pivot.call("add_shake", 5.0, 1.0)
	check(is_equal_approx(float(pivot.call("shake_remaining")), 0.0),
		"reduce_camera_motion suppresses impact shake")

	settings.call("set_look_sensitivity", 0.15)
	check(is_equal_approx(float(pivot.get(&"look_sensitivity")), 0.15),
		"settings_changed live-updates an already-readied camera")

	settings.call("set_reduce_camera_motion", false)
	body.queue_free()


func _check_menu(settings: Node, menu: Node) -> void:
	print("\n== SettingsMenu ==")
	check(not bool(menu.call("is_open")), "menu starts closed")

	settings.call("set_master_volume", 0.6)
	menu.call("set_open", true)
	check(bool(menu.call("is_open")), "menu opens")
	check(menu.is_in_group(&"blocks_gameplay_input"), "open menu blocks gameplay input (D-032)")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "open menu frees the cursor")

	var master_slider: HSlider = menu.get(&"_master_slider") as HSlider
	check(master_slider != null and is_equal_approx(master_slider.value, 0.6),
		"opening the menu refreshes its sliders from SettingsService")
	var graphics_option: OptionButton = menu.get(&"_graphics_option") as OptionButton
	check(graphics_option != null and graphics_option.item_count == 3,
		"the graphics dropdown has exactly Low/Medium/High")
	var keybind_buttons: Dictionary = menu.get(&"_keybind_buttons") as Dictionary
	check(keybind_buttons.size() == 12, "one keybind row per rebindable action")
	var gamepad_keybind_buttons: Dictionary = menu.get(&"_gamepad_keybind_buttons") as Dictionary
	check(gamepad_keybind_buttons.size() == 10, "one gamepad-bind row per joypad-rebindable action")
	var gamepad_slider: HSlider = menu.get(&"_gamepad_sensitivity_slider") as HSlider
	check(gamepad_slider != null, "the gamepad sensitivity slider exists")

	var other := Node.new()
	other.name = "SettingsCheckOtherUI"
	other.add_to_group(&"blocks_gameplay_input")
	root.add_child(other)
	menu.call("set_open", false)
	menu.call("set_open", true)
	check(not bool(menu.call("is_open")), "menu refuses to stack on another cursor UI (D-032)")
	root.remove_child(other)
	other.free()

	menu.call("set_open", true)
	check(bool(menu.call("is_open")), "menu opens again once the other UI is gone")
	menu.call("set_open", false)
	check(not bool(menu.call("is_open")), "menu closes")
	check(not menu.is_in_group(&"blocks_gameplay_input"), "closing releases the blocking group")
	settings.call("set_master_volume", 1.0)


func _cleanup_test_paths() -> void:
	for path: String in [TEST_PATH, TEST_CORRUPT_PATH, TEST_MISSING_VERSION_PATH, TEST_ROUNDTRIP_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
