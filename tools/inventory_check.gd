extends SceneTree

## Focused offline proof for task 2.4: stable stacks, all-or-nothing mutations, harvest grants,
## client-facing confirmations, slot movement, snapshots, and the atomic crafting seam.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const INVENTORY_STORE_SCRIPT := preload("res://systems/inventory/inventory_store.gd")

var failures: int = 0
var local_changes: int = 0
var host_changes: int = 0
var confirmations: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(registry != null, "Registry autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	if registry == null or inventory == null:
		finish()
		return
	inventory.get("local_inventory_changed").connect(_on_local_changed)
	inventory.get("host_inventory_changed").connect(_on_host_changed)
	inventory.get("operation_confirmed").connect(_on_confirmed)

	var slots: Array = inventory.call("local_slots")
	check(slots.size() == 24, "inventory exposes 24 stable slots")
	check(_occupied(slots) == 0, "offline inventory starts empty")
	check(int(inventory.call("hotbar_slot_count")) == 8,
		"first eight stable slots are reserved for hotbar UI")
	check(EVENT_BUS.harvest_yielded_subscriber_count() == 1,
		"InventoryService owns one harvest-yield subscription")

	EVENT_BUS.emit_harvest_yielded(&"tree", 1, &"log", 3, Vector3.ZERO)
	check(int(inventory.call("local_count", &"log")) == 3, "real harvest seam grants three logs")
	check(local_changes == 1 and host_changes == 1, "harvest publishes one confirmed revision")
	check(int(inventory.call("local_revision")) == 1, "first mutation advances revision to one")

	check(bool(inventory.call("host_add", 1, &"log", 96)), "host fills the existing log stack")
	slots = inventory.call("local_slots")
	check(int((slots[0] as Dictionary).get("amount", 0)) == 99, "stack is capped at ItemDef.stack_size")
	check(bool(inventory.call("host_add", 1, &"log", 1)), "overflow opens a second stable slot")
	slots = inventory.call("local_slots")
	check(int((slots[1] as Dictionary).get("amount", 0)) == 1, "overflow amount is preserved")

	var caller_copy: Array = inventory.call("local_slots")
	(caller_copy[0] as Dictionary)["amount"] = 1
	check(int(inventory.call("local_count", &"log")) == 100, "public snapshots cannot mutate authority")
	check(bool(inventory.call("host_remove", 1, &"log", 1)), "host removal succeeds when enough exists")
	slots = inventory.call("local_slots")
	check((slots[1] as Dictionary).is_empty(), "removal consumes high slots before stable early slots")

	var remove_request: int = int(inventory.call("request_remove", &"log", 9))
	check(_confirmation(remove_request).get("accepted", false), "offline request gets accepted confirmation")
	check(int(inventory.call("local_count", &"log")) == 90, "accepted request changes authoritative count")
	var revision_before_reject: int = int(inventory.call("local_revision"))
	var rejected_request: int = int(inventory.call("request_remove", &"log", 999))
	check(not bool(_confirmation(rejected_request).get("accepted", true)), "overspend is explicitly rejected")
	check(int(inventory.call("local_revision")) == revision_before_reject,
		"rejected request publishes no fake revision")

	check(bool(inventory.call(
		"host_transaction", 1, {&"log": 10}, {&"stone": 2}
	)), "atomic transaction removes ingredients and grants output")
	check(int(inventory.call("local_count", &"log")) == 80, "transaction removes exact ingredient amount")
	check(int(inventory.call("local_count", &"stone")) == 2, "transaction grants exact output amount")
	var before_failed_transaction: Array = inventory.call("local_slots")
	check(not bool(inventory.call(
		"host_transaction", 1, {&"log": 999}, {&"iron_ore": 2}
	)), "invalid transaction is rejected")
	check(inventory.call("local_slots") == before_failed_transaction, "failed transaction rolls back exactly")

	slots = inventory.call("local_slots")
	var stone_index: int = _first_item(slots, &"stone")
	check(stone_index >= 0, "stone stack has a stable slot")
	check(bool(inventory.call("host_move_stack", 1, stone_index, 7)), "host can move a whole stack")
	check(StringName(String((inventory.call("local_slots") as Array)[7].get("item_id", ""))) == &"stone",
		"moved stack lands in requested slot")
	check(bool(inventory.call("host_add", 1, &"stone", 97)), "same-item grant fills moved stack")
	var move_request: int = int(inventory.call("request_move_stack", 7, 8, 20))
	check(_confirmation(move_request).get("accepted", false), "split move is host-confirmed")
	slots = inventory.call("local_slots")
	check(int((slots[7] as Dictionary).get("amount", 0)) == 79, "split leaves source remainder")
	check(int((slots[8] as Dictionary).get("amount", 0)) == 20, "split creates exact destination amount")

	var tiny: RefCounted = INVENTORY_STORE_SCRIPT.new(registry, 2)
	check(bool(tiny.call("add", &"log", 198)), "isolated two-slot store fills exactly")
	check(not bool(tiny.call("add", &"log", 1)), "full store rejects the entire excess grant")
	check(int(tiny.call("count", &"log")) == 198, "failed grant loses and duplicates nothing")
	var valid_snapshot: Array = tiny.call("slots_snapshot")
	check(bool(INVENTORY_STORE_SCRIPT.snapshot_is_valid(valid_snapshot, registry, 2)),
		"valid authoritative snapshot passes client validation")
	var overflow_snapshot: Array = valid_snapshot.duplicate(true)
	(overflow_snapshot[0] as Dictionary)["amount"] = 100
	check(not bool(INVENTORY_STORE_SCRIPT.snapshot_is_valid(overflow_snapshot, registry, 2)),
		"client rejects a stack above its ItemDef limit")
	check(not bool(inventory.call("host_add", 2, &"log", 1)), "offline authority rejects an unknown peer")
	check(not bool(inventory.call("host_add", 1, &"missing", 1)), "unknown item ids are rejected")

	print("INVENTORY_CHECK local_changes=%d host_changes=%d confirmations=%d failures=%d" % [
		local_changes, host_changes, confirmations.size(), failures
	])
	finish()


func _on_local_changed(_slots: Array[Dictionary], _revision: int) -> void:
	local_changes += 1


func _on_host_changed(_peer_id: int, _slots: Array[Dictionary], _revision: int) -> void:
	host_changes += 1


func _on_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	confirmations.append({"request_id": request_id, "accepted": accepted, "detail": detail})


func _confirmation(request_id: int) -> Dictionary:
	for result: Dictionary in confirmations:
		if int(result.get("request_id", -1)) == request_id:
			return result
	return {}


func _occupied(slots: Array) -> int:
	var result: int = 0
	for value: Variant in slots:
		if value is Dictionary and not (value as Dictionary).is_empty():
			result += 1
	return result


func _first_item(slots: Array, item_id: StringName) -> int:
	for index: int in slots.size():
		if StringName(String((slots[index] as Dictionary).get("item_id", ""))) == item_id:
			return index
	return -1


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
