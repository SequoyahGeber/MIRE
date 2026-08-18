extends SceneTree

## Smoke test for NetDebugPanel (task 1.10).
##
## Autoload singletons are not compile-time identifiers in a --script main loop — the entry script
## given to --script is compiled before [autoload] is bootstrapped, so any script it PRELOADS at
## class scope fails with "Identifier not found: DebugOverlay" even though the reference is
## completely valid once the game is actually running (confirmed against this repo's own
## tools/_tmp_verify_1_5.gd, which hits the same thing). Fix: load() net_debug_panel.gd at runtime,
## from inside _initialize(), by which point autoload bootstrap has already happened — same timing
## real gameplay scripts get, since they too are loaded only after autoloads finish.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/net_debug_panel_check.gd
##
## Exits non-zero on failure.
##
## F-037: the real host+client RTT/bandwidth section used to fake its second peer as a second
## MultiplayerAPI in THIS process, pointed at this process's own /root (F-021's fix for autoload-
## addressed RPCs). That makes it the host's tree too, so when PlayerNet spawns a body for the fake
## peer, MultiplayerSpawner replicates it right back into the same container under a name that's
## already taken — "parent->has_node(name)" errors, harmless but undeclared. Fixed the way every
## other tools/*_net_check.gd does it (docs/SPECS.md's "Two-process checks" seam): a real second
## process, talking back through a user:// JSON file, exactly like tools/inventory_net_check.gd.

const PORT: int = 47435
const RESULT_PATH: String = "user://net_debug_panel_client.json"
const TIMEOUT_SEC: float = 15.0

var _panel_script: GDScript
var _failures: int = 0
var _panel: Node
var _transport: Node
var _child_pid: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	_transport = root.get_node_or_null(^"NetTransport")
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "panel-probe":
		_run_probe()
	else:
		_run_driver()


# ── Driver: boot / registration / offline readouts, then a real two-process session ────────────────


func _run_driver() -> void:
	print("\n-- boot --")
	# Relative to root, not "/root/..." — an absolute path is refused this early (root itself is not
	# yet considered "the active scene tree"), same finding tools/steam_lobby_check.gd already made.
	var overlay: Node = root.get_node_or_null(^"DebugOverlay")
	_check("DebugOverlay autoload present", overlay != null)
	_check("NetTransport autoload present", _transport != null)

	print("\n-- registration --")
	_panel_script = load("res://ui/debug/net_debug_panel.gd")
	_panel = _panel_script.new()
	root.add_child(_panel)
	# _ready() runs on the deferred call queue; SceneTree flushes it once we hand control back, so
	# check on the next frame instead of asserting anything here.
	_check("panel added without error", is_instance_valid(_panel))

	call_deferred(&"_after_ready")


