extends SceneTree

## Proof for F-274 — every biome's authored `detail_amplitude`/`ridge_amplitude` now reaches the
## ground the game actually builds, and the seam between two biomes is a slope rather than a cliff.
##
##   .agent/bin/agent godot --script tools/biome_terrain_check.gd
##
## D-144 split `IslandHeightmap` in two so a biome could shape its own ground: `continent()` decides
## where the biomes are, `height(..., detail_amplitude, ridge_amplitude)` decides how rough each one
## is, and `BiomeMap.terrain_amplitudes()` was named as the seam between them. The seam was built and
## nothing crossed it — the chunk mesher, the POI dart loop, the resource scatter and
## `ProceduralWorld.height_at()` all took the 1.0/1.0 defaults, so editing `shore.tres`'s six numbers
## changed the audit PNG and nothing else. Five things have to hold now:
##
##   1. REACH — a point well inside a biome gets that biome's AUTHORED pair, not 1.0/1.0 and not an
##      average. The blend has to converge to the content in the content's own interior or the
##      authored numbers still do not mean what they say.
##   2. EFFECT — the shipped table visibly moves the chunk mesh. A pair that reaches the sampler and
##      changes nothing is the same dead content in a longer pipeline.
##   3. AGREEMENT — the mesh, `BiomeMap.surface_from_set()`, `ProceduralWorld.height_at()`'s
##      one-shot form and the POI/scatter sampler all return the SAME height at the same point. This
##      is the one that matters in play: a disagreement is a landmark floating over a ridge.
##   4. CONTINUITY — no step in the surface along a dense walk across biome boundaries larger than
##      the terrain's own roughness allows. Handing each vertex its winning biome's pair alone puts
##      a ~7.7 m wall along the forest/grassland moisture contour (`AMPLITUDE_BLEND_MOISTURE` in
##      `biome_map.gd` explains the arithmetic); this is the assertion that would go red if the
##      crossfade were ever removed.
##   5. TRIPWIRE — `build_mesh()` still REQUIRES a biome table. F-274 was a default that silently
##      produced the wrong surface, so the check that the argument stayed mandatory is part of the
##      fix, not a nicety.
##
## Cross-platform bit-identity of the new operations is `tools/check_determinism.gd`'s
## `biome_surface` line; layout tripwires are `tools/worldgen_noise_reuse_check.gd`'s goldens.

## Preloaded, never named bare: a script new to this session is not in
## .godot/global_script_class_cache.cfg yet (F-016).
const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")
const ChunkMesher := preload("res://world/chunk/chunk_mesher.gd")
const PoiMap := preload("res://world/gen/poi_map.gd")
const BiomeDefsLib := preload("res://tools/biome_defs_lib.gd")

const SEEDS: Array[int] = [20260819, 4242, 7, 991]
const SEED: int = 20260819

## Half the chunk footprint, in metres, either side of origin — a walk long enough to cross the
## shore/grassland height band and the grassland/forest moisture contour several times each.
const WALK_SPAN_M: float = 220.0
## Step for the continuity walk. 0.25 m is a quarter of the finest LOD's vertex spacing, so a step
## the mesh itself could never resolve — a discontinuity that hides between these samples cannot
## reach a vertex either.
const WALK_STEP_M: float = 0.25

## The most the biome shaping may ADD to the surface's own local step, in metres, at any point
## along the walk — `|delta shaped| - |delta biome-blind|` at the same pair of samples.
##
## Measured against the absolute step rather than asserted on it, because the terrain is already
## discontinuous for reasons that have nothing to do with biomes: the river corridor has a hard
## edge (`_river_channel()` returns its sentinel outside `RIVER_CORRIDOR`, so the carve stops
## abruptly) and a ridge crest can climb metres over a chord. Across the four seeds below the blind
## surface steps up to 3.6 m per 0.25 m all by itself, so an absolute threshold would be measuring
## the river, not the fix.
##
## 0.75 m against a measured worst of 0.531 m (seed 4242). The number that matters is what a
## winner-takes-all amplitude table would score here: ~7.7 m, an order of magnitude clear of this
## limit, because it is a vertical wall along the forest/grassland moisture contour.
const MAX_ADDED_STEP_M: float = 0.75

