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

## Island radius in metres, measured from world origin.
##
## 118 m — an island about **236 m across**, in the same class as the hand-authored Hollowmere
## (192 m, D-045) and the size a run of one evening can actually cover. The first procedural cut
## used 512 m to match the Mire grid's 1024 m coverage (`docs/ARCHITECTURE.md` §5), and rendering it
## top-down showed the mistake immediately: a landmass filling the whole frame, which is a continent
## with a shoreline, not an island in an ocean. The grid still covers more ground than the island —
## that is harmless, it simply means most cells are open water, and it is the right way round:
## terrain sized to the run, not to the simulation's bookkeeping.
const ISLAND_RADIUS: float = 118.0

## The SHAPE layers — continental noise, its domain warp, and the coastline jitter — are authored
## against a 512 m island and scaled to whatever `ISLAND_RADIUS` actually is, so a smaller island
## has the same number of bays and headlands rather than cropping out most of them.
##
## The TEXTURE layers — detail and ridges — deliberately do NOT scale. A ridge is a landform tens of
## metres across and a bump underfoot is a few metres, whatever size the island is; scaling them
## with the island put ridge crests 11 m apart and turned the interior into a sponge of tiny lakes
## and white spikes. Shape scales with the place, texture stays the size a person is.
const _FREQUENCY_REFERENCE_RADIUS: float = 512.0
const FREQUENCY_SCALE: float = _FREQUENCY_REFERENCE_RADIUS / ISLAND_RADIUS

## Peak terrain amplitude in metres, before the island mask is applied.
##
## 11 m, down from 26 (which was down from 60): Sequoyah's island-feel direction after seeing the
## first shipped procedural island (2026-08-20, 4.18's tuning input) — "mostly flat, some gentle
## rolling hills is nice but no mountains, look at Muck for reference." At 26 the island rendered
## as a massif; at 11, with the raised LAND_BIAS below, the interior settles around 5-12 m of
## gentle roll a player can sprint straight across.
const HEIGHT_SCALE: float = 11.0

## How much of the continental noise actually reaches the surface. His second verdict (2026-08-20,
## same day, off the first retune's renders): "still wayyy too steep on the hills, im thinking like
## 3-5 hills on the whole island." Rolling fBm everywhere is the wrong STRUCTURE for that, not just
## the wrong amplitude — the interior is now a near-flat plateau (this weight damps the noise to
## about ±1 m of undulation at the base frequency's ~38 m wavelength) and the hills are PLACED
## landforms below (`HILL_*`), countable the way he counted them.
const BASE_NOISE_WEIGHT: float = 0.25

## THE HILLS (D-184, second pass) — 3 to 5 per island, placed, not emergent.
##
## Same recipe as `lobes()`/`islet_centres()`: positions from integer mixing on the direction
## table, radii and heights from modulo spreads, all inside the D-017 safe set. Each hill is a
## smooth radial mound (`t*t*(3-2t)` — smoothstep's polynomial, no libm); overlapping hills take
## `maxf` like the lobe masks do, so two neighbours merge into a broader rise instead of stacking
## into a peak. Slope stays around 7 m over 35+ m of run — a place you walk up without thinking.
const HILL_COUNT_MIN: int = 3
const HILL_COUNT_MAX: int = 5
## Centre offset from the island's middle, as a fraction of ISLAND_RADIUS. Capped at 0.62 so a
## hill's toe stays on the plateau rather than sliding into the coastal falloff.
const HILL_OFFSET_MAX: float = 0.62
const HILL_RADIUS_MIN: float = 26.0     # metres
const HILL_RADIUS_MAX: float = 52.0
const HILL_HEIGHT_MIN: float = 5.0      # metres of lift at the crown
const HILL_HEIGHT_MAX: float = 8.0
const HILL_SALT: int = 0x48C3D1
## Fraction of ISLAND_RADIUS where the falloff begins. Inside this, height is unmasked; outside,
## it tapers cubically to 0 at ISLAND_RADIUS.
##
## 0.78 rather than the original 0.55: the wider taper left a ~230 m annulus of
## ground sitting within a metre or two of sea level, which renders as a beach
## ring around the whole island and gives `shore` most of the coast to itself. A
## shore should be tens of metres of sand, and the drop into water should be
## something a player can see happening.
const FALLOFF_START_FRACTION: float = 0.78
## Continental layer: low frequency, several octaves, decides the island's overall landmass shape.
const BASE_NOISE_FREQUENCY: float = 0.006 * FREQUENCY_SCALE
const BASE_NOISE_OCTAVES: int = 5
const BASE_NOISE_LACUNARITY: float = 2.0
const BASE_NOISE_GAIN: float = 0.5
## Detail layer: higher frequency, fewer octaves, small weight — adds fine variation on top of the
## continental shape without changing it. This is the "layered" half of "layered simplex": two
## independent noise fields at different scales, summed, rather than one fractal call alone.
const DETAIL_NOISE_FREQUENCY: float = 0.05
const DETAIL_NOISE_OCTAVES: int = 2
const DETAIL_NOISE_WEIGHT: float = 0.08
## Peak metres the masked ridged layer may add. Sized against HEIGHT_SCALE: at 22
## on a 26 m island the layer was the terrain rather than a feature on it, and at 8.5 the crests
## still read as a mountain range — the exact thing the Muck-reference direction rules out. 2 m,
## multiplied by the biome amplitudes (forest 0.9, grassland 0.25), is rolling texture on the high
## ground, not a skyline.
const RIDGE_WEIGHT: float = 2.0

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
const WARP_AMPLITUDE: float = 46.0 / FREQUENCY_SCALE
const WARP_FREQUENCY: float = 0.0075 * FREQUENCY_SCALE
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
## Where a crest starts, in the ridged fractal's own range, and how sharply it
## rises past it. Below the threshold there is no ridge at all — that is the flat
## ground between ranges.
const RIDGE_THRESHOLD: float = 0.18
const RIDGE_GATHER: float = 1.7

