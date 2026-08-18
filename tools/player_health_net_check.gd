extends SceneTree

## Real two-process ENet proof for task 2.13. A client cannot revive itself, an out-of-range revive
## is rejected by the HOST's own copy of both positions (never a client-supplied distance), the
## downed flag reaches a peer other than the one who went down, and a run-player's health follows a
## reconnect under a new peer id (D-035) instead of resetting.
##
## Two players, real PlayerController bodies via PlayerNet, same shape as tools/combat_net_check.gd.
## The host (this driver process) plays peer 1 and downs ITSELF — the interesting replication proof
## is a peer other than the one who went down learning about it, and the driver already knows its own
## state, so having the client learn about the HOST is the genuine cross-peer case.

const PORT: int = 47429
const RESULT_PATH: String = "user://player_health_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://player_health_net_driver.json"
const TIMEOUT_SEC: float = 15.0

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
	if not args.is_empty() and args[0] == "player-health-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== player health network check (task 2.13) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_write_driver_signal({"host_close": false})

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

	var host_player: Node3D = await _wait_for_body(NetConfig.HOST_PEER_ID)
	var client_player: Node3D = await _wait_for_body(client_peer_id)
	check(host_player != null and client_player != null, "both bodies exist on the host")
	if host_player == null or client_player == null:
		finish()
		return

	# Far from the client's spawn — the out-of-range revive attempt below needs this to be real, not
	# asserted. Own player movement is CLIENT authority elsewhere, but the host is that client for its
	# own body, so writing its own position directly is legitimate here, not a special case.
	host_player.position = Vector3(300.0, 0.0, 300.0)
	check(bool(health.call(&"host_apply_damage", NetConfig.HOST_PEER_ID, max_hp, 0)),
		"host downs itself")
	check(bool(health.call(&"host_is_downed", NetConfig.HOST_PEER_ID)), "and is downed on the host")

	var saw_downed: bool = await _until(
		func() -> bool: return bool(_read_result().get("saw_host_downed", false)), TIMEOUT_SEC
	)
	check(saw_downed, "the downed flag replicates to a DIFFERENT peer, not just the one who went down")

	var self_tested: bool = await _until(
		func() -> bool: return bool(_read_result().get("self_revive_tested", false)), TIMEOUT_SEC
	)
	check(self_tested, "client attempts to revive itself")
	check(bool(_read_result().get("self_revive_rejected", false)),
		"a client cannot heal itself — the host rejects a self-targeted revive")

	var out_of_range_tested: bool = await _until(
		func() -> bool: return bool(_read_result().get("out_of_range_tested", false)), TIMEOUT_SEC
	)
	check(out_of_range_tested, "client attempts a revive while the host is far away")
	check(bool(_read_result().get("out_of_range_rejected", false)),
		"the host rejects it using its OWN copy of both positions")
	check(bool(health.call(&"host_is_downed", NetConfig.HOST_PEER_ID)),
		"and the host is still downed — the rejected attempt changed nothing")

	# Bring the host to exactly where the host's own (replicated) copy of the client sits, then let
	# the client know it can retry.
	host_player.position = client_player.global_position
	_write_driver_signal({"host_close": true})

	var revived: bool = await _until(
		func() -> bool: return bool(_read_result().get("revive_succeeded", false)), TIMEOUT_SEC
	)
	check(revived, "in range, the client's revive is accepted")
	check(bool(health.call(&"host_is_alive", NetConfig.HOST_PEER_ID)),
		"and the host is alive again, on the host's own authoritative state")
	check(int(health.call(&"host_hp", NetConfig.HOST_PEER_ID)) > 0
		and int(health.call(&"host_hp", NetConfig.HOST_PEER_ID)) < max_hp,
		"restored to a fraction of max hp, not a full heal")

	# ── D-035: the client's own health follows a reconnect under a new peer id ────────────────────
	# A non-lethal host-applied hit, so the rebind proof is about real damaged state surviving the
	# peer-id swap, not merely "a fresh peer starts at max_hp" (which would pass even if the whole
	# rebind wiring were missing).
	var partial_damage: int = 25
	check(bool(health.call(&"host_apply_damage", client_peer_id, partial_damage, 0)),
		"host also lands a non-lethal hit on the client, to prove rebind carries real state")

	var rebind_ready: bool = await _until(
		func() -> bool: return bool(_read_result().get("rebind_ready", false)), TIMEOUT_SEC
	)
	check(rebind_ready, "client took damage and is ready to disconnect")
	var pre_rebind_hp: int = int(_read_result().get("pre_rebind_hp", -1))
	check(pre_rebind_hp > 0 and pre_rebind_hp < max_hp, "client's hp is damaged, not full, before it drops")

	var rebound: bool = await _until(
		func() -> bool: return bool(_read_result().get("rebind_complete", false)), TIMEOUT_SEC
	)
	check(rebound, "client reconnects under a new peer id")
	var new_peer_id: int = int(_read_result().get("new_peer_id", 0))
	check(new_peer_id > NetConfig.HOST_PEER_ID and new_peer_id != client_peer_id,
		"the new peer id really is different (%d -> %d)" % [client_peer_id, new_peer_id])
	check(int(_read_result().get("post_rebind_hp", -1)) == pre_rebind_hp,
		"and its damaged hp followed the rebind instead of resetting to full (D-035)")
	check(bool(health.call(&"host_is_alive", new_peer_id)), "the host's own state agrees")
	check(not bool(health.call(&"host_is_alive", client_peer_id)),
		"and the OLD peer id holds no state at all — it moved, it was not copied")

	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	transport.call("leave")
	print("PLAYER_HEALTH_NET_CHECK client=%d->%d failures=%d" % [
		client_peer_id, new_peer_id, failures
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
	var ready: bool = await _until(_client_health_ready, TIMEOUT_SEC)
	if not ready:
		_write_result({"error": "initial health snapshot timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	_write_result({"connected": true, "peer_id": peer_id})

	var saw_downed: bool = await _until(
		func() -> bool: return bool(health.call(&"is_downed_known", NetConfig.HOST_PEER_ID)),
		TIMEOUT_SEC
	)
	_merge_result({"saw_host_downed": saw_downed})

	# A client cannot heal itself: request_revive(self) must be rejected by the host, over the real
	# RPC, not just by the local guard (the request still leaves this process).
	var confirmations: Dictionary[int, Dictionary] = {}
	var on_confirmed := func(request_id: int, accepted: bool, detail: String) -> void:
		confirmations[request_id] = {"accepted": accepted, "detail": detail}
	health.connect(&"revive_confirmed", on_confirmed)

	var self_request: int = int(health.call(&"request_revive", peer_id))
	var self_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(self_request), TIMEOUT_SEC
	)
	var self_rejected: bool = self_confirmed and not bool(confirmations[self_request].get("accepted", true))
	_merge_result({"self_revive_tested": self_confirmed, "self_revive_rejected": self_rejected})

	# Out of range: the host moved its own body to (300, 0, 300) before going down.
	var far_request: int = int(health.call(&"request_revive", NetConfig.HOST_PEER_ID))
	var far_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(far_request), TIMEOUT_SEC
	)
	var far_rejected: bool = far_confirmed and not bool(confirmations[far_request].get("accepted", true))
	_merge_result({"out_of_range_tested": far_confirmed, "out_of_range_rejected": far_rejected})

	var host_close: bool = await _until(
		func() -> bool: return bool(_read_driver_signal().get("host_close", false)), TIMEOUT_SEC
	)
	if not host_close:
		_merge_result({"error": "driver never signalled host_close"})
		finish()
		return

	var near_request: int = int(health.call(&"request_revive", NetConfig.HOST_PEER_ID))
	var near_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(near_request), TIMEOUT_SEC
	)
	var near_accepted: bool = near_confirmed and bool(confirmations[near_request].get("accepted", false))
	_merge_result({"revive_succeeded": near_accepted})
	health.disconnect(&"revive_confirmed", on_confirmed)

	# ── D-035: wait for the host's non-lethal hit, then drop and reconnect ────────────────────────
	# The driver applies this — a client cannot damage itself, and does not need to: the point is
	# that damaged state (not a fresh max_hp default) survives the peer-id swap.
	await _until(func() -> bool: return int(health.call(&"local_hp")) < max_hp, TIMEOUT_SEC)
	var pre_rebind_hp: int = int(health.call(&"local_hp"))
	_merge_result({"rebind_ready": true, "pre_rebind_hp": pre_rebind_hp})

	transport.call("leave")
	var left: bool = await _until(
		func() -> bool: return not bool(transport.call("is_active")), TIMEOUT_SEC
	)
	if not left:
		_merge_result({"error": "client did not actually disconnect"})
		finish()
		return

	var rejoin_error: Error = transport.call(
		"join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT
	)
	if rejoin_error != OK:
		_merge_result({"error": "rejoin failed: %s" % error_string(rejoin_error)})
		finish()
		return

	var rejoined: bool = await _until(
		func() -> bool: return (
			bool(transport.call("is_active"))
			and int(transport.call("local_peer_id")) != peer_id
		),
		TIMEOUT_SEC
	)
	if not rejoined:
		_merge_result({"error": "did not reconnect under a new peer id"})
		finish()
		return
	var new_peer_id: int = int(transport.call("local_peer_id"))

	# The rebound snapshot has to actually arrive — poll rather than trust the join alone.
	await _until(
		func() -> bool: return int(health.call(&"local_hp")) == pre_rebind_hp, TIMEOUT_SEC
	)
	_merge_result({
		"rebind_complete": true,
		"new_peer_id": new_peer_id,
		"post_rebind_hp": int(health.call(&"local_hp")),
	})
	await create_timer(1.0).timeout
	finish()


## F-060: is_active() is the load-bearing check here, not the other two. ENet hands a client its
## own unique id locally the instant create_client() succeeds (net_transport.gd's join(), before the
## host<->client handshake completes), and PlayerHealth's own OFFLINE bootstrap already sets
## local_revision to 0 at boot, before join() is ever called — so local_peer_id() > HOST_PEER_ID and
## local_revision >= 0 can BOTH already be true while the connection is still CONNECTING.
func _client_health_ready() -> bool:
	return (
		bool(transport.call("is_active"))
		and int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
		and int(health.call("local_revision")) >= 0
	)


func _wait_for_body(peer_id: int) -> Node3D:
	var found: bool = await _until(
		func() -> bool: return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC
	)
	return player_net.call("player_for", peer_id) as Node3D if found else null


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/player_health_net_check.gd",
		"--", "player-health-probe",
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
