extends SceneTree

## Real two-process ENet proof for task 2.3. The driver hosts and relaunches this script as a client;
## both build the same Harvestable at the same node path. The client sends three parameterless hit
## RPCs, the host alone emits one yield, and depletion plus explicit respawn replicate back.

const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
const HARVESTABLE_DEF_SCRIPT := preload("res://systems/harvesting/harvestable_def.gd")
const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const PORT: int = 47423
const RESULT_PATH: String = "user://harvestable_net_client.json"
const TEST_ITEM_ID: StringName = &"net_check_log"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var player_net: Node
var prop: Node3D
var yield_count: int = 0
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	if transport == null or player_net == null:
		fail("NetTransport and PlayerNet autoloads must exist")
		finish()
		return
	_build_prop()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "harvest-probe":
		_run_client()
	else:
		_run_driver()


func _build_prop() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", TEST_ITEM_ID)
	# F-060: .set() back explicitly. Registry.items is a strictly-typed Dictionary; reading it through
	# the generic Object.get() property API can hand back a converted copy rather than the live
	# reference, so mutating what .get() returns does not reliably reach the original.
	var items: Dictionary = registry.get("items")
	items[TEST_ITEM_ID] = item
	registry.set("items", items)

	var definition: Resource = HARVESTABLE_DEF_SCRIPT.new()
	definition.set("id", &"net_check_tree")
	definition.set("max_health", 3)
	definition.set("damage_per_hit", 1)
	definition.set("yield_item_id", TEST_ITEM_ID)
	definition.set("yield_amount", 2)
	definition.set("respawn_seconds", 30.0)
	definition.set("request_range_m", 10.0)
	definition.set("request_cooldown_seconds", 0.0)
	var active_scenes: Array[PackedScene] = [
		_state_scene("Intact"), _state_scene("DamagedA"), _state_scene("DamagedB")
	]
	definition.set("active_state_scenes", active_scenes)
	definition.set("depleted_scene", _state_scene("Depleted"))

	var world := Node3D.new()
	world.name = "HarvestNetWorld"
	root.add_child(world)
	prop = HARVESTABLE_SCRIPT.new() as Node3D
	prop.name = "Harvestable"
	prop.set("definition", definition)
	var body := StaticBody3D.new()
	body.name = "CollisionBody"
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	prop.add_child(body)
	world.add_child(prop)


func _run_driver() -> void:
	print("\n== harvestable network check (task 2.3) ==")
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
	var yielded: bool = await _until(func() -> bool: return yield_count == 1, TIMEOUT_SEC)
	check(yielded, "host receives three requests and emits one yield")
	check(int(prop.get("health")) == 0, "host owns the resulting zero health")
	check(not bool(prop.get("active")), "host owns depletion")

	var client_depleted: bool = await _until(func() -> bool:
		return bool(_read_result().get("depleted", false)), TIMEOUT_SEC)
	check(client_depleted, "client receives replicated depletion")
	check(bool(prop.call("host_respawn")), "host explicitly respawns the prop")

	var client_done: bool = await _until(func() -> bool:
		return bool(_read_result().get("respawned", false)), TIMEOUT_SEC)
	check(client_done, "client receives replicated respawn")
	var result: Dictionary = _read_result()
	check(int(result.get("yield_count", -1)) == 0, "client never emits an authoritative yield")
	check(int(result.get("health", 0)) == 3, "client finishes at replicated full health")
	check(yield_count == 1, "host yield remains exactly once after respawn")

	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	EVENT_BUS.unsubscribe_harvest_yielded(_on_harvest_yielded)
	transport.call("leave")
	print("HARVESTABLE_NET_CHECK yields=%d failures=%d result=%s" % [yield_count, failures, result])
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
	# F-060: is_active() is load-bearing here, not local_peer_id() alone — ENet hands a client its own
	# unique id locally before the host<->client handshake completes.
	var connected: bool = await _until(func() -> bool:
		return (
			bool(transport.call("is_active"))
			and int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
		), TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout", "yield_count": yield_count})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	var spawned: bool = await _until(func() -> bool:
		return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	if not spawned:
		_write_result({"error": "player spawn timeout", "yield_count": yield_count})
		finish()
		return
	_write_result({"connected": true, "depleted": false, "respawned": false, "yield_count": yield_count})

	for _hit: int in 3:
		prop.call("request_hit")
	var depleted_seen: bool = await _until(func() -> bool:
		return not bool(prop.get("active")) and int(prop.get("health")) == 0, TIMEOUT_SEC)
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

	var respawn_seen: bool = await _until(func() -> bool:
		return bool(prop.get("active")) and int(prop.get("health")) == 3, TIMEOUT_SEC)
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
		"--headless", "--path", project_dir, "--script", "tools/harvestable_net_check.gd",
		"--", "harvest-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _state_scene(source_name: String) -> PackedScene:
	var state_root := Node3D.new()
	state_root.name = source_name
	var packed := PackedScene.new()
	packed.pack(state_root)
	state_root.free()
	return packed


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
