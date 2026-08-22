extends SceneTree

## Direct proof for task 6.1: CycleService is registered, subscribed to the real DayNight's dawn
## crossing, and its `host_advance_cycle()` step actually does the three things DESIGN.md §5.1 names
## — escalates MireGrid's spread rate, expands WaveSpawner's enemy roster, and announces (WorldDeltaLog
## record + EventBus emission). Single-process, offline (host-of-one) — same convention
## mire_interaction_check.gd uses: every touched system's own host-authority is already proven by its
## own check (mire_grid_check.gd, wave_spawner_check.gd), this file only proves 6.1's new state
## machine layered on top.
##
##   .agent/bin/agent godot --script tools/cycle_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0
var cycle_service: Node
var day_night: Node
var mire_grid: Node
var wave_spawner: Node
var world_delta_log: Node
## Written by `_on_cycle_advanced()`. A lambda closing over a local in `_check_announce()` would
## capture that local BY VALUE in GDScript — mutating it inside the closure would not be visible to
## the caller — so this needs to be a real member field the listener assigns through `self`.
var _logged_cycle: int = -1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	_check_state_machine_step()
	_check_day_counting()
	_check_announce()

	print("\nCYCLE_CHECK failures=%d" % failures)
	finish()


## F-068-shaped regression anchor (the same lesson wave_spawner_check.gd's own header records): a
## check that builds its own fake CycleService/DayNight only proves the script, not that the shipped
## project actually wires one to the other. This asserts the real autoload and the real signal
## connection.
func _check_wiring() -> bool:
	print("== the shipped project actually has a Cycle director ==")
	cycle_service = root.get_node_or_null(^"CycleService")
	day_night = root.get_node_or_null(^"DayNight")
	mire_grid = root.get_node_or_null(^"MireGrid")
	wave_spawner = root.get_node_or_null(^"WaveSpawner")
	world_delta_log = root.get_node_or_null(^"WorldDeltaLog")
	check(cycle_service != null, "CycleService is registered as an autoload")
	check(day_night != null, "DayNight is registered as an autoload")
	check(mire_grid != null, "MireGrid is registered as an autoload")
	check(wave_spawner != null, "WaveSpawner is registered as an autoload")
	check(world_delta_log != null, "WorldDeltaLog is registered as an autoload")
	var all_present: bool = cycle_service != null and day_night != null and mire_grid != null \
		and wave_spawner != null and world_delta_log != null
	if not all_present:
		return false
	check(day_night.is_connected(&"day_started", Callable(cycle_service, "_on_day_started")),
		"CycleService is subscribed to the real DayNight's dawn crossing")
	return true


func _check_state_machine_step() -> void:
	print("\n== host_advance_cycle() does the three DESIGN.md §5.1 things ==")
	var cycle_before: int = int(cycle_service.call("current_cycle"))
	var spread_before: float = float(mire_grid.get(&"_cycle_spread_multiplier"))
	var pool_before: Array = wave_spawner.call("unlocked_enemy_pool")

	var advanced: int = int(cycle_service.call("host_advance_cycle"))
	check(advanced == cycle_before + 1, "host_advance_cycle() increments current_cycle (%d -> %d)"
		% [cycle_before, advanced])
	check(int(cycle_service.call("current_cycle")) == advanced,
		"current_cycle() reflects the new value")

	var spread_after: float = float(mire_grid.get(&"_cycle_spread_multiplier"))
	check(spread_after > spread_before,
		"1. escalates the Mire's spread rate (%.4f -> %.4f)" % [spread_before, spread_after])

	var pool_after: Array = wave_spawner.call("unlocked_enemy_pool")
	check(pool_after.size() == pool_before.size() + 1,
		"3. expands the enemy roster (%d -> %d unlocked)" % [pool_before.size(), pool_after.size()])
	# Asserted against the registry, NOT against a hardcoded id: this check named `bog_crawler` until
	# task 5.11 rewrote `roster_order` into the night ladder and moved `fen_stalker` to the front, at
	# which point it failed on a change that was entirely correct. What it is actually for is that the
	# roster never unlocks a name with no `.tres` behind it — a wave that spawns nothing.
	var unlocked_id: StringName = pool_after[pool_after.size() - 1] if pool_after.size() > 0 else &""
	var enemy_world: Node = root.get_node_or_null(^"/root/EnemyWorld")
	check(unlocked_id != &"" and enemy_world != null and bool(enemy_world.call("has_def", unlocked_id)),
		"the unlocked archetype is content that actually exists (%s)" % unlocked_id)

	# A second advance past roster_order's one authored entry must not crash or duplicate — it is a
	# legitimate "nothing left to unlock yet" state, same as WaveSpawner's own host_unlock_next_enemy
	# doc comment describes.
	cycle_service.call("host_advance_cycle")
	var pool_final: Array = wave_spawner.call("unlocked_enemy_pool")
	check(pool_final.size() == pool_after.size(),
		"unlocking past roster_order's end is a no-op, not a crash or a duplicate")


func _check_day_counting() -> void:
	print("\n== 3 DayNight.day_started crossings advance exactly one Cycle ==")
	var before: int = int(cycle_service.call("current_cycle"))
	for _day_index: int in 3:
		day_night.emit_signal(&"day_started")
	check(int(cycle_service.call("current_cycle")) == before + 1,
		"three day_started crossings advance the Cycle once (%d -> %d)"
		% [before, int(cycle_service.call("current_cycle"))])

	var mid_before: int = int(cycle_service.call("current_cycle"))
	day_night.emit_signal(&"day_started")
	day_night.emit_signal(&"day_started")
	check(int(cycle_service.call("current_cycle")) == mid_before,
		"one or two crossings alone do not advance the Cycle")


func _check_announce() -> void:
	print("\n== announce: WorldDeltaLog record + EventBus emission ==")
	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)

	var expected: int = int(cycle_service.call("host_advance_cycle"))
	check(_logged_cycle == expected, "EventBus.emit_cycle_advanced() reaches a subscriber (%d)"
		% _logged_cycle)

	var logged: int = int(world_delta_log.call(
		"latest", Vector2i.ZERO, &"cycle", "current", -1))
	check(logged == expected,
		"WorldDeltaLog carries the same Cycle number a late joiner would read (%d)" % logged)

	EVENT_BUS.unsubscribe_cycle_advanced(_on_cycle_advanced)


func _on_cycle_advanced(cycle: int) -> void:
	_logged_cycle = cycle


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
