extends SceneTree

## Proof for F-261 — the third and last instalment of the per-sample noise-rebuild fix F-241 started
## on the chunk mesher and F-252 continued on the resource scatter.
##
##   .agent/bin/agent godot --script tools/worldgen_noise_reuse_check.gd
##
## F-261 added `BiomeMap.NoiseSet` / `make_noise_set()` / `moisture_from_set()` /
## `biome_at_from_set()` / `terrain_amplitudes_from_set()` and `IslandHeightmap.continent_from_set()`,
## then threaded one set through `PoiMap.sites_for_island()`'s dart loop, `ResourceScatter`'s
## moisture sample and `tools/terrain_map_render.gd`'s per-pixel loop.
##
## FOUR things have to hold, and the third is the one that actually matters:
##   1. EQUIVALENCE — every `*_from_set` call is bit-identical to its bare sibling. A faster answer
##      that is a different answer is a world desync, not an optimisation.
##   2. ADOPTION — `make_noise_set(seed, existing_island_set)` samples identically to a set that
##      built its own island half, so `ResourceScatter` reusing one island set is free of charge.
##   3. LAYOUT IDENTITY — POI sites, biome ids and terrain amplitudes hash to the SAME values they
##      did before F-261 touched anything. The constants below were captured at commit 17bacba (the
##      commit F-261 was fixed on top of) by running the bare pre-fix API, so this is a comparison
##      against the old code, not merely the new code agreeing with itself. `agent baseline` cannot
##      stand in for it: this script does not exist at that revision, and the APIs it drives did not
##      either. If a later task deliberately changes worldgen output, THESE CONSTANTS MUST BE
##      RE-CAPTURED and the change recorded — they are a tripwire, not a specification of the layout.
##      F-271 added a fourth hash here, the SCATTER layout, and is itself the worked example of that
##      rule: it deliberately moved scatter (biome classification now obeys D-144) and left the other
##      three untouched, so its close-out re-captured one constant and proved the rest still passed.
##   4. SPEED — sampling through a shared set is meaningfully cheaper per sample than rebuilding.
##      Relative, same-process, same-machine: an absolute number here would only measure the box.
##
## Cross-platform bit-identity of the underlying float ops stays `tools/check_determinism.gd`'s job.

## Preloaded, never named bare: a script new to this session is not in
## .godot/global_script_class_cache.cfg yet (F-016).
const IslandHeightmap = preload("res://world/gen/island_heightmap.gd")
const BiomeMap = preload("res://world/gen/biome_map.gd")
const PoiMap = preload("res://world/gen/poi_map.gd")
const ResourceScatter = preload("res://world/gen/resource_scatter.gd")

const SEEDS: Array[int] = [1, 20260819, -77, 0x5EED, 999983]

## Captured at 17bacba, before F-261's first edit, with the bare `sites_for_island()` /
## `biome_at()` / `moisture()` / `terrain_amplitudes()` API. See point 3 in the header.
const GOLDEN_POI: Dictionary = {
	1: "ec0e4e28abd1fcfb",
	20260819: "fa265c12b7ff0318",
	-77: "6fa64b61bbac0256",
	0x5EED: "0d5110a470a06993",
	999983: "8036675b339ac2c8",
}
const GOLDEN_BIOME: Dictionary = {
	1: "1c3ed123238a5fc0",
	20260819: "ec7e068c82caff15",
	-77: "1b4a559bda6f8b5e",
	0x5EED: "537fc99b71f55371",
	999983: "0f57083774aa3f1b",
}
const GOLDEN_AMPLITUDES: Dictionary = {
	1: "c75d6cacc238bc59",
	20260819: "b1979946182f8ba5",
	-77: "7a5196113765b5cb",
	0x5EED: "c72cdd79cb349965",
	999983: "bf2f672a4de972a9",
}
## Captured AFTER F-271, and deliberately so: F-271 is the change these three siblings were watching
## for, and scatter had no witness of its own when it landed. The pre-F-271 values, for the record,
## were e1b81b6cdf97bb57 / 0ba6f0e311c68e58 / eadd61e208e89c9f / 357d154af9590f1a / 8ff13290e7187f75
## — every one of them moved when scatter stopped classifying its points from `height()`. From here
## on, scatter layout is a tripwire like the other three: a worldgen refactor that moves it must say
## so and re-capture, and one that claims to move nothing must leave it alone.
const GOLDEN_SCATTER: Dictionary = {
	1: "428ea591736623cc",
	20260819: "1fb5f19469c5fc2f",
	-77: "559e522d6b5d2706",
	0x5EED: "906faea3771ca932",
	999983: "de9ffaa1d503238d",
}

