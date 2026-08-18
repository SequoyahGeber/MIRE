extends SceneTree

## Offline proof for task 3.6's placement rules: snapping is pure and identical everywhere, and the
## validator refuses the four things a building system has to refuse.
##
##   .agent/bin/agent godot --script tools/build_check.gd
##
## Runs against a REAL physics world, not a mocked one. The validator's whole job is asking a space
## state questions, so a fake space state would test the mock. This builds a floor, a slope and an
## obstruction as actual StaticBody3Ds and queries them the way the ghost and the host will.
##
## The snapping half is deliberately separate and pure: it takes no world, so it is identical on
## every peer by construction, which is what lets one player's wall line up with another's.

const VALIDATOR := preload("res://systems/building/placement_validator.gd")

const WORLD_LAYER: int = 1

var failures: int = 0
var registry: Node
var level: Node3D
var space: PhysicsDirectSpaceState3D
var wall: Resource
var service: Node
var _confirmations: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	registry = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		finish()
		return

	_check_content_loads()
	if wall == null:
		finish()
		return
	_check_snapping_is_pure()
	await _build_world()
	_check_placement_rules()
	await _check_host_placement()

	print("\nBUILD_CHECK failures=%d" % failures)
	finish()


func _check_content_loads() -> void:
	print("\n== the worked examples load through the real registry ==")
	wall = registry.call(&"get_buildable", &"wall_wood")
	var ward: Resource = registry.call(&"get_buildable", &"ward_post")
	check(wall != null, "content/buildables/wall.tres is indexed by its id")
	check(ward != null, "content/buildables/ward_post.tres is indexed by its id")
	if wall == null or ward == null:
		return
	check((wall.call(&"validation_errors") as PackedStringArray).is_empty(), "the wall validates clean")
	check(not bool(wall.call(&"is_ward")), "a wall is not a Ward")
	check(bool(ward.call(&"is_ward")) and is_equal_approx(float(ward.get(&"ward_radius_m")), 12.0),
		"the Ward post carries the radius 4.11 will read")
	check(int((wall.get(&"cost") as Dictionary).get(&"log", 0)) == 4,
		"the wall costs 4 log, which the host will spend through host_transaction")

	var broken: Resource = preload("res://systems/building/buildable_def.gd").new()
	check(not (broken.call(&"validation_errors") as PackedStringArray).is_empty(),
		"an empty BuildableDef is rejected rather than silently indexed")


## No physics, no world, no builder — snapping has to be a pure function of the aim point, or two
## players standing in different places snap the same wall to different grids and nothing lines up.
func _check_snapping_is_pure() -> void:
	print("\n== snapping is world-space and pure ==")
	var snapped: Transform3D = VALIDATOR.snap_transform(wall, Vector3(3.4, 0.2, -7.8), 0.0)
	check(snapped.origin.is_equal_approx(Vector3(3.0, 0.0, -8.0)),
		"a 1 m grid snaps (3.4, 0.2, -7.8) to (3, 0, -8) — got %s" % snapped.origin)

	# Y is snapped too: a floor at 2.5 and another at 2.51 is a seam you cannot see or walk over.
	var stacked: Transform3D = VALIDATOR.snap_transform(wall, Vector3(0.0, 2.51, 0.0), 0.0)
	check(is_equal_approx(stacked.origin.y, 3.0), "height snaps as well (%.2f)" % stacked.origin.y)

	var rotated: Transform3D = VALIDATOR.snap_transform(wall, Vector3.ZERO, deg_to_rad(58.0))
	var yaw_degrees: float = rad_to_deg(rotated.basis.get_euler().y)
	check(is_equal_approx(snappedf(yaw_degrees, 1.0), 90.0),
		"a 90 degree step snaps 58 degrees to 90 (got %.1f)" % yaw_degrees)

	# Same input, same output, every time — this is what "identical on every peer" rests on.
	var again: Transform3D = VALIDATOR.snap_transform(wall, Vector3(3.4, 0.2, -7.8), 0.0)
	check(again.origin.is_equal_approx(snapped.origin), "snapping is deterministic")

	check(VALIDATOR.evaluate(null, null, Transform3D(), Vector3.ZERO) ==
		VALIDATOR.Reason.UNKNOWN_PIECE, "a null def is UNKNOWN_PIECE, not a crash")


