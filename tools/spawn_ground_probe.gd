extends SceneTree

## "Can a player actually stand where they spawn?" — the question that owned no check until F-056.
##
##     .agent/bin/agent godot --script tools/spawn_ground_probe.gd
##
## playtest_hollow_check validates 323 colliders, grid sanity and facet angles, and verify_setup's
## physics assertions run against a FLAT FIXTURE level. Both passed while the real map was a hole you
## fell through for eternity. This drops the real player into the real main scene and watches.

## The MAP, not `run/main_scene` (F-564). Since MENU-3's cutover the main scene is the front
## end, so loading that setting and treating the result as a level boots a menu. `ProbeScene`
## asks the front end what world it bypasses into (F-561).
const ProbeScene := preload("res://tools/probe_scene.gd")


const SETTLE_STEPS: int = 60


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load(ProbeScene.shipped_map_path()) as PackedScene
	if packed == null:
		push_error("FAIL: no main scene")
		quit(1)
		return
	var level: Node = packed.instantiate()
	root.add_child(level)
	root.get_tree().current_scene = level
	await process_frame

	var player: CharacterBody3D = null
	for node: Node in level.get_children():
		if node is CharacterBody3D:
			player = node as CharacterBody3D
			break
	if player == null:
		push_error("FAIL: the level has no Player body for PlayerNet to spawn from")
		quit(1)
		return

	var start: float = player.global_position.y
	for _i: int in SETTLE_STEPS:
		await physics_frame

	var landed: bool = player.is_on_floor()
	var y: float = player.global_position.y
	var failures: int = 0

	print("\nspawn start y = %.3f" % start)
	print("after %d physics steps: y = %.3f  on_floor = %s" % [SETTLE_STEPS, y, landed])

	if not landed:
		push_error("FAIL: the player never reached the floor — it is falling through the map")
		failures += 1
	if y < start - 2.0:
		push_error("FAIL: the player fell %.1f m below its spawn" % (start - y))
		failures += 1

	# The ground the player is standing on must also exist under every peer slot PlayerNet fans out
	# to, or the host lands and joining clients do not.
	var space: PhysicsDirectSpaceState3D = (level as Node3D).get_world_3d().direct_space_state
	var exclude: Array[RID] = [player.get_rid()]
	var base: Vector3 = player.global_position
	for offset: Vector3 in [Vector3.ZERO, Vector3(1.6, 0, 0), Vector3(-1.6, 0, 0),
			Vector3(0, 0, 1.6), Vector3(0, 0, -1.6)]:
		var q: Vector3 = base + offset
		var params := PhysicsRayQueryParameters3D.create(q + Vector3.UP * 50.0, q + Vector3.DOWN * 50.0)
		params.exclude = exclude
		var hit: Dictionary = space.intersect_ray(params)
		if hit.is_empty():
			push_error("FAIL: peer slot x%+.1f z%+.1f has no ground beneath it" % [offset.x, offset.z])
			failures += 1
		else:
			print("  peer slot x%+.1f z%+.1f  ground y=%.3f (%s)" % [
				offset.x, offset.z, (hit.get("position") as Vector3).y, (hit.get("collider") as Node).name])

	print("\nSPAWN_GROUND_PROBE failures=%d" % failures)
	quit(1 if failures > 0 else 0)
