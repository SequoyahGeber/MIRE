extends SceneTree

## SPIKE R3 benchmark — throwaway. Run headless:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/bench_navbake.gd
##
## Answers: can we bake navigation on runtime-generated terrain chunks without a visible
## hitch, and do adjacent chunks connect across the seam? Prints numbers only; the verdict
## goes in docs/DECISIONS.md (D-016).
##
## The number that matters is not "how long does a bake take" — it is "how long is the MAIN
## THREAD stalled". A 200 ms bake on a worker is fine; a 40 ms bake that blocks is not. So
## every measurement here is engine-side wall time between our own callbacks: we stamp a
## clock immediately before yielding the frame and read it again on entry to _process, so
## anything the engine does in between — physics, navigation map sync, deferred bake
## completion callbacks — is counted, and none of this script's own work is.
##
## Three traps this harness had to work around, all worth knowing before writing nav code:
##   1. Headless sleeps low_processor_usage_mode_sleep_usec (6.9 ms) every frame because the
##      dummy window can never draw. That is 3x the hitch we are looking for.
##   2. A navigation map is not queryable until the server syncs it on a physics frame.
##      map_force_update() does not force that, and map_get_iteration_id() reaches 1 while
##      the polygon graph is still empty. Both give a false "ready".
##   3. Triangle winding is silently load-bearing — see nav_bake_probe.gd.

const Probe = preload("res://world/chunk/nav_bake_probe.gd")

const SYNC_BAKE_RUNS: int = 20
const WARMUP_BAKES: int = 3
const CELL_SIZE_SAMPLES: int = 5
const BASELINE_FRAMES: int = 20000
const ASYNC_RUNS: int = 5
const BURST_CHUNKS: int = 16          # worst case: a 4x4 region arrives all at once
const ATTACH_RUNS: int = 8
const STREAM_CHUNKS: int = 24         # realistic case: chunks arrive one at a time
const STREAM_LIVE: int = 9            # a 3x3 window of navigation around the player
const SEAM_OVERLAP: float = 4.0
const FRAME_BUDGET_MS: float = 16.667
const HITCH_MS: float = 2.0           # GREEN threshold for main-thread block
const HARD_TIMEOUT_S: float = 300.0
const MAX_SAMPLES: int = 400000

var _gaps: PackedFloat64Array = PackedFloat64Array()
var _last_exit_us: int = 0
var _collect: bool = false
var _pending: int = 0
var _loop_start_us: int = 0

var _sync_median_ms: float = 0.0
var _baseline_p50: float = 0.0
var _baseline_ref: float = 0.0
var _single_block_ms: PackedFloat64Array = PackedFloat64Array()
var _single_wall_ms: PackedFloat64Array = PackedFloat64Array()
var _single_submit_ms: PackedFloat64Array = PackedFloat64Array()
var _burst_block_ms: float = 0.0
var _attach_block_ms: PackedFloat64Array = PackedFloat64Array()
var _stream_block_ms: float = 0.0
var _seam_ok: bool = false
## Set by `_report()`; read by the quit below so a missed budget leaves a nonzero status (F-347).
var _verdict_failed: bool = false
var _seam_strategy: String = "none"
var _control_ok: bool = false


func _initialize() -> void:
	# Headless sleeps low_processor_usage_mode_sleep_usec (default 6900 us) every frame
	# because the dummy window can never draw — clearing the mode flag alone does nothing.
	# 6.9 ms would bury the hitch we are trying to detect, so shrink the sleep instead.
	OS.low_processor_usage_mode = false
	OS.low_processor_usage_mode_sleep_usec = 100
	Engine.max_fps = 0

	print("=== MIRE Spike R3 — runtime NavMesh bake on generated chunks ===")
	print("Godot %s | %s | %d logical cores" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_count(),
	])
	print("Chunk: %.0f m x %.0f m terrain at %.0f m grid | agent radius %.2f m, cell %.2f m" % [
		Probe.CHUNK_SIZE, Probe.CHUNK_SIZE, Probe.TERRAIN_STEP,
		Probe.DEFAULT_AGENT_RADIUS, Probe.DEFAULT_CELL_SIZE,
	])
	print("")

	if not _sanity():
		quit(1)
		return

	_bench_sync()
	_bench_cell_size()
	_bench_region_size()

	_loop_start_us = Time.get_ticks_usec()
	_run_frame_phases()


## Everything below needs the engine to actually run frames, so it lives in a coroutine
## kicked off from _initialize() and driven by the main loop.
func _run_frame_phases() -> void:
	await _measure_async()
	await _bench_seams()
	_report()
	quit(1 if _verdict_failed else 0)


