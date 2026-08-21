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
const FOCUS_RING_SLIDER := preload("res://ui/menu/focus_ring_slider.gd")

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
	var gfx: Node = root.get_node_or_null(^"GraphicsQuality")
	check(settings != null, "SettingsService autoload exists")
	check(gfx != null, "GraphicsQuality autoload exists")
	if settings == null or gfx == null:
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
	_check_defaults(settings)
	# The obsolete SettingsMenu autoload was removed by F-413. The live tabbed screen and its
	# preview/readout/scroll contract are covered by tools/settings_screen_check.gd.

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
	check(bool(missing.get(&"vsync_enabled", false)), "a missing file defaults VSync on")
	check(int(missing.get(&"fps_cap", -1)) == 0, "a missing file defaults to an uncapped frame rate")
	check(is_equal_approx(float(missing.get(&"look_sensitivity", -1.0)), 0.12),
		"a missing file resolves to the default sensitivity")

	var corrupt_file: FileAccess = FileAccess.open(TEST_CORRUPT_PATH, FileAccess.WRITE)
	corrupt_file.store_string("{ not json")
	corrupt_file.close()
	var corrupt: Dictionary = SETTINGS_SAVE.load_data(TEST_CORRUPT_PATH)
	# Read off the constant, never a literal: this assertion was hardcoded to 2 and failed the moment
	# task 3.19 added the guidance keys as schema 3 — a check that has to be edited for every legitimate
	# migration is a check people learn to edit without reading.
	check(int(corrupt.get(&"schema_version", -1)) == SETTINGS_SAVE.SCHEMA_VERSION,
		"a corrupt file falls back to fresh defaults, not a crash")

	var missing_version_file: FileAccess = FileAccess.open(TEST_MISSING_VERSION_PATH, FileAccess.WRITE)
	missing_version_file.store_string(JSON.stringify({"graphics_preset": 0}))
	missing_version_file.close()
	var migrated: Dictionary = SETTINGS_SAVE.load_data(TEST_MISSING_VERSION_PATH)
	check(int(migrated.get(&"graphics_preset", -1)) == 0, "migration preserves a field the old file already had")
	check(is_equal_approx(float(migrated.get(&"master_volume", -1.0)), 1.0),
		"migration backfills a field the old file never had")
	check(int(migrated.get(&"schema_version", -1)) == SETTINGS_SAVE.SCHEMA_VERSION,
		"migration stamps the current schema version")
	check(int(migrated.get(&"resolution_index", -1)) == 1,
		"migration backfills the default display resolution")
	# 3.19's own migration hop: an old file has never seen a tip and gets guidance on by default.
	check(int(migrated.get(&"guidance_mode", -1)) == 0,
		"migration backfills guidance mode as FULL")
	check((migrated.get(&"guide_tips_seen", null) as Array).is_empty(),
		"migration backfills an empty seen-tips record")

	SETTINGS_SAVE.save_data({
		"graphics_preset": 1, "master_volume": 0.3, "music_volume": 0.4, "sfx_volume": 0.5,
		"window_mode": 1, "resolution_index": 3, "vsync_enabled": false, "fps_cap": 120,
		"ssao_override": 0, "anti_aliasing": 4, "dynamic_resolution": true, "brightness": 1.2,
		"look_sensitivity": 0.2, "gamepad_look_sensitivity": 240.0, "invert_y": true, "fov_degrees": 95.0,
		"reduce_camera_motion": true, "keybinds": {"jump": 74}, "joypad_binds": {"jump": 2},
	}, TEST_ROUNDTRIP_PATH)
	var round_trip: Dictionary = SETTINGS_SAVE.load_data(TEST_ROUNDTRIP_PATH)
	check(int(round_trip.get(&"graphics_preset", -1)) == 1, "round trip: graphics preset")
	check(int(round_trip.get(&"window_mode", -1)) == 1, "round trip: window mode")
	check(int(round_trip.get(&"resolution_index", -1)) == 3, "round trip: resolution")
	check(not bool(round_trip.get(&"vsync_enabled", true)), "round trip: VSync")
	check(int(round_trip.get(&"fps_cap", -1)) == 120, "round trip: FPS cap")
	check(int(round_trip.get(&"ssao_override", -2)) == 0, "round trip: SSAO override")
	check(int(round_trip.get(&"anti_aliasing", -1)) == 4, "round trip: anti-aliasing")
	check(bool(round_trip.get(&"dynamic_resolution", false)), "round trip: dynamic resolution")
	check(is_equal_approx(float(round_trip.get(&"brightness", 0.0)), 1.2), "round trip: brightness")
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
	settings.call("set_window_mode", 0)
	settings.call("set_resolution_index", 3)
	settings.call("set_vsync_enabled", false)
	settings.call("set_fps_cap", 120)
	check(int(settings.call("window_mode")) == 0, "window mode is read back")
	check(int(settings.call("resolution_index")) == 3, "resolution index is read back")
	check(not bool(settings.call("vsync_enabled")), "VSync is read back")
	check(int(settings.call("fps_cap")) == 120 and Engine.max_fps == 120,
		"FPS cap reaches Engine.max_fps")
	settings.call("set_fps_cap", 61)
	check(int(settings.call("fps_cap")) == 0 and Engine.max_fps == 0,
		"unsupported FPS caps safely resolve to uncapped")
	settings.call("set_vsync_enabled", true)
	settings.call("set_ssao_override", 0)
	settings.call("set_anti_aliasing", 4)
	settings.call("set_dynamic_resolution", true)
	settings.call("set_brightness", 1.2)
	check(int(settings.call("ssao_override")) == 0, "SSAO override is read back")
	check(int(settings.call("anti_aliasing")) == 4, "anti-aliasing mode is read back")
	if DisplayServer.get_name() != "headless":
		check(root.msaa_3d == Viewport.MSAA_4X and not root.use_taa,
			"MSAA 4x reaches the live viewport and disables competing AA modes")
	check(bool(settings.call("dynamic_resolution")), "dynamic resolution is read back")
	check(bool(gfx.get(&"dynamic_scale_enabled")), "dynamic resolution reaches GraphicsQuality")
	check(is_equal_approx(float(settings.call("brightness")), 1.2), "brightness is read back")
	check(is_equal_approx(float(gfx.get(&"brightness")), 1.2), "brightness reaches GraphicsQuality")
	settings.call("set_dynamic_resolution", false)
	settings.call("set_ssao_override", -1)
	settings.call("set_brightness", 1.0)


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


