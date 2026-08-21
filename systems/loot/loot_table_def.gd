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
## here is ever sent on the wire. `roll()`'s optional unlock gate (D-111/F-173) rides the same
## boundary: the caller passes it a Callable, so this file never touches UnlockService directly.

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

## Entries granted on EVERY roll, before the weighted draws and independent of them — the table's
## certainties rather than its odds. `weight` and `rarity` are ignored here; `min_amount`/`max_amount`
## still apply, so "1–2 shards, always" is expressible and "sometimes a shard" is not.
##
## Task 3.18 (D-200) is why this exists. The tool ladder's top two rungs are gated on a Wellglass
## Shard from a Wellspring cap and a Guardian Core from a boss, and a gate that pays out on a
## weighted draw is not a gate — it is a slot machine standing where a rung should be. Every other
## table leaves this empty and behaves exactly as it did before the field existed.
@export var guaranteed: Array[LOOT_ENTRY] = []


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
	if entries.is_empty() and guaranteed.is_empty() and coin_max <= 0:
		errors.append("table grants neither items nor coins")
	for index: int in guaranteed.size():
		var certain: Resource = guaranteed[index]
		if certain == null:
			errors.append("guaranteed[%d] is empty" % index)
			continue
		if StringName(String(certain.get("item_id"))) == &"":
			errors.append("guaranteed[%d] has no item_id" % index)
		if int(certain.get("max_amount")) < int(certain.get("min_amount")):
			errors.append("guaranteed[%d] max_amount is below min_amount" % index)
		if int(certain.get("kind")) != LOOT_ENTRY.Kind.ITEM:
			# Deliberate: an unconditionally granted POWERUP would hand every player the same
			# build every run and would also route around the unlock gate `roll()` applies to
			# weighted powerup entries (D-111/F-173).
			errors.append("guaranteed[%d] must be an ITEM entry" % index)
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
		var rarity: int = int(entry.get("rarity"))
		if rarity < 0 or rarity > 3:
			errors.append("entries[%d] rarity %d is outside 0..3" % [index, rarity])
		var kind: int = int(entry.get("kind"))
		if kind != LOOT_ENTRY.Kind.ITEM and kind != LOOT_ENTRY.Kind.POWERUP:
			errors.append("entries[%d] has unknown kind %d" % [index, kind])
	return errors


## Host-only. [param rng] is the caller's own RandomNumberGenerator — never randi() — so how it was
## seeded is entirely the caller's business; this table just consumes whatever stream it is handed.
##
## [param luck] is the opener's `loot_luck` stat, 0.0 for nobody special. It multiplies each entry's
## weight by (1 + luck * rarity), so a rarity-0 filler line is untouched and a rarity-3 jackpot line
## leans hardest — luck changes the ODDS and never the contents (D-063: tune frequency, not potency).
##
## [param is_unlocked] gates POWERUP entries only (D-111/F-173): a `Callable(content_id: StringName)
## -> bool`, called with each POWERUP entry's `item_id`. An entry it returns false for is treated as
## zero-weight for this roll, same as an unauthored weight — it can still be drawn again once
## unlocked, nothing about the table itself changes. An unset (invalid) Callable — the default, and
## every call site that has no unlock system to ask — never filters anything, so this stays a no-op
## for every caller that predates F-173. ITEM entries are never gated; only POWERUP rows can be
## behind the unlock tree (DESIGN.md §4.6).
##
## Returns {"coins": int, "items": Dictionary[StringName, int],
##          "powerups": Dictionary[StringName, int]}.
func roll(rng: RandomNumberGenerator, luck: float = 0.0, is_unlocked: Callable = Callable()) -> Dictionary:
	var result: Dictionary = {"coins": 0, "items": {}, "powerups": {}}
	if coin_max > 0:
		result["coins"] = rng.randi_range(coin_min, coin_max)
	# The certainties first, and outside every gate below: no weight, no luck, no unlock filter. They
	# are consumed from the same rng stream as the draws, so a table's whole outcome stays a pure
	# function of the seed it was handed.
	for certain: Resource in guaranteed:
		if certain == null:
			continue
		var certain_id := StringName(String(certain.get("item_id")))
		if certain_id == &"":
			continue
		var certain_amount: int = rng.randi_range(
			int(certain.get("min_amount")), int(certain.get("max_amount"))
		)
		var certain_items: Dictionary = result["items"]
		certain_items[certain_id] = int(certain_items.get(certain_id, 0)) + certain_amount
		result["items"] = certain_items
	if entries.is_empty():
		return result

	var weights := PackedFloat32Array()
	var total_weight: float = 0.0
	for entry: Resource in entries:
		var weight: float = 0.0
		if entry != null:
			weight = float(entry.get("weight"))
			if weight > 0.0 and int(entry.get("kind")) == LOOT_ENTRY.Kind.POWERUP and is_unlocked.is_valid():
				if not bool(is_unlocked.call(StringName(String(entry.get("item_id"))))):
					weight = 0.0
			if weight > 0.0:
				weight *= 1.0 + maxf(0.0, luck) * float(entry.get("rarity"))
			else:
				weight = 0.0
		weights.append(weight)
		total_weight += weight
	if total_weight <= 0.0:
		return result

	var items: Dictionary = result["items"]
	var powerups: Dictionary = result["powerups"]
	for _draw: int in roll_count:
		var pick: Resource = _weighted_pick(rng, weights, total_weight)
		if pick == null:
			continue
		var granted_id := StringName(String(pick.get("item_id")))
		var amount: int = rng.randi_range(int(pick.get("min_amount")), int(pick.get("max_amount")))
		var bucket: Dictionary = powerups if int(pick.get("kind")) == LOOT_ENTRY.Kind.POWERUP else items
		bucket[granted_id] = int(bucket.get(granted_id, 0)) + amount
	result["items"] = items
	result["powerups"] = powerups
	return result


func _weighted_pick(rng: RandomNumberGenerator, weights: PackedFloat32Array, total_weight: float) -> Resource:
	var target: float = rng.randf_range(0.0, total_weight)
	var cursor: float = 0.0
	var last_valid: Resource = null
	for index: int in entries.size():
		var weight: float = weights[index]
		if weight <= 0.0:
			continue
		last_valid = entries[index]
		cursor += weight
		if target <= cursor:
			return entries[index]
	# Float rounding can leave target a hair above the accumulated sum; the last positive-weight
	# entry is the correct fallback rather than null.
	return last_valid
