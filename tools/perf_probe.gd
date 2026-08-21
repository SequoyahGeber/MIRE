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
const DrawPolicy := preload("res://world/environment/draw_policy.gd")

## Whatever `project.godot` boots, unless `-- --scene res://...` overrides it (F-342).
var level_path: String = ""
## 0.7 s before 2026-08-21. Too short: a row that changes shadow geometry, draw distance or the
## LOD threshold forces a rebuild — a full shadow-atlas re-render, a walk over every registered
## instance — and at 0.7 s that transient landed INSIDE the 2.2 s sample. The result was four rows
## that removed hundreds of draw calls and reported the frame getting 1.5-2.2 ms SLOWER, which is
## not a thing that can happen. Rows that mutate geometry ask for `settle` explicitly on top.
const SETTLE_SECONDS: float = 1.5
## 2.2 s before 2026-08-21, which was fine for a median and useless for a 1% low: at ~140 fps it
## is ~300 frames, so the worst 1% is THREE frames and one unrelated hitch moves the number by
## 20 ms. The 1% low is the headline metric — it is what a player feels — so the sample has to be
## long enough to have a stable tail. 5 s is ~700 frames, worst-1% = 7 frames averaged.
const SAMPLE_SECONDS: float = 5.0
## Frames discarded at the start of every sample. Applying a config re-renders shadow atlases,
## rebuilds draw-policy state and recompiles shaders; that transient belongs to the toggle, not to
## the configuration, and it lands squarely in the 1% tail if it is measured.
const DISCARD_FRAMES: int = 15

