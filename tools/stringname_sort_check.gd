extends SceneTree

## Focused proof for F-175: the three `Array[StringName].sort()` call sites F-167's own fix did not
## touch, now switched to `sort_custom(func(a, b): return String(a) < String(b))` the same way
## `CraftingService.recipes_for_station()` was fixed under F-167. `StringName`'s `<` compares
## interned identity, not string content, so plain `.sort()` on an `Array[StringName]` silently does
## not produce alphabetical order.
##
##   .agent/bin/agent godot --script tools/stringname_sort_check.gd
##
## Covers: RuleService.rule_ids(), InventoryStore._sorted_ids(), ChestUI's reward-row order. A
## fourth pair of sites (CommandService.spec_names()/function_names()) is still bugged — filed as
## F-179 rather than fixed here, since autoload/command_service.gd was held by another lane's claim
## for the whole session (F-157).
const InventoryStoreScript := preload("res://systems/inventory/inventory_store.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	_check_rule_service()
	await _check_inventory_store()
	await _check_chest_ui()

	print("\nSTRINGNAME_SORT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_rule_service() -> void:
	var rules: Node = root.get_node_or_null(^"RuleService")
	check(rules != null, "RuleService autoload exists")
	if rules == null:
		return
	var ids: Array = rules.call("rule_ids")
	var expected: Array = ids.duplicate()
	expected.sort_custom(func(a, b): return String(a) < String(b))
	check(ids.size() >= 2, "rule_ids() has enough entries to prove ordering (%d)" % ids.size())
	check(ids == expected, "RuleService.rule_ids() is lexicographic: %s" % [ids])


func _check_inventory_store() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		return
	var store: InventoryStoreScript = InventoryStoreScript.new(registry, 32)
	var values: Dictionary = {&"wooden_axe": 1, &"arrow": 2, &"mushroom": 3}
	var sorted_ids: Array = store.call("_sorted_ids", values)
	check(sorted_ids == [&"arrow", &"mushroom", &"wooden_axe"],
		"InventoryStore._sorted_ids() is lexicographic: %s" % [sorted_ids])


func _check_chest_ui() -> void:
	var chest_ui: Node = root.get_node_or_null(^"ChestUI")
	check(chest_ui != null, "ChestUI autoload exists")
	if chest_ui == null:
		return

	chest_ui.call("_populate_rewards", {&"wooden_axe": 1, &"arrow": 2, &"mushroom": 3})
	check(int(chest_ui.call("reward_row_count")) == 3, "chest UI rendered all three reward rows")

	var reward_box: Node = chest_ui.find_child("Rewards", true, false)
	check(reward_box != null, "chest UI built its Rewards container")
	if reward_box != null:
		var names: Array[String] = []
		for row: Node in reward_box.get_children():
			var label: Label = row.find_children("*", "Label", true, false)[0] as Label
			names.append(label.text)
		check(names == ["Arrow", "Mushroom", "Wooden Axe"],
			"chest UI reward rows are lexicographic by item id: %s" % [names])

	chest_ui.call("_clear_rewards")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
