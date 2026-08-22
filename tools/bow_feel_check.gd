extends SceneTree

## F-594 — the three things Sequoyah reported about the bow, asserted.
##
##   1. A flying arrow points along its own flight path, not broadside to it.
##   2. It keeps pointing along the path as gravity bends the path down.
##   3. Drawing a bow poses the viewmodel from the RANGED service, with a draw that HOLDS.
##
## The orientation assertions measure the arrow's own shaft, not its -Z. That distinction IS the
## bug: `arrow_world` is 0.226 x 0.239 x 1.476 m, so the shaft runs along +Y, and a check written
## against -Z would have passed happily while every arrow in the game flew sideways.
##
## Authority: none. Pure measurement of presentation code.

const ViewmodelScript := preload("res://entities/player/viewmodel.gd")

## The model axis the shaft actually runs along, from assets/tools_weapons/catalog.json.
const SHAFT_AXIS := Vector3.UP
const TOLERANCE_DEG: float = 1.0

var failures: int = 0
## The live autoload. `_orient_projectile` is static, but GDScript refuses `Script.call()` on a
## class that also has instance members, so it is reached through the running service.
var ranged: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	ranged = root.get_node_or_null(^"RangedCombatService")
	check(ranged != null, "RangedCombatService is registered as an autoload")
	if ranged == null:
		_finish()
		return
	_check_orientation()
	_check_follows_the_arc()
	_check_draw_holds()
	_finish()


## The shaft points where the arrow is going — the F-594 regression itself.
func _check_orientation() -> void:
	print("\n== a flying arrow's shaft points along its velocity ==")
	for velocity: Vector3 in [
		Vector3(0, 0, -30), Vector3(30, 0, 0), Vector3(-12, 4, 20),
		Vector3(0, -25, 0), Vector3(0, 25, 0), Vector3(3, -1, -40),
	]:
		var node := Node3D.new()
		root.add_child(node)
		ranged.call(&"_orient_projectile", node, velocity)
		var shaft: Vector3 = (node.global_transform.basis * SHAFT_AXIS).normalized()
		var error_deg: float = rad_to_deg(shaft.angle_to(velocity.normalized()))
		check(error_deg <= TOLERANCE_DEG,
			"velocity %s -> shaft off by %.2f deg" % [velocity, error_deg])
		node.queue_free()

	# The negative control. Without the model-axis correction the old code aimed -Z down the path,
	# which leaves the shaft ~90 degrees off — so this proves the correction is what fixes it rather
	# than `look_at` having been fine all along.
	var bare := Node3D.new()
	root.add_child(bare)
	bare.look_at(bare.global_position + Vector3(0, 0, -1), Vector3.UP)
	var bare_shaft: Vector3 = (bare.global_transform.basis * SHAFT_AXIS).normalized()
	var bare_error: float = rad_to_deg(bare_shaft.angle_to(Vector3(0, 0, -1)))
	check(bare_error > 45.0,
		"negative control: a plain look_at leaves the shaft %.1f deg off (the original bug)"
			% bare_error)
	bare.queue_free()


## Orientation tracks the CURVE, not the launch direction.
func _check_follows_the_arc() -> void:
	print("\n== the arrow noses over as its path drops ==")
	var launch := Vector3(0, 6, -34)
	var gravity: float = 24.0
	var early := Node3D.new()
	var late := Node3D.new()
	root.add_child(early)
	root.add_child(late)
	ranged.call(&"_orient_projectile", early, launch)
	ranged.call(&"_orient_projectile", late, launch - Vector3.UP * gravity * 1.2)
	var early_pitch: float = (early.global_transform.basis * SHAFT_AXIS).normalized().y
	var late_pitch: float = (late.global_transform.basis * SHAFT_AXIS).normalized().y
	check(early_pitch > 0.0, "a rising arrow points up (%.3f)" % early_pitch)
	check(late_pitch < 0.0, "a falling arrow points down (%.3f)" % late_pitch)
	check(late_pitch < early_pitch,
		"the arrow's nose drops as the flight goes on (%.3f -> %.3f)" % [early_pitch, late_pitch])
	early.queue_free()
	late.queue_free()


## A draw pulls back and STAYS back — the property that separates it from a swing.
func _check_draw_holds() -> void:
	print("\n== drawing a bow holds at full draw, then releases forward ==")
	var view := ViewmodelScript.new() as Node3D
	root.add_child(view)

	var rest: Vector3 = view.call(&"bow_pose", 1, 0.0)[0]
	var mid: Vector3 = view.call(&"bow_pose", 1, 0.55)[0]
	var full: Vector3 = view.call(&"bow_pose", 1, 1.0)[0]
	# +Z is toward the camera in viewmodel space, so a draw increases z.
	check(mid.z > rest.z, "the draw pulls back (%.4f -> %.4f)" % [rest.z, mid.z])
	check(absf(full.z - mid.z) < absf(mid.z - rest.z),
		"the second half of the draw moves less than the first — it holds, not creeps")

	var released: Vector3 = view.call(&"bow_pose", 2, 1.0)[0]
	check(released.z < full.z, "release snaps forward (%.4f -> %.4f)" % [full.z, released.z])

	# A swing does the opposite: it drives forward DURING wind-up, into the contact frame at its end.
	# Asserting the difference is what stops someone "simplifying" the bow onto the swing curve.
	var swing_mid: Vector3 = view.call(&"swing_pose", 1, 1, 0.55)[0]
	var swing_end: Vector3 = view.call(&"swing_pose", 1, 1, 1.0)[0]
	check(swing_end.z < swing_mid.z,
		"a swing still drives forward through its own wind-up (%.4f -> %.4f)"
			% [swing_mid.z, swing_end.z])
	view.queue_free()


func check(ok: bool, label: String) -> void:
	if ok:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func _finish() -> void:
	print("\nBOW_FEEL_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
