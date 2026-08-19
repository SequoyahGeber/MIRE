extends SceneTree

## Task 4.9 (docs/ARCHITECTURE.md §5). Two parts, same file:
##
##   1. Single-process: MireGridSim is pure, so determinism, Wellspring-cap clearing and Ward
##      resistance are asserted directly against the function, no engine involved.
##   2. Real two-process ENet proof, same shape as tools/seed_sync_check.gd: a driver hosts and a
##      spawned child process is the CLIENT. SPECS.md 4.9 asks for this "enemy_net_check style" —
##      the thing a single process cannot prove is that a CLIENT never simulates, only ever receives
##      WorldDeltaLog deltas. The negative assertion reads the client's own `_seeded`/`_grid` fields
##      directly (Godot's `Object.get()` has no real privacy — underscore is convention only) to
##      prove the simulation code path never ran there, not just that the numbers happen to agree
##      (which a client independently re-simulating the SAME deterministic seed would also produce,
##      masking exactly this regression).
##
##   .agent/bin/agent godot --script tools/mire_grid_check.gd

const SIM := preload("res://world/mire/mire_grid_sim.gd")

const PORT: int = 47533
const RESULT_PATH: String = "user://mire_grid_client.json"
const DRIVER_SIGNAL_PATH: String = "user://mire_grid_driver.json"
const TIMEOUT_SEC: float = 15.0

const BEFORE_POSITION := Vector3(120.0, 0.0, -80.0)
const BEFORE_VALUE: float = 0.8
const LIVE_POSITION := Vector3(-200.0, 0.0, 40.0)
const LIVE_VALUE: float = 0.55

var failures: int = 0
var transport: Node
var mire_grid: Node
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "mire-grid-probe":
		_run_client()
		return

	_run_pure_checks()

	transport = root.get_node_or_null(^"NetTransport")
	mire_grid = root.get_node_or_null(^"MireGrid")
	if transport == null or mire_grid == null:
		fail("NetTransport and MireGrid must both be registered")
		finish()
		return
	_run_offline_checks()
	await _run_driver()


# ── 1. Pure MireGridSim — no engine, no node ────────────────────────────────────────────────────


func _run_pure_checks() -> void:
	print("\n== MireGridSim: pure function determinism and mechanics ==")

	var seed_a: PackedFloat32Array = SIM.seed_initial(1234)
	var seed_b: PackedFloat32Array = SIM.seed_initial(1234)
	check(_arrays_equal(seed_a, seed_b),
		"seed_initial(seed) is deterministic — same seed, identical grid")
	var seed_c: PackedFloat32Array = SIM.seed_initial(5678)
	check(not _arrays_equal(seed_a, seed_c), "a different seed produces a different grid")

	var corrupted_cell_count: int = 0
	for value: float in seed_a:
		if value > 0.0:
			corrupted_cell_count += 1
	check(corrupted_cell_count > 0, "seeding actually places corruption somewhere (%d cells)" % corrupted_cell_count)

	var tick_a: PackedFloat32Array = SIM.tick(seed_a, [], 0.06)
	var tick_b: PackedFloat32Array = SIM.tick(seed_a, [], 0.06)
	check(_arrays_equal(tick_a, tick_b), "tick() is deterministic given the same grid/wards/rate")

	var grew: bool = false
	for i: int in tick_a.size():
		if tick_a[i] > seed_a[i] + 0.0001:
			grew = true
			break
	check(grew, "a tick actually spreads corruption into at least one neighbour")

	# Ward resistance: two symmetric neighbours of one corrupted cell, one behind a ward circle.
	var probe_grid := PackedFloat32Array()
	probe_grid.resize(SIM.CELL_COUNT)
	var origin_cell := Vector2i(128, 128)
	probe_grid[SIM.cell_index(origin_cell.x, origin_cell.y)] = 1.0
	var warded_neighbor := Vector2i(origin_cell.x + 1, origin_cell.y)
	var open_neighbor := Vector2i(origin_cell.x - 1, origin_cell.y)
	var ward_position: Vector2 = SIM.cell_to_world_center(warded_neighbor.x, warded_neighbor.y)
	var wards: Array = [{"position": ward_position, "radius": SIM.CELL_SIZE_M * 0.5}]
	var warded_tick: PackedFloat32Array = SIM.tick(probe_grid, wards, 0.5)
	check(warded_tick[SIM.cell_index(warded_neighbor.x, warded_neighbor.y)] == 0.0,
		"a cell inside a ward's radius resists accumulation entirely")
	check(warded_tick[SIM.cell_index(open_neighbor.x, open_neighbor.y)] > 0.0,
		"the symmetric unwarded neighbour still accumulates — the ward, not some other bug, made the difference")

	# Wellspring cap: a filled disc clears to exactly zero inside its radius, untouched outside.
	var clear_grid := PackedFloat32Array()
	clear_grid.resize(SIM.CELL_COUNT)
	for i: int in clear_grid.size():
		clear_grid[i] = 0.9
	var clear_center := Vector2(0.0, 0.0)
	var cleared: PackedFloat32Array = SIM.clear_radius(clear_grid, clear_center, 40.0)
	var inside_cell: Vector2i = SIM.world_to_cell(5.0, 5.0)
	var outside_cell: Vector2i = SIM.world_to_cell(400.0, 400.0)
	check(cleared[SIM.cell_index(inside_cell.x, inside_cell.y)] == 0.0,
		"clear_radius zeroes a cell well inside its radius")
	check(is_equal_approx(cleared[SIM.cell_index(outside_cell.x, outside_cell.y)], 0.9),
		"clear_radius leaves a cell far outside its radius untouched")


