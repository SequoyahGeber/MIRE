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
##
## F-368: this is a per-cell, per-tick fraction, and `MireGridSim.CELL_SIZE_M` is derived from
## `IslandHeightmap.ISLAND_RADIUS` over a FIXED 256x256 grid. So growing the island coarsens the
## cells and, at a fixed rate, silently speeds the Mire up in METRES per second — the units a player
## experiences it in. Raising the radius 2.5x would have made F-350 ("saturates the whole island in
## 30 minutes") two and a half times worse as a side effect of a terrain change, which is exactly
## the kind of coupling nobody would think to look for later.
##
## So the authored number is normalised against the cell size it was tuned at. `_TUNED_CELL_SIZE_M`
## is what `CELL_SIZE_M` evaluated to at `ISLAND_RADIUS` 118 (236 m / 256 cells), and the ratio holds
## the front's advance constant in metres per second across any future radius change. Retune
## `_AUTHORED_SPREAD_RATE`, never the product.
const _AUTHORED_SPREAD_RATE: float = 0.06
const _TUNED_CELL_SIZE_M: float = 236.0 / 256.0
const BASE_SPREAD_RATE: float = _AUTHORED_SPREAD_RATE * (_TUNED_CELL_SIZE_M / SIM.CELL_SIZE_M)
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

## ---------------------------------------------------------------------------------------------
## F-435 · THE CORRUPTION FIELD AS A TEXTURE.
##
## Sequoyah, from play: "the tainted ground that starts damaging you has no indication that it's
## different." It did not, anywhere in the 3D world — `PlayerHealth._tick_blight()` reads
## `corruption_at()` per player per physics tick and F-349's HUD vignette tells you the ground you
## are ALREADY standing on is hurting you. Nothing said so at a distance.
##
## `corruption_at()` cannot be the answer for a look: it is one GDScript call per position, and a
## shader needs the value at every fragment of ground within view. So the grid is also published as
## a 256x256 single-channel texture in world space, which any shader can sample for the price of one
## fetch. `world/chunk/terrain_flat.gdshader` (purple ground) and
## `world/environment/ground_fog.gdshader` (low yellow-green mist) are its two consumers.
##
## R8, not RF: `EMIT_QUANTUM` is 0.02, so the replicated field itself only carries ~50 distinguishable
## levels and eight bits is already twice the precision that survives the wire. 64 KB resident
## instead of 256 KB, and every low-end GPU samples it at full rate.
##
## WHY THE MIRROR EXISTS. The host has `_grid`. A client never simulates and has no grid at all —
## `corruption_at()` answers it a cell at a time out of `WorldDeltaLog`, which is fine for one query
## per tick and hopeless for 65,536 of them every refresh. So a client keeps `_field_grid`, fed
## incrementally by `delta_applied` and rebuilt wholesale on `snapshot_applied` (the late-join
## catch-up and the run reseed both replace `_state` without replaying deltas — F-435's own addition
## to `world_delta_log.gd`). The host leaves `_field_grid` empty and reads `_grid` directly; there is
## exactly one grid on each peer either way.
## ---------------------------------------------------------------------------------------------

const FIELD_CELLS: int = SIM.CELLS_PER_SIDE
## How often the texture is re-uploaded, at most. The simulation only moves on `TICK_INTERVAL_SEC`
## (2 s) so anything faster than this is upload cost for a field that did not change; anything slower
## and a Wellspring cap's 48 m clear visibly lags the sound of it.
const FIELD_REFRESH_SEC: float = 0.25

## The published field. `_field_image` is the CPU side, reused every refresh — `Image.create()` per
## refresh would allocate 64 KB four times a second for the whole run.
var _field_image: Image
var _field_texture: ImageTexture
## Client-side mirror only; empty on the host, which reads `_grid`. See the header above.
var _field_grid: PackedFloat32Array = PackedFloat32Array()
var _field_dirty: bool = true
var _field_elapsed: float = 0.0

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
	# F-435. `_process`, not `_physics_process`: the texture refresh must run on a CLIENT too, and
	# `_physics_process()` above returns immediately on one by design.
	set_process(true)
	_build_field_texture()
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		world_delta_log.connect(&"delta_applied", _on_delta_applied)
		world_delta_log.connect(&"snapshot_applied", _on_snapshot_applied)
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.subscribe_wellspring_recorrupted(_on_wellspring_recorrupted)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)


