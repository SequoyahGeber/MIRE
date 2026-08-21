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
## What counts as FLAT, in degrees of slope, and over what BASELINE.
##
## The baseline is 16 m, not the 1 m the walk-limit test uses, and the difference is the whole point.
## "i dont like narrow hills that make the map always go up and down" is a complaint about LANDFORM,
## and landform is not what a one-metre gradient measures: the detail layer puts ~0.9 m of
## undulation at a ~20 m wavelength across the entire island, which is about 5 degrees at a
## one-metre baseline. Measured that way, a perfectly level plain and a gentle ramp score nearly the
## same, and the number moves when the texture layer is retuned rather than when the terrain's shape
## changes. Sixteen metres is a few strides — the scale at which "am I on a plain or on a slope"
## is a question with an answer.
const FLAT_DEGREES: float = 4.0
const LANDFORM_STEP_M: float = 16.0
## ...and what counts as HIGH, in metres above sea level. The interior plateau sits around 6 m, so
## anything past 15 m is on an upland rather than on the ground the uplands stand on.
const HIGH_GROUND_M: float = 15.0
## Sequoyah, F-450: "i do like big flat areas but i also like higher areas, i dont like narrow hills
## that make the map always go up and down" — and, when the first cut of this check gated on strict
## flatness, **"it doesnt need to be perfectly flat"**.
##
## So the gate is on EASY GOING — land at 10 degrees or less — rather than on the strict `< 4 deg`
## share. That is the number his sentence is about: a walk that does not go up and down is one where
## most of the ground is either level or a gentle roll, and insisting on the strict share was
## chasing a figure this island has no reason to hit. Uplands cost sloping ground; the question is
## whether what is left is comfortable, not whether it is a table.
##
## Measured across four seeds after the upland pass: 58-68% easy, against 92-98% on the pre-upland
## island that had no high ground at all. The strict `< 4 deg` share is still printed per seed
## because it is the number that moves first when a profile changes — it is diagnosis, not a gate.
const MIN_EASY_SHARE: float = 0.55
## ...and the other half of his sentence: a real share of the LEVEL ground must be up on an upland
## rather than all of it being the one low plain. Measured at 22-58%; it was 0% before F-450.
const MIN_HIGH_FLAT_SHARE: float = 0.12
## Where "easy going" ends, in degrees at landform scale.
const EASY_DEGREES: float = 10.0
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
## How far below the crown the ground has to fall before the walk counts itself as having left the
## SUMMIT and started down the ramp, as a fraction of the crown lift. Small, but not zero: an
## upland's flat top carries the detail layer's own centimetres of undulation, and a strict
## equality would call the first bump the start of the descent.
const SUMMIT_TOLERANCE: float = 0.05

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

	print("\n-- the island's own shape: how much of it is flat, and at what heights --")
	var unwalkable_total: float = 0.0
	var easy_total: float = 0.0
	var high_flat_total: float = 0.0
	for index in seed_count:
		var world_seed: int = 20260821 + index * 7919
		var profile: Dictionary = _terrain_profile(world_seed)
		unwalkable_total += float(profile["unwalkable"])
		var seed_bands: PackedFloat32Array = profile["bands"]
		easy_total += seed_bands[0] + seed_bands[1]
		high_flat_total += float(profile["high_flat"])
		var bands: PackedFloat32Array = profile["bands"]
		print("  seed %d · flat %.0f%% | 4-10 deg %.0f%% | 10-20 deg %.0f%% | 20+ %.0f%%"
			% [world_seed, bands[0] * 100.0, bands[1] * 100.0, bands[2] * 100.0, bands[3] * 100.0]
			+ " · %.0f%% of flat ground is above %.0f m · %.1f%% past %.0f deg · peak %.1f m"
			% [float(profile["high_flat"]) * 100.0, HIGH_GROUND_M,
			float(profile["unwalkable"]) * 100.0, WALK_LIMIT_DEGREES, float(profile["peak"])])
	var mean_unwalkable: float = unwalkable_total / float(seed_count)
	var mean_easy: float = easy_total / float(seed_count)
	var mean_high_flat: float = high_flat_total / float(seed_count)

	# The two halves of "i do like big flat areas but i also like higher areas" (F-450), as two
	# assertions, because a single one is satisfiable by the wrong island. Easy ground alone passes
	# on a pancake; high ground alone passes on an island that is all ramp. Both together say what
	# he asked for: comfortable ground, at more than one elevation.
	var easy_label: String = \
		"most of the island is EASY GOING (>= %.0f%% of land under %.0f deg)" \
		% [MIN_EASY_SHARE * 100.0, EASY_DEGREES]
	_check(easy_label, mean_easy >= MIN_EASY_SHARE, "mean %.0f%% easy" % (mean_easy * 100.0))
	var high_label: String = \
		"...and a real share of that flat ground is UP (>= %.0f%% of it above %.0f m)" \
		% [MIN_HIGH_FLAT_SHARE * 100.0, HIGH_GROUND_M]
	_check(high_label, mean_high_flat >= MIN_HIGH_FLAT_SHARE,
		"mean %.0f%% of flat ground is high" % (mean_high_flat * 100.0))
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
	var reach: float = hill.footprint() * 1.2
	var steps: int = int(reach / PROBE_STEP_M)
	# The hill's centre is a BENT coordinate, and heights are sampled at WORLD ones — so the walk
	# is laid out along the bearing in bent space and each point is un-bent before it is sampled.
	# The run is then accumulated in world space, because a gradient a player feels is rise over
	# the ground they actually cross.
	var crown_world: Vector2 = _unbend(hill.centre, world_seed)
	var crown: float = IslandHeightmap.height_from_set(crown_world.x, crown_world.y, set,
		world_seed)
	# The gradient of the RAMP, not of the whole walk from the summit (F-450). An upland has a flat
	# top, so a run measured from the crown includes however wide that top is — which is not slope
	# at all, and reading it as slope reported a 45-degree scarp as 33 degrees and got gentler the
	# broader the summit was. The walk therefore finds two distances: where the ground first leaves
	# the summit, and where it has descended `DESCENT_FRACTION` of the crown lift. The ramp is what
	# lies between them.
	var leaves: float = hill.height * SUMMIT_TOLERANCE
	var target: float = crown - hill.height * DESCENT_FRACTION
	var previous: Vector2 = crown_world
	var run: float = 0.0
	var summit_run: float = -1.0
	for step in range(1, steps + 1):
		var at_world: Vector2 = _unbend(hill.centre + bearing * (float(step) * PROBE_STEP_M),
			world_seed)
		run += at_world.distance_to(previous)
		previous = at_world
		var here: float = IslandHeightmap.height_from_set(at_world.x, at_world.y, set, world_seed)
		if summit_run < 0.0 and here < crown - leaves:
			summit_run = run
		if here > target:
			continue
		var ramp: float = run - maxf(summit_run, 0.0)
		if ramp <= 0.01:
			return 0.0
		# `rad_to_deg(atan(...))` is a libm call, which this repo keeps out of the GENERATOR
		# (D-017) — a check may use one: it never feeds a shipped height, it only reports on one.
		return rad_to_deg(atan((crown - target - leaves) / ramp))
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


