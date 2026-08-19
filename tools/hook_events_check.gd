extends SceneTree

## Focused proof for F-154: COMMANDS.md §5.2's illustrative hook vocabulary named `run_started` and
## `player_downed` alongside `night_started`/`day_started`/`enemy_died`, but the first two had no
## shipped signal to bind to — naming either in a HookDef failed loudly (a MireLog error) at wire
## time instead of silently never firing. Both now have real rows in `CommandService._HOOK_EVENTS`:
## `CycleService.run_started` (fires once per process, the instant Cycle 1 is live) and
## `PlayerHealth.player_downed` (the real ALIVE->DOWNED edge, not the broadcast `downed_flag_changed`
## bool that also fires on revive). This asserts each end to end, the same proof
## tools/function_check.gd already gave `night_started` — wire_hook() connects without an
## "unknown event" error, and firing the real underlying signal actually runs the bound function
## through the real front door — plus the negative case: an event genuinely absent from the table
## still fails loudly, not silently.
##
##   .agent/bin/agent godot --script tools/hook_events_check.gd
##
## F-016: command_service.gd and hook_def.gd are preloaded rather than referenced bare, same
## reasoning every other check touching these classes follows.
const CommandServiceScript = preload("res://autoload/command_service.gd")
const HOOK_DEF := preload("res://systems/rules/hook_def.gd")

const HOST_PEER: int = 1  # NetConfig.HOST_PEER_ID — not preloaded, this file never needs the rest of it
const NON_OP_RUN_STARTED: int = 4243
const NON_OP_PLAYER_DOWNED: int = 4244

var failures: int = 0
var command_service: CommandServiceScript
var cycle_service: Node
var player_health: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	cycle_service = root.get_node_or_null(^"CycleService")
	player_health = root.get_node_or_null(^"PlayerHealth")
	check(command_service != null, "CommandService autoload exists")
	check(cycle_service != null, "CycleService autoload exists")
	check(player_health != null, "PlayerHealth autoload exists")
	if command_service == null or cycle_service == null or player_health == null:
		finish()
		return

	await _check_run_started()
	await _check_player_downed()
	_check_unknown_event_still_fails_loudly()

	print("\nHOOK_EVENTS_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"unknown event .* has no signal binding\""
		% failures)
	finish()


# ── run_started (CycleService) ──────────────────────────────────────────────────────────────────


func _check_run_started() -> void:
	print("\n== run_started: F-154's row resolves to CycleService's real signal ==")
	check(bool(cycle_service.get(&"_run_started_emitted")),
		"CycleService already fired run_started once, at boot (host/solo _ready())")

	# Idempotency: a later Cycle-machine event (host_advance_cycle) must never look like a second run
	# starting — _emit_run_started() is the only emit site and is guarded to fire exactly once.
	var counter: Dictionary = {"n": 0}
	var counter_listener := func() -> void: counter["n"] = int(counter["n"]) + 1
	cycle_service.connect(&"run_started", counter_listener)
	cycle_service.call("_emit_run_started")
	check(int(counter["n"]) == 0, "_emit_run_started() re-called after boot is a no-op")
	cycle_service.disconnect(&"run_started", counter_listener)

	# End-to-end: CommandService._HOOK_EVENTS actually connects to the REAL signal and runs the bound
	# function. run_started has no repeatable real trigger within one process by design (see its own
	# doc comment — a run's lifetime IS the process lifetime here), so this drives the signal
	# directly, exactly what a live second emission would look like to CommandService; the guard
	# above already proved CycleService itself can never produce one.
	check(not command_service.is_op(NON_OP_RUN_STARTED),
		"setup: peer %d starts un-opped" % NON_OP_RUN_STARTED)
	command_service.register_function(
		&"test_run_started_fn", PackedStringArray(["op %d" % NON_OP_RUN_STARTED]))
	var hook: Resource = HOOK_DEF.new()
	hook.set("id", &"test_run_started_hook")
	hook.set("event", &"run_started")
	hook.set("function", &"test_run_started_fn")
	hook.set("host_only", true)
	hook.set("enabled", true)
	command_service.wire_hook(hook)
	check(command_service.has_wired_hook(&"test_run_started_hook"),
		"wire_hook() connects run_started to CycleService's real signal, no 'unknown event' error")

	cycle_service.emit_signal(&"run_started")
	await process_frame
	await process_frame
	check(command_service.is_op(NON_OP_RUN_STARTED),
		"firing the real signal actually runs the bound function through the front door")


