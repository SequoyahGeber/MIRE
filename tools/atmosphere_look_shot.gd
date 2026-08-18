extends SceneTree

## Renders the shipped map at several times of day to PNGs, so a change to the LOOK can be judged
## by looking at it instead of by reading the diff.
##
## Needs a real renderer, so run it windowed. The wrapper forces a 64x64 window (F-077), which is
## why this renders through a SubViewport of its own size rather than through the main window — the
## window is irrelevant, only the renderer has to be real.
##
##   .agent/bin/agent godot --windowed --script tools/atmosphere_look_shot.gd
##
## Writes to `user://atmosphere_look/`; the run prints the absolute paths.

const WIDTH: int = 1280
const HEIGHT: int = 720
const OUT_DIR: String = "user://atmosphere_look"
## label, hour, camera position, look-at target. Chosen to put the mere and the valley floor in
## frame from a low vantage, which is where ground mist either works or does not.
## The sun's elevation is `sin((hour - 6) / 24 * TAU) * 90`, so hour 6 is exactly sunrise, 12 is
## exactly overhead and 18 is exactly sunset — and golden hour is only about 1.2 game-hours wide
## either side of those. The first run of this used 18.6 for "dusk" and rendered full night.
const SHOTS: Array = [
	["dawn", 6.25, Vector3(6.0, 6.0, 34.0), Vector3(-18.0, 0.0, 6.0)],
	["golden_morning", 6.9, Vector3(6.0, 6.0, 34.0), Vector3(-18.0, 0.0, 6.0)],
	["morning", 8.35, Vector3(6.0, 6.0, 34.0), Vector3(-18.0, 0.0, 6.0)],
	["noon", 12.0, Vector3(6.0, 6.0, 34.0), Vector3(-18.0, 0.0, 6.0)],
	["golden_evening", 17.2, Vector3(6.0, 6.0, 34.0), Vector3(-18.0, 0.0, 6.0)],
	["dusk", 17.85, Vector3(6.0, 6.0, 34.0), Vector3(-18.0, 0.0, 6.0)],
	["dawn_ridge", 6.5, Vector3(26.0, 28.0, 26.0), Vector3(-10.0, 0.0, 0.0)],
	["night", 22.0, Vector3(6.0, 6.0, 34.0), Vector3(-18.0, 0.0, 6.0)],
	["golden_sunward", 6.7, Vector3(4.0, 5.0, 20.0), Vector3.ZERO],
	["morning_sunward", 8.35, Vector3(4.0, 5.0, 20.0), Vector3.ZERO],
	["evening_sunward", 17.3, Vector3(4.0, 5.0, 20.0), Vector3.ZERO],
	## Standing among trunks with a low sun behind them — the only place shafts can actually be
	## carved, since a shaft is a shadow cut through the fog and needs something to cast it.
	["forest_sunward", 6.7, Vector3(-26.0, 3.4, 22.0), Vector3.ZERO],
	["forest_evening_sunward", 17.35, Vector3(-26.0, 3.4, 22.0), Vector3.ZERO],
	## Close on a stand of trees, where falling leaves are large enough on screen to judge.
	["canopy_leaves", 9.5, Vector3(-14.0, 4.0, 30.0), Vector3(-26.0, 4.5, 22.0)],
	["canopy_leaves_golden", 6.8, Vector3(-14.0, 4.0, 30.0), Vector3(-26.0, 4.5, 22.0)],
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("atmosphere_look_shot needs a renderer — run it with --windowed")
		quit(1)
		return
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	var scene := (load(scene_path) as PackedScene).instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 20:
		await process_frame
	await physics_frame

	var atmosphere: Node = scene.get_node_or_null(^"Atmosphere")
	if atmosphere == null:
		push_error("no Atmosphere node on %s" % scene_path)
		quit(1)
		return
	# DayNight owns the clock and re-applies it EVERY physics tick, so setting the hour on the
	# atmosphere directly is overwritten before the next frame is drawn — the first run of this
	# script rendered six identical mid-morning shots for exactly that reason. Drive DayNight
	# instead, in its own 0..1 units.
	var day_night: Node = root.get_node_or_null(^"DayNight")
	if day_night == null:
		push_error("DayNight autoload is missing; the clock cannot be posed")
		quit(1)
		return

	var fog: Node = atmosphere.get_node_or_null(^"GroundFog")
	print("GROUNDFOG present=%s base_height=%s size=%s material=%s" % [
		fog != null,
		"n/a" if fog == null else str(fog.get("base_height")),
		"n/a" if fog == null else str(fog.get("size")),
		"n/a" if fog == null else str(fog.get("material")),
	])

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(WIDTH, HEIGHT)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = false
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 72.0
	camera.far = 400.0
	viewport.add_child(camera)
	camera.make_current()

	var sun := scene.get_node_or_null(^"Sun") as DirectionalLight3D
	for shot_value: Variant in SHOTS:
		var shot: Array = shot_value as Array
		day_night.set("time_of_day", float(shot[1]) / 24.0)
		atmosphere.call(&"set_time_of_day", float(shot[1]))
		camera.global_position = shot[2] as Vector3
		if String(shot[0]).ends_with("_sunward") and sun != null:
			# A DirectionalLight3D shines along its own -Z, so the sun itself is at +Z of its basis.
			# Looking that way is the only frame that can tell you whether the shafts are working.
			await process_frame
			camera.look_at(camera.global_position + sun.global_basis.z * 60.0, Vector3.UP)
		else:
			camera.look_at(shot[3] as Vector3, Vector3.UP)
		# Volumetric fog uses temporal reprojection, so the first frames after a jump are still
		# blending in the previous camera's froxels. Give it enough frames to converge or every
		# shot is judged on a smear.
		for _frame: int in 30:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = viewport.get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, String(shot[0])]
		var error: int = image.save_png(path)
		var fog_scale: Variant = "n/a" if fog == null else fog.get("density_scale")
		print("SHOT %s hour=%.2f fog_scale=%s -> %s (%s)" % [
			String(shot[0]), float(shot[1]), str(fog_scale),
			ProjectSettings.globalize_path(path), error_string(error)
		])
	print("ATMOSPHERE_LOOK_SHOT dir=%s" % ProjectSettings.globalize_path(OUT_DIR))
	quit(0)