func _exit_tree() -> void:
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		if world_delta_log.is_connected(&"delta_applied", _on_delta_applied):
			world_delta_log.disconnect(&"delta_applied", _on_delta_applied)
		if world_delta_log.is_connected(&"snapshot_applied", _on_snapshot_applied):
			world_delta_log.disconnect(&"snapshot_applied", _on_snapshot_applied)
	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.unsubscribe_wellspring_recorrupted(_on_wellspring_recorrupted)
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


func _physics_process(delta: float) -> void:
	if not _owns_simulation():
		return
	ensure_ready()
	_elapsed += delta
	while _elapsed >= TICK_INTERVAL_SEC:
		_elapsed -= TICK_INTERVAL_SEC
		_tick()


## F-435. Refresh cadence only — the DECISION about whether anything changed is `_field_dirty`, so a
## standing-still run with a saturated grid uploads nothing at all.
func _process(delta: float) -> void:
	_field_elapsed += delta
	if _field_elapsed < FIELD_REFRESH_SEC:
		return
	_field_elapsed = 0.0
	if not _field_dirty:
		return
	_field_dirty = false
	_upload_field_texture()


## F-435's public seam. The returned texture is STABLE for the lifetime of this autoload — the image
## behind it is re-uploaded in place — so a consumer binds it to a material once and never re-reads
## it. Never null: it exists from `_ready()`, black (= clean everywhere) until a grid does.
func corruption_field_texture() -> Texture2D:
	return _field_texture


## Half the width of the field in metres, i.e. the world X/Z that maps to the texture's edge. A
## shader wants `(world.xz + half) / (2 * half)` for its UV. Exposed rather than duplicated as a
## shader constant so the field cannot silently stop lining up with the terrain when
## `IslandHeightmap.ISLAND_RADIUS` moves (F-368 is the same coupling, one layer down).
func corruption_field_half_extent() -> float:
	return SIM.ISLAND_HALF_M


func _build_field_texture() -> void:
	_field_image = Image.create_empty(FIELD_CELLS, FIELD_CELLS, false, Image.FORMAT_R8)
	_field_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_field_texture = ImageTexture.create_from_image(_field_image)


## Writes whichever grid this peer actually has into `_field_image` and pushes it to the GPU.
##
## `set_pixel` per cell would be 65,536 Variant-boxed calls; the raw byte buffer is one allocation
## and a tight loop, and `Image.set_data()` on the SAME dimensions and format reuses the image's
## existing storage. `update()` (not `set_image()`) keeps the RID, which is what makes the texture
## returned by `corruption_field_texture()` safe to bind once.
func _upload_field_texture() -> void:
	if _field_image == null or _field_texture == null:
		return
	var source: PackedFloat32Array = _grid if _owns_simulation() else _field_grid
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(SIM.CELL_COUNT)
	if source.size() == SIM.CELL_COUNT:
		for idx: int in SIM.CELL_COUNT:
			bytes[idx] = int(clampf(source[idx], 0.0, 1.0) * 255.0)
	_field_image.set_data(FIELD_CELLS, FIELD_CELLS, false, Image.FORMAT_R8, bytes)
	_field_texture.update(_field_image)


## Client-side mirror maintenance. Filtered on `KIND` first because this signal carries every kind
## of world delta in the project (harvest depletion, building state) and the Mire is the chattiest
## of them by two orders of magnitude — this handler runs on all of them.
func _on_delta_applied(_chunk: Vector2i, kind: StringName, key: String, value: Variant) -> void:
	if kind != KIND or _owns_simulation():
		return
	var separator: int = key.find(":")
	if separator <= 0:
		return
	var cell_x: int = key.substr(0, separator).to_int()
	var cell_z: int = key.substr(separator + 1).to_int()
	if cell_x < 0 or cell_x >= FIELD_CELLS or cell_z < 0 or cell_z >= FIELD_CELLS:
		return
	if _field_grid.size() != SIM.CELL_COUNT:
		_field_grid.resize(SIM.CELL_COUNT)
	_field_grid[SIM.cell_index(cell_x, cell_z)] = clampf(float(value), 0.0, 1.0)
	_field_dirty = true


