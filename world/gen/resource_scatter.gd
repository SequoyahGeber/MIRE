class_name ResourceScatter
extends RefCounted

## Task 4.4 — deterministic per-chunk resource placement (docs/ARCHITECTURE.md §4 pipeline).
##
## `placements_for_chunk()` is a pure function: no nodes, no instance state, same discipline as
## `IslandHeightmap.height()` and `BiomeMap` (4.1/4.2) — same (chunk, world_seed, scatter tables)
## always produces the identical placement list on every peer and every platform, so nothing about
## WHERE a tree stands ever needs to cross the network (matches ARCHITECTURE.md §2.2's "chunk
## streaming / terrain LOD" row: client-local, independently per peer, correct by construction as
## long as the content it reads — `ScatterDef`, `BiomeDef` — is the same set on every peer, which is
## true because content is never generated, only authored).
##
## Network authority: none, exactly like `BiomeMap`/`HarvestLibrary`. What this file returns is
## classification and geometry, not state. `world/gen/resource_scatter_field.gd` is the one place a
## placement's HOST-owned depletion state lives.
##
## ## Jittered grid, not Poisson-disc
##
## The spec allows either. A jittered grid was chosen: every point's RNG stream is independent
## (seeded from `(world_seed, chunk, def.id, gx, gz)` alone), so it parallelizes per-point exactly
## like `IslandHeightmap.height()` and needs no shared dart-throwing state across a chunk or its
## neighbours. True Poisson-disc's minimum-distance guarantee is nicer, but it requires either a
## shared RNG stream walked in a fixed order (which then has to agree on that order across chunk
## boundaries too) or a rejection pass against already-placed points — both are real complexity for
## a visual difference `jitter_fraction` already buys most of. Revisit only if a playtest finds the
## grid's residual regularity actually reads as planted rows at ground level.
##
## ## Determinism notes
##
## - `_point_seed()` mixes every input with integer multiply/xor only — never Godot's built-in
##   `hash()`, whose cross-platform/cross-version stability for `StringName` is not a documented
##   guarantee the way `int` overflow (fixed-width two's-complement wraparound) is. Same caution
##   D-017 applies to floats, applied here to the seed itself.
## - `scatter_defs` is sorted by `id` before use so an incidental directory-scan order (disk order is
##   not alphabetical on every platform — the same hazard D-079 already named for biomes) can never
##   change which point lands which asset.
## - A point's identity (`point_id`) is derived from its OWN coordinates, never from its position in
##   the returned array, so two peers that happen to iterate `scatter_defs`/a `Dictionary` in a
##   different order still agree on which point is which — `world/gen/resource_scatter_field.gd`
##   keys its depletion memory on this id.

const CHUNK_MESHER := preload("res://world/chunk/chunk_mesher.gd")
const ISLAND_HEIGHTMAP := preload("res://world/gen/island_heightmap.gd")

## How far apart the two probes that measure a candidate's slope sit (F-471). Roughly the footprint
## of the things being placed: measured over a shorter run the number is the terrain's detail noise
## rather than the ground a trunk sits on, and a metre of chatter would flicker trees in and out of
## a whole hillside between one seed and the next.
const SLOPE_PROBE_M: float = 1.5
const BIOME_MAP := preload("res://world/gen/biome_map.gd")
const SCATTER_DEF := preload("res://world/gen/scatter_def.gd")
## F-445: `MireGridSim` is a `class_name`, preloaded for the same F-016 reason as the others above.
const MIRE_GRID_SIM := preload("res://world/mire/mire_grid_sim.gd")
## F-016: ScatterDef/ScatterEntry are brand-new this task. `scatter_defs` stays untyped `Array` of
## plain `Resource` throughout this file (never cast to the class) for the same reason
## `systems/loot/loot_table_def.gd` treats `LootEntry` as `Resource` — see that file's own comment.

## Same XOR-a-salt convention `IslandHeightmap`'s own header names as the one to use here.
const SEED_SALT: int = 0x5CA77E5


