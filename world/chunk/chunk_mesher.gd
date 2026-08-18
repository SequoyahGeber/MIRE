class_name ChunkMesher
extends RefCounted

## Task 4.3 — the real terrain chunk mesher. Heights come from `IslandHeightmap.height()` (task
## 4.1, D-075), the deterministic cross-platform-safe field: no more R2's own placeholder
## FastNoiseLite. Footprint and LOD0 vertex/tri counts are unchanged from the R2/R2b spikes
## (D-015/D-074), so `tools/bench_chunks.gd` and `tools/bench_chunk_gpu.gd` still run unmodified —
## they now build real terrain instead of placeholder noise, which does not affect either spike's
## already-recorded timing verdict (both measured shape/cost, never a specific height value).
##
## Network authority (docs/ARCHITECTURE.md §2.2): none of its own — a pure function, safe to call
## from any thread (WorkerThreadPool included) or any peer. Every peer that calls it with the same
## (chunk_x, chunk_z, world_seed, lod) gets the identical mesh, because `IslandHeightmap.height()`
## is itself pure and cross-platform-safe (D-017/D-075) and this file adds no RNG, no `sin`/`cos`/
## `pow`/`exp`/`log`, and no shared mutable state.

const Heightmap := preload("res://world/gen/island_heightmap.gd")

## Chunk footprint in metres. Fixed across every LOD — only vertex density changes.
const CHUNK_SIZE: int = 32

## Metres between vertices at each LOD tier, index 0 = nearest/full detail, ascending toward
## coarser/farther (`docs/ARCHITECTURE.md` §4 step 3: "2-3 LOD levels"; task 4.3 uses 3). Every
## entry must divide CHUNK_SIZE evenly so a chunk always tiles to a whole number of quads.
const LOD_STEPS: PackedInt32Array = [1, 2, 4]
const LOD_COUNT: int = 3

## LOD0 numbers, kept as top-level consts because `tools/bench_chunks.gd` and
## `tools/bench_chunk_gpu.gd` (D-015/D-074) already read them by these exact names.
const VERTS_PER_SIDE: int = CHUNK_SIZE / 1 + 1
const VERT_COUNT: int = VERTS_PER_SIDE * VERTS_PER_SIDE
const TRI_COUNT: int = (VERTS_PER_SIDE - 1) * (VERTS_PER_SIDE - 1) * 2
const INDEX_COUNT: int = TRI_COUNT * 3


static func verts_per_side(lod: int) -> int:
	return CHUNK_SIZE / LOD_STEPS[lod] + 1


static func vert_count(lod: int) -> int:
	var side: int = verts_per_side(lod)
	return side * side


static func tri_count(lod: int) -> int:
	var quads_per_side: int = verts_per_side(lod) - 1
	return quads_per_side * quads_per_side * 2


## Height field with a 1-sample border on every side, at [param lod]'s step spacing, sampled at
## WORLD coordinates. Sampling in world space (not chunk-local) is what makes two neighbouring
## chunks — or two neighbouring LOD tiers — agree exactly wherever they sample the same point,
## because `IslandHeightmap.height()` is a pure function of world x/z (D-075). No shared state:
## every sample calls the heightmap fresh, so this is safe from any WorkerThreadPool task.
static func _sample_heights(
	chunk_x: int, chunk_z: int, world_seed: int, lod: int
) -> PackedFloat32Array:
	var step: int = LOD_STEPS[lod]
	var side: int = verts_per_side(lod)
	var apron_side: int = side + 2
	var heights := PackedFloat32Array()
	heights.resize(apron_side * apron_side)
	var origin_x: float = float(chunk_x * CHUNK_SIZE)
	var origin_z: float = float(chunk_z * CHUNK_SIZE)
	for az: int in apron_side:
		var world_z: float = origin_z + float((az - 1) * step)
		var row: int = az * apron_side
		for ax: int in apron_side:
			var world_x: float = origin_x + float((ax - 1) * step)
			heights[row + ax] = Heightmap.height(world_x, world_z, world_seed)
	return heights


