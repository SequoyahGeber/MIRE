class_name PlayerCamera
extends Node3D

## First-person camera pivot. Owns pitch; yaws the body it hangs off.
##
## Network authority: CLIENT-LOCAL, always (ARCHITECTURE.md §2.2, last row). Camera state is never
## networked. Remote players' view direction comes from their replicated body yaw, not from here —
## which is why yaw lives on the body and only pitch lives on this node.
##
## Expects to be a child of the player body, with a Camera3D child of its own.

@export_group("Look")
## Degrees of rotation per pixel of mouse movement.
@export_range(0.01, 1.0, 0.01) var look_sensitivity: float = 0.12
## Invert vertical look.
@export var invert_y: bool = false
## How far up/down the view can pitch, in degrees. Just under 90 avoids gimbal weirdness at the poles.
@export_range(30.0, 89.9, 0.1) var pitch_limit_degrees: float = 89.0

@export_group("Sprint FOV")
## Extra degrees of field of view while sprinting. Set to 0 to disable the effect entirely.
@export_range(0.0, 30.0, 0.5) var sprint_fov_boost: float = 6.0
## How quickly the FOV eases between its resting and sprinting values.
@export_range(1.0, 30.0, 0.5) var fov_lerp_speed: float = 8.0

@onready var camera: Camera3D = $Camera3D

var _body: Node3D
var _base_fov: float = 75.0
var _sprinting: bool = false


func _ready() -> void:
	_body = get_parent_node_3d()
	_base_fov = camera.fov
	set_process(false)


## Called by the owning PlayerController with raw mouse motion. Yaw goes to the body so that movement
## direction and view direction can never drift apart.
func apply_look(relative: Vector2) -> void:
	var sensitivity: float = deg_to_rad(look_sensitivity)

	_body.rotate_y(-relative.x * sensitivity)

	var pitch_delta: float = -relative.y * sensitivity
	if invert_y:
		pitch_delta = -pitch_delta

	var limit: float = deg_to_rad(pitch_limit_degrees)
	rotation.x = clampf(rotation.x + pitch_delta, -limit, limit)


## Only the locally-controlled player renders through its camera.
func set_active(active: bool) -> void:
	camera.current = active
	set_process(active and sprint_fov_boost > 0.0)


func set_sprinting(sprinting: bool) -> void:
	_sprinting = sprinting


func _process(delta: float) -> void:
	var target_fov: float = _base_fov + (sprint_fov_boost if _sprinting else 0.0)
	camera.fov = lerpf(camera.fov, target_fov, minf(fov_lerp_speed * delta, 1.0))
