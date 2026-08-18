extends SceneTree

## Offline proof for task 3.13's command core — everything that does not need a second real peer:
## parse/validate/usage errors, scope routing, op permissions (including the host-only op/deop
## restriction), and the `commands --json` introspection dump docs/COMMANDS.md §2.5 promises.
##
##   .agent/bin/agent godot --script tools/command_check.gd
##
## Boots the real project offline (host-of-one), so every migrated command (give/loadout/items,
## spawn/killall/enemies, the console builtins) runs through its REAL registration, against the
## REAL Registry/EnemyWorld content — not a stand-in. `tools/command_net_check.gd` is the other half:
## a real client→host RPC round trip, non-op refusal over the wire, and the console-paused wrinkle.
##
## Preloaded rather than referenced bare: command_service.gd is a script new to this session, so a
## fresh headless clone has not scanned it into the global class cache yet (F-016). Preloading it and
## casting the live autoload node to that type gives a normal, statically-typed coroutine call —
## `await` on it is unremarkable GDScript, unlike awaiting through a dynamic `Object.call()` dispatch
## (see command_service.gd's own header for why nothing else in this codebase relies on that).
const CommandServiceScript = preload("res://autoload/command_service.gd")

const NON_OP_PEER: int = 999
const HOST_PEER: int = 1  # NetConfig.HOST_PEER_ID — not preloaded, this file never needs the rest of it

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

	await _check_unknown_and_help()
	await _check_commands_introspection()
	await _check_parse_and_usage_errors()
	await _check_give_end_to_end()
	await _check_spawn_end_to_end()
	await _check_scope_routing()
	await _check_op_refusal_and_grant()
	await _check_op_deop_is_host_only()

	print("\nCOMMAND_CHECK failures=%d" % failures)
	finish()


func _ctx(peer_id: int, source: StringName = &"console") -> Dictionary:
	return {"peer_id": peer_id, "source": source, "position": Vector3.ZERO, "facing": Vector3.FORWARD}


# ── unknown command / help ──────────────────────────────────────────────────────────────────────────


func _check_unknown_and_help() -> void:
	print("\n== unknown command, and help lists what is registered ==")
	var result: Dictionary = await command_service.execute("nosuchcommand", _ctx(HOST_PEER))
	check(not bool(result.get("ok", true)), "an unregistered command is refused")
	check(String(result.get("message", "")).contains("unknown command"),
		"refusal names itself as unknown: %s" % result.get("message"))

	var help_result: Dictionary = await command_service.execute("help", _ctx(HOST_PEER))
	check(bool(help_result.get("ok", false)), "help succeeds")
	var help_text: String = String(help_result.get("message", ""))
	check(help_text.contains("give") and help_text.contains("spawn"),
		"help lists migrated commands from other autoloads: %s" % help_text)


# ── commands --json (COMMANDS.md §2.5) ──────────────────────────────────────────────────────────────


func _check_commands_introspection() -> void:
	print("\n== commands --json is the 3.16 coverage checklist's data source ==")
	var plain: Dictionary = await command_service.execute("commands", _ctx(HOST_PEER))
	check(bool(plain.get("ok", false)), "commands succeeds")
	var plain_dump: Array = (plain.get("data", {}) as Dictionary).get("commands", [])
	check(not plain_dump.is_empty(), "commands returns at least one entry")

	var json_result: Dictionary = await command_service.execute("commands --json", _ctx(HOST_PEER))
	check(bool(json_result.get("ok", false)), "commands --json succeeds")
	var dump: Array = (json_result.get("data", {}) as Dictionary).get("commands", [])
	var by_name: Dictionary[String, Dictionary] = {}
	for entry_v: Variant in dump:
		var entry: Dictionary = entry_v
		by_name[String(entry.get("name", ""))] = entry

	for expected: String in ["give", "loadout", "items", "spawn", "killall", "enemies", "help",
			"clear", "channels", "log", "overlay", "quit", "commands", "op", "deop"]:
		check(by_name.has(expected), "commands --json lists '%s'" % expected)

	check(String(by_name.get("give", {}).get("scope", "")) == "host", "give is HOST scope")
	check(String(by_name.get("items", {}).get("scope", "")) == "local", "items is LOCAL scope")
	check(String(by_name.get("op", {}).get("scope", "")) == "host", "op is HOST scope")

	var parsed: Variant = JSON.parse_string(String(json_result.get("message", "")))
	check(parsed is Array and (parsed as Array).size() == dump.size(),
		"the printed message is the same dump as valid JSON")


