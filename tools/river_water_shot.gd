extends SceneTree

## F-478 — eyeball evidence that the procedural island's river has water in it.
##
##   .agent/bin/agent godot --windowed --script tools/river_water_shot.gd
##
## Boots the shipped scene, finds the deepest point of THIS seed's river by walking the sheet the
## same way `RiverWater` builds it, anchors chunk streaming there so the valley actually meshes, and
## saves two framed PNGs into `assets/audit/terrain/` — a bank-level look down the channel, which is
## the view play reported as a dry quarry, and a low orbit that shows the whole course running to
## the sea. Same SubViewport shape as `tools/procedural_look_probe.gd`, for the same reason: the root
## window carries boot UI and its own size, and neither belongs in terrain evidence.

const IslandHeightmap = preload("res://world/gen/island_heightmap.gd")
const OUT_DIR: String = "res://assets/audit/terrain"
const SETTLE_FRAMES: int = 420


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("river_water_shot needs a renderer — run it with --windowed")
		quit(1)
		return
	# The island scene by path, not `run/main_scene`: that boots the frontend now, and this wants the
	# world the frontend eventually loads. Same file `tools/procedural_world_check.gd` boots.
	var scene_path := "res://levels/procedural_island.tscn"
	var scene := (load(scene_path) as PackedScene).instantiate() as Node3D
	# No player body. It is not just unwanted furniture: `ChunkStreamer`'s anchors follow the players
	# group, so a spawned player parks streaming on the shore and the river valley — which is where
	# this is pointing a camera — never meshes at all. The first run of this tool produced two
	# frames of empty ocean for exactly that reason.
	scene.set(&"build_player", false)
	root.add_child(scene)
	current_scene = scene
	if not scene.has_method(&"water_surface_at"):
		push_error("main scene %s is not the procedural composer" % scene_path)
		quit(1)
		return
	var world_seed: int = int(scene.get(&"world_seed"))

	# The deepest water on the map, and the river's own direction there. Walked over the same
	# corridor bound `RiverWater` marches, at a coarser step — this is aiming a camera, not meshing.
	var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
	var line: PackedVector2Array = IslandHeightmap.river_polyline(world_seed)
	var shape: IslandHeightmap.Shape = IslandHeightmap.Shape.new()
	var best := Vector2.ZERO
	var best_depth: float = 0.0
	var best_t: float = 0.0
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for point: Vector2 in line:
		lo = lo.min(point)
		hi = hi.max(point)
	var margin: float = IslandHeightmap.RIVER_WIDTH_MOUTH * IslandHeightmap.RIVER_WATER_REACH \
		+ IslandHeightmap.SHAPE_WARP_AMPLITUDE * sqrt(2.0)
	lo -= Vector2(margin, margin)
	hi += Vector2(margin, margin)
	var z: float = lo.y
	while z <= hi.y:
		var x: float = lo.x
		while x <= hi.x:
			IslandHeightmap.shape_into(x, z, set, world_seed, shape)
			var track: Vector2 = IslandHeightmap.river_water_band_on(line, shape.bent)
			if track.x >= 0.0:
				var ground: float = IslandHeightmap.height_from_shape(x, z, shape, set)
				var level: float = IslandHeightmap.river_water_level_on(line, shape, ground)
				if level > -INF and level - ground > best_depth:
					best_depth = level - ground
					best = Vector2(x, z)
					best_t = track.x
			x += 3.0
		z += 3.0
	if best_depth <= 0.0:
		push_error("no river water anywhere on seed %d — that is the F-478 defect, not a shot" % world_seed)
		quit(1)
		return
	var here := Vector3(best.x, float(scene.call(&"water_surface_at", best.x, best.y)), best.y)
	print("RIVER seed=%d deepest %.2f m at %s (t=%.2f)" % [world_seed, best_depth, here, best_t])

	# Downstream, in world coordinates, taken as the direction the MOUTH lies in: the polyline's
	# last point is the mouth, and while the warp bends the line it never reverses it (the amplitude
	# is a tenth of the length), so this is a sound bearing even without inverting the warp.
	var downstream := Vector2(line[line.size() - 1] - line[0]).normalized()
	var flow := Vector3(downstream.x, 0.0, downstream.y)

	if scene.get(&"streamer") != null:
		var anchors: Array[Vector3] = [here]
		(scene.get(&"streamer") as Node).call(&"set_anchors", anchors)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 900)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = false
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 70.0
	camera.far = 4000.0
	viewport.add_child(camera)
	camera.make_current()
	for _frame: int in SETTLE_FRAMES:
		await process_frame

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var shots: Array = [
		# Standing on the bank, looking down the channel — the framing of the play capture.
		["river_water_bank", here - flow * 16.0 + Vector3.UP * 3.2, here + flow * 26.0],
		# High enough to see the course, low enough that the sheet is more than a blue thread.
		["river_water_course", here - flow * 60.0 + Vector3.UP * 46.0, here + flow * 90.0],
	]
	for shot: Array in shots:
		camera.global_position = shot[1]
		camera.look_at(shot[2] as Vector3, Vector3.UP)
		for _frame: int in 90:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = viewport.get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, String(shot[0])]
		var error: int = image.save_png(path)
		print("SHOT %s -> %s (%s)" % [shot[0],
			ProjectSettings.globalize_path(path), error_string(error)])

	print("RIVER_WATER_SHOT done seed=%d" % world_seed)
	quit(0)
