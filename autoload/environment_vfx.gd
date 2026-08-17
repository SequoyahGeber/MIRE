extends Node

## Client-local environmental presentation. Gameplay state never depends on this node.

const FOLIAGE_SHADER := preload("res://world/environment/foliage_wind.gdshader")
const PARTICLE_SHADER := preload("res://world/environment/particle_billboard.gdshader")
const VFX_META: StringName = &"mire_environment_vfx_applied"
const FOLIAGE_WORDS: Array[String] = ["grass", "fern", "reed", "sedge"]
const FIRE_WORDS: Array[String] = ["flame_outer", "furnace_fire"]

var foliage_mesh_count: int = 0
var fire_source_count: int = 0
var _foliage_materials: Dictionary = {}
var _fire_lights: Array[OmniLight3D] = []
var _time: float = 0.0


func _ready() -> void:
	# Imported GLBs can enter the tree after autoloads, so cover both the current scene and later nodes.
	get_tree().node_added.connect(_on_node_added)
	call_deferred("refresh_scene")


func _process(delta: float) -> void:
	_time += delta
	for index: int in _fire_lights.size():
		var light := _fire_lights[index]
		if not is_instance_valid(light):
			continue
		var flutter := sin(_time * 10.7 + float(index) * 1.91) * 0.13
		var pulse := sin(_time * 4.1 + float(index) * 0.73) * 0.1
		light.light_energy = 2.25 + flutter + pulse


func refresh_scene() -> void:
	var scene := get_tree().current_scene
	if scene != null:
		_apply_recursive(scene)


func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D:
		call_deferred("_apply_mesh", node as MeshInstance3D)


func _apply_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		_apply_mesh(node as MeshInstance3D)
	for child: Node in node.get_children():
		_apply_recursive(child)


func _apply_mesh(mesh_instance: MeshInstance3D) -> void:
	if not is_instance_valid(mesh_instance) or mesh_instance.has_meta(VFX_META):
		return
	mesh_instance.set_meta(VFX_META, true)
	var identity := _node_identity(mesh_instance)
	if _contains_any(identity, FOLIAGE_WORDS):
		_apply_foliage(mesh_instance)
	if _is_fire_source(mesh_instance, identity):
		_apply_fire(mesh_instance)


