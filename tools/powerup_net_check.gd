extends SceneTree

## Real two-process ENet proof for task 3.3's replication split.
##
##   .agent/bin/agent godot --script tools/powerup_net_check.gd
##
## Same shape as tools/day_night_net_check.gd — the driver hosts and plays the HOST in-process, a
## spawned child process is the CLIENT, and they talk through a user:// JSON file.
##
## Three things this proves that the offline check cannot, all of them about the owner/teammate
## split that is the spec's actual requirement ("owner gets full replication; teammates get counts
## only"):
##
##   1. The owner receives its OWN full id -> stacks map, so a client-authoritative system (own
##      movement, §2.2 row 1) can resolve its own stats locally without asking the host per frame.
##   2. Everybody receives per-family COUNTS for everybody, so a teammate's Resonance is visible —
##      §4.4 makes that a social decision at every chest.
##   3. A teammate does NOT receive the identities. The client can see the host is three-deep in
##      Kinetic and still cannot name a single powerup the host holds. This is the assertion that
##      would silently pass if the snapshot were broadcast by mistake, and no offline check can
##      catch it because offline there is only one peer.
##
## It also covers the mid-run join: the client is granted nothing until AFTER it connects for (1),
## but the host arranges its own powerups BEFORE the client exists, so (2) and (3) are only true if
## `_on_peer_joined` sends the board to a joiner.

const PORT: int = 47461
const RESULT_PATH: String = "user://powerup_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://powerup_net_driver.json"
const TIMEOUT_SEC: float = 15.0

const BASE_SPEED: float = 4.4

var failures: int = 0
var transport: Node
var service: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	service = root.get_node_or_null(^"PowerupService")
	if transport == null or service == null:
		fail("NetTransport and PowerupService autoloads must exist (is PowerupService registered?)")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "powerup-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== powerup replication over real ENet (task 3.3) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_write_driver_signal({"should_exit": false})

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	await process_frame

	# The host arranges its OWN powerups before the client exists. Everything the client later knows
	# about the host therefore had to arrive through the mid-run join path.
	service.call(&"host_clear", NetConfig.HOST_PEER_ID)
	service.call(&"host_grant", NetConfig.HOST_PEER_ID, &"swift_stride", 3)
	check(bool(service.call(&"resonance_active", NetConfig.HOST_PEER_ID, &"Kinetic")),
		"host is Kinetic-resonant before the client connects")

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")
	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false)), TIMEOUT_SEC
	)
	check(connected, "client connects")
	if not connected:
		finish()
		return

	var client_peer: int = int(_read_result().get("peer_id", 0))
	check(client_peer > NetConfig.HOST_PEER_ID, "client has its own peer id (%d)" % client_peer)

	# Now grant to the CLIENT, after it exists — this is the ordinary mid-run chest case.
	var granted: int = int(service.call(&"host_grant", client_peer, &"swift_stride", 3))
	check(granted == 3, "host granted the client 3 stacks (%d)" % granted)

	var arrived: bool = await _until(
		func() -> bool: return int(_read_result().get("own_stacks", 0)) == 3, TIMEOUT_SEC
	)
	check(arrived, "the owner's full map reaches it over the wire")

	var report: Dictionary = _read_result()
	check(bool(report.get("own_resonance", false)),
		"the client's own Kinetic Resonance is active on the client")
	var expected_speed: float = BASE_SPEED * (1.0 + 0.08 * 3.0)
	check(is_equal_approx(float(report.get("own_speed", 0.0)), expected_speed),
		"the client resolves its own move_speed locally: %.4f (got %.4f)" %
			[expected_speed, float(report.get("own_speed", 0.0))])

	# The teammate half. The client must know the host's family COUNT and none of its identities.
	check(int(report.get("host_kinetic_count", -1)) == 3,
		"the client sees the host's Kinetic count of 3 (got %d)" %
			int(report.get("host_kinetic_count", -1)))
	check(bool(report.get("host_resonance", false)),
		"and therefore that the host is Resonant")
	check(int(report.get("host_named_stacks", -1)) == 0,
		"but cannot name a single powerup the host holds (got %d)" %
			int(report.get("host_named_stacks", -1)))

	_write_driver_signal({"should_exit": true})
	await _until(func() -> bool: return not OS.is_process_running(child_pid), 5.0)
	check(int(_read_result().get("failures", 1)) == 0,
		"client-side self checks report 0 failures")

	print("\nPOWERUP_NET_CHECK failures=%d" % failures)
	finish()


func _run_client() -> void:
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, "", PORT)
	if error != OK:
		_write_result({"error": "join returned %s" % error_string(error)})
		finish()
		return
	var joined: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC
	)
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	while not bool(_read_driver_signal().get("should_exit", false)):
		_write_client_snapshot()
		await create_timer(0.1).timeout
	_write_client_snapshot()
	transport.call("leave")
	finish()


func _write_client_snapshot() -> void:
	var me: int = int(transport.call("local_peer_id"))
	var client_failures: int = 0
	if bool(transport.call("is_host")):
		client_failures += 1  # the join target was LOCAL; this process must never be the host
	_write_result({
		"connected": true,
		"peer_id": me,
		"own_stacks": int(service.call(&"stacks_of", me, &"swift_stride")),
		"own_resonance": bool(service.call(&"resonance_active", me, &"Kinetic")),
		"own_speed": float(service.call(&"stat", me, &"move_speed", BASE_SPEED)),
		"host_kinetic_count": int(service.call(
			&"family_count", NetConfig.HOST_PEER_ID, &"Kinetic")),
		"host_resonance": bool(service.call(
			&"resonance_active", NetConfig.HOST_PEER_ID, &"Kinetic")),
		# The privacy half: counts arrived, identities must not have.
		"host_named_stacks": int(service.call(
			&"stacks_of", NetConfig.HOST_PEER_ID, &"swift_stride")),
		"failures": client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/powerup_net_check.gd",
		"--", "powerup-probe",
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


func _write_driver_signal(result: Dictionary) -> void:
	var file := FileAccess.open(DRIVER_SIGNAL_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()


func _read_driver_signal() -> Dictionary:
	if not FileAccess.file_exists(DRIVER_SIGNAL_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DRIVER_SIGNAL_PATH))
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
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	quit(0 if failures == 0 else 1)