## F-386 gave `SettingsService` a single authored copy of the factory values so "restore defaults"
## has something to ask for. `core/save/settings_save.gd` keeps its own copy (a save-file migration
## has to run without this autoload), so the two have to be held to each other or a future edit to
## one silently makes "restore defaults" and "fresh install" mean different things.
func _check_defaults(settings: Node) -> void:
	print("\n== SettingsService: DEFAULTS ==")
	var fresh: Dictionary = SETTINGS_SAVE.load_data(TEST_MISSING_PATH)
	var defaults: Dictionary = settings.call("default_state") as Dictionary

	check(int(defaults[&"graphics_preset"]) == int(fresh.get(&"graphics_preset", -1)),
		"default graphics preset matches the save file's fresh-install value")
	for key: StringName in [
		&"master_volume", &"music_volume", &"sfx_volume",
		&"look_sensitivity", &"gamepad_look_sensitivity", &"fov_degrees",
	]:
		check(is_equal_approx(float(defaults[key]), float(fresh.get(key, -1.0))),
			"default %s matches the save file's fresh-install value" % key)
	for key: StringName in [&"invert_y", &"reduce_camera_motion"]:
		check(bool(defaults[key]) == bool(fresh.get(key, true)),
			"default %s matches the save file's fresh-install value" % key)

	check((defaults[&"keybinds"] as Dictionary).is_empty()
			and (defaults[&"joypad_binds"] as Dictionary).is_empty(),
		"default_state carries no keybind overrides — restoring defaults reaches the InputMap too")