## Raised with the flat-plateau restructure: the plateau sits around 0.75 x HEIGHT_SCALE, so the
## old 0.14/0.52 window put ridge texture on ALL of it. Starting just above the plateau confines
## the cresting to the placed hills' upper slopes — the only high ground left.
const RIDGE_MASK_START: float = 0.95
const RIDGE_MASK_FULL: float = 1.30

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
##
## 0.75 (was 0.54), raised together with the HEIGHT_SCALE drop to 11: the bias sets where the
## interior SITS and the scale sets how much it rolls, and the two must move together or the
## flatter island sinks — at 0.54 x 11 the interior centred on 5.9 m and every ordinary noise dip
## fell under the 4 m shore/grassland biome boundary, scattering sand through the meadows.
const LAND_BIAS: float = 0.75

## How far the coastline wanders in and out, in metres, and how quickly it does
## so. Without this the falloff is a circle and the island renders as a coin with
## a sand rim — geometrically an island, visually a token. The mask reads a
## jittered radius instead of the true one, so the shore is ragged for the same
## reason a real one is: the land does not end at a constant distance.
const COAST_JITTER: float = 74.0 / FREQUENCY_SCALE
const COAST_FREQUENCY: float = 0.0042 * FREQUENCY_SCALE
const COAST_NOISE_SALT: int = 0x7A11C0

## The island's gross form: a union of overlapping LOBES, not a disc.
##
## Sequoyah's direction (2026-08-19): "the islands are quite round, they shouldn't be standard
## shapes." A radial falloff makes a coin, and displacing its edge with noise only makes a coin with
## a wobbly rim — the silhouette is still a circle because the thing being displaced is a circle.
## The fix has to change the FORM, not the trim: three or four overlapping lobes at different
## offsets and radii, unioned, so the island has peninsulas, a waist, and bays that go somewhere.
##
## Lobes are placed off the same unit-vector table the islets use (no `sin`/`cos` in this file —
## they resolve differently across platforms and D-017/D-028 rest on this function being
## bit-identical), and their radii are chosen so the union always stays connected: every lobe
## overlaps the first one.
const LOBE_COUNT_MIN: int = 3
const LOBE_COUNT_MAX: int = 4
## How far a lobe's centre sits from the island's, and how big it is, as fractions of
## ISLAND_RADIUS. The ranges are deliberately wide: lobes of similar size at similar offsets
## average back out into the circle this exists to avoid.
const LOBE_OFFSET_MIN: float = 0.28
const LOBE_OFFSET_MAX: float = 0.88
const LOBE_RADIUS_MIN: float = 0.40
const LOBE_RADIUS_MAX: float = 0.72
## The centred lobe the others hang off. Deliberately NOT the biggest thing in the
## union: at 0.84 it was the island and everything else was a bump on it, which is
## how a "lobed" island still renders as a circle. At 0.60 no single lobe owns the
## outline, and the shape is whatever the union happens to be.
const LOBE_BODY_RADIUS: float = 0.60
## Every lobe must overlap the body by at least this much of ISLAND_RADIUS, so an
## island is always one connected landmass however the seed falls. Enforced by
## clamping the offset rather than by choosing numbers that happen to work.
const LOBE_MIN_OVERLAP: float = 0.14
const LOBE_SALT: int = 0x3C0A57

