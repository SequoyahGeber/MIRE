extends SceneTree

## F-432 — a look at what chopping a tree now leaves behind.
##
## `tools/harvest_tree_states_check.gd` asserts the numbers; this one exists because "is that a
## stump?" is a question about a picture. It stands three real scattered trees side by side, chops
## the middle group down through the same host path a swing takes, and saves one image of each row:
## intact, mid-chop (leaning), and felled.
##
##   .agent/bin/agent godot --windowed --script tools/harvest_tree_states_shot.gd
##
## Windowed on purpose (F-005/F-077): `agent godot` always passes --headless, whose dummy renderer
## never draws, so `RenderingServer.frame_post_draw` would never fire. With no framebuffer this
## still runs and still chops; it just says it could not capture.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only apart from the props it builds itself.

const FIELD := preload("res://world/gen/resource_scatter_field.gd")

const OUT_DIR: String = "res://assets/audit/harvest"
const SUBJECTS: Array = [
	["flora", "tree_willow_a"],
	["environment", "tree_pine_c"],
	["environment", "tree_birch_a"],
]
const SPACING_M: float = 9.0
const TOOL_CLASS: int = 1
const TOOL_POWER: int = 3


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := Node3D.new()
	scene.name = "TreeStatesShot"
	root.add_child(scene)
	current_scene = scene

	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.16, 0.20, 0.17)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.72, 0.76, 0.70)
	settings.ambient_light_energy = 0.9
	environment.environment = settings
	scene.add_child(environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -38.0, 0.0)
	sun.light_energy = 1.5
	scene.add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	ground.mesh = plane
	scene.add_child(ground)

	var field: Node3D = FIELD.new()
	var harvestables: Array[Node] = []
	for index: int in SUBJECTS.size():
		var kit := String(SUBJECTS[index][0])
		var asset := String(SUBJECTS[index][1])
		var parts: Array = field.call("_load_mesh_parts", kit, asset)
		if parts.is_empty():
			continue
		field.call("_build_node_holder", scene, {
			"point_id": "shot:%s" % asset,
			"position": Vector3((float(index) - 1.0) * SPACING_M, 0.0, 0.0),
			"rotation_y": 0.0,
			"scale": 1.0,
		}, StringName(asset), kit, parts)

	var camera := Camera3D.new()
	camera.fov = 55.0
	camera.far = 300.0
	scene.add_child(camera)
	camera.current = true

	for _frame: int in 20:
		await process_frame
	for holder: Node in scene.get_children():
		var harvestable: Node = holder.get_node_or_null(^"Harvestable")
		if harvestable != null:
			harvestables.append(harvestable)

	var can_capture := DisplayServer.get_name() != "headless"
	if not can_capture:
		print("HARVEST_TREE_STATES_SHOT capture skipped — headless has no framebuffer")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	await _shoot(camera, "intact", can_capture)
	for harvestable: Node in harvestables:
		harvestable.call("host_apply_tool_damage", TOOL_CLASS, TOOL_POWER, 1)
	# Past the shake, so the picture shows the LEAN rather than a frame of the wobble.
	for _frame: int in 60:
		await process_frame
	await _shoot(camera, "chopping", can_capture)
	for harvestable: Node in harvestables:
		while bool(harvestable.get("active")):
			harvestable.call("host_apply_tool_damage", TOOL_CLASS, TOOL_POWER, 1)
	for _frame: int in 10:
		await process_frame
	await _shoot(camera, "felled", can_capture)

	print("HARVEST_TREE_STATES_SHOT display=%s trees=%d" % [
		DisplayServer.get_name(), harvestables.size()])
	field.free()
	quit()


func _shoot(camera: Camera3D, name: String, can_capture: bool) -> void:
	# Two framings per state: the row of trees, and a close crop on the middle one's base, because
	# the stump is 0.6 m of a 19 m picture and is otherwise a few pixels.
	var framings: Array = [
		["wide", Vector3(0.0, 8.0, 30.0), Vector3(0.0, 7.0, 0.0)],
		["base", Vector3(-6.0, 1.6, 7.5), Vector3(-7.5, 0.7, 0.0)],
	]
	for framing: Array in framings:
		camera.global_position = framing[1] as Vector3
		camera.look_at(framing[2] as Vector3, Vector3.UP)
		for _frame: int in 6:
			await process_frame
		if not can_capture:
			continue
		await RenderingServer.frame_post_draw
		var path := "%s/tree_%s_%s.png" % [OUT_DIR, name, String(framing[0])]
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
		print("HARVEST_TREE_SHOT %s/%s -> %s" % [name, String(framing[0]), path])
