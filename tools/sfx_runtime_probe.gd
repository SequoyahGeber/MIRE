extends SceneTree

## End-to-end proof that the sound effects fire in a RUNNING game, not merely
## that they are wired. `tools/sfx_check.gd` drives handlers directly and proves
## the plumbing; this boots the real world with a real session, lets it run, and
## reads `SfxDirector.play_counts` to see what the game actually made a noise
## about.
##
## The distinction matters. Every failure this catches looks fine to the static
## check: a footstep driver whose grounded test is always false, an ambient
## scatterer whose biome lookup throws, an enemy poll that never finds the group.
## All of those pass `sfx_check` and produce a silent game.
##
##   .agent/bin/agent godot --script tools/sfx_runtime_probe.gd -- host
##
## Reports a per-cue tally and fails if the categories that should ALWAYS produce
## sound in a live world produced none.

const RUN_SECONDS: float = 22.0
## Drive the player in a slow circle so the footstep driver has distance to
## accumulate — a probe that stands still proves nothing about steps.
const WALK_SPEED: float = 3.2
const WALK_RADIUS: float = 9.0

var failures: int = 0
var director: Node
var elapsed: float = 0.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	director = root.get_node_or_null(^"SfxDirector")
	if director == null:
		print("FAIL: SfxDirector is not registered")
		print("\nSFX_RUNTIME_PROBE failures=1")
		quit(1)
		return

	print("== running the world for %.0f s ==" % RUN_SECONDS)
	# `process_frame` carries no delta, so the wall clock is the clock here. That
	# is correct for a probe: it should run for the time a human would wait.
	var body: Node3D = null
	var started_ms: int = Time.get_ticks_msec()
	var last_ms: int = started_ms
	while elapsed < RUN_SECONDS:
		await process_frame
		var now_ms: int = Time.get_ticks_msec()
		var delta: float = float(now_ms - last_ms) / 1000.0
		last_ms = now_ms
		elapsed = float(now_ms - started_ms) / 1000.0
		if body == null or not is_instance_valid(body):
			body = _local_body()
			continue
		_walk(body, delta)

	print("\n== what made a noise ==")
	var counts: Dictionary = director.play_counts
	var by_system: Dictionary[StringName, int] = {}
	var names: Array = counts.keys()
	names.sort()
	for cue: StringName in names:
		var system: StringName = &"?"
		var row: Variant = load("res://autoload/sfx_catalogue.gd").CUES.get(cue)
		if row is Array and (row as Array).size() >= 2:
			system = (row as Array)[1]
		by_system[system] = int(by_system.get(system, 0)) + int(counts[cue])
		print("  %-24s %s  x%d" % [cue, system, counts[cue]])

	print("\n== by system ==")
	for system: StringName in by_system:
		print("  %-14s %d" % [system, by_system[system]])

	# A live world with a walking player must produce these. Anything else is
	# situational — no enemy may spawn in 22 seconds, nobody builds anything —
	# and asserting on it would make this probe flaky rather than useful.
	_require(counts.size() > 0, "some sound played at all")
	_require(int(by_system.get(&"ambient", 0)) > 0,
		"the world made ambient noise (%d)" % int(by_system.get(&"ambient", 0)))
	# Only assert on footsteps if there was ground to walk on. A headless boot
	# that never streams collision is a world-gen timing question, not an audio
	# one, and failing here for it would make this probe a liar.
	if _local_body() == null:
		print("NOTE: no local player body spawned — movement not asserted")
	elif grounded_frames < 60:
		print("NOTE: terrain collision never loaded (%d grounded frames) — "
			% grounded_frames + "movement not asserted")
	else:
		_require(int(by_system.get(&"movement", 0)) > 0,
			"walking on real terrain produced footsteps (%d)"
			% int(by_system.get(&"movement", 0)))

	print("\nSFX_RUNTIME_PROBE failures=%d" % failures)
	quit(1 if failures > 0 else 0)


func _require(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: %s" % msg)
	else:
		failures += 1
		print("FAIL: %s" % msg)


func _local_body() -> Node3D:
	var net: Node = root.get_node_or_null(^"PlayerNet")
	if net == null or not net.has_method(&"player_for"):
		return null
	return net.player_for(get_multiplayer().get_unique_id()) as Node3D


## Teleport rather than drive input: this probe is about whether MOTION produces
## sound, and going through the controller's input path would make it a test of
## the input map instead. The footstep driver reads position, so position is
## what this moves.
##
## The body is also pinned to the terrain every frame. Without that it simply
## falls: a headless boot reaches the world before chunk collision is streamed,
## and the first run of this probe found the player at y = -64 and dropping,
## with `is_on_floor()` false forever — which read as "footsteps are broken"
## when the real answer was "there is no floor yet".
func _walk(body: Node3D, delta: float) -> void:
	var angle: float = elapsed * (WALK_SPEED / WALK_RADIUS)
	var origin: Vector3 = body.global_position
	var target := Vector3(cos(angle) * WALK_RADIUS, origin.y, sin(angle) * WALK_RADIUS)
	var moved: Vector3 = origin.lerp(target, clampf(delta * 4.0, 0.0, 1.0))
	body.global_position = _pinned_to_ground(body, moved)


## Snap onto whatever terrain is under (or above) the point, if any is loaded.
## Searches from well overhead so it finds ground even after a long fall.
func _pinned_to_ground(body: Node3D, point: Vector3) -> Vector3:
	var world: World3D = body.get_world_3d()
	if world == null:
		return point
	var from := Vector3(point.x, 200.0, point.z)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 500.0)
	if body is CollisionObject3D:
		query.exclude = [body.get_rid()]
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		grounded_frames = 0
		return point
	grounded_frames += 1
	return Vector3(point.x, float(hit["position"].y) + 0.05, point.z)


var grounded_frames: int = 0