# ── parse/validate/usage errors ─────────────────────────────────────────────────────────────────────


func _check_parse_and_usage_errors() -> void:
	print("\n== a parse failure returns usage automatically, never reaching the handler ==")
	var missing_item: Dictionary = await command_service.execute("give", _ctx(HOST_PEER))
	check(not bool(missing_item.get("ok", true)), "give with no item_id fails to parse")
	check(String(missing_item.get("message", "")).begins_with("usage: give"),
		"the usage message names the command: %s" % missing_item.get("message"))

	var bad_item: Dictionary = await command_service.execute(
		"give nosuchitem_xyz", _ctx(HOST_PEER))
	check(not bool(bad_item.get("ok", true)), "give with an unknown item_id is refused")
	check(String(bad_item.get("message", "")) == "no such item 'nosuchitem_xyz' — try 'items'",
		"item_id parse failure keeps give's exact wording: %s" % bad_item.get("message"))

	var bad_enemy: Dictionary = await command_service.execute(
		"spawn nosuchenemy_xyz", _ctx(HOST_PEER))
	check(not bool(bad_enemy.get("ok", true)), "spawn with an unknown enemy_id is refused")
	check(String(bad_enemy.get("message", "")).contains("no such enemy"),
		"enemy_id parse failure names itself: %s" % bad_enemy.get("message"))

	var bad_int: Dictionary = await command_service.execute("give branch notanumber", _ctx(HOST_PEER))
	check(not bool(bad_int.get("ok", true)), "give with a non-numeric count is refused")


# ── give end to end (exact strings preserved per this task's own spec) ─────────────────────────────


func _check_give_end_to_end() -> void:
	print("\n== give, exact output strings ==")
	var normal: Dictionary = await command_service.execute("give branch 5", _ctx(HOST_PEER))
	check(bool(normal.get("ok", false)), "give branch 5 succeeds")
	check(String(normal.get("message", "")) == "gave 5 x branch",
		"give's success line is exactly 'gave <n> x <item>': %s" % normal.get("message"))

	var default_count: Dictionary = await command_service.execute("give branch", _ctx(HOST_PEER))
	check(String(default_count.get("message", "")) == "gave 1 x branch",
		"give with no count defaults to 1: %s" % default_count.get("message"))

	var clamped: Dictionary = await command_service.execute("give branch 999999", _ctx(HOST_PEER))
	check(String(clamped.get("message", "")) == "gave 999 x branch",
		"give's count clamps to the spec's max 999: %s" % clamped.get("message"))


# ── spawn end to end (ctx.position/facing generalize the old is_multiplayer_authority() search) ────


func _check_spawn_end_to_end() -> void:
	print("\n== spawn, killall, enemies ==")
	var enemy_world: Node = root.get_node_or_null(^"EnemyWorld")
	check(enemy_world != null, "EnemyWorld autoload exists")
	if enemy_world == null:
		return

	var before: int = int(enemy_world.call("live_count"))
	var spawned: Dictionary = await command_service.execute("spawn crawler 2", _ctx(HOST_PEER))
	check(bool(spawned.get("ok", false)), "spawn crawler 2 succeeds")
	check(String(spawned.get("message", "")) == "spawned 2 crawler",
		"spawn's success line: %s" % spawned.get("message"))
	check(int(enemy_world.call("live_count")) == before + 2, "two more crawlers are alive")

	var killed: Dictionary = await command_service.execute("killall", _ctx(HOST_PEER))
	check(bool(killed.get("ok", false)), "killall succeeds")
	# host_despawn_all() queue_free()s each enemy — deferred, so live_count() only reflects it a
	# couple of frames later.
	await process_frame
	await process_frame
	check(int(enemy_world.call("live_count")) == 0, "killall actually despawned everything")

	var enemies_result: Dictionary = await command_service.execute("enemies", _ctx(HOST_PEER))
	check(bool(enemies_result.get("ok", false)), "enemies (a read) succeeds")
	check(String(enemies_result.get("message", "")).begins_with("0 alive"),
		"enemies reports the field empty after killall: %s" % enemies_result.get("message"))


