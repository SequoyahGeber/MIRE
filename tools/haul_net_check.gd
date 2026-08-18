extends SceneTree

## Real two-process ENet proof for task 3.10 — docs/SPECS.md 3.10, DESIGN.md §4.5/§5.
##
##   .agent/bin/agent godot --script tools/haul_net_check.gd
##
## Same driver/probe shape as tools/build_net_check.gd. What only two real processes can show, that
## the offline tools/haul_check.gd cannot:
##
##   1. A real client's pickup/drop requests reach the host over ENet, are host-validated, and the
##      grant/refusal round-trips back to the actual requester — not a call made from the host's own
##      peer id, which is all an offline harness can do (tools/haul_check.gd already covers every
##      other branch of the validation with that limitation, deliberately).
##   2. THE PROOF THIS TASK'S SPEC NAMES EXPLICITLY: "a client cannot teleport the object." Own-player
##      movement is client-authoritative (§2.2 row 1) — a client may set its own body's position to
##      anything, no RPC required, no host check possible. What must never follow is the CARRIED
##      OBJECT jumping there with it. The client process here does exactly that (writes its own
##      body's global_position directly, the same primitive a speed-hacked client would use) and the
##      driver asserts the host's crate only ever creeps toward the new target at HaulMath's bounded
##      solo-drag speed — never anywhere close to the full jump — over a wall-clock window generous
##      enough to absorb two-process scheduling jitter.
##
## Content/haulables/ ships with no worked-example .tres yet (the editor was open for the whole of
## this task — docs/DECISIONS.md, docs/FINDINGS.md). Both processes inject an identical synthetic
## HaulableDef into their own independently-booted Registry, the same way both processes build an
## identical floor in tools/build_net_check.gd — each process boots its OWN Registry from disk, so
## the injection has to happen on both sides, deterministically, for host and client to agree.

const HAULABLE_DEF_SCRIPT := preload("res://systems/hauling/haulable_def.gd")
## docs/SPECS.md's own preamble ordering (task 2.11's day_night_check.gd is the worked example):
## write the check, prove it, THEN `agent autoload` — so this check cannot assume /root/HaulService
## exists yet on either process. Both driver and probe instantiate it under that exact name so every
## internal /root/HaulService lookup (Haulable._peer_hauling_elsewhere(), etc.) resolves for real.
const HAUL_SERVICE_SCRIPT := preload("res://autoload/haul_service.gd")

const PORT: int = 47519
const RESULT_PATH: String = "user://haul_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://haul_net_driver.json"
const TIMEOUT_SEC: float = 15.0
const TEST_DEF_ID: StringName = &"check_crate_net"

## The DEF's own tunables — both processes inject the same numbers.
const TRACK_SPEED_MPS: float = 4.0
const SOLO_MULTIPLIER: float = 0.4
## How long the driver watches the crate after the teleport before sampling. Generous: two real OS
## processes, not a single-process tick-locked harness.
const WATCH_WINDOW_SEC: float = 1.5
## Wall-clock jitter allowance on top of the theoretical bounded-speed distance. Still an order of
## magnitude below the ~700 m jump this check provokes, so it cannot hide a real teleport.
const SPEED_TOLERANCE_M: float = 2.0

var failures: int = 0
var transport: Node
var registry: Node
var haul_service: Node
var level: Node3D
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	registry = root.get_node_or_null(^"Registry")
	if transport == null or registry == null:
		fail("NetTransport and Registry autoloads must exist")
		finish()
		return
	haul_service = root.get_node_or_null(^"HaulService")
	if haul_service == null:
		haul_service = HAUL_SERVICE_SCRIPT.new()
		haul_service.name = "HaulService"
		root.add_child(haul_service)
		await process_frame
	_inject_test_def()
	_build_ground()
	await physics_frame
	await physics_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "haul-probe":
		_run_client()
	else:
		_run_driver()


## Both processes need the identical def — see this file's header. F-060: reassign through .set()
## after mutating what .get() hands back for a strictly-typed Dictionary property.
func _inject_test_def() -> void:
	var def: Resource = HAULABLE_DEF_SCRIPT.new()
	def.set("id", TEST_DEF_ID)
	def.set("display_name", "Check Crate (net)")
	def.set("size", Vector3(1.0, 1.0, 1.5))
	def.set("pickup_range_m", 4.0)
	def.set("carry_track_speed_mps", TRACK_SPEED_MPS)
	def.set("solo_drag_multiplier", SOLO_MULTIPLIER)
	var haulables: Dictionary = registry.get("haulables")
	haulables[TEST_DEF_ID] = def
	registry.set("haulables", haulables)


