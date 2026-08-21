class_name ChunkMesher
extends RefCounted

## Task 4.3 — the real terrain chunk mesher. Heights come from `BiomeMap.surface_from_set()`
## (F-274) — `IslandHeightmap`'s deterministic cross-platform-safe field (task 4.1, D-075) sampled
## at the terrain amplitudes each vertex's OWN biome authors (D-144) — no more R2's own placeholder
## FastNoiseLite, and no more the biome-blind 1.0/1.0 surface this file took until F-274. Footprint and LOD0 vertex/tri counts are unchanged from the R2/R2b spikes
## (D-015/D-074), so `tools/bench_chunks.gd` and `tools/bench_chunk_gpu.gd` still run unmodified —
## they now build real terrain instead of placeholder noise, which does not affect either spike's
## already-recorded timing verdict (both measured shape/cost, never a specific height value).
##
## Network authority (docs/ARCHITECTURE.md §2.2): none of its own — a pure function, safe to call
## from any thread (WorkerThreadPool included) or any peer. Every peer that calls it with the same
## (chunk_x, chunk_z, world_seed, biome_defs, lod) gets the identical mesh, because the surface
## beneath it is itself pure and cross-platform-safe (D-017/D-075) and this file adds no RNG, no
## `sin`/`cos`/`pow`/`exp`/`log`, and no shared mutable state. `biome_defs` is content — authored
## `.tres`, identical on every peer, never generated — so it changes nothing about that.
##
## F-379 added a second thing the biome table decides: the ground's COLOUR, blended per vertex into
## `Mesh.ARRAY_COLOR` across the same contour that blends its roughness. Everything above still
## holds — the colours are authored content, the blend is the same crossfade, and the conversion
## that would have cost a `pow()` lives in the shader instead (see [GroundPalette]).

const Heightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeMapScript := preload("res://world/gen/biome_map.gd")
const BiomeDefScript := preload("res://world/gen/biome_def.gd")

## The ground colour a chunk falls back to when `biome_defs` carries no usable def — the same green
## `ChunkStreamer` used to paint the WHOLE island with (F-379). Kept as the fallback and nothing
## else: a bench harness that builds a mesh with an empty biome table still gets ground it can see,
## and anything that renders this colour across real terrain is the bug this constant is named after.
const FALLBACK_GROUND_ALBEDO := Color(0.26, 0.40, 0.19)

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
## value a placeholder awaiting a real pass. See F-128/D-084 for the original sizing.
##
## Retuned by F-251 (2026-08-19): D-142/4.13-4.14's domain warp + masked ridged layer + carved
## river added relief `HEIGHT_SCALE` alone doesn't capture — a ridge crest can climb ~13 m across a
## single LOD1/LOD2 chord (2-4 m of world space), even though `HEIGHT_SCALE` itself dropped from 60
## to 26 in the same retuning. A 12-seed island-wide sweep (`tools/_tmp_seam_probe.gd`, not
## committed) found a worst case of 12.805 m (seed 4242, chunk (3,-4)); 10% of the new HEIGHT_SCALE
## (2.6 m) covers barely a fifth of that. 170% of HEIGHT_SCALE clears it with the same ~3.4x margin
## F-128 originally sized for, scaled to the new worst case. `tools/chunk_stream_check.gd`
## re-measures the divergence every run and fails if the margin is ever lost again.
##
## Re-based by F-450 (2026-08-21) onto `MAX_HEIGHT` instead of `HEIGHT_SCALE`, which is the real
## repair rather than another number. `HEIGHT_SCALE` is the amplitude of the continental NOISE
## only; the placed uplands add their crown lift on top of it and are not in it at all, so when
## F-450 took hill lift from 13 m to 40 m the terrain's actual relief tripled while this constant
## did not move at all. Measured immediately afterwards, the recorded worst seam divergence went
## 4.4004 -> 13.5104 m against an 18.700 m skirt: still covered, but at 1.38x where F-128 sized for
## 3.4x, and the margin assertion in `tools/chunk_stream_check.gd` caught it.
##
## Scarps are why this needs headroom rather than a tight fit. A LOD1 chord spans 2 m of ground and
## a 45-degree scarp face climbs 2 m across it; halve the sampling rate over a feature that sharp
## and the coarse mesh cuts the corner by metres. Expect this number to matter again if cliffs are
## ever made commoner or steeper.
##
## 0.65 of `MAX_HEIGHT` is 33.2 m at the shipped constants — 2.5x the measured worst case, and it
## now tracks the uplands automatically because `MAX_HEIGHT` includes `HILL_HEIGHT_MAX`. The cost is
## only depth on an apron that is never seen: the skirt's vertex and triangle counts are unchanged.
const SKIRT_DEPTH_FRACTION: float = 0.65
const SKIRT_DEPTH: float = Heightmap.MAX_HEIGHT * SKIRT_DEPTH_FRACTION

