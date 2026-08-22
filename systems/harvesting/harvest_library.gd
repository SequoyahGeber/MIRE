class_name HarvestLibrary
extends RefCounted

## What an asset is worth hitting, decided from the asset alone.
##
## ## Why this file exists (F-114)
##
## Harvestability used to be authored per *placement*: `tools/mapgen/hollowmere_layout.py` passed
## `harvestable=True` on 83 props and `autoload/harvest_world.gd` carried a three-entry table of
## the three `assets/harvestables` exports. The result was a valley holding 62 trees, 198 rocks and
## 794 bushes that were painted scenery — you walked up to a pine, swung, and nothing happened.
##
## It is the same failure `world/environment/asset_vfx_library.gd` was written to end, and the
## reasoning is identical: **release worlds are procedurally generated**, so a layout file is not a
## place to record what a pine *is*. The only durable identity is the asset. Give this file an asset
## id and it answers what that asset yields; any world containing `tree_pine_c` gets a choppable
## pine the moment it stamps that id, with no layout flag, no map edit, and no code change here.
##
## ## The contract generators must honour
##
## Same one `AssetVfxLibrary` already has: stamp the asset id on the node you emit. A world builder
## additionally asks `representation_for()` how to *place* the prop — see the enum below.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2. This is content classification, identical on every peer and never
## sent. The harvest itself stays host-owned inside `systems/harvesting/harvestable.gd`.

## How a tool bites the world. Deliberately NOT the same axis as `WeaponDef.damage`: an iron pickaxe
## is the best weapon in the game against a rock and a poor one against a pine, and combat damage
## cannot express that. Mirrored as plain ints on `WeaponDef.tool_class` and
## `HarvestableDef.required_tool` — see `TOOL_NAMES` for the authoritative order, and note the .tres
## files store the integer, so never reorder these.
enum Tool {
	NONE,  ## Not a harvesting tool, and — on a harvestable — "anything will do": bushes, saplings.
	CHOP,  ## Axes. Wood: trees, saplings, stumps, fallen logs.
	MINE,  ## Pickaxes. Stone: boulders, rock clusters, ore nodes.
}

const TOOL_NAMES: PackedStringArray = ["none", "chop", "mine"]

## How a world builder should place this prop. The split exists for one reason and it is frame time:
## `world/gen/authored_world.gd` batches props into one `MultiMeshInstance3D` per (chunk, asset), and
## promoting all 794 bushes to their own `MeshInstance3D` would have traded a handful of draw calls
## for eight hundred on the machines this game is meant to run on.
enum Represent {
	## Its own holder with its own `Visual` mesh. Correct for anything with authored damage states
	## or a collider — trees, ore, boulders. A few hundred at most, and you stand right next to them.
	NODE,
	## Stays inside the chunk's `MultiMesh` batch; the holder carries logic and no mesh of its own.
	## Depletion hides the single instance by zeroing its transform, which is the only way to hide
	## one copy of a batch. Correct for dense soft flora — bushes, saplings — that has no collider
	## and no damage-state art.
	BATCH,
}

const DEFINITION_DIR: String = "res://content/harvestables/"

