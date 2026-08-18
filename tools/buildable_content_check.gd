extends SceneTree

## Verify task 3.7's buildable set in the running engine: every definition, the piece scene it
## points at, and the two things a placed piece is judged on — does it LOOK like the thing, and does
## it BEHAVE like the thing.
##
## Run with:  .agent/bin/agent godot --script tools/buildable_content_check.gd
##
## The interesting assertion is the third one. `BuildableDef.size` is deliberately data rather than
## a measurement of the scene, because the ghost, the placement validator and the host must all
## reason about one box without loading each other's copy. That is the right call and it is also
## exactly how art and footprint drift apart (F-137's shape): a def can claim 2.0 m while its art is
## 2.4 m and nothing below this level would ever notice. So every piece's real art is measured here,
## in the engine, against the box its definition promises.

const BUILDABLE_DIR: String = "res://content/buildables"
## The ramp exists because the controller has no step-up (F-136). A ramp whose collider is a box is
## a wall with a picture of a ramp on it, so the shape is checked with a real physics query.
const RAMP_TOLERANCE_M: float = 0.12

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

	var ids: Array[StringName] = []
	var dir := DirAccess.open(BUILDABLE_DIR)
	if dir == null:
		check(false, "content/buildables is readable")
		_finish()
		return
	var names: Array[String] = []
	for file_name in dir.get_files():
		if file_name.ends_with(".tres"):
			names.append(file_name)
	names.sort()

	var with_art: int = 0
	var without_art: Array[String] = []
	for file_name in names:
		var def: Resource = load("%s/%s" % [BUILDABLE_DIR, file_name]) as Resource
		if def == null:
			check(false, "%s loads" % file_name)
			continue
		var id := StringName(String(def.get(&"id")))
		ids.append(id)
		check(id != &"", "%s has an id" % file_name)
		check(registry.call("has_buildable", id), "%s is indexed by Registry" % id)

		# Costs are ids too, and an unresolvable one is a piece nobody can ever afford to build.
		var cost: Dictionary = def.get(&"cost")
		for item_id: StringName in cost:
			check(
				registry.call("get_item", item_id) != null,
				"%s: cost item '%s' exists" % [id, item_id]
			)
			check(int(cost[item_id]) > 0, "%s: cost of '%s' is positive" % [id, item_id])

		var size: Vector3 = def.get(&"size")
		check(size.x > 0.0 and size.y > 0.0 and size.z > 0.0, "%s has a real footprint" % id)

		var scene: PackedScene = def.get(&"scene")
		if scene == null:
			without_art.append(String(id))
			continue
		with_art += 1
		_check_piece_scene(id, scene, size)

	print("BUILDABLE_CONTENT defs=%d with_art=%d without_art=%s" % [ids.size(), with_art, without_art])
	check(with_art >= 12, "the authored set carries real art (%d pieces)" % with_art)

	await _check_ramp_is_walkable(registry)
	_finish()


func _check_piece_scene(id: StringName, scene: PackedScene, size: Vector3) -> void:
	var piece: Node = scene.instantiate()
	if piece == null:
		check(false, "%s: piece scene instantiates" % id)
		return
	check(piece is StaticBody3D, "%s: piece root is a StaticBody3D" % id)
	if piece is StaticBody3D:
		check(
			(piece as StaticBody3D).collision_layer == 1,
			"%s: piece is on the layer BuildService queries" % id,
			str((piece as StaticBody3D).collision_layer)
		)
	# BuildService attaches buildable_piece.gd to any root that cannot take a hit, so an authored
	# root must NOT bring its own script unless it implements the damage contract itself (F-085).
	check(
		not piece.has_method(&"host_apply_damage") or piece.get_script() != null,
		"%s: damage contract is either inherited or implemented, never half" % id
	)

	var shapes: Array[CollisionShape3D] = []
	var meshes: Array[MeshInstance3D] = []
	_collect(piece, shapes, meshes)
	check(not shapes.is_empty(), "%s: piece carries collision" % id)
	check(not meshes.is_empty(), "%s: piece carries art" % id)

	# The art, measured. Vertices rather than transformed AABBs, for the reason F-138 records.
	var low := Vector3.INF
	var high := -Vector3.INF
	for instance in meshes:
		var mesh: Mesh = instance.mesh
		if mesh == null:
			continue
		var to_root := _transform_to_root(instance, piece)
		for surface in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface)
			for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
				var point := to_root * vertex
				low = low.min(point)
				high = high.max(point)
	if low != Vector3.INF:
		var art := AABB(low, high - low)
		# The footprint box is centred on the placement origin at floor level, so the art has to sit
		# inside it: no overhang wider than the box, and nothing below the floor.
		check(
			art.size.x <= size.x + 0.25 and art.size.z <= size.z + 0.25,
			"%s: art footprint %.2f x %.2f fits the declared %.2f x %.2f" % [
				id, art.size.x, art.size.z, size.x, size.z
			]
		)
		check(
			art.size.y <= size.y + 0.25,
			"%s: art is %.2f m tall, definition says %.2f" % [id, art.size.y, size.y]
		)
		check(art.position.y > -0.05, "%s: art sits on the floor, not through it" % id)
	piece.free()