var failures: int = 0
var poi_defs: Array = []
var biome_defs: Array = []
var scatter_defs: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var registry: Node = root.get_node_or_null(^"Registry")
	_check(registry != null and registry.has_method(&"poi_defs"),
		"Registry exposes the poi family")
	if registry == null or not registry.has_method(&"poi_defs"):
		_finish()
		return
	poi_defs = (registry.call("poi_defs") as Dictionary).values()
	biome_defs = (registry.get(&"biomes") as Dictionary).values()
	scatter_defs = (registry.get(&"scatter_tables") as Dictionary).values()
	_check(poi_defs.size() >= 3, "content/poi/ loaded %d def(s)" % poi_defs.size())
	_check(not biome_defs.is_empty(), "content biome defs loaded (%d)" % biome_defs.size())
	_check(not scatter_defs.is_empty(), "content scatter tables loaded (%d)" % scatter_defs.size())

	_check_equivalence()
	_check_adoption()
	_check_layout_unchanged()
	_check_poi_determinism()
	_check_speedup()

	print("\nWORLDGEN_NOISE_REUSE failures=%d" % failures)
	_finish()


func _check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _finish() -> void:
	quit(1 if failures > 0 else 0)


## A grid wide enough to cross the falloff edge, the river corridor and several biome boundaries —
## not just flat interior, where every path agrees by accident.
func _check_equivalence() -> void:
	print("\n== every *_from_set call is bit-identical to its bare sibling ==")
	for world_seed: int in SEEDS:
		var set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed)
		var moisture_bad: int = 0
		var continent_bad: int = 0
		var biome_bad: int = 0
		var amplitude_bad: int = 0
		var samples: int = 0
		for gx in range(-9, 10):
			for gz in range(-9, 10):
				var x: float = float(gx) * 17.0
				var z: float = float(gz) * 17.0
				samples += 1
				if BiomeMap.moisture(x, z, world_seed) != BiomeMap.moisture_from_set(x, z, set):
					moisture_bad += 1
				if IslandHeightmap.continent(x, z, world_seed) \
						!= IslandHeightmap.continent_from_set(x, z, set.island, world_seed):
					continent_bad += 1
				if BiomeMap.biome_at(x, z, world_seed, biome_defs) \
						!= BiomeMap.biome_at_from_set(x, z, set, world_seed, biome_defs):
					biome_bad += 1
				if BiomeMap.terrain_amplitudes(x, z, world_seed, biome_defs) \
						!= BiomeMap.terrain_amplitudes_from_set(x, z, set, world_seed, biome_defs):
					amplitude_bad += 1
		_check(moisture_bad == 0, "seed %d: moisture_from_set matches moisture on %d samples"
			% [world_seed, samples], "%d mismatched" % moisture_bad)
		_check(continent_bad == 0, "seed %d: continent_from_set matches continent on %d samples"
			% [world_seed, samples], "%d mismatched" % continent_bad)
		_check(biome_bad == 0, "seed %d: biome_at_from_set matches biome_at on %d samples"
			% [world_seed, samples], "%d mismatched" % biome_bad)
		_check(amplitude_bad == 0,
			"seed %d: terrain_amplitudes_from_set matches terrain_amplitudes on %d samples"
			% [world_seed, samples], "%d mismatched" % amplitude_bad)