static func _build_indices(lod: int) -> PackedInt32Array:
	var side: int = verts_per_side(lod)
	var quads_per_side: int = side - 1
	var indices := PackedInt32Array()
	indices.resize(quads_per_side * quads_per_side * 6)
	var i: int = 0
	for z: int in quads_per_side:
		for x: int in quads_per_side:
			var a: int = z * side + x
			var b: int = a + 1
			var c: int = a + side
			var d: int = c + 1
			indices[i] = a
			indices[i + 1] = c
			indices[i + 2] = b
			indices[i + 3] = b
			indices[i + 4] = c
			indices[i + 5] = d
			i += 6
	return indices


## Build one chunk at [param lod] (0 = nearest/full detail, [constant LOD_COUNT] - 1 = farthest/
## coarsest). Vertices are chunk-local (0..CHUNK_SIZE on X/Z regardless of LOD spacing); the caller
## places the MeshInstance3D at the chunk origin. Deterministic and thread-safe — every input is
## explicit, nothing is read from engine or instance state.
##
## KNOWN LIMITATION (not fixed here — see FINDINGS.md): a LOD0 chunk sharing an edge with a LOD1
## or LOD2 neighbour has more vertices along that edge than the neighbour does, so the two meshes
## do not stitch (a T-junction crack). This does not affect 4.3's acceptance test, which measures
## per-frame streaming COST, not the seam's visual continuity — skirts or edge stitching are a
## follow-up, not a blocker.
static func build_mesh(chunk_x: int, chunk_z: int, world_seed: int, lod: int = 0) -> ArrayMesh:
	var step: int = LOD_STEPS[lod]
	var side: int = verts_per_side(lod)
	var apron_side: int = side + 2
	var heights: PackedFloat32Array = _sample_heights(chunk_x, chunk_z, world_seed, lod)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var count: int = side * side
	vertices.resize(count)
	normals.resize(count)
	uvs.resize(count)

	var inv_size: float = 1.0 / float(CHUNK_SIZE)
	# Central-difference slope per metre. The apron samples are `step` metres apart, so the raw
	# difference must be halved AND divided by `step` to stay a per-metre slope regardless of LOD —
	# at step=1 this reduces to the original R2 formula (`diff * 0.5`).
	var slope_scale: float = 0.5 / float(step)
	var v: int = 0
	for z: int in side:
		var arow: int = (z + 1) * apron_side
		for x: int in side:
			var ai: int = arow + x + 1
			var h: float = heights[ai]
			var local_x: float = float(x * step)
			var local_z: float = float(z * step)
			vertices[v] = Vector3(local_x, h, local_z)
			var dx: float = (heights[ai + 1] - heights[ai - 1]) * slope_scale
			var dz: float = (heights[ai + apron_side] - heights[ai - apron_side]) * slope_scale
			normals[v] = Vector3(-dx, 1.0, -dz).normalized()
			uvs[v] = Vector2(local_x * inv_size, local_z * inv_size)
			v += 1

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _build_indices(lod)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Same chunk via SurfaceTool, LOD0 only — kept only so `tools/bench_chunks.gd` (D-015) still runs
## unmodified; not called by build_mesh or by the real streamer.
static func build_mesh_surface_tool(chunk_x: int, chunk_z: int, world_seed: int) -> ArrayMesh:
	var heights: PackedFloat32Array = _sample_heights(chunk_x, chunk_z, world_seed, 0)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var inv_size: float = 1.0 / float(CHUNK_SIZE)
	for z: int in VERTS_PER_SIDE:
		var arow: int = (z + 1) * (VERTS_PER_SIDE + 2)
		for x: int in VERTS_PER_SIDE:
			var ai: int = arow + x + 1
			var dx: float = (heights[ai + 1] - heights[ai - 1]) * 0.5
			var dz: float = (heights[ai + VERTS_PER_SIDE + 2] - heights[ai - VERTS_PER_SIDE - 2]) * 0.5
			st.set_normal(Vector3(-dx, 1.0, -dz).normalized())
			st.set_uv(Vector2(float(x) * inv_size, float(z) * inv_size))
			st.add_vertex(Vector3(float(x), heights[ai], float(z)))

	for z: int in CHUNK_SIZE:
		for x: int in CHUNK_SIZE:
			var a: int = z * VERTS_PER_SIDE + x
			var b: int = a + 1
			var c: int = a + VERTS_PER_SIDE
			var d: int = c + 1
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)

	return st.commit()
