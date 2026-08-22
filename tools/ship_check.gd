extends SceneTree

## Verify every extraction-ship export imports, instantiates and ASSEMBLES in the
## real engine.
##
## Run with:  .agent/bin/agent godot --script tools/ship_check.gd
##
## A GLB that Blender wrote happily can still fail here: Godot re-imports it, and
## an inverted face, a missing material or a name collision only shows up on that
## side of the fence. The catalog is the contract, so this checks the exports
## against it rather than against a glob.
##
## The part that is specific to A-009 is the assembly check at the bottom. Eleven
## of the fifteen exports are authored in the hull's own coordinate frame instead
## of being individually ground-centred, so that a scene can add the hull, the
## mast, the sail, the rudder, the ramp and the hatch as siblings at
## Transform3D.IDENTITY and get a whole ship. That claim is worth nothing unless
## something proves it, and the only place it can be proved is here, with the
## engine's own measurements. Blender axes map as X -> X, Y -> -Z, Z -> Y, so the
## hull is 10.4 m along X, 3.4 m across Z and 3.6 m up Y.

const EXPORT_DIR: String = "res://assets/ships/exports"
const CATALOG_PATH: String = "res://assets/ships/catalog.json"
const DECK_Y: float = 1.78

var failures: Array[String] = []
var boxes: Dictionary = {}


func _init() -> void:
	var catalog: Array = _load_catalog()
	if catalog.is_empty():
		_finish()
		return

	var listed: Dictionary = {}
	for entry_value: Variant in catalog:
		listed[String((entry_value as Dictionary).get("name", ""))] = entry_value

	var on_disk: Array[String] = []
	var dir := DirAccess.open(EXPORT_DIR)
	if dir == null:
		failures.append("cannot open %s" % EXPORT_DIR)
		_finish()
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".glb"):
			on_disk.append(file_name.get_basename())
	on_disk.sort()

	for name: Variant in listed.keys():
		if not on_disk.has(String(name)):
			failures.append("%s: in catalog, no GLB on disk" % name)
	for name in on_disk:
		if not listed.has(name):
			failures.append("%s: GLB on disk, not in catalog" % name)

	var total_triangles: int = 0
	for name in on_disk:
		if not listed.has(name):
			continue
		total_triangles += _check_asset(name, listed[name] as Dictionary)

	print("SHIP_IMPORT checked=%d triangles=%d" % [boxes.size(), total_triangles])
	_check_state_drift()
	_check_assembly()
	_finish()


func _load_catalog() -> Array:
	var text := FileAccess.get_file_as_string(CATALOG_PATH)
	if text.is_empty():
		failures.append("cannot read %s" % CATALOG_PATH)
		return []
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Array:
		failures.append("%s is not a JSON array" % CATALOG_PATH)
		return []
	return parsed as Array