func _process(_delta: float) -> bool:
	var entry: int = Time.get_ticks_usec()
	if _collect and _last_exit_us > 0 and _gaps.size() < MAX_SAMPLES:
		_gaps.append(float(entry - _last_exit_us) / 1000.0)
	if _loop_start_us > 0 and float(entry - _loop_start_us) / 1000000.0 > HARD_TIMEOUT_S:
		printerr("[bench] TIMED OUT with %d bakes pending" % _pending)
		quit(1)
	return false


## Yield a frame. Stamping the clock here rather than in _process is the whole trick: the
## interval measured is engine-side only, with this script's work excluded at both ends.
func _idle() -> void:
	_last_exit_us = Time.get_ticks_usec()
	await process_frame


func _on_bake_done() -> void:
	_pending -= 1


# --- 0. sanity -----------------------------------------------------------------------

## If the bake produces no polygons every number below is noise, so gate on it. Not
## paranoia: a flipped triangle winding bakes an empty mesh and reports no error at all.
func _sanity() -> bool:
	var nm: NavigationMesh = Probe.make_nav_mesh()
	var geom: NavigationMeshSourceGeometryData3D = Probe.make_source_geometry(0, 0)
	Probe.bake_sync(nm, geom)
	var ext: Vector2 = Probe.extent_x(nm)
	print("[sanity] %d source tris -> %d polys, %d verts | local x extent %.2f..%.2f" % [
		geom.get_indices().size() / 3, nm.get_polygon_count(), nm.get_vertices().size(),
		ext.x, ext.y,
	])
	if nm.get_polygon_count() == 0:
		printerr("[sanity] FAILED — bake produced zero polygons. Check triangle winding.")
		return false
	return true


# --- 1. synchronous bake cost --------------------------------------------------------

func _bench_sync() -> void:
	for i: int in WARMUP_BAKES:
		Probe.bake_sync(Probe.make_nav_mesh(), Probe.make_source_geometry(i, 0))

	var samples: PackedFloat64Array = PackedFloat64Array()
	var geom_ms: PackedFloat64Array = PackedFloat64Array()
	for i: int in SYNC_BAKE_RUNS:
		var t0: int = Time.get_ticks_usec()
		var geom: NavigationMeshSourceGeometryData3D = Probe.make_source_geometry(i, 0)
		geom_ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		samples.append(Probe.bake_sync(Probe.make_nav_mesh(), geom))
	samples.sort()
	geom_ms.sort()
	_sync_median_ms = _pct(samples, 0.5)
	print("--- 1. blocking bake, one 32 m chunk ---")
	print("  %d chunks | min %.2f | median %.2f | mean %.2f | max %.2f ms" % [
		SYNC_BAKE_RUNS, samples[0], _sync_median_ms, _mean(samples), samples[samples.size() - 1],
	])
	print("  source-geometry build (GDScript, main thread): median %.2f ms/chunk" % [
		_pct(geom_ms, 0.5),
	])
	print("  a blocking bake costs %.0f%% of a 16.7 ms frame" % [
		100.0 * _sync_median_ms / FRAME_BUDGET_MS,
	])


# --- 2. how bake time scales with cell_size ------------------------------------------

func _bench_cell_size() -> void:
	print("")
	print("--- 2. bake time vs cell_size (32 m chunk, blocking, median of %d) ---" % CELL_SIZE_SAMPLES)
	for cs: float in [0.1, 0.15, 0.2, 0.25, 0.3, 0.5, 1.0]:
		var samples: PackedFloat64Array = PackedFloat64Array()
		var polys: int = 0
		for i: int in CELL_SIZE_SAMPLES:
			var nm: NavigationMesh = Probe.make_nav_mesh(cs)
			samples.append(Probe.bake_sync(nm, Probe.make_source_geometry(i, 0)))
			polys = nm.get_polygon_count()
		samples.sort()
		var cells: int = int(Probe.CHUNK_SIZE / cs)
		print("  cell_size %.2f m (%3dx%3d voxels): %7.2f ms | %d polys" % [
			cs, cells, cells, _pct(samples, 0.5), polys,
		])


# --- 3. bake a bigger region less often ----------------------------------------------

func _bench_region_size() -> void:
	print("")
	print("--- 3. bake time vs region size (cell 0.25 m, blocking, median of %d) ---" % CELL_SIZE_SAMPLES)
	print("  (prices the mitigation: one bake over N chunks instead of N bakes, no seams inside)")
	for side: int in [1, 2, 4]:
		var samples: PackedFloat64Array = PackedFloat64Array()
		var polys: int = 0
		for _i: int in CELL_SIZE_SAMPLES:
			var nm: NavigationMesh = Probe.make_nav_mesh()
			samples.append(Probe.bake_sync(nm, Probe.make_region_source_geometry(side)))
			polys = nm.get_polygon_count()
		samples.sort()
		var median: float = _pct(samples, 0.5)
		var chunks: int = side * side
		print("  %dx%d chunks (%3.0f m square, %2d chunks): %8.2f ms | %6.2f ms/chunk | %d polys" % [
			side, side, Probe.CHUNK_SIZE * float(side), chunks, median,
			median / float(chunks), polys,
		])


