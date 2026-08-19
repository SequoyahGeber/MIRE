extends Node

## SettingsService — autoload (task 7.5). Owns every knob `ui/menu/settings_menu.gd` exposes:
## graphics preset (delegates to `GraphicsQuality.apply()`), the Master/Music/SFX audio bus
## volumes, look sensitivity/invert-Y/FOV (read by `entities/player/player_camera.gd`), the
## "reduce camera motion" accessibility toggle, and keyboard keybind overrides (InputMap, keyboard
## events only — joypad bindings are untouched, and `attack` stays mouse-bound; rebinding those is
## a different UI flow than 7.5 scopes). Persists to `user://settings.json` via
## `core/save/settings_save.gd`, the same D-107 shape SalvageService/UnlockService already use —
## see `_persistence_enabled()`.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row): none. Every peer
## applies its own settings locally; nothing here is ever sent over the wire.
##
## Registered last in `project.godot`'s `[autoload]` list (D-021 append-only) — everything it reads
## at `_ready()` (`GraphicsQuality`, `AudioServer`, `InputMap`) is either an engine singleton or an
## autoload already earlier in that list, so append-only ordering is never a problem here. Consumers
## (`SettingsMenu`, `PlayerCamera`) look this node up lazily via `/root/SettingsService` rather than
## assuming boot order, so they never depend on where in the list this entry sits either.

const SETTINGS_SAVE := preload("res://core/save/settings_save.gd")

const MUSIC_BUS: StringName = &"Music"
const SFX_BUS: StringName = &"SFX"

## The keyboard-primary actions a settings row may rebind. `attack` is mouse-button-primary and
## out of scope for 7.5's keybind rows.
const REBINDABLE_ACTIONS: PackedStringArray = [
	"move_forward", "move_back", "move_left", "move_right",
	"jump", "sprint", "interact", "inventory", "build", "dodge",
]

const MIN_FOV: float = 60.0
const MAX_FOV: float = 110.0
const MIN_SENSITIVITY: float = 0.01
const MAX_SENSITIVITY: float = 1.0

## Fires after any setting changes and is applied — `PlayerCamera` and `SettingsMenu` both refresh
## from this rather than each setter having its own bespoke callback.
signal settings_changed

## Override for `tools/settings_check.gd` only — production code never sets this, so it always
## reads `SettingsSave.SAVE_PATH` and a check run never touches a real player's settings file.
var save_path: String = SETTINGS_SAVE.SAVE_PATH

var _graphics_preset: int = 2
var _master_volume: float = 1.0
var _music_volume: float = 1.0
var _sfx_volume: float = 1.0
var _look_sensitivity: float = 0.12
var _invert_y: bool = false
var _fov_degrees: float = 75.0
var _reduce_camera_motion: bool = false
## StringName action -> int physical_keycode. Only entries this peer has explicitly rebound; every
## action not in here is still bound, just to `project.godot`'s own authored default.
var _keybinds: Dictionary = {}


func _ready() -> void:
	_ensure_audio_buses()
	_load()


func graphics_preset() -> int:
	return _graphics_preset


func set_graphics_preset(preset: int) -> void:
	_graphics_preset = clampi(preset, 0, 2)
	_apply_graphics()
	_save()
	settings_changed.emit()


func master_volume() -> float:
	return _master_volume


func set_master_volume(linear: float) -> void:
	_master_volume = clampf(linear, 0.0, 1.0)
	_apply_bus_volume(&"Master", _master_volume)
	_save()
	settings_changed.emit()


func music_volume() -> float:
	return _music_volume


func set_music_volume(linear: float) -> void:
	_music_volume = clampf(linear, 0.0, 1.0)
	_apply_bus_volume(MUSIC_BUS, _music_volume)
	_save()
	settings_changed.emit()


func sfx_volume() -> float:
	return _sfx_volume


func set_sfx_volume(linear: float) -> void:
	_sfx_volume = clampf(linear, 0.0, 1.0)
	_apply_bus_volume(SFX_BUS, _sfx_volume)
	_save()
	settings_changed.emit()


func look_sensitivity() -> float:
	return _look_sensitivity


func set_look_sensitivity(value: float) -> void:
	_look_sensitivity = clampf(value, MIN_SENSITIVITY, MAX_SENSITIVITY)
	_save()
	settings_changed.emit()


func invert_y() -> bool:
	return _invert_y


func set_invert_y(value: bool) -> void:
	_invert_y = value
	_save()
	settings_changed.emit()


func fov_degrees() -> float:
	return _fov_degrees


func set_fov_degrees(value: float) -> void:
	_fov_degrees = clampf(value, MIN_FOV, MAX_FOV)
	_save()
	settings_changed.emit()


func reduce_camera_motion() -> bool:
	return _reduce_camera_motion


func set_reduce_camera_motion(value: bool) -> void:
	_reduce_camera_motion = value
	_save()
	settings_changed.emit()


func rebindable_actions() -> PackedStringArray:
	return REBINDABLE_ACTIONS


## The physical key currently bound to `action`, as a display string ("—" if none, which should
## never happen for a real InputMap action but keeps this total).
func keybind_label(action: StringName) -> String:
	if not InputMap.has_action(action):
		return "—"
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventKey:
			return OS.get_keycode_string((event as InputEventKey).physical_keycode)
	return "—"


