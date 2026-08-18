extends SceneTree

## Verify every flora export imports and instantiates in the real engine.
##
## Run with:  .agent/bin/agent godot --script tools/flora_check.gd
##
## A GLB that Blender wrote happily can still fail here: Godot re-imports it, and
## an inverted face, a missing material or a name collision only shows up on that
## side of the fence. The catalog is the contract, so this checks the exports
## against it rather than against a glob — a file the catalog does not list is as
## much a defect as a listed file that is missing.

const EXPORT_DIR: String = "res://assets/flora/exports"
const CATALOG_PATH: String = "res://assets/flora/catalog.json"

var failures: Array[String] = []


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

	for name in listed.keys():
		if not on_disk.has(String(name)):
			failures.append("%s: in catalog, no GLB on disk" % name)
	for name in on_disk:
		if not listed.has(name):
			failures.append("%s: GLB on disk, not in catalog" % name)

	var total_triangles: int = 0
	var checked: int = 0
	for name in on_disk:
		if not listed.has(name):
			continue
		total_triangles += _check_asset(name, listed[name] as Dictionary)
		checked += 1

	print("FLORA_IMPORT checked=%d triangles=%d" % [checked, total_triangles])
	_check_scatter()


## The kit is only shipped if something in the world actually grows it. This runs
## the real level and asks the scatter what it managed to place, because an asset
## folder nobody instantiates is not content (AGENTS.md: "a script nothing loads
## isn't shipped").
func _check_scatter() -> void:
	var level: PackedScene = load("res://levels/playtest_hollow.tscn") as PackedScene
	if level == null:
		failures.append("could not load levels/playtest_hollow.tscn")
		_finish()
		return
	var instance := level.instantiate()
	root.add_child(instance)
	for frame in 12:
		await process_frame
		await physics_frame
	var undergrowth := instance.get_node_or_null("Undergrowth")
	if undergrowth == null:
		failures.append("the level has no Undergrowth node, so no flora is placed")
	else:
		var placed := int(undergrowth.get("placed_count"))
		var meshes := int(undergrowth.get("multimesh_count"))
		if placed < 400:
			failures.append("undergrowth placed only %d plants" % placed)
		if meshes <= 0:
			failures.append("undergrowth built no MultiMeshInstance3D")
		print("FLORA_SCATTER placed=%d multimeshes=%d" % [placed, meshes])
	instance.queue_free()
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
	var path := "%s/%s.glb" % [EXPORT_DIR, name]
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		failures.append("%s: did not import as a PackedScene" % name)
		return 0
	var root: Node = packed.instantiate()
	if root == null:
		failures.append("%s: imported but would not instantiate" % name)
		return 0

	var meshes: Array[MeshInstance3D] = []
	_collect(root, meshes)
	if meshes.is_empty():
		failures.append("%s: instantiated with no MeshInstance3D" % name)
		root.free()
		return 0

	var triangles: int = 0
	var low := Vector3.INF
	var high := -Vector3.INF
	for instance in meshes:
		var mesh := instance.mesh
		if mesh == null:
			failures.append("%s: %s has no mesh" % [name, instance.name])
			continue
		var to_root := _transform_to_root(instance, root)
		for surface in mesh.get_surface_count():
			if mesh.surface_get_material(surface) == null:
				failures.append("%s: surface %d has no embedded material" % [name, surface])
			var arrays: Array = mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			triangles += indices.size() / 3
			# Measure VERTICES, never `transform * get_aabb()`. An AABB is
			# axis-aligned in the mesh's own space, so pushing it through a
			# rotation returns the box around the rotated box — strictly larger
			# than the geometry inside it. Ported from ship_check.gd's
			# _check_asset() (F-108/F-122).
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var point := to_root * vertex
				low = low.min(point)
				high = high.max(point)
	var aabb := AABB(low, high - low)

	# Ground contact and size are contracts the map relies on: a prop is placed by
	# its origin, so an asset whose origin is not at its base sinks or floats the
	# moment it is scattered, and no visual check will catch a 3 cm error.
	if absf(aabb.position.y) > 0.01:
		failures.append("%s: base sits %.1f mm off its origin" % [name, aabb.position.y * 1000.0])
	var expected_height := float(entry.get("height_m", 0.0))
	if absf(aabb.size.y - expected_height) > 0.02:
		failures.append(
			"%s: height %.3f m in engine, catalog says %.3f m" % [name, aabb.size.y, expected_height]
		)
	var expected_triangles := int(entry.get("triangles", 0))
	if triangles != expected_triangles:
		failures.append(
			"%s: %d triangles in engine, catalog says %d" % [name, triangles, expected_triangles]
		)
	root.free()
	return triangles


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
		print("FLORA_CHECK_GODOT PASS")
	else:
		print("FLORA_CHECK_GODOT FAIL (%d)" % failures.size())
		for failure in failures:
			print("  ", failure)
	quit(0 if failures.is_empty() else 1)
