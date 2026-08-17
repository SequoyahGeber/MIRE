class_name HarvestableDef
extends Resource

## Static content for one harvestable kind. Author this as a .tres in the inspector; runtime health,
## depletion and respawn state live on Harvestable, never on this shared Resource.
##
## Network authority: none. The definition is immutable content loaded identically on every peer.
## Harvestable sends only small state values and item ids over the network.

@export var id: StringName = &""
@export_range(1, 100000, 1) var max_health: int = 3

## Used only by request_hit(). Clients never provide a damage value; the host reads this trusted
## definition. Host-owned combat may instead call Harvestable.host_apply_damage() with its own
## validated tool/weapon result.
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
@export var active_state_scenes: Array[PackedScene] = []
@export var depleted_scene: PackedScene


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
	if active_state_scenes.is_empty():
		errors.append("active_state_scenes needs at least an intact scene")
	for index: int in active_state_scenes.size():
		if active_state_scenes[index] == null:
			errors.append("active_state_scenes[%d] is empty" % index)
	return errors
