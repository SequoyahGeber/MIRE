extends SceneTree

## Real two-process ENet proof for task 3.14's gamerules — everything `tools/rule_check.gd` cannot
## exercise offline:
##
##   · a joiner receives the FULL snapshot of rules the host already changed before it arrived, and
##     its own owning system adopts them (the failure this replaces: a client that quietly runs the
##     host's session on its own authored defaults, looking correct until the difference bites);
##   · a host-side change BROADCASTS to a connected client and lands in that client's owner too;
##   · a non-op client can READ a rule without touching the network (COMMANDS.md §4.2's LOCAL half)
##     but cannot SET one;
##   · once opped, the same client's set crosses `net_submit_command`, the host re-parses it, and the
##     HOST's value moves.
##
##   .agent/bin/agent godot --script tools/rule_net_check.gd
##
## Same driver/probe shape as tools/command_net_check.gd: the driver hosts and relaunches this exact
## script as a client; the two talk through a user:// JSON file, never a fake in-process peer (F-037).

const CommandServiceScript = preload("res://autoload/command_service.gd")

const PORT: int = 47521
const RESULT_PATH: String = "user://rule_net_client.json"
const TIMEOUT_SEC: float = 15.0

## Set on the host BEFORE the client is launched, so the only way the client can know it is the
## join-time snapshot. Deliberately a value no default anywhere equals.
const PRE_JOIN_RULE: StringName = &"bleed_out_seconds"
const PRE_JOIN_VALUE: float = 77.0
## Set on the host AFTER the client is connected — the broadcast path.
const BROADCAST_RULE: StringName = &"ambient_enemy_population"
const BROADCAST_VALUE: int = 9
## The client's own set, once opped — proves a rule change can originate from a client.
const CLIENT_SET_RULE: StringName = &"wave_base_count"
const CLIENT_SET_VALUE: int = 12

var failures: int = 0
var transport: Node
var player_net: Node
var rules: Node
var command_service: CommandServiceScript
var child_pid: int = 0
## Client-side. Every phase MERGES into this and republishes the whole thing, rather than each write
## replacing the file. The driver polls that one file for a key unique to the phase it is waiting on,
## and on loopback the client can finish two phases inside a single 50 ms poll — so a phase's write
## must never be able to answer an EARLIER phase's predicate with its own, later contents. It did:
## re-stating `joined_value` in phase B satisfied the driver's wait for phase A and handed it a
## snapshot with phase A's other keys missing, which read as a product failure and was not one.
var _report: Dictionary = {}


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	rules = root.get_node_or_null(^"RuleService")
	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	if transport == null or player_net == null or rules == null or command_service == null:
		fail("NetTransport, PlayerNet, RuleService and CommandService autoloads must exist")
		finish()
		return

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "rule-probe":
		_run_client()
	else:
		_run_driver()


# ── Driver (host) ────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== gamerule network check (task 3.14) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return

	# BEFORE the client exists. This is the whole point of the snapshot path.
	var pre_join: float = float(rules.call("host_set", PRE_JOIN_RULE, PRE_JOIN_VALUE))
	check(is_equal_approx(pre_join, PRE_JOIN_VALUE),
		"host changes %s to %s before anyone joins" % [PRE_JOIN_RULE, PRE_JOIN_VALUE])

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var client_peer: int = -1
	var got_peer: bool = await _until(func() -> bool: return _first_client_peer() > 0, TIMEOUT_SEC)
	check(got_peer, "host observes the client's peer id")
	client_peer = _first_client_peer()

	# ── phase A: snapshot on join, plus a non-op LOCAL read ──────────────────────────────────────
	var phase_a: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("phase_a_done"))
	check(is_equal_approx(float(phase_a.get("joined_value", -1.0)), PRE_JOIN_VALUE),
		"the joiner's RuleService holds the host's pre-join value (%s)" % phase_a.get("joined_value"))
	check(is_equal_approx(float(phase_a.get("joined_owner_value", -1.0)), PRE_JOIN_VALUE),
		"and the joiner's own PlayerHealth adopted it (%s) — replication reaches the OWNER, not just "
			% phase_a.get("joined_owner_value") + "the service")
	check(bool(phase_a.get("read_ok", false)),
		"a non-op client can read a rule: %s" % phase_a.get("read_message", ""))

	# ── phase B: a non-op client's SET is refused ────────────────────────────────────────────────
	var phase_b: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("refused_ok"))
	check(bool(phase_b.get("refused_ok", false)),
		"a non-op client's set is refused: %s" % phase_b.get("refused_message", ""))
	check(String(phase_b.get("refused_message", "")).begins_with("not op"),
		"with CommandService's uniform not-op wording")
	check(rules.call("value_int", CLIENT_SET_RULE, -1) == 4,
		"and the HOST's value never moved while the client was refused")

	if client_peer > 0:
		var op_result: Dictionary = await command_service.execute(
			"op %d" % client_peer, command_service.build_local_ctx(&"console"))
		check(bool(op_result.get("ok", false)), "host ops the client: %s" % op_result.get("message"))

	# The broadcast half, fired now so it races the client's own retry — a rule change in each
	# direction at once is the realistic case, not a politely serialized one.
	rules.call("host_set", BROADCAST_RULE, float(BROADCAST_VALUE))

	# ── phase C: the opped client's set reaches the host ─────────────────────────────────────────
	var phase_c: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("set_ok"))
	check(bool(phase_c.get("set_ok", false)),
		"the opped client's set succeeded: %s" % phase_c.get("set_message", ""))
	var host_value: int = await _until_rule_int(CLIENT_SET_RULE, CLIENT_SET_VALUE, TIMEOUT_SEC)
	check(host_value == CLIENT_SET_VALUE,
		"the HOST's own RuleService holds the client's value (%d)" % host_value)
	var host_waves: Node = root.get_node_or_null(^"WaveSpawner")
	check(host_waves != null and int(host_waves.get(&"base_count")) == CLIENT_SET_VALUE,
		"and the HOST's WaveSpawner adopted it — a client turned a knob on the host's simulation")

	# ── phase D: the host's broadcast reached the connected client ───────────────────────────────
	var phase_d: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("broadcast_value"))
	check(int(phase_d.get("broadcast_value", -1)) == BROADCAST_VALUE,
		"the connected client saw the host's mid-session change (%s)" % phase_d.get("broadcast_value"))
	check(int(phase_d.get("broadcast_owner_value", -1)) == BROADCAST_VALUE,
		"and its EnemyWorld adopted it (%s)" % phase_d.get("broadcast_owner_value"))

	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0

	transport.call("leave")
	print("RULE_NET_CHECK failures=%d" % failures)
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
	# F-060: gate on is_active(), not local_peer_id() > 0 — the id can read true before the
	# host<->client handshake actually completes.
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout"})
		finish()
		return

	await _client_phase_a_snapshot()
	await _client_phase_b_refused_set()
	await _client_phase_c_opped_set()
	await _client_phase_d_broadcast()
	finish()


