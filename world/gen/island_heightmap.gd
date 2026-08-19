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
##
## 0.78 rather than the original 0.55: the wider taper left a ~230 m annulus of
## ground sitting within a metre or two of sea level, which renders as a beach
## ring around the whole island and gives `shore` most of the coast to itself. A
## shore should be tens of metres of sand, and the drop into water should be
## something a player can see happening.
const FALLOFF_START_FRACTION: float = 0.78
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
## Peak metres the masked ridged layer may add on top of the continent.
const RIDGE_WEIGHT: float = 22.0

## Domain warp: the coastline's own coordinates are pushed around by a second
## noise field before the continental noise is sampled, which is what turns fBm's
## characteristic soft blobs into bays, spits and headlands. FastNoiseLite applies
## it inside `get_noise_2d` when enabled, so it is the same trusted, integer-seeded
## library and adds no float operations of our own — the determinism requirement
## D-142 puts on every new generator operation (probe extended in this task).
##
## The warp shares the base layer's seed, because FastNoiseLite has one `seed` per
## instance and the warp reads it. That is why there is no WARP_NOISE_SALT: a salt
## that cannot be applied is a constant that lies about what it controls.
const WARP_AMPLITUDE: float = 46.0
const WARP_FREQUENCY: float = 0.0075
const WARP_OCTAVES: int = 2

## Ridged layer: sharp-crested noise, MASKED so it only appears where the
## continent is already high. Ridges everywhere is a spiky planet; ridges on the
## high ground is a mountain range with foothills, which is the shape Hollowmere
## got by hand and the one D-142 asks for procedurally.
const RIDGE_FREQUENCY: float = 0.021
const RIDGE_OCTAVES: int = 4
const RIDGE_LACUNARITY: float = 2.1
const RIDGE_GAIN: float = 0.48
## Where the ridged layer starts and reaches full strength, as a fraction of the
## unmasked continental height. Below the first number there is none at all.
const RIDGE_MASK_START: float = 0.14
const RIDGE_MASK_FULL: float = 0.52

const BASE_NOISE_SALT: int = 0x5F10A
const DETAIL_NOISE_SALT: int = 0x9E3779B9
const RIDGE_NOISE_SALT: int = 0x2FA5E1

## Continental lift. Simplex returns roughly -1..1 centred on zero, so a bare
## `noise * mask` puts half the island's interior below sea level and the result
## is an archipelago of ponds, not an island — visible immediately in
## `tools/terrain_map_render.gd`'s top-down render, and not visible at all from a
## chunk of it at ground level, which is why that tool exists.
##
## Adding a bias before the mask moves the whole interior up so land is connected
## and the coast is where the noise dips below the bias, rather than wherever it
## happens to cross zero. The mask then brings the edge down through sea level on
## its own, which is what makes a beach a beach instead of a ring.
const LAND_BIAS: float = 0.46

## How far the coastline wanders in and out, in metres, and how quickly it does
## so. Without this the falloff is a circle and the island renders as a coin with
## a sand rim — geometrically an island, visually a token. The mask reads a
## jittered radius instead of the true one, so the shore is ragged for the same
## reason a real one is: the land does not end at a constant distance.
const COAST_JITTER: float = 74.0
const COAST_FREQUENCY: float = 0.0042
const COAST_NOISE_SALT: int = 0x7A11C0


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
static func _island_mask(x: float, z: float, jitter: float = 0.0) -> float:
	# The jitter moves the shoreline in and out, so both thresholds below apply to
	# a distance that varies around the island instead of a perfect circle.
	var dist: float = Vector2(x, z).length() - jitter
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
## The CONTINENT: warped fBm through the island mask, and nothing else. This is
## the half of the terrain that decides where land is, and it is deliberately
## biome-independent — `BiomeMap` reads it to decide which biome a point is in, so
## anything that varied with biome here would be circular (D-144). Every caller
## that wants "which biome is this" wants this number, not `height()`.
static func _make_continent_noise(world_seed: int) -> FastNoiseLite:
	var base_noise := _make_noise(
		world_seed ^ BASE_NOISE_SALT, BASE_NOISE_FREQUENCY, BASE_NOISE_OCTAVES,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	base_noise.domain_warp_enabled = true
	base_noise.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
	base_noise.domain_warp_amplitude = WARP_AMPLITUDE
	base_noise.domain_warp_frequency = WARP_FREQUENCY
	base_noise.domain_warp_fractal_type = FastNoiseLite.DOMAIN_WARP_FRACTAL_PROGRESSIVE
	base_noise.domain_warp_fractal_octaves = WARP_OCTAVES
	return base_noise


static func continent(x: float, z: float, world_seed: int) -> float:
	var base_noise := _make_continent_noise(world_seed)
	var coast_noise := _make_noise(
		world_seed ^ COAST_NOISE_SALT, COAST_FREQUENCY, 3, BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	var jitter: float = coast_noise.get_noise_2d(x, z) * COAST_JITTER
	var shaped: float = base_noise.get_noise_2d(x, z) + LAND_BIAS
	return shaped * HEIGHT_SCALE * _island_mask(x, z, jitter)


## How much of the ridged layer applies at this continental height: none in the
## lowlands, all of it on the high ground, smooth in between. Written with
## `smoothstep` because a linear ramp puts a visible crease along the line where
## ridges switch on, and that crease reads as a terrace nobody built.
static func ridge_mask(continent_height: float) -> float:
	var low: float = RIDGE_MASK_START * HEIGHT_SCALE
	var high: float = RIDGE_MASK_FULL * HEIGHT_SCALE
	return smoothstep(low, high, continent_height)


## The full surface: continent + the rough layers, scaled by the amplitudes the
## point's own biome authors. `detail_amplitude` and `ridge_amplitude` come from
## the BiomeDef; passing 1.0/1.0 gives the biome-blind terrain, which is what a
## caller with no biome table (and `BiomeMap` itself) gets.
static func height(x: float, z: float, world_seed: int,
		detail_amplitude: float = 1.0, ridge_amplitude: float = 1.0) -> float:
	var base_noise := _make_continent_noise(world_seed)
	var coast_noise := _make_noise(
		world_seed ^ COAST_NOISE_SALT, COAST_FREQUENCY, 3, BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	var jitter: float = coast_noise.get_noise_2d(x, z) * COAST_JITTER
	var mask: float = _island_mask(x, z, jitter)
	var continent_height: float = (base_noise.get_noise_2d(x, z) + LAND_BIAS) * HEIGHT_SCALE * mask

	var detail_noise := _make_noise(
		world_seed ^ DETAIL_NOISE_SALT, DETAIL_NOISE_FREQUENCY, DETAIL_NOISE_OCTAVES,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	var detail: float = detail_noise.get_noise_2d(x, z) * DETAIL_NOISE_WEIGHT * detail_amplitude

	var ridge_noise := _make_noise(
		world_seed ^ RIDGE_NOISE_SALT, RIDGE_FREQUENCY, RIDGE_OCTAVES,
		RIDGE_LACUNARITY, RIDGE_GAIN)
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	# Ridged noise returns roughly 0..1 rather than -1..1, so it is re-centred
	# before scaling: added raw it would lift every high point by half a layer and
	# quietly raise the snow line.
	var ridged: float = (ridge_noise.get_noise_2d(x, z) - 0.5) * 2.0
	var ridge: float = ridged * ridge_mask(continent_height) * ridge_amplitude * RIDGE_WEIGHT

	# Both rough layers ride the island mask too, so the coastline stays where the
	# continent put it and an island does not grow a rocky halo out to sea.
	return continent_height + (detail * HEIGHT_SCALE + ridge) * mask
