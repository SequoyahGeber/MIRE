extends SceneTree

## **Can the client pick anything up?** Real two-process ENet proof of the loop's most-repeated verb.
##
##   .agent/bin/agent godot --script tools/item_drop_net_check.gd
##
## Since F-535 every harvest yield becomes a physical `ItemDrop` on the ground, so "pick it up" is
## now the step between every swing and every crafting recipe. It is also entirely host-authoritative
## and entirely invisible to the client until it works: the host runs the proximity scan, the host
## calls `InventoryService.host_add()`, and the host emits `collected`. If any of that fails to reach
## the client, the item vanishes off the ground and never appears in the pack — the player just loses
## it, with no error, forever. That is a slow, silent progression-killer rather than a crash.
##
## `tools/item_drop_check.gd` proves the drop in one process. This asserts the four cross-process
## facts it cannot:
##
##   1. a drop the HOST spawns exists on the CLIENT (spawner replication)
##   2. **auto-pickup fires for a client walking over it** — the host's scan must see a client body
##   3. the item lands in the CLIENT's own inventory, not just the host's ledger
##   4. `PickupFeedService` reaches the client, which is what makes the pickup visible at all (F-581)

const PORT: int = 47433
const RESULT_PATH: String = "user://item_drop_net_client.json"
const TEST_ITEM_ID: StringName = &"log"
const TIMEOUT_SEC: float = 20.0
const DROP_POSITION := Vector3(3.0, 0.5, 0.0)
const AWAY := Vector3(40.0, 0.0, 0.0)

var failures: int = 0
var transport: Node
var player_net: Node
var inventory: Node
var drops: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	inventory = root.get_node_or_null(^"InventoryService")
	drops = root.get_node_or_null(^"ItemDropService")
	if transport == null or player_net == null or inventory == null or drops == null:
		fail("NetTransport, PlayerNet, InventoryService and ItemDropService autoloads must exist")
		finish()
		return
	_build_floor()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "drop-probe":
		_run_client()
	else:
		_run_driver()


## Both peers build it: without ground, every body falls out of pickup range and the failure is
## indistinguishable from broken replication (the trap extraction_net_check.gd hit first).
func _build_floor() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "NetCheckFloor"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 2.0, 200.0)
	shape.shape = box
	floor_body.add_child(shape)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -1.0, 0.0)


func _run_driver() -> void:
	print("\n== item drop network check — can the client pick anything up? ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var got_peer: bool = await _until(func() -> bool:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				return true
		return false, TIMEOUT_SEC)
	check(got_peer, "client connects to the host")
	var client_peer: int = 0
	for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
		if peer_id != NetConfig.HOST_PEER_ID:
			client_peer = peer_id

	var both: bool = await _until(func() -> bool:
		return get_nodes_in_group(&"players").size() >= 2, TIMEOUT_SEC)
	check(both, "the host sees both player bodies")

	# The host's own player goes far away, so nothing it does can collect the drop — otherwise a
	# passing check would not distinguish "the client picked it up" from "the host did".
	var host_player: Node3D = player_net.call("player_for", NetConfig.HOST_PEER_ID) as Node3D
	if host_player != null:
		host_player.global_position = AWAY

	# Wait for the client to report it is standing clear, then drop the item next to it.
	var staged: bool = await _until(func() -> bool:
		return bool(_read_result().get("staged", false)), TIMEOUT_SEC)
	check(staged, "client reported it is in position")

	var before: int = int(inventory.call(&"host_count", client_peer, TEST_ITEM_ID))
	var drop: Node3D = drops.call(&"host_spawn_drop", TEST_ITEM_ID, 3, DROP_POSITION) as Node3D
	check(drop != null, "the host spawns a ground drop")

	var seen_by_client: bool = await _until(func() -> bool:
		return bool(_read_result().get("saw_drop", false)), TIMEOUT_SEC)
	check(seen_by_client, "the drop replicates to the client — it can SEE the item on the ground")

	# The client now walks onto it. Everything after this is the host's proximity scan reading a
	# client-authoritative position, which is the fact this file exists to prove.
	var collected: bool = await _until(func() -> bool:
		return int(inventory.call(&"host_count", client_peer, TEST_ITEM_ID)) >= before + 3,
		TIMEOUT_SEC)
	check(collected,
		"auto-pickup fires for a CLIENT walking over the drop (host ledger %d -> %d)" %
		[before, int(inventory.call(&"host_count", client_peer, TEST_ITEM_ID))])
	check(int(drops.call(&"live_count")) == 0, "the collected drop leaves the world")

	var result: Dictionary = await _wait_for_result()
	print("ITEM_DROP_NET_CHECK failures=%d result=%s" % [failures, JSON.stringify(result, "  ")])
	check(bool(result.get("in_client_inventory", false)),
		"the item is in the CLIENT's own inventory, not merely in the host's ledger")
	check(bool(result.get("feed_fired", false)),
		"PickupFeedService announced it on the CLIENT — without this the pickup is invisible (F-581)")
	finish()