# --- 4. main-thread blocking ---------------------------------------------------------

func _measure_async() -> void:
	print("")
	print("--- 4. main-thread blocking ---")

	# 4a. What an idle frame costs, so we have something to subtract.
	_collect = true
	_gaps.clear()
	while _gaps.size() < BASELINE_FRAMES:
		await _idle()
	_collect = false
	_gaps.sort()
	_baseline_p50 = _pct(_gaps, 0.5)
	# Compare against p99.9, not the median: idle frames that happen to carry a physics tick
	# are already slower, and charging those to the bake would invent a hitch.
	_baseline_ref = _pct(_gaps, 0.999)
	print("  [baseline] %d idle frames | p50 %.3f | p99 %.3f | p99.9 %.3f | max %.3f ms" % [
		_gaps.size(), _baseline_p50, _pct(_gaps, 0.99), _baseline_ref, _gaps[_gaps.size() - 1],
	])

	# 4b. One async bake in isolation. Does the threaded bake touch the main thread at all?
	for run: int in ASYNC_RUNS:
		var nm: NavigationMesh = Probe.make_nav_mesh()
		var geom: NavigationMeshSourceGeometryData3D = Probe.make_source_geometry(run + 100, 0)
		_gaps.clear()
		_collect = true
		_pending = 1
		var t0: int = Time.get_ticks_usec()
		var submit_ms: float = Probe.bake_async(nm, geom, _on_bake_done)
		while _pending > 0:
			await _idle()
		var wall_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
		_collect = false
		var stats: Dictionary = _block_stats()
		_single_block_ms.append(stats["worst"])
		_single_wall_ms.append(wall_ms)
		_single_submit_ms.append(submit_ms)
		print("  [bake x1  ] wall %6.2f ms | %4d frames | submit %.3f ms | slowest frame %.3f ms | block %.3f ms" % [
			wall_ms, stats["frames"], submit_ms, stats["raw"], stats["worst"],
		])

	# 4c. Sixteen bakes fired at once — the pathological case, all cores saturated.
	var meshes: Array[NavigationMesh] = []
	var geoms: Array[NavigationMeshSourceGeometryData3D] = []
	for i: int in BURST_CHUNKS:
		meshes.append(Probe.make_nav_mesh())
		geoms.append(Probe.make_source_geometry(i % 4, i / 4))
	_gaps.clear()
	_collect = true
	_pending = BURST_CHUNKS
	var burst_t0: int = Time.get_ticks_usec()
	for i: int in BURST_CHUNKS:
		NavigationServer3D.bake_from_source_geometry_data_async(meshes[i], geoms[i], _on_bake_done)
	var burst_submit_ms: float = float(Time.get_ticks_usec() - burst_t0) / 1000.0
	while _pending > 0:
		await _idle()
	var burst_wall_ms: float = float(Time.get_ticks_usec() - burst_t0) / 1000.0
	_collect = false
	var burst: Dictionary = _block_stats()
	_burst_block_ms = burst["worst"]
	print("  [bake x%d ] wall %6.2f ms | submit %.3f ms | slowest frame %.3f ms | block %.3f ms" % [
		BURST_CHUNKS, burst_wall_ms, burst_submit_ms, burst["raw"], burst["worst"],
	])

	# 4d. Handing a finished mesh to a LIVE map. This is the part people forget, and it is
	# where the cost actually is: the map rebuilds its polygon graph and re-derives every
	# inter-region edge connection.
	await _measure_attach(true)
	await _measure_attach(false)

	# 4f. F-347: which half of a streaming step is expensive.
	await _measure_retire()

	# 4e. The case that decides the verdict: a player walking into new terrain. One bake in
	# flight at a time, each chunk attached as it lands, oldest chunks retired.
	await _measure_streaming()


