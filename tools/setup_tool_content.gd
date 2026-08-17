extends SceneTree

## Generates an ItemDef for every tool/weapon design A-004 exported, plus a WeaponDef for the melee
## ones, so the ten designs sitting in `assets/tools_weapons/` are actually holdable.
##
## **This is bulk content generation, which AGENTS.md tells agents not to do** — items are meant to
## be authored by hand in the inspector, because that is free and an agent's time is not. It is done
## here because Sequoyah asked for a starting loadout with one of each tool, and nine of the ten had
## no ItemDef at all, so there was nothing to grant. Everything below is *derived* from the existing
## authored catalog (`assets/tools_weapons/catalog.json` names the designs, `assets/icons/exports/`
## has an icon for each) rather than invented.
##
## The WEAPON numbers are starting points for task 2.9, not tuned values. They come from one rule —
## heavier tools swing slower, hit harder and reach further — applied consistently so the ten weapons
## differ from each other in a way that can be felt and then argued with. Retune them in the
## inspector; re-running this script overwrites them.

const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")
const WEAPON_DEF_SCRIPT := preload("res://systems/combat/weapon_def.gd")

## category: 1 = TOOL, 2 = WEAPON (ItemDef.Category).
## weight drives the derived swing: 0.0 is a paring knife, 1.0 is a sledgehammer.
const DESIGNS: Array[Dictionary] = [
	{"id": &"wooden_axe", "name": "Wooden Axe", "category": 1, "weight": 0.35, "melee": true,
		"desc": "A green-wood axe. It bites, eventually."},
	{"id": &"wooden_pickaxe", "name": "Wooden Pickaxe", "category": 1, "weight": 0.45, "melee": true,
		"desc": "Better at rock than the rock is at it. Barely."},
	{"id": &"stone_pickaxe", "name": "Stone Pickaxe", "category": 1, "weight": 0.6, "melee": true,
		"desc": "Heavy enough to break stone, and to be a poor weapon."},
	{"id": &"iron_pickaxe", "name": "Iron Pickaxe", "category": 1, "weight": 0.75, "melee": true,
		"desc": "The good one. Do not lose it in the Mire."},
	{"id": &"cleaver", "name": "Cleaver", "category": 2, "weight": 0.3, "melee": true,
		"desc": "Fast, mean, and not remotely a tool."},
	{"id": &"skewer", "name": "Skewer", "category": 2, "weight": 0.2, "melee": true,
		"desc": "All reach, no weight. Poke first."},
	{"id": &"repair_hammer", "name": "Repair Hammer", "category": 1, "weight": 0.9, "melee": true,
		"desc": "For mending wards. Also for endings."},
	{"id": &"short_bow", "name": "Short Bow", "category": 2, "weight": 0.0, "melee": false,
		"desc": "Ranged combat is not built yet. It is a stick with intent."},
	{"id": &"arrow", "name": "Arrow", "category": 0, "weight": 0.0, "melee": false, "stack": 64,
		"desc": "Waiting for something to fire it."},
]

var failures: int = 0
var made_items: int = 0
var made_weapons: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/items"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/weapons"))

	for design: Dictionary in DESIGNS:
		var id := StringName(design["id"])
		_save_item(id, design)
		if bool(design.get("melee", false)):
			_save_weapon(id, design)

	print("TOOL_CONTENT_SETUP items=%d weapons=%d failures=%d"
		% [made_items, made_weapons, failures])
	quit(0 if failures == 0 else 1)


func _save_item(id: StringName, design: Dictionary) -> void:
	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", id)
	item.set("display_name", String(design["name"]))
	item.set("description", String(design.get("desc", "")))
	item.set("category", int(design["category"]))
	# Tools and weapons do not stack; ammunition does.
	item.set("stack_size", int(design.get("stack", 1)))
	item.set("icon", _load_if_present("res://assets/icons/exports/icon_%s.png" % id))
	item.set("world_model", _load_if_present(
		"res://assets/tools_weapons/exports/%s_world.glb" % id
	))
	if _save(item, "res://content/items/%s.tres" % id):
		made_items += 1


## One rule, applied to every melee design: weight buys damage and reach, and costs speed. That is
## the whole model — it exists so the ten weapons are *different* in a way 2.9 can feel and retune,
## not because these are the right numbers.
func _save_weapon(id: StringName, design: Dictionary) -> void:
	var weight: float = float(design.get("weight", 0.5))
	var weapon: Resource = WEAPON_DEF_SCRIPT.new()
	weapon.set("item_id", id)
	weapon.set("display_name", String(design["name"]))
	weapon.set("wind_up_seconds", snappedf(lerpf(0.14, 0.34, weight), 0.01))
	weapon.set("commit_seconds", snappedf(lerpf(0.08, 0.16, weight), 0.01))
	weapon.set("recovery_seconds", snappedf(lerpf(0.20, 0.46, weight), 0.01))
	weapon.set("damage", int(roundf(lerpf(2.0, 7.0, weight))))
	# The skewer is the exception the rule needs: light AND long, so "light" does not just mean
	# "worse". Everything else gets reach from weight.
	var reach: float = 3.1 if id == &"skewer" else lerpf(2.2, 2.9, weight)
	weapon.set("range_m", snappedf(reach, 0.05))
	weapon.set("arc_degrees", snappedf(lerpf(110.0, 80.0, weight), 1.0))
	weapon.set("vertical_reach_m", 2.4)
	weapon.set("hitstop_seconds", snappedf(lerpf(0.04, 0.11, weight), 0.005))
	weapon.set("shake_magnitude", snappedf(lerpf(0.06, 0.18, weight), 0.005))
	weapon.set("shake_duration", snappedf(lerpf(0.14, 0.28, weight), 0.01))
	weapon.set("impact_audible_range_m", 24.0)
	if _save(weapon, "res://content/weapons/%s.tres" % id):
		made_weapons += 1


func _load_if_present(path: String) -> Resource:
	return load(path) if ResourceLoader.exists(path) else null


func _save(resource: Resource, path: String) -> bool:
	var error: Error = ResourceSaver.save(resource, path)
	if error == OK:
		print("SAVED: %s" % path)
		return true
	failures += 1
	push_error("FAILED: %s (%s)" % [path, error_string(error)])
	return false
