extends Node

## Boot loader for content data. Scans content/items/ and content/recipes/ for .tres files and
## indexes them by their `id` field — see ARCHITECTURE.md §3.1 ("content is data, not code").
## Sequoyah adds new items/recipes by saving a new .tres in those folders; nothing here needs to
## change when he does.
##
## Network authority: none. Every peer loads the same content from disk and boots the same registry —
## nothing here is sent over the network, only referenced by id (ARCHITECTURE.md §2.2).
##
## Must be registered *before* any autoload that looks up items/recipes in its own _ready().

const ITEMS_PATH: String = "res://content/items"
const RECIPES_PATH: String = "res://content/recipes"
const STATIONS_PATH: String = "res://content/stations"
const WEAPONS_PATH: String = "res://content/weapons"
const LOOT_PATH: String = "res://content/loot"
const POWERUPS_PATH: String = "res://content/powerups"
const BUILDABLES_PATH: String = "res://content/buildables"

## F-016: LootTableDef is a brand-new class_name (task 3.5) and this autoload boots in every
## headless run, so a bare reference here would break every check in the project the moment the
## class cache is stale, not just this task's own. Preload it and compare scripts instead of `is`.
const LOOT_TABLE_DEF := preload("res://systems/loot/loot_table_def.gd")
## Same F-016 reasoning as LOOT_TABLE_DEF above: PowerupDef is a brand-new class_name (task
## 3.3) and this autoload boots in every headless run.
const POWERUP_DEF := preload("res://systems/powerups/powerup_def.gd")
## Same F-016 reasoning again: BuildableDef is new in task 3.6.
const BUILDABLE_DEF := preload("res://systems/building/buildable_def.gd")
## Same F-016 reasoning again: StationDef is new in task 3.1.
const STATION_DEF := preload("res://systems/crafting/station_def.gd")

var items: Dictionary[StringName, ItemDef] = {}
var recipes: Dictionary[StringName, RecipeDef] = {}
## Keyed by station id (task 3.1). Shared content, same shape as `recipes`. Untyped Resource for the
## same F-016 reason as the preload above.
var stations: Dictionary[StringName, Resource] = {}
## Keyed by the ItemDef id the weapon belongs to, not by an id of its own — a WeaponDef describes
## how an existing item swings (task 2.8).
var weapons: Dictionary[StringName, WeaponDef] = {}
## Keyed by tier id (task 3.5) — many placed Chests of the same tier share one table, same shared-
## content shape as `recipes`, not the per-instance shape `content/harvestables/` uses. Untyped
## Resource rather than LootTableDef for the same F-016 reason as the preload above.
var loot_tables: Dictionary[StringName, Resource] = {}

## Keyed by powerup id (task 3.3). Shared content, same shape as `recipes`. Untyped Resource
## for the same F-016 reason as the preload above.
var powerups: Dictionary[StringName, Resource] = {}

## Keyed by buildable id (task 3.6). Shared content; task 3.7 authors the real set.
var buildables: Dictionary[StringName, Resource] = {}


func _ready() -> void:
	_load_items()
	_load_recipes()
	_load_stations()
	_load_weapons()
	_load_loot_tables()
	_load_powerups()
	_load_buildables()
	MireLog.info(&"content", "loaded %d item(s), %d recipe(s), %d station(s), %d weapon(s), %d loot table(s), %d powerup(s), %d buildable(s)" % [
		items.size(), recipes.size(), stations.size(), weapons.size(), loot_tables.size(),
		powerups.size(), buildables.size()
	])


func get_item(id: StringName) -> ItemDef:
	return items.get(id)


func has_item(id: StringName) -> bool:
	return items.has(id)


func get_recipe(id: StringName) -> RecipeDef:
	return recipes.get(id)


func has_recipe(id: StringName) -> bool:
	return recipes.has(id)


func get_station(id: StringName) -> Resource:
	return stations.get(id)


func has_station(id: StringName) -> bool:
	return stations.has(id)


func get_weapon(item_id: StringName) -> WeaponDef:
	return weapons.get(item_id)


func has_weapon(item_id: StringName) -> bool:
	return weapons.has(item_id)


func get_loot_table(id: StringName) -> Resource:
	return loot_tables.get(id)


func has_loot_table(id: StringName) -> bool:
	return loot_tables.has(id)


func _load_items() -> void:
	for file_path: String in _tres_files_in(ITEMS_PATH):
		var res: Resource = load(file_path)
		if not (res is ItemDef):
			MireLog.error(&"content", "%s does not contain an ItemDef, skipped" % file_path)
			continue
		var item: ItemDef = res
		if item.id == &"":
			MireLog.error(&"content", "%s has no id set, skipped" % file_path)
			continue
		if items.has(item.id):
			MireLog.error(&"content", "duplicate item id '%s' at %s, keeping first" % [item.id, file_path])
			continue
		items[item.id] = item


func _load_recipes() -> void:
	for file_path: String in _tres_files_in(RECIPES_PATH):
		var res: Resource = load(file_path)
		if not (res is RecipeDef):
			MireLog.error(&"content", "%s does not contain a RecipeDef, skipped" % file_path)
			continue
		var recipe: RecipeDef = res
		if recipe.id == &"":
			MireLog.error(&"content", "%s has no id set, skipped" % file_path)
			continue
		if recipes.has(recipe.id):
			MireLog.error(&"content", "duplicate recipe id '%s' at %s, keeping first" % [recipe.id, file_path])
			continue
		recipes[recipe.id] = recipe