## F-385: reported from play as "the fov slider does not have a number value for fov and neither do
## any other settings". Every slider in the panel is built by one helper, so the proof is that each
## of the six has a bound readout, that the readout says what the value actually is, and that its
## width is pinned — a number that shoves the row sideways as digits change is barely better.
func _check_slider_readouts(menu: Node) -> void:
	print("\n== SettingsMenu: numeric readouts (F-385) ==")
	var settings: Node = root.get_node_or_null(^"SettingsService")
	settings.call("set_master_volume", 0.6)
	settings.call("set_music_volume", 0.25)
	settings.call("set_sfx_volume", 1.0)
	settings.call("set_look_sensitivity", 0.35)
	settings.call("set_gamepad_look_sensitivity", 245.0)
	settings.call("set_fov_degrees", 103.0)

	menu.call("set_open", true)

	var expected: Dictionary = {
		&"_master_slider": "60%",
		&"_music_slider": "25%",
		&"_sfx_slider": "100%",
		&"_sensitivity_slider": "0.35",
		&"_gamepad_sensitivity_slider": "245°/s",
		&"_fov_slider": "103°",
	}
	for property: StringName in expected.keys():
		var slider: HSlider = menu.get(property) as HSlider
		check(slider is FOCUS_RING_SLIDER, "%s is a FocusRingSlider" % property)
		if not (slider is FOCUS_RING_SLIDER):
			continue
		var ring: FocusRingSlider = slider
		check(ring.readout_text() == String(expected[property]),
			"%s reads %s (got: %s)" % [property, expected[property], ring.readout_text()])
		check(ring.readout_min_width() > 0.0,
			"%s's readout has a fixed width, so the row cannot reflow mid-drag" % property)

	# The readout has to survive a refresh, which writes the value with signals blocked — the one
	# path that would otherwise leave a stale number on screen after re-opening the panel. Note the
	# order: the value is changed with the panel CLOSED, because a change made while it is open is
	# staged and handed back on close (F-386), which is a different behaviour tested elsewhere.
	menu.call("set_open", false)
	settings.call("set_fov_degrees", 66.0)
	menu.call("set_open", true)
	var fov: FocusRingSlider = menu.get(&"_fov_slider")
	check(fov.readout_text() == "66°",
		"re-opening the panel re-derives the readout (got: %s)" % fov.readout_text())
	menu.call("set_open", false)

	check(FOCUS_RING_SLIDER.format_value(0.0, FOCUS_RING_SLIDER.Readout.PERCENT) == "0%",
		"the format table renders a zero volume as 0%")
	check(FOCUS_RING_SLIDER.format_value(60.0, FOCUS_RING_SLIDER.Readout.DEGREES) == "60°",
		"the format table renders the minimum FOV as 60°")
	check(FOCUS_RING_SLIDER.format_value(0.01, FOCUS_RING_SLIDER.Readout.DECIMAL2) == "0.01",
		"the format table keeps two decimals at the bottom of the sensitivity range")


## F-387: reported from play as "the settings menu has no scrolling so some settings are hidden".
## The ScrollContainer was always there — what stopped it was `Slider.scrollable`, which makes every
## slider eat the wheel and change its own value, plus `Control`'s STOP mouse filter, which then
## drops the event rather than letting the ancestor scroll. Both are properties, so both are
## assertable; the fixed 380 px viewport is checked here too.
func _check_scroll_reachability(menu: Node) -> void:
	print("\n== SettingsMenu: the wheel scrolls the panel (F-387) ==")
	var root_control: Control = menu.get(&"_root") as Control
	var sliders: Array[HSlider] = []
	_collect_sliders(root_control, sliders)
	check(sliders.size() == 6, "the panel still has its six sliders (%d)" % sliders.size())
	var wheel_safe: int = 0
	for slider: HSlider in sliders:
		if not slider.scrollable and slider.mouse_force_pass_scroll_events:
			wheel_safe += 1
	check(wheel_safe == sliders.size(),
		"every slider declines the wheel and lets it climb to the scroll container (%d/%d)"
			% [wheel_safe, sliders.size()])

	var scroll: ScrollContainer = menu.get(&"_scroll") as ScrollContainer
	check(scroll != null, "the panel exposes its ScrollContainer")
	if scroll == null:
		return
	check(scroll.follow_focus, "the viewport follows focus, so a gamepad can reach the rows below")

	var consts: Dictionary = (menu.get_script() as GDScript).get_script_constant_map()
	var window_height: float = float(root_control.get_viewport().get_visible_rect().size.y)
	var expected: float = maxf(
		minf(window_height * float(consts["SCROLL_HEIGHT_FRACTION"]),
			window_height - float(consts["SCROLL_CHROME_HEIGHT"])),
		float(consts["SCROLL_MIN_HEIGHT"]))
	check(is_equal_approx(scroll.custom_minimum_size.y, expected),
		"the viewport is derived from the window (%.0f px of %.0f), not a fixed 380"
			% [scroll.custom_minimum_size.y, window_height])
	check(scroll.custom_minimum_size.y + float(consts["SCROLL_CHROME_HEIGHT"]) <= window_height,
		"the panel with its title and footer still fits the window")