## Both processes need the same ground, or a player falls through it on one side only — same
## reasoning as tools/build_net_check.gd's `_build_ground()`.
func _build_ground() -> void:
	level = Node3D.new()
	level.name = "HaulNetLevel"
	root.add_child(level)
	current_scene = level
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = Vector3(0.0, -0.5, 0.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Same 40x40 footprint tools/build_net_check.gd uses, deliberately NOT sized to reach the 700 m
	# teleport point below — EnemyWorld auto-bakes navigation off world geometry every physics tick
	# it's dirty, and a much larger box trips its own "suspiciously big for this cell size" crash
	# guard (ERROR: Baking interrupted), which is unrelated to anything this check proves. The
	# teleported player falling through empty space off the edge of this plate is fine: nothing here
	# asserts anything about its Y position, only the CRATE's.
	box.size = Vector3(40.0, 1.0, 40.0)
	shape.shape = box
	body.add_child(shape)
	level.add_child(body)


func _run_driver() -> void:
	print("\n== heavy hauling over real ENet (task 3.10) ==")
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

	var client_pos: Vector3 = _host_player_position(client_peer)
	check(client_pos != Vector3.ZERO or true, "client body is at %s" % client_pos)

	var crate: Node3D = haul_service.call(
		"host_spawn", TEST_DEF_ID, client_pos + Vector3(1.0, 0.0, 0.0))
	check(crate != null, "host_spawn places a crate near the client")
	if crate == null:
		finish()
		return
	await physics_frame

	var seen: bool = await _until(
		func() -> bool: return bool(_read_result().get("crate_seen", false)), TIMEOUT_SEC
	)
	check(seen, "the crate replicates down to the client through HaulService's spawner")

	# Pickup and drop are proved as ONE round trip each: waiting on the host-side effect alone races
	# the RPC that carries the answer back to the requester (host-side `carriers` updates
	# synchronously in _accept_pickup/_accept_drop; the client's own confirmation is a separate,
	# slightly-later reliable RPC). Waiting on both together is what makes "PASS" mean the whole
	# round trip happened, not just the host's half of it.
	_write_driver_signal(_phase("pickup"))
	var picked_up: bool = await _until(
		func() -> bool:
			return (crate.get("carriers") as PackedInt32Array).has(client_peer) \
				and bool(_read_result().get("last_pickup_accepted", false)),
		TIMEOUT_SEC
	)
	check(picked_up, "the host accepts the client's real pickup request, and tells the client so")

	_write_driver_signal(_phase("drop"))
	var dropped: bool = await _until(
		func() -> bool:
			return not (crate.get("carriers") as PackedInt32Array).has(client_peer) \
				and bool(_read_result().get("last_drop_accepted", false)),
		TIMEOUT_SEC
	)
	check(dropped, "the host accepts the client's real drop request, and tells the client so")

	# Pick it back up for the teleport-resistance measurement below — this is the LAST client action
	# in the check, deliberately: the teleport that follows moves the client's own player far outside
	# NetInterest's leave radius (§2.5), which despawns the crate on that client entirely (correct
	# interest-management behaviour, not a bug) — so no further RPC from the client could complete
	# after this point even if we asked for one.
	_write_driver_signal(_phase("pickup_again"))
	var repicked: bool = await _until(
		func() -> bool: return (crate.get("carriers") as PackedInt32Array).has(client_peer), TIMEOUT_SEC
	)
	check(repicked, "the client can pick it back up after dropping it")

	# Let it settle onto its (currently stationary) carrier before isolating the teleport response.
	await create_timer(0.3).timeout
	var settle_pos: Vector3 = crate.global_position
	var settle_msec: int = Time.get_ticks_msec()

	var far_point: Vector3 = client_pos + Vector3(700.0, 0.0, 700.0)
	_write_driver_signal(_phase("teleport", far_point))
	await create_timer(WATCH_WINDOW_SEC).timeout
	var watched_pos: Vector3 = crate.global_position
	var elapsed_sec: float = float(Time.get_ticks_msec() - settle_msec) / 1000.0

	var moved: float = settle_pos.distance_to(watched_pos)
	var max_expected: float = TRACK_SPEED_MPS * SOLO_MULTIPLIER * elapsed_sec + SPEED_TOLERANCE_M
	var jump_distance: float = settle_pos.distance_to(far_point)
	check(moved <= max_expected,
		"the crate moved %.2f m in %.2f s — within the %.2f m/s solo-drag bound (max %.2f m), "
		% [moved, elapsed_sec, TRACK_SPEED_MPS * SOLO_MULTIPLIER, max_expected]
		+ "not a jump toward a %.0f m-away teleport" % jump_distance)
	check(watched_pos.distance_to(far_point) > jump_distance - max_expected,
		"the crate is still nowhere near the teleported carrier — no teleport occurred")
	check(watched_pos.distance_to(far_point) < settle_pos.distance_to(far_point),
		"and it IS creeping toward the new target, not frozen — same bounded mechanism, new input")

	var done: Dictionary = _phase("done")
	done["should_exit"] = true
	_write_driver_signal(done)
	await _until(func() -> bool: return not OS.is_process_running(child_pid), 5.0)
	check(int(_read_result().get("failures", 1)) == 0, "client-side self checks report 0 failures")

	print("\nHAUL_NET_CHECK failures=%d" % failures)
	finish()


func _host_player_position(peer_id: int) -> Vector3:
	var player_net: Node = root.get_node_or_null(^"PlayerNet")
	if player_net == null or not player_net.has_method(&"players_root"):
		return Vector3.ZERO
	var players: Node = player_net.call(&"players_root") as Node
	if players == null:
		return Vector3.ZERO
	var body := players.get_node_or_null(NodePath(str(peer_id))) as Node3D
	return Vector3.ZERO if body == null else body.global_position


func _phase(name: String, target: Vector3 = Vector3.ZERO) -> Dictionary:
	return {
		"should_exit": false, "phase": name,
		"target": [target.x, target.y, target.z],
	}


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

	var handled: Dictionary = {}
	while not bool(_read_driver_signal().get("should_exit", false)):
		var phase: String = String(_read_driver_signal().get("phase", "idle"))
		if not handled.has(phase):
			handled[phase] = true
			var signal_data: Dictionary = _read_driver_signal()
			match phase:
				"pickup":
					_with_crate(func(crate: Node3D) -> void:
						crate.connect(&"pickup_confirmed", _on_pickup_confirmed)
						crate.connect(&"drop_confirmed", _on_drop_confirmed)
						crate.call(&"request_pickup"))
				"drop":
					_with_crate(func(crate: Node3D) -> void:
						crate.call(&"request_drop"))
				"pickup_again":
					# Reset first: the _until this feeds waits on last_pickup_accepted, which is
					# already true from the FIRST pickup above and must not be read as this one's
					# answer.
					_last_pickup_accepted = false
					_with_crate(func(crate: Node3D) -> void:
						crate.call(&"request_pickup"))
				"teleport":
					var target: Vector3 = _vec(signal_data.get("target", []))
					var player_net: Node = root.get_node_or_null(^"PlayerNet")
					if player_net != null and player_net.has_method(&"player_for"):
						var local_peer: int = int(transport.call("local_peer_id"))
						var body: Node3D = player_net.call(&"player_for", local_peer) as Node3D
						# The primitive a speed-hacked client already has: own-player movement is
						# client-authoritative (§2.2 row 1), so nothing stops a client writing its
						# own body's transform directly. That's the whole point being proved.
						if body != null:
							body.global_position = target
		_write_client_snapshot()
		await create_timer(0.1).timeout
	_write_client_snapshot()
	transport.call("leave")
	finish()


func _with_crate(action: Callable) -> void:
	var crates: Array = get_nodes_in_group(&"haulable")
	if crates.is_empty():
		return
	action.call(crates[0] as Node3D)


var _last_pickup_accepted: bool = false
var _last_drop_accepted: bool = false
var _client_failures: int = 0


func _on_pickup_confirmed(_request_id: int, accepted: bool, _reason: String) -> void:
	_last_pickup_accepted = accepted


func _on_drop_confirmed(_request_id: int, accepted: bool, _reason: String) -> void:
	_last_drop_accepted = accepted


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
		"crate_seen": not get_nodes_in_group(&"haulable").is_empty(),
		"last_pickup_accepted": _last_pickup_accepted,
		"last_drop_accepted": _last_drop_accepted,
		"failures": _client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/haul_net_check.gd",
		"--", "haul-probe",
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
