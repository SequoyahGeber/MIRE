extends SceneTree
const PerfFormat := preload("res://core/bench/perf_format.gd")

## What the traversal hitch is actually made of (F-454).
##
##   .agent/bin/agent godot --display-driver macos --script tools/traversal_profile.gd
##
## `tools/perf_probe.gd` established the SIZE of the problem: standing still, the shipped world
## holds an 81 fps 1% low; walking into unstreamed terrain it is 13 fps — 74 ms frames — and no
## graphics preset touches it. This tool answers the next question, which is *what is in those
## frames*, without guessing.
##
## It walks the streamer's anchor body through unloaded ground exactly the way the probe's traversal
## rows do, and records, for EVERY frame:
##
##   · the frame's own wall-clock delta
##   · `ChunkStreamer.last_process_cost_ms()` — that node's self-reported issuing cost, so
##     "the streamer blew its own 4 ms budget" can be told apart from "something else did"
##   · nodes added to the tree that frame, counted off `SceneTree.node_added`
##   · chunks resident and jobs in flight
##
## Then it prints the worst frames with all four numbers side by side. A 74 ms frame whose streamer
## cost is 3 ms and which added 2,000 nodes is a different bug from a 74 ms frame whose streamer
## cost is 70 ms, and the fix for one is not the fix for the other.
##
## Needs a display: the hitch is only reproducible with a real renderer under load, and a headless
## run has no frames to be slow. Fullscreen, ~60 s, hands off the machine.
##
## AUTHORITY: none — an instrument.

const ProbeScene := preload("res://tools/probe_scene.gd")

## Metres per second the anchor walks. Roughly sprint speed: the streamer must be continuously
## building for the frames this tool exists to catch to appear at all.
const TRAVEL_SPEED: float = 7.0
## How long to walk for, after the world has settled.
const TRAVEL_SECONDS: float = 45.0
## A frame at or above this is a hitch worth attributing. 25 ms is 40 fps — comfortably past
## "a slow frame" and well short of the 74 ms the probe measured.
const HITCH_MS: float = 25.0
## How many of the worst frames to print in full.
const WORST_FRAMES_SHOWN: int = 20
## Radius to stay inside, so the walk does not end up over open ocean where nothing streams.
const TRAVEL_RADIUS_M: float = 190.0

var _level: Node3D
var _player: Node3D
var _streamer: Node
var _nav_baker: Node
var _scatter: Node
var _travel_origin: Vector3 = Vector3.ZERO
var _heading: float = 0.0
## Reset every frame; counts `node_added` signals so a hitch can be attributed to tree churn.
var _nodes_added_this_frame: int = 0

## One row per sampled frame.
var _frames: Array[Dictionary] = []

