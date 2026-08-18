extends SceneTree

## Focused offline proof for F-136: PlayerController's step-up (_apply_step_up() in
## entities/player/player_controller.gd) climbs a lip at or under `step_height` and refuses one
## taller than it, using a real entities/player/player.tscn instance against real StaticBody3D
## geometry — not an assertion on private state in isolation.
##
##   .agent/bin/agent godot --script tools/step_up_check.gd
##
## Ground settle uses real physics_frame stepping (tools/spawn_ground_probe.gd's technique) over
## code-built StaticBody3D geometry (tools/build_check.gd's technique). The walk itself then drives
## _apply_gravity()/_apply_horizontal_movement()/_apply_step_up()/move_and_slide() by hand, same
## reasoning tools/dodge_check.gd already established for this controller: AttunementUI (autoload)
## polls for any node joining the `players` group and opens a BLOCKING_UI_GROUP role picker ~0.5 s
## after spawn, which starves a check that instead waits real frames for real WASD input. Hand-driving
## with input_allowed forced true calls the identical physics-tick sequence _physics_process() does,
## in the same order, just without racing that picker.

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")
## Below player_controller.gd's default step_height (0.4 m) — a threshold/kerb the controller must
## climb without breaking stride.
const LOW_LIP_M: float = 0.15
## Above step_height — an ordinary short wall the controller must still refuse to climb.
const TALL_LIP_M: float = 0.6
const WALK_TICKS: int = 150
const PHYSICS_DELTA: float = 1.0 / 60.0

var failures: int = 0
var level: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	level = Node3D.new()
	root.add_child(level)

	# Ground on the near side (Z 0..10, top y=0) meets a raised slab on the far side (Z -10..0) at
	# Z=0 for each lane; the step at that seam is the only thing being measured. Two independent
	# lanes (X=0 low lip, X=20 tall lip) share one level so both cases can be built once up front.
	_add_lane(0.0, LOW_LIP_M)
	_add_lane(20.0, TALL_LIP_M)
	await physics_frame
	await physics_frame

	await _check_climbs_low_lip()
	await _check_refuses_tall_lip()
	await _check_disabled_step_height_gets_stuck()

	print("\n%d failure(s)\n" % failures)
	quit(0 if failures == 0 else 1)


func _add_lane(lane_x: float, lip_height_m: float) -> void:
	_add_box(Vector3(lane_x, -0.5, 5.0), Vector3(4.0, 1.0, 10.0))                       # top y=0
	_add_box(Vector3(lane_x, lip_height_m * 0.5, -5.0), Vector3(4.0, lip_height_m, 10.0)) # top y=lip_height_m


func _add_box(centre: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = centre
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	level.add_child(body)


## Spawns on the near-ground lane at (lane_x, 0.1, 8) and lets the REAL engine _physics_process
## settle it onto the floor via gravity — real path, no UI can intervene since nothing needs input
## yet. Then hands control to _walk_forward(), which drives the rest by hand (see file header).
func _spawn_and_settle(lane_x: float) -> CharacterBody3D:
	var player: CharacterBody3D = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "1"
	player.position = Vector3(lane_x, 0.1, 8.0)
	level.add_child(player)
	for _i: int in 10:
		await physics_frame
	player.set_physics_process(false)
	return player


## Walks WALK_TICKS at PHYSICS_DELTA by calling _physics_process()'s own movement sequence directly,
## input_allowed forced true — enough at walk_speed (4 m/s default) to cross the 8 m to the seam and
## continue onto the far slab.
func _walk_forward(player: CharacterBody3D, ticks: int) -> void:
	Input.action_press(&"move_forward")
	for _i: int in ticks:
		player.call(&"_apply_gravity", PHYSICS_DELTA)
		player.call(&"_apply_horizontal_movement", PHYSICS_DELTA, true, false, false)
		player.call(&"_apply_step_up", PHYSICS_DELTA)
		player.move_and_slide()
	Input.action_release(&"move_forward")


func _check_climbs_low_lip() -> void:
	var player: CharacterBody3D = await _spawn_and_settle(0.0)
	check(bool(player.call(&"is_on_floor")), "settles onto the near-ground lane before walking")

	_walk_forward(player, WALK_TICKS)

	var pos: Vector3 = player.global_position
	check(pos.z < -0.5, "walked past the seam onto the far slab (z=%.2f)" % pos.z)
	check(pos.y > LOW_LIP_M - 0.1 and pos.y < LOW_LIP_M + 0.2,
		"landed at the lip's own height, not floating at a flat step_height (y=%.2f, lip=%.2f)" % [
			pos.y, LOW_LIP_M
		])
	check(bool(player.call(&"is_on_floor")), "still grounded after stepping up")

	player.queue_free()
	await physics_frame


func _check_refuses_tall_lip() -> void:
	var player: CharacterBody3D = await _spawn_and_settle(20.0)
	check(bool(player.call(&"is_on_floor")), "settles onto the near-ground lane before walking")

	_walk_forward(player, WALK_TICKS)

	var pos: Vector3 = player.global_position
	check(pos.z > -0.5, "stopped at the seam instead of climbing a wall taller than step_height (z=%.2f)" % pos.z)
	# Not y < step_height's own "scuff" allowance: a capsule's rounded bottom naturally rides a short
	# way up any corner under ordinary move_and_slide() collision response (the exact behaviour
	# F-136's own finding text names — "a capsule will scuff over a very small lip because its bottom
	# is round"), independent of _apply_step_up(). What must hold is that it never MOUNTS the wall —
	# nowhere near TALL_LIP_M's own height.
	check(pos.y < TALL_LIP_M - 0.2,
		"never climbed anywhere near the tall slab's own height (y=%.2f, lip=%.2f)" % [pos.y, TALL_LIP_M])

	player.queue_free()
	await physics_frame


## Regression guard for the check itself: with step_height forced to 0, the SAME low lip that the
## first case climbs must now stop the player, proving this suite would actually fail if
## _apply_step_up() stopped doing anything rather than passing by construction.
func _check_disabled_step_height_gets_stuck() -> void:
	var player: CharacterBody3D = await _spawn_and_settle(0.0)
	player.set(&"step_height", 0.0)

	_walk_forward(player, WALK_TICKS)

	var pos: Vector3 = player.global_position
	check(pos.z > -0.5, "with step_height=0 the same lip now blocks (z=%.2f) — proves the case above tests the real fix" % pos.z)

	player.queue_free()
	await physics_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
