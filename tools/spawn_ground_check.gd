extends SceneTree

## F-324 proof — a player spawned into a procedurally generated island stands on ground that
## already exists, instead of falling through terrain that has not finished cooking yet.
##
##   .agent/bin/agent godot --script tools/spawn_ground_check.gd
##
## The bug this pins: `ChunkStreamer` is lazy on purpose — ring evaluation every 0.2 s, mesh
## generation on `WorkerThreadPool`, `ConcavePolygonShape3D` cooking trickled through a 4 ms/frame
## slice. `ProceduralWorld` used to place the Player and call `set_anchors()`, which SCHEDULES that
## work rather than waiting for it, so for the first ~40 frames there was no collider anywhere near
## the spawn. Headless it survived on luck (a 1.1 m fall inside 1.2 m of clearance); on a real boot,
## where the first second is the worst frame time in the session, the same fall is metres deep — and
## the terrain collider has no backface collision, so a body that gets under the mesh falls forever.
##
## What is asserted here is therefore a TIMING-FREE invariant, deliberately: not "the player happened
## to land", which is what the old code also did in this harness, but "a collider is already under
## the spawn point when `_ready()` returns". A check that only watched the player land would pass on
## the broken build.

const WorldScene := preload("res://levels/procedural_island.tscn")

## Two islands with quite different shore geometry, so the assertion is about the seam and not about
## one lucky seed. SEED_A is the one F-324 was measured on.
const SEED_A: int = 20260819
const SEED_B: int = 987654321
## A third, only used for the rebuild path.
const SEED_REBUILD: int = 4242

## How far under the terrain the void-recovery test drops the player. Well past
## `ProceduralWorld.VOID_DEPTH_M`, and past anything a real fall would reach before being caught.
const VOID_DROP_M: float = 40.0

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var game_state: Node = root.get_node_or_null(^"GameState")
	check(game_state != null, "GameState autoload exists")
	if game_state == null:
		return finish()

	for seed_value: int in [SEED_A, SEED_B]:
		await _check_boot(game_state, seed_value)

	await _check_offset_slots(game_state)
	await _check_void_recovery(game_state)
	await _check_rebuild(game_state)

	finish()


# ── the boot seam ─────────────────────────────────────────────────────────────────────────────────


