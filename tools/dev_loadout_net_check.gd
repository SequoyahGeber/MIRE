extends SceneTree

## Two-process regression for F-540. It deliberately delivers player_spawned before the client's
## authoritative inventory store exists, then proves the first inventory-ready snapshot completes
## the promised starting grant on both host and client.

const PORT: int = 47540
const RESULT_PATH: String = "user://dev_loadout_net_client.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var inventory: Node
var dev_loadout: Node
var child_pid: int = 0


func _initialize() -> void:
	OS.set_environment("MIRE_DEV_LOADOUT", "1")
	_run.call_deferred()


func _run() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	inventory = root.get_node_or_null(^"InventoryService")
	dev_loadout = root.get_node_or_null(^"DevLoadout")
	if transport == null or inventory == null or dev_loadout == null:
		fail("NetTransport, InventoryService and DevLoadout autoloads must exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "loadout-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts")
	if error != OK:
		finish()
		return

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")
	var identified: bool = await _until(
		func() -> bool: return int(_read_result().get("peer_id", 0)) > NetConfig.HOST_PEER_ID,
		TIMEOUT_SEC
	)
	check(identified, "client reports its ENet peer id during first join")
	var joining_peer_id: int = int(_read_result().get("peer_id", 0))
	# Re-deliver the real PlayerNet seam at the join boundary. Depending on signal scheduling this
	# either grants immediately or queues until InventoryService's first authoritative snapshot.
	dev_loadout.call("_on_player_spawned", joining_peer_id, null)
	var complete: bool = await _until(
		func() -> bool: return bool(_read_result().get("complete", false)), TIMEOUT_SEC
	)
	check(complete, "joining client receives its starting inventory")
	var result: Dictionary = _read_result()
	var peer_id: int = int(result.get("peer_id", 0))
	check(peer_id == joining_peer_id, "the grant targets the joining peer, not the host")
	check(int(result.get("coins", -1)) == 50, "client receives 50 starting coins")
	check(int(inventory.call("host_count", peer_id, &"coins")) == 50,
		"host owns the same 50-coin count")
	check((dev_loadout.call("granted_peers") as PackedInt32Array).has(peer_id),
		"peer is marked granted only after the loadout succeeds")
	check(not bool(dev_loadout.call("grant", peer_id)), "a later grant cannot duplicate the loadout")
	check(int(inventory.call("host_count", peer_id, &"coins")) == 50,
		"duplicate protection keeps the coin count at 50")
	transport.call("leave")
	print("DEV_LOADOUT_NET_CHECK peer=%d coins=%d failures=%d" % [
		peer_id, int(result.get("coins", -1)), failures,
	])
	finish()


func _run_client() -> void:
	_write_result({"complete": false, "peer_id": 0})
	var error: Error = transport.call(
		"join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT
	)
	if error != OK:
		_write_result({"complete": false, "error": error_string(error)})
		finish()
		return
	_write_result({
		"complete": false,
		"peer_id": int(transport.call("local_peer_id")),
		"coins": int(inventory.call("local_count", &"coins")),
	})
	var ready: bool = await _until(
		func() -> bool:
			return bool(transport.call("is_active")) \
				and int(inventory.call("local_count", &"coins")) == 50,
		TIMEOUT_SEC
	)
	_write_result({
		"complete": ready,
		"peer_id": int(transport.call("local_peer_id")),
		"coins": int(inventory.call("local_count", &"coins")),
	})
	await create_timer(0.5).timeout
	finish()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/dev_loadout_net_check.gd",
		"--", "loadout-probe",
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
