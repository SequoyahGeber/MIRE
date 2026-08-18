extends SceneTree

## Real two-process ENet proof for task 3.15 — the half `tools/entity_check.gd` cannot reach offline:
##
##   · a client's HOST-scope selector command is re-parsed AND RE-RESOLVED on the host, against the
##     host's own complete directory — never against whatever the client could see;
##   · `tp` on a PLAYER respects the authority table (COMMANDS.md §3.3): the host does not write the
##     body, it goes through `PlayerHealth.host_place_player()` -> `net_force_respawn` -> the owning
##     client places itself. The proof is the CLIENT's own body moving, in the client's own process;
##   · a non-op client is refused before anything is killed;
##   · a LOCAL `entities` answers off the client's own replicated view with no round trip.
##
##   .agent/bin/agent godot --script tools/entity_net_check.gd
##
## Same driver/probe shape as tools/rule_net_check.gd and tools/command_net_check.gd (F-037: a real
## second process, never a fake in-process peer).

const CommandServiceScript = preload("res://autoload/command_service.gd")

const PORT: int = 47523
const RESULT_PATH: String = "user://entity_net_client.json"
const TIMEOUT_SEC: float = 15.0
const TELEPORT_TO := Vector3(24.0, 3.0, -18.0)

var failures: int = 0
var transport: Node
var player_net: Node
var directory: Node
var enemy_world: Node
var command_service: CommandServiceScript
var child_pid: int = 0
## Merge-and-republish, for the reason rule_net_check.gd records: on loopback the client can finish
## two phases inside one 50 ms poll, so a later phase's file must be a SUPERSET of every earlier one
## or the driver reads the wrong snapshot and reports a product failure that is not one.
var _report: Dictionary = {}


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	directory = root.get_node_or_null(^"EntityDirectory")
	enemy_world = root.get_node_or_null(^"EnemyWorld")
	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	if transport == null or player_net == null or directory == null or command_service == null:
		fail("NetTransport, PlayerNet, EntityDirectory and CommandService autoloads must exist")
		finish()
		return

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "entity-probe":
		_run_client()
	else:
		_run_driver()


# ── Driver (host) ────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== entity directory network check (task 3.15) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")
	var got_peer: bool = await _until(func() -> bool: return _first_client_peer() > 0, TIMEOUT_SEC)
	check(got_peer, "host observes the client's peer id")
	var client_peer: int = _first_client_peer()

	# Spawned on the HOST only. The client's own directory never sees these as host-owned entities to
	# kill — which is exactly why the host has to be the one resolving the selector.
	for i: int in 3:
		enemy_world.call("host_spawn", &"crawler", Vector3(float(i) * 6.0, 0.0, 0.0))
	await process_frame
	check(int(enemy_world.call("live_count")) == 3, "host has 3 enemies for the client to aim at")

	# ── phase A: a non-op client is refused, and a LOCAL read still works ────────────────────────
	var phase_a: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("phase_a_done"))
	check(bool(phase_a.get("refused_ok", false)),
		"a non-op client's `kill` is refused: %s" % phase_a.get("refused_message", ""))
	check(int(enemy_world.call("live_count")) == 3, "and nothing on the host died while it was refused")
	check(bool(phase_a.get("entities_ok", false)),
		"a non-op client can still run `entities` — it is LOCAL scope: %s"
			% phase_a.get("entities_message", ""))

	if client_peer > 0:
		var op_result: Dictionary = await command_service.execute(
			"op %d" % client_peer, command_service.build_local_ctx(&"console"))
		check(bool(op_result.get("ok", false)), "host ops the client")

	# ── phase B: the opped client's kill resolves on the HOST's directory ────────────────────────
	var phase_b: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("kill_ok"))
	check(bool(phase_b.get("kill_ok", false)),
		"the opped client's kill succeeded: %s" % phase_b.get("kill_message", ""))
	var remaining: int = await _until_count(0, TIMEOUT_SEC)
	check(remaining == 0,
		"the HOST's enemies are gone — the selector resolved against the host's own directory, not "
			+ "the client's partial view (%d left)" % remaining)

	# ── phase C: tp on a PLAYER goes the long way round, and the client's body actually moves ────
	var phase_c: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("tp_ok"))
	check(bool(phase_c.get("tp_ok", false)), "the client's `tp @s` succeeded: %s" % phase_c.get("tp_message", ""))
	var landed: Array = phase_c.get("tp_position", [])
	var client_body_position := Vector3(
		float(landed[0]) if landed.size() == 3 else 0.0,
		float(landed[1]) if landed.size() == 3 else 0.0,
		float(landed[2]) if landed.size() == 3 else 0.0)
	check(client_body_position.distance_to(TELEPORT_TO) < 0.5,
		"the CLIENT's own body is at the destination in the CLIENT's process (%s) — the host asked "
			% client_body_position + "it to move rather than writing a transform it does not own")

	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0

	transport.call("leave")
	print("ENTITY_NET_CHECK failures=%d" % failures)
	finish()


