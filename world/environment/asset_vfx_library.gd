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
}

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
	## Hand-authored scenes name the placeholder mesh rather than the asset. Playtest Hollow
	## builds its fires this way, and any fixture someone assembles in the editor may too.
	["flame_outer", Emitter.CAMPFIRE],
	["furnace_fire", Emitter.FORGE],
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


## True if the asset has any presentation at all, so a caller can skip the expensive parts early.
static func is_animated(asset_id: String) -> bool:
	return sway_for(asset_id) != Sway.NONE or emitter_for(asset_id) != Emitter.NONE
