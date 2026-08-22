class_name MireGridSim
extends RefCounted

## Task 4.9 — the pure Mire corruption grid (docs/ARCHITECTURE.md §5).
##
## Same discipline as `world/gen/island_heightmap.gd`/`world/gen/biome_map.gd`: no nodes, no shared
## state, every function takes the grid it operates on and returns a new one. `world/mire/mire_grid.gd`
## is the autoload that owns the live authoritative array, ticks it on a timer, and replicates it —
## this file is what makes that tickable logic independently testable and, incidentally, safe to call
## from a WorkerThreadPool task the way the rest of world/gen/ already is.
##
## 256x256 cells over the same 1024m the terrain covers (`IslandHeightmap.ISLAND_RADIUS`) — one
## shared source of truth for "how big is the island" rather than a second copy of the number.

const Heightmap := preload("res://world/gen/island_heightmap.gd")

const CELLS_PER_SIDE: int = 256
const ISLAND_HALF_M: float = Heightmap.ISLAND_RADIUS
const CELL_SIZE_M: float = (ISLAND_HALF_M * 2.0) / float(CELLS_PER_SIDE)
const CELL_COUNT: int = CELLS_PER_SIDE * CELLS_PER_SIDE

## Below this, a cell is treated as clean — stops the tick loop from doing real work on residual
## float dust forever.
const MIN_CORRUPTION: float = 0.001

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

## Deterministic initial spread — task 4.9's own "Seeded spread" requirement. Independent of
## `IslandHeightmap`'s own noise salts (D-017's convention: XOR the shared seed with a per-subsystem
## constant) so retuning terrain noise can never shift where the Mire starts.
const SEED_CLUSTER_SALT: int = 0x6D97E001
## ONE. Sequoyah, 2026-08-21: "there should only be one corruption area on the map since it will
## start spreading, having more than one is too much."
##
## This was 4, and four fronts is a different game from one. A run has a single thing eating the
## island, so a player can point at it, decide to go there or away from it, and watch one edge
## advance; four overlapping fronts merge within minutes into "the ground is going bad everywhere",
## which is weather, not a threat with a location. It also gives the Mire's own art somewhere to be
## (F-445 scatters `mire_growth` only inside this seed) — one dense, unmistakable place instead of
## four thin smudges. See D-191.
const SEED_CLUSTER_COUNT: int = 1
const SEED_CLUSTER_RADIUS_M: float = 32.0
## Clusters land within this fraction of the island radius — keeps every seed off the outer taper
## the terrain falloff already thins to nothing (`IslandHeightmap.FALLOFF_START_FRACTION`).
const SEED_CLUSTER_SPAN_FRACTION: float = 0.6
## F-489. The span above is a SQUARE; the island inside it is a lobed, noisy shape, so a uniform
## draw puts the one seed cluster in open water on a fair share of seeds — unreachable, and with
## no ground under the `mire_growth` scatter that lives inside it. Every candidate centre is now
## terrain-tested: the centre itself must stand at least `SEED_LAND_MIN_CENTRE_M` above sea level,
## and eight points on a ring at `SEED_LAND_RING_FRACTION` of the cluster radius must all be above
## `SEED_LAND_MIN_RING_M`, so the patch sits on land rather than merely touching it. A river
## crossing the ring is the case the ring margin is deliberately small for: a channel through the
## Mire is fine, a Mire in the sea is not.
const SEED_LAND_ATTEMPTS: int = 48
const SEED_LAND_MIN_CENTRE_M: float = 1.0
const SEED_LAND_MIN_RING_M: float = 0.25
const SEED_LAND_RING_FRACTION: float = 0.7
const SEED_LAND_RING_SAMPLES: int = 8


## One seed's centres, memoised. `seed_cluster_centres()` is called once per generated chunk by
## `world/gen/resource_scatter.gd`, and F-489's land test made it build a `NoiseSet` and sample the
## heightmap up to a few hundred times — cheap once, absurd per chunk. Keyed by seed so a run
## restart on a new island recomputes rather than serving the old island's answer.
static var _centres_cache: PackedVector2Array = PackedVector2Array()
static var _centres_cache_seed: int = 0


