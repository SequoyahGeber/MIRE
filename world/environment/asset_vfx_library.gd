class_name AssetVfxLibrary
extends RefCounted

## Which VFX an asset carries, decided from the asset alone.
##
## ## Why this file exists (F-097)
##
## The first environmental VFX pass discovered what to animate by walking the level for
## `MeshInstance3D` nodes whose *node names* contained "grass" or "flame_outer". That worked on
## Playtest Hollow and reached **exactly nothing** on Hollowmere, because both world generators
## emit `MultiMeshInstance3D` batches instead — 1,740 of them holding 13,026 copies, all invisible
## to a walk keyed on the wrong node type. It was F-076's failure a second time: a system keyed to
## one map's representation, silently dead on the next map.
##
## **Release worlds are procedurally generated.** A level is not a stable thing to bind behaviour
## to, and neither is a node name a level author happened to choose. The only durable identity is
## the asset itself, so that is what this file keys on: give it an asset id — `station_campfire`,
## `grass_tuft_a` — and it returns what that asset does, with no reference to any scene, map,
## layout or node. Any world containing a campfire gets firelight; that is the whole contract.
##
## ## The contract generators must honour
##
## A generator stamps `EnvironmentVfx.ASSET_META` on every node it emits, holding the asset id.
## `world/gen/authored_world.gd` and `world/gen/undergrowth.gd` do this today; the future world
## generator must do the same, and gets every effect here for free the moment it does.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2, "VFX, audio, camera, UI" row. Every peer classifies locally from
## the same asset ids and nothing crosses the wire. Two peers on different graphics presets see
## different numbers of campfire lights and simulate identically.

## F-391: `impact_for_tool()` maps a harvestable's `required_tool` onto a destruction material, so
## this file needs that enum. Preloaded by path rather than named as `HarvestLibrary`, the same rule
## every other file here follows — a `class_name` only enters the global script class cache when the
## editor rescans the project, and `agent godot` is always a headless `--script` run that never does.
const HARVEST_LIB := preload("res://systems/harvesting/harvest_library.gd")

## How an asset moves in wind. The enum is the asset-facing vocabulary; `SWAY_PROFILES` holds the
## numbers, so retuning the look never touches the classification.
enum Sway {
	NONE,          ## Rigid: stone, timber, ruins, dead snags, anything flat on the ground.
	GROUND_COVER,  ## Short and dense — grass, clover. Small, quick, high-frequency rustle.
	FROND,         ## Ferns, bracken, nettles, broad low leaves. Softer and slower than grass.
	BUSH,          ## Woody and stiff at the base, loose at the top.
	REED,          ## Tall, thin, water-rooted. The largest lateral travel of anything here.
	FLOWER,        ## Slender stems with weight on top; quick, light nodding.
	SAPLING,       ## A young trunk that bends along its whole length.
	CANOPY,        ## Mature trees. Slow and small — the trunk holds, the crown drifts.
	TENDRIL,       ## Mire growth. Slow, wrong-looking, unsynchronised with the honest plants.
	FLOAT,         ## Lily pads. Bobs vertically on water instead of leaning.
}

## What flies off an asset when something breaks it (F-391). Deliberately a SEPARATE axis from
## `Emitter`: every one of those is ambient and pooled — it exists because the asset is standing
## there — while this one is fired from a gameplay event and lasts under two seconds. Harvesting a
## node used to produce no impact feedback at all, reported from play as "the destruction partials
## either dont work or look bad as well"; the swap to a depleted stump was the whole of it.
enum Impact {
	NONE,
	WOOD,     ## Trees, saplings, stumps, felled logs: pale splinters and a thin puff of sawdust.
	STONE,    ## Boulders, rock clusters, ore nodes: hard grey chips and a heavier dust cloud.
	FOLIAGE,  ## Soft growth — bushes, nettles, sedge: torn leaf, no dust and no hard fragments.
}

## A light/particle effect the asset carries. Budgeted at runtime by distance — see
## `EMITTER_PROFILES.max_live` — because a generated world may contain any number of them.
enum Emitter {
	NONE,
	CAMPFIRE,  ## Open fire: flame, sparks, smoke, and a flickering warm light.
	FORGE,     ## Contained fire in stone: shorter flame, more smoke, no loose sparks.
	EMBER,     ## Small cooking fire: low flame and a close warm light, no smoke plume.
	CRYSTAL,   ## Mire crystal: cold light and slow rising motes.
	SPORE,     ## Mire tendril: drifting motes, no light at all.
	GLOW,      ## Emissive material only — no light, no particles, no per-instance node.
	LEAF_FALL, ## A living canopy shedding leaves. No light, no shadows — the cheapest emitter here.
}

