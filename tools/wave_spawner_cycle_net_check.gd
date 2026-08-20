extends SceneTree

## Real two-process ENet proof for F-226: `WaveSpawner.current_cycle()` claims "readable on any
## peer" but was reading only a private `_current_cycle` cache that `_on_cycle_advanced()` updates
## from `EventBus.cycle_advanced` — and `CycleService._announce()`
## (systems/cycle/cycle_service.gd:142-149) gated that emission behind `_owns_cycle()`, host-only, so
## a real client's cache never left its `1` default. `tools/wave_director_check.gd` already exercises
## `current_cycle()` against a DIRECT `EVENT_BUS.emit_cycle_advanced()` call, which bypasses
## `CycleService` entirely and would PASS even with F-226's bug present — it only proves the getter
## reads its own cache, not that a real client ever gets that cache updated. This file proves the
## actual cross-peer path instead: the HOST advances the Cycle for real through
## `CycleService.host_advance_cycle()`, and the CLIENT must still read the correct Cycle back,
## through the `WorldDeltaLog` fallback F-226 added to `current_cycle()`.
##
## F-250 (2026-08-19) fixed `_announce()`'s host-only gate on the EMIT side too — a client's own
## `EventBus.cycle_advanced` now really fires, re-derived from `WorldDeltaLog` locally
## (`CycleService._on_world_delta_applied()`). That means `WaveSpawner`'s private `_current_cycle`
## cache is no longer stuck at `1` on a client either — it now updates from the live signal exactly
## like the host's own copy does, so this file's old "the cache stays at 1, proving the read went
## through the WorldDeltaLog fallback and not a stray local emission" assertion no longer holds: the
## emission is real now, not stray, and the cache legitimately follows it. The assertion below was
## updated to check the cache reflects the real Cycle too, rather than asserting it stays wrong.
## `current_cycle()`'s own `WorldDeltaLog` fallback branch is still real and still load-bearing for
## the window before a client's first `cycle_advanced` signal ever arrives (right after joining,
## before the host's next advance) — `tools/cycle_advanced_net_check.gd` is F-250's dedicated proof
## that the signal path itself now reaches a client at all.
##
##   .agent/bin/agent godot --script tools/wave_spawner_cycle_net_check.gd
##
## Same driver/probe shape as tools/day_night_net_check.gd — driver plays the HOST in-process, a
## spawned child process is the CLIENT, talking through a user:// JSON file.

const PORT: int = 47441
const RESULT_PATH: String = "user://wave_spawner_cycle_net_client.json"
const TIMEOUT_SEC: float = 15.0
const ADVANCES: int = 3  # host lands on Cycle 1 + ADVANCES

var failures: int = 0
var transport: Node
var cycle_service: Node
var wave_spawner: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	cycle_service = root.get_node_or_null(^"CycleService")
	wave_spawner = root.get_node_or_null(^"WaveSpawner")
	if transport == null or cycle_service == null or wave_spawner == null:
		fail("NetTransport, CycleService and WaveSpawner autoloads must all exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "cycle-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== F-226: WaveSpawner.current_cycle() on a real client (task 5.9/6.1) ==")
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

	# Let the replication (WorldDeltaLog record) actually reach the client before reading it back.
	var client_caught_up: bool = await _until(
		func() -> bool: return int(_read_result().get("current_cycle", -1)) == expected_cycle,
		TIMEOUT_SEC
	)
	check(client_caught_up,
		("client's WaveSpawner.current_cycle() reaches the host's real Cycle (%d), not stuck at 1 "
		+ "(F-226) — got %s") % [expected_cycle, str(_read_result().get("current_cycle", -1))])

	var client_result: Dictionary = _read_result()
	check(int(client_result.get("cached_current_cycle", -1)) == expected_cycle,
		("F-250: client's private _current_cycle cache also reflects the real Cycle (%d) now — the "
		+ "signal reaching a client is no longer stray, so the cache legitimately follows it too — "
		+ "got %s") % [expected_cycle, str(client_result.get("cached_current_cycle", -1))])
	check(int(client_result.get("multiplier_matches", 0)) == 1,
		"cycle_count_multiplier() called bare on the client also reflects the real Cycle")
	check(int(client_result.get("failures", -1)) == 0, "client-side self checks report 0 failures")

	transport.call("leave")
	print("WAVE_SPAWNER_CYCLE_NET_CHECK failures=%d" % failures)
	finish()


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var joined: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	var client_failures: int = 0
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	if bool(transport.call("is_host")):
		client_failures += 1  # the join target was LOCAL; this process must never end up the host

	# Poll and re-write a fresh snapshot every tick so the driver's _until() sees the Cycle the
	# instant WorldDeltaLog replication delivers it. The driver kills this process once satisfied.
	while true:
		var current: int = int(wave_spawner.call("current_cycle"))
		var bare_multiplier: float = float(wave_spawner.call("cycle_count_multiplier"))
		var explicit_multiplier: float = float(wave_spawner.call("cycle_count_multiplier", current))
		_write_result({
			"connected": true,
			"current_cycle": current,
			"cached_current_cycle": int(wave_spawner.get(&"_current_cycle")),
			"multiplier_matches": 1 if is_equal_approx(bare_multiplier, explicit_multiplier) else 0,
			"failures": client_failures,
		})
		await create_timer(0.1).timeout


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/wave_spawner_cycle_net_check.gd",
		"--", "cycle-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


## F-290: written to a sibling `.part` path and RENAMED into place. `_client_drive()` rewrites this
## file every 100 ms while the driver polls it every 50 ms, and a plain `FileAccess.WRITE` truncates
## the target before `store_string()` refills it — so the driver could read an empty or half document
## and `JSON.parse_string` would log `Parse JSON failed` as an undeclared ERROR line while the run
## still reported `failures=0` and exited 0. A rename is atomic: a reader always sees one whole
## document, the previous one or the next one, never a torn one. Same shape as
## `tools/harvest_restart_check.gd` and `tools/attunement_restart_check.gd`.
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