static func cell_index(cell_x: int, cell_z: int) -> int:
	return cell_z * CELLS_PER_SIDE + cell_x


## World (x, z) -> the cell it falls in, clamped to the grid — a position beyond the island edge
## reads as whatever its nearest edge cell says rather than needing a sentinel every caller must
## handle.
static func world_to_cell(world_x: float, world_z: float) -> Vector2i:
	var cell_x: int = floori((world_x + ISLAND_HALF_M) / CELL_SIZE_M)
	var cell_z: int = floori((world_z + ISLAND_HALF_M) / CELL_SIZE_M)
	return Vector2i(clampi(cell_x, 0, CELLS_PER_SIDE - 1), clampi(cell_z, 0, CELLS_PER_SIDE - 1))


static func cell_to_world_center(cell_x: int, cell_z: int) -> Vector2:
	return Vector2(
		-ISLAND_HALF_M + (float(cell_x) + 0.5) * CELL_SIZE_M,
		-ISLAND_HALF_M + (float(cell_z) + 0.5) * CELL_SIZE_M
	)


## A fresh grid with `SEED_CLUSTER_COUNT` corrupted patches placed deterministically from
## `world_seed` — same (world_seed) always produces the identical grid, which is exactly what
## `tools/mire_grid_check.gd` asserts.
static func seed_initial(world_seed: int) -> PackedFloat32Array:
	var grid := PackedFloat32Array()
	grid.resize(CELL_COUNT)
	for center: Vector2 in seed_cluster_centres(world_seed):
		_stamp_cluster(grid, center.x, center.y, SEED_CLUSTER_RADIUS_M)
	return grid


## Where this seed's initial corruption clusters are centred, in world XZ.
##
## Split out of `seed_initial()` rather than copied, so there is exactly one description of where
## the Mire starts. `world/gen/resource_scatter.gd` needs the CENTRES and not the grid: it asks
## "how corrupt is this one point" a few thousand times per chunk, and answering that by building a
## 65536-cell `PackedFloat32Array` per chunk would be absurd when four centres and a distance test
## give the same answer. `seed_initial()` still walks the same list in the same order, so the two
## cannot drift.
static func seed_cluster_centres(world_seed: int) -> PackedVector2Array:
	if _centres_cache_seed == world_seed and _centres_cache.size() == SEED_CLUSTER_COUNT:
		return _centres_cache
	var centres := PackedVector2Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ SEED_CLUSTER_SALT
	var span: float = ISLAND_HALF_M * SEED_CLUSTER_SPAN_FRACTION
	var noise_set: Heightmap.NoiseSet = Heightmap.make_noise_set(world_seed)
	for _cluster_index: int in SEED_CLUSTER_COUNT:
		# Two draws per candidate, in this order — the stream shape `seed_initial()` always
		# consumed. F-489 draws it repeatedly instead of once, so a world's Mire can move
		# relative to older builds; nothing persists a centre, so that costs only reproducibility
		# against pre-F-489 screenshots.
		var best := Vector2.ZERO
		var best_score: float = -INF
		for _attempt: int in SEED_LAND_ATTEMPTS:
			var candidate := Vector2(rng.randf_range(-span, span), rng.randf_range(-span, span))
			var score: float = _land_score(candidate, noise_set, world_seed)
			if score > best_score:
				best_score = score
				best = candidate
			if score >= 0.0:
				break
		centres.append(best)
	_centres_cache_seed = world_seed
	_centres_cache = centres
	return centres