func _check_asset(name: String, entry: Dictionary) -> int:
	var packed: PackedScene = load("%s/%s.glb" % [EXPORT_DIR, name]) as PackedScene
	if packed == null:
		failures.append("%s: did not import as a PackedScene" % name)
		return 0
	var node: Node = packed.instantiate()
	if node == null:
		failures.append("%s: imported but would not instantiate" % name)
		return 0

	var meshes: Array[MeshInstance3D] = []
	_collect(node, meshes)
	if meshes.is_empty():
		failures.append("%s: instantiated with no MeshInstance3D" % name)
		node.free()
		return 0

	var triangles: int = 0
	var low := Vector3.INF
	var high := -Vector3.INF
	for instance in meshes:
		var mesh := instance.mesh
		if mesh == null:
			failures.append("%s: %s has no mesh" % [name, instance.name])
			continue
		var to_root := _transform_to_root(instance, node)
		for surface in mesh.get_surface_count():
			if mesh.surface_get_material(surface) == null:
				failures.append("%s: surface %d has no embedded material" % [name, surface])
			var arrays: Array = mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			triangles += indices.size() / 3
			# Measure VERTICES, never `transform * get_aabb()`. An AABB is
			# axis-aligned in the mesh's own space, so pushing it through a
			# rotation returns the box around the rotated box — strictly larger
			# than the geometry inside it, and larger by more the more the part
			# is turned. Every cone this batch makes is a rotated primitive, so
			# the inflated ruler reported all four hull states 50 mm long, the
			# broken mast 72 mm, and its origin 23 mm low, and it would have
			# been read as the exporter corrupting the geometry rather than as
			# the check mismeasuring it. This is F-094 (`world_bounds` in
			# Blender) on the engine side of the fence.
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var point := to_root * vertex
				low = low.min(point)
				high = high.max(point)
		if instance.skin != null:
			failures.append("%s: %s carries a skin; this batch is static geometry" % [name, instance.name])
	var aabb := AABB(low, high - low)

	# Blender's z is Godot's y, and Blender's y is Godot's -z, so the catalog's
	# width/depth/height land on x/z/y respectively.
	var expected := Vector3(
		float(entry.get("width_m", 0.0)),
		float(entry.get("height_m", 0.0)),
		float(entry.get("depth_m", 0.0))
	)
	if (aabb.size - expected).length() > 0.02:
		failures.append(
			"%s: engine measures %v, catalog says %v" % [name, aabb.size.snappedf(0.001), expected]
		)
	var expected_triangles := int(entry.get("triangles", 0))
	if triangles != expected_triangles:
		failures.append(
			"%s: %d triangles in engine, catalog says %d" % [name, triangles, expected_triangles]
		)

	# Origin rule, which differs by family on purpose. A prop is dropped into the
	# world by its own origin and has to sit on the ground; a ship-framed part is
	# added at identity alongside the hull and sits wherever the hull puts it.
	var origin := String(entry.get("origin", ""))
	var catalog_min_y := float(entry.get("min_z_m", 0.0))
	if origin == "ground_centred":
		if absf(aabb.position.y) > 0.01:
			failures.append("%s: base sits %.1f mm off its origin" % [name, aabb.position.y * 1000.0])
		var centre := aabb.position + aabb.size * 0.5
		if absf(centre.x) > 0.01 or absf(centre.z) > 0.01:
			failures.append("%s: not horizontally centred (%v)" % [name, centre.snappedf(0.001)])
	else:
		if aabb.position.y < -0.01:
			failures.append("%s: %.1f mm below the ground plane" % [name, aabb.position.y * 1000.0])
		if absf(aabb.position.y - catalog_min_y) > 0.01:
			failures.append(
				"%s: sits at y=%.3f, catalog says %.3f" % [name, aabb.position.y, catalog_min_y]
			)

	boxes[name] = aabb
	node.free()
	return triangles


## The four hull states are swapped in place as the wreck is repaired. Nothing
## re-centres them, so they cannot drift — but "cannot" is a claim, and this is
## the measurement. Beam, height and stern must agree exactly; only the bow may
## differ, because the finished ship earns a carved stem ornament.
func _check_state_drift() -> void:
	var states: Array[String] = [
		"ship_hull_wrecked", "ship_hull_repair_1", "ship_hull_repair_2", "ship_hull_repaired"
	]
	var reference: AABB = boxes.get(states[0], AABB())
	if reference.size == Vector3.ZERO:
		failures.append("ship_hull_wrecked did not import, so drift cannot be measured")
		return
	var worst: float = 0.0
	for name in states:
		if not boxes.has(name):
			failures.append("%s missing from the drift comparison" % name)
			continue
		var box: AABB = boxes[name]
		var drift: float = maxf(
			maxf(absf(box.position.y - reference.position.y), absf(box.position.z - reference.position.z)),
			maxf(absf(box.size.z - reference.size.z), absf(box.position.x - reference.position.x))
		)
		worst = maxf(worst, drift)
		if drift > 0.001:
			failures.append("%s drifts %.2f mm from the wrecked state" % [name, drift * 1000.0])
	print("SHIP_STATE_DRIFT worst=%.4f mm across %d states" % [worst * 1000.0, states.size()])