## ResourceScatter hands its own already-built island set to BiomeMap.make_noise_set() rather than
## paying for a second one. That shortcut is only safe if an adopted set answers identically.
func _check_adoption() -> void:
	print("\n== an adopted IslandHeightmap.NoiseSet answers identically to a self-built one ==")
	for world_seed: int in SEEDS:
		var island: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(world_seed)
		var adopted: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed, island)
		var own: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed)
		_check(adopted.island == island, "seed %d: the passed island set is adopted, not copied"
			% world_seed)
		var mismatches: int = 0
		for gx in range(-7, 8):
			for gz in range(-7, 8):
				var x: float = float(gx) * 21.0
				var z: float = float(gz) * 21.0
				if BiomeMap.biome_at_from_set(x, z, adopted, world_seed, biome_defs) \
						!= BiomeMap.biome_at_from_set(x, z, own, world_seed, biome_defs):
					mismatches += 1
				if BiomeMap.moisture_from_set(x, z, adopted) != BiomeMap.moisture_from_set(x, z, own):
					mismatches += 1
		_check(mismatches == 0, "seed %d: adopted and self-built sets agree everywhere" % world_seed,
			"%d mismatched" % mismatches)


## The tripwire. Same hashes as the pre-F-261 code produced, or the refactor moved the world.
func _check_layout_unchanged() -> void:
	print("\n== the island is byte-for-byte the one the pre-F-261 code generated ==")
	for world_seed: int in SEEDS:
		var sites: Array = PoiMap.sites_for_island(world_seed, poi_defs, biome_defs)
		var actual: String = _poi_hash(sites)
		_check(actual == String(GOLDEN_POI[world_seed]),
			"seed %d: %d POI site(s) hash to the pre-fix value" % [world_seed, sites.size()],
			"%s, expected %s" % [actual, GOLDEN_POI[world_seed]])

		var biome_actual: String = _biome_hash(world_seed)
		_check(biome_actual == String(GOLDEN_BIOME[world_seed]),
			"seed %d: the biome/moisture grid hashes to the pre-fix value" % world_seed,
			"%s, expected %s" % [biome_actual, GOLDEN_BIOME[world_seed]])

		var amplitude_actual: String = _amplitude_hash(world_seed)
		_check(amplitude_actual == String(GOLDEN_AMPLITUDES[world_seed]),
			"seed %d: the terrain-amplitude grid hashes to the pre-fix value" % world_seed,
			"%s, expected %s" % [amplitude_actual, GOLDEN_AMPLITUDES[world_seed]])

		var scatter_actual: String = _scatter_hash(world_seed)
		_check(scatter_actual == String(GOLDEN_SCATTER[world_seed]),
			"seed %d: the scatter layout hashes to its post-F-271 value" % world_seed,
			"%s, expected %s" % [scatter_actual, GOLDEN_SCATTER[world_seed]])


## Every placement an 8x8 block of chunks around the origin produces: which point, which asset, and
## where it stands. `point_id` alone would not notice a point that kept its identity and moved, and
## `position` alone would not notice two points swapping assets, so both go in.
func _scatter_hash(world_seed: int) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for cx in range(-4, 4):
		for cz in range(-4, 4):
			var placements: Array[Dictionary] = ResourceScatter.placements_for_chunk(
				cx, cz, world_seed, scatter_defs, biome_defs)
			for placement: Dictionary in placements:
				ctx.update(String(placement["point_id"]).to_utf8_buffer())
				ctx.update(String(placement["asset"]).to_utf8_buffer())
				var p: Vector3 = placement["position"]
				ctx.update(PackedFloat64Array([p.x, p.y, p.z]).to_byte_array())
	return ctx.finish().hex_encode().substr(0, 16)


