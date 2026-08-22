extends SceneTree

## F-349/F-350 — how long does an unwarded island stay survivable?
##
## Runs `MireGridSim` forward at the rate `world/mire/mire_grid.gd` actually ticks it and reports,
## per elapsed minute, how much of the island is above `PlayerHealth.BLIGHT_CORRUPTION_THRESHOLD`
## and what that costs a player standing on it. Pure static sim — no scene, no renderer — so this is
## the cheap way to answer "is the death he saw the Mire arriving, or something broken?".
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only measurement.
##
##   .agent/bin/agent godot --script tools/blight_timeline_check.gd

const SIM := preload("res://world/mire/mire_grid_sim.gd")
const GRID := preload("res://world/mire/mire_grid.gd")
const HEALTH := preload("res://systems/health/player_health.gd")

const WORLD_SEED: int = 20260819
const HORIZON_SEC: float = 1800.0
## Sampled at the origin because that is where a run starts — see `_report_row`.
const SPAWN := Vector2(0.0, 0.0)


## F-599. Multipliers to sweep, so the `mire_spread_multiplier` gamerule's default is chosen from
## measured arrival times rather than from a feel about a number.
##
## The rate this file has always measured is `BASE_SPREAD_RATE` alone, which is right for the
## question F-349 asked ("when does Blight arrive on an unwarded island") and useless for the one
## Sequoyah asked after playing ("the mire spreading is super unclear"). At 1.0 the answer is that it
## never arrives inside a session, and a report that stops there tells nobody what to do about it.
const SWEEP_MULTIPLIERS: Array[float] = [1.0, 1.5, 2.0, 3.0, 5.0]


func _initialize() -> void:
	var threshold: float = HEALTH.BLIGHT_CORRUPTION_THRESHOLD
	var drain: float = HEALTH.BLIGHT_HP_DRAIN_PER_SEC_AT_FULL_CORRUPTION
	print("F-349 — Blight arrival on an unwarded island (seed %d)" % WORLD_SEED)
	print("  tick %.1f s, spread %.3f, threshold %.2f, drain %.1f hp/s at full\n"
		% [GRID.TICK_INTERVAL_SEC, GRID.BASE_SPREAD_RATE, threshold, drain])
	print("   time   island>thr   corruption@spawn   hp/s@spawn   time-to-die")

	var grid: PackedFloat32Array = SIM.seed_initial(WORLD_SEED)
	var ticks: int = int(HORIZON_SEC / GRID.TICK_INTERVAL_SEC)
	var lethal_at: float = -1.0
	_report_row(0.0, grid, threshold, drain)
	for step: int in ticks:
		grid = SIM.tick(grid, [], GRID.BASE_SPREAD_RATE)
		var elapsed: float = float(step + 1) * GRID.TICK_INTERVAL_SEC
		if lethal_at < 0.0 and _at(grid, SPAWN) >= threshold:
			lethal_at = elapsed
		if is_equal_approx(fmod(elapsed, 120.0), 0.0):
			_report_row(elapsed, grid, threshold, drain)

	print("")
	if lethal_at < 0.0:
		print("  spawn never crossed the threshold within %.0f s" % HORIZON_SEC)
	else:
		print("  spawn crossed the Blight threshold at %.0f s (%.1f min) with no ward built"
			% [lethal_at, lethal_at / 60.0])
	_sweep(threshold)
	print("BLIGHT_TIMELINE_CHECK lethal_at_sec=%.0f horizon_sec=%.0f" % [lethal_at, HORIZON_SEC])
	# This one only ever REPORTS — it has no assertions and no failure counter, so its verdict is a
	# constant zero. `agent verify` still needs the line, or a run that reported nothing at all is
	# indistinguishable from this one (F-555).
	print("BLIGHT_TIMELINE_CHECK failures=0")
	quit()


## F-599: how long the Mire takes to reach the spawn at each candidate multiplier, and how much of
## the island it holds by then. This is the table the gamerule's default should be read off.
##
## Runs to a longer horizon than the report above, because the interesting answer at 1.0 is "longer
## than a session" and a horizon that stops before it can never say so.
func _sweep(threshold: float) -> void:
	print("\n== F-599: arrival at spawn by mire_spread_multiplier ==")
	print("  multiplier   reaches spawn   island corrupted at that moment")
	var horizon: float = 7200.0
	var ticks: int = int(horizon / GRID.TICK_INTERVAL_SEC)
	for multiplier: float in SWEEP_MULTIPLIERS:
		var grid: PackedFloat32Array = SIM.seed_initial(WORLD_SEED)
		var rate: float = GRID.BASE_SPREAD_RATE * multiplier
		var arrived: float = -1.0
		var share_at_arrival: float = 0.0
		for step: int in ticks:
			grid = SIM.tick(grid, [], rate)
			if _at(grid, SPAWN) >= threshold:
				arrived = float(step + 1) * GRID.TICK_INTERVAL_SEC
				share_at_arrival = _share_above(grid, threshold)
				break
		if arrived < 0.0:
			print("  %5.1fx        never (>%d min)   %.1f%% at horizon"
				% [multiplier, int(horizon / 60.0), _share_above(grid, threshold) * 100.0])
		else:
			print("  %5.1fx        %4.0f min          %.1f%%"
				% [multiplier, arrived / 60.0, share_at_arrival * 100.0])
	print("  (base rate only — the per-Cycle +15%% escalation makes every figure above an upper bound)")
	print("  (sampled at the island ORIGIN, not the real spawn: F-602 measures the shore spawn at")
	print("   296-383 m from the seed, so a real camp is reached LATER than the times above)")


## Fraction of the island above the Blight threshold.
func _share_above(grid: PackedFloat32Array, threshold: float) -> float:
	var above: int = 0
	for value: float in grid:
		if value >= threshold:
			above += 1
	return float(above) / float(maxi(grid.size(), 1))


func _report_row(
	elapsed: float, grid: PackedFloat32Array, threshold: float, drain: float
) -> void:
	var above: int = 0
	for value: float in grid:
		if value >= threshold:
			above += 1
	var fraction: float = float(above) / float(grid.size()) * 100.0
	var here: float = _at(grid, SPAWN)
	var hp_per_sec: float = drain * here if here >= threshold else 0.0
	var to_die: String = "—"
	if hp_per_sec > 0.0:
		to_die = "%.0f s" % (100.0 / hp_per_sec)
	print("  %5.0f s   %6.1f%%      %8.3f          %7.2f      %s"
		% [elapsed, fraction, here, hp_per_sec, to_die])


func _at(grid: PackedFloat32Array, position: Vector2) -> float:
	var cell: Vector2i = SIM.world_to_cell(position.x, position.y)
	return grid[SIM.cell_index(cell.x, cell.y)]
