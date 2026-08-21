extends SceneTree

## Proof for F-472/D-202: placement snapping is a toggle, mates to real neighbours, and — the
## property everything else rests on — is IDEMPOTENT.
##
##   .agent/bin/agent godot --script tools/build_snap_check.gd
##
## Why idempotence is the headline assertion. `BuildService._process_place()` re-resolves whatever
## transform a client sent, because the host trusts nobody. The client's ghost has already resolved
## it once. If re-resolving a resolved transform moved it even slightly, every placement would jump
## on confirmation — the piece would land somewhere the player was never shown, and the symptom
## ("it doesn't go where I aim") would look like a snapping bug rather than an authority one. So
## this asserts `resolve(resolve(x)) == resolve(x)` directly, in both modes, with and without
## neighbours, rather than reasoning that it must hold.
##
## Runs against a REAL physics world for the same reason `build_check.gd` does: neighbour mating is
## a question asked of a space state, and a mocked one would test the mock.

const VALIDATOR := preload("res://systems/building/placement_validator.gd")
const WORLD_LAYER: int = 1

var failures: int = 0
var registry: Node
var level: Node3D
var space: PhysicsDirectSpaceState3D
var wall: Resource
var floor_def: Resource


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	registry = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		finish()
		return
	wall = registry.call(&"get_buildable", &"wall_wood") as Resource
	floor_def = registry.call(&"get_buildable", &"floor_wood") as Resource
	check(wall != null and floor_def != null,
		"the two pieces this check reasons about are both registered")
	if wall == null or floor_def == null:
		finish()
		return

	level = Node3D.new()
	level.name = "SnapLevel"
	root.add_child(level)
	await process_frame
	space = level.get_world_3d().direct_space_state

	_check_free_placement()
	_check_grid_fallback()
	await _check_mates()
	await _check_rotated_neighbour()
	await _check_idempotence()
	finish()


## Snapping OFF must mean OFF — the aim point, to the millimetre, on all three axes. This is the
## half of the toggle Sequoyah asked for first ("they should be able to be placed anywhere"), and a
## "free" mode that still quietly rounded x/z would be indistinguishable from the bug being fixed.
func _check_free_placement() -> void:
	print("\n== snapping off places exactly where you aim ==")
	var aim := Vector3(3.37, 1.04, -2.61)
	var result: Transform3D = VALIDATOR.resolve_placement(wall, aim, 0.0, false, space, WORLD_LAYER)
	check(result.origin.is_equal_approx(aim),
		"the origin is the aim point untouched (%s)" % result.origin)

	# Yaw is the exception, and deliberately so: it never comes from the aim ray at all. The player
	# builds it up in whole `rotation_step_degrees` presses, so quantising it changes nothing they
	# did and keeps a free-placed wall parallel to itself.
	var odd_yaw: float = deg_to_rad(93.0)
	var turned: Transform3D = VALIDATOR.resolve_placement(
		wall, aim, odd_yaw, false, space, WORLD_LAYER)
	check(absf(rad_to_deg(turned.basis.get_euler().y) - 90.0) < 0.001,
		"but yaw still quantises to the piece's own 90 degree step (%.3f deg)"
			% rad_to_deg(turned.basis.get_euler().y))


## With snapping on and nothing to mate to, the answer must be the world grid this system has always
## used. Neighbour snapping is an ADDITION, not a replacement: an empty field still builds on metres.
func _check_grid_fallback() -> void:
	print("\n== snapping on with no neighbours is the old world grid ==")
	var aim := Vector3(3.37, 1.04, -2.61)
	var snapped: Transform3D = VALIDATOR.resolve_placement(
		wall, aim, 0.0, true, space, WORLD_LAYER)
	var legacy: Transform3D = VALIDATOR.snap_transform(wall, aim, 0.0)
	check(snapped.is_equal_approx(legacy),
		"identical to snap_transform() (%s vs %s)" % [snapped.origin, legacy.origin])
	check(is_equal_approx(snapped.origin.y, aim.y),
		"and y is still the raw aim height, never rounded (D-056)")


