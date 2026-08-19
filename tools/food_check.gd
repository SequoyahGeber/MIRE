extends SceneTree

## Verify A-012's food kit in the engine, and verify the one thing the batch actually claims:
## nine of its thirteen assets come off three shared frames, and a shared frame means the SAME
## numbers, not a similar recipe.
##
## Run with:  .agent/bin/agent godot --script tools/food_check.gd
##
## Blender's own contract already asserts this, so why again here? Because A-011 shipped a node that
## Blender called grounded while the exported GLB sat 53 mm underground — the join's inherited
## rotation was written out as a node transform, and only a reader that measures the imported mesh
## could see it. Every measurement below is taken from vertices on this side of the fence.

const EXPORT_DIR: String = "res://assets/food/exports"
const CATALOG_PATH: String = "res://assets/food/catalog.json"
## A hand-sized item. Nothing in this kit may ship bigger than a forearm or smaller than a plum.
const LARGEST_M: float = 0.45
const SMALLEST_M: float = 0.08

var failures: int = 0
var boxes: Dictionary = {}
var triangles: Dictionary = {}


func _init() -> void:
	var catalog: Dictionary = _load_catalog()
	if catalog.is_empty():
		_finish()
		return
	var entries: Array = catalog.get("assets", [])
	check(entries.size() == 13, "the catalog lists all thirteen assets", str(entries.size()))

	var on_disk: Array[String] = []
	var dir := DirAccess.open(EXPORT_DIR)
	if dir == null:
		check(false, "the export directory is readable")
		_finish()
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".glb"):
			on_disk.append(file_name.get_basename())
	on_disk.sort()
	check(on_disk.size() == entries.size(), "every catalogued asset has a GLB", str(on_disk.size()))

	var total: int = 0
	for entry_value: Variant in entries:
		total += _check_asset(entry_value as Dictionary)
	print("FOOD_IMPORT checked=%d triangles=%d" % [boxes.size(), total])

	_check_frames(catalog)
	_finish()


func _load_catalog() -> Dictionary:
	var text := FileAccess.get_file_as_string(CATALOG_PATH)
	if text.is_empty():
		check(false, "the catalog is readable")
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		check(false, "the catalog is a JSON object")
		return {}
	return parsed as Dictionary


func _check_asset(entry: Dictionary) -> int:
	var name := String(entry.get("name", ""))
	var packed: PackedScene = load("%s/%s.glb" % [EXPORT_DIR, name]) as PackedScene
	if packed == null:
		check(false, "%s: imports as a PackedScene" % name)
		return 0
	var node: Node = packed.instantiate()
	var meshes: Array[MeshInstance3D] = []
	_collect(node, meshes)
	if meshes.is_empty():
		check(false, "%s: instantiates with a mesh" % name)
		node.free()
		return 0

	var low := Vector3.INF
	var high := -Vector3.INF
	var count: int = 0
	var materials: int = 0
	for instance in meshes:
		var mesh: Mesh = instance.mesh
		if mesh == null:
			check(false, "%s: %s has no mesh" % [name, instance.name])
			continue
		if instance.skin != null:
			check(false, "%s: carries a skin; this batch is static geometry" % name)
		# A node transform on a static prop is how A-011's resin node shipped 53 mm
		# underground: correct only if the reader remembers to apply it.
		if not instance.transform.is_equal_approx(Transform3D.IDENTITY):
			check(false, "%s: %s ships a node transform" % [name, instance.name],
				str(instance.transform))
		materials = maxi(materials, mesh.get_surface_count())
		for surface in mesh.get_surface_count():
			if mesh.surface_get_material(surface) == null:
				check(false, "%s: surface %d has no embedded material" % [name, surface])
			var arrays: Array = mesh.surface_get_arrays(surface)
			count += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
				low = low.min(vertex)
				high = high.max(vertex)
	var aabb := AABB(low, high - low)
	boxes[name] = aabb
	triangles[name] = count

	# Blender's z is Godot's y and Blender's y is Godot's -z.
	var expected := Vector3(
		float(entry.get("width_m", 0.0)),
		float(entry.get("height_m", 0.0)),
		float(entry.get("depth_m", 0.0))
	)
	if (aabb.size - expected).length() > 0.005:
		check(false, "%s: engine measures %v, catalog says %v" % [name, aabb.size.snappedf(0.001), expected])
	if count != int(entry.get("triangles", 0)):
		check(false, "%s: %d triangles here, %d in the catalog" % [name, count, int(entry.get("triangles", 0))])
	if absf(aabb.position.y) > 0.005:
		check(false, "%s: sits %.1f mm off the ground" % [name, aabb.position.y * 1000.0])
	var longest: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if longest > LARGEST_M or longest < SMALLEST_M:
		check(false, "%s: %.3f m long, and food is hand-sized" % [name, longest])
	return count


## The batch's claim, re-measured: siblings are one object with different paint.
func _check_frames(catalog: Dictionary) -> void:
	var frames: Dictionary = catalog.get("frames", {})
	check(not frames.is_empty(), "the catalog names its shared frames")
	var worst: float = 0.0
	for family: String in frames:
		var names: Array = frames[family]
		if names.size() < 2:
			continue
		var reference := String(names[0])
		if not boxes.has(reference):
			check(false, "%s: reference sibling %s did not import" % [family, reference])
			continue
		for index in range(1, names.size()):
			var other := String(names[index])
			if not boxes.has(other):
				check(false, "%s: sibling %s did not import" % [family, other])
				continue
			var drift: float = maxf(
				((boxes[reference] as AABB).size - (boxes[other] as AABB).size).length(),
				((boxes[reference] as AABB).position - (boxes[other] as AABB).position).length()
			)
			worst = maxf(worst, drift)
			if drift > 0.0005:
				check(false, "%s: %s drifts %.3f mm from %s" % [family, other, drift * 1000.0, reference])
			if int(triangles[other]) != int(triangles[reference]):
				check(false, "%s: %s costs %d triangles, %s costs %d — not the same object" % [
					family, other, int(triangles[other]), reference, int(triangles[reference])
				])
	print("FOOD_FRAMES families=%d worst_drift=%.4f mm" % [frames.size(), worst * 1000.0])


func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, out)


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		return
	failures += 1
	print("FAIL: %s%s" % [label, "" if detail.is_empty() else " — " + detail])


func _finish() -> void:
	print("FOOD_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