# ── player_downed (PlayerHealth) ────────────────────────────────────────────────────────────────


func _check_player_downed() -> void:
	print("\n== player_downed: the real ALIVE->DOWNED edge, distinct from downed_flag_changed ==")
	check(bool(player_health.call("host_is_alive", HOST_PEER)), "setup: host peer starts alive")

	var fire_count: Dictionary = {"n": 0}
	var last_peer: Dictionary = {"id": -1}
	var listener := func(peer_id: int) -> void:
		fire_count["n"] = int(fire_count["n"]) + 1
		last_peer["id"] = peer_id
	player_health.connect(&"player_downed", listener)

	var max_hp: int = int(player_health.get(&"max_hp"))
	check(bool(player_health.call("host_apply_damage", HOST_PEER, max_hp, 0)), "lethal damage lands")
	check(bool(player_health.call("host_is_downed", HOST_PEER)), "peer is now downed")
	check(int(fire_count["n"]) == 1,
		"player_downed fired exactly once on the ALIVE->DOWNED edge (%d)" % int(fire_count["n"]))
	check(int(last_peer["id"]) == HOST_PEER, "player_downed named the right peer")

	# Already-downed is a no-op in DownedState.apply_damage() (state != ALIVE guard), so
	# Transition.WENT_DOWN — and therefore this signal — can only ever fire once per down.
	player_health.call("host_apply_damage", HOST_PEER, 5, 0)
	check(int(fire_count["n"]) == 1, "a further hit while already downed does not re-fire")

	# The actual bug this signal exists to not have: downed_flag_changed fires on revive too
	# (true->false). player_downed must not.
	check(bool(player_health.call("host_revive", HOST_PEER)), "revive succeeds")
	check(bool(player_health.call("host_is_alive", HOST_PEER)), "peer is alive again")
	check(int(fire_count["n"]) == 1, "revive does not fire player_downed (unlike downed_flag_changed)")

	# An edge signal, not a latch: going down again after a revive must fire again.
	check(bool(player_health.call("host_apply_damage", HOST_PEER, max_hp, 0)), "lethal damage again")
	check(int(fire_count["n"]) == 2,
		"a second down, after a revive, fires player_downed again (%d)" % int(fire_count["n"]))

	player_health.disconnect(&"player_downed", listener)
	player_health.call("host_revive", HOST_PEER)

	# End-to-end through CommandService, same proof pattern as run_started above.
	check(not command_service.is_op(NON_OP_PLAYER_DOWNED),
		"setup: peer %d starts un-opped" % NON_OP_PLAYER_DOWNED)
	command_service.register_function(
		&"test_player_downed_fn", PackedStringArray(["op %d" % NON_OP_PLAYER_DOWNED]))
	var hook: Resource = HOOK_DEF.new()
	hook.set("id", &"test_player_downed_hook")
	hook.set("event", &"player_downed")
	hook.set("function", &"test_player_downed_fn")
	hook.set("host_only", true)
	hook.set("enabled", true)
	command_service.wire_hook(hook)
	check(command_service.has_wired_hook(&"test_player_downed_hook"),
		"wire_hook() connects player_downed to PlayerHealth's real signal, no 'unknown event' error")

	player_health.call("host_apply_damage", HOST_PEER, max_hp, 0)
	await process_frame
	await process_frame
	check(command_service.is_op(NON_OP_PLAYER_DOWNED),
		"firing the real signal actually runs the bound function through the front door")

	player_health.call("host_revive", HOST_PEER)


# ── the negative case: still absent means still loud ────────────────────────────────────────────


func _check_unknown_event_still_fails_loudly() -> void:
	print("\n== an event genuinely absent from _HOOK_EVENTS still fails loudly, not silently ==")
	var hook: Resource = HOOK_DEF.new()
	hook.set("id", &"test_unknown_event_hook")
	hook.set("event", &"nosuchevent_xyz")
	hook.set("function", &"test_run_started_fn")
	hook.set("host_only", true)
	hook.set("enabled", true)
	command_service.wire_hook(hook)
	check(not command_service.has_wired_hook(&"test_unknown_event_hook"),
		"an unknown event name is never recorded as wired (MireLog.error fires — expected)")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
