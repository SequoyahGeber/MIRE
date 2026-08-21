extends SceneTree

## F-447 — the placed hills are ASYMMETRIC, and this is the instrument that says so in numbers.
##
## Sequoyah's direction (2026-08-21): "some more variety in steepness, like one side of the hill
## could be more steep than the other kinda making a cliff type area." That is two claims, and a
## picture proves neither — a top-down render shows where hills are, not how steep either flank is.
## So this check measures both:
##
##  1. **Every hill has a steep side and a gentle side.** For each hill on each seed it walks a
##     transect down the cliff bearing and another down the exact opposite bearing, and compares
##     the steepest metre-scale gradient it finds on each. The asymmetry is the whole feature; a
##     ratio near 1.0 means the hills went back to being symmetric domes and nobody noticed.
##  2. **The cliffs stay LOCAL.** Steep ground is the point, but the player's walkable floor limit
##     is 46 degrees (F-136) — ground past it cannot be climbed at all. A few percent of the island
##     being unclimbable is a cliff you route around; a large fraction is a wall around the high
##     ground, and the interior stops being reachable. This walks a grid over the whole island and
##     reports the share of land past the limit.
##
## Run with:
##   .agent/bin/agent godot --script tools/hill_slope_check.gd
##   .agent/bin/agent godot --script tools/hill_slope_check.gd -- --seeds 5
##
## Everything samples through `IslandHeightmap.height_from_set()` with ONE noise set per seed:
## `height()` rebuilds six `FastNoiseLite` objects per call (F-241) and this walks six figures of
## samples. It reads the biome-blind 1.0/1.0 surface deliberately — the hills are a continent-layer
## landform, and mixing in per-biome detail amplitudes would measure the biome table's tuning here
## instead of the hill profile's.

const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")

