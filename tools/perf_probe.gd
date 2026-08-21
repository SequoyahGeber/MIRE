extends SceneTree

## F-090 frame-budget probe. Launches the REAL level fullscreen, then toggles one suspect at a
## time and prints what each costs, so the fix targets what the numbers convict instead of what
## reading the code suggests. Run it on a machine with a display (NOT headless):
##
##   .agent/bin/agent godot --display-driver macos --script tools/perf_probe.gd
##
## The trailing --display-driver wins over the wrapper's --headless because Godot parses
## arguments in order — the wrapper still holds the shared engine lock (F-044). Audio stays on
## the Dummy driver from --headless, so the run is silent. Total runtime ~40 s; keep hands off
## the machine while it runs, since input feeds the real player controller.
##
## Configs 2..N each apply ONE change on top of config 1 (vsync off, everything else as
## shipped), so each row's delta against config 1 is that suspect's isolated cost. The last
## config is the combined candidate fix.

const ProbeScene := preload("res://tools/probe_scene.gd")

## Whatever `project.godot` boots, unless `-- --scene res://...` overrides it (F-342).
var level_path: String = ""
const SETTLE_SECONDS: float = 0.7
const SAMPLE_SECONDS: float = 2.2

var _level: Node3D
var _viewport_rid: RID
## GPU/CPU render-time unit is normalised on first read (see _render_time_ms).
var _render_time_scale: float = 1.0
var _saved_undergrowth_shadows: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("perf_probe needs a display — run with --display-driver macos after the "
			+ "wrapper's --headless (see the header of this file)")
		quit(1)
		return

	root.mode = Window.MODE_FULLSCREEN
	root.title = "MIRE perf probe (F-090) — hands off, ~40s"
	_viewport_rid = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)

	print("\n=== MIRE perf probe (F-090) ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_name()])

	level_path = ProbeScene.resolve()
	print("measuring %s" % ProbeScene.describe(level_path))
	var packed := load(level_path) as PackedScene
	if packed == null:
		push_error("could not load %s" % level_path)
		quit(1)
		return
	_level = packed.instantiate() as Node3D
	root.add_child(_level)
	current_scene = _level

	# Undergrowth waits two physics frames, then scatters synchronously; give the level a
	# moment beyond that for colliders, player spawn and first-frame shader compiles.
	for _i: int in 8:
		await physics_frame
	await _sleep(1.5)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var screen_scale: float = DisplayServer.screen_get_scale()
	print("display: %s px backing store | screen scale %.1fx | refresh %.0f Hz" % [
		root.size, screen_scale, DisplayServer.screen_get_refresh_rate()])
	var undergrowth: Node = _level.get_node_or_null(^"Undergrowth")
	if undergrowth != null:
		print("undergrowth: placed=%s multimeshes=%s" % [
			undergrowth.get(&"placed_count"), undergrowth.get(&"multimesh_count")])

	var results: Array[Dictionary] = []
	for config: Dictionary in _configs():
		(config["apply"] as Callable).call()
		# A config may ask for a longer settle — the dynamic-resolution row needs its
		# controller (one step per half second) to converge before sampling.
		await _sleep(float(config.get("settle", SETTLE_SECONDS)))
		var row := await _measure(config["name"] as String)
		results.append(row)
		(config["undo"] as Callable).call()

	_print_table(results)
	_close_out()


## Every config assumes vsync is already OFF except the first, which measures exactly what a
## player sees today. Apply/undo pairs keep configs independent.
func _configs() -> Array[Dictionary]:
	var day_night: Node = root.get_node(^"/root/DayNight")
	var sun := _level.get_node(^"Sun") as DirectionalLight3D
	var environment := (_level.get_node(^"WorldEnvironment") as WorldEnvironment).environment
	return [
		{"name": "0 as shipped (vsync ON)",
			"apply": func() -> void: pass,
			# Everything after this row measures real cost, not the compositor's pace.
			"undo": func() -> void: DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_DISABLED)},
		{"name": "1 vsync OFF (baseline)",
			"apply": func() -> void: pass,
			"undo": func() -> void: pass},
		{"name": "2 sky/time frozen",
			"apply": func() -> void: day_night.set_physics_process(false),
			"undo": func() -> void: day_night.set_physics_process(true)},
		{"name": "3 undergrowth hidden",
			"apply": func() -> void: _set_undergrowth_visible(false),
			"undo": func() -> void: _set_undergrowth_visible(true)},
		{"name": "4 undergrowth shadows off",
			"apply": func() -> void: _set_undergrowth_shadows(false),
			"undo": func() -> void: _set_undergrowth_shadows(true)},
		{"name": "5 sun shadows off",
			"apply": func() -> void: sun.shadow_enabled = false,
			"undo": func() -> void: sun.shadow_enabled = true},
		{"name": "6 volumetric fog off",
			"apply": func() -> void: environment.volumetric_fog_enabled = false,
			"undo": func() -> void: environment.volumetric_fog_enabled = true},
		{"name": "7 glow off",
			"apply": func() -> void: environment.glow_enabled = false,
			"undo": func() -> void: environment.glow_enabled = true},
		{"name": "8 3D render scale 50%",
			"apply": func() -> void: root.scaling_3d_scale = 0.5,
			"undo": func() -> void: root.scaling_3d_scale = 1.0},
		{"name": "9 combo: 2+4+6",
			"apply": _apply_combo,
			"undo": _undo_combo},
		{"name": "10 gfx preset medium",
			"apply": func() -> void: _apply_gfx_preset(1),
			"undo": func() -> void: _apply_gfx_preset(2)},
		{"name": "11 gfx preset low",
			"apply": func() -> void: _apply_gfx_preset(0),
			"undo": func() -> void: _apply_gfx_preset(2)},
		# LAST on purpose: crossing 18:00 fires night_started and WaveSpawner spawns real
		# enemies, which stay in the scene afterwards — night is when the game is actually
		# played hard, so the row measures stars + moonlight + shadow-refresh + a live wave.
		{"name": "12 night 02:00 + waves",
			"apply": func() -> void: day_night.set(&"time_of_day", 2.0 / 24.0),
			"undo": func() -> void: day_night.set(&"time_of_day", 8.35 / 24.0)},
		# Target far above what full scale can reach, so the controller must drive the render
		# scale to its floor — the row proves the loop steers and shows the fps it buys.
		{"name": "13 dynamic res @240", "settle": 4.0,
			"apply": func() -> void: _set_dynamic_scale(true, 240.0),
			"undo": func() -> void: _set_dynamic_scale(false, 0.0)},
	]


