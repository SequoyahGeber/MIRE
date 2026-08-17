extends SceneTree

## Real two-process ENet proof for task 2.6. A client submits only a recipe id; the host derives its
## peer/player, validates workbench range, atomically spends ingredients, and confirms the result.

const PORT: int = 47426
const RESULT_PATH: String = "user://crafting_net_client.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var player_net: Node
var inventory: Node
var crafting: Node
var child_pid: int = 0
var confirmations: Dictionary[int, Dictionary] = {}


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	inventory = root.get_node_or_null(^"InventoryService")
	crafting = root.get_node_or_null(^"CraftingService")
	if transport == null or player_net == null or inventory == null or crafting == null:
		fail("NetTransport, PlayerNet, InventoryService, and CraftingService autoloads must exist")
		finish()
		return
	crafting.get("craft_confirmed").connect(_on_craft_confirmed)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "crafting-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== crafting network check (task 2.6) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var workbench := Node3D.new()
	workbench.name = "NetworkCheckWorkbench"
	workbench.set_meta(&"asset", "station_workbench_primitive")
	workbench.add_to_group(&"playtest_hollow_asset")
	root.add_child(workbench)

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
	check(connected, "client receives its initial authoritative inventory")
	if not connected:
		finish()
		return
	var peer_id: int = int(_read_result().get("peer_id", 0))
	check(peer_id > NetConfig.HOST_PEER_ID, "client reports a real peer id")
	check(player_net.call("player_for", peer_id) != null,
		"host owns the requesting client's player")

	check(bool(inventory.call("host_add", peer_id, &"log", 2)), "host grants client recipe logs")
	check(bool(inventory.call("host_add", peer_id, &"stone", 3)), "host grants client recipe stone")
	var granted: bool = await _until(
		func() -> bool: return bool(_read_result().get("granted", false)), TIMEOUT_SEC
	)
	check(granted, "client receives both authoritative ingredients")

	var complete: bool = await _until(
		func() -> bool: return bool(_read_result().get("complete", false)), TIMEOUT_SEC
	)
	check(complete, "client completes accepted and rejected craft requests")
	var result: Dictionary = _read_result()
	check(bool(result.get("craft_accepted", false)), "client receives accepted craft confirmation")
	check(bool(result.get("repeat_rejected", false)), "client receives rejected repeat confirmation")
	check(int(result.get("axe_count", -1)) == 1, "client snapshot contains one crafted stone axe")
	check(int(result.get("log_count", -1)) == 0, "client snapshot spent its logs")
	check(int(result.get("stone_count", -1)) == 0, "client snapshot spent its stone")
	check(int(inventory.call("host_count", peer_id, &"stone_axe")) == 1,
		"host owns the crafted output")
	check(int(inventory.call("host_count", peer_id, &"log")) == 0,
		"host owns the spent log count")
	check(int(inventory.call("host_count", peer_id, &"stone")) == 0,
		"host owns the spent stone count")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"stone_axe")) == 0,
		"client craft does not leak output to host inventory")

	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	var peer_removed: bool = await _until(
		func() -> bool: return (inventory.call("host_slots", peer_id) as Array).is_empty(),
		TIMEOUT_SEC
	)
	check(peer_removed, "host releases departed client's crafted inventory")
	transport.call("leave")
	print("CRAFTING_NET_CHECK peer=%d axe_count=%d failures=%d result=%s" % [
		peer_id, int(result.get("axe_count", -1)), failures, result
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
	_write_result({"connected": true, "peer_id": peer_id, "granted": false, "complete": false})
	var ingredients_seen: bool = await _until(
		func() -> bool:
			return (
				int(inventory.call("local_count", &"log")) == 2
				and int(inventory.call("local_count", &"stone")) == 3
			),
		TIMEOUT_SEC
	)
	if not ingredients_seen:
		_write_result({"connected": true, "peer_id": peer_id, "error": "ingredient timeout"})
		finish()
		return
	_write_result({"connected": true, "peer_id": peer_id, "granted": true, "complete": false})
	await create_timer(0.25).timeout

	var craft_id: int = int(crafting.call("request_craft", &"stone_axe"))
	var craft_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(craft_id), TIMEOUT_SEC
	)
	var craft_accepted: bool = (
		craft_confirmed and bool((confirmations.get(craft_id, {}) as Dictionary).get("accepted", false))
	)
	var craft_applied: bool = await _until(
		func() -> bool:
			return (
				int(inventory.call("local_count", &"stone_axe")) == 1
				and int(inventory.call("local_count", &"log")) == 0
				and int(inventory.call("local_count", &"stone")) == 0
			),
		TIMEOUT_SEC
	)

	var repeat_id: int = int(crafting.call("request_craft", &"stone_axe"))
	var repeat_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(repeat_id), TIMEOUT_SEC
	)
	var repeat_rejected: bool = (
		repeat_confirmed
		and not bool((confirmations.get(repeat_id, {}) as Dictionary).get("accepted", true))
	)
	_write_result({
		"connected": true,
		"peer_id": peer_id,
		"granted": true,
		"complete": craft_applied and repeat_confirmed,
		"craft_accepted": craft_accepted,
		"repeat_rejected": repeat_rejected,
		"axe_count": int(inventory.call("local_count", &"stone_axe")),
		"log_count": int(inventory.call("local_count", &"log")),
		"stone_count": int(inventory.call("local_count", &"stone")),
	})
	await create_timer(1.0).timeout
	finish()


func _on_craft_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	confirmations[request_id] = {"accepted": accepted, "detail": detail}


func _client_inventory_ready() -> bool:
	return (
		int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
		and int(inventory.call("local_revision")) >= 0
	)


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/crafting_net_check.gd",
		"--", "crafting-probe",
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
		child_pid = 0
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	quit(0 if failures == 0 else 1)
