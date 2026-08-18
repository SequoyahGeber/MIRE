extends SceneTree

## What the GPU is actually asked to draw, counted from the built scene rather than guessed.
##
##   .agent/bin/agent godot --script tools/render_census.gd
##
## Headless on purpose. A draw call is a (visual instance, surface) pair, and both of those are
## properties of the tree — they do not need a framebuffer to count. That makes this runnable in
## the same loop as every other check, unlike tools/perf_probe.gd which needs a display and a
## quiet machine (F-066). Use the probe for milliseconds; use this for the structure that
## produces them, and for regressions in it.
##
## The shadow multiplier is the part that surprises people: a DirectionalLight3D with 4 PSSM
## splits re-renders every shadow-casting surface once per split, so a scene's real draw count is
## roughly `opaque + casters * cascades`. That is why F-098 measured ~3.3k of 5.4k draws in the
## shadow pass.

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
## `directional_shadow_blend_splits` makes casters near a cascade boundary render into both, so
## the shadow pass draws somewhat more than one copy per caster. A flat surcharge is a coarse
## stand-in for a boundary test, and it is deliberately on the pessimistic side: this number
## should never flatter a change.
const SPLIT_BLEND_OVERLAP: float = 1.3

var failures: Array[String] = []


func _init() -> void:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	if packed == null:
		failures.append("could not load %s" % SCENE_PATH)
		_finish()
		return
	var level := packed.instantiate()
	root.add_child(level)
	current_scene = level
	for _frame in 24:
		await process_frame
		await physics_frame

	print("\n=== MIRE render census — %s ===" % SCENE_PATH)
	print("Godot %s | %s" % [Engine.get_version_info()["string"], OS.get_name()])

	var stats := _walk(level)
	_report(stats, level)
	_finish()


## One pass over the tree, bucketed by what each visual instance costs.
func _walk(node: Node) -> Dictionary:
	var stats := {
		"mesh_instances": 0,
		"multimesh_instances": 0,
		"surfaces": 0,          # opaque draw calls: one per (instance, surface)
		"mm_instances_total": 0, # copies inside MultiMeshes
		"tris_unique": 0,        # triangles in distinct meshes, counted once each
		"tris_drawn": 0,         # triangles the GPU walks per opaque pass
		"casters": 0,            # surfaces that also render into every shadow cascade
		"caster_tris": 0,
		"with_lod_range": 0,     # instances carrying a visibility_range_end
		"meshes_with_lod": 0,    # distinct meshes carrying real LOD levels
		"meshes_seen": 0,
	}
	var seen_meshes: Dictionary = {}
	_walk_into(node, stats, seen_meshes)
	stats["by_parent"] = _by_parent(node)
	return stats


func _walk_into(node: Node, stats: Dictionary, seen: Dictionary) -> void:
	var geometry := node as GeometryInstance3D
	if geometry != null and geometry.visible:
		var mesh: Mesh = null
		var copies := 1
		if node is MultiMeshInstance3D:
			var multimesh: MultiMesh = (node as MultiMeshInstance3D).multimesh
			if multimesh != null:
				mesh = multimesh.mesh
				copies = multimesh.instance_count
				stats["multimesh_instances"] += 1
				stats["mm_instances_total"] += copies
		elif node is MeshInstance3D:
			mesh = (node as MeshInstance3D).mesh
			stats["mesh_instances"] += 1
		if mesh != null:
			var surfaces := mesh.get_surface_count()
			var tris := _triangles(mesh)
			stats["surfaces"] += surfaces
			stats["tris_drawn"] += tris * copies
			var key := mesh.get_instance_id()
			if not seen.has(key):
				seen[key] = true
				stats["meshes_seen"] += 1
				stats["tris_unique"] += tris
				if _has_lod(mesh):
					stats["meshes_with_lod"] += 1
			if geometry.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				stats["casters"] += surfaces
				stats["caster_tris"] += tris * copies
			if geometry.visibility_range_end > 0.0:
				stats["with_lod_range"] += 1
	for child in node.get_children():
		_walk_into(child, stats, seen)


## Triangles in a mesh, from the surface arrays — `get_faces()` allocates the whole soup.
func _triangles(mesh: Mesh) -> int:
	var total := 0
	for surface in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var indices: int = mesh.surface_get_array_index_len(surface)
		var verts: int = mesh.surface_get_array_len(surface)
		total += int(indices if indices > 0 else verts) / 3
	return total