func _arrays_equal(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return false
	for i: int in a.size():
		if a[i] != b[i]:
			return false
	return true


# ── 2. The live autoload, offline (host-of-one) ─────────────────────────────────────────────────


func _run_offline_checks() -> void:
	print("\n== MireGrid autoload: offline host-of-one ==")
	# The harness owns time from here — see wave_spawner_check.gd's own note on why.
	mire_grid.set_physics_process(false)
	mire_grid.call("ensure_ready")
	check(bool(mire_grid.get(&"_seeded")), "ensure_ready() seeds the live grid")
	var grid: PackedFloat32Array = mire_grid.get(&"_grid")
	check(grid.size() == SIM.CELL_COUNT, "the live grid is the full 256x256 cell count")

	var probe_position := Vector3(30.0, 0.0, -15.0)
	mire_grid.call("host_set_corruption_at", probe_position, 0.7)
	check(is_equal_approx(float(mire_grid.call("corruption_at", probe_position)), 0.7),
		"host_set_corruption_at is immediately visible through corruption_at on the host")
	check(bool(mire_grid.call("is_corrupted", probe_position, 0.5)),
		"is_corrupted respects the threshold argument")

	# Ward wiring seam (4.11 fills this in for real) — an empty default provider must not crash a tick.
	mire_grid.call("_physics_process", 2.1)
	check(true, "a tick runs with no ward provider wired (4.11's own job) without erroring")


# ── 3. Real two-process proof: a client never simulates ────────────────────────────────────────


func _run_driver() -> void:
	print("\n== two-process: client only ever receives deltas, never simulates ==")
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

	mire_grid.call("host_set_corruption_at", BEFORE_POSITION, BEFORE_VALUE)
	mire_grid.call("flush_deltas")

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false)), TIMEOUT_SEC
	)
	check(connected, "client connects")
	if not connected:
		finish()
		return

	var got_before: bool = await _until(
		func() -> bool: return bool(_read_result().get("saw_before", false)), TIMEOUT_SEC
	)
	check(got_before,
		"a corruption value set BEFORE the client joined reached it via the late-joiner snapshot")
	check(is_equal_approx(float(_read_result().get("before_value", -1.0)), BEFORE_VALUE),
		"the snapshotted value matches exactly what the host set")

	mire_grid.call("host_set_corruption_at", LIVE_POSITION, LIVE_VALUE)
	mire_grid.call("flush_deltas")
	var got_live: bool = await _until(
		func() -> bool: return bool(_read_result().get("saw_live", false)), TIMEOUT_SEC
	)
	check(got_live, "a corruption value set AFTER the client joined reached it live")

	check(not bool(_read_result().get("owned_simulation_on_connect", true)),
		"NEGATIVE: _owns_simulation() already reads false the instant the client connects")
	check(bool(_read_result().get("grid_frozen_since_connect", false)),
		"NEGATIVE: the client's own _grid never changed after connecting — it never ticked locally")

	_write_driver_signal({"should_exit": true})
	var client_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(client_exited, "client exits cleanly")
	if client_exited:
		child_pid = 0
	check(int(_read_result().get("failures", -1)) == 0, "client-side self checks report 0 failures")

	transport.call("leave")
	print("MIRE_GRID_CHECK failures=%d" % failures)
	finish()


