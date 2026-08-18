class_name IslandHeightmap
extends RefCounted

## Task 4.1 — seeded island heightmap (docs/ARCHITECTURE.md §4 pipeline step 1).
##
## `height(x, z, world_seed)` is a pure function: no nodes, no instance state, no engine state
## beyond a freshly seeded FastNoiseLite built inside the call. Same (x, z, world_seed) produces
## the identical float on every platform we ship to (macOS/Windows/Linux, all measured — D-017,
## D-028), because every operation here stays inside the §7 safe set: `+ − × ÷`, `sqrt`,
## `Vector2.length()`, and `FastNoiseLite` itself. No `sin`/`cos`/`pow`/`exp`/`log` — those resolve
## to the platform's libm and are not bit-identical across CPU architectures (D-017). The falloff
## below is `1.0 - t*t*t`, never `1.0 - pow(t, 3.0)`.
##
## No RNG here: a continuous height field needs none, only noise. The seed-derivation convention
## it establishes for the RNG-driven subsystems still to come (POI placement, resource scatter) is
## the one `world/gen/undergrowth.gd` already uses — XOR the shared world seed with a per-subsystem
## salt constant, so every subsystem's stream is independent even though they all trace back to one
## shared seed. `BASE_NOISE_SALT`/`DETAIL_NOISE_SALT` below are that pattern applied to noise seeds.

## Island radius in metres, measured from world origin. Matches the Mire grid's own coverage
## (`docs/ARCHITECTURE.md` §5: 256×256 cells at ~4m/cell = 1024m across), so the corruption sim and
## the terrain it tints cover the same ground.
const ISLAND_RADIUS: float = 512.0
## Fraction of ISLAND_RADIUS where the falloff begins. Inside this, height is unmasked; outside,
## it tapers cubically to 0 at ISLAND_RADIUS.
const FALLOFF_START_FRACTION: float = 0.55
## Peak terrain amplitude in metres, before the island mask is applied. Placeholder-tuned, like
## every other early M4 magnitude — the real pass waits for 4.2's biomes and something to look at.
const HEIGHT_SCALE: float = 60.0

## Continental layer: low frequency, several octaves, decides the island's overall landmass shape.
const BASE_NOISE_FREQUENCY: float = 0.006
const BASE_NOISE_OCTAVES: int = 5
const BASE_NOISE_LACUNARITY: float = 2.0
const BASE_NOISE_GAIN: float = 0.5
## Detail layer: higher frequency, fewer octaves, small weight — adds fine variation on top of the
## continental shape without changing it. This is the "layered" half of "layered simplex": two
## independent noise fields at different scales, summed, rather than one fractal call alone.
const DETAIL_NOISE_FREQUENCY: float = 0.05
const DETAIL_NOISE_OCTAVES: int = 2
const DETAIL_NOISE_WEIGHT: float = 0.08

const BASE_NOISE_SALT: int = 0x5F10A
const DETAIL_NOISE_SALT: int = 0x9E3779B9


## One per call, not shared — cheap to build, and a shared FastNoiseLite is not safe to sample from
## several WorkerThreadPool tasks at once (same rule `world/chunk/chunk_mesher.gd` documents).
static func _make_noise(noise_seed: int, frequency: float, octaves: int, lacunarity: float, gain: float) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_lacunarity = lacunarity
	noise.fractal_gain = gain
	return noise


## Radial island mask: 1.0 out to FALLOFF_START_FRACTION of the radius, cubic taper to 0.0 at the
## radius, 0.0 beyond it. `t*t*t`, never `pow(t, 3.0)` — see the file header and D-017.
static func _island_mask(x: float, z: float) -> float:
	var dist: float = Vector2(x, z).length()
	var falloff_start: float = ISLAND_RADIUS * FALLOFF_START_FRACTION
	if dist <= falloff_start:
		return 1.0
	if dist >= ISLAND_RADIUS:
		return 0.0
	var t: float = (dist - falloff_start) / (ISLAND_RADIUS - falloff_start)
	var inv: float = 1.0 - t
	return inv * inv * inv


## The pure heightmap function. Deterministic for a given (x, z, world_seed): rebuilding both
## noise sources per call costs a small allocation but guarantees no shared mutable state, which is
## what makes this safe to call from any thread and what makes "same inputs, same output" hold
## without qualification.
static func height(x: float, z: float, world_seed: int) -> float:
	var base_noise := _make_noise(
		world_seed ^ BASE_NOISE_SALT, BASE_NOISE_FREQUENCY, BASE_NOISE_OCTAVES,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	var detail_noise := _make_noise(
		world_seed ^ DETAIL_NOISE_SALT, DETAIL_NOISE_FREQUENCY, DETAIL_NOISE_OCTAVES,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)

	var base: float = base_noise.get_noise_2d(x, z)
	var detail: float = detail_noise.get_noise_2d(x, z)
	var combined: float = base + detail * DETAIL_NOISE_WEIGHT

	return combined * HEIGHT_SCALE * _island_mask(x, z)
