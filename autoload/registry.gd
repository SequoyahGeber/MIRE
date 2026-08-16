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

var items: Dictionary[StringName, ItemDef] = {}
var recipes: Dictionary[StringName, RecipeDef] = {}


func _ready() -> void:
	_load_items()
	_load_recipes()
	MireLog.info(&"content", "loaded %d item(s), %d recipe(s)" % [items.size(), recipes.size()])


func get_item(id: StringName) -> ItemDef:
	return items.get(id)


func has_item(id: StringName) -> bool:
	return items.has(id)


func get_recipe(id: StringName) -> RecipeDef:
	return recipes.get(id)


func has_recipe(id: StringName) -> bool:
	return recipes.has(id)


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
