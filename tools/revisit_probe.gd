extends SceneTree

## F-459: does a first visit hitch because of CPU work that only happens once, or because of GPU
## pipeline/shader compilation on first sight of a material?
##
## The finding is a measurement, not a diagnosis: "every location's FIRST visit hitches and its
## second does not", with the chunk streamer already reporting itself idle before either sample. The
## suspects it names — shader compilation, first-time `ResourceLoader` work, prop collider
## construction, `EnvironmentVfx` emitter registration — split cleanly into two families, and one
## number tells them apart:
##
##   · **CPU work that only happens once** (loads, colliders, emitter registration) creates objects.
##     It shows up as NODES ENTERING THE TREE, and there are far more of them on visit one.
##   · **GPU pipeline compilation** creates nothing. The scene graph on visit two is identical to
##     visit one; only the driver's pipeline cache differs.
##
## So this visits the same place twice, with an identical approach both times, and reports frame
## times AND nodes added for each visit. Same hitch with the same node count means the cost is on the
## GPU and the fix is pre-warming pipelines. Same hitch with far fewer nodes means it was CPU work
## that the second visit had already done, and the fix is to do it earlier or off the main thread.
##
## Deliberately teleports rather than walking: F-454's traversal hitch is a DIFFERENT problem (the
## streamer building ground it has not built before), and walking there would mix the two. Each
## sample happens after the world has settled at the destination, which is the condition
## `BenchmarkRunner.settle_world()` established for the original measurement.
##
##     .agent/bin/agent godot --display-driver macos --script tools/revisit_probe.gd

const ProbeScene := preload("res://tools/probe_scene.gd")

## Where to go. Offsets from spawn, in metres — far enough apart that nothing streamed for one is
## still resident for the other.
const DESTINATION := Vector3(260.0, 0.0, -240.0)
const ELSEWHERE := Vector3(-280.0, 0.0, 260.0)
## Frames sampled at a destination once its world has settled.
const SAMPLE_FRAMES: int = 180
## How long to wait for streaming to go quiet after a teleport.
const SETTLE_MAX_FRAMES: int = 1800
const SETTLE_QUIET_FRAMES: int = 30
## A frame worth calling a hitch, at the 60 fps this project ships to.
const HITCH_MS: float = 16.667
## How long to wait for a run to stand its world up. Same reason as `traversal_profile.gd`: the
## shipped scene boots into a menu and builds `ProceduralWorld` at runtime.
const WORLD_WAIT_FRAMES: int = 600

