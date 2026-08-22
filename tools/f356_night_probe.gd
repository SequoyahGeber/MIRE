extends SceneTree

## Fixed-seed rendered proof for F-356/F-415. Production values only; every completed shot is appended
## immediately so an interrupted render can resume without losing finished work.

## The MAP, not `run/main_scene` (F-564). Since MENU-3's cutover the main scene is the front
## end, so loading that setting and treating the result as a level boots a menu. `ProbeScene`
## asks the front end what world it bypasses into (F-561).
const ProbeScene := preload("res://tools/probe_scene.gd")


const OUT_DIR: String = "res://assets/audit/lighting"
const LEDGER_PATH: String = OUT_DIR + "/f415_dark_night_render.jsonl"
const FIXED_SEED: int = 4242
const SETTLE_FRAMES: int = 420
const PER_SHOT_FRAMES: int = 90
const SHOTS: Array[Dictionary] = [
	{"label": "f415_10_noon_control", "hour": 12.0},
	{"label": "f415_11_blue_hour", "hour": 19.5},
	{"label": "f415_12_dark_moonlit_night", "hour": 0.0},
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("f356_night_probe needs --windowed")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var completed: Dictionary = _completed_labels()
	var game_state: Node = root.get_node_or_null(^"GameState")
	if game_state != null:
		game_state.call(&"set_replicated_seed", FIXED_SEED)
	var scene_path := String(ProbeScene.shipped_map_path())
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("could not load main scene %s" % scene_path)
		quit(1)
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene

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
	var day_night: Node = root.get_node_or_null(^"DayNight")
	if day_night != null:
		day_night.set_physics_process(false)
	var atmosphere: Node = scene.get_node_or_null(^"Atmosphere")
	if atmosphere == null:
		push_error("main scene is missing Atmosphere")
		quit(1)
		return
	var spawn: Vector3 = scene.get(&"spawn_position")
	camera.global_position = spawn + Vector3.UP * 2.0
	camera.look_at(Vector3.UP * 12.0, Vector3.UP)

	for shot: Dictionary in SHOTS:
		var label: String = shot["label"]
		if completed.has(label):
			print("F356_RENDER resume skip %s" % label)
			continue
		atmosphere.call(&"set_time_of_day", float(shot["hour"]))
		for _frame: int in PER_SHOT_FRAMES:
			await process_frame
		await RenderingServer.frame_post_draw
		var relative_path := "%s/%s.png" % [OUT_DIR, label]
		var error: Error = viewport.get_texture().get_image().save_png(relative_path)
		if error != OK:
			push_error("failed to save %s: %s" % [relative_path, error_string(error)])
			quit(1)
			return
		_append_result({"label": label, "hour": shot["hour"], "seed": FIXED_SEED,
			"path": relative_path})
		print("F356_RENDER %s" % label)
	print("F356_RENDER done seed=%d" % FIXED_SEED)
	quit(0)


func _completed_labels() -> Dictionary:
	var completed: Dictionary = {}
	if not FileAccess.file_exists(LEDGER_PATH):
		return completed
	var file := FileAccess.open(LEDGER_PATH, FileAccess.READ)
	if file == null:
		return completed
	while not file.eof_reached():
		var line: String = file.get_line()
		if line.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary and (parsed as Dictionary).has("label"):
			completed[String((parsed as Dictionary)["label"])] = true
	return completed


func _append_result(result: Dictionary) -> void:
	var file: FileAccess
	if FileAccess.file_exists(LEDGER_PATH):
		file = FileAccess.open(LEDGER_PATH, FileAccess.READ_WRITE)
		file.seek_end()
	else:
		file = FileAccess.open(LEDGER_PATH, FileAccess.WRITE)
	file.store_line(JSON.stringify(result))
	file.flush()
