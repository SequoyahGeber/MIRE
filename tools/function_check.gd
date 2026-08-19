extends SceneTree

## Offline proof for task 3.17: content/functions/*.mcmd load and run through CommandService's real
## front door, `function <name>` inherits the D-086 dynamic-scope trick (HOST only when a contained
## line actually needs it), the recursion cap (4) turns self-reference into an error rather than a
## hang, and a content/hooks/*.tres-shaped HookDef actually fires its bound function on a REAL
## DayNight.host_advance() dusk crossing — driving the real clock, not the signal, same discipline
## tools/day_night_check.gd and tools/wave_spawner_check.gd already established (docs/SPECS.md
## 3.17's own instruction).
##
##   .agent/bin/agent godot --script tools/function_check.gd
##
## F-016: command_service.gd and hook_def.gd are scripts new this session; preload both rather than
## reference bare, same reasoning every other check touching a brand-new class_name follows.
const CommandServiceScript = preload("res://autoload/command_service.gd")
const HOOK_DEF := preload("res://systems/rules/hook_def.gd")

const HOST_PEER: int = 1  # NetConfig.HOST_PEER_ID — not preloaded, this file never needs the rest of it
const NON_OP_PEER: int = 4242

var failures: int = 0
var command_service: CommandServiceScript


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var node: Node = root.get_node_or_null(^"CommandService")
	check(node != null, "CommandService autoload exists")
	if node == null:
		finish()
		return
	command_service = node as CommandServiceScript
	check(command_service != null, "CommandService node is the expected script")
	if command_service == null:
		finish()
		return

	await _check_worked_example_loaded()
	await _check_function_runs_end_to_end()
	await _check_dynamic_scope_routes_through_function()
	await _check_recursion_cap()
	await _check_hook_fires_on_real_dusk_crossing()

	print("\nFUNCTION_CHECK failures=%d" % failures)
	finish()


func _ctx(peer_id: int) -> Dictionary:
	return {"peer_id": peer_id, "source": &"console", "position": Vector3.ZERO, "facing": Vector3.FORWARD}


# ── the worked example actually loaded off disk ─────────────────────────────────────────────────────


func _check_worked_example_loaded() -> void:
	print("\n== the worked example loads off disk at boot ==")
	check(command_service.has_function(&"night_siege"),
		"content/functions/night_siege.mcmd is loaded as function 'night_siege'")

	var dump: Dictionary = await command_service.execute("commands --json", _ctx(HOST_PEER))
	var commands: Array = (dump.get("data", {}) as Dictionary).get("commands", [])
	var has_function_verb: bool = false
	for entry_v: Variant in commands:
		var entry: Dictionary = entry_v
		if String(entry.get("name", "")) == "function":
			has_function_verb = true
			check(String(entry.get("scope", "")) == "host",
				"function reports HOST as its max declared scope (D-086)")
	check(has_function_verb, "`function` is registered in the command catalog")


# ── running a function end to end through the real front door ──────────────────────────────────────


func _check_function_runs_end_to_end() -> void:
	print("\n== `function <name>` runs every line through the real front door ==")
	command_service.register_function(
		&"test_give_two", PackedStringArray(["give branch 1", "give branch 1"]))
	var result: Dictionary = await command_service.execute("function test_give_two", _ctx(HOST_PEER))
	check(bool(result.get("ok", false)), "function test_give_two succeeds: %s" % result.get("message"))
	check(int((result.get("data", {}) as Dictionary).get("executed", 0)) == 2, "both lines executed")

	command_service.register_function(&"test_bad_line", PackedStringArray(["give nosuchitem_xyz"]))
	var failed: Dictionary = await command_service.execute("function test_bad_line", _ctx(HOST_PEER))
	check(not bool(failed.get("ok", true)), "a failing line fails the whole function")
	check(String(failed.get("message", "")).contains("no such item"),
		"the failure names the real underlying error: %s" % failed.get("message"))

	var unknown: Dictionary = await command_service.execute(
		"function nosuchfunction_xyz", _ctx(HOST_PEER))
	check(not bool(unknown.get("ok", true)), "an unknown function name is refused")


# ── D-086 dynamic scope: HOST only when a contained line actually needs it ─────────────────────────


