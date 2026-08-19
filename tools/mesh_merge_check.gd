extends SceneTree

## Regression check for F-152: `core/render/mesh_merge.gd` concatenated a channel (UV/UV2/
## colour/tangent) whose length didn't match the merged vertex count whenever one merged part
## carried an attribute a sibling part lacked. Godot's own surface builder rejects that silently
## -- "array.size() != p_vertex_array_len" from `mesh_create_surface_data_from_arrays` -- and the
## merge fell back to a mesh with ZERO surfaces, so a `surface_get_material(-1)` a caller assumed
## valid threw next and the batch drew nothing. Loud in the log, invisible on screen.
##
## Exercises `MeshMerge.merged()` directly against every .glb kit export rather than booting a
## level: the failure is a property of the ASSET (a part missing a channel its siblings have),
## not of any one scene that happens to place it -- the same population core/render/mesh_merge.gd's
## own doc comment says the merge belongs to.
##
## The disk cache is cleared first so every run exercises the real `_build()` path rather than
## reading back a mesh a previous good run already cached -- otherwise a regression that does not
## also bump `MeshMerge.CACHE_VERSION` would hide behind a stale, valid cache entry.
##
## Run with:  .agent/bin/agent godot --script tools/mesh_merge_check.gd

const MeshMerge := preload("res://core/render/mesh_merge.gd")
const ASSETS_DIR: String = "res://assets"

var failures: Array[String] = []
var checked: int = 0
var total_surfaces: int = 0


func _init() -> void:
	_clear_cache()
	var kits := _list_kits()
	if kits.is_empty():
		failures.append("no kit exports/ directories found under %s" % ASSETS_DIR)
	for kit in kits:
		_check_kit(kit)
	print("MESH_MERGE_CHECK checked=%d surfaces=%d" % [checked, total_surfaces])
	_finish()


## Every top-level assets/ folder that has an exports/ subdirectory is a kit MeshMerge is asked
## to collapse (authored_world.gd, harvestable.gd) -- this discovers them rather than naming a
## fixed list, so a new kit is covered the moment its exports/ folder exists.
func _list_kits() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(ASSETS_DIR)
	if dir == null:
		return out
	for entry in dir.get_directories():
		if DirAccess.dir_exists_absolute("%s/%s/exports" % [ASSETS_DIR, entry]):
			out.append(entry)
	out.sort()
	return out


func _check_kit(kit: String) -> void:
	var export_dir := "%s/%s/exports" % [ASSETS_DIR, kit]
	var dir := DirAccess.open(export_dir)
	if dir == null:
		failures.append("%s: cannot open %s" % [kit, export_dir])
		return
	var names := dir.get_files()
	names.sort()
	for file_name in names:
		if file_name.ends_with(".glb"):
			_check_asset("%s/%s" % [export_dir, file_name])


func _check_asset(path: String) -> void:
	checked += 1
	var mesh := MeshMerge.merged(path)
	if mesh == null:
		# A source with no mesh parts at all legitimately merges to null (nothing to build). Only
		# flag it if the source demonstrably HAD geometry -- that is the F-152 failure mode.
		if _has_mesh_parts(path):
			failures.append("%s: merged to null despite having mesh parts" % path)
		return
	if mesh.get_surface_count() == 0:
		failures.append("%s: merged mesh has zero surfaces -- the F-152 failure mode" % path)
		return
	for surface in mesh.get_surface_count():
		total_surfaces += 1
		var arrays: Array = mesh.surface_get_arrays(surface)
		var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if vertex_count == 0:
			failures.append("%s surface %d: no vertices" % [path, surface])
			continue
		_check_channel(path, surface, "normal", arrays[Mesh.ARRAY_NORMAL], vertex_count, 1)
		_check_channel(path, surface, "uv", arrays[Mesh.ARRAY_TEX_UV], vertex_count, 1)
		_check_channel(path, surface, "uv2", arrays[Mesh.ARRAY_TEX_UV2], vertex_count, 1)
		_check_channel(path, surface, "color", arrays[Mesh.ARRAY_COLOR], vertex_count, 1)
		_check_channel(path, surface, "tangent", arrays[Mesh.ARRAY_TANGENT], vertex_count, 4)
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices != null:
			for index in (indices as PackedInt32Array):
				if index < 0 or index >= vertex_count:
					failures.append("%s surface %d: index %d out of range for %d vertices"
						% [path, surface, index, vertex_count])
					break


## Every present channel must carry exactly `stride` entries per vertex -- the invariant F-152's
## bug broke. An absent channel (null, or empty) is fine; a present-but-short one is the
## "array.size() != p_vertex_array_len" bug, caught here even though it never reaches the log
## once mesh_merge.gd rejects the concatenation before calling into the engine.
func _check_channel(path: String, surface: int, label: String, value: Variant,
		vertex_count: int, stride: int) -> void:
	if value == null:
		return
	var size := _packed_size(value)
	if size == 0:
		return
	if size != vertex_count * stride:
		failures.append("%s surface %d: %s has %d entries, expected %d for %d vertices"
			% [path, surface, label, size, vertex_count * stride, vertex_count])


func _packed_size(value: Variant) -> int:
	match typeof(value):
		TYPE_PACKED_VECTOR2_ARRAY: return (value as PackedVector2Array).size()
		TYPE_PACKED_VECTOR3_ARRAY: return (value as PackedVector3Array).size()
		TYPE_PACKED_COLOR_ARRAY: return (value as PackedColorArray).size()
		TYPE_PACKED_FLOAT32_ARRAY: return (value as PackedFloat32Array).size()
		TYPE_PACKED_INT32_ARRAY: return (value as PackedInt32Array).size()
	return 0


func _has_mesh_parts(path: String) -> bool:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		return false
	var instance := packed.instantiate()
	var found: Array[MeshInstance3D] = []
	_collect(instance, found)
	instance.free()
	return not found.is_empty()


func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, out)


func _clear_cache() -> void:
	var dir := DirAccess.open(MeshMerge.CACHE_DIR)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)


func _finish() -> void:
	if failures.is_empty():
		print("MESH_MERGE_CHECK_GODOT PASS")
	else:
		print("MESH_MERGE_CHECK_GODOT FAIL (%d)" % failures.size())
		for failure in failures:
			print("  ", failure)
	quit(0 if failures.is_empty() else 1)
