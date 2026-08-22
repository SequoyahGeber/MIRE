extends Node

## SettingsService — autoload (task 7.5, gamepad rebind + look sensitivity added by 7.6). Owns every
## knob `ui/menu/settings_menu.gd` exposes: graphics preset (delegates to `GraphicsQuality.apply()`),
## the Master/Music/SFX audio bus volumes, mouse and gamepad look sensitivity/invert-Y/FOV (read by
## `entities/player/player_camera.gd`), the "reduce camera motion" accessibility toggle, keyboard
## keybind overrides (InputMap `InputEventKey` events — `attack`/`build_destroy` stay mouse-primary
## and out of scope, D-114/D-131), and gamepad button keybind overrides (InputMap
## `InputEventJoypadButton` events, `JOYPAD_REBINDABLE_ACTIONS` only — the analog-bound actions
## (movement, look, `attack`, `build_destroy`) have no single-button capture flow, D-131). Persists
## to `user://settings.json` via `core/save/settings_save.gd`, the same D-107 shape
## SalvageService/UnlockService already use — see `_persistence_enabled()`.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row): none. Every peer
## applies its own settings locally; nothing here is ever sent over the wire.
##
## Since F-386 this also owns the preview seam both settings screens commit through —
## `hold_persistence()` / `release_persistence()` / `capture_state()` / `apply_state()` /
## `default_state()`, documented at their own section below. It changes nothing for any other caller:
## a setter invoked from gameplay code still applies and persists on the spot.
##
## Registered last in `project.godot`'s `[autoload]` list (D-021 append-only) — everything it reads
## at `_ready()` (`GraphicsQuality`, `AudioServer`, `InputMap`) is either an engine singleton or an
## autoload already earlier in that list, so append-only ordering is never a problem here. Consumers
## (`SettingsMenu`, `PlayerCamera`) look this node up lazily via `/root/SettingsService` rather than
## assuming boot order, so they never depend on where in the list this entry sits either.

const SETTINGS_SAVE := preload("res://core/save/settings_save.gd")
## First-boot hardware classification (F-452). Preloaded, not `class_name`-referenced, so a
## headless `--script` run can reach it before the editor rescans the project.
const HARDWARE_TIER := preload("res://core/render/hardware_tier.gd")

const MUSIC_BUS: StringName = &"Music"
const SFX_BUS: StringName = &"SFX"

## The keyboard-primary actions a settings row may rebind. `attack`/`build_destroy` are
## mouse-button-primary and out of scope, same reasoning D-114 gave for `attack` alone before
## `build_destroy` existed (D-131).
const REBINDABLE_ACTIONS: PackedStringArray = [
	"move_forward", "move_back", "move_left", "move_right",
	"jump", "sprint", "interact", "inventory", "build", "dodge", "eat", "build_rotate",
]

## The gamepad-BUTTON-primary actions a settings row may rebind to a different `InputEventJoypadButton`
## (task 7.6/D-131). Deliberately excludes every action whose gamepad binding is an axis/trigger
## (`move_*`, `look_*`, `attack`, `build_destroy`) — a single-button-press capture flow (this file's
## `rebind_action_joypad`, `SettingsMenu._finish_rebind_joypad()`) does not generalize to "hold a stick
## direction" or "pull a trigger" without a materially different UI, the same boundary D-114 drew
## around `attack`'s mouse binding for keyboard rebind.
const JOYPAD_REBINDABLE_ACTIONS: PackedStringArray = [
	"jump", "sprint", "interact", "inventory", "build", "dodge",
	"eat", "build_rotate", "hotbar_prev", "hotbar_next",
]

## Friendly labels for the JoyButton indices this project actually binds (task 7.6) — Godot has no
## built-in "joystick button name" util the way `OS.get_keycode_string()` covers keyboard. Xbox-layout
## names, since GodotSteam's `SteamMultiplayerPeer`/Steam Input remaps every controller (including a
## Steam Deck's own) to that layout before Godot ever sees an event (ARCHITECTURE.md §2.4).
const JOYPAD_BUTTON_LABELS: Dictionary = {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "BACK", JOY_BUTTON_GUIDE: "GUIDE", JOY_BUTTON_START: "START",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_DPAD_UP: "D-PAD UP", JOY_BUTTON_DPAD_DOWN: "D-PAD DOWN",
	JOY_BUTTON_DPAD_LEFT: "D-PAD LEFT", JOY_BUTTON_DPAD_RIGHT: "D-PAD RIGHT",
}

const MIN_FOV: float = 60.0
const MAX_FOV: float = 110.0
const MIN_SENSITIVITY: float = 0.01
const MAX_SENSITIVITY: float = 1.0
const MIN_GAMEPAD_SENSITIVITY: float = 30.0
const MAX_GAMEPAD_SENSITIVITY: float = 720.0
const WINDOW_MODES: PackedStringArray = ["WINDOWED", "BORDERLESS", "FULLSCREEN"]
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1152, 648), Vector2i(1280, 720), Vector2i(1600, 900),
	Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160),
]
const FPS_CAPS: PackedInt32Array = [0, 30, 60, 90, 120, 144, 165, 240]
const ANTI_ALIASING_MODES: PackedStringArray = ["OFF", "FXAA", "TAA", "MSAA 2X", "MSAA 4X"]

