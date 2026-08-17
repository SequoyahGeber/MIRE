extends SceneTree

## Diagnostic for "the crawlers walk backwards and attack facing away".
##
## Renders one crawler at yaw 0 from a camera placed along -Z — the direction the asset docs say the
## model faces. If the render shows its head, the asset and the code agree and the bug is elsewhere;
## if it shows its tail, the model's forward is +Z and `Enemy._face()` is pointing the wrong end.

const ENEMY_DEF := preload("res://systems/enemies/enemy_def.gd")
const OUTPUT_PATH: String = "/tmp/mire_crawler_facing.png"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(960, 540)
	await process_frame
	await process_frame

	var world: Node = root.get_node_or_null(^"EnemyWorld")

	# A real Enemy through the real spawn path, turned by the real _face() toward a real player —
	# not a bare model at yaw 0. The bug was that the whole chain pointed the wrong end at the
	# player, so the whole chain is what has to be looked at.
	var player := Node3D.new()
	player.name = "1"
	player.add_to_group(&"players")
	root.add_child(player)
	player.global_position = Vector3(0.0, 0.0, -6.0)

	var visual: Node3D = world.call("host_spawn", &"crawler", Vector3.ZERO)
	await process_frame
	for _i: int in 30:
		visual.call("_physics_process", 0.1)
	print("enemy yaw after facing a player at -Z: %.1f deg" % rad_to_deg(visual.rotation.y))

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40.0, 150.0, 0.0)
	root.add_child(light)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.25, 0.3, 0.28)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.6, 0.65, 0.6)
	environment.ambient_light_energy = 1.2
	env.environment = environment
	root.add_child(env)

	# Camera on the -Z side, looking back toward +Z. A model whose forward really is -Z shows its
	# FRONT from here.
	var camera := Camera3D.new()
	camera.current = true
	root.add_child(camera)
	# In the tree FIRST: look_at needs a global transform, and outside the tree it errors and leaves
	# the camera pointing at nothing.
	camera.look_at_from_position(Vector3(0.0, 0.55, -2.4), Vector3(0.0, 0.3, 0.0), Vector3.UP)

	var aabb: AABB = _visual_bounds(visual.get_node(^"EnemyVisual") as Node3D)
	print("crawler local AABB position=%v size=%v" % [aabb.position, aabb.size])
	print("longest axis: %s" % ("Z (front-to-back)" if aabb.size.z > aabb.size.x else "X (side-to-side)"))

	# Both sides, so "which end is the head" is a comparison rather than a guess.
	# The camera sits where the player is. A correct fix shows the crawler's face.
	for view: Dictionary in [
		{"pos": Vector3(0.0, 0.45, -2.4), "path": "/tmp/mire_crawler_facing_player.png",
			"label": "from the player's eye"},
	]:
		camera.look_at_from_position(view["pos"], Vector3(0.0, 0.28, 0.0), Vector3.UP)
		await process_frame
		await process_frame
		await process_frame
		var image: Image = root.get_texture().get_image()
		if image.save_png(String(view["path"])) != OK:
			push_error("render failed")
			quit(1)
			return
		print("ENEMY_FACING_RENDER %s (%s)" % [view["path"], view["label"]])
	quit(0)


func _visual_bounds(node: Node3D) -> AABB:
	var bounds := AABB()
	var first: bool = true
	for child: Node in node.find_children("*", "VisualInstance3D", true, false):
		var vis := child as VisualInstance3D
		var box: AABB = vis.get_aabb()
		box.position += vis.position
		if first:
			bounds = box
			first = false
		else:
			bounds = bounds.merge(box)
	return bounds