## The log replaced itself wholesale (late-join snapshot, or a run reseed) — see
## `WorldDeltaLog.snapshot_applied`. Nothing incremental arrives for what it brought in, so the
## mirror is rebuilt from scratch. Costs one pass over the log's own mire entries, and happens twice
## per run at most.
func _on_snapshot_applied() -> void:
	if _owns_simulation():
		return
	_field_grid = PackedFloat32Array()
	_field_grid.resize(SIM.CELL_COUNT)
	_field_dirty = true
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log == null:
		return
	# The log is keyed by chunk, and the Mire's cells are spread across every chunk the island
	# covers, so this walks the cells and asks for each rather than trying to enumerate chunks.
	for cell_z: int in FIELD_CELLS:
		for cell_x: int in FIELD_CELLS:
			var chunk: Vector2i = _chunk_for_cell(Vector2i(cell_x, cell_z))
			var value: float = float(world_delta_log.call(
				"latest", chunk, KIND, "%d:%d" % [cell_x, cell_z], 0.0))
			_field_grid[SIM.cell_index(cell_x, cell_z)] = clampf(value, 0.0, 1.0)


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
	_field_dirty = true
	_last_emitted = PackedFloat32Array()
	_last_emitted.resize(SIM.CELL_COUNT)
	_emit_changed_deltas()


## F-243: re-seeds a clean grid for a new run, by letting `ensure_ready()` run a second time — no new
## seeding logic of its own. F-258/D-161 changed what that produces without changing a line here:
## `ensure_ready()` reads the seed through `GameState.ensure_seed()` at call time, and the restart has
## already drawn a fresh one by the time `run_restarted` reaches this handler, so the second run gets
## the NEW island's initial corruption rather than a replay of the run that just ended. Host-only, self-guarded, so every peer's own `EVENT_BUS.run_restarted` handler
## can call this unconditionally; a client's own copy simply no-ops and waits for the re-broadcast
## deltas `ensure_ready()`'s own `_emit_changed_deltas()` sends.
func host_reset() -> void:
	if not _owns_simulation():
		return
	_seeded = false
	_capped_wellsprings = 0
	_elapsed = 0.0
	_cycle_spread_multiplier = 1.0
	ensure_ready()


func _on_run_restarted() -> void:
	host_reset()


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
	_field_dirty = true


## Host-only: publishes whatever `host_set_corruption_at()`/`_tick()` changed since the last flush.
## `_tick()` already calls this itself; exposed so a check can force an immediate broadcast after
## `host_set_corruption_at()` without waiting a full `TICK_INTERVAL_SEC`.
func flush_deltas() -> void:
	if not _owns_simulation():
		return
	_emit_changed_deltas()


func capped_wellspring_count() -> int:
	return _capped_wellsprings


## Host-only: what fraction of the whole grid is at or above [param threshold] corruption. Task
## 6.7's own consumer — `DefeatService` polls this to decide "the Mire consumes the island"
## (DESIGN.md §5.3). Returns 0.0 before the grid is seeded and on a client, which never simulates
## and has no reason to decide this itself (the host's verdict replicates to it instead).
func consumed_fraction(threshold: float) -> float:
	if not _owns_simulation() or _grid.is_empty():
		return 0.0
	var count: int = 0
	for value: float in _grid:
		if value >= threshold:
			count += 1
	return float(count) / float(_grid.size())


func _tick() -> void:
	# Cycle Modifier `rooted` (F-245, content/cycle_modifiers/rooted.tres: "the Mire no longer
	# recedes anywhere a Ward stands"). `_is_warded()` in mire_grid_sim.gd is the ONLY thing a Ward
	# does here — it resists this tick's spread from reaching warded cells, never actively shrinks
	# existing corruption (only a capped Wellspring's `clear_radius()` does that). Passing an empty
	# array while `rooted` is active reproduces exactly the no-wards case 4.9 already ships, so a
	# Ward's resistance simply stops applying rather than needing a second code path.
	var wards: Array = [] if _has_modifier(&"rooted") \
		else (_ward_circles_provider.call() if _ward_circles_provider.is_valid() else [])
	var rate: float = BASE_SPREAD_RATE * _cycle_spread_multiplier
	for _cap_index: int in _capped_wellsprings:
		rate *= SPREAD_REDUCTION_PER_CAP
	_grid = SIM.tick(_grid, wards, rate)
	_field_dirty = true
	_emit_changed_deltas()


func _on_wellspring_capped(_wellspring_name: StringName, world_position: Vector3) -> void:
	if not _owns_simulation() or _grid.is_empty():
		return
	_grid = SIM.clear_radius(_grid, Vector2(world_position.x, world_position.z), WELLSPRING_CLEAR_RADIUS_M)
	_field_dirty = true
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


func _has_modifier(id: StringName) -> bool:
	var modifiers: Node = get_node_or_null(^"/root/CycleModifierService")
	return modifiers != null and bool(modifiers.call(&"has_modifier", id))


func _owns_simulation() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