## The snapshot is sent from the host's `peer_joined`, which fires after this process reports
## is_active — so poll for it rather than assuming it has already landed. Reporting whatever it last
## saw on timeout is deliberate: the driver's assertion should read "held 30, expected 77", which
## names the bug, rather than a bare timeout that does not.
func _client_phase_a_snapshot() -> void:
	await _until(func() -> bool:
		return is_equal_approx(float(rules.call("value", PRE_JOIN_RULE, -1.0)), PRE_JOIN_VALUE)
	, TIMEOUT_SEC)
	var health: Node = root.get_node_or_null(^"PlayerHealth")
	var read: Dictionary = await command_service.execute(
		"rule %s" % PRE_JOIN_RULE, command_service.build_local_ctx(&"console"))
	_publish({
		"joined_value": float(rules.call("value", PRE_JOIN_RULE, -1.0)),
		"joined_owner_value": float(health.get(&"bleed_out_seconds")) if health != null else -1.0,
		# A LOCAL-scope read on a non-op client. If the dynamic scope were wrong and this routed to
		# the host as a HOST-scope command, it would come back refused instead.
		"read_ok": bool(read.get("ok", false)),
		"read_message": String(read.get("message", "")),
		"phase_a_done": true,
	})


func _client_phase_b_refused_set() -> void:
	var result: Dictionary = await command_service.execute(
		"rule %s %d" % [CLIENT_SET_RULE, CLIENT_SET_VALUE], command_service.build_local_ctx(&"console"))
	_publish({
		"refused_ok": not bool(result.get("ok", true)),
		"refused_message": String(result.get("message", "")),
	})


## The driver ops this peer right after phase B; this process has no other way to learn that, so it
## retries until the host accepts or the whole check times out.
func _client_phase_c_opped_set() -> void:
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	var accepted: bool = false
	var message: String = ""
	while Time.get_ticks_msec() < deadline_msec and not accepted:
		var result: Dictionary = await command_service.execute(
			"rule %s %d" % [CLIENT_SET_RULE, CLIENT_SET_VALUE], ctx)
		accepted = bool(result.get("ok", false))
		message = String(result.get("message", ""))
		if not accepted:
			await create_timer(0.3).timeout
	_publish({"set_ok": accepted, "set_message": message})


func _client_phase_d_broadcast() -> void:
	await _until(func() -> bool:
		return rules.call("value_int", BROADCAST_RULE, -1) == BROADCAST_VALUE
	, TIMEOUT_SEC)
	var enemy_world: Node = root.get_node_or_null(^"EnemyWorld")
	_publish({
		"broadcast_value": rules.call("value_int", BROADCAST_RULE, -1),
		"broadcast_owner_value": int(enemy_world.get(&"ambient_population")) if enemy_world != null else -1,
	})


# ── Harness plumbing (same shape as tools/command_net_check.gd) ──────────────────────────────────


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/rule_net_check.gd",
		"--", "rule-probe",
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


func _until_rule_int(id: StringName, expected: int, timeout_seconds: float) -> int:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var value: int = rules.call("value_int", id, -1)
	while value != expected and Time.get_ticks_msec() < deadline_msec:
		await create_timer(0.05).timeout
		value = rules.call("value_int", id, -1)
	return value


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


## Merge-and-republish, so a later phase's file contents are a SUPERSET of every earlier phase's.
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