## F-386: reported from play as "theres no 'save changes' button in the settings menu to confirm
## changes". The contract is deliberately not "defer everything" — FOV has to move while you drag it
## — so what is proved here is the pair: the value applies live AND does not reach disk, until SAVE.
func _check_preview_commit(settings: Node, menu: Node) -> void:
	print("\n== SettingsMenu: preview, save, cancel, restore defaults (F-386) ==")
	settings.call("set_fov_degrees", 80.0)
	check(is_equal_approx(_fov_on_disk(), 80.0), "a change with no panel open persists as it always did")

	var fov_slider: HSlider = menu.get(&"_fov_slider") as HSlider
	var save_button: Button = menu.get(&"_save_button") as Button
	var restore_button: Button = menu.get(&"_restore_defaults_button") as Button
	check(save_button != null and restore_button != null, "the panel has SAVE and RESTORE DEFAULTS")
	if fov_slider == null or save_button == null or restore_button == null:
		return

	# ── drag, then cancel ────────────────────────────────────────────────────────────────────────
	menu.call("set_open", true)
	check(bool(settings.call("is_persistence_held")), "opening the panel starts a preview")
	check(not bool(menu.call("has_unsaved_changes")), "a freshly opened panel has nothing to save")

	fov_slider.value = 100.0
	check(is_equal_approx(float(settings.call("fov_degrees")), 100.0),
		"dragging FOV applies live — the preview is the whole reason this is not deferred")
	check(is_equal_approx(_fov_on_disk(), 80.0), "dragging FOV does NOT reach disk")
	check(bool(menu.call("has_unsaved_changes")), "the panel says it has unsaved changes")

	menu.call("set_open", false)
	check(is_equal_approx(float(settings.call("fov_degrees")), 80.0),
		"closing hands back the FOV the player opened with — the drag is recoverable")
	check(not bool(settings.call("is_persistence_held")), "closing releases the preview")
	check(is_equal_approx(_fov_on_disk(), 80.0), "the cancelled drag never touched disk")

	# ── drag, then save ──────────────────────────────────────────────────────────────────────────
	menu.call("set_open", true)
	fov_slider.value = 95.0
	save_button.pressed.emit()
	check(is_equal_approx(_fov_on_disk(), 95.0), "SAVE writes the staged value to disk")
	check(not bool(menu.call("has_unsaved_changes")), "SAVE clears the unsaved marker")
	check(bool(settings.call("is_persistence_held")),
		"SAVE keeps previewing, so the next edit stages instead of writing through")
	menu.call("set_open", false)
	check(is_equal_approx(float(settings.call("fov_degrees")), 95.0),
		"closing AFTER a save keeps the save rather than reverting to the opening value")
	check(is_equal_approx(_fov_on_disk(), 95.0), "and disk still holds it")

	# ── restore defaults is a proposal, not a commit ─────────────────────────────────────────────
	var default_fov: float = float((settings.call("default_state") as Dictionary)[&"fov_degrees"])
	menu.call("set_open", true)
	restore_button.pressed.emit()
	check(is_equal_approx(float(settings.call("fov_degrees")), default_fov),
		"RESTORE DEFAULTS loads the default FOV into the live state")
	check(is_equal_approx(fov_slider.value, default_fov), "and the slider follows it")
	check(is_equal_approx(_fov_on_disk(), 95.0), "RESTORE DEFAULTS does not persist on its own")
	check(bool(menu.call("has_unsaved_changes")), "restored defaults count as unsaved changes")
	menu.call("set_open", false)
	check(is_equal_approx(float(settings.call("fov_degrees")), 95.0),
		"closing undoes RESTORE DEFAULTS, same as any other unsaved change")

	# Leave the service unheld and agreeing with disk, for the on-disk assertions at the end of the
	# run — a leaked hold would make every later write invisible.
	check(not bool(settings.call("is_persistence_held")), "no preview is left holding the service")
	settings.call("set_fov_degrees", 90.0)
	settings.call("set_graphics_preset", 2)


func _fov_on_disk() -> float:
	return float(SETTINGS_SAVE.load_data(TEST_PATH).get(&"fov_degrees", -1.0))


func _collect_sliders(node: Node, into: Array[HSlider]) -> void:
	if node is HSlider:
		into.append(node)
	for child: Node in node.get_children():
		_collect_sliders(child, into)


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
