class_name ChunkStreamer
extends Node3D

## Task 4.3 — chunk streaming + LOD. Owns a ring-buffer of terrain chunks around a set of
## world-space anchors (normally just the local player's own position — see `set_anchors()`),
## streamed in and out with hysteresis (D-025's lesson, generalized from one radius pair to one
## per LOD tier) so a chunk sitting on a ring boundary does not reload every time an anchor drifts
## back and forth across it.
##
## Network authority (docs/ARCHITECTURE.md §2.2): CLIENT-LOCAL, none of the table's networked
## rows. Terrain itself is never sent over the wire (§4: every peer regenerates it from the shared
## seed), so which chunks are resident is a per-peer rendering/physics-locality decision, not a
## networked one — a host and a client streaming different chunk sets around their own local
## players is correct, not a desync. What DOES have to agree cross-peer is the terrain itself at
## any given point, and that is `IslandHeightmap`/`ChunkMesher`'s job (both pure, deterministic,
## already proven cross-platform-safe by D-017/D-075), not this node's.
##
## Budget (D-074, task 4.0a): the gating main-thread cost is `ConcavePolygonShape3D` cooking —
## ~1.15-1.5 ms/chunk and NOT movable to WorkerThreadPool, because it calls PhysicsServer/Jolt
## synchronously (same constraint R3 hit baking NavigationServer3D, D-016). Mesh GENERATION moves
## off-thread here, which is this task's whole point; mesh UPLOAD and material bind stay on the
## main thread but cost under 3% of the collision number (0.020 ms / 0.002 ms per chunk measured)
## and are not separately throttled. So every chunk within LOAD_RADIUS_CHUNKS gets a
## WorkerThreadPool mesh job and a (cheap) budgeted upload; only the nearest ring gets a collider,
## cooked lazily and budgeted against the same FRAME_BUDGET_MS slice the uploads share — "collision
## cooks lazily (nearest ring only)" from the spec is implemented by making the collision ring and
## the LOD0 (full-detail) ring the SAME ring, so a chunk with a collider is always full-resolution.
##
## Ring geometry: Chebyshev (square-ring) distance in chunk-grid coordinates from the NEAREST
## anchor, not Euclidean — "ring-buffer" is a grid concept here, one integer comparison per axis
## with no sqrt, cheap enough to run over hundreds of resident chunks (`NetInterest`'s circular
## filter runs over far fewer entities per peer per tick, which is why it can afford the sqrt-free
## squared-distance form instead — same idea, different shape for a different workload).
##
## **F-132's host contract.** A host that calls `set_anchors()` with only its own local player's
## position never builds a chunk-resident harvestable proxy (`ResourceScatterField`, task 4.4) for a
## point a REMOTE client's own local ring covers — that peer's `Harvestable.request_hit()`
## `rpc_id(HOST_PEER_ID)` then has no node at that NodePath on the host to receive it, because
## nothing here is anchored there. `set_anchors()` already takes an array for exactly this reason:
## the host-side caller (whichever task first wires this into a live session — `docs/FINDINGS.md`
## F-139) must pass the UNION of every connected peer's last-known position, its own included, not
## just its own. Ring membership already unions correctly over an arbitrary anchor set (`_ring_distance()`
## takes the nearest anchor, so a chunk stays resident as long as ANY anchor's ring reaches it) — no
## API change was needed to support this, only the calling contract, verified in
## `tools/chunk_stream_check.gd`'s union-of-interest section: two independent, far-apart anchors each
## get their own resident, wired proxy from one streamer/field pair.

const Mesher := preload("res://world/chunk/chunk_mesher.gd")
const PlacementValidator := preload("res://systems/building/placement_validator.gd")