func _measure_attach(use_async_iterations: bool) -> void:
	var map: RID = Probe.make_map(Probe.DEFAULT_CELL_SIZE, 1.10, use_async_iterations)
	var live: Array[RID] = []
	var held: Array[NavigationMesh] = []
	for i: int in STREAM_LIVE:
		var nm: NavigationMesh = Probe.make_nav_mesh()
		Probe.bake_sync(nm, Probe.make_source_geometry(i % 3, i / 3))
		held.append(nm)

	# Bulk attach onto a cold map — what a joining player or a teleport actually does.
	_gaps.clear()
	_collect = true
	for i: int in STREAM_LIVE:
		live.append(Probe.add_region(map, held[i], Vector3(
			float(i % 3) * Probe.CHUNK_SIZE, 0.0, float(i / 3) * Probe.CHUNK_SIZE
		)))
	await _wait_for_map(map)
	_collect = false
	var cold: Dictionary = _block_stats()
	print("  [attach   ] %d regions at once onto a COLD map, async_iterations=%-5s | slowest frame %.3f ms | block %.3f ms" % [
		STREAM_LIVE, use_async_iterations, cold["raw"], cold["worst"],
	])

	var blocks: PackedFloat64Array = PackedFloat64Array()
	for run: int in ATTACH_RUNS:
		var nm: NavigationMesh = Probe.make_nav_mesh()
		Probe.bake_sync(nm, Probe.make_source_geometry(3, run))
		held.append(nm)
		_gaps.clear()
		_collect = true
		var region: RID = Probe.add_region(map, nm, Vector3(
			3.0 * Probe.CHUNK_SIZE, 0.0, float(run) * Probe.CHUNK_SIZE
		))
		await _wait_iterations(map, 2)
		_collect = false
		blocks.append(_block_stats()["worst"])
		live.append(region)
	blocks.sort()
	if use_async_iterations:
		_attach_block_ms = blocks.duplicate()
	print("  [attach   ] 1 region onto a live %d-region map, async_iterations=%-5s | block median %.3f | max %.3f ms" % [
		STREAM_LIVE, use_async_iterations, _pct(blocks, 0.5), blocks[blocks.size() - 1],
	])
	for r: RID in live:
		NavigationServer3D.free_rid(r)
	NavigationServer3D.free_rid(map)


## The realistic streaming episode: bake one chunk at a time, attach it when it lands,
## retire the oldest so only a 3x3 window stays live. The worst engine-side frame across
## the whole episode is what a player would feel as a stutter.
## F-347: attach and RETIREMENT, measured apart.
##
## `_measure_attach()` above only ever adds a region, and reports 0.009 ms median onto a live map.
## The streaming episode adds a region AND frees the oldest one, and reports tens of milliseconds.
## Freeing is the only structural difference between the two, so it is the first thing to isolate
## rather than the last — a benchmark that reports one blended number for a two-part operation
## cannot tell anyone which part to fix.
func _measure_retire() -> void:
	print("")
	print("--- 4f. attach vs retire, measured apart (F-347) ---")
	var retire_only: PackedFloat64Array = await _retire_cycle(false)
	var attach_and_retire: PackedFloat64Array = await _retire_cycle(true)
	retire_only.sort()
	attach_and_retire.sort()
	print("  [retire   ] free 1 region from a live %d-region map | median %.3f | max %.3f ms" % [
		STREAM_LIVE, _pct(retire_only, 0.5), retire_only[retire_only.size() - 1],
	])
	print("  [add+retire] attach 1 and free 1 in the same step  | median %.3f | max %.3f ms" % [
		_pct(attach_and_retire, 0.5), attach_and_retire[attach_and_retire.size() - 1],
	])

	# Which way of retiring is cheap. `NavBaker._retire()` ships the first one, so if another is
	# materially cheaper this table is the argument for changing it — and if none is, that is worth
	# knowing before anyone spends a session trying.
	print("")
	print("  retirement strategies, same map, same step count:")
	for strategy: String in ["free_rid", "unset_map", "empty_mesh", "disable"]:
		var blocks: PackedFloat64Array = await _retire_strategy(strategy)
		blocks.sort()
		print("    %-12s | median %7.3f | max %7.3f ms" % [
			strategy, _pct(blocks, 0.5), blocks[blocks.size() - 1],
		])


## One retirement strategy, measured over `ATTACH_RUNS` steps on a warm map.
##
## `free_rid` is what `world/chunk/nav_baker.gd._retire()` ships today. The other three are the
## alternatives that keep the RID alive so it can be reused, which is the shape a fix would take if
## freeing turns out to be the expensive part.
func _retire_strategy(strategy: String) -> PackedFloat64Array:
	var map: RID = Probe.make_map(Probe.DEFAULT_CELL_SIZE, 1.10)
	var live: Array[RID] = []
	var held: Array[NavigationMesh] = []
	var initial: int = STREAM_LIVE + ATTACH_RUNS + 1
	for i: int in initial:
		var nm: NavigationMesh = Probe.make_nav_mesh()
		Probe.bake_sync(nm, Probe.make_source_geometry(i % 4, i / 4))
		held.append(nm)
		live.append(Probe.add_region(map, nm, Vector3(
			float(i % 4) * Probe.CHUNK_SIZE, 0.0, float(i / 4) * Probe.CHUNK_SIZE
		)))
	await _wait_for_map(map)
	var empty := NavigationMesh.new()

	var blocks := PackedFloat64Array()
	var retired: Array[RID] = []
	for _run: int in ATTACH_RUNS:
		var victim: RID = live.pop_front()
		_gaps.clear()
		_collect = true
		match strategy:
			"free_rid":
				NavigationServer3D.free_rid(victim)
			"unset_map":
				NavigationServer3D.region_set_map(victim, RID())
				retired.append(victim)
			"empty_mesh":
				NavigationServer3D.region_set_navigation_mesh(victim, empty)
				retired.append(victim)
			"disable":
				NavigationServer3D.region_set_enabled(victim, false)
				retired.append(victim)
		await _wait_iterations(map, 2)
		_collect = false
		blocks.append(_block_stats()["worst"])

	for r: RID in live + retired:
		NavigationServer3D.free_rid(r)
	NavigationServer3D.free_rid(map)
	return blocks


