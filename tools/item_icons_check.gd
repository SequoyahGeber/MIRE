extends SceneTree

## Headless proof that the A-042a inventory icons import, and that every ItemDef
## that should carry one does.
##
## Network authority: none. Icons are presentation only — item *instances* stay
## host-authoritative (ARCHITECTURE.md §2.2, "Inventory / crafting" row).

const ICON_CATALOG: String = "res://assets/icons/catalog.json"
const ICON_DIR: String = "res://assets/icons/exports"
const ITEM_DIR: String = "res://content/items"
const TOOL_EXPORTS: String = "res://assets/tools_weapons/exports"
const EXPECTED_SIZE: int = 256

var _failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := _load_catalog()
	_check(catalog.size() == 24, "icon catalog lists 24 icons (got %d)" % catalog.size())

	for entry: Dictionary in catalog:
		var id: String = entry.get("id", "")
		var path := "%s/icon_%s.png" % [ICON_DIR, id]
		var texture := load(path) as Texture2D
		_check(texture != null, "icon_%s.png imports as Texture2D" % id)
		if texture == null:
			continue
		var size := texture.get_size()
		_check(
			int(size.x) == EXPECTED_SIZE and int(size.y) == EXPECTED_SIZE,
			"icon_%s.png is %dx%d" % [id, EXPECTED_SIZE, EXPECTED_SIZE]
		)
		# A GLB whose source moved would render an empty icon rather than fail to
		# import, so the catalog's claimed source has to still exist.
		var source: String = "res://%s" % entry.get("source", "")
		_check(ResourceLoader.exists(source), "icon_%s source %s still exists" % [id, source])

	_check_items()
	_check_tool_scenes()

	if _failures == 0:
		print("item_icons_check: PASS")
	else:
		printerr("item_icons_check: %d FAILURE(S)" % _failures)
	quit(1 if _failures > 0 else 0)


func _load_catalog() -> Array:
	var file := FileAccess.open(ICON_CATALOG, FileAccess.READ)
	if file == null:
		_check(false, "icon catalog opens")
		return []
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Array:
		return parsed as Array
	_check(false, "icon catalog parses as an array")
	return []


func _check_items() -> void:
	var names := DirAccess.get_files_at(ITEM_DIR)
	_check(names.size() > 0, "content/items contains item definitions")
	for name: String in names:
		if not name.ends_with(".tres"):
			continue
		var item := load("%s/%s" % [ITEM_DIR, name]) as ItemDef
		_check(item != null, "%s loads as ItemDef" % name)
		if item == null:
			continue
		_check(item.icon != null, "%s has an inventory icon" % name)


func _check_tool_scenes() -> void:
	# The refreshed A-004 exports have to still instantiate: the rebuild changed
	# every mesh in them.
	for design: String in ["wooden_axe", "stone_axe", "iron_pickaxe", "cleaver", "short_bow"]:
		for presentation: String in ["world", "viewmodel"]:
			var path := "%s/%s_%s.glb" % [TOOL_EXPORTS, design, presentation]
			var packed := load(path) as PackedScene
			_check(packed != null, "%s_%s.glb loads as PackedScene" % [design, presentation])
			if packed == null:
				continue
			var instance := packed.instantiate() as Node3D
			_check(instance != null, "%s_%s.glb instantiates" % [design, presentation])
			if instance != null:
				_check(
					_mesh_count(instance) > 0,
					"%s_%s.glb carries mesh geometry" % [design, presentation]
				)
				instance.queue_free()


func _mesh_count(node: Node) -> int:
	var total := 0
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		total += 1
	for child: Node in node.get_children():
		total += _mesh_count(child)
	return total


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok   %s" % label)
	else:
		_failures += 1
		printerr("  FAIL %s" % label)
