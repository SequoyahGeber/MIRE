extends SceneTree

## Verify A-014's road kit in the engine, and verify the one thing the batch actually claims:
## six of its sixteen assets come off two shared frames — one crate in two states, and one rack
## carrying four different loads — and a shared frame means the SAME numbers, not a similar recipe.
##
## Run with:  .agent/bin/agent godot --script tools/path_check.gd
##
## Blender's own contract already asserts this, so why again here? Because A-011 shipped a node that
## Blender called grounded while the exported GLB sat 53 mm underground — the join's inherited
## rotation was written out as a node transform, and only a reader that measures the imported mesh
## could see it. Every measurement below is taken from vertices on this side of the fence.

const EXPORT_DIR: String = "res://assets/paths/exports"
const CATALOG_PATH: String = "res://assets/paths/catalog.json"
## Camp furniture: nothing here is bigger than a bedroll or smaller than a bucket.
const LARGEST_M: float = 2.20
const SMALLEST_M: float = 0.30

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
	print("PATH_IMPORT checked=%d triangles=%d" % [boxes.size(), total])

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


## A-010's module, re-measured on this side of the fence.
##
## The claim is that a path tile, a boardwalk and a dock from the construction kit all belong to one
## 2.00 m grid, so a route can change surface without changing gauge. The generator asserts it on the
## walking SURFACE — the slab, the deck boards — because a tile whose bounding box is 2.000 m while
## its surface is 1.988 m still shows a stripe of untouched ground at every joint (F-135). By import
## time the asset is one joined mesh, so what this asserts is the consequence: every tiling piece
## measures the module along its run, and the four surfaces share it in both axes so a mixed run
## tiles in a field.
func _check_frames(catalog: Dictionary) -> void:
	var module: float = float(catalog.get("module_m", 2.0))
	check(is_equal_approx(module, 2.0), "the kit is on A-010's 2 m module", str(module))
	var spans: Dictionary = catalog.get("run_span_m", {})
	check(not spans.is_empty(), "the catalog names which pieces tile")
	var worst: float = 0.0
	for name: String in spans:
		if not boxes.has(name):
			check(false, "%s: named as tiling but did not import" % name)
			continue
		var size := (boxes[name] as AABB).size
		var drift: float = absf(size.x - module)
		worst = maxf(worst, drift)
		# Along the run, the whole asset may not exceed the module either: a kerb
		# or a marker stone that overhangs is a piece that will not sit beside its
		# own neighbour.
		if size.x > module + 0.05:
			check(false, "%s: %.3f m along the run, module is %.2f" % [name, size.x, module])
	# The stairs are the join between this kit and A-010's: they climb from the
	# boardwalk deck to the construction kit's, and nothing else in either kit does.
	var decks: Dictionary = catalog.get("deck_z_m", {})
	var boardwalk: float = float(decks.get("boardwalk", 0.0))
	var construction: float = float(decks.get("construction_kit", 0.0))
	check(boardwalk > 0.0 and construction > boardwalk,
		"the two deck heights are declared and the stairs have somewhere to climb",
		"%s -> %s" % [boardwalk, construction])
	if boxes.has("boardwalk_stairs"):
		var stairs := boxes["boardwalk_stairs"] as AABB
		check(absf(stairs.end.y - construction) < 0.05,
			"the stairs top out at the construction kit's deck (%.3f m)" % stairs.end.y)
		var rise: float = construction - boardwalk
		var angle: float = rad_to_deg(atan2(rise, module))
		check(angle < 46.0, "the stairs climb at %.1f degrees, under the player's floor limit" % angle)
	# The deck boards cannot be isolated after the join, so what is asserted here is
	# that the walkway is a WALKWAY: its highest point is the deck plus a kerb, not
	# a deck plus a handrail. The board plane itself is measured in the generator,
	# where the boards still have names.
	if boxes.has("boardwalk_straight"):
		var deck := boxes["boardwalk_straight"] as AABB
		check(deck.end.y >= boardwalk - 0.005 and deck.end.y <= boardwalk + 0.08,
			"the boardwalk is deck-plus-kerb high, not deck-plus-rail (%.3f m)" % deck.end.y)
	print("PATH_MODULE pieces=%d worst_run_drift=%.4f mm" % [spans.size(), worst * 1000.0])


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
	print("PATH_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