## poi_check.gd already asserts this for its own seeds; repeated here because F-261 introduced a
## piece of state (one NoiseSet shared across every def in one island) into a generator that had
## none, and "shared state leaked between defs" is exactly what that buys you if it is ever mutable.
func _check_poi_determinism() -> void:
	print("\n== one shared NoiseSet per island did not make placement order-dependent ==")
	for world_seed: int in SEEDS:
		var first: Array = PoiMap.sites_for_island(world_seed, poi_defs, biome_defs)
		var second: Array = PoiMap.sites_for_island(world_seed, poi_defs, biome_defs)
		_check(_poi_hash(first) == _poi_hash(second),
			"seed %d places identically twice in one process" % world_seed)


## Relative, same-process. The primitive being timed is one biome resolution — a continent sample
## plus a moisture sample plus the def scan — which is what PoiMap's dart loop and terrain_map_render
## both pay per point.
func _check_speedup() -> void:
	print("\n== resolving through a shared set beats rebuilding noise per sample ==")
	const SIDE: int = 24
	const REPEATS: int = 3
	const SEED: int = 20260819

	var t0: int = Time.get_ticks_usec()
	for r in REPEATS:
		for gz in SIDE:
			for gx in SIDE:
				var _b: StringName = BiomeMap.biome_at(float(gx) * 7.0, float(gz) * 7.0, SEED, biome_defs)
	var bare_us: float = float(Time.get_ticks_usec() - t0) / float(REPEATS * SIDE * SIDE)

	var t1: int = Time.get_ticks_usec()
	for r in REPEATS:
		var set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(SEED)
		for gz in SIDE:
			for gx in SIDE:
				var _b: StringName = BiomeMap.biome_at_from_set(
					float(gx) * 7.0, float(gz) * 7.0, set, SEED, biome_defs)
	var shared_us: float = float(Time.get_ticks_usec() - t1) / float(REPEATS * SIDE * SIDE)

	print("  per-call biome_at():      %.3f us/sample" % bare_us)
	print("  shared BiomeMap.NoiseSet: %.3f us/sample" % shared_us)
	print("  speedup:                  %.2fx" % (bare_us / maxf(shared_us, 0.0001)))
	# Same 1.3x floor noise_reuse_check.gd uses, and for the same reason: most of a sample's cost is
	# the SAMPLING (fractal octaves, domain warp, the river polyline walk), which both paths pay
	# identically. The floor is set to catch a broken reuse — a set rebuilt per sample by accident —
	# not to certify a particular speed on a machine running six agents at once.
	_check(shared_us * 1.3 < bare_us, "a shared set is meaningfully faster per sample",
		"%.3f us vs %.3f us" % [shared_us, bare_us])


## Position, rotation, biome and site id — everything a peer could disagree about. Floats fed as
## raw bytes, never rounded strings, because a rounded compare hides exactly the small drift a
## refactor like this one could introduce.
func _poi_hash(sites: Array) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for site: Dictionary in sites:
		ctx.update(String(site["site_id"]).to_utf8_buffer())
		ctx.update(String(site["biome"]).to_utf8_buffer())
		var p: Vector3 = site["position"]
		ctx.update(PackedFloat64Array([p.x, p.y, p.z, float(site["rotation_y"])]).to_byte_array())
	return ctx.finish().hex_encode().substr(0, 16)


func _biome_hash(world_seed: int) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for gx in range(-16, 17):
		for gz in range(-16, 17):
			var x: float = float(gx) * 9.5
			var z: float = float(gz) * 9.5
			ctx.update(String(BiomeMap.biome_at(x, z, world_seed, biome_defs)).to_utf8_buffer())
			ctx.update(PackedFloat64Array([BiomeMap.moisture(x, z, world_seed)]).to_byte_array())
	return ctx.finish().hex_encode().substr(0, 16)


func _amplitude_hash(world_seed: int) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for gx in range(-12, 13):
		for gz in range(-12, 13):
			var a: Vector2 = BiomeMap.terrain_amplitudes(
				float(gx) * 11.0, float(gz) * 11.0, world_seed, biome_defs)
			ctx.update(PackedFloat64Array([a.x, a.y]).to_byte_array())
	return ctx.finish().hex_encode().substr(0, 16)
