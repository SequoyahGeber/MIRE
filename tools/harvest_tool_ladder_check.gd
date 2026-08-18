extends SceneTree

## F-113: does the tool you are holding decide how long a prop takes, and does the intended tool
## take THREE swings?
##
## The regression this exists to stop is not subtle — before it, one stone-axe swing felled a whole
## tree, because the weapon's combat damage (4) and the harvest raycast's own hit (1) both landed on
## a prop authored with 3 health. So this asserts the ladder in swings, which is the unit a player
## actually experiences, and it reads the SHIPPED .tres files rather than building fixtures: a
## content edit that quietly makes a tree one-shottable again fails here.
##
## Run with: .agent/bin/agent godot --script tools/harvest_tool_ladder_check.gd

const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
const HARVEST_LIBRARY := preload("res://systems/harvesting/harvest_library.gd")

## weapon id -> harvestable id -> swings to deplete, or -1 for "never".
const EXPECTED_SWINGS: Dictionary = {
	&"stone_axe": {&"tree": 3, &"wild_tree": 3, &"sapling": 2, &"bush": 2, &"stone_node": -1},
	&"wooden_axe": {&"tree": 6, &"wild_tree": 6, &"stump": 4},
	&"iron_pickaxe": {&"iron_node": 3, &"stone_node": 2, &"boulder": 3, &"tree": 6},
	&"stone_pickaxe": {&"stone_node": 3, &"rock_cluster": 3, &"iron_node": 5, &"tree": -1},
	&"wooden_pickaxe": {&"stone_node": 6, &"tree": -1},
	&"unarmed": {&"bush": 3, &"sapling": 4, &"tree": -1, &"stone_node": -1},
}

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var combat: Node = root.get_node_or_null(^"CombatService")
	var registry: Node = root.get_node_or_null(^"Registry")
	check(combat != null, "CombatService autoload exists")
	check(registry != null, "Registry autoload exists")
	if combat == null or registry == null:
		_finish()
		return

	# Every definition the asset table can hand out must load and validate. A typo in a path there
	# is otherwise a family that is silently scenery again, which is the whole of F-114.
	var definitions: Dictionary[StringName, Resource] = {}
	for path: String in HARVEST_LIBRARY.definition_paths():
		var definition: Resource = load(path)
		check(definition != null, "%s loads" % path)
		if definition == null:
			continue
		var errors: PackedStringArray = definition.call("validation_errors")
		check(errors.is_empty(), "%s validates (%s)" % [path, "; ".join(errors)])
		check(bool(registry.call("has_item", definition.get("yield_item_id"))),
			"%s yields a registered item '%s'" % [path, definition.get("yield_item_id")])
		definitions[StringName(String(definition.get("id")))] = definition

	for weapon_id: StringName in EXPECTED_SWINGS:
		var weapon: Resource = _weapon(combat, registry, weapon_id)
		check(weapon != null, "weapon '%s' resolves" % weapon_id)
		if weapon == null:
			continue
		var table: Dictionary = EXPECTED_SWINGS[weapon_id]
		for harvestable_id: StringName in table:
			var definition: Resource = definitions.get(harvestable_id)
			check(definition != null, "harvestable '%s' is in the asset table" % harvestable_id)
			if definition == null:
				continue
			var expected: int = int(table[harvestable_id])
			var actual: int = _swings_to_deplete(definition, weapon)
			check(actual == expected, "%s -> %s: %s (expected %s)" % [
				weapon_id, harvestable_id, _swings_label(actual), _swings_label(expected)
			])

	# Awaited: `_check_live_prop` is a coroutine (it yields a frame so the prop is in the tree), and
	# calling it bare would let this function reach `_finish()` and quit before a single live
	# assertion ran — a check that passes by not running is worse than no check.
	await _check_live_prop(definitions.get(&"tree"), _weapon(combat, registry, &"stone_axe"))
	print("HARVEST_TOOL_LADDER failures=%d" % failures)
	_finish()


## One real Harvestable taken down by real calls, so the arithmetic above is proven against the
## component and not just against itself — including that the third swing is the one that yields.
func _check_live_prop(definition: Resource, weapon: Resource) -> void:
	if definition == null or weapon == null:
		return
	var prop: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	prop.name = "LadderProp"
	prop.set("definition", definition)
	root.add_child(prop)
	await process_frame

	var tool_class: int = int(weapon.get("tool_class"))
	var power: int = int(weapon.get("harvest_power"))
	check(bool(prop.call("host_apply_tool_damage", tool_class, power, 1)), "swing 1 connects")
	check(bool(prop.get("active")), "a tree still stands after one stone-axe swing")
	check(bool(prop.call("host_apply_tool_damage", tool_class, power, 1)), "swing 2 connects")
	check(bool(prop.get("active")), "a tree still stands after two stone-axe swings")
	check(bool(prop.call("host_apply_tool_damage", tool_class, power, 1)), "swing 3 connects")
	check(not bool(prop.get("active")), "the third stone-axe swing fells it")

	# A wrong-tool connect must still report as a hit — the thunk is how you learn to switch tools —
	# but it must not move health.
	check(bool(prop.call("host_respawn")), "prop respawns for the wrong-tool case")
	var before: int = int(prop.get("health"))
	check(bool(prop.call("host_apply_tool_damage", HARVEST_LIBRARY.Tool.NONE, 1, 1)),
		"a bare-handed swing at a tree still registers as a connect")
	check(int(prop.get("health")) == before, "a bare-handed swing takes nothing off a tree")
	prop.queue_free()


func _swings_to_deplete(definition: Resource, weapon: Resource) -> int:
	var per_swing: int = int(definition.call(
		"damage_from_tool", int(weapon.get("tool_class")), int(weapon.get("harvest_power"))
	))
	if per_swing <= 0:
		return -1
	return ceili(float(int(definition.get("max_health"))) / float(per_swing))


func _swings_label(swings: int) -> String:
	return "never" if swings < 0 else "%d swing(s)" % swings


func _weapon(combat: Node, registry: Node, weapon_id: StringName) -> Resource:
	if weapon_id == &"unarmed":
		return combat.get("unarmed") as Resource
	return registry.call("get_weapon", weapon_id) as Resource


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	quit(1 if failures > 0 else 0)
