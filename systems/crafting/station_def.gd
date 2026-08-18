class_name StationDef
extends Resource

## Static definition of one crafting station kind. Authored by hand as a .tres in
## content/stations/ — see ARCHITECTURE.md §3.1. `registry.gd` loads every .tres in that folder at
## boot and indexes it by `id`; `RecipeDef.station` references stations by this id, never by path.
##
## Network authority: none directly, same as RecipeDef/ItemDef — this is the station *definition*,
## identical on every peer. Which physical station a player is standing at is derived host-side from
## world proximity (CraftingService), never trusted from the client (ARCHITECTURE.md §2.2).

## Unique key, e.g. &"workbench" or &"furnace". What RecipeDef.station and craft requests reference.
@export var id: StringName = &""
@export var display_name: String = ""

## Matches the baked world asset this station appears as — `assets/crafting_stations/catalog.json`'s
## `name` field, and the suffix of the Hollowmere marker mapgen drops for it (`Station_<world_scene>`,
## `tools/mapgen/hollowmere_layout.py`). NOT a PackedScene: every station shipped so far is baked map
## art placed by world/gen (a MultiMeshInstance3D on Hollowmere, a plain node on Playtest Hollow),
## never a scene CraftingService instantiates. This is the identifier its host-side proximity check
## matches against — see CraftingService._station_in_range.
@export var world_scene: StringName = &""

## Crafting tier — DESIGN.md §4.3/§4.5 ("Tinker: ... station tiers"). Presentation and future
## unlock-gating only for now; resolving a recipe's station through Registry (rather than the bare
## string comparison 2.6 shipped) is what task 3.1 means by "the station-tier check" — a recipe whose
## station id does not resolve to a registered StationDef is rejected before the range check ever
## runs.
@export var tier: int = 1


## Same shape as LootTableDef's/PowerupDef's/BuildableDef's — registry.gd calls this before indexing
## and skips anything that fails, so a malformed .tres is a named boot error rather than a crash the
## first time a recipe tries to resolve its station.
func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if world_scene == &"":
		errors.append("world_scene is empty")
	if tier < 1:
		errors.append("tier must be at least 1")
	return errors
