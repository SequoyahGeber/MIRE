class_name SettingsSave
extends RefCounted

## Persistence for task 7.5/7.6's player settings — graphics preset, audio bus volumes, mouse and
## gamepad look sensitivity/invert-Y/FOV, the "reduce camera motion" accessibility toggle, and any
## keyboard or gamepad-button keybind overrides. Same shape as `salvage_save.gd`/`unlock_save.gd`:
## pure data I/O, no autoload; a missing file, a corrupt file and an old-schema file all resolve to
## something the caller can use without checking first.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row): none. Per-player
## presentation settings on that player's own machine — nothing here is ever sent to another peer.
##
## Pure data I/O, no autoload: `autoload/settings_service.gd` is the runtime seam that decides WHEN
## to load/save and applies the values to the engine; this class only knows how to get a Dictionary
## on and off disk.

const SAVE_PATH: String = "user://settings.json"
const SCHEMA_VERSION: int = 4


## Reads `path` (defaults to `SAVE_PATH`) and returns an always-valid, always-current-schema
## Dictionary — a missing file, a corrupt file and an old-schema file all resolve to something the
## caller can use without checking first. `path` is only ever overridden by `tools/settings_check.gd`,
## so a check run never touches a real player's settings.
static func load_data(path: String = SAVE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _default_data()
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SettingsSave: could not open %s for read (%s)" % [path, error_string(FileAccess.get_open_error())])
		return _default_data()
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SettingsSave: %s did not contain a JSON object, starting fresh" % path)
		return _default_data()
	return _migrate(parsed as Dictionary)


## Writes `data` to `path` (defaults to `SAVE_PATH`), stamping the current schema version. Whole-file
## overwrite, not an append or a diff — the save is a handful of scalars plus a small keybind map, so
## there is nothing an incremental write would save that is worth the corruption risk of a partial one.
##
## Durable, via `AtomicJson` (F-326): the document lands in a sibling `.part` file and is renamed over
## the destination, so an interrupted write leaves the PREVIOUS settings intact rather than an empty
## file that `load_data()` would silently resolve to defaults — losing every rebound key and slider.
## `false` means the save did not happen AND the old one survived.
static func save_data(data: Dictionary, path: String = SAVE_PATH) -> bool:
	data["schema_version"] = SCHEMA_VERSION
	return AtomicJson.write(path, data, "SettingsSave")


static func _default_data() -> Dictionary:
	return {
		&"schema_version": SCHEMA_VERSION,
		&"graphics_preset": 2,
		&"window_mode": 0,
		&"resolution_index": 1,
		&"vsync_enabled": true,
		&"fps_cap": 0,
		&"ssao_override": -1,
		&"anti_aliasing": 2,
		&"dynamic_resolution": false,
		&"brightness": 1.0,
		&"master_volume": 1.0,
		&"music_volume": 1.0,
		&"sfx_volume": 1.0,
		&"look_sensitivity": 0.12,
		&"gamepad_look_sensitivity": 180.0,
		&"invert_y": false,
		&"fov_degrees": 75.0,
		&"reduce_camera_motion": false,
		&"ui_scale": 1.0,
		&"camera_shake_intensity": 1.0,
		&"foliage_quality": -1,
		&"shadow_quality": -1,
		&"shadow_distance": -1,
		&"volumetric_fog": -1,
		&"left_stick_deadzone": 0.2,
		&"right_stick_deadzone": 0.2,
		&"controller_vibration": 1.0,
		&"crosshair_size": 1.0,
		&"crosshair_opacity": 1.0,
		&"crosshair_colour": "ffffff",
		&"crosshair_high_contrast": false,
		&"streamer_mode": false,
		&"guidance_mode": 0,
		&"guide_tips_seen": [],
		&"keybinds": {},
		&"joypad_binds": {},
	}


## Same migration shape `salvage_save.gd`/`unlock_save.gd` already use — one more `if version < N:`
## block per future schema bump, upgrading in place. Today there is only one shipped schema, so this
## pass does nothing but backfill missing keys (an interrupted first write, or a hand-edited file).
static func _migrate(data: Dictionary) -> Dictionary:
	var version: int = int(data.get("schema_version", 0))
	if version < 1:
		var defaults: Dictionary = _default_data()
		for key: StringName in defaults:
			if key == &"schema_version":
				continue
			if not data.has(String(key)):
				data[String(key)] = defaults[key]
		version = 1
	if version < 2:
		var defaults: Dictionary = _default_data()
		for key: StringName in [&"window_mode", &"resolution_index", &"vsync_enabled", &"fps_cap",
				&"ssao_override", &"anti_aliasing", &"dynamic_resolution", &"brightness"]:
			if not data.has(String(key)):
				data[String(key)] = defaults[key]
		version = 2
	if version < 3:
		# Task 3.19's guidance layer. Backfilled rather than assumed present: a player upgrading
		# into this build has never seen a tip, and `guidance_mode` 0 is FULL — the default a new
		# player wants and an existing one can turn off in one click.
		var defaults: Dictionary = _default_data()
		for key: StringName in [&"guidance_mode", &"guide_tips_seen"]:
			if not data.has(String(key)):
				data[String(key)] = defaults[key]
		version = 3
	if version < 4:
		var defaults: Dictionary = _default_data()
		for key: StringName in [&"ui_scale", &"camera_shake_intensity", &"foliage_quality",
				&"shadow_quality", &"shadow_distance", &"volumetric_fog",
				&"left_stick_deadzone", &"right_stick_deadzone", &"controller_vibration",
				&"crosshair_size", &"crosshair_opacity", &"crosshair_colour",
				&"crosshair_high_contrast", &"streamer_mode"]:
			if not data.has(String(key)):
				data[String(key)] = defaults[key]
		version = 4
	data["schema_version"] = version
	return data
