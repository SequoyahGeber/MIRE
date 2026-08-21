extends SceneTree

## Rendered proof for F-433 — what the enemy bars and the damage numbers actually look like.
##
##   .agent/bin/agent godot --windowed --script tools/target_feedback_shot.gd
##
## `tools/target_feedback_check.gd` proves the RULES — who gets a bar, what the number says, when it
## fades. Only pixels prove the things that decide whether this is worth shipping: that a bar reads
## against foliage at twenty metres, that it sits above the head rather than through it, and that a
## "-5" is legible for the fifth of a second it is at full opacity. Windowed because reading the
## framebuffer back needs one (F-077).
##
## Two shots: a knot of crawlers at mixed health and distance, and the same scene mid-swing with a
## damage number and a wrong-tool "0" in flight.

const GROUND_PATH: String = "/tmp/mire_target_bars.png"
const NUMBERS_PATH: String = "/tmp/mire_damage_numbers.png"

var _hud: Node
var _numbers: Node


func _initialize() -> void:
	_render.call_deferred()


func _render() -> void:
	_resize(Vector2i(1280, 720))
	await process_frame
	await process_frame

	_hud = root.get_node(^"TargetHealthHud")
	_numbers = root.get_node(^"DamageNumbers")
	var world: Node = root.get_node(^"EnemyWorld")

	_build_stage()
	await process_frame

	# Mixed on purpose: full health up close, half a bar at mid range, nearly dead far out. One shot
	# has to answer "can I read this at a glance", and a row of identical bars would not.
	var near: Node3D = _spawn(world, Vector3(-1.6, 0.0, -5.0))
	var mid: Node3D = _spawn(world, Vector3(1.8, 0.0, -11.0))
	var far: Node3D = _spawn(world, Vector3(-0.4, 0.0, -22.0))
	mid.set(&"health", maxi(int(mid.get(&"health")) / 2, 1))
	far.set(&"health", 1)
	await process_frame
	_hud.call(&"refresh_now")
	await _save(GROUND_PATH, "TARGET_BARS_SHOT")

	# Mid-swing: the number the host applied, and the deliberate "0" a pickaxe bouncing off a pine
	# reports through the same path.
	_numbers.call(&"show_damage", near.global_position, 5)
	_numbers.call(&"show_damage", mid.global_position, 12)
	_numbers.call(&"show_damage", far.global_position, 0)
	_numbers.call(&"_advance", 0.18)
	_hud.call(&"refresh_now")
	await _save(NUMBERS_PATH, "DAMAGE_NUMBERS_SHOT")
	quit(0)


func _spawn(world: Node, at: Vector3) -> Node3D:
	var enemy: Node3D = world.call("host_spawn", &"crawler", at)
	if enemy != null:
		# Frozen: this file renders a frame, and an enemy that charges the camera between the spawn
		# and the readback is rendering a different scene than the one being described.
		enemy.set_physics_process(false)
	return enemy


## Camera, ground and a warm key light. A bar shot against the void proves nothing about contrast,
## which is the whole reason this file renders instead of asserting.
func _build_stage() -> void:
	var camera := Camera3D.new()
	camera.name = "ShotCamera"
	root.add_child(camera)
	camera.global_position = Vector3(0.0, 1.7, 0.0)
	camera.make_current()

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(120.0, 120.0)
	ground.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.20, 0.26, 0.17)
	material.roughness = 1.0
	ground.material_override = material
	ground.position = Vector3(0.0, 0.0, -30.0)
	root.add_child(ground)

	var light := DirectionalLight3D.new()
	light.light_energy = 1.2
	light.light_color = Color(1.0, 0.94, 0.84)
	light.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	root.add_child(light)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.42, 0.50, 0.52)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.44, 0.48, 0.46)
	environment.ambient_light_energy = 0.7
	camera.environment = environment


func _resize(window_size: Vector2i) -> void:
	root.content_scale_size = window_size
	root.size = window_size


func _save(path: String, tag: String) -> bool:
	await process_frame
	await process_frame
	await process_frame
	var image: Image = root.get_texture().get_image()
	var error: Error = image.save_png(path)
	if error != OK:
		push_error("%s failed: %s" % [tag, error_string(error)])
		quit(1)
		return false
	print("%s %s %dx%d" % [tag, path, image.get_width(), image.get_height()])
	return true
