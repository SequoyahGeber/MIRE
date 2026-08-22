extends SceneTree

## Real two-process ENet proof for F-272: the run-restart reseed record actually crosses a socket,
## and it lands on the client BEFORE `CycleService`'s `RUN_KIND` record re-derives `run_restarted`.
##
##   .agent/bin/agent godot --script tools/run_reseed_net_check.gd
##
## `tools/run_reseed_check.gd` phase 3 proves F-258's receive half by calling
## `WorldDeltaLog.net_delta_applied(0, 0, "world", "seed", v)` in-process — byte-for-byte the
## arguments a client's ENet callback passes, and enough to prove the discrimination and
## `_reseed_local()`'s wipe-and-adopt. It is NOT proof that the record crosses a real socket, nor
## that it arrives before the run record. That ordering is load-bearing: `host_restart_run()` writes
## seed then run onto one reliable-ordered channel, and every `run_restarted` subscriber that
## re-derives itself from the seed (MireGrid's `host_reset()`, `Chest.host_reset_for_new_run()`,
## `ProceduralWorld`) reads the WRONG world if the run record overtakes the reseed. ENet's
## reliable-ordered guarantee is an engine property this repo had never asserted for itself.
##
## The client here asserts, at the instant its own `EventBus.run_restarted` fires and not after:
##   (a) `GameState.run_seed` has ALREADY changed away from the seed it joined on,
##   (b) its `WorldDeltaLog` has ALREADY been wiped of the ended run's chunk records,
##   (c) and only then does it report the restart at all.
## Sampling inside the handler is the whole point — reading (a) and (b) from the driver after the
## fact would pass no matter which record arrived first.
##
## Phase 3 keeps the discrimination honest over the wire: an ordinary post-restart delta must be
## applied, not treated as a new world. Same driver/probe shape as
## `tools/cycle_modifier_net_check.gd` — driver plays the HOST in-process, a spawned child process
## is the CLIENT, talking through a user:// JSON file written by atomic rename (F-290).

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const WORLD_DELTA_LOG := preload("res://autoload/world_delta_log.gd")

const PORT: int = 47451
const RESULT_PATH: String = "user://run_reseed_net_client.json"
const TIMEOUT_SEC: float = 15.0

## The ended run's record. Any chunk that is not `WorldDeltaLog.SEED_CHUNK` will do; the value is
## arbitrary and only has to be recognisable on the far side.
const MARK_CHUNK := Vector2i(7, 7)
const MARK_KIND: StringName = &"harvest"
const MARK_KEY: String = "f272_marker"
const MARK_VALUE: int = 4272
const POST_VALUE: int = 91

var failures: int = 0
var transport: Node
var world_delta_log: Node
var game_state: Node
var cycle_service: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	world_delta_log = root.get_node_or_null(^"WorldDeltaLog")
	game_state = root.get_node_or_null(^"GameState")
	cycle_service = root.get_node_or_null(^"CycleService")
	if transport == null or world_delta_log == null or game_state == null or cycle_service == null:
		fail("NetTransport, WorldDeltaLog, GameState and CycleService autoloads must all exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "run-reseed-probe":
		_run_client()
	else:
		_run_driver()


# ── driver (HOST) ────────────────────────────────────────────────────────────────────────────────


func _run_driver() -> void:
	print("\n== F-272: the reseed crosses a real socket, and it arrives before run_restarted ==")
	for stale: String in [RESULT_PATH, RESULT_PATH + ".part"]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))

	game_state.call("ensure_seed")
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

	var old_seed: int = int(game_state.get(&"run_seed"))
	check(int(_read_result().get("boot_seed", 0)) == old_seed,
		"client joined on the host's live seed (%d)" % old_seed)

	await _phase_mark()
	await _phase_restart(old_seed)
	await _phase_ordinary_delta_after_restart()

	var client_result: Dictionary = _read_result()
	check(int(client_result.get("failures", -1)) == 0, "client-side self checks report 0 failures")

	transport.call("leave")
	# The driver tears down a live ENet session at exit, and the shutdown order leaves a handful of
	# resources referenced — the one declared pattern this project already carries for the netcode
	# checks (SPECS standing rule 4, `tools/steam_stats_check.gd` sets the precedent).
	print("RUN_RESEED_NET_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"resources still in use\""
		% failures)
	finish()


## Give the ended run a record on the client worth wiping. Without this the "wiped" assertion below
## is vacuous — an empty log looks wiped whether or not the reseed did anything.
func _phase_mark() -> void:
	print("\n== RESEEDNET 1 · the ended run gets a real record on the client ==")
	world_delta_log.call("host_record", MARK_CHUNK, MARK_KIND, MARK_KEY, MARK_VALUE)
	var mirrored: bool = await _until(
		func() -> bool: return int(_read_result().get("mark", 0)) == MARK_VALUE, TIMEOUT_SEC
	)
	check(mirrored,
		"the ended run's ordinary delta replicated to the client (mark=%s)"
		% str(_read_result().get("mark", null)))