## A vector warp applied to the point BEFORE any distance is measured, so every mask in this file —
## island, lobes and islets alike — is measured in bent space. Scalar radial jitter can only push a
## coastline in and out along its own radius, which keeps arcs as arcs; bending the plane turns them
## into inlets and spits.
const SHAPE_WARP_AMPLITUDE: float = 58.0 / FREQUENCY_SCALE
const SHAPE_WARP_FREQUENCY: float = 0.0055 * FREQUENCY_SCALE
const SHAPE_WARP_SALT_X: int = 0x51A9E
const SHAPE_WARP_SALT_Z: int = 0x62B7F

## Satellite islets: one or two, deliberately close in, and nothing else out there.
##
## Sequoyah's direction (2026-08-19): one main island, maybe one or two mini islands really close
## to it, and otherwise just a big ocean. Islets are therefore PLACED, not left to noise — noise
## that produces satellites at all also produces them scattered to the horizon, and the last render
## before this change was an archipelago.
##
## Directions are a fixed table of unit vectors rather than an angle, because this file may not use
## `sin`/`cos`: they resolve differently across platforms and the whole seed-shared-world contract
## (D-017/D-028) rests on this function being bit-identical everywhere. A table of literals is the
## portable way to say "pick a direction".
const ISLET_DIRECTIONS: Array[Vector2] = [
	Vector2(1.0, 0.0), Vector2(0.7071, 0.7071), Vector2(0.0, 1.0), Vector2(-0.7071, 0.7071),
	Vector2(-1.0, 0.0), Vector2(-0.7071, -0.7071), Vector2(0.0, -1.0), Vector2(0.7071, -0.7071),
]
## Centre distance and radius, as fractions of ISLAND_RADIUS. "Really close" is the brief: at 1.22
## the gap between the two shorelines is about 12 m of water, which reads as a place you could wade
## or bridge rather than a second destination.
const ISLET_DISTANCE: float = 1.22
const ISLET_RADIUS_FRACTION: float = 0.26
const ISLET_SALT: int = 0x15E7

## THE RIVER (task 4.14, D-142) — one per island, guaranteed, analytic.
##
## Hollowmere's identity is "a river out of the northern rim through a gorge into the mere", and it
## was authored. Procedurally the same guarantee comes from a SEEDED POLYLINE, not a traced flow:
## tracing steepest descent needs the whole field and somewhere to cache it, and this file's
## contract is pure functions with no shared state (D-075's thread-safety rests on it). Four points
## — a source pulled inside the biggest outer lobe, two seeded bends, a mouth direction extended
## past the coast — cost O(3 segments) of arithmetic per sample and derive from the same integer
## mixing `lobes()`/`islet_centres()` already use. No trig, no RNG, nothing outside the D-017 set.
##
## The carve is `min(surface, channel)`: where terrain crosses the corridor the channel wins, which
## is what cuts a GORGE through a ridge instead of the river politely climbing it. The channel bed
## runs monotonically downhill from source to below sea level, so the water never flows uphill; the
## whole depression is multiplied by the island mask, so at the real (warped, jittered) coast the
## carve hands over to the sea exactly where the land ends, wherever this seed put it.
##
## Lateral distance is measured in BENT space like every other landform here — the same warp that
## turns circular coasts into inlets turns this straight polyline into meanders for free.
const RIVER_SOURCE_PULL: float = 0.55       # source sits this fraction of its lobe's offset inward
const RIVER_BEND_FRACTIONS: Array[float] = [0.35, 0.68]   # where along the line the bends sit
const RIVER_BEND_OFFSET_MIN: float = 0.08   # bend offset, as a fraction of river length
const RIVER_BEND_OFFSET_MAX: float = 0.20
const RIVER_OVERSHOOT: float = 1.18         # mouth extends to this x ISLAND_RADIUS past the source
const RIVER_WIDTH_SOURCE: float = 3.5       # half-width in metres at the source...
const RIVER_WIDTH_MOUTH: float = 9.0        # ...and at the mouth
const RIVER_BED_SOURCE: float = 3.0         # bed height at the source (m)
const RIVER_BED_MOUTH: float = -2.2         # below sea level: the mouth is open water
const RIVER_BANK_RISE: float = 7.0          # how fast the channel ceiling rises off the bed
const RIVER_CORRIDOR: float = 2.6           # carve influence ends at width x this
const RIVER_SALT: int = 0x71E5B

## The outer bound of ALL land, as a function rather than a constant: GDScript will not evaluate
## `maxf()` in a const expression, and the alternative — a hand-computed literal — is exactly what
## went wrong the first time. The original was `ISLAND_RADIUS * (ISLET_DISTANCE +
## ISLET_RADIUS_FRACTION)`, correct for islets and quietly wrong the moment lobes could reach
## further, which `terrain_check` caught as 11 mm of land sitting on the boundary.
##
## Anything that means "past here it is open water" reads this — chunk streaming, POI placement and
## the Mire grid all reason about the edge of the world, and a short edge is a culled coastline.
## Anything that adds a landform must appear in this expression or the bound stops being one.
static func world_radius() -> float:
	var lobe_reach: float = LOBE_OFFSET_MAX + LOBE_RADIUS_MAX
	var islet_reach: float = ISLET_DISTANCE + ISLET_RADIUS_FRACTION
	return ISLAND_RADIUS * maxf(lobe_reach, islet_reach) + SHAPE_WARP_AMPLITUDE + COAST_JITTER

