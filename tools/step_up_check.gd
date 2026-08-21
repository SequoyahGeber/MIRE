extends SceneTree

## F-403: pushing into a wall must not lift the player.
##
## `PlayerController._apply_step_up()` (F-136) exists because CharacterBody3D has no built-in
## step-up: a capsule's flat vertical face reads any kerb as a wall. It raises the body by
## `step_height`, sweeps forward and down, and keeps the result.
##
## Its only refusal test is on the sweep's VERTICAL travel — "the sweep found nothing within reach"
## — which cannot distinguish a lip from a wall, because a wall stops the sweep's FORWARD component
## before it ever descends. So walking into a tree raised the player 0.4 m and left them there;
## gravity dropped them the next frame, and the frame after that raised them again. Reported from
## play, twice: "running into a tree still makes the play bounce up and down."
##
## This drives the real `_apply_step_up()` + `move_and_slide()` pair rather than reasoning about it,
## and asserts BOTH halves of the contract, because a fix that just disables the feature would pass
## the first half alone:
##   · pushing into a full-height wall must not move the player vertically at all
##   · a genuine kerb below `step_height` must still be climbed
##
## Run with: .agent/bin/agent godot --script tools/step_up_check.gd

const PLAYER_SCENE := preload("res://entities/player/player.tscn")

const TICKS: int = 90
const DELTA: float = 1.0 / 60.0
const PUSH_SPEED: float = 4.0

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var world := Node3D.new()
	world.name = "StepUpWorld"
	root.add_child(world)
	current_scene = world
	_add_floor(world)

	# ── 1. A full-height wall. This is the tree case. ────────────────────────────────────────────
	var wall_body: StaticBody3D = _add_box(world, Vector3(0.6, 6.0, 6.0), Vector3(2.5, 3.0, 0.0))
	var wall_result: Dictionary = await _push_into(world, "wall")
	wall_body.queue_free()
	await process_frame

	check(float(wall_result["rise"]) < 0.02,
		"pushing into a full-height wall never lifts the player (rose %.3f m)" % wall_result["rise"])
	check(int(wall_result["oscillations"]) == 0,
		"and does not oscillate (%d up/down reversals)" % wall_result["oscillations"])

	# ── 2. A 0.3 m kerb, below step_height. This must still be climbed. ──────────────────────────
	var kerb_body: StaticBody3D = _add_box(world, Vector3(6.0, 0.3, 6.0), Vector3(4.0, 0.15, 0.0))
	var kerb_result: Dictionary = await _push_into(world, "kerb")
	kerb_body.queue_free()

	# The second half of the contract: the fix must not be "delete the feature". A kerb below
	# `step_height` has to be climbed and crossed, not merely nudged.
	#
	# This assertion was deliberately weak while F-403 was the only fix in place — it asserted the
	# 0.135 m partial lift that was all the controller could manage then, with a comment pointing at
	# F-405. F-405 is fixed, so it now demands the real thing: on top of the kerb, and across it.
	check(float(kerb_result["rise"]) > 0.28,
		"a 0.3 m kerb is climbed, not stalled on (rose %.3f m)" % kerb_result["rise"])
	check(float(kerb_result["advance"]) > 3.0,
		"and the player carries on across it (advanced %.2f m; it used to stall at 0.63)"
			% kerb_result["advance"])

	print("STEP_UP_CHECK failures=%d wall_rise=%.3f wall_osc=%d kerb_rise=%.3f kerb_advance=%.2f" % [
		failures, wall_result["rise"], wall_result["oscillations"],
		kerb_result["rise"], kerb_result["advance"]])
	quit(0 if failures == 0 else 1)


## Drops a player, lets it settle, then drives it forward into whatever is in front for TICKS
## physics steps through the REAL `_apply_step_up()` + `move_and_slide()` path.
func _push_into(world: Node3D, label: String) -> Dictionary:
	var player: CharacterBody3D = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "StepUpPlayer_%s" % label
	world.add_child(player)
	player.global_position = Vector3(0.0, 0.6, 0.0)
	# The controller's own _physics_process reads input and networking; drive the movement seam
	# directly instead so this check has no dependency on either.
	player.set_physics_process(false)

	# Settle onto the floor first — a body still falling reads every frame as vertical movement.
	for _i: int in 30:
		player.velocity.y -= 9.8 * DELTA
		player.move_and_slide()
		await physics_frame

	var settled_y: float = player.global_position.y
	var start_x: float = player.global_position.x
	var lowest: float = settled_y
	var highest: float = settled_y
	var reversals: int = 0
	var previous: float = settled_y
	var direction: int = 0

	for _i: int in TICKS:
		player.velocity.x = PUSH_SPEED
		player.velocity.z = 0.0
		player.velocity.y = 0.0 if player.is_on_floor() else player.velocity.y - 9.8 * DELTA
		player.call(&"_apply_step_up", DELTA)
		player.move_and_slide()
		await physics_frame

		var y: float = player.global_position.y
		highest = maxf(highest, y)
		lowest = minf(lowest, y)
		var moved: float = y - previous
		if absf(moved) > 0.01:
			var now: int = 1 if moved > 0.0 else -1
			if direction != 0 and now != direction:
				reversals += 1
			direction = now
		previous = y

	var out := {
		"rise": highest - settled_y,
		"oscillations": reversals,
		"advance": player.global_position.x - start_x,
	}
	player.queue_free()
	await process_frame
	return out


func _add_floor(parent: Node3D) -> void:
	_add_box(parent, Vector3(40.0, 1.0, 40.0), Vector3(0.0, -0.5, 0.0))


func _add_box(parent: Node3D, size: Vector3, centre: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = centre
	return body


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
