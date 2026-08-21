extends SceneTree

## Real two-process ENet proof for task 3.6: a client asks, the host decides, and the piece appears
## on both machines.
##
##   .agent/bin/agent godot --script tools/build_net_check.gd
##
## Same driver/child shape as tools/powerup_net_check.gd and tools/day_night_net_check.gd.
##
## What only two processes can show:
##   1. A client's request reaches the host, is charged and accepted, and the spawned piece
##      REPLICATES down to that client through the code-built MultiplayerSpawner (D-023). The
##      offline check spawns into the same tree it asserts on, so it cannot tell a working spawner
##      from a local add_child.
##   2. A refusal travels back to the requester with its reason, so the client can say why.
##   3. A client is not an authority: running the host's own decision function ON the client places
##      nothing. That is the assertion that matters most here — the whole point of routing builds
##      through the host is that a wall a client can conjure is one it can conjure for free.
##   4. F-084: destroying a real piece by name over the real RPC is refused when the requesting
##      peer's OWN host-known body is far from it, and accepted (with a refund) when it isn't — the
##      offline check calls `request_destroy` from the host's own peer id and never exercises the
##      range rule against a genuinely remote requester's position at all.

const PORT: int = 47473
const RESULT_PATH: String = "user://build_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://build_net_driver.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var service: Node
var inventory: Node
var level: Node3D
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	service = root.get_node_or_null(^"BuildService")
	inventory = root.get_node_or_null(^"InventoryService")
	if transport == null or service == null or inventory == null:
		fail("NetTransport, BuildService and InventoryService autoloads must exist")
		finish()
		return
	_build_ground()
	await physics_frame
	await physics_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "build-probe":
		_run_client()
	else:
		_run_driver()