var _level: Node3D
var _viewport_rid: RID
## GPU/CPU render-time unit is normalised on first read (see _render_time_ms).
var _render_time_scale: float = 1.0
var _saved_undergrowth_shadows: Dictionary = {}
## The body the streamer anchors on. Driven through the world during sampling — see `_travel()`.
var _player: Node3D
var _travel_origin: Vector3 = Vector3.ZERO
var _travel_heading: float = 0.0
## Metres per second the probe walks while sampling. Roughly sprint speed: fast enough that the
## streamer is continuously building, which is the only condition the hitch appears in.
const TRAVEL_SPEED: float = 7.0
## The lever table (rows 0-21) is sampled STATIONARY, because a traversal hitch is a large,
## sporadic event whose incidence varies per 5 s window — measured under motion, the per-row 1%-low
## deltas swung +-170 ms and told you nothing about the lever. Travel is a SCENARIO instead: the
## rows at the end turn it on and their whole job is quantifying the hitch.
var _travelling: bool = false


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
	# A frame limiter turns every row into the same number. `_configs()` disables vsync for rows
	# 1..N, but an `Engine.max_fps` inherited from project settings would survive that and pin
	# the whole table to one value (F-452).
	Engine.max_fps = 0
	_viewport_rid = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)

	print("\n=== MIRE perf probe (F-090) ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_name()])

	var pinned_seed: int = ProbeScene.pin_seed(self)
	level_path = ProbeScene.resolve()
	print("measuring %s | seed %d" % [ProbeScene.describe(level_path), pinned_seed])
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
	# ...and then wait for the STREAMER, which the fixed 1.5 s above never did (F-452). The
	# procedural default arrives over hundreds of frames: measured at 1.5 s it is a third-built
	# world reporting 1,288 draw calls, where the settled world draws 4,908. Every row of this
	# table was being taken against a world the player never stands in.
	var settle_report: Dictionary = await ProbeScene.settle(_level)
	if bool(settle_report.get("streaming", false)):
		print("streamed %d chunk(s) in %d frame(s)%s" % [
			int(settle_report.get("chunks", 0)), int(settle_report.get("frames", 0)),
			"" if bool(settle_report.get("settled", true)) else " — NOT SETTLED"])
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Every row is sampled WHILE MOVING. A stationary probe at the spawn point measures the one
	# situation the game is never in: everything already streamed, nothing being built, and the
	# frame-time tail players actually feel simply absent. Traversal is what forces the streamer,
	# the mesher, the nav baker and the scatter fields to run inside the sample window
	# (Sequoyah, 2026-08-21: "it really only shows the lag and performance hit when you move and
	# force the game to load new terrain").
	_player = _level.get_node_or_null(^"Player") as Node3D
	if _player == null:
		push_warning("no Player node — every row will be a stationary sample, which is not the "
			+ "scenario that hitches")
	else:
		_travel_origin = _player.global_position

	var screen_scale: float = DisplayServer.screen_get_scale()
	print("display: %s px backing store | screen scale %.1fx | refresh %.0f Hz" % [
		root.size, screen_scale, DisplayServer.screen_get_refresh_rate()])
	var undergrowth: Node = _level.get_node_or_null(^"Undergrowth")
	if undergrowth != null:
		print("undergrowth: placed=%s multimeshes=%s" % [
			undergrowth.get(&"placed_count"), undergrowth.get(&"multimesh_count")])

	# PAIRED measurement: every config is sampled, then undone and the UNTOUCHED build sampled
	# again immediately after, and the row's delta is taken against that adjacent reference. A
	# serial run quoting every row against one baseline taken twenty rows earlier cannot resolve
	# anything smaller than its own drift, and this run drifts ~1.9 ms — enough to swallow every
	# lever in the table except the render scale and the LOW preset, and enough to make four rows
	# that removed hundreds of draw calls report the frame getting SLOWER. Pairing costs twice the
	# wall clock and is the difference between a table and a table you can act on.
	var results: Array[Dictionary] = []
	var reference: Dictionary = {}
	for config: Dictionary in _configs():
		var settle: float = float(config.get("settle", SETTLE_SECONDS))
		(config["apply"] as Callable).call()
		# A config may ask for a longer settle — the dynamic-resolution row needs its
		# controller (one step per half second) to converge before sampling, and any row that
		# mutates geometry needs its rebuild to land outside the sample window.
		await _sleep(settle)
		var row := await _measure(config["name"] as String)
		(config["undo"] as Callable).call()
		await _sleep(settle)
		reference = await _measure("   ...reference", true)
		row["reference_ms"] = reference["median_ms"]
		row["reference_fps"] = reference["fps"]
		row["reference_low1_ms"] = reference["low1_ms"]
		row["reference_low1_fps"] = reference["low1_fps"]
		results.append(row)

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
		# ── one lever at a time, for the knobs GraphicsQuality bundles into presets ──────────
		# A preset moves six things at once, so its row proves the bundle is worth something but
		# never which part earned it. These isolate the parts (Sequoyah, 2026-08-21).
		{"name": "9 SSAO off",
			"apply": func() -> void: environment.ssao_enabled = false,
			"undo": func() -> void: environment.ssao_enabled = true},
		{"name": "10 anti-aliasing off",
			"apply": func() -> void: _set_anti_aliasing(false),
			"undo": func() -> void: _set_anti_aliasing(true)},
		{"name": "11 shadow cascades 4->2", "settle": 3.0,
			"apply": func() -> void: sun.directional_shadow_mode = \
				DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
			"undo": func() -> void: sun.directional_shadow_mode = \
				DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS},
		{"name": "12 shadow distance halved", "settle": 3.0,
			"apply": func() -> void: sun.directional_shadow_max_distance *= 0.5,
			"undo": func() -> void: sun.directional_shadow_max_distance *= 2.0},
		{"name": "13 draw distance 0.55", "settle": 3.0,
			"apply": func() -> void: _set_draw_distance(0.55),
			"undo": func() -> void: _set_draw_distance(1.0)},
		{"name": "14 mesh LOD threshold 4.0", "settle": 3.0,
			"apply": func() -> void: root.mesh_lod_threshold = 4.0,
			"undo": func() -> void: root.mesh_lod_threshold = 1.0},
		# The sharpness half of the render-scale trade: same pixel count as row 8's neighbourhood,
		# a fixed upscale pass instead of a bilinear stretch. If this row costs little more than
		# a plain 0.59 scale, LOW should be using it.
		{"name": "15 FSR upscale @0.59", "settle": 2.5,
			"apply": func() -> void: _set_upscale(Viewport.SCALING_3D_MODE_FSR, 0.59),
			"undo": func() -> void: _set_upscale(Viewport.SCALING_3D_MODE_BILINEAR, 1.0)},
		{"name": "16 bilinear @0.59 (FSR control)", "settle": 2.5,
			"apply": func() -> void: _set_upscale(Viewport.SCALING_3D_MODE_BILINEAR, 0.59),
			"undo": func() -> void: _set_upscale(Viewport.SCALING_3D_MODE_BILINEAR, 1.0)},
		{"name": "17 combo: 2+4+6",
			"apply": _apply_combo,
			"undo": _undo_combo},
		{"name": "18 gfx preset medium", "settle": 3.0,
			"apply": func() -> void: _apply_gfx_preset(1),
			"undo": func() -> void: _apply_gfx_preset(2)},
		{"name": "19 gfx preset low", "settle": 3.0,
			"apply": func() -> void: _apply_gfx_preset(0),
			"undo": func() -> void: _apply_gfx_preset(2)},
		# LAST on purpose: crossing 18:00 fires night_started and WaveSpawner spawns real
		# enemies, which stay in the scene afterwards — night is when the game is actually
		# played hard, so the row measures stars + moonlight + shadow-refresh + a live wave.
		{"name": "20 night 02:00 + waves",
			"apply": func() -> void: day_night.set(&"time_of_day", 2.0 / 24.0),
			"undo": func() -> void: day_night.set(&"time_of_day", 8.35 / 24.0)},
		# Target far above what full scale can reach, so the controller must drive the render
		# scale to its floor — the row proves the loop steers and shows the fps it buys.
		{"name": "21 dynamic res @240", "settle": 4.0,
			"apply": func() -> void: _set_dynamic_scale(true, 240.0),
			"undo": func() -> void: _set_dynamic_scale(false, 0.0)},
		# ── SCENARIOS: what the game actually does, not what one setting costs ────────────────
		# The rows above sample a stationary camera on ground that has already arrived. That is
		# the one situation play never contains. These walk the anchor body through unstreamed
		# terrain at sprint speed so the streamer, mesher, nav baker and scatter fields all run
		# inside the sample window — which is where every hitch anyone has ever felt lives.
		{"name": "T1 TRAVERSAL (streaming)", "settle": 2.0,
			"apply": func() -> void: _travelling = true,
			"undo": func() -> void: _travelling = false},
		{"name": "T2 traversal @ preset low", "settle": 3.0,
			"apply": func() -> void:
				_travelling = true
				_apply_gfx_preset(0),
			"undo": func() -> void:
				_travelling = false
				_apply_gfx_preset(2)},
		# Sequoyah asked whether an open menu costs frames. Measured rather than guessed.
		{"name": "T3 traversal + menu open", "settle": 2.0,
			"apply": func() -> void:
				_travelling = true
				_set_menu_open(true),
			"undo": func() -> void:
				_travelling = false
				_set_menu_open(false)},
	]