## Nearest ring: full detail (LOD 0) AND the only ring that gets a collider.
const LOD0_RADIUS_CHUNKS: int = 2
## How much of the LOD0 ring `prime()` builds SYNCHRONOUSLY when a caller has to stand something on
## the ground this instant (F-324). One ring — the anchor's own chunk and its eight neighbours — is
## everything a stationary body can be standing on, and nine chunks is the smallest slice that
## still guarantees the anchor is not on a chunk seam. Never larger than [constant
## LOD0_RADIUS_CHUNKS]: a primed chunk outside the collision ring would have its collider dropped
## again by the next `_evaluate_rings()`, which is the hole this closes, reopened.
const PRIME_RADIUS_CHUNKS: int = 1
## Mid ring: half detail (LOD 1), no collider.
const LOD1_RADIUS_CHUNKS: int = 5
## Outer ring: quarter detail (LOD 2), no collider. Beyond this, a chunk is not loaded at all.
const LOAD_RADIUS_CHUNKS: int = 8
## D-025's hysteresis, generalized: a chunk only LOOSENS (drops a tier, or unloads) once it is
## this many rings past the tier boundary it currently occupies. Tightening (gaining a tier as an
## anchor approaches) is never delayed — only the outward direction thrashes without this.
const HYSTERESIS_CHUNKS: int = 1
## Ascending tier boundaries, index = LOD level. `_tier_for_ring()` walks this to find the
## tightest tier a given ring distance qualifies for; one past the end means "unloaded".
const TIER_RADII: PackedInt32Array = [LOD0_RADIUS_CHUNKS, LOD1_RADIUS_CHUNKS, LOAD_RADIUS_CHUNKS]

## How often ring membership is recomputed. Not a `_physics_process` accumulator (§5a) because
## nothing about GAME PLAY depends on this — it is a rendering/physics-locality decision, the same
## class of thing §5a's own table names as `_process`-appropriate (camera smoothing, VFX). A
## quarter-second of lag on a ~2-8 chunk (64-256 m) buffer ahead of a 6 m/s sprint is negligible.
const RING_EVAL_INTERVAL_SEC: float = 0.2
## The 4 ms streaming slice D-074/task 4.0a measured this budget against, out of a 16.667 ms
## frame — shared by both the upload pass and the lazy-collision pass below, in that order.
const FRAME_BUDGET_MS: float = 4.0

## Sentinel: a job's `superseded_lod` has not been touched since it was queued.
const NOT_SUPERSEDED: int = -2

## A chunk finished generating (mesh uploaded, in the tree) at [param lod]. Fired before any
## collision exists for it — 4.4/4.5 should not assume a walkable collider is present yet.
signal chunk_mesh_ready(coord: Vector2i, lod: int)
## A chunk left the tree entirely (mesh AND any collision freed).
signal chunk_unloaded(coord: Vector2i)

## Set by the owner before streaming starts — the shared seed every peer regenerates terrain from
## (§4). Left at 0 rather than defaulted from anywhere here: no `GameState.run_seed` exists yet
## (D-041 already noted this gap), so the caller supplies it explicitly.
var world_seed: int = 0
## The authored biome table — `Registry.biomes.values()` — set by the owner alongside `world_seed`,
## for the same reason it is: this node has no business reaching into an autoload from a
## `WorkerThreadPool` task, and `ProceduralWorld` already reads the registry for the scatter field
## and the POI map.
##
## F-274: the mesher takes this and shapes each vertex by its own biome's terrain amplitudes. Left
## empty, every chunk comes out on the biome-blind 1.0/1.0 surface — which is the terrain the game
## actually built until F-274, and which would then disagree with the POI/scatter/spawn queries that
## do resolve their biome. Never a partial wiring: either this is the registry's table or nothing
## in the world is standing on the ground the mesh draws.
var biome_defs: Array = []