## The feature itself: a piece put down beside another one lands flush against a real face of it.
func _check_mates() -> void:
	print("\n== a piece mates to its neighbour's actual faces ==")
	var neighbour: Node3D = await _place_fixture(&"wall_wood", Vector3.ZERO, 0.0)

	# Out past the wall's end: the end mate is the nearest candidate, and "flush" for a 2.00 m wall
	# means its neighbour's origin is exactly 2.00 m along the shared facing.
	var along: Transform3D = VALIDATOR.resolve_placement(
		wall, Vector3(1.3, 0.0, 0.0), 0.0, true, space, WORLD_LAYER)
	check(along.origin.distance_to(Vector3(2.0, 0.0, 0.0)) < 0.001,
		"aimed past the end it mates one full module along the run (%s)" % along.origin)

	# At the broad face: a wall built back-to-back, 0.25 m of thickness away. Not a lesser answer —
	# it is the nearest real face to that aim, and doubling a wall is a thing players do.
	var through: Transform3D = VALIDATOR.resolve_placement(
		wall, Vector3(0.0, 0.0, 0.2), 0.0, true, space, WORLD_LAYER)
	check(through.origin.distance_to(Vector3(0.0, 0.0, 0.25)) < 0.001,
		"aimed at the broad face it mates one thickness through it (%s)" % through.origin)

	# Straight up: stacking is the neighbour's floor plus its full height, because every origin in
	# this system is the piece's FLOOR centre.
	var stacked: Transform3D = VALIDATOR.resolve_placement(
		wall, Vector3(0.0, 2.8, 0.0), 0.0, true, space, WORLD_LAYER)
	check(stacked.origin.distance_to(Vector3(0.0, 3.0, 0.0)) < 0.001,
		"aimed above it stacks exactly one wall height (%s)" % stacked.origin)

	# A piece of a DIFFERENT footprint mates on that footprint, not on the neighbour's: a 2.00 m
	# floor beside a 2.00 m wall meets it at half a wall thickness plus half a floor.
	var mixed: Transform3D = VALIDATOR.resolve_placement(
		floor_def, Vector3(0.0, 0.0, 1.0), 0.0, true, space, WORLD_LAYER)
	check(mixed.origin.distance_to(Vector3(0.0, 0.0, 1.125)) < 0.001,
		"a floor beside that wall mates on ITS own depth, not the wall's (%s)" % mixed.origin)

	# Far away from everything, the neighbour must not reach: SNAP_TOLERANCE_M is what stops a
	# magnet from dragging a piece across the camp.
	var distant: Transform3D = VALIDATOR.resolve_placement(
		wall, Vector3(9.0, 0.0, 9.0), 0.0, true, space, WORLD_LAYER)
	check(distant.origin.distance_to(Vector3(9.0, 0.0, 9.0)) < 0.001,
		"and a piece well out of range of any neighbour is left on the grid (%s)" % distant.origin)
	neighbour.queue_free()
	await process_frame


## Mating happens in the NEIGHBOUR's frame, not the world's. This is the difference between a fort
## you can turn and one that must be axis-aligned to be gapless, and it is invisible in every
## axis-aligned test above — a bug here would pass all of them.
func _check_rotated_neighbour() -> void:
	print("\n== a turned neighbour still mates along its own faces ==")
	var turn: float = deg_to_rad(45.0)
	var neighbour: Node3D = await _place_fixture(&"wall_wood", Vector3.ZERO, turn)
	# One module along the neighbour's own local +x. Note the sign: rotation about +y takes +x toward
	# -z, so at 45 degrees local +x is (cos45, 0, -sin45) — the same trap
	# `tools/blender/build_construction_set.py`'s `brace()` documents on its side of the fence, and
	# the reason this case exists at all. Getting it wrong mirrors every mate and is invisible in
	# every axis-aligned assertion above.
	var expected := Vector3(cos(turn), 0.0, -sin(turn)) * 2.0
	var mated: Transform3D = VALIDATOR.resolve_placement(
		wall, expected * 0.65, turn, true, space, WORLD_LAYER)
	check(mated.origin.distance_to(expected) < 0.001,
		"it mates along the turned neighbour's local axis (%s, wanted %s)" % [mated.origin, expected])
	check(absf(rad_to_deg(mated.basis.get_euler().y) - 45.0) < 0.001,
		"and adopts its facing, so the two are parallel (%.3f deg)"
			% rad_to_deg(mated.basis.get_euler().y))

	# The player's own rotation is still theirs — it is counted in whole steps FROM the neighbour's
	# facing rather than from world zero, so they can still turn a corner. What they cannot do is end
	# up 3 degrees off it.
	var cornered: Transform3D = VALIDATOR.resolve_placement(
		wall, expected * 0.65, turn + deg_to_rad(87.0), true, space, WORLD_LAYER)
	check(absf(rad_to_deg(cornered.basis.get_euler().y) - 135.0) < 0.001,
		"a near-90 rotation next to it lands on exactly 135, not 132 (%.3f deg)"
			% rad_to_deg(cornered.basis.get_euler().y))
	neighbour.queue_free()
	await process_frame


