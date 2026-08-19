extends Node

## MireGrid — autoload. Task 4.9 (docs/ARCHITECTURE.md §5): the live, ticking corruption grid.
##
## NETWORK AUTHORITY (ARCHITECTURE.md §2.2, "Mire grid" row): HOST. Only the host ever calls
## `MireGridSim.seed_initial()`/`tick()`/`clear_radius()` — see `_owns_simulation()`, the same gate
## every other world-mutation seam in this project uses. A client never simulates; it only ever reads
## corruption back through `WorldDeltaLog`'s replicated deltas (task 4.6). **This is deliberately not
## a new RPC.** `autoload/world_delta_log.gd`'s own doc comment names the Mire grid as "this log's
## next intended consumer, same per-cell-keyed-by-chunk shape, a different kind" — `KIND` below is
## that kind. Reusing it means this task needs neither a new RPC pair nor a `PROTOCOL_VERSION` bump.
##
## §5a's accumulator rule applies: `_elapsed` accumulates real `delta` and the `while` loop below
## runs however many 2s ticks that time owes, never tying the spread rate to frame rate.
##
## Ward resistance (task 4.11's own consumer, ARCHITECTURE.md §5's "Wards resist accumulation in a
## radius"): `MireGridSim.tick()` takes a `ward_circles` array so the mechanism lives in one place,
## but this file only ever calls it with whatever `_ward_circles_provider` returns — empty (no
## wards) until `set_ward_circles_provider()` is wired, which is 4.11's job, not this one's.

const SIM := preload("res://world/mire/mire_grid_sim.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")
## `ChunkMesher` is a `class_name` — preloaded rather than referenced bare, or a fresh headless clone
## cannot resolve it inside a `--script` harness (F-016).
const ChunkMesherScript := preload("res://world/chunk/chunk_mesher.gd")

## `WorldDeltaLog`'s `kind` for every record this file writes.
const KIND: StringName = &"mire"
const TICK_INTERVAL_SEC: float = 2.0
## Placeholder-tuned, same status as `IslandHeightmap.HEIGHT_SCALE`. ARCHITECTURE.md §5 calls for
## "the current Cycle's rate" — task 6.1's `CycleService` now supplies the Cycle half of that via
## `set_cycle_spread_multiplier()` (`_cycle_spread_multiplier` below); this constant is still the
## un-escalated Cycle-1 base and still wants a real playtest to tune it.
const BASE_SPREAD_RATE: float = 0.06
## DESIGN.md §4.2: a Wellspring cap "reduces global spread rate" alongside its own local clear. No
## fixed fraction is written down anywhere else, so each additional cap this run further multiplies
## the effective rate by this factor (three caps: ~0.61x).
const SPREAD_REDUCTION_PER_CAP: float = 0.85
## Metres cleared to zero around a Wellspring the instant it caps.
const WELLSPRING_CLEAR_RADIUS_M: float = 48.0
## A cell must move by at least this much since its last broadcast value before a new
## `WorldDeltaLog.host_record` is worth sending — R4 (ARCHITECTURE.md risk register): "Mire grid
## replication too chatty at scale." Quantizing here is this task's answer to that risk.
const EMIT_QUANTUM: float = 0.02

var _grid: PackedFloat32Array = PackedFloat32Array()
var _last_emitted: PackedFloat32Array = PackedFloat32Array()
var _elapsed: float = 0.0
var _capped_wellsprings: int = 0
var _seeded: bool = false
## () -> Array[Dictionary]{position: Vector2, radius: float}. Unset (no wards) until 4.11 calls
## `set_ward_circles_provider()`.
var _ward_circles_provider: Callable = Callable()
## Task 6.1's "Mire base spread rate increases, permanently" (DESIGN.md §5.1). Multiplies
## BASE_SPREAD_RATE alongside the existing per-Wellspring-cap reduction; 1.0 (never set) is 4.9's
## own shipped behaviour, unchanged until `CycleService` calls `set_cycle_spread_multiplier()`.
var _cycle_spread_multiplier: float = 1.0


func _ready() -> void:
	set_physics_process(true)
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.subscribe_wellspring_recorrupted(_on_wellspring_recorrupted)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.unsubscribe_wellspring_recorrupted(_on_wellspring_recorrupted)


func _physics_process(delta: float) -> void:
	if not _owns_simulation():
		return
	ensure_ready()
	_elapsed += delta
	while _elapsed >= TICK_INTERVAL_SEC:
		_elapsed -= TICK_INTERVAL_SEC
		_tick()


## Forces deterministic seeding without waiting for a physics tick — real gameplay never needs to
## call this (the first `_physics_process` does it), but a headless check driving this file directly
## does. Safe to call repeatedly; only the first call does anything.
func ensure_ready() -> void:
	if _seeded or not _owns_simulation():
		return
	_seeded = true
	var game_state: Node = get_node_or_null(^"/root/GameState")
	var world_seed: int = int(game_state.call("ensure_seed")) if game_state != null else 0
	_grid = SIM.seed_initial(world_seed)
	_last_emitted = PackedFloat32Array()
	_last_emitted.resize(SIM.CELL_COUNT)
	_emit_changed_deltas()