var _anchors: Array[Vector3] = []
var _loaded: Dictionary[Vector2i, ChunkEntry] = {}
var _jobs: Dictionary[Vector2i, ChunkJob] = {}
## Starts AT the interval, not at zero: the first `_process()` after `set_anchors()` evaluates
## rings immediately instead of a fifth of a second later. That delay was the first of the three
## lags in F-324 — nothing under a freshly-placed player even being REQUESTED yet — and it costs
## nothing to remove, because an evaluation with no resident chunks and one anchor is a single
## scan box.
var _eval_accum: float = RING_EVAL_INTERVAL_SEC
var _shared_material: ShaderMaterial
## Wall-clock cost of the most recent `_process()` call, covering ring evaluation plus the
## budgeted upload/collision-cook work — everything this node itself did that frame. Deliberately
## NOT the same thing as total real frame time, which also includes rendering, physics, and
## whatever else the machine is doing; read this to tell "this node blew its own budget" apart
## from "the frame was slow for an unrelated reason" (see `last_process_cost_ms()`).
var _last_process_cost_usec: int = 0


## One resident chunk: its uploaded mesh, and its (optional, lazily-cooked) collider.
class ChunkEntry extends RefCounted:
	var lod: int = -1
	var mesh_instance: MeshInstance3D
	var has_collision: bool = false
	var collision_body: StaticBody3D


## One in-flight WorkerThreadPool mesh-build job. Self-contained on purpose — `run()` touches only
## its own fields, never the streamer, so it is safe for the worker thread to call regardless of
## what the main thread is doing to `_jobs`/`_loaded` concurrently.
class ChunkJob extends RefCounted:
	var coord: Vector2i
	var lod: int
	var world_seed: int
	## Read-only content, so unlike a `NoiseSet` this one Array IS shared across every in-flight
	## job — nothing sampling it mutates it (`BiomeMap.make_terrain_table()` copies before sorting).
	var biome_defs: Array = []
	var task_id: int = -1
	var finished: bool = false
	var result_mesh: ArrayMesh
	## Set by `_evaluate_rings()` if this chunk's desired LOD changes again while the job is still
	## in flight (or if it stops being wanted at all — [constant ChunkStreamer.NOT_SUPERSEDED]'s
	## sibling sentinel -1). Reconciled once the job completes, in `_drain_ready_jobs()`; never
	## acted on early, because a running WorkerThreadPool task cannot be cancelled.
	var superseded_lod: int = ChunkStreamer.NOT_SUPERSEDED

	func run() -> void:
		result_mesh = ChunkStreamer.Mesher.build_mesh(
			coord.x, coord.y, world_seed, biome_defs, lod)


func _ready() -> void:
	# Flat-shaded terrain (4.18/D-184): per-facet lighting from screen-space derivatives — see the
	# shader's own header. Still one shared material, one bind per chunk.
	_shared_material = ShaderMaterial.new()
	_shared_material.shader = preload("res://world/chunk/terrain_flat.gdshader")
	# F-379: 4.4's "eventual per-biome tint" is no longer eventual, and it is no longer THIS. The
	# single value that used to live here (F-353's Color(0.26, 0.40, 0.19)) painted every chunk on
	# the island one saturated green — which, against a canopy in the same band under warm light, is
	# most of why Sequoyah's verdict was "game looks to green/yellow". The ground's colour is a
	# per-vertex blend of each biome's authored `ground_albedo` now (`ChunkMesher.make_ground_palette`),
	# and this uniform is what survives of the old one: a global multiply over that, shipping at
	# white so it contributes nothing. Anything that wants to tint the whole ground at once — a
	# weather state, a debug view, `tools/grade_probe.gd`'s sweep — still has its lever here.
	_shared_material.set_shader_parameter(&"albedo_color", Color(1.0, 1.0, 1.0))
	_bind_mire_field()