## MSAA is the one AA mode with a real per-pixel cost; the row toggles it rather than the whole
## `anti_aliasing` setting so the delta is attributable to one thing.
func _set_anti_aliasing(enabled: bool) -> void:
	root.msaa_3d = Viewport.MSAA_2X if enabled else Viewport.MSAA_DISABLED
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if enabled \
		else Viewport.SCREEN_SPACE_AA_DISABLED


## Drives the same seam `GraphicsQuality` uses, so the row measures the shipped mechanism rather
## than a probe-only shortcut that no player ever gets.
func _set_draw_distance(scale: float) -> void:
	var quality: Node = root.get_node_or_null(^"/root/GraphicsQuality")
	if quality == null:
		push_warning("GraphicsQuality autoload missing — draw-distance config measures nothing")
		return
	quality.set(&"prop_draw_distance_scale", scale)
	DrawPolicy.rescale(self)


func _set_upscale(mode: int, scale: float) -> void:
	root.scaling_3d_mode = mode as Viewport.Scaling3DMode
	root.scaling_3d_scale = scale


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


func _measure(name: String, quiet: bool = false) -> Dictionary:
	var deltas := PackedFloat64Array()
	var gpu_sum: float = 0.0
	var cpu_sum: float = 0.0
	var draws: float = 0.0
	var primitives: float = 0.0
	for _i: int in DISCARD_FRAMES:
		await process_frame
		_travel()
	var start: int = Time.get_ticks_usec()
	var last: int = start
	while Time.get_ticks_usec() - start < int(SAMPLE_SECONDS * 1e6):
		await process_frame
		_travel()
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
		# The 1% low: the MEAN of the worst 1% of frame times, reported as the frame rate it
		# corresponds to. This is the headline number, not the median — a median describes the
		# smooth stretches, and what a player feels as the game being bad is the worst one frame
		# in a hundred: a chunk streaming in, the Mire tick, a wave spawning. An optimization that
		# moves the median and leaves this alone has not improved anything anyone feels.
		#
		# A mean of the tail rather than the single 99th-percentile sample, because one frame is
		# not a measurement — the percentile form swung 20 ms between runs on identical configs.
		"low1_ms": _worst_percent_mean(deltas),
		"low1_fps": 1000.0 / maxf(_worst_percent_mean(deltas), 0.001),
		"gpu_ms": gpu_sum / count,
		"cpu_ms": cpu_sum / count,
		"draws": draws / count,
		"mprims": primitives / count / 1e6,
	}
	if not quiet:
		print("  %-28s %6.0f fps  1%%low %5.0f fps (%5.2f ms)  med %6.2f ms  cpu %5.2f ms  draws %5.0f  prims %5.1fM" % [
			row["name"], row["fps"], row["low1_fps"], row["low1_ms"], row["median_ms"],
			row["cpu_ms"], row["draws"], row["mprims"]])
	return row


