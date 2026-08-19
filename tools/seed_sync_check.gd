extends SceneTree

## Real two-process ENet proof for task 4.6 (docs/ARCHITECTURE.md §4). Same shape as
## tools/day_night_net_check.gd: the driver process hosts and plays the HOST directly; a spawned
## child process is the CLIENT, talking back through a user:// JSON file
## (docs/SPECS.md's "Two-process checks" seam).
##
##   .agent/bin/agent godot --script tools/seed_sync_check.gd
##
## Three things this proves that a single-process check cannot:
##   1. The seed really crosses the wire: a client that never picked its own seed regenerates the
##      SAME terrain a host picked, proven by comparing tools/check_determinism.gd's own
##      `terrain_hash` sample computed independently on each process.
##   2. A mutation recorded BEFORE a peer ever connects (the late-joiner case) still reaches it —
##      `WorldDeltaLog`'s admit-time snapshot, not just its live broadcast.
##   3. A mutation recorded AFTER a peer is already connected reaches it too, live — the other half
##      of `ARCHITECTURE.md` §4's "every mutation... replicates as deltas keyed by chunk."

## Preloaded rather than referenced by bare class_name — a script new to this session is not yet in
## .godot/global_script_class_cache.cfg (F-016, same fix tools/handshake_check.gd uses).
const IslandHeightmap = preload("res://world/gen/island_heightmap.gd")

const PORT: int = 47530
const RESULT_PATH: String = "user://seed_sync_client.json"
const DRIVER_SIGNAL_PATH: String = "user://seed_sync_driver.json"
const TIMEOUT_SEC: float = 15.0

## Recorded before the client even exists — the late-joiner snapshot case.
const BEFORE_CHUNK := Vector2i(3, -2)
const BEFORE_KEY: String = "test:before"
## Recorded once the client is already connected — the live-broadcast case.
const LIVE_CHUNK := Vector2i(5, 1)
const LIVE_KEY: String = "test:live"
const DEPLETION_KIND: StringName = &"harvest_depleted"