## The property the host/client agreement rests on — see this file's header.
func _check_idempotence() -> void:
	print("\n== resolving an already-resolved transform changes nothing ==")
	var neighbour: Node3D = await _place_fixture(&"wall_wood", Vector3.ZERO, deg_to_rad(45.0))
	var aims: Array[Vector3] = [
		Vector3(1.3, 0.0, 0.0), Vector3(0.0, 0.0, 0.2), Vector3(0.0, 2.8, 0.0),
		Vector3(3.37, 1.04, -2.61), Vector3(9.0, 0.0, 9.0), Vector3(0.9, 0.0, 0.9),
	]
	for snapping: bool in [true, false]:
		var stable: bool = true
		var worst: float = 0.0
		for aim: Vector3 in aims:
			var once: Transform3D = VALIDATOR.resolve_placement(
				wall, aim, deg_to_rad(37.0), snapping, space, WORLD_LAYER)
			var twice: Transform3D = VALIDATOR.resolve_placement(
				wall, once.origin, once.basis.get_euler().y, snapping, space, WORLD_LAYER)
			worst = maxf(worst, once.origin.distance_to(twice.origin))
			if not once.is_equal_approx(twice):
				stable = false
		check(stable,
			"snapping %s: every one of the %d aims is a fixed point (worst drift %.6f m)"
				% ["on" if snapping else "off", aims.size(), worst])

	# Six hand-picked aims prove the cases someone thought of. The property has to hold for the ones
	# nobody thought of too, and it is exactly the kind of property that fails in a narrow band —
	# the bug this check caught during authoring was a grid fallback carrying an origin from just
	# outside the snap tolerance to just inside it, which no round-numbered aim would ever land on.
	# So: a deterministic sweep across the band where mating and the grid actually compete.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED_B111
	var unstable: int = 0
	var worst_fuzz: float = 0.0
	for i: int in 400:
		var aim := Vector3(
			rng.randf_range(-4.0, 4.0), rng.randf_range(0.0, 4.0), rng.randf_range(-4.0, 4.0))
		var yaw: float = rng.randf_range(-PI, PI)
		var snapping: bool = rng.randi() % 2 == 0
		var once: Transform3D = VALIDATOR.resolve_placement(
			wall, aim, yaw, snapping, space, WORLD_LAYER)
		var twice: Transform3D = VALIDATOR.resolve_placement(
			wall, once.origin, once.basis.get_euler().y, snapping, space, WORLD_LAYER)
		worst_fuzz = maxf(worst_fuzz, once.origin.distance_to(twice.origin))
		if not once.is_equal_approx(twice):
			unstable += 1
	check(unstable == 0,
		"400 seeded aims around a turned neighbour are all fixed points (%d unstable, worst %.6f m)"
			% [unstable, worst_fuzz])

	neighbour.queue_free()
	await process_frame


## A real placed piece, built the way BuildService builds one: on the layer the snap query reads,
## in PIECE_GROUP, and carrying the `buildable_id` metadata that names its definition. Without that
## metadata a neighbour is an anonymous collider and snapping correctly ignores it — which is worth
## saying out loud, because a fixture that forgot it would make every mate assertion above fail in a
## way that looked like the snapping was broken.
func _place_fixture(piece_id: StringName, at: Vector3, yaw: float) -> Node3D:
	var def: Resource = registry.call(&"get_buildable", piece_id) as Resource
	var size: Vector3 = def.get(&"size")
	var body := StaticBody3D.new()
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = Vector3(0.0, size.y * 0.5, 0.0)
	body.add_child(shape)
	body.position = at
	body.rotation.y = yaw
	body.add_to_group(&"buildable_piece")
	body.set_meta(&"buildable_id", String(piece_id))
	level.add_child(body)
	await process_frame
	return body


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	print("BUILD_SNAP_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