## The highest ground this generator can produce, in metres.
##
## `HEIGHT_SCALE` is the noise's amplitude, not the peak: `LAND_BIAS` lifts the whole continent
## before the scale is applied, the tallest placed hill stands on that plateau, and the ridged
## layer adds on top. Anything that sizes a camera, a water plane, a chunk's vertical bounds or a
## check's invariant wants this number.
const MAX_HEIGHT: float = (BASE_NOISE_WEIGHT + LAND_BIAS) * HEIGHT_SCALE \
		+ HILL_HEIGHT_MAX + RIDGE_WEIGHT


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
## How many islets this seed gets (one or two) and where they sit. Integer arithmetic only, so it
## is identical on every platform.
## The lobe centres and radii this seed's island is built from. Integer arithmetic only.
static func lobes(world_seed: int) -> Array[Vector3]:
	var mixed: int = (world_seed ^ LOBE_SALT) & 0x7FFFFFFF
	var count: int = LOBE_COUNT_MIN + (mixed % (LOBE_COUNT_MAX - LOBE_COUNT_MIN + 1))
	# The first lobe is the island's body, centred and large; the rest hang off it.
	var out: Array[Vector3] = [Vector3(0.0, 0.0, ISLAND_RADIUS * LOBE_BODY_RADIUS)]
	for index in count:
		var step: int = mixed / (11 + index * 17)
		# Each lobe picks its own direction rather than stepping a fixed stride round
		# the table. A fixed stride spreads lobes evenly, and evenly-spread lobes
		# union back into the circle this whole mechanism exists to avoid — every
		# seed came out the same rounded polygon. Independent directions let some
		# seeds cluster their lobes (a long island with a waist) and others spread
		# them (a broad one), which is variety rather than one shape with noise on it.
		var direction: Vector2 = ISLET_DIRECTIONS[(step / (3 + index * 5)) % ISLET_DIRECTIONS.size()]
		var offset_span: float = LOBE_OFFSET_MAX - LOBE_OFFSET_MIN
		var radius_span: float = LOBE_RADIUS_MAX - LOBE_RADIUS_MIN
		var offset: float = LOBE_OFFSET_MIN + offset_span * float(step % 17) / 16.0
		var radius: float = LOBE_RADIUS_MIN + radius_span * float(step % 23) / 22.0
		# Pull the lobe in if it would only graze the body: a tangent lobe reads as
		# a separate island that happens to touch, and a gap reads as a bug.
		offset = minf(offset, LOBE_BODY_RADIUS + radius - LOBE_MIN_OVERLAP)
		var centre: Vector2 = direction * (ISLAND_RADIUS * offset)
		out.append(Vector3(centre.x, centre.y, ISLAND_RADIUS * radius))
	return out


## The point, bent, given already-built warp fields. Split out of `_warp_point` (F-241) so a
## caller sampling many points for the same seed — `height_from_set`'s whole reason to exist —
## bends each point without rebuilding `warp_x`/`warp_z`.
static func _warp_point_with(x: float, z: float, warp_x: FastNoiseLite, warp_z: FastNoiseLite) -> Vector2:
	return Vector2(x + warp_x.get_noise_2d(x, z) * SHAPE_WARP_AMPLITUDE,
		z + warp_z.get_noise_2d(x, z) * SHAPE_WARP_AMPLITUDE)


