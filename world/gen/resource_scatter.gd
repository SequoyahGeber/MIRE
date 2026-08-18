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
const BIOME_MAP := preload("res://world/gen/biome_map.gd")
## F-016: ScatterDef/ScatterEntry are brand-new this task. `scatter_defs` stays untyped `Array` of
## plain `Resource` throughout this file (never cast to the class) for the same reason
## `systems/loot/loot_table_def.gd` treats `LootEntry` as `Resource` — see that file's own comment.

## Same XOR-a-salt convention `IslandHeightmap`'s own header names as the one to use here.
const SEED_SALT: int = 0x5CA77E5


## One entry per surviving jittered-grid point in this chunk, across every `ScatterDef` whose
## `biome_id` this chunk contains anywhere. Each entry: `{point_id: String, def_id: StringName,
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

	for def: Resource in defs:
		var total_weight: float = float(def.call(&"total_weight"))
		var entries: Array = def.get(&"entries")
		if total_weight <= 0.0 or entries.is_empty():
			continue
		var cell: float = maxf(float(def.get(&"cell_size_m")), 0.5)
		var cells_per_side: int = maxi(1, ceili(float(CHUNK_MESHER.CHUNK_SIZE) / cell))
		for gx: int in cells_per_side:
			for gz: int in cells_per_side:
				var placement: Dictionary = _placement_at(
					chunk_x, chunk_z, gx, gz, cell, origin_x, origin_z, world_seed, def, total_weight,
					biome_defs
				)
				if not placement.is_empty():
					out.append(placement)
	return out


static func _placement_at(
	chunk_x: int, chunk_z: int, gx: int, gz: int, cell: float, origin_x: float, origin_z: float,
	world_seed: int, def: Resource, total_weight: float, biome_defs: Array
) -> Dictionary:
	var def_id: StringName = def.get(&"id")
	var rng := RandomNumberGenerator.new()
	rng.seed = _point_seed(chunk_x, chunk_z, gx, gz, def_id, world_seed)

	if rng.randf() > float(def.get(&"coverage")):
		return {}

	var jitter_span: float = cell * float(def.get(&"jitter_fraction"))
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

	var height: float = ISLAND_HEIGHTMAP.height(world_x, world_z, world_seed)
	var moisture: float = BIOME_MAP.moisture(world_x, world_z, world_seed)
	var biome_id: StringName = BIOME_MAP.assign(height, moisture, biome_defs)
	# The jitter may have carried a point out of the biome its cell nominally belongs to. Skip
	# rather than force it — a def that pulled the point back to its own biome would place the
	# asset at the wrong height/moisture combination it was never authored to describe.
	if biome_id != def.get(&"biome_id"):
		return {}

	var entry: Resource = def.call(&"pick_entry", rng.randf() * total_weight)
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
	const PRIME: int = 1000003
	var h: int = world_seed ^ SEED_SALT
	h = h * PRIME + chunk_x
	h = h * PRIME + chunk_z
	h = h * PRIME + gx
	h = h * PRIME + gz
	h = h ^ _hash_id(def_id)
	return h


static func _hash_id(id: StringName) -> int:
	var h: int = 0x1000193
	for byte: int in String(id).to_utf8_buffer():
		h = (h ^ byte) * 16777619
	return h
