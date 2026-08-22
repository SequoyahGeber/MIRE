extends SceneTree

const PerfFormat := preload("res://core/bench/perf_format.gd")

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
## Four places nobody has been, spread far enough apart that none of them streams another in, and
## picked to cross different ground (inland, toward shore, across the island) so they carry
## genuinely different scatter densities. Offsets from spawn, in metres.
## The cold/warm A-B legs. All five are distinct from each other and from DESTINATION, so no leg
## streams another in and none has cached geometry when it is measured.
const COLD_LEG := Vector3(-210.0, 0.0, 140.0)
const WARMING_LEGS: Array[Vector3] = [
	Vector3(180.0, 0.0, -210.0),
	Vector3(-120.0, 0.0, -330.0),
	Vector3(310.0, 0.0, 180.0),
]
const WARMED_LEG := Vector3(-350.0, 0.0, -110.0)
const SWEEP_OFFSETS: Array[Vector3] = [
	Vector3(-190.0, 0.0, -170.0),
	Vector3(150.0, 0.0, 320.0),
	Vector3(-330.0, 0.0, 90.0),
	Vector3(240.0, 0.0, -300.0),
]
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
## F-459. The two consumers that keep creating nodes AFTER the streamer reports itself idle —
## `ResourceScatterField`'s dressing queue and `NavBaker`'s bake queue. Settling on the streamer
## alone cut the arrival window at an arbitrary point in their work, which is why the same first
## visit measured 1382 nodes one run and 852 the next: the difference was not the visit, it was
## where the ruler stopped.
var _scatter: Node
var _nav_baker: Node
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
	_scatter = _find(root, &"pending_group_count")
	_nav_baker = _find(root, &"pending_bake_count")
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
	await _cold_versus_warmed_elsewhere(spawn)
	await _sweep_first_visits(spawn)
	var first: Dictionary = await _visit(spawn + DESTINATION, "FIRST visit")
	await _visit(spawn + ELSEWHERE, "elsewhere (evicting the destination)")
	var second: Dictionary = await _visit(spawn + DESTINATION, "SECOND visit — same place")
	node_added.disconnect(_on_node_added)

	_verdict(first, second)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	quit(0)


## F-459's decisive test, and the one that actually separates the two hypotheses.
##
## Both legs are places the player has NEVER been, so neither has any cached geometry — the F-501
## mesh cache is keyed by `(coord, lod)` and these coords are new to both. The ONLY thing the second
## leg has that the first did not is whatever visiting three unrelated locations in between left
## warm. Scatter assets are already warmed at startup by F-407's threaded `ResourceLoader` pass, so
## loading is not what changes hands here. Materials, shaders and render pipelines are.
##
##   · If the two legs cost the SAME, the arrival is paying per-node CPU work that every new place
##     owes afresh. Fix by creating less, or creating it off the frame.
##   · If the second leg is much CHEAPER, the cost was per-MATERIAL and one-time, and the fix is to
##     pre-warm every shipped material behind the loading screen where nobody feels it.
func _cold_versus_warmed_elsewhere(spawn: Vector3) -> void:
	print("=== cold first visit vs an equally-new place after warming elsewhere ===")
	print("(neither has cached geometry — only materials can have changed hands)\n")
	var cold: Dictionary = (await _visit(spawn + COLD_LEG, "A · cold, nothing warm"))["arrival"]
	for offset: Vector3 in WARMING_LEGS:
		await _visit(spawn + offset, "   warming %s" % offset)
	var warmed: Dictionary = (await _visit(
		spawn + WARMED_LEG, "B · equally new, materials warm"))["arrival"]

	var cold_cost: float = float(cold["low1"])
	var warm_cost: float = float(warmed["low1"])
	# F-592: the 1% low stays the headline and is now stated as the frame rate it corresponds to.
	print("\n  A cold        %6d node(s), %3d frame(s), 1%% low %5.0f fps (%.2f ms), %d hitch(es)"
		% [cold["nodes"], cold["frames"], PerfFormat.fps(cold_cost), cold_cost, cold["hitches"]])
	print("  B warm-ish    %6d node(s), %3d frame(s), 1%% low %5.0f fps (%.2f ms), %d hitch(es)"
		% [warmed["nodes"], warmed["frames"], PerfFormat.fps(warm_cost), warm_cost, warmed["hitches"]])
	print("  B vs A on arrival: %s" % PerfFormat.change_line(cold_cost, warm_cost))
	if warm_cost < cold_cost * 0.6:
		print("  -> MATERIALS. B is %.2fx cheaper than A on ground just as new, so the cost A paid"
			% (cold_cost / maxf(warm_cost, 0.001)))
		print("     was per-material and one-time. Pre-warm every shipped material behind the")
		print("     loading screen and the player never meets it.")
	elif warm_cost > cold_cost * 0.9:
		print("  -> PER-NODE CPU WORK. Warming elsewhere bought B nothing, so every new place owes")
		print("     this cost afresh. Pre-warming is the wrong fix; create less, or off the frame.")
	else:
		print("  -> PARTIAL. B is cheaper but not decisively so — some of the cost is shared and")
		print("     some is per-place. Widen WARMING_LEGS before drawing a conclusion.")
	print("")


