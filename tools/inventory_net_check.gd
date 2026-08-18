extends SceneTree

## Real two-process ENet proof for task 2.4. A trusted host harvest grant targets the client, the
## client receives only its snapshot, accepted/rejected destructive requests are confirmed, and no
## client path can mint items.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const PORT: int = 47425
const RESULT_PATH: String = "user://inventory_net_client.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var inventory: Node
var child_pid: int = 0
var confirmations: Dictionary[int, bool] = {}


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	inventory = root.get_node_or_null(^"InventoryService")
	if transport == null or inventory == null:
		fail("NetTransport and InventoryService autoloads must exist")
		finish()
		return
	inventory.get("operation_confirmed").connect(_on_operation_confirmed)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "inventory-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== inventory network check (task 2.4) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	await process_frame
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")
	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false)), TIMEOUT_SEC
	)
	check(connected, "client receives its initial authoritative snapshot")
	if not connected:
		finish()
		return
	var client_peer_id: int = int(_read_result().get("peer_id", 0))
	check(client_peer_id > NetConfig.HOST_PEER_ID, "client reports a real peer id")
	check(int(inventory.call("host_count", client_peer_id, &"log")) == 0,
		"host creates the client inventory empty")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"log")) == 0,
		"host inventory is isolated from client inventory")

	EVENT_BUS.emit_harvest_yielded(&"net_tree", client_peer_id, &"log", 3, Vector3.ZERO)
	var granted: bool = await _until(
		func() -> bool: return bool(_read_result().get("granted", false)), TIMEOUT_SEC
	)
	check(granted, "client receives its host-only harvest grant")
	check(int(inventory.call("host_count", client_peer_id, &"log")) == 3,
		"host owns the granted count")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"log")) == 0,
		"grant does not leak into host inventory")

	var complete: bool = await _until(
		func() -> bool: return bool(_read_result().get("complete", false)), TIMEOUT_SEC
	)
	check(complete, "client completes accepted, rejected, and move requests")
	var result: Dictionary = _read_result()
	check(bool(result.get("remove_accepted", false)), "client receives accepted removal confirmation")
	check(bool(result.get("overspend_rejected", false)), "client receives rejected overspend confirmation")
	check(bool(result.get("move_accepted", false)), "client receives accepted slot-move confirmation")
	check(bool(result.get("direct_add_rejected", false)), "client cannot call the trusted host grant seam")
	check(int(result.get("log_count", -1)) == 1, "client finishes with one confirmed log")
	check(int(inventory.call("host_count", client_peer_id, &"log")) == 1,
		"host and client agree on the final count")
	var client_slots: Array = inventory.call("host_slots", client_peer_id)
	check(
		client_slots.size() == 32
		and (client_slots[0] as Dictionary).is_empty()
		and StringName(String((client_slots[24] as Dictionary).get("item_id", ""))) == &"log",
		"host owns distinct backpack and hotbar slot layouts"
	)

	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	# D-035 (F-052): a departed peer's inventory is PARKED, not released — `peer_left` cannot tell a
	# drop from a rejoin, so the host holds the slots until `run_player_expired` (90 s grace).
	# The old assertion here polled for the slots to empty, which is the exact behaviour F-032's fix
	# removed on purpose. Assert the parking instead, plus the registry counting one orphan.
	var session: Node = root.get_node_or_null(^"NetSession")
	var parked: bool = await _until(
		func() -> bool: return (not (inventory.call("host_slots", client_peer_id) as Array).is_empty()
			and session != null and int(session.call("orphaned_run_players")) == 1),
		TIMEOUT_SEC
	)
	check(parked, "host parks a departed peer's inventory for the D-035 grace window")

	# F-074: _valid_host_peer() used to require peer_id in transport.peer_ids() even for a peer with
	# a live parked _host_stores entry, so host_add()/host_remove()/host_move_stack()/
	# host_transaction() all rejected a mid-grace-window mutation outright — a harvest yield landing
	# for a laggy or briefly dropped peer was silently lost, logged only as "could not collect ...
	# (invalid or full)" by _on_harvest_yielded. Call the real public API, not _commit() directly, to
	# prove it now reaches a parked peer's store.
	var pre_grant_count: int = int(inventory.call("host_count", client_peer_id, &"log"))
	var granted_while_parked: bool = bool(inventory.call("host_add", client_peer_id, &"log", 4))
	check(granted_while_parked, "host_add() reaches a peer parked mid-D-035-grace-window")
	check(
		int(inventory.call("host_count", client_peer_id, &"log")) == pre_grant_count + 4,
		"the grant lands on the parked peer's store"
	)
	# _publish_snapshot() gates its rpc_id send on _peer_connected() (F-059) — the parked peer has no
	# live transport connection, so the commit above must complete without an engine "unknown peer
	# ID" error. No assertion here can catch that (push_error does not raise); per SPECS.md rule 4
	# the caller must grep this run's own output for `ERROR:`.
	transport.call("leave")
	print("INVENTORY_NET_CHECK peer=%d final_logs=%d failures=%d result=%s" % [
		client_peer_id, int(result.get("log_count", -1)), failures, result
	])
	finish()


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call(
		"join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT
	)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var ready: bool = await _until(_client_inventory_ready, TIMEOUT_SEC)
	if not ready:
		_write_result({"error": "initial inventory snapshot timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	_write_result({
		"connected": true,
		"peer_id": peer_id,
		"granted": false,
		"complete": false,
	})
	var grant_seen: bool = await _until(
		func() -> bool: return int(inventory.call("local_count", &"log")) == 3,
		TIMEOUT_SEC
	)
	if not grant_seen:
		_write_result({"connected": true, "peer_id": peer_id, "error": "grant timeout"})
		finish()
		return
	_write_result({
		"connected": true,
		"peer_id": peer_id,
		"granted": true,
		"complete": false,
	})
	await create_timer(0.5).timeout

	var remove_id: int = int(inventory.call("request_remove", &"log", 2))
	var remove_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(remove_id), TIMEOUT_SEC
	)
	var remove_accepted: bool = remove_confirmed and bool(confirmations.get(remove_id, false))
	var remove_applied: bool = await _until(
		func() -> bool: return int(inventory.call("local_count", &"log")) == 1,
		TIMEOUT_SEC
	)

	var overspend_id: int = int(inventory.call("request_remove", &"log", 99))
	var overspend_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(overspend_id), TIMEOUT_SEC
	)
	var overspend_rejected: bool = (
		overspend_confirmed and not bool(confirmations.get(overspend_id, true))
	)

	var move_id: int = int(inventory.call("request_move_stack", 0, 24))
	var move_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(move_id), TIMEOUT_SEC
	)
	var move_accepted: bool = move_confirmed and bool(confirmations.get(move_id, false))
	var move_applied: bool = await _until(_client_log_in_hotbar_zero, TIMEOUT_SEC)
	var direct_add_rejected: bool = not bool(inventory.call("host_add", peer_id, &"log", 50))
	_write_result({
		"connected": true,
		"peer_id": peer_id,
		"granted": true,
		"complete": remove_applied and move_applied,
		"remove_accepted": remove_accepted,
		"overspend_rejected": overspend_rejected,
		"move_accepted": move_accepted,
		"direct_add_rejected": direct_add_rejected,
		"log_count": int(inventory.call("local_count", &"log")),
	})
	# Keep the peer present long enough for the driver to inspect host-owned state before proving
	# peer_left cleanup. The result file is not a transport acknowledgement.
	await create_timer(1.0).timeout
	finish()


func _on_operation_confirmed(request_id: int, accepted: bool, _detail: String) -> void:
	confirmations[request_id] = accepted


## F-060: gate on is_active() directly. local_peer_id() > HOST_PEER_ID and local_revision >= 0 can
## both already read true while the connection is still CONNECTING, not CONNECTED — ENet hands a
## client its own unique id locally before the host<->client handshake completes.
func _client_inventory_ready() -> bool:
	return (
		bool(transport.call("is_active"))
		and int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
		and int(inventory.call("local_revision")) >= 0
	)


func _client_log_in_hotbar_zero() -> bool:
	var slots: Array = inventory.call("local_slots")
	return (
		slots.size() == 32
		and (slots[0] as Dictionary).is_empty()
		and StringName(String((slots[24] as Dictionary).get("item_id", ""))) == &"log"
	)


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/inventory_net_check.gd",
		"--", "inventory-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


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
