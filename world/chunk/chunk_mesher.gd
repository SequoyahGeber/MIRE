class_name ChunkMesher
extends RefCounted

## SPIKE R2 — throwaway. Answers "how fast can GDScript build a terrain chunk mesh?"
## This is NOT the real terrain system: no LOD, no materials, no collision, no biomes.
## Delete or rewrite once the measurement is recorded in docs/DECISIONS.md (D-015).
##
## Determinism: every height comes from a seeded FastNoiseLite. No global randi()/randf(),
## no time, no engine state. Same (chunk_x, chunk_z, noise_seed) → identical mesh on every
## machine, which is what docs/ARCHITECTURE.md §4 requires for seed-shared world gen.

## Chunk footprint in metres.
const CHUNK_SIZE: int = 32
## Vertices per side at 1 m spacing.
const VERTS_PER_SIDE: int = CHUNK_SIZE + 1
## Height samples per side including a 1-vertex apron, so edge normals match the neighbour chunk.
const APRON_PER_SIDE: int = VERTS_PER_SIDE + 2
const VERT_COUNT: int = VERTS_PER_SIDE * VERTS_PER_SIDE
const TRI_COUNT: int = CHUNK_SIZE * CHUNK_SIZE * 2
const INDEX_COUNT: int = TRI_COUNT * 3

const NOISE_FREQUENCY: float = 0.008
const NOISE_OCTAVES: int = 4
const HEIGHT_SCALE: float = 30.0


## Deterministic noise source. One per call — FastNoiseLite.new() is cheap and a shared
## instance would not be safe to sample from several WorkerThreadPool tasks at once.
static func make_noise(noise_seed: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = NOISE_FREQUENCY
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = NOISE_OCTAVES
	return noise


## Height field with a 1-vertex border on every side (APRON_PER_SIDE²), in chunk-local
## sample space: apron index 0 is local vertex -1.
static func _sample_heights(chunk_x: int, chunk_z: int, noise: FastNoiseLite) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	heights.resize(APRON_PER_SIDE * APRON_PER_SIDE)
	var origin_x: float = float(chunk_x * CHUNK_SIZE)
	var origin_z: float = float(chunk_z * CHUNK_SIZE)
	for az: int in APRON_PER_SIDE:
		var world_z: float = origin_z + float(az - 1)
		var row: int = az * APRON_PER_SIDE
		for ax: int in APRON_PER_SIDE:
			var world_x: float = origin_x + float(ax - 1)
			heights[row + ax] = noise.get_noise_2d(world_x, world_z) * HEIGHT_SCALE
	return heights


## Shared index buffer — identical for every chunk, but rebuilt per call so the benchmark
## measures the honest cost of a cold chunk build.
static func _build_indices() -> PackedInt32Array:
	var indices := PackedInt32Array()
	indices.resize(INDEX_COUNT)
	var i: int = 0
	for z: int in CHUNK_SIZE:
		for x: int in CHUNK_SIZE:
			var a: int = z * VERTS_PER_SIDE + x
			var b: int = a + 1
			var c: int = a + VERTS_PER_SIDE
			var d: int = c + 1
			indices[i] = a
			indices[i + 1] = c
			indices[i + 2] = b
			indices[i + 3] = b
			indices[i + 4] = c
			indices[i + 5] = d
			i += 6
	return indices


## Build one 32 m × 32 m chunk. Vertices are chunk-local (0..32 on X/Z); the caller places
## the MeshInstance3D at the chunk origin.
static func build_mesh(chunk_x: int, chunk_z: int, noise_seed: int) -> ArrayMesh:
	var noise := make_noise(noise_seed)
	var heights: PackedFloat32Array = _sample_heights(chunk_x, chunk_z, noise)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	vertices.resize(VERT_COUNT)
	normals.resize(VERT_COUNT)
	uvs.resize(VERT_COUNT)

	var inv_size: float = 1.0 / float(CHUNK_SIZE)
	var v: int = 0
	for z: int in VERTS_PER_SIDE:
		var arow: int = (z + 1) * APRON_PER_SIDE
		for x: int in VERTS_PER_SIDE:
			var ai: int = arow + x + 1
			var h: float = heights[ai]
			vertices[v] = Vector3(float(x), h, float(z))
			# Central differences over the apron — seamless with the neighbouring chunk
			# because both sample the same world-space noise.
			var dx: float = (heights[ai + 1] - heights[ai - 1]) * 0.5
			var dz: float = (heights[ai + APRON_PER_SIDE] - heights[ai - APRON_PER_SIDE]) * 0.5
			normals[v] = Vector3(-dx, 1.0, -dz).normalized()
			uvs[v] = Vector2(float(x) * inv_size, float(z) * inv_size)
			v += 1

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _build_indices()

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Same chunk via SurfaceTool, kept only so the benchmark can justify which path build_mesh
## uses. Not called by build_mesh.
static func build_mesh_surface_tool(chunk_x: int, chunk_z: int, noise_seed: int) -> ArrayMesh:
	var noise := make_noise(noise_seed)
	var heights: PackedFloat32Array = _sample_heights(chunk_x, chunk_z, noise)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var inv_size: float = 1.0 / float(CHUNK_SIZE)
	for z: int in VERTS_PER_SIDE:
		var arow: int = (z + 1) * APRON_PER_SIDE
		for x: int in VERTS_PER_SIDE:
			var ai: int = arow + x + 1
			var dx: float = (heights[ai + 1] - heights[ai - 1]) * 0.5
			var dz: float = (heights[ai + APRON_PER_SIDE] - heights[ai - APRON_PER_SIDE]) * 0.5
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