## The most `blend_amplitudes()` may move per step of a dense sweep of its own (height, moisture)
## domain — 0.01 m of continental height, 0.001 of moisture.
##
## Asserted in the domain rather than along a world walk on purpose: the blend is a function of that
## pair alone, so sweeping it directly is seed-independent and covers every boundary the content has
## rather than the ones this seed's island happens to contain. The true worst is bounded by the
## crossfade's own slope — `smoothstep` peaks at 1.5/margin, so at most 0.8 x 1.5 / 1.5 = 0.8 per
## metre of height, and 0.65 x 1.5 / 0.06 = 16 per unit of moisture; over the step sizes above that
## is ~0.008 and ~0.016. 0.05 gives that three times the room it needs and still fails hard on a
## winner-takes-all table, whose smallest authored jump is 0.25 in a single step.
const MAX_AMPLITUDE_STEP: float = 0.05
const AMPLITUDE_SWEEP_HEIGHT_STEP: float = 0.01
const AMPLITUDE_SWEEP_MOISTURE_STEP: float = 0.001

var failures: int = 0
var biome_defs: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	biome_defs = BiomeDefsLib.load_defs(self)
	_check(biome_defs.size() >= 3, "the shipped biome table loaded (%d def(s))" % biome_defs.size())
	if biome_defs.is_empty():
		_finish()
		return

	_check_amplitudes_reach_content()
	_check_table_moves_the_mesh()
	_check_every_consumer_agrees()
	_check_surface_is_continuous()
	_check_table_is_mandatory()

	print("\nBIOME_TERRAIN failures=%d" % failures)
	_finish()


func _check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _finish() -> void:
	quit(1 if failures > 0 else 0)


## 1. REACH. Probed in the (height, moisture) domain rather than at world coordinates: what the
## blend is a function of is exactly that pair, and driving it directly means the assertion holds
## for any seed and any island shape rather than for wherever this seed happens to put a forest.
func _check_amplitudes_reach_content() -> void:
	print("\n== a biome's interior gets that biome's AUTHORED amplitudes ==")
	var table: BiomeMap.TerrainTable = BiomeMap.make_terrain_table(biome_defs)
	# Well inside each shipped band, by more than AMPLITUDE_BLEND_HEIGHT_M (0.22 m) and
	# AMPLITUDE_BLEND_MOISTURE (0.03) on both axes. Coordinates are (height_m, moisture).
	#
	# F-401 rebuilt the biome set from three rows to seven, and BOTH halves of that broke this
	# block. The forest probe sat at height 14.0, which was correct when forest's band was
	# `height 1.6 - 100` — the wet half of the island at any elevation. Forest is now a narrow
	# `2.9 - 3.9` belt with `highland` above it, so height 14 resolves to highland and the probe was
	# asserting forest's amplitudes against highland's numbers. And four of the seven biomes had no
	# probe at all, so a check whose whole job is "authored numbers mean something" was covering
	# under half the content that carries them.
	#
	# Every entry below is re-derived from the shipped bands rather than carried over, so this stays
	# a real assertion instead of one that happens to still pass.
	var probes: Dictionary = {
		&"shore": Vector2(0.0, 0.5),        # height < 1.7, any moisture
		&"marsh": Vector2(2.3, 0.8),        # 1.7 - 2.9,  wet
		&"forest": Vector2(3.4, 0.8),       # 2.9 - 3.9,  wet
		&"birchwood": Vector2(2.8, 0.51),   # 1.7 - 3.9,  mid moisture
		&"highland": Vector2(14.0, 0.7),    # 3.9+,       mid-wet
		&"grassland": Vector2(14.0, 0.25),  # 1.7+,       dry
		&"heath": Vector2(14.0, 0.07),      # 1.7+,       driest
	}
	_check(probes.size() == biome_defs.size(),
		"every shipped biome has a probe (%d biomes, %d probes)" % [biome_defs.size(), probes.size()],
		"a biome with no probe is a biome whose authored amplitudes nothing checks")
	for id: StringName in probes:
		var probe: Vector2 = probes[id]
		var authored: Vector2 = BiomeMap.amplitudes_for(id, biome_defs)
		var blended: Vector2 = BiomeMap.blend_amplitudes(probe.x, probe.y, table)
		_check(blended.is_equal_approx(authored),
			"%s's interior resolves to its authored (%.2f, %.2f)" % [id, authored.x, authored.y],
			"got (%.3f, %.3f)" % [blended.x, blended.y])
		_check(BiomeMap.assign(probe.x, probe.y, biome_defs) == id,
			"%s's probe point really is in %s" % [id, id])

	# The other half of "authored numbers mean something": at least one shipped biome must differ
	# from the biome-blind default, or every assertion above passes on content that says nothing.
	var differs: int = 0
	for def_value: Variant in biome_defs:
		var def: Resource = def_value as Resource
		if def == null:
			continue
		if not BiomeMap.amplitudes_for(StringName(String(def.get(&"id"))), biome_defs) \
				.is_equal_approx(Vector2.ONE):
			differs += 1
	_check(differs >= 2, "at least two shipped biomes author a non-default pair (%d)" % differs)


