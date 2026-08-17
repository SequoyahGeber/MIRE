extends SceneTree

## Deterministic authoring helper for task 2.6's single vertical-slice recipe. Bulk item/recipe
## content remains task 3.2; Godot serializes these resources so typed subresources stay valid.

const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")
const RECIPE_DEF_SCRIPT := preload("res://systems/crafting/recipe_def.gd")
const INGREDIENT_SCRIPT := preload("res://systems/crafting/recipe_ingredient.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/items"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/recipes"))

	var axe: Resource = ITEM_DEF_SCRIPT.new()
	axe.set("id", &"stone_axe")
	axe.set("display_name", "Stone Axe")
	axe.set("description", "A rough chopping tool that doubles as a close-range weapon.")
	axe.set("category", 2)
	# Regenerating this file used to drop the icon kiln9's A-042 batch wired up, so the hotbar fell
	# back to a two-letter name. Set it here so a re-run cannot silently undo that again.
	axe.set("icon", load("res://assets/icons/exports/icon_stone_axe.png") as Texture2D)
	axe.set("stack_size", 1)
	axe.set("world_model", load(
		"res://assets/tools_weapons/exports/stone_axe_world.glb"
	) as PackedScene)
	# F-041: the first-person presentation. Grip values match what setup_tool_content derives for a
	# 1.32 m design; both are starting points for the inspector.
	axe.set("view_model", load(
		"res://assets/tools_weapons/exports/stone_axe_viewmodel.glb"
	) as PackedScene)
	axe.set("grip_offset", Vector3(0.17, -0.30, -0.55))
	axe.set("grip_rotation_degrees", Vector3(-6.0, 158.0, 10.0))
	axe.set("grip_scale", 0.22)
	_save(axe, "res://content/items/stone_axe.tres")
	var saved_axe := load("res://content/items/stone_axe.tres") as ItemDef

	var recipe: Resource = RECIPE_DEF_SCRIPT.new()
	recipe.set("id", &"stone_axe")
	recipe.set("display_name", "Stone Axe")
	recipe.set("station", &"workbench")
	var inputs: Array[RecipeIngredient] = [
		_ingredient(load("res://content/items/log.tres") as Resource, 2),
		_ingredient(load("res://content/items/stone.tres") as Resource, 3),
	]
	recipe.set("inputs", inputs)
	recipe.set("output_item", saved_axe)
	recipe.set("output_count", 1)
	_save(recipe, "res://content/recipes/stone_axe.tres")

	print("CRAFTING_CONTENT_SETUP resources=2 failures=%d" % failures)
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