## `strength` is metres of lateral travel at the top of the asset; `speed` is radians/second of the
## base oscillation; `mask_power` shapes how fast motion falls off toward the root (higher = a
## stiffer base and a looser tip); `vertex_phase` is how much of the wave's phase comes from the
## vertex's own world position rather than the object's origin.
##
## `bob` is vertical travel in metres and defaults to 0 — only floating assets use it.
##
## `vertex_phase` is the seam that survives F-098's static chunk batching. Phase taken from
## `MODEL_MATRIX[3]` is per-instance while an asset is a MultiMesh, but collapses to *per chunk*
## the moment instances are merged into one static mesh — a whole hillside would then sway as one
## object. Reading phase from world-space vertex position instead stays per-plant through any
## merge. Small assets use it freely; a tree cannot, because a phase that varies across a 8 m
## crown shears the crown instead of leaning it.
const SWAY_PROFILES: Dictionary = {
	Sway.GROUND_COVER: {"strength": 0.055, "speed": 2.05, "mask_power": 1.0, "vertex_phase": 1.0},
	Sway.FROND:        {"strength": 0.085, "speed": 1.45, "mask_power": 1.2, "vertex_phase": 1.0},
	Sway.BUSH:         {"strength": 0.050, "speed": 1.15, "mask_power": 2.0, "vertex_phase": 0.6},
	Sway.REED:         {"strength": 0.150, "speed": 1.70, "mask_power": 1.0, "vertex_phase": 1.0},
	Sway.FLOWER:       {"strength": 0.075, "speed": 1.90, "mask_power": 1.4, "vertex_phase": 1.0},
	Sway.SAPLING:      {"strength": 0.090, "speed": 1.05, "mask_power": 1.6, "vertex_phase": 0.4},
	Sway.CANOPY:       {"strength": 0.055, "speed": 0.62, "mask_power": 2.6, "vertex_phase": 0.0},
	Sway.TENDRIL:      {"strength": 0.070, "speed": 0.48, "mask_power": 1.3, "vertex_phase": 0.8},
	Sway.FLOAT:        {"strength": 0.020, "speed": 0.85, "mask_power": 0.0, "vertex_phase": 1.0,
		"bob": 0.035},
}

## `max_live` is how many of this emitter may run particles and a light at once, nearest first.
## `shadow_live` is how many of those may also cast shadows — the single most expensive thing an
## omni light can do, so it is counted separately and kept tiny. Both are scaled by the graphics
## preset at runtime (`EnvironmentVfx._budget_scale`).
##
## The numbers are chosen against a generated world, not against Hollowmere's census. Hollowmere
## happens to hold 5 fires, 99 mire crystals and 163 tendrils; the crystals are why an emitter
## budget exists at all, since 99 shadowed omni lights would sink a low-end GPU on their own.
const EMITTER_PROFILES: Dictionary = {
	Emitter.CAMPFIRE: {"max_live": 6, "shadow_live": 2, "radius": 5.5},
	Emitter.FORGE:    {"max_live": 4, "shadow_live": 1, "radius": 4.5},
	Emitter.EMBER:    {"max_live": 4, "shadow_live": 1, "radius": 3.4},
	Emitter.CRYSTAL:  {"max_live": 8, "shadow_live": 0, "radius": 4.0},
	Emitter.SPORE:    {"max_live": 10, "shadow_live": 0, "radius": 0.0},
	Emitter.GLOW:     {"max_live": 0, "shadow_live": 0, "radius": 0.0},
	## The most numerous emitter by an order of magnitude — Hollowmere has 113 trees and a
	## generated forest could have thousands — so the budget is what makes it affordable, not the
	## per-emitter cost. Nearest first, no light and no shadow: at that point one slot is a single
	## small GPUParticles3D and the whole class costs less than two campfires.
	##
	## F-376 cut this from 12 to 7. Twelve live crowns times `EnvironmentVfx`'s twelve leaves each
	## put up to 144 leaves in the air around the player, and play reported "way too many spawn".
	## The per-emitter count came down with it (`EnvironmentVfx.LEAF_FALL_AMOUNT`), so a walk
	## through the forest now shows about 35 leaves at once rather than 144 — which is what "the
	## one effect whose job is to be barely noticed" was always supposed to look like.
	Emitter.LEAF_FALL: {"max_live": 7, "shadow_live": 0, "radius": 0.0},
}