## One warm map, then `ATTACH_RUNS` steps that either free a region, or attach one and free one.
## Returns the engine-side block for each step.
func _retire_cycle(also_attach: bool) -> PackedFloat64Array:
	var map: RID = Probe.make_map(Probe.DEFAULT_CELL_SIZE, 1.10)
	var live: Array[RID] = []
	var held: Array[NavigationMesh] = []
	# Enough regions to keep freeing one for every step without running the map dry.
	var initial: int = STREAM_LIVE + ATTACH_RUNS + 1
	for i: int in initial:
		var nm: NavigationMesh = Probe.make_nav_mesh()
		Probe.bake_sync(nm, Probe.make_source_geometry(i % 4, i / 4))
		held.append(nm)
		live.append(Probe.add_region(map, nm, Vector3(
			float(i % 4) * Probe.CHUNK_SIZE, 0.0, float(i / 4) * Probe.CHUNK_SIZE
		)))
	await _wait_for_map(map)

	var blocks := PackedFloat64Array()
	for run: int in ATTACH_RUNS:
		var fresh: NavigationMesh = null
		if also_attach:
			fresh = Probe.make_nav_mesh()
			Probe.bake_sync(fresh, Probe.make_source_geometry(3, run + 9))
			held.append(fresh)
		# Everything above is this script's own work and is deliberately outside the window.
		_gaps.clear()
		_collect = true
		if also_attach:
			live.append(Probe.add_region(map, fresh, Vector3(
				3.0 * Probe.CHUNK_SIZE, 0.0, float(run + 9) * Probe.CHUNK_SIZE
			)))
		NavigationServer3D.free_rid(live.pop_front())
		await _wait_iterations(map, 2)
		_collect = false
		blocks.append(_block_stats()["worst"])

	for r: RID in live:
		NavigationServer3D.free_rid(r)
	NavigationServer3D.free_rid(map)
	return blocks


func _measure_streaming() -> void:
	var map: RID = Probe.make_map(Probe.DEFAULT_CELL_SIZE, 1.10)
	var live: Array[RID] = []
	var held: Array[NavigationMesh] = []
	var warm: NavigationMesh = Probe.make_nav_mesh()
	Probe.bake_sync(warm, Probe.make_source_geometry(0, 0))
	held.append(warm)
	live.append(Probe.add_region(map, warm, Vector3.ZERO))
	await _wait_for_map(map)

	_gaps.clear()
	_collect = true
	var t0: int = Time.get_ticks_usec()
	for i: int in STREAM_CHUNKS:
		var cx: int = i % 6
		var cz: int = i / 6
		var nm: NavigationMesh = Probe.make_nav_mesh()
		var geom: NavigationMeshSourceGeometryData3D = Probe.make_source_geometry(cx, cz)
		held.append(nm)
		_pending = 1
		Probe.bake_async(nm, geom, _on_bake_done)
		while _pending > 0:
			await _idle()
		live.append(Probe.add_region(map, nm, Vector3(
			float(cx) * Probe.CHUNK_SIZE, 0.0, float(cz) * Probe.CHUNK_SIZE
		)))
		if live.size() > STREAM_LIVE:
			NavigationServer3D.free_rid(live.pop_front())
		await _wait_iterations(map, 2)
	var wall_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	_collect = false
	var stats: Dictionary = _block_stats()
	_stream_block_ms = stats["worst"]
	print("  [stream   ] %d chunks baked+attached+retired, %d live | %.0f ms wall over %d frames" % [
		STREAM_CHUNKS, STREAM_LIVE, wall_ms, stats["frames"],
	])
	print("  [stream   ] WORST ENGINE FRAME %.3f ms -> block %.3f ms  (wall is harness-paced:" % [
		stats["raw"], stats["worst"],
	])
	print("  [stream   ]  it waits 2 full map iterations per chunk, so it is not a throughput limit)")
	for r: RID in live:
		NavigationServer3D.free_rid(r)
	NavigationServer3D.free_rid(map)