## Every value's factory default, in one place. These were three copies before F-386 — the field
## initialisers below, `_load()`'s `data.get()` fallbacks, and `core/save/settings_save.gd`'s
## migration backfill — and the settings screens' "restore defaults" button had no way to ask for
## them at all, which is why they never had one. `_load()` and `default_state()` both read from here
## now; `settings_save.gd` keeps its own copy because a save-file migration has to be able to run
## without this autoload, and `tools/settings_check.gd` asserts the two agree.
const DEFAULTS: Dictionary = {
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
}

## Fires after any setting changes and is applied — `PlayerCamera` and `SettingsMenu` both refresh
## from this rather than each setter having its own bespoke callback.
signal settings_changed

## Override for `tools/settings_check.gd` only — production code never sets this, so it always
## reads `SettingsSave.SAVE_PATH` and a check run never touches a real player's settings file.
var save_path: String = SETTINGS_SAVE.SAVE_PATH

## F-386: how many settings surfaces are currently previewing. While this is above zero every setter
## still applies its value for real — the player must see FOV and sensitivity change as they drag —
## but `_save()` records the intent instead of writing, and the open screen decides on Save or Cancel
## whether that intent ever reaches disk. Counted rather than a bool only so a stray double
## `hold_persistence()` cannot strand the service in preview mode; D-032's one-cursor-UI interlock
## means two screens are never actually open at once.
var _persistence_holds: int = 0
## True when a setter wanted to write while held. Cleared by either outcome of `release_persistence`.
var _persistence_pending: bool = false

var _graphics_preset: int = 2
var _window_mode: int = 0
var _resolution_index: int = 1
var _vsync_enabled: bool = true
var _fps_cap: int = 0
var _ssao_override: int = -1
var _anti_aliasing: int = 2
var _dynamic_resolution: bool = false
var _brightness: float = 1.0
var _master_volume: float = 1.0
var _music_volume: float = 1.0
var _sfx_volume: float = 1.0
var _look_sensitivity: float = 0.12
var _gamepad_look_sensitivity: float = 180.0
var _invert_y: bool = false
var _fov_degrees: float = 75.0
var _reduce_camera_motion: bool = false
var _ui_scale: float = 1.0
var _camera_shake_intensity: float = 1.0
var _foliage_quality: int = -1
var _shadow_quality: int = -1
var _shadow_distance: int = -1
var _volumetric_fog: int = -1
var _left_stick_deadzone: float = 0.2
var _right_stick_deadzone: float = 0.2
var _controller_vibration: float = 1.0
var _crosshair_size: float = 1.0
var _crosshair_opacity: float = 1.0
var _crosshair_colour: String = "ffffff"
var _crosshair_high_contrast: bool = false
var _streamer_mode: bool = false
## Task 3.19. 0 FULL · 1 OBJECTIVES ONLY · 2 OFF — see `GuideService.Mode`, which owns the meaning;
## this file only stores and persists the number, the same way it does for `graphics_preset`.
var _guidance_mode: int = 0
## Ids of tips this PROFILE has already been shown, so a returning player is never re-taught
## (`docs/PROGRESSION.md` §5.2). Grows by one String per tip and is never pruned — the whole
## authored set is a few dozen entries, which is smaller than one keybind row.
var _guide_tips_seen: Dictionary = {}
## StringName action -> int physical_keycode. Only entries this peer has explicitly rebound; every
## action not in here is still bound, just to `project.godot`'s own authored default.
var _keybinds: Dictionary = {}
## StringName action -> int JoyButton index. Same shape as `_keybinds`, for `JOYPAD_REBINDABLE_ACTIONS`
## (task 7.6).
var _joypad_binds: Dictionary = {}


func _ready() -> void:
	_ensure_audio_buses()
	_load()


func graphics_preset() -> int:
	return _graphics_preset


func graphics_selection() -> int:
	return 3 if _foliage_quality >= 0 or _shadow_quality >= 0 or _shadow_distance >= 0 \
		or _volumetric_fog >= 0 else _graphics_preset


func set_graphics_preset(preset: int) -> void:
	if preset > 2:
		return
	_graphics_preset = clampi(preset, 0, 2)
	_foliage_quality = -1
	_shadow_quality = -1
	_shadow_distance = -1
	_volumetric_fog = -1
	_apply_graphics()
	_save()
	settings_changed.emit()


func window_mode() -> int:
	return _window_mode


func set_window_mode(mode: int) -> void:
	_window_mode = clampi(mode, 0, WINDOW_MODES.size() - 1)
	_apply_display()
	_save()
	settings_changed.emit()


func resolution_index() -> int:
	return _resolution_index


