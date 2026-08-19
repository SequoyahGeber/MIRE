class_name PlayerCamera
extends Node3D

## First-person camera pivot. Owns pitch; yaws the body it hangs off.
##
## Network authority: CLIENT-LOCAL, always (ARCHITECTURE.md §2.2, last row). Camera state is never
## networked. Remote players' view direction comes from their replicated body yaw, not from here —
## which is why yaw lives on the body and only pitch lives on this node.
##
## Expects to be a child of the player body, with a Camera3D child of its own.
##
## `look_sensitivity`, `gamepad_look_sensitivity`, `invert_y`, resting FOV and whether shake/sprint-FOV
## run at all are overridden from `SettingsService` (task 7.5/7.6) if that autoload is present — see
## `_apply_settings()` — so the `@export` values below are only the fallback for a scene run without
## it (e.g. a check).

@export_group("Look")
## Degrees of rotation per pixel of mouse movement.
@export_range(0.01, 1.0, 0.01) var look_sensitivity: float = 0.12
## Degrees of rotation PER SECOND at full analog-stick deflection (task 7.6). A rate, not a
## per-pixel delta like `look_sensitivity` — a gamepad stick reports a HELD magnitude every frame,
## not a discrete motion event, so `apply_look_gamepad()` has to multiply by `delta` itself.
@export_range(30.0, 720.0, 5.0) var gamepad_look_sensitivity: float = 180.0
## Invert vertical look.
@export var invert_y: bool = false
## How far up/down the view can pitch, in degrees. Just under 90 avoids gimbal weirdness at the poles.
@export_range(30.0, 89.9, 0.1) var pitch_limit_degrees: float = 89.0

@export_group("Sprint FOV")
## Extra degrees of field of view while sprinting. Set to 0 to disable the effect entirely.
@export_range(0.0, 30.0, 0.5) var sprint_fov_boost: float = 6.0
## How quickly the FOV eases between its resting and sprinting values.
@export_range(1.0, 30.0, 0.5) var fov_lerp_speed: float = 8.0

@export_group("Impact shake")
## Shakes per second. Low values read as a heavy thud, high values as a rattle.
@export_range(4.0, 60.0, 0.5) var shake_frequency: float = 26.0
## Peak camera roll during a shake, degrees per unit of magnitude.
@export_range(0.0, 30.0, 0.1) var shake_roll_degrees: float = 7.0

@onready var camera: Camera3D = $Camera3D

var _body: Node3D
var _base_fov: float = 75.0
var _sprinting: bool = false
## Task 7.5's "Reduce Camera Motion" accessibility toggle, read from SettingsService. Suppresses
## both the sprint FOV pulse and impact shake, the two things this class moves the camera on its
## own without the player's input — a motion-sensitive player can turn off exactly those and keep
## everything else.
var _reduce_motion: bool = false

## Impact shake state. Client-local presentation, never networked (see the class docs above); decay
## is integrated from elapsed time rather than lerped per frame, so it is framerate-independent.
var _camera_rest_position: Vector3 = Vector3.ZERO
var _shake_magnitude: float = 0.0
var _shake_duration: float = 0.0
var _shake_elapsed: float = 0.0


func _ready() -> void:
	_body = get_parent_node_3d()
	_base_fov = camera.fov
	_camera_rest_position = camera.position
	set_process(false)
	_apply_settings()
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings != null and settings.has_signal("settings_changed"):
		settings.connect("settings_changed", _apply_settings)


## Pulls look sensitivity, invert-Y, resting FOV and the "reduce camera motion" toggle from
## SettingsService (task 7.5) if present, overriding this node's own @export defaults. Called once
## at ready and again on every `settings_changed` — the settings menu can be opened mid-run, and
## this is a first-person camera, not a value that should need a scene reload to take effect.
func _apply_settings() -> void:
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings == null:
		return
	if settings.has_method("look_sensitivity"):
		look_sensitivity = float(settings.call("look_sensitivity"))
	if settings.has_method("gamepad_look_sensitivity"):
		gamepad_look_sensitivity = float(settings.call("gamepad_look_sensitivity"))
	if settings.has_method("invert_y"):
		invert_y = bool(settings.call("invert_y"))
	if settings.has_method("fov_degrees"):
		_base_fov = float(settings.call("fov_degrees"))
		if not _sprinting:
			camera.fov = _base_fov
	if settings.has_method("reduce_camera_motion"):
		_reduce_motion = bool(settings.call("reduce_camera_motion"))


