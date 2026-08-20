extends SceneTree

## Real two-process ENet proof for F-254: `CycleModifierService._announce()` is reachable only through
## `host_draw_modifier()`, which returns early on `if not _owns_modifiers()`, so its
## `EVENT_BUS.emit_cycle_modifier_drawn()` only ever ran host-side — a real connected client's own
## `EventBus.subscribe_cycle_modifier_drawn()` listeners never fired at all, no matter how many
## Modifiers the host drew. The exact shape F-250 fixed for `CycleService`, one file over.
##
## `tools/cycle_modifier_check.gd` and `tools/cycle_modifier_effects_check.gd` both PASS with the bug
## present: they run host/solo, where `_announce()` emits directly. Only a second process proves the
## client path. The client here subscribes ONLY through `EventBus.subscribe_cycle_modifier_drawn()`
## and never calls `active_modifier_ids()` — that getter already had a correct `WorldDeltaLog`
## fallback before this fix and would mask the bug completely (same trap `cycle_advanced_net_check.gd`
## documents for `current_cycle()`).
##
##   .agent/bin/agent godot --script tools/cycle_modifier_net_check.gd
##
## Same driver/probe shape as tools/cycle_advanced_net_check.gd — driver plays the HOST in-process, a
## spawned child process is the CLIENT, talking through a user:// JSON file.
##
## Phase 2 (restart) is not decoration. `WorldDeltaLog` is latest-value-wins and never deletes, and a
## restart re-uses slot 0 with an UNCHANGED run seed (`CycleService`'s own scope cut, F-258), so each
## restarted run redraws the SAME modifier on the same Cycle — a byte-identical `(def_id, cycle)`
## pair to one the client already announced. That is what proves the client's `_announced_draws`
## dedupe is genuinely cleared on `run_restarted` rather than silently swallowing every post-restart
## draw as a duplicate of the last one, which no single-run check can distinguish.
##
## Note that a restart alone draws NOTHING: it lands on Cycle 1, and no shipped `CycleModifierDef`
## has a positive `weight_at(1)` — the deck is deliberately empty on the opening Cycle, which is why
## the boot-time `cycle_advanced(1)` logs "no eligible Cycle Modifier to draw" too. The phase has to
## advance the Cycle after each restart to get a real draw out of it.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const PORT: int = 47447
const RESULT_PATH: String = "user://cycle_modifier_net_client.json"
const TIMEOUT_SEC: float = 15.0
const DRAWS: int = 3  # host draws for Cycles 2..DRAWS+1 after the client is connected

var failures: int = 0
var transport: Node
var modifier_service: Node
var cycle_service: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	modifier_service = root.get_node_or_null(^"CycleModifierService")
	cycle_service = root.get_node_or_null(^"CycleService")
	if transport == null or modifier_service == null or cycle_service == null:
		fail("NetTransport, CycleModifierService and CycleService autoloads must all exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "cycle-modifier-probe":
		_run_client()
	else:
		_run_driver()


# ── driver (HOST) ────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== F-254: EventBus.cycle_modifier_drawn fires on a real connected client ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	await process_frame
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false)), TIMEOUT_SEC
	)
	check(connected, "client connects")
	if not connected:
		finish()
		return

	var expected: Array[String] = []
	await _phase_draws(expected)
	await _phase_restarts(expected)

	var client_result: Dictionary = _read_result()
	check(int(client_result.get("failures", -1)) == 0, "client-side self checks report 0 failures")

	transport.call("leave")
	print("CYCLE_MODIFIER_NET_CHECK failures=%d" % failures)
	finish()


## The core F-254 assertion: real host draws, and the client's own bus must see every one of them.
func _phase_draws(expected: Array[String]) -> void:
	print("\n== MODNET 1 · host draws for real; the client's own listener must fire ==")
	for index: int in DRAWS:
		var cycle: int = 2 + index
		var drawn: StringName = StringName(modifier_service.call("host_draw_modifier", cycle))
		if drawn == &"":
			fail("host_draw_modifier(%d) drew nothing — the deck ran dry, so this check proves "
				% cycle + "nothing about the client path")
			continue
		expected.append("%s|%d" % [drawn, cycle])
	check(expected.size() == DRAWS, "host really drew %d Modifiers post-connect" % DRAWS)

	var caught_up: bool = await _until(
		func() -> bool: return _client_draws() == expected, TIMEOUT_SEC
	)
	check(caught_up,
		("client's own EventBus.subscribe_cycle_modifier_drawn() listener actually fired for every "
		+ "real host draw, with the right (id, cycle) pairs and in order — not silent (F-254). "
		+ "expected %s, got %s") % [str(expected), str(_client_draws())])

	# Exactly-once: a draw writes three WorldDeltaLog records, so a naive per-key client handler
	# would emit up to three times for one draw.
	check(_client_draws().size() == expected.size(),
		"client emitted exactly once per draw (%d), not once per replicated record — got %d"
		% [expected.size(), _client_draws().size()])