## Rebinds `action`'s keyboard event to `event`'s physical keycode. Returns `&""` on success, or the
## StringName of the other rebindable action already using that key (nothing changes then) — two
## actions must never share a key, or a player physically cannot press one while holding the other.
func rebind_action(action: StringName, event: InputEventKey) -> StringName:
	if not REBINDABLE_ACTIONS.has(String(action)):
		return &"__not_rebindable__"
	for other_name: String in REBINDABLE_ACTIONS:
		var other := StringName(other_name)
		if other == action:
			continue
		for existing: InputEvent in InputMap.action_get_events(other):
			if existing is InputEventKey \
					and (existing as InputEventKey).physical_keycode == event.physical_keycode:
				return other
	_apply_keybind(action, event.physical_keycode)
	_keybinds[action] = event.physical_keycode
	_save()
	settings_changed.emit()
	return &""


## Drops every rebind this peer has made and restores `project.godot`'s own authored InputMap.
func reset_keybinds() -> void:
	InputMap.load_from_project_settings()
	_keybinds.clear()
	_save()
	settings_changed.emit()


func _apply_keybind(action: StringName, physical_keycode: int) -> void:
	if not InputMap.has_action(action):
		return
	for existing: InputEvent in InputMap.action_get_events(action):
		if existing is InputEventKey:
			InputMap.action_erase_event(action, existing)
	var new_event := InputEventKey.new()
	new_event.physical_keycode = physical_keycode
	InputMap.action_add_event(action, new_event)


## "Music"/"SFX" are runtime-created rather than a committed bus layout resource — a couple of
## `AudioServer.add_bus()` calls need no `.tres` and avoids adding a Godot-authored file to this
## task's claim set for something this small (AGENTS.md's Godot-file rule). Both send to Master, so
## a bus with nothing routed to it yet (Music, until a future MusicDirector plays into it — see
## docs/DELEGATION.md's 7.1/7.2 note) still obeys the Master slider.
func _ensure_audio_buses() -> void:
	_ensure_bus(MUSIC_BUS)
	_ensure_bus(SFX_BUS)


func _ensure_bus(bus_name: StringName) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	var index: int = AudioServer.bus_count
	AudioServer.add_bus(index)
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, &"Master")


func _apply_graphics() -> void:
	var gfx: Node = get_node_or_null(^"/root/GraphicsQuality")
	if gfx != null and gfx.has_method("apply"):
		gfx.call("apply", _graphics_preset)


func _apply_bus_volume(bus_name: StringName, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	AudioServer.set_bus_mute(index, linear <= 0.0)
	if linear > 0.0:
		AudioServer.set_bus_volume_db(index, linear_to_db(linear))


func _load() -> void:
	var data: Dictionary = SETTINGS_SAVE.load_data(save_path)
	_graphics_preset = clampi(int(data.get(&"graphics_preset", 2)), 0, 2)
	_master_volume = clampf(float(data.get(&"master_volume", 1.0)), 0.0, 1.0)
	_music_volume = clampf(float(data.get(&"music_volume", 1.0)), 0.0, 1.0)
	_sfx_volume = clampf(float(data.get(&"sfx_volume", 1.0)), 0.0, 1.0)
	_look_sensitivity = clampf(
		float(data.get(&"look_sensitivity", 0.12)), MIN_SENSITIVITY, MAX_SENSITIVITY)
	_invert_y = bool(data.get(&"invert_y", false))
	_fov_degrees = clampf(float(data.get(&"fov_degrees", 75.0)), MIN_FOV, MAX_FOV)
	_reduce_camera_motion = bool(data.get(&"reduce_camera_motion", false))

	_keybinds.clear()
	var raw_keybinds: Dictionary = data.get(&"keybinds", {}) as Dictionary
	for action_name: String in raw_keybinds.keys():
		if not REBINDABLE_ACTIONS.has(action_name):
			continue
		var keycode: int = int(raw_keybinds[action_name])
		_apply_keybind(StringName(action_name), keycode)
		_keybinds[StringName(action_name)] = keycode

	_apply_graphics()
	_apply_bus_volume(&"Master", _master_volume)
	_apply_bus_volume(MUSIC_BUS, _music_volume)
	_apply_bus_volume(SFX_BUS, _sfx_volume)


func _save() -> void:
	if not _persistence_enabled():
		return
	var raw_keybinds: Dictionary = {}
	for action: StringName in _keybinds.keys():
		raw_keybinds[String(action)] = _keybinds[action]
	SETTINGS_SAVE.save_data({
		"graphics_preset": _graphics_preset,
		"master_volume": _master_volume,
		"music_volume": _music_volume,
		"sfx_volume": _sfx_volume,
		"look_sensitivity": _look_sensitivity,
		"invert_y": _invert_y,
		"fov_degrees": _fov_degrees,
		"reduce_camera_motion": _reduce_camera_motion,
		"keybinds": raw_keybinds,
	}, save_path)


## Same D-107 guard `SalvageService`/`UnlockService` already use: a `--script` harness never loads
## `project.godot`'s `run/main_scene` (`current_scene` stays null for the whole run), which the real
## game always does, so that is the one signal available for free. `tools/settings_check.gd` opts
## back in by overriding `save_path` away from the real one.
func _persistence_enabled() -> bool:
	return save_path != SETTINGS_SAVE.SAVE_PATH or get_tree().current_scene != null
