extends SceneTree

## Deterministic authoring helper for task 3.1's worked example: the workbench and furnace
## StationDefs, and the one furnace recipe (iron_ore x2 -> iron_ingot) that proves the timed-craft
## path. Bulk item/recipe/station content remains task 3.2; Godot serializes these resources so
## typed fields and subresources stay valid — same reasoning as setup_crafting_content.gd, whose
## stone_axe content this script does not touch.
##
## RE-RUNNING OVERWRITES content/stations/workbench.tres, content/stations/furnace.tres,
## content/items/iron_ingot.tres and content/recipes/iron_ingot.tres. Do not re-run once tuning has
## started (craft_time_sec, tier, icon, etc. are inspector-tunable after this).

const STATION_DEF_SCRIPT := preload("res://systems/crafting/station_def.gd")
const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")
const RECIPE_DEF_SCRIPT := preload("res://systems/crafting/recipe_def.gd")
const INGREDIENT_SCRIPT := preload("res://systems/crafting/recipe_ingredient.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/stations"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/items"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/recipes"))

	var workbench: Resource = STATION_DEF_SCRIPT.new()
	workbench.set("id", &"workbench")
	workbench.set("display_name", "Workbench")
	# Matches assets/crafting_stations/catalog.json and the Hollowmere marker
	# "Station_station_workbench_primitive" (tools/mapgen/hollowmere_layout.py).
	workbench.set("world_scene", &"station_workbench_primitive")
	workbench.set("tier", 1)
	_save(workbench, "res://content/stations/workbench.tres")

	var furnace: Resource = STATION_DEF_SCRIPT.new()
	furnace.set("id", &"furnace")
	furnace.set("display_name", "Furnace")
	# Matches assets/crafting_stations/catalog.json's "station_stone_furnace" and the Hollowmere
	# marker "Station_station_stone_furnace".
	furnace.set("world_scene", &"station_stone_furnace")
	furnace.set("tier", 2)
	_save(furnace, "res://content/stations/furnace.tres")

	var ingot: Resource = ITEM_DEF_SCRIPT.new()
	ingot.set("id", &"iron_ingot")
	ingot.set("display_name", "Iron Ingot")
	ingot.set("description", "Smelted iron, ready for the anvil.")
	ingot.set("category", 0) # ItemDef.Category.RESOURCE
	ingot.set("icon", load("res://assets/icons/exports/icon_iron_ingot.png") as Texture2D)
	ingot.set("stack_size", 99)
	ingot.set("world_model", load("res://assets/pickups/exports/pickup_iron_ingot.glb") as PackedScene)
	_save(ingot, "res://content/items/iron_ingot.tres")
	var saved_ingot := load("res://content/items/iron_ingot.tres") as ItemDef

	var recipe: Resource = RECIPE_DEF_SCRIPT.new()
	recipe.set("id", &"iron_ingot")
	recipe.set("display_name", "Iron Ingot")
	recipe.set("station", &"furnace")
	var inputs: Array[RecipeIngredient] = [
		_ingredient(load("res://content/items/iron_ore.tres") as Resource, 2),
	]
	recipe.set("inputs", inputs)
	recipe.set("output_item", saved_ingot)
	recipe.set("output_count", 1)
	# Short enough to keep headless checks fast, long enough that a progress poll mid-craft is
	# meaningfully between 0 and 1 rather than racing straight to completion.
	recipe.set("craft_time_sec", 2.0)
	_save(recipe, "res://content/recipes/iron_ingot.tres")

	print("STATION_CONTENT_SETUP resources=4 failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _ingredient(item: Resource, count: int) -> RecipeIngredient:
	var ingredient := INGREDIENT_SCRIPT.new() as RecipeIngredient
	ingredient.set("item", item)
	ingredient.set("count", count)
	return ingredient


func _save(resource: Resource, path: String) -> void:
	var error: Error = ResourceSaver.save(resource, path)
	if error == OK:
		print("SAVED: %s" % path)
		return
	failures += 1
	push_error("FAILED: %s (%s)" % [path, error_string(error)])
