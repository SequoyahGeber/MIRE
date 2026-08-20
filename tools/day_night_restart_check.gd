extends SceneTree

## F-278 — the day/night clock is RUN-scoped state, and F-243's restart left it running.
##
##   .agent/bin/agent godot --script tools/day_night_restart_check.gd
##
## Phase 1 (solo, host-of-one) proves the host half: a run ended at night starts the next one at the
## authored morning, the reset does NOT count as a `day_started` crossing (which would hand
## `CycleService` a phantom elapsed day the instant `host_restart_run()` zeroed the counter), and the
## 0.75 crossing WaveSpawner waits on is back IN FRONT of the clock so the new run's first night
## arrives on its own. It restarts twice, because a reset that works once and then latches is exactly
## the shape F-280 found elsewhere in the same feature.
##
## Phase 2 is the two-process half, and it is the reason this check is not simply four more lines in
## `tools/run_restart_check.gd`. A client never runs its own clock — it lerps between the last two
## host snapshots through `_lerp_wrapped_unit()`, which always takes the SHORTEST way round the wrap.
## So the host jumping BACKWARDS from night to morning is the one motion that interpolation renders
## wrong: without a client-side snap, the peer spends a full replication interval watching the sun
## run backwards through dusk and afternoon. Nothing in a single process can catch that, because the
## host branch of `_physics_process()` never touches the interpolation fields at all. The client here
## samples its own clock every frame across the restart and reports any frame that landed inside the
## band it can only reach by smearing.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const NET_CONFIG := preload("res://core/net/net_config.gd")

const PORT: int = 47451
const RESULT_PATH: String = "user://day_night_restart_client.json"
const DRIVER_SIGNAL_PATH: String = "user://day_night_restart_driver.json"
const TIMEOUT_SEC: float = 15.0

## Where a run realistically ends: past `night_started_at`'s 0.75 default, so the reset is a genuine
## backwards jump across the day/night boundary rather than a nudge.
const RUN_END_TIME: float = 0.80
## The authored morning, written out rather than read from the node — an assertion that reads its
## expected value off the thing under test proves only self-consistency. `run_start_time_of_day()`
## is checked against this literal separately.
const AUTHORED_MORNING: float = 0.348
## A client frame whose clock sits strictly inside this band cannot have got there any way but by
## interpolating backwards: the run ends at 0.80 (above the band) and resets to 0.348 (below it), and
## the host advances forward by well under a thousandth of a day over the seconds this check runs.
const SMEAR_BAND_LOW: float = 0.42
const SMEAR_BAND_HIGH: float = 0.78