func _run_client() -> void:
	_write_result({"staged": false, "saw_drop": false, "in_client_inventory": false,
		"feed_fired": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"final": true, "error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")),
		TIMEOUT_SEC)
	if not connected:
		_write_result({"final": true, "error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	# F-107: re-fetch in the outer scope; a lambda captures outer locals by value.
	var spawned: bool = await _until(func() -> bool:
		return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	var body: Node3D = player_net.call("player_for", peer_id) as Node3D
	if not spawned or body == null:
		_write_result({"final": true, "error": "player spawn timeout"})
		finish()
		return

	var announced: Array[bool] = [false]
	var feed: Node = root.get_node_or_null(^"PickupFeedService")
	if feed != null:
		feed.connect(&"pickup_received", func(_kind, id, _amount, _source) -> void:
			if id == TEST_ITEM_ID:
				announced[0] = true)

	# Stand clear of where the drop will land, so the pickup cannot happen before the walk.
	body.global_position = Vector3(12.0, 0.0, 0.0)
	await _until(func() -> bool: return false, 1.0)
	_write_result({"staged": true, "saw_drop": false, "in_client_inventory": false,
		"feed_fired": false})

	var saw_drop: bool = await _until(func() -> bool:
		return get_nodes_in_group(&"item_drop").size() > 0, TIMEOUT_SEC)
	_write_result({"staged": true, "saw_drop": saw_drop, "in_client_inventory": false,
		"feed_fired": false})

	# Walk onto it — own movement, applied locally, exactly as a player does.
	body.global_position = DROP_POSITION
	var in_pack: bool = await _until(func() -> bool:
		return int(inventory.call(&"local_count", TEST_ITEM_ID)) >= 3, TIMEOUT_SEC)
	await process_frame
	_write_result({
		"final": true,
		"staged": true,
		"saw_drop": saw_drop,
		"in_client_inventory": in_pack,
		"feed_fired": announced[0],
	})
	finish()


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	return parsed as Dictionary if parsed is Dictionary else {}


func _wait_for_result() -> Dictionary:
	await _until(func() -> bool: return bool(_read_result().get("final", false)), TIMEOUT_SEC * 2.0)
	return _read_result()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	return OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/item_drop_net_check.gd",
		"--", "drop-probe",
	]))


func _write_result(data: Dictionary) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()


func _until(condition: Callable, seconds: float = TIMEOUT_SEC) -> bool:
	var waited: float = 0.0
	while waited < seconds:
		if bool(condition.call()):
			return true
		await process_frame
		waited += 1.0 / 60.0
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func fail(description: String) -> void:
	check(false, description)


func finish() -> void:
	if child_pid > 0:
		OS.kill(child_pid)
	quit(0 if failures == 0 else 1)
