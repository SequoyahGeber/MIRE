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
## Metres, in IslandHeightmap.height()'s own units — inclusive bounds. Overlapping another biome's
## range is allowed on purpose (see priority below); a real island has soft transitions, not walls.
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
