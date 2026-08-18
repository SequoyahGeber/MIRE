extends Node3D

## BuildGhost — the translucent preview of a piece before it is placed. Attach one to the player.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, last row — "VFX, audio, camera, UI"): **NONE, and
## that is the entire contract.** Nothing here decides anything. It aims, snaps, colours itself, and
## asks `BuildService`. Its green is a prediction of the host's answer, never a substitute for it,
## and `confirm()` deliberately sends the request even when the ghost is red — the host is the one
## that says no, and it says no with a reason this ghost may not have been able to compute.
##
## It computes that prediction by calling `PlacementValidator`, the SAME function the host runs.
## Writing the rules a second time in here is the one thing that must not happen: two
## implementations of "can this go here" drift, and the symptom is a player lining up a wall that
## reads green and gets refused with no explanation — the exact bug that makes a building system
## feel broken rather than strict.

const VALIDATOR := preload("res://systems/building/placement_validator.gd")

## Matches BuildService.QUERY_MASK. The ghost has to ask the same question of the same layers, or its
## prediction is answering a different one. See F-075 for why this is a single shared layer.
const QUERY_MASK: int = 1

const VALID_COLOR := Color(0.35, 0.95, 0.45, 0.42)
const INVALID_COLOR := Color(0.95, 0.3, 0.28, 0.42)

## How far ahead of the camera to look for a surface to place on.
@export_range(1.0, 32.0, 0.5) var aim_distance_m: float = 6.0

var _def: Resource
var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _yaw: float = 0.0
var _last_reason: int = VALIDATOR.Reason.UNKNOWN_PIECE
var _placement: Transform3D = Transform3D()


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.albedo_color = INVALID_COLOR
	# A ghost that z-fights the surface it is hovering over reads as a glitch, and it must never
	# occlude the world it is previewing against.
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_material.disable_receive_shadows = true

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "GhostMesh"
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.material_override = _material
	add_child(_mesh_instance)
	visible = false


## Selects the piece being previewed, or clears it with `&""`. Resolving through the Registry rather
## than taking a def keeps the caller (a hotbar, a build menu) working in ids, which is what it will
## have and what goes over the wire anyway.
func set_piece(piece_id: StringName) -> bool:
	if piece_id == &"":
		_def = null
		visible = false
		return false
	var registry: Node = get_node_or_null(^"/root/Registry")
	_def = null if registry == null else registry.call(&"get_buildable", piece_id)
	if _def == null:
		visible = false
		return false
	var box := BoxMesh.new()
	box.size = _def.get(&"size")
	_mesh_instance.mesh = box
	# The placement origin is the piece's FLOOR centre; the box is drawn from there upward, matching
	# how BuildService builds the real collider.
	_mesh_instance.position = Vector3(0.0, (_def.get(&"size") as Vector3).y * 0.5, 0.0)
	visible = true
	return true


func current_piece_id() -> StringName:
	return &"" if _def == null else StringName(String(_def.get(&"id")))


## Turns the piece by one authored step. Rotation is snapped in `PlacementValidator.snap_transform`,
## so accumulating a raw angle here is fine and keeps the input simple.
func rotate_step(steps: int = 1) -> void:
	if _def == null:
		return
	var step_degrees: float = float(_def.get(&"rotation_step_degrees"))
	_yaw += deg_to_rad(step_degrees if step_degrees > 0.0 else 15.0) * float(steps)


## Call every frame from whatever owns the camera. `from`/`direction` are the aim ray;
## `builder_position` is the player, for the range rule. Returns the current Reason so a caller can
## show `PlacementValidator.reason_text()` next to the crosshair.
func update_aim(from: Vector3, direction: Vector3, builder_position: Vector3) -> int:
	if _def == null:
		_last_reason = VALIDATOR.Reason.UNKNOWN_PIECE
		return _last_reason

	var space: PhysicsDirectSpaceState3D = _space_state()
	var target: Vector3 = from + direction.normalized() * aim_distance_m
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(from, target)
		query.collision_mask = QUERY_MASK
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			target = hit["position"]

	_placement = VALIDATOR.snap_transform(_def, target, _yaw)
	global_transform = _placement
	_last_reason = VALIDATOR.evaluate(
		space, _def, _placement, builder_position, QUERY_MASK)
	_material.albedo_color = VALID_COLOR if VALIDATOR.is_placeable(_last_reason) else INVALID_COLOR
	return _last_reason


func placement() -> Transform3D:
	return _placement


func last_reason() -> int:
	return _last_reason


func last_reason_text() -> String:
	return VALIDATOR.reason_text(_last_reason)


func is_valid() -> bool:
	return VALIDATOR.is_placeable(_last_reason)


## Sends the request. Deliberately does NOT gate on `is_valid()`: the ghost's verdict is a
## prediction, and a client that refuses to ask is a client that has quietly become the authority.
## The host answers on `BuildService.build_confirmed`, and a rejection there is the real answer —
## including for the one rule this ghost cannot check at all, which is whether you can afford it.
func confirm() -> int:
	if _def == null:
		return -1
	var service: Node = get_node_or_null(^"/root/BuildService")
	if service == null:
		return -1
	return int(service.call(&"request_place", current_piece_id(), _placement))


func _space_state() -> PhysicsDirectSpaceState3D:
	if not is_inside_tree():
		return null
	var world: World3D = get_world_3d()
	return null if world == null else world.direct_space_state
