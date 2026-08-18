extends SceneTree

## Verify the Hollowmere map builds, holds a player up, and is walkable.
##
## Run with:  .agent/bin/agent godot --script tools/hollowmere_check.gd
##
## The layout generator already proves reachability against its own heightfield.
## This proves the *engine* agrees: that the terrain collider Godot builds from
## that same field is where the generator thought the ground was, and that a ray
## dropped anywhere sensible lands on it. A map that validates in Python and has
## no floor in Godot would pass every check written on one side of the fence.

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const LAYOUT_PATH: String = "res://world/gen/layouts/hollowmere.json"

var failures: Array[String] = []


func _init() -> void:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	if packed == null:
		failures.append("could not load %s" % SCENE_PATH)
		_finish()
		return
	var level := packed.instantiate()
	root.add_child(level)
	for frame in 16:
		await process_frame
		await physics_frame

	var world := level.get_node_or_null("World")
	if world == null:
		failures.append("scene has no World node")
		_finish()
		return

	var layout: Dictionary = _layout()
	print("HOLLOWMERE_BUILD terrain_tris=%d props=%d multimeshes=%d colliders=%d water=%d" % [
		int(world.get("terrain_triangles")), int(world.get("prop_count")),
		int(world.get("multimesh_count")), int(world.get("collider_count")),
		int(world.get("water_surfaces"))
	])
	if int(world.get("terrain_triangles")) < 30000:
		failures.append("terrain built only %d triangles" % int(world.get("terrain_triangles")))
	if int(world.get("prop_count")) < 800:
		failures.append("only %d props built" % int(world.get("prop_count")))

	var undergrowth := level.get_node_or_null("Undergrowth")
	if undergrowth != null:
		print("HOLLOWMERE_FLORA placed=%d multimeshes=%d" % [
			int(undergrowth.get("placed_count")), int(undergrowth.get("multimesh_count"))
		])
		if int(undergrowth.get("placed_count")) < 4000:
			failures.append("undergrowth placed only %d plants" % int(undergrowth.get("placed_count")))

	_probe_ground(level, world, layout)
	_check_markers(level, layout)
	level.queue_free()
	_finish()


func _layout() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_PATH))
	return parsed as Dictionary if parsed is Dictionary else {}


## Drop rays over the whole map and compare what physics reports against what the
## layout's own heightfield says. This is the seam where a map most often lies.
func _probe_ground(level: Node, world: Node, layout: Dictionary) -> void:
	var space := (level as Node3D).get_world_3d().direct_space_state
	var bound := float(layout.get("bound", 100.0))
	var misses := 0
	var worst := 0.0
	var samples := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 99001
	for attempt in 900:
		var x := rng.randf_range(-bound + 6.0, bound - 6.0)
		var z := rng.randf_range(-bound + 6.0, bound - 6.0)
		if Vector2(x, z).length() > bound - 6.0:
			continue
		samples += 1
		var expected := float(world.call("height_at", x, z))
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, expected + 60.0, z), Vector3(x, expected - 60.0, z)
		)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			misses += 1
			continue
		# A ray dropped from 60 m up hits the tree before it hits the hill. Props
		# are grouped, so skip those samples rather than reporting the canopy as a
		# six-metre error in the terrain collider.
		var collider := hit.get("collider") as Node
		if collider != null and collider.is_in_group(&"authored_world_prop"):
			samples -= 1
			continue
		worst = maxf(worst, absf((hit["position"] as Vector3).y - expected))
	print("HOLLOWMERE_GROUND samples=%d misses=%d worst_delta=%.3f m" % [samples, misses, worst])
	if misses > 0:
		failures.append("%d of %d ground probes hit nothing — the map has holes" % [misses, samples])
	if worst > 1.5:
		failures.append("collision is %.2f m from the authored height somewhere" % worst)


func _check_markers(level: Node, layout: Dictionary) -> void:
	var markers := level.get_tree().get_nodes_in_group(&"authored_world_marker")
	var expected: int = (layout.get("markers", []) as Array).size()
	if markers.size() != expected:
		failures.append("%d markers in scene, layout lists %d" % [markers.size(), expected])
	var kinds: Dictionary = {}
	for marker in markers:
		var kind := String((marker as Node).get_meta(&"kind", ""))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	print("HOLLOWMERE_MARKERS ", kinds)
	for required in ["spawn", "extraction", "objective", "enemy_nest", "landmark"]:
		if not kinds.has(required):
			failures.append("no %s marker in the map" % required)


func _finish() -> void:
	if failures.is_empty():
		print("HOLLOWMERE_CHECK PASS")
	else:
		print("HOLLOWMERE_CHECK FAIL (%d)" % failures.size())
		for failure in failures:
			print("  ", failure)
	quit(0 if failures.is_empty() else 1)
