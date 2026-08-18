extends SceneTree

## SPIKE R2 benchmark — throwaway. Run headless:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/bench_chunks.gd
##
## Answers: can Godot 4.7 GDScript build chunked terrain meshes fast enough to stream an
## island at 60 fps? Prints numbers only; the verdict goes in docs/DECISIONS.md (D-015).

# Preloaded rather than referenced by class_name: a --script run does not depend on the
# editor having refreshed the global class cache.
const Mesher = preload("res://world/chunk/chunk_mesher.gd")

const CHUNK_COUNT: int = 100
const WARMUP_CHUNKS: int = 8
const BENCH_SEED: int = 20260815
const GRID_SIDE: int = 10
const FRAME_BUDGET_MS: float = 16.667

var _threaded_results: Array = []


func _initialize() -> void:
	print("=== MIRE Spike R2 — chunked terrain meshing ===")
	print("Godot %s | %s | %d logical cores" % [
		Engine.get_version_info()["string"],
		OS.get_name(),
		OS.get_processor_count(),
	])
	print("Chunk: %d m x %d m, 1 m spacing -> %d verts, %d tris, %d indices" % [
		Mesher.CHUNK_SIZE, Mesher.CHUNK_SIZE,
		Mesher.VERT_COUNT, Mesher.TRI_COUNT, Mesher.INDEX_COUNT,
	])
	print("")

	_check_determinism()
	_warmup()

	var direct_ms: float = _bench_single(false)
	var st_ms: float = _bench_single(true)
	var threaded_ms: float = _bench_threaded()
	_bench_memory()

	print("")
	print("--- summary (%d chunks) ---" % CHUNK_COUNT)
	print("ArrayMesh direct, single-threaded : %.3f ms/chunk" % direct_ms)
	print("SurfaceTool,      single-threaded : %.3f ms/chunk" % st_ms)
	print("ArrayMesh direct, WorkerThreadPool: %.3f ms/chunk amortized (%d cores)" % [
		threaded_ms, OS.get_processor_count(),
	])
	print("Chunks per 16.667 ms frame, single-threaded: %.1f" % (FRAME_BUDGET_MS / direct_ms))
	print("Chunks per 16.667 ms frame, threaded       : %.1f" % (FRAME_BUDGET_MS / threaded_ms))
	print("")
	print("Verdict thresholds: GREEN <8 ms  AMBER 8-25 ms  RED >25 ms threaded")
	quit()


## Determinism gate. If this fails the numbers below are irrelevant — clients would
## generate different islands from the same seed.
func _check_determinism() -> void:
	var a: ArrayMesh = Mesher.build_mesh(3, -7, BENCH_SEED)
	var b: ArrayMesh = Mesher.build_mesh(3, -7, BENCH_SEED)
	var c: ArrayMesh = Mesher.build_mesh(3, -7, BENCH_SEED + 1)
	var va: PackedVector3Array = a.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var vb: PackedVector3Array = b.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var vc: PackedVector3Array = c.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	print("determinism: same seed identical = %s | different seed differs = %s" % [
		va == vb, va != vc,
	])


func _warmup() -> void:
	for i: int in WARMUP_CHUNKS:
		var _m: ArrayMesh = Mesher.build_mesh(i, 0, BENCH_SEED)


## Returns mean ms per chunk. Also prints min/max, which is what a streaming hitch looks like.
func _bench_single(use_surface_tool: bool) -> float:
	var label: String = "SurfaceTool" if use_surface_tool else "ArrayMesh direct"
	var worst: float = 0.0
	var best: float = 1.0e9
	var start: int = Time.get_ticks_usec()
	for i: int in CHUNK_COUNT:
		var t0: int = Time.get_ticks_usec()
		var _m: ArrayMesh = (
			Mesher.build_mesh_surface_tool(i % GRID_SIDE, i / GRID_SIDE, BENCH_SEED)
			if use_surface_tool
			else Mesher.build_mesh(i % GRID_SIDE, i / GRID_SIDE, BENCH_SEED)
		)
		var dt: float = float(Time.get_ticks_usec() - t0) / 1000.0
		worst = maxf(worst, dt)
		best = minf(best, dt)
	var total_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	var mean: float = total_ms / float(CHUNK_COUNT)
	print("[single-threaded %s] mean %.3f ms | min %.3f | max %.3f | total %.1f ms" % [
		label, mean, best, worst, total_ms,
	])
	return mean


func _build_one_threaded(index: int) -> void:
	_threaded_results[index] = Mesher.build_mesh(index % GRID_SIDE, index / GRID_SIDE, BENCH_SEED)


## Amortized ms per chunk across all cores: wall time for CHUNK_COUNT chunks / CHUNK_COUNT.
## This is the number that matters for streaming — it is how much work the pool retires per
## unit of wall clock, not how long one chunk takes on one worker.
func _bench_threaded() -> float:
	_threaded_results.clear()
	_threaded_results.resize(CHUNK_COUNT)
	var start: int = Time.get_ticks_usec()
	var task_id: int = WorkerThreadPool.add_group_task(
		_build_one_threaded, CHUNK_COUNT, -1, true, "bench_chunks"
	)
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	var total_ms: float = float(Time.get_ticks_usec() - start) / 1000.0

	var built: int = 0
	for m: Variant in _threaded_results:
		if m != null:
			built += 1
	_threaded_results.clear()

	var mean: float = total_ms / float(CHUNK_COUNT)
	print("[WorkerThreadPool] %d/%d chunks built | wall %.1f ms | %.3f ms/chunk amortized" % [
		built, CHUNK_COUNT, total_ms, mean,
	])
	return mean


## Static memory delta for CHUNK_COUNT chunks held live at once. Note this counts the
## GDScript/Object side; ArrayMesh vertex data also lives in the RenderingServer, so the
## theoretical figure below is the honest floor for GPU-side cost.
func _bench_memory() -> void:
	var held: Array[ArrayMesh] = []
	var before: int = OS.get_static_memory_usage()
	for i: int in CHUNK_COUNT:
		held.append(Mesher.build_mesh(i % GRID_SIDE, i / GRID_SIDE, BENCH_SEED))
	var after: int = OS.get_static_memory_usage()
	var delta: int = after - before

	# 3 floats position + 3 normal + 2 uv = 32 B/vert, plus 4 B/index. The consts above are the
	# terrain grid alone, so F-128's skirt is added explicitly rather than folded into them —
	# `VERT_COUNT`/`INDEX_COUNT` still mean exactly what D-015 recorded them meaning.
	var verts_per_chunk: int = Mesher.VERT_COUNT + Mesher.skirt_vert_count(0)
	var indices_per_chunk: int = Mesher.INDEX_COUNT + Mesher.skirt_tri_count(0) * 3
	var theoretical: int = CHUNK_COUNT * (verts_per_chunk * 32 + indices_per_chunk * 4)
	print("[memory] %d chunks live: static delta %.2f MB (%.1f KB/chunk)" % [
		CHUNK_COUNT, float(delta) / 1048576.0, float(delta) / float(CHUNK_COUNT) / 1024.0,
	])
	print("[memory] raw vertex+index data floor: %.2f MB (%.1f KB/chunk)" % [
		float(theoretical) / 1048576.0, float(theoretical) / float(CHUNK_COUNT) / 1024.0,
	])
	held.clear()