## F-435. Hands the terrain shader the live corruption field so blighted ground reads purple. Bound
## ONCE, here: `MireGrid.corruption_field_texture()` returns a texture whose RID never changes (the
## image behind it is re-uploaded in place), so there is nothing to re-push per frame and no
## per-frame cost to this at all.
##
## Silent when there is no MireGrid — the greybox scene and every headless check that builds a
## streamer without the full autoload set. The shader's `hint_default_black` makes that case read as
## "clean everywhere", which is the correct terrain for a world with no Mire in it.
func _bind_mire_field() -> void:
	var mire_grid: Node = get_node_or_null(^"/root/MireGrid")
	if mire_grid == null or not mire_grid.has_method(&"corruption_field_texture"):
		return
	_shared_material.set_shader_parameter(
		&"mire_field", mire_grid.call(&"corruption_field_texture"))
	_shared_material.set_shader_parameter(
		&"mire_field_half_extent", float(mire_grid.call(&"corruption_field_half_extent")))


func _exit_tree() -> void:
	# WorkerThreadPool tasks must be waited on to release their slot even if already finished
	# (F-005's caution about believing an async API without checking applies here too — an
	# unreleased task id is a leak, not a no-op).
	for coord: Vector2i in _jobs:
		var job: ChunkJob = _jobs[coord]
		if not job.finished:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
	_jobs.clear()


## Where to stream around. Normally called once a tick with just the local player's position —
## the API takes an array because nothing here assumes exactly one anchor, so a future caller
## that wants to keep terrain loaded around more than one point of interest (a followed ally, a
## minimap camera) does not need a second streamer.
func set_anchors(anchors: Array[Vector3]) -> void:
	_anchors = anchors


## Builds the ground around [param anchors] RIGHT NOW — mesh generated, uploaded, and collision
## cooked — before this call returns, ignoring [constant FRAME_BUDGET_MS] entirely. Returns how many
## colliders it cooked.
##
## F-324: every other path into a collider here is lazy by design, and lazy is correct for streaming
## — a chunk two rings out can take as many frames as it likes. It is wrong exactly once, at the
## moment something is PLACED on ground that has never been resident: `set_anchors()` only says
## where to stream, it does not say when the streaming finished, so a caller that places a body and
## returns has placed it in mid-air over a hole. Gravity does the rest, and because the terrain
## collider is a `ConcavePolygonShape3D` with no backface collision, a body that gets under the mesh
## before the cook lands never comes back — it falls forever.
##
## So this is the seam a spawner needs: `prime()` first, place second. Deliberately BLOCKING, and
## deliberately unbudgeted — the caller is mid-world-build behind a loading screen, where the stall
## is invisible and a frame-budgeted trickle is the bug. Measured over five seeds, priming the nine
## spawn chunks is a fraction of a whole `ProceduralWorld` build, which itself runs 20-44 ms end to
## end. `_process()`'s budget still governs every ordinary chunk; this is the exception, and it is
## the only one.
##
## [param radius_chunks] is clamped to [constant LOD0_RADIUS_CHUNKS] — see [constant
## PRIME_RADIUS_CHUNKS].
func prime(anchors: Array[Vector3], radius_chunks: int = PRIME_RADIUS_CHUNKS) -> int:
	if anchors.is_empty():
		return 0
	var radius: int = clampi(radius_chunks, 0, LOD0_RADIUS_CHUNKS)

	var coords: Array[Vector2i] = []
	var seen: Dictionary[Vector2i, bool] = {}
	for anchor: Vector3 in anchors:
		var ac: Vector2i = _chunk_of(anchor)
		for dz: int in range(-radius, radius + 1):
			for dx: int in range(-radius, radius + 1):
				var coord := Vector2i(ac.x + dx, ac.y + dz)
				if seen.has(coord):
					continue
				seen[coord] = true
				coords.append(coord)

	# Dispatch every mesh job BEFORE waiting on any of them, so the nine builds still run across the
	# pool in parallel — blocking the caller is the point, serializing the workers is not.
	for coord: Vector2i in coords:
		if _loaded.has(coord) and _loaded[coord].lod == 0:
			continue                      # right mesh already resident; collision cooked below
		_request_chunk(coord, 0)

	# `_drain_ready_jobs()` re-requests any job it finds superseded (a lazy LOD1 build that was in
	# flight when we asked for LOD0), so one pass is not always enough. The loop is bounded because
	# a supersede chain here is at most one deep — the guard is a backstop, not the mechanism.
	var guard: int = 0
	while guard < LOD0_RADIUS_CHUNKS + 4:
		guard += 1
		var pending: Array[ChunkJob] = []
		for coord: Vector2i in coords:
			if _jobs.has(coord):
				pending.append(_jobs[coord])
		if pending.is_empty():
			break
		for job: ChunkJob in pending:
			if not job.finished:
				WorkerThreadPool.wait_for_task_completion(job.task_id)
				job.finished = true
		# A deadline far enough out that the budget check inside never trips — see the header.
		_drain_ready_jobs(Time.get_ticks_usec() + (1 << 30))

	var cooked: int = 0
	for coord: Vector2i in coords:
		if not _loaded.has(coord):
			continue
		var entry: ChunkEntry = _loaded[coord]
		if entry.lod != 0 or entry.has_collision:
			continue
		_cook_collision(entry)
		cooked += 1
	return cooked


