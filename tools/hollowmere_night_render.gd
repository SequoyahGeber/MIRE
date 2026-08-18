extends SceneTree

## Look at Hollowmere's sky at four times of day, so F-065's verdict ("it's night time now, but the
## clouds are still bright white, and there's no stars") can be judged instead of argued about.
##
## Needs a real framebuffer, so it does NOT go through `agent godot` (which is always --headless,
## F-044). Hold the same lock by hand — this is what tools/run_windowed.py in the scratchpad does,
## and what any future windowed check should do:
##
##   python3 - <<'PY'
##   import fcntl, subprocess
##   fh = open('.agent/locks/godot.lock', 'w'); fcntl.flock(fh, fcntl.LOCK_EX)
##   subprocess.call(['/Applications/Godot.app/Contents/MacOS/Godot', '--path', '.',
##                    '--script', 'tools/hollowmere_night_render.gd', '--', '--outdir', '/tmp/x'])
##   PY
##
## Run headless anyway and it still does its other job: it prints the mean luminance of each time of
## day, which is a number, not an opinion, and is how the log alone can show night got darker.
##
## Writes one JSONL line per shot the moment that shot is done (AGENTS.md's ledger rule) — being
## killed halfway through then costs the shot in flight and nothing else.

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const SETTLE_FRAMES: int = 24

## One vantage per time of day is not enough: the complaint was about clouds AND stars, which live
## in different parts of the frame. Each shot below is taken at every time.
const VIEWS: Array = [
	{"name": "skyline", "from": Vector3(-58.0, 26.0, 56.0), "at": Vector3(-20.0, 30.0, -20.0)},
	{"name": "zenith", "from": Vector3(0.0, 12.0, 40.0), "at": Vector3(0.0, 60.0, -30.0)},
]

## Noon, the sun on the horizon, deep dusk once the stars are in, and the middle of the night.
const TIMES: Array = [
	{"name": "noon", "hour": 12.0},
	{"name": "sunset", "hour": 18.0},
	{"name": "dusk", "hour": 18.7},
	{"name": "night", "hour": 23.0},
]

var _out_dir: String = ""
var _ledger_path: String = ""
var _done: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_out_dir = _resolve_out_dir()
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_ledger_path = "%s/night_render.jsonl" % _out_dir
	_load_ledger()

	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		push_error("NIGHT_RENDER could not load %s" % SCENE_PATH)
		quit(1)
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene

	# DayNight pushes its own time every physics tick and would overwrite each sample the frame
	# after it is set. Freeze the clock; this script is the one driving time here.
	var day_night: Node = root.get_node_or_null(^"DayNight")
	if day_night != null:
		day_night.set_physics_process(false)
	var atmosphere: Node = scene.get_node_or_null(^"Atmosphere")
	if atmosphere == null:
		push_error("NIGHT_RENDER found no Atmosphere node")
		quit(1)
		return

	var camera := Camera3D.new()
	camera.name = "ShotCamera"
	camera.fov = 66.0
	camera.far = 520.0
	scene.add_child(camera)
	camera.current = true

	var can_capture := DisplayServer.get_name() != "headless"
	if not can_capture:
		print("NIGHT_RENDER capture skipped — headless has no framebuffer; luminance still measured")

	for _frame: int in SETTLE_FRAMES:
		await process_frame

	for time_value: Variant in TIMES:
		var time_entry := time_value as Dictionary
		atmosphere.call(&"set_time_of_day", float(time_entry["hour"]))
		for view_value: Variant in VIEWS:
			var view := view_value as Dictionary
			var shot_id := "%s_%s" % [String(time_entry["name"]), String(view["name"])]
			if _done.has(shot_id):
				continue
			camera.global_position = view["from"] as Vector3
			camera.look_at(view["at"] as Vector3, Vector3.UP)
			camera.current = true
			for _frame: int in 6:
				await process_frame

			var luminance := -1.0
			var path := ""
			if can_capture:
				await RenderingServer.frame_post_draw
				var image := root.get_texture().get_image()
				path = "%s/%s.png" % [_out_dir, shot_id]
				image.save_png(path)
				luminance = _mean_luminance(image)
			_append_ledger({
				"shot": shot_id,
				"hour": float(time_entry["hour"]),
				"path": path,
				"mean_luminance": luminance,
			})
			print("NIGHT_SHOT %s hour=%.2f luminance=%.4f %s" % [
				shot_id, float(time_entry["hour"]), luminance, path])

	print("NIGHT_RENDER display=%s out=%s" % [DisplayServer.get_name(), _out_dir])
	quit(0)


## Average of a coarse sample rather than every pixel: this is a "did it get darker" number, and
## reading 900,000 pixels through GDScript to get one more decimal place is not worth the seconds.
func _mean_luminance(image: Image) -> float:
	var total := 0.0
	var samples := 0
	var step := maxi(1, image.get_width() / 96)
	for y: int in range(0, image.get_height(), step):
		for x: int in range(0, image.get_width(), step):
			var pixel := image.get_pixel(x, y)
			total += 0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b
			samples += 1
	return 0.0 if samples == 0 else total / float(samples)


func _resolve_out_dir() -> String:
	var args := OS.get_cmdline_user_args()
	for index: int in args.size():
		if args[index] == "--outdir" and index + 1 < args.size():
			return args[index + 1]
	return ProjectSettings.globalize_path("user://night_preview")


## Tolerates a torn final line from a hard kill mid-write, per AGENTS.md.
func _load_ledger() -> void:
	if not FileAccess.file_exists(_ledger_path):
		return
	var file := FileAccess.open(_ledger_path, FileAccess.READ)
	if file == null:
		return
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary and (parsed as Dictionary).has("shot"):
			_done[String((parsed as Dictionary)["shot"])] = true
	file.close()
	if not _done.is_empty():
		print("NIGHT_RENDER resuming: %d shot(s) already done" % _done.size())


func _append_ledger(entry: Dictionary) -> void:
	var file := FileAccess.open(_ledger_path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(_ledger_path, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(JSON.stringify(entry))
	file.close()
