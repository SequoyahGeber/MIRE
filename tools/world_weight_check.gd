extends SceneTree

## F-606 — what does a settled procedural island actually WEIGH, and did today make it heavier?
##
##   .agent/bin/agent godot --script tools/world_weight_check.gd
##   .agent/bin/agent baseline --rev <before> --script tools/world_weight_check.gd
##
## Sequoyah is about to play a co-op session on an **M1 MacBook Air** — fanless, integrated GPU at
## roughly a third of this development machine's, and unified memory where VRAM competes with
## everything else he has open. Several agents made the world busier today (ambient enemies 4 -> 18,
## nests 5 -> 12, +307 scatter collision shapes, hazard fields, fauna) and nobody measured it.
##
## ## What this can and cannot answer, stated up front because it decides what the numbers mean
##
## It measures STRUCTURE: nodes, meshes, MultiMesh instances, collision shapes, physics bodies, and
## mesh residency in vertices. All of those are scene-tree and resource facts that survive
## `--headless` exactly, and all of them are what a population change actually moves.
##
## It does NOT measure frame time, and must not be read as if it did. Under `--headless` Godot runs
## the DUMMY renderer: `RenderingServer` draw-call and VRAM counters read zero because there is no
## renderer to report them. Those are printed when they are non-zero and explicitly called absent
## when they are not, rather than being quietly reported as 0 — a zero that means "not measured"
## looks exactly like a zero that means "free".
##
## Frame rate on the target machine needs HIS display, the foreground, and a run long enough to
## thermally throttle a fanless laptop — `perf_probe` samples ~40 s and would never see it. That is a
## hand-off to be asked for, not attempted. A windowed run here measures a backgrounded window and is
## worthless (F-457).
##
## ## Why vertices rather than megabytes for residency
##
## `RENDERING_INFO_VIDEO_MEM_USED` is a renderer figure and reads zero headless. Vertex and surface
## counts come off the `Mesh` resources themselves, so they survive — and on unified memory the thing
## that competes for his 8 GB is the resident geometry, which this counts directly.

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
const PerfFormat := preload("res://tools/perf_format.gd")

const WORLD_SEED: int = 20260822
## Frames given to streaming, placement jobs and the deferred service passes before counting. A
## count taken mid-stream measures how far the world got, not how heavy it is.
const SETTLE_FRAMES: int = 90


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var game_state: Node = root.get_node_or_null(^"GameState")
	if game_state != null:
		game_state.call(&"set_replicated_seed", WORLD_SEED)

	var world: Node3D = ProceduralWorldScript.new()
	world.name = "ProceduralWorld"
	root.add_child(world)
	current_scene = world
	for _frame: int in SETTLE_FRAMES:
		await process_frame
		await physics_frame

	var tally: Dictionary = _weigh(world)
	_report(tally)
	# One machine-readable line, keys stable, for a baseline diff to parse. Deliberately NOT
	# converted to FPS/percentages (F-592): this line is for tooling, and the human-facing report
	# above it is where the units rule applies.
	print("\nWORLD_WEIGHT seed=%d nodes=%d meshes=%d multimeshes=%d mm_instances=%d shapes=%d bodies=%d vertices=%d surfaces=%d submissions=%d enemies=%d drops=%d" % [
		WORLD_SEED, tally["nodes"], tally["meshes"], tally["multimeshes"], tally["mm_instances"],
		tally["shapes"], tally["bodies"], tally["vertices"], tally["surfaces"],
		tally["submissions"], tally["enemies"], tally["drops"]])
	print("WORLD_WEIGHT_CHECK failures=0")
	quit(0)