func _load_stations() -> void:
	for file_path: String in _tres_files_in(STATIONS_PATH):
		var res: Resource = load(file_path)
		if res == null or res.get_script() != STATION_DEF:
			MireLog.error(&"content", "%s does not contain a StationDef, skipped" % file_path)
			continue
		var station_id := StringName(String(res.get("id")))
		if station_id == &"":
			MireLog.error(&"content", "%s has no id set, skipped" % file_path)
			continue
		if stations.has(station_id):
			MireLog.error(&"content", "duplicate station id '%s' at %s, keeping first" % [
				station_id, file_path
			])
			continue
		var errors: PackedStringArray = res.call("validation_errors")
		if not errors.is_empty():
			MireLog.error(&"content", "%s is invalid (%s), skipped" % [file_path, "; ".join(errors)])
			continue
		stations[station_id] = res


func _load_weapons() -> void:
	for file_path: String in _tres_files_in(WEAPONS_PATH):
		var res: Resource = load(file_path)
		if not (res is WeaponDef):
			MireLog.error(&"content", "%s does not contain a WeaponDef, skipped" % file_path)
			continue
		var weapon: WeaponDef = res
		if weapon.item_id == &"":
			MireLog.error(&"content", "%s has no item_id set, skipped" % file_path)
			continue
		var errors: PackedStringArray = weapon.validation_errors()
		if not errors.is_empty():
			MireLog.error(&"content", "%s is invalid (%s), skipped" % [file_path, "; ".join(errors)])
			continue
		if weapons.has(weapon.item_id):
			MireLog.error(&"content", "duplicate weapon for item '%s' at %s, keeping first" % [
				weapon.item_id, file_path
			])
			continue
		weapons[weapon.item_id] = weapon


func _load_loot_tables() -> void:
	for file_path: String in _tres_files_in(LOOT_PATH):
		var res: Resource = load(file_path)
		if res == null or res.get_script() != LOOT_TABLE_DEF:
			MireLog.error(&"content", "%s does not contain a LootTableDef, skipped" % file_path)
			continue
		var table_id := StringName(String(res.get("id")))
		if table_id == &"":
			MireLog.error(&"content", "%s has no id set, skipped" % file_path)
			continue
		if loot_tables.has(table_id):
			MireLog.error(&"content", "duplicate loot table id '%s' at %s, keeping first" % [
				table_id, file_path
			])
			continue
		var errors: PackedStringArray = res.call("validation_errors")
		if not errors.is_empty():
			MireLog.error(&"content", "%s is invalid (%s), skipped" % [file_path, "; ".join(errors)])
			continue
		loot_tables[table_id] = res


func get_powerup(id: StringName) -> Resource:
	return powerups.get(id)


func has_powerup(id: StringName) -> bool:
	return powerups.has(id)


func _load_powerups() -> void:
	for file_path: String in _tres_files_in(POWERUPS_PATH):
		var res: Resource = load(file_path)
		if res == null or res.get_script() != POWERUP_DEF:
			MireLog.error(&"content", "%s does not contain a PowerupDef, skipped" % file_path)
			continue
		var powerup_id := StringName(String(res.get("id")))
		if powerup_id == &"":
			MireLog.error(&"content", "%s has no id set, skipped" % file_path)
			continue
		if powerups.has(powerup_id):
			MireLog.error(&"content", "duplicate powerup id '%s' at %s, keeping first" % [
				powerup_id, file_path
			])
			continue
		var errors: PackedStringArray = res.call("validation_errors")
		if not errors.is_empty():
			MireLog.error(&"content", "%s is invalid (%s), skipped" % [file_path, "; ".join(errors)])
			continue
		powerups[powerup_id] = res


func get_buildable(id: StringName) -> Resource:
	return buildables.get(id)


func has_buildable(id: StringName) -> bool:
	return buildables.has(id)


func _load_buildables() -> void:
	for file_path: String in _tres_files_in(BUILDABLES_PATH):
		var res: Resource = load(file_path)
		if res == null or res.get_script() != BUILDABLE_DEF:
			MireLog.error(&"content", "%s does not contain a BuildableDef, skipped" % file_path)
			continue
		var buildable_id := StringName(String(res.get("id")))
		if buildable_id == &"":
			MireLog.error(&"content", "%s has no id set, skipped" % file_path)
			continue
		if buildables.has(buildable_id):
			MireLog.error(&"content", "duplicate buildable id '%s' at %s, keeping first" % [
				buildable_id, file_path
			])
			continue
		var errors: PackedStringArray = res.call("validation_errors")
		if not errors.is_empty():
			MireLog.error(&"content", "%s is invalid (%s), skipped" % [file_path, "; ".join(errors)])
			continue
		buildables[buildable_id] = res


func _tres_files_in(dir_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		MireLog.error(&"content", "cannot open %s (%s)" % [dir_path, DirAccess.get_open_error()])
		return result
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			result.append(dir_path.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	return result
