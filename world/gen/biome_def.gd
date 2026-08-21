class_name BiomeDef
extends Resource

## Static definition of one biome kind. Authored by hand as a .tres in content/biomes/ — see
## ARCHITECTURE.md §3's project structure ("world/gen/ — island generation, biome placement, POI
## scatter") and §4 pipeline step 2 ("biome assignment from height + moisture noise"). registry.gd
## loads every .tres in that folder at boot and indexes it by `id`; world/gen/biome_map.gd resolves
## a sample point's biome by testing every registered BiomeDef's range and picking the best match —
## see that file for the resolution rule.
##
## Network authority: none — same as every other content Def (ItemDef, RecipeDef, ...). Every peer
## loads the same content/biomes/*.tres files and derives the identical biome for the identical
## (x, z, world_seed), so nothing about a biome assignment is ever sent over the network.

## Unique key, e.g. &"shore" or &"forest". Never sent over the network directly — only used to look
## up scatter tables, ground materials etc. locally on every peer (future tasks: 4.4, 4.10).
@export var id: StringName = &""
@export var display_name: String = ""

@export_group("Height range")
## Metres of CONTINENTAL height — `IslandHeightmap.continent()`, not `height()`. Inclusive bounds.
##
## D-144: since 4.13 a BiomeDef carries terrain amplitudes, so the full surface `height()` depends on
## which biome a point is in, and picking the biome from it would pick it from a surface the biome
## itself shaped. The continent is the biome-INDEPENDENT half, so that is what `BiomeMap.biome_at()`
## tests these bounds against. The practical consequence when authoring: these numbers are the bare
## landmass, BELOW whatever metres this biome's own detail and ridge amplitudes then add on top.
##
## `PoiDef.height_min`/`height_max` are documented in the same word, "metres", and mean something
## different — the full surface height of the ground the landmark stands on (D-163). Do not tune one
## against the other's values.
##
## Overlapping another biome's range is allowed on purpose (see priority below); a real island has
## soft transitions, not walls.
@export var height_min: float = -1000.0
@export var height_max: float = 1000.0

@export_group("Moisture range")
## Normalized 0..1 — BiomeMap.moisture()'s own output range. Inclusive bounds.
@export_range(0.0, 1.0, 0.01) var moisture_min: float = 0.0
@export_range(0.0, 1.0, 0.01) var moisture_max: float = 1.0

## Resolution order when more than one biome's ranges contain the same sample point — LOWER runs
## first and wins. Ties (equal priority, both ranges contain the point) break on `id` alphabetically,
## which is arbitrary but deterministic — every peer computes it identically off the same content, so
## "arbitrary" costs nothing here. Shore's low priority is what lets it win at sea level even though a
## sloppy grassland/forest range reaching down to 0m would otherwise compete for the same band.
@export var priority: int = 10

@export_group("Terrain")
## How rough this biome's ground is, as multipliers on the two layers
## `IslandHeightmap` adds on top of the continent. The continent itself is NOT
## scaled here and cannot be: `BiomeMap` reads it to decide which biome a point
## is in, so a biome that moved the continent would be choosing where it lives
## (D-144). A shore is flat because its multipliers are near zero, not because
## the island is lower there.
@export_range(0.0, 4.0, 0.05) var detail_amplitude: float = 1.0
## Ridged crests, and the reason a mountain biome looks like mountains. Masked by
## continental height as well, so a high `ridge_amplitude` in a lowland biome
## still produces lowland — the mask and the table have to agree before a crest
## appears anywhere.
@export_range(0.0, 4.0, 0.05) var ridge_amplitude: float = 1.0

@export_group("Look")
## This biome's ground colour, authored in sRGB — the value a colour picker shows, not a linear
## radiance. `world/chunk/chunk_mesher.gd` runs it through `Color.srgb_to_linear()` on its way into
## the chunk mesh's vertex colours, so authoring one here is the same act as picking a swatch out of
## `tools/blender/mire_art.py`'s palette, and the two stay comparable by eye.
##
## F-379: until this existed the whole island was ONE colour. `ChunkStreamer` set a single
## `albedo_color` uniform on the shared terrain material and biomes differed only in
## `detail_amplitude`/`ridge_amplitude`, so ground, canopy and every lit prop sat in the same narrow
## yellow-green band and nothing separated from anything else — Sequoyah's "game looks to
## green/yellow". The three shipped biomes now differ in HUE and in VALUE, not only in roughness.
##
## The constraint when authoring a new one: the canopy is `mire_art`'s `leaf`, #59AF65 — a bright,
## saturated, mid-green — and it is what every ground colour is seen against. A biome that lands at
## that value with that chroma puts the flat back, however different its roughness is. What the
## three shipped biomes do about that, and why each is the value it is:
##
##   · `shore`     #918A78  pale grey-sand. The lightest ground on the map, so the island has a
##                          visible EDGE — before this the beach was the same green as the interior
##                          and the waterline was a shape, not a shore.
##   · `grassland` #616B4F  muted meadow. Still green, because it is a meadow, but half the chroma
##                          of the old single value and well below the canopy in brightness, so a
##                          tree reads as a lighter shape against the field it stands in rather than
##                          as the same colour with a shadow under it.
##   · `forest`    #474338  dark neutral humus. Under a closed canopy the ground is leaf litter, not
##                          grass. It is the darkest ground on the map and the reason a forest reads
##                          as a forest from outside it.
##
## Three VALUES first (0.57 / 0.42 / 0.28 sRGB), hue second, and that ordering is deliberate: the
## terrain is flat-shaded with no texture and no normal map (D-184), so value is the only thing
## carrying form at distance, and three biomes at one value is one silhouette however they differ in
## hue. The green sits in the MIDDLE of that ladder with a neutral at either end, which is what
## stops the whole ladder reading as one ramp.
##
## And all three are LOW CHROMA on purpose. The light is warm and the grade multiplies saturation by
## 1.30 (`playtest_atmosphere.gd`), so whatever chroma the ground has is amplified and then tinted
## toward the sun — a first cut of this fix used a warm brown forest floor (#4E4534) and golden hour
## came back a flat orange, which is F-379 again with the hue moved rather than fixed. Warm light
## needs ground that is not itself warm and saturated, or there is nothing for it to be warm
## AGAINST.
##
## Blended, not picked, at the biome boundary: `ChunkMesher` weighs every biome's colour by the same
## `BiomeMap._band_weight()` crossfade that `blend_amplitudes()` weighs the roughness by, so the
## colour transition and the roughness transition land on the same contour instead of a hue wall
## next to a slope.
@export var ground_albedo: Color = Color(0.26, 0.40, 0.19)


## Same shape as every other Def's validation_errors() — registry.gd calls this before indexing and
## skips anything that fails, so a malformed .tres is a named boot error, not a silent hole in the
## island's biome coverage.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if height_min > height_max:
		errors.append("height_min (%f) is greater than height_max (%f)" % [height_min, height_max])
	if moisture_min > moisture_max:
		errors.append("moisture_min (%f) is greater than moisture_max (%f)" % [moisture_min, moisture_max])
	return errors


## True if (height, moisture) falls inside this biome's range, inclusive on both ends.
func contains(height: float, moisture_value: float) -> bool:
	return height >= height_min and height <= height_max \
		and moisture_value >= moisture_min and moisture_value <= moisture_max