func _first_client_peer() -> int:
	for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
		if peer_id != NetConfig.HOST_PEER_ID:
			return peer_id
	return -1


# ── Client (probe) ───────────────────────────────────────────────────────────────────────────────


func _run_client() -> void:
	_write_result({})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	# F-060: gate on is_active(), not local_peer_id() > 0.
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	var spawned: bool = await _until(func() -> bool:
		return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	if not spawned:
		_write_result({"error": "player spawn timeout"})
		finish()
		return

	await _client_phase_a()
	await _client_phase_b()
	await _client_phase_c(peer_id)
	finish()


func _client_phase_a() -> void:
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var refused: Dictionary = await command_service.execute("kill @e[type=enemy]", ctx)
	var listed: Dictionary = await command_service.execute("entities @a", ctx)
	_publish({
		"refused_ok": not bool(refused.get("ok", true)),
		"refused_message": String(refused.get("message", "")),
		"entities_ok": bool(listed.get("ok", false)),
		"entities_message": String(listed.get("message", "")).split("\n")[0],
		"phase_a_done": true,
	})


func _client_phase_b() -> void:
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	var accepted: bool = false
	var message: String = ""
	while Time.get_ticks_msec() < deadline_msec and not accepted:
		var result: Dictionary = await command_service.execute("kill @e[type=enemy]", ctx)
		accepted = bool(result.get("ok", false))
		message = String(result.get("message", ""))
		if not accepted:
			await create_timer(0.3).timeout
	_publish({"kill_ok": accepted, "kill_message": message})


## `@s` is this client's own player. The host resolves it, decides it is a player, and hands it to
## PlayerHealth — which cannot write the body from over there, so it asks this process to. Reading
## the body HERE, after the round trip, is the only place that proves the whole chain ran.
func _client_phase_c(peer_id: int) -> void:
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var result: Dictionary = await command_service.execute(
		"tp @s %f %f %f" % [TELEPORT_TO.x, TELEPORT_TO.y, TELEPORT_TO.z], ctx)
	# The host's reply returns as soon as it dispatched; the placement lands on this process a moment
	# later, over net_force_respawn. Poll for it rather than reading the frame the reply arrived in.
	await _until(func() -> bool:
		var body := player_net.call("player_for", peer_id) as Node3D
		return body != null and body.global_position.distance_to(TELEPORT_TO) < 0.5
	, TIMEOUT_SEC)
	var body := player_net.call("player_for", peer_id) as Node3D
	var position: Vector3 = body.global_position if body != null else Vector3.ZERO
	_publish({
		"tp_ok": bool(result.get("ok", false)),
		"tp_message": String(result.get("message", "")),
		"tp_position": [position.x, position.y, position.z],
	})


# ── Harness plumbing ─────────────────────────────────────────────────────────────────────────────


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/entity_net_check.gd",
		"--", "entity-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _wait_for_result(done: Callable) -> Dictionary:
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	var result: Dictionary = _read_result()
	while Time.get_ticks_msec() < deadline_msec:
		result = _read_result()
		if bool(done.call(result)):
			return result
		await create_timer(0.05).timeout
	return result


func _until_count(expected: int, timeout_seconds: float) -> int:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var value: int = int(enemy_world.call("live_count"))
	while value != expected and Time.get_ticks_msec() < deadline_msec:
		await create_timer(0.05).timeout
		value = int(enemy_world.call("live_count"))
	return value


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _publish(patch: Dictionary) -> void:
	_report.merge(patch, true)
	_write_result(_report)


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
