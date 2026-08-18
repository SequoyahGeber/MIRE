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
	_check_support_probe_requirements()
	await _check_host_placement()
	await _check_ghost()

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
	# A thin 55 degree bank whose FACE passes exactly through (32, -0.15, 0), the point under the
	# wall placed at (32, 0, 0) rotated 90 degrees so its 2 m width runs ALONG the slope's contour
	# (world Z, which this Z-axis tilt never touches) rather than across it. F-082 now requires
	# every one of the five footprint probes to hit, and a wall run across a 55 degree slope — width
	# along X — puts its corners roughly 2.9 m apart vertically, far outside any probe's 0.6 m reach,
	# which correctly reads NO_SUPPORT rather than TOO_STEEP: nothing that steep can honestly carry a
	# flat piece laid across it. Turned along the contour, the corners are only 0.125 m apart in X, a
	# ~0.18 m rise that fits inside the probe window with room either side. The box is thin (0.1 m,
	# vs the old 1 m) on purpose — full thickness tilted 55 degrees is ~1.7 m of solid along a
	# world-vertical line, so a probe that starts just clear of the face by design still starts
	# INSIDE the solid a few centimetres either side of that exact point, and reads as no hit at all
	# (same trap the single-point version of this comment used to warn about). Centre derived from
	# the face normal, not guessed: cx = px + hy*sin(t), cy = py - hy*cos(t).
	_add_box(Vector3(32.041, -0.179, 0.0), Vector3(12.0, 0.1, 12.0), 55.0)
	_add_box(Vector3(0.0, 1.5, 4.0), Vector3(2.0, 3.0, 2.0), 0.0)             # an obstruction

	# F-082 regression geometry, each isolated so a probe hits at most the one thing it is meant to.
	# A wall (size 2 x 3 x 0.25, half-extents 1 / 1.5 / 0.125) placed at these origins with yaw 0 puts
	# its five probe points at exact, known world positions — see _check_support_probe_requirements().
	_add_box(Vector3(-40.0, -0.5, -40.0), Vector3(0.3, 1.0, 0.3), 0.0)
	_add_box(Vector3(-49.0, -0.5, -39.875), Vector3(0.3, 1.0, 0.3), 0.0)
	# A 50 degree panel whose face passes exactly through (11, 0.05, 15.125) — one corner of a wall
	# placed at (10, 0, 15), which otherwise sits entirely on the flat floor above. 0.05 m above the
	# floor's own surface so the probe there hits the panel, not the flat ground underneath it. Centre
	# derived the same way as the bank above: cx = px + hy*sin(t), cy = py - hy*cos(t), for the box's
	# own half-height hy.
	_add_box(Vector3(11.383, -0.271, 15.125), Vector3(2.0, 1.0, 2.0), 50.0)

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

	# Rotated 90 degrees so the wall's 2 m width runs along the bank's contour rather than across
	# its face — see the bank's own comment in _build_world() for why that is the only orientation
	# that puts all five probes within reach of a 55 degree slope at once.
	var on_the_bank: Transform3D = VALIDATOR.snap_transform(
		wall, Vector3(32.0, 0.0, 0.0), deg_to_rad(90.0))
	var bank_reason: int = VALIDATOR.evaluate(
		space, wall, on_the_bank, Vector3(32.0, 0.0, 0.0), WORLD_LAYER)
	check(bank_reason == VALIDATOR.Reason.TOO_STEEP,
		"a 55 degree bank, wall turned along its contour -> TOO_STEEP, every probe hits (%s)" %
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


## F-082: every footprint probe must hit before a placement counts as supported, and the WORST
## (steepest) of the hits decides the slope — not the flattest survivor. Before the fix a single
## grounded probe was enough for `evaluate()` to call the whole footprint OK.
func _check_support_probe_requirements() -> void:
	print("\n== every footprint probe must hit, and the worst slope wins (F-082) ==")
	check(space != null, "a real physics space is available to query")
	if space == null:
		return

	# A 2 m wall balanced on a 20 cm pillar directly under its centre: the centre probe hits, all
	# four corner probes hang over open air. Picking the flattest surviving hit used to read this as
	# fully supported.
	var on_pillar: Transform3D = VALIDATOR.snap_transform(wall, Vector3(-40.0, 0.0, -40.0), 0.0)
	check(VALIDATOR.evaluate(space, wall, on_pillar, on_pillar.origin, WORLD_LAYER) ==
		VALIDATOR.Reason.NO_SUPPORT,
		"a wall balanced on a pillar under its centre -> NO_SUPPORT, not OK")

	# Only one of the four corners still has ground under it — a cliff-edge piece with the centre and
	# three corners hanging off, same failure the review's real-physics probe printed.
	var one_corner: Transform3D = VALIDATOR.snap_transform(wall, Vector3(-50.0, 0.0, -40.0), 0.0)
	check(VALIDATOR.evaluate(space, wall, one_corner, one_corner.origin, WORLD_LAYER) ==
		VALIDATOR.Reason.NO_SUPPORT,
		"only one corner still over ground -> NO_SUPPORT, not OK")

	# All five probes hit here, but one corner's surface is a 50 degree panel while the rest is flat
	# floor. The verdict has to come from the worst of the five, or the flat majority hides the one
	# corner steep enough to refuse.
	var mixed_slope: Transform3D = VALIDATOR.snap_transform(wall, Vector3(10.0, 0.0, 15.0), 0.0)
	var mixed_reason: int = VALIDATOR.evaluate(
		space, wall, mixed_slope, mixed_slope.origin, WORLD_LAYER)
	check(mixed_reason == VALIDATOR.Reason.TOO_STEEP,
		"four flat corners and one 50 degree corner -> TOO_STEEP, the worst of the five wins (%s)" %
			VALIDATOR.reason_text(mixed_reason))


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


## Increment C: the ghost. It is presentation, so what is asserted is that it PREDICTS with the same
## function the host decides with, and that it never decides anything itself.
func _check_ghost() -> void:
	print("\n== the ghost predicts, and never decides ==")
	var ghost: Node3D = preload("res://systems/building/build_ghost.gd").new()
	level.add_child(ghost)
	check(not ghost.visible, "a ghost with no piece selected draws nothing")
	check(not bool(ghost.call(&"set_piece", &"no_such_piece")),
		"selecting an unknown piece fails cleanly rather than showing a phantom")

	check(bool(ghost.call(&"set_piece", &"wall_wood")), "selecting a real piece succeeds")
	check(ghost.visible, "and the ghost becomes visible")
	check(StringName(ghost.call(&"current_piece_id")) == &"wall_wood", "it knows what it is showing")

	# Aim at clear flat ground well away from the obstruction at (0, *, 4).
	var reason: int = ghost.call(&"update_aim", Vector3(-6.0, 2.0, 0.0),
		Vector3(1.0, -1.0, 0.0).normalized(), Vector3(-6.0, 0.0, 0.0))
	check(reason == VALIDATOR.Reason.OK, "aimed at clear ground it reads valid (%s)" %
		VALIDATOR.reason_text(reason))
	check(bool(ghost.call(&"is_valid")), "is_valid() agrees")
	var placement: Transform3D = ghost.call(&"placement")
	check(is_equal_approx(placement.origin.x, snappedf(placement.origin.x, 1.0)),
		"the ghost snaps to the same world grid the host will re-snap to (%s)" % placement.origin)
	check(ghost.global_position.is_equal_approx(placement.origin),
		"and the node actually sits where it says it does")

	# Aim into the obstruction at (0, *, 4): the same validator the host uses must call it invalid.
	reason = ghost.call(&"update_aim", Vector3(0.0, 1.5, 0.0), Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 0.0))
	check(reason != VALIDATOR.Reason.OK, "aimed into an obstruction it reads invalid (%s)" %
		VALIDATOR.reason_text(reason))
	check(not bool(ghost.call(&"is_valid")), "is_valid() agrees")
	check(not String(ghost.call(&"last_reason_text")).is_empty(),
		"and it has words for the player: '%s'" % String(ghost.call(&"last_reason_text")))

	var before_yaw: float = (ghost.call(&"placement") as Transform3D).basis.get_euler().y
	ghost.call(&"rotate_step", 1)
	ghost.call(&"update_aim", Vector3(-6.0, 2.0, 0.0), Vector3(1.0, -1.0, 0.0).normalized(),
		Vector3(-6.0, 0.0, 0.0))
	var after_yaw: float = (ghost.call(&"placement") as Transform3D).basis.get_euler().y
	check(not is_equal_approx(before_yaw, after_yaw), "rotate_step turns it")
	check(is_equal_approx(snappedf(rad_to_deg(after_yaw), 1.0),
			snappedf(snappedf(rad_to_deg(after_yaw), 90.0), 1.0)),
		"and it stays on the authored 90 degree step (%.1f)" % rad_to_deg(after_yaw))

	ghost.queue_free()


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