## The whole point of F-324, asserted on the frame the world finishes building — before any
## `_process()` has run, so nothing here can be satisfied by the lazy path catching up.
func _check_boot(game_state: Node, seed_value: int) -> void:
	var world: Node3D = await _build_world(game_state, seed_value)
	var label: String = "seed %d" % seed_value

	var spawn: Vector3 = world.get(&"spawn_position")
	var streamer: Node = world.get(&"streamer")
	check(streamer != null, "%s: the world built a ChunkStreamer" % label)
	if streamer == null:
		_teardown(world)
		return

	# Guarded rather than called blind, so that on a build WITHOUT the fix this reports a missing
	# seam and carries on to the behavioural assertions below, instead of aborting the section on a
	# nonexistent method and taking the interesting failures with it.
	if not streamer.has_method(&"has_ground_at"):
		check(false, "%s: ChunkStreamer exposes has_ground_at() — F-324's seam is absent" % label)
	else:
		# THE assertion. `_ready()` has returned; no frame has been processed since.
		check(bool(streamer.call(&"has_ground_at", spawn)),
			"%s: the spawn chunk has a cooked collider the instant the world is built" % label)
		# And its neighbours, so a spawn on a chunk seam is standing on both sides of it.
		check(bool(streamer.call(&"has_ground_at", spawn, 1)),
			"%s: so do all eight neighbouring chunks — a seam spawn is covered" % label)

	# `has_ground_at()` proves the streamer cooked a shape. This proves the SPACE can see it on the
	# same frame — which is what `_standing_position()`'s downward ray depends on, and the one part
	# of the fix that is a claim about Jolt rather than about this code.
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	var probe := PhysicsRayQueryParameters3D.create(
		spawn + Vector3.UP * 4.0, spawn + Vector3.DOWN * 8.0)
	probe.collision_mask = 2                    # PlacementValidator.TERRAIN_LAYER
	check(not space.intersect_ray(probe).is_empty(),
		"%s: a downward ray at the spawn hits terrain immediately after the build" % label)

	var player: Node3D = world.get_node_or_null(^"Player") as Node3D
	check(player != null, "%s: the world built a Player" % label)
	if player == null:
		_teardown(world)
		return
	var start_above: float = player.global_position.y - float(
		world.call(&"height_at", spawn.x, spawn.z))
	check(start_above > -0.25,
		"%s: the player starts on the surface, not inside it (%.2f m above)" % [label, start_above])
	check(start_above < 0.5,
		"%s: and is placed ON it rather than dropped from clearance (%.2f m above)" % [
			label, start_above])

	# Then watch it settle. The surface it must never go under is the pure heightmap's, which is
	# exactly what the LOD0 collider is cooked from.
	var lowest: float = INF
	var deepest_below: float = 0.0
	var grounded_frame: int = -1
	for frame: int in range(180):
		await physics_frame
		var here: Vector3 = player.global_position
		var surface: float = float(world.call(&"height_at", here.x, here.z))
		lowest = minf(lowest, here.y)
		deepest_below = maxf(deepest_below, surface - here.y)
		if grounded_frame < 0 and bool(player.call(&"is_on_floor")):
			grounded_frame = frame

	# Six ticks is a tenth of a second — the settle from `SPAWN_CLEARANCE_M`, and nothing like the
	# ~21 ticks the old 1.2 m drop took or the ~40 the unprimed fall took.
	check(grounded_frame >= 0 and grounded_frame <= 6,
		"%s: on the floor within a tenth of a second (was frame %d)" % [label, grounded_frame])
	check(lowest > float(world.call(&"height_at", spawn.x, spawn.z)) - 0.5,
		"%s: and never dipped through the ground while settling (lowest %.2f m)" % [label, lowest])
	check(deepest_below < 0.5,
		"%s: never sank more than 0.5 m below the surface (deepest %.2f m)" % [
			label, deepest_below])
	check(int(world.get(&"_void_recoveries")) == 0,
		"%s: and never needed the void net to save it" % label)
	check(bool(streamer.call(&"has_ground_at", spawn)) if streamer.has_method(&"has_ground_at")
		else false, "%s: the spawn still has ground under it once everything has settled" % label)

	_teardown(world)


# ── the co-op spawn cluster ───────────────────────────────────────────────────────────────────────


## `PlayerNet.SPAWN_OFFSETS` fans six players up to 1.6 m sideways off one captured transform, and
## used to carry slot one's HEIGHT to all six. `standing_position_at()` is the seam that fixes it, so
## assert its contract directly: every offset lands on the ground under THAT offset, not under the
## spawn point.
func _check_offset_slots(game_state: Node) -> void:
	var world: Node3D = await _build_world(game_state, SEED_A)
	var spawn: Vector3 = world.get(&"spawn_position")

	# Copied by value from PlayerNet — the same reason that file duplicates its group names: the
	# table IS the contract, and a change on either side should fail loudly here.
	var offsets: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0), Vector3(1.6, 0.0, 0.0), Vector3(-1.6, 0.0, 0.0),
		Vector3(0.0, 0.0, 1.6), Vector3(0.0, 0.0, -1.6), Vector3(1.6, 0.0, 1.6),
	]
	if not world.has_method(&"standing_position_at"):
		check(false, "co-op slots: the world exposes standing_position_at() — F-324's seam is absent")
		_teardown(world)
		return

	var worst: float = 0.0
	var spread: float = 0.0
	for offset: Vector3 in offsets:
		var asked: Vector3 = spawn + offset
		var placed: Vector3 = world.call(&"standing_position_at", asked)
		var surface: float = float(world.call(&"height_at", asked.x, asked.z))
		worst = maxf(worst, absf(placed.y - surface))
		spread = maxf(spread, absf(placed.y - spawn.y))

	check(worst < 0.35,
		"co-op slots: every offset is placed on its own ground (worst error %.2f m)" % worst)
	check(spread > 0.0,
		"co-op slots: and the heights genuinely differ per slot — not all six on slot one's y")

	_teardown(world)