## True when every chunk within [param radius_chunks] of [param position] is resident at LOD0 with a
## cooked collider — "there is ground under this point, right now". The question `prime()` answers
## and the one a spawn check asserts.
func has_ground_at(position: Vector3, radius_chunks: int = 0) -> bool:
	var ac: Vector2i = _chunk_of(position)
	for dz: int in range(-radius_chunks, radius_chunks + 1):
		for dx: int in range(-radius_chunks, radius_chunks + 1):
			if not chunk_has_collision(Vector2i(ac.x + dx, ac.y + dz)):
				return false
	return true


func is_chunk_loaded(coord: Vector2i) -> bool:
	return _loaded.has(coord)


## -1 if [param coord] is not currently loaded.
func chunk_lod(coord: Vector2i) -> int:
	return _loaded[coord].lod if _loaded.has(coord) else -1


func chunk_has_collision(coord: Vector2i) -> bool:
	return _loaded.has(coord) and _loaded[coord].has_collision


func loaded_chunk_count() -> int:
	return _loaded.size()


func pending_job_count() -> int:
	return _jobs.size()


## See `_last_process_cost_usec`'s doc comment — this node's own issuing cost for its most recent
## `_process()` call, not total frame time.
func last_process_cost_ms() -> float:
	return float(_last_process_cost_usec) / 1000.0


func _process(delta: float) -> void:
	if _anchors.is_empty():
		return
	var t0_usec: int = Time.get_ticks_usec()

	_eval_accum += delta
	if _eval_accum >= RING_EVAL_INTERVAL_SEC:
		_eval_accum = 0.0
		_evaluate_rings()

	var deadline_usec: int = Time.get_ticks_usec() + int(FRAME_BUDGET_MS * 1000.0)
	_drain_ready_jobs(deadline_usec)
	_cook_lazy_collision(deadline_usec)

	_last_process_cost_usec = Time.get_ticks_usec() - t0_usec


# ── Ring membership ───────────────────────────────────────────────────────────────────────────


func _evaluate_rings() -> void:
	var candidates: Dictionary[Vector2i, bool] = {}
	var scan_r: int = LOAD_RADIUS_CHUNKS + HYSTERESIS_CHUNKS
	for anchor: Vector3 in _anchors:
		var ac: Vector2i = _chunk_of(anchor)
		for dz: int in range(-scan_r, scan_r + 1):
			for dx: int in range(-scan_r, scan_r + 1):
				candidates[Vector2i(ac.x + dx, ac.y + dz)] = true
	# Anything already resident or in flight must be reconsidered too, even if every anchor has
	# since moved far enough that it falls outside every scan box above — that is exactly the
	# "should this unload" case.
	for coord: Vector2i in _loaded:
		candidates[coord] = true
	for coord: Vector2i in _jobs:
		candidates[coord] = true

	for coord: Vector2i in candidates:
		var ring: int = _ring_distance(coord)
		var current: int = _current_lod(coord)
		var desired: int = _desired_lod(current, ring)
		if desired == current:
			continue
		if desired == -1:
			_retire(coord)
		else:
			_request_chunk(coord, desired)


