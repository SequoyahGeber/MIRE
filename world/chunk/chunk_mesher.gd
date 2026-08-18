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

## Skirt depth as a fraction of the heightmap's own peak amplitude rather than a bare metre count,
## so the margin survives `IslandHeightmap.HEIGHT_SCALE` being retuned — 4.1 explicitly calls that
## value a placeholder awaiting a real pass. See F-128/D-084: the worst LOD-boundary divergence
## measured over the whole island across four seeds is 1.78 m (LOD1 against LOD2) at the current
## HEIGHT_SCALE of 60, so 10% of amplitude is a ~3.4x margin. `tools/chunk_stream_check.gd`
## re-measures the divergence and fails if that margin is ever lost.
const SKIRT_DEPTH_FRACTION: float = 0.10
const SKIRT_DEPTH: float = Heightmap.HEIGHT_SCALE * SKIRT_DEPTH_FRACTION


static func verts_per_side(lod: int) -> int:
	return CHUNK_SIZE / LOD_STEPS[lod] + 1


static func vert_count(lod: int) -> int:
	var side: int = verts_per_side(lod)
	return side * side


static func tri_count(lod: int) -> int:
	var quads_per_side: int = verts_per_side(lod) - 1
	return quads_per_side * quads_per_side * 2


## Extra vertices the skirt contributes: one dropped copy per border vertex. The border's own
## terrain vertices are reused as the skirt's top ring, so only the bottom ring is new.
static func skirt_vert_count(lod: int) -> int:
	return 4 * (verts_per_side(lod) - 1)


## Two triangles per border segment. The border is a closed loop, so it has exactly as many
## segments as vertices.
static func skirt_tri_count(lod: int) -> int:
	return skirt_vert_count(lod) * 2


## Terrain vertex indices walked once around the chunk border: south (x ascending), east
## (z ascending), north (x descending), west (z descending), closing back onto the first. That
## traversal order is load-bearing — it is what lets every skirt quad use one uniform winding and
## still come out facing OUTWARD on all four sides, instead of needing a per-edge special case.
## Which uniform winding is the right one is the same question `_build_indices` answers — see the
## note there, and F-133.
static func _perimeter_indices(lod: int) -> PackedInt32Array:
	var side: int = verts_per_side(lod)
	var last: int = side - 1
	var ring := PackedInt32Array()
	ring.resize(4 * last)
	var i: int = 0
	for x: int in last:
		ring[i] = x
		i += 1
	for z: int in last:
		ring[i] = z * side + last
		i += 1
	for k: int in last:
		ring[i] = last * side + (last - k)
		i += 1
	for k: int in last:
		ring[i] = (last - k) * side
		i += 1
	return ring


## The chunk's TERRAIN triangles alone, flattened for `ConcavePolygonShape3D.set_faces()`.
## Deliberately not `ArrayMesh.get_faces()`, which would hand the physics server the skirt as well:
## a skirt is a vertical wall standing exactly on the seam a player walks across, so colliding with
## it is free snagging on a surface that exists only to be looked at — and it is ~12% more faces
## (LOD0) to cook, against the one main-thread cost this whole system is budgeted around (D-074).
## `build_mesh` appends the skirt after the terrain, so the terrain is always the first
## `tri_count(lod)` triangles: this is a slice, not a search.
static func collision_faces(mesh: ArrayMesh, lod: int) -> PackedVector3Array:
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var n: int = tri_count(lod) * 3
	var faces := PackedVector3Array()
	faces.resize(n)
	for i: int in n:
		faces[i] = verts[indices[i]]
	return faces


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


## Winding note (F-133): Godot's front face is the one whose vertices run CLOCKWISE as seen from
## the front, which is the opposite of the (v1-v0) x (v2-v0) right-hand rule it is easy to reach
## for. `a, b, c` / `b, d, c` below is what makes this surface face UP; the mirror of it renders
## and collides as a floor you can only see and stand on from underneath.
## `tools/chunk_stream_check.gd` pins this down with `SurfaceTool.generate_normals()`, which
## applies the engine's own convention rather than anyone's recollection of it.
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
			indices[i + 1] = b
			indices[i + 2] = c
			indices[i + 3] = b
			indices[i + 4] = d
			indices[i + 5] = c
			i += 6
	return indices


## Build one chunk at [param lod] (0 = nearest/full detail, [constant LOD_COUNT] - 1 = farthest/
## coarsest). Vertices are chunk-local (0..CHUNK_SIZE on X/Z regardless of LOD spacing); the caller
## places the MeshInstance3D at the chunk origin. Deterministic and thread-safe — every input is
## explicit, nothing is read from engine or instance state.
##
## The mesh carries a vertical SKIRT below its outer border (F-128/D-084). Two neighbours at the
## same LOD tile exactly — both sample the identical world-space points along their shared edge —
## but two neighbours at DIFFERENT tiers connect the same edge with different triangle counts, so
## the surfaces diverge and a T-junction crack opens. The skirt hides that gap without needing to
## know anything about the neighbour, which is what keeps this function pure in
## (chunk_x, chunk_z, world_seed, lod): real stitching would take the neighbours' tiers as a fifth
## input and force a re-mesh of the finer chunk every time a neighbour changed tier, cascading work
## through exactly the frame budget task 4.3 exists to protect.
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

	var indices: PackedInt32Array = _build_indices(lod)

	# Skirt: a thin wall hanging SKIRT_DEPTH metres straight down from the chunk's outer border,
	# appended AFTER the terrain so `collision_faces()` can slice the terrain off the front. Both
	# sides of a tier boundary grow one, which is what makes the gap covered whichever surface
	# happens to sit higher at a given point along the seam.
	#
	# One surface, not two: a second surface would be a second draw call on every one of the ~289
	# resident chunks, and this ships to the worst machine we target, not the best.
	var ring: PackedInt32Array = _perimeter_indices(lod)
	var ring_len: int = ring.size()
	var skirt_base: int = count
	vertices.resize(count + ring_len)
	normals.resize(count + ring_len)
	uvs.resize(count + ring_len)
	for i: int in ring_len:
		var top: int = ring[i]
		var above: Vector3 = vertices[top]
		vertices[skirt_base + i] = Vector3(above.x, above.y - SKIRT_DEPTH, above.z)
		# The wall inherits the normal and UV of the terrain vertex it hangs from, rather than a
		# true outward-facing normal. That is deliberate: lit as if it were more terrain, the wall
		# reads as a continuation of the surface at the seam instead of a dark flange under it —
		# which is the entire point, since it is only ever seen through a crack a few centimetres
		# tall. The UV streaks downward for the same reason.
		normals[skirt_base + i] = normals[top]
		uvs[skirt_base + i] = uvs[top]

	var si: int = indices.size()
	indices.resize(si + ring_len * 6)
	for i: int in ring_len:
		var next: int = (i + 1) % ring_len
		var t0: int = ring[i]
		var t1: int = ring[next]
		var b0: int = skirt_base + i
		var b1: int = skirt_base + next
		indices[si] = t0
		indices[si + 1] = b0
		indices[si + 2] = t1
		indices[si + 3] = t1
		indices[si + 4] = b0
		indices[si + 5] = b1
		si += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Same chunk via SurfaceTool, LOD0 only — kept only so `tools/bench_chunks.gd` (D-015) still runs
## unmodified; not called by build_mesh or by the real streamer. No skirt: it exists to time
## SurfaceTool against the array path on identical work, and nothing renders what it returns.
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
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(d)
			st.add_index(c)

	return st.commit()
