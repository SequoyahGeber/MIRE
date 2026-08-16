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

var _panel_script: GDScript
var _failures: int = 0
var _panel: Node


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("\n-- boot --")
	# Relative to root, not "/root/..." — an absolute path is refused this early (root itself is not
	# yet considered "the active scene tree"), same finding tools/steam_lobby_check.gd already made.
	var overlay: Node = root.get_node_or_null(^"DebugOverlay")
	_check("DebugOverlay autoload present", overlay != null)
	var transport: Node = root.get_node_or_null(^"NetTransport")
	_check("NetTransport autoload present", transport != null)

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

	print("\n-- offline handshake, then real ENet host+client RTT/bandwidth --")
	await _check_real_session()

	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_real_session() -> void:
	var host_transport: Node = root.get_node_or_null(^"NetTransport")
	var err: Error = host_transport.host(NetConfig.Mode.LOCAL, 47399)
	_check("host() started", err == OK, error_string(err))
	await create_timer(0.3).timeout

	# A second in-process peer to actually populate peer_ids()/get_peer() with something real.
	var client_peer := ENetMultiplayerPeer.new()
	var cerr: Error = client_peer.create_client("127.0.0.1", 47399)
	_check("client create_client() ok", cerr == OK, error_string(cerr))
	var client_mp := MultiplayerAPI.create_default_interface()
	client_mp.multiplayer_peer = client_peer

	# connected_to_server is racy to catch from outside — it can fire between two of our poll()
	# calls before the signal connection below even runs. The peer's own connection status is the
	# same information without the race.
	var deadline: int = Time.get_ticks_msec() + 3000
	while client_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED \
			and Time.get_ticks_msec() < deadline:
		client_mp.poll()
		await create_timer(0.05).timeout
	_check("second peer connected",
		client_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)

	# Let a few packets round-trip so ENet has a real RTT sample, not a fresh-connection zero.
	for i: int in range(10):
		host_transport.multiplayer.poll()
		client_mp.poll()
		await create_timer(0.05).timeout

	print(_panel._session_line())
	_check("session line shows LOCAL host", _panel._session_line().begins_with("LOCAL  host"),
		_panel._session_line())

	var rtt_line: String = _panel._rtt_line()
	print("rtt: %s" % rtt_line)
	_check("rtt line names the remote peer, not n/a", rtt_line.contains("2:") or rtt_line.contains(
		str(client_mp.get_unique_id()) + ":"), rtt_line)

	var bw_line: String = _panel._bandwidth_line()
	print("bandwidth: %s" % bw_line)
	_check("bandwidth line is a real reading, not n/a", not bw_line.begins_with("n/a"), bw_line)

	client_peer.close()
	host_transport.leave()
