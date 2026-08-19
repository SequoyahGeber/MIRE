extends SceneTree

## F-210 proof: `Chest._ready()` now derives its RNG seed from `(GameState.run_seed, this node's own
## stable name)` instead of boot-time `randomize()` — see `systems/loot/chest.gd`'s `_seed_for_run()`/
## `_run_seed()`. Two chests sharing (run_seed, name) must roll identically; changing either input
## must change the roll (a wide 1..999 amount range makes a coincidental match astronomically
## unlikely, same confidence `seed_sync_check.gd` relies on for its own equality checks).
##
##   .agent/bin/agent godot --script tools/chest_seed_check.gd
##
## Same synthetic Registry injection `chest_check.gd` uses (3.5's header) — content is hand-authored,
## this proves the framework without bulk-generating a real .tres.

const CHEST_SCRIPT := preload("res://systems/loot/chest.gd")
const LOOT_TABLE_DEF_SCRIPT := preload("res://systems/loot/loot_table_def.gd")
const LOOT_ENTRY_SCRIPT := preload("res://systems/loot/loot_entry.gd")
const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")

const TEST_ITEM_ID: StringName = &"chest_seed_check_widget"
const TEST_TIER: StringName = &"chest_seed_check_tier"

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("\n== F-210 chest seed determinism check ==")
	var registry: Node = root.get_node_or_null(^"Registry")
	var game_state: Node = root.get_node_or_null(^"GameState")
	check(registry != null, "Registry autoload exists")
	check(game_state != null, "GameState autoload exists")
	if registry == null or game_state == null:
		finish()
		return

	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", TEST_ITEM_ID)
	item.set("stack_size", 999)
	var items: Dictionary = registry.get("items")
	items[TEST_ITEM_ID] = item
	registry.set("items", items)

	var entry: Resource = LOOT_ENTRY_SCRIPT.new()
	entry.set("item_id", TEST_ITEM_ID)
	entry.set("min_amount", 1)
	entry.set("max_amount", 999)
	entry.set("weight", 1.0)

	var entries: Array[LOOT_ENTRY_SCRIPT] = [entry]
	var table: Resource = LOOT_TABLE_DEF_SCRIPT.new()
	table.set("id", TEST_TIER)
	table.set("coin_min", 0)
	table.set("coin_max", 0)
	table.set("roll_count", 1)
	table.set("entries", entries)
	check((table.call("validation_errors") as PackedStringArray).is_empty(), "test table is valid")

	var loot_tables: Dictionary = registry.get("loot_tables")
	loot_tables[TEST_TIER] = table
	registry.set("loot_tables", loot_tables)

	# ── Case 1: same run_seed, same chest id -> identical roll. ────────────────────────────────
	game_state.call("set_replicated_seed", 20260819)
	var roll_a: Dictionary = await _spawn_and_roll("Chest_seed_check_a")
	var roll_b: Dictionary = await _spawn_and_roll("Chest_seed_check_a")
	check(not roll_a.is_empty() and roll_a == roll_b,
		"same run_seed + same chest id rolls identically (%s vs %s)" % [roll_a, roll_b])

	# ── Case 2: same run_seed, different chest id -> different roll. ───────────────────────────
	var roll_c: Dictionary = await _spawn_and_roll("Chest_seed_check_c")
	check(roll_a != roll_c,
		"same run_seed, different chest id rolls differently (%s vs %s)" % [roll_a, roll_c])

	# ── Case 3: different run_seed, same chest id -> different roll. ───────────────────────────
	game_state.call("set_replicated_seed", 424242)
	var roll_d: Dictionary = await _spawn_and_roll("Chest_seed_check_a")
	check(roll_a != roll_d,
		"different run_seed, same chest id rolls differently (%s vs %s)" % [roll_a, roll_d])

	var cleanup_items: Dictionary = registry.get("items")
	cleanup_items.erase(TEST_ITEM_ID)
	registry.set("items", cleanup_items)
	var cleanup_tables: Dictionary = registry.get("loot_tables")
	cleanup_tables.erase(TEST_TIER)
	registry.set("loot_tables", cleanup_tables)

	print("CHEST_SEED_CHECK failures=%d" % failures)
	finish()


## Builds a real Chest under the given stable node name — ChestPlacementService's own naming
## contract, "Chest_<marker name>", is what makes a placed chest's id deterministic across peers —
## lets it `_ready()` (where the seed is actually drawn), opens it offline (host-of-one, same path
## `chest_check.gd` proves), and returns what it granted. `remove_child()` + `free()` rather than
## `queue_free()`: the next call reuses the same name, and a still-pending deferred free would make
## `add_child()` silently uniquify that name instead of colliding, breaking the "same id" premise
## this check exists to prove.
func _spawn_and_roll(chest_name: String) -> Dictionary:
	var chest: Node3D = CHEST_SCRIPT.new() as Node3D
	chest.name = chest_name
	chest.set("tier", TEST_TIER)
	root.add_child(chest)
	await process_frame

	var confirmations: Array = []
	chest.connect(&"open_confirmed", func(_rid, accepted, granted, _detail):
		confirmations.append({"accepted": accepted, "granted": granted})
	)
	chest.call("request_open")

	var granted: Dictionary = {}
	if confirmations.size() == 1 and bool(confirmations[0]["accepted"]):
		granted = confirmations[0]["granted"]
	else:
		failures += 1
		push_error("FAIL: chest '%s' opened successfully" % chest_name)

	root.remove_child(chest)
	chest.free()
	return granted


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
