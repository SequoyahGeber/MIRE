extends SceneTree

## F-232's hostile-client audit: real two-process ENet proof that `RpcRateLimiter` actually throttles
## a connected peer that floods a host RPC, rather than asserting on the limiter class in isolation
## (which would prove nothing about the real `net_request_place`/`net_submit_command` wiring).
##
##   .agent/bin/agent godot --script tools/hostile_client_check.gd
##
## Same driver/child two-process shape as tools/build_net_check.gd (task 3.6) and
## tools/disconnect_timing_check.gd (task 7.8) — the two prior checks that drove a real hostile
## scenario through a real ENet connection rather than calling host-side functions directly. A
## single-process check cannot exercise this at all: `multiplayer.get_remote_sender_id()` only
## resolves inside a real incoming RPC, so there is no way to simulate "a remote peer floods this"
## without a second process actually being that remote peer.
##
## What this proves that the audit itself could only assert by reading code:
##   1. `BuildService.net_request_place()` — a peer that fires far more requests than
##      `RATE_LIMIT_INTERVAL_MSEC` allows gets most of them answered "requests too frequent — slow
##      down" instead of each one running a real `PhysicsDirectSpaceState3D` overlap query.
##   2. `CommandService.net_submit_command()` — the same shape, but for a LOCAL-scope command
##      (`entities`) that needs no op at all, which is what makes this the more exploitable of the two:
##      any connected peer, not just one the host has opped, could otherwise force a full
##      `EntityDirectory.snapshot()` (every entity group scanned) on every single submission.
##   3. Neither limiter blocks a peer outright — at least one request in each flood still gets a real
##      answer, so a legitimate player's occasional double-press is never silently eaten.

const PORT: int = 47491
const RESULT_PATH: String = "user://hostile_client_check_client.json"
const DRIVER_SIGNAL_PATH: String = "user://hostile_client_check_driver.json"
const TIMEOUT_SEC: float = 15.0
## Comfortably above both services' RATE_LIMIT_INTERVAL_MSEC (100) — enough that even a slow CI box
## fires the whole burst well inside one interval window, so "most were throttled" cannot flake.
const FLOOD_COUNT: int = 40

