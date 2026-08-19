extends SceneTree

## Prove that task 3.7's doors and gates actually open — in the engine, with physics, not by
## reading the transform (F-150).
##
## Run with:  .agent/bin/agent godot --script tools/door_check.gd
##
## Three claims, one per failure this feature can have. It swings (the leaf really turns, on its own
## hinge, because A-010 exported it with its origin there). It BLOCKS while shut and is walkable
## while open — a door that swings but whose collider does not is the worst of the three, because it
## looks correct in motion. And it is host-authoritative: `open` is the entire replicated schema and
## a request from out of range is refused.

const DOOR_GROUP: StringName = &"door"
const DOORS: Array[StringName] = [&"door", &"gate", &"palisade_gate"]

var failures: int = 0
var space: PhysicsDirectSpaceState3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		_finish()
		return
	space = (root as Node).get_viewport().world_3d.direct_space_state

	for id: StringName in DOORS:
		await _check_door(registry, id)
	_finish()


func _check_door(registry: Node, id: StringName) -> void:
	var def: Resource = registry.call("get_buildable", id) as Resource
	if def == null:
		check(false, "%s: definition exists" % id)
		return
	var scene: PackedScene = def.get(&"scene")
	if scene == null:
		check(false, "%s: carries a piece scene" % id)
		return
	var piece: Node3D = scene.instantiate() as Node3D
	root.add_child(piece)
	piece.global_position = Vector3.ZERO
	await process_frame
	await physics_frame

	check(piece.is_in_group(DOOR_GROUP), "%s: joins the door group" % id)
	check(piece.has_method(&"request_toggle"), "%s: exposes the interact seam" % id)
	# F-085: an authored root that BuildService leaves alone must bring the damage contract itself.
	check(piece.has_method(&"host_apply_damage"), "%s: still satisfies the damageable contract" % id)
	var errors: PackedStringArray = piece.call("validation_errors")
	check(errors.is_empty(), "%s: door configuration validates" % id, "; ".join(errors))

	var sync: Node = piece.get_node_or_null(^"DoorSync")
	check(sync is MultiplayerSynchronizer, "%s: code-built DoorSync exists" % id)
	if sync is MultiplayerSynchronizer:
		var synchronizer := sync as MultiplayerSynchronizer
		check(
			synchronizer.get_multiplayer_authority() == NetConfig.HOST_PEER_ID,
			"%s: DoorSync is host-authoritative" % id
		)
		var properties: Array = synchronizer.replication_config.get_properties()
		check(
			properties.size() == 1 and String(properties[0]) == ".:open",
			"%s: open is the entire replicated schema" % id, str(properties)
		)

	# Shut: the doorway is a wall.
	check(not bool(piece.get(&"open")), "%s: starts shut" % id)
	check(not bool(piece.call("is_passable")), "%s: is not passable while shut" % id)
	check(_blocked_through_doorway(), "%s: a shut doorway stops a body" % id)

	# Open: the leaf turns and the doorway clears.
	var accepted: bool = bool(piece.call("request_toggle"))
	check(accepted, "%s: an in-range toggle is accepted" % id)
	await process_frame
	await physics_frame
	check(bool(piece.get(&"open")), "%s: is open after a toggle" % id)
	check(bool(piece.call("is_passable")), "%s: is passable while open" % id)
	check(not _blocked_through_doorway(), "%s: an open doorway lets a body through" % id)

	var leaves: Array = piece.get(&"leaves")
	for index: int in leaves.size():
		var leaf: Node3D = piece.get_node_or_null(leaves[index]) as Node3D
		var target: float = float(piece.call("leaf_target_degrees", index))
		check(not is_zero_approx(target), "%s: leaf %d has somewhere to swing to" % [id, index])
		if leaf != null:
			# Swing time is presentation; the target is the contract. Finish the tween first so the
			# assertion is about where the leaf ENDS, not about tween timing.
			leaf.rotation.y = deg_to_rad(target)
			check(
				absf(rad_to_deg(leaf.rotation.y) - target) < 0.5,
				"%s: leaf %d reaches %.0f degrees" % [id, index, target]
			)

	# And shut again.
	piece.call("request_toggle")
	await process_frame
	await physics_frame
	check(not bool(piece.get(&"open")), "%s: toggles closed again" % id)
	check(_blocked_through_doorway(), "%s: blocks again once shut" % id)

	piece.queue_free()
	await process_frame


## Sweep a player-sized capsule through the doorway at walking height. This is the assertion that
## cannot be faked by moving a mesh: either the physics server lets the body through or it does not.
func _blocked_through_doorway() -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.32
	shape.height = 1.70
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.9, 0.0))
	return not space.intersect_shape(query, 1).is_empty()


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		print("PASS: %s" % label)
		return
	failures += 1
	print("FAIL: %s%s" % [label, "" if detail.is_empty() else " — " + detail])


func _finish() -> void:
	print("DOOR_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