## The current value (0..1, clean to fully corrupted) at a world position — every 4.11 consumer's
## entry point. Works on any peer: the host reads its own live simulation directly, a client reads
## whatever `WorldDeltaLog` has told it, which is exactly what makes "client never simulates"
## something other than an accident — there is nothing here FOR a client to simulate.
func corruption_at(world_position: Vector3) -> float:
	var cell: Vector2i = SIM.world_to_cell(world_position.x, world_position.z)
	if _owns_simulation():
		if _grid.is_empty():
			return 0.0
		return _grid[SIM.cell_index(cell.x, cell.y)]
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log == null:
		return 0.0
	var chunk: Vector2i = _chunk_for_cell(cell)
	var key: String = "%d:%d" % [cell.x, cell.y]
	return float(world_delta_log.call("latest", chunk, KIND, key, 0.0))


func is_corrupted(world_position: Vector3, threshold: float = 0.05) -> bool:
	return corruption_at(world_position) >= threshold


## Injected by 4.11: `() -> Array[Dictionary]{position: Vector2, radius: float}`, called once per
## tick. Left unset, `_tick()` passes an empty array through — no wards, exactly 4.9's own shipped
## behaviour.
func set_ward_circles_provider(provider: Callable) -> void:
	_ward_circles_provider = provider


## Host-only seam for task 6.1's `CycleService`: escalates the base spread rate a Cycle at a time.
## Takes effect on the NEXT tick, same "read once, applied going forward" shape every other
## Cycle-driven knob in this project uses.
func set_cycle_spread_multiplier(multiplier: float) -> void:
	_cycle_spread_multiplier = multiplier


## Host-only test/debug seam: sets one cell directly, bypassing the real diffusion. Real gameplay
## never calls this — checks use it to set up a known corruption level without waiting on `_tick()`'s
## actual spread to arrive there on its own.
func host_set_corruption_at(world_position: Vector3, value: float) -> void:
	if not _owns_simulation():
		return
	ensure_ready()
	var cell: Vector2i = SIM.world_to_cell(world_position.x, world_position.z)
	_grid[SIM.cell_index(cell.x, cell.y)] = clampf(value, 0.0, 1.0)


## Host-only: publishes whatever `host_set_corruption_at()`/`_tick()` changed since the last flush.
## `_tick()` already calls this itself; exposed so a check can force an immediate broadcast after
## `host_set_corruption_at()` without waiting a full `TICK_INTERVAL_SEC`.
func flush_deltas() -> void:
	if not _owns_simulation():
		return
	_emit_changed_deltas()


func capped_wellspring_count() -> int:
	return _capped_wellsprings


func _tick() -> void:
	var wards: Array = _ward_circles_provider.call() if _ward_circles_provider.is_valid() else []
	var rate: float = BASE_SPREAD_RATE * _cycle_spread_multiplier
	for _cap_index: int in _capped_wellsprings:
		rate *= SPREAD_REDUCTION_PER_CAP
	_grid = SIM.tick(_grid, wards, rate)
	_emit_changed_deltas()


func _on_wellspring_capped(_wellspring_name: StringName, world_position: Vector3) -> void:
	if not _owns_simulation() or _grid.is_empty():
		return
	_grid = SIM.clear_radius(_grid, Vector2(world_position.x, world_position.z), WELLSPRING_CLEAR_RADIUS_M)
	_capped_wellsprings += 1
	_emit_changed_deltas()


## Task 6.4's symmetric half of `_on_wellspring_capped()`: a Wellspring that fully re-corrupts stops
## helping, so its spread-rate reduction comes back off `_tick()`'s multiplier. No radius re-seed
## here — `clear_radius()` only zeroed the cells, it never froze them, so `_tick()`'s own flood-fill
## already regrows the circle from its still-corrupted edge inward once the multiplier lifts, the
## same mechanic every other cleared cell on the map uses. Never negative: `_capped_wellsprings`
## tracks a real count, and a stray extra recorruption event must not push it below zero.
func _on_wellspring_recorrupted(_wellspring_name: StringName, _world_position: Vector3) -> void:
	if not _owns_simulation():
		return
	_capped_wellsprings = maxi(_capped_wellsprings - 1, 0)


func _emit_changed_deltas() -> void:
	if _grid.is_empty():
		return
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log == null:
		return
	for cell_z: int in SIM.CELLS_PER_SIDE:
		for cell_x: int in SIM.CELLS_PER_SIDE:
			var idx: int = SIM.cell_index(cell_x, cell_z)
			var value: float = _grid[idx]
			if absf(value - _last_emitted[idx]) < EMIT_QUANTUM:
				continue
			_last_emitted[idx] = value
			var chunk: Vector2i = _chunk_for_cell(Vector2i(cell_x, cell_z))
			world_delta_log.call("host_record", chunk, KIND, "%d:%d" % [cell_x, cell_z], value)


func _chunk_for_cell(cell: Vector2i) -> Vector2i:
	var world: Vector2 = SIM.cell_to_world_center(cell.x, cell.y)
	var chunk_size: float = float(ChunkMesherScript.CHUNK_SIZE)
	return Vector2i(floori(world.x / chunk_size), floori(world.y / chunk_size))


func _owns_simulation() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