func _set_dynamic_scale(enabled: bool, target_fps: float) -> void:
	var quality: Node = root.get_node_or_null(^"/root/GraphicsQuality")
	if quality == null:
		push_warning("GraphicsQuality autoload missing — dynamic-res config measures nothing")
		return
	quality.call(&"set_dynamic_scale", enabled, target_fps)


## Presets are GraphicsQuality.Preset values: 0 low, 1 medium, 2 high (the authored default).
func _apply_gfx_preset(preset: int) -> void:
	var quality: Node = root.get_node_or_null(^"/root/GraphicsQuality")
	if quality == null:
		push_warning("GraphicsQuality autoload missing — preset config measures nothing")
		return
	quality.call(&"apply", preset)


func _apply_combo() -> void:
	(root.get_node(^"/root/DayNight")).set_physics_process(false)
	_set_undergrowth_shadows(false)
	(_level.get_node(^"WorldEnvironment") as WorldEnvironment) \
		.environment.volumetric_fog_enabled = false


func _undo_combo() -> void:
	(root.get_node(^"/root/DayNight")).set_physics_process(true)
	_set_undergrowth_shadows(true)
	(_level.get_node(^"WorldEnvironment") as WorldEnvironment) \
		.environment.volumetric_fog_enabled = true


func _set_undergrowth_visible(value: bool) -> void:
	var undergrowth := _level.get_node_or_null(^"Undergrowth") as Node3D
	if undergrowth != null:
		undergrowth.visible = value


func _set_undergrowth_shadows(on: bool) -> void:
	var undergrowth: Node = _level.get_node_or_null(^"Undergrowth")
	if undergrowth == null:
		return
	for instance: Node in undergrowth.find_children("*", "MultiMeshInstance3D", true, false):
		var mesh_instance := instance as MultiMeshInstance3D
		if on:
			var saved: Variant = _saved_undergrowth_shadows.get(mesh_instance.get_instance_id())
			mesh_instance.cast_shadow = saved if saved != null \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		else:
			_saved_undergrowth_shadows[mesh_instance.get_instance_id()] = mesh_instance.cast_shadow
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _measure(name: String) -> Dictionary:
	var deltas := PackedFloat64Array()
	var gpu_sum: float = 0.0
	var cpu_sum: float = 0.0
	var draws: float = 0.0
	var primitives: float = 0.0
	var start: int = Time.get_ticks_usec()
	var last: int = start
	while Time.get_ticks_usec() - start < int(SAMPLE_SECONDS * 1e6):
		await process_frame
		var now: int = Time.get_ticks_usec()
		deltas.append(float(now - last) / 1000.0)
		last = now
		gpu_sum += _render_time_ms(RenderingServer.viewport_get_measured_render_time_gpu(
			_viewport_rid))
		cpu_sum += _render_time_ms(RenderingServer.viewport_get_measured_render_time_cpu(
			_viewport_rid))
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var count: int = deltas.size()
	var elapsed_s: float = float(last - start) / 1e6
	deltas.sort()
	var row := {
		"name": name,
		"fps": float(count) / elapsed_s,
		"median_ms": deltas[count / 2],
		"p95_ms": deltas[int(float(count) * 0.95)],
		"gpu_ms": gpu_sum / count,
		"cpu_ms": cpu_sum / count,
		"draws": draws / count,
		"mprims": primitives / count / 1e6,
	}
	print("  %-28s %6.0f fps  med %6.2f ms  p95 %6.2f ms  gpu %6.2f ms  cpu %5.2f ms  draws %5.0f  prims %5.1fM" % [
		row["name"], row["fps"], row["median_ms"], row["p95_ms"], row["gpu_ms"],
		row["cpu_ms"], row["draws"], row["mprims"]])
	return row


## The engine reports render times in a unit that has changed across versions; anchor on the
## first nonzero read — a fullscreen frame plausibly costs 0.05..100 ms, so scale down by 1000
## until it lands in range.
func _render_time_ms(raw: float) -> float:
	if raw <= 0.0:
		return 0.0
	if _render_time_scale == 1.0 and raw > 200.0:
		_render_time_scale = 0.001 if raw < 200000.0 else 0.000001
	return raw * _render_time_scale


func _print_table(results: Array[Dictionary]) -> void:
	print("\n=== summary (deltas vs config 1, vsync OFF) ===")
	var baseline: Dictionary = results[1]
	for row: Dictionary in results:
		var gpu_delta: float = (row["gpu_ms"] as float) - (baseline["gpu_ms"] as float)
		print("  %-28s %6.0f fps   gpu %+6.2f ms   frame med %+6.2f ms" % [
			row["name"], row["fps"],
			gpu_delta, (row["median_ms"] as float) - (baseline["median_ms"] as float)])
	print("\nPERF_PROBE done")


func _close_out() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	quit(0)


func _sleep(seconds: float) -> void:
	await create_timer(seconds).timeout