## Both processes need the same ground, or the host validates against a floor the client never had.
func _build_ground() -> void:
	level = Node3D.new()
	level.name = "BuildNetLevel"
	root.add_child(level)
	current_scene = level
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = Vector3(0.0, -0.5, 0.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	shape.shape = box
	body.add_child(shape)
	level.add_child(body)


func _run_driver() -> void:
	print("\n== build replication over real ENet (task 3.6) ==")
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
	var client_peer: int = int(_read_result().get("peer_id", 0))

	# Pick the build spot from where the CLIENT actually is, rather than hard-coding one. PlayerNet
	# fans peers out from the level's spawn point, so a fixed spot lands on somebody's body and the
	# host refuses it as OVERLAPS — correctly, since you cannot build inside a player, but it means
	# the cost path never gets reached and the test measures the wrong refusal. 3 m out is well
	# inside the wall's 6 m build range and clear of both bodies.
	var builder: Vector3 = _host_player_position(client_peer)
	var spot: Vector3 = builder + Vector3(0.0, 0.0, 3.0)
	var forge_spot: Vector3 = builder + Vector3(0.0, 0.0, -3.0)
	check(true, "client body is at %s, building at %s" % [builder, spot])

	# The client cannot pay yet, so its first request must come back refused — with a reason.
	_write_driver_signal(_phase("request", spot, forge_spot))
	var refused: bool = await _until(
		func() -> bool: return String(_read_result().get("last_reason", "")) != "", TIMEOUT_SEC
	)
	check(refused, "the host's refusal reaches the client")
	check(String(_read_result().get("last_reason", "")) == "not enough materials",
		"and carries the reason (%s)" % String(_read_result().get("last_reason", "")))
	check(int(service.call(&"placed_count")) == 0, "nothing was built for a refused request")

	# Pay the client, then let it ask again.
	inventory.call(&"host_transaction", client_peer, {} as Dictionary, {&"log": 10} as Dictionary)
	_write_driver_signal(_phase("request_again", spot, forge_spot))
	var built: bool = await _until(
		func() -> bool: return int(service.call(&"placed_count")) == 1, TIMEOUT_SEC
	)
	check(built, "with materials the host accepts the client's request and spawns the piece")

	var replicated: bool = await _until(
		func() -> bool: return int(_read_result().get("pieces_seen", 0)) >= 1, TIMEOUT_SEC
	)
	check(replicated, "the piece replicates down to the client through the spawner")
	check(bool(_read_result().get("last_accepted", false)),
		"and the client was told its build was accepted")

	# F-084: the missing path — a real client asking the host to destroy a piece by name. A far
	# piece proves the host does not just trust `_placed.has(name)`; the near one proves a real
	# in-range destroy still works and still refunds.
	var near_name: StringName = StringName(
		(get_nodes_in_group(&"buildable_piece")[0] as Node).name)
	var far_piece: Node3D = service.call(
		&"_spawn_piece", &"wall_wood", Transform3D(Basis(), builder + Vector3(0.0, 0.0, 100.0)))
	check(far_piece != null,
		"driver plants a second piece 100 m from the client — one built elsewhere on the map")
	var far_name: StringName = StringName(far_piece.name)
	# `_placed` is host-private bookkeeping; this is how the driver gives the far piece a
	# destroy-able identity without a second real player body to place it with in range. F-060:
	# mutating what `.get()` returns off a strictly-typed Dictionary property does not reliably
	# reach the original — capture it to a local, then `.set()` it back explicitly.
	var placed_state: Dictionary = service.get(&"_placed")
	placed_state[far_name] = {"def": &"wall_wood", "owner": NetConfig.HOST_PEER_ID}
	service.set(&"_placed", placed_state)
	var far_replicated: bool = await _until(
		func() -> bool: return int(_read_result().get("pieces_seen", 0)) >= 2, TIMEOUT_SEC
	)
	check(far_replicated, "the far piece replicates down to the client too")

	_write_driver_signal(_destroy_phase("destroy_far", far_name, spot, forge_spot))
	var refused_far: bool = await _until(
		func() -> bool: return String(_read_result().get("last_reason", "")) == "too far away",
		TIMEOUT_SEC
	)
	check(refused_far, "destroying a piece 100 m away is refused by name alone (F-084)")
	check(int(service.call(&"placed_count")) == 2, "and it is neither freed nor refunded")
	var log_before_near_destroy: int = int(inventory.call(&"host_count", client_peer, &"log"))

	_write_driver_signal(_destroy_phase("destroy_near", near_name, spot, forge_spot))
	var destroyed_near: bool = await _until(
		func() -> bool: return int(service.call(&"placed_count")) == 1, TIMEOUT_SEC
	)
	check(destroyed_near, "destroying the piece the client actually built and stands beside works")
	check(int(inventory.call(&"host_count", client_peer, &"log")) == log_before_near_destroy + 2,
		"and refunds floor(4 * 0.5) = 2 log")
	var far_only: bool = await _until(
		func() -> bool: return int(_read_result().get("pieces_seen", 0)) == 1, TIMEOUT_SEC
	)
	check(far_only, "the destruction replicates: the client is left seeing only the far piece")

	# Authority: the client running the host's own decision path must place nothing.
	_write_driver_signal(_phase("forge", spot, forge_spot))
	await _until(func() -> bool: return bool(_read_result().get("forge_done", false)), TIMEOUT_SEC)
	check(int(service.call(&"placed_count")) == 1,
		"a client running the host's placement path forges nothing (host still has 1)")
	check(int(_read_result().get("pieces_seen", 0)) == 1,
		"and no phantom piece exists on the client either")

	var done: Dictionary = _phase("done", spot, forge_spot)
	done["should_exit"] = true
	_write_driver_signal(done)
	await _until(func() -> bool: return not OS.is_process_running(child_pid), 5.0)
	check(int(_read_result().get("failures", 1)) == 0, "client-side self checks report 0 failures")

	print("\nBUILD_NET_CHECK failures=%d" % failures)
	finish()


## Where the host thinks that peer's body is. The host is the authority on position, so this is the
## same number `BuildService._builder_position()` will use for the range rule.
func _host_player_position(peer_id: int) -> Vector3:
	var player_net: Node = root.get_node_or_null(^"PlayerNet")
	if player_net == null or not player_net.has_method(&"players_root"):
		return Vector3.ZERO
	var players: Node = player_net.call(&"players_root") as Node
	if players == null:
		return Vector3.ZERO
	var body := players.get_node_or_null(NodePath(str(peer_id))) as Node3D
	return Vector3.ZERO if body == null else body.global_position


func _phase(name: String, spot: Vector3, forge_spot: Vector3) -> Dictionary:
	return {
		"should_exit": false, "phase": name,
		"spot": [spot.x, spot.y, spot.z],
		"forge": [forge_spot.x, forge_spot.y, forge_spot.z],
	}


func _destroy_phase(name: String, target: StringName, spot: Vector3, forge_spot: Vector3) -> Dictionary:
	var phase: Dictionary = _phase(name, spot, forge_spot)
	phase["target"] = String(target)
	return phase


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
	service.connect(&"build_confirmed", _on_client_confirmed)

	var handled: Dictionary = {}
	while not bool(_read_driver_signal().get("should_exit", false)):
		var phase: String = String(_read_driver_signal().get("phase", "idle"))
		if not handled.has(phase):
			handled[phase] = true
			var signal_data: Dictionary = _read_driver_signal()
			match phase:
				"request", "request_again":
					service.call(&"request_place", &"wall_wood",
						Transform3D(Basis(), _vec(signal_data.get("spot", []))))
				"destroy_far", "destroy_near":
					service.call(&"request_destroy",
						StringName(String(signal_data.get("target", ""))))
				"forge":
					# The host's own decision function, run on a client. _owns_mutation() is false
					# here, so it must return immediately without spawning anything.
					# F-472/D-202 added the snap toggle between the transform and the request id.
					service.call(&"_process_place", 1, &"wall_wood",
						Transform3D(Basis(), _vec(signal_data.get("forge", []))), true, 9999)
					_forge_done = true
		_write_client_snapshot()
		await create_timer(0.1).timeout
	_write_client_snapshot()
	transport.call("leave")
	finish()


var _last_reason: String = ""
var _last_accepted: bool = false
var _client_failures: int = 0
var _forge_done: bool = false


func _on_client_confirmed(_request_id: int, accepted: bool, reason: String) -> void:
	_last_accepted = accepted
	if not reason.is_empty():
		_last_reason = reason


func _vec(raw: Variant) -> Vector3:
	var parts: Array = raw as Array
	if parts == null or parts.size() < 3:
		return Vector3.ZERO
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


func _write_client_snapshot() -> void:
	if bool(transport.call("is_host")):
		_client_failures += 1  # the join target was LOCAL; this process must never be the host
	_write_result({
		"connected": true,
		"peer_id": int(transport.call("local_peer_id")),
		"pieces_seen": get_nodes_in_group(&"buildable_piece").size(),
		"last_reason": _last_reason,
		"last_accepted": _last_accepted,
		"forge_done": _forge_done,
		"failures": _client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/build_net_check.gd",
		"--", "build-probe",
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