var failures: int = 0
var transport: Node
var day_night: Node
var cycle_service: Node
var defeat_service: Node
var child_pid: int = 0
## Client-side counters. Members rather than locals for the reason tools/day_night_net_check.gd
## spells out: a lambda captures locals BY VALUE, so incrementing one updates a copy nothing reads.
var _client_restart_count: int = 0
var _client_night_count: int = 0
var _client_day_count: int = 0
var _client_smear_frames: int = 0
var _client_worst_smear: float = 0.0
var _client_failures: int = 0
## Last successfully parsed client snapshot. The result file is rewritten in place while the driver
## may be reading it, so a mid-write parse yields null (F-290); falling back to the previous good
## payload turns that race into one stale sample instead of a spurious failure.
var _last_result: Dictionary = {}


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	day_night = root.get_node_or_null(^"DayNight")
	cycle_service = root.get_node_or_null(^"CycleService")
	defeat_service = root.get_node_or_null(^"DefeatService")
	if transport == null or day_night == null or cycle_service == null or defeat_service == null:
		fail("NetTransport, DayNight, CycleService and DefeatService autoloads must exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "day-night-restart-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	_run_host_phase()
	await _run_client_phase()
	print("DAY_NIGHT_RESTART_CHECK failures=%d" % failures)
	finish()


# ── Phase 1 · the host's own clock ────────────────────────────────────────────────────────────────


func _run_host_phase() -> void:
	print("\n== 1 F-278 · a run ended at night starts the next one at the authored morning ==")
	check(is_equal_approx(float(day_night.call("run_start_time_of_day")), AUTHORED_MORNING),
		"the captured run-start morning is the authored default (%.4f)"
			% float(day_night.call("run_start_time_of_day")))

	var night_count: Dictionary = {"n": 0}
	var day_count: Dictionary = {"n": 0}
	day_night.connect(&"night_started", func() -> void: night_count["n"] = int(night_count["n"]) + 1)
	day_night.connect(&"day_started", func() -> void: day_count["n"] = int(day_count["n"]) + 1)

	# Two restarts: a reset that works once and then stops is the failure shape F-280 describes.
	for attempt: int in 2:
		day_night.set(&"time_of_day", RUN_END_TIME)
		check(float(day_night.get(&"time_of_day")) >= float(day_night.get(&"night_started_at")),
			"restart %d: the ended run's clock really is at night (%.3f)"
				% [attempt + 1, float(day_night.get(&"time_of_day"))])
		defeat_service.set(&"defeated", true)
		check(int(cycle_service.call("host_restart_run")) == 1,
			"restart %d: the run restarts and the Cycle returns to 1" % [attempt + 1])
		check(is_equal_approx(float(day_night.get(&"time_of_day")), AUTHORED_MORNING),
			"restart %d: the clock returns to the authored morning (%.4f)"
				% [attempt + 1, float(day_night.get(&"time_of_day"))])

	# The reset is a run BEGINNING, not a crossing. `host_set_time()` would have fired day_started on
	# the way from 0.80 to 0.348 (past day_started_at's 0.25), and CycleService._on_day_started()
	# would have banked a phantom elapsed day against the counter host_restart_run() just zeroed.
	check(int(day_count["n"]) == 0,
		"the reset does not fire day_started (%d) — no phantom elapsed day" % int(day_count["n"]))
	check(int(night_count["n"]) == 0,
		"the reset does not fire night_started (%d)" % int(night_count["n"]))
	check(int(cycle_service.call("days_elapsed_this_cycle")) == 0,
		"the restarted run's day count agrees with its clock (%d days elapsed)"
			% int(cycle_service.call("days_elapsed_this_cycle")))

	print("\n== 2 F-278 · the new run's first night still arrives on its own ==")
	# The whole reason the previous run's clock mattered to WaveSpawner: starting mid-night leaves the
	# 0.75 crossing BEHIND the clock, and F-259's latch clear cannot re-fire a signal that already
	# fired. Starting at morning puts it back in front, so a plain forward advance produces the edge.
	var day_length: float = float(day_night.get(&"day_length_seconds"))
	day_night.call("host_advance", day_length * 0.45)
	check(int(night_count["n"]) == 1,
		"advancing the restarted run forward crosses night_started exactly once (%d)"
			% int(night_count["n"]))
	check(float(day_night.get(&"time_of_day")) > float(day_night.get(&"night_started_at")),
		"the restarted run reaches its own night (%.4f)" % float(day_night.get(&"time_of_day")))


# ── Phase 2 · a real connected client adopts the reset without smearing across the wrap ───────────


func _run_client_phase() -> void:
	print("\n== 3 F-278 · a connected client snaps to the reset instead of lerping backwards ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_write_driver_signal({"should_exit": false})
	day_night.set(&"time_of_day", RUN_END_TIME)

	var error: Error = transport.call("host", NET_CONFIG.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		return
	await process_frame
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false)), TIMEOUT_SEC)
	check(connected, "client connects")
	if not connected:
		return

	# The client must actually be holding the ENDED run's night before the restart, or "it is at
	# morning afterwards" would be satisfied by a client that simply never heard anything.
	var adopted: bool = await _until(func() -> bool:
		return absf(float(_read_result().get("time_of_day", 0.0)) - RUN_END_TIME) < 0.02,
		TIMEOUT_SEC)
	check(adopted, "the client adopts the ended run's night (%.4f)"
		% float(_read_result().get("time_of_day", -1.0)))

	defeat_service.set(&"defeated", true)
	cycle_service.call("host_restart_run")
	var relayed: bool = await _until(
		func() -> bool: return int(_read_result().get("restart_count", 0)) >= 1, TIMEOUT_SEC)
	check(relayed, "run_restarted reaches the client's own EventBus")

	# Long enough to cover the full replication interval a smear would occupy, plus the host push
	# that follows the reset.
	await create_timer(2.0).timeout
	_write_driver_signal({"should_exit": true})
	var exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(exited, "client exits cleanly")
	if exited:
		child_pid = 0

	var result: Dictionary = _read_result()
	check(absf(float(result.get("time_of_day", -1.0)) - AUTHORED_MORNING) < 0.02,
		"the client ends at the restarted run's morning (%.4f)"
			% float(result.get("time_of_day", -1.0)))
	check(int(result.get("smear_frames", -1)) == 0,
		"the client never renders a frame between the two clocks (%d smeared frame(s), worst %.4f)"
			% [int(result.get("smear_frames", -1)), float(result.get("worst_smear", 0.0))])
	check(int(result.get("night_count", -1)) == 0,
		"the client still never fires night_started — thresholds stay host-only across a restart")
	check(int(result.get("day_count", -1)) == 0, "the client still never fires day_started")
	check(int(result.get("failures", -1)) == 0, "client-side self checks report 0 failures")
	transport.call("leave")