## What each destruction class throws off, in the same shape `EMITTER_PROFILES` uses: the
## classification above is the asset-facing vocabulary, the numbers live here, and retuning the look
## never touches which asset is made of what.
##
## `chip_*` is the solid fragment — splinters, stone flakes, torn leaf. `dust_*` is the soft cloud
## that hangs after it; `dust_amount` 0 means the material does not make one, which is correct for
## foliage and would read as smoke if it did.
const IMPACT_PROFILES: Dictionary = {
	Impact.WOOD: {
		"chip_amount": 16, "chip_life": 0.9, "chip_size": Vector2(0.075, 0.032),
		"chip_color": Color(0.60, 0.44, 0.24, 1.0),
		"chip_speed_min": 1.5, "chip_speed_max": 4.0, "origin_radius": 0.20,
		"dust_amount": 5, "dust_life": 0.85, "dust_size": Vector2(0.30, 0.30),
		"dust_color": Color(0.46, 0.38, 0.26, 0.30), "dust_rise": 0.55,
	},
	Impact.STONE: {
		"chip_amount": 20, "chip_life": 0.75, "chip_size": Vector2(0.05, 0.034),
		"chip_color": Color(0.55, 0.54, 0.51, 1.0),
		"chip_speed_min": 2.0, "chip_speed_max": 5.2, "origin_radius": 0.18,
		"dust_amount": 9, "dust_life": 1.25, "dust_size": Vector2(0.42, 0.42),
		"dust_color": Color(0.62, 0.60, 0.55, 0.38), "dust_rise": 0.75,
	},
	Impact.FOLIAGE: {
		"chip_amount": 12, "chip_life": 1.15, "chip_size": Vector2(0.085, 0.05),
		"chip_color": Color(0.36, 0.48, 0.20, 1.0),
		"chip_speed_min": 0.9, "chip_speed_max": 2.4, "origin_radius": 0.26,
		"dust_amount": 0, "dust_life": 0.0, "dust_size": Vector2(0.2, 0.2),
		"dust_color": Color(0.0, 0.0, 0.0, 0.0), "dust_rise": 0.0,
	},
}

## Assets whose own mesh is a PLACEHOLDER that the effect replaces, rather than something the
## effect decorates. Hand-authored scenes name a stand-in mesh where a fire should go and expect it
## to disappear; a tree very much does not (F-118 — without this list, giving canopies an emitter
## made `EnvironmentVfx` hide every tree on the map that was not instanced through a MultiMesh).
const PLACEHOLDER_ASSETS: PackedStringArray = ["flame_outer", "furnace_fire"]

## Ordered longest-prefix-first, because `marsh_grass_a` must not be caught by `grass_`.
## First match wins; anything unmatched is rigid, which is the correct default for a kit that is
## mostly stone, timber and ruins.
const SWAY_RULES: Array = [
	["marsh_grass", Sway.REED],
	["reeds", Sway.REED],
	["sedge", Sway.REED],
	["grass_", Sway.GROUND_COVER],
	["clover_patch", Sway.GROUND_COVER],
	["plant_creeper", Sway.GROUND_COVER],
	["flowers_", Sway.FLOWER],
	["bracken", Sway.FROND],
	["fern", Sway.FROND],
	["nettle", Sway.FROND],
	["plant_dock", Sway.FROND],
	["plant_broadleaf", Sway.FROND],
	["bush_", Sway.BUSH],
	["sapling", Sway.SAPLING],
	["lily_pad", Sway.FLOAT],
	["mire_tendril", Sway.TENDRIL],
	["tree_snag", Sway.NONE],       ## Dead standing timber — reads wrong if it moves.
	["tree_", Sway.CANOPY],
	["mire_broadleaf_tree", Sway.CANOPY],
	["harvest_tree_intact", Sway.CANOPY],
	["harvest_tree_damaged", Sway.CANOPY],
]

const EMITTER_RULES: Array = [
	["station_campfire", Emitter.CAMPFIRE],
	["station_stone_furnace", Emitter.FORGE],
	["station_cooking_spit", Emitter.EMBER],
	["wellspring_crystal", Emitter.CRYSTAL],
	["ward_activation_crystal", Emitter.CRYSTAL],
	["mire_crystal", Emitter.CRYSTAL],
	["mire_tendril", Emitter.SPORE],
	["mushroom_cluster", Emitter.GLOW],
	## Canopies shed; dead timber, bare winter trunks, stumps and felled logs do not. The NONE rules
	## come first because matching is longest-prefix-first-wins, and `tree_snag_a` would otherwise
	## be caught by `tree_`.
	["tree_snag", Emitter.NONE],
	["tree_bare", Emitter.NONE],
	["tree_", Emitter.LEAF_FALL],
	["mire_broadleaf_tree", Emitter.LEAF_FALL],
	["harvest_tree_depleted_stump", Emitter.NONE],
	["harvest_tree_fresh_stump", Emitter.NONE],
	["harvest_tree_felled_trunk", Emitter.NONE],
	["harvest_tree_", Emitter.LEAF_FALL],
	## Hand-authored scenes name the placeholder mesh rather than the asset. Playtest Hollow
	## builds its fires this way, and any fixture someone assembles in the editor may too.
	["flame_outer", Emitter.CAMPFIRE],
	["furnace_fire", Emitter.FORGE],
]