## Two restarts, because one cannot tell a working dedupe-reset from a broken one: the run seed is
## unchanged across a restart, so both restarts redraw the SAME modifier id on the same Cycle 1.
func _phase_restarts(expected: Array[String]) -> void:
	print("\n== MODNET 2 · a restart re-uses slot 0; the client must not swallow the redraw ==")
	var defeat_service: Node = root.get_node_or_null(^"DefeatService")
	if defeat_service == null:
		fail("DefeatService autoload must exist to end a run")
		return

	for attempt: int in 2:
		var label: String = "restart %d" % (attempt + 1)
		defeat_service.set(&"defeated", true)
		await process_frame
		check(bool(defeat_service.get(&"defeated")), "%s: the run is ended" % label)
		check(int(cycle_service.call("host_restart_run")) == 1, "%s: back to Cycle 1" % label)
		await process_frame
		check((modifier_service.call("active_modifier_ids") as Array).is_empty(),
			"%s: the modifier stack reset with the run" % label)

		# Cycle 1 draws nothing by design (see the header) — the draw comes from advancing past it,
		# and with the run seed unchanged it is the same modifier on the same Cycle as phase 1's.
		check(int(cycle_service.call("host_advance_cycle")) == 2, "%s: Cycle advances to 2" % label)
		await process_frame

		var stack: Array = modifier_service.call("active_modifier_ids")
		if stack.size() != 1:
			fail("%s: host's stack should hold exactly the fresh Cycle-2 draw, holds %d"
				% [label, stack.size()])
			return
		var stamp: String = "%s|2" % StringName(stack[0])
		check(expected.has(stamp),
			("%s: the redraw is an EXACT repeat of a pair the client already announced (%s) — "
			+ "that repeat is what the dedupe-reset has to survive") % [label, stamp])
		expected.append(stamp)

		var seen: bool = await _until(
			func() -> bool: return _client_draws() == expected, TIMEOUT_SEC
		)
		check(seen,
			("%s: client's listener fired for the post-restart slot-0 draw. This is the identical "
			+ "(id, cycle) pair as the previous run's — a dedupe that is not cleared on "
			+ "run_restarted swallows it. expected %s, got %s")
			% [label, str(expected), str(_client_draws())])
		if not seen:
			return


func _client_draws() -> Array[String]:
	var raw: Array = _read_result().get("draws", []) as Array
	var result: Array[String] = []
	for entry: Variant in raw:
		result.append(String(entry))
	return result


# ── probe (CLIENT) ───────────────────────────────────────────────────────────────────────────────


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


var _draws: Array[String] = []


func _client_drive() -> void:
	var joined: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	var client_failures: int = 0
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	if bool(transport.call("is_host")):
		client_failures += 1  # the join target was LOCAL; this process must never end up the host

	# Subscribe through the real EventBus static dispatcher only. Deliberately never touching
	# CycleModifierService.active_modifier_ids() — that getter's own WorldDeltaLog fallback was
	# already correct before F-254 and would make this check pass with the bug still in place.
	EVENT_BUS.subscribe_cycle_modifier_drawn(_on_cycle_modifier_drawn)

	while true:
		_write_result({
			"connected": true,
			"draws": _draws,
			"failures": client_failures,
		})
		await create_timer(0.1).timeout


func _on_cycle_modifier_drawn(modifier_id: StringName, cycle: int) -> void:
	_draws.append("%s|%d" % [modifier_id, cycle])


# ── harness ──────────────────────────────────────────────────────────────────────────────────────


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/cycle_modifier_net_check.gd",
		"--", "cycle-modifier-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _write_result(result: Dictionary) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
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
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	quit(0 if failures == 0 else 1)