## 2. EFFECT — through `build_mesh()` itself, not through the sampler it calls. The mesher is what
## F-274 found taking the defaults, so the mesher is what has to be shown to have stopped.
func _check_table_moves_the_mesh() -> void:
	print("\n== the shipped table visibly moves the chunk mesh ==")
	for world_seed: int in SEEDS:
		var shaped: PackedVector3Array = _chunk_vertices(1, 0, world_seed, biome_defs)
		var blind: PackedVector3Array = _chunk_vertices(1, 0, world_seed, [])
		var moved: int = 0
		var worst: float = 0.0
		for i: int in mini(shaped.size(), blind.size()):
			var delta: float = absf(shaped[i].y - blind[i].y)
			if delta > 0.001:
				moved += 1
			worst = maxf(worst, delta)
		_check(moved > 0,
			"seed %d: %d/%d chunk vertices differ from the biome-blind surface (worst %.3f m)"
				% [world_seed, moved, shaped.size(), worst])


## 3. AGREEMENT. Five independent paths to "how high is the ground here", all of which something in
## the game stands on: the mesh vertex, the shared-set sampler, the one-shot sampler
## `ProceduralWorld.height_at()` uses, `IslandHeightmap.height()` fed the blended pair by hand, and
## `PoiMap`'s own site heights.
func _check_every_consumer_agrees() -> void:
	print("\n== the mesh, the samplers and PoiMap all describe the same ground ==")
	var set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(SEED)
	var table: BiomeMap.TerrainTable = BiomeMap.make_terrain_table(biome_defs)
	var verts: PackedVector3Array = _chunk_vertices(1, 0, SEED, biome_defs)
	var side: int = ChunkMesher.verts_per_side(0)
	var origin_x: float = float(1 * ChunkMesher.CHUNK_SIZE)
	var origin_z: float = 0.0

	var mesh_bad: int = 0
	var oneshot_bad: int = 0
	var manual_bad: int = 0
	for z: int in side:
		for x: int in side:
			# The vertex's OWN stored position, not the grid point: every vertex carries the
			# 4.18/D-184 XZ jitter, and the contract is "every vertex sits on the analytic
			# ground AT ITS OWN XZ" — which is exactly as strong, since a vertex parked anywhere
			# off the surface still fails. Borders are pinned by the cross-chunk agreement
			# assertion below instead of by grid position: what tiling needs is that both
			# neighbours put the shared vertex in the same world place, not that the place is
			# the grid point.
			var vert: Vector3 = verts[z * side + x]
			var world_x: float = origin_x + vert.x
			var world_z: float = origin_z + vert.z
			var expected: float = BiomeMap.surface_from_set(world_x, world_z, set, SEED, table)
			# Compared through a float32 round-trip, not against the raw double. The mesher stores
			# its apron in a `PackedFloat32Array` and its vertices in `Vector3`s, both of which are
			# single-precision, so the ~1e-6 m difference is the STORAGE, not a divergent
			# calculation — every vertex matches exactly once the same narrowing is applied to the
			# reference. Widening this to `is_equal_approx` instead would hide a real drift of
			# millimetres, which is the size of drift that matters here.
			#
			# Jittered vertices narrow their XZ through Vector3 too, so the reference must sample
			# at the float32 position the mesh actually stores — which it does: `vert.x` above IS
			# that float32.
			if vert.y != PackedFloat32Array([expected])[0]:
				mesh_bad += 1
			if BiomeMap.surface_at(world_x, world_z, SEED, biome_defs) != expected:
				oneshot_bad += 1
			var pair: Vector2 = BiomeMap.terrain_amplitudes(world_x, world_z, SEED, biome_defs)
			if IslandHeightmap.height(world_x, world_z, SEED, pair.x, pair.y) != expected:
				manual_bad += 1
	# The tiling contract, asserted directly: the chunk east of this one must place every shared
	# west-border vertex at the same world position and height. Jitter is a pure function of world
	# position + seed, so the only disagreement left is float32 chunk-LOCAL storage — the shared
	# point is `32 + j` in one chunk and `j` in the other, and narrowing those two sums rounds
	# differently by up to ~2e-6 m. The tolerance is 0.1 mm: a millionfold margin over rounding,
	# a millionfold too small to ever be a visible crack.
	var east_verts: PackedVector3Array = _chunk_vertices(2, 0, SEED, biome_defs)
	var east_origin_x: float = float(2 * ChunkMesher.CHUNK_SIZE)
	var seam_mismatches: int = 0
	for z: int in side:
		var mine: Vector3 = verts[z * side + (side - 1)]
		var theirs: Vector3 = east_verts[z * side]
		if absf((origin_x + mine.x) - (east_origin_x + theirs.x)) > 0.0001 \
				or absf(mine.y - theirs.y) > 0.0001 or absf(mine.z - theirs.z) > 0.0001:
			seam_mismatches += 1
	_check(seam_mismatches == 0,
		"both neighbours place every shared border vertex identically (world x, y, z)",
		"%d seam vertex(es) disagree" % seam_mismatches)
	_check(mesh_bad == 0, "every chunk vertex equals surface_from_set() to the float32 it stores",
		"%d differ" % mesh_bad)
	_check(oneshot_bad == 0, "surface_at() equals surface_from_set() bit-for-bit",
		"%d differ" % oneshot_bad)
	_check(manual_bad == 0, "height() + terrain_amplitudes() equals surface_from_set() bit-for-bit",
		"%d differ" % manual_bad)

	# PoiMap's sites: `position.y` re-derived from the surface, which is what `poi_check.gd` also
	# asserts — repeated here because F-274 is precisely the class of bug where one consumer is
	# migrated and its siblings are not.
	var registry: Node = root.get_node_or_null(^"Registry")
	if registry == null:
		print("  --    no Registry autoload; PoiMap agreement skipped")
		return
	var poi_defs: Array = (registry.get(&"poi") as Dictionary).values()
	var site_bad: int = 0
	var sites: int = 0
	for site: Dictionary in PoiMap.sites_for_island(SEED, poi_defs, biome_defs):
		sites += 1
		var p: Vector3 = site["position"]
		if not is_equal_approx(p.y, BiomeMap.surface_at(p.x, p.z, SEED, biome_defs)):
			site_bad += 1
	_check(site_bad == 0, "all %d POI sites stand on the shipped surface" % sites,
		"%d floating or buried" % site_bad)


