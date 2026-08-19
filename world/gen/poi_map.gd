class_name PoiMap
extends RefCounted

## Where every point of interest lands on one island — Wellsprings first, then landmarks. Pure and
## node-free, the same discipline as IslandHeightmap (4.1), BiomeMap (4.2) and ResourceScatter (4.4):
## same `(world_seed, content)` in, same sites out, on every peer and every platform, so a POI
## position is derived rather than replicated (ARCHITECTURE.md §4).
##
## Network authority: none. This is a function.
##
## POISSON-DISC HERE, JITTERED GRID THERE — and the contrast with D-083 is the interesting part.
## 4.4's resource scatter had to be generated PER CHUNK, independently, by peers that stream
## different chunks at different times; true Poisson-disc needs to see every previously accepted
## point, so it chose a jittered grid instead. POIs are the opposite shape: there are a few dozen per
## island, they are island-GLOBAL rather than per-chunk, and every peer generates the whole set at
## once from the shared seed. That makes real dart-throwing affordable and correct here, which
## matters because minimum spacing is the entire point of a POI layout — two Wellsprings 12 m apart
## is a broken island, while two bushes 12 m apart is a bush.
##
## DETERMINISM RULES this file obeys, all of them learned elsewhere in world/gen:
##   · integer multiply/xor seed mixing only, never Godot's `hash()` (4.4's header);
##   · defs are processed in SORTED id order, never Dictionary/directory-scan order, so the layout
##     cannot depend on how the content directory happened to enumerate (4.4's `point_id` lesson);
##   · every random draw comes from one RandomNumberGenerator seeded from `(world_seed, def id)` —
##     nothing here touches the global RNG.

const ISLAND_HEIGHTMAP := preload("res://world/gen/island_heightmap.gd")
const BIOME_MAP := preload("res://world/gen/biome_map.gd")

const SEED_SALT: int = 0x9017A11

## Bridson's k — darts thrown per placement attempt before giving up on a site. 30 is the paper's
## value and is comfortable here: the whole island is a few dozen points, so the cost is invisible
## and a higher k only buys a marginally more even layout.
const DARTS_PER_SITE: int = 30
## How many placement rounds a def gets before its target is declared unreachable. A def whose
## constraints exclude most of the island (a shore-only landmark on a mountainous seed) must not spin
## forever; it places what fits and the caller sees a short list, which `poi_check` asserts is
## reported honestly rather than padded.
const MAX_ROUNDS_PER_SITE: int = 24


## The one entry point. `poi_defs` and `biome_defs` are `Registry.poi_defs().values()` and
## `Registry.biomes.values()` — the same convention `BiomeMap.biome_at()` and
## `ResourceScatter.placements_for_chunk()` callers already follow.
##
## Returns, in placement order:
##   [{def_id: StringName, site_id: String, position: Vector3, rotation_y: float,
##     biome: StringName, scene_path: String, spacing: float, clearance: float}]
##
## `spacing` and `clearance` are the def's own two radii, carried on the site so `_too_close` can
## compare two kinds without holding the def list — and useful to a caller that wants to keep other
## content out of a POI's footprint (4.4's scatter is the obvious first one, and `clearance` is the
## number it wants).
##
## `position.y` is the terrain height at that point, so a caller can instance straight onto it.
static func sites_for_island(
	world_seed: int, poi_defs: Array, biome_defs: Array
) -> Array[Dictionary]:
	var sites: Array[Dictionary] = []
	for definition: Resource in _sorted_defs(poi_defs):
		_place_kind(definition, world_seed, biome_defs, sites)
	return sites


## Sorted by `placement_priority` then `id` — never by whatever order the Registry's Dictionary or
## the directory scan produced.
##
## Both halves are load-bearing, for different reasons. **Stability** (the `id` tie-break) is a
## determinism requirement: placement is order-dependent, so an unstable order means two peers
## generating different islands from the same seed — the one bug this subsystem exists to not have.
## **Priority** is a design requirement, and it was not obvious until measured: sorting by id alone
## placed the Wellspring last, because "wellspring" sorts after "shipwreck" and "standing_stones",
## and the nine landmarks already on the ground blocked it out of an island entirely on one seed.
## The objective places first now. D-095 records it; `tools/poi_check.gd` asserts every seed still
## gets a Wellspring, which is what caught it.
static func _sorted_defs(poi_defs: Array) -> Array:
	var defs: Array = []
	for definition: Variant in poi_defs:
		if definition is Resource and StringName(String((definition as Resource).get(&"id"))) != &"":
			defs.append(definition)
	defs.sort_custom(func(a: Resource, b: Resource) -> bool:
		var priority_a: int = int(a.get(&"placement_priority"))
		var priority_b: int = int(b.get(&"placement_priority"))
		if priority_a != priority_b:
			return priority_a < priority_b
		return String(a.get(&"id")) < String(b.get(&"id")))
	return defs


static func _place_kind(
	definition: Resource, world_seed: int, biome_defs: Array, sites: Array[Dictionary]
) -> void:
	var def_id := StringName(String(definition.get(&"id")))
	var target: int = int(definition.get(&"target_count"))
	if target <= 0:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = _kind_seed(world_seed, def_id)
	var placed_before: int = sites.size()
	_place_kind_pass(definition, world_seed, biome_defs, sites, rng, 0)

	# D-151: a REQUIRED kind that placed nothing gets the ladder, not a shrug. Each rung relaxes
	# one constraint family and reruns the same deterministic dart loop (the rng stream simply
	# continues, so every peer still computes the identical outcome). Rung 1 drops the terrain-fit
	# tests (slope, biome); rung 2 additionally opens height to "any land" and the radius band to
	# the whole disc. Spacing/clearance are never relaxed — two objectives fused together is the
	# one thing worse than a slightly-tilted one.
	if sites.size() == placed_before and bool(definition.get(&"required")):
		_place_kind_pass(definition, world_seed, biome_defs, sites, rng, 1)
		if sites.size() == placed_before:
			_place_kind_pass(definition, world_seed, biome_defs, sites, rng, 2)

	return


