extends SceneTree

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
	print("float_math     %s" % _hash_float_math())

	print("\nAll four must match on macOS and Windows. Record in DECISIONS.md.")
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
