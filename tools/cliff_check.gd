extends SceneTree

## F-464 — the river's cut through high ground must be a CLIFF, never a vertical wall.
##
##   .agent/bin/agent godot --script tools/cliff_check.gd
##
## Play reported the defect as "it just drops from the top of the hill straight down to the river
## and leaves a straight vertical wall". `world/gen/island_heightmap.gd`'s CLIFFS block has the
## mechanism; this measures the result, and it measures it the only way that cannot be gamed by
## knowing where the river is: **the steepest step anywhere on the island**, found by scanning,
## not by sampling the transects the fix was tuned on.
##
## That framing matters. The heightfield is warped, so there is no closed form for "the world-space
## points near the river" — and a check that walked the polyline in DESIGN space would be measuring
## the fix's own coordinate system. A scan has neither problem and catches a wall wherever one
## appears, including ones the river had nothing to do with (a lobe seam, a hill against the coast).
##
## Two passes, because a 1 m scan of an 800 m island is 2.5 million height samples and GDScript is
## not the language for that: a coarse pass locates the steepest neighbourhoods, then a fine pass
## re-measures each of them at [constant FINE_STEP_M]. A wall is many metres tall and cannot hide
## from the coarse pass — it is the single largest gradient on the island by construction.
##
## The verdict is on CARVED ground only — every sample the river's channel actually reaches, which
## `IslandHeightmap.Shape.channel` reports exactly, so there is no guessing and no geometry
## reconstructed here. Uncarved ground is measured too and printed as a CONTROL, the way F-372's
## bank measurements were: a number for the river's cut means nothing without the number for the
## island it cut through. The control is deliberately not asserted on: the placed hills have steep
## flanks BY DESIGN — `tools/hill_slope_check.gd` asserts that the steepest of them passes the
## 46-degree walk limit, and holding them to this file's threshold would be one check demanding the
## opposite of another. What matters here is that the river's cut is no longer the steepest thing
## on the island by 20 degrees, which is what it was.
##
## THE THRESHOLD IS NOT "gentle". A river cutting a hill is a gorge and a gorge is steep; the
## finding was never that. [constant MAX_SLOPE_DEG] is set where ground stops reading as ground:
## past it a face is a wall, and no natural slope of loose or bedded material stands there.

const IslandHeightmap = preload("res://world/gen/island_heightmap.gd")
const ChunkMesher = preload("res://world/chunk/chunk_mesher.gd")
const ResourceScatter = preload("res://world/gen/resource_scatter.gd")

## Coarse locating pass. 4 m is a quarter of the narrowest cliff face the carve can produce (the
## band is `RIVER_CORRIDOR - RIVER_BANK_HOLD` = 4 half-widths, and the narrowest half-width is 3 m),
## so a face is always several coarse cells wide.
const COARSE_STEP_M: float = 4.0
## What the verdict is actually measured at. Deliberately finer than the ~1 m facet the mesher
## builds: the player walks on the mesh, and a step the mesh cannot represent is not one they can
## fall down. Anything finer than this is measuring the generator, not the game.
const FINE_STEP_M: float = 0.75
## How many coarse neighbourhoods get re-measured, and how far around each.
const CANDIDATES: int = 48
const CANDIDATE_RADIUS_M: float = 10.0
## Ground stops reading as ground here. 60 degrees is the shipped stream bank F-372 measured before
## its retune and called "a random ravine"; a cliff is allowed to be steeper than that, because a
## cliff is what it is meant to be. Vertical is not.
const MAX_SLOPE_DEG: float = 72.0
## Sea level. Below it the seabed's own falloff is not a slope anybody stands on, and the ocean
## floor drop is deliberately steep — measuring it would be measuring OCEAN_FLOOR_DEPTH.
const MIN_HEIGHT_M: float = 0.2

