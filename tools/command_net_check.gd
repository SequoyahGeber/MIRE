extends SceneTree

## Real two-process ENet proof for task 3.13 — everything `tools/command_check.gd` cannot exercise
## offline: a client's `give` actually reaches the host over `net_submit_command` and lands in the
## HOST's InventoryService; a non-op client is refused before anything is granted; and the wrinkle
## COMMANDS.md §10 calls out by name — the console genuinely open (so the local tree is paused) while
## the RPC round-trips, proving `SceneTree` really does poll multiplayer outside the pause gate in
## 4.7, the way `debug_console.gd`'s own doc comment assumes.
##
##   .agent/bin/agent godot --script tools/command_net_check.gd
##
## Same driver/probe shape as tools/chest_net_check.gd: the driver hosts and relaunches this exact
## script as a client; the two talk through a user:// JSON file, never a fake in-process peer (F-037).

const CommandServiceScript = preload("res://autoload/command_service.gd")

const PORT: int = 47512
const RESULT_PATH: String = "user://command_net_client.json"
const TIMEOUT_SEC: float = 15.0
const GIVE_ITEM: StringName = &"branch"

var failures: int = 0
var transport: Node
var player_net: Node
var inventory: Node
var command_service: CommandServiceScript
var child_pid: int = 0
## Written by `_on_phase_c_result` — NOT a function-local a lambda closes over. F-107 (see
## chest_net_check.gd): a GDScript lambda captures an outer local BY VALUE, so a `bool`/`Dictionary`
## a signal handler lambda reassigns is invisible to a SEPARATE lambda (`_until`'s condition) reading
## what looks like the same variable. A bound method reading/writing `self` state has no such trap.
var _phase_c_got_result: bool = false
var _phase_c_captured: Dictionary = {}


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	inventory = root.get_node_or_null(^"InventoryService")
	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	if transport == null or player_net == null or inventory == null or command_service == null:
		fail("NetTransport, PlayerNet, InventoryService and CommandService autoloads must exist")
		finish()
		return

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "command-probe":
		_run_client()
	else:
		_run_driver()