## Vertex XZ jitter, as a fraction of the LOD's vertex spacing (4.18/D-184's flat-shaded
## low-poly look). A regular grid flat-shades into uniform right triangles; the rvr9ca reference —
## and the Delaunay approach its comment thread suggests — gets its organic read from IRREGULAR
## facets. Deterministic hash jitter gives the same read without retriangulating: strictly under
## 0.5 so no quad can fold. BORDER vertices jitter too — at this fixed LOD0 amplitude rather than
## their own tier's, so any two chunks sharing a world point compute the identical offset and the
## seam still tiles exactly (the first cut exempted borders and the un-jittered rows read as
## straight lines across the terrain). Each vertex RE-SAMPLES the true surface at its actual
## position, so every vertex still sits exactly on the analytic ground —
## `tools/noise_reuse_check.gd`'s and `tools/biome_terrain_check.gd`'s mesh/surface agreement
## contracts hold by construction, and `biome_terrain_check` asserts the cross-chunk border
## agreement directly.
const VERTEX_JITTER_FRACTION: float = 0.35


## The authored biome colours flattened to plain floats, once per chunk build, for the same reason
## `BiomeMap.TerrainTable` exists (F-274): a LOD0 chunk resolves 1,089 vertices, and going back to
## the `Resource` for a Color and four bounds at each of them is thousands of Variant property
## lookups on a `WorkerThreadPool` task the whole streaming budget (D-074) is measured against.
##
## Colours stay in the sRGB the `.tres` authored, all the way into the mesh. Two reasons, and the
## second is the one that decided it: `Mesh.ARRAY_COLOR` is eight bits a channel, and sRGB spends
## those 256 steps where the eye is — a forest floor at linear 0.04 would land on code 10 of 255 and
## band across its own crossfade. The other is this file's own header contract: converting here
## means `pow()` on a content value inside the mesher, and "no `sin`/`cos`/`pow`/`exp`/`log`" is the
## D-017 discipline that makes `build_mesh()` bit-identical on every platform. `terrain_flat.gdshader`
## decodes to linear in its vertex stage instead, where it is three instructions per vertex and
## nobody's determinism claim is involved.
##
## Sorted by `id`, like `make_terrain_table()`, and for the identical reason: the blend below SUMS
## float weights, float addition is not associative, and an incidental directory-scan order would
## move a vertex colour by a few ULPs between two peers running the same seed (D-079, F-175). A
## colour is not gameplay, but it IS in the mesh, and a mesh that differs between peers is a mesh
## nothing can compare.
class GroundPalette extends RefCounted:
	var count: int = 0
	## Four floats per def, ordered by `id`: height_min, height_max, moisture_min, moisture_max.
	## Deliberately its own copy rather than an index into `BiomeMap.TerrainTable.bands` — the two
	## are built by the same sort rule, but an implicit index alignment between two structures in
	## two files is exactly the coupling that goes wrong silently when one of them is retuned.
	var bands := PackedFloat64Array()
	## Index-aligned with `bands`, in the authored sRGB — see this class's header for why.
	var colors := PackedColorArray()


