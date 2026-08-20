extends SceneTree

## F-280 — THE PUBLIC `run_started` HOOK LIFECYCLE CHECK. F-154 gave `CommandService._HOOK_EVENTS`'s
## `run_started` row a real signal and latched it once per PROCESS, saying in as many words that a
## future play-again flow would have to revisit that guard. F-243 shipped play-again and did not, so
## an enabled user-authored `run_started` HookDef ran at boot and then silently skipped every later
## run in the same lobby — the run the player is actually in.
##
## This drives the PUBLIC path end to end on the shipped map, not the signal in isolate: a synthetic
## HookDef is wired through `CommandService.wire_hook()` (the same front door `_wire_hooks()` uses
## for `content/hooks/*.tres`), the run is ended by real lethal damage, and the assertion is that the
## bound COMMAND FUNCTION actually ran for the restarted run. `tools/hook_events_check.gd` proves the
## binding resolves; this proves it keeps firing. Four separate claims, since the finding is really
## about which of them F-243 broke:
##   1. it fires at boot                          (F-154's original, unchanged)
##   2. it does NOT fire on `host_advance_cycle()` — Cycle 2 is not a new run
##   3. it does NOT fire on a REFUSED restart     — a run still in progress never began again
##   4. it fires again on every real restart, and the hook function runs with it — F-280 itself
## Plus ordering (D-168): the state the listener reads AT EMIT TIME must be the NEW run's, since a
## hook body is arbitrary command script that has to act on the run it is named after.
##
## Solo/offline — the path `_owns_cycle()` treats as host, same as `tools/run_restart_check.gd`. The
## client half (a connected peer must NEVER fire its own `run_started`; its `_owns_cycle()` is false
## at both emit sites) needs two processes and lives in `tools/run_restart_net_check.gd`.
##
##   .agent/bin/agent godot --script tools/run_started_hook_check.gd

const CommandServiceScript = preload("res://autoload/command_service.gd")
const HOOK_DEF := preload("res://systems/rules/hook_def.gd")

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
## D-107: a real save write must never land in a developer's actual user://salvage.json.
const TEST_SAVE_PATH: String = "user://run_started_hook_check_salvage.json"
const HOST_PEER: int = 1
## Un-opped peer ids the hook's bound function ops. Nothing else in the process touches them, so
## `is_op()` flipping is unambiguous evidence that THIS hook body ran.
const SENTINEL_PEER: int = 4280
const HOOK_ID: StringName = &"f280_run_started_hook"
const HOOK_FN: StringName = &"f280_run_started_fn"
const TEST_ITEM_ID: StringName = &"iron_ingot"

var failures: int = 0
var command_service: CommandServiceScript
var cycle_service: Node
var defeat_service: Node
var inventory: Node
var level: Node
## One entry per `run_started`, each a snapshot of the world AS THE LISTENER SAW IT. The count is
## the finding; the snapshots are D-168's ordering half.
var emits: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await _phase_boot()
	if level == null:
		_finish()
		return
	await _phase_wire_hook()
	await _phase_not_a_new_run()
	await _phase_first_restart()
	await _phase_second_restart()
	_finish()


# ── 1 · boot ─────────────────────────────────────────────────────────────────────────────────────


func _phase_boot() -> void:
	print("\n== RUN_STARTED 1 · boot fires the first run's run_started ==")
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	check(packed != null, "the shipped map loads")
	if packed == null:
		return
	level = packed.instantiate()
	root.add_child(level)
	current_scene = level
	for _index: int in 30:
		await process_frame
		await physics_frame

	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	cycle_service = root.get_node_or_null(^"CycleService")
	defeat_service = root.get_node_or_null(^"DefeatService")
	inventory = root.get_node_or_null(^"InventoryService")
	check(command_service != null and cycle_service != null and defeat_service != null \
		and inventory != null, "CommandService, CycleService, DefeatService and InventoryService are up")
	if cycle_service == null:
		return

	var salvage: Node = root.get_node_or_null(^"SalvageService")
	if salvage != null:
		salvage.set(&"save_path", TEST_SAVE_PATH)

	check(bool(cycle_service.get(&"_run_started_emitted")),
		"the first run's run_started already fired at boot (host/solo _ready())")


# ── 2 · wire a real HookDef, the way content/hooks/*.tres are wired ──────────────────────────────


func _phase_wire_hook() -> void:
	print("\n== RUN_STARTED 2 · a user-authored HookDef binds to the public event ==")
	cycle_service.connect(&"run_started", _on_run_started)

	check(not command_service.is_op(SENTINEL_PEER),
		"setup: peer %d starts un-opped" % SENTINEL_PEER)
	command_service.register_function(HOOK_FN, PackedStringArray(["op %d" % SENTINEL_PEER]))
	var hook: Resource = HOOK_DEF.new()
	hook.set("id", HOOK_ID)
	hook.set("event", &"run_started")
	hook.set("function", HOOK_FN)
	hook.set("host_only", true)
	hook.set("enabled", true)
	command_service.wire_hook(hook)
	check(command_service.has_wired_hook(HOOK_ID),
		"wire_hook() binds run_started with no 'unknown event' error")
	# Wired AFTER boot, exactly like a hook a player enables mid-session — so nothing has fired it
	# yet. This is also the only reason the sentinel is trustworthy evidence below.
	check(not command_service.is_op(SENTINEL_PEER), "the hook has not run yet")
	check(emits.is_empty(), "no run_started observed yet by this check's own listener")