# ── Driver (host) ────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== command network check (task 3.13) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var client_peer: int = -1
	var got_peer: bool = await _until(func() -> bool:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				return true
		return false
	, TIMEOUT_SEC)
	check(got_peer, "host observes the client's peer id")
	if got_peer:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				client_peer = peer_id
				break

	# ── phase A: non-op refusal, proven from BOTH sides ──────────────────────────────────────────
	var phase_a: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("refused_ok"))
	check(bool(phase_a.get("refused_ok", false)),
		"client observed a refusal before being opped: %s" % phase_a.get("refused_message", ""))
	check(String(phase_a.get("refused_message", "")).begins_with("not op"),
		"the refusal is CommandService's uniform not-op wording")
	if client_peer > 0:
		check(int(inventory.call("host_count", client_peer, GIVE_ITEM)) == 0,
			"nothing was granted while the client was refused — the host never even ran the handler")

	# ── the host itself ops the client, over the SAME front door a console command would use ──────
	if client_peer > 0:
		var op_ctx: Dictionary = command_service.build_local_ctx(&"console")
		var op_result: Dictionary = await command_service.execute(
			"op %d" % client_peer, op_ctx)
		check(bool(op_result.get("ok", false)), "host ops the client: %s" % op_result.get("message"))

	# ── phase B: opped, the client's retry succeeds ─────────────────────────────────────────────
	# Not gating on the host's inventory count HERE: the client moves on to phase C the instant its
	# OWN retry succeeds, with no barrier waiting for the driver to look — on loopback ENet all three
	# requests (refuse, refuse, accept) can complete in well under one polling interval, so by the
	# time this line runs phase C's grant may ALREADY be in. The cumulative check after phase C below
	# is the one that actually pins down "exactly two grants landed, nothing lost or duplicated".
	var phase_b: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("opped_ok"))
	check(bool(phase_b.get("opped_ok", false)), "client's give succeeded once opped")

	# ── phase C: console genuinely open (tree paused) while the RPC round-trips (COMMANDS.md §10) ──
	var phase_c: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("paused_ok"))
	check(bool(phase_c.get("was_paused", false)),
		"the client's tree was actually paused for this submission — otherwise this proves nothing")
	check(bool(phase_c.get("paused_ok", false)),
		"the RPC round-trip still completed while paused: %s" % phase_c.get("paused_message", ""))
	if client_peer > 0:
		var count_after_c: int = await _until_count(client_peer, GIVE_ITEM, 4, TIMEOUT_SEC)
		check(count_after_c == 4,
			"the HOST's own InventoryService holds exactly both grants (1 + 3), not the client's own "
				+ "and nothing dropped or duplicated (got %d)" % count_after_c)

	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0

	transport.call("leave")
	print("COMMAND_NET_CHECK failures=%d" % failures)
	finish()


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
	var peer_id: int = int(transport.call("local_peer_id"))
	var spawned: bool = await _until(func() -> bool:
		return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	if not spawned:
		_write_result({"error": "player spawn timeout"})
		finish()
		return

	await _client_phase_a_refusal()
	await _client_phase_b_opped_retry()
	await _client_phase_c_paused_console()
	finish()


## Not opped yet — `give` must route the RPC, the host must refuse it, and the refusal must come
## back over `net_command_result` as a normal CommandResult, not a timeout or a dropped connection.
func _client_phase_a_refusal() -> void:
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var result: Dictionary = await command_service.execute("give %s 1" % GIVE_ITEM, ctx)
	_write_result({
		"refused_ok": not bool(result.get("ok", true)),
		"refused_message": String(result.get("message", "")),
	})


## The driver ops this peer right after phase A; this process has no other way to learn that, so it
## just retries the same command until the host accepts it or the whole check times out.
func _client_phase_b_opped_retry() -> void:
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	var accepted: bool = false
	while Time.get_ticks_msec() < deadline_msec and not accepted:
		var result: Dictionary = await command_service.execute("give %s 1" % GIVE_ITEM, ctx)
		accepted = bool(result.get("ok", false))
		if not accepted:
			await create_timer(0.3).timeout
	_write_result({"refused_ok": true, "opped_ok": accepted})


## COMMANDS.md §10's wrinkle: open the console for real (pause_while_open pauses this process's
## tree, same as it would on a real client) and submit through the REAL UI path — DebugConsole's
## `_on_submitted` -> `_run` -> `submit()` + the `command_result` signal — not a shortcut straight to
## CommandService.execute(). If the RPC round trip cannot complete while paused, this hangs until
## TIMEOUT_SEC and reports `paused_ok: false`.
func _client_phase_c_paused_console() -> void:
	var console: Node = root.get_node_or_null(^"DebugConsole")
	if console == null:
		_write_result({"refused_ok": true, "opped_ok": true, "paused_ok": false,
			"paused_message": "no DebugConsole autoload"})
		return

	_phase_c_got_result = false
	_phase_c_captured = {}
	command_service.command_result.connect(_on_phase_c_result)

	console.call("set_open", true)
	# This script IS the SceneTree (extends SceneTree) — `paused` is its own property, there is no
	# separate tree to fetch.
	var was_paused: bool = paused
	console.call("_on_submitted", "give %s 3" % GIVE_ITEM)

	var completed: bool = await _until(func() -> bool: return _phase_c_got_result, TIMEOUT_SEC)
	console.call("set_open", false)
	command_service.command_result.disconnect(_on_phase_c_result)

	_write_result({
		"refused_ok": true,
		"opped_ok": true,
		"was_paused": was_paused,
		"paused_ok": completed and bool(_phase_c_captured.get("ok", false)),
		"paused_message": String(_phase_c_captured.get("message", "")) if completed
			else "timed out while paused",
	})


func _on_phase_c_result(_handle: int, result: Dictionary) -> void:
	_phase_c_captured = result
	_phase_c_got_result = true


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/command_net_check.gd",
		"--", "command-probe",
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


## Polls the HOST's own live InventoryService count for [param peer_id]/[param item_id] until it
## reaches [param expected] or [param timeout_seconds] runs out, returning whatever it last saw.
func _until_count(peer_id: int, item_id: StringName, expected: int, timeout_seconds: float) -> int:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var value: int = int(inventory.call("host_count", peer_id, item_id))
	while value != expected and Time.get_ticks_msec() < deadline_msec:
		await create_timer(0.05).timeout
		value = int(inventory.call("host_count", peer_id, item_id))
	return value


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
