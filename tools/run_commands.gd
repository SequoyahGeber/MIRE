extends SceneTree

## The headless runner docs/COMMANDS.md §6 promises: executes a `.mcmd` command file line-by-line
## through CommandService's real front door and reports structured pass/fail — the mechanism every
## future check's scenario SETUP can lean on instead of hand-poking services (§6's own words: "give
## iron_sword, spawn crawler 3, time set 0.8, rule wave_base_count 10 — and the check asserts on
## state"). content/functions/dev_scenario.mcmd is the worked example this task ships.
##
##   .agent/bin/agent godot --script tools/run_commands.gd -- --file <path> [--json]
##
## Boots the real project offline (host-of-one, exactly like tools/command_check.gd) so every
## command runs against real content/services, not a stand-in. `--file` accepts ANY path, not only
## content/functions/ — a one-off scenario for a single check run has no reason to become permanent
## content.
##
## Recognizes ONE directive of its own, `# expect-fail`, on its own line immediately before the ONE
## command line it applies to — inverts that line's pass/fail so a refusal path is testable without
## every future checker inventing its own "this should fail" convention. Every other `#` line is a
## plain comment, same rule as the `.mcmd` format itself (FunctionRunner.parse_lines) — this file
## intentionally does not share that parser, because a shared one would have nowhere to keep the
## expect-fail flag attached to the line that follows it.
##
## Exit code is non-zero the moment any line's actual result (after an expect-fail inversion)
## disagrees with what was expected — this is what lets a CI-shaped caller trust `$?` alone.
##
## F-016: command_service.gd is a script this session may not have scanned into the class cache yet.
const CommandServiceScript = preload("res://autoload/command_service.gd")

const EXPECT_FAIL_DIRECTIVE: String = "# expect-fail"
const HOST_PEER_ID: int = 1  # NetConfig.HOST_PEER_ID — not preloaded, this file never needs the rest of it

var command_service: CommandServiceScript
var _failures: int = 0
var _as_json: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame  # every autoload's own _ready() (command_check.gd's own convention) has settled

	var parsed_args: Dictionary = _parse_args(OS.get_cmdline_user_args())
	_as_json = bool(parsed_args.get("json", false))
	var file_path: String = String(parsed_args.get("file", ""))
	if file_path.is_empty():
		push_error("run_commands: --file <path> is required")
		quit(1)
		return
	if not FileAccess.file_exists(file_path):
		push_error("run_commands: cannot open '%s'" % file_path)
		quit(1)
		return

	var node: Node = root.get_node_or_null(^"CommandService")
	if node == null:
		push_error("run_commands: CommandService autoload never appeared")
		quit(1)
		return
	command_service = node as CommandServiceScript

	var ctx: Dictionary = {
		"peer_id": HOST_PEER_ID, "source": &"runner",
		"position": Vector3.ZERO, "facing": Vector3.FORWARD,
	}

	var expect_fail: bool = false
	for raw_line: String in FileAccess.get_file_as_string(file_path).split("\n"):
		var line: String = raw_line.strip_edges()
		if line.is_empty():
			continue
		if line == EXPECT_FAIL_DIRECTIVE:
			expect_fail = true
			continue
		if line.begins_with("#"):
			continue

		var result: Dictionary = await command_service.execute(line, ctx)
		_report(line, result, expect_fail)
		expect_fail = false

	print("\nRUN_COMMANDS failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _report(line: String, result: Dictionary, expect_fail: bool) -> void:
	var ok: bool = bool(result.get("ok", false))
	var passed: bool = (not ok) if expect_fail else ok
	if not passed:
		_failures += 1
	if _as_json:
		print(JSON.stringify({
			"line": line, "ok": ok, "expect_fail": expect_fail, "passed": passed,
			"message": result.get("message", ""), "data": result.get("data", {}),
		}))
		return
	var tag: String = "PASS" if passed else "FAIL"
	print("%s: %s -> %s" % [tag, line, result.get("message", "")])


func _parse_args(user_args: PackedStringArray) -> Dictionary:
	var parsed: Dictionary = {}
	var i: int = 0
	while i < user_args.size():
		var token: String = user_args[i]
		if token == "--file" and i + 1 < user_args.size():
			parsed["file"] = user_args[i + 1]
			i += 2
			continue
		if token == "--json":
			parsed["json"] = true
			i += 1
			continue
		i += 1
	return parsed
