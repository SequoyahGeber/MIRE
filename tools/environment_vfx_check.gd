extends SceneTree

const SCENE_PATH: String = "res://levels/playtest_hollow.tscn"
const VFX_SCRIPT := preload("res://autoload/environment_vfx.gd")
const FOLIAGE_SHADER := preload("res://world/environment/foliage_wind.gdshader")

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
	var controller := scene.find_child("EnvironmentVfx", true, false)
	if controller == null:
		controller = VFX_SCRIPT.new() as Node
		root.add_child(controller)
	for _frame: int in 10:
		await process_frame
	check(int(controller.get("foliage_mesh_count")) >= 50, "foliage wind reaches the authored ground cover")
	check(int(controller.get("fire_source_count")) >= 2, "fire VFX replaces at least the camp and ridge flames")
	var animated_foliage: int = 0
	var hidden_fire_sources: int = 0
	var fire_effects: int = 0
	for node: Node in _all_descendants(scene):
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			if mesh_instance.get_surface_override_material_count() > 0:
				var override := mesh_instance.get_surface_override_material(0)
				if override is ShaderMaterial and (override as ShaderMaterial).shader == FOLIAGE_SHADER:
					animated_foliage += 1
			if not mesh_instance.visible and ("flame" in String(mesh_instance.name).to_lower() or "fire" in String(mesh_instance.name).to_lower()):
				hidden_fire_sources += 1
		if node.name == &"ClientFireVfx":
			fire_effects += 1
			check(_count_type(node, GPUParticles3D) == 3, "each fire has flame, spark, and smoke emitters")
			check(_count_type(node, OmniLight3D) == 1, "each fire has one flickering light")
	check(animated_foliage >= 50, "foliage surfaces use the wind shader")
	check(hidden_fire_sources >= 2, "static flame placeholders are hidden")
	check(fire_effects >= 2, "runtime fire effects exist")
	print("ENVIRONMENT_VFX_CHECK foliage=%d fires=%d failures=%d" % [animated_foliage, fire_effects, failures])
	finish()


func _all_descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child: Node in node.get_children():
		result.append(child)
		result.append_array(_all_descendants(child))
	return result


func _count_type(node: Node, type: Variant) -> int:
	var count: int = 0
	for child: Node in node.get_children():
		if is_instance_of(child, type):
			count += 1
	return count


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
