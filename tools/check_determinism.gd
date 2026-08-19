extends SceneTree

## Preloaded rather than referenced by bare class_name: a script new to this session is not yet in
## .godot/global_script_class_cache.cfg, so a --script run that names it bare fails "Identifier not
## declared" (F-016, same fix tools/handshake_check.gd uses for NetVersion).
const IslandHeightmap = preload("res://world/gen/island_heightmap.gd")

## Cross-platform determinism probe (risk R6).
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/check_determinism.gd
##
## WHY THIS MATTERS
## ARCHITECTURE.md §4 has every client regenerate the island locally from a shared seed, so the
## network never carries terrain. That only works if identical seeds produce byte-identical results on
## every platform we ship to. IEEE-754 add/sub/mul/div are exact everywhere, but transcendentals
## (sin/cos/pow/exp) are NOT guaranteed identical across CPU architectures and compilers — and noise
## generation leans on them.
##
## If macOS arm64 and Windows x86_64 disagree, two players in the same lobby stand on different
## islands: resources in different places, collision that doesn't match what they see.
##
## HOW TO USE
## Run on macOS, run on Windows, compare the hashes. All four must match across platforms.
## Record the result in DECISIONS.md.
##
## If they DIVERGE, the fallback is in ARCHITECTURE.md §6 R6: the host generates and ships a compact
## heightmap to clients instead of everyone regenerating.

const GRID := 64
const SEED := 20260815


func _initialize() -> void:
	print("\nplatform : %s" % OS.get_name())
	print("arch     : %s" % Engine.get_architecture_name())
	print("godot    : %s" % Engine.get_version_info().get("string", "?"))
	print("")

	print("rng_sequence   %s" % _hash_rng())
	print("noise_simplex  %s" % _hash_noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH))
	print("noise_perlin   %s" % _hash_noise(FastNoiseLite.TYPE_PERLIN))
	print("continent      %s" % _hash_continent())
	print("river          %s" % _hash_river())
	print("ridge_mask     %s" % _hash_ridge_mask())
	print("float_math     %s" % _hash_float_math())
	print("terrain_hash   %s" % _hash_terrain())

	print("\nAll five must match on macOS and Windows. Record in DECISIONS.md.")
	quit()


## Bit-exact hash of a float. Comparing rounded strings would hide exactly the small
## discrepancies we are hunting for.
func _feed(ctx: HashingContext, value: float) -> void:
	var bytes := PackedFloat64Array([value]).to_byte_array()
	ctx.update(bytes)


func _digest(ctx: HashingContext) -> String:
	return ctx.finish().hex_encode().substr(0, 16)


## Integer PRNG — should be identical everywhere. If this differs, nothing else can be trusted.
func _hash_rng() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in 4096:
		ctx.update(PackedInt64Array([rng.randi()]).to_byte_array())
	# randf() adds float conversion on top of the integer stream.
	for i in 4096:
		_feed(ctx, rng.randf())
	return _digest(ctx)


## The one that actually decides whether shared-seed terrain is viable.
func _hash_noise(type: FastNoiseLite.NoiseType) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var noise := FastNoiseLite.new()
	noise.noise_type = type
	noise.seed = SEED
	noise.frequency = 0.013
	noise.fractal_octaves = 5
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5
	for y in GRID:
		for x in GRID:
			_feed(ctx, noise.get_noise_2d(float(x) * 3.7, float(y) * 3.7))
	return _digest(ctx)


## Transcendentals and the island falloff shape, which is where divergence is most likely.
func _hash_float_math() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for i in 2048:
		var t: float = float(i) * 0.017
		_feed(ctx, sin(t))
		_feed(ctx, cos(t))
		_feed(ctx, pow(t + 1.0, 1.7))
		_feed(ctx, sqrt(t + 1.0))
		_feed(ctx, exp(t * 0.01))
		# The island falloff from ARCHITECTURE.md §4, in the shape it will actually be used.
		var d: float = Vector2(t - 17.0, t * 0.5 - 9.0).length() / 24.0
		_feed(ctx, clampf(1.0 - pow(d, 3.0), 0.0, 1.0))
	return _digest(ctx)


## Task 4.1's island heightmap, exercised end to end: both noise layers plus the island falloff.
## This is the real terrain pipeline, not a standalone probe of its parts — if this diverges across
## platforms while the four probes above don't, the bug is in island_heightmap.gd's own arithmetic,
## not in an engine primitive.
## 4.13's two new operations, probed separately from the combined surface so a
## cross-platform mismatch says WHICH one drifted. Domain warp and ridged fractal
## are both FastNoiseLite-internal, which is exactly why they are cheap to trust
## and exactly why they still have to be measured (D-142).
## 4.14's river: the polyline control points AND carved samples along the corridor, hashed
## separately so a cross-platform drift says whether the GEOMETRY moved (integer mixing — should
## never drift) or the CARVE did (float lerp/smoothstep chain — the plausible suspect).
func _hash_river() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var line: PackedVector2Array = IslandHeightmap.river_polyline(SEED)
	for point: Vector2 in line:
		_feed(ctx, point.x)
		_feed(ctx, point.y)
	for step in range(0, 33):
		var t: float = float(step) / 32.0
		var total: float = 0.0
		for index in range(line.size() - 1):
			total += line[index].distance_to(line[index + 1])
		var walked: float = total * t
		var probe: Vector2 = line[0]
		for index in range(line.size() - 1):
			var segment_length: float = line[index].distance_to(line[index + 1])
			if walked <= segment_length or index == line.size() - 2:
				probe = line[index] + (line[index + 1] - line[index]) \
					* (walked / segment_length if segment_length > 0.0 else 0.0)
				break
			walked -= segment_length
		_feed(ctx, IslandHeightmap.height(probe.x, probe.y, SEED))
		_feed(ctx, IslandHeightmap.height(probe.x + 5.0, probe.y - 3.0, SEED))
	return _digest(ctx)


func _hash_continent() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for x in range(-6, 7):
		for z in range(-6, 7):
			_feed(ctx, IslandHeightmap.continent(float(x) * 37.0, float(z) * 37.0, SEED))
	return _digest(ctx)


func _hash_ridge_mask() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for step in range(0, 41):
		_feed(ctx, IslandHeightmap.ridge_mask(float(step) * 1.5))
	return _digest(ctx)


func _hash_terrain() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for gz in GRID:
		for gx in GRID:
			# Spread samples across several hundred metres so the grid crosses the island falloff
			# edge (radius 512m) as well as the interior — a grid that never leaves flat interior
			# noise couldn't catch a falloff-math regression.
			var x: float = (float(gx) - float(GRID) * 0.5) * 24.0
			var z: float = (float(gz) - float(GRID) * 0.5) * 24.0
			_feed(ctx, IslandHeightmap.height(x, z, SEED))
	return _digest(ctx)
