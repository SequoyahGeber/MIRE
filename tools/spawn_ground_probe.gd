extends SceneTree

## Diagnostic for "I fall through the map on join" (F-056).
##
##     .agent/bin/agent godot --script tools/spawn_ground_probe.gd
##
## PlayerNet treats the level's hand-placed `Player` body as the SPAWN TRANSFORM and fans peers out
## from it by PlayerNet.SPAWN_OFFSETS. c187ede replaced the Hollow's flat floor with a heightfield
## carrying 2.67 m of relief, so a spawn authored against the old floor can now sit *inside* or below
## the new surface — and a CharacterBody3D that starts inside collision is pushed through rather than
## resting on it.
##
## For each spawn slot this casts DOWN from high above to find the true surface, then reports the
## signed gap. Negative gap = spawn is buried = you fall through.

const PROBE_HEIGHT: float = 100.0
const PROBE_DEPTH: float = 400.0
## Mirrors PlayerNet.SPAWN_OFFSETS (read there, not guessed: the LAN run showed 0, +1.6, -1.6 on X).
const SLOTS: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0), Vector3(1.6, 0.0, 0.0), Vector3(-1.6, 0.0, 0.0),
	Vector3(0.0, 0.0, 1.6), Vector3(0.0, 0.0, -1.6),
]

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load(str(ProjectSettings.get_setting("application/run/main_scene", "")))
	if packed == null:
		push_error("FAIL: no main scene")
		quit(1)
		return
	var level: Node = packed.instantiate()
	root.add_child(level)
	root.get_tree().current_scene = level
	for _i: int in 24:
		await process_frame
	await physics_frame
	await physics_frame

	var space: PhysicsDirectSpaceState3D = (level as Node3D).get_world_3d().direct_space_state
	var spawn: Node3D = _level_player(level)
	if spawn == null:
		push_error("FAIL: level has no hand-placed Player to use as a spawn point")
		quit(1)
		return

	var base: Vector3 = spawn.global_position
	print("\nspawn transform (PlayerNet reads this): (%.3f, %.3f, %.3f)" % [base.x, base.y, base.z])
	print("%-18s %10s %10s %10s   verdict" % ["slot", "spawn y", "ground y", "gap"])

	for offset: Vector3 in SLOTS:
		var p: Vector3 = base + offset
		var hit: Dictionary = _cast(space, p + Vector3.UP * PROBE_HEIGHT, p + Vector3.DOWN * PROBE_DEPTH)
		if hit.is_empty():
			print("%-18s %10.3f %10s %10s   NO GROUND ANYWHERE" % [
				"x%+.1f z%+.1f" % [offset.x, offset.z], p.y, "-", "-"])
			_failures += 1
			continue
		var gy: float = (hit.get("position") as Vector3).y
		var gap: float = p.y - gy
		var verdict: String = "ok"
		if gap < -0.01:
			verdict = "BURIED — falls through"
			_failures += 1
		elif gap > 3.0:
			verdict = "high drop (%.1f m)" % gap
		print("%-18s %10.3f %10.3f %10.3f   %s" % [
			"x%+.1f z%+.1f" % [offset.x, offset.z], p.y, gy, gap, verdict])

	print("\nSPAWN_GROUND_PROBE slots=%d failures=%d" % [SLOTS.size(), _failures])
	quit(1 if _failures > 0 else 0)


## The level's own Player body — the one PlayerNet consumes as a spawn point and then frees.
func _level_player(level: Node) -> Node3D:
	for node: Node in level.find_children("*", "CharacterBody3D", true, false):
		return node as Node3D
	for node: Node in level.find_children("Player*", "Node3D", true, false):
		return node as Node3D
	return null


func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	return space.intersect_ray(params)