func _weigh(world: Node) -> Dictionary:
	var nodes: int = 0
	var meshes: int = 0
	var multimeshes: int = 0
	var mm_instances: int = 0
	var shapes: int = 0
	var bodies: int = 0
	var surfaces: int = 0
	var vertices: int = 0
	# Counted per unique Mesh RESOURCE, not per instance. Two hundred rocks sharing one mesh cost
	# one mesh's residency and two hundred submissions — conflating those is how a scatter field
	# looks catastrophic on paper and is fine in practice.
	var seen_meshes: Dictionary = {}

	for node: Node in _walk(world):
		nodes += 1
		if node is CollisionShape3D:
			shapes += 1
		if node is PhysicsBody3D:
			bodies += 1
		var mesh_instance := node as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			meshes += 1
			_account(mesh_instance.mesh, seen_meshes)
		var multi := node as MultiMeshInstance3D
		if multi != null and multi.multimesh != null:
			multimeshes += 1
			mm_instances += multi.multimesh.instance_count
			if multi.multimesh.mesh != null:
				_account(multi.multimesh.mesh, seen_meshes)

	for key: Variant in seen_meshes:
		var entry: Dictionary = seen_meshes[key]
		surfaces += int(entry["surfaces"])
		vertices += int(entry["vertices"])

	# A PROXY for draw calls, and named as one rather than dressed up as a measurement. A
	# MeshInstance3D submits once per surface; a MultiMesh submits once per surface for the whole
	# batch however many instances it holds — which is the entire reason the scatter field batches.
	# The real number depends on culling, shadow passes and material sorting, none of which exist
	# headless. It is the right proxy for "did today's work move submissions" because it moves for
	# exactly the reasons real draw calls move.
	var submissions: int = meshes + multimeshes

	var renderer_draws: int = int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	var renderer_vram: float = float(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0

	return {
		"nodes": nodes, "meshes": meshes, "multimeshes": multimeshes,
		"mm_instances": mm_instances, "shapes": shapes, "bodies": bodies,
		"surfaces": surfaces, "vertices": vertices, "submissions": submissions,
		"unique_meshes": seen_meshes.size(),
		"enemies": get_nodes_in_group(&"enemy").size(),
		"drops": get_nodes_in_group(&"item_drop").size(),
		"renderer_draws": renderer_draws, "renderer_vram_mb": renderer_vram,
	}


func _account(mesh: Mesh, seen: Dictionary) -> void:
	var key: int = mesh.get_instance_id()
	if seen.has(key):
		return
	var surface_count: int = mesh.get_surface_count()
	var vertex_count: int = 0
	for surface: int in surface_count:
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
			vertex_count += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	seen[key] = {"surfaces": surface_count, "vertices": vertex_count}


func _report(tally: Dictionary) -> void:
	print("\n== what a settled procedural island weighs (seed %d) ==" % WORLD_SEED)
	print("  submissions (draw-call proxy)  %8d   %d mesh instances + %d MultiMeshes"
		% [tally["submissions"], tally["meshes"], tally["multimeshes"]])
	print("  MultiMesh instances            %8d   drawn by those %d batches, not one call each"
		% [tally["mm_instances"], tally["multimeshes"]])
	print("  collision shapes               %8d" % tally["shapes"])
	print("  physics bodies                 %8d" % tally["bodies"])
	print("  scene nodes                    %8d" % tally["nodes"])
	print("  resident geometry              %8d vertices across %d surfaces in %d unique meshes"
		% [tally["vertices"], tally["surfaces"], tally["unique_meshes"]])
	print("  live enemies / ground drops    %8d / %d" % [tally["enemies"], tally["drops"]])

	print("\n  NOT MEASURED HERE, and not zero-cost — do not read the absence as free:")
	if int(tally["renderer_draws"]) > 0:
		print("    renderer draw calls          %8d" % tally["renderer_draws"])
	else:
		print("    renderer draw calls          absent — the headless dummy renderer reports none")
	if float(tally["renderer_vram_mb"]) > 0.0:
		print("    video memory                 %8.1f MB" % tally["renderer_vram_mb"])
	else:
		print("    video memory                 absent — same reason; resident vertices above are the")
		print("                                 headless stand-in, and are what competes for unified memory")
	print("    frame rate                   needs the target machine, its display, and a run long")
	print("                                 enough to throttle a fanless laptop. Ask; do not infer.")


## Every node under [param node], itself included. Iterative rather than recursive: a settled island
## is tens of thousands of nodes deep in places and a recursive walk is a stack risk on the machine
## this is meant to be safe on.
func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		out.append(current)
		for child: Node in current.get_children():
			stack.append(child)
	return out
