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


## The two amplitudes a point's own biome authors, ready to hand to
## `IslandHeightmap.height()`. Returns (1.0, 1.0) — the biome-blind terrain — when no def matches
## or the table is empty, so a caller with no biome content still gets a surface.
static func terrain_amplitudes(x: float, z: float, world_seed: int, biome_defs: Array) -> Vector2:
	return amplitudes_for(biome_at(x, z, world_seed, biome_defs), biome_defs)


## Same result as `terrain_amplitudes()`, through a set the caller built once (F-261).
static func terrain_amplitudes_from_set(
	x: float, z: float, set: NoiseSet, world_seed: int, biome_defs: Array
) -> Vector2:
	return amplitudes_for(biome_at_from_set(x, z, set, world_seed, biome_defs), biome_defs)


## The two amplitudes for an ALREADY-RESOLVED biome id. Public because a caller that needs both the
## id and its amplitudes at one point — `tools/terrain_map_render.gd` shades every pixel by biome and
## then re-samples the surface at that biome's roughness — would otherwise resolve the biome twice
## (F-261).
static func amplitudes_for(id: StringName, biome_defs: Array) -> Vector2:
	for def_value: Variant in biome_defs:
		var def: Resource = def_value as Resource
		if def != null and StringName(String(def.get(&"id"))) == id:
			return Vector2(float(def.get(&"detail_amplitude")), float(def.get(&"ridge_amplitude")))
	return Vector2.ONE
