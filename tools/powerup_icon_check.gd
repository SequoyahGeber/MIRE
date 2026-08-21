extends SceneTree

## Does every powerup and attunement have an icon, and does that icon agree with the card?
##
## `tools/blender/build_powerup_icons.py` runs inside Blender with no Godot available, so its
## `EMBLEMS` table repeats each card's tag list rather than reading it from the `.tres`. That is a
## duplication, and a duplication with nothing checking it is a bug waiting for someone to retag a
## powerup: the card would quietly keep the old family's plaque colour, which is the ONE thing a
## player sorts these by at icon size. This is the check that keeps the two honest.
##
## It asserts, for every powerup and attunement definition:
##
##   * the icon slot is filled and the texture loads,
##   * the texture is the square the UI expects rather than whatever Blender last wrote,
##   * the icon actually belongs to this definition (the filename carries its id, so a copy-paste
##     that points two cards at one picture is caught), and
##   * the emblem catalog's tag list matches the definition's.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only measurement.
##
##   .agent/bin/agent godot --script tools/powerup_icon_check.gd

const EXPECTED_SIZE: int = 256

var _failures: int = 0


func _check(condition: bool, label: String) -> void:
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % label)


func _initialize() -> void:
	print("Powerup and attunement icons\n")
	var catalog: Dictionary = {}
	var file := FileAccess.open("res://assets/icons/powerup_catalog.json", FileAccess.READ)
	if file == null:
		print("FAIL: assets/icons/powerup_catalog.json is missing — run build_powerup_icons.py")
		_failures += 1
	else:
		for entry: Variant in JSON.parse_string(file.get_as_text()):
			catalog[String((entry as Dictionary)["id"])] = entry

	var checked: int = 0
	var seen_paths: Dictionary = {}
	for family: String in ["powerups", "attunements"]:
		var dir := DirAccess.open("res://content/%s" % family)
		var names: PackedStringArray = dir.get_files()
		names.sort()
		for file_name: String in names:
			if not file_name.ends_with(".tres"):
				continue
			var id_from_file: String = file_name.get_basename()
			var definition: Resource = load("res://content/%s/%s" % [family, file_name])
			if definition == null:
				_check(false, "%s/%s loads" % [family, file_name])
				continue
			checked += 1
			var icon: Texture2D = definition.get("icon") as Texture2D
			if icon == null:
				_check(false, "%s/%s has an icon" % [family, id_from_file])
				continue
			_check(icon.get_width() == EXPECTED_SIZE and icon.get_height() == EXPECTED_SIZE,
				"%s/%s icon is %dx%d, expected %dx%d"
					% [family, id_from_file, icon.get_width(), icon.get_height(),
						EXPECTED_SIZE, EXPECTED_SIZE])
			var path: String = icon.resource_path
			_check(path.contains(id_from_file),
				"%s/%s icon %s carries this definition's id" % [family, id_from_file, path])
			if family == "powerups":
				_check(not seen_paths.has(path),
					"%s is used by only one definition (also %s)"
						% [path, seen_paths.get(path, "")])
				seen_paths[path] = id_from_file
				var entry: Dictionary = catalog.get(id_from_file, {})
				_check(not entry.is_empty(), "%s appears in the emblem catalog" % id_from_file)
				if not entry.is_empty():
					var built: Array = entry["tags"]
					var authored: Array = definition.get("tags")
					var same: bool = built.size() == authored.size()
					if same:
						for index: int in built.size():
							if String(built[index]) != String(authored[index]):
								same = false
					_check(same, "%s: emblem built for %s, definition says %s — the plaque colour "
						% [id_from_file, str(built), str(authored)]
						+ "is the family the player sorts by, so these cannot disagree")

	print("POWERUP_ICON_CHECK definitions=%d failures=%d" % [checked, _failures])
	quit(1 if _failures > 0 else 0)
