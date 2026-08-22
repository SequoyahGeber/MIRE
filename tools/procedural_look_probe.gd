extends SceneTree

## 4.19 — eyeball probe for the SHIPPED procedural island. Boots `run/main_scene`, lets the
## streamer bring chunks in around the composer's own spawn, and saves three framed PNGs:
## the spawn view a player actually lands in, a high orbit of the whole island, and a look
## toward the Wellspring centroid (the direction `_pick_spawn()` promises landfall faces).
##
## Needs a renderer: run with `.agent/bin/agent godot --windowed --script tools/procedural_look_probe.gd`.
## Writes to `assets/audit/terrain/`, which is where terrain-look evidence already lives.

## The MAP, not `run/main_scene` (F-564). Since MENU-3's cutover the main scene is the front
## end, so loading that setting and treating the result as a level boots a menu. `ProbeScene`
## asks the front end what world it bypasses into (F-561).
const ProbeScene := preload("res://tools/probe_scene.gd")


const OUT_DIR: String = "res://assets/audit/terrain"
## Frames given to chunk streaming before each shot. First scatter lands in ~45 frames (F-287's
## measurement); LOD0 rings near the anchor take longer, and this is evidence, not a benchmark.
const SETTLE_FRAMES: int = 420


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("procedural_look_probe needs a renderer — run it with --windowed")
		quit(1)
		return
	var scene_path := String(ProbeScene.shipped_map_path())
	var packed := load(scene_path) as PackedScene
	var scene := packed.instantiate() as Node3D
	# The shipped main scene is the non-playable frontend now. Follow its declared PLAY target just
	# as verify_setup does, so this remains a probe of the shipped world rather than the title screen.
	if scene != null and scene.get_script() == load("res://ui/frontend/frontend.gd"):
		scene_path = String(scene.call("_world_scene_path"))
		scene.free()
		packed = load(scene_path) as PackedScene
		scene = packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	if not scene.has_method(&"height_at") or scene.get(&"spawn_position") == null:
		push_error("main scene %s is not the procedural composer" % scene_path)
		quit(1)
		return

	var spawn: Vector3 = scene.get(&"spawn_position")
	# An offscreen SubViewport, same as tools/atmosphere_look_shot.gd: the root window carries
	# boot UI overlays and its own size, and neither belongs in terrain evidence.
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = false
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 72.0
	camera.far = 4000.0
	viewport.add_child(camera)
	camera.make_current()

	for _frame: int in SETTLE_FRAMES:
		await process_frame

	var inland: Vector3 = Vector3.ZERO   # island centre — the direction play moves
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var shots: Array = [
		["island_spawn_view", spawn + Vector3.UP * 2.0, inland + Vector3.UP * 12.0],
		["island_orbit", Vector3(spawn.x * 1.15, 260.0, spawn.z * 1.15), inland],
		["island_shore_look", spawn + Vector3.UP * 22.0 + (spawn - inland).normalized() * 55.0,
			spawn],
	]
	for shot: Array in shots:
		camera.global_position = shot[1]
		camera.look_at(shot[2] as Vector3, Vector3.UP)
		# Volumetric fog reprojects temporally; give the froxels frames to converge per view.
		for _frame: int in 90:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = viewport.get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, String(shot[0])]
		var error: int = image.save_png(path)
		print("SHOT %s -> %s (%s)" % [shot[0],
			ProjectSettings.globalize_path(path), error_string(error)])

	print("PROCEDURAL_LOOK_PROBE done seed=%s" % str(scene.get(&"world_seed")))
	quit(0)