## Bare rock has to stay a LANDFORM, not a colour the island wears. `ChunkMesher._rock_exposure()`
## paints anything past its slope thresholds, and those thresholds are tuned by eye against a render
## — which is exactly the kind of tuning that drifts until half the island is grey and nobody
## noticed it happening one degree at a time. So the coverage is asserted, in the same spirit as
## `hill_slope_check`'s "cliffs stay local: under 18% of land is past the walk limit".
##
## Measured on the same coarse grid, over LAND only, at the same slope thresholds the mesher uses —
## read from `ChunkMesher` rather than copied, so retuning them there moves this measurement with
## them and can only fail on the COVERAGE, which is the property that actually matters.
const MAX_ROCK_SHARE: float = 0.14

const SEEDS: Array[int] = [20260818, 8102602, 4242, 90210]

var _failures: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


## Reused across every sample rather than allocated per point — the same rule `ChunkMesher` follows,
## and at ~700k samples a run the allocation is most of the cost.
var _shape := IslandHeightmap.Shape.new()
## Set by `_slope_deg()`: was the sample inside the river's channel?
var _carved: bool = false


## Steepest of the two axis-aligned steps out of (x, z), in degrees, or -1.0 where the point is
## under water (see MIN_HEIGHT_M). Sets `_carved`.
func _slope_deg(x: float, z: float, step: float, set: IslandHeightmap.NoiseSet,
		world_seed: int) -> float:
	IslandHeightmap.shape_into(x, z, set, world_seed, _shape)
	_carved = _shape.channel.y > 0.0
	var here: float = IslandHeightmap.height_from_shape(x, z, _shape, set)
	if here < MIN_HEIGHT_M:
		return -1.0
	var east: float = IslandHeightmap.height_from_set(x + step, z, set, world_seed)
	var north: float = IslandHeightmap.height_from_set(x, z + step, set, world_seed)
	var rise: float = maxf(absf(east - here), absf(north - here))
	return rad_to_deg(atan2(rise, step))