const _PALETTE_STRIDE: int = 4


## Flattens `biome_defs` — `Registry.biomes.values()` on every shipped caller — into a
## [GroundPalette]. Skips anything that is not a `BiomeDef`, exactly as `BiomeMap` does, so a
## fixture array with a stray Resource in it is not a crash.
static func make_ground_palette(biome_defs: Array) -> GroundPalette:
	var defs: Array = []
	for def_value: Variant in biome_defs:
		var def: Resource = def_value as Resource
		if def != null and def.get_script() == BiomeDefScript:
			defs.append(def)
	defs.sort_custom(
		func(a: Resource, b: Resource) -> bool: return String(a.get(&"id")) < String(b.get(&"id"))
	)
	var palette := GroundPalette.new()
	palette.count = defs.size()
	palette.bands.resize(palette.count * _PALETTE_STRIDE)
	palette.colors.resize(palette.count)
	var i: int = 0
	for def: Resource in defs:
		palette.bands[i] = float(def.get(&"height_min"))
		palette.bands[i + 1] = float(def.get(&"height_max"))
		palette.bands[i + 2] = float(def.get(&"moisture_min"))
		palette.bands[i + 3] = float(def.get(&"moisture_max"))
		palette.colors[i / _PALETTE_STRIDE] = def.get(&"ground_albedo") as Color
		i += _PALETTE_STRIDE
	return palette


## The ground colour at one point: every biome weighted by how far inside its own (height, moisture)
## band the point sits, and the weighted mean of their colours (F-379).
##
## The weights come from `BiomeMap._band_weight()` and the two margins `BiomeMap.blend_amplitudes()`
## uses, and that is not a convenience — it is the requirement. Colour and roughness have to cross
## the SAME contour with the SAME width, or the ground changes hue in one place and changes shape in
## another and the island reads as two unrelated maps laid over each other. A local copy of that
## smoothstep would be one retuning away from exactly that, so this calls the shared one instead.
##
## Priority-blind, like `blend_amplitudes()` and unlike `BiomeMap.assign()`: where two authored
## bands overlap, the ground there genuinely IS between the two, and a winner-takes-all step would
## put a hue wall along the moisture contour — the same cliff the amplitude crossfade exists to
## remove, in colour instead of in metres.
##
## Mixes in sRGB, because that is the space the values are stored and travel in (see [GroundPalette]).
## A linear mix of the same two ends would darken the middle of the crossfade; on a beach running
## into a meadow, sRGB is also the space the two were CHOSEN in.
static func blend_ground_albedo(
	continent_height: float, moisture_value: float, palette: GroundPalette
) -> Color:
	var total: float = 0.0
	var red: float = 0.0
	var green: float = 0.0
	var blue: float = 0.0
	var i: int = 0
	while i < palette.bands.size():
		var weight: float = BiomeMapScript._band_weight(
			continent_height, palette.bands[i], palette.bands[i + 1],
			BiomeMapScript.AMPLITUDE_BLEND_HEIGHT_M)
		if weight > 0.0:
			weight *= BiomeMapScript._band_weight(
				moisture_value, palette.bands[i + 2], palette.bands[i + 3],
				BiomeMapScript.AMPLITUDE_BLEND_MOISTURE)
		if weight > 0.0:
			var colour: Color = palette.colors[i / _PALETTE_STRIDE]
			total += weight
			red += weight * colour.r
			green += weight * colour.g
			blue += weight * colour.b
		i += _PALETTE_STRIDE
	if total <= 0.0:
		return FALLBACK_GROUND_ALBEDO
	var inverse: float = 1.0 / total
	return Color(red * inverse, green * inverse, blue * inverse, 1.0)


