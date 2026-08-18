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
const HAULABLES_PATH: String = "res://content/haulables"
const ATTUNEMENTS_PATH: String = "res://content/attunements"
const BIOMES_PATH: String = "res://content/biomes"
const SCATTER_PATH: String = "res://content/scatter"
const RULES_PATH: String = "res://content/rules"
const HOOKS_PATH: String = "res://content/hooks"

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
## Same F-016 reasoning again: HaulableDef is new in task 3.10.
const HAULABLE_DEF := preload("res://systems/hauling/haulable_def.gd")
## Same F-016 reasoning again: AttunementDef is new in task 3.9.
const ATTUNEMENT_DEF := preload("res://systems/attunement/attunement_def.gd")
## Same F-016 reasoning again: BiomeDef is new in task 4.2. Lives under world/gen/, not systems/,
## matching ARCHITECTURE.md §3's own project structure ("world/gen/ — island generation, biome
## placement, POI scatter") rather than the systems/<domain> convention every other Def above uses.
const BIOME_DEF := preload("res://world/gen/biome_def.gd")
## Same F-016 reasoning again: RuleDef is new in task 3.14. It is a content family like any other —
## the AUTHORED half of a gamerule (id, type, bounds, default). Its live VALUE is not content and
## does not live here; autoload/rule_service.gd owns that and is the only thing allowed to change one
## (docs/COMMANDS.md §4.2).
const RULE_DEF := preload("res://systems/rules/rule_def.gd")
## Same F-016 reasoning again: ScatterDef is new in task 4.4. Lives under world/gen/ for the same
## reason BiomeDef does — §3's project structure already names it "POI scatter" territory.
const SCATTER_DEF := preload("res://world/gen/scatter_def.gd")
## Same F-016 reasoning again: HookDef is new in task 3.17. It is a content family like any other —
## the AUTHORED binding of a game event to a function (id, event, function, enabled). Whether one is
## actually WIRED to its real signal is not content and does not live here; autoload/command_service.gd
## owns that (docs/COMMANDS.md §5.2).
const HOOK_DEF := preload("res://systems/rules/hook_def.gd")
## Preloaded like the four above so the one generic loader can use script equality uniformly —
## it is the F-016-safe type check for every def, established or new (F-099).
const ITEM_DEF := preload("res://systems/inventory/item_def.gd")
const RECIPE_DEF := preload("res://systems/crafting/recipe_def.gd")
const WEAPON_DEF := preload("res://systems/combat/weapon_def.gd")

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

## Keyed by haulable id (task 3.10). Shared content, same shape as `buildables` — one worked
## example, the rest is Sequoyah's (AGENTS.md: never bulk-generate content data).
var haulables: Dictionary[StringName, Resource] = {}

## Keyed by Attunement id (task 3.9). Exactly four — DESIGN.md §4.5's fixed roster, not an open
## content pool, so all four ship as the framework rather than one worked example plus Sequoyah's
## authoring (D-070).
var attunements: Dictionary[StringName, Resource] = {}

## Keyed by biome id (task 4.2). Shared content, same shape as `recipes` — 4.1's heightmap plus
## world/gen/biome_map.gd's moisture noise decide which biome a world point resolves to; this is
## just the authored range data. Three worked examples ship with this task; Sequoyah authors the
## rest (D-073 — one at a time, not a bulk sweep).
var biomes: Dictionary[StringName, Resource] = {}

## Keyed by scatter table id (task 4.4). Shared content, same shape as `recipes` — `biome_id` on
## each table says which `BiomeDef` it dresses; `ResourceScatter` groups these by that field itself
## rather than this dictionary being pre-grouped. One worked example ships with this task
## (`forest`); Sequoyah authors the rest (D-073 — one at a time, not a bulk sweep).
var scatter_tables: Dictionary[StringName, Resource] = {}

## Keyed by rule id (task 3.14). Shared content, same shape as `biomes`. The eight first-wave knobs
## COMMANDS.md §4.3 migrates ship with the task; later waves add one `.tres` plus one line in the
## owning system, which is the whole point of the family.
var rules: Dictionary[StringName, Resource] = {}

## Keyed by hook id (task 3.17). Shared content, same shape as `rules`. One worked example ships
## with this task (`night_siege`, disabled by default); Sequoyah authors the rest (D-073 — one at a
## time, not a bulk sweep).
var hooks: Dictionary[StringName, Resource] = {}