## F-459's discriminator, second attempt. The first one asked whether the first visit creates more
## nodes than the second — a RATIO, which landed either side of its threshold run to run and proved
## nothing. This asks a better-posed question: across several places nobody has been before, does the
## arrival cost TRACK the number of nodes created?
##
## Every location here is a first visit, so whatever once-only cost exists is paid at all of them.
## What differs between them is how much scatter the ground carries, and therefore how many nodes
## enter the tree. If node creation is what the arrival is paying for, cost rises with node count. If
## cost is flat while node count swings, the cost is something the node counter cannot see — which is
## what pipeline compilation on first sight of a material would look like.
##
## Reported, never asserted. Four points is enough to see a slope or its absence and not enough to
## put a number on; anyone acting on this should widen `SWEEP_OFFSETS` first.
func _sweep_first_visits(spawn: Vector3) -> void:
	print("=== first-visit sweep: does arrival cost track nodes created? ===")
	var rows: Array[Dictionary] = []
	for offset: Vector3 in SWEEP_OFFSETS:
		var row: Dictionary = await _visit(spawn + offset, "sweep %s" % offset)
		rows.append(row["arrival"] as Dictionary)
	print("
  %-10s %-8s %-10s %-8s" % ["nodes", "frames", "1% low", "hitches"])
	var min_nodes: int = 1 << 30
	var max_nodes: int = 0
	var cost_at_min: float = 0.0
	var cost_at_max: float = 0.0
	for row: Dictionary in rows:
		print("  %-10d %-8d %-10.2f %-8d"
			% [row["nodes"], row["frames"], row["low1"], row["hitches"]])
		if int(row["nodes"]) < min_nodes:
			min_nodes = int(row["nodes"])
			cost_at_min = float(row["low1"])
		if int(row["nodes"]) > max_nodes:
			max_nodes = int(row["nodes"])
			cost_at_max = float(row["low1"])
	var node_ratio: float = float(max_nodes) / maxf(float(min_nodes), 1.0)
	var cost_ratio: float = cost_at_max / maxf(cost_at_min, 0.001)
	print("
  %.2fx the nodes (%d -> %d) bought %.2fx the arrival cost (%.2f -> %.2f ms)"
		% [node_ratio, min_nodes, max_nodes, cost_ratio, cost_at_min, cost_at_max])
	if node_ratio >= 1.5 and cost_ratio < node_ratio * 0.5:
		print("  -> cost does NOT track node creation. Whatever the arrival is paying for is mostly")
		print("     invisible to the node counter — consistent with per-material pipeline")
		print("     compilation, and NOT with once-only per-node CPU work.")
	elif node_ratio >= 1.5:
		print("  -> cost DOES track node creation. The arrival is paying for what enters the tree,")
		print("     so the fix is to create less or create it off the frame — not to pre-warm.")
	else:
		print("  -> inconclusive: these locations carry too similar a node count (%.2fx) to tell."
			% node_ratio)
	print("")


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
		if _world_is_quiet():
			quiet += 1
			if quiet >= SETTLE_QUIET_FRAMES:
				break
		else:
			quiet = 0
	var arrival: Dictionary = _summarize(settle_samples)
	arrival["nodes"] = settle_nodes
	arrival["frames"] = settle_frames
	print("%-38s ARRIVING  %4d frame(s) | median %5.0f fps | 1%% low %5.0f fps | worst %5.0f fps | hitches %3d | nodes added %6d  (%.2f / %.2f / %.2f ms)"
		% [label, settle_frames, PerfFormat.fps(arrival["median"]), PerfFormat.fps(arrival["low1"]),
			PerfFormat.fps(arrival["worst"]), arrival["hitches"], settle_nodes,
			arrival["median"], arrival["low1"], arrival["worst"]])

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
	print("%-38s SETTLED   %4d frame(s) | median %5.0f fps | 1%% low %5.0f fps | worst %5.0f fps | hitches %3d | nodes added %6d  (%.2f / %.2f / %.2f ms)\n"
		% [label, SAMPLE_FRAMES, PerfFormat.fps(result["median"]), PerfFormat.fps(result["low1"]),
			PerfFormat.fps(result["worst"]), result["hitches"], nodes,
			result["median"], result["low1"], result["worst"]])
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
	print("  1%% low   first %.0f fps  vs  second %.0f fps  —  %s"
		% [PerfFormat.fps(first_low), PerfFormat.fps(second_low),
			PerfFormat.change_line(first_low, second_low)])
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


## Every producer of per-chunk work is idle, not just the streamer. F-459 argued that a satisfied
## `settle_world()` ruled chunk streaming out as the cause; it only ever ruled out the streamer's own
## mesh jobs, and left the two systems that do the actual node creation still running.
func _world_is_quiet() -> bool:
	if int(_streamer.call(&"pending_job_count")) != 0:
		return false
	if _scatter != null and int(_scatter.call(&"pending_group_count")) != 0:
		return false
	if _nav_baker != null and int(_nav_baker.call(&"pending_bake_count")) != 0:
		return false
	return true


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