func set_resolution_index(index: int) -> void:
	_resolution_index = clampi(index, 0, RESOLUTIONS.size() - 1)
	_apply_display()
	_save()
	settings_changed.emit()


func vsync_enabled() -> bool:
	return _vsync_enabled


func set_vsync_enabled(enabled: bool) -> void:
	_vsync_enabled = enabled
	_apply_display()
	_save()
	settings_changed.emit()


func fps_cap() -> int:
	return _fps_cap


func set_fps_cap(cap: int) -> void:
	_fps_cap = cap if FPS_CAPS.has(cap) else 0
	_apply_display()
	_save()
	settings_changed.emit()


func ssao_override() -> int:
	return _ssao_override


func set_ssao_override(value: int) -> void:
	_ssao_override = clampi(value, -1, 1)
	_apply_graphics()
	_save()
	settings_changed.emit()


func anti_aliasing() -> int:
	return _anti_aliasing


func set_anti_aliasing(value: int) -> void:
	_anti_aliasing = clampi(value, 0, ANTI_ALIASING_MODES.size() - 1)
	_apply_display()
	_save()
	settings_changed.emit()


func dynamic_resolution() -> bool:
	return _dynamic_resolution


func set_dynamic_resolution(enabled: bool) -> void:
	_dynamic_resolution = enabled
	_apply_graphics()
	_save()
	settings_changed.emit()


func brightness() -> float:
	return _brightness


func set_brightness(value: float) -> void:
	_brightness = clampf(value, 0.5, 1.5)
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


func gamepad_look_sensitivity() -> float:
	return _gamepad_look_sensitivity


func set_gamepad_look_sensitivity(value: float) -> void:
	_gamepad_look_sensitivity = clampf(value, MIN_GAMEPAD_SENSITIVITY, MAX_GAMEPAD_SENSITIVITY)
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


func ui_scale() -> float: return _ui_scale
func camera_shake_intensity() -> float: return 0.0 if _reduce_camera_motion else _camera_shake_intensity
func foliage_quality() -> int: return _foliage_quality
func shadow_quality() -> int: return _shadow_quality
func shadow_distance() -> int: return _shadow_distance
func volumetric_fog() -> int: return _volumetric_fog
func left_stick_deadzone() -> float: return _left_stick_deadzone
func right_stick_deadzone() -> float: return _right_stick_deadzone
func controller_vibration() -> float: return _controller_vibration
func crosshair_size() -> float: return _crosshair_size
func crosshair_opacity() -> float: return _crosshair_opacity
func crosshair_colour() -> String: return _crosshair_colour
func crosshair_high_contrast() -> bool: return _crosshair_high_contrast
func streamer_mode() -> bool: return _streamer_mode

func set_ui_scale(value: float) -> void:
	_ui_scale = clampf(value, 1.0, 1.5)
	_apply_ui_scale()
	_save()
	settings_changed.emit()
func set_camera_shake_intensity(value: float) -> void: _set_advanced(&"camera_shake_intensity", clampf(value, 0.0, 1.0))
func set_foliage_quality(value: int) -> void: _set_graphics_override(&"foliage_quality", clampi(value, -1, 2))
func set_shadow_quality(value: int) -> void: _set_graphics_override(&"shadow_quality", clampi(value, -1, 2))
func set_shadow_distance(value: int) -> void: _set_graphics_override(&"shadow_distance", clampi(value, -1, 2))
func set_volumetric_fog(value: int) -> void: _set_graphics_override(&"volumetric_fog", clampi(value, -1, 1))
func set_left_stick_deadzone(value: float) -> void:
	_left_stick_deadzone = clampf(value, 0.0, 0.5)
	_apply_deadzones()
	_save()
	settings_changed.emit()
func set_right_stick_deadzone(value: float) -> void:
	_right_stick_deadzone = clampf(value, 0.0, 0.5)
	_apply_deadzones()
	_save()
	settings_changed.emit()
func set_controller_vibration(value: float) -> void: _set_advanced(&"controller_vibration", clampf(value, 0.0, 1.0))
func set_crosshair_size(value: float) -> void: _set_advanced(&"crosshair_size", clampf(value, 0.5, 2.0))
func set_crosshair_opacity(value: float) -> void: _set_advanced(&"crosshair_opacity", clampf(value, 0.1, 1.0))
func set_crosshair_colour(value: String) -> void:
	var colour := Color.from_string(value, Color.WHITE)
	_set_advanced(&"crosshair_colour", colour.to_html(false))
func set_crosshair_high_contrast(value: bool) -> void: _set_advanced(&"crosshair_high_contrast", value)
func set_streamer_mode(value: bool) -> void: _set_advanced(&"streamer_mode", value)

func vibrate_controller(weak: float, strong: float, duration: float, device: int = 0) -> void:
	if _controller_vibration <= 0.0 or duration <= 0.0:
		return
	Input.start_joy_vibration(device, clampf(weak, 0.0, 1.0) * _controller_vibration,
		clampf(strong, 0.0, 1.0) * _controller_vibration, duration)