## F-456. How long to wait for a run to stand its world up before settling. The shipped scene boots
## into a menu, so the streamer does not exist on frame one; generous because this is a wait for a
## world build, not a per-frame budget.
const STREAMER_WAIT_FRAMES: int = 600


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("traversal_profile needs a display — run with --display-driver macos after "
			+ "the wrapper's --headless (see the header of this file)")
		quit(1)
		return
	root.mode = Window.MODE_FULLSCREEN
	root.title = "MIRE traversal profile (F-454) — hands off, ~60s"
	# Nothing here is comparable under a frame limiter, and the hitches are exactly the frames a
	# limiter would hide behind its own pacing (F-452).
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var pinned_seed: int = ProbeScene.pin_seed(self)
	var scene_path: String = ProbeScene.resolve()
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("could not load %s" % scene_path)
		quit(1)
		return
	_level = packed.instantiate() as Node3D
	root.add_child(_level)
	current_scene = _level

	print("\n=== MIRE traversal profile (F-454) ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_name()])
	print("measuring %s | seed %d" % [ProbeScene.describe(scene_path), pinned_seed])

	for _i: int in 8:
		await physics_frame
	# F-456: the shipped scene is a menu that builds `ProceduralWorld` (and with it the streamer)
	# only once a run starts, and it does not parent that world under the scene this tool
	# instantiated. Searching `_level` therefore found no streamer, so `settle()` returned
	# instantly, "0 chunk(s) in 0 frame(s)", and the whole walk was measured against an empty
	# world. Wait for the streamer to actually exist, and search from `root` so it is found
	# wherever the run puts it.
	for _i: int in STREAMER_WAIT_FRAMES:
		if _find_streamer(root) != null:
			break
		await process_frame
	var settle: Dictionary = await ProbeScene.settle(root)
	print("settled: %d chunk(s) in %d frame(s)" % [
		int(settle.get("chunks", 0)), int(settle.get("frames", 0))])

	_player = _find_player()
	if _player == null:
		push_error("no player found — nothing to anchor the walk on")
		quit(1)
		return
	_travel_origin = _player.global_position
	_streamer = _find_streamer(root)
	_nav_baker = _find_with(root, &"pending_bake_count")
	_scatter = _find_with(root, &"pending_group_count")
	if _streamer == null:
		print("  (no ChunkStreamer found — per-frame streamer cost will read 0)")
	print("walking %.0f m/s for %.0f s from %s\n" % [
		TRAVEL_SPEED, TRAVEL_SECONDS, _travel_origin])

	node_added.connect(_on_node_added)
	await _walk()
	node_added.disconnect(_on_node_added)

	_report()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	quit(0)


func _on_node_added(_node: Node) -> void:
	_nodes_added_this_frame += 1


func _walk() -> void:
	var start: int = Time.get_ticks_usec()
	var last: int = start
	while float(Time.get_ticks_usec() - start) / 1e6 < TRAVEL_SECONDS:
		_nodes_added_this_frame = 0
		await process_frame
		var now: int = Time.get_ticks_usec()
		var frame_ms: float = float(now - last) / 1000.0
		last = now
		_step()
		_frames.append({
			"ms": frame_ms,
			"streamer_ms": 0.0 if _streamer == null \
				else float(_streamer.call(&"last_process_cost_ms")),
			# F-461: the streamer's own cost split across the three things `_process()` does, plus
			# what it actually did. "The streamer spent 60 ms" is not a diagnosis; "it spent 60 ms
			# cooking two colliders" is.
			"phases": ([0.0, 0.0, 0.0, 0.0] as Array[float]) if _streamer == null \
				or not _streamer.has_method(&"last_phase_costs_ms") \
				else (_streamer.call(&"last_phase_costs_ms") as Array),
			"counts": ([0, 0] as Array[int]) if _streamer == null \
				or not _streamer.has_method(&"last_phase_counts") \
				else (_streamer.call(&"last_phase_counts") as Array),
			"nodes_added": _nodes_added_this_frame,
			"chunks": 0 if _streamer == null else int(_streamer.call(&"loaded_chunk_count")),
			"pending": 0 if _streamer == null else int(_streamer.call(&"pending_job_count")),
			# Godot's own split of main-thread time. A 100 ms frame that added six nodes and
			# spent nothing in `_process` is physics or servers, not gameplay code — and that
			# is a different bug from the one the node counter catches (F-454).
			"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			"nav_pending": 0 if _nav_baker == null \
				else int(_nav_baker.call(&"pending_bake_count")),
			"groups_pending": 0 if _scatter == null \
				else int(_scatter.call(&"pending_group_count")),
			"at_second": float(now - start) / 1e6,
		})


## Advances the anchor along a slow spiral. Position is written directly rather than driven through
## the controller: this wants a repeatable path across unstreamed ground, not a physics simulation,
## and `ProceduralWorld._physics_process()` re-anchors the streamer on the body's position either
## way.
func _step() -> void:
	_heading += 0.004
	var step: float = TRAVEL_SPEED / 60.0
	var moved: Vector3 = _player.global_position \
		+ Vector3(cos(_heading), 0.0, sin(_heading)) * step
	if moved.distance_to(_travel_origin) > TRAVEL_RADIUS_M:
		_heading += PI
		moved = _player.global_position + Vector3(cos(_heading), 0.0, sin(_heading)) * step
	_player.global_position = moved


func _report() -> void:
	if _frames.is_empty():
		print("no frames sampled")
		return
	var sorted: Array[Dictionary] = _frames.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ms"]) > float(b["ms"]))

	var total: float = 0.0
	var hitches: int = 0
	var hitch_ms_total: float = 0.0
	var nodes_total: int = 0
	for frame: Dictionary in _frames:
		total += float(frame["ms"])
		nodes_total += int(frame["nodes_added"])
		if float(frame["ms"]) >= HITCH_MS:
			hitches += 1
			hitch_ms_total += float(frame["ms"])

	print("=== %d frames over %.1f s ===" % [_frames.size(), total / 1000.0])
	# F-592: frame rates lead. The worst frame is the one that matters and is stated last so it is
	# the number left in the reader's eye, not buried between two healthier ones.
	var median_ms: float = float(sorted[sorted.size() / 2]["ms"])
	var mean_ms: float = total / float(_frames.size())
	var worst_ms: float = float(sorted[0]["ms"])
	print("  median %.0f fps | mean %.0f fps | worst frame %.0f fps  (%.2f / %.2f / %.2f ms)" % [
		PerfFormat.fps(median_ms), PerfFormat.fps(mean_ms), PerfFormat.fps(worst_ms),
		median_ms, mean_ms, worst_ms])
	print("  frames slower than %.0f fps: %d (%.1f%% of frames, %.1f%% of the wall clock)" % [
		PerfFormat.fps(HITCH_MS), hitches, 100.0 * float(hitches) / float(_frames.size()),
		100.0 * hitch_ms_total / total])
	print("  nodes added over the walk: %d (%.0f per frame average)" % [
		nodes_total, float(nodes_total) / float(_frames.size())])

	print("\n=== the %d worst frames ===" % WORST_FRAMES_SHOWN)
	# F-456 added `s:emit` — the share of `s:drain` spent inside OTHER nodes' `chunk_mesh_ready`
	# handlers (scatter dressing, nav bake queueing). It is a subset of drain, not a fourth column
	# of disjoint cost, so `s:drain` minus `s:emit` is what the streamer itself actually spent.
	print("  %8s %8s %8s %8s | %7s %7s %7s %7s %5s %5s | %6s %6s %6s" % [
		"frame ms", "process", "physics", "streamer",
		"s:eval", "s:drain", "s:emit", "s:cook", "up", "cook",
		"nodes", "grpQ", "at s"])
	for i: int in mini(WORST_FRAMES_SHOWN, sorted.size()):
		var frame: Dictionary = sorted[i]
		var phases: Array = frame["phases"]
		var counts: Array = frame["counts"]
		var emit_ms: float = float(phases[3]) if phases.size() > 3 else 0.0
		print("  %8.2f %8.2f %8.2f %8.2f | %7.2f %7.2f %7.2f %7.2f %5d %5d | %6d %6d %6.1f" % [
			frame["ms"], frame["process_ms"], frame["physics_ms"], frame["streamer_ms"],
			phases[0], phases[1], emit_ms, phases[2], counts[0], counts[1],
			frame["nodes_added"], frame["groups_pending"],
			frame["at_second"]])

	_attribute(sorted)
	print("\nTRAVERSAL_PROFILE done")


## The whole point of the tool: say which of the two stories the numbers tell, rather than leaving
## a reader to eyeball a table. Correlation over the hitch frames only — the quiet frames are not
## what anyone is trying to explain.
func _attribute(sorted: Array[Dictionary]) -> void:
	var hitch_frames: Array[Dictionary] = []
	for frame: Dictionary in sorted:
		if float(frame["ms"]) >= HITCH_MS:
			hitch_frames.append(frame)
	if hitch_frames.is_empty():
		print("\n  No frame reached %.0f ms — nothing to attribute." % HITCH_MS)
		return

	var streamer_share: float = 0.0
	var frame_total: float = 0.0
	var nodes_in_hitches: int = 0
	for frame: Dictionary in hitch_frames:
		streamer_share += float(frame["streamer_ms"])
		frame_total += float(frame["ms"])
		nodes_in_hitches += int(frame["nodes_added"])

	var quiet_nodes: int = 0
	var quiet_count: int = 0
	for frame: Dictionary in _frames:
		if float(frame["ms"]) < HITCH_MS:
			quiet_nodes += int(frame["nodes_added"])
			quiet_count += 1

	var process_total: float = 0.0
	var physics_total: float = 0.0
	for frame: Dictionary in hitch_frames:
		process_total += float(frame["process_ms"])
		physics_total += float(frame["physics_ms"])

	print("\n=== attribution over the %d hitch frames ===" % hitch_frames.size())
	print("  Main-thread split: %.1f%% in _process, %.1f%% in _physics_process, %.1f%% elsewhere"
		% [100.0 * process_total / frame_total, 100.0 * physics_total / frame_total,
			100.0 * (frame_total - process_total - physics_total) / frame_total])
	print("  (\"elsewhere\" is servers and drivers — physics body creation, navmesh commits,"
		+ " shader compilation, buffer uploads.)")
	# Already a percentage, and it names the total it is a share of — the shape F-592 asks for.
	print("  ChunkStreamer's own reported cost accounts for %.1f%% of hitch time (%.2f of %.2f ms)."
		% [100.0 * streamer_share / frame_total, streamer_share, frame_total])
	print("  Nodes added: %.0f per hitch frame vs %.0f per quiet frame." % [
		float(nodes_in_hitches) / float(hitch_frames.size()),
		0.0 if quiet_count == 0 else float(quiet_nodes) / float(quiet_count)])
	if streamer_share / frame_total > 0.5:
		print("  -> The streamer is overrunning its own FRAME_BUDGET_MS. Look there first.")
	elif quiet_count > 0 and float(nodes_in_hitches) / float(hitch_frames.size()) \
			> 4.0 * maxf(1.0, float(quiet_nodes) / float(quiet_count)):
		print("  -> The streamer is inside its budget and the hitch frames are the ones that")
		print("     ADD NODES. The cost is downstream of streaming: whatever instantiates and")
		print("     enters the tree per newly-resident chunk (scatter placement, prop wiring,")
		print("     nav bake), none of which the 4 ms budget covers.")
	else:
		print("  -> Neither the streamer's own cost nor tree churn explains these frames.")
		print("     Next suspects: the nav bake, physics body creation, or shader compilation.")


## First node in the tree with [param method]. Duck-typed so an instrument never needs a class
## reference to something it only reads counters off.
## The shipped scene (`levels/frontend.tscn`) is a bare `Node3D` that BUILDS its world at runtime,
## so there is no authored `Player` child to fetch by name — this used to read
## `_level.get_node_or_null(^"Player")` and abort every run with "no Player node". The player
## controller adds itself to the `players` group (`entities/player/player_controller.gd`), which is
## the same handle every shipped system uses to find it, so ask the tree for that instead. The
## named-child lookup stays as a fallback for an authored fixture (`--scene`) that does have one.
func _find_player() -> Node3D:
	for node: Node in get_nodes_in_group(&"players"):
		if node is Node3D:
			return node as Node3D
	return _level.get_node_or_null(^"Player") as Node3D


func _find_with(node: Node, method: StringName) -> Node:
	if node.has_method(method):
		return node
	for child: Node in node.get_children():
		var found: Node = _find_with(child, method)
		if found != null:
			return found
	return null


func _find_streamer(node: Node) -> Node:
	if node.has_method(&"last_process_cost_ms") and node.has_method(&"loaded_chunk_count"):
		return node
	for child: Node in node.get_children():
		var found: Node = _find_streamer(child)
		if found != null:
			return found
	return null
