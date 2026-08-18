extends SceneTree

## SPIKE R2b (task 4.0a) — throwaway. Answers what R2 (`tools/bench_chunks.gd`, D-015) could not:
## R2 ran under the headless dummy renderer, which accepts CPU-side mesh/shape data without doing
## any real driver work, so it measured GDScript mesh-build cost only. This script re-uses the same
## R2 chunk (32 m, 1 m spacing, 2048 tris — see the note below on "1.5 m voxel scale") and adds the
## two costs D-015 flagged as unmeasured: `ConcavePolygonShape3D` cooking (PhysicsServer/Jolt) and
## GPU mesh upload + material bind (RenderingServer). MUST run with a real renderer:
##
##   .agent/bin/agent godot --windowed --script tools/bench_chunk_gpu.gd
##
## Under --headless this prints an error and quits — the whole point of F-005 is that a dummy
## renderer answers the collision/upload questions with a false GREEN.
##
## Note on "1.5 m voxel scale": the 4.0a work order asks to measure "at the 1.5 m voxel scale R2
## used." No 1.5 m figure exists anywhere in R2's spike, D-015, or `chunk_mesher.gd` — R2 is a
## heightmap mesher (32 m chunk, 1 m vertex spacing), not a voxel system, and nothing in this repo
## has ever used a 1.5 m scale. Decided (per AGENTS.md "ambiguous spec, decide and record"): measure
## at R2's actual, on-record parameters instead of inventing a new chunk size the rest of M4 was
## never budgeted against. Recorded as DECISIONS.md D-072.

const Mesher = preload("res://world/chunk/chunk_mesher.gd")

const CHUNK_COUNT: int = 60
const WARMUP_CHUNKS: int = 4
const BENCH_SEED: int = 20260818
const GRID_SIDE: int = 8
## Spacing between chunk origins in the scene, in chunk-size units — >1 so neighbouring 32 m
## chunks don't overlap once placed (they'd share an edge at 1.0, which is fine physically, but
## a hair of gap makes the render/collision debug draw legible if anyone opens this in the editor).
const CHUNK_SPACING: float = 1.0

