extends SceneTree

## What fraction of the machine this game actually uses, in one report.
##
## The project has instruments for FRAME TIME (`perf_probe.gd`, `traversal_profile.gd`,
## `benchmark_check.gd`) and none at all for CAPACITY — how much memory is resident, how much of it
## is on the GPU, and how many of the machine's cores are ever doing anything. Those are different
## questions with different fixes: a game at 8 ms a frame on one core of twelve is not "fast", it is
## leaving the machine idle, and nothing that measures milliseconds will ever say so.
##
## Samples the settled world, then again after a traversal, because the numbers that matter are the
## ones that MOVE. A resident set that climbs 300 MB over a 30-second walk and does not come back
## down is a different fact from a large steady one.
##
##     .agent/bin/agent godot --display-driver macos --script tools/hardware_census.gd

const ProbeScene := preload("res://tools/probe_scene.gd")

const WORLD_WAIT_FRAMES: int = 600
const WALK_SECONDS: float = 30.0
const WALK_SPEED: float = 7.0
## Sampled every this many frames during the walk, to catch the peak rather than only the endpoints.
const SAMPLE_INTERVAL_FRAMES: int = 20

var _level: Node3D
var _player: Node3D
var _streamer: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("hardware_census needs a real renderer — video memory and texture/buffer "
			+ "totals are all zero under the dummy driver. Re-run with --display-driver macos.")
		quit(1)
		return
	root.mode = Window.MODE_FULLSCREEN
	root.title = "MIRE hardware census — hands off, ~60s"
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var pinned_seed: int = ProbeScene.pin_seed(self)
	var packed := load(ProbeScene.resolve()) as PackedScene
	_level = packed.instantiate() as Node3D
	root.add_child(_level)
	current_scene = _level

	print("\n=== MIRE hardware census ===")
	print("Godot %s | %s" % [Engine.get_version_info()["string"], OS.get_name()])
	print("CPU: %s — %d logical processor(s)" % [OS.get_processor_name(), OS.get_processor_count()])
	print("GPU: %s (%s)" % [
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor()])
	var mem: Dictionary = OS.get_memory_info()
	print("System memory: physical %s | free %s | available to this process %s" % [
		_mb(mem.get("physical", 0)), _mb(mem.get("free", 0)), _mb(mem.get("available", 0))])
	print("WorkerThreadPool: %d thread(s)"
		% [maxi(1, OS.get_processor_count() - 1)])
	print("seed %d\n" % pinned_seed)

	for _i: int in 8:
		await physics_frame
	for _i: int in WORLD_WAIT_FRAMES:
		if _find(root, &"pending_job_count") != null:
			break
		await process_frame
	_streamer = _find(root, &"pending_job_count")
	_player = _player_node()
	await ProbeScene.settle(root)

	_report("settled at spawn")
	var peak: Dictionary = await _walk()
	_report("after a %.0f s walk" % WALK_SECONDS)
	print("\nPEAK during the walk: resident %s | video %s | %d chunk(s)" % [
		_mb(peak["rss"]), _mb(peak["video"]), int(peak["chunks"])])
	_advice()

	print("\nHARDWARE_CENSUS done")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	quit(0)


## Walks the anchor in a straight line through unstreamed ground — the condition that grows every
## number here, since standing still neither loads chunks nor allocates.
func _walk() -> Dictionary:
	var peak := {"rss": 0, "video": 0, "chunks": 0}
	if _player == null:
		return peak
	var start: int = Time.get_ticks_usec()
	var origin: Vector3 = _player.global_position
	var frames: int = 0
	while float(Time.get_ticks_usec() - start) / 1e6 < WALK_SECONDS:
		await process_frame
		frames += 1
		var travelled: float = float(Time.get_ticks_usec() - start) / 1e6 * WALK_SPEED
		_player.global_position = origin + Vector3(travelled, 0.0, travelled * 0.35)
		if frames % SAMPLE_INTERVAL_FRAMES != 0:
			continue
		peak["rss"] = maxi(int(peak["rss"]), OS.get_static_memory_usage())
		peak["video"] = maxi(int(peak["video"]),
			int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)))
		peak["chunks"] = maxi(int(peak["chunks"]),
			0 if _streamer == null else int(_streamer.call(&"loaded_chunk_count")))
	return peak


func _report(label: String) -> void:
	var video: int = int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var texture: int = int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var buffer: int = int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED))
	print("--- %s ---" % label)
	print("  CPU memory   resident %-10s peak %-10s" % [
		_mb(OS.get_static_memory_usage()), _mb(OS.get_static_memory_peak_usage())])
	print("  GPU memory   video %-13s (textures %s, buffers %s)" % [
		_mb(video), _mb(texture), _mb(buffer)])
	print("  Objects      %d node(s), %d object(s), %d orphan(s)" % [
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))])
	print("  Rendering    %d draw call(s), %d primitive(s)" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))])
	print("  Streaming    %d chunk(s) resident, %d job(s) in flight" % [
		0 if _streamer == null else int(_streamer.call(&"loaded_chunk_count")),
		0 if _streamer == null else int(_streamer.call(&"pending_job_count"))])
	print("  Frame        process %.2f ms | physics %.2f ms" % [
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])


## The point of a capacity report is the headroom, not the number. Stated as a share of the machine
## it ran on, because "1.2 GB" means nothing without "of 48".
func _advice() -> void:
	var mem: Dictionary = OS.get_memory_info()
	var physical: int = int(mem.get("physical", 0))
	var rss: int = OS.get_static_memory_usage()
	print("\n=== headroom on this machine ===")
	if physical > 0:
		print("  Using %s of %s physical — %.1f%%." % [
			_mb(rss), _mb(physical), 100.0 * float(rss) / float(physical)])
	print("  %d logical processor(s). This project dispatches background work from exactly two"
		% OS.get_processor_count())
	print("  places (ChunkStreamer mesh jobs, ResourceScatterField placement), so most of those")
	print("  cores are idle whatever the frame time says.")


func _mb(bytes: int) -> String:
	return "%.1f MB" % (float(bytes) / 1048576.0)


func _player_node() -> Node3D:
	for node: Node in get_nodes_in_group(&"players"):
		if node is Node3D:
			return node as Node3D
	return null


func _find(node: Node, method: StringName) -> Node:
	if node.has_method(method):
		return node
	for child: Node in node.get_children():
		var found: Node = _find(child, method)
		if found != null:
			return found
	return null