## F-464 · HOW MUCH OF THIS VERTEX IS BARE ROCK, 0..1, from the emitted surface's own tilt.
##
## Travels in `ARRAY_COLOR`'s alpha, which the biome blend was leaving at a constant 1.0 — so it
## costs nothing in the vertex buffer, needs no second attribute, and the skirt inherits it with the
## rest of the colour exactly as it already did. `terrain_flat.gdshader` is the only reader.
##
## The two angles are where ground stops holding what grows on it. Grass and litter sit on anything
## up to about the angle of repose of soil; past that a slope sheds, and by the high number it is a
## face. The low number straddles the river cliff's own 52-degree mean (F-464) rather than sitting
## well under it: rock has to start before the cliff proper does, or the face gets a hard green line
## along its rim — but the first cut at 34/56 painted half the island's ordinary hillsides grey,
## which is the same mistake in the other direction and much more visible, because there is far more
## hillside than there is cliff.
const ROCK_START_SLOPE_DEG: float = 40.0
const ROCK_FULL_SLOPE_DEG: float = 62.0
## `cos()` of those, because a unit normal's y IS the cosine of the slope and comparing there costs
## no trig per vertex. GDScript will not fold `cos()` into a const, hence the literals — recompute
## both together if either angle moves.
const _ROCK_START_COS: float = 0.766    # cos(40 deg)
const _ROCK_FULL_COS: float = 0.469     # cos(62 deg)


