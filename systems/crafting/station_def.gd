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

## Which station family this belongs to — the same grouping `assets/crafting_stations/catalog.json`
## already gives the art ("workbench", "fire", "forge", "repair", "wood"). Stations progress in
## families rather than as one flat set: the workbench is upgraded into the reinforced workbench, the
## furnace is followed by the anvil. `tier` orders the family; this names it.
##
## The rule the family exists to express (Sequoyah, 2026-08-21): THE FIRST TIER OF EVERY FAMILY MUST
## BE BUILDABLE FROM BASE GATHERED RESOURCES — log, branch, stone, fibre — never from a crafted
## intermediate and never from a loot or POI drop. A family whose entry point needs something the
## world may not hand out is a branch of progression that can fail to open at all; that is exactly
## how the forge branch shipped closed (F-487). tools/station_tier_check.gd enforces it.
@export var family: StringName = &""

## Crafting tier — DESIGN.md §4.3/§4.5 ("Tinker: ... station tiers"). Presentation and future
## unlock-gating only for now; resolving a recipe's station through Registry (rather than the bare
## string comparison 2.6 shipped) is what task 3.1 means by "the station-tier check" — a recipe whose
## station id does not resolve to a registered StationDef is rejected before the range check ever
## runs.
@export var tier: int = 1

## The station this one REPLACES — every recipe that station can make, this one can make too.
##
## F-575: `family` and `tier` alone cannot answer this, and reading them as if they could is the bug
## that made the first attempt at this fix wrong. A family is a themed progression, not a ladder of
## substitutes: `forge` runs furnace (1) then anvil (2) because the anvil is gated behind the
## furnace's output, but an anvil does not smelt ore, and `recipe_station_check.gd` (F-484) is
## explicit that smelting belongs at the furnace and smithing at the anvil. Inferring "tier 2
## satisfies tier 1" from the same data would have moved both ingot recipes onto the anvil.
##
## So substitution is DECLARED, never inferred. `workbench_upgraded` sets this to `workbench`
## because the Reinforced Workbench genuinely is a better bench; the anvil sets nothing, because it
## is a different tool that happens to come later. Chains resolve transitively, so a hypothetical
## tier-3 bench need only name the tier-2 one.
##
## Constrained rather than free-form: `tools/station_tier_check.gd` requires the named station to
## exist, to be in the same family, and to sit at a strictly lower tier — so this can express an
## upgrade and cannot express a shortcut across the progression.
@export var upgrades_from: StringName = &""


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
	if family == &"":
		errors.append("family is empty")
	if tier < 1:
		errors.append("tier must be at least 1")
	return errors