func _check_dynamic_scope_routes_through_function() -> void:
	print("\n== effective scope is the MAX of a function's lines (COMMANDS.md §5.1) ==")
	command_service.register_function(&"test_local_only", PackedStringArray(["items"]))
	command_service.register_function(
		&"test_needs_host", PackedStringArray(["items", "give branch 1"]))

	var non_op_ctx: Dictionary = _ctx(NON_OP_PEER)
	var local_result: Dictionary = await command_service.execute("function test_local_only", non_op_ctx)
	check(bool(local_result.get("ok", false)),
		"a function with only LOCAL lines runs for a non-op: %s" % local_result.get("message"))

	var host_result: Dictionary = await command_service.execute("function test_needs_host", non_op_ctx)
	check(not bool(host_result.get("ok", true)),
		"a function with any HOST line is refused for a non-op")
	check(String(host_result.get("message", "")).begins_with("not op"),
		"refused with the uniform not-op wording: %s" % host_result.get("message"))

	# F-230: a DYNAMIC-scope command (D-086's `time`, `rule`, `function`, and the entity verbs) reports
	# its DECLARED maximum (host) from `scope_of()` — correct for the `commands` listing, wrong for
	# judging one concrete line. `time query` is a read; wrapped in a function it must stay LOCAL, not
	# be forced to HOST just because `time set ...` (the same command's other form) can mutate.
	command_service.register_function(&"test_dynamic_local_only", PackedStringArray(["time query"]))
	var dynamic_local_result: Dictionary = await command_service.execute(
		"function test_dynamic_local_only", non_op_ctx)
	check(bool(dynamic_local_result.get("ok", false)),
		"a function wrapping a LOCAL invocation of a dynamic-scope command runs for a non-op: %s"
			% dynamic_local_result.get("message"))

	command_service.register_function(&"test_dynamic_needs_host", PackedStringArray(["time set 0.5"]))
	var dynamic_host_result: Dictionary = await command_service.execute(
		"function test_dynamic_needs_host", non_op_ctx)
	check(not bool(dynamic_host_result.get("ok", true)),
		"a function wrapping a HOST invocation of the same dynamic-scope command still requires op")


# ── recursion cap: an error, not a hang ─────────────────────────────────────────────────────────────


func _check_recursion_cap() -> void:
	print("\n== recursion cap (4) turns self-reference into an error ==")
	command_service.register_function(&"test_self_loop", PackedStringArray(["function test_self_loop"]))
	var result: Dictionary = await command_service.execute("function test_self_loop", _ctx(HOST_PEER))
	check(not bool(result.get("ok", true)), "a self-recursive function is refused, not hung")
	check(String(result.get("message", "")).contains("recursion cap"),
		"the refusal names the recursion cap: %s" % result.get("message"))

	command_service.register_function(&"test_chain_d", PackedStringArray(["items"]))
	command_service.register_function(&"test_chain_c", PackedStringArray(["function test_chain_d"]))
	command_service.register_function(&"test_chain_b", PackedStringArray(["function test_chain_c"]))
	command_service.register_function(&"test_chain_a", PackedStringArray(["function test_chain_b"]))
	var chained: Dictionary = await command_service.execute("function test_chain_a", _ctx(HOST_PEER))
	check(bool(chained.get("ok", false)),
		"a 4-deep chain under the cap still succeeds: %s" % chained.get("message"))


# ── a hook actually firing on a real dusk crossing (the 2.12 pattern) ──────────────────────────────


func _check_hook_fires_on_real_dusk_crossing() -> void:
	print("\n== a HookDef fires its function on a real DayNight.host_advance() dusk crossing ==")
	var day_night: Node = root.get_node_or_null(^"DayNight")
	check(day_night != null, "DayNight autoload exists")
	if day_night == null:
		return

	# `op 4242` is the observable: nothing else in the real game touches peer 4242's op status, so a
	# flip from false to true can only mean the hook's function actually ran — unlike a themed wave
	# (night_siege's own real content), which the real WaveSpawner ALSO starts on every dusk
	# crossing regardless of this hook, making enemy count an ambiguous signal here.
	check(not command_service.is_op(NON_OP_PEER), "setup: peer %d starts un-opped" % NON_OP_PEER)
	command_service.register_function(&"test_hook_fn", PackedStringArray(["op %d" % NON_OP_PEER]))

	var hook: Resource = HOOK_DEF.new()
	hook.set("id", &"test_dusk_hook")
	hook.set("event", &"night_started")
	hook.set("function", &"test_hook_fn")
	hook.set("host_only", true)
	hook.set("enabled", true)
	command_service.wire_hook(hook)
	check(command_service.has_wired_hook(&"test_dusk_hook"), "wire_hook() records the binding")

	day_night.set(&"day_length_seconds", 1.0)
	day_night.set(&"time_of_day", 0.0)
	day_night.set(&"night_started_at", 0.75)
	day_night.call(&"host_advance", 0.8)  # 0.0 -> 0.8, crossing 0.75 in one real step

	await process_frame
	await process_frame

	check(command_service.is_op(NON_OP_PEER),
		"the hook's function actually ran through the real front door")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