var failures: int = 0
var transport: Node
var build_service: Node
var command_service: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	build_service = root.get_node_or_null(^"BuildService")
	command_service = root.get_node_or_null(^"CommandService")
	if transport == null or build_service == null or command_service == null:
		fail("NetTransport, BuildService and CommandService autoloads must exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "hostile-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== hostile-client rate-limit proof (F-232) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_write_driver_signal({"should_exit": false, "phase": "idle"})

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

	_write_driver_signal({"should_exit": false, "phase": "flood_build"})
	var build_done: bool = await _until(
		func() -> bool: return int(_read_result().get("build_replies", 0)) == FLOOD_COUNT, TIMEOUT_SEC
	)
	check(build_done, "all %d net_request_place floods got SOME reply (none silently dropped)" % FLOOD_COUNT)
	var build_throttled: int = int(_read_result().get("build_throttled", 0))
	var build_answered: int = int(_read_result().get("build_replies", 0)) - build_throttled
	check(build_throttled > 0, "BuildService throttled at least one flooded request (%d of %d)" % [
		build_throttled, FLOOD_COUNT])
	check(build_answered > 0 and build_answered < FLOOD_COUNT,
		"and at least one request still got a real (non-throttled) answer (%d of %d)" % [
			build_answered, FLOOD_COUNT])

	_write_driver_signal({"should_exit": false, "phase": "flood_command"})
	var command_done: bool = await _until(
		func() -> bool: return int(_read_result().get("command_replies", 0)) == FLOOD_COUNT, TIMEOUT_SEC
	)
	check(command_done,
		"all %d net_submit_command floods got SOME reply (none silently dropped)" % FLOOD_COUNT)
	var command_throttled: int = int(_read_result().get("command_throttled", 0))
	var command_answered: int = int(_read_result().get("command_replies", 0)) - command_throttled
	check(command_throttled > 0,
		("CommandService throttled at least one flooded LOCAL-scope 'entities' submission (%d of %d)"
			+ " — no op required to trigger this, which is what makes it the more exploitable of the two")
		% [command_throttled, FLOOD_COUNT])
	check(command_answered > 0 and command_answered < FLOOD_COUNT,
		"and at least one submission still got a real (non-throttled) answer (%d of %d)" % [
			command_answered, FLOOD_COUNT])

	var done: Dictionary = {"should_exit": true, "phase": "done"}
	_write_driver_signal(done)
	await _until(func() -> bool: return not OS.is_process_running(child_pid), 5.0)
	check(int(_read_result().get("client_failures", 1)) == 0, "client-side self checks report 0 failures")

	print("\nHOSTILE_CLIENT_CHECK failures=%d" % failures)
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

	build_service.connect(&"build_confirmed", _on_build_confirmed)
	# NOT `command_result` — that only fires for a request THIS process routed through `submit()`,
	# and `submit()` never puts a LOCAL-scope command like `entities` on the wire at all (it runs
	# `_execute_locally()` right here, client-side, exactly as COMMANDS.md says a LOCAL command
	# should). A hostile client does not go through the game's own client-side dispatch logic — it
	# calls the `@rpc("any_peer")` function directly with whatever it wants, which is exactly what
	# `_flood_command()` below does. `_rpc_result_received` is what actually fires for a REAL
	# `net_submit_command` round trip, regardless of who — or what bypassed what — sent it.
	command_service.connect(&"_rpc_result_received", _on_command_result)

	var handled: Dictionary = {}
	while not bool(_read_driver_signal().get("should_exit", false)):
		var phase: String = String(_read_driver_signal().get("phase", "idle"))
		if not handled.has(phase):
			handled[phase] = true
			match phase:
				"flood_build":
					_flood_build()
				"flood_command":
					_flood_command()
		_write_client_snapshot()
		await create_timer(0.05).timeout
	_write_client_snapshot()
	transport.call("leave")
	finish()


## Fired back-to-back with no `await` between calls — the whole point is that every one of these
## reaches the host inside the same ~100ms window `RATE_LIMIT_INTERVAL_MSEC` gates, exactly what a
## scripted flood (not a human mashing a key) looks like on the wire.
func _flood_build() -> void:
	for i: int in FLOOD_COUNT:
		# Deliberately far off any built ground (never proven to exist in this check at all) so every
		# ANSWERED request is rejected the same ordinary way — this check is about whether a reply
		# says "too frequent" at all, not about a successful placement.
		build_service.call(&"request_place", &"wall_wood", Transform3D(Basis(), Vector3(i, 0.0, 0.0)))


func _flood_command() -> void:
	# Straight to the wire, bypassing `submit()`/`execute()`'s own client-side routing entirely — a
	# hostile client is not the game's own console UI and has no reason to respect
	# CommandService.execute()'s "LOCAL commands never leave this machine" rule. `entities` is
	# LOCAL-scope and needs no op either way (COMMANDS.md §1.3), which is what makes this endpoint
	# exploitable by ANY connected peer, not just one the host has opped.
	for i: int in FLOOD_COUNT:
		command_service.rpc_id(NetConfig.HOST_PEER_ID, &"net_submit_command", 9000 + i, "entities")


var _build_replies: int = 0
var _build_throttled: int = 0
var _command_replies: int = 0
var _command_throttled: int = 0
var _client_failures: int = 0


func _on_build_confirmed(_request_id: int, _accepted: bool, reason: String) -> void:
	_build_replies += 1
	if reason == "requests too frequent — slow down":
		_build_throttled += 1


func _on_command_result(_handle: int, result: Dictionary) -> void:
	# `submit()` fires this for EVERY command this process issues, including calls the driver itself
	# may make on this same autoload — but the driver never calls `submit()` on the client process, so
	# every event this listener sees here is one of this client's own flood requests.
	_command_replies += 1
	if String(result.get("message", "")) == "commands too frequent — slow down":
		_command_throttled += 1


func _write_client_snapshot() -> void:
	if bool(transport.call("is_host")):
		_client_failures += 1  # the join target was LOCAL; this process must never be the host
	_write_result({
		"connected": true,
		"build_replies": _build_replies,
		"build_throttled": _build_throttled,
		"command_replies": _command_replies,
		"command_throttled": _command_throttled,
		"client_failures": _client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/hostile_client_check.gd",
		"--", "hostile-probe",
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