## Opens the Attunement/class picker if this build has one in the tree, so a row can measure what
## an open menu costs. Best-effort by design: the picker is driven by run state, and a probe that
## hard-failed when it could not be opened would block the far more important traversal rows.
func _set_menu_open(open: bool) -> void:
	var ui: CanvasLayer = _find_attunement_ui(root)
	if ui == null:
		if open:
			push_warning("no AttunementUI in the tree — the menu row measures nothing")
		return
	ui.visible = open
	if open:
		ui.call(&"_open_picker")
	else:
		ui.call(&"_close_picker")


func _find_attunement_ui(node: Node) -> CanvasLayer:
	if node is CanvasLayer and node.has_method(&"_open_picker") and node.has_method(&"is_picking"):
		return node as CanvasLayer
	for child: Node in node.get_children():
		var found: CanvasLayer = _find_attunement_ui(child)
		if found != null:
			return found
	return null


## Walks the anchor body outward at a constant speed, turning a little each frame so the path
## spirals rather than leaving the island. Position is written directly rather than driven through
## the controller: the probe wants a repeatable path through unstreamed ground, not a physics
## simulation, and `ProceduralWorld._physics_process()` re-anchors the streamer on whatever the
## body's position is either way.
func _travel() -> void:
	if _player == null or not _travelling:
		return
	_travel_heading += 0.004
	var step: float = TRAVEL_SPEED / 60.0
	var direction := Vector3(cos(_travel_heading), 0.0, sin(_travel_heading))
	var moved: Vector3 = _player.global_position + direction * step
	# Stay over the island rather than walking into open ocean, where nothing streams and the
	# rows would quietly go back to measuring an empty frame.
	if moved.distance_to(_travel_origin) > 180.0:
		_travel_heading += PI
		moved = _player.global_position + Vector3(cos(_travel_heading), 0.0,
			sin(_travel_heading)) * step
	_player.global_position = moved