## Fire two rays at a placed ramp: one at the toe, one at the head. If the collider is the slope the
## art promises, they land a metre apart in height and neither hits a wall.
func _check_ramp_is_walkable(registry: Node) -> void:
	var def: Resource = registry.call("get_buildable", &"ramp") as Resource
	if def == null:
		check(false, "the ramp definition exists")
		return
	var scene: PackedScene = def.get(&"scene")
	if scene == null:
		check(false, "the ramp carries a piece scene")
		return
	var piece: Node3D = scene.instantiate() as Node3D
	root.add_child(piece)
	piece.global_position = Vector3.ZERO
	await process_frame
	await physics_frame

	var world: World3D = (root as Node).get_viewport().world_3d
	space = world.direct_space_state
	# Sampled at the module edges, not somewhere convenient in the middle: what matters is the two
	# heights where the ramp MEETS things — the ground at its toe and a dock or bridge deck at its
	# head. A ramp that is the right angle but lands 60 mm below the deck is a lip, and a lip is a
	# wall (F-136).
	var toe: float = _drop(Vector3(-0.98, 4.0, 0.0))
	var head: float = _drop(Vector3(0.98, 4.0, 0.0))
	var middle: float = _drop(Vector3(0.0, 4.0, 0.0))
	check(toe >= 0.0 and head >= 0.0 and middle >= 0.0, "all three rays land on the ramp")
	if toe >= 0.0 and head >= 0.0:
		check(
			absf(head - 1.0) < RAMP_TOLERANCE_M,
			"the ramp's head meets the kit's 1.00 m deck (%.3f m)" % head
		)
		check(toe < 0.10, "the ramp's toe meets the ground (%.0f mm)" % (toe * 1000.0))
		var rise: float = head - toe
		var angle: float = rad_to_deg(atan2(rise, 1.96))
		check(angle < 46.0, "the ramp climbs at %.1f degrees, under the player's floor limit" % angle)
		check(
			absf(middle - (toe + head) * 0.5) < RAMP_TOLERANCE_M,
			"the middle of the ramp is halfway up it (%.3f m)" % middle
		)
		print("BUILDABLE_RAMP toe=%.3f middle=%.3f head=%.3f angle=%.1f" % [toe, middle, head, angle])
	piece.queue_free()


func _drop(from: Vector3) -> float:
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 8.0)
	query.collision_mask = 1
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return -1.0
	return float((hit["position"] as Vector3).y)


func _collect(node: Node, shapes: Array[CollisionShape3D], meshes: Array[MeshInstance3D]) -> void:
	if node is CollisionShape3D:
		shapes.append(node as CollisionShape3D)
	if node is MeshInstance3D:
		meshes.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, shapes, meshes)


func _transform_to_root(node: Node3D, piece_root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var walker: Node = node
	while walker != null and walker != piece_root:
		if walker is Node3D:
			result = (walker as Node3D).transform * result
		walker = walker.get_parent()
	return result


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		print("PASS: %s" % label)
		return
	failures += 1
	print("FAIL: %s%s" % [label, "" if detail.is_empty() else " — " + detail])


func _finish() -> void:
	print("BUILDABLE_CONTENT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