# ── scope routing: LOCAL never touches the op set, HOST always does ────────────────────────────────


func _check_scope_routing() -> void:
	print("\n== scope routing: LOCAL bypasses the op check entirely ==")
	var non_op_ctx: Dictionary = _ctx(NON_OP_PEER)
	var items_result: Dictionary = await command_service.execute("items", non_op_ctx)
	check(bool(items_result.get("ok", false)),
		"a non-op peer can still run a LOCAL command: %s" % items_result.get("message"))

	var enemies_result: Dictionary = await command_service.execute("enemies", non_op_ctx)
	check(bool(enemies_result.get("ok", false)), "enemies (LOCAL) also bypasses the op check")


# ── op refusal, and op/deop actually changing it ────────────────────────────────────────────────────


func _check_op_refusal_and_grant() -> void:
	print("\n== a non-op peer is refused a HOST command with the uniform refusal ==")
	var non_op_ctx: Dictionary = _ctx(NON_OP_PEER)
	var refused: Dictionary = await command_service.execute("give branch 1", non_op_ctx)
	check(not bool(refused.get("ok", true)), "peer %d is not op yet — give is refused" % NON_OP_PEER)
	check(String(refused.get("message", "")).begins_with("not op"),
		"refusal uses the uniform not-op wording: %s" % refused.get("message"))

	var op_result: Dictionary = await command_service.execute(
		"op %d" % NON_OP_PEER, _ctx(HOST_PEER))
	check(bool(op_result.get("ok", false)), "the host can op a peer: %s" % op_result.get("message"))

	# `spawn`, not `give`: peer 999 is a made-up id with no real InventoryService store (nobody ever
	# joined as it), so `give` would fail at the inventory layer regardless of op status. `spawn`
	# needs nothing peer-specific, so it isolates the one thing this is actually testing — the op
	# check itself flipping from refused to allowed.
	var now_allowed: Dictionary = await command_service.execute("spawn crawler 1", non_op_ctx)
	check(bool(now_allowed.get("ok", false)),
		"the same peer's spawn now succeeds once opped: %s" % now_allowed.get("message"))
	await command_service.execute("killall", _ctx(HOST_PEER))

	var deop_result: Dictionary = await command_service.execute(
		"deop %d" % NON_OP_PEER, _ctx(HOST_PEER))
	check(bool(deop_result.get("ok", false)), "the host can deop a peer")

	var refused_again: Dictionary = await command_service.execute("spawn crawler 1", non_op_ctx)
	check(not bool(refused_again.get("ok", true)), "deop actually revokes it")


func _check_op_deop_is_host_only() -> void:
	print("\n== op cannot mint another op — restricted to the host peer itself ==")
	var op_result: Dictionary = await command_service.execute(
		"op %d" % NON_OP_PEER, _ctx(HOST_PEER))
	check(bool(op_result.get("ok", false)), "setup: host ops peer %d" % NON_OP_PEER)

	var non_op_ctx: Dictionary = _ctx(NON_OP_PEER)
	var second_op_attempt: Dictionary = await command_service.execute("op 42", non_op_ctx)
	check(not bool(second_op_attempt.get("ok", true)),
		"an opped, non-host peer still cannot op someone else")
	check(String(second_op_attempt.get("message", "")).contains("only the host itself"),
		"refusal explains why: %s" % second_op_attempt.get("message"))

	await command_service.execute("deop %d" % NON_OP_PEER, _ctx(HOST_PEER))


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