## The point, bent. Everything that measures a distance in this file measures it here.
static func _warp_point(x: float, z: float, world_seed: int) -> Vector2:
	var warp_x := _make_noise(world_seed ^ SHAPE_WARP_SALT_X, SHAPE_WARP_FREQUENCY, 3,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	var warp_z := _make_noise(world_seed ^ SHAPE_WARP_SALT_Z, SHAPE_WARP_FREQUENCY, 3,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	return _warp_point_with(x, z, warp_x, warp_z)


## This seed's placed hills: (centre.x, centre.y, radius, height) per entry. Integer arithmetic
## only, same portability contract as `lobes()`.
static func hills(world_seed: int) -> Array[Vector4]:
	var mixed: int = (world_seed ^ HILL_SALT) & 0x7FFFFFFF
	var count: int = HILL_COUNT_MIN + (mixed % (HILL_COUNT_MAX - HILL_COUNT_MIN + 1))
	var out: Array[Vector4] = []
	for index in count:
		var step: int = mixed / (5 + index * 19)
		# Independent direction and offset per hill, same reasoning as lobes(): a fixed stride
		# spaces them into a ring, and a ring of hills reads as a crater rim.
		var direction: Vector2 = ISLET_DIRECTIONS[(step / (7 + index * 3)) % ISLET_DIRECTIONS.size()]
		var offset: float = HILL_OFFSET_MAX * float(step % 13) / 12.0
		var radius: float = HILL_RADIUS_MIN \
			+ (HILL_RADIUS_MAX - HILL_RADIUS_MIN) * float(step % 29) / 28.0
		var lift: float = HILL_HEIGHT_MIN \
			+ (HILL_HEIGHT_MAX - HILL_HEIGHT_MIN) * float(step % 7) / 6.0
		var centre: Vector2 = direction * (ISLAND_RADIUS * offset)
		out.append(Vector4(centre.x, centre.y, radius, lift))
	return out


## Metres of placed-hill lift at `bent`. Smooth radial mounds, merged with `maxf` so neighbours
## read as one broader rise; the profile is smoothstep's own polynomial, nothing outside D-017.
static func _hill_lift(bent: Vector2, world_seed: int) -> float:
	var lift: float = 0.0
	for hill: Vector4 in hills(world_seed):
		var distance: float = bent.distance_to(Vector2(hill.x, hill.y))
		if distance >= hill.z:
			continue
		var t: float = 1.0 - distance / hill.z
		lift = maxf(lift, hill.w * t * t * (3.0 - 2.0 * t))
	return lift


static func islet_centres(world_seed: int) -> Array[Vector2]:
	var mixed: int = (world_seed ^ ISLET_SALT) & 0x7FFFFFFF
	var count: int = 1 + (mixed % 2)
	var centres: Array[Vector2] = []
	for index in count:
		var slot: int = (mixed / (7 + index * 13)) % ISLET_DIRECTIONS.size()
		# Two islets never share a quadrant: the second is pushed three slots round
		# the table, which is far enough that they read as separate places.
		var direction: Vector2 = ISLET_DIRECTIONS[(slot + index * 3) % ISLET_DIRECTIONS.size()]
		centres.append(direction * (ISLAND_RADIUS * ISLET_DISTANCE))
	return centres


## The river's four control points for this seed, in DESIGN space (pre-warp). Source: the centre
## of the farthest-reaching non-body lobe, pulled toward the island's middle — reliably interior
## high ground without sampling any noise. Mouth: the opposite direction, overshot past the coast;
## the mask fades the carve out at the real shoreline so the overshoot costs nothing. Two bends
## give the line a reason to exist before the warp bends it further.
static func river_polyline(world_seed: int) -> PackedVector2Array:
	var mixed: int = (world_seed ^ RIVER_SALT) & 0x7FFFFFFF
	var source_dir := Vector2(1.0, 0.0)
	var source_offset: float = ISLAND_RADIUS * LOBE_BODY_RADIUS * 0.5
	var best_reach: float = 0.0
	var lobe_list: Array[Vector3] = lobes(world_seed)
	for index in range(1, lobe_list.size()):
		var lobe: Vector3 = lobe_list[index]
		var centre := Vector2(lobe.x, lobe.y)
		var reach: float = centre.length() + lobe.z
		if reach > best_reach:
			best_reach = reach
			source_dir = centre.normalized() if centre.length() > 0.001 else source_dir
			source_offset = centre.length() * RIVER_SOURCE_PULL
	var source: Vector2 = source_dir * source_offset
	var mouth: Vector2 = -source_dir * (ISLAND_RADIUS * RIVER_OVERSHOOT)

	var out := PackedVector2Array([source])
	var along: Vector2 = mouth - source
	var perpendicular := Vector2(-along.y, along.x)
	for bend_index in RIVER_BEND_FRACTIONS.size():
		var step: int = mixed / (13 + bend_index * 19)
		var span: float = RIVER_BEND_OFFSET_MAX - RIVER_BEND_OFFSET_MIN
		var magnitude: float = RIVER_BEND_OFFSET_MIN + span * float(step % 19) / 18.0
		var side: float = 1.0 if (step % 2) == 0 else -1.0
		out.append(source + along * RIVER_BEND_FRACTIONS[bend_index]
			+ perpendicular * (magnitude * side))
	out.append(mouth)
	return out


## The channel ceiling at `bent` (a point already in warped space), or a huge sentinel when the
## point is outside the river's corridor. `t` is the 0..1 fraction along the whole polyline —
## width and bed depth both grow with it, and the bed is LINEAR in t, which is the monotonic-
## downhill guarantee terrain_check asserts.
static func _river_channel(bent: Vector2, world_seed: int) -> float:
	var points: PackedVector2Array = river_polyline(world_seed)
	var total_length: float = 0.0
	for index in range(points.size() - 1):
		total_length += points[index].distance_to(points[index + 1])
	if total_length <= 0.0:
		return 1.0e9

	var best_distance: float = 1.0e9
	var best_t: float = 0.0
	var walked: float = 0.0
	for index in range(points.size() - 1):
		var a: Vector2 = points[index]
		var b: Vector2 = points[index + 1]
		var segment: Vector2 = b - a
		var segment_length: float = segment.length()
		var to_point: Vector2 = bent - a
		var projection: float = clampf(to_point.dot(segment) / (segment_length * segment_length),
			0.0, 1.0)
		var distance: float = (a + segment * projection).distance_to(bent)
		if distance < best_distance:
			best_distance = distance
			best_t = (walked + segment_length * projection) / total_length
		walked += segment_length

	var width: float = lerpf(RIVER_WIDTH_SOURCE, RIVER_WIDTH_MOUTH, best_t)
	if best_distance >= width * RIVER_CORRIDOR:
		return 1.0e9
	var bed: float = lerpf(RIVER_BED_SOURCE, RIVER_BED_MOUTH, best_t)
	var lateral: float = best_distance / width
	return bed + lateral * lateral * RIVER_BANK_RISE


## `min(surface, channel)`, faded by the island mask so the carve ends where the land does.
##
## The fade is a STEEPENED mask, not the raw one: linearly blending by mask let every interior
## mask dip — a coastal notch the warp pulled inland, a lobe seam — weaken the carve mid-river,
## and the bed popped BACK UP over the notch: water flowing uphill, caught by terrain_check's
## monotonic walk on the first run. Full carve strength from mask 0.35 up means the channel only
## hands over to the sea in the true coastal fringe, where handing over is the point.
## `_river_channel()` is the expensive half and is cached on `Shape` (F-274), so the carve itself
## takes the channel rather than the point: two carves of the same point — the continent's and the
## finished surface's — share one polyline walk instead of paying for two.
static func _carve(channel: float, surface: float, mask: float) -> float:
	if channel >= surface:
		return surface
	var carve_strength: float = smoothstep(0.0, 0.35, mask)
	return surface + (channel - surface) * carve_strength


## Falloff for one circular landmass. Cubic, so the shore drops away rather than ending at a line.
static func _radial_mask(distance: float, radius: float) -> float:
	var falloff_start: float = radius * FALLOFF_START_FRACTION
	if distance <= falloff_start:
		return 1.0
	if distance >= radius:
		return 0.0
	var t: float = (distance - falloff_start) / (radius - falloff_start)
	var inv: float = 1.0 - t
	return inv * inv * inv


static func _island_mask(x: float, z: float, world_seed: int, jitter: float = 0.0) -> float:
	# Measured in bent space, so no mask below is measuring a circle in the first
	# place; the jitter then roughens what is already an irregular edge.
	return _island_mask_bent(_warp_point(x, z, world_seed), world_seed, jitter)


## The mask body, for a caller that already bent the point — `continent()`/`height()` bend once
## and share it between the mask and the river (4.14), keeping the per-sample noise count flat.
static func _island_mask_bent(point: Vector2, world_seed: int, jitter: float = 0.0) -> float:
	var mask: float = 0.0
	for lobe: Vector3 in lobes(world_seed):
		var centre := Vector2(lobe.x, lobe.y)
		mask = maxf(mask, _radial_mask(point.distance_to(centre) - jitter, lobe.z))
	# The islets take the LARGER of the masks rather than adding, so where one
	# overlaps the main island it merges into a headland instead of stacking into
	# a spike offshore.
	var islet_radius: float = ISLAND_RADIUS * ISLET_RADIUS_FRACTION
	for centre: Vector2 in islet_centres(world_seed):
		mask = maxf(mask, _radial_mask(point.distance_to(centre) - jitter * 0.5, islet_radius))
	return mask




## Bundles the six `FastNoiseLite` fields one `height()` call builds, so a caller sampling many
## points for the same `world_seed` — `world/chunk/chunk_mesher.gd`'s ~1,089 vertices per chunk is
## the case that motivated this (F-241) — builds them ONCE via `make_noise_set()` and reuses them
## through `height_from_set()` instead of paying six fresh constructions per sample. Same rule as
## everywhere else in this file: one set per `WorkerThreadPool` task, never shared, because a
## `FastNoiseLite` instance is not safe to sample from several tasks at once.
class NoiseSet:
	var base_noise: FastNoiseLite
	var coast_noise: FastNoiseLite
	var warp_x: FastNoiseLite
	var warp_z: FastNoiseLite
	var detail_noise: FastNoiseLite
	var ridge_noise: FastNoiseLite


## Everything about a point that does NOT depend on which biome it is in, computed once: the
## shape-warped point, the island mask, and the continental height before the river carve.
##
## This is the split D-144 asks for made concrete (F-274). A caller that wants the biome-shaped
## surface needs the continent twice over — once to decide the point's biome, once as the base the
## biome's own rough layers ride on — and computing it twice costs four noise samples, two `lobes()`
## walks and a river-corridor walk it has already paid for. `shape_into()` computes it once into a
## caller-owned `Shape`, and `continent_from_shape()`/`height_from_shape()` each finish the job from
## there.
##
## Caller-owned and REUSED, exactly like `NoiseSet`: `world/chunk/chunk_mesher.gd` fills one Shape
## per vertex out of a single instance built per chunk, so per-vertex biome resolution costs no
## allocation at all. Same threading rule for the same reason — one Shape per `WorkerThreadPool`
## task, never shared, because two tasks filling one would read each other's point.
class Shape:
	## The point after `_warp_point_with()`. Every distance in this file is measured here.
	var bent: Vector2 = Vector2.ZERO
	## The island/lobe/islet mask at `bent`, 0..1.
	var mask: float = 0.0
	## The continent BEFORE the river carve. The rough layers ride on this and `ridge_mask()` reads
	## it, so ridge placement stays stable on either side of the valley (4.14).
	var raw_continent: float = 0.0
	## The river channel's ceiling at `bent` (or `_river_channel()`'s no-corridor sentinel).
	##
	## Cached here because the carve is applied TWICE per biome-shaped sample — once to the continent
	## the biome is classified from, once to the finished surface — and the channel is a function of
	## `bent` and `world_seed` alone, so the two applications cannot disagree. Walking the polyline
	## twice was measured at roughly a third of a sample's cost: `_river_channel()` rebuilds the
	## polyline (which rebuilds `lobes()`), sums its length and then walks its segments again.
	var channel: float = 0.0


## Builds the four fields that decide the island's SHAPE — the ones `continent()` reads. Split out
## of `make_noise_set()` so `continent()` can go through the same one body `continent_from_set()`
## does without paying for the two texture layers it deliberately never samples (D-144).
static func _make_shape_noise_set(world_seed: int) -> NoiseSet:
	var set := NoiseSet.new()
	set.base_noise = _make_continent_noise(world_seed)
	set.coast_noise = _make_noise(
		world_seed ^ COAST_NOISE_SALT, COAST_FREQUENCY, 3, BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	set.warp_x = _make_noise(world_seed ^ SHAPE_WARP_SALT_X, SHAPE_WARP_FREQUENCY, 3,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	set.warp_z = _make_noise(world_seed ^ SHAPE_WARP_SALT_Z, SHAPE_WARP_FREQUENCY, 3,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	return set


## Builds one `NoiseSet` for `world_seed`. Every field is constructed exactly as `height()` built
## it inline before F-241 — same seed, frequency and fractal settings — so sampling through a
## `NoiseSet` and sampling through a bare `height()` call are bit-identical for the same
## (x, z, world_seed); `tools/noise_reuse_check.gd` is the proof.
static func make_noise_set(world_seed: int) -> NoiseSet:
	var set: NoiseSet = _make_shape_noise_set(world_seed)
	set.detail_noise = _make_noise(world_seed ^ DETAIL_NOISE_SALT, DETAIL_NOISE_FREQUENCY,
		DETAIL_NOISE_OCTAVES, BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	set.ridge_noise = _make_noise(world_seed ^ RIDGE_NOISE_SALT, RIDGE_FREQUENCY, RIDGE_OCTAVES,
		RIDGE_LACUNARITY, RIDGE_GAIN)
	set.ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	return set


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


## Fills `out` with the biome-independent half of a sample at (x, z). Reads only `base_noise`,
## `coast_noise`, `warp_x` and `warp_z`, so a set built by `_make_shape_noise_set()` is enough.
##
## Every path in this file funnels through this body — `continent()`, `continent_from_set()`,
## `height()`, `height_from_set()` and `BiomeMap.surface_from_set()` alike — rather than each
## carrying its own copy of the formula. A duplicated body is how two of those would quietly drift
## apart under a later edit, which is the same reason `_continent_with()` existed before F-274
## folded it in here.
static func shape_into(x: float, z: float, set: NoiseSet, world_seed: int, out: Shape) -> void:
	var jitter: float = set.coast_noise.get_noise_2d(x, z) * COAST_JITTER
	out.bent = _warp_point_with(x, z, set.warp_x, set.warp_z)
	out.mask = _island_mask_bent(out.bent, world_seed, jitter)
	# Plateau + placed hills (D-184 second pass): the noise is damped to an undulation on a
	# near-flat interior, and the hills are seeded landforms — both ride the island mask so the
	# coast still tapers into the sea wherever this seed put it.
	out.raw_continent = ((set.base_noise.get_noise_2d(x, z) * BASE_NOISE_WEIGHT + LAND_BIAS)
		* HEIGHT_SCALE + _hill_lift(out.bent, world_seed)) * out.mask
	out.channel = _river_channel(out.bent, world_seed)


## The carved continent from an already-filled `Shape` — what `continent()` returns.
##
## The river carves the CONTINENT too (4.14): biomes read this surface (D-144), so the valley floor
## resolves as low ground — banks go shore/marsh by height, no special casing anywhere.
##
## Takes no `world_seed`: the only seed-derived thing the carve needs is the channel, and `shape`
## already carries it.
static func continent_from_shape(shape: Shape) -> float:
	return _carve(shape.channel, shape.raw_continent, shape.mask)


static func continent(x: float, z: float, world_seed: int) -> float:
	return continent_from_set(x, z, _make_shape_noise_set(world_seed), world_seed)


## Same result as `continent()`, sampled through a `NoiseSet` the caller built once (F-261). The set
## already holds all four fields `continent()` builds — it is a superset, carrying the detail and
## ridge layers `continent()` deliberately does not read (D-144: the continent is the
## biome-INDEPENDENT half of the terrain).
##
## `BiomeMap.biome_at_from_set()` is the caller this exists for: deciding a point's biome costs one
## continent sample, and POI placement asks for tens of thousands of them per island.
static func continent_from_set(x: float, z: float, set: NoiseSet, world_seed: int) -> float:
	var shape := Shape.new()
	shape_into(x, z, set, world_seed, shape)
	return continent_from_shape(shape)


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
## the BiomeDef; passing 1.0/1.0 gives the biome-blind terrain.
##
## Nothing shipped passes 1.0/1.0 any more (F-274): every surface the game builds goes through
## `BiomeMap.surface_from_set()`, which resolves the pair from the point's own biome. The defaults
## are for a caller with no biome table at all — a bench, or a check isolating one layer.
static func height(x: float, z: float, world_seed: int,
		detail_amplitude: float = 1.0, ridge_amplitude: float = 1.0) -> float:
	return height_from_set(x, z, make_noise_set(world_seed), world_seed,
		detail_amplitude, ridge_amplitude)


## Same result as `height()`, sampled through a `NoiseSet` the caller built once via
## `make_noise_set()` instead of six fresh `FastNoiseLite` constructions per call (F-241).
## `world_seed` is still required alongside `set`: the island mask (`lobes`/`islet_centres`) and
## the river carve (`_river_channel` -> `river_polyline`) derive their geometry from it directly via
## integer mixing, not from any noise field, so it is not something the noise set alone determines.
static func height_from_set(x: float, z: float, set: NoiseSet, world_seed: int,
		detail_amplitude: float = 1.0, ridge_amplitude: float = 1.0) -> float:
	var shape := Shape.new()
	shape_into(x, z, set, world_seed, shape)
	return height_from_shape(x, z, shape, set, detail_amplitude, ridge_amplitude)


## The rough layers on top of an already-filled `Shape`, at the amplitudes this point's biome
## authors. Split out of `height_from_set()` by F-274 so `BiomeMap.surface_from_set()` can resolve
## the biome off the same Shape and then finish the surface without re-deriving the continent.
## Takes no `world_seed` for the same reason `continent_from_shape()` does not: everything the
## finish needs that derives from the seed — the mask and the river channel — is already in `shape`.
static func height_from_shape(x: float, z: float, shape: Shape, set: NoiseSet,
		detail_amplitude: float = 1.0, ridge_amplitude: float = 1.0) -> float:
	var detail: float = set.detail_noise.get_noise_2d(x, z) * DETAIL_NOISE_WEIGHT * detail_amplitude

	# A ridge only ever ADDS. Re-centring the ridged fractal to -1..1 and scaling
	# it made the layer cut as deep as it lifted, which on a 26 m island carved
	# 22 m pits — the interior came out riddled with lakes and read as a sponge.
	# Thresholding instead keeps the crests and drops the troughs on the floor,
	# which is what "ridges on the high ground" is supposed to mean.
	var raw: float = set.ridge_noise.get_noise_2d(x, z)
	var ridged: float = maxf(0.0, (raw - RIDGE_THRESHOLD) * RIDGE_GATHER)
	var ridge: float = ridged * ridge_mask(shape.raw_continent) * ridge_amplitude * RIDGE_WEIGHT

	# Both rough layers ride the island mask too, so the coastline stays where the
	# continent put it and an island does not grow a rocky halo out to sea.
	var surface: float = shape.raw_continent + (detail * HEIGHT_SCALE + ridge) * shape.mask
	# Carved LAST (4.14): a ridge that wandered across the corridor loses to the channel, which is
	# what a gorge is. The ridge_mask above deliberately reads the UNCARVED continent, so ridge
	# placement stays stable on either side of the valley.
	return _carve(shape.channel, surface, shape.mask)
