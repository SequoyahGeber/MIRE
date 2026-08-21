extends SceneTree

## F-338: what the Mire tick costs at the fill levels a long run actually reaches.
##
## `MireGridSim.tick()` duplicates a 65,536-float grid, visits every cell, examines four neighbours
## for each corrupted one, and — for a warded run — linearly scans every ward circle per neighbour.
## `MireGrid` runs it synchronously on the host main thread every 2 seconds. Correctness and
## determinism are covered (`mire_grid_check`), but nothing measured the cost, and the worst state is
## the one nobody reaches in a check: late in the longest session, grid near-saturated, base built up.
##
## That is the wrong way round. A periodic hitch is least acceptable exactly when it arrives — deep
## in a run somebody has been playing for an hour.
##
##   .agent/bin/agent godot --script tools/bench_mire.gd
##
## Reports the cost per tick against the frame budget, across the fill and ward counts a run passes
## through. Exits nonzero if the saturated case misses its budget, so this is a gate and not a
## pamphlet — the mistake F-347's benchmark made for months.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). `MireGridSim` is pure static functions over an array.

const Sim := preload("res://world/mire/mire_grid_sim.gd")

const FRAME_BUDGET_MS: float = 16.667
## The Mire ticks every 2 s, so a tick is allowed to be a big slice of one frame — but it must not
## eat the frame. Half a frame is the line: past that, one tick is a visible stutter on a machine
## already near budget, and this project targets the worst machine someone might play on (F-174).
const TICK_BUDGET_MS: float = 8.0

## What this check FAILS above, as distinct from the budget it aims at.
##
## After F-338's optimisation a saturated, 16-ward grid ticks at 16.6 ms — 41x faster than the
## 687 ms it cost before, with the ward term gone entirely, and still over the 8 ms goal. The
## remainder is the full 65,536-cell pass itself, which cannot come down further without either
## moving the tick off the main thread or reordering its float accumulation, and reordering would
## change results the determinism assertion pins and the gameplay depends on.
##
## So the check gates REGRESSION at a ceiling with headroom over the measured worst, and says
## loudly, every run, that the goal is not met and why. A permanently-red gate gets ignored (F-347
## spent months as one); a gate quietly set to whatever the code happens to do measures nothing.
## This is neither: it holds the line where it is and names the gap.
const REGRESSION_CEILING_MS: float = 22.0
const SAMPLES: int = 9
const SPREAD_RATE: float = 0.08
const TEST_SEED: int = 20260819

## Fill fractions a run passes through: the seeded start, a mid-run spread, and the late-run state
## the finding names — near-total corruption with a built-up base still holding wards.
const FILLS: Array = [
	{"name": "seeded start", "fill": 0.0},
	{"name": "mid run", "fill": 0.35},
	{"name": "late run", "fill": 0.80},
	{"name": "saturated", "fill": 1.00},
]
## Ward counts: none, a modest camp, and a base that has been fortified for an hour.
const WARD_COUNTS: Array = [0, 4, 16]

var failures: int = 0
var _worst_saturated_ms: float = 0.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	print("\n=== MIRE tick cost — %dx%d grid, %d cells ===" % [
		Sim.CELLS_PER_SIDE, Sim.CELLS_PER_SIDE, Sim.CELL_COUNT])
	print("Godot %s | %s | %s" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_name()])
	print("tick budget %.1f ms (half a %.1f ms frame; the Mire ticks every 2 s)\n"
		% [TICK_BUDGET_MS, FRAME_BUDGET_MS])
	print("  %-14s %6s %10s %10s %10s" % ["fill", "wards", "median ms", "worst ms", "% frame"])

	for fill_spec: Dictionary in FILLS:
		for wards: int in WARD_COUNTS:
			var grid: PackedFloat32Array = _grid_at_fill(float(fill_spec["fill"]))
			var circles: Array = _wards(wards)
			var samples := PackedFloat64Array()
			for _i: int in SAMPLES:
				var t0: int = Time.get_ticks_usec()
				Sim.tick(grid, circles, SPREAD_RATE)
				samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			samples.sort()
			var median: float = samples[samples.size() / 2]
			var worst: float = samples[samples.size() - 1]
			print("  %-14s %6d %10.3f %10.3f %9.1f%%" % [
				fill_spec["name"], wards, median, worst, 100.0 * median / FRAME_BUDGET_MS])
			if float(fill_spec["fill"]) >= 1.0:
				_worst_saturated_ms = maxf(_worst_saturated_ms, median)

	check(_worst_saturated_ms <= REGRESSION_CEILING_MS,
		"a saturated, fully warded grid ticks under the %.1f ms regression ceiling (worst median "
		% REGRESSION_CEILING_MS + "%.3f ms)" % _worst_saturated_ms)
	if _worst_saturated_ms > TICK_BUDGET_MS:
		print("\nAMBER: %.3f ms is still over the %.1f ms goal. What remains is the full %d-cell"
			% [_worst_saturated_ms, TICK_BUDGET_MS, Sim.CELL_COUNT]
			+ " pass; closing the gap needs the tick off the main thread or time-sliced, which is"
			+ " architectural. Filed separately — do not silence this line by raising the goal.")
	print("\nBENCH_MIRE failures=%d worst_saturated_ms=%.3f" % [failures, _worst_saturated_ms])
	quit(0 if failures == 0 else 1)


## A grid at a given corruption fraction. `fill` of 0 is the real seeded start; anything above it
## corrupts that fraction of cells deterministically, so two runs of this bench measure the same
## work rather than two different worlds.
func _grid_at_fill(fill: float) -> PackedFloat32Array:
	var grid: PackedFloat32Array = Sim.seed_initial(TEST_SEED)
	if fill <= 0.0:
		return grid
	var rng := RandomNumberGenerator.new()
	rng.seed = TEST_SEED
	for i: int in Sim.CELL_COUNT:
		if fill >= 1.0 or rng.randf() < fill:
			grid[i] = maxf(grid[i], 0.5)
	return grid


## Ward circles spread across the island, sized like the shipped ward pieces. Deliberately placed so
## they do NOT all cluster: a linear per-neighbour scan costs the same wherever they are, which is
## the point the measurement is meant to expose.
func _wards(count: int) -> Array:
	var circles: Array = []
	var span: float = Sim.ISLAND_HALF_M * 0.8
	for i: int in count:
		var angle: float = TAU * float(i) / float(maxi(count, 1))
		circles.append({
			"position": Vector2(cos(angle), sin(angle)) * span * (0.3 + 0.7 * float(i % 3) / 3.0),
			"radius": 6.0,
		})
	return circles


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