## How well a candidate centre stands on dry land: >= 0.0 means "accept", and the value itself is
## the worst margin found, so the best-of fallback picks the driest candidate when no draw clears
## the bar outright (a seed whose island is small enough that nothing does). Never returns early on
## a failure — the ranking needs the full picture, and this runs at most a few hundred times a run.
static func _land_score(centre: Vector2, noise_set: Heightmap.NoiseSet, world_seed: int) -> float:
	var centre_height: float = Heightmap.height_from_set(centre.x, centre.y, noise_set, world_seed)
	var worst: float = centre_height - SEED_LAND_MIN_CENTRE_M
	var ring_radius: float = SEED_CLUSTER_RADIUS_M * SEED_LAND_RING_FRACTION
	for sample_index: int in SEED_LAND_RING_SAMPLES:
		var angle: float = TAU * float(sample_index) / float(SEED_LAND_RING_SAMPLES)
		var point: Vector2 = centre + Vector2(cos(angle), sin(angle)) * ring_radius
		var ring_height: float = Heightmap.height_from_set(point.x, point.y, noise_set, world_seed)
		worst = minf(worst, ring_height - SEED_LAND_MIN_RING_M)
	return worst


## The corruption this seed STARTS with at a world point, without building a grid — the same
## `1 - distance / radius` cone `_stamp_cluster()` stamps, maxed across clusters.
##
## Continuous where `seed_initial()` is quantized to cell centres, and that difference is deliberate:
## the grid exists to be ticked and replicated per cell, while a caller placing individual props
## wants the smooth field, not the 1.15 m stair-step of a 256-cell grid.
##
## This is the world's INITIAL corruption and it never changes — it is not a reading of the live,
## spreading `MireGrid`. Callers that need where the Mire is *now* must ask the autoload's
## `corruption_at()`; callers that need something deterministic and identical on every peer forever
## (scatter placement, which is baked per chunk and cached) must ask this.
static func initial_corruption_at(world_x: float, world_z: float, world_seed: int) -> float:
	return initial_corruption_from_centres(
		world_x, world_z, seed_cluster_centres(world_seed))


## `initial_corruption_at()` with the centres hoisted out, for callers sampling many points against
## one seed (a chunk of scatter draws the centres once and then tests every candidate against them).
static func initial_corruption_from_centres(
	world_x: float, world_z: float, centres: PackedVector2Array
) -> float:
	var point := Vector2(world_x, world_z)
	var best: float = 0.0
	for centre: Vector2 in centres:
		var distance: float = point.distance_to(centre)
		if distance > SEED_CLUSTER_RADIUS_M:
			continue
		best = maxf(best, 1.0 - distance / SEED_CLUSTER_RADIUS_M)
	return best


static func _stamp_cluster(
	grid: PackedFloat32Array, center_x: float, center_z: float, radius_m: float
) -> void:
	var center := Vector2(center_x, center_z)
	var cell_span: int = ceili(radius_m / CELL_SIZE_M) + 1
	var center_cell: Vector2i = world_to_cell(center_x, center_z)
	for delta_z: int in range(-cell_span, cell_span + 1):
		for delta_x: int in range(-cell_span, cell_span + 1):
			var cell_x: int = center_cell.x + delta_x
			var cell_z: int = center_cell.y + delta_z
			if cell_x < 0 or cell_x >= CELLS_PER_SIDE or cell_z < 0 or cell_z >= CELLS_PER_SIDE:
				continue
			var distance: float = center.distance_to(cell_to_world_center(cell_x, cell_z))
			if distance > radius_m:
				continue
			var value: float = clampf(1.0 - distance / radius_m, 0.0, 1.0)
			var idx: int = cell_index(cell_x, cell_z)
			grid[idx] = maxf(grid[idx], value)


