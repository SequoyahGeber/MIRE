class_name BiomeMap
extends RefCounted

## Task 4.2 — biome assignment from height + moisture (docs/ARCHITECTURE.md §4 pipeline step 2).
##
## Pure functions only, same discipline as world/gen/island_heightmap.gd (task 4.1): no nodes, no
## shared state, safe to call from any thread. Every operation stays inside the D-017 world-gen safe
## set — FastNoiseLite, `+ − × ÷`, comparisons — no transcendentals.
##
## `moisture(x, z, world_seed)` is its own noise field, independent of IslandHeightmap's two layers,
## seeded with the same XOR-salt convention island_heightmap.gd established (so a future subsystem
## has two worked examples to extend, not one). `assign(height, moisture, biome_defs)` picks the
## best-matching BiomeDef out of whatever list is passed in — production callers pass
## `Registry.biomes.values()`; the check script builds its own small fixture array instead of
## booting the whole autoload tree.
##
## BiomeDef is accessed by script-equality + `.get()`/`.call()` rather than a typed `BiomeDef`
## parameter, for the same F-016 reason registry.gd's untyped Def dictionaries do it: a brand-new
## class_name is not bare-resolvable in a fresh headless clone until the editor scans it.

const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeDefScript := preload("res://world/gen/biome_def.gd")

const MOISTURE_NOISE_FREQUENCY: float = 0.01
const MOISTURE_NOISE_OCTAVES: int = 3
const MOISTURE_NOISE_LACUNARITY: float = 2.0
const MOISTURE_NOISE_GAIN: float = 0.5
const MOISTURE_NOISE_SALT: int = 0x0C0FFEE1


## The moisture field plus the `IslandHeightmap.NoiseSet` a continent sample needs, so a caller
## resolving many points for one `world_seed` builds all seven `FastNoiseLite` fields ONCE (F-261,
## the same fix F-241 gave the chunk mesher and F-252 gave the resource scatter). `PoiMap`'s dart
## loop is the case that motivated it: up to 720 attempts per def, each of which was rebuilding
## every field twice over.
##
## It NESTS `IslandHeightmap.NoiseSet` rather than folding moisture into it (F-261 offered both).
## The dependency runs one way — this file preloads `island_heightmap.gd`, never the reverse — and a
## moisture field living inside the heightmap's own set would invert that, making the terrain layer
## carry a field only the biome layer above it reads. Nesting also lets a caller that already built
## an island set (`ResourceScatter.placements_for_chunk()`) hand it in instead of paying for a second
## one, which folding could not offer.
##
## Same threading rule as `IslandHeightmap.NoiseSet`: one set per `WorkerThreadPool` task, never
## shared, because a `FastNoiseLite` is not safe to sample from two tasks at once.
class NoiseSet:
	var island: IslandHeightmap.NoiseSet
	var moisture_noise: FastNoiseLite


## Builds one set for `world_seed`. Pass `island_set` when the caller already has one — it is
## adopted, not copied, so the caller keeps the same one-set-per-task discipline over both halves.
static func make_noise_set(world_seed: int, island_set: IslandHeightmap.NoiseSet = null) -> NoiseSet:
	var set := NoiseSet.new()
	set.island = island_set if island_set != null else IslandHeightmap.make_noise_set(world_seed)
	set.moisture_noise = _make_moisture_noise(world_seed)
	return set


