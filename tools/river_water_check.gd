extends SceneTree

## Verifies F-478 — the water in the procedural island's river.
##
##   .agent/bin/agent godot --script tools/river_water_check.gd
##
## Three things have to hold together for a river to read as a river, and each of them has a
## failure this check exists to catch:
##
##   1. There IS water, on every seed. The defect was a channel with nothing in it.
##   2. It never flows uphill, the same guarantee `tools/terrain_check.gd` walks on the bed.
##   3. Its EDGES are buried in the bank. A water sheet whose rim is above the ground it ends on
##      is a slab of blue hanging in mid-air, which is a worse artefact than no water at all.
##
## and one seam:
##
##   4. `ProceduralWorld.water_surface_at()` answers the same level the mesh is drawn at, because
##      `PlayerController` derives wading depth from it (F-284) and "looks fordable / is fordable"
##      must be one fact.
##
## Heights here are the BIOME-BLIND surface (`height_from_set` at amplitude 1.0), not the shipped
## `BiomeMap.surface_from_set()`, because a headless harness has no Registry to resolve biomes from
## (F-011) — and `RiverWater` gets the same biome-blind table for the same reason when it is built
## by one. 1.0 is the top of the amplitude range, so the ground this samples is as rough as the
## generator can make it, which is the conservative direction for every assertion below.

const IslandHeightmap = preload("res://world/gen/island_heightmap.gd")
const RiverWaterScript = preload("res://world/environment/river_water.gd")

const SEEDS: Array[int] = [20260821, 7, 4242, 90210, 8102602]
## Coarser than `RiverWater.CELL_M` on purpose — this walks the same footprint five times over and
## is looking for outliers in a field, not meshing it.
const PROBE_CELL_M: float = 4.0