func _set_advanced(property: StringName, value: Variant) -> void:
	set("_" + String(property), value)
	_save()
	settings_changed.emit()

func _set_graphics_override(property: StringName, value: int) -> void:
	set("_" + String(property), value)
	_apply_graphics()
	_save()
	settings_changed.emit()


## 0 FULL · 1 OBJECTIVES ONLY · 2 OFF. `GuideService.Mode` names them.
func guidance_mode() -> int:
	return _guidance_mode


func set_guidance_mode(mode: int) -> void:
	_guidance_mode = clampi(mode, 0, 2)
	_save()
	settings_changed.emit()


func has_seen_tip(tip_id: StringName) -> bool:
	return _guide_tips_seen.has(tip_id)


## Idempotent, and silent when nothing changed — a tip already marked must not cost a disk write
## every time it is re-evaluated.
func mark_tip_seen(tip_id: StringName) -> void:
	if tip_id == &"" or _guide_tips_seen.has(tip_id):
		return
	_guide_tips_seen[tip_id] = true
	_save()


## Wipes the "already taught" record, so the tips fire again from scratch. Exists for the settings
## screen ("show tips again") and for `tools/guide_check.gd`, which would otherwise be at the mercy
## of whatever the dev machine's profile had already seen.
func reset_seen_tips() -> void:
	if _guide_tips_seen.is_empty():
		return
	_guide_tips_seen.clear()
	_save()
	settings_changed.emit()


func _seen_tip_list() -> Array:
	var out: Array = []
	for tip_id: StringName in _guide_tips_seen.keys():
		out.append(String(tip_id))
	out.sort()
	return out


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


## Drops every rebind this peer has made — keyboard AND gamepad — and restores `project.godot`'s own
## authored InputMap.
func reset_keybinds() -> void:
	InputMap.load_from_project_settings()
	_keybinds.clear()
	_joypad_binds.clear()
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


func rebindable_actions_joypad() -> PackedStringArray:
	return JOYPAD_REBINDABLE_ACTIONS


## The gamepad button currently bound to `action`, as a display string ("—" if none).
func keybind_label_joypad(action: StringName) -> String:
	if not InputMap.has_action(action):
		return "—"
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventJoypadButton:
			var button_index: int = (event as InputEventJoypadButton).button_index
			return String(JOYPAD_BUTTON_LABELS.get(button_index, "BUTTON %d" % button_index))
	return "—"


## Gamepad-button counterpart to `rebind_action()` — same "two actions must never share a
## button/key" refusal, checked against `JOYPAD_REBINDABLE_ACTIONS`' own joypad events only, never
## the keyboard ones `rebind_action()` guards.
func rebind_action_joypad(action: StringName, event: InputEventJoypadButton) -> StringName:
	if not JOYPAD_REBINDABLE_ACTIONS.has(String(action)):
		return &"__not_rebindable__"
	for other_name: String in JOYPAD_REBINDABLE_ACTIONS:
		var other := StringName(other_name)
		if other == action:
			continue
		for existing: InputEvent in InputMap.action_get_events(other):
			if existing is InputEventJoypadButton \
					and (existing as InputEventJoypadButton).button_index == event.button_index:
				return other
	_apply_keybind_joypad(action, event.button_index)
	_joypad_binds[action] = event.button_index
	_save()
	settings_changed.emit()
	return &""


func _apply_keybind_joypad(action: StringName, button_index: int) -> void:
	if not InputMap.has_action(action):
		return
	for existing: InputEvent in InputMap.action_get_events(action):
		if existing is InputEventJoypadButton:
			InputMap.action_erase_event(action, existing)
	var new_event := InputEventJoypadButton.new()
	new_event.button_index = button_index
	InputMap.action_add_event(action, new_event)


# ── F-386: preview, then commit or discard ────────────────────────────────────────────────────────
#
# Before this, every control in both settings screens wrote straight through to a setter that applied
# AND persisted on the spot: no Save, no Cancel, no way back to what you had. Reported from play
# (2026-08-20, Sequoyah) as "theres no 'save changes' button in the settings menu to confirm changes",
# and it is worse than it sounds combined with F-385's missing readouts — a FOV handle knocked by
# accident was unrecoverable, because you could not see the number you had and nothing would put it
# back.
#
# Making everything deferred would have been the wrong fix: you have to SEE field of view and mouse
# sensitivity to judge them, so a settings screen that only applies on Save is a settings screen you
# cannot tune. These four calls are the seam that lets a screen keep the live preview and still offer
# a real commit step:
#
#     hold_persistence()                    on open — stop writing to disk, keep applying
#     var baseline := capture_state()       on open — what the player had, to hand back on Cancel
#     release_persistence(true)             SAVE    — flush the current state to disk
#     apply_state(baseline)                 CANCEL  — put every value back, live, still not writing
#     release_persistence(false)            CANCEL  — drop the intent; memory matches disk again
#
# Nothing else in the project holds persistence, so a setter called from gameplay code (or from a
# check) behaves exactly as it always did.