# ── the net under it ──────────────────────────────────────────────────────────────────────────────


## Priming closes the boot hole, but a collider is a per-peer, per-frame fact and any future path
## can reopen it. Drop a player far under the island and prove the world pulls it back out.
func _check_void_recovery(game_state: Node) -> void:
	var world: Node3D = await _build_world(game_state, SEED_A)
	var player: Node3D = world.get_node_or_null(^"Player") as Node3D
	if player == null:
		check(false, "void recovery: no Player to drop")
		_teardown(world)
		return
	await physics_frame
	await physics_frame

	var here: Vector3 = player.global_position
	var surface: float = float(world.call(&"height_at", here.x, here.z))
	player.global_position = Vector3(here.x, surface - VOID_DROP_M, here.z)
	(player as CharacterBody3D).velocity = Vector3.ZERO

	# One check interval is 0.5 s; give it two, plus slack for the settle after the lift.
	var recovered: bool = false
	for _frame: int in range(120):
		await physics_frame
		if player.global_position.y > surface - 1.0:
			recovered = true
			break

	check(recovered, "void recovery: a player %.0f m under the terrain is lifted back to the surface"
		% VOID_DROP_M)
	check(int(world.get(&"_void_recoveries")) == 1,
		"void recovery: exactly one rescue was recorded (%d)" % int(world.get(&"_void_recoveries")))
	check(bool(player.call(&"is_on_floor")) or player.global_position.y > surface - 1.0,
		"void recovery: and it is standing on the island afterwards")

	_teardown(world)


# ── the rebuild path ──────────────────────────────────────────────────────────────────────────────


## `rebuild_for_seed()` moves the local player to a NEW island's shore. Same hole, same fix.
func _check_rebuild(game_state: Node) -> void:
	var world: Node3D = await _build_world(game_state, SEED_A)
	var player: Node3D = world.get_node_or_null(^"Player") as Node3D
	await physics_frame

	world.call(&"rebuild_for_seed", SEED_REBUILD)
	var streamer: Node = world.get(&"streamer")
	var spawn: Vector3 = world.get(&"spawn_position")
	check(streamer.has_method(&"has_ground_at") and bool(streamer.call(&"has_ground_at", spawn)),
		"rebuild: the new island's spawn has a collider before the rebuild call returns")

	if player != null and is_instance_valid(player):
		var deepest_below: float = 0.0
		for _frame: int in range(120):
			await physics_frame
			var here: Vector3 = player.global_position
			deepest_below = maxf(
				deepest_below, float(world.call(&"height_at", here.x, here.z)) - here.y)
		check(deepest_below < 0.5,
			"rebuild: the moved player never sank below the new surface (deepest %.2f m)"
				% deepest_below)

	_teardown(world)


# ── harness ───────────────────────────────────────────────────────────────────────────────────────


func _build_world(game_state: Node, seed_value: int) -> Node3D:
	# Same two lines `tools/procedural_world_check.gd` uses: set the value and mark it ready, so
	# `ensure_seed()` inside the world adopts THIS seed instead of drawing its own.
	game_state.set(&"run_seed", seed_value)
	game_state.set("_seed_ready", true)
	var world: Node3D = WorldScene.instantiate() as Node3D
	# add_child runs `_ready()` synchronously — every assertion above about "the instant the world
	# is built" is made on the other side of THIS line, with no frame in between.
	root.add_child(world)
	return world


func _teardown(world: Node3D) -> void:
	root.remove_child(world)
	world.queue_free()


func check(condition: bool, label: String) -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		failures += 1
		print("  FAIL  %s" % label)


func finish() -> void:
	print("")
	if failures == 0:
		print("spawn_ground_check: all checks passed")
	else:
		print("spawn_ground_check: %d FAILURE(S)" % failures)
	quit(1 if failures > 0 else 0)
