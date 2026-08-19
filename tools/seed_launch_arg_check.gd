extends SceneTree

## F-172 proof: a `--seed=<value>` launch argument reaches `GameState` before anything on the
## solo/offline path (`MireGrid.ensure_ready()` → `GameState.ensure_seed()`) could ever draw one.
##
##   .agent/bin/agent godot --script tools/seed_launch_arg_check.gd -- --seed=204060517
##
## THIS process must itself be launched with the `--seed=` argument being tested — `GameState`'s own
## autoload `_ready()` (which parses it) runs before this script's `_initialize()` ever fires, so the
## driver case below proves the real boot-order guarantee, not a simulation of it. Two child
## processes (docs/SPECS.md's "Two-process checks" seam) cover the cases the driver's own fixed
## launch can't: no `--seed=` arg at all (default path unchanged), and a non-integer `--seed=` text
## (hashed the same way `ui/menu/main_menu.gd`'s `request_set_seed()` hashes a typed word-seed).

const RESULT_PATH: String = "user://seed_launch_arg_check_child.json"
const TIMEOUT_SEC: float = 15.0

## The value this whole check must itself be launched with — see the header comment.
const TEST_SEED: int = 204060517
const TEST_TEXT_SEED: String = "hollowmere-test-seed"

var failures: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "seed-launch-probe":
		_run_probe()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== F-172 seed launch-argument check ==")

	var game_state: Node = root.get_node_or_null(^"GameState")
	check(game_state != null, "GameState autoload is registered")
	if game_state == null:
		print("SEED_LAUNCH_ARG_CHECK failures=%d" % failures)
		quit(1)
		return

	# ── Case 1: THIS process's own --seed= arg. GameState._ready() (which parses it) and MireGrid's
	# own first _physics_process (which calls ensure_seed()) both already ran by `await process_frame`
	# above — same boot order a real solo session goes through — so `run_seed` below is MireGrid's
	# own real world-gen seed, not a value this script drew itself. ────────────────────────────────
	check(bool(game_state.call("is_seed_ready")),
		"solo boot already drew a seed by the time this script's own _start() runs")
	check(int(game_state.get(&"run_seed")) == TEST_SEED,
		"MireGrid's real boot-time draw used the launch-arg seed, not real entropy (got %d)" % int(game_state.get(&"run_seed")))
	check(int(game_state.call("ensure_seed")) == TEST_SEED,
		"ensure_seed() stays idempotent — a second call returns the same launch-arg seed")

	# ── Case 2: no --seed= arg at all -> default eager-draw path is untouched. ─────────────────────
	_clear_result()
	var no_arg_pid: int = _spawn_probe(PackedStringArray())
	var no_arg_result: Dictionary = await _wait_for_result(no_arg_pid)
	check(bool(no_arg_result.get("ok", false)), "child with no --seed= arg exits cleanly")
	check(not bool(no_arg_result.get("has_pending", true)),
		"no --seed= arg means no pending seed is staged (default solo boot is unchanged)")

	# ── Case 3: non-integer text hashes exactly the way MainMenu's seed field already does. ────────
	_clear_result()
	var text_pid: int = _spawn_probe(PackedStringArray(["--seed=%s" % TEST_TEXT_SEED]))
	var text_result: Dictionary = await _wait_for_result(text_pid)
	check(bool(text_result.get("ok", false)), "child with a text --seed= exits cleanly")
	check(int(text_result.get("pending_seed", -1)) == TEST_TEXT_SEED.hash(),
		"non-integer --seed= text hashes with String.hash(), same convention MainMenu.request_set_seed() uses")

	print("SEED_LAUNCH_ARG_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _run_probe() -> void:
	var game_state: Node = root.get_node_or_null(^"GameState")
	_write_result({
		"ok": game_state != null,
		"has_pending": game_state != null and bool(game_state.call("has_pending_seed")),
		"pending_seed": int(game_state.call("pending_seed")) if game_state != null else -1,
	})
	quit(0)


func _spawn_probe(extra_args: PackedStringArray) -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var full_args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/seed_launch_arg_check.gd",
		"--", "seed-launch-probe",
	])
	for arg: String in extra_args:
		full_args.append(arg)
	return OS.create_process(OS.get_executable_path(), full_args)


func _wait_for_result(pid: int) -> Dictionary:
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if not OS.is_process_running(pid):
			break
		await create_timer(0.05).timeout
	if FileAccess.file_exists(RESULT_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
		if parsed is Dictionary:
			return parsed
	return {}


func _clear_result() -> void:
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))


func _write_result(result: Dictionary) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	fail(description)


func fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)
