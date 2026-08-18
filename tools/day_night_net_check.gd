extends SceneTree

## Real two-process ENet proof for task 2.11. The driver process hosts and plays the HOST's copy of
## DayNight directly; a spawned child process is the CLIENT. Same shape as
## tools/player_health_net_check.gd — driver plays one peer in-process, a subprocess is the other,
## talking through a user:// JSON file (docs/SPECS.md's "Two-process checks" seam).
##
##   requires DayNight already registered — run `agent godot --script tools/day_night_net_check.gd`
##   AFTER `agent autoload DayNight res://systems/environment/day_night.gd`, not before.
##
## Three things this proves that the offline check cannot:
##   1. The client's time_of_day follows the host's within about one replication interval.
##   2. Pausing the HOST's own processing (not disconnecting — see the note below) freezes the
##      client's time instead of it free-running on its own clock. A real disconnect is deliberately
##      NOT used for this: _owns_mutation() correctly promotes a disconnected peer to host-of-one,
##      which would make it start advancing on its own — that is the CORRECT behaviour for a player
##      who left the session, not a bug, so it would prove nothing about the RUNNING connection.
##      Pausing set_physics_process() on the host's node stops the flow of updates while the peers
##      stay connected, which is the actual case the spec means by "killing the flow of updates".
##   3. The client never emits night_started / day_started — thresholds are host-only by contract.

const PORT: int = 47433
const RESULT_PATH: String = "user://day_night_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://day_night_net_driver.json"
const TIMEOUT_SEC: float = 15.0

## Short enough that a threshold crossing happens in about a second of real time, long enough that
## the 1 Hz replication interval is a small, meaningful fraction of the day (so "follows within one
## interval" is an actually tight assertion, not a trivially loose one).
const TEST_DAY_LENGTH_SEC: float = 20.0
const TEST_START_TIME: float = 0.70  # just before night_started's default 0.75 threshold

var failures: int = 0
var transport: Node
var day_night: Node
var child_pid: int = 0
var host_night_count: int = 0
var host_day_count: int = 0
# Client-side counters. Members, not locals inside _client_drive() — GDScript lambdas capture
# locals BY VALUE, so a lambda incrementing a local would silently update a copy nothing reads back
# (the same trap tools/crafting_ui_check.gd's notes warn about). Members resolve through `self`,
# which the lambda captures by reference, so this mutation is actually visible.
var _client_night_count: int = 0
var _client_day_count: int = 0
var _client_failures: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	day_night = root.get_node_or_null(^"DayNight")
	if transport == null or day_night == null:
		fail("NetTransport and DayNight autoloads must exist (is DayNight registered yet?)")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "day-night-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== day/night network check (task 2.11) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_write_driver_signal({"should_exit": false})

	day_night.connect(&"night_started", func() -> void: host_night_count += 1)
	day_night.connect(&"day_started", func() -> void: host_day_count += 1)
	day_night.set(&"time_of_day", TEST_START_TIME)
	day_night.set(&"day_length_seconds", TEST_DAY_LENGTH_SEC)

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

	# ── 1. Client follows the host within about one replication interval ──────────────────────────
	# Let a handful of 1 Hz pushes land — long enough to also cross night_started once.
	await create_timer(3.0).timeout
	check(host_night_count == 1, "host crosses night_started exactly once (%d)" % host_night_count)

	var host_time: float = float(day_night.get(&"time_of_day"))
	var client_time: float = float(_read_result().get("time_of_day", -1.0))
	var drift: float = _wrapped_distance(host_time, client_time)
	var max_drift: float = 1.5 / TEST_DAY_LENGTH_SEC + 0.02  # ~1.5 replication intervals of slack
	check(drift <= max_drift,
		"client time_of_day follows the host (host=%.4f client=%.4f drift=%.4f max=%.4f)" % [
			host_time, client_time, drift, max_drift
		])

	# ── 2. Pausing the host's own processing freezes the client instead of it free-running ─────────
	day_night.call(&"set_physics_process", false)
	var host_frozen_at: float = float(day_night.get(&"time_of_day"))
	await create_timer(0.5).timeout  # let any in-flight snapshot land before sampling starts
	var client_before: float = float(_read_result().get("time_of_day", -1.0))
	await create_timer(1.5).timeout
	var client_after: float = float(_read_result().get("time_of_day", -1.0))
	var host_after_pause: float = float(day_night.get(&"time_of_day"))
	check(is_equal_approx(host_after_pause, host_frozen_at), "pausing the host really stops its own clock too")
	check(is_equal_approx(client_before, client_after),
		"with no updates arriving, the client's sky FREEZES instead of free-running (%.5f vs %.5f)" % [
			client_before, client_after
		])
	day_night.call(&"set_physics_process", true)

	# ── 3. The client never emits either threshold signal, even though the host just crossed one ───
	_write_driver_signal({"should_exit": true})
	var client_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(client_exited, "client exits cleanly")
	if client_exited:
		child_pid = 0
	check(int(_read_result().get("night_count", -1)) == 0,
		"client never fires night_started, even after the host did")
	check(int(_read_result().get("day_count", -1)) == 0, "client never fires day_started")
	check(int(_read_result().get("failures", -1)) == 0, "client-side self checks report 0 failures")

	transport.call("leave")
	print("DAY_NIGHT_NET_CHECK failures=%d" % failures)
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


func _on_client_night_started() -> void:
	_client_night_count += 1


func _on_client_day_started() -> void:
	_client_day_count += 1


func _client_drive() -> void:
	day_night.connect(&"night_started", _on_client_night_started)
	day_night.connect(&"day_started", _on_client_day_started)

	var joined: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	if bool(transport.call("is_host")):
		_client_failures += 1  # the join target was LOCAL; this process must never end up the host

	while not bool(_read_driver_signal().get("should_exit", false)):
		_write_client_snapshot()
		await create_timer(0.1).timeout

	_write_client_snapshot()
	transport.call("leave")
	finish()


func _write_client_snapshot() -> void:
	_write_result({
		"connected": true,
		"peer_id": int(transport.call("local_peer_id")),
		"time_of_day": float(day_night.get(&"time_of_day")),
		"night_count": _client_night_count,
		"day_count": _client_day_count,
		"failures": _client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/day_night_net_check.gd",
		"--", "day-night-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


## Shortest distance between two 0..1 fractions across the wrap, mirroring day_night.gd's own
## _lerp_wrapped_unit() reasoning — a direct subtraction would read a wrap as ~1.0 apart instead of
## whatever the true, small distance is.
func _wrapped_distance(a: float, b: float) -> float:
	var diff: float = fposmod(a - b + 0.5, 1.0) - 0.5
	return absf(diff)


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