## Begins a preview. Setters keep applying; `_save()` stops writing until the matching release.
func hold_persistence() -> void:
	_persistence_holds += 1


## Ends a preview. `commit` true writes the current in-memory state to disk (SAVE); false drops the
## deferred write entirely (CANCEL) — correct only because the canceller has already handed the
## baseline back through `apply_state()`, which leaves memory equal to what is still on disk.
func release_persistence(commit: bool) -> void:
	_persistence_holds = maxi(_persistence_holds - 1, 0)
	if _persistence_holds > 0:
		return
	var pending: bool = _persistence_pending
	_persistence_pending = false
	if commit and pending:
		_save()


func is_persistence_held() -> bool:
	return _persistence_holds > 0


## Every persisted value as it stands right now, in the shape `apply_state()` reads back. The
## keybind dictionaries are duplicated: a snapshot the caller holds across a whole settings session
## must not be mutated out from under it by the rebinds that session performs.
func capture_state() -> Dictionary:
	return {
		&"graphics_preset": _graphics_preset,
		&"window_mode": _window_mode,
		&"resolution_index": _resolution_index,
		&"vsync_enabled": _vsync_enabled,
		&"fps_cap": _fps_cap,
		&"ssao_override": _ssao_override,
		&"anti_aliasing": _anti_aliasing,
		&"dynamic_resolution": _dynamic_resolution,
		&"brightness": _brightness,
		&"master_volume": _master_volume,
		&"music_volume": _music_volume,
		&"sfx_volume": _sfx_volume,
		&"look_sensitivity": _look_sensitivity,
		&"gamepad_look_sensitivity": _gamepad_look_sensitivity,
		&"invert_y": _invert_y,
		&"fov_degrees": _fov_degrees,
		&"reduce_camera_motion": _reduce_camera_motion,
		&"ui_scale": _ui_scale,
		&"camera_shake_intensity": _camera_shake_intensity,
		&"foliage_quality": _foliage_quality,
		&"shadow_quality": _shadow_quality,
		&"shadow_distance": _shadow_distance,
		&"volumetric_fog": _volumetric_fog,
		&"left_stick_deadzone": _left_stick_deadzone,
		&"right_stick_deadzone": _right_stick_deadzone,
		&"controller_vibration": _controller_vibration,
		&"crosshair_size": _crosshair_size,
		&"crosshair_opacity": _crosshair_opacity,
		&"crosshair_colour": _crosshair_colour,
		&"crosshair_high_contrast": _crosshair_high_contrast,
		&"streamer_mode": _streamer_mode,
		&"keybinds": _keybinds.duplicate(),
		&"joypad_binds": _joypad_binds.duplicate(),
	}


## The factory defaults in `capture_state()`'s shape, with no keybind overrides at all — "restore
## defaults" has to reach the InputMap too, or the button would silently leave a rebound WASD in
## place while claiming everything was back to normal.
func default_state() -> Dictionary:
	var state: Dictionary = DEFAULTS.duplicate()
	state[&"keybinds"] = {}
	state[&"joypad_binds"] = {}
	return state


## Applies a whole state at once — the Cancel and Restore Defaults path. Every value is pushed
## through the same clamps and the same apply seams the individual setters use, then
## `settings_changed` fires exactly once, so a listener (`PlayerCamera`) sees one coherent change
## rather than eleven. Writes to disk only if nothing is holding persistence.
func apply_state(state: Dictionary) -> void:
	_graphics_preset = clampi(int(state.get(&"graphics_preset", _graphics_preset)), 0, 2)
	_window_mode = clampi(int(state.get(&"window_mode", _window_mode)), 0, WINDOW_MODES.size() - 1)
	_resolution_index = clampi(
		int(state.get(&"resolution_index", _resolution_index)), 0, RESOLUTIONS.size() - 1)
	_vsync_enabled = bool(state.get(&"vsync_enabled", _vsync_enabled))
	var requested_cap: int = int(state.get(&"fps_cap", _fps_cap))
	_fps_cap = requested_cap if FPS_CAPS.has(requested_cap) else 0
	_ssao_override = clampi(int(state.get(&"ssao_override", _ssao_override)), -1, 1)
	_anti_aliasing = clampi(
		int(state.get(&"anti_aliasing", _anti_aliasing)), 0, ANTI_ALIASING_MODES.size() - 1)
	_dynamic_resolution = bool(state.get(&"dynamic_resolution", _dynamic_resolution))
	_brightness = clampf(float(state.get(&"brightness", _brightness)), 0.5, 1.5)
	_master_volume = clampf(float(state.get(&"master_volume", _master_volume)), 0.0, 1.0)
	_music_volume = clampf(float(state.get(&"music_volume", _music_volume)), 0.0, 1.0)
	_sfx_volume = clampf(float(state.get(&"sfx_volume", _sfx_volume)), 0.0, 1.0)
	_look_sensitivity = clampf(
		float(state.get(&"look_sensitivity", _look_sensitivity)), MIN_SENSITIVITY, MAX_SENSITIVITY)
	_gamepad_look_sensitivity = clampf(
		float(state.get(&"gamepad_look_sensitivity", _gamepad_look_sensitivity)),
		MIN_GAMEPAD_SENSITIVITY, MAX_GAMEPAD_SENSITIVITY)
	_invert_y = bool(state.get(&"invert_y", _invert_y))
	_fov_degrees = clampf(float(state.get(&"fov_degrees", _fov_degrees)), MIN_FOV, MAX_FOV)
	_reduce_camera_motion = bool(state.get(&"reduce_camera_motion", _reduce_camera_motion))
	_load_advanced(state)

	_apply_keybind_state(
		state.get(&"keybinds", _keybinds) as Dictionary,
		state.get(&"joypad_binds", _joypad_binds) as Dictionary)

	_apply_values()
	_save()
	settings_changed.emit()