## raw    — slowest engine-side frame in the window, as measured.
## worst  — that frame minus the idle baseline's own p99.9. The hitch attributable to nav.
## excess — total engine-side time above the median idle frame across the window. Catches a
##          cost spread thinly over many frames rather than concentrated in one.
func _block_stats() -> Dictionary:
	if _gaps.is_empty():
		return {"raw": 0.0, "worst": 0.0, "excess": 0.0, "frames": 0}
	var frames: int = _gaps.size()
	var total: float = 0.0
	var worst: float = 0.0
	for g: float in _gaps:
		total += g
		worst = maxf(worst, g)
	return {
		"raw": worst,
		"worst": maxf(0.0, worst - _baseline_ref),
		"excess": maxf(0.0, total - _baseline_p50 * float(frames)),
		"frames": frames,
	}


# --- 5. do adjacent chunks connect? --------------------------------------------------

func _bench_seams() -> void:
	print("")
	print("--- 5. seam connectivity: two adjacent 32 m chunks, path from A to B ---")
	print("  agent_radius erodes the navmesh inward from the geometry edge, so two chunks")
	print("  baked independently leave a hole 2*radius wide. 'gap' is that hole, measured")
	print("  from the baked vertices. It closes only if edge_connection_margin exceeds it.")
	print("")
	print("  %-38s %6s %6s %5s %6s  %s" % ["strategy", "gap m", "conns", "pts", "maxX", "verdict"])

	_control_ok = await _seam_control()
	# label, overlap, clip, radius, border, mesh_cell, map_cell, margin
	await _seam_case("radius 0.50, margin 0.25 (defaults)", 0.0, 0.0, 0.5, 0.0, 0.25, 0.25, 0.25)
	await _seam_case("radius 0.50, margin 1.10", 0.0, 0.0, 0.5, 0.0, 0.25, 0.25, 1.10)
	await _seam_case("radius 0.50, margin 2.00", 0.0, 0.0, 0.5, 0.0, 0.25, 0.25, 2.00)
	await _seam_case("radius 0.25, margin 0.60", 0.0, 0.0, 0.25, 0.0, 0.25, 0.25, 0.60)
	await _seam_case("radius 0.00, margin 0.25", 0.0, 0.0, 0.0, 0.0, 0.25, 0.25, 0.25)
	await _seam_case("overlap 4 m + filter_baking_aabb", SEAM_OVERLAP, 32.0, 0.5, 0.0, 0.25, 0.25, 0.25)
	await _seam_case("overlap 4 m, no clip (regions overlap)", SEAM_OVERLAP, 0.0, 0.5, 0.0, 0.25, 0.25, 0.25)
	await _seam_case("radius 0.50, m 1.10, border_size 4", 0.0, 0.0, 0.5, 4.0, 0.25, 0.25, 1.10)
	await _seam_case("radius 0.00, mesh cell 0.25 / map 0.50", 0.0, 0.0, 0.0, 0.0, 0.25, 0.50, 0.25)
	await _seam_negative()


## Negative control: two chunks a full 32 m apart, with the wide margin that closes a real
## seam. If this reports CONNECTED then edge_connection_margin is inventing links across
## terrain that is genuinely separated, and the margin fix is not safe.
func _seam_negative() -> void:
	var nm_a: NavigationMesh = Probe.make_nav_mesh()
	var nm_b: NavigationMesh = Probe.make_nav_mesh()
	Probe.bake_sync(nm_a, Probe.make_source_geometry(0, 0))
	Probe.bake_sync(nm_b, Probe.make_source_geometry(2, 0))
	var map: RID = Probe.make_map(0.25, 1.10)
	var region_a: RID = Probe.add_region(map, nm_a, Vector3.ZERO)
	var region_b: RID = Probe.add_region(map, nm_b, Vector3(2.0 * Probe.CHUNK_SIZE, 0.0, 0.0))
	await _wait_for_map(map)
	var res: Dictionary = _query_seam(map, 72.0)
	print("  %-38s %6.2f %6d %5d %6.1f  %s" % [
		"NEGATIVE: chunks 32 m apart, m 1.10", 32.0,
		NavigationServer3D.region_get_connections_count(region_a),
		res["points"], res["max_x"],
		"CONNECTED (BAD)" if res["reached"] else "SPLIT (correct)",
	])
	NavigationServer3D.free_rid(region_a)
	NavigationServer3D.free_rid(region_b)
	NavigationServer3D.free_rid(map)


