extends SceneTree

## F-404: the two movement properties that can be PINNED, as opposed to judged.
##
## The finding is explicit that stopping distance, air control and fall weight are feel calls and
## belong in play, not in a check. But two of them have objective components that a regression would
## break silently, and those are worth holding:
##
##   1. **Steering in the air must not cost speed.** The old model ran `move_toward` on the velocity
##      VECTOR, so pushing a direction that differed from current travel dragged the vector through
##      lower magnitudes — the player paid speed for turning and then won it back. Any future change
##      that reintroduces vector-interpolated air control fails this.
##   2. **A long fall must be capped.** `terminal_velocity` was 60 m/s, high enough that nothing a
##      player survives ever reached it, so it was a cap in name only.
##
## Input is driven through `Input.action_press()` so the real `_apply_horizontal_movement()` path
## runs, rather than a reimplementation of it that could agree with itself while the game disagrees.
##
## Run with: .agent/bin/agent godot --script tools/movement_feel_check.gd

const PLAYER_SCENE := preload("res://entities/player/player.tscn")
const D: float = 1.0 / 60.0

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var world := Node3D.new()
	world.name = "MovementWorld"
	root.add_child(world)
	current_scene = world
	_box(world, Vector3(200.0, 1.0, 200.0), Vector3(0.0, -0.5, 0.0))

	await _check_air_steering_keeps_speed(world)
	await _check_long_fall_is_capped(world)

	print("MOVEMENT_FEEL_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


## Launch the body horizontally, then steer. Speed must not fall.
func _check_air_steering_keeps_speed(world: Node3D) -> void:
	var p: CharacterBody3D = PLAYER_SCENE.instantiate() as CharacterBody3D
	world.add_child(p)
	p.global_position = Vector3(0.0, 8.0, 0.0)
	p.set_physics_process(false)

	# Travelling forward at a realistic sprint, well clear of the ground so is_on_floor() is false.
	p.velocity = Vector3(6.0, 0.0, 0.0)
	var before: float = Vector2(p.velocity.x, p.velocity.z).length()

	# Steer PERPENDICULAR to travel for a quarter second — the case that used to bleed speed.
	# It has to be perpendicular: the body is travelling +X with an identity basis, so `move_left`
	# would be a reverse (correctly decelerating) rather than a steer, and would test nothing.
	# `move_forward` maps to -Z, square to the direction of travel.
	Input.action_press(&"move_forward")
	for _i: int in 15:
		p.call(&"_apply_horizontal_movement", D, true, false, false)
		p.velocity.y = 0.0            # hold it airborne; gravity is not what is under test
		p.move_and_slide()
		await physics_frame
	Input.action_release(&"move_forward")

	var after: float = Vector2(p.velocity.x, p.velocity.z).length()
	check(after >= before - 0.05,
		"steering in the air does not cost speed (%.2f -> %.2f m/s)" % [before, after],
		"vector-interpolated air control drags the velocity through lower magnitudes when the input "
		+ "direction differs from current travel")
	check(absf(p.velocity.z) > 0.5,
		"...and the steer actually redirected the arc (z became %.2f m/s)" % p.velocity.z,
		"if z never moved, the assertion above passed because nothing happened")
	p.queue_free()
	await process_frame


## Drop from high enough to exceed the cap and confirm it engages.
func _check_long_fall_is_capped(world: Node3D) -> void:
	var p: CharacterBody3D = PLAYER_SCENE.instantiate() as CharacterBody3D
	world.add_child(p)
	p.global_position = Vector3(50.0, 60.0, 50.0)
	p.set_physics_process(false)

	var cap: float = float(p.get(&"terminal_velocity"))
	var fastest: float = 0.0
	for _i: int in 180:
		p.call(&"_apply_gravity", D)
		fastest = maxf(fastest, -p.velocity.y)
		p.move_and_slide()
		await physics_frame
		if p.is_on_floor():
			break

	check(cap <= 30.0,
		"terminal_velocity is a cap a real fall can actually reach (%.0f m/s)" % cap,
		"at 60 m/s nothing a player survives ever reaches it, so it caps nothing")
	check(fastest <= cap + 0.5,
		"a 60 m drop is capped at terminal_velocity (peaked %.1f m/s, cap %.1f)" % [fastest, cap])
	p.queue_free()
	await process_frame


func _box(parent: Node3D, size: Vector3, centre: Vector3) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = centre


func check(condition: bool, description: String, detail: String = "") -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s%s" % [description, "" if detail.is_empty() else " — " + detail])