## Mean of the slowest 1% of frames, over at least three of them. `sorted_deltas` must already be
## sorted ascending; `_measure()` sorts once for the median and reuses it here.
func _worst_percent_mean(sorted_deltas: PackedFloat64Array) -> float:
	var count: int = sorted_deltas.size()
	if count == 0:
		return 0.0
	var tail: int = mini(count, maxi(3, int(float(count) * 0.01)))
	var total: float = 0.0
	for i: int in range(count - tail, count):
		total += sorted_deltas[i]
	return total / float(tail)


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
	print("\n=== summary (each row against the reference sampled right after it) ===")
	print("  The 1% low column is the one that matters — it is what a player feels.")
	print("  %-28s %14s %14s" % ["", "1% low vs ref", "median vs ref"])
	for row: Dictionary in results:
		var reference_ms: float = float(row.get("reference_ms", 0.0))
		if reference_ms <= 0.0:
			continue
		print("  %-28s %+9.2f ms   %+9.2f ms   (1%% low %4.0f fps, ref %4.0f fps)" % [
			row["name"],
			(row["low1_ms"] as float) - float(row.get("reference_low1_ms", reference_ms)),
			(row["median_ms"] as float) - reference_ms,
			row["low1_fps"], float(row.get("reference_low1_fps", 0.0))])
	_warn_if_refresh_capped(results)
	_report_drift(results)
	print("\nPERF_PROBE done")


## A vsync-off row that still lands on the display's refresh rate did not measure the build; it
## measured the monitor. Under a cap every delta in the table above is noise, and reading it as
## "shadows cost nothing" is exactly the wrong conclusion to draw (F-452). Say so rather than
## printing a table that looks like evidence.
## How far the baseline moved between its first and last measurement. Any delta in the table
## smaller than this is inside the run's own drift and must not be reported as a finding.
func _report_drift(results: Array[Dictionary]) -> void:
	var references: Array[float] = []
	for row: Dictionary in results:
		var reference_ms: float = float(row.get("reference_ms", 0.0))
		if reference_ms > 0.0:
			references.append(reference_ms)
	if references.size() < 2:
		return
	var drift: float = references[references.size() - 1] - references[0]
	var lowest: float = references[0]
	var highest: float = references[0]
	for value: float in references:
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
	print("\n  reference drift across the run: %+.2f ms (%.2f -> %.2f, range %.2f..%.2f)."
		% [drift, references[0], references[references.size() - 1], lowest, highest])
	print("  Pairing is what makes the deltas above survive that. A single-baseline table")
	print("  could not have resolved anything smaller than %.2f ms." % absf(highest - lowest))


func _warn_if_refresh_capped(results: Array[Dictionary]) -> void:
	var refresh: float = DisplayServer.screen_get_refresh_rate()
	if refresh <= 0.0:
		return
	var capped: int = 0
	for i: int in range(1, results.size()):
		if absf((results[i]["fps"] as float) - refresh) / refresh < 0.03:
			capped += 1
	if capped < results.size() - 2:
		return
	print("\n  !! %d of %d vsync-OFF rows sit within 3%% of this display's %.0f Hz refresh."
		% [capped, results.size() - 1, refresh])
	print("     The frame limiter, not the build, decided those numbers — the per-row deltas")
	print("     above are noise. Compare the `draws`/`prims`/`cpu` columns instead, or re-run")
	print("     on a machine this scene can actually saturate (F-174, F-452).")


func _close_out() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	quit(0)


func _sleep(seconds: float) -> void:
	await create_timer(seconds).timeout