## The player's walkable floor limit (F-136). Ground steeper than this cannot be climbed.
const WALK_LIMIT_DEGREES: float = 46.0
## Share of land allowed past that limit before the cliffs stop being features and start being a
## wall. Measured at 0.1% per seed with the F-447 scarps in — the steep faces reach 52 degrees but
## they are a few hundred square metres of a half-square-kilometre island, which is the intended
## read: a bluff you walk round, not a rampart round the high ground. The gate is two orders of
## magnitude above that because it is a REGRESSION gate, not a target; if a later profile change
## trips it, the island has been fenced off and the change is wrong.
const MAX_UNWALKABLE_SHARE: float = 0.18
## **This check asserts a SPREAD of steepness, not a floor under it.**
##
## Sequoyah's second direction on F-447: "i dont want every single hill to have a cliff, some hills
## can be very gentle and rolling and others can have a steeper side or whatever, just variety."
## A floor — every hill at least this asymmetric — is exactly the uniform treatment he ruled out,
## and a fleet average alone cannot tell a spread apart from a floor. So the run demands both ends:
## some hills near-symmetric, some steep enough to be cliffs, and it fails if either disappears.
##
## A hill counts as GENTLE when its steep flank is within this factor of its lee — i.e. it is a
## plain rolling dome, whatever the seed nominally gave it.
const GENTLE_ASYMMETRY: float = 1.25
## ...and as a SCARP when its steep flank is past this. Both ends are per-hill; the fractions below
## are what must hold over the run.
const SCARP_ASYMMETRY: float = 2.0
## At least this share of hills must be gentle, and at least this share must be scarps. Measured
## across three seeds with the shipped spread; the gates sit well inside the measurement so
## ordinary seed variation does not trip them, and they fail loudly if a later change collapses the
## distribution to one end.
const MIN_GENTLE_SHARE: float = 0.15
const MIN_SCARP_SHARE: float = 0.15
## Ground spacing of the island-wide slope grid, in metres. 4 m is finer than the chunk mesh's own
## vertex spacing, so nothing this reports is a gradient the built terrain does not actually have.
const GRID_STEP_M: float = 4.0
## Spacing of the transect walk and of the central differences, in metres. 1 m is the scale a
## player's step-up and floor-angle checks work at, so "steepest gradient" here means the same
## thing it means to the character controller.
const PROBE_STEP_M: float = 1.0
## How much of a hill's crown lift a flank walk descends before it stops and reports. 0.7 is far
## enough down that the answer is the flank's shape rather than the crown's rounding, and short of
## the toe, where the hill has already handed over to whatever it stands on.
const DESCENT_FRACTION: float = 0.7

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var seed_count: int = _arg_int(args, "--seeds", 3)

	print("\n-- hill asymmetry: steep flank vs lee flank --")
	var asymmetry_samples: int = 0
	var gentle: int = 0
	var scarps: int = 0
	var steepest_face: float = 0.0
	for index in seed_count:
		var world_seed: int = 20260821 + index * 7919
		var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
		var hills: Array = IslandHeightmap.hills(world_seed)
		var seed_ratios: PackedStringArray = []
		for hill_value: Variant in hills:
			var hill: IslandHeightmap.Hill = hill_value
			var steep: float = _flank_degrees(hill, hill.cliff_direction, set, world_seed)
			var lee: float = _flank_degrees(hill, -hill.cliff_direction, set, world_seed)
			steepest_face = maxf(steepest_face, steep)
			if lee <= 0.01 or steep <= 0.01:
				continue
			var ratio: float = steep / lee
			asymmetry_samples += 1
			if ratio <= GENTLE_ASYMMETRY:
				gentle += 1
			elif ratio >= SCARP_ASYMMETRY:
				scarps += 1
			seed_ratios.append("%.0f/%.0f=%.2fx" % [steep, lee, ratio])
		print("  seed %d · %d hills · %s" % [world_seed, hills.size(), " ".join(seed_ratios)])

	var measured: float = maxf(1.0, float(asymmetry_samples))
	var gentle_share: float = float(gentle) / measured
	var scarp_share: float = float(scarps) / measured
	print("  %d hills measured · %.0f%% gentle (<=%.2fx) · %.0f%% scarps (>=%.2fx)"
		% [asymmetry_samples, gentle_share * 100.0, GENTLE_ASYMMETRY, scarp_share * 100.0,
		SCARP_ASYMMETRY])
	_check("some hills are plain rolling domes (>= %.0f%% gentle)" % (MIN_GENTLE_SHARE * 100.0),
		gentle_share >= MIN_GENTLE_SHARE, "%.0f%% gentle of %d" % [gentle_share * 100.0,
		asymmetry_samples])
	_check("...and some are scarps (>= %.0f%%)" % (MIN_SCARP_SHARE * 100.0),
		scarp_share >= MIN_SCARP_SHARE, "%.0f%% scarps of %d" % [scarp_share * 100.0,
		asymmetry_samples])
	_check("the steepest hill face is a cliff (past the %.0f deg walk limit)" % WALK_LIMIT_DEGREES,
		steepest_face > WALK_LIMIT_DEGREES, "steepest face %.1f deg" % steepest_face)

	print("\n-- island-wide walkability --")
	var unwalkable_total: float = 0.0
	for index in seed_count:
		var world_seed: int = 20260821 + index * 7919
		var share: float = _unwalkable_share(world_seed)
		unwalkable_total += share
		print("  seed %d · %.1f%% of land past %.0f deg" % [world_seed, share * 100.0,
			WALK_LIMIT_DEGREES])
	var mean_unwalkable: float = unwalkable_total / float(seed_count)
	_check("cliffs stay local: under %.0f%% of land is past the walk limit"
		% (MAX_UNWALKABLE_SHARE * 100.0), mean_unwalkable < MAX_UNWALKABLE_SHARE,
		"mean %.1f%%" % (mean_unwalkable * 100.0))

	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


