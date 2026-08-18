extends SceneTree

## Real two-process ENet proof for F-141: a REMOTE client's net_request_toggle_channel.rpc_id()
## actually reaches _process_toggle(multiplayer.get_remote_sender_id()) on a real second ENet
## process — the one seam tools/wellspring_check.gd's single-process run cannot exercise, because
## its host and its requester are the same process. That check already proves the ritual state
## machine exhaustively (start/cancel, out-of-range rejection, solo/co-op sizing, presence-gated
## pausing, completion); this one exists only to prove the RPC annotation and remote_sender_id,
## mirroring chest_net_check.gd's split from chest_check.gd.
##
##   .agent/bin/agent godot --script tools/wellspring_net_check.gd

const WELLSPRING_SCRIPT := preload("res://systems/wellspring/wellspring.gd")

const PORT: int = 47532
const RESULT_PATH: String = "user://wellspring_net_client.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var player_net: Node
var wellspring: Node3D
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	if transport == null or player_net == null:
		fail("NetTransport and PlayerNet autoloads must exist")
		finish()
		return
	_build_wellspring()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "wellspring-probe":
		_run_client()
	else:
		_run_driver()


func _build_wellspring() -> void:
	var world := Node3D.new()
	world.name = "WellspringNetWorld"
	root.add_child(world)
	wellspring = WELLSPRING_SCRIPT.new() as Node3D
	wellspring.name = "Wellspring"
	world.add_child(wellspring)


func _run_driver() -> void:
	print("\n== wellspring network check (F-141) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	# Same by-value-capture trap F-107 already paid for in chest_net_check.gd: derive client_peer
	# in the outer scope once _until confirms a peer exists, never inside the lambda.
	var client_peer: int = -1
	var got_peer: bool = await _until(func() -> bool:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				return true
		return false
	, TIMEOUT_SEC)
	check(got_peer, "host observes the client's peer id")
	if got_peer:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				client_peer = peer_id
				break

	var client_player: Node3D = null
	if got_peer:
		# Same by-value-capture trap as client_peer above (F-107) — assigning client_player inside
		# the lambda would only ever update the closure's own copy. Poll a boolean only, then
		# re-fetch in the outer scope once it is true.
		var spawned: bool = await _until(func() -> bool:
			return player_net.call("player_for", client_peer) != null
		, TIMEOUT_SEC)
		check(spawned, "host's PlayerNet spawns a body for the client's peer id")
		if spawned:
			client_player = player_net.call("player_for", client_peer) as Node3D
			# PRESENCE_RANGE_M is a fixed constant on Wellspring (4.5 m) that this check cannot
			# override — stand it exactly where the client's own player really is on the HOST's
			# tree instead of assuming a PlayerNet spawn offset, so this check does not silently
			# start failing if SPAWN_OFFSETS ever changes.
			wellspring.global_position = client_player.global_position

	var channeling: bool = await _until(func() -> bool: return bool(wellspring.get("channeling")), TIMEOUT_SEC)
	check(
		channeling,
		"the client's net_request_toggle_channel RPC reaches the host's _process_toggle and starts the channel"
	)
	check(
		int(wellspring.get("required_players")) == 2,
		"host and client both spawned a player this session -> the co-op requirement"
	)
	check(
		is_equal_approx(float(wellspring.get("duration_sec")), 60.0),
		"co-op duration is the short timer"
	)

	var started_result: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool:
		return bool(r.get("saw_channeling", false))
	)
	check(
		bool(started_result.get("saw_channeling", false)),
		"the client observes channeling=true through replication, not a direct RPC reply"
	)

	var cancelled: bool = await _until(func() -> bool: return not bool(wellspring.get("channeling")), TIMEOUT_SEC)
	check(cancelled, "the client's second RPC reaches the host and cancels the channel")
	check(
		is_equal_approx(float(wellspring.get("progress_sec")), 0.0),
		"cancelling forfeits progress on the host, over a real RPC same as the offline path"
	)

	var result: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool:
		return bool(r.get("saw_cancel", false))
	)
	check(
		bool(result.get("saw_cancel", false)),
		"the client observes channeling=false through replication after cancelling"
	)

	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	transport.call("leave")
	print("WELLSPRING_NET_CHECK failures=%d result=%s" % [failures, result])
	finish()


func _run_client() -> void:
	_write_result({"connected": false, "saw_channeling": false, "saw_cancel": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	# F-060: gate on is_active() directly rather than local_peer_id() > HOST_PEER_ID, which can read
	# true the instant ENet hands back a local unique id, before the handshake actually completes.
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	var spawned: bool = await _until(func() -> bool:
		return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	if not spawned:
		_write_result({"error": "player spawn timeout"})
		finish()
		return
	_write_result({"connected": true, "saw_channeling": false, "saw_cancel": false})

	wellspring.call(&"request_toggle_channel")
	var saw_channeling: bool = await _until(func() -> bool: return bool(wellspring.get("channeling")), TIMEOUT_SEC)
	_write_result({"connected": true, "saw_channeling": saw_channeling, "saw_cancel": false})
	if not saw_channeling:
		finish()
		return

	wellspring.call(&"request_toggle_channel")
	var saw_cancel: bool = await _until(func() -> bool: return not bool(wellspring.get("channeling")), TIMEOUT_SEC)
	_write_result({"connected": true, "saw_channeling": saw_channeling, "saw_cancel": saw_cancel})
	finish()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/wellspring_net_check.gd",
		"--", "wellspring-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _wait_for_result(done: Callable) -> Dictionary:
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	var result: Dictionary = _read_result()
	while Time.get_ticks_msec() < deadline_msec:
		result = _read_result()
		if bool(done.call(result)):
			return result
		await create_timer(0.05).timeout
	return result


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
