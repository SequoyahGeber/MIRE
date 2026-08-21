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
	print("BLIGHT_TIMELINE_CHECK lethal_at_sec=%.0f horizon_sec=%.0f" % [lethal_at, HORIZON_SEC])
	quit()


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
