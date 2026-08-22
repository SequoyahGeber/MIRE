extends SceneTree

## F-535 — a look at what a harvest leaves lying on the ground.
##
## `tools/item_drop_check.gd` asserts the numbers; this one exists because "does a floating icon read
## as a dropped item?" is a question about a picture. It drops three real items — log, stone and
## whatever else the registry has an icon for — onto a lit ground plane and photographs them at
## standing height and from close up.
##
##   .agent/bin/agent godot --windowed --script tools/item_drop_shot.gd
##
## Windowed on purpose (F-005/F-077): `agent godot` always passes --headless, whose dummy renderer
## never draws, so `RenderingServer.frame_post_draw` would never fire.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only apart from the drops it spawns itself.

const OUT_DIR: String = "res://assets/audit/drops"
const SUBJECTS: Array[StringName] = [&"log", &"stone", &"iron_ore"]
const SPACING_M: float = 1.1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := Node3D.new()
	scene.name = "ItemDropShot"
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

	# A real floor, on the terrain layer the drops' collision mask looks for — without it they fall
	# forever and the picture is of an empty field.
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = PlacementValidator.TERRAIN_LAYER
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	floor_shape.shape = box
	floor_shape.position.y = -0.5
	floor_body.add_child(floor_shape)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	floor_mesh.mesh = plane
	floor_body.add_child(floor_mesh)
	scene.add_child(floor_body)

	var drops: Node = root.get_node_or_null(^"ItemDropService")
	if drops == null:
		print("ITEM_DROP_SHOT ItemDropService is not registered")
		quit(1)
		return
	for index: int in SUBJECTS.size():
		drops.call("host_spawn_drop", SUBJECTS[index], index + 1, Vector3(
			(float(index) - 1.0) * SPACING_M, 0.0, 0.0
		))

	var camera := Camera3D.new()
	camera.fov = 70.0
	scene.add_child(camera)
	camera.current = true

	# Long enough for the pop to land and settle, so the picture shows where a drop RESTS.
	for _frame: int in 120:
		await process_frame

	var can_capture := DisplayServer.get_name() != "headless"
	if not can_capture:
		print("ITEM_DROP_SHOT capture skipped — headless has no framebuffer")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Eye height first: this is the only framing that answers whether a player walking past sees them.
	await _shoot(camera, "eye_level", Vector3(0.0, 1.65, 3.0), Vector3(0.0, 0.5, 0.0), can_capture)
	await _shoot(camera, "close", Vector3(0.6, 0.7, 1.4), Vector3(0.0, 0.45, 0.0), can_capture)
	await _shoot(camera, "above", Vector3(0.0, 3.0, 1.6), Vector3(0.0, 0.3, 0.0), can_capture)

	print("ITEM_DROP_SHOT display=%s drops=%d" % [DisplayServer.get_name(), int(drops.call("live_count"))])
	quit()


func _shoot(
	camera: Camera3D, shot_name: String, from: Vector3, at: Vector3, can_capture: bool
) -> void:
	camera.global_position = from
	camera.look_at(at, Vector3.UP)
	for _frame: int in 6:
		await process_frame
	if not can_capture:
		return
	await RenderingServer.frame_post_draw
	var path := "%s/drop_%s.png" % [OUT_DIR, shot_name]
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	print("ITEM_DROP_SHOT %s -> %s" % [shot_name, path])
