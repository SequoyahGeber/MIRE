extends SceneTree

## Two-process ENet proof for F-029 using the actual playtest_hollow map and HarvestWorld wiring.
## Both peers build the same deterministic holder tree. The host depletes layout prop 240, the
## client observes its replicated state, and only the host emits the yield before respawn replicates.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const SCENE_PATH: String = "res://levels/playtest_hollow.tscn"
const TARGET_LAYOUT_INDEX: int = 240
const PORT: int = 47424
const RESULT_PATH: String = "user://harvest_world_net_client.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var prop: Node3D
var yield_count: int = 0
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	if transport == null:
		fail("NetTransport autoload exists")
		finish()
		return
	if not await _load_real_map():
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "harvest-world-probe":
		_run_client()
	else:
		_run_driver()


func _load_real_map() -> bool:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		fail("playtest_hollow loads")
		return false
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 12:
		await process_frame
	await physics_frame
	var harvest_world: Node = root.get_node_or_null(^"HarvestWorld")
	if harvest_world == null:
		fail("HarvestWorld autoload exists")
		return false
	var harvestables: Array = harvest_world.call("wired_harvestables")
	for value: Variant in harvestables:
		var candidate := value as Node3D
		if int(candidate.get_meta(&"layout_index", -1)) == TARGET_LAYOUT_INDEX:
			prop = candidate
			break
	if prop == null:
		fail("real map harvestable %d is wired" % TARGET_LAYOUT_INDEX)
		return false
	return true


func _run_driver() -> void:
	print("\n== harvest world network check (F-029) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	EVENT_BUS.subscribe_harvest_yielded(_on_harvest_yielded)
	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")
	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false)), TIMEOUT_SEC
	)
	check(connected, "client loads and connects with the same real map")
	if not connected:
		finish()
		return

	var definition: Resource = prop.get("definition")
	check(bool(prop.call("host_apply_damage", int(definition.get("max_health")), 1)),
		"host depletes real map prop 240")
	check(yield_count == 1, "host emits exactly one authoritative yield")
	var client_depleted: bool = await _until(
		func() -> bool: return bool(_read_result().get("depleted", false)), TIMEOUT_SEC
	)
	check(client_depleted, "client receives real map depletion")
	check(bool(prop.call("host_respawn")), "host respawns real map prop 240")
	var client_respawned: bool = await _until(
		func() -> bool: return bool(_read_result().get("respawned", false)), TIMEOUT_SEC
	)
	check(client_respawned, "client receives real map respawn")
	var result: Dictionary = _read_result()
	check(int(result.get("yield_count", -1)) == 0, "client emits no authoritative yield")
	check(int(result.get("health", 0)) == int(definition.get("max_health")),
		"client finishes at replicated full health")
	check(yield_count == 1, "host yield remains exactly once")
	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid),
		TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	EVENT_BUS.unsubscribe_harvest_yielded(_on_harvest_yielded)
	transport.call("leave")
	print("HARVEST_WORLD_NET_CHECK yields=%d failures=%d result=%s" % [
		yield_count, failures, result
	])
	finish()


func _run_client() -> void:
	EVENT_BUS.subscribe_harvest_yielded(_on_harvest_yielded)
	_write_result({"connected": false, "depleted": false, "respawned": false, "yield_count": 0})
	var error: Error = transport.call(
		"join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT
	)
	if error != OK:
		_write_result({"error": error_string(error), "yield_count": yield_count})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var connected: bool = await _until(
		func() -> bool: return int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID,
		TIMEOUT_SEC
	)
	if not connected:
		_write_result({"error": "connect timeout", "yield_count": yield_count})
		finish()
		return
	_write_result({"connected": true, "depleted": false, "respawned": false, "yield_count": yield_count})
	var depleted_seen: bool = await _until(
		func() -> bool: return not bool(prop.get("active")) and int(prop.get("health")) == 0,
		TIMEOUT_SEC
	)
	_write_result({
		"connected": true,
		"depleted": depleted_seen,
		"respawned": false,
		"health": int(prop.get("health")),
		"yield_count": yield_count,
	})
	if not depleted_seen:
		finish()
		return
	var max_health: int = int((prop.get("definition") as Resource).get("max_health"))
	var respawn_seen: bool = await _until(
		func() -> bool: return bool(prop.get("active")) and int(prop.get("health")) == max_health,
		TIMEOUT_SEC
	)
	_write_result({
		"connected": true,
		"depleted": true,
		"respawned": respawn_seen,
		"health": int(prop.get("health")),
		"yield_count": yield_count,
	})
	EVENT_BUS.unsubscribe_harvest_yielded(_on_harvest_yielded)
	finish()


func _on_harvest_yielded(
	_harvestable_id: StringName,
	_peer_id: int,
	_item_id: StringName,
	_amount: int,
	_world_position: Vector3
) -> void:
	yield_count += 1


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/harvest_world_net_check.gd",
		"--", "harvest-world-probe",
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