var _level: Node3D
var _player: Node3D
var _streamer: Node
var _nodes_added: int = 0
## Set false unless the run has grounds to trust the node-count discriminator. See `_verdict()`:
## across two runs of this probe the first visit's node count came out 1382 then 852 against a
## second visit that was 460 both times, so the ratio crossed the 2x line one run and not the next.
## The probe therefore refuses to name GPU-versus-CPU on the strength of one run.
var _stable: bool = false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("revisit_probe needs a real renderer — the whole question is whether the cost "
			+ "is GPU pipeline compilation, and the dummy driver compiles nothing. Re-run with "
			+ "--display-driver macos (see the header).")
		quit(1)
		return
	root.mode = Window.MODE_FULLSCREEN
	root.title = "MIRE revisit probe (F-459) — hands off"
	# Same reason as traversal_profile.gd: a frame limiter hides exactly the frames being measured.
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

	print("\n=== MIRE revisit probe (F-459) ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_name()])
	print("measuring %s | seed %d" % [ProbeScene.describe(scene_path), pinned_seed])

	for _i: int in 8:
		await physics_frame
	for _i: int in WORLD_WAIT_FRAMES:
		if _find(root, &"pending_job_count") != null:
			break
		await process_frame
	_streamer = _find(root, &"pending_job_count")
	_player = _player_node()
	if _player == null or _streamer == null:
		push_error("no player (%s) or streamer (%s) — nothing to probe"
			% [_player != null, _streamer != null])
		quit(1)
		return
	await ProbeScene.settle(root)
	var spawn: Vector3 = _player.global_position
	print("spawn %s | destination %s\n" % [spawn, spawn + DESTINATION])

	node_added.connect(_on_node_added)
	var first: Dictionary = await _visit(spawn + DESTINATION, "FIRST visit")
	await _visit(spawn + ELSEWHERE, "elsewhere (evicting the destination)")
	var second: Dictionary = await _visit(spawn + DESTINATION, "SECOND visit — same place")
	node_added.disconnect(_on_node_added)

	_verdict(first, second)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	quit(0)


## Teleport, let the world settle, then sample. The settle is what makes this a fair comparison:
## without it the first visit would simply be measuring the streamer still working.
func _visit(destination: Vector3, label: String) -> Dictionary:
	_player.global_position = destination
	# The SETTLE is measured, not skipped. The first version of this probe sampled only after the
	# world went quiet and found the first visit no worse than the second — because everything that
	# distinguishes them happens while the world is still arriving. Settling took 211 frames on the
	# first visit and 149 on the second, and the sample windows either side of that were identical
	# down to the node count. So the arrival is the measurement.
	var settle_frames: int = 0
	var quiet: int = 0
	var settle_samples: Array[float] = []
	var settle_nodes: int = 0
	var settle_last: int = Time.get_ticks_usec()
	while settle_frames < SETTLE_MAX_FRAMES:
		_nodes_added = 0
		await process_frame
		var settle_now: int = Time.get_ticks_usec()
		settle_samples.append(float(settle_now - settle_last) / 1000.0)
		settle_last = settle_now
		settle_nodes += _nodes_added
		settle_frames += 1
		if int(_streamer.call(&"pending_job_count")) == 0:
			quiet += 1
			if quiet >= SETTLE_QUIET_FRAMES:
				break
		else:
			quiet = 0
	var arrival: Dictionary = _summarize(settle_samples)
	arrival["nodes"] = settle_nodes
	print("%-38s ARRIVING  %4d frame(s) | median %6.2f ms | 1%% low %7.2f ms | worst %7.2f ms | hitches %3d | nodes added %6d"
		% [label, settle_frames, arrival["median"], arrival["low1"], arrival["worst"],
			arrival["hitches"], settle_nodes])

	var samples: Array[float] = []
	var nodes: int = 0
	var last: int = Time.get_ticks_usec()
	for _i: int in SAMPLE_FRAMES:
		_nodes_added = 0
		await process_frame
		var now: int = Time.get_ticks_usec()
		samples.append(float(now - last) / 1000.0)
		last = now
		nodes += _nodes_added

	var result: Dictionary = _summarize(samples)
	result["label"] = label
	result["nodes"] = nodes
	result["settle_frames"] = settle_frames
	result["arrival"] = arrival
	print("%-38s SETTLED   %4d frame(s) | median %6.2f ms | 1%% low %7.2f ms | worst %7.2f ms | hitches %3d | nodes added %6d\n"
		% [label, SAMPLE_FRAMES, result["median"], result["low1"], result["worst"],
			result["hitches"], nodes])
	return result


## 1% low as the mean of the slowest 1% of frames — the same definition `tools/perf_probe.gd` uses,
## so these numbers can be read next to F-459's own.
func _summarize(samples: Array[float]) -> Dictionary:
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var total: float = 0.0
	var hitches: int = 0
	for ms: float in sorted:
		total += ms
		if ms >= HITCH_MS:
			hitches += 1
	var tail_count: int = maxi(1, sorted.size() / 100)
	var tail: float = 0.0
	for i: int in tail_count:
		tail += sorted[sorted.size() - 1 - i]
	return {
		"median": sorted[sorted.size() / 2],
		"mean": total / float(sorted.size()),
		"worst": sorted[sorted.size() - 1],
		"low1": tail / float(tail_count),
		"hitches": hitches,
	}


## The whole point: say which family the cost belongs to rather than leaving a reader to eyeball it.
func _verdict(first: Dictionary, second: Dictionary) -> void:
	# The verdict reads the ARRIVAL, not the settled window — see `_visit()`.
	var first_arrival: Dictionary = first["arrival"]
	var second_arrival: Dictionary = second["arrival"]
	var first_low: float = first_arrival["low1"]
	var second_low: float = second_arrival["low1"]
	var first_nodes: int = first_arrival["nodes"]
	var second_nodes: int = second_arrival["nodes"]
	print("\n=== verdict (on ARRIVAL — where the two visits actually differ) ===")
	print("  1%% low   first %.2f ms  vs  second %.2f ms  (%.2fx)"
		% [first_low, second_low, first_low / maxf(second_low, 0.001)])
	print("  frames   first %d  vs  second %d to settle"
		% [first["settle_frames"], second["settle_frames"]])
	print("  nodes    first %d  vs  second %d" % [first_nodes, second_nodes])
	if _streamer != null and _streamer.has_method(&"mesh_cache_stats"):
		var stats: Array = _streamer.call(&"mesh_cache_stats")
		print("  F-501 mesh cache: %d hit(s), %d miss(es) — %.0f%% hit rate | %d/%d entries (~%.1f MB)"
			% [stats[0], stats[1],
				100.0 * float(stats[0]) / maxf(float(stats[0] + stats[1]), 1.0),
				stats[2], stats[3],
				float(_streamer.call(&"mesh_cache_bytes")) / 1048576.0])

	# Which number decides. NOT the 1% low: an arrival window is a handful of large frames in a sea
	# of ordinary ones, so its tail is dominated by the single worst frame and moves 20-30% between
	# identical runs on a shared machine. How LONG the arrival takes and how MANY frames blew the
	# budget are counts over the whole window, and they separate the two visits cleanly where the
	# tail does not — 213 frames and 6 hitches against 144 and 2, on a run whose 1% lows were 48 ms
	# and 38 ms. Reading the tail alone would have called that "not reproduced".
	var first_hitches: int = first_arrival["hitches"]
	var second_hitches: int = second_arrival["hitches"]
	print("  hitches  first %d  vs  second %d" % [first_hitches, second_hitches])
	var slower: bool = first["settle_frames"] > int(float(second["settle_frames"]) * 1.3) \
		or first_hitches > maxi(second_hitches, 1) * 2
	if not slower:
		print("  -> NOT REPRODUCED here. The first visit is not meaningfully worse than the second,")
		print("     so whatever F-459 measured is not present in this scenario — check the")
		print("     destination is far enough out, or that the benchmark's own path differs.")
	elif first_nodes > maxi(second_nodes, 1) * 2 and _stable:
		print("  -> CPU, ONCE-ONLY WORK. The first visit hitches AND creates far more nodes, so the")
		print("     cost is what enters the tree: first-time ResourceLoader work, prop colliders,")
		print("     EnvironmentVfx emitter registration. Fix by doing it earlier or off the main")
		print("     thread — NOT by pre-warming shaders.")
	else:
		print("  -> REPRODUCED, CAUSE NOT SEPARATED. The first visit is measurably worse, and it is")
		print("     worse during ARRIVAL — the settled window either side of it is clean, which")
		print("     corrects F-459's framing that the streamer being idle rules streaming out.")
		print("     But the node count does not separate the two hypotheses reliably: it varies")
		print("     run to run for the SAME first visit (1382, then 852, against a second visit")
		print("     that was 460 both times), so a ratio either side of 2x is not evidence.")
		print("     Both are still live: some once-only CPU work is certainly happening (the first")
		print("     visit always creates more nodes), and pipeline compilation would be invisible")
		print("     to this counter entirely. Separating them needs a run with the scatter tables")
		print("     reduced to ONE asset — identical geometry, one material — so that node creation")
		print("     and material variety move independently.")
	print("\nREVISIT_PROBE done")


func _on_node_added(_node: Node) -> void:
	_nodes_added += 1


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