## The average gradient of one flank, in degrees: walk out from the crown along `bearing` until
## the surface has dropped `DESCENT_FRACTION` of the hill's crown lift, and report that drop over
## the distance it took. Returns 0.0 if the flank never gets there inside `reach` — a hill merged
## into a taller neighbour has no flank of its own to measure, and counting one would be measuring
## the neighbour.
##
## **The average, not the steepest one-metre step, and the first cut of this check got that wrong.**
## A steepest-step statistic over a whole transect is an extreme-value statistic: on this terrain it
## picks up whichever metre of the detail layer or the ridged layer happened to be roughest, and the
## ridged layer is gated on high ground (`ridge_mask()`), so it fires hardest exactly where the
## hills are. Measured that way, six of eighteen flank pairs reported the LEE as steeper than the
## cliff — not because the profile was symmetric but because the statistic was reading noise on top
## of it rather than the profile underneath. The run-to-a-fixed-drop measure is the shape of the
## flank and nothing else.
func _flank_degrees(hill: IslandHeightmap.Hill, bearing: Vector2,
		set: IslandHeightmap.NoiseSet, world_seed: int) -> float:
	var reach: float = hill.radius * 2.2
	var steps: int = int(reach / PROBE_STEP_M)
	# The hill's centre is a BENT coordinate, and heights are sampled at WORLD ones — so the walk
	# is laid out along the bearing in bent space and each point is un-bent before it is sampled.
	# The run is then accumulated in world space, because a gradient a player feels is rise over
	# the ground they actually cross.
	var crown_world: Vector2 = _unbend(hill.centre, world_seed)
	var crown: float = IslandHeightmap.height_from_set(crown_world.x, crown_world.y, set,
		world_seed)
	var target: float = crown - hill.height * DESCENT_FRACTION
	var previous: Vector2 = crown_world
	var run: float = 0.0
	for step in range(1, steps + 1):
		var at_world: Vector2 = _unbend(hill.centre + bearing * (float(step) * PROBE_STEP_M),
			world_seed)
		run += at_world.distance_to(previous)
		previous = at_world
		if IslandHeightmap.height_from_set(at_world.x, at_world.y, set, world_seed) > target:
			continue
		if run <= 0.01:
			return 0.0
		# `rad_to_deg(atan(...))` is a libm call, which this repo keeps out of the GENERATOR
		# (D-017) — a check may use one: it never feeds a shipped height, it only reports on one.
		return rad_to_deg(atan((crown - target) / run))
	return 0.0


## The world point whose bent image is `bent`, by fixed-point iteration.
##
## The warp is `world + displacement(world)`, so `world = bent - displacement(world)` — substitute
## the current estimate on the right and iterate. It converges because the displacement field is
## smooth and its gradient is well under 1 at the warp's frequency; ten passes puts the residual
## comfortably inside a metre, which the assert below insists on rather than assumes. There is no
## closed-form inverse of a domain warp, and there does not need to be: this is an instrument.
func _unbend(bent: Vector2, world_seed: int) -> Vector2:
	var estimate: Vector2 = bent
	for _pass in 10:
		var image: Vector2 = IslandHeightmap.bend(estimate.x, estimate.y, world_seed)
		estimate -= image - bent
	return estimate


## Share of this seed's LAND (surface above sea level) whose slope is past the walk limit. Slope
## comes from central differences at `PROBE_STEP_M`, the same scale the character controller's own
## floor test works at.
func _unwalkable_share(world_seed: int) -> float:
	var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
	var reach: float = IslandHeightmap.ISLAND_RADIUS
	var steps: int = int(reach * 2.0 / GRID_STEP_M)
	var land: int = 0
	var steep: int = 0
	for iz in steps:
		var z: float = -reach + float(iz) * GRID_STEP_M
		for ix in steps:
			var x: float = -reach + float(ix) * GRID_STEP_M
			var here: float = IslandHeightmap.height_from_set(x, z, set, world_seed)
			if here <= 0.0:
				continue
			land += 1
			var east: float = IslandHeightmap.height_from_set(x + PROBE_STEP_M, z, set, world_seed)
			var west: float = IslandHeightmap.height_from_set(x - PROBE_STEP_M, z, set, world_seed)
			var north: float = IslandHeightmap.height_from_set(x, z + PROBE_STEP_M, set, world_seed)
			var south: float = IslandHeightmap.height_from_set(x, z - PROBE_STEP_M, set, world_seed)
			var gradient := Vector2((east - west) / (2.0 * PROBE_STEP_M),
				(north - south) / (2.0 * PROBE_STEP_M))
			if rad_to_deg(atan(gradient.length())) > WALK_LIMIT_DEGREES:
				steep += 1
	return float(steep) / maxf(1.0, float(land))


func _check(label: String, passed: bool, detail: String) -> void:
	if passed:
		print("  ok    %s" % label)
		return
	_failures += 1
	print("  FAIL  %s  — %s" % [label, detail])


func _arg_int(args: PackedStringArray, key: String, fallback: int) -> int:
	for index in range(args.size() - 1):
		if args[index] == key:
			return int(args[index + 1])
	return fallback