## The whole reason the ship frame exists: add the parts as siblings at identity
## and you get a ship, with nothing for a human to position by eye (D-039).
func _check_assembly() -> void:
	var hull: AABB = boxes.get("ship_hull_repaired", AABB())
	if hull.size == Vector3.ZERO:
		failures.append("ship_hull_repaired did not import, so assembly cannot be checked")
		return

	var mast: AABB = boxes.get("ship_mast", AABB())
	var mast_x: float = mast.position.x + mast.size.x * 0.5
	if not (hull.position.x < mast_x and mast_x < hull.position.x + hull.size.x):
		failures.append("the mast does not step inside the hull (x=%.2f)" % mast_x)
	if mast.position.y > DECK_Y:
		failures.append("the mast heel starts above the deck, so it is stepped on nothing")
	if mast.position.y + mast.size.y < hull.position.y + hull.size.y:
		failures.append("the mast does not rise above the hull")

	var rudder: AABB = boxes.get("ship_rudder", AABB())
	if rudder.position.x >= hull.position.x:
		failures.append("the rudder is not hung aft of the transom")

	var ramp: AABB = boxes.get("ship_boarding_ramp", AABB())
	if absf(ramp.position.y) > 0.01:
		failures.append("the boarding ramp does not reach the ground (y=%.3f)" % ramp.position.y)
	if ramp.position.y + ramp.size.y < DECK_Y:
		failures.append("the boarding ramp does not reach the deck")
	if maxf(absf(ramp.position.z), absf(ramp.position.z + ramp.size.z)) <= hull.size.z * 0.5:
		failures.append("the boarding ramp never leaves the hull's own footprint")

	var hatch: AABB = boxes.get("ship_cargo_hatch", AABB())
	if absf(hatch.position.y - DECK_Y) > 0.05:
		failures.append("the cargo hatch does not sit on the deck (y=%.3f)" % hatch.position.y)
	if not hull.intersects(hatch):
		failures.append("the cargo hatch is not inside the hull's volume")

	for sail in ["ship_sail_raised", "ship_sail_furled"]:
		var box: AABB = boxes.get(sail, AABB())
		if not box.intersects(mast):
			failures.append("%s does not meet the mast" % sail)
		if box.position.y < DECK_Y:
			failures.append("%s hangs below deck level, so its boom is inside the boat" % sail)

	var assembled := hull
	for name in ["ship_mast", "ship_sail_raised", "ship_rudder", "ship_boarding_ramp", "ship_cargo_hatch"]:
		assembled = assembled.merge(boxes.get(name, hull) as AABB)
	print(
		"SHIP_ASSEMBLY hull=%v assembled=%v" % [hull.size.snappedf(0.01), assembled.size.snappedf(0.01)]
	)


## Accumulated transform from an instance up to the imported scene's root. The
## GLB importer nests the meshes under a root node, so an instance's own
## `transform` is only part of the story and `global_transform` is unavailable
## on a scene that was never added to the tree.
func _transform_to_root(instance: Node3D, root_node: Node) -> Transform3D:
	var combined := Transform3D.IDENTITY
	var walker: Node = instance
	while walker != null and walker != root_node:
		if walker is Node3D:
			combined = (walker as Node3D).transform * combined
		walker = walker.get_parent()
	if root_node is Node3D:
		combined = (root_node as Node3D).transform * combined
	return combined


func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, out)


func _finish() -> void:
	if failures.is_empty():
		print("SHIP_CHECK_GODOT PASS")
	else:
		print("SHIP_CHECK_GODOT FAIL (%d)" % failures.size())
		for failure in failures:
			print("  ", failure)
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("SHIP_CHECK failures=%d" % failures.size())
	quit(0 if failures.is_empty() else 1)