## The streaming budget this spike exists to publish (4.3's design input, ARCHITECTURE §6 R2/R3
## pattern: a slice of the 16.667 ms frame, not the whole frame — nav baking got 2 ms, this asks 4).
const FRAME_BUDGET_MS: float = 4.0
const FULL_FRAME_MS: float = 16.667


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("bench_chunk_gpu needs a real renderer — run it with --windowed (F-005)")
		quit(1)
		return

	print("=== MIRE Spike R2b (4.0a) — collision cook + GPU upload + material bind per chunk ===")
	print("Godot %s | %s | renderer=%s | %d logical cores" % [
		Engine.get_version_info()["string"],
		OS.get_name(),
		RenderingServer.get_video_adapter_name(),
		OS.get_processor_count(),
	])
	print("Chunk: %d m x %d m, 1 m spacing -> %d verts, %d tris (R2's own parameters — see header note)" % [
		Mesher.CHUNK_SIZE, Mesher.CHUNK_SIZE, Mesher.VERT_COUNT, Mesher.TRI_COUNT,
	])
	print("")

	var root_node := Node3D.new()
	root.add_child(root_node)
	var camera := Camera3D.new()
	camera.far = 4000.0
	root_node.add_child(camera)
	var half_extent: float = float(GRID_SIDE) * float(Mesher.CHUNK_SIZE) * CHUNK_SPACING * 0.5
	camera.global_position = Vector3(half_extent, half_extent * 1.5, half_extent * 2.5)
	camera.look_at(Vector3(half_extent, 0.0, half_extent), Vector3.UP)
	camera.make_current()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -30.0, 0.0)
	root_node.add_child(sun)

	# One shared material, the pattern this codebase already uses for anything instanced many
	# times (F-097/D-060's "sway materials applied to the mesh resource, once per asset" — here
	# it's simpler still, one terrain material for every chunk).
	var shared_material := StandardMaterial3D.new()
	shared_material.albedo_color = Color(0.35, 0.45, 0.3)

	# Warm up the mesher, the physics server, and shader/pipeline compilation before timing.
	# An untimed warmup chunk goes through every step once so the FIRST timed chunk isn't paying
	# for one-time costs (first ConcavePolygonShape3D ever created, first material ever bound).
	for i: int in WARMUP_CHUNKS:
		var wmesh: ArrayMesh = Mesher.build_mesh(-1 - i, -1, BENCH_SEED)
		var wshape := ConcavePolygonShape3D.new()
		wshape.set_faces(Mesher.collision_faces(wmesh, 0))
		var wmi := MeshInstance3D.new()
		wmi.mesh = wmesh
		wmi.material_override = shared_material
		wmi.visible = false
		root_node.add_child(wmi)
	await process_frame
	await RenderingServer.frame_post_draw

	var collision_ms: PackedFloat32Array = PackedFloat32Array()
	var upload_ms: PackedFloat32Array = PackedFloat32Array()
	var material_ms: PackedFloat32Array = PackedFloat32Array()
	collision_ms.resize(CHUNK_COUNT)
	upload_ms.resize(CHUNK_COUNT)
	material_ms.resize(CHUNK_COUNT)

	var placed: Array[MeshInstance3D] = []
	var t_all_start: int = Time.get_ticks_usec()

	for i: int in CHUNK_COUNT:
		var cx: int = i % GRID_SIDE
		var cz: int = i / GRID_SIDE
		# Mesh build itself is R2's own number (D-015, 0.330 ms/chunk single-threaded) — not
		# re-timed here, only used as the input every downstream step needs.
		var mesh: ArrayMesh = Mesher.build_mesh(cx, cz, BENCH_SEED)

		# 1. Collision cook — ConcavePolygonShape3D.set_faces() hands the trimesh to the physics
		# server (Jolt), which builds its acceleration structure synchronously on this call.
		var t0: int = Time.get_ticks_usec()
		var shape := ConcavePolygonShape3D.new()
		# Terrain faces only, matching what ChunkStreamer actually cooks — the mesh also
		# carries F-128's skirt, which is deliberately not collidable (D-084).
		shape.set_faces(Mesher.collision_faces(mesh, 0))
		collision_ms[i] = float(Time.get_ticks_usec() - t0) / 1000.0

		# 2. Mesh upload — assigning the mesh and adding the instance to a live tree is what
		# actually pushes vertex/index buffers to the RenderingServer. Under the headless dummy
		# driver this is nearly free; under a real driver it is real GPU/staging-buffer work,
		# which is the entire cost R2 excluded (F-005).
		t0 = Time.get_ticks_usec()
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = Vector3(
			float(cx) * float(Mesher.CHUNK_SIZE) * CHUNK_SPACING,
			0.0,
			float(cz) * float(Mesher.CHUNK_SIZE) * CHUNK_SPACING,
		)
		root_node.add_child(mi)
		upload_ms[i] = float(Time.get_ticks_usec() - t0) / 1000.0

		# 3. Material bind
		t0 = Time.get_ticks_usec()
		mi.material_override = shared_material
		material_ms[i] = float(Time.get_ticks_usec() - t0) / 1000.0

		var body := StaticBody3D.new()
		# Spike fixture, not the shipped terrain body — a real chunk streamer's ground body must
		# set collision_layer = PlacementValidator.TERRAIN_LAYER (D-061); left at the layer-1
		# default here since nothing in this throwaway scene queries layers.
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		mi.add_child(body)
		placed.append(mi)

	var issue_total_ms: float = float(Time.get_ticks_usec() - t_all_start) / 1000.0

	# 4. First-frame GPU sync — the three steps above measure CPU-side call cost (issuing
	# RenderingServer/PhysicsServer commands). Real driver work (shader/pipeline compilation on
	# first draw, any deferred buffer upload) can still land on a later frame. Measure the wall
	# clock to render everything placed above for the first time, amortized per chunk, so that
	# cost isn't silently missing from the budget.
	var t_sync_start: int = Time.get_ticks_usec()
	await process_frame
	await RenderingServer.frame_post_draw
	var first_frame_total_ms: float = float(Time.get_ticks_usec() - t_sync_start) / 1000.0
	var first_frame_per_chunk_ms: float = first_frame_total_ms / float(CHUNK_COUNT)

	var collision_mean: float = _mean(collision_ms)
	var upload_mean: float = _mean(upload_ms)
	var material_mean: float = _mean(material_ms)
	var steady_state_ms: float = collision_mean + upload_mean + material_mean

	print("--- per-chunk main-thread cost (%d chunks, mean | min | max), ms ---" % CHUNK_COUNT)
	_print_stat("collision cook  (ConcavePolygonShape3D)", collision_ms)
	_print_stat("mesh upload     (MeshInstance3D + add_child)", upload_ms)
	_print_stat("material bind   (material_override=)", material_ms)
	print("")
	print("issue phase total: %.2f ms for %d chunks (%.3f ms/chunk)" % [
		issue_total_ms, CHUNK_COUNT, issue_total_ms / float(CHUNK_COUNT),
	])
	print("first-frame GPU sync (shader compile + any deferred upload), amortized: %.3f ms/chunk (%.2f ms total)" % [
		first_frame_per_chunk_ms, first_frame_total_ms,
	])
	print("")
	print("steady-state main-thread cost per streamed-in chunk: %.3f ms (cook %.3f + upload %.3f + material %.3f)" % [
		steady_state_ms, collision_mean, upload_mean, material_mean,
	])
	print("PER-FRAME CHUNK BUDGET: %.1f chunks fit in a %.1f ms streaming slice (%.1f in a full %.3f ms frame)" % [
		FRAME_BUDGET_MS / steady_state_ms, FRAME_BUDGET_MS,
		FULL_FRAME_MS / steady_state_ms, FULL_FRAME_MS,
	])
	print("")
	print("BENCH_CHUNK_GPU_DONE collision_ms=%.4f upload_ms=%.4f material_ms=%.4f steady_ms=%.4f first_frame_ms=%.4f chunks_per_4ms=%.2f" % [
		collision_mean, upload_mean, material_mean, steady_state_ms, first_frame_per_chunk_ms,
		FRAME_BUDGET_MS / steady_state_ms,
	])
	quit(0)


func _mean(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for v: float in values:
		total += v
	return total / float(values.size())


func _print_stat(label: String, values: PackedFloat32Array) -> void:
	var worst: float = 0.0
	var best: float = 1.0e9
	for v: float in values:
		worst = maxf(worst, v)
		best = minf(best, v)
	print("%-46s mean %.4f | min %.4f | max %.4f" % [label, _mean(values), best, worst])
