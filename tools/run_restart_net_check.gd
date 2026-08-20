extends SceneTree

## F-243 review. Phase 1 extends `tools/run_restart_check.gd` across run state its implementation
## omitted (harvestables, Attunement, day/night, spawn position, the public run_started lifecycle)
## and both terminal overlays' keyboard/gamepad focus. Phase 2 is the real two-process proof that a
## host restart reaches a connected client's own EventBus: the separate
## `WorldDeltaLog.net_delta_applied()` -> `CycleService._on_world_delta_applied()` relay that co-op
## clients depend on. Two restarts prove the generation record remains reusable rather than acting
## like a one-shot boolean.
##
##   .agent/bin/agent godot --script tools/run_restart_net_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const NET_CONFIG := preload("res://core/net/net_config.gd")

const PORT: int = 47449
const RESULT_PATH: String = "user://run_restart_net_client.json"
const TEST_SAVE_PATH: String = "user://run_restart_net_salvage.json"
const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const TIMEOUT_SEC: float = 15.0
const RESTARTS: int = 2

var failures: int = 0
var transport: Node
var cycle_service: Node
var defeat_service: Node
var child_pid: int = 0
var _client_restart_count: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	cycle_service = root.get_node_or_null(^"CycleService")
	defeat_service = root.get_node_or_null(^"DefeatService")
	if transport == null or cycle_service == null or defeat_service == null:
		_fail("NetTransport, CycleService and DefeatService autoloads must exist")
		_finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "run-restart-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	await _run_solo_regressions()
	print("\n== F-243 REVIEW 2 · run_restarted reaches a real connected client ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

	var error: Error = transport.call("host", NET_CONFIG.Mode.LOCAL, PORT)
	_check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		_finish()
		return
	await process_frame
	child_pid = _spawn_client()
	_check(child_pid > 0, "client process launches")

	var armed: bool = await _until(
		func() -> bool: return bool(_read_result().get("armed", false)), TIMEOUT_SEC
	)
	_check(armed, "client connects, subscribes, and seeds terminal run state")
	if not armed:
		_finish()
		return

	for attempt: int in RESTARTS:
		defeat_service.set(&"defeated", true)
		_check(bool(defeat_service.get(&"defeated")),
			"restart %d: host run is terminal" % (attempt + 1))
		var cycle: int = int(cycle_service.call("host_restart_run"))
		_check(cycle == 1, "restart %d: host returns to Cycle 1" % (attempt + 1))
		var expected_count: int = attempt + 1
		var relayed: bool = await _until(
			func() -> bool:
				return int(_read_result().get("restart_count", 0)) == expected_count,
			TIMEOUT_SEC
		)
		_check(relayed,
			"restart %d: connected client's own run_restarted listener fires exactly once"
				% (attempt + 1))

	var result: Dictionary = _read_result()
	_check(int(result.get("restart_count", 0)) == RESTARTS,
		"client observed exactly %d restarts" % RESTARTS)
	_check(not bool(result.get("defeated", true)),
		"client DefeatService cleared its terminal state from run_restarted")
	_check(int(result.get("failures", -1)) == 0, "client self-checks report 0 failures")
	print("RUN_RESTART_NET_CHECK failures=%d" % failures)
	_finish()


func _run_solo_regressions() -> void:
	print("\n== F-243 REVIEW 1 · a next run is fresh and operable from gamepad ==")
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	_check(packed != null, "the shipped map loads")
	if packed == null:
		return
	var level: Node = packed.instantiate()
	root.add_child(level)
	current_scene = level
	for _index: int in 30:
		await process_frame
		await physics_frame

	var salvage_service: Node = root.get_node_or_null(^"SalvageService")
	if salvage_service != null:
		salvage_service.set(&"save_path", TEST_SAVE_PATH)
	var attunement_service: Node = root.get_node_or_null(^"AttunementService")
	var attunement_ui: Node = root.get_node_or_null(^"AttunementUI")
	_check(attunement_service != null and attunement_ui != null,
		"the run-start Attunement service and picker exist")
	if attunement_service != null and attunement_ui != null:
		attunement_service.call("request_select", &"forager")
		await process_frame
		_check(StringName(attunement_service.call("local_selection")) == &"forager",
			"an Attunement is locked for the first run")
	var day_night: Node = root.get_node_or_null(^"DayNight")
	_check(day_night != null, "the authoritative day/night clock exists")
	if day_night != null:
		day_night.set(&"time_of_day", 0.80)
	var restarted_run_started: Dictionary = {"count": 0}
	cycle_service.connect(&"run_started", func() -> void:
		restarted_run_started["count"] = int(restarted_run_started["count"]) + 1)
	var player: Node3D = null
	for candidate: Node in get_nodes_in_group(&"players"):
		if candidate is Node3D and candidate.is_multiplayer_authority():
			player = candidate as Node3D
			break
	_check(player != null, "the local player exists before restart")
	var run_spawn: Vector3 = player.global_position if player != null else Vector3.ZERO
	if player != null:
		player.global_position += Vector3(12.0, 0.0, 0.0)

	var harvestable: Node = null
	for candidate: Node in get_nodes_in_group(&"harvestable"):
		if bool(candidate.get(&"active")):
			harvestable = candidate
			break
	_check(harvestable != null, "an active harvestable exists before restart")
	if harvestable != null:
		while bool(harvestable.get(&"active")):
			harvestable.call("host_apply_damage", 1000000, 1)
		await physics_frame
		_check(not bool(harvestable.get(&"active")), "the harvestable is depleted before restart")

	defeat_service.set(&"defeated", true)
	await process_frame
	var focus_owner: Control = root.get_viewport().gui_get_focus_owner()
	_check(focus_owner is Button and (focus_owner as Button).text == "Start Next Run",
		"the terminal overlay focuses Start Next Run for keyboard/gamepad activation")
	cycle_service.call("host_restart_run")
	await process_frame
	await physics_frame
	if harvestable != null:
		_check(bool(harvestable.get(&"active")),
			"restart immediately restores a harvested world resource")
	if attunement_service != null and attunement_ui != null:
		_check(StringName(attunement_service.call("local_selection")) == &"",
			"restart clears the first run's Attunement selection")
		_check(bool(attunement_ui.call("is_open")),
			"restart reopens the mandatory run-start Attunement picker")
	if day_night != null:
		# Tolerance, not is_equal_approx: two frames were awaited above and the restarted run's clock
		# is RUNNING, so the exact-equality form this started as could never pass — a 900-second day
		# advances ~1.9e-5 per physics tick, twice CMP_EPSILON. The band is far tighter than the
		# ~0.45 error F-278 was actually about, and `tools/day_night_restart_check.gd` pins the
		# reset value itself with no frames in between.
		_check(absf(float(day_night.get(&"time_of_day")) - 0.348) < 0.001,
			"restart returns the authoritative clock to the authored morning (%.5f)"
				% float(day_night.get(&"time_of_day")))
	if player != null:
		_check(player.global_position.distance_to(run_spawn) < 1.0,
			"restart returns the local player to the run spawn")
	_check(int(restarted_run_started["count"]) == 1,
		"the public run_started lifecycle signal fires for the restarted run")

	var ship: Node = null
	for candidate: Node in get_nodes_in_group(&"extraction_ship"):
		ship = candidate
		break
	_check(ship != null, "the shipped map has an extraction ship")
	if ship != null:
		ship.set(&"departed", true)
		await process_frame
		var extraction_hud: Node = root.get_node_or_null(^"ExtractionHud")
		_check(extraction_hud != null and get_nodes_in_group(&"blocks_gameplay_input").has(
			extraction_hud), "the extraction summary is terminal before restart")
		focus_owner = root.get_viewport().gui_get_focus_owner()
		_check(focus_owner is Button and (focus_owner as Button).text == "Start Next Run",
			"the extraction overlay focuses Start Next Run for keyboard/gamepad activation")
		_check(int(cycle_service.call("host_restart_run")) == 1,
			"a completed extraction can start the next run")
		await process_frame
		_check(not bool(ship.get(&"departed")), "the extraction ship resets for the next run")
		_check(not get_nodes_in_group(&"blocks_gameplay_input").has(extraction_hud),
			"the extraction summary releases gameplay input")

	current_scene = null
	root.remove_child(level)
	level.free()
	await process_frame


func _run_client() -> void:
	_write_result({"armed": false})
	var error: Error = transport.call(
		"join", NET_CONFIG.Mode.LOCAL, NET_CONFIG.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		_finish()
		return
	_client_drive()


func _client_drive() -> void:
	var joined: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	var client_failures: int = 0
	if not joined:
		_write_result({"error": "client never connected"})
		_finish()
		return
	if bool(transport.call("is_host")):
		client_failures += 1

	EVENT_BUS.subscribe_run_restarted(_on_client_run_restarted)
	# Directly seed the client's terminal state so the relayed event must exercise DefeatService's
	# real subscriber, rather than merely observing an already-false value.
	defeat_service.set(&"defeated", true)
	while true:
		_write_result({
			"armed": true,
			"restart_count": _client_restart_count,
			"defeated": bool(defeat_service.get(&"defeated")),
			"failures": client_failures,
		})
		await create_timer(0.05).timeout


func _on_client_run_restarted() -> void:
	_client_restart_count += 1


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/run_restart_net_check.gd",
		"--", "run-restart-probe",
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


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	_fail(description)


func _fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	quit(0 if failures == 0 else 1)
