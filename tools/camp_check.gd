extends SceneTree

## Verify A-013's camp kit in the engine, and verify the one thing the batch actually claims:
## six of its sixteen assets come off two shared frames — one crate in two states, and one rack
## carrying four different loads — and a shared frame means the SAME numbers, not a similar recipe.
##
## Run with:  .agent/bin/agent godot --script tools/camp_check.gd
##
## Blender's own contract already asserts this, so why again here? Because A-011 shipped a node that
## Blender called grounded while the exported GLB sat 53 mm underground — the join's inherited
## rotation was written out as a node transform, and only a reader that measures the imported mesh
## could see it. Every measurement below is taken from vertices on this side of the fence.

const EXPORT_DIR: String = "res://assets/camp/exports"
const CATALOG_PATH: String = "res://assets/camp/catalog.json"
## Camp furniture: nothing here is bigger than a bedroll or smaller than a bucket.
const LARGEST_M: float = 2.00
const SMALLEST_M: float = 0.15

var failures: int = 0
var boxes: Dictionary = {}
var triangles: Dictionary = {}


func _init() -> void:
	var catalog: Dictionary = _load_catalog()
	if catalog.is_empty():
		_finish()
		return
	var entries: Array = catalog.get("assets", [])
	check(entries.size() == 16, "the catalog lists all thirteen assets", str(entries.size()))

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
	print("CAMP_IMPORT checked=%d triangles=%d" % [boxes.size(), total])

	_check_frames(catalog)
	_check_stock(catalog)
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


## What a shared frame means HERE, and why it is not A-012's assertion.
##
## A-012's siblings differed by paint alone, so whole-asset bounds and triangle counts had to match
## exactly. A-013's do not: four racks share a frame and carry four different loads, and a smashed
## crate spills boards past the footprint of the crate it was. Demanding identical totals of those
## would be demanding that the loads be identical, which would defeat the point of having four racks.
##
## So the frame claim is enforced where the parts still have names — in the generator, on the
## `frame_bounds` of the shared prefixes, at 0.0000 mm. By the time a GLB is imported the asset is
## one joined mesh and those parts are gone. What survives the join, and what this asserts, is the
## consequence a player can see: the four racks are the same rack, so they must stand the same
## height and the same width, however differently they are loaded.
func _check_frames(catalog: Dictionary) -> void:
	var frames: Dictionary = catalog.get("frames", {})
	check(not frames.is_empty(), "the catalog names its shared frames")
	var racks: Array = frames.get("rack", [])
	check(racks.size() == 4, "the rack family has four members", str(racks.size()))
	var worst: float = 0.0
	if racks.size() > 1 and boxes.has(String(racks[0])):
		var reference := (boxes[String(racks[0])] as AABB).size
		for index in range(1, racks.size()):
			var other := String(racks[index])
			if not boxes.has(other):
				check(false, "rack: %s did not import" % other)
				continue
			var size := (boxes[other] as AABB).size
			var drift: float = maxf(absf(size.x - reference.x), absf(size.y - reference.y))
			worst = maxf(worst, drift)
			if drift > 0.001:
				check(false, "rack: %s stands %.2f mm off %s — same frame, different size" % [
					other, drift * 1000.0, String(racks[0])
				])
	# The crate pair swaps in place, so its footprint may only GROW where boards
	# spilled — never shrink, and never change height.
	if boxes.has("crate") and boxes.has("crate_broken"):
		var intact := (boxes["crate"] as AABB).size
		var smashed := (boxes["crate_broken"] as AABB).size
		if absf(intact.y - smashed.y) > 0.02:
			check(false, "crate: the pair stands %.0f mm apart in height" % (absf(intact.y - smashed.y) * 1000.0))
		if smashed.x < intact.x - 0.001 or smashed.z < intact.z - 0.001:
			check(false, "crate: the smashed crate is smaller than the crate it was")
	print("CAMP_FRAMES families=%d rack_drift=%.4f mm" % [frames.size(), worst * 1000.0])


## The stock list is the batch's other claim: every board in the camp is one board.
## It is enforced at build time in Blender, where the parts still have names; by the
## time a GLB is imported the whole asset is one joined mesh, so what CAN be checked
## here is that the catalog still declares the stock it was built to — a kit whose
## stock block goes missing has stopped being a kit and nobody would notice.
func _check_stock(catalog: Dictionary) -> void:
	var stock: Dictionary = catalog.get("stock", {})
	for key: String in ["plank_thickness_m", "plank_width_m", "post_radius_m",
			"rail_radius_m", "band_thickness_m", "stave_thickness_m"]:
		check(stock.has(key), "the catalog declares %s" % key)
		if stock.has(key):
			check(float(stock[key]) > 0.0, "%s is a real dimension" % key, str(stock[key]))
	print("CAMP_STOCK %s" % JSON.stringify(stock))

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
	print("CAMP_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