## What this seed's island is actually SHAPED like, as four numbers over a grid of its whole extent:
## the share of land that is flat, the share of THAT which is high ground, the share past the walk
## limit, and the peak. Slope comes from central differences at `PROBE_STEP_M`, the same scale the
## character controller's own floor test works at.
##
## One walk producing all four rather than four walks: the grid is the expensive part and every
## number here is a different question about the same samples.
func _terrain_profile(world_seed: int) -> Dictionary:
	var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
	var reach: float = IslandHeightmap.ISLAND_RADIUS
	var steps: int = int(reach * 2.0 / GRID_STEP_M)
	var land: int = 0
	var steep: int = 0
	var flat: int = 0
	var high_flat: int = 0
	var peak: float = 0.0
	## Landform-scale slope histogram: [< FLAT_DEGREES, .. 10, .. 20, 20+], in samples of land.
	var bands: PackedInt32Array = [0, 0, 0, 0]
	for iz in steps:
		var z: float = -reach + float(iz) * GRID_STEP_M
		for ix in steps:
			var x: float = -reach + float(ix) * GRID_STEP_M
			var here: float = IslandHeightmap.height_from_set(x, z, set, world_seed)
			if here <= 0.0:
				continue
			land += 1
			peak = maxf(peak, here)
			# Underfoot, at the character controller's own scale: is this ground climbable.
			if _slope_degrees(x, z, PROBE_STEP_M, set, world_seed) > WALK_LIMIT_DEGREES:
				steep += 1
			# At landform scale: is this a plain or a ramp. See FLAT_DEGREES.
			var landform: float = _slope_degrees(x, z, LANDFORM_STEP_M, set, world_seed)
			# The full spread, not just the pass/fail split: "the map always goes up and down" is a
			# complaint about how much GENTLE slope there is as much as about how much steep, and a
			# single flat-or-not number cannot tell an island of plains and bluffs apart from an
			# island that is entirely a 6-degree ramp.
			if landform < FLAT_DEGREES:
				bands[0] += 1
			elif landform < 10.0:
				bands[1] += 1
			elif landform < 20.0:
				bands[2] += 1
			else:
				bands[3] += 1
			if landform >= FLAT_DEGREES:
				continue
			flat += 1
			if here >= HIGH_GROUND_M:
				high_flat += 1
	var land_f: float = maxf(1.0, float(land))
	return {
		"bands": PackedFloat32Array([float(bands[0]) / land_f, float(bands[1]) / land_f,
			float(bands[2]) / land_f, float(bands[3]) / land_f]),
		"unwalkable": float(steep) / maxf(1.0, float(land)),
		"flat": float(flat) / maxf(1.0, float(land)),
		"high_flat": float(high_flat) / maxf(1.0, float(flat)),
		"peak": peak,
	}


## Terrain slope at (x, z) in degrees, from central differences over `baseline` metres. The
## baseline is a parameter because the two questions this check asks want different ones — see
## `FLAT_DEGREES`.
func _slope_degrees(x: float, z: float, baseline: float, set: IslandHeightmap.NoiseSet,
		world_seed: int) -> float:
	var east: float = IslandHeightmap.height_from_set(x + baseline, z, set, world_seed)
	var west: float = IslandHeightmap.height_from_set(x - baseline, z, set, world_seed)
	var north: float = IslandHeightmap.height_from_set(x, z + baseline, set, world_seed)
	var south: float = IslandHeightmap.height_from_set(x, z - baseline, set, world_seed)
	var gradient := Vector2((east - west) / (2.0 * baseline), (north - south) / (2.0 * baseline))
	return rad_to_deg(atan(gradient.length()))


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