var failures: int = 0
var transport: Node
var game_state: Node
var delta_log: Node
var net_session: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	game_state = root.get_node_or_null(^"GameState")
	delta_log = root.get_node_or_null(^"WorldDeltaLog")
	net_session = root.get_node_or_null(^"NetSession")
	if transport == null or game_state == null or delta_log == null or net_session == null:
		fail("NetTransport, GameState, WorldDeltaLog and NetSession must all be registered")
		finish()
		return

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "seed-sync-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== seed replication + delta sync network check (task 4.6) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_write_driver_signal({"should_exit": false})

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	await process_frame
	check(bool(game_state.call("is_seed_ready")), "GameState picks a run seed the moment hosting starts")

	# ── 2. A mutation recorded before the late joiner even exists ─────────────────────────────────
	delta_log.call("host_record", BEFORE_CHUNK, DEPLETION_KIND, BEFORE_KEY, true)
	check(bool(delta_log.call("latest", BEFORE_CHUNK, DEPLETION_KIND, BEFORE_KEY, false)),
		"the host's own record of a pre-join mutation is immediate, not RPC round-trip dependent")

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false)), TIMEOUT_SEC
	)
	check(connected, "client connects")
	if not connected:
		finish()
		return

	# F-253: this used to poll `seed_ready` here, which is NOT proof `net_world_snapshot` arrived —
	# `GameState.is_seed_ready()` also flips true the moment the client's OWN `MireGrid` autoload
	# draws itself a throwaway local seed (`ensure_ready()` -> `GameState.ensure_seed()`), which it
	# does unconditionally on ANY not-yet-connected peer (`_owns_simulation()` reads true whenever
	# the transport is neither active nor connecting — true for "genuinely offline", but just as true
	# for "about to join, hasn't yet"). That is intentional, decided behavior (D-110, D-119, F-172:
	# solo/offline play must seed instantly at boot, and the project explicitly rejected gating
	# world-gen behind a connection-state check), so it is not something to fix here — it just means
	# `seed_ready` alone proves nothing about replication. `before_delta` is the real proof: it can
	# only read true once `WorldDeltaLog.net_world_snapshot()` has actually run, and that one RPC
	# body sets the replicated seed and decodes the delta state sequentially, so gating on it makes
	# every read below (which used to race the client's own premature local draw) consistent.
	var snapshotted: bool = await _until(
		func() -> bool: return bool(_read_result().get("before_delta", false)), TIMEOUT_SEC
	)
	check(snapshotted, "client's run seed is ready (net_world_snapshot arrived)")

	# ── 1. Independently regenerated terrain matches ───────────────────────────────────────────────
	var host_seed: int = int(game_state.get(&"run_seed"))
	var client_seed: int = int(_read_result().get("run_seed", -1))
	check(host_seed == client_seed, "client's run_seed equals the host's (host=%d client=%d)" % [
		host_seed, client_seed
	])

	var host_hash: String = _hash_terrain(host_seed)
	var client_hash: String = String(_read_result().get("terrain_hash", ""))
	check(host_hash == client_hash and not host_hash.is_empty(),
		"client-regenerated terrain_hash equals the host's (host=%s client=%s)" % [host_hash, client_hash])

	# ── 2. The pre-join mutation was in the snapshot ───────────────────────────────────────────────
	check(bool(_read_result().get("before_delta", false)),
		"a mutation recorded before the client joined reached it via the late-joiner snapshot")

	# ── 3. A live mutation, recorded after the client is already connected, reaches it too ─────────
	delta_log.call("host_record", LIVE_CHUNK, DEPLETION_KIND, LIVE_KEY, true)
	var live_arrived: bool = await _until(
		func() -> bool: return bool(_read_result().get("live_delta", false)), TIMEOUT_SEC
	)
	check(live_arrived, "a mutation recorded AFTER the client joined reached it live (net_delta_applied)")

	_write_driver_signal({"should_exit": true})
	var client_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(client_exited, "client exits cleanly")
	if client_exited:
		child_pid = 0
	check(int(_read_result().get("failures", -1)) == 0, "client-side self checks report 0 failures")

	transport.call("leave")
	print("SEED_SYNC_CHECK failures=%d" % failures)
	finish()


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var client_failures: int = 0

	var joined: bool = await _until(func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	if bool(transport.call("is_host")):
		client_failures += 1  # the join target was LOCAL; this process must never end up the host

	var seed_ready: bool = await _until(
		func() -> bool: return bool(game_state.call("is_seed_ready")), TIMEOUT_SEC
	)
	if not seed_ready:
		client_failures += 1

	while not bool(_read_driver_signal().get("should_exit", false)):
		_write_client_snapshot(client_failures)
		await create_timer(0.1).timeout

	_write_client_snapshot(client_failures)
	transport.call("leave")
	finish()


func _write_client_snapshot(client_failures: int) -> void:
	var run_seed: int = int(game_state.get(&"run_seed"))
	_write_result({
		"connected": true,
		"peer_id": int(transport.call("local_peer_id")),
		"seed_ready": bool(game_state.call("is_seed_ready")),
		"run_seed": run_seed,
		"terrain_hash": _hash_terrain(run_seed),
		"before_delta": bool(delta_log.call("latest", BEFORE_CHUNK, DEPLETION_KIND, BEFORE_KEY, false)),
		"live_delta": bool(delta_log.call("latest", LIVE_CHUNK, DEPLETION_KIND, LIVE_KEY, false)),
		"failures": client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/seed_sync_check.gd",
		"--", "seed-sync-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


## Same grid/spacing/hash as tools/check_determinism.gd's own `_hash_terrain()` — this is
## deliberately the identical probe, run twice by two independent OS processes instead of once, so
## agreement here is proof the SEED crossed the wire, not proof the math is platform-stable (that is
## check_determinism.gd's job).
func _hash_terrain(seed_value: int) -> String:
	const GRID: int = 64
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for gz in GRID:
		for gx in GRID:
			var x: float = (float(gx) - float(GRID) * 0.5) * 24.0
			var z: float = (float(gz) - float(GRID) * 0.5) * 24.0
			var height: float = IslandHeightmap.height(x, z, seed_value)
			ctx.update(PackedFloat64Array([height]).to_byte_array())
	return ctx.finish().hex_encode().substr(0, 16)


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


func _write_driver_signal(result: Dictionary) -> void:
	var file := FileAccess.open(DRIVER_SIGNAL_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()


func _read_driver_signal() -> Dictionary:
	if not FileAccess.file_exists(DRIVER_SIGNAL_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DRIVER_SIGNAL_PATH))
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