## Rebuilds the InputMap from `project.godot`'s authored bindings and then re-applies exactly the
## overrides in `keys`/`buttons`. Skipped entirely when neither dictionary differs from what is
## already applied — a Cancel that touched no keybind must not reset the whole InputMap, because
## `load_from_project_settings()` is process-wide and would drop a rebind another surface made.
func _apply_keybind_state(keys: Dictionary, buttons: Dictionary) -> void:
	if keys == _keybinds and buttons == _joypad_binds:
		return
	InputMap.load_from_project_settings()
	_keybinds = keys.duplicate()
	_joypad_binds = buttons.duplicate()
	for action: StringName in _keybinds.keys():
		_apply_keybind(action, int(_keybinds[action]))
	for action: StringName in _joypad_binds.keys():
		_apply_keybind_joypad(action, int(_joypad_binds[action]))


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
		gfx.call("set_player_overrides", _ssao_override, _brightness)
		if gfx.has_method(&"set_advanced_overrides"):
			gfx.call(&"set_advanced_overrides", _foliage_quality, _shadow_quality,
				_shadow_distance, _volumetric_fog)
		gfx.call("set_dynamic_scale", _dynamic_resolution, float(_fps_cap))


func _apply_display() -> void:
	Engine.max_fps = _fps_cap
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if _vsync_enabled else DisplayServer.VSYNC_DISABLED)
	var viewport: Viewport = get_viewport()
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_taa = false
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	match _anti_aliasing:
		1: viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		2: viewport.use_taa = true
		3: viewport.msaa_3d = Viewport.MSAA_2X
		4: viewport.msaa_3d = Viewport.MSAA_4X
	match _window_mode:
		0:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(RESOLUTIONS[_resolution_index])
		1:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		2:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	_apply_fullscreen_render_resolution()


func _apply_fullscreen_render_resolution() -> void:
	var gfx: Node = get_node_or_null(^"/root/GraphicsQuality")
	if gfx == null or not gfx.has_method(&"set_render_scale_limit"):
		return
	if _window_mode == 0:
		gfx.call(&"set_render_scale_limit", 1.0)
		return
	var screen: int = DisplayServer.window_get_current_screen()
	var native_size: Vector2i = DisplayServer.screen_get_size(screen)
	var target_size: Vector2i = RESOLUTIONS[_resolution_index]
	if native_size.x <= 0 or native_size.y <= 0:
		gfx.call(&"set_render_scale_limit", 1.0)
		return
	# Viewport 3D scaling is uniform. On a 16:10 Mac display, selecting 1920x1080 therefore renders
	# at no more than either requested dimension (typically 1728x1080), rather than stretching or
	# cropping the game to force a 16:9 buffer.
	var scale: float = minf(
		float(target_size.x) / float(native_size.x),
		float(target_size.y) / float(native_size.y))
	gfx.call(&"set_render_scale_limit", minf(scale, 1.0))


