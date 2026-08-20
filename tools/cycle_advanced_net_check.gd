extends SceneTree

## Real two-process ENet proof for F-250: `CycleService._announce()`'s `EVENT_BUS.emit_cycle_advanced()`
## call only ever ran host-side (`_owns_cycle()`), so a real connected client's own
## `EventBus.subscribe_cycle_advanced()` listeners never fired at all, no matter how many Cycles the
## host actually advanced. `tools/wave_director_check.gd` and `tools/cycle_check.gd` only ever exercise
## `EVENT_BUS.emit_cycle_advanced()` directly or on the host process — both would PASS even with F-250's
## bug present, since neither proves a CLIENT's own bus ever receives it. This file proves the real
## cross-peer path: the HOST advances the Cycle for real through `CycleService.host_advance_cycle()`,
## and the CLIENT — subscribed only through `EventBus.subscribe_cycle_advanced()`, never polling
## `current_cycle()` — must see its own listener actually fire, with the right Cycle number, close to
## real time (not just eventually true via some unrelated poll).
##
##   .agent/bin/agent godot --script tools/cycle_advanced_net_check.gd
##
## Same driver/probe shape as tools/wave_spawner_cycle_net_check.gd — driver plays the HOST in-process,
## a spawned child process is the CLIENT, talking through a user:// JSON file.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const PORT: int = 47442
const RESULT_PATH: String = "user://cycle_advanced_net_client.json"
const TIMEOUT_SEC: float = 15.0
const ADVANCES: int = 3  # host lands on Cycle 1 + ADVANCES

var failures: int = 0
var transport: Node
var cycle_service: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	cycle_service = root.get_node_or_null(^"CycleService")
	if transport == null or cycle_service == null:
		fail("NetTransport and CycleService autoloads must both exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "cycle-advanced-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== F-250: EventBus.cycle_advanced fires on a real connected client ==")
	for stale: String in [RESULT_PATH, RESULT_PATH + ".part"]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))

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

	var expected_cycle: int = 1
	for _index: int in ADVANCES:
		expected_cycle = int(cycle_service.call("host_advance_cycle"))
	check(expected_cycle == 1 + ADVANCES, "host really advanced the Cycle %d times (now %d)"
		% [ADVANCES, expected_cycle])

	# The client never polls anything here — it only ever writes what its own
	# EventBus.subscribe_cycle_advanced() listener received. Waiting for this to become true is
	# waiting for the real WorldDeltaLog replication + CycleService._on_world_delta_applied() +
	# EventBus.emit_cycle_advanced() chain to fire ON THE CLIENT PROCESS.
	var client_caught_up: bool = await _until(
		func() -> bool: return int(_read_result().get("last_signaled_cycle", -1)) == expected_cycle,
		TIMEOUT_SEC
	)
	check(client_caught_up,
		("client's own EventBus.subscribe_cycle_advanced() listener actually fired with the host's "
		+ "real Cycle (%d), not silent (F-250) — got %s")
		% [expected_cycle, str(_read_result().get("last_signaled_cycle", -1))])

	var client_result: Dictionary = _read_result()
	check(int(client_result.get("signal_fire_count", 0)) == ADVANCES,
		("client's listener fired exactly once per real host_advance_cycle() after it joined (%d), "
		+ "not zero (F-250) and not double-counted — got %d")
		% [ADVANCES, int(client_result.get("signal_fire_count", 0))])
	check(int(client_result.get("failures", -1)) == 0, "client-side self checks report 0 failures")

	transport.call("leave")
	print("CYCLE_ADVANCED_NET_CHECK failures=%d" % failures)
	finish()


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


var _last_signaled_cycle: int = -1
var _signal_fire_count: int = 0


func _client_drive() -> void:
	var joined: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	var client_failures: int = 0
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	if bool(transport.call("is_host")):
		client_failures += 1  # the join target was LOCAL; this process must never end up the host

	# Subscribe through the real EventBus static dispatcher — never touch CycleService.current_cycle()
	# (that getter already had a correct fallback pre-F-250 via F-226 and would mask this bug).
	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)

	while true:
		_write_result({
			"connected": true,
			"last_signaled_cycle": _last_signaled_cycle,
			"signal_fire_count": _signal_fire_count,
			"failures": client_failures,
		})
		await create_timer(0.1).timeout


func _on_cycle_advanced(cycle: int) -> void:
	_last_signaled_cycle = cycle
	_signal_fire_count += 1


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/cycle_advanced_net_check.gd",
		"--", "cycle-advanced-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


## F-290: written to a sibling `.part` path and RENAMED into place. The probe rewrites this file in
## a loop while the driver polls it, and a plain `FileAccess.WRITE` truncates the target before
## `store_string()` refills it — a poll landing in that window reads an empty or half document and
## `JSON.parse_string` logs `Parse JSON failed` as an undeclared ERROR line (SPECS standing rule 4)
## in a run that still prints `failures=0`. A rename is atomic: the reader sees the previous whole
## document or the next one, never a torn one. `tools/json_result_race_check.gd` measures both forms.
func _write_result(result: Dictionary) -> void:
	var staging: String = RESULT_PATH + ".part"
	var file := FileAccess.open(staging, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(staging), ProjectSettings.globalize_path(RESULT_PATH))


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var raw: String = FileAccess.get_file_as_string(RESULT_PATH)
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw)
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
