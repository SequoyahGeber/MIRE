extends SceneTree

## F-290's mechanism, made deterministic and permanent.
##
## Every two-process `--script` check in `tools/` talks to its spawned probe through one `user://`
## JSON file: the child rewrites it in a loop, the parent polls it every 50 ms. Written with a plain
## `FileAccess.open(path, FileAccess.WRITE)` that is a truncate-then-refill, so a poll landing inside
## the window reads an empty or half document and `JSON.parse_string` logs
## `Parse JSON failed. Error at line 0: Unknown error getting token` — an UNDECLARED `ERROR:` line
## (SPECS standing rule 4) in a run that still prints `failures=0` and exits 0. That is exactly what
## F-259-review caught once at HEAD in `tools/wave_spawner_cycle_net_check.gd` and could not
## reproduce on rerun, because the window is a few hundred microseconds wide at a ~100-byte payload.
##
## This file does not wait for luck. A child process hammers one path with a payload large enough
## that the truncate window is milliseconds wide, twice: once with the plain truncating write, once
## with the write-to-`.part`-then-`DirAccess.rename_absolute` form the fix uses. The parent counts
## TORN reads — samples where the file existed but did not parse as the whole document — for each.
## The renamed round must be torn ZERO times; POSIX `rename(2)` swaps the directory entry, so a
## reader sees the previous whole document or the next whole document and never a partial one.
##
##   .agent/bin/agent godot --script tools/json_result_race_check.gd
##
## Authority: none. This is a filesystem-transport proof for the check harness itself — it starts no
## `NetTransport`, touches no game system, and declares no ARCHITECTURE.md §2.2 row.
##
## Reads here go through `JSON.new().parse()`, NOT the static `JSON.parse_string()`. The instance
## method returns an `Error` silently; the static one `ERR_PRINT`s on malformed input. A check whose
## job is to COUNT torn reads must not emit an engine ERROR for each one it finds — it would fail
## its own standing-rule-4 grep while succeeding at its measurement.

const RESULT_PATH: String = "user://json_result_race_probe.json"
const PART_PATH: String = RESULT_PATH + ".part"
const DONE_PATH: String = "user://json_result_race_done.json"
const PAYLOAD_BYTES: int = 262144  # wide enough that truncate-then-refill is a real window
const WRITE_SECONDS: float = 2.0
const SAMPLE_DELAY_SEC: float = 0.001
const TIMEOUT_SEC: float = 30.0

var failures: int = 0
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() >= 2 and args[0] == "race-writer":
		_run_writer(args[1])
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== F-290: a polled user:// result file must never hand its reader a torn document ==")

	var plain_torn: int = await _measure("plain")
	var atomic_torn: int = await _measure("atomic")

	print("plain truncate-then-write: %d torn read(s)" % plain_torn)
	print("write-to-.part-then-rename: %d torn read(s)" % atomic_torn)

	check(atomic_torn == 0,
		("the renamed write is never observed torn — a reader sees the previous whole document or "
		+ "the next one, never a partial one (got %d torn)") % atomic_torn)

	# Evidence, not a gate: the plain window is timing-dependent, and a machine under no load can
	# miss it. When it IS observed, say so — that observation is F-290's repro.
	if plain_torn > 0:
		print(("PASS: F-290's race reproduced on this run — the plain truncating write was caught "
			+ "mid-rewrite %d time(s), each of which is one undeclared `Parse JSON failed` ERROR "
			+ "line in a check that would still print failures=0") % plain_torn)
	else:
		print(("NOTE: the plain truncating write was not caught torn on this run. The window is "
			+ "load-dependent, not absent — F-290 was observed once in %d runs of "
			+ "wave_spawner_cycle_net_check. The atomic assertion above is the standing guarantee.")
			% 3)

	print("JSON_RESULT_RACE_CHECK failures=%d" % failures)
	finish()


## One round: spawn a writer in `mode`, poll its file until the writer reports done, count the
## samples that existed but did not parse as the whole document.
func _measure(mode: String) -> int:
	_remove_all()
	child_pid = _spawn_writer(mode)
	if child_pid <= 0:
		fail("writer process launches (%s)" % mode)
		return 0

	var torn: int = 0
	var samples: int = 0
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if FileAccess.file_exists(DONE_PATH):
			break
		if FileAccess.file_exists(RESULT_PATH):
			samples += 1
			if not _parses_whole(FileAccess.get_file_as_string(RESULT_PATH)):
				torn += 1
		await create_timer(SAMPLE_DELAY_SEC).timeout

	check(FileAccess.file_exists(DONE_PATH), "%s writer finished inside %ds" % [mode, int(TIMEOUT_SEC)])
	check(samples > 0, "%s round actually sampled the file (%d samples)" % [mode, samples])
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
	child_pid = 0
	return torn


## True only for a complete document carrying the sentinel key. `JSON.new().parse()` so a torn
## sample is COUNTED, not logged as an engine ERROR (see the header).
func _parses_whole(raw: String) -> bool:
	if raw.is_empty():
		return false
	var json := JSON.new()
	if json.parse(raw) != OK:
		return false
	var parsed: Variant = json.data
	if not parsed is Dictionary:
		return false
	return (parsed as Dictionary).has("payload")


func _run_writer(mode: String) -> void:
	var payload: String = "x".repeat(PAYLOAD_BYTES)
	var deadline_msec: int = Time.get_ticks_msec() + int(WRITE_SECONDS * 1000.0)
	var ticks: int = 0
	while Time.get_ticks_msec() < deadline_msec:
		ticks += 1
		var document: String = JSON.stringify({"tick": ticks, "payload": payload})
		if mode == "atomic":
			_write_atomic(document)
		else:
			_write_plain(document)
		await process_frame
	_write_done(ticks)
	quit(0)


func _write_plain(document: String) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(document)
	file.close()


func _write_atomic(document: String) -> void:
	var file := FileAccess.open(PART_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(document)
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(PART_PATH), ProjectSettings.globalize_path(RESULT_PATH))


func _write_done(ticks: int) -> void:
	var file := FileAccess.open(DONE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"ticks": ticks}))
	file.close()


func _spawn_writer(mode: String) -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/json_result_race_check.gd",
		"--", "race-writer", mode,
	])
	return OS.create_process(OS.get_executable_path(), args)


func _remove_all() -> void:
	for path: String in [RESULT_PATH, PART_PATH, DONE_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


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
	_remove_all()
	quit(0 if failures == 0 else 1)
