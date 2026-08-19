extends SceneTree

## Focused proof for F-175: the three `Array[StringName].sort()` call sites F-167's own fix did not
## touch, now switched to `sort_custom(func(a, b): return String(a) < String(b))` the same way
## `CraftingService.recipes_for_station()` was fixed under F-167. `StringName`'s `<` compares
## interned identity, not string content, so plain `.sort()` on an `Array[StringName]` silently does
## not produce alphabetical order.
##
##   .agent/bin/agent godot --script tools/stringname_sort_check.gd
##
## Covers: RuleService.rule_ids(), InventoryStore._sorted_ids(), ChestUI's reward-row order, and
## CommandService.spec_names()/function_names() (F-179 — the fourth/fifth site F-175 named but could
## not fix itself, since autoload/command_service.gd was held by another lane's claim all session).
const InventoryStoreScript := preload("res://systems/inventory/inventory_store.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	_check_rule_service()
	await _check_inventory_store()
	await _check_chest_ui()
	_check_command_service()

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


func _check_command_service() -> void:
	var commands: Node = root.get_node_or_null(^"CommandService")
	check(commands != null, "CommandService autoload exists")
	if commands == null:
		return

	var noop_handler: Callable = func(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
		return {"ok": true, "message": ""}
	# Registered out of alphabetical order on purpose — the bug this guards against is plain
	# `.sort()` silently keeping StringName interned-identity (roughly registration) order instead.
	for name: StringName in [&"zz_stringname_sort_check", &"aa_stringname_sort_check", &"mm_stringname_sort_check"]:
		commands.call("register_spec", name, {"handler": noop_handler})
	commands.call("register_function", &"zz_stringname_sort_check_fn", PackedStringArray())
	commands.call("register_function", &"aa_stringname_sort_check_fn", PackedStringArray())
	commands.call("register_function", &"mm_stringname_sort_check_fn", PackedStringArray())

	var spec_names: Array = commands.call("spec_names")
	var expected_spec_names: Array = spec_names.duplicate()
	expected_spec_names.sort_custom(func(a, b): return String(a) < String(b))
	check(spec_names.has(&"aa_stringname_sort_check") and spec_names.has(&"mm_stringname_sort_check")
		and spec_names.has(&"zz_stringname_sort_check"), "spec_names() includes all three test specs")
	check(spec_names == expected_spec_names, "CommandService.spec_names() is lexicographic: %s" % [spec_names])

	var function_names: Array = commands.call("function_names")
	var expected_function_names: Array = function_names.duplicate()
	expected_function_names.sort_custom(func(a, b): return String(a) < String(b))
	check(function_names.has(&"aa_stringname_sort_check_fn") and function_names.has(&"mm_stringname_sort_check_fn")
		and function_names.has(&"zz_stringname_sort_check_fn"), "function_names() includes all three test functions")
	check(function_names == expected_function_names,
		"CommandService.function_names() is lexicographic: %s" % [function_names])


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
