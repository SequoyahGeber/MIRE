extends SceneTree

## Real two-process ENet proof for task 3.5. The driver hosts and relaunches this script as a
## client; both build the same Chest at the same node path (mirrors harvestable_net_check.gd). The
## client alone requests the open; the host alone rolls and grants; the resulting `opened` bool
## replicates back, independent of the direct grant reply.

const CHEST_SCRIPT := preload("res://systems/loot/chest.gd")
const LOOT_TABLE_DEF_SCRIPT := preload("res://systems/loot/loot_table_def.gd")
const LOOT_ENTRY_SCRIPT := preload("res://systems/loot/loot_entry.gd")
const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")

const PORT: int = 47424
const RESULT_PATH: String = "user://chest_net_client.json"
const TEST_ITEM_ID: StringName = &"net_check_widget"
const TEST_TIER: StringName = &"net_check_tier"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var player_net: Node
var inventory: Node
var registry: Node
var chest: Node3D
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	inventory = root.get_node_or_null(^"InventoryService")
	registry = root.get_node_or_null(^"Registry")
	if transport == null or player_net == null or inventory == null or registry == null:
		fail("NetTransport, PlayerNet, InventoryService and Registry autoloads must exist")
		finish()
		return
	_build_content_and_chest()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "chest-probe":
		_run_client()
	else:
		_run_driver()


func _build_content_and_chest() -> void:
	# F-060: mutating what Node.get() hands back for a strictly-typed Dictionary property may not
	# alias the original — always .set() it back explicitly afterward.
	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", TEST_ITEM_ID)
	item.set("stack_size", 999)
	var items: Dictionary = registry.get("items")
	items[TEST_ITEM_ID] = item
	registry.set("items", items)

	var entry: Resource = LOOT_ENTRY_SCRIPT.new()
	entry.set("item_id", TEST_ITEM_ID)
	entry.set("min_amount", 4)
	entry.set("max_amount", 4)
	entry.set("weight", 1.0)

	var entries: Array[LOOT_ENTRY_SCRIPT] = [entry]
	var table: Resource = LOOT_TABLE_DEF_SCRIPT.new()
	table.set("id", TEST_TIER)
	table.set("coin_min", 7)
	table.set("coin_max", 7)
	table.set("roll_count", 1)
	table.set("entries", entries)

	var loot_tables: Dictionary = registry.get("loot_tables")
	loot_tables[TEST_TIER] = table
	registry.set("loot_tables", loot_tables)

	var world := Node3D.new()
	world.name = "ChestNetWorld"
	root.add_child(world)
	chest = CHEST_SCRIPT.new() as Node3D
	chest.name = "Chest"
	chest.set("tier", TEST_TIER)
	# Generous on purpose: this check does not control the connecting player's exact spawn
	# transform, only that PlayerNet spawned one (same reasoning harvestable_net_check.gd's own
	# request_range_m=10.0 documents).
	chest.set("request_range_m", 500.0)
	world.add_child(chest)


