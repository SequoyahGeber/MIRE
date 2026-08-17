extends SceneTree

## Real two-process ENet proof for task 2.10. The host spawns, simulates, damages and kills; the
## client receives a body it never simulates. The interesting assertions are all negative ones —
## what the client does NOT do is the authority claim.

const PORT: int = 47428
const RESULT_PATH: String = "user://enemy_net_client.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var world: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	world = root.get_node_or_null(^"EnemyWorld")
	if transport == null or world == null:
		fail("NetTransport and EnemyWorld autoloads must exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "enemy-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== enemy network check (task 2.10) ==")
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
	check(connected, "client connects")
	if not connected:
		finish()
		return

	var enemy: Node3D = world.call("host_spawn", &"crawler", Vector3(0.0, 0.0, -4.0))
	check(enemy != null, "host spawns a crawler")
	if enemy == null:
		finish()
		return

	var seen: bool = await _until(
		func() -> bool: return int(_read_result().get("enemy_count", 0)) >= 1, TIMEOUT_SEC
	)
	check(seen, "the client receives the spawned enemy")
	var after_spawn: Dictionary = _read_result()
	check(not bool(after_spawn.get("client_simulates", true)),
		"the client's copy runs no physics — it simulates no AI at all")
	check(bool(after_spawn.get("client_interpolated", false)),
		"the client's copy is smoothed by NetInterp (F-004)")
	check(int(after_spawn.get("health", -1)) == int(enemy.get("health")),
		"the client sees the host's health")

	check(bool(enemy.call("host_apply_damage", 4, NetConfig.HOST_PEER_ID)), "host damages it")
	var damaged: bool = await _until(
		func() -> bool: return int(_read_result().get("health", -1)) == int(enemy.get("health")),
		TIMEOUT_SEC
	)
	check(damaged, "the damage replicates to the client")

	check(bool(enemy.call("host_apply_damage", 9999, NetConfig.HOST_PEER_ID)), "host kills it")
	check(not bool(enemy.call("is_alive")), "the host records it as dead")
	var died: bool = await _until(
		func() -> bool: return int(_read_result().get("state", -1)) == 5, TIMEOUT_SEC
	)
	check(died, "the client is told it died")

	var gone: bool = await _until(
		func() -> bool: return int(world.call("live_count")) == 0, TIMEOUT_SEC
	)
	check(gone, "the host stops counting it among the living")

	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	transport.call("leave")
	print("ENEMY_NET_CHECK failures=%d result=%s" % [failures, _read_result()])
	finish()


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var ready: bool = await _until(
		func() -> bool: return int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID,
		TIMEOUT_SEC
	)
	if not ready:
		_write_result({"error": "never connected"})
		finish()
		return
	_write_result({"connected": true, "enemy_count": 0})

	# Report continuously until the driver has what it needs; the host's state changes are what the
	# assertions are about, so the client just mirrors whatever it currently believes. It exits once
	# it has seen the enemy die — a client that runs a fixed wall-clock loop outlives the driver's
	# patience and fails "client exits cleanly" for no reason.
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 3.0 * 1000.0)
	var saw_death: bool = false
	while Time.get_ticks_msec() < deadline:
		var enemies: Array[Node] = root.get_tree().get_nodes_in_group(&"enemies")
		var payload: Dictionary = {"connected": true, "enemy_count": enemies.size()}
		if not enemies.is_empty():
			var enemy: Node = enemies[0]
			payload["health"] = int(enemy.get("health"))
			payload["state"] = int(enemy.get("state"))
			payload["client_simulates"] = bool(enemy.call("is_physics_processing"))
			payload["client_interpolated"] = enemy.get_node_or_null(^"RemoteInterp") != null
		_write_result(payload)
		if int(payload.get("state", -1)) == 5:
			saw_death = true
		elif saw_death:
			# The corpse is gone and the death has been reported; nothing further to mirror.
			break
		await create_timer(0.1).timeout
	await create_timer(0.4).timeout
	finish()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	return OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/enemy_net_check.gd",
		"--", "enemy-probe",
	]))


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
