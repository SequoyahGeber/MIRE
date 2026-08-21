extends SceneTree

## Real host/client proof for F-411. The client uses GodModeService.request_local_enabled(), exactly
## what the Settings checkbox calls: non-op refusal, host op grant, approved state on both peers,
## host-side damage immunity, then disable and ordinary damage restoration.
##
##   .agent/bin/agent godot --script tools/god_mode_net_check.gd

const PORT: int = 47541
const RESULT_PATH: String = "user://god_mode_net_client.json"
const SIGNAL_PATH: String = "user://god_mode_net_driver.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var player_net: Node
var commands: Node
var god_mode: Node
var health: Node
var child_pid: int = 0
var _request_done: bool = false
var _request_accepted: bool = false
var _request_detail: String = ""


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	commands = root.get_node_or_null(^"CommandService")
	god_mode = root.get_node_or_null(^"GodModeService")
	health = root.get_node_or_null(^"PlayerHealth")
	if transport == null or player_net == null or commands == null or god_mode == null or health == null:
		fail("required autoloads exist")
		finish()
		return

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "god-mode-probe":
		await _run_client()
	else:
		await _run_driver()


func _run_driver() -> void:
	_remove_file(RESULT_PATH)
	_remove_file(SIGNAL_PATH)
	check(transport.call(&"host", NetConfig.Mode.LOCAL, PORT) == OK, "host starts")
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var connected: bool = await _until(func() -> bool:
		return (transport.call(&"peer_ids") as PackedInt32Array).size() >= 2, TIMEOUT_SEC)
	check(connected, "host observes the client")
	var client_peer: int = _remote_peer()

	var refused: Dictionary = await _wait_result("refused")
	check(bool(refused.get("refused", false)), "Settings request is refused before the client is opped")
	check(String(refused.get("refused_detail", "")).begins_with("not op"),
		"refusal is CommandService's authority gate")
	check(not bool(god_mode.call(&"is_enabled", client_peer)),
		"a refused client never enters the host canonical set")

	if client_peer > 0:
		var ctx: Dictionary = commands.call(&"build_local_ctx", &"console")
		var op_result: Dictionary = await commands.call(&"execute", "op %d" % client_peer, ctx)
		check(bool(op_result.get("ok", false)), "host ops the client")

	var enabled: Dictionary = await _wait_result("enabled")
	check(bool(enabled.get("enabled", false)), "the same Settings request succeeds after op")
	check(bool(enabled.get("local_enabled", false)), "the owning client adopts approved flight state")
	check(bool(god_mode.call(&"is_enabled", client_peer)), "the host canonical set matches the client")
	check(not bool(health.call(&"host_apply_damage", client_peer, 10, 0)),
		"host-side damage authority rejects damage to the remote God-mode player")

	_write_json(SIGNAL_PATH, {"disable": true})
	var disabled: Dictionary = await _wait_result("disabled")
	check(bool(disabled.get("disabled", false)), "the client Settings toggle disables God mode")
	check(not bool(disabled.get("local_enabled", true)), "the owning client's flight state clears")
	check(not bool(god_mode.call(&"is_enabled", client_peer)), "the host canonical set clears")
	check(bool(health.call(&"host_apply_damage", client_peer, 5, 0)),
		"ordinary remote-player damage resumes after disable")

	var exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(exited, "client exits cleanly")
	if exited:
		child_pid = 0
	transport.call(&"leave")
	print("GOD_MODE_NET_CHECK failures=%d" % failures)
	finish()


func _run_client() -> void:
	_write_json(RESULT_PATH, {})
	if transport.call(&"join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT) != OK:
		_write_result({"error": "join failed"})
		finish()
		return
	var connected: bool = await _until(func() -> bool:
		return bool(transport.call(&"is_active")), TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call(&"local_peer_id"))
	var spawned: bool = await _until(func() -> bool:
		return player_net.call(&"player_for", peer_id) != null, TIMEOUT_SEC)
	if not spawned:
		_write_result({"error": "spawn timeout"})
		finish()
		return

	god_mode.connect(&"god_mode_request_completed", _on_request_completed)
	var first_accepted: bool = await _request_mode(true)
	_write_result({"refused": not first_accepted, "refused_detail": _request_detail})

	var accepted: bool = first_accepted
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while not accepted and Time.get_ticks_msec() < deadline:
		await create_timer(0.3).timeout
		accepted = await _request_mode(true)
	var local_on: bool = await _until(func() -> bool:
		return bool(god_mode.call(&"is_local_enabled")), TIMEOUT_SEC)
	_write_result({"enabled": accepted, "local_enabled": local_on})

	var disable_signal: bool = await _until(func() -> bool:
		return bool(_read_json(SIGNAL_PATH).get("disable", false)), TIMEOUT_SEC)
	var disabled: bool = false
	if disable_signal:
		disabled = await _request_mode(false)
	var local_off: bool = await _until(func() -> bool:
		return not bool(god_mode.call(&"is_local_enabled")), TIMEOUT_SEC)
	_write_result({"disabled": disabled, "local_enabled": not local_off})
	transport.call(&"leave")
	finish()


func _request_mode(enabled: bool) -> bool:
	_request_done = false
	_request_accepted = false
	_request_detail = "request timed out"
	god_mode.call(&"request_local_enabled", enabled)
	await _until(func() -> bool: return _request_done, TIMEOUT_SEC)
	return _request_done and _request_accepted


func _on_request_completed(_enabled: bool, accepted: bool, detail: String) -> void:
	_request_done = true
	_request_accepted = accepted
	_request_detail = detail


func _remote_peer() -> int:
	for peer_id: int in transport.call(&"peer_ids") as PackedInt32Array:
		if peer_id != NetConfig.HOST_PEER_ID:
			return peer_id
	return -1


func _spawn_client() -> int:
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "tools/god_mode_net_check.gd", "--", "god-mode-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _wait_result(key: String) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	var result: Dictionary = _read_json(RESULT_PATH)
	while Time.get_ticks_msec() < deadline:
		result = _read_json(RESULT_PATH)
		if result.has(key):
			return result
		await create_timer(0.05).timeout
	return result


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _write_result(update: Dictionary) -> void:
	var merged: Dictionary = _read_json(RESULT_PATH)
	merged.merge(update, true)
	_write_json(RESULT_PATH, merged)


func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data))
	file.close()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
		return
	fail(label)


func fail(label: String) -> void:
	failures += 1
	push_error("FAIL: %s" % label)


func finish() -> void:
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
	quit(1 if failures > 0 else 0)