## One diffusion step: every corrupted cell bleeds `value * spread_rate` into each of its four
## orthogonal neighbours, additive and clamped to 1.0. Reads only from `grid` (the previous tick's
## frozen snapshot) and writes only to the returned copy, so iteration order can never change the
## result — the thing `tools/mire_grid_check.gd`'s determinism assertion depends on.
##
## `ward_circles`: `Array[Dictionary]{position: Vector2, radius: float}` — task 4.11 wires
## `BuildService.ward_radii()` through `world/mire/mire_grid.gd`'s provider seam; empty here means
## "no wards", which is what 4.9 ships with on its own.
static func tick(grid: PackedFloat32Array, ward_circles: Array, spread_rate: float) -> PackedFloat32Array:
	var next: PackedFloat32Array = grid.duplicate()
	# F-338: the ward test is resolved ONCE per tick into a per-cell mask, instead of scanning every
	# circle for every neighbour of every corrupted cell. The old shape cost
	# `corrupted x 4 x wards` distance checks — 687 ms on a saturated grid with 16 wards, a
	# 41-frame freeze on the host, and 248 ms with only four. Stamping the mask costs the sum of the
	# wards' areas, which is a few hundred cells.
	var ward_mask: PackedByteArray = _ward_mask(ward_circles)
	var warded: bool = not ward_circles.is_empty()

	# Flat index arithmetic, and the four neighbours written out. `NEIGHBOR_OFFSETS` iterated
	# `Vector2i` objects and re-derived `cell_index()` per neighbour, which in GDScript is most of
	# the per-cell cost. The ORDER is identical to the offsets table — north, south, west, east —
	# because `next[i] += spread` is float accumulation and reordering it would change results that
	# `mire_grid_check`'s determinism assertion pins.
	var row: int = 0
	for cell_z: int in CELLS_PER_SIDE:
		for cell_x: int in CELLS_PER_SIDE:
			var index: int = row + cell_x
			var value: float = grid[index]
			if value <= MIN_CORRUPTION:
				continue
			var spread: float = value * spread_rate
			if cell_z > 0:
				var n: int = index - CELLS_PER_SIDE
				if not (warded and ward_mask[n] == 1):
					next[n] = clampf(next[n] + spread, 0.0, 1.0)
			if cell_z < CELLS_PER_SIDE - 1:
				var sth: int = index + CELLS_PER_SIDE
				if not (warded and ward_mask[sth] == 1):
					next[sth] = clampf(next[sth] + spread, 0.0, 1.0)
			if cell_x > 0:
				var w: int = index - 1
				if not (warded and ward_mask[w] == 1):
					next[w] = clampf(next[w] + spread, 0.0, 1.0)
			if cell_x < CELLS_PER_SIDE - 1:
				var e: int = index + 1
				if not (warded and ward_mask[e] == 1):
					next[e] = clampf(next[e] + spread, 0.0, 1.0)
		row += CELLS_PER_SIDE
	return next


## One byte per cell, 1 where a ward covers it — the same test `_is_warded()` makes, resolved once
## per tick instead of once per (corrupted cell, neighbour, ward).
##
## Only the cells inside each circle's bounding box are examined, so this costs the wards' area
## rather than the grid's. Empty ward list returns an empty array and the caller skips the lookup
## entirely, which keeps the unwarded path free of it.
static func _ward_mask(ward_circles: Array) -> PackedByteArray:
	var mask := PackedByteArray()
	if ward_circles.is_empty():
		return mask
	mask.resize(CELL_COUNT)
	for circle: Dictionary in ward_circles:
		var radius: float = float(circle.get("radius", 0.0))
		if radius <= 0.0:
			continue
		var position: Vector2 = circle.get("position", Vector2.ZERO)
		# Bounding box in cell space, clamped to the grid. `world_to_cell` is the same mapping
		# `cell_to_world_center` inverts, so the box cannot miss a cell whose centre is in range.
		var low: Vector2i = world_to_cell(position.x - radius, position.y - radius)
		var high: Vector2i = world_to_cell(position.x + radius, position.y + radius)
		var min_x: int = maxi(low.x - 1, 0)
		var min_z: int = maxi(low.y - 1, 0)
		var max_x: int = mini(high.x + 1, CELLS_PER_SIDE - 1)
		var max_z: int = mini(high.y + 1, CELLS_PER_SIDE - 1)
		for cell_z: int in range(min_z, max_z + 1):
			for cell_x: int in range(min_x, max_x + 1):
				# The identical distance test, on the identical cell centre, so the mask and the
				# old per-neighbour scan agree cell for cell.
				if cell_to_world_center(cell_x, cell_z).distance_to(position) <= radius:
					mask[cell_index(cell_x, cell_z)] = 1
	return mask


