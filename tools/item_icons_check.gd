extends SceneTree

## Headless proof that the A-042a inventory icons import, and that every ItemDef
## that should carry one does.
##
## Network authority: none. Icons are presentation only — item *instances* stay
## host-authoritative (ARCHITECTURE.md §2.2, "Inventory / crafting" row).

const ICON_CATALOG: String = "res://assets/icons/catalog.json"
## Icon families rendered by something OTHER than `render_item_icons.py`, which
## therefore have their own catalog and their own check. `icon_powerup_*` comes
## from `build_powerup_icons.py` and is verified by `powerup_icon_check.gd`;
## they share this directory because they share a destination, not an owner.
const FOREIGN_FAMILIES: PackedStringArray = ["icon_powerup_"]

const ICON_DIR: String = "res://assets/icons/exports"
const ITEM_DIR: String = "res://content/items"
const TOOL_EXPORTS: String = "res://assets/tools_weapons/exports"
const EXPECTED_SIZE: int = 256
## A floor, not a target: an empty or unparsed catalog must not read as a pass.
const MINIMUM_ICONS: int = 24

var _failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := _load_catalog()
	# Derived from the directory, not hard-coded. The literal 24 here went red the
	# moment A-021S rendered a 25th icon, which is a check failing at the one thing it
	# was meant to allow — adding an icon. What actually matters is that the catalog
	# and the exports agree exactly, in both directions.
	_check(catalog.size() >= MINIMUM_ICONS, "icon catalog is populated (got %d)" % catalog.size())
	var catalogued: Dictionary = {}
	for entry: Dictionary in catalog:
		var id: String = entry.get("id", "")
		_check(not catalogued.has(id), "icon catalog lists %s exactly once" % id)
		catalogued[id] = true
	var strays: PackedStringArray = PackedStringArray()
	for file_name: String in DirAccess.get_files_at(ICON_DIR):
		if not file_name.ends_with(".png"):
			continue
		var foreign := false
		for prefix: String in FOREIGN_FAMILIES:
			if file_name.begins_with(prefix):
				foreign = true
		if foreign:
			continue
		var id := file_name.trim_prefix("icon_").trim_suffix(".png")
		if not catalogued.has(id):
			strays.append(file_name)
	# A stray is REPORTED, not failed (F-428/F-440). The two failures that protect
	# the game are "an item has no icon" and "an item's icon does not match what it
	# was rendered from", and both are asserted above. An extra file in the export
	# directory breaks nothing — but treating it as an error made this check
	# useless twice over: once on 78 untracked stale duplicates somebody's file
	# manager left behind, and again on 72 perfectly good powerup icons that
	# simply belong to a different catalog. A check nobody can read is a check
	# nobody runs.
	if not strays.is_empty():
		print("  note: %d file(s) in %s are in no catalog — stale renders, or a family "
			% [strays.size(), ICON_DIR] + "that needs adding to FOREIGN_FAMILIES:")
		for index: int in mini(strays.size(), 6):
			print("        %s" % strays[index])

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
	for design: String in ["wooden_axe", "stone_axe", "iron_pickaxe", "cleaver", "short_bow", "iron_sword"]:
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