## Control: both chunks baked into ONE navmesh and one region. If this cannot path across
## x = 32 the harness is broken and every SPLIT below is meaningless.
func _seam_control() -> bool:
	var nm: NavigationMesh = Probe.make_nav_mesh()
	Probe.bake_sync(nm, Probe.make_region_source_geometry(2))
	var map: RID = Probe.make_map()
	var region: RID = Probe.add_region(map, nm, Vector3.ZERO)
	await _wait_for_map(map)
	var res: Dictionary = _query_seam(map)
	print("  %-38s %6s %6d %5d %6.1f  %s" % [
		"CONTROL: one region over both chunks", "-",
		NavigationServer3D.region_get_connections_count(region),
		res["points"], res["max_x"], "CONNECTED" if res["reached"] else "SPLIT",
	])
	NavigationServer3D.free_rid(region)
	NavigationServer3D.free_rid(map)
	return res["reached"]


func _seam_case(
	label: String, overlap: float, clip_span: float, radius: float, border: float,
	mesh_cell: float, map_cell: float, margin: float
) -> bool:
	var nm_a: NavigationMesh = Probe.make_nav_mesh(mesh_cell, radius, clip_span, border)
	var nm_b: NavigationMesh = Probe.make_nav_mesh(mesh_cell, radius, clip_span, border)
	Probe.bake_sync(nm_a, Probe.make_source_geometry(0, 0, overlap))
	Probe.bake_sync(nm_b, Probe.make_source_geometry(1, 0, overlap))

	var ext_a: Vector2 = Probe.extent_x(nm_a)
	var ext_b: Vector2 = Probe.extent_x(nm_b)
	# Chunk B's region sits at x = +32, so its world-space left edge is 32 + ext_b.x.
	var gap: float = (Probe.CHUNK_SIZE + ext_b.x) - ext_a.y

	var map: RID = Probe.make_map(map_cell, margin)
	var region_a: RID = Probe.add_region(map, nm_a, Vector3.ZERO)
	var region_b: RID = Probe.add_region(map, nm_b, Vector3(Probe.CHUNK_SIZE, 0.0, 0.0))
	await _wait_for_map(map)

	var conns: int = NavigationServer3D.region_get_connections_count(region_a)
	var res: Dictionary = _query_seam(map)
	print("  %-38s %6.2f %6d %5d %6.1f  %s" % [
		label, gap, conns, res["points"], res["max_x"],
		"CONNECTED" if res["reached"] else "SPLIT",
	])

	NavigationServer3D.free_rid(region_a)
	NavigationServer3D.free_rid(region_b)
	NavigationServer3D.free_rid(map)

	if res["reached"] and not _seam_ok:
		_seam_ok = true
		_seam_strategy = label
	return res["reached"]


## Path from the middle of chunk A to the middle of chunk B. map_get_path silently returns a
## path to the closest REACHABLE point, so "we got a path" proves nothing — only arriving
## within a metre of the requested destination does.
func _query_seam(map: RID, dest_x: float = 56.0) -> Dictionary:
	var raw_start: Vector3 = Vector3(8.0, Probe.height_at(8.0, 16.0), 16.0)
	var raw_dest: Vector3 = Vector3(dest_x, Probe.height_at(dest_x, 16.0), 16.0)
	var start: Vector3 = NavigationServer3D.map_get_closest_point(map, raw_start)
	var dest: Vector3 = NavigationServer3D.map_get_closest_point(map, raw_dest)
	var path: PackedVector3Array = NavigationServer3D.map_get_path(map, start, dest, true)
	var max_x: float = -INF
	for p: Vector3 in path:
		max_x = maxf(max_x, p.x)
	return {
		"points": path.size(),
		"max_x": max_x if path.size() > 0 else NAN,
		"reached": (
			path.size() >= 2
			and dest.x > Probe.CHUNK_SIZE
			and path[path.size() - 1].distance_to(dest) < 1.0
		),
	}


## Wait until a fresh map answers a real query. Checking map_get_iteration_id() first avoids
## the "query before first synchronization" error; checking an actual query afterwards is
## necessary because iteration 1 can still have an empty polygon graph.
func _wait_for_map(map: RID, probe: Vector3 = Vector3(8.0, 0.0, 16.0)) -> int:
	NavigationServer3D.map_force_update(map)
	for i: int in 20000:
		await _idle()
		if NavigationServer3D.map_get_iteration_id(map) > 0:
			if NavigationServer3D.map_get_closest_point(map, probe) != Vector3.ZERO:
				return i + 1
	printerr("[bench] map never became queryable")
	return -1


## Wait for the map to complete `count` more sync iterations, so a measurement window is
## guaranteed to contain the work caused by whatever we just changed.
func _wait_iterations(map: RID, count: int) -> int:
	var start_id: int = NavigationServer3D.map_get_iteration_id(map)
	for i: int in 20000:
		await _idle()
		if NavigationServer3D.map_get_iteration_id(map) >= start_id + count:
			return i + 1
	printerr("[bench] map stopped iterating")
	return -1


# --- 6. verdict ----------------------------------------------------------------------