func _apply_foliage(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.mesh == null:
		return
	var bounds := mesh_instance.get_aabb()
	if bounds.size.y <= 0.001:
		return
	for surface_index: int in mesh_instance.mesh.get_surface_count():
		var original := mesh_instance.get_active_material(surface_index)
		var shader_material := _foliage_material_for(original)
		mesh_instance.set_surface_override_material(surface_index, shader_material)
	mesh_instance.set_instance_shader_parameter(&"wind_root_y", bounds.position.y)
	mesh_instance.set_instance_shader_parameter(&"wind_inv_height", 1.0 / bounds.size.y)
	mesh_instance.set_instance_shader_parameter(
		&"wind_phase", fposmod(mesh_instance.global_position.x * 0.37 + mesh_instance.global_position.z * 0.61, TAU)
	)
	foliage_mesh_count += 1


func _foliage_material_for(original: Material) -> ShaderMaterial:
	var color := Color(0.24, 0.42, 0.16)
	var material_roughness: float = 0.9
	if original is StandardMaterial3D:
		var standard := original as StandardMaterial3D
		color = standard.albedo_color
		material_roughness = standard.roughness
	var key := "%s:%.3f" % [color.to_html(), material_roughness]
	if _foliage_materials.has(key):
		return _foliage_materials[key] as ShaderMaterial
	var material := ShaderMaterial.new()
	material.shader = FOLIAGE_SHADER
	material.set_shader_parameter(&"albedo_color", color)
	material.set_shader_parameter(&"roughness", material_roughness)
	_foliage_materials[key] = material
	return material


func _is_fire_source(mesh_instance: MeshInstance3D, identity: String) -> bool:
	if _contains_any(identity, FIRE_WORDS):
		return true
	if mesh_instance.mesh == null:
		return false
	for surface_index: int in mesh_instance.mesh.get_surface_count():
		var material := mesh_instance.get_active_material(surface_index)
		if material != null and "station_fire_orange" in material.resource_name.to_lower():
			return "outer" in identity or "furnace" in identity
	return false


func _apply_fire(source: MeshInstance3D) -> void:
	var parent := source.get_parent() as Node3D
	if parent == null:
		return
	var effect := Node3D.new()
	effect.name = "ClientFireVfx"
	effect.transform = source.transform
	effect.set_meta(VFX_META, true)
	parent.add_child(effect)
	source.visible = false

	var flames := _make_particles(30, 0.72, Vector2(0.18, 0.38), Color(1.0, 0.72, 0.08, 0.88), Color(1.0, 0.08, 0.01, 0.0), 0)
	var flame_process := flames.process_material as ParticleProcessMaterial
	flame_process.direction = Vector3.UP
	flame_process.spread = 18.0
	flame_process.initial_velocity_min = 0.55
	flame_process.initial_velocity_max = 1.15
	flame_process.gravity = Vector3(0.0, 0.45, 0.0)
	flame_process.scale_min = 0.45
	flame_process.scale_max = 1.15
	effect.add_child(flames)

	var sparks := _make_particles(13, 1.15, Vector2(0.025, 0.025), Color(1.0, 0.78, 0.16, 1.0), Color(1.0, 0.12, 0.01, 0.0), 1)
	var spark_process := sparks.process_material as ParticleProcessMaterial
	spark_process.direction = Vector3.UP
	spark_process.spread = 28.0
	spark_process.initial_velocity_min = 0.85
	spark_process.initial_velocity_max = 1.8
	spark_process.gravity = Vector3(0.0, -0.35, 0.0)
	spark_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	spark_process.emission_sphere_radius = 0.16
	effect.add_child(sparks)

	var smoke := _make_particles(9, 2.4, Vector2(0.26, 0.26), Color(0.19, 0.17, 0.2, 0.2), Color(0.08, 0.07, 0.1, 0.0), 2)
	var smoke_process := smoke.process_material as ParticleProcessMaterial
	smoke_process.direction = Vector3.UP
	smoke_process.spread = 14.0
	smoke_process.initial_velocity_min = 0.35
	smoke_process.initial_velocity_max = 0.62
	smoke_process.gravity = Vector3(0.08, 0.04, 0.03)
	smoke_process.scale_min = 0.55
	smoke_process.scale_max = 1.4
	smoke.position.y = 0.28
	effect.add_child(smoke)

	var light := OmniLight3D.new()
	light.name = "FireLight"
	light.light_color = Color(1.0, 0.42, 0.12)
	light.light_energy = 2.25
	light.omni_range = 5.5
	light.shadow_enabled = true
	light.position.y = 0.42
	effect.add_child(light)
	_fire_lights.append(light)
	fire_source_count += 1


func _make_particles(amount: int, lifetime: float, size: Vector2, start_color: Color, end_color: Color, particle_shape: int) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.randomness = 0.42
	particles.visibility_aabb = AABB(Vector3(-2.0, -0.5, -2.0), Vector3(4.0, 5.0, 4.0))
	var process := ParticleProcessMaterial.new()
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([start_color, end_color])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	particles.process_material = process

	var quad := QuadMesh.new()
	quad.size = size
	quad.orientation = PlaneMesh.FACE_Z
	var draw_material := ShaderMaterial.new()
	draw_material.shader = PARTICLE_SHADER
	draw_material.set_shader_parameter(&"particle_shape", particle_shape)
	quad.material = draw_material
	particles.draw_pass_1 = quad
	return particles


func _node_identity(node: Node) -> String:
	var parts: Array[String] = []
	var cursor: Node = node
	for _depth: int in 6:
		if cursor == null:
			break
		parts.append(String(cursor.name).to_lower())
		cursor = cursor.get_parent()
	return "/".join(parts)


func _contains_any(value: String, words: Array[String]) -> bool:
	for word: String in words:
		if word in value:
			return true
	return false