## One full dart-throwing pass at [param relax] level: 0 = the def's authored constraints exactly
## as before D-151; 1 = terrain-fit dropped (slope, biome); 2 = additionally any land above the
## waterline, anywhere on the disc. Spacing holds at every level.
static func _place_kind_pass(
	definition: Resource, world_seed: int, biome_defs: Array, sites: Array[Dictionary],
	rng: RandomNumberGenerator, relax: int
) -> void:
	var def_id := StringName(String(definition.get(&"id")))
	var target: int = int(definition.get(&"target_count"))
	var radius: float = ISLAND_HEIGHTMAP.ISLAND_RADIUS
	var placed: int = 0
	var rounds: int = 0
	while placed < target and rounds < MAX_ROUNDS_PER_SITE:
		rounds += 1
		var found: bool = false
		for dart: int in DARTS_PER_SITE:
			# Uniform over the disc: sqrt on the radius, or every layout crowds the centre. Drawn
			# BEFORE the constraint tests so a rejected dart still advances the RNG identically on
			# every peer — an early `continue` that skipped a draw would desync the stream.
			var angle: float = rng.randf() * TAU
			var distance_fraction: float = sqrt(rng.randf())
			var spin: float = rng.randf() * TAU
			var x: float = cos(angle) * distance_fraction * radius
			var z: float = sin(angle) * distance_fraction * radius

			if _too_close(x, z, definition, sites):
				continue
			var height: float = ISLAND_HEIGHTMAP.height(x, z, world_seed)
			if relax >= 2:
				if height < 0.5:
					continue
			else:
				var slope: float = _slope_at(x, z, world_seed, float(definition.get(&"flatness_probe_m")))
				if relax >= 1:
					# Height and radius still authored; slope/biome waived.
					if height < float(definition.get(&"height_min")) \
							or height > float(definition.get(&"height_max")):
						continue
				elif not bool(definition.call("accepts", height, slope, distance_fraction)):
					continue
				if relax == 0:
					var biome: StringName = BIOME_MAP.biome_at(x, z, world_seed, biome_defs)
					if not bool(definition.call("accepts_biome", biome)):
						continue

			placed += 1
			sites.append({
				"def_id": def_id,
				# Derived from the POSITION, not from array index — stable across peers regardless of
				# how many other defs happened to place first (4.4's own point_id reasoning).
				"site_id": "%s@%d,%d" % [def_id, roundi(x), roundi(z)],
				"position": Vector3(x, height, z),
				"rotation_y": spin,
				"biome": BIOME_MAP.biome_at(x, z, world_seed, biome_defs),
				"scene_path": String(definition.get(&"scene_path")),
				"spacing": float(definition.get(&"min_spacing_m")),
				"clearance": float(definition.get(&"clearance_m")),
			})
			found = true
			break
		if not found and rounds >= MAX_ROUNDS_PER_SITE:
			break
	return


## Checked against EVERY site already placed, but with two different rulers (D-095): `min_spacing_m`
## between two sites of the SAME kind, and the larger of the two defs' `clearance_m` between
## different kinds. Using one number for both is what crowded the island — see PoiDef's own note.
static func _too_close(x: float, z: float, definition: Resource, sites: Array[Dictionary]) -> bool:
	var own_id := StringName(String(definition.get(&"id")))
	var own_spacing: float = float(definition.get(&"min_spacing_m"))
	var own_clearance: float = float(definition.get(&"clearance_m"))
	for site: Dictionary in sites:
		var required: float = own_spacing if StringName(String(site["def_id"])) == own_id \
			else maxf(own_clearance, float(site.get("clearance", 0.0)))
		if required <= 0.0:
			continue
		var other: Vector3 = site["position"]
		var dx: float = other.x - x
		var dz: float = other.z - z
		if dx * dx + dz * dz < required * required:
			return true
	return false


## Max height difference between the centre and four probes around it. Cheap — five heightmap
## samples — and it is the difference between a Wellspring standing on ground and one wedged into a
## slope, which is a thing you can only otherwise find by looking.
static func _slope_at(x: float, z: float, world_seed: int, probe_m: float) -> float:
	var centre: float = ISLAND_HEIGHTMAP.height(x, z, world_seed)
	var worst: float = 0.0
	for offset: Vector2 in [
		Vector2(probe_m, 0.0), Vector2(-probe_m, 0.0),
		Vector2(0.0, probe_m), Vector2(0.0, -probe_m),
	]:
		var sample: float = ISLAND_HEIGHTMAP.height(x + offset.x, z + offset.y, world_seed)
		worst = maxf(worst, absf(sample - centre))
	return worst


## Integer multiply/xor only, so the result is identical under GDScript's fixed-width 64-bit `int` on
## every platform — no dependence on `hash()`'s implementation (the same rule ResourceScatter states).
static func _kind_seed(world_seed: int, def_id: StringName) -> int:
	const PRIME: int = 1000003
	var h: int = world_seed ^ SEED_SALT
	h = h * PRIME + _hash_id(def_id)
	return h


static func _hash_id(id: StringName) -> int:
	var h: int = 0x1000193
	for byte: int in String(id).to_utf8_buffer():
		h = (h ^ byte) * 16777619
	return h