## Does this mesh carry LOD levels the renderer can drop to? Imported meshes get them from the
## import pipeline; a mesh built at runtime with `add_surface_from_arrays` never has any.
##
## There is no scripting getter for a surface's LODs, so this reads `_surfaces` — the same
## property ResourceSaver serialises. Each entry is a Dictionary whose "lods" key holds the
## {screen_ratio: PackedInt32Array} the renderer switches between.
func _has_lod(mesh: Mesh) -> bool:
	var array_mesh := mesh as ArrayMesh
	if array_mesh == null:
		return false
	var surfaces: Variant = array_mesh.get("_surfaces")
	if not surfaces is Array:
		return false
	for entry: Variant in surfaces as Array:
		if entry is Dictionary and not ((entry as Dictionary).get("lods", []) as Array).is_empty():
			return true
	return false


## Draw calls attributed to the subtree that owns them, so a regression names its own system.
func _by_parent(level: Node) -> Dictionary:
	var out: Dictionary = {}
	for group: Array in [
		["terrain+props", level.get_node_or_null(^"World")],
		["undergrowth", level.get_node_or_null(^"Undergrowth")],
	]:
		var node: Node = group[1]
		if node == null:
			continue
		for child in node.get_children():
			var sub := {"surfaces": 0, "instances": 0}
			_count_surfaces(child, sub)
			if sub["surfaces"] > 0:
				out["%s/%s" % [group[0], child.name]] = sub
	return out


func _count_surfaces(node: Node, into: Dictionary) -> void:
	var mesh: Mesh = null
	if node is MultiMeshInstance3D:
		var multimesh: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if multimesh != null:
			mesh = multimesh.mesh
			into["instances"] += multimesh.instance_count
	elif node is MeshInstance3D:
		mesh = (node as MeshInstance3D).mesh
		into["instances"] += 1
	if mesh != null:
		into["surfaces"] += mesh.get_surface_count()
	for child in node.get_children():
		_count_surfaces(child, into)


## What a camera standing IN the world actually submits.
##
## Everything above counts the scene as built, which is the right number for "how much geometry
## exists" and the wrong one for "how much is drawn": `visibility_range` culling happens in the
## RenderingServer, so a range that removes 90% of the map is invisible to a tree walk. This
## samples player-height camera positions on a grid across the island and counts, per position,
## the instances whose own range still reaches — no frustum, deliberately, because a 360-degree
## count is the honest before/after comparison and modelling the frustum only adds a way to be
## wrong. Reported as median and worst over the samples.
func _in_range_draws(level: Node, samples: Array[Vector3], shadow_distance: float) -> Dictionary:
	var instances: Array[Dictionary] = []
	_collect_ranged(level, instances)
	var opaque_counts: Array[int] = []
	var shadow_counts: Array[int] = []
	for eye: Vector3 in samples:
		var opaque: int = 0
		var shadow: int = 0
		for entry: Dictionary in instances:
			var distance: float = (entry["pos"] as Vector3).distance_to(eye)
			var range_end: float = entry["range"]
			if range_end > 0.0 and distance > range_end:
				continue
			var surfaces: int = entry["surfaces"]
			opaque += surfaces
			# A caster is in the shadow pass only inside the light's own max distance, and there
			# it lands in ONE cascade, not all of them — PSSM splits are nested slices of the
			# view frustum, so a rock at 70 m is rendered by the far cascade and by no other.
			# Blend splits make objects near a boundary render twice, which is what the overlap
			# factor pays for.
			if entry["casts"] and distance <= shadow_distance:
				shadow += surfaces
		opaque_counts.append(opaque)
		shadow_counts.append(int(round(float(shadow) * SPLIT_BLEND_OVERLAP)))
	opaque_counts.sort()
	shadow_counts.sort()
	var mid: int = opaque_counts.size() / 2
	return {
		"opaque_median": opaque_counts[mid] if not opaque_counts.is_empty() else 0,
		"opaque_worst": opaque_counts[-1] if not opaque_counts.is_empty() else 0,
		"shadow_median": shadow_counts[mid] if not shadow_counts.is_empty() else 0,
		"shadow_worst": shadow_counts[-1] if not shadow_counts.is_empty() else 0,
		"samples": samples.size(),
	}


func _shadow_distance(level: Node) -> float:
	var light := _find_light(level)
	return light.directional_shadow_max_distance if light != null else 0.0


func _collect_ranged(node: Node, out: Array[Dictionary]) -> void:
	var geometry := node as GeometryInstance3D
	if geometry != null and geometry.visible:
		var mesh: Mesh = null
		if node is MultiMeshInstance3D:
			var multimesh: MultiMesh = (node as MultiMeshInstance3D).multimesh
			if multimesh != null:
				mesh = multimesh.mesh
		elif node is MeshInstance3D:
			mesh = (node as MeshInstance3D).mesh
		if mesh != null:
			out.append({
				"pos": geometry.global_position,
				"range": geometry.visibility_range_end,
				"surfaces": mesh.get_surface_count(),
				"casts": geometry.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			})
	for child in node.get_children():
		_collect_ranged(child, out)