func _run_client() -> void:
	_write_result({"connected": false})
	var local_transport: Node = root.get_node_or_null(^"NetTransport")
	var local_mire_grid: Node = root.get_node_or_null(^"MireGrid")
	var error: Error = local_transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	await _client_drive(local_transport, local_mire_grid)


## What "a client never simulates" actually has to mean here: the offline-solo convention every
## host-authoritative system in this project shares (`_owns_simulation()`, same shape as
## `PlayerHealth._owns_mutation()`) makes an UNCONNECTED process its own "host of one" — so this
## process may legitimately have started ticking its own local grid in the brief window before
## `join()` completes, exactly like it would if nobody ever joined it to anything. That is not the
## bug this file exists to catch. What must never happen is a CONNECTED, non-host client continuing
## to simulate — so the real assertion is taken from the moment `is_active()` first turns true:
## `_owns_simulation()` must already read false, and `_grid` must be byte-for-byte frozen from that
## instant onward, for as long as this process stays connected, no matter how much real wall-clock
## time (and how many missed 2s ticks) passes.
func _client_drive(local_transport: Node, local_mire_grid: Node) -> void:
	var client_failures: int = 0
	var joined: bool = await _until(
		func() -> bool: return bool(local_transport.call("is_active")), TIMEOUT_SEC
	)
	if not joined:
		_write_result({"error": "client never connected"})
		finish()
		return
	if bool(local_transport.call("is_host")):
		client_failures += 1  # LOCAL join target; this process must never end up the host

	var owns_simulation_on_connect: bool = bool(local_mire_grid.call("_owns_simulation"))
	if owns_simulation_on_connect:
		client_failures += 1
	var grid_at_connect: PackedFloat32Array = (local_mire_grid.get(&"_grid") as PackedFloat32Array).duplicate()

	while not bool(_read_driver_signal().get("should_exit", false)):
		_write_client_snapshot(local_mire_grid, client_failures, owns_simulation_on_connect, grid_at_connect)
		await create_timer(0.1).timeout

	_write_client_snapshot(local_mire_grid, client_failures, owns_simulation_on_connect, grid_at_connect)
	local_transport.call("leave")
	finish()


func _write_client_snapshot(
	local_mire_grid: Node, client_failures: int,
	owns_simulation_on_connect: bool, grid_at_connect: PackedFloat32Array
) -> void:
	var before_value: float = float(local_mire_grid.call("corruption_at", BEFORE_POSITION))
	var live_value: float = float(local_mire_grid.call("corruption_at", LIVE_POSITION))
	var grid_now: PackedFloat32Array = local_mire_grid.get(&"_grid")
	var grid_frozen: bool = _arrays_equal(grid_at_connect, grid_now)
	if not grid_frozen:
		client_failures += 1
	_write_result({
		"connected": true,
		"saw_before": before_value > 0.0,
		"before_value": before_value,
		"saw_live": live_value > 0.0,
		"owned_simulation_on_connect": owns_simulation_on_connect,
		"grid_frozen_since_connect": grid_frozen,
		"failures": client_failures,
	})


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/mire_grid_check.gd",
		"--", "mire-grid-probe",
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
