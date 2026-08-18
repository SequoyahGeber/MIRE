extends SceneTree

## Headless lifecycle proof for task 3.5. Uses the real Registry, exactly like harvestable_check.gd,
## and injects a synthetic item + LootTableDef so the framework is verified without bulk-authoring
## content — content/loot/small.tres and content/items/coins.tres are the one worked example each,
## proven for real by tools/chest_net_check.gd instead.

const CHEST_SCRIPT := preload("res://systems/loot/chest.gd")
const LOOT_TABLE_DEF_SCRIPT := preload("res://systems/loot/loot_table_def.gd")
const LOOT_ENTRY_SCRIPT := preload("res://systems/loot/loot_entry.gd")
const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")

const TEST_ITEM_ID: StringName = &"check_widget"
const TEST_TIER: StringName = &"check_tier"
const UNKNOWN_TIER: StringName = &"check_tier_missing"

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(registry != null, "Registry autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	if registry == null or inventory == null:
		finish()
		return

	# F-060: Object.get() on a strictly-typed Dictionary property can hand back a value that does not
	# alias the original — always .set() it back after mutating.
	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", TEST_ITEM_ID)
	item.set("stack_size", 999)
	var items: Dictionary = registry.get("items")
	items[TEST_ITEM_ID] = item
	registry.set("items", items)

	var entry: Resource = LOOT_ENTRY_SCRIPT.new()
	entry.set("item_id", TEST_ITEM_ID)
	entry.set("min_amount", 2)
	entry.set("max_amount", 2)
	entry.set("weight", 1.0)

	var entries: Array[LOOT_ENTRY_SCRIPT] = [entry]
	var table: Resource = LOOT_TABLE_DEF_SCRIPT.new()
	table.set("id", TEST_TIER)
	table.set("coin_min", 10)
	table.set("coin_max", 10)
	table.set("roll_count", 1)
	table.set("entries", entries)
	check((table.call("validation_errors") as PackedStringArray).is_empty(), "test table is valid")

	var loot_tables: Dictionary = registry.get("loot_tables")
	loot_tables[TEST_TIER] = table
	registry.set("loot_tables", loot_tables)
	check(registry.call("has_loot_table", TEST_TIER), "table reachable through Registry.get_loot_table")

	# ── LootTableDef.roll(), pure ────────────────────────────────────────────────────────────────
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var roll: Dictionary = table.call("roll", rng)
	check(int(roll.get("coins", -1)) == 10, "fixed coin_min == coin_max rolls exactly that amount")
	var rolled_items: Dictionary = roll.get("items", {})
	check(
		int(rolled_items.get(TEST_ITEM_ID, -1)) == 2,
		"single-entry table always grants that entry's fixed amount"
	)

	# ── Chest, offline (host-of-one) ────────────────────────────────────────────────────────────
	var chest: Node3D = CHEST_SCRIPT.new() as Node3D
	chest.name = "CheckChest"
	chest.set("tier", TEST_TIER)
	root.add_child(chest)
	await process_frame

	check(chest.is_in_group(&"chest"), "chest joins the chest group")
	check(not bool(chest.get("opened")), "chest starts closed")
	_check_replication(chest)

	var unknown_chest: Node3D = CHEST_SCRIPT.new() as Node3D
	unknown_chest.name = "CheckChestUnknownTier"
	unknown_chest.set("tier", UNKNOWN_TIER)
	root.add_child(unknown_chest)
	await process_frame
	var rejected: Array = []
	unknown_chest.connect(&"open_confirmed", func(rid, accepted, granted, detail):
		rejected.append({"id": rid, "accepted": accepted, "granted": granted, "detail": detail})
	)
	unknown_chest.call("request_open")
	check(rejected.size() == 1 and not bool(rejected[0]["accepted"]), "unknown tier is rejected")
	unknown_chest.queue_free()

	chest.call("host_seed_rng", 999)
	var confirmations: Array = []
	chest.connect(&"open_confirmed", func(rid, accepted, granted, detail):
		confirmations.append({"id": rid, "accepted": accepted, "granted": granted, "detail": detail})
	)
	var request_id: int = int(chest.call("request_open"))
	check(confirmations.size() == 1, "offline open answers synchronously")
	if confirmations.size() == 1:
		var confirmation: Dictionary = confirmations[0]
		check(int(confirmation["id"]) == request_id, "confirmation carries the caller's request id")
		check(bool(confirmation["accepted"]), "in-range open on an unopened chest is accepted")
		var granted: Dictionary = confirmation["granted"]
		check(int(granted.get(&"coins", -1)) == 10, "granted dictionary carries the rolled coins")
		check(int(granted.get(TEST_ITEM_ID, -1)) == 2, "granted dictionary carries the rolled item")
		check(
			int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"coins")) == 10,
			"InventoryService actually holds the granted coins"
		)
		check(
			int(inventory.call("host_count", NetConfig.HOST_PEER_ID, TEST_ITEM_ID)) == 2,
			"InventoryService actually holds the granted item"
		)
	check(bool(chest.get("opened")), "chest is open after a successful grant")

	chest.call("request_open")
	check(
		confirmations.size() == 2 and not bool(confirmations[1]["accepted"]),
		"a second open on an already-open chest is rejected"
	)

	var far_chest: Node3D = CHEST_SCRIPT.new() as Node3D
	far_chest.name = "CheckChestRange"
	far_chest.set("tier", TEST_TIER)
	far_chest.set("request_range_m", 1.0)
	root.add_child(far_chest)
	await process_frame
	check(
		int(far_chest.call("request_open")) > 0,
		"offline open still returns a request id even when a session would range-check"
	)
	far_chest.queue_free()

	chest.queue_free()
	# F-060: same .get()/.set() rule applies to erase() as to assignment — reassign explicitly.
	var cleanup_items: Dictionary = registry.get("items")
	cleanup_items.erase(TEST_ITEM_ID)
	registry.set("items", cleanup_items)
	var cleanup_loot_tables: Dictionary = registry.get("loot_tables")
	cleanup_loot_tables.erase(TEST_TIER)
	registry.set("loot_tables", cleanup_loot_tables)
	# The unknown-tier chest above deliberately provokes Chest's own rejection log once, on
	# purpose, to prove an unresolvable tier is refused. Standing rule 4 (docs/SPECS.md): declare
	# it by pattern rather than "fixing" it by silencing the production log call.
	print("CHEST_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"references unknown loot tier\"" % failures)
	finish()


func _check_replication(chest: Node3D) -> void:
	var sync := chest.get_node_or_null(^"ChestSync") as MultiplayerSynchronizer
	check(sync != null, "code-built ChestSync exists")
	if sync == null:
		return
	check(sync.get_multiplayer_authority() == NetConfig.HOST_PEER_ID, "ChestSync is host-authoritative")
	check(sync.root_path == NodePath(".."), "ChestSync replicates its parent")
	check(sync.is_in_group(NetConfig.SYNCED_GROUP), "ChestSync is counted by the net debug panel")
	check(
		is_equal_approx(sync.replication_interval, NetConfig.PROP_SYNC_INTERVAL_SEC),
		"ChestSync uses the prop replication interval"
	)
	var properties: Array[NodePath] = sync.replication_config.get_properties()
	check(properties == [NodePath(".:opened")], "opened is the entire replicated schema")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
