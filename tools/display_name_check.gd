extends SceneTree

## Real two-process ENet proof for F-157's display-name registry — everything a single offline
## process cannot exercise: a client's chosen name actually reaching the HOST over
## `net_request_display_name`, the host's sanitized result reaching back to that same client over
## `net_display_name_changed`, a peer that connects AFTER a name is already set receiving it via
## `net_display_name_snapshot` rather than waiting for a resubmission, `CommandService._parse_peer()`
## resolving a name to the right peer id (case-insensitively) through the real registry, and the
## ambiguous-match refusal when two connected peers share a name.
##
##   .agent/bin/agent godot --script tools/display_name_check.gd
##
## Same driver/probe shape as tools/command_net_check.gd: the driver hosts and relaunches this exact
## script as a client; the two talk through a user:// JSON file, never a fake in-process peer (F-037).

const CommandServiceScript = preload("res://autoload/command_service.gd")

const PORT: int = 47513
const RESULT_PATH: String = "user://display_name_check_client.json"
const TIMEOUT_SEC: float = 15.0
const HOST_NAME: String = "HostName"
const FIRST_CLIENT_NAME: String = "Rowan"
## Leading/trailing whitespace, a control character (BEL), and well over the 24-char cap — proves
## _sanitize_display_name() trims, strips, and caps rather than storing the raw wire value.
const MESSY_NAME: String = "  Verylongdisplaynamewaytoolong1234  "
const DUP_NAME: String = "Dup"

var failures: int = 0
var transport: Node
var command_service: CommandServiceScript
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	if transport == null or command_service == null:
		fail("NetTransport and CommandService autoloads must exist")
		finish()
		return

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "display-name-probe":
		_run_client()
	else:
		_run_driver()


# ── Driver (host) ────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== display name check (F-157) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return

	# The host is a peer too, and nothing else submits a name on its behalf (host()'s own
	# auto-submit already ran) — override it with a deterministic value the rest of this check can
	# assert against without depending on the machine's OS username / Steam persona.
	transport.call("submit_display_name", HOST_NAME)
	check(String(transport.call("display_name", NetConfig.HOST_PEER_ID)) == HOST_NAME,
		"host applies its own submitted name directly, no RPC round trip needed")

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var client_peer: int = await _until_client_peer()
	check(client_peer > 0, "host observes the client's peer id")
	if client_peer <= 0:
		finish()
		return

	# ── round trip: the client's explicit submission lands on the host, sanitized ────────────────
	var got_first_name: bool = await _until(func() -> bool:
		return String(transport.call("display_name", client_peer)) == FIRST_CLIENT_NAME
	, TIMEOUT_SEC)
	check(got_first_name, "host's registry reflects the client's submitted name '%s' (got '%s')" % [
		FIRST_CLIENT_NAME, transport.call("display_name", client_peer)
	])

	# ── CommandService._parse_peer() resolves a name against the real registry ──────────────────
	var host_ctx: Dictionary = command_service.build_local_ctx(&"console")
	var by_name: Dictionary = await command_service.execute("op %s" % FIRST_CLIENT_NAME, host_ctx)
	check(bool(by_name.get("ok", false)), "op resolves a display name: %s" % by_name.get("message"))
	check(int((by_name.get("data", {}) as Dictionary).get("peer", -1)) == client_peer,
		"op by name opped the RIGHT peer id (%d)" % client_peer)

	var by_name_upper: Dictionary = await command_service.execute(
		"op %s" % FIRST_CLIENT_NAME.to_upper(), host_ctx)
	check(bool(by_name_upper.get("ok", false)), "name resolution is case-insensitive: %s" % by_name_upper.get("message"))
	await command_service.execute("deop %d" % client_peer, host_ctx)

	# ── sanitization: a messy raw submission arrives on the host trimmed, stripped, capped ─────────
	var sanitize_ok: bool = await _wait_for_sanitized_name(client_peer)
	check(sanitize_ok, "messy client-submitted name arrives sanitized: '%s'" % transport.call("display_name", client_peer))

	# ── ambiguous match: two connected peers with the same name refuse rather than guess ──────────
	transport.call("submit_display_name", DUP_NAME)
	check(String(transport.call("display_name", NetConfig.HOST_PEER_ID)) == DUP_NAME,
		"host renames itself to the duplicate-test name")
	_write_client_command("dup-name")
	var got_dup: bool = await _until(func() -> bool:
		return String(transport.call("display_name", client_peer)).nocasecmp_to(DUP_NAME) == 0
	, TIMEOUT_SEC)
	check(got_dup, "client also takes the duplicate-test name (case-varied)")

	var ambiguous: Dictionary = await command_service.execute("op %s" % DUP_NAME, host_ctx)
	check(not bool(ambiguous.get("ok", true)), "op by an ambiguous name is refused, not guessed")
	var ambiguous_msg: String = String(ambiguous.get("message", ""))
	check(ambiguous_msg.contains("matches more than one peer") and ambiguous_msg.contains(str(client_peer)),
		"refusal names the ambiguity and lists the peer ids: %s" % ambiguous_msg)

	# ── snapshot: the client's own mirror learned the host's PRE-EXISTING name on connect ─────────
	var snapshot: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("host_name_seen"))
	check(String(snapshot.get("host_name_seen", "")) == HOST_NAME,
		"client's own registry mirror received the host's name via the join snapshot, not a resubmit: got '%s'" % snapshot.get("host_name_seen"))

	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0

	transport.call("leave")
	print("DISPLAY_NAME_CHECK failures=%d" % failures)
	finish()