## 4. CONTINUITY — the assertion that justifies the crossfade, in two halves.
##
## The first sweeps `blend_amplitudes()`'s own (height, moisture) domain, which is where a
## winner-takes-all table would show a bare step. The second walks the world and asks what the
## shaping ADDS to the surface's local step over the same terrain without it. Two dense world walks
## per seed, one along each axis, because a boundary running parallel to one is invisible to it.
func _check_surface_is_continuous() -> void:
	print("\n== the amplitude field has no step in its own domain ==")
	var table: BiomeMap.TerrainTable = BiomeMap.make_terrain_table(biome_defs)
	var worst_domain: float = 0.0
	var worst_domain_at := Vector2.ZERO
	for moisture_index: int in 11:
		var moisture_value: float = float(moisture_index) * 0.1
		var previous := Vector2.ZERO
		var height: float = -10.0
		var first: bool = true
		while height <= 30.0:
			var pair: Vector2 = BiomeMap.blend_amplitudes(height, moisture_value, table)
			if not first:
				var step: float = maxf(absf(pair.x - previous.x), absf(pair.y - previous.y))
				if step > worst_domain:
					worst_domain = step
					worst_domain_at = Vector2(height, moisture_value)
			previous = pair
			first = false
			height += AMPLITUDE_SWEEP_HEIGHT_STEP
	for height_index: int in 9:
		var height: float = -4.0 + float(height_index) * 4.0
		var previous := Vector2.ZERO
		var moisture_value: float = 0.0
		var first: bool = true
		while moisture_value <= 1.0:
			var pair: Vector2 = BiomeMap.blend_amplitudes(height, moisture_value, table)
			if not first:
				var step: float = maxf(absf(pair.x - previous.x), absf(pair.y - previous.y))
				if step > worst_domain:
					worst_domain = step
					worst_domain_at = Vector2(height, moisture_value)
			previous = pair
			first = false
			moisture_value += AMPLITUDE_SWEEP_MOISTURE_STEP
	_check(worst_domain <= MAX_AMPLITUDE_STEP,
		"the biggest amplitude step anywhere in the domain is %.4f (limit %.2f)"
			% [worst_domain, MAX_AMPLITUDE_STEP],
		"at height %.2f moisture %.3f" % [worst_domain_at.x, worst_domain_at.y])

	print("\n== biome shaping adds no cliff to the surface ==")
	for world_seed: int in SEEDS:
		var set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed)
		# The same walk with a table of no biomes at all: `blend_amplitudes()` falls back to
		# (1.0, 1.0), so this is the surface the mesher built before F-274 — the control.
		var blind: BiomeMap.TerrainTable = BiomeMap.make_terrain_table([])
		var worst_added: float = 0.0
		var worst_at := Vector2.ZERO
		var crossings: int = 0
		for axis: int in 2:
			var previous_shaped: float = NAN
			var previous_blind: float = 0.0
			var previous_biome: StringName = &""
			var t: float = -WALK_SPAN_M
			while t <= WALK_SPAN_M:
				# Offset the fixed axis so the two walks are not the same line twice.
				var x: float = t if axis == 0 else 37.0
				var z: float = -23.0 if axis == 0 else t
				var shaped: float = BiomeMap.surface_from_set(x, z, set, world_seed, table)
				var flat: float = BiomeMap.surface_from_set(x, z, set, world_seed, blind)
				var biome: StringName = BiomeMap.biome_at_from_set(
					x, z, set, world_seed, biome_defs)
				if not is_nan(previous_shaped):
					var added: float = absf(shaped - previous_shaped) \
						- absf(flat - previous_blind)
					if added > worst_added:
						worst_added = added
						worst_at = Vector2(x, z)
					if biome != previous_biome:
						crossings += 1
				previous_shaped = shaped
				previous_blind = flat
				previous_biome = biome
				t += WALK_STEP_M
		_check(crossings > 0, "seed %d: the walks actually cross biome boundaries (%d)"
			% [world_seed, crossings])
		_check(worst_added <= MAX_ADDED_STEP_M,
			"seed %d: shaping adds at most %.3f m to a %.2f m step (limit %.2f)"
				% [world_seed, worst_added, WALK_STEP_M, MAX_ADDED_STEP_M],
			"at %s" % worst_at)


