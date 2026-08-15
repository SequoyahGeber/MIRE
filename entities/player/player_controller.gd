class_name PlayerController
extends CharacterBody3D

## First-person ground movement: walk, sprint, jump, coyote time, jump buffering.
##
## Network authority: OWN PLAYER MOVEMENT — CLIENT (ARCHITECTURE.md §2.2, row 1).
## The peer that owns this node simulates it locally and its transform is replicated outward by a
## MultiplayerSynchronizer. Remote copies of this node run no input and no physics — they are moved
## purely by replication (interpolation lands in task 1.6). The host sanity-checks speed later (1.5);
## nothing here is trusted by anyone but the owner.
##
## Everything below is @export'd on purpose. Task 0.5 is "tune until movement feels good", and that
## tuning should happen in the inspector with the game running, not in this file.

## Emitted the frame a jump leaves the ground. Client-local — audio/VFX only, never networked.
signal jumped
## Emitted on landing, with the downward speed at the moment of impact (positive, m/s).
signal landed(impact_speed: float)

@export_group("Speed")
## Base ground speed, metres per second.
@export_range(1.0, 15.0, 0.1) var walk_speed: float = 5.0
## Ground speed while the sprint action is held.
@export_range(1.0, 25.0, 0.1) var sprint_speed: float = 8.0

@export_group("Acceleration")
## How fast we reach target speed on the ground. Higher = snappier, more arcade.
@export_range(1.0, 200.0, 1.0) var ground_acceleration: float = 60.0
## How fast we stop on the ground with no input. Higher = less slide.
@export_range(1.0, 200.0, 1.0) var ground_friction: float = 50.0
## Steering authority in the air. Low values make jumps feel committed.
@export_range(0.0, 100.0, 1.0) var air_acceleration: float = 14.0

@export_group("Jump")
## Apex height of a standing jump, in metres. Converted to launch velocity via gravity.
@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.1
## Grace period after walking off a ledge during which a jump still counts. The single biggest
## "why does this feel bad" fix in first-person movement.
@export_range(0.0, 0.5, 0.01) var coyote_time: float = 0.12
## Grace period for a jump pressed just before landing; it fires on touchdown instead of being eaten.
@export_range(0.0, 0.5, 0.01) var jump_buffer_time: float = 0.12
## Releasing jump early cuts upward velocity by this factor, giving variable jump height.
@export_range(0.0, 1.0, 0.05) var jump_cut_multiplier: float = 0.45

@export_group("Gravity")
## Multiplies project gravity. >1 makes jumps feel heavier without changing apex height.
@export_range(0.1, 5.0, 0.05) var gravity_scale: float = 1.6
## Downward speed cap, metres per second.
@export_range(10.0, 200.0, 1.0) var terminal_velocity: float = 60.0

## Set false on remote copies of this player so they are driven by replication only.
var is_local_authority: bool = true

@onready var camera: PlayerCamera = $CameraPivot

var _gravity: float = 9.8
var _time_since_grounded: float = INF
var _time_since_jump_pressed: float = INF
var _was_on_floor: bool = true


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))

	# Offline this returns true (no peer -> unique id 1, default authority 1), so the controller
	# works standalone for M0. Task 1.5 assigns real authority at spawn time.
	is_local_authority = is_multiplayer_authority()

	camera.set_active(is_local_authority)
	set_physics_process(is_local_authority)
	set_process_unhandled_input(is_local_authority)

	if is_local_authority:
		_capture_mouse(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Look input is routed through the controller rather than read by the camera directly, so
		# that authority gating lives in exactly one place.
		camera.apply_look((event as InputEventMouseMotion).relative)
		return

	# Temporary mouse release. Replaced by the pause menu in M7 — until then it is how you get your
	# cursor back without killing the process.
	if event.is_action_pressed(&"ui_cancel"):
		_capture_mouse(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
	_tick_timers(delta)
	_apply_gravity(delta)
	_apply_horizontal_movement(delta)
	_try_jump()

	# move_and_slide() zeroes vertical velocity on contact, so read the fall speed before it runs.
	var fall_speed: float = maxf(-velocity.y, 0.0)

	move_and_slide()

	_detect_landing(fall_speed)


func _tick_timers(delta: float) -> void:
	_time_since_grounded = 0.0 if is_on_floor() else _time_since_grounded + delta

	if Input.is_action_just_pressed(&"jump"):
		_time_since_jump_pressed = 0.0
	else:
		_time_since_jump_pressed += delta


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		# A small downward bias keeps us glued to slopes and stairs instead of skipping off them.
		velocity.y = minf(velocity.y, -0.1)
		return

	velocity.y -= _gravity * gravity_scale * delta

	# Variable jump height: cut once on release, not every frame — repeated multiplication would
	# kill upward velocity almost instantly.
	if velocity.y > 0.0 and Input.is_action_just_released(&"jump"):
		velocity.y *= jump_cut_multiplier

	velocity.y = maxf(velocity.y, -terminal_velocity)


func _apply_horizontal_movement(delta: float) -> void:
	var input_2d: Vector2 = Input.get_vector(
		&"move_left", &"move_right", &"move_forward", &"move_back"
	)
	# Body yaw defines the movement basis; the camera only pitches (see player_camera.gd).
	var wish_dir: Vector3 = (transform.basis * Vector3(input_2d.x, 0.0, input_2d.y)).normalized()

	var sprinting: bool = Input.is_action_pressed(&"sprint") and wish_dir != Vector3.ZERO
	var target: Vector3 = wish_dir * (sprint_speed if sprinting else walk_speed)

	var rate: float
	if is_on_floor():
		rate = ground_acceleration if wish_dir != Vector3.ZERO else ground_friction
	else:
		rate = air_acceleration

	var horizontal: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	horizontal = horizontal.move_toward(target, rate * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z

	camera.set_sprinting(sprinting and is_on_floor())


func _try_jump() -> void:
	var buffered: bool = _time_since_jump_pressed <= jump_buffer_time
	var grounded_recently: bool = _time_since_grounded <= coyote_time
	if not (buffered and grounded_recently):
		return

	velocity.y = sqrt(2.0 * _gravity * gravity_scale * jump_height)

	# Consume both windows so one press can never produce two jumps.
	_time_since_jump_pressed = INF
	_time_since_grounded = INF

	jumped.emit()


func _detect_landing(fall_speed: float) -> void:
	var on_floor: bool = is_on_floor()
	if on_floor and not _was_on_floor:
		landed.emit(fall_speed)
	_was_on_floor = on_floor


func _capture_mouse(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
