extends SceneTree

## Environmental VFX on **Playtest Hollow**, the hand-authored fixture.
##
## Hollowmere is covered by `tools/environment_vfx_hollowmere_check.gd`; this one earns its keep by
## being the opposite kind of map. Playtest Hollow's props are loose `MeshInstance3D` nodes with no
## `asset` meta, so it is the only place the **name fallback** in `EnvironmentVfx._asset_id_for` is
## exercised — the path that keeps a scene someone assembles by hand in the editor working.
##
## It reads the registered autoload. A check that builds its own controller cannot see the shipped
## one, and would also read zeros: the autoload marks each node as done, so a second controller
## walking the same tree correctly skips everything and reports nothing.

const FOLIAGE_SHADER := preload("res://world/environment/foliage_wind.gdshader")
const AssetVfx := preload("res://world/environment/asset_vfx_library.gd")
const SCENE_PATH: String = "res://levels/playtest_hollow.tscn"

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	check(packed != null, "playtest hollow loads")
	if packed == null:
		finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene

	var controller: Node = root.get_node_or_null(^"EnvironmentVfx")
	check(controller != null, "EnvironmentVfx is registered as an autoload")
	if controller == null:
		finish()
		return
	for _frame: int in 60:
		await process_frame

	var wind_meshes: int = 0
	var hidden_placeholders: int = 0
	var unmatched: PackedStringArray = PackedStringArray()
	for node: Node in _all_descendants(scene):
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			if _uses_wind(mesh_instance.mesh):
				wind_meshes += 1
			elif unmatched.size() < 8 and mesh_instance.mesh != null:
				unmatched.append(String(mesh_instance.name))
			var lowered := String(mesh_instance.name).to_lower()
			if not mesh_instance.visible and ("flame" in lowered or "fire" in lowered):
				hidden_placeholders += 1

	print("PLAYTEST_HOLLOW wind_meshes=%d hidden_placeholders=%d sway_assets=%d"
		% [wind_meshes, hidden_placeholders, int(controller.get("sway_asset_count"))])
	if wind_meshes == 0:
		print("UNMATCHED sample: %s" % ", ".join(unmatched))

	var sites: Dictionary = controller.call(&"site_counts")
	for emitter: int in sites:
		print("EMITTER %d sites=%d" % [emitter, int(sites[emitter])])

	check(wind_meshes >= 50, "the name fallback finds this map's foliage without any asset meta")
	check(hidden_placeholders >= 2, "static flame placeholders are replaced, not decorated")
	check(int(controller.get("fire_source_count")) >= 2, "the camp and ridge fires are found")
	print("ENVIRONMENT_VFX_CHECK foliage=%d failures=%d" % [wind_meshes, failures])
	finish()


func _uses_wind(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for surface: int in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface)
		if material is ShaderMaterial and (material as ShaderMaterial).shader == FOLIAGE_SHADER:
			return true
	return false


func _all_descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child: Node in node.get_children():
		result.append(child)
		result.append_array(_all_descendants(child))
	return result


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
