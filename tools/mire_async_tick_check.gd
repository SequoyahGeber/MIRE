extends SceneTree

## D-208/F-363 regression guard: the Mire tick runs on a worker thread, and `_grid` is only ever
## replaced by a COMPLETED tick.
##
## The change this guards is invisible to every other Mire check — they assert what the grid
## CONTAINS, and the async version reaches the same contents a frame later. What none of them can
## see is the property that makes it safe: a synchronous mutation (a Peatling's death stain, a
## Wellspring's clear) that happens while a tick is in flight must WIN, and the tick's result must be
## thrown away rather than applied on top of it. A running `WorkerThreadPool` task cannot be
## cancelled, so discarding the answer is the only cancel there is.
##
## If that rule broke, the symptom in a real run would be a stain or a Wellspring clear that
## flickered into existence and then silently reverted two seconds later — the kind of bug that gets
## reported as "the Mire came back" and costs a session to find.
##
##     .agent/bin/agent godot --script tools/mire_async_tick_check.gd

const SIM := preload("res://world/mire/mire_grid_sim.gd")

## How long to pump frames waiting for a dispatched tick to land. A tick is ~15 ms of work at
## saturation and this is headless, so this is a generous ceiling, not a tuned figure.
const LAND_TIMEOUT_SEC: float = 10.0

var mire_grid: Node
var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	mire_grid = get_root().get_node_or_null(^"MireGrid")
	if mire_grid == null:
		push_error("no MireGrid autoload")
		quit(1)
		return
	# The harness owns time from here — the same stance mire_grid_check.gd takes, so a real
	# _physics_process cannot dispatch a tick underneath these assertions.
	mire_grid.set_physics_process(false)
	mire_grid.call(&"ensure_ready")

	await _check_dispatches_and_lands()
	await _check_stain_supersedes_a_running_tick()
	_check_force_tick_is_synchronous()

	print("MIRE_ASYNC_TICK_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


## The happy path: a due tick goes to the pool and its result arrives on a later frame.
func _check_dispatches_and_lands() -> void:
	print("\n== a due tick dispatches to the pool and lands later ==")
	var before: Array = mire_grid.call(&"tick_stats")

	# One interval's worth of time, delivered the way the engine would.
	mire_grid.call("_physics_process", 2.1)
	var after_dispatch: Array = mire_grid.call(&"tick_stats")
	check(int(after_dispatch[0]) == int(before[0]) + 1,
		"one tick dispatched (%d -> %d)" % [before[0], after_dispatch[0]])
	check(int(after_dispatch[1]) == int(before[1]),
		"it has NOT landed yet — the grid is untouched on the frame that dispatched it")

	var landed: bool = await _pump_until(func() -> bool:
		return int((mire_grid.call(&"tick_stats") as Array)[1]) > int(before[1]))
	check(landed, "the result lands on a later frame")
	var final: Array = mire_grid.call(&"tick_stats")
	check(int(final[2]) == int(before[2]),
		"nothing was discarded — no synchronous mutation raced this one")


## The rule that matters. A stain applied WHILE a tick is running must survive the tick landing.
func _check_stain_supersedes_a_running_tick() -> void:
	print("\n== a synchronous mutation beats a tick that is already in flight ==")
	var probe := Vector3(20.0, 0.0, 20.0)
	var before: Array = mire_grid.call(&"tick_stats")

	mire_grid.call("_physics_process", 2.1)
	check(int((mire_grid.call(&"tick_stats") as Array)[0]) == int(before[0]) + 1,
		"a tick is in flight")

	# The stain lands on the live grid while the worker is computing from a copy that predates it.
	mire_grid.call(&"host_set_corruption_at", probe, 0.9)
	check(is_equal_approx(float(mire_grid.call(&"corruption_at", probe)), 0.9),
		"the stain is immediately visible, without waiting for the tick")

	var settled: bool = await _pump_until(func() -> bool:
		var stats: Array = mire_grid.call(&"tick_stats")
		return int(stats[1]) + int(stats[2]) > int(before[1]) + int(before[2]))
	check(settled, "the in-flight tick finished")
	check(int((mire_grid.call(&"tick_stats") as Array)[2]) == int(before[2]) + 1,
		"its result was DISCARDED, not applied — it was computed from a pre-stain grid")
	# The actual regression: without the discard, this reads back whatever the stale tick held.
	check(is_equal_approx(float(mire_grid.call(&"corruption_at", probe)), 0.9),
		"the stain SURVIVED the tick landing — this is the bug that would read as "
		+ "'the corruption reverted two seconds later'")


## The test seam every other check leans on has to stay synchronous, or those checks silently start
## asserting against a grid that has not moved.
func _check_force_tick_is_synchronous() -> void:
	print("\n== host_force_tick() advances the grid before it returns ==")
	var probe := Vector3(-40.0, 0.0, 12.0)
	mire_grid.call(&"host_set_corruption_at", probe, 0.8)
	var neighbour_cell: Vector2i = SIM.world_to_cell(probe.x + SIM.CELL_SIZE_M, probe.z)
	var grid_before: PackedFloat32Array = mire_grid.get(&"_grid")
	var neighbour_before: float = grid_before[SIM.cell_index(neighbour_cell.x, neighbour_cell.y)]

	mire_grid.call(&"host_force_tick")

	var grid_after: PackedFloat32Array = mire_grid.get(&"_grid")
	var neighbour_after: float = grid_after[SIM.cell_index(neighbour_cell.x, neighbour_cell.y)]
	check(neighbour_after > neighbour_before,
		"corruption spread to the neighbouring cell synchronously (%.5f -> %.5f)"
			% [neighbour_before, neighbour_after])


func _pump_until(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(LAND_TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline:
		# Drives `_drain_tick()` the way a real frame would, without letting `_elapsed` accumulate
		# enough to dispatch another tick and confuse the counters.
		mire_grid.call("_physics_process", 0.0)
		if predicate.call():
			return true
		await process_frame
	return false


func check(condition: bool, description: String) -> void:
	if condition:
		print("  ok    %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