## Constructed exactly as `moisture()` built it inline before F-261 — same seed, same fractal
## settings — so the bare and set-backed paths are bit-identical for the same (x, z, world_seed).
## `tools/worldgen_noise_reuse_check.gd` is the proof.
static func _make_moisture_noise(world_seed: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = world_seed ^ MOISTURE_NOISE_SALT
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = MOISTURE_NOISE_FREQUENCY
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = MOISTURE_NOISE_OCTAVES
	noise.fractal_lacunarity = MOISTURE_NOISE_LACUNARITY
	noise.fractal_gain = MOISTURE_NOISE_GAIN
	return noise


## Normalized 0..1 (FastNoiseLite's native -1..1 rescaled) — a separate noise field from
## IslandHeightmap's two layers so wet/dry pockets don't just trace the terrain's own shape.
##
## Builds its noise field per call. A caller sampling many points for one seed wants
## `moisture_from_set()` (F-261) — same output, the construction paid once.
static func moisture(x: float, z: float, world_seed: int) -> float:
	return _moisture_with(x, z, _make_moisture_noise(world_seed))


## Same result as `moisture()`, through a set the caller built once. Takes no `world_seed`: unlike
## `IslandHeightmap.height_from_set()`, nothing here derives geometry from the seed directly — the
## moisture field IS the whole function, so the set determines the answer on its own.
static func moisture_from_set(x: float, z: float, set: NoiseSet) -> float:
	return _moisture_with(x, z, set.moisture_noise)


## The one body both paths funnel through, so the rescale cannot drift between them.
static func _moisture_with(x: float, z: float, noise: FastNoiseLite) -> float:
	return (noise.get_noise_2d(x, z) + 1.0) * 0.5


## Resolution rule: among every BiomeDef whose range contains (height, moisture), the LOWEST
## `priority` wins; a tie breaks on `id` alphabetically (plain String comparison, so it is
## deterministic on every peer regardless of Dictionary iteration order). No match at all falls
## back to the single best-priority def in the whole list (same tie-break) rather than returning an
## empty StringName, so a gap in authored coverage reads as "the closest thing we've got," never a
## hole in the terrain. Returns `&""` only when `biome_defs` is empty.
static func assign(height: float, moisture_value: float, biome_defs: Array) -> StringName:
	var best: Resource = null
	var fallback: Resource = null
	for def: Resource in biome_defs:
		if def == null or def.get_script() != BiomeDefScript:
			continue
		if fallback == null or _better(def, fallback):
			fallback = def
		if bool(def.call(&"contains", height, moisture_value)) and (best == null or _better(def, best)):
			best = def
	var chosen: Resource = best if best != null else fallback
	return StringName(String(chosen.get(&"id"))) if chosen != null else &""


## True if `candidate` should be preferred over `current` under the priority/id resolution rule
## above.
static func _better(candidate: Resource, current: Resource) -> bool:
	var candidate_priority: int = int(candidate.get(&"priority"))
	var current_priority: int = int(current.get(&"priority"))
	if candidate_priority != current_priority:
		return candidate_priority < current_priority
	return String(candidate.get(&"id")) < String(current.get(&"id"))


## Convenience one-shot: continental height + moisture + assignment for one world sample point.
##
## Samples `IslandHeightmap.continent()`, NOT `height()`, and that is the whole of D-144: since
## 4.13 a biome carries terrain amplitudes, so `height()` depends on which biome a point is in.
## Deciding the biome from `height()` would therefore be circular — the biome would be chosen from
## a surface the biome itself shaped. The continent is the biome-independent half: the landmass
## decides where the biomes are, and each biome decides how rough its own ground is.
##
## The `height_min`/`height_max` a BiomeDef authors are therefore CONTINENTAL heights. They read
## the same as before for every biome shipped to date, because the rough layers only ever added
## metres on top; a def tuned against the old combined surface would sit a few metres low.
## Builds both noise fields per call. A caller resolving many points for one seed wants
## `biome_at_from_set()` (F-261).
static func biome_at(x: float, z: float, world_seed: int, biome_defs: Array) -> StringName:
	var continent_height: float = IslandHeightmap.continent(x, z, world_seed)
	var moisture_value: float = moisture(x, z, world_seed)
	return assign(continent_height, moisture_value, biome_defs)


## Same result as `biome_at()`, through a set the caller built once via `make_noise_set()` (F-261).
static func biome_at_from_set(
	x: float, z: float, set: NoiseSet, world_seed: int, biome_defs: Array
) -> StringName:
	var continent_height: float = IslandHeightmap.continent_from_set(x, z, set.island, world_seed)
	var moisture_value: float = moisture_from_set(x, z, set)
	return assign(continent_height, moisture_value, biome_defs)


## How far OUTSIDE its authored band a biome still contributes to the ground's roughness, in metres
## of continental height and in moisture units respectively — the width of the crossfade F-274 put
## between two biomes' amplitudes.
##
## A crossfade is not decoration here, it is the difference between a seam and a cliff. The
## amplitudes are a STEP function of the biome id: `forest.tres` authors `ridge_amplitude = 0.9` and
## `grassland.tres` authors 0.25, and the two meet along the `moisture = 0.5` contour at whatever
## height that contour happens to cross. Handing `height_from_shape()` the winning biome's pair
## alone puts a vertical wall of up to `(0.9 - 0.25) x RIDGE_GATHER-scaled crest x RIDGE_WEIGHT`
## — about 7.7 m — along that contour across the island's high ground: unclimbable (F-136's 46
## degree floor limit), and a chunk seam runs straight through it. Blending the pair instead makes
## the amplitude field continuous, so the transition is a slope with a width rather than an edge.
##
## Sized against the fields they read, not chosen round. 1.5 m of continental height is ~5 m of
## ground at a typical coastal slope, over which the shore/grassland detail step (0.35 -> 0.8, at
## most 0.94 m of relief) spreads to well under a fifth of the floor limit. 0.06 of moisture is a
## ~0.12-wide band on a field whose fBm crosses its full range over ~100 m, so roughly 10-15 m of
## ground for the forest/grassland ridge step — the same order, and the largest step there is.
const AMPLITUDE_BLEND_HEIGHT_M: float = 1.5
const AMPLITUDE_BLEND_MOISTURE: float = 0.06


## The authored biome table flattened to plain floats, ONCE, so a caller resolving a point's
## roughness thousands of times does not pay a `Resource.get()` per field per def per point.
##
## `world/chunk/chunk_mesher.gd` is the caller this exists for (F-274): a LOD0 chunk resolves 1,225
## apron points, and going back to the `Resource` for six exported values at each of them is ~22,000
## Variant property lookups per chunk, on a `WorkerThreadPool` task the whole streaming budget
## (D-074) is measured against. Build one per chunk task and hand it to `blend_amplitudes()`.
##
## Immutable once built and read-only thereafter, so unlike `NoiseSet`/`IslandHeightmap.Shape` a
## table CAN be shared across tasks — nothing in it is mutated by sampling.
class TerrainTable:
	var count: int = 0
	## Six floats per def, ordered by `id`: height_min, height_max, moisture_min, moisture_max,
	## detail_amplitude, ridge_amplitude.
	var bands := PackedFloat64Array()


const _BAND_STRIDE: int = 6


## Flattens `biome_defs` — production callers pass `Registry.biomes.values()` — into a `TerrainTable`.
##
## Sorted by `id` rather than left in whatever order the Dictionary hands back, because
## `blend_amplitudes()` SUMS float weights and float addition is not associative: an incidental
## directory-scan order would move the surface by a few ULPs between two peers running the same
## seed. That is the same hazard D-079 named for biome scan order and F-175 found in seeded world
## generation, applied here to the arithmetic rather than to the pick.
static func make_terrain_table(biome_defs: Array) -> TerrainTable:
	var defs: Array = []
	for def_value: Variant in biome_defs:
		var def: Resource = def_value as Resource
		if def != null and def.get_script() == BiomeDefScript:
			defs.append(def)
	defs.sort_custom(
		func(a: Resource, b: Resource) -> bool: return String(a.get(&"id")) < String(b.get(&"id"))
	)
	var table := TerrainTable.new()
	table.count = defs.size()
	table.bands.resize(table.count * _BAND_STRIDE)
	var i: int = 0
	for def: Resource in defs:
		table.bands[i] = float(def.get(&"height_min"))
		table.bands[i + 1] = float(def.get(&"height_max"))
		table.bands[i + 2] = float(def.get(&"moisture_min"))
		table.bands[i + 3] = float(def.get(&"moisture_max"))
		table.bands[i + 4] = float(def.get(&"detail_amplitude"))
		table.bands[i + 5] = float(def.get(&"ridge_amplitude"))
		i += _BAND_STRIDE
	return table


## 1.0 inside [lo, hi], falling smoothly to 0.0 over `margin` on either side. `smoothstep` is a
## cubic polynomial, so it stays inside the D-017 world-gen safe set — the same reason
## `IslandHeightmap.ridge_mask()` uses it, and the same reason neither uses `pow`.
static func _band_weight(value: float, lo: float, hi: float, margin: float) -> float:
	if value < lo:
		return smoothstep(lo - margin, lo, value)
	if value > hi:
		return 1.0 - smoothstep(hi, hi + margin, value)
	return 1.0


## The terrain amplitudes at one point, CROSSFADED across biome boundaries: every def is weighted by
## how far inside its own (height, moisture) band the point sits, and the pair is the weighted mean.
##
## Deliberately priority-BLIND, unlike `assign()`. Priority resolves a point's IDENTITY — which
## scatter table, which ground material, which biome the HUD names — and identity has to be a single
## answer. Roughness does not: where two authored bands overlap, the ground there is genuinely
## somewhere between the two, and averaging is a truer answer than a winner-takes-all step. The
## consequence to know when authoring: overlapping a flat biome onto a rough one flattens the
## overlap even where the rough one wins the id.
##
## Falls back to (1.0, 1.0) — the biome-blind terrain — when the table is empty or the point is
## further than a margin outside every authored band, so a caller with no biome content still gets a
## surface. With the shipped content that fallback is unreachable (`shore` covers every moisture
## below 4 m, `grassland`/`forest` cover every moisture above it), which matters: the fallback is a
## DISCONTINUITY in an otherwise continuous field, so authored coverage with a gap in it would put
## back exactly the cliff this function exists to remove.
static func blend_amplitudes(
	continent_height: float, moisture_value: float, table: TerrainTable
) -> Vector2:
	var total: float = 0.0
	var detail: float = 0.0
	var ridge: float = 0.0
	var i: int = 0
	while i < table.bands.size():
		var weight: float = _band_weight(continent_height, table.bands[i], table.bands[i + 1],
			AMPLITUDE_BLEND_HEIGHT_M)
		if weight > 0.0:
			weight *= _band_weight(moisture_value, table.bands[i + 2], table.bands[i + 3],
				AMPLITUDE_BLEND_MOISTURE)
		if weight > 0.0:
			total += weight
			detail += weight * table.bands[i + 4]
			ridge += weight * table.bands[i + 5]
		i += _BAND_STRIDE
	if total <= 0.0:
		return Vector2.ONE
	return Vector2(detail / total, ridge / total)


## The two amplitudes to hand `IslandHeightmap.height()` at one world point — the seam D-144 named
## and F-274 wired. Blended, not picked: see `blend_amplitudes()`.
##
## Builds a table and both noise fields per call. A caller resolving many points wants
## `blend_amplitudes()` against a `TerrainTable` built once (F-274), or `surface_from_set()`, which
## is the whole sample.
static func terrain_amplitudes(x: float, z: float, world_seed: int, biome_defs: Array) -> Vector2:
	return terrain_amplitudes_from_set(
		x, z, make_noise_set(world_seed), world_seed, biome_defs)


## Same result as `terrain_amplitudes()`, through a set the caller built once (F-261).
static func terrain_amplitudes_from_set(
	x: float, z: float, set: NoiseSet, world_seed: int, biome_defs: Array
) -> Vector2:
	return blend_amplitudes(
		IslandHeightmap.continent_from_set(x, z, set.island, world_seed),
		moisture_from_set(x, z, set),
		make_terrain_table(biome_defs))


## The two amplitudes an ALREADY-RESOLVED biome AUTHORED. This is the raw content value, not what
## the ground under that point actually uses — between two biomes the surface uses
## `blend_amplitudes()`'s crossfade, and only well inside a band do the two agree. Public because a
## check that asks "does a forest interior actually get forest roughness" needs the authored number
## to compare against (`tools/biome_terrain_check.gd`).
static func amplitudes_for(id: StringName, biome_defs: Array) -> Vector2:
	for def_value: Variant in biome_defs:
		var def: Resource = def_value as Resource
		if def != null and StringName(String(def.get(&"id"))) == id:
			return Vector2(float(def.get(&"detail_amplitude")), float(def.get(&"ridge_amplitude")))
	return Vector2.ONE


## THE SURFACE — the one function every shipped consumer of "how high is the ground at (x, z)"
## calls, and the seam F-274 wired.
##
## `IslandHeightmap.height_from_set()` still exists and still takes an amplitude pair, but nothing
## that ships passes one: the pair is not the caller's to choose, it is the point's own biome's, and
## resolving it is what this function does. The chunk mesher, the POI dart loop, the resource
## scatter and `ProceduralWorld.height_at()` all come through here, so the mesh, the collider, the
## navmesh, a landmark's feet, a tree's feet and a spawn query all describe the SAME ground. That
## agreement is the whole requirement — a divergence here is a landmark floating a metre over a
## ridge, not a cosmetic difference.
##
## Costs one continent sample, one moisture sample and one river walk more than a bare
## `height_from_set()`, and not two continent samples: `shape` carries the biome-independent half
## between the classification and the surface (`IslandHeightmap.Shape`). Pass a reusable `shape` and
## a prebuilt `table` when sampling many points — `world/chunk/chunk_mesher.gd` builds one of each
## per chunk and allocates nothing per vertex.
##
## Network authority: none, exactly like the rest of this file. Every peer derives the identical
## surface from the identical (x, z, world_seed) and the identical authored content, so no height
## ever crosses the wire.
static func surface_from_set(
	x: float, z: float, set: NoiseSet, world_seed: int, table: TerrainTable,
	shape: IslandHeightmap.Shape = null
) -> float:
	var point: IslandHeightmap.Shape = shape if shape != null else IslandHeightmap.Shape.new()
	IslandHeightmap.shape_into(x, z, set.island, world_seed, point)
	var amplitudes: Vector2 = blend_amplitudes(
		IslandHeightmap.continent_from_shape(point),
		moisture_from_set(x, z, set),
		table)
	return IslandHeightmap.height_from_shape(
		x, z, point, set.island, amplitudes.x, amplitudes.y)


## One-shot `surface_from_set()` for a caller with a single point to ask about, building both noise
## fields and the table per call. `ProceduralWorld.height_at()` is a query, not a loop, and is the
## caller this exists for; anything in a loop wants the `_from_set` form.
static func surface_at(x: float, z: float, world_seed: int, biome_defs: Array) -> float:
	return surface_from_set(
		x, z, make_noise_set(world_seed), world_seed, make_terrain_table(biome_defs))