func _run_driver() -> void:
	print("\n== chest network check (task 3.5) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	# F-107: a GDScript lambda captures an outer local BY VALUE, not by reference — assigning
	# client_peer inside the _until closure below updated only the closure's own copy, so the
	# outer client_peer stayed at its -1 sentinel even after got_peer reported success. That fed
	# host_count() a peer_id <= 0, which _valid_host_peer() rejects, reading back 0 unconditionally
	# regardless of what the host actually granted. Re-scan peer_ids() directly in the outer scope
	# once _until confirms a peer is present, instead of writing into the closure's copy.
	var client_peer: int = -1
	var got_peer: bool = await _until(func() -> bool:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				return true
		return false
	, TIMEOUT_SEC)
	check(got_peer, "host observes the client's peer id")
	if got_peer:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				client_peer = peer_id
				break

	var opened: bool = await _until(func() -> bool: return bool(chest.get("opened")), TIMEOUT_SEC)
	check(opened, "host's own chest opens from the client's request")
	if got_peer:
		check(
			int(inventory.call("host_count", client_peer, &"coins")) == 7,
			"host's InventoryService grants coins to the requesting peer, not the host"
		)
		check(
			int(inventory.call("host_count", client_peer, TEST_ITEM_ID)) == 4,
			"host's InventoryService grants the rolled item to the requesting peer"
		)
		check(
			int(inventory.call("host_count", NetConfig.HOST_PEER_ID, TEST_ITEM_ID)) == 0,
			"the host's own inventory receives nothing from someone else's chest"
		)

	var result: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool:
		return bool(r.get("rejected_second_open", false))
	)
	check(bool(result.get("accepted", false)), "client's own open request was accepted")
	check(int(result.get("granted_coins", -1)) == 7, "client's grant reply carries the rolled coins")
	check(
		int(result.get("granted_item", -1)) == 4, "client's grant reply carries the rolled item"
	)
	check(
		bool(result.get("replicated_opened", false)),
		"client observes `opened` flip through replication, independent of its own grant reply"
	)
	check(
		bool(result.get("rejected_second_open", false)),
		"a second open request against an already-open chest is rejected"
	)

	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	transport.call("leave")
	print("CHEST_NET_CHECK failures=%d result=%s" % [failures, result])
	finish()


func _run_client() -> void:
	_write_result({"connected": false, "accepted": false, "replicated_opened": false, "rejected_second_open": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	# F-060: gate on is_active() directly. local_peer_id() > HOST_PEER_ID can read true the instant
	# ENet hands back a local unique id, before the host<->client handshake actually completes.
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	var spawned: bool = await _until(func() -> bool:
		return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	if not spawned:
		_write_result({"error": "player spawn timeout"})
		finish()
		return
	_write_result({"connected": true, "accepted": false, "replicated_opened": false, "rejected_second_open": false})

	var confirmations: Array = []
	chest.connect(&"open_confirmed", func(_rid, accepted, granted, _detail):
		confirmations.append({"accepted": accepted, "granted": granted})
	)
	chest.call("request_open")
	var confirmed: bool = await _until(func() -> bool: return confirmations.size() >= 1, TIMEOUT_SEC)
	if not confirmed:
		_write_result({"error": "open confirmation timeout"})
		finish()
		return
	var first: Dictionary = confirmations[0]
	var granted: Dictionary = first.get("granted", {})
	_write_result({
		"connected": true,
		"accepted": bool(first.get("accepted", false)),
		"granted_coins": int(granted.get(&"coins", -1)),
		"granted_item": int(granted.get(TEST_ITEM_ID, -1)),
		"replicated_opened": false,
		"rejected_second_open": false,
	})

	var replicated: bool = await _until(func() -> bool: return bool(chest.get("opened")), TIMEOUT_SEC)
	chest.call("request_open")
	var second_confirmed: bool = await _until(func() -> bool: return confirmations.size() >= 2, TIMEOUT_SEC)
	var rejected_second: bool = second_confirmed and not bool(confirmations[1].get("accepted", true))
	_write_result({
		"connected": true,
		"accepted": bool(first.get("accepted", false)),
		"granted_coins": int(granted.get(&"coins", -1)),
		"granted_item": int(granted.get(TEST_ITEM_ID, -1)),
		"replicated_opened": replicated,
		"rejected_second_open": rejected_second,
	})
	finish()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/chest_net_check.gd",
		"--", "chest-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _wait_for_result(done: Callable) -> Dictionary:
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	var result: Dictionary = _read_result()
	while Time.get_ticks_msec() < deadline_msec:
		result = _read_result()
		if bool(done.call(result)):
			return result
		await create_timer(0.05).timeout
	return result


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _write_result(result: Dictionary) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	return parsed if parsed is Dictionary else {}


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	fail(description)


func fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
	quit(0 if failures == 0 else 1)