# ── The client half ───────────────────────────────────────────────────────────────────────────────


func _run_client() -> void:
	_write_client_snapshot(false)
	var error: Error = transport.call(
		"join", NET_CONFIG.Mode.LOCAL, NET_CONFIG.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	day_night.connect(&"night_started", _on_client_night_started)
	day_night.connect(&"day_started", _on_client_day_started)
	EVENT_BUS.subscribe_run_restarted(_on_client_run_restarted)

	var joined: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	if bool(transport.call("is_host")):
		_client_failures += 1  # the join target was LOCAL; this process must never be the host

	# Every frame, not every 50ms: a smear lasts one replication interval and this has to be able to
	# say it saw NO frame inside the band, which a sampler coarser than the frame rate cannot.
	var frames_since_write: int = 0
	while not bool(_read_driver_signal().get("should_exit", false)):
		await process_frame
		_sample_client_clock()
		frames_since_write += 1
		if frames_since_write >= 5:
			frames_since_write = 0
			_write_client_snapshot(true)

	_write_client_snapshot(true)
	transport.call("leave")
	finish()


## Ungated on the restart having been observed yet, deliberately: a client that has not yet heard
## anything sits at its own 0.348 default (below the band) and one tracking the ended run sits at
## 0.80 (above it), and the first snapshot SNAPS rather than lerping (`net_push_time` seeds prev from
## the value itself when there is no previous). So every legitimate state of this client is outside
## the band at every frame, and gating on `_client_restart_count` would only risk missing the first
## smeared frames if the unreliable time push ever overtook the reliable restart record.
func _sample_client_clock() -> void:
	var now: float = float(day_night.get(&"time_of_day"))
	if now <= SMEAR_BAND_LOW or now >= SMEAR_BAND_HIGH:
		return
	_client_smear_frames += 1
	_client_worst_smear = maxf(_client_worst_smear, now)


func _on_client_run_restarted() -> void:
	_client_restart_count += 1


func _on_client_night_started() -> void:
	_client_night_count += 1


func _on_client_day_started() -> void:
	_client_day_count += 1


func _write_client_snapshot(connected: bool) -> void:
	_write_result({
		"connected": connected,
		"time_of_day": float(day_night.get(&"time_of_day")),
		"restart_count": _client_restart_count,
		"smear_frames": _client_smear_frames,
		"worst_smear": _client_worst_smear,
		"night_count": _client_night_count,
		"day_count": _client_day_count,
		"failures": _client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/day_night_restart_check.gd",
		"--", "day-night-restart-probe",
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
		return _last_result
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	if parsed is Dictionary:
		_last_result = parsed
	return _last_result


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
