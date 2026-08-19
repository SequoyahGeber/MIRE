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
const SEED_CLUSTER_COUNT: int = 4
const SEED_CLUSTER_RADIUS_M: float = 32.0
## Clusters land within this fraction of the island radius — keeps every seed off the outer taper
## the terrain falloff already thins to nothing (`IslandHeightmap.FALLOFF_START_FRACTION`).
const SEED_CLUSTER_SPAN_FRACTION: float = 0.6


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
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ SEED_CLUSTER_SALT
	var span: float = ISLAND_HALF_M * SEED_CLUSTER_SPAN_FRACTION
	for _cluster_index: int in SEED_CLUSTER_COUNT:
		var center_x: float = rng.randf_range(-span, span)
		var center_z: float = rng.randf_range(-span, span)
		_stamp_cluster(grid, center_x, center_z, SEED_CLUSTER_RADIUS_M)
	return grid


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
	for cell_z: int in CELLS_PER_SIDE:
		for cell_x: int in CELLS_PER_SIDE:
			var value: float = grid[cell_index(cell_x, cell_z)]
			if value <= MIN_CORRUPTION:
				continue
			var spread: float = value * spread_rate
			for offset: Vector2i in NEIGHBOR_OFFSETS:
				var neighbor_x: int = cell_x + offset.x
				var neighbor_z: int = cell_z + offset.y
				if neighbor_x < 0 or neighbor_x >= CELLS_PER_SIDE \
						or neighbor_z < 0 or neighbor_z >= CELLS_PER_SIDE:
					continue
				if _is_warded(neighbor_x, neighbor_z, ward_circles):
					continue
				var neighbor_idx: int = cell_index(neighbor_x, neighbor_z)
				next[neighbor_idx] = clampf(next[neighbor_idx] + spread, 0.0, 1.0)
	return next


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