# ── 3 · the two things that are NOT a new run ────────────────────────────────────────────────────


func _phase_not_a_new_run() -> void:
	print("\n== RUN_STARTED 3 · a Cycle bump and a refused restart are not run starts ==")
	check(int(cycle_service.call("host_advance_cycle")) == 2, "the Cycle advances to 2")
	await physics_frame
	await process_frame
	check(emits.is_empty(), "host_advance_cycle() did not fire run_started — Cycle 2 is the SAME run")
	check(not command_service.is_op(SENTINEL_PEER), "and the bound hook function did not run")

	# The run is still in progress, so `host_restart_run()` refuses (`_run_has_ended()`). A refusal
	# must not fire the event either — the guard clear lives past that early return, not before it.
	check(not bool(defeat_service.get(&"defeated")), "setup: the run is still in progress")
	check(int(cycle_service.call("host_restart_run")) == 2, "host_restart_run() refuses mid-run")
	await physics_frame
	await process_frame
	check(emits.is_empty(), "a refused restart did not fire run_started")


# ── 4 · a real restart fires it again, and the hook runs ─────────────────────────────────────────


func _phase_first_restart() -> void:
	print("\n== RUN_STARTED 4 · F-280: the second run fires its own run_started ==")
	# Seeded so the emit-time snapshot can prove the listener sees the NEW run, not the ended one.
	await _cmd("give %s 5" % TEST_ITEM_ID, true)
	check(int(inventory.call("host_count", HOST_PEER, TEST_ITEM_ID)) >= 5,
		"setup: the ending run holds inventory")

	await _end_the_run()
	check(int(cycle_service.call("host_restart_run")) == 1, "host_restart_run() starts Cycle 1")
	for _index: int in 10:
		await process_frame
		await physics_frame

	check(emits.size() == 1,
		"run_started fired exactly once for the restarted run (%d)" % emits.size())
	if emits.is_empty():
		return
	# D-168's ordering: the hook body is arbitrary command script, so everything it can read has to
	# already be the new run's. Both halves of the restart are checked — this file's own reset
	# (`_current_cycle`) and a `run_restarted` subscriber's (InventoryService).
	var snapshot: Dictionary = emits[0]
	check(int(snapshot["cycle"]) == 1,
		"the listener read Cycle 1 at emit time — the event follows the reset (%d)" % int(snapshot["cycle"]))
	check(int(snapshot["items"]) == 0,
		"and every run_restarted subscriber had already reset (inventory %d)" % int(snapshot["items"]))
	check(not bool(snapshot["defeated"]), "and the ended run's defeat was already cleared")

	var hook_ran: bool = await _until(
		func() -> bool: return command_service.is_op(SENTINEL_PEER), 5.0)
	check(hook_ran,
		"THE FINDING: the bound HookDef function actually ran for the restarted run")

	# The guard re-latches, so the event stays once per RUN — the half F-154 was right about.
	check(bool(cycle_service.get(&"_run_started_emitted")),
		"the run-scoped guard re-latched for the new run")
	cycle_service.call("_emit_run_started")
	await process_frame
	check(emits.size() == 1, "a second _emit_run_started() inside the same run is still a no-op")


# ── 5 · and again, so it is per-run and not merely two-shot ──────────────────────────────────────


func _phase_second_restart() -> void:
	print("\n== RUN_STARTED 5 · a third run fires it too ==")
	await _cmd("deop %d" % SENTINEL_PEER, true)
	check(not command_service.is_op(SENTINEL_PEER),
		"setup: the sentinel is un-opped again, so the next op can only come from the hook")

	await _end_the_run()
	check(int(cycle_service.call("host_restart_run")) == 1, "the second restart starts Cycle 1")
	for _index: int in 10:
		await process_frame
		await physics_frame

	check(emits.size() == 2, "run_started fired for the third run as well (%d total)" % emits.size())
	var hook_ran: bool = await _until(
		func() -> bool: return command_service.is_op(SENTINEL_PEER), 5.0)
	check(hook_ran, "and the hook function ran again — per-run, not a two-shot latch")


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────


func _on_run_started() -> void:
	emits.append({
		"cycle": int(cycle_service.call("current_cycle")),
		"items": int(inventory.call("host_count", HOST_PEER, TEST_ITEM_ID)),
		"defeated": bool(defeat_service.get(&"defeated")),
	})


## A real defeat, through real lethal damage — the same path the "Start Next Run" button appears
## behind. Not `defeat_service.set(&"defeated", true)`: this check is about a PUBLIC lifecycle
## contract, so the run has to end the way a run ends.
func _end_the_run() -> void:
	await _cmd("damage @s 1000000", true)
	await physics_frame
	var ended: bool = await _until(
		func() -> bool: return bool(defeat_service.get(&"defeated")), 15.0)
	check(ended, "the run actually ended in defeat")


func _cmd(line: String, expect_ok: bool) -> Dictionary:
	var result: Dictionary = await command_service.execute(
		line, command_service.build_local_ctx(&"runner"))
	if expect_ok and not bool(result.get("ok", false)):
		check(false, "command `%s` failed: %s" % [line, result.get("message", "")])
	return result


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.1).timeout
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	print("\nRUN_STARTED_HOOK_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