func _apply_bus_volume(bus_name: StringName, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	AudioServer.set_bus_mute(index, linear <= 0.0)
	if linear > 0.0:
		AudioServer.set_bus_volume_db(index, linear_to_db(linear))


func _load() -> void:
	var data: Dictionary = SETTINGS_SAVE.load_data(save_path)
	# First boot only: let the hardware pick the preset instead of handing every machine the
	# authored look with the safety net off (F-452). `load_data()` resolves a missing file to full
	# defaults, so it cannot tell a first launch from a player who deliberately chose HIGH — the
	# file's existence is what separates the two, and a saved choice always wins.
	if not FileAccess.file_exists(save_path):
		var tier: Dictionary = HARDWARE_TIER.detect()
		data[&"graphics_preset"] = int(tier["preset"])
		data[&"dynamic_resolution"] = bool(tier["dynamic_resolution"])
		MireLog.info(&"perf", "first boot: graphics preset '%s'%s — %s" % [
			HARDWARE_TIER.preset_name(int(tier["preset"])),
			" + dynamic resolution" if bool(tier["dynamic_resolution"]) else "",
			tier["reason"]])
	_graphics_preset = clampi(int(data.get(&"graphics_preset", DEFAULTS[&"graphics_preset"])), 0, 2)
	_window_mode = clampi(
		int(data.get(&"window_mode", DEFAULTS[&"window_mode"])), 0, WINDOW_MODES.size() - 1)
	_resolution_index = clampi(
		int(data.get(&"resolution_index", DEFAULTS[&"resolution_index"])), 0, RESOLUTIONS.size() - 1)
	_vsync_enabled = bool(data.get(&"vsync_enabled", DEFAULTS[&"vsync_enabled"]))
	var loaded_cap: int = int(data.get(&"fps_cap", DEFAULTS[&"fps_cap"]))
	_fps_cap = loaded_cap if FPS_CAPS.has(loaded_cap) else 0
	_ssao_override = clampi(int(data.get(&"ssao_override", DEFAULTS[&"ssao_override"])), -1, 1)
	_anti_aliasing = clampi(int(data.get(&"anti_aliasing", DEFAULTS[&"anti_aliasing"])),
		0, ANTI_ALIASING_MODES.size() - 1)
	_dynamic_resolution = bool(data.get(&"dynamic_resolution", DEFAULTS[&"dynamic_resolution"]))
	_brightness = clampf(float(data.get(&"brightness", DEFAULTS[&"brightness"])), 0.5, 1.5)
	_master_volume = clampf(float(data.get(&"master_volume", DEFAULTS[&"master_volume"])), 0.0, 1.0)
	_music_volume = clampf(float(data.get(&"music_volume", DEFAULTS[&"music_volume"])), 0.0, 1.0)
	_sfx_volume = clampf(float(data.get(&"sfx_volume", DEFAULTS[&"sfx_volume"])), 0.0, 1.0)
	_look_sensitivity = clampf(
		float(data.get(&"look_sensitivity", DEFAULTS[&"look_sensitivity"])),
		MIN_SENSITIVITY, MAX_SENSITIVITY)
	_gamepad_look_sensitivity = clampf(
		float(data.get(&"gamepad_look_sensitivity", DEFAULTS[&"gamepad_look_sensitivity"])),
		MIN_GAMEPAD_SENSITIVITY, MAX_GAMEPAD_SENSITIVITY)
	_invert_y = bool(data.get(&"invert_y", DEFAULTS[&"invert_y"]))
	_fov_degrees = clampf(float(data.get(&"fov_degrees", DEFAULTS[&"fov_degrees"])), MIN_FOV, MAX_FOV)
	_reduce_camera_motion = bool(
		data.get(&"reduce_camera_motion", DEFAULTS[&"reduce_camera_motion"]))
	_load_advanced(data)
	_guidance_mode = clampi(int(data.get(&"guidance_mode", DEFAULTS[&"guidance_mode"])), 0, 2)
	_guide_tips_seen.clear()
	for raw: Variant in data.get(&"guide_tips_seen", []):
		_guide_tips_seen[StringName(raw)] = true

	_keybinds.clear()
	var raw_keybinds: Dictionary = data.get(&"keybinds", {}) as Dictionary
	for action_name: String in raw_keybinds.keys():
		if not REBINDABLE_ACTIONS.has(action_name):
			continue
		var keycode: int = int(raw_keybinds[action_name])
		_apply_keybind(StringName(action_name), keycode)
		_keybinds[StringName(action_name)] = keycode

	_joypad_binds.clear()
	var raw_joypad_binds: Dictionary = data.get(&"joypad_binds", {}) as Dictionary
	for action_name: String in raw_joypad_binds.keys():
		if not JOYPAD_REBINDABLE_ACTIONS.has(action_name):
			continue
		var button_index: int = int(raw_joypad_binds[action_name])
		_apply_keybind_joypad(StringName(action_name), button_index)
		_joypad_binds[StringName(action_name)] = button_index

	_apply_values()


## Pushes the non-InputMap values at the engine seams that own them. Shared by `_load()` and
## `apply_state()` (F-386) so a whole-state change cannot forget one of the three audio buses the
## way a hand-written second copy would.
func _apply_values() -> void:
	_apply_graphics()
	_apply_display()
	_apply_bus_volume(&"Master", _master_volume)
	_apply_bus_volume(MUSIC_BUS, _music_volume)
	_apply_bus_volume(SFX_BUS, _sfx_volume)
	_apply_ui_scale()
	_apply_deadzones()


func _apply_ui_scale() -> void:
	var window: Window = get_tree().root
	if window != null:
		window.content_scale_factor = _ui_scale


func _apply_deadzones() -> void:
	for action: StringName in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
		if InputMap.has_action(action):
			InputMap.action_set_deadzone(action, _left_stick_deadzone)
	for action: StringName in [&"look_up", &"look_down", &"look_left", &"look_right"]:
		if InputMap.has_action(action):
			InputMap.action_set_deadzone(action, _right_stick_deadzone)


func _load_advanced(data: Dictionary) -> void:
	_ui_scale = clampf(float(data.get(&"ui_scale", DEFAULTS[&"ui_scale"])), 1.0, 1.5)
	_camera_shake_intensity = clampf(float(data.get(&"camera_shake_intensity", DEFAULTS[&"camera_shake_intensity"])), 0.0, 1.0)
	_foliage_quality = clampi(int(data.get(&"foliage_quality", DEFAULTS[&"foliage_quality"])), -1, 2)
	_shadow_quality = clampi(int(data.get(&"shadow_quality", DEFAULTS[&"shadow_quality"])), -1, 2)
	_shadow_distance = clampi(int(data.get(&"shadow_distance", DEFAULTS[&"shadow_distance"])), -1, 2)
	_volumetric_fog = clampi(int(data.get(&"volumetric_fog", DEFAULTS[&"volumetric_fog"])), -1, 1)
	_left_stick_deadzone = clampf(float(data.get(&"left_stick_deadzone", DEFAULTS[&"left_stick_deadzone"])), 0.0, 0.5)
	_right_stick_deadzone = clampf(float(data.get(&"right_stick_deadzone", DEFAULTS[&"right_stick_deadzone"])), 0.0, 0.5)
	_controller_vibration = clampf(float(data.get(&"controller_vibration", DEFAULTS[&"controller_vibration"])), 0.0, 1.0)
	_crosshair_size = clampf(float(data.get(&"crosshair_size", DEFAULTS[&"crosshair_size"])), 0.5, 2.0)
	_crosshair_opacity = clampf(float(data.get(&"crosshair_opacity", DEFAULTS[&"crosshair_opacity"])), 0.1, 1.0)
	_crosshair_colour = Color.from_string(String(data.get(&"crosshair_colour", DEFAULTS[&"crosshair_colour"])), Color.WHITE).to_html(false)
	_crosshair_high_contrast = bool(data.get(&"crosshair_high_contrast", DEFAULTS[&"crosshair_high_contrast"]))
	_streamer_mode = bool(data.get(&"streamer_mode", DEFAULTS[&"streamer_mode"]))


func _save() -> void:
	# F-386: a settings screen is previewing. Remember that there is something to write and let the
	# screen's Save or Cancel decide — the value itself has already been applied by the caller, so
	# the preview the player is looking at is unaffected.
	if _persistence_holds > 0:
		_persistence_pending = true
		return
	if not _persistence_enabled():
		return
	var raw_keybinds: Dictionary = {}
	for action: StringName in _keybinds.keys():
		raw_keybinds[String(action)] = _keybinds[action]
	var raw_joypad_binds: Dictionary = {}
	for action: StringName in _joypad_binds.keys():
		raw_joypad_binds[String(action)] = _joypad_binds[action]
	SETTINGS_SAVE.save_data({
		"graphics_preset": _graphics_preset,
		"window_mode": _window_mode,
		"resolution_index": _resolution_index,
		"vsync_enabled": _vsync_enabled,
		"fps_cap": _fps_cap,
		"ssao_override": _ssao_override,
		"anti_aliasing": _anti_aliasing,
		"dynamic_resolution": _dynamic_resolution,
		"brightness": _brightness,
		"master_volume": _master_volume,
		"music_volume": _music_volume,
		"sfx_volume": _sfx_volume,
		"look_sensitivity": _look_sensitivity,
		"gamepad_look_sensitivity": _gamepad_look_sensitivity,
		"invert_y": _invert_y,
		"fov_degrees": _fov_degrees,
		"reduce_camera_motion": _reduce_camera_motion,
		"ui_scale": _ui_scale,
		"camera_shake_intensity": _camera_shake_intensity,
		"foliage_quality": _foliage_quality,
		"shadow_quality": _shadow_quality,
		"shadow_distance": _shadow_distance,
		"volumetric_fog": _volumetric_fog,
		"left_stick_deadzone": _left_stick_deadzone,
		"right_stick_deadzone": _right_stick_deadzone,
		"controller_vibration": _controller_vibration,
		"crosshair_size": _crosshair_size,
		"crosshair_opacity": _crosshair_opacity,
		"crosshair_colour": _crosshair_colour,
		"crosshair_high_contrast": _crosshair_high_contrast,
		"streamer_mode": _streamer_mode,
		"guidance_mode": _guidance_mode,
		"guide_tips_seen": _seen_tip_list(),
		"keybinds": raw_keybinds,
		"joypad_binds": raw_joypad_binds,
	}, save_path)


## Same D-107 guard `SalvageService`/`UnlockService` already use: a `--script` harness never loads
## `project.godot`'s `run/main_scene` (`current_scene` stays null for the whole run), which the real
## game always does, so that is the one signal available for free. `tools/settings_check.gd` opts
## back in by overriding `save_path` away from the real one.
func _persistence_enabled() -> bool:
	return save_path != SETTINGS_SAVE.SAVE_PATH or get_tree().current_scene != null
