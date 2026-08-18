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


## Normalized 0..1 (FastNoiseLite's native -1..1 rescaled) — a separate noise field from
## IslandHeightmap's two layers so wet/dry pockets don't just trace the terrain's own shape.
static func moisture(x: float, z: float, world_seed: int) -> float:
	var noise := FastNoiseLite.new()
	noise.seed = world_seed ^ MOISTURE_NOISE_SALT
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = MOISTURE_NOISE_FREQUENCY
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = MOISTURE_NOISE_OCTAVES
	noise.fractal_lacunarity = MOISTURE_NOISE_LACUNARITY
	noise.fractal_gain = MOISTURE_NOISE_GAIN
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


## Convenience one-shot: height + moisture + assignment for one world sample point. Callers that
## already have the height (e.g. 4.3's chunk mesher, which needs it anyway to place vertices) should
## call assign() directly with that value instead of recomputing it here.
static func biome_at(x: float, z: float, world_seed: int, biome_defs: Array) -> StringName:
	var height: float = IslandHeightmap.height(x, z, world_seed)
	var moisture_value: float = moisture(x, z, world_seed)
	return assign(height, moisture_value, biome_defs)