func _report() -> void:
	_single_block_ms.sort()
	_single_wall_ms.sort()
	_single_submit_ms.sort()
	var worst_single: float = _single_block_ms[_single_block_ms.size() - 1]
	var attach_median: float = _pct(_attach_block_ms, 0.5)

	print("")
	print("--- summary ---")
	print("  blocking bake, 32 m chunk, cell 0.25 : %7.2f ms  (%.0f%% of a frame)" % [
		_sync_median_ms, 100.0 * _sync_median_ms / FRAME_BUDGET_MS,
	])
	print("  async bake wall time, 1 chunk        : %7.2f ms median" % _pct(_single_wall_ms, 0.5))
	print("  async submit cost (main thread)      : %7.3f ms median" % _pct(_single_submit_ms, 0.5))
	print("")
	print("  BLOCK: single async bake             : %7.3f ms worst of %d" % [worst_single, ASYNC_RUNS])
	print("  BLOCK: %d bakes fired at once        : %7.3f ms" % [BURST_CHUNKS, _burst_block_ms])
	print("  BLOCK: attaching 1 region to a map   : %7.3f ms median" % attach_median)
	print("  BLOCK: full streaming episode        : %7.3f ms worst  <-- the number" % _stream_block_ms)
	print("")
	print("  seam control (single region)         : %s" % [
		"path crosses x=32" if _control_ok else "BROKEN HARNESS",
	])
	print("  seams connect across chunk regions   : %s%s" % [
		"YES" if _seam_ok else "NO", " via %s" % _seam_strategy if _seam_ok else "",
	])
	print("")

	# F-347: composed from two INDEPENDENT axes, because it used to be a fall-through ladder that
	# conflated them. With a 39 ms block and seams connecting, every branch failed its test and the
	# `else` printed "RED — hitches at runtime and seams do not join" — the second half flatly false,
	# and contradicting the table two lines above it that reads "seams connect across chunk regions:
	# YES". A verdict that argues with its own evidence gets discounted, and this verdict is the
	# evidence D-016 rests on.
	var verdict: String = ""
	if not _control_ok:
		verdict = "INVALID — the seam control failed; do not trust these numbers"
		_verdict_failed = true
	else:
		var block_grade: String = _grade_block()
		var seam_grade: String = "GREEN" if _seam_ok else "RED"
		var grade: String = _worse_of(block_grade, seam_grade)
		var block_clause: String = "block %.3f ms" % _stream_block_ms
		if block_grade == "GREEN":
			block_clause += " (under the %.0f ms budget)" % HITCH_MS
		elif block_grade == "AMBER":
			block_clause += " (over the %.0f ms budget, inside a %.1f ms frame)" % [
				HITCH_MS, FRAME_BUDGET_MS]
		else:
			block_clause += " (over a whole %.1f ms frame)" % FRAME_BUDGET_MS
		var seam_clause: String = ("seams connect via %s" % _seam_strategy) if _seam_ok \
			else "seams do not join"
		verdict = "%s — %s; %s" % [grade, block_clause, seam_clause]
		_verdict_failed = grade != "GREEN"
	print("VERDICT: %s" % verdict)
	print("thresholds: GREEN block <%.0f ms AND seams connect | RED block >%.1f ms OR seams cannot join" % [
		HITCH_MS, FRAME_BUDGET_MS,
	])
	# F-347: a benchmark that reports a missed budget and exits 0 is a benchmark the battery treats
	# as passing. D-016 declares runtime navigation GREEN on this instrument's own evidence, so the
	# instrument has to be able to withdraw it.
	if _verdict_failed:
		print("BENCH_NAVBAKE_BUDGET_MISSED — exiting nonzero so a red verdict cannot read as a pass")


## Where the streaming block sits against the two thresholds. Separate from the seam axis on purpose.
func _grade_block() -> String:
	if _stream_block_ms < HITCH_MS:
		return "GREEN"
	if _stream_block_ms < FRAME_BUDGET_MS:
		return "AMBER"
	return "RED"


## The worse of two grades. The overall verdict can never be better than either axis, and each axis
## still gets to state what IT found in the clause above.
static func _worse_of(a: String, b: String) -> String:
	var rank: Dictionary = {"GREEN": 0, "AMBER": 1, "RED": 2}
	return a if int(rank[a]) >= int(rank[b]) else b


# --- stats ---------------------------------------------------------------------------

static func _pct(sorted_vals: PackedFloat64Array, p: float) -> float:
	if sorted_vals.is_empty():
		return 0.0
	var i: int = clampi(int(floor(p * float(sorted_vals.size() - 1))), 0, sorted_vals.size() - 1)
	return sorted_vals[i]


static func _mean(vals: PackedFloat64Array) -> float:
	if vals.is_empty():
		return 0.0
	var total: float = 0.0
	for v: float in vals:
		total += v
	return total / float(vals.size())
