extends SceneTree

## F-223's regression guard: proof that a command typed directly into the console — the synchronous
## path every LOCAL command and every HOST command the host types at its own console takes — actually
## prints its result, not just the echoed `> <line>`. `tools/command_check.gd` only proves
## `CommandService.execute()` in isolation, bypassing `submit()` entirely; `tools/command_net_check.gd`
## only drives the real console UI for the genuinely async client-over-RPC path (phase C). Neither
## ever drove `DebugConsole._on_submitted()` for the synchronous path and read the console's own
## output buffer back — which is the exact gap F-223 fell through: `submit()` used to hand the handle
## back to `_run()` only AFTER `_run_submission()` had already run to completion and emitted
## `command_result`, for anything that resolves without a real `await`. `_pending_handles[handle]`
## was armed one line too late to see its own result, so `_on_command_result` silently discarded it.
##
##   .agent/bin/agent godot --script tools/command_console_check.gd
##
## Reflection calls into DebugConsole's own private surface (`_on_submitted`, `_output`,
## `_pending_handles`) mirror `tools/command_net_check.gd`'s phase C, the only other check that drives
## the real console UI instead of `CommandService.execute()` directly. `console` stays a plain `Node`,
## never a preloaded-and-cast `debug_console.gd` reference: that script (an autoload) is allowed its
## own bare `DebugOverlay` reference (standing rule 1), but `preload()`ing it from a `--script`
## harness pulls it into THIS script's own compile-time dependency chain, where that bare name does
## not resolve yet — confirmed by hitting exactly that compile error while writing this check.

var failures: int = 0
var console: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame  # DebugConsole's builtins register one idle frame deferred — see its _ready().

	console = root.get_node_or_null(^"DebugConsole")
	check(console != null, "DebugConsole autoload exists")
	if console == null:
		finish()
		return

	_check_local_command_prints()
	_check_host_typed_command_prints()
	_check_no_pending_handle_leak()

	print("\nCOMMAND_CONSOLE_CHECK failures=%d" % failures)
	finish()


func _output_text() -> String:
	var label: RichTextLabel = console.get("_output")
	return label.get_parsed_text()


func _pending_handle_count() -> int:
	var pending: Dictionary = console.get("_pending_handles")
	return pending.size()


func _check_local_command_prints() -> void:
	print("\n== a LOCAL command typed into the console prints its result, not just the echo ==")
	console.call("_on_submitted", "help")
	var text: String = _output_text()
	check(text.contains("> help"), "the echoed line is there: %s" % text)
	check(text.contains("give") and text.contains("spawn"),
		"help's actual listing appears too, not just the echo — this is F-223's exact repro: %s" % text)


func _check_host_typed_command_prints() -> void:
	print("\n== a HOST-scope command typed by the host itself also resolves synchronously and prints ==")
	console.call("_on_submitted", "give branch 5")
	var text: String = _output_text()
	check(text.contains("gave 5 x branch"),
		("give's result line appears — this path is HOST scope but never leaves this process "
			+ "(owns_execution() is true for the host), so it is exactly as synchronous as a LOCAL "
			+ "command: %s") % text)


func _check_no_pending_handle_leak() -> void:
	print("\n== every handle the console armed also got erased — the guard did real work, not defeated ==")
	check(_pending_handle_count() == 0,
		"_pending_handles is empty after both commands resolved (%d left over)" % _pending_handle_count())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