## One entry per surviving jittered-grid point in this chunk, across every `ScatterDef` whose
## `biome_id` this chunk contains anywhere (plus any `ANY_BIOME` table, which is gated on Mire
## corruption instead — F-445). Each entry: `{point_id: String, def_id: StringName,
## asset: StringName, kit: String, position: Vector3, rotation_y: float, scale: float}`.
static func placements_for_chunk(
	chunk_x: int, chunk_z: int, world_seed: int, scatter_defs: Array, biome_defs: Array
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var defs: Array = scatter_defs.duplicate()
	defs.sort_custom(
		func(a: Resource, b: Resource) -> bool: return String(a.get(&"id")) < String(b.get(&"id"))
	)

	var origin_x: float = float(chunk_x * CHUNK_MESHER.CHUNK_SIZE)
	var origin_z: float = float(chunk_z * CHUNK_MESHER.CHUNK_SIZE)
	# F-252, same fix F-241 gave the chunk mesher: one NoiseSet built here and reused for every
	# candidate point in this chunk, instead of `_placement_at()` rebuilding all six FastNoiseLite
	# fields per call via a bare `height()`.
	#
	# F-261 finished the job on the other half: `_placement_at()` also called a bare
	# `BiomeMap.moisture()`, which rebuilt a seventh field per candidate. The biome set ADOPTS the
	# island set above rather than building a second one, so a chunk still constructs each field once.
	var island_set: ISLAND_HEIGHTMAP.NoiseSet = ISLAND_HEIGHTMAP.make_noise_set(world_seed)
	var noise_set: BIOME_MAP.NoiseSet = BIOME_MAP.make_noise_set(world_seed, island_set)
	# F-274: the flattened biome table, built once per chunk for the same reason as the noise set.
	# A placement's `position.y` now comes from `BiomeMap.surface_from_set()`, so a tree's feet are
	# on the surface the chunk mesher builds rather than on the biome-blind 1.0/1.0 one — which in
	# forest, the biome most of the scatter lives in, sits up to several metres below it.
	var table: BIOME_MAP.TerrainTable = BIOME_MAP.make_terrain_table(biome_defs)
	# F-445: where this seed's Mire starts, drawn once per chunk for the same reason as the noise
	# set above. Empty unless some table actually gates on corruption, so a world whose content has
	# no Mire table pays nothing for this.
	var mire_centres := PackedVector2Array()
	for def: Resource in defs:
		if bool(def.call(&"reads_corruption")):
			mire_centres = MIRE_GRID_SIM.seed_cluster_centres(world_seed)
			break

	# F-461: ONE generator for the whole chunk, re-seeded per candidate point rather than allocated
	# per candidate point. A chunk offers ~3,750 candidates (31 tables x 121 cells) and this used to
	# be 3,750 object allocations inside it. Determinism is untouched: every point still assigns
	# `rng.seed` from `_point_seed()` before its first draw, and assigning `seed` resets the stream,
	# so each point consumes exactly the sequence it consumed before.
	var rng := RandomNumberGenerator.new()

	for def: Resource in defs:
		var total_weight: float = float(def.call(&"total_weight"))
		var entries: Array = def.get(&"entries")
		if total_weight <= 0.0 or entries.is_empty():
			continue
		var cell: float = maxf(float(def.get(&"cell_size_m")), 0.5)
		var cells_per_side: int = maxi(1, ceili(float(CHUNK_MESHER.CHUNK_SIZE) / cell))
		# F-461: every one of these was read off the Resource once per CANDIDATE — a dynamic
		# property lookup by StringName, 121 times per table for a value that cannot change between
		# cells. `_hash_id()` was the worst of them: it built a String and a PackedByteArray from
		# the def id and walked its bytes, per candidate, to produce the same integer every time.
		var plan := DefPlan.new()
		plan.def = def
		plan.def_id = def.get(&"id")
		plan.id_hash = _hash_id(plan.def_id)
		plan.total_weight = total_weight
		plan.cell = cell
		plan.coverage = float(def.get(&"coverage"))
		plan.jitter_fraction = float(def.get(&"jitter_fraction"))
		plan.biome_id = def.get(&"biome_id")
		plan.reads_corruption = bool(def.call(&"reads_corruption"))
		plan.min_corruption = float(def.get(&"min_corruption"))
		plan.max_corruption = float(def.get(&"max_corruption"))
		plan.min_height = float(def.get(&"min_height"))
		plan.max_height = float(def.get(&"max_height"))
		plan.reads_slope = bool(def.call(&"reads_slope"))
		plan.min_slope_deg = float(def.get(&"min_slope_deg"))
		plan.max_slope_deg = float(def.get(&"max_slope_deg"))
		for gx: int in cells_per_side:
			for gz: int in cells_per_side:
				var placement: Dictionary = _placement_at(
					chunk_x, chunk_z, gx, gz, origin_x, origin_z, world_seed, plan,
					biome_defs, noise_set, table, mire_centres, rng
				)
				if not placement.is_empty():
					out.append(placement)
	return out


## F-461. One scatter table's per-chunk constants, read off the `ScatterDef` Resource once instead
## of once per candidate point. Typed fields on a RefCounted rather than a Dictionary: the whole
## point is to get off keyed lookups on the inner loop, and a Dictionary would only trade a
## StringName property lookup for a StringName hash lookup.
class DefPlan extends RefCounted:
	var def: Resource
	var def_id: StringName
	var id_hash: int = 0
	var total_weight: float = 0.0
	var cell: float = 0.0
	var coverage: float = 0.0
	var jitter_fraction: float = 0.0
	var biome_id: StringName
	var reads_corruption: bool = false
	var min_corruption: float = 0.0
	var max_corruption: float = 0.0
	var min_height: float = 0.0
	var max_height: float = 0.0
	var reads_slope: bool = false
	var min_slope_deg: float = 0.0
	var max_slope_deg: float = 90.0


static func _placement_at(
	chunk_x: int, chunk_z: int, gx: int, gz: int, origin_x: float, origin_z: float,
	world_seed: int, plan: DefPlan, biome_defs: Array,
	noise_set: BIOME_MAP.NoiseSet, table: BIOME_MAP.TerrainTable, mire_centres: PackedVector2Array,
	rng: RandomNumberGenerator
) -> Dictionary:
	var def_id: StringName = plan.def_id
	var cell: float = plan.cell
	rng.seed = _seed_from_hash(chunk_x, chunk_z, gx, gz, plan.id_hash, world_seed)

	if rng.randf() > plan.coverage:
		return {}

	var jitter_span: float = cell * plan.jitter_fraction
	var local_x: float = clampf(
		(float(gx) + 0.5) * cell + rng.randf_range(-0.5, 0.5) * jitter_span,
		0.0, float(CHUNK_MESHER.CHUNK_SIZE) - 0.001
	)
	var local_z: float = clampf(
		(float(gz) + 0.5) * cell + rng.randf_range(-0.5, 0.5) * jitter_span,
		0.0, float(CHUNK_MESHER.CHUNK_SIZE) - 0.001
	)
	var world_x: float = origin_x + local_x
	var world_z: float = origin_z + local_z

	# F-271: the biome comes from `biome_at_from_set()`, never from the surface `height` below.
	# D-144 is the rule — a biome is decided from the CONTINENT, the biome-independent half of the
	# surface, because since 4.13 a BiomeDef carries terrain amplitudes and so `height()` depends on
	# which biome a point is in. Classifying from `height()` put every point on high ground into a
	# higher-`height_min` biome than `BiomeMap.biome_at()` says it occupies, and the gate below then
	# rejected points it should have kept. Never re-derive the biome from the `height` local just
	# because it is already in hand: that reuse is what produced the bug.
	#
	# The jitter may have carried a point out of the biome its cell nominally belongs to. Skip
	# rather than force it — a def that pulled the point back to its own biome would place the
	# asset at the wrong height/moisture combination it was never authored to describe.
	var def_biome: StringName = plan.biome_id
	if def_biome != SCATTER_DEF.ANY_BIOME:
		var biome_id: StringName = BIOME_MAP.biome_at_from_set(
			world_x, world_z, noise_set, world_seed, biome_defs)
		if biome_id != def_biome:
			return {}

	# F-445: the Mire band, tested before the surface sample for the same reason as the biome gate —
	# it is the cheapest rejection there is (four distance tests) and it is what a Mire table rejects
	# almost every point on. Stream-safe: like the gates around it, it touches no `rng`.
	if plan.reads_corruption:
		var corruption: float = MIRE_GRID_SIM.initial_corruption_from_centres(
			world_x, world_z, mire_centres)
		if corruption < plan.min_corruption or corruption > plan.max_corruption:
			return {}

	# Only surviving points pay for the surface sample, and it is used for `position.y` alone —
	# where the asset's feet go. Safe to sit after the gate: neither this nor the biome test touches
	# `rng`, so the per-point stream is consumed in the same order as before.
	var height: float = BIOME_MAP.surface_from_set(
		world_x, world_z, noise_set, world_seed, table)
	# The def's height band (see its own comment: shore biome includes the seabed). Gating here is
	# stream-safe — every point draws from its own seeded rng, so a rejection cannot shift any
	# other point's rolls.
	if height < plan.min_height or height > plan.max_height:
		return {}

	# F-471, the slope band. Two more surface samples, and only for a point that has already
	# survived every cheaper gate — the order is the same argument the corruption and height gates
	# make above. Stream-safe for the same reason too: no `rng` is touched here, so a rejection
	# cannot shift any other point's rolls.
	#
	# Measured on the SHIPPED surface (`surface_from_set`, the one `ChunkMesher` meshes), not on the
	# biome-blind heightmap: a prop stands on the mesh, and the two differ by the biome's own detail
	# and ridge amplitudes — which is exactly the roughness that decides whether a given square metre
	# is a bank or a face.
	if plan.reads_slope:
		var east: float = BIOME_MAP.surface_from_set(
			world_x + SLOPE_PROBE_M, world_z, noise_set, world_seed, table)
		var north: float = BIOME_MAP.surface_from_set(
			world_x, world_z + SLOPE_PROBE_M, noise_set, world_seed, table)
		# The steeper of the two axes, not their vector sum: a prop on a face fails on whichever
		# direction the ground actually falls away, and a diagonal average would let a point sitting
		# on a 45-degree wall pass by being flat along the other axis.
		var rise: float = maxf(absf(east - height), absf(north - height))
		var slope_deg: float = rad_to_deg(atan2(rise, SLOPE_PROBE_M))
		if slope_deg < plan.min_slope_deg or slope_deg > plan.max_slope_deg:
			return {}

	var entry: Resource = plan.def.call(&"pick_entry", rng.randf() * plan.total_weight)
	if entry == null:
		return {}

	return {
		"point_id": "%d:%d:%s:%d:%d" % [chunk_x, chunk_z, String(def_id), gx, gz],
		"def_id": def_id,
		"asset": entry.get(&"asset"),
		"kit": entry.get(&"kit"),
		"position": Vector3(world_x, height, world_z),
		"rotation_y": rng.randf_range(0.0, TAU),
		"scale": rng.randf_range(float(entry.get(&"min_scale")), float(entry.get(&"max_scale"))),
	}


## Every mixing step is integer multiply/xor, so the result is identical under GDScript's
## fixed-width 64-bit `int` on every platform — no dependence on `hash()`'s implementation.
static func _point_seed(
	chunk_x: int, chunk_z: int, gx: int, gz: int, def_id: StringName, world_seed: int
) -> int:
	return _seed_from_hash(chunk_x, chunk_z, gx, gz, _hash_id(def_id), world_seed)


## F-461: the same mix, taking the def id's hash already computed. `_point_seed()` above is now a
## thin wrapper over this so the pure-function contract the checks assert against is unchanged;
## the inner loop calls this one and hashes the id once per TABLE instead of once per point.
static func _seed_from_hash(
	chunk_x: int, chunk_z: int, gx: int, gz: int, id_hash: int, world_seed: int
) -> int:
	const PRIME: int = 1000003
	var h: int = world_seed ^ SEED_SALT
	h = h * PRIME + chunk_x
	h = h * PRIME + chunk_z
	h = h * PRIME + gx
	h = h * PRIME + gz
	h = h ^ id_hash
	return h


static func _hash_id(id: StringName) -> int:
	var h: int = 0x1000193
	for byte: int in String(id).to_utf8_buffer():
		h = (h ^ byte) * 16777619
	return h
