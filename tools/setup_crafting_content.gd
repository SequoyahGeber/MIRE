extends SceneTree

## Deterministic authoring helper for task 2.6's single vertical-slice recipe. Bulk item/recipe
## content remains task 3.2; Godot serializes these resources so typed subresources stay valid.
##
## RE-RUNNING OVERWRITES content/items/stone_axe.tres and content/recipes/stone_axe.tres —
## including the grip_* values below, which are exactly what task 2.9 tunes in the inspector
## (F-048). The icon is pinned below so a re-run keeps it; nothing else authored after 2.6
## survives. Do not re-run once tuning has started. Note the split ownership: this file writes the
## stone_axe ITEM, setup_combat_content.gd writes the stone_axe WEAPON.

const TOOL_CONTENT := preload("res://tools/setup_tool_content.gd")
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
	# F-041: the first-person presentation. F-073: these are READ FROM setup_tool_content.gd's GRIPS
	# rather than repeated here. Two generators own `stone_axe.tres` — this one authors it and that
	# one holds the solved grips — and when the numbers were written out twice, this copy silently
	# re-authored the item with the pre-F-073 sword grip and no `attack_style` the next time anyone
	# ran it. That is the same clobber class the header already warns about for the icon (F-048).
	axe.set("view_model", load(
		"res://assets/tools_weapons/exports/stone_axe_viewmodel.glb"
	) as PackedScene)
	var grip: Dictionary = TOOL_CONTENT.GRIPS[&"stone_axe"]
	axe.set("grip_offset", grip["pos"])
	axe.set("grip_rotation_degrees", grip["rot"])
	axe.set("grip_scale", grip["scale"])
	axe.set("attack_style", grip["style"])
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