static func _chunk_of(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(pos.x / float(Mesher.CHUNK_SIZE))),
		int(floor(pos.z / float(Mesher.CHUNK_SIZE))),
	)


func _ring_distance(coord: Vector2i) -> int:
	var best: int = 1 << 30
	for anchor: Vector3 in _anchors:
		var ac: Vector2i = _chunk_of(anchor)
		var d: int = maxi(absi(coord.x - ac.x), absi(coord.y - ac.y))
		best = mini(best, d)
	return best


## The tightest LOD tier [param ring] qualifies for by its plain enter-boundary, ignoring
## hysteresis — [constant TIER_RADII].size() (one past the last real tier) means "unloaded".
func _tier_for_ring(ring: int) -> int:
	for t: int in TIER_RADII.size():
		if ring <= TIER_RADII[t]:
			return t
	return TIER_RADII.size()


## D-025's enter/leave asymmetry, generalized to N tiers: tightening (gaining detail) is immediate,
## loosening (losing detail, or unloading) only happens once [param ring] passes the CURRENT
## tier's own boundary plus [constant HYSTERESIS_CHUNKS] — so hovering near a boundary changes
## nothing, same as a single entity crossing NetInterest's enter/leave radii.
func _desired_lod(current_lod: int, ring: int) -> int:
	var tightest: int = _tier_for_ring(ring)
	var unloaded: int = TIER_RADII.size()
	if current_lod == -1:
		return tightest if tightest < unloaded else -1
	if tightest < current_lod:
		return tightest
	var leave_boundary: int = TIER_RADII[current_lod] + HYSTERESIS_CHUNKS
	if ring <= leave_boundary:
		return current_lod
	return tightest if tightest < unloaded else -1


## What this chunk is currently heading toward: an in-flight job's (possibly superseded) target
## takes priority over a resident entry's LOD, since the job is the more recent decision.
func _current_lod(coord: Vector2i) -> int:
	if _jobs.has(coord):
		var job: ChunkJob = _jobs[coord]
		return job.superseded_lod if job.superseded_lod != NOT_SUPERSEDED else job.lod
	if _loaded.has(coord):
		return _loaded[coord].lod
	return -1


# ── Requesting / retiring ─────────────────────────────────────────────────────────────────────


func _request_chunk(coord: Vector2i, lod: int) -> void:
	if _jobs.has(coord):
		_jobs[coord].superseded_lod = lod
		return
	var job := ChunkJob.new()
	job.coord = coord
	job.lod = lod
	job.world_seed = world_seed
	job.biome_defs = biome_defs
	job.task_id = WorkerThreadPool.add_task(job.run)
	_jobs[coord] = job


## A chunk is no longer wanted at all. A running job cannot be cancelled (D-074's own note on
## `ConcavePolygonShape3D` applies to WorkerThreadPool tasks generally: once submitted, they run to
## completion) — mark it superseded so `_drain_ready_jobs()` discards the result instead of
## uploading it. Any currently-visible mesh (an LOD rebuild was in flight when this chunk fell out
## of every ring) unloads right away regardless — there is no replacement coming to swap it for.
func _retire(coord: Vector2i) -> void:
	if _jobs.has(coord):
		_jobs[coord].superseded_lod = -1
	_unload_chunk(coord)


