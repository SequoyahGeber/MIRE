class_name SettingsSave
extends RefCounted

## Persistence for task 7.5's player settings — graphics preset, audio bus volumes, look
## sensitivity/invert-Y/FOV, the "reduce camera motion" accessibility toggle, and any keyboard
## keybind overrides. Same shape as `salvage_save.gd`/`unlock_save.gd`: pure data I/O, no autoload;
## a missing file, a corrupt file and an old-schema file all resolve to something the caller can use
## without checking first.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row): none. Per-player
## presentation settings on that player's own machine — nothing here is ever sent to another peer.
##
## Pure data I/O, no autoload: `autoload/settings_service.gd` is the runtime seam that decides WHEN
## to load/save and applies the values to the engine; this class only knows how to get a Dictionary
## on and off disk.

const SAVE_PATH: String = "user://settings.json"
const SCHEMA_VERSION: int = 1


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
static func save_data(data: Dictionary, path: String = SAVE_PATH) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("SettingsSave: could not open %s for write (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	data["schema_version"] = SCHEMA_VERSION
	file.store_string(JSON.stringify(data))
	file.close()


static func _default_data() -> Dictionary:
	return {
		&"schema_version": SCHEMA_VERSION,
		&"graphics_preset": 2,
		&"master_volume": 1.0,
		&"music_volume": 1.0,
		&"sfx_volume": 1.0,
		&"look_sensitivity": 0.12,
		&"invert_y": false,
		&"fov_degrees": 75.0,
		&"reduce_camera_motion": false,
		&"keybinds": {},
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
	data["schema_version"] = version
	return data