func _after_ready() -> void:
	var overlay: Object = root.get_node_or_null(^"DebugOverlay")
	_check("net_session watch registered", overlay._watches.has(&"net_session"))
	_check("net_rtt watch registered", overlay._watches.has(&"net_rtt"))
	_check("net_bw watch registered", overlay._watches.has(&"net_bw"))
	_check("net_log watch registered", overlay._watches.has(&"net_log"))
	_check("synced group tracked", overlay._tracked_groups.has(&"synced"))

	print("\n-- readouts while offline --")
	_check("session line reads OFFLINE", _panel._session_line() == "OFFLINE",
		_panel._session_line())
	_check("rtt line degrades cleanly", _panel._rtt_line() == "n/a (offline)", _panel._rtt_line())
	_check("bandwidth line degrades cleanly", _panel._bandwidth_line() == "n/a (offline)",
		_panel._bandwidth_line())
	_check("log line starts empty", _panel._log_line() == "(none yet)", _panel._log_line())

	print("\n-- event log ring buffer --")
	_panel._on_peer_joined(2)
	_panel._on_connected_to_host()
	for i: int in range(_panel_script.EVENT_LOG_LIMIT + 3):
		_panel._on_peer_left(i)
	var log_text: String = _panel._log_line()
	var line_count: int = log_text.split("\n").size()
	_check("log caps at EVENT_LOG_LIMIT lines", line_count == _panel_script.EVENT_LOG_LIMIT,
		"got %d lines: %s" % [line_count, log_text])
	_check("oldest events fell off the front", not log_text.contains("joined  peer 2"), log_text)

	print("\n-- real second process, host+client RTT/bandwidth (F-037) --")
	await _check_real_session()

	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_real_session() -> void:
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

	var err: Error = _transport.host(NetConfig.Mode.LOCAL, PORT)
	_check("host() started", err == OK, error_string(err))
	if err != OK:
		return
	await create_timer(0.3).timeout

	_child_pid = _spawn_probe()
	_check("client process launched", _child_pid > 0, "pid %d" % _child_pid)

	var joined: bool = await _until(
		func() -> bool: return (_transport.peer_ids() as PackedInt32Array).size() >= 1, TIMEOUT_SEC)
	_check("host saw the client join", joined, "peers now %s" % str(_transport.peer_ids()))

	# Let a few real packets round-trip so ENet has a real RTT sample, not a fresh-connection zero.
	await create_timer(1.0).timeout

	print(_panel._session_line())
	_check("session line shows LOCAL host", _panel._session_line().begins_with("LOCAL  host"),
		_panel._session_line())

	var rtt_line: String = _panel._rtt_line()
	print("host rtt: %s" % rtt_line)
	_check("host rtt line names the remote peer, not n/a", not rtt_line.begins_with("n/a"), rtt_line)

	var bw_line: String = _panel._bandwidth_line()
	print("host bandwidth: %s" % bw_line)
	_check("host bandwidth line is a real reading, not n/a", not bw_line.begins_with("n/a"), bw_line)

	var reported: bool = await _until(
		func() -> bool: return bool(_read_result().get("done", false)), TIMEOUT_SEC)
	_check("client probe reported its own readouts", reported)
	var result: Dictionary = _read_result()
	_check("client session line shows LOCAL client",
		String(result.get("session_line", "")).begins_with("LOCAL  client"), str(result))
	_check("client rtt line names the host, not n/a",
		not String(result.get("rtt_line", "")).begins_with("n/a"), str(result))
	_check("client bandwidth line is a real reading, not n/a",
		not String(result.get("bandwidth_line", "")).begins_with("n/a"), str(result))

	var child_exited: bool = await _until(
		func() -> bool: return _child_pid <= 0 or not OS.is_process_running(_child_pid), TIMEOUT_SEC)
	_check("client exited cleanly", child_exited)
	if child_exited:
		_child_pid = 0

	_transport.leave()


func _spawn_probe() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/net_debug_panel_check.gd",
		"--", "panel-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


# ── Probe: the second process, reporting what it saw ────────────────────────────────────────────────


func _run_probe() -> void:
	_panel_script = load("res://ui/debug/net_debug_panel.gd")
	_panel = _panel_script.new()
	root.add_child(_panel)
	await process_frame

	var err: Error = _transport.join(NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if err != OK:
		_write_result({"error": error_string(err), "done": true})
		quit(1)
		return

	var ready: bool = await _until(_probe_ready, TIMEOUT_SEC)
	if not ready:
		_write_result({"error": "connect timeout", "done": true})
		quit(1)
		return

	# Let a few real packets round-trip so ENet has a real RTT sample, not a fresh-connection zero.
	await create_timer(1.0).timeout
	_write_result({
		"session_line": _panel._session_line(),
		"rtt_line": _panel._rtt_line(),
		"bandwidth_line": _panel._bandwidth_line(),
		"done": true,
	})
	# Stay alive a moment so the driver can read the result before this process exits.
	await create_timer(0.5).timeout
	_transport.leave()
	quit(0)


## F-060 trap 1: local_peer_id() reads a real value from the instant create_client() succeeds, before
## the host<->client handshake completes — is_active() is what's actually false until CONNECTED.
func _probe_ready() -> bool:
	return (
		bool(_transport.call("is_active"))
		and int(_transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
	)


# ── Shared helpers ───────────────────────────────────────────────────────────────────────────────────


func _until(condition: Callable, timeout_sec: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _write_result(result: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	return parsed if parsed is Dictionary else {}
