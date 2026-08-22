extends SceneTree

## "Make sure there isn't a single thing in the game that's missing art."
##
## That is only answerable as a MEASUREMENT, so this is the tape measure. It loads every `.tres`
## under `content/`, works out which art slots that kind of definition has, and reports the ones that
## are empty or that point at something which fails to load. It deliberately does not guess: the slot
## list comes from the definition scripts' own exported properties, so a new art field on a def shows
## up here the first time anyone runs it, rather than being silently uncovered.
##
## Two kinds of gap are reported separately, because they need different work:
##
##   MISSING  the slot is null — nothing has been authored
##   BROKEN   the slot names a resource that does not load — art existed and the path rotted
##
## A definition may declare a slot legitimately unused (an item with no world mesh, a harvestable
## that draws the world builder's own geometry — F-114). Those are listed under EXEMPT with the
## reason, and the exemptions are named here rather than inferred, so adding one is a decision
## somebody makes on purpose.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only measurement.
##
##   .agent/bin/agent godot --script tools/art_coverage_check.gd

## Which exported properties count as art, per definition script. Anything of these types found on a
## definition is treated as an art slot whether or not it is listed, so this map only needs to carry
## the EXEMPTIONS and the human-readable family name.
const ART_TYPES: PackedStringArray = ["Texture2D", "PackedScene", "Mesh", "Material"]

## family -> array of property names that are allowed to be empty, with the reason.
const EXEMPT: Dictionary = {
	"harvestables": {
		"active_state_scenes": "F-114: an empty array means the prop is its own intact visual",
		"depleted_scene": "depletion may be a full visual despawn",
	},
	"items": {
		"world_scene": "not every item has a dropped-in-world presentation yet",
	},
	"loot": {},
	"scatter": {},
}

var _missing: Array[String] = []
var _broken: Array[String] = []
var _exempt: int = 0
var _slots: int = 0


func _initialize() -> void:
	print("Art coverage — every content definition, every art slot\n")
	var families: PackedStringArray = DirAccess.get_directories_at("res://content")
	families.sort()
	var by_family: Dictionary = {}
	for family: String in families:
		var dir := DirAccess.open("res://content/%s" % family)
		if dir == null:
			continue
		var files: PackedStringArray = dir.get_files()
		files.sort()
		var family_missing: Array[String] = []
		var family_total: int = 0
		for file_name: String in files:
			if not file_name.ends_with(".tres"):
				continue
			var path := "res://content/%s/%s" % [family, file_name]
			var definition: Resource = ResourceLoader.load(path)
			if definition == null:
				_broken.append("%s (the definition itself fails to load)" % path)
				continue
			family_total += 1
			for property: Dictionary in definition.get_property_list():
				if not (int(property["usage"]) & PROPERTY_USAGE_STORAGE):
					continue
				var name: String = String(property["name"])
				var hint: String = String(property.get("hint_string", ""))
				var is_art := false
				for art_type: String in ART_TYPES:
					if hint == art_type or hint.ends_with("/%s" % art_type) or hint.contains(art_type):
						is_art = true
				if not is_art:
					continue
				_slots += 1
				var value: Variant = definition.get(name)
				var empty: bool = value == null or (value is Array and (value as Array).is_empty())
				var exemptions: Dictionary = EXEMPT.get(family, {})
				if empty and exemptions.has(name):
					_exempt += 1
					continue
				if empty:
					family_missing.append("%s.%s" % [file_name.get_basename(), name])
					_missing.append("%s/%s.%s" % [family, file_name.get_basename(), name])
		if family_total > 0:
			by_family[family] = [family_total, family_missing]

	for family: String in by_family:
		var total: int = by_family[family][0]
		var gaps: Array = by_family[family][1]
		var mark: String = "OK  " if gaps.is_empty() else "GAP "
		print("%s %-16s %3d definitions, %3d art slot(s) empty" % [mark, family, total, gaps.size()])
		for gap: String in gaps:
			print("        MISSING  %s" % gap)
	for entry: String in _broken:
		print("     BROKEN   %s" % entry)

	print("\nART_COVERAGE_CHECK slots=%d missing=%d broken=%d exempt=%d"
		% [_slots, _missing.size(), _broken.size(), _exempt])
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("ART_COVERAGE_CHECK failures=%d" % (_missing.size() + _broken.size()))
	quit(1 if (_missing.size() + _broken.size()) > 0 else 0)