func _build_world() -> void:
	level = Node3D.new()
	level.name = "BuildTestLevel"
	root.add_child(level)
	current_scene = level

	_add_box(Vector3(0.0, -0.5, 0.0), Vector3(40.0, 1.0, 40.0), 0.0)          # flat floor at y=0
	# A 55 degree bank whose FACE passes exactly through (32, 0, 0), the point the wall is placed
	# at. Two things had to be true and neither is obvious: it must be clear of the floor's x=+20
	# edge, or the wall's corner probes find flat floor, take it as the flattest support and the
	# slope rule never sees the bank; and the surface must be at the probe's height, because a
	# support ray that starts INSIDE the solid returns no hit at all and the placement reads as
	# unsupported rather than steep. Centre derived from the face normal, not guessed.
	_add_box(Vector3(32.410, -0.287, 0.0), Vector3(12.0, 1.0, 12.0), 55.0)
	_add_box(Vector3(0.0, 1.5, 4.0), Vector3(2.0, 3.0, 2.0), 0.0)             # an obstruction

	# Two physics frames: one for the bodies to enter the tree, one for the space to know them.
	await physics_frame
	await physics_frame
	space = level.get_viewport().find_world_3d().direct_space_state


func _add_box(centre: Vector3, size: Vector3, tilt_degrees: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = WORLD_LAYER
	body.position = centre
	body.rotation_degrees = Vector3(0.0, 0.0, tilt_degrees)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	level.add_child(body)


func _check_placement_rules() -> void:
	print("\n== the four refusals ==")
	check(space != null, "a real physics space is available to query")
	if space == null:
		return
	var builder := Vector3(0.0, 0.0, 0.0)

	var clear: Transform3D = VALIDATOR.snap_transform(wall, Vector3(2.0, 0.0, 0.0), 0.0)
	check(VALIDATOR.evaluate(space, wall, clear, builder, WORLD_LAYER) == VALIDATOR.Reason.OK,
		"flat ground, in range, nothing in the way -> OK")

	var far_away: Transform3D = VALIDATOR.snap_transform(wall, Vector3(25.0, 0.0, 0.0), 0.0)
	check(VALIDATOR.evaluate(space, wall, far_away, builder, WORLD_LAYER) ==
		VALIDATOR.Reason.OUT_OF_RANGE,
		"past max_build_range_m -> OUT_OF_RANGE, checked before anything expensive")

	var into_obstruction: Transform3D = VALIDATOR.snap_transform(wall, Vector3(0.0, 0.0, 4.0), 0.0)
	check(VALIDATOR.evaluate(space, wall, into_obstruction, builder, WORLD_LAYER) ==
		VALIDATOR.Reason.OVERLAPS,
		"inside an existing body -> OVERLAPS")

	# Off the edge of the floor entirely: nothing under any of the five support probes.
	var over_the_void: Transform3D = VALIDATOR.snap_transform(wall, Vector3(0.0, 5.0, 0.0), 0.0)
	check(VALIDATOR.evaluate(space, wall, over_the_void, Vector3(0.0, 5.0, 0.0), WORLD_LAYER) ==
		VALIDATOR.Reason.NO_SUPPORT,
		"hanging in the air -> NO_SUPPORT")

	var on_the_bank: Transform3D = VALIDATOR.snap_transform(wall, Vector3(32.0, 0.0, 0.0), 0.0)
	var bank_reason: int = VALIDATOR.evaluate(
		space, wall, on_the_bank, Vector3(32.0, 0.0, 0.0), WORLD_LAYER)
	check(bank_reason == VALIDATOR.Reason.TOO_STEEP,
		"a 55 degree bank -> TOO_STEEP, the reason the player can act on (%s)" %
			VALIDATOR.reason_text(bank_reason))

	# Two walls side by side share a face exactly. Without the overlap skin every second wall in a
	# run would be refused for touching its neighbour, which makes the system feel broken.
	var neighbour: Transform3D = VALIDATOR.snap_transform(wall, Vector3(-2.0, 0.0, 0.0), 0.0)
	check(VALIDATOR.evaluate(space, wall, neighbour, builder, WORLD_LAYER) == VALIDATOR.Reason.OK,
		"a wall on the adjacent grid cell is fine — touching is not overlapping")

	print("\n== every refusal has words for the player ==")
	for reason: int in [
		VALIDATOR.Reason.OK, VALIDATOR.Reason.UNKNOWN_PIECE, VALIDATOR.Reason.OUT_OF_RANGE,
		VALIDATOR.Reason.OVERLAPS, VALIDATOR.Reason.NO_SUPPORT, VALIDATOR.Reason.TOO_STEEP,
		VALIDATOR.Reason.CANNOT_AFFORD,
	]:
		check(not VALIDATOR.reason_text(reason).is_empty(),
			"reason %d reads as '%s'" % [reason, VALIDATOR.reason_text(reason)])
	check(VALIDATOR.is_placeable(VALIDATOR.Reason.OK) and
		not VALIDATOR.is_placeable(VALIDATOR.Reason.OVERLAPS),
		"is_placeable() agrees with the enum")


## Increment B: the host's own decision path, offline, where this process is host-of-one and every
## host branch below is the real one.
func _check_host_placement() -> void:
	print("\n== the host decides, charges, and can be told no ==")
	service = root.get_node_or_null(^"BuildService")
	# F-068's lesson: a check whose subject is an autoload resolves the autoload, so an unregistered
	# service fails here rather than passing against a private copy.
	check(service != null,
		"BuildService is registered as an autoload — without it nothing can ever be built")
	if service == null:
		return
	service.connect(&"build_confirmed", _on_build_confirmed)

	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(inventory != null, "InventoryService exists to charge the cost against")
	if inventory == null:
		return

	# A wall costs 4 log and this peer has none.
	_confirmations.clear()
	var clear_spot := Transform3D(Basis(), Vector3(2.0, 0.0, 0.0))
	service.call(&"request_place", &"wall_wood", clear_spot)
	await process_frame
	check(_confirmations.size() == 1 and not bool(_confirmations[0]["accepted"]),
		"with an empty inventory the placement is refused")
	if not _confirmations.is_empty():
		check(String(_confirmations[0]["reason"]) == "not enough materials",
			"and the reason names the cost (%s)" % String(_confirmations[0]["reason"]))
	check(int(service.call(&"placed_count")) == 0, "nothing was spawned for a refused build")

	# Pay for it.
	inventory.call(&"host_transaction", 1, {} as Dictionary, {&"log": 10} as Dictionary)
	_confirmations.clear()
	service.call(&"request_place", &"wall_wood", clear_spot)
	await process_frame
	check(_confirmations.size() == 1 and bool(_confirmations[0]["accepted"]),
		"with materials the placement is accepted")
	check(int(service.call(&"placed_count")) == 1, "and exactly one piece exists")

	var pieces: Array = get_nodes_in_group(&"buildable_piece")
	check(pieces.size() == 1, "the piece joined the buildable_piece group")
	check(get_nodes_in_group(&"damageable").size() >= 1,
		"and &\"damageable\", so it can be attacked like anything else in the world")
	check(bool(service.get(&"_nav_rebake_pending")),
		"a placement queues a navmesh rebake rather than baking inline")
	check(is_equal_approx(float(service.get(&"NAV_REBAKE_INTERVAL_SEC")), 1.0),
		"and the rebake is debounced to at most one per second (SPECS 3.6)")

	# The host re-runs the validator: a second wall in the same place must be refused even though
	# the client "asked nicely" with a transform that was valid a moment ago.
	_confirmations.clear()
	service.call(&"request_place", &"wall_wood", clear_spot)
	await process_frame
	check(_confirmations.size() == 1 and not bool(_confirmations[0]["accepted"]),
		"a second piece in the same spot is refused — the host revalidates from scratch")
	check(int(service.call(&"placed_count")) == 1, "and still exactly one piece exists")

	# Destroy it and get materials back.
	var piece_name := StringName((pieces[0] as Node).name)
	var record: Dictionary = service.call(&"placed_record", piece_name)
	check(StringName(String(record.get("def", ""))) == &"wall_wood",
		"the host knows which def each placed piece came from")
	_confirmations.clear()
	service.call(&"request_destroy", piece_name)
	await process_frame
	check(_confirmations.size() == 1 and bool(_confirmations[0]["accepted"]),
		"destroying an existing piece is accepted")
	check(int(service.call(&"placed_count")) == 0, "and the host forgets it")

	_confirmations.clear()
	service.call(&"request_destroy", &"NoSuchPiece")
	await process_frame
	check(_confirmations.size() == 1 and not bool(_confirmations[0]["accepted"]),
		"destroying something that does not exist is refused, not a crash")

	service.disconnect(&"build_confirmed", _on_build_confirmed)


func _on_build_confirmed(request_id: int, accepted: bool, reason: String) -> void:
	_confirmations.append({"id": request_id, "accepted": accepted, "reason": reason})


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
