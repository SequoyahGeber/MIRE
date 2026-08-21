class_name HarvestableDef
extends Resource

## Static content for one harvestable kind. Author this as a .tres in the inspector; runtime health,
## depletion and respawn state live on Harvestable, never on this shared Resource.
##
## Network authority: none. The definition is immutable content loaded identically on every peer.
## Harvestable sends only small state values and item ids over the network.

const HARVEST_LIBRARY := preload("res://systems/harvesting/harvest_library.gd")

@export var id: StringName = &""

## What the world prompt calls this prop when the player looks at it (`ui/hud/focus_prompt.gd`).
## Empty falls back to the id with underscores opened out and each word capitalised, so a new
## definition is never nameless on screen — but author it, because "Iron Node" is not "Iron Vein".
@export var display_name: String = ""

## Authored in TOOL POWER, not in weapon damage (F-113). One swing of the tool this prop is meant
## for lands `WeaponDef.harvest_power` — 1 for a wooden tool, 2 for stone, 3 for iron — so a
## `max_health` of 6 is "three swings of a stone axe, two of an iron one", and stays that sentence
## no matter how combat damage is retuned for enemies later.
@export_range(1, 100000, 1) var max_health: int = 6

## Which tool class actually bites this. `Tool.NONE` means anything does, including bare hands, and
## is what a bush or a sapling wants. Stored as the integer from `HarvestLibrary.Tool` — never
## reorder that enum.
@export_enum("Any:0", "Chop:1", "Mine:2") var required_tool: int = 0

## What the WRONG tool class achieves, as a fraction of its harvest power, floored. At the default
## 0.34 an iron pickaxe (power 3) still worries a tree down in six swings while bare hands and any
## wooden tool (power 1) floor to zero and never will — which is the readable version of "you need
## an axe for this", without a tutorial. Set to 0.0 to make the wrong tool useless outright.
@export_range(0.0, 1.0, 0.01) var wrong_tool_scale: float = 0.34

## Used only by request_hit(), the parameterless convenience path. Clients never provide a damage
## value; the host reads this trusted definition. Host-owned combat instead calls
## `Harvestable.host_apply_tool_damage()` with its own validated weapon, which is the path a real
## swing takes.
@export_range(1, 100000, 1) var damage_per_hit: int = 1

@export var yield_item_id: StringName = &""
@export_range(1, 100000, 1) var yield_amount: int = 1
@export_range(0.01, 3600.0, 0.01, "or_greater") var respawn_seconds: float = 300.0

## Validation for the convenience client request. Task 2.8's host-owned hitbox path bypasses this
## request and calls host_apply_damage() only after it has validated the attack itself.
@export_range(0.5, 20.0, 0.1, "or_greater") var request_range_m: float = 4.0
@export_range(0.0, 2.0, 0.01, "or_greater") var request_cooldown_seconds: float = 0.25

## Intact first, then progressively more damaged presentations. Health is divided evenly across the
## array. The optional depleted scene remains visible while collision and harvesting are disabled;
## with no depleted scene, depletion is a full visual despawn.
##
## **Empty is a supported and now common case (F-114):** it means *this asset is its own intact
## visual*. Harvestable then leaves whatever the world builder already drew in place and only hides
## it on depletion. That is what lets ONE definition cover the 62 wild trees or the 794 bushes a
## generated world may contain, instead of demanding a three-state Blender export per species.
@export var active_state_scenes: Array[PackedScene] = []
@export var depleted_scene: PackedScene


## Damage one swing of `tool_class` at `harvest_power` does to this prop. The floor is deliberate:
## an under-powered wrong-class tool reaches exactly 0 and can never chip the prop down over time.
func damage_from_tool(tool_class: int, harvest_power: int) -> int:
	if harvest_power <= 0:
		return 0
	if required_tool == HARVEST_LIBRARY.Tool.NONE or tool_class == required_tool:
		return harvest_power
	return floori(float(harvest_power) * wrong_tool_scale)


## Title for the look-at prompt. See `display_name` for why the fallback exists.
func label() -> String:
	if not display_name.is_empty():
		return display_name
	return String(id).replace("_", " ").capitalize()


## True when this prop draws itself from the world builder's own geometry rather than from
## `active_state_scenes`. See that property.
func uses_authored_visual() -> bool:
	return active_state_scenes.is_empty()


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if max_health <= 0:
		errors.append("max_health must be positive")
	if damage_per_hit <= 0:
		errors.append("damage_per_hit must be positive")
	if yield_item_id == &"":
		errors.append("yield_item_id is empty")
	if yield_amount <= 0:
		errors.append("yield_amount must be positive")
	if respawn_seconds <= 0.0:
		errors.append("respawn_seconds must be positive")
	if request_range_m <= 0.0:
		errors.append("request_range_m must be positive")
	if request_cooldown_seconds < 0.0:
		errors.append("request_cooldown_seconds cannot be negative")
	if required_tool < 0 or required_tool >= HARVEST_LIBRARY.TOOL_NAMES.size():
		errors.append("required_tool %d is not a HarvestLibrary.Tool" % required_tool)
	for index: int in active_state_scenes.size():
		if active_state_scenes[index] == null:
			errors.append("active_state_scenes[%d] is empty" % index)
	return errors
