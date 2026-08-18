extends SceneTree

## Real two-process ENet proof for task 3.8b's wire surface: the `dodging` flag PlayerController
## replicates over its existing (position/rotation) synchronizer actually reaches the HOST, and the
## host's i-frame decision — PlayerHealth._on_enemy_attack_landed() reading that flag before applying
## damage — genuinely answers a REMOTE client's dodge, not just a same-process one.
##
## Two players, real PlayerController bodies via PlayerNet, same shape as
## tools/player_vitals_net_check.gd. The driver (host, peer 1) is also the one thing that can fire a
## believable "enemy hit" — EnemyWorld enemies are host-only and this check has no live enemy, so it
## calls EVENT_BUS.emit_enemy_attack_landed() directly on the host process, exactly the call
## systems/enemies/enemy.gd makes at the end of a real telegraphed swing (see that file's own note on
## the event). What's under test is everything downstream of that call, not the enemy AI itself.
##
## The CLIENT executes its own dodge directly through PlayerController._execute_dodge() rather than
## simulating a real InputEventAction press — tools/player_vitals_net_check.gd's stamina ticker makes
## the identical call for the identical reason: the input->_execute_dodge() wiring is proven offline
## by tools/dodge_check.gd, so this check's own job is the RPC/replication surface, not re-proving
## input handling over a second harness.

const PORT: int = 47441
const RESULT_PATH: String = "user://dodge_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://dodge_net_driver.json"
const TIMEOUT_SEC: float = 15.0

const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0
var transport: Node
var player_net: Node
var health: Node
var child_pid: int = 0
var max_hp: int = 100


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	health = root.get_node_or_null(^"PlayerHealth")
	if transport == null or player_net == null or health == null:
		fail("NetTransport, PlayerNet and PlayerHealth autoloads must exist")
		finish()
		return
	max_hp = int(health.get("max_hp"))

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "dodge-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== dodge network check (task 3.8b) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

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
	check(connected, "client connects and receives its authoritative snapshot")
	if not connected:
		finish()
		return
	var client_peer_id: int = int(_read_result().get("peer_id", 0))
	check(client_peer_id > NetConfig.HOST_PEER_ID, "client reports a real peer id")

	var client_body: Node3D = await _wait_for_body(client_peer_id)
	check(client_body != null, "the host has a real PlayerController for the client")
	if client_body == null:
		finish()
		return

	check(int(health.call(&"host_hp", client_peer_id)) == max_hp, "client starts at full hp")
	check(not bool(client_body.get("dodging")),
		"the host's copy of the client's `dodging` flag starts false")

	# ── The client dodges; the flag must reach the host's own copy of that body ──────────────────────
	_write_driver_signal({"go_dodge": true})
	var saw_dodging: bool = await _until(
		func() -> bool: return bool(client_body.get("dodging")), TIMEOUT_SEC
	)
	check(saw_dodging,
		"the client's `dodging` flag replicates to the host over the real synchronizer wire")

	# ── I-frames: an enemy hit fired ON THE HOST, exactly the way systems/enemies/enemy.gd does it,
	#    must be dodged while the host still reads dodging == true ─────────────────────────────────────
	EVENT_BUS.emit_enemy_attack_landed(&"crawler", client_peer_id, 35, Vector3.ZERO)
	check(int(health.call(&"host_hp", client_peer_id)) == max_hp,
		"an enemy hit fired while the host still sees dodging==true costs the REMOTE client nothing")

	# ── Wait out the dash window on the host's own copy, then the identical hit must land ─────────────
	var dodge_ended: bool = await _until(
		func() -> bool: return not bool(client_body.get("dodging")), TIMEOUT_SEC
	)
	check(dodge_ended, "the host's copy of `dodging` clears once the client's dash window ends")
	EVENT_BUS.emit_enemy_attack_landed(&"crawler", client_peer_id, 35, Vector3.ZERO)
	check(int(health.call(&"host_hp", client_peer_id)) == max_hp - 35,
		"the SAME hit lands once dodging is false again — this was never a permanently-dead subscriber")

	_write_driver_signal({"go_dodge": true, "go_exit": true})
	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	transport.call("leave")
	print("DODGE_NET_CHECK client=%d failures=%d" % [client_peer_id, failures])
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
	var ready: bool = await _until(_client_ready, TIMEOUT_SEC)
	if not ready:
		_write_result({"error": "initial connection/spawn timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	var own_body: Node3D = await _wait_for_body(peer_id)
	if own_body == null:
		_write_result({"error": "own PlayerController never appeared"})
		finish()
		return
	_write_result({"connected": true, "peer_id": peer_id})

	var already_dodged: bool = false
	while true:
		var signal_data: Dictionary = _read_driver_signal()
		if bool(signal_data.get("go_dodge", false)) and not already_dodged:
			already_dodged = true
			# Direct call, not a simulated input event — see the file doc's own note on why.
			var accepted: bool = bool(own_body.call(&"_execute_dodge"))
			_merge_result({"dodge_accepted": accepted})
		if bool(signal_data.get("go_exit", false)):
			break
		await create_timer(0.05).timeout

	transport.call("leave")
	finish()


## is_active() alone is not enough (F-038's own lesson, see player_vitals_net_check.gd's
## _client_health_ready note) — PlayerNet spawns the local body asynchronously after the session
## opens, so this also waits for the client's own multiplayer-authority peer id to resolve.
func _client_ready() -> bool:
	return bool(transport.call("is_active")) \
		and int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID


func _wait_for_body(peer_id: int) -> Node3D:
	var found: bool = await _until(
		func() -> bool: return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC
	)
	return player_net.call("player_for", peer_id) as Node3D if found else null


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/dodge_net_check.gd",
		"--", "dodge-probe",
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


func _merge_result(patch: Dictionary) -> void:
	var current: Dictionary = _read_result()
	for key: String in patch:
		current[key] = patch[key]
	_write_result(current)


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
