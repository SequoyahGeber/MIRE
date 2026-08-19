extends SceneTree

## A-043 — verifies the wetland kit as GODOT sees it, not as Blender reported it.
##
##   .agent/bin/agent godot --headless --script tools/wetland_check.gd
##
## Same instrument as `tools/gatherables_check.gd` (A-011) pointed at a different catalog, and it
## exists for the same reason: the build-time contract in `tools/blender/build_wetland_set.py`
## measures the BLENDER scene, which is not evidence about the shipped GLB. A-011 shipped a resin
## node that Blender called perfectly grounded while the export sat 53 mm underground, because the
## measurement went through the object's world matrix and the exporter wrote the rotation out as a
## node transform instead.
##
## Vertices, never `Transform3D * AABB` (F-108/F-094): an AABB pushed through a rotation inflates,
## and that construction once reported seven of A-009's fifteen exports oversized when nothing was
## wrong with them.

const CATALOG_PATH := "res://assets/wetland/catalog.json"
const EXPORT_DIR := "res://assets/wetland/exports/"

## Blender and Godot disagree in the last decimal place on a float that has been through a glTF
## round trip. A millimetre is far tighter than anything that could matter and far looser than that
## disagreement.
const DIMENSION_TOLERANCE_M := 0.001
## The kit's own ground-contact rule, restated engine-side.
const GROUND_TOLERANCE_M := 0.005

var _failures: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("=== MIRE A-043 — wetland gatherables II ===")
	print("Godot %s | %s" % [Engine.get_version_info()["string"], OS.get_name()])

	var file := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if file == null:
		push_error("no catalog at %s" % CATALOG_PATH)
		quit(1)
		return
	var catalog: Dictionary = JSON.parse_string(file.get_as_text())
	var assets: Array = catalog["assets"]
	print("catalog: batch %s, %d asset(s), built with Blender %s\n" % [
		catalog["batch"], assets.size(), catalog["blender"],
	])

	var seen: Dictionary[String, bool] = {}
	for entry: Dictionary in assets:
		_check_asset(entry)
		seen[String(entry["name"]) + ".glb"] = true

	# Orphans: a GLB on disk that no catalog record claims is an asset nobody can find.
	var listed := DirAccess.get_files_at(EXPORT_DIR)
	var orphans: Array[String] = []
	for name: String in listed:
		if name.ends_with(".glb") and not seen.has(name):
			orphans.append(name)
	print("")
	_check("every GLB in exports/ has a catalog record", orphans.is_empty(),
		"orphans: %s" % str(orphans))

	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_asset(entry: Dictionary) -> void:
	var name: String = entry["name"]
	var path: String = EXPORT_DIR + name + ".glb"
	if not ResourceLoader.exists(path):
		_check("%s imports" % name, false, "no imported resource at %s" % path)
		return
	var scene: PackedScene = load(path)
	if scene == null:
		_check("%s imports" % name, false, "load() returned null")
		return
	var root: Node = scene.instantiate()
	if root == null:
		_check("%s instantiates" % name, false, "instantiate() returned null")
		return
	root_node_add(root)

	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	if meshes.is_empty():
		_check("%s has mesh geometry" % name, false, "no MeshInstance3D in the imported scene")
		root.queue_free()
		return

	# Vertices in the scene's own space, so a node transform is included rather than
	# assumed away — see the header.
	var minimum := Vector3.INF
	var maximum := -Vector3.INF
	var triangles: int = 0
	var materials: Dictionary[String, bool] = {}
	for instance: MeshInstance3D in meshes:
		var mesh: Mesh = instance.mesh
		for surface: int in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			triangles += (indices.size() if indices.size() > 0 else verts.size()) / 3
			var transform: Transform3D = instance.transform
			for vertex: Vector3 in verts:
				var world: Vector3 = transform * vertex
				minimum = minimum.min(world)
				maximum = maximum.max(world)
			var material: Material = mesh.surface_get_material(surface)
			if material != null:
				materials[material.resource_name] = true

	var size: Vector3 = maximum - minimum
	var expected := Vector3(entry["width_m"], entry["depth_m"], entry["height_m"])
	# glTF is Y-up; the catalog records Blender's Z-up. Height is Y in the engine.
	var engine_expected := Vector3(expected.x, expected.z, expected.y)
	var worst: float = maxf(maxf(absf(size.x - engine_expected.x), absf(size.y - engine_expected.y)),
		absf(size.z - engine_expected.z))
	_check("%s measures as the catalog says (%.3f x %.3f x %.3f m)" % [
		name, engine_expected.x, engine_expected.y, engine_expected.z,
	], worst <= DIMENSION_TOLERANCE_M,
		"engine reads %.4f x %.4f x %.4f m, worst axis off by %.1f mm" % [
			size.x, size.y, size.z, worst * 1000.0,
		])
	_check("%s sits on the ground plane" % name, absf(minimum.y) <= GROUND_TOLERANCE_M,
		"lowest vertex at y = %.1f mm" % (minimum.y * 1000.0))
	_check("%s keeps its triangle count through the round trip (%d)" % [name, entry["triangles"]],
		triangles == int(entry["triangles"]), "engine counts %d" % triangles)
	_check("%s carries its %d embedded material(s)" % [name, (entry["materials"] as Array).size()],
		materials.size() == (entry["materials"] as Array).size(),
		"engine sees %d: %s" % [materials.size(), str(materials.keys())])
	root.queue_free()


func root_node_add(node: Node) -> void:
	root.add_child(node)


func _collect_meshes(node: Node, into: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		into.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_meshes(child, into)