## F-391. Same longest-prefix-first-wins table as everything else here, and deliberately keyed on the
## asset rather than on the tool that happens to be swinging: the asset is what is being destroyed.
## `impact_for_tool()` below is the fallback for an asset no rule names yet, so a generated world
## containing a species this table has never heard of still throws the right kind of debris.
const IMPACT_RULES: Array = [
	## Wood. The three authored harvest states first, for the same reason the emitter table orders
	## them first — `harvest_tree_` would otherwise never be reached past `tree_`.
	["harvest_tree_", Impact.WOOD],
	["mire_broadleaf_tree", Impact.WOOD],
	["tree_", Impact.WOOD],
	["sapling", Impact.WOOD],
	["stump_", Impact.WOOD],
	["fallen_log", Impact.WOOD],

	## Stone.
	["mire_mossy_boulder", Impact.STONE],
	["boulder_", Impact.STONE],
	["rock_cluster", Impact.STONE],
	["stone_node", Impact.STONE],
	["iron_node", Impact.STONE],
	["mire_crystal", Impact.STONE],

	## Soft growth — every batched harvestable in `HarvestLibrary.HARVEST_RULES`.
	["bush_", Impact.FOLIAGE],
	["nettle", Impact.FOLIAGE],
	["sedge_", Impact.FOLIAGE],
	["bracken", Impact.FOLIAGE],
	["fern", Impact.FOLIAGE],
]


## What this asset does. `asset_id` is the bare export name — `grass_tuft_a`, `station_campfire` —
## with no kit, path or extension.
static func sway_for(asset_id: String) -> Sway:
	var id := asset_id.to_lower()
	for rule: Array in SWAY_RULES:
		if id.begins_with(String(rule[0])):
			return rule[1] as Sway
	return Sway.NONE


static func emitter_for(asset_id: String) -> Emitter:
	var id := asset_id.to_lower()
	for rule: Array in EMITTER_RULES:
		if id.begins_with(String(rule[0])):
			return rule[1] as Emitter
	return Emitter.NONE


static func sway_profile(sway: Sway) -> Dictionary:
	return SWAY_PROFILES.get(sway, {}) as Dictionary


static func emitter_profile(emitter: Emitter) -> Dictionary:
	return EMITTER_PROFILES.get(emitter, {}) as Dictionary


## What this asset throws off when it is broken (F-391).
static func impact_for(asset_id: String) -> Impact:
	var id := asset_id.to_lower()
	for rule: Array in IMPACT_RULES:
		if id.begins_with(String(rule[0])):
			return rule[1] as Impact
	return Impact.NONE


## The fallback classification for an asset `IMPACT_RULES` does not name: the tool the harvestable
## demands already says what it is made of, because that is the whole content of `HarvestLibrary`'s
## tool axis — an axe is for wood and a pickaxe is for stone. `Tool.NONE` ("anything will do") is
## what every soft batched prop uses, so it maps to foliage rather than to nothing.
##
## Takes the plain int the definition stores rather than the enum, exactly as `HarvestableDef`
## does — `HARVEST_LIB` is preloaded by path for the usual reason (a `class_name` is invisible to a
## headless `--script` run until the editor rescans the project, F-093's family).
static func impact_for_tool(tool_class: int) -> Impact:
	match tool_class:
		HARVEST_LIB.Tool.CHOP:
			return Impact.WOOD
		HARVEST_LIB.Tool.MINE:
			return Impact.STONE
		HARVEST_LIB.Tool.NONE:
			return Impact.FOLIAGE
	return Impact.NONE


static func impact_profile(impact: Impact) -> Dictionary:
	return IMPACT_PROFILES.get(impact, {}) as Dictionary


## True when this asset's own mesh is a stand-in the effect takes the place of. See
## `PLACEHOLDER_ASSETS`.
static func replaces_host_mesh(asset_id: String) -> bool:
	var id := asset_id.to_lower()
	for placeholder: String in PLACEHOLDER_ASSETS:
		if id.begins_with(placeholder):
			return true
	return false


## True if the asset has any presentation at all, so a caller can skip the expensive parts early.
static func is_animated(asset_id: String) -> bool:
	return sway_for(asset_id) != Sway.NONE or emitter_for(asset_id) != Emitter.NONE