static func _rock_exposure(normal_y: float) -> float:
	return 1.0 - smoothstep(_ROCK_FULL_COS, _ROCK_START_COS, normal_y)


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
## because the surface is a pure function of world x/z (D-075).
##
## Every sample goes through `BiomeMap.surface_from_set()` (F-274), so each vertex stands on the
## roughness ITS OWN biome authors — the seam D-144 named and nothing shipped crossed until this
## task. `biome_defs` is REQUIRED and not defaulted on purpose: an empty table silently produces the
## biome-blind 1.0/1.0 surface, which is exactly the terrain F-274 found the whole game building,
## and a default is how that gets shipped again.
##
## Samples through ONE `BiomeMap.NoiseSet`, one `TerrainTable` and one reused
## `IslandHeightmap.Shape`, built once per `build_mesh()` call and passed in (F-241, F-274; the
## jitter pass in `build_mesh` samples the same surface, which is why the trio moved up a level): a
## LOD0 apron is 35x35 = 1,225 points and every one of them would otherwise rebuild seven
## `FastNoiseLite` fields and re-read six exported values off three `BiomeDef` resources. Still safe
## from any WorkerThreadPool task — all three are locals of `build_mesh`, built fresh per call,
## never shared or cached across calls, the same one-per-task rule `IslandHeightmap.NoiseSet`
## documents.
static func _sample_heights(
	chunk_x: int, chunk_z: int, world_seed: int, lod: int,
	noise_set: BiomeMapScript.NoiseSet, table: BiomeMapScript.TerrainTable,
	shape: Heightmap.Shape
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
			heights[row + ax] = BiomeMapScript.surface_from_set(
				world_x, world_z, noise_set, world_seed, table, shape)
	return heights


## Area-weighted vertex normals accumulated from the emitted triangles.
##
## Called with the TERRAIN indices only, before the skirt is appended: the skirt's walls are vertical,
## and letting them contribute would drag every border vertex's normal sideways. The skirt keeps
## inheriting its top vertex's normal, which is the deliberate choice documented at that loop.
##
## The cross product is left unnormalised on purpose — its magnitude is twice the triangle's area,
## which is exactly the weighting wanted here. Jitter makes neighbouring triangles genuinely unequal,
## so a large facet should pull a shared vertex more than a sliver does.
static func _accumulate_normals(
	vertices: PackedVector3Array, indices: PackedInt32Array, normals: PackedVector3Array, count: int
) -> void:
	for i: int in count:
		normals[i] = Vector3.ZERO
	var tri: int = 0
	while tri + 2 < indices.size():
		var ia: int = indices[tri]
		var ib: int = indices[tri + 1]
		var ic: int = indices[tri + 2]
		var a: Vector3 = vertices[ia]
		# (c - a) x (b - a), not the other order: `_build_indices()` winds a quad as
		# (a, b, c) = (x,z), (x+1,z), (x,z+1), and this order is the one that comes out +Y on a flat
		# quad. The other way lights the whole island from underneath.
		var face: Vector3 = (vertices[ic] - a).cross(vertices[ib] - a)
		normals[ia] += face
		normals[ib] += face
		normals[ic] += face
		tri += 3
	for i: int in count:
		var n: Vector3 = normals[i]
		# A zero-area fan is only reachable if jitter collapsed a quad, which VERTEX_JITTER_FRACTION
		# < 0.5 forbids — but a zero normal is a black facet, so it falls back to straight up.
		normals[i] = n.normalized() if n.length_squared() > 0.0 else Vector3.UP


## Unit-range jitter for the vertex at integer WORLD metres (ix, iz) — the same offset whichever
## chunk or LOD asks, and identical on every platform: integer mixing and one division by a
## constant, the D-017 discipline `IslandHeightmap.lobes()` set. Components in [-1, 1]; the caller
## scales by `VERTEX_JITTER_FRACTION * step`.
static func _vertex_jitter(ix: int, iz: int, world_seed: int) -> Vector2:
	var mixed: int = ((ix * 73856093) ^ (iz * 19349663) ^ (world_seed * 83492791)) & 0x7FFFFFFF
	var jx: float = float(mixed % 2048) / 1023.5 - 1.0
	var jz: float = float((mixed / 2048) % 2048) / 1023.5 - 1.0
	return Vector2(jx, jz)


## Winding note (F-133): Godot's front face is the one whose vertices run CLOCKWISE as seen from
## the front, which is the opposite of the (v1-v0) x (v2-v0) right-hand rule it is easy to reach
## for. `a, b, c` / `d, c, b` below is what makes this surface face UP; the mirror of it renders
## and collides as a floor you can only see and stand on from underneath. (The second triangle was
## written `b, d, c` until F-399 rotated it; a cyclic rotation is the same triangle, the same
## winding and the same normal — only the provoking vertex moves. The reason it had to move is at
## the rotation itself.)
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
			# F-399: `d, c, b` — a CYCLIC rotation of the `b, d, c` this shipped with, so the
			# triangle, its winding and its normal are all unchanged and only its FIRST index moves.
			# That index is the provoking vertex, which is what a `flat` varying reads, and
			# `terrain_flat.gdshader` now hangs a per-facet tint jitter off one. Under `b, d, c` the
			# provoking vertex of this triangle was `b` — which is also the provoking vertex of the
			# NEXT quad's first triangle, an edge-adjacent neighbour, so every facet on the island
			# came in a matched pair and the jitter read as a rhombus grid instead of as variation.
			# With `d`, the two triangles that share a provoking vertex (this one and the first
			# triangle of the quad up-and-right of it) meet at a single point, never along an edge —
			# and that holds under either provoking-vertex convention, so it does not quietly depend
			# on Vulkan's first-vertex default.
			indices[i + 3] = d
			indices[i + 4] = c
			indices[i + 5] = b
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
## `biome_defs` — `Registry.biomes.values()` on every shipped caller — sits BEFORE the optional
## `lod` rather than after it (F-274). GDScript cannot put a required parameter after an optional
## one, and making the biome table optional is what let the biome-blind surface ship unnoticed in
## the first place, so the argument order gave way instead of the requirement.
static func build_mesh(
	chunk_x: int, chunk_z: int, world_seed: int, biome_defs: Array, lod: int = 0
) -> ArrayMesh:
	var step: int = LOD_STEPS[lod]
	var side: int = verts_per_side(lod)
	var noise_set: BiomeMapScript.NoiseSet = BiomeMapScript.make_noise_set(world_seed)
	var table: BiomeMapScript.TerrainTable = BiomeMapScript.make_terrain_table(biome_defs)
	# F-379: the same authored table again, flattened for colour instead of roughness. Built here
	# rather than per vertex for the reason the terrain table is — see make_ground_palette().
	var palette: GroundPalette = make_ground_palette(biome_defs)
	var shape := Heightmap.Shape.new()

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var count: int = side * side
	vertices.resize(count)
	normals.resize(count)
	uvs.resize(count)
	colors.resize(count)

	var inv_size: float = 1.0 / float(CHUNK_SIZE)
	# F-339 removed the one-ring apron this function used to sample. Its only consumer was the
	# central-difference normal below, which is gone; keeping it would have cost `(side + 2)^2` noise
	# samples per chunk — 1,225 at LOD0, more than the 1,089 the vertices themselves need — for a
	# result nothing read. `_sample_heights()` itself stays: the reference-mesh builder below is a
	# second, unjittered consumer.
	var origin_x: float = float(chunk_x * CHUNK_SIZE)
	var origin_z: float = float(chunk_z * CHUNK_SIZE)
	var jitter_amp: float = VERTEX_JITTER_FRACTION * float(step)
	var v: int = 0
	for z: int in side:
		for x: int in side:
			var local_x: float = float(x * step)
			var local_z: float = float(z * step)
			# Every vertex jitters — the first cut exempted the border entirely, and the playtest
			# read the un-jittered rows as visible straight lines every CHUNK_SIZE metres ("some
			# edges don't line up"). What the border actually needs is not stillness but AGREEMENT:
			# the offset is a pure function of the vertex's world position and the seed, so any two
			# chunks — either LOD — that place a vertex at the same world point compute the same
			# offset, provided the amplitude does not scale with THEIR step. Hence border vertices
			# use the fixed LOD0 amplitude and interior vertices their own tier's; cross-tier
			# chords between shared points diverge exactly as before and stay the skirt's job.
			var on_border: bool = x == 0 or x == side - 1 or z == 0 or z == side - 1
			var amp: float = VERTEX_JITTER_FRACTION if on_border else jitter_amp
			var jitter: Vector2 = _vertex_jitter(
				chunk_x * CHUNK_SIZE + x * step, chunk_z * CHUNK_SIZE + z * step, world_seed)
			# Through a Vector2 FIRST: components are float32, the same narrowing Vector3
			# applies when the vertex is stored. Sampling at the narrowed position is what
			# keeps `biome_terrain_check`'s exact vertex==surface comparison exact — sampling
			# at the double and narrowing afterwards can drift the stored y a ULP off the
			# surface at the stored x.
			var snapped := Vector2(local_x + jitter.x * amp, local_z + jitter.y * amp)
			local_x = snapped.x
			local_z = snapped.y
			var world_x: float = origin_x + local_x
			var world_z: float = origin_z + local_z
			var h: float = BiomeMapScript.surface_from_set(
				world_x, world_z, noise_set, world_seed, table, shape)
			vertices[v] = Vector3(local_x, h, local_z)
			uvs[v] = Vector2(local_x * inv_size, local_z * inv_size)
			# F-379: the vertex's own biome colour, crossfaded exactly as its roughness was.
			#
			# The continental height is FREE here — `surface_from_set()` just filled `shape` with it
			# on its way to the surface, and `continent_from_shape()` only reads what is already
			# there. Moisture is the one field this costs: a second 3-octave fBm sample per vertex,
			# the cheapest of the seven the surface already builds, and the only alternative was
			# widening `BiomeMap.surface_from_set()`'s return so it hands back the two intermediates
			# — which would put a colour concern into the signature every height query in the game
			# goes through.
			colors[v] = blend_ground_albedo(
				Heightmap.continent_from_shape(shape),
				BiomeMapScript.moisture_from_set(world_x, world_z, noise_set),
				palette)
			v += 1

	var indices: PackedInt32Array = _build_indices(lod)
	# F-339: normals derived from the geometry that is actually EMITTED.
	#
	# They used to come from a central difference across the unjittered apron, at `ai +/- 1`, while
	# the vertex itself had been moved in XZ and re-sampled at its new coordinate — so the stored
	# normal described a surface the triangles do not form. `terrain_flat.gdshader` computes its
	# facet normal from screen-space derivatives, so shipped LIGHTING was never wrong; what was wrong
	# is the mesh's own data, which is a trap for anything that reads it (a check, a tool, any future
	# material without the derivative trick) and was wrong for no reason.
	_accumulate_normals(vertices, indices, normals, count)
	# F-464: rock exposure, into the alpha the biome colour left at 1.0.
	#
	# Steep ground is bare rock, everywhere, for the same reason it is in the world: soil and the
	# things that root in it do not stay on a face. So this is not a river-cliff special case —
	# a lobe's sea cliff and a placed hill's scarp get it too, off the one property they share.
	#
	# It has to be HERE and not in the vertex loop, because the honest slope is the one the emitted
	# triangles actually form (F-339's whole point), and that is not known until they exist. It is
	# also why this costs no samples at all: `normals` is already built and already paid for.
	#
	# Per VERTEX rather than per fragment. `terrain_flat.gdshader` could derive a facet slope from
	# the same screen-space derivatives it lights with, at two more instructions on every terrain
	# pixel on the screen; this is 1,089 lerps per chunk, once, at build time, on a thread. On the
	# machine docs/PERFORMANCE.md targets that is not a close call. The cost is that a cliff meshed
	# at LOD2 reads its slope across 4 m instead of 1 m and comes out a little greener — which is
	# the correct direction to be wrong in, since LOD2 chunks are the far ones.
	for i in count:
		var colour: Color = colors[i]
		colour.a = _rock_exposure(normals[i].y)
		colors[i] = colour

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
	colors.resize(count + ring_len)
	for i: int in ring_len:
		var top: int = ring[i]
		var above: Vector3 = vertices[top]
		vertices[skirt_base + i] = Vector3(above.x, above.y - SKIRT_DEPTH, above.z)
		# The wall inherits the normal, UV and COLOUR of the terrain vertex it hangs from, rather
		# than a true outward-facing normal. That is deliberate: lit as if it were more terrain, the
		# wall reads as a continuation of the surface at the seam instead of a dark flange under it —
		# which is the entire point, since it is only ever seen through a crack a few centimetres
		# tall. The UV streaks downward for the same reason, and F-379's colour has to come with
		# them: a skirt in the old single green under a shore chunk's sand would be a brown seam
		# drawn along every chunk edge on the beach.
		normals[skirt_base + i] = normals[top]
		uvs[skirt_base + i] = uvs[top]
		colors[skirt_base + i] = colors[top]

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
	# F-379. Four bytes a vertex in the attribute buffer (Godot stores ARRAY_COLOR as RGBA8), so a
	# LOD0 chunk carries ~4.8 KB more and a full 289-chunk residency ~1.4 MB — paid once at upload,
	# never per frame, and it buys the only per-point ground colour the flat-shaded terrain can have
	# without a texture or a second material. A per-CHUNK uniform would have been free and wrong: a
	# chunk is 32 m and the biome contour runs straight through it, so the island would have gone
	# from one green to a checkerboard.
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Same chunk via SurfaceTool, LOD0 only — kept only so `tools/bench_chunks.gd` (D-015) still runs
## unmodified; not called by build_mesh or by the real streamer. No skirt: it exists to time
## SurfaceTool against the array path on identical work, and nothing renders what it returns.
static func build_mesh_surface_tool(
	chunk_x: int, chunk_z: int, world_seed: int, biome_defs: Array
) -> ArrayMesh:
	# Grid-only, no jitter pass: this path exists to benchmark SurfaceTool against the array path
	# on comparable work, and nothing renders what it returns.
	var heights: PackedFloat32Array = _sample_heights(
		chunk_x, chunk_z, world_seed, 0,
		BiomeMapScript.make_noise_set(world_seed),
		BiomeMapScript.make_terrain_table(biome_defs), Heightmap.Shape.new())

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