func _unload_chunk(coord: Vector2i) -> void:
	if not _loaded.has(coord):
		return
	var entry: ChunkEntry = _loaded[coord]
	_loaded.erase(coord)
	if is_instance_valid(entry.mesh_instance):
		# Frees the collision StaticBody3D too — it is a child of the mesh instance, not a sibling.
		entry.mesh_instance.queue_free()
	chunk_unloaded.emit(coord)


# ── Budgeted main-thread work ─────────────────────────────────────────────────────────────────


func _drain_ready_jobs(deadline_usec: int) -> void:
	var coords: Array[Vector2i] = _jobs.keys()
	for coord: Vector2i in coords:
		var job: ChunkJob = _jobs[coord]
		if not job.finished:
			if not WorkerThreadPool.is_task_completed(job.task_id):
				continue
			WorkerThreadPool.wait_for_task_completion(job.task_id)
			job.finished = true

		if job.superseded_lod != NOT_SUPERSEDED:
			var next_lod: int = job.superseded_lod
			_jobs.erase(coord)
			if next_lod != -1:
				_request_chunk(coord, next_lod)
			continue

		if Time.get_ticks_usec() >= deadline_usec:
			continue  # Done, but this frame's slice is spent — upload on a later frame.

		_upload_chunk(job)
		_jobs.erase(coord)


## Mesh upload + material bind — cheap (D-074: 0.020 ms / 0.002 ms per chunk), so this is not
## separately budgeted beyond sharing the frame deadline with collision cooking below.
func _upload_chunk(job: ChunkJob) -> void:
	if _loaded.has(job.coord):
		# An LOD change: the old mesh (and any collider hanging off it) is replaced wholesale
		# rather than mutated, so a downgrade away from LOD0 drops its collider for free.
		var old: ChunkEntry = _loaded[job.coord]
		if is_instance_valid(old.mesh_instance):
			old.mesh_instance.queue_free()

	var mi := MeshInstance3D.new()
	mi.mesh = job.result_mesh
	mi.material_override = _shared_material
	mi.position = _chunk_origin(job.coord)
	# The same group authored_world.gd puts its terrain visuals in: presentation systems that
	# measure "where the ground is" off VisualInstance3D AABBs (ground_fog.gd's mist height) see
	# streamed terrain the way they see authored terrain. Before add_child, F-012's ordering rule.
	mi.add_to_group(&"authored_world_terrain")
	add_child(mi)

	var entry := ChunkEntry.new()
	entry.lod = job.lod
	entry.mesh_instance = mi
	_loaded[job.coord] = entry
	chunk_mesh_ready.emit(job.coord, job.lod)


static func _chunk_origin(coord: Vector2i) -> Vector3:
	return Vector3(float(coord.x * Mesher.CHUNK_SIZE), 0.0, float(coord.y * Mesher.CHUNK_SIZE))


## "Collision cooks lazily (nearest ring only)" — every resident LOD0 chunk without a collider yet
## gets one, budgeted against whatever is left of this frame's slice after uploads. `ConcavePolygonShape3D.set_faces()`
## is a synchronous PhysicsServer/Jolt call (D-074) and cannot move to WorkerThreadPool.
func _cook_lazy_collision(deadline_usec: int) -> void:
	for coord: Vector2i in _loaded:
		if Time.get_ticks_usec() >= deadline_usec:
			return
		var entry: ChunkEntry = _loaded[coord]
		if entry.lod != 0 or entry.has_collision:
			continue
		_cook_collision(entry)


## Terrain triangles only, never `mesh.get_faces()` — the mesh also carries F-128's visual skirt,
## and a skirt is a vertical wall standing on the exact seam a player walks across (D-084).
func _cook_collision(entry: ChunkEntry) -> void:
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(Mesher.collision_faces(entry.mesh_instance.mesh, entry.lod))

	var body := StaticBody3D.new()
	body.collision_layer = PlacementValidator.TERRAIN_LAYER
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	entry.mesh_instance.add_child(body)

	entry.has_collision = true
	entry.collision_body = body
