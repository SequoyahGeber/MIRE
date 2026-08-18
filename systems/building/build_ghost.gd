extends Node3D

## BuildGhost — the translucent preview of a piece before it is placed. Attached to the player by
## entities/player/player_controller.gd (F-086 — 3.6 shipped this with no production caller; only
## tools/build_check.gd ever instantiated one before that fix).
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
##
## `aim_destroy_target()` is a second, independent ray for teardown targeting — see its own comment.
## It never decides anything either; it only names the piece for the caller's own
## `BuildService.request_destroy()` call.

const VALIDATOR := preload("res://systems/building/placement_validator.gd")

## Matches BuildService.QUERY_MASK — the "solid" layer (props, harvestables, placed pieces, players,
## enemies). The ghost has to ask `PlacementValidator.evaluate()` the same question of the same
## layers `BuildService` does, or its prediction is answering a different one.
const QUERY_MASK: int = 1

## Matches BuildService.PIECE_GROUP — duplicated as a literal rather than resolved through the
## autoload, same reasoning autoload/harvest_world.gd's own HARVESTABLE_GROUP duplicates
## systems/harvesting/harvestable.gd's: the string costs nothing to keep in sync and this file has no
## other reason to reach BuildService at all.
const PIECE_GROUP: StringName = &"buildable_piece"

const VALID_COLOR := Color(0.35, 0.95, 0.45, 0.42)
const INVALID_COLOR := Color(0.95, 0.3, 0.28, 0.42)

## How far ahead of the camera to look for a surface to place on.
@export_range(1.0, 32.0, 0.5) var aim_distance_m: float = 6.0

## F-105: update_aim() is a physics-tick call, and VALIDATOR.evaluate() is 5 support raycasts plus a
## shape cast with fresh query/shape allocations (placement_validator.gd) — real cost for a ghost that
## is usually just sitting still in front of an unchanged surface. Re-running it only happens when the
## snapped transform actually moved, or this long since the last time it ran, whichever comes first —
## the timer is what still catches a world change (someone else builds where you're aiming) under a
## ghost that hasn't moved at all.
const REEVALUATE_INTERVAL_S: float = 0.2

var _def: Resource
var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _yaw: float = 0.0
var _last_reason: int = VALIDATOR.Reason.UNKNOWN_PIECE
var _placement: Transform3D = Transform3D()
var _evaluated_placement: Transform3D = Transform3D()
var _evaluated_builder_position: Vector3 = Vector3.ZERO
var _has_evaluated: bool = false
var _time_since_evaluate: float = 0.0
## How many times VALIDATOR.evaluate() has actually run — exists so a check can prove the skip
## above is real rather than trusting the comment. Not read by anything gameplay-facing.
var _evaluate_count: int = 0


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
	# A cached evaluate() belongs to the OLD piece's def (size, mass, rules) as much as to a
	# transform — a same-spot swap between two pieces must not read the previous piece's verdict.
	_has_evaluated = false
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
## `builder_position` is the player, for the range rule. `delta` is the caller's own frame delta —
## optional, and only used to pace the F-105 re-evaluate timer below; a caller that omits it (every
## `tools/build_check.gd` case) just never gets the timer's own proactive refresh, which those cases
## never depend on since each one already moves the aim or the piece between assertions. Returns the
## current Reason so a caller can show `PlacementValidator.reason_text()` next to the crosshair.
func update_aim(
		from: Vector3, direction: Vector3, builder_position: Vector3, delta: float = 0.0) -> int:
	if _def == null:
		_last_reason = VALIDATOR.Reason.UNKNOWN_PIECE
		return _last_reason

	var space: PhysicsDirectSpaceState3D = _space_state()
	var target: Vector3 = from + direction.normalized() * aim_distance_m
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(from, target)
		# QUERY_MASK alone would never find bare ground now that terrain has its own layer (F-075) —
		# this ray is "what is the player pointing at", ground or piece, so it has to see both.
		query.collision_mask = QUERY_MASK | VALIDATOR.TERRAIN_LAYER
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			target = hit["position"]

	_placement = VALIDATOR.snap_transform(_def, target, _yaw)
	global_transform = _placement

	# F-105: evaluate() is the expensive part (5 support raycasts + a shape cast, fresh query/shape
	# allocations each call — placement_validator.gd:164). A ghost sitting still in front of an
	# unchanged surface asks the same question every physics tick and gets the same answer; skip it
	# unless the snapped transform or the builder's range-check position actually moved, or
	# REEVALUATE_INTERVAL_S has passed since the last real answer — the timer is what still notices a
	# world change (someone else built where you're aiming) under a ghost that never moves at all.
	_time_since_evaluate += delta
	var stale: bool = not _has_evaluated \
		or not _placement.is_equal_approx(_evaluated_placement) \
		or not builder_position.is_equal_approx(_evaluated_builder_position) \
		or _time_since_evaluate >= REEVALUATE_INTERVAL_S
	if stale:
		_last_reason = VALIDATOR.evaluate(
			space, _def, _placement, builder_position, QUERY_MASK)
		_evaluate_count += 1
		_material.albedo_color = VALID_COLOR if VALIDATOR.is_placeable(_last_reason) else INVALID_COLOR
		_evaluated_placement = _placement
		_evaluated_builder_position = builder_position
		_has_evaluated = true
		_time_since_evaluate = 0.0
	return _last_reason


## F-105 instrumentation — see `_evaluate_count`'s own comment.
func evaluate_count() -> int:
	return _evaluate_count


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


## A SECOND ray, independent of update_aim()'s placement preview — a player must be able to target an
## EXISTING piece for teardown even while a different piece (or none) is selected to place. Returns
## the piece's node name, which is what BuildService._placed keys by and what request_destroy() takes,
## or &"" if nothing in PIECE_GROUP is within aim_distance_m. Walks up from the collider rather than
## trusting it directly, the same defensive shape harvest_world.gd's own collider walk uses — every
## generated piece today IS its own collider, but a future authored scene (task 3.7) may wrap one in
## a child CollisionShape holder.
func aim_destroy_target(from: Vector3, direction: Vector3) -> StringName:
	var space: PhysicsDirectSpaceState3D = _space_state()
	if space == null:
		return &""
	var query := PhysicsRayQueryParameters3D.create(
		from, from + direction.normalized() * aim_distance_m)
	query.collision_mask = QUERY_MASK
	var hit: Dictionary = space.intersect_ray(query)
	var cursor: Node = hit.get("collider") as Node
	while cursor != null:
		if cursor.is_in_group(PIECE_GROUP):
			return StringName(cursor.name)
		cursor = cursor.get_parent()
	return &""