## A grid of eye positions over the playable area, from the terrain's own extent.
func _eye_samples(level: Node) -> Array[Vector3]:
	var world: Node = level.get_node_or_null(^"World")
	var half: float = 96.0
	if world != null:
		var nx: int = int(world.get(&"_nx"))
		var cell: float = float(world.get(&"_cell"))
		if nx > 1 and cell > 0.0:
			half = float(nx - 1) * cell * 0.5
	var out: Array[Vector3] = []
	var steps: int = 5
	for iz in steps:
		for ix in steps:
			var x: float = lerpf(-half * 0.7, half * 0.7, float(ix) / float(steps - 1))
			var z: float = lerpf(-half * 0.7, half * 0.7, float(iz) / float(steps - 1))
			var y: float = 1.7
			if world != null and world.has_method(&"height_at"):
				y = float(world.call(&"height_at", x, z)) + 1.7
			out.append(Vector3(x, y, z))
	return out


func _report(stats: Dictionary, level: Node) -> void:
	var cascades := _cascades(level)
	var shadow_distance := _shadow_distance(level)
	var opaque: int = stats["surfaces"]
	print("\n-- geometry as built (no culling; an upper bound, not a frame) --")
	print("  opaque surfaces        %6d" % opaque)
	print("  shadow-casting surfaces %5d   (shadow distance %.0f m, %d cascades)" % [
		stats["casters"], shadow_distance, cascades])
	print("\n-- geometry --")
	print("  MeshInstance3D         %6d" % stats["mesh_instances"])
	print("  MultiMeshInstance3D    %6d  holding %d instances (%.1f per draw)" % [
		stats["multimesh_instances"], stats["mm_instances_total"],
		float(stats["mm_instances_total"]) / maxf(1.0, float(stats["multimesh_instances"]))])
	print("  distinct meshes        %6d  (%d with LOD levels)" % [
		stats["meshes_seen"], stats["meshes_with_lod"]])
	print("  triangles drawn        %6d opaque, %d into shadows" % [
		stats["tris_drawn"], stats["caster_tris"] * cascades])
	print("  instances with a LOD distance  %d" % stats["with_lod_range"])
	var effective := _in_range_draws(level, _eye_samples(level), shadow_distance)
	print("\n-- what a camera in the world submits (%d eye positions, 360 degrees, no frustum) --"
		% effective["samples"])
	print("  opaque    median %5d   worst %5d" % [
		effective["opaque_median"], effective["opaque_worst"]])
	print("  shadow    median %5d   worst %5d" % [
		effective["shadow_median"], effective["shadow_worst"]])
	print("  TOTAL     median %5d   worst %5d" % [
		int(effective["opaque_median"]) + int(effective["shadow_median"]),
		int(effective["opaque_worst"]) + int(effective["shadow_worst"])])

	print("\n-- draws by subtree --")
	var names: Array = (stats["by_parent"] as Dictionary).keys()
	names.sort_custom(func(a: String, b: String) -> bool:
		return int((stats["by_parent"][a] as Dictionary)["surfaces"]) \
			> int((stats["by_parent"][b] as Dictionary)["surfaces"]))
	for name: String in names:
		var row: Dictionary = stats["by_parent"][name]
		print("  %-38s %5d draws / %6d instances" % [name, row["surfaces"], row["instances"]])

	# Not assertions about a good number — assertions that the levers exist at all. Both fail
	# today; they are what F-144 is for, and they are what a regression would trip again.
	if stats["with_lod_range"] == 0:
		failures.append("no visual instance has a LOD distance — every prop draws at full "
			+ "detail from any range")
	if stats["meshes_with_lod"] == 0:
		failures.append("no mesh carries LOD levels — the runtime merge discards the "
			+ "import pipeline's automatic LODs")


func _cascades(level: Node) -> int:
	var light := _find_light(level)
	if light == null:
		return 1
	match light.directional_shadow_mode:
		DirectionalLight3D.SHADOW_ORTHOGONAL: return 1
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS: return 2
		DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS: return 4
	return 1


func _find_light(node: Node) -> DirectionalLight3D:
	if node is DirectionalLight3D and (node as DirectionalLight3D).shadow_enabled:
		return node as DirectionalLight3D
	for child in node.get_children():
		var found := _find_light(child)
		if found != null:
			return found
	return null


func _finish() -> void:
	if failures.is_empty():
		print("\nRENDER_CENSUS_OK")
		quit(0)
		return
	print("\n-- levers not yet pulled --")
	for failure in failures:
		print("  ! %s" % failure)
	print("RENDER_CENSUS_GAPS %d" % failures.size())
	quit(1)