## Called by the owning PlayerController with raw mouse motion. Yaw goes to the body so that movement
## direction and view direction can never drift apart.
func apply_look(relative: Vector2) -> void:
	var sensitivity: float = deg_to_rad(look_sensitivity)
	var pitch_delta: float = -relative.y * sensitivity
	if invert_y:
		pitch_delta = -pitch_delta
	_rotate_view(-relative.x * sensitivity, pitch_delta)


## The gamepad half of look (task 7.6) — `PlayerController._physics_process()` calls this every tick
## with the right stick's `Input.get_vector()` already resolved through `input_allowed` (F-105's
## "resolve once, thread it through" pattern, not re-derived here). Unlike `apply_look()`, this is a
## HELD magnitude sampled every tick rather than a one-shot motion event, so it has to scale by
## `delta` itself — `gamepad_look_sensitivity` is degrees/second, not degrees/pixel. `input_allowed`
## is the gamepad equivalent of `apply_look()`'s own `Input.mouse_mode == MOUSE_MODE_CAPTURED` gate:
## the thing that stops the view spinning while a blocking UI (inventory, settings) is open.
func apply_look_gamepad(delta: float, input_allowed: bool) -> void:
	if not input_allowed:
		return
	var stick: Vector2 = Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	if stick == Vector2.ZERO:
		return
	var rate: float = deg_to_rad(gamepad_look_sensitivity) * delta
	var pitch_delta: float = -stick.y * rate
	if invert_y:
		pitch_delta = -pitch_delta
	_rotate_view(-stick.x * rate, pitch_delta)


func _rotate_view(yaw_delta: float, pitch_delta: float) -> void:
	_body.rotate_y(yaw_delta)
	var limit: float = deg_to_rad(pitch_limit_degrees)
	rotation.x = clampf(rotation.x + pitch_delta, -limit, limit)


## Only the locally-controlled player renders through its camera. Processing now also drives impact
## shake, so it is no longer conditional on the sprint-FOV effect being enabled.
func set_active(active: bool) -> void:
	camera.current = active
	set_process(active)


func set_sprinting(sprinting: bool) -> void:
	_sprinting = sprinting


## Called by CombatService on a host-confirmed connect. Client-local feel only — a shake decides
## nothing and is never sent anywhere. Overlapping impacts take the stronger shake and restart it,
## rather than summing into a blur.
func add_shake(magnitude: float, duration: float) -> void:
	if _reduce_motion or magnitude <= 0.0 or duration <= 0.0:
		return
	if _shake_elapsed < _shake_duration and magnitude < _shake_magnitude:
		magnitude = _shake_magnitude
	_shake_magnitude = magnitude
	_shake_duration = duration
	_shake_elapsed = 0.0


func shake_remaining() -> float:
	return maxf(_shake_duration - _shake_elapsed, 0.0)


func _process(delta: float) -> void:
	if sprint_fov_boost > 0.0 and not _reduce_motion:
		var target_fov: float = _base_fov + (sprint_fov_boost if _sprinting else 0.0)
		# Framerate-independent exponential smoothing (F-002, ARCHITECTURE.md §5a rule 6). The naive
		# `lerpf(a, b, speed * delta)` form converges at different rates at 60 and 240 fps, so the
		# same `fov_lerp_speed` produced a snappier punch on faster hardware. This form reaches the
		# same fraction of the remaining distance per unit of *time*, whatever the frame rate. Kept
		# here rather than left as a documented cosmetic exception because it is the shape most
		# likely to be copy-pasted into something that does affect gameplay.
		camera.fov = lerpf(camera.fov, target_fov, 1.0 - exp(-fov_lerp_speed * delta))
	if not _reduce_motion:
		_apply_shake(delta)


func _apply_shake(delta: float) -> void:
	if _shake_duration <= 0.0:
		return
	_shake_elapsed += delta
	if _shake_elapsed >= _shake_duration:
		_shake_duration = 0.0
		_shake_magnitude = 0.0
		camera.position = _camera_rest_position
		camera.rotation.z = 0.0
		return

	# Amplitude falls off with the square of remaining time: a sharp initial punch, no long wobble.
	var remaining: float = 1.0 - _shake_elapsed / _shake_duration
	var amplitude: float = _shake_magnitude * remaining * remaining
	var phase: float = _shake_elapsed * shake_frequency * TAU
	# Two incommensurate frequencies read as noise without needing a random source, so the same
	# elapsed time always produces the same offset.
	camera.position = _camera_rest_position + Vector3(
		sin(phase) * amplitude,
		sin(phase * 1.73 + 1.1) * amplitude * 0.6,
		0.0
	)
	camera.rotation.z = deg_to_rad(shake_roll_degrees) * amplitude * sin(phase * 0.8)
