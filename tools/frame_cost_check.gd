extends SceneTree

## Ground truth for what a frame costs, straight from the renderer's own counters.
##
##   .agent/bin/agent godot --windowed --script tools/frame_cost_check.gd
##
## tools/render_census.gd counts the scene and MODELS what culling will do to it. This asks the
## RenderingServer what it actually did, which is the number that decides whether any of the
## modelling was right. It needs a rendering device, so it runs `--windowed` — the window parks
## offscreen (F-077). That makes the millisecond figures unreliable in absolute terms, because an
## unfocused window is throttled differently from a foregrounded one (F-066); the DRAW CALL and
## PRIMITIVE counters are not affected by focus and are the numbers to compare. For absolute
## frame times on a quiet, foregrounded machine, use tools/perf_probe.gd.
##
## Pair it with `agent baseline --windowed --script tools/frame_cost_check.gd` to get the same
## counters at HEAD, which is the only honest way to claim a change made anything faster.

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const WARMUP_FRAMES: int = 90
const SAMPLE_FRAMES: int = 120
const VIEWPORT_SIZE: Vector2i = Vector2i(1280, 720)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("FRAME_COST_SKIP no rendering device — run through `agent godot --windowed`")
		quit(0)
		return
	# Pinned so two runs are comparable. `agent godot --windowed` parks a tiny offscreen window
	# and a direct invocation opens 1280x720; draw calls barely notice, but primitives, VRAM and
	# anything resolution-dependent do, and a before/after taken at two different sizes is not a
	# before/after at all.
	root.size = VIEWPORT_SIZE
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		push_error("could not load %s" % SCENE_PATH)
		quit(1)
		return
	var level := packed.instantiate()
	root.add_child(level)
	current_scene = level

	# The world builds deferred, undergrowth scatters two physics frames later, and the first
	# frames pay for shader compilation. None of that is a steady-state frame.
	for _i in WARMUP_FRAMES:
		await process_frame

	var draw_calls: Array[int] = []
	var primitives: Array[int] = []
	var frame_ms: Array[float] = []
	for _i in SAMPLE_FRAMES:
		await process_frame
		draw_calls.append(int(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)))
		primitives.append(int(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)))
		frame_ms.append(1000.0 / maxf(Engine.get_frames_per_second(), 0.001))

	print("\n=== MIRE frame cost — %s ===" % SCENE_PATH)
	print("Godot %s | %s | %s" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_name()])
	print("viewport %s | samples %d" % [root.size, SAMPLE_FRAMES])
	print("FRAME_COST draw_calls_median=%d primitives_median=%d vram_mb=%.1f frame_ms_median=%.2f"
		% [_median_i(draw_calls), _median_i(primitives),
			float(RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0,
			_median_f(frame_ms)])
	print("  draw calls   median %6d   min %6d   max %6d" % [
		_median_i(draw_calls), draw_calls.min(), draw_calls.max()])
	print("  primitives   median %6d" % _median_i(primitives))
	print("  texture mem  %.1f MB | buffer mem %.1f MB" % [
		float(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)) / 1048576.0,
		float(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)) / 1048576.0])
	print("FRAME_COST_OK")
	quit(0)


func _median_i(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _median_f(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
