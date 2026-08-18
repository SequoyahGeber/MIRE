extends SceneTree

## Real two-process ENet proof for task 3.9's selection replication.
##
##   .agent/bin/agent godot --script tools/attunement_net_check.gd
##
## Same shape as tools/powerup_net_check.gd — the driver hosts and plays the HOST in-process, a
## spawned child process is the CLIENT, and they talk through a user:// JSON file.
##
## Three things this proves that the offline check cannot:
##
##   1. A CLIENT's request genuinely round-trips through the host (net_request_attunement ->
##      net_attunement_confirmed), not a call the client could fake locally.
##   2. Every peer sees EVERY peer's pick — the host's pre-existing selection reaches a joiner
##      (net_attunement_selected replay in `_on_peer_joined`, the mid-run-join case), and the
##      client's own pick reaches the host in the other direction.
##   3. A second request from the same peer is refused over the real wire, not just in-process.

const PORT: int = 47466
const RESULT_PATH: String = "user://attunement_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://attunement_net_driver.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var service: Node
var powerups: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	service = root.get_node_or_null(^"AttunementService")
	powerups = root.get_node_or_null(^"PowerupService")
	if transport == null or service == null or powerups == null:
		fail("NetTransport, AttunementService and PowerupService autoloads must all exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "attunement-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== attunement selection over real ENet (task 3.9) ==")
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

	# The host picks its OWN role before the client exists. Everything the client later knows about
	# the host's pick therefore had to arrive through the mid-run join path.
	powerups.call(&"host_clear", NetConfig.HOST_PEER_ID)
	service.call(&"request_select", &"warden")
	check(String(service.call(&"selection_of", NetConfig.HOST_PEER_ID)) == "warden",
		"host picked warden before the client connects")

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

	var saw_host_pick: bool = await _until(
		func() -> bool: return String(_read_result().get("host_selection", "")) == "warden", TIMEOUT_SEC
	)
	check(saw_host_pick, "the joiner learns the host's pre-existing pick (mid-run join)")

	_write_driver_signal({"should_exit": false, "request": "reaver"})
	var confirmed: bool = await _until(
		func() -> bool: return bool(_read_result().get("first_confirmed", false)), TIMEOUT_SEC
	)
	check(confirmed, "the client's own request round-trips through the host and confirms")
	# `net_attunement_confirmed` (drives first_confirmed) and `net_attunement_selected` (drives
	# own_selection) are two separate RPCs sent back-to-back from the host — poll rather than
	# assume the second has landed the instant the first is observed.
	var own_selection_arrived: bool = await _until(
		func() -> bool: return String(_read_result().get("own_selection", "")) == "reaver", TIMEOUT_SEC
	)
	check(own_selection_arrived,
		"the client's own selection reads back as what it asked for")

	# Read the HOST's own dictionary directly (this driver process IS the host) rather than trusting
	# anything the client reports about itself — this is the assertion that would silently pass if
	# the request never actually reached the host at all.
	check(String(service.call(&"selection_of", client_peer)) == "reaver",
		"the host's own record of the client's pick is correct, host-side")
	check(int(powerups.call(&"stacks_of", client_peer, &"attunement_reaver")) == 1,
		"the host actually granted the client's backing powerup, host-side")

	_write_driver_signal({"should_exit": false, "request": "tinker"})
	var refused: bool = await _until(
		func() -> bool: return bool(_read_result().get("second_confirmed", false)), TIMEOUT_SEC
	)
	check(refused, "the second request over the wire gets an answer at all")
	check(not bool(_read_result().get("second_accepted", true)),
		"and the answer is a refusal — locked after the first real pick")
	check(String(_read_result().get("own_selection", "")) == "reaver",
		"the client's selection is unchanged by the refused second request")

	_write_driver_signal({"should_exit": true})
	await _until(func() -> bool: return not OS.is_process_running(child_pid), 5.0)
	check(int(_read_result().get("failures", 1)) == 0, "client-side self checks report 0 failures")

	print("\nATTUNEMENT_NET_CHECK failures=%d" % failures)
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

	service.connect(&"selection_confirmed", _on_confirmed)
	var last_request: String = ""
	while not bool(_read_driver_signal().get("should_exit", false)):
		var signal_data: Dictionary = _read_driver_signal()
		var wanted: String = String(signal_data.get("request", ""))
		if wanted != "" and wanted != last_request:
			last_request = wanted
			var sent_count: int = _confirm_count + 1
			service.call(&"request_select", StringName(wanted))
			# Wait for THIS request to resolve before reading the next distinct driver signal — both
			# confirmations fire the same signal, so counting them keeps the two attempts ordered.
			await _until(func() -> bool: return _confirm_count >= sent_count, TIMEOUT_SEC)
		_write_client_snapshot()
		await create_timer(0.1).timeout
	_write_client_snapshot()
	transport.call("leave")
	finish()


var _confirm_count: int = 0
var _first_accepted: bool = false
var _first_detail: String = ""
var _second_accepted: bool = false


func _on_confirmed(accepted: bool, _attunement_id: StringName, detail: String) -> void:
	_confirm_count += 1
	if _confirm_count == 1:
		_first_accepted = accepted
		_first_detail = detail
	else:
		_second_accepted = accepted


func _write_client_snapshot() -> void:
	var me: int = int(transport.call("local_peer_id"))
	var client_failures: int = 0
	if bool(transport.call("is_host")):
		client_failures += 1  # the join target was LOCAL; this process must never be the host
	_write_result({
		"connected": true,
		"peer_id": me,
		"host_selection": String(service.call(&"selection_of", NetConfig.HOST_PEER_ID)),
		"own_selection": String(service.call(&"selection_of", me)),
		"first_confirmed": _confirm_count >= 1,
		"second_confirmed": _confirm_count >= 2,
		"second_accepted": _second_accepted,
		"first_detail": _first_detail,
		"failures": client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/attunement_net_check.gd",
		"--", "attunement-probe",
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
