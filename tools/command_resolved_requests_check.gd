extends SceneTree

## F-224 regression guard: proves `CommandService._resolved_requests` (client-side only — see the
## dictionary's own doc comment) is erased once a host round trip resolves, instead of growing for
## the life of the process. Real two-process ENet, same driver/probe shape as `command_net_check.gd`
## (never a fake in-process peer — F-037); the client never needs to be opped, because a HOST-scope
## command still round-trips through `_submit_to_host()` on its way to being refused with "not op" —
## that refusal is exactly what exercises the guard this check is proving.
##
##   .agent/bin/agent godot --script tools/command_resolved_requests_check.gd

const CommandServiceScript = preload("res://autoload/command_service.gd")

const PORT: int = 47513
const RESULT_PATH: String = "user://command_resolved_requests_client.json"
const TIMEOUT_SEC: float = 15.0
const REQUEST_ROUNDS: int = 5

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
	if not args.is_empty() and args[0] == "resolved-requests-probe":
		_run_client()
	else:
		_run_driver()


# ── Driver (host) ────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== command _resolved_requests check (F-224) ==")
	for stale: String in [RESULT_PATH, RESULT_PATH + ".part"]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var result: Dictionary = await _wait_for_result(func(r: Dictionary) -> bool: return r.has("done"))
	check(bool(result.get("done", false)), "client finished its %d round trips" % REQUEST_ROUNDS)

	var counts_after: Array = result.get("counts_after", [])
	check(counts_after.size() == REQUEST_ROUNDS,
		"client reported one post-request count per round trip (got %d)" % counts_after.size())
	var all_zero: bool = true
	for count: Variant in counts_after:
		if int(count) != 0:
			all_zero = false
	check(all_zero,
		"_resolved_requests is empty again after EVERY round trip, not just eventually (%s)" % [counts_after])

	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0

	transport.call("leave")
	print("COMMAND_RESOLVED_REQUESTS_CHECK failures=%d" % failures)
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

	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var counts_after: Array = []
	for i: int in REQUEST_ROUNDS:
		# Never opped — a HOST-scope command still has to round-trip through `_submit_to_host()` to
		# come back "not op", and that round trip is exactly what arms and then must clear the guard.
		var result: Dictionary = await command_service.execute("op %d" % (i + 1), ctx)
		if bool(result.get("ok", false)):
			_write_result({"error": "unexpectedly opped — this check assumes a non-op client"})
			finish()
			return
		counts_after.append(command_service.resolved_request_count())

	_write_result({"done": true, "counts_after": counts_after})
	finish()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/command_resolved_requests_check.gd",
		"--", "resolved-requests-probe",
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


## F-290: written to a sibling `.part` path and RENAMED into place. The probe rewrites this file in
## a loop while the driver polls it, and a plain `FileAccess.WRITE` truncates the target before
## `store_string()` refills it — a poll landing in that window reads an empty or half document and
## `JSON.parse_string` logs `Parse JSON failed` as an undeclared ERROR line (SPECS standing rule 4)
## in a run that still prints `failures=0`. A rename is atomic: the reader sees the previous whole
## document or the next one, never a torn one. `tools/json_result_race_check.gd` measures both forms.
func _write_result(result: Dictionary) -> void:
	var staging: String = RESULT_PATH + ".part"
	var file := FileAccess.open(staging, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(staging), ProjectSettings.globalize_path(RESULT_PATH))


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var raw: String = FileAccess.get_file_as_string(RESULT_PATH)
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw)
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