func _phase_restart(old_seed: int) -> void:
	print("\n== RESEEDNET 2 · restart: the client adopts the new seed BEFORE run_restarted ==")
	var defeat_service: Node = root.get_node_or_null(^"DefeatService")
	if defeat_service == null:
		fail("DefeatService autoload must exist to end a run")
		return
	defeat_service.set(&"defeated", true)
	await process_frame
	check(bool(defeat_service.get(&"defeated")), "the run is ended")

	check(int(cycle_service.call("host_restart_run")) == 1, "host restarts the run, back to Cycle 1")
	await process_frame
	var new_seed: int = int(game_state.get(&"run_seed"))
	check(new_seed != old_seed and new_seed != 0,
		"host actually redrew the world seed (%d -> %d)" % [old_seed, new_seed])

	var restarted: bool = await _until(
		func() -> bool: return int(_read_result().get("restarts", 0)) > 0, TIMEOUT_SEC
	)
	check(restarted,
		"the client's own EventBus.run_restarted fired — the RUN_KIND record crossed the socket")
	if not restarted:
		return

	var result: Dictionary = _read_result()
	check(int(result.get("seed_at_restart", 0)) == new_seed,
		("client's GameState.run_seed was ALREADY the host's new seed at the instant run_restarted "
		+ "fired — the reseed record won the ordering. expected %d, sampled %s")
		% [new_seed, str(result.get("seed_at_restart", null))])
	check(bool(result.get("seed_changed_at_restart", false)),
		"client's seed had changed away from the joined-on seed (%d) before run_restarted" % old_seed)
	check(bool(result.get("wiped_at_restart", false)),
		("client's WorldDeltaLog had ALREADY dropped the ended run's chunk record at the instant "
		+ "run_restarted fired — `_reseed_local()`'s wipe ran over the wire, not just in-process. "
		+ "sampled mark=%s") % str(result.get("mark_at_restart", null)))
	check(int(result.get("seed_entry_at_restart", 0)) == new_seed,
		"the new seed was re-laid as the wiped log's own first entry on the client (%d)" % new_seed)


## The discrimination, over a real socket this time: an ordinary delta on any other chunk must be
## applied, and must NOT be mistaken for a new world.
func _phase_ordinary_delta_after_restart() -> void:
	print("\n== RESEEDNET 3 · an ordinary delta after the restart is applied, not reseeded ==")
	var seed_before: int = int(game_state.get(&"run_seed"))
	world_delta_log.call("host_record", MARK_CHUNK, MARK_KIND, MARK_KEY, POST_VALUE)
	var applied: bool = await _until(
		func() -> bool: return int(_read_result().get("mark", 0)) == POST_VALUE, TIMEOUT_SEC
	)
	check(applied, "the post-restart delta replicated to the client (mark=%s)"
		% str(_read_result().get("mark", null)))
	var result: Dictionary = _read_result()
	check(int(result.get("restarts", 0)) == 1,
		"an ordinary delta did NOT trigger a second reseed on the client (restarts=%s)"
		% str(result.get("restarts", null)))
	check(int(result.get("seed", 0)) == seed_before,
		"the client's seed is unchanged by an ordinary delta (%d)" % seed_before)


# ── probe (CLIENT) ───────────────────────────────────────────────────────────────────────────────


var _boot_seed: int = 0
var _restarts: int = 0
var _seed_at_restart: int = 0
var _seed_entry_at_restart: int = 0
var _mark_at_restart: Variant = null
var _wiped_at_restart: bool = false
var _seed_changed_at_restart: bool = false


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var joined: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	var client_failures: int = 0
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	if bool(transport.call("is_host")):
		client_failures += 1  # the join target was LOCAL; this process must never end up the host

	# The joined-on seed comes from `net_world_snapshot`, which lands with the admission handshake.
	var seeded: bool = await _until(
		func() -> bool: return int(game_state.get(&"run_seed")) != 0, TIMEOUT_SEC)
	if not seeded:
		client_failures += 1
	_boot_seed = int(game_state.get(&"run_seed"))

	# Subscribed through the real EventBus dispatcher, exactly as a shipped system does. The samples
	# are taken INSIDE the handler on purpose — that is what makes this an ordering assertion.
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)

	while true:
		_write_result({
			"connected": true,
			"boot_seed": _boot_seed,
			"seed": int(game_state.get(&"run_seed")),
			"mark": world_delta_log.call("latest", MARK_CHUNK, MARK_KIND, MARK_KEY, 0),
			"restarts": _restarts,
			"seed_at_restart": _seed_at_restart,
			"seed_entry_at_restart": _seed_entry_at_restart,
			"mark_at_restart": _mark_at_restart,
			"wiped_at_restart": _wiped_at_restart,
			"seed_changed_at_restart": _seed_changed_at_restart,
			"failures": client_failures,
		})
		await create_timer(0.1).timeout


func _on_run_restarted() -> void:
	_restarts += 1
	if _restarts > 1:
		return
	_seed_at_restart = int(game_state.get(&"run_seed"))
	_seed_changed_at_restart = _seed_at_restart != _boot_seed and _seed_at_restart != 0
	_mark_at_restart = world_delta_log.call("latest", MARK_CHUNK, MARK_KIND, MARK_KEY, null)
	_wiped_at_restart = _mark_at_restart == null
	_seed_entry_at_restart = int(world_delta_log.call(
		"latest", WORLD_DELTA_LOG.SEED_CHUNK, WORLD_DELTA_LOG.SEED_KIND,
		WORLD_DELTA_LOG.SEED_KEY, 0))


# ── harness ──────────────────────────────────────────────────────────────────────────────────────


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/run_reseed_net_check.gd",
		"--", "run-reseed-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


## F-290: staged and renamed into place so a poll never reads a torn document.
func _write_result(result: Dictionary) -> void:
	var staging: String = RESULT_PATH + ".part"
	var file := FileAccess.open(staging, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(staging), ProjectSettings.globalize_path(RESULT_PATH))


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var raw: String = FileAccess.get_file_as_string(RESULT_PATH)
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw)
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
