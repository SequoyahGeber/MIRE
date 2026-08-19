class_name PoiDef
extends Resource

## One kind of point of interest — a Wellspring, a landmark, a ruin. Authored by hand as a .tres in
## content/poi/ and loaded by registry.gd at boot, like every other content family
## (ARCHITECTURE.md §3.1, §4 pipeline step 4 "POI placement").
##
## A PoiDef says WHAT may be placed and WHERE it is allowed; world/gen/poi_map.gd decides where each
## one actually lands. Splitting it that way is what makes a new landmark a .tres and nothing else.
##
## Network authority: none, same as every other content Def. Placement is derived from the shared
## world seed and this content, identically on every peer, so no POI position is ever sent over the
## wire (ARCHITECTURE.md §4 — the whole point of seed replication).

## Unique key, e.g. &"wellspring". Used as the placement RNG's salt, so renaming a def RE-ROLLS its
## placements — deliberate, and the reason ids are stable content rather than a display concern.
@export var id: StringName = &""
@export var display_name: String = ""

## What gets instanced at each site. Empty is legitimate and means "the caller knows what to build
## here": `Wellspring` is script-constructed rather than a packed scene (systems/wellspring/
## wellspring.gd builds its own visual from two GLB constants), and a def may also exist purely to
## RESERVE space — a plaza, a clearing — that other content must keep out of. poi_map.gd returns the
## site either way; only the instancing caller cares.
@export_file("*.tscn", "*.glb") var scene_path: String = ""

## What this site IS to the world services (task 4.15, D-143): the `kind` meta the composer stamps
## on the site's `authored_world_marker`. The vocabulary is the services' own — `objective`
## (WellspringService), `shipwreck` (ExtractionService), `enemy_nest` (EnemyWorld), plus the chest
## and `station` kinds — and an EMPTY value is legitimate scenery: a landmark that reserves space
## but answers to nobody. Content stays in charge of what a POI means; the composer stays a dumb
## loop. Authored maps ignore this field entirely (their generators place markers directly).
@export var marker_kind: StringName = &""
## The marker NODE NAME, for the two services whose contract is the name and not just the kind:
## ChestPlacementService reads the tier from a `Cache_*`/`Chest_<tier>_*` prefix, and
## CraftingService resolves the station asset from an exact `Station_<asset>` name. Empty keeps the
## composer's default (site id + "Marker"), which is fine for every kind-only consumer
## (objective/shipwreck). Collisions are impossible — each marker is the sole child of its own site
## root — so an exact name here is safe to repeat across sites (4.16, D-146).
@export var marker_name: String = ""

## Placement order when several kinds compete for the same island — LOWER goes first and therefore
## wins the good ground. Same convention as `BiomeDef.priority`, and it exists because sorting by id
## alone put the Wellspring LAST (alphabetically) and let six standing stones and three shipwrecks
## claim the island before the objective got a look in: on one measured seed that produced an island
## with ZERO Wellsprings. Ties break on `id`, which keeps placement deterministic. See D-095.
@export var placement_priority: int = 50

## A REQUIRED kind must land on EVERY island, whatever the seed hands it. The Wellspring is the
## run's objective and the shipwreck is its only exit — an island without either is not a harder
## island, it is a broken run, and 4.13's smaller island (118 m, 60 m height scale) produces real
## seeds where the authored constraints match no ground at all. When normal placement lands zero,
## poi_map.gd relaxes THIS def's terrain-fit constraints in documented steps rather than shipping
## an island with no game on it (D-151). Landmarks and caches leave this off: fewer of those on a
## hostile seed is flavour, not breakage.
@export var required: bool = false

@export_group("How many")
## Target count for one island. The generator places up to this many and reports what it achieved —
## a crowded island with tight spacing may fit fewer, which is a normal outcome, not a failure.
@export_range(0, 64, 1) var target_count: int = 1
## Metres, between two sites of THIS KIND. Four Wellsprings spread across an island want a big
## number here; six standing stones want a modest one.
@export_range(1.0, 512.0, 1.0) var min_spacing_m: float = 64.0
## Metres, between this site and a site of any OTHER kind. Deliberately separate from
## `min_spacing_m`, and much smaller by default: those two numbers answer different questions, and
## conflating them is measurably wrong. Wellsprings want 180 m from each other so they are spread
## across the island — but re-using that as the exclusion radius against everything else carved four
## 180 m holes out of the map and left one measured seed with no standing stones at all. A landmark
## 100 m from a Wellspring is not a problem; a second Wellspring there is. See D-095.
@export_range(0.0, 256.0, 1.0) var clearance_m: float = 24.0

@export_group("Where it may land")
## Empty means "any biome". Otherwise the site's biome (BiomeMap.biome_at) must be in this list.
@export var biomes: Array[StringName] = []
## Metres, in IslandHeightmap.height()'s units. A Wellspring wants to be above the waterline; a
## shipwreck wants to be at it.
@export var height_min: float = 0.0
@export var height_max: float = 1000.0
## Fraction of IslandHeightmap.ISLAND_RADIUS. Keeps a landmark off the very centre or the very edge
## without needing a metre figure that breaks the day the island is resized.
@export_range(0.0, 1.0, 0.01) var radius_min_fraction: float = 0.0
@export_range(0.0, 1.0, 0.01) var radius_max_fraction: float = 0.9

@export_group("Terrain fit")
## Metres of height change tolerated across `flatness_probe_m`. A Wellspring on a cliff edge is a
## Wellspring half-buried in rock; this is the cheap test that keeps it off one. 0 disables the test.
@export_range(0.0, 20.0, 0.1) var max_slope_m: float = 2.5
@export_range(0.5, 32.0, 0.5) var flatness_probe_m: float = 4.0


## Same shape as every other Def's validation_errors() — registry.gd calls it before indexing and
## skips anything that fails, so a malformed .tres is a named boot error rather than a POI kind that
## silently never appears on any island.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if height_min > height_max:
		errors.append("height_min (%f) is greater than height_max (%f)" % [height_min, height_max])
	if radius_min_fraction > radius_max_fraction:
		errors.append("radius_min_fraction (%f) is greater than radius_max_fraction (%f)"
			% [radius_min_fraction, radius_max_fraction])
	if not scene_path.is_empty() and not ResourceLoader.exists(scene_path):
		# A typo'd path is the single most likely authoring mistake here, and the symptom without
		# this check is an island that generates fine and is simply missing its landmark.
		errors.append("scene_path '%s' does not exist" % scene_path)
	return errors


## True if a candidate site's sampled terrain satisfies this def's own constraints. Biome is checked
## by the caller, which is the only side holding the biome def list.
func accepts(height: float, slope: float, radius_fraction: float) -> bool:
	if height < height_min or height > height_max:
		return false
	if radius_fraction < radius_min_fraction or radius_fraction > radius_max_fraction:
		return false
	if max_slope_m > 0.0 and slope > max_slope_m:
		return false
	return true


func accepts_biome(biome_id: StringName) -> bool:
	return biomes.is_empty() or biomes.has(biome_id)