## Drives the sanitization phase: tells the client (via the result file's "next" field) to submit
## MESSY_NAME, then polls until the host's registry shows a plausibly-sanitized result — no leading/
## trailing whitespace, no control character, within the length cap, and different from what was
## there before.
func _wait_for_sanitized_name(client_peer: int) -> bool:
	_write_client_command("sanitize")
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		var name: String = String(transport.call("display_name", client_peer))
		if name != FIRST_CLIENT_NAME and name == name.strip_edges() and not name.is_empty():
			var clean: bool = true
			for c: String in name:
				if c.unicode_at(0) < 0x20 or c.unicode_at(0) == 0x7F:
					clean = false
					break
			if clean and name.length() <= 24:
				return true
		await create_timer(0.05).timeout
	return false


## Same shape as command_net_check.gd's own peer-detection block: the wait condition and the answer
## are two separate scans of peer_ids(), not a value threaded out of the lambda — a lambda closing
## over an outer local is its own trap (F-107, command_net_check.gd's header) that re-scanning avoids
## outright.
func _until_client_peer() -> int:
	var got: bool = await _until(func() -> bool:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				return true
		return false
	, TIMEOUT_SEC)
	if not got:
		return -1
	for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
		if peer_id != NetConfig.HOST_PEER_ID:
			return peer_id
	return -1


## Tells the client probe what to do next. The client polls this file for a "cmd" it has not already
## acted on — same one-file coordination channel _write_result/_read_result use for results, just
## read in the other direction.
func _write_client_command(cmd: String) -> void:
	var existing: Dictionary = _read_result()
	existing["cmd"] = cmd
	_write_result(existing)


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
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout"})
		finish()
		return

	# Snapshot proof: the host already renamed itself to HOST_NAME before this process was even
	# spawned, so seeing it here proves net_display_name_snapshot(), not a resubmission this process
	# somehow triggered.
	var host_name_seen: String = await _until_host_name()
	_write_result({"host_name_seen": host_name_seen})

	transport.call("submit_display_name", FIRST_CLIENT_NAME)
	await _act_on_driver_commands()
	finish()


func _until_host_name() -> String:
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		var name: String = String(transport.call("display_name", NetConfig.HOST_PEER_ID))
		if name != "Player %d" % NetConfig.HOST_PEER_ID:
			return name
		await create_timer(0.05).timeout
	return String(transport.call("display_name", NetConfig.HOST_PEER_ID))


## Watches the shared result file for "cmd" values the driver writes and acts on each exactly once —
## the mirror image of command_net_check.gd's phase functions, just command-driven instead of
## timing-driven, because the driver needs to control exactly when the messy/duplicate names go out.
func _act_on_driver_commands() -> void:
	var seen: Dictionary = {}
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		var state: Dictionary = _read_result()
		var cmd: String = String(state.get("cmd", ""))
		if not cmd.is_empty() and not seen.has(cmd):
			seen[cmd] = true
			match cmd:
				"sanitize":
					transport.call("submit_display_name", MESSY_NAME)
				"dup-name":
					transport.call("submit_display_name", DUP_NAME.to_lower())
					# Reliable RPCs are still queued packets — ENet needs a few more polled frames to
					# actually put this one on the wire before the process exits. Racing straight to
					# finish() here dropped the submission entirely: the client disconnected before
					# the host ever saw it (caught by this check's first run).
					await create_timer(0.5).timeout
					return
		await create_timer(0.05).timeout


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/display_name_check.gd",
		"--", "display-name-probe",
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