## Ordered longest-prefix-first, first match wins, exactly like `AssetVfxLibrary.SWAY_RULES`.
## An empty definition name means "explicitly inert": it stops a longer family rule below from
## claiming a prop that is already a depleted or damaged *decoration*, which would otherwise let you
## mine a rock that is drawn as an empty hole.
const HARVEST_RULES: Array = [
	## The three authored multi-state harvestables. Their damaged and depleted exports are placed as
	## scenery in their own right and must stay scenery.
	["harvest_tree_intact", "tree", Represent.NODE],
	["harvest_tree_damaged", "", Represent.NODE],
	["harvest_tree_felled_trunk", "fallen_log", Represent.NODE],
	["harvest_tree_fresh_stump", "stump", Represent.NODE],
	["harvest_tree_depleted_stump", "", Represent.NODE],
	["stone_node_intact", "stone_node", Represent.NODE],
	["stone_node_", "", Represent.NODE],
	["iron_node_intact", "iron_node", Represent.NODE],
	["iron_node_", "", Represent.NODE],
	## Task 3.18's tier-4 source. The definition ships ahead of its art (F-480): no export is named
	## `bogsilver_node_*` yet, so this rule currently claims nothing and the seam simply does not
	## appear in the world. That is correct data waiting, the same posture ITEMS.md §4.2 takes for a
	## drop authored ahead of its creature — and bogsilver is reachable meanwhile because a Wellspring
	## cap grants ore outright (content/loot/wellspring.tres `guaranteed`).
	["bogsilver_node_intact", "bogsilver_node", Represent.NODE],
	["bogsilver_node_", "", Represent.NODE],

	## Wood.
	["mire_broadleaf_tree", "wild_tree", Represent.NODE],
	["tree_", "wild_tree", Represent.NODE],
	["fallen_log", "fallen_log", Represent.NODE],
	["stump_", "stump", Represent.NODE],

	## Stone.
	["mire_mossy_boulder", "boulder", Represent.NODE],
	["boulder_", "boulder", Represent.NODE],
	["rock_cluster", "rock_cluster", Represent.NODE],

	## Sticks. Batched: hundreds of them, no collider, no damage states.
	["sapling", "sapling", Represent.BATCH],
	["bush_", "bush", Represent.BATCH],

	## Fibre (F-366). Same batched treatment as the sticks above, and bare-hands like them, because
	## this is the entry point of the whole tool tree: `wooden_axe` and `wooden_pickaxe` are both
	## `branch` + `fibre_bundle`, and until this rule existed NO harvestable in the game yielded
	## fibre — the only sources were a bog chest table and one hand-placed pickup in Playtest
	## Hollow's layout. On the procedural island that made both starter tools uncraftable, which
	## locked the player out of every `required_tool` 1 or 2 node forever. Reported from play as
	## "no way to harvest the base resources without tools and theres no way to craft tools without
	## base resouces".
	##
	## Two prefixes so both halves of the early game have a source: `nettle_*` is in
	## `content/scatter/forest_floor.tres`, and `sedge_*` is in `shore_beach.tres` — which matters
	## because the shore is where the player makes landfall.
	["nettle", "nettle", Represent.BATCH],
	["sedge_", "nettle", Represent.BATCH],
	## F-439: the `gatherables` kit's purpose-built fibre plant, which was modelled, exported and
	## catalogued and then referenced by nothing. It harvests as `nettle` rather than earning a
	## definition of its own — same yield, same bare-hands cost — because a second definition with
	## identical numbers is a second place to forget to change. What it adds is a source that reads
	## as fibre at a glance: `nettle_*` and `sedge_*` are flora-kit dressing that happen to be
	## harvestable, so the player learns them by accident, and the note above is about exactly the
	## kind of lockout that follows when fibre is hard to recognise.
	["fibre_plant", "nettle", Represent.BATCH],

	## Food (F-488). The `gatherables` kit shipped `apple_tree_*`, `berry_bush_*` and
	## `mushroom_patch_*` art alongside definitions in `content/harvestables/`, and then nothing
	## classified them — so even a placed one was scenery, and no scatter table placed one anyway.
	## All three are NODE despite the small ones being cheap-looking: each has authored picked art
	## (`*_picked`/`*_harvested`) and BATCH depletion can only hide an instance, which would read as
	## a bush vanishing when you pick a berry. Their scatter weights are kept low
	## (`content/scatter/*.tres`) so the count stays in NODE's budget.
	##
	## The picked/harvested exports are explicitly inert: they are the depleted state the definition
	## swaps in, and a scattered one is dressing, not a second berry bush.
	["apple_tree_full", "apple_tree", Represent.NODE],
	["apple_tree_", "", Represent.NODE],
	["berry_bush_full", "berry_bush", Represent.NODE],
	["berry_bush_", "", Represent.NODE],
	["mushroom_patch_full", "mushroom_patch", Represent.NODE],
	["mushroom_patch_", "", Represent.NODE],
]


## Resource path of the definition this asset harvests as, or "" when it is scenery.
static func definition_path_for(asset: StringName) -> String:
	var name := String(asset)
	for rule: Array in HARVEST_RULES:
		if name.begins_with(String(rule[0])):
			var definition := String(rule[1])
			return "" if definition.is_empty() else DEFINITION_DIR + definition + ".tres"
	return ""


static func is_harvestable(asset: StringName) -> bool:
	return not definition_path_for(asset).is_empty()


## NODE for anything this file does not batch, including scenery — a caller that asks about a prop
## it is not going to promote gets the answer that changes nothing about how it places it.
static func representation_for(asset: StringName) -> Represent:
	var name := String(asset)
	for rule: Array in HARVEST_RULES:
		if name.begins_with(String(rule[0])):
			return rule[2] as Represent
	return Represent.NODE


## Every distinct definition path this table can return, for content checks and preloading.
static func definition_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for rule: Array in HARVEST_RULES:
		var definition := String(rule[1])
		if definition.is_empty():
			continue
		var path := DEFINITION_DIR + definition + ".tres"
		if not paths.has(path):
			paths.append(path)
	return paths


static func tool_name(tool_class: int) -> String:
	if tool_class < 0 or tool_class >= TOOL_NAMES.size():
		return "?"
	return TOOL_NAMES[tool_class]