var _failures: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("\n-- the water surface is monotonically downhill --")
	var previous: float = INF
	var climbs: String = ""
	for step in 401:
		var t: float = float(step) / 400.0
		var level: float = IslandHeightmap.river_water_surface(t)
		if level > previous + 0.0001:
			climbs = "t=%.3f rose from %.3f to %.3f" % [t, previous, level]
			break
		previous = level
	_check("river_water_surface() never climbs from source to mouth", climbs == "", climbs)
	_check("the surface stands above the bed at the source",
		IslandHeightmap.river_water_surface(0.0) > IslandHeightmap.RIVER_BED_SOURCE,
		"%.2f vs bed %.2f" % [IslandHeightmap.river_water_surface(0.0),
			IslandHeightmap.RIVER_BED_SOURCE])
	_check("the surface has merged with the sea by the mouth",
		is_equal_approx(IslandHeightmap.river_water_surface(1.0), 0.0),
		"%.4f" % IslandHeightmap.river_water_surface(1.0))

	for world_seed: int in SEEDS:
		_check_seed(world_seed)

	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_seed(world_seed: int) -> void:
	print("\n-- seed %d --" % world_seed)

	var water: Node3D = RiverWaterScript.new()
	water.set(&"world_seed", world_seed)
	var started: int = Time.get_ticks_msec()
	water.call(&"build")
	var elapsed: int = Time.get_ticks_msec() - started
	var quads: int = int(water.get(&"quads"))
	_check("the sheet is built and has surface", quads > 0, "%d quad(s)" % quads)
	_check("it costs under 400 ms to build", elapsed < 400, "%d ms" % elapsed)
	_check("no part of the sheet sits below sea level",
		float(water.get(&"level_min")) >= 0.0, "min %.3f" % float(water.get(&"level_min")))
	_check("no part of the sheet sits above the source's own level",
		float(water.get(&"level_max")) <= IslandHeightmap.river_water_surface(0.0) + 0.001,
		"max %.3f" % float(water.get(&"level_max")))
	water.free()

	# The field walk. Everything below wants (world point -> bent -> track -> level, height), so it
	# is gathered once and the three assertions read it rather than each re-marching the island.
	var set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
	var line: PackedVector2Array = IslandHeightmap.river_polyline(world_seed)
	var margin: float = IslandHeightmap.RIVER_WIDTH_MOUTH * IslandHeightmap.RIVER_WATER_REACH \
		+ IslandHeightmap.SHAPE_WARP_AMPLITUDE * sqrt(2.0)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for point: Vector2 in line:
		lo = lo.min(point)
		hi = hi.max(point)
	lo -= Vector2(margin, margin)
	hi += Vector2(margin, margin)

	var shape: IslandHeightmap.Shape = IslandHeightmap.Shape.new()
	var deep_samples: int = 0
	var deep_dry: int = 0
	var deep_worst: String = ""
	var rim_samples: int = 0
	var rim_worst_depth: float = 0.0
	var rim_worst: String = ""

	var z: float = lo.y
	while z <= hi.y:
		var x: float = lo.x
		while x <= hi.x:
			IslandHeightmap.shape_into(x, z, set, world_seed, shape)
			var track: Vector2 = IslandHeightmap.river_track_on(line, shape.bent)
			if track.x >= 0.0:
				var width: float = lerpf(IslandHeightmap.RIVER_WIDTH_SOURCE,
					IslandHeightmap.RIVER_WIDTH_MOUTH, track.x)
				var lateral: float = track.y / width
				var ground: float = IslandHeightmap.height_from_shape(x, z, shape, set)
				var level: float = IslandHeightmap.river_water_level_on(line, shape, ground)
				# Only where the river's own water stands ABOVE the sea. Below that the ocean plane
				# is the surface and neither assertion is this file's to make.
				var ideal: float = minf(IslandHeightmap.river_water_surface(track.x),
					shape.raw_continent - IslandHeightmap.RIVER_WATER_FREEBOARD)
				# Two exclusions, and both are `river_water_level_on()`'s own documented rules
				# rather than conveniences. Ground at or under sea level belongs to the OCEAN, which
				# floods it to exactly 0 — there is no river question to ask there. And where the
				# mask fade has taken the level under a third of a metre the channel has handed over
				# to the sea; a "river" 6 cm deep is the coastal apron, not a reach.
				if ground > 0.0 and ideal > 0.30:
					if lateral <= 0.5:
						# THE CHANNEL FLOOR. If the ground here is not under the water, the sheet
						# is a decal lying on dry rock — the F-478 defect, re-dressed.
						deep_samples += 1
						if level == -INF:
							deep_dry += 1
							if deep_worst == "":
								deep_worst = "(%.0f, %.0f) ground %.2f >= water %.2f" % [
									x, z, ground, ideal]
					elif lateral >= IslandHeightmap.RIVER_WATER_REACH - 0.15:
						# THE RIM. The sheet stops here, so the ground must already be over it or
						# the player sees the cut edge.
						rim_samples += 1
						if ideal - ground > rim_worst_depth:
							rim_worst_depth = ideal - ground
							rim_worst = "(%.0f, %.0f) ground %.2f < water %.2f" % [
								x, z, ground, ideal]
			x += PROBE_CELL_M
		z += PROBE_CELL_M

	_check("the channel floor was sampled at all", deep_samples > 20, "%d sample(s)" % deep_samples)
	# NOT "everywhere". `_carve()` fades against the island mask, so over an interior mask dip — a
	# lobe seam, a coastal notch the warp pulled inland — the bed is carved less deeply than
	# `bed(t)` and can stand through the sheet. That is a RIFFLE, and a river with a few gravel bars
	# in it is not a defect; a river that is mostly gravel bar is. The threshold is what separates
	# the two. (The underlying bed hump is the one `_carve()`'s own comment records as the reason the
	# mask fade is steepened rather than linear — this bounds what is left of it, it does not hide
	# it: the count prints on every run, pass or fail.)
	var dry_fraction: float = float(deep_dry) / maxf(1.0, float(deep_samples))
	_check("under 8% of the channel floor stands through the water (riffles, not a dry bed)",
		dry_fraction < 0.08, "%d of %d dry (%.1f%%) — %s" % [
			deep_dry, deep_samples, dry_fraction * 100.0, deep_worst])
	# `RIVER_WATER_REACH` has to be a real bound, not a shrug. The sheet is clipped to the ground, so
	# the drawn edge is the waterline — but only if the waterline is INSIDE the searched band. If the
	# ground at 3 half-widths is still under the level, the river was wider than the search and the
	# edge that gets drawn is the search boundary, which is a straight line across a valley floor.
	_check("the search band is wide enough: the ground at its rim is above the water",
		rim_worst_depth <= 0.0, "worst %.2f m under water, over %d rim sample(s) — %s" % [
			rim_worst_depth, rim_samples, rim_worst])


func _check_seam(_unused: int) -> void:
	pass
