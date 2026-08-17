extends SceneTree

## LAN launch-path check (F-054). Two REAL processes, real ENet, over a ROUTABLE address rather than
## loopback — the point is to prove `--lan-host` / `--lan-join=<address>` open a session the way a
## second physical machine would, not to re-prove LOCAL mode with extra steps.
##
##     .agent/bin/agent godot --script tools/lan_launch_check.gd
##
## The driver hosts with the same code path `--lan-host` uses, then spawns a child that joins this
## machine's real LAN IP with the code path `--lan-join=` uses. If this passes and a VM still cannot
## connect, the fault is the network (firewall, bridged vs NAT, wrong IP) and not the game — which is
## the distinction that makes a cross-machine session debuggable at all.

const TIMEOUT_SEC: float = 20.0
const PROBE_ARG: String = "lan-probe"
const RESULT_FILE: String = "user://lan_launch_check_result.json"

var _failures: int = 0
var _child_pid: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == PROBE_ARG:
		await _run_probe(args[1] if args.size() > 1 else "")
		return
	await _run_driver()


# ── driver ────────────────────────────────────────────────────────────────────────────────────────

func _run_driver() -> void:
	var transport: Node = root.get_node_or_null(^"NetTransport")
	if transport == null:
		push_error("FAIL: NetTransport autoload missing")
		quit(1)
		return

	var address: String = _routable_address()
	check(not address.is_empty(), "this machine has a routable LAN address (%s)" % address)
	if address.is_empty():
		_finish()
		return

	# Mode.LAN, exactly as --lan-host does: binds ANY_ADDRESS so an off-box peer can reach it.
	var err: int = transport.call("host", NetConfig.Mode.LAN, NetConfig.DEFAULT_PORT)
	check(err == OK, "host(Mode.LAN) opened on port %d (%s)" % [NetConfig.DEFAULT_PORT, error_string(err)])
	if err != OK:
		_finish()
		return
	await process_frame
	check(bool(transport.call("is_host")), "driver reports itself host")

	_child_pid = _spawn_probe(address)
	check(_child_pid > 0, "probe process launched")
	if _child_pid <= 0:
		_finish()
		return

	# The client must ARRIVE — this is the assertion the whole file exists for. peer_ids() includes
	# the local peer, so a joined client means size >= 2.
	var joined: bool = await _until(
		func() -> bool: return (transport.call("peer_ids") as PackedInt32Array).size() >= 2, TIMEOUT_SEC
	)
	check(joined, "a peer joined over the routable address within %.0fs (peers: %s)"
		% [TIMEOUT_SEC, transport.call("peer_ids")])

	var players: bool = await _until(
		func() -> bool: return root.get_tree().get_nodes_in_group(&"players").size() >= 2, TIMEOUT_SEC
	)
	check(players, "both players exist on the host (%d)" %
		root.get_tree().get_nodes_in_group(&"players").size())

	var result: Dictionary = await _await_result()
	check(bool(result.get("connected", false)),
		"the probe reports a completed connection (%s)" % result)
	check(int(result.get("peer_id", 0)) > 1,
		"the probe was assigned a real peer id (%s)" % result.get("peer_id", 0))

	# Clean departure: the host must notice, which is what a VM disconnect will look like.
	var departed: bool = await _until(
		func() -> bool: return _child_pid <= 0 or not OS.is_process_running(_child_pid), TIMEOUT_SEC
	)
	check(departed, "probe exited")
	if departed:
		_child_pid = 0
	var despawned: bool = await _until(
		func() -> bool: return (transport.call("peer_ids") as PackedInt32Array).size() <= 1, TIMEOUT_SEC
	)
	check(despawned, "host saw the peer leave (peers: %s)" % transport.call("peer_ids"))

	transport.call("leave")
	print("\nLAN_LAUNCH_CHECK address=%s failures=%d\n" % [address, _failures])
	_finish()


## The first non-loopback IPv4 this machine owns — the address a VM would actually dial.
func _routable_address() -> String:
	for candidate: String in IP.get_local_addresses():
		if candidate.contains(":"):
			continue
		if candidate.begins_with("127.") or candidate.begins_with("169.254."):
			continue
		return candidate
	return ""


func _spawn_probe(address: String) -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	return OS.create_process(OS.get_executable_path(), [
		"--headless", "--path", project_dir, "--script", "tools/lan_launch_check.gd",
		"--", PROBE_ARG, address,
	])


func _await_result() -> Dictionary:
	var path: String = ProjectSettings.globalize_path(RESULT_FILE)
	await _until(func() -> bool: return FileAccess.file_exists(path), TIMEOUT_SEC)
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


# ── probe ─────────────────────────────────────────────────────────────────────────────────────────

func _run_probe(address: String) -> void:
	var path: String = ProjectSettings.globalize_path(RESULT_FILE)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	var transport: Node = root.get_node_or_null(^"NetTransport")
	var result: Dictionary = {"connected": false, "peer_id": 0, "address": address}
	if transport == null or address.is_empty():
		_write(path, result)
		quit(1)
		return

	# join(Mode.LAN, "<ip>") — the --lan-join= path.
	var err: int = transport.call("join", NetConfig.Mode.LAN, address, NetConfig.DEFAULT_PORT)
	if err != OK:
		result["error"] = error_string(err)
		_write(path, result)
		quit(1)
		return

	# is_active() covers "connected as a client"; there is no is_client(). A real assigned id is > 1
	# because 1 is always the host.
	var connected: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")) and int(transport.call("local_peer_id")) > 1,
		TIMEOUT_SEC
	)
	result["connected"] = connected
	result["peer_id"] = int(transport.call("local_peer_id"))
	# Hold the session briefly so the host can observe a real spawned player, then leave cleanly.
	if connected:
		await _wait(2.0)
	_write(path, result)
	transport.call("leave")
	await _wait(0.3)
	quit(0 if connected else 1)


func _write(path: String, data: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()


# ── helpers ───────────────────────────────────────────────────────────────────────────────────────

func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await process_frame
	return bool(condition.call())


func _wait(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	_failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	if _child_pid > 0 and OS.is_process_running(_child_pid):
		OS.kill(_child_pid)
	quit(1 if _failures > 0 else 0)
