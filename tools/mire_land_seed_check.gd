extends SceneTree

## F-489: the initial Mire cluster must never seed in the ocean.
##
## Walks many seeds, asks `MireGridSim.seed_cluster_centres()` where the run's one corruption area
## starts, and asserts the terrain there is dry land — the centre above sea level, and a ring inside
## the cluster radius above it too. Also re-asks with the same seed to confirm the memo cache serves
## the same answer (determinism is the property every other Mire check leans on).

const MireGridSimLib := preload("res://world/mire/mire_grid_sim.gd")
const Heightmap := preload("res://world/gen/island_heightmap.gd")

const SEED_COUNT: int = 400


func _init() -> void:
	var failures: int = 0
	var worst_margin: float = INF
	for world_seed: int in range(1, SEED_COUNT + 1):
		var centres := MireGridSimLib.seed_cluster_centres(world_seed)
		if centres.size() != MireGridSimLib.SEED_CLUSTER_COUNT:
			print("FAIL seed %d: %d centres" % [world_seed, centres.size()])
			failures += 1
			continue
		if centres != MireGridSimLib.seed_cluster_centres(world_seed):
			print("FAIL seed %d: not deterministic across calls" % world_seed)
			failures += 1
		var noise_set := Heightmap.make_noise_set(world_seed)
		var centre: Vector2 = centres[0]
		var margin: float = Heightmap.height_from_set(centre.x, centre.y, noise_set, world_seed)
		for sample_index: int in 16:
			var angle: float = TAU * float(sample_index) / 16.0
			var point: Vector2 = centre + Vector2(cos(angle), sin(angle)) \
				* MireGridSimLib.SEED_CLUSTER_RADIUS_M * MireGridSimLib.SEED_LAND_RING_FRACTION
			margin = minf(margin, Heightmap.height_from_set(point.x, point.y, noise_set, world_seed))
		worst_margin = minf(worst_margin, margin)
		if margin <= 0.0:
			print("FAIL seed %d: Mire seed at (%.1f, %.1f) has %.2f m margin — in water"
				% [world_seed, centre.x, centre.y, margin])
			failures += 1
	print("seeds: %d   worst land margin: %.2f m   failures: %d"
		% [SEED_COUNT, worst_margin, failures])
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("MIRE_LAND_SEED_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