static func _is_warded(cell_x: int, cell_z: int, ward_circles: Array) -> bool:
	if ward_circles.is_empty():
		return false
	var cell_center: Vector2 = cell_to_world_center(cell_x, cell_z)
	for circle: Dictionary in ward_circles:
		var radius: float = float(circle.get("radius", 0.0))
		if radius <= 0.0:
			continue
		var position: Vector2 = circle.get("position", Vector2.ZERO)
		if cell_center.distance_to(position) <= radius:
			return true
	return false


## docs/ENEMIES.md §3.5 — the Peatling's stain. Adds corruption in a radius, strongest at the centre
## and falling linearly to nothing at the edge, so a stain has a soft boundary the way a spill does
## rather than the hard disc a Wellspring's clear leaves.
##
## ADDITIVE and clamped, deliberately unlike `_stamp_cluster()`'s `maxf`. Two Peatlings killed on the
## same spot really have poured twice as much into it, and under `maxf` the second kill would be free
## — which would quietly make "kill them all in one place" the optimal play, the exact opposite of
## what the mechanic is for.
##
## Reads only from `grid` and writes only to the returned copy, like every other function here, so it
## cannot interact with a `tick()` in flight.
static func stain_radius(
	grid: PackedFloat32Array, world_position: Vector2, radius_m: float, amount: float
) -> PackedFloat32Array:
	var next: PackedFloat32Array = grid.duplicate()
	if radius_m <= 0.0 or amount <= 0.0:
		return next
	var cell_span: int = ceili(radius_m / CELL_SIZE_M) + 1
	var center_cell: Vector2i = world_to_cell(world_position.x, world_position.y)
	for delta_z: int in range(-cell_span, cell_span + 1):
		for delta_x: int in range(-cell_span, cell_span + 1):
			var cell_x: int = center_cell.x + delta_x
			var cell_z: int = center_cell.y + delta_z
			if cell_x < 0 or cell_x >= CELLS_PER_SIDE or cell_z < 0 or cell_z >= CELLS_PER_SIDE:
				continue
			# The cell the position is IN always takes the full amount, whatever the radius. A cell
			# is `CELL_SIZE_M` across — 4.6 m at the shipped island radius — and its CENTRE can be
			# most of that away from the position, so a stain smaller than a cell would otherwise
			# fail the distance test against every cell including its own and land nowhere at all.
			# That is not a hypothetical: it is what the first pass did, silently, and the enemy
			# whose entire identity is this mechanic simply had no effect. Radius still governs how
			# far the stain REACHES; it must never govern whether it exists.
			var is_center: bool = cell_x == center_cell.x and cell_z == center_cell.y
			var falloff: float = 1.0
			if not is_center:
				var distance: float = cell_to_world_center(cell_x, cell_z).distance_to(world_position)
				if distance > radius_m:
					continue
				falloff = 1.0 - distance / radius_m
			var idx: int = cell_index(cell_x, cell_z)
			next[idx] = clampf(next[idx] + amount * falloff, 0.0, 1.0)
	return next


## DESIGN.md §4.2: a capped Wellspring clears corruption in a radius around itself. Zeroes rather
## than subtracting — "local corruption cleared" is the exact word DESIGN uses, and a partial clear
## would just regrow from its own remaining seed on the very next tick.
static func clear_radius(
	grid: PackedFloat32Array, world_position: Vector2, radius_m: float
) -> PackedFloat32Array:
	var next: PackedFloat32Array = grid.duplicate()
	var cell_span: int = ceili(radius_m / CELL_SIZE_M) + 1
	var center_cell: Vector2i = world_to_cell(world_position.x, world_position.y)
	for delta_z: int in range(-cell_span, cell_span + 1):
		for delta_x: int in range(-cell_span, cell_span + 1):
			var cell_x: int = center_cell.x + delta_x
			var cell_z: int = center_cell.y + delta_z
			if cell_x < 0 or cell_x >= CELLS_PER_SIDE or cell_z < 0 or cell_z >= CELLS_PER_SIDE:
				continue
			if cell_to_world_center(cell_x, cell_z).distance_to(world_position) <= radius_m:
				next[cell_index(cell_x, cell_z)] = 0.0
	return next
