extends SceneTree

## How much memory one built chunk mesh actually costs, per LOD.
##
## `ChunkStreamer`'s mesh cache (F-501) is sized from available system memory, and that arithmetic
## needs a real per-chunk figure. Estimating it from vertex counts times a guessed bytes-per-vertex
## is exactly the kind of constant that is wrong by 3x and never checked, so this measures it:
## build N meshes, HOLD them all so nothing is collected, and divide the resident-memory delta.
##
## Runs headless — this measures the CPU-side `ArrayMesh`, which is what a cache holds. The GPU-side
## copy is the RenderingServer's and is not what is being sized here.
##
##     .agent/bin/agent godot --script tools/chunk_mesh_weight.gd

const Mesher := preload("res://world/chunk/chunk_mesher.gd")

## Enough that per-mesh noise averages out and the delta is large against allocator granularity.
const SAMPLE_CHUNKS: int = 120
const SEED: int = 20260821


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry: Node = get_root().get_node_or_null(^"Registry")
	var biome_defs: Array = []
	if registry != null:
		biome_defs = (registry.get(&"biomes") as Dictionary).values()
	print("\n=== chunk mesh weight ===")
	print("biome defs: %d | sample: %d chunk(s) per LOD\n" % [biome_defs.size(), SAMPLE_CHUNKS])

	for lod: int in 3:
		# Warm: the first build in a process pays one-off allocations that are not per-mesh.
		var warm: ArrayMesh = Mesher.build_mesh(9000, 9000, SEED, biome_defs, lod)
		var before: int = OS.get_static_memory_usage()
		var held: Array[ArrayMesh] = []
		var verts: int = 0
		var tris: int = 0
		for i: int in SAMPLE_CHUNKS:
			var mesh: ArrayMesh = Mesher.build_mesh(i % 40, i / 40, SEED, biome_defs, lod)
			held.append(mesh)
			if mesh.get_surface_count() > 0:
				verts += mesh.surface_get_array_len(0)
				tris += mesh.surface_get_array_index_len(0) / 3
		var after: int = OS.get_static_memory_usage()
		var per_chunk: float = float(after - before) / float(SAMPLE_CHUNKS)
		print("LOD %d  %8.1f KB/chunk  | %6d verts, %6d tris per chunk | %.1f MB for %d chunks"
			% [lod, per_chunk / 1024.0,
				verts / SAMPLE_CHUNKS, tris / SAMPLE_CHUNKS,
				float(after - before) / 1048576.0, SAMPLE_CHUNKS])
		# Held until here on purpose — releasing inside the loop would measure the allocator, not
		# the meshes.
		held.clear()
		warm = null

	print("\nCHUNK_MESH_WEIGHT done")
	quit(0)