func _ready() -> void:
	_load_dir(ITEMS_PATH, "ItemDef", ITEM_DEF, &"id", "item id", items)
	_load_dir(RECIPES_PATH, "RecipeDef", RECIPE_DEF, &"id", "recipe id", recipes)
	_load_dir(STATIONS_PATH, "StationDef", STATION_DEF, &"id", "station id", stations)
	_load_dir(WEAPONS_PATH, "WeaponDef", WEAPON_DEF, &"item_id", "weapon for item", weapons)
	_load_dir(LOOT_PATH, "LootTableDef", LOOT_TABLE_DEF, &"id", "loot table id", loot_tables)
	_load_dir(POWERUPS_PATH, "PowerupDef", POWERUP_DEF, &"id", "powerup id", powerups)
	_load_dir(BUILDABLES_PATH, "BuildableDef", BUILDABLE_DEF, &"id", "buildable id", buildables)
	_load_dir(HAULABLES_PATH, "HaulableDef", HAULABLE_DEF, &"id", "haulable id", haulables)
	_load_dir(ATTUNEMENTS_PATH, "AttunementDef", ATTUNEMENT_DEF, &"id", "attunement id", attunements)
	_load_dir(BIOMES_PATH, "BiomeDef", BIOME_DEF, &"id", "biome id", biomes)
	_load_dir(SCATTER_PATH, "ScatterDef", SCATTER_DEF, &"id", "scatter table id", scatter_tables)
	_load_dir(RULES_PATH, "RuleDef", RULE_DEF, &"id", "rule id", rules)
	_load_dir(HOOKS_PATH, "HookDef", HOOK_DEF, &"id", "hook id", hooks)
	MireLog.info(&"content", "loaded %d item(s), %d recipe(s), %d station(s), %d weapon(s), %d loot table(s), %d powerup(s), %d buildable(s), %d haulable(s), %d attunement(s), %d biome(s), %d scatter table(s), %d rule(s), %d hook(s)" % [
		items.size(), recipes.size(), stations.size(), weapons.size(), loot_tables.size(),
		powerups.size(), buildables.size(), haulables.size(), attunements.size(), biomes.size(),
		scatter_tables.size(), rules.size(), hooks.size()
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


func get_powerup(id: StringName) -> Resource:
	return powerups.get(id)


func has_powerup(id: StringName) -> bool:
	return powerups.has(id)


func get_buildable(id: StringName) -> Resource:
	return buildables.get(id)


func has_buildable(id: StringName) -> bool:
	return buildables.has(id)


func get_haulable(id: StringName) -> Resource:
	return haulables.get(id)


func has_haulable(id: StringName) -> bool:
	return haulables.has(id)


func get_attunement(id: StringName) -> Resource:
	return attunements.get(id)


func has_attunement(id: StringName) -> bool:
	return attunements.has(id)


## The accessor RuleService looks for by name at boot. Named `rule_defs()` rather than exposing
## `rules` bare because "the rules" in conversation means their live values, which live in the
## service — this returns the authored DEFINITIONS, and the name should say so.
func rule_defs() -> Dictionary:
	return rules


func get_rule(id: StringName) -> Resource:
	return rules.get(id)


func has_rule(id: StringName) -> bool:
	return rules.has(id)


func get_biome(id: StringName) -> Resource:
	return biomes.get(id)


func has_biome(id: StringName) -> bool:
	return biomes.has(id)


func get_scatter_table(id: StringName) -> Resource:
	return scatter_tables.get(id)


func has_scatter_table(id: StringName) -> bool:
	return scatter_tables.has(id)


## The accessor CommandService looks for by name at boot (`_wire_hooks()`), same naming reasoning as
## `rule_defs()` — the AUTHORED bindings, not whether one is currently wired to a real signal.
func hook_defs() -> Dictionary:
	return hooks


func get_hook(id: StringName) -> Resource:
	return hooks.get(id)


func has_hook(id: StringName) -> bool:
	return hooks.has(id)


## The one loader behind every content directory (F-099 — this replaced seven near-identical
## functions, and an eighth content type is now one _ready() line, not another copy). Script
## equality is the F-016-safe type check for every def. Defs that implement validation_errors()
## are validated exactly as the per-type loaders did; ItemDef/RecipeDef, which do not, load as
## before. Boot-time only.
func _load_dir(
	dir_path: String,
	type_name: String,
	def_script: Script,
	id_property: StringName,
	duplicate_label: String,
	target: Dictionary
) -> void:
	for file_path: String in _tres_files_in(dir_path):
		var res: Resource = load(file_path)
		if res == null or res.get_script() != def_script:
			MireLog.error(&"content", "%s does not contain a %s, skipped" % [file_path, type_name])
			continue
		var def_id := StringName(String(res.get(id_property)))
		if def_id == &"":
			MireLog.error(&"content", "%s has no %s set, skipped" % [file_path, id_property])
			continue
		if target.has(def_id):
			MireLog.error(&"content", "duplicate %s '%s' at %s, keeping first" % [
				duplicate_label, def_id, file_path
			])
			continue
		if res.has_method(&"validation_errors"):
			var errors: PackedStringArray = res.call("validation_errors")
			if not errors.is_empty():
				MireLog.error(&"content", "%s is invalid (%s), skipped" % [file_path, "; ".join(errors)])
				continue
		target[def_id] = res


func _tres_files_in(dir_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		MireLog.error(&"content", "cannot open %s (%s)" % [dir_path, DirAccess.get_open_error()])
		return result
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		# Exported builds pack "<name>.tres" as "<name>.tres.remap", so a raw .tres filter matches
		# nothing there and the game ships with no content at all (F-121). load() wants the original
		# .tres path and resolves the remap itself.
		if not dir.current_is_dir():
			var res_name: String = file_name.trim_suffix(".remap")
			if res_name.ends_with(".tres"):
				var res_path: String = dir_path.path_join(res_name)
				if not result.has(res_path):
					result.append(res_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	return result
