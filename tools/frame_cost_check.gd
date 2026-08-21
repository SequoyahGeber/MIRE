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

const ProbeScene := preload("res://tools/probe_scene.gd")

## Whatever `project.godot` boots, unless `-- --scene res://...` overrides it (F-342). Resolved at
## run time in `_run()`, because `ProjectSettings` is not readable from a const initialiser.
var scene_path: String = ""

## The procedural default streams its chunks in rather than arriving whole the way an authored level
## did, so a warmup sized for Hollowmere would sample a half-built world and report it as cheap.
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
	# Same island every run, unless `--seed=` says otherwise (F-452).
	var pinned_seed: int = ProbeScene.pin_seed(self)
	scene_path = ProbeScene.resolve()
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("could not load %s" % scene_path)
		quit(1)
		return
	var level := packed.instantiate()
	root.add_child(level)
	current_scene = level

	# The world builds deferred, undergrowth scatters two physics frames later, and the first
	# frames pay for shader compilation. None of that is a steady-state frame.
	for _i in WARMUP_FRAMES:
		await process_frame
	# A fixed warmup is a guess about how long streaming takes; `settle()` is the answer (F-452).
	# 90 frames happened to be enough here, but the same guess measured a third-built world in
	# tools/perf_probe.gd, and nothing about this file made it immune to that.
	var settle_report: Dictionary = await ProbeScene.settle(level)
	if bool(settle_report.get("streaming", false)):
		print("streamed %d chunk(s) in %d frame(s)%s" % [
			int(settle_report.get("chunks", 0)), int(settle_report.get("frames", 0)),
			"" if bool(settle_report.get("settled", true)) else " — NOT SETTLED"])

	print("\n=== MIRE frame cost — %s ===" % ProbeScene.describe(scene_path))
	print("Godot %s | %s | %s" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_name()])
	print("viewport %s | samples %d per row | seed %d" % [root.size, SAMPLE_FRAMES, pinned_seed])

	# The shipped default first, then each preset, so the row that matters for the worst machine
	# someone might play this on is measured rather than assumed.
	var rows: Array[Dictionary] = [await _sample("as shipped")]
	var quality: Node = root.get_node_or_null(^"GraphicsQuality")
	if quality != null:
		for preset: int in [2, 1, 0]:
			quality.call(&"apply", preset)
			# A preset that rescatters the undergrowth needs its rebuild to land before sampling.
			for _i in 30:
				await process_frame
			rows.append(await _sample("preset %s" % ["low", "medium", "high"][preset]))

	print("")
	print("  %-16s %11s %13s %10s %10s" % ["", "draw calls", "primitives", "vram MB", "frame ms"])
	for row: Dictionary in rows:
		print("  %-16s %11d %13d %10.1f %10.2f" % [
			row["name"], row["draws"], row["primitives"], row["vram"], row["ms"]])
	var first: Dictionary = rows[0]
	print("\nFRAME_COST draw_calls_median=%d primitives_median=%d vram_mb=%.1f frame_ms_median=%.2f"
		% [first["draws"], first["primitives"], first["vram"], first["ms"]])
	print("FRAME_COST_OK")
	quit(0)


func _sample(label: String) -> Dictionary:
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
	return {
		"name": label,
		"draws": _median_i(draw_calls),
		"primitives": _median_i(primitives),
		"vram": float(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0,
		"ms": _median_f(frame_ms),
	}


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
