class_name LootTableDef
extends Resource

## Static loot table for one chest tier. Authored by hand as a .tres in content/loot/ — see
## ARCHITECTURE.md §3.1 ("content is data, not code"). `registry.gd` loads every .tres in that
## folder at boot and indexes it by `id`; Chest resolves its tier through `Registry.get_loot_table()`
## rather than holding a direct resource reference, because many placed chests of the same tier share
## one table — the RecipeDef shape, not the per-instance HarvestableDef shape.
##
## Network authority: none. The table is immutable content loaded identically on every peer. Only the
## ROLL happens over the network's boundary, and it happens once, host-side, inside Chest — nothing
## here is ever sent on the wire.

## F-016: a brand-new class_name is not bare-resolvable in a fresh headless clone (no editor scan has
## rebuilt .godot/global_script_class_cache.cfg yet). Preload it and use the constant as the type.
const LOOT_ENTRY := preload("res://systems/loot/loot_entry.gd")

@export var id: StringName = &""
@export_range(0, 999, 1) var coin_min: int = 0
@export_range(0, 999, 1) var coin_max: int = 0
## How many independent weighted draws one open performs. The same entry can be drawn more than
## once — its amounts simply add — rather than the table tracking "already drawn" state a chest has
## no real reason to care about.
@export_range(1, 20, 1) var roll_count: int = 1
@export var entries: Array[LOOT_ENTRY] = []


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if coin_min < 0:
		errors.append("coin_min cannot be negative")
	if coin_max < coin_min:
		errors.append("coin_max cannot be less than coin_min")
	if roll_count <= 0:
		errors.append("roll_count must be positive")
	if entries.is_empty() and coin_max <= 0:
		errors.append("table grants neither items nor coins")
	for index: int in entries.size():
		var entry: Resource = entries[index]
		if entry == null:
			errors.append("entries[%d] is empty" % index)
			continue
		if StringName(String(entry.get("item_id"))) == &"":
			errors.append("entries[%d] has no item_id" % index)
		if int(entry.get("max_amount")) < int(entry.get("min_amount")):
			errors.append("entries[%d] max_amount is below min_amount" % index)
		if float(entry.get("weight")) <= 0.0:
			errors.append("entries[%d] weight must be positive" % index)
	return errors


## Host-only. [param rng] is the caller's own RandomNumberGenerator — never randi() — so how it was
## seeded is entirely the caller's business; this table just consumes whatever stream it is handed.
## Returns {"coins": int, "items": Dictionary[StringName, int]}.
func roll(rng: RandomNumberGenerator) -> Dictionary:
	var result: Dictionary = {"coins": 0, "items": {}}
	if coin_max > 0:
		result["coins"] = rng.randi_range(coin_min, coin_max)
	if entries.is_empty():
		return result

	var total_weight: float = 0.0
	for entry: Resource in entries:
		if entry != null and float(entry.get("weight")) > 0.0:
			total_weight += float(entry.get("weight"))
	if total_weight <= 0.0:
		return result

	var items: Dictionary = result["items"]
	for _draw: int in roll_count:
		var pick: Resource = _weighted_pick(rng, total_weight)
		if pick == null:
			continue
		var item_id := StringName(String(pick.get("item_id")))
		var amount: int = rng.randi_range(int(pick.get("min_amount")), int(pick.get("max_amount")))
		items[item_id] = int(items.get(item_id, 0)) + amount
	result["items"] = items
	return result


func _weighted_pick(rng: RandomNumberGenerator, total_weight: float) -> Resource:
	var target: float = rng.randf_range(0.0, total_weight)
	var cursor: float = 0.0
	var last_valid: Resource = null
	for entry: Resource in entries:
		if entry == null or float(entry.get("weight")) <= 0.0:
			continue
		last_valid = entry
		cursor += float(entry.get("weight"))
		if target <= cursor:
			return entry
	# Float rounding can leave target a hair above the accumulated sum; the last positive-weight
	# entry is the correct fallback rather than null.
	return last_valid
