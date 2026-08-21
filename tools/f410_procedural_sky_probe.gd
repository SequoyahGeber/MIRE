extends SceneTree

## F-410 — fixed-seed rendered proof of the shipped atmosphere controller.
##
## Unlike the exploratory probe this replaced, this script applies no material, grade, sun, fog, or
## AO overrides. Every pixel comes from production code. It records each completed shot immediately
## so an interrupted run resumes without losing prior work.
##
## Authority: none (docs/ARCHITECTURE.md section 2.2). Presentation-only probe.
##
##   .agent/bin/agent godot --windowed --script tools/f410_procedural_sky_probe.gd

const OUT_DIR: String = "res://assets/audit/lighting"
const LEDGER_PATH: String = OUT_DIR + "/f410_final_render.jsonl"
const FIXED_SEED: int = 4242
const SETTLE_FRAMES: int = 420
const PER_SHOT_FRAMES: int = 90
const SHOTS: Array[Dictionary] = [
	{"label": "f410_20_noon_baseline", "hour": 12.0},
	{"label": "f410_21_golden_hour", "hour": 17.25},
	{"label": "f410_22_moonlit_night", "hour": 0.0},
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("f410_procedural_sky_probe needs --windowed")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var completed: Dictionary = _completed_labels()

	var game_state: Node = root.get_node_or_null(^"GameState")
	if game_state != null:
		game_state.call(&"set_replicated_seed", FIXED_SEED)
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
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
			print("F410_RENDER resume skip %s" % label)
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
		_append_result({
			"label": label,
			"hour": float(shot["hour"]),
			"seed": FIXED_SEED,
			"path": relative_path,
		})
		print("F410_RENDER %s" % label)

	print("F410_RENDER done seed=%d" % FIXED_SEED)
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