func _initialize() -> void:
	print("\n-- F-464 · the steepest ground on the island --")
	var radius: float = IslandHeightmap.world_radius()
	for world_seed: int in SEEDS:
		var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)

		# Coarse pass: every cell's slope, keeping the steepest CANDIDATES of them.
		var hot_x := PackedFloat32Array()
		var hot_z := PackedFloat32Array()
		var hot_deg := PackedFloat32Array()
		var floor_deg: float = 0.0
		var control_deg: float = 0.0
		var rocky: int = 0
		var samples: int = 0
		var slope_sum: float = 0.0
		var x: float = -radius
		while x <= radius:
			var z: float = -radius
			while z <= radius:
				var deg: float = _slope_deg(x, z, COARSE_STEP_M, set, world_seed)
				var carved: bool = _carved
				z += COARSE_STEP_M
				if deg < 0.0:
					continue
				samples += 1
				slope_sum += deg
				# `cos()` of the slope IS the y of the unit normal the mesher reads, so this asks
				# `_rock_exposure()` the same question with the same units.
				if ChunkMesher._rock_exposure(cos(deg_to_rad(deg))) > 0.5:
					rocky += 1
				if not carved:
					control_deg = maxf(control_deg, deg)
					continue
				if deg <= floor_deg and hot_deg.size() >= CANDIDATES:
					continue
				hot_x.append(x)
				hot_z.append(z - COARSE_STEP_M)
				hot_deg.append(deg)
				if hot_deg.size() > CANDIDATES * 4:
					# Compaction rather than an insertion sort: appending is O(1) and this runs
					# once per few thousand cells, where a sorted insert runs on every one.
					var order: Array = _order_by_slope(hot_deg)
					hot_x = _take(hot_x, order, CANDIDATES)
					hot_z = _take(hot_z, order, CANDIDATES)
					hot_deg = _take(hot_deg, order, CANDIDATES)
					floor_deg = hot_deg[hot_deg.size() - 1]
			x += COARSE_STEP_M
		var order_final: Array = _order_by_slope(hot_deg)
		hot_x = _take(hot_x, order_final, CANDIDATES)
		hot_z = _take(hot_z, order_final, CANDIDATES)

		# Fine pass over each hot neighbourhood.
		var worst: float = 0.0
		var worst_at := Vector2.ZERO
		for i in range(hot_x.size()):
			var fx: float = hot_x[i] - CANDIDATE_RADIUS_M
			while fx <= hot_x[i] + CANDIDATE_RADIUS_M:
				var fz: float = hot_z[i] - CANDIDATE_RADIUS_M
				while fz <= hot_z[i] + CANDIDATE_RADIUS_M:
					var deg: float = _slope_deg(fx, fz, FINE_STEP_M, set, world_seed)
					if deg > worst and _carved:
						worst = deg
						worst_at = Vector2(fx, fz)
					fz += FINE_STEP_M
				fx += FINE_STEP_M
		var mean: float = slope_sum / maxf(float(samples), 1.0)
		print(("  seed %d — steepest CARVED %.1f deg at (%.0f, %.0f);"
			+ " control (uncarved, coarse) %.1f deg; island mean %.1f deg over %d cells")
			% [world_seed, worst, worst_at.x, worst_at.y, control_deg, mean, samples])
		_check("seed %d: the river's cut stays under %.0f deg" % [world_seed, MAX_SLOPE_DEG],
			worst < MAX_SLOPE_DEG,
			"measured %.1f deg at (%.0f, %.0f)" % [worst, worst_at.x, worst_at.y])
		var rock_share: float = float(rocky) / maxf(float(samples), 1.0)
		_check("seed %d: bare rock stays a landform — %.1f%% of land (limit %.0f%%)"
			% [world_seed, rock_share * 100.0, MAX_ROCK_SHARE * 100.0],
			rock_share < MAX_ROCK_SHARE)

	_check_rubble_lands()

	print("\n%d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)


## F-464's other half: A-016a's rock actually reaching the island.
##
## Until this, `terrain_accents` appeared in exactly one script in the repo — its own build check —
## so six authored cliff assets existed and none of them had ever been placed. `cliff_rubble` is the
## table that places them, and what makes it possible is F-471's slope gate, so this asserts the two
## together: the table has to survive validation, and it has to put something on real ground.
##
## Content is loaded directly rather than through `Registry`, because a `--script` harness's
## `_initialize()` runs before autoloads are ready (F-011) and this check has no reason to become
## asynchronous over a `load()`.
func _check_rubble_lands() -> void:
	print("\n-- F-464 · the cliff table reaches the island --")
	var def: Resource = load("res://content/scatter/cliff_rubble.tres")
	if def == null:
		_check("cliff_rubble.tres loads", false)
		return
	var errors: PackedStringArray = def.call(&"validation_errors")
	_check("cliff_rubble passes ScatterDef validation", errors.is_empty(), ", ".join(errors))

	var biome_defs: Array = []
	for file: String in (DirAccess.get_files_at("res://content/biomes") as PackedStringArray):
		if file.ends_with(".tres"):
			biome_defs.append(load("res://content/biomes/%s" % file))

	# Around the steepest carved point found above, which is where a cliff table is supposed to
	# work. A sweep of the whole island would prove less: a table with no slope gate at all would
	# also pass that, by dressing the meadows.
	for world_seed: int in SEEDS:
		var placed: int = 0
		var chunks: int = 0
		for cx in range(-6, 7):
			for cz in range(-6, 7):
				chunks += 1
				var list: Array = ResourceScatter.placements_for_chunk(
					cx, cz, world_seed, [def], biome_defs)
				placed += list.size()
		_check("seed %d: cliff_rubble places rock (%d piece(s) over %d chunks)"
			% [world_seed, placed, chunks], placed > 0)


## Indices of `values`, steepest first.
func _order_by_slope(values: PackedFloat32Array) -> Array:
	var order: Array = []
	for i in range(values.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return values[a] > values[b])
	return order


func _take(values: PackedFloat32Array, order: Array, count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in range(mini(count, order.size())):
		out.append(values[order[i]])
	return out
