extends SceneTree

## Review probe for task 3.3's D-035 lifecycle replication.
##
## The host keeps powerups while a player is in the reconnect grace window, then either moves them
## to the replacement peer id or expires them. Teammates must see the old id disappear in both
## cases; otherwise their replicated family-count board retains ghost Resonances forever.

const PORT: int = 47462
const MODE_LOCAL: int = 1
const OLD_PEER: int = 701
const NEW_PEER: int = 702
const RESULT_PATH: String = "user://powerup_review_client.json"
const CONTROL_PATH: String = "user://powerup_review_control.json"
const TIMEOUT_SEC: float = 10.0

var failures: int = 0
var child_pid: int = 0
var transport: Node
var service: Node


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	service = root.get_node_or_null(^"PowerupService")
	if transport == null or service == null:
		fail("NetTransport and PowerupService autoloads must exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "powerup-review-probe":
		await _run_client()
	else:
		await _run_driver()


func _run_driver() -> void:
	print("== task 3.3 review: lifecycle removes old replicated family counts ==")
	_remove_file(RESULT_PATH)
	_remove_file(CONTROL_PATH)
	_write_json(CONTROL_PATH, {"exit": false})

	var error: Error = transport.call(&"host", MODE_LOCAL, PORT)
	check(error == OK, "host starts")
	if error != OK:
		finish()
		return

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")
	var connected: bool = await _until(
		func() -> bool: return bool(_read_json(RESULT_PATH).get("connected", false))
	)
	check(connected, "client connects")
	if not connected:
		finish()
		return

	service.call(&"host_grant", OLD_PEER, &"swift_stride", 3)
	var initial_arrived: bool = await _until(
		func() -> bool: return int(_read_json(RESULT_PATH).get("old_count", 0)) == 3
	)
	check(initial_arrived, "teammate receives the parked player's family count")

	service.call(&"_on_run_player_rebound", OLD_PEER, NEW_PEER)
	var rebound_arrived: bool = await _until(
		func() -> bool: return int(_read_json(RESULT_PATH).get("new_count", 0)) == 3
	)
	check(rebound_arrived, "teammate receives the rebound peer's family count")
	check(int(_read_json(RESULT_PATH).get("old_count", -1)) == 0,
		"rebound clears the obsolete peer id on teammates")

	service.call(&"_on_run_player_expired", NEW_PEER)
	await create_timer(0.25).timeout
	check(int(_read_json(RESULT_PATH).get("new_count", -1)) == 0,
		"expiry clears the departed player's family count on teammates")

	_write_json(CONTROL_PATH, {"exit": true})
	await _until(func() -> bool: return not OS.is_process_running(child_pid), 3.0)
	print("POWERUP_REVIEW_CHECK failures=%d" % failures)
	finish()


func _run_client() -> void:
	var error: Error = transport.call(&"join", MODE_LOCAL, "", PORT)
	if error != OK:
		_write_json(RESULT_PATH, {"error": error_string(error)})
		finish()
		return
	var connected: bool = await _until(func() -> bool: return bool(transport.call(&"is_active")))
	if not connected:
		_write_json(RESULT_PATH, {"error": "connection timed out"})
		finish()
		return
	while not bool(_read_json(CONTROL_PATH).get("exit", false)):
		_write_json(RESULT_PATH, {
			"connected": true,
			"old_count": int(service.call(&"family_count", OLD_PEER, &"Kinetic")),
			"new_count": int(service.call(&"family_count", NEW_PEER, &"Kinetic")),
		})
		await create_timer(0.05).timeout
	transport.call(&"leave")
	finish()


func _spawn_client() -> int:
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "tools/powerup_review_check.gd", "--", "powerup-review-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_sec: float = TIMEOUT_SEC) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


## F-290: written to a sibling `.part` path and RENAMED into place. Both directions race here — the
## probe rewrites RESULT_PATH in a loop while the driver polls it, and the driver rewrites
## CONTROL_PATH while the probe polls that. A plain `FileAccess.WRITE` truncates before
## `store_string()` refills, so either reader can catch an empty or half document and
## `JSON.parse_string` logs `Parse JSON failed` as an undeclared ERROR line (SPECS standing rule 4)
## in a run that still prints `failures=0`. A rename is atomic.
## `tools/json_result_race_check.gd` measures both forms.
func _write_json(path: String, value: Dictionary) -> void:
	var staging: String = path + ".part"
	var file := FileAccess.open(staging, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(value))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(staging), ProjectSettings.globalize_path(path))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var raw: String = FileAccess.get_file_as_string(path)
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	return parsed if parsed is Dictionary else {}


## Takes the staging sibling with it — a run killed mid-write can leave a `.part` behind.
func _remove_file(path: String) -> void:
	for stale: String in [path, path + ".part"]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))


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
	if transport != null and bool(transport.call(&"is_active")):
		transport.call(&"leave")
	quit(0 if failures == 0 else 1)