## 5. TRIPWIRE. `build_mesh()` must keep REQUIRING a table. A default would compile everywhere and
## silently restore F-274, so this asserts the signature itself rather than a behaviour.
func _check_table_is_mandatory() -> void:
	print("\n== build_mesh() still requires a biome table ==")
	var found: bool = false
	# Bound to a `Script` local first: `ChunkMesher.get_script_method_list()` parses as a static call
	# on the class, and the method is an instance method on the Script resource itself.
	var mesher_script: Script = ChunkMesher
	for method: Dictionary in mesher_script.get_script_method_list():
		if String(method.get("name", "")) != "build_mesh":
			continue
		found = true
		var args: Array = method.get("args", [])
		var defaults: Array = method.get("default_args", [])
		var names: PackedStringArray = []
		for arg: Dictionary in args:
			names.append(String(arg.get("name", "")))
		var index: int = names.find("biome_defs")
		_check(index >= 0, "build_mesh takes a biome_defs argument", ", ".join(names))
		if index < 0:
			continue
		# Godot reports defaults right-aligned against the argument list: the last
		# `defaults.size()` arguments are the ones that have one.
		var first_defaulted: int = args.size() - defaults.size()
		_check(index < first_defaulted,
			"biome_defs has no default — a caller cannot silently mesh the biome-blind surface",
			"argument %d of %d, %d defaulted" % [index, args.size(), defaults.size()])
	_check(found, "build_mesh is on ChunkMesher's method list")


func _chunk_vertices(cx: int, cz: int, world_seed: int, defs: Array) -> PackedVector3Array:
	var mesh: ArrayMesh = ChunkMesher.build_mesh(cx, cz, world_seed, defs, 0)
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
