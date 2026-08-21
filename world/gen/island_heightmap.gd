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
## **590 m — an island about 1.18 km across.** Doubled from 295 m on the 2026-08-21 playtest
## verdict, "the island should be maybe twice as big" (F-447). 295 m was itself a 2.5x raise from
## 118 m at the previous playtest (F-368), for reasons that are still worth reading because they
## are why the number has only ever moved one way:
##
##  · `content/poi/loot_cache.tres` asks for 8 sites at `min_spacing_m` 70. Eight mutually-70 m-
##    separated points do not EXIST inside a 118 m disc's placeable band, so `PoiMap`'s relaxation
##    ladder was the only thing placing any, and `autoload/chest_placement_service.gd` — which only
##    ever builds a `Chest` on a `loot` marker — therefore had nothing to build. No chests in a
##    shipped run at all (F-367).
##  · The Wellspring's 180 m spacing made a second one geometrically impossible (F-319).
##  · There was no room for a dense forest AND open ground, so the whole island read as one
##    continuous field (F-369).
##
## The original 512 m cut was rejected for a good reason — rendered top-down it was "a landmass
## filling the whole frame, which is a continent with a shoreline, not an island in an ocean" — and
## 590 m does not reopen it, because the thing that produced that read was the FRAME, not the
## radius. What the top-down render actually shows is the ratio of land to visible water, and the
## island mask covers well under half the disc `ISLAND_RADIUS` names: measured over four seeds at
## 295 m, land was 6.3-8.3% of a 1600 m square, against 27% for a full disc of that radius. The
## lobe union is a scatter of headlands and bays inside the nominal circle, not the circle. At
## 590 m the same seeds put roughly a quarter of a 2400 m square under land, which is an island in
## an ocean at the scale a player walks it — about 20 minutes of coast to round instead of 10.
##
## **What moves with this number, and what does not.** `FREQUENCY_SCALE` below is defined against a
## fixed 512 m reference precisely so terrain frequency stays put when the radius moves — the island
## gets bigger, not noisier. The POI band (`radius_*_fraction`), the lobes, the islets and the river
## overshoot are all authored as fractions and scale for free.
##
## Two things did NOT scale for free and were handled explicitly:
##  · `world/mire/mire_grid_sim.gd` derives `CELL_SIZE_M` from this radius over a FIXED 256x256
##    grid, so a bigger island means coarser cells and — at an unchanged per-tick spread rate — a
##    Mire that advances faster in metres per second at an unchanged per-tick rate. `MireGrid.BASE_SPREAD_RATE` is now
##    normalised against cell size to hold the metres-per-second rate constant. See its comment.
##  · Per-POI `target_count`/`min_spacing_m` pairs were tuned against 118 m and are now generous
##    rather than impossible. That is the right direction, but it means the ore-node density in
##    `content/scatter/*_rocks.tres` wants a re-look now that there is more ground to spread over
##    (noted on F-365).
const ISLAND_RADIUS: float = 590.0

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
## 6 m, down from 11 (down from 26, down from 60) — the playtest verdict (2026-08-20): "we need to
## make the map closer to sea level with very very gentle rolling hills." With LAND_BIAS below,
## the walkable interior now sits ~1.8-4.8 m above the water instead of ~8, so the shore is a
## beach you step off, not a bank you fall down.
const HEIGHT_SCALE: float = 11.0

## How much of the continental noise actually reaches the surface. His second verdict (2026-08-20,
## same day, off the first retune's renders): "still wayyy too steep on the hills, im thinking like
## 3-5 hills on the whole island." Rolling fBm everywhere is the wrong STRUCTURE for that, not just
## the wrong amplitude — the interior is now a near-flat plateau (this weight damps the noise to
## about ±1 m of undulation at the base frequency's ~38 m wavelength) and the hills are PLACED
## landforms below (`HILL_*`), countable the way he counted them.
const BASE_NOISE_WEIGHT: float = 0.25

## THE HILLS (D-184, second pass) — placed landforms, not emergent ones.
##
## Same recipe as `lobes()`/`islet_centres()`: positions from integer mixing on the direction
## table, radii and heights from modulo spreads, all inside the D-017 safe set. Each hill is a
## smooth radial mound; overlapping hills take `maxf` like the lobe masks do, so two neighbours
## merge into a broader rise instead of stacking into a peak.
##
## **These are UPLANDS, not hills, and the count came back down because of it (F-450).**
##
## Sequoyah: "taller hills please the map is wayy too flat, i do like big flat areas but i also like
## higher areas, i dont like narrow hills that make the map always go up and down if you know what
## i mean." The last clause is the structural one. A dome's crown is a single point, so every metre
## of its footprint is sloping ground — put enough of them on an island and the walk is a continuous
## up-and-down whatever their amplitude is. More of them, or taller ones, makes that worse.
##
## What he is describing is high ground with a TOP: a broad rise, a flat area on top of it at a
## different elevation from the flat area around it, and a limited amount of slope in between. That
## is `HILL_FLAT_*` below, and it is the change that matters here — the height and radius numbers
## only decide how much of it there is.
##
## 3-5 at these radii covers as much of the island as 5-8 did at the old ones, and it covers it in
## fewer, larger pieces, which is the point. `HILL_MIN_SEPARATION` is loose enough that neighbours
## merge under `maxf` into one bigger upland rather than standing as two — at this size merging is
## the desired outcome, not a collision to be pushed apart.
const HILL_COUNT_MIN: int = 3
const HILL_COUNT_MAX: int = 5
## **Hills are placed inside a LOBE, not at a bearing from the island's middle** — the biggest
## single correction in the F-447 pass, and the one that was invisible until the hills were
## measured rather than looked at.
##
## An offset-from-centre placement assumes the island fills the disc `ISLAND_RADIUS` names. It does
## not: the lobe union is an irregular scatter of headlands inside that circle, so a bearing with no
## lobe on it is open sea, and a hill placed there is multiplied by a zero island mask and simply
## does not exist. Probed on seed 20260821, **two of five hills sat on the ocean floor** — a seed
## that nominally had five had three, and which three depended on the lobes.
##
## Choosing a lobe first and offsetting within it makes "on land" structural rather than lucky. It
## costs nothing: `lobes()` is the same integer arithmetic `hills()` already is, no noise is
## sampled, and the D-017 safe set is untouched.
##
## The offset is a fraction of the chosen lobe's radius, measured in that lobe's own elliptical
## frame so a stretched lobe scatters its hills along its length rather than bunching them across
## its waist. Capped short of the lobe's edge so a hill's toe stays off the coastal falloff, which
## is what the old cap against ISLAND_RADIUS was for.
const HILL_LOBE_OFFSET_MAX: float = 0.46
## An upland may be no broader than this fraction of its lobe's SHORT half-axis.
##
## Raised to 1.0 with the upland restructure (F-450). At 0.70 it existed to stop a hill being wider
## than the land it stood on; at upland radii it was instead cutting every upland down to the
## smallest lobe it might land on, which is the "narrow hills" complaint arriving from the other
## direction. 1.0 lets an upland reach its lobe's own edge, where the island mask fades it into the
## coastal falloff — high ground that runs out at the shore, which is a headland, and one of the
## better things this generator now makes.
const HILL_LOBE_FIT: float = 0.85
## Minimum centre separation between two hills, as a fraction of the sum of their radii. Below this
## they read as one landform, so `hills()` pushes the later one out — deterministically, along the
## line between them, no RNG and no iteration to convergence.
const HILL_MIN_SEPARATION: float = 0.50
## **The FLAT TOP's radius, in metres** — not the upland's whole footprint (F-450). The ramps are
## added outside it, each sized from the gradient it is meant to have, so this number is exactly one
## thing: how big the level area on top is. At the old sizes (34-95 m) a "taller hill" was only ever
## a steeper hill, because the height had nowhere to spread out over; the island is 1.18 km across
## and these are the landforms the map is supposed to be made OF.
##
## The first cut of the upland made this the whole footprint and took the flat top as a FRACTION of
## it, which quietly coupled the two things that most needed separating. A big flat top meant a
## narrow ramp, so the tablelands with the most level ground on top were ringed by 38-degree rims on
## every bearing — a mesa you cannot get onto, and the "one side steeper" variety collapsed because
## every side was steep. Measured: 15-21% of all land sat past 20 degrees.
##
## 60-260 m of radius is a level area from a clearing to a small plain.
const HILL_TOP_RADIUS_MIN: float = 60.0     # metres
const HILL_TOP_RADIUS_MAX: float = 260.0
## Crown lift, in metres. 10-34 m against F-447's 6.9-13.1: the rendered high point of the island
## goes from ~20 m to ~45 m above the sea, which is what "wayy too flat" was about.
const HILL_HEIGHT_MIN: float = 12.0
const HILL_HEIGHT_MAX: float = 40.0
## **Height is derived FROM the top's radius, not drawn independently of it** (F-450) — metres of
## lift per metre of top radius, clamped into the range above.
##
## Drawing the two independently means a quarter of all hills are the tall-and-narrow combination,
## and tall-and-narrow is exactly the landform he ruled out: "i dont like narrow hills that make the
## map always go up and down". Tying them means a big upland is a high one and a small rise is a low
## one, which is also how real ground works — a landmass's relief scales with its extent. The
## spread is what keeps two uplands of the same size from being the same height.
const HILL_LIFT_PER_RADIUS_MIN: float = 0.12
const HILL_LIFT_PER_RADIUS_MAX: float = 0.26
## **The GENTLE side's gradient**, in metres of run per metre of rise — the same unit as
## `HILL_SCARP_RUN_*` below, and the counterpart to it (F-450).
##
## Every upland has one; it is what the ground does on the bearing away from its steep face, and on
## one that drew no scarp worth the name it is what the ground does all the way round. 4.5 is about
## 12 degrees and 11.0 about 5 — from "a slope you notice" to "you are on the upland before you
## register having climbed".
##
## The ramp is `height * run` of ground OUTSIDE the flat top, so a taller upland gets a
## proportionally longer ramp and its gradient stays what this says it is. That is precisely the
## property a fraction-of-radius ramp cannot have, and why the flat top and the ramps are now sized
## independently: the top decides how much level high ground there is, and these decide how you get
## onto it.
const HILL_LEE_RUN_MIN: float = 3.0
const HILL_LEE_RUN_MAX: float = 6.5
## HILL ASYMMETRY — the cliff side (F-447).
##
## Sequoyah's direction: "some more variety in steepness, like one side of the hill could be more
## steep than the other kinda making a cliff type area." A symmetric radial mound cannot do that at
## any amplitude: every hill in the game had the same gradient at the same distance from its crown
## on every bearing, so "steep" was a property of the hill and never of the side you approached
## from. Two independent per-hill terms fix that, and they are separate because they do different
## things and the seed picks them independently:
##
##  · `scarp_run` sets the steep face's RADIUS from the hill's own height and a chosen gradient,
##    so the same crown height is spent over as much or as little run as that gradient asks for,
##    while the lee keeps the hill's nominal radius. A 13 m hill with a 90 m radius and a 1.0 scarp
##    run is a swell you stroll up from the south and an 13 m bluff on its north side.
##  · `sharpness` changes the PROFILE, and only on the steep side (it fades out with the same
##    bearing term, so the lee stays a smoothstep swell). It blends the mound's curve toward one
##    that does its rising at the toe instead of at the middle, which is what turns a steep slope
##    into something with a lip at the bottom — the "cliff type area" read rather than just a
##    steeper hill.
##
## The two compose: a short scarp run with high sharpness gives a short, front-loaded face, and
## the steepest ground on the island lives there. That ground is INTENDED to be near the edge of
## walkable (the player's floor limit is 46 degrees, F-136) — a cliff you route around is the
## feature. `tools/hill_slope_check.gd` measures how much of the island lands past that limit and
## fails if the cliffs stop being local features and start being a wall around the high ground.
## **The steep face is specified as an ANGLE, not as a fraction of the hill's footprint**, and that
## is the second thing the first cut of this got wrong. Squeezing the radius by a bias fraction ties
## the face's steepness to a radius and a height the seed drew independently, so a tall hill that
## happened to draw a broad radius came out gentle on both sides no matter how large the bias was.
## Measured that way, the steepest hill face across three seeds was 20.3 degrees — asymmetric, and
## nowhere near "a cliff type area".
##
## `scarp_run` is METRES OF RUN PER METRE OF RISE on the steep face, so it IS the face's gradient
## and the seed picks it directly: 1.0 is a 45-degree average (and, because the profile's steepest
## point is about 1.5x its average, near 57 degrees at the middle of the face — past the player's
## 46-degree floor limit, which is what makes it a cliff you route around rather than a slope you
## grind up).
##
## The hill's own `radius` still sets the LEE flank and therefore the footprint, so a hill can be a
## broad 90 m swell that happens to end in a bluff on its north side. That combination is the one
## the direction is really asking for, and it is unreachable from a bias fraction.
##
## **The top of the range is deliberately past the point where the scarp stops existing, and that
## is the feature, not sloppiness in the number.** `_hill_lift()` clamps the scarp's radius to the
## hill's own, so any run long enough that `height * run >= radius` gives a hill that is
## symmetric — a plain rolling dome with no steep side at all. At 8.0 most hills clear that bar,
## so the spread runs from bluff through mildly-lopsided to perfectly ordinary.
##
## The first cut of this had a floor under the spread so that every hill on every seed had a
## discernible steep face, on the reasoning that a symmetric hill was the thing being fixed.
## Sequoyah corrected it the same day: "i dont want every single hill to have a cliff, some hills
## can be very gentle and rolling and others can have a steeper side or whatever, just variety."
## The plain hills are what the dramatic ones are read against; a cliff on every hill is a terrain
## style, not a landmark. `tools/hill_slope_check.gd` asserts the SPREAD for this reason — that
## some hills come out near-symmetric and some come out as cliffs — rather than a floor, which a
## uniform treatment would satisfy just as well.
const HILL_SCARP_RUN_MIN: float = 1.0
const HILL_SCARP_RUN_MAX: float = 8.0
## How much the steep face front-loads its rise: 0 is the same smoothstep curve the lee has, 1 puts
## the steepest part at the TOE, which is what gives a scarp a lip at the bottom instead of easing
## into the ground. Spread from zero for the same reason the run is: a gentle hill that also had a
## front-loaded profile would be a scarp by another name.
const HILL_SHARPNESS_MIN: float = 0.0
const HILL_SHARPNESS_MAX: float = 1.0
const HILL_SALT: int = 0x48C3D1
## Fraction of ISLAND_RADIUS where the falloff begins. Inside this, height is unmasked; outside,
## it tapers cubically to 0 at ISLAND_RADIUS.
##
## 0.78 rather than the original 0.55: the wider taper left a ~230 m annulus of
## ground sitting within a metre or two of sea level, which renders as a beach
## ring around the whole island and gives `shore` most of the coast to itself. A
## shore should be tens of metres of sand, and the drop into water should be
## something a player can see happening.
##
## Eased back to 0.70 with the sea-level rebase, then to 0.48 at the playtest verdict "make the
## slope down to the water much more gradual, it's way too steep". Measured before that change
## (`tools/_tmp_shore_slope_probe.gd`, 5 seeds): the whole transition from +2 m to -1 m happened
## in under 4 m of ground, at up to **71 degrees** — past the player's own 46-degree walkable
## floor limit (F-136), so stretches of coast could not be walked at all. The band is the
## horizontal budget the drop is spent over, and it was far too small to spend ~8 m of relief in.
##
## Widening it does NOT shrink the island: land ends where the surface crosses sea level, which
## the two curve changes below move OUTWARD (~0.75 -> ~0.79 of each lobe's radius) even as the
## taper starts earlier.
const FALLOFF_START_FRACTION: float = 0.48

## The floor under that band, in METRES of ground, applied per landmass by `_radial_mask()`. A
## lobe or islet small enough that its proportional band is narrower than this takes this instead,
## so every shore on the map is walked down over a comparable distance no matter how big the thing
## it belongs to. 30 m spends the ~8 m of coastal relief at roughly one in four.
const MIN_FALLOFF_BAND_M: float = 30.0
## ...but never so wide that a landmass is nothing but taper — this much of its radius, at most.
## An islet ends up close to this: a low dome you wade onto, which is the right read at that size.
const MAX_FALLOFF_RADIUS_FRACTION: float = 0.85
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
const RIDGE_WEIGHT: float = 2.2

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
## Raised again with the uplands (F-450). The window is a fraction of HEIGHT_SCALE against the
## CONTINENT height, and uplands lift the continent to 30-45 m — so the old 0.95/1.30 window
## (10.5-14.3 m) put full-strength ridged texture on every square metre of every flat top. Flat
## tops are the feature; ridging them is the same mistake as ridging the plateau was. 2.6/3.6
## (28.6-39.6 m) confines it to the highest uplands' upper ramps and summits, where a little crest
## texture reads as rock rather than as a bumpy field.
const RIDGE_MASK_START: float = 2.60
const RIDGE_MASK_FULL: float = 3.60

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
## The bias sets where the interior SITS and the scale sets how much it rolls, and the two move
## together (the 0.54 x 11 lesson: dips fell under the shore biome boundary and scattered sand
## through the meadows — the boundary in `content/biomes/*.tres` moves with this pair). At
## 0.55 x 6 the meadow centres ~3.3 m over the water — "closer to sea level", the playtest ask —
## with ordinary dips staying above the 1.6 m shore line.
const LAND_BIAS: float = 0.55

## How far below sea level the ground settles where the island mask runs out. Before the ocean
## pass this was implicitly ZERO — mask 0 meant height 0, so "the sea" rendered as an endless
## green plain at the waterline and the shipped map had no visible water at all (the playtest's
## "no ocean" report). The floor sits deep enough that the water reads as water next to the
## shore, and shallow enough that the beach-to-floor ramp stays a wade, not a wall.
const OCEAN_FLOOR_DEPTH: float = 5.0

## How far the coastline wanders in and out, in metres, and how quickly it does
## so. Without this the falloff is a circle and the island renders as a coin with
## a sand rim — geometrically an island, visually a token. The mask reads a
## jittered radius instead of the true one, so the shore is ragged for the same
## reason a real one is: the land does not end at a constant distance.
##
## The FREQUENCY is a slope control, not just a shape control, and that is why it dropped with the
## gradual-coast pass. This jitter displaces the shoreline radially, so where the jitter field
## changes fast the coast's own taper is compressed into less ground — the falloff curve can be as
## gentle as it likes and a fast-wobbling jitter will still stand a wall up inside it. Halving the
## frequency doubles the wobble's wavelength and halves that compression, while the amplitude (how
## far the coast wanders in and out, which is what makes it ragged) is untouched.
const COAST_JITTER: float = 74.0 / FREQUENCY_SCALE
const COAST_FREQUENCY: float = 0.0021 * FREQUENCY_SCALE
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
const LOBE_COUNT_MIN: int = 4
const LOBE_COUNT_MAX: int = 6
## How far a lobe's centre sits from the island's, and how big it is, as fractions of
## ISLAND_RADIUS. The ranges are deliberately wide: lobes of similar size at similar offsets
## average back out into the circle this exists to avoid.
const LOBE_OFFSET_MIN: float = 0.24
const LOBE_OFFSET_MAX: float = 0.95
const LOBE_RADIUS_MIN: float = 0.26
const LOBE_RADIUS_MAX: float = 0.62
## The centred lobe the others hang off. Deliberately NOT the biggest thing in the
## union: at 0.84 it was the island and everything else was a bump on it, which is
## how a "lobed" island still renders as a circle. At 0.60 no single lobe owns the
## outline, and the shape is whatever the union happens to be.
const LOBE_BODY_RADIUS: float = 0.52
## The body is itself pushed off the world origin by this fraction of ISLAND_RADIUS.
##
## Two jobs, and the second is the reason it exists. It breaks the one piece of symmetry the lobe
## union could never break — a lobe centred exactly on the origin makes the origin the island's
## middle on every seed — and it gives the body an offset DIRECTION, which is what
## `_lobe_stretch_axis()` below elongates it along. A lobe at the origin has no direction to
## elongate along, so without this the biggest single mass on the island would be the one thing
## still guaranteed to be circular.
const LOBE_BODY_OFFSET: float = 0.13
## Lobes are ELLIPSES, not discs, and this is how far from round they are allowed to get.
##
## Sequoyah's direction (2026-08-21): "id like the shape to be a bit more random rather than
## usually mostly round it would be cool if it could be more unique." The lobe union was already
## meant to answer that (2026-08-19, "the islands are quite round"), and top-down renders at 295 m
## show why it only half did: a union of DISCS is a rounded blob whatever the offsets are, because
## every piece of the outline is an arc of a circle and arcs of circles are what "round" means. The
## previous passes moved the circles around; none of them stopped the pieces being circles.
##
## Each lobe therefore gets a stretch factor and an axis, and its mask is measured in a frame
## scaled along that axis. The transform is AREA-PRESERVING — the along component is divided by the
## stretch and the across component multiplied by it — so elongating a lobe lengthens it into a
## peninsula rather than simply inflating it, and the island's total land does not creep upward as
## this constant rises. That matters for `world_radius()` too, which would otherwise have to
## reserve the inflated reach on every axis.
##
## 1.0 is a disc; the max is deliberately high enough that a seed can produce a genuinely long,
## narrow arm. Above about 2.0 the narrow axis of an outer lobe gets thin enough that the coastal
## falloff band (which is absolute metres, `MIN_FALLOFF_BAND_M`) eats the whole thing and the arm
## renders as a shoal rather than as land.
const LOBE_STRETCH_MIN: float = 1.0
const LOBE_STRETCH_MAX: float = 1.85
## Every lobe must overlap the body by at least this much of ISLAND_RADIUS, so an
## island is always one connected landmass however the seed falls. Enforced by
## clamping the offset rather than by choosing numbers that happen to work.
const LOBE_MIN_OVERLAP: float = 0.14
const LOBE_SALT: int = 0x3C0A57

## A vector warp applied to the point BEFORE any distance is measured, so every mask in this file —
## island, lobes and islets alike — is measured in bent space. Scalar radial jitter can only push a
## coastline in and out along its own radius, which keeps arcs as arcs; bending the plane turns them
## into inlets and spits.
## Same slope caveat as `COAST_FREQUENCY`: bending space fast compresses the coastal taper into
## less ground. Eased from 0.0055 for the gradual-coast pass; the amplitude — the actual bays and
## spits — is unchanged, they are simply broader sweeps now instead of tight kinks.
const SHAPE_WARP_AMPLITUDE: float = 58.0 / FREQUENCY_SCALE
const SHAPE_WARP_FREQUENCY: float = 0.0036 * FREQUENCY_SCALE
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
## Retuned at the playtest verdict ("weird pits and aggressive valleys"): on the old ~8 m plateau
## this carved a 10 m gorge with walls; on a ~3 m plateau the same numbers dug a pit you fell into
## and could not read from inside. It is a STREAM now — a metre or two below the meadow, banks you
## walk down, still ending under the sea so the mouth is open water.
##
## F-372: that retune moved the DEPTH and left the bank angle alone, so "banks you walk down" stayed
## aspirational — the walls still measured 60.6 degrees against 9.2 for ordinary ground on the same
## island. The next playtest reported it as "a random ravine in the middle of the island": a
## steep-sided dry cut through otherwise flat grass, with the same grass on its floor as on the
## plateau either side. Shallower is not the same property as gentler, and only the second one was
## ever what the sentence above promised.
##
## **The banks were a gorge, and this project's terrain target is not gorges.** The channel
## ceiling is `bed + lateral^2 * RIVER_BANK_RISE` against a `min(surface, channel)` carve, so the
## bank rise decides how far out the walls take to reach the surface, and therefore how steep they
## are. Measured as the steepest 1 m step on a 90 m transect straight across the channel, against a
## control running the identical transect over inland terrain at least 90 m from the river:
##
##     ordinary inland terrain                9.2 deg   (the control)
##     rise 2.2, corridor 2.6  (shipped)     60.6 deg   <- "a random ravine in the middle"
##     rise 0.8, corridor 2.9                44.2 deg
##     rise 0.3, corridor 5.0                35.0 deg   <- chosen
##     rise 0.2, corridor 6.5                28.6 deg
##     rise 0.1, corridor 10.0               24.7 deg
##
## The control is what makes the shipped number damning: the channel was **51 degrees steeper than
## anything else on the island**, which is precisely why it read as an intrusion rather than as
## terrain. 0.3/5.0 halves that excess and turns the walls into something you walk down.
##
## It does not reach the control, and going further is not worth what it costs. The curve flattens
## hard — the last 10 degrees would need double the width, because what is left is no longer the
## channel at all: it is the detail noise riding on top of the walls (which deliberately does NOT
## scale with the island, see FREQUENCY_SCALE above) plus the beach drop where the river meets the
## sea. At 5.0 the valley is already about 70 m across at the mouth on a 590 m island; at 10.0 it
## would be a fifth of the island, which trades one thing that looks wrong for another.
##
## **The corridor has to widen with a softer rise, and this is not optional.** The carve is clipped
## at `width * RIVER_CORRIDOR`, so if the walls have not reached the surface by then the clip itself
## becomes a hard vertical step — the ravine, back, at the corridor edge instead of at the bed.
## Sweeping the rise alone showed it plainly: 0.28 at the old 2.9 corridor measured 60.5 deg, no
## better than shipped. Walls need `sqrt(depth / rise)` half-widths to land, so the two move together.
##
## **The widths stay in absolute metres and deliberately did NOT scale with F-368's larger island.**
## The first attempt scaled them by the radius ratio, for symmetry with `FREQUENCY_SCALE`, and the
## top-down render killed it in one look: a 2.5x wider channel whose bed already dips below sea
## level at the mouth simply flooded, and cut the island in half. A river is a river at any island
## size; only its banks needed to relax. (They went 2.5 -> 3.0 and 6.0 -> 7.0, which is a nudge, not
## a scaling.)
##
## The BED is untouched by all of this: still linear in `t`, which is the monotonic-downhill
## guarantee `tools/terrain_check.gd` walks. Softening banks cannot make water flow uphill.
const RIVER_WIDTH_SOURCE: float = 3.0       # half-width in metres at the source...
const RIVER_WIDTH_MOUTH: float = 7.0        # ...and at the mouth
const RIVER_BED_SOURCE: float = 1.2         # bed height at the source (m)
const RIVER_BED_MOUTH: float = -1.2         # below sea level: the mouth is open water
const RIVER_BANK_RISE: float = 0.30          # how fast the channel ceiling rises off the bed
## Widened with the softer banks: at 0.8 the walls need more lateral room to reach the surface, and
## clipping the corridor before they get there would put a hard step back where the ravine was.
const RIVER_CORRIDOR: float = 5.0           # carve influence ends at width x this
const RIVER_SALT: int = 0x71E5B

## CLIFFS (F-464) — what happens where the river crosses ground the corridor is too narrow for.
##
## Everything above tunes the river on the INTERIOR PLATEAU, and on the plateau it is right: the
## channel ceiling at the corridor edge is `bed + RIVER_CORRIDOR^2 * RIVER_BANK_RISE` = bed + 7.5 m,
## which is already above a ~3 m plateau, so the carve had faded to nothing of its own accord long
## before the clip fired and F-372's measured 35-degree banks are what a player walks down.
##
## Through a placed hill or a ridge crest it is not right. There the surface at the corridor edge is
## metres ABOVE the ceiling, the carve is still holding down real rock when `_river_channel()`
## returns its sentinel, and the whole remainder appears between two adjacent samples: a straight
## vertical wall from the hilltop to the water, which is what play reported.
##
## **Widening the corridor cannot fix that, and this is worth stating once so nobody tries.** Walls
## need `sqrt(depth / rise)` half-widths to land, and through a hill `depth` is whatever terrain the
## river happened to cross — there is no fixed corridor wide enough for an arbitrary one. The fix
## has to be in the SHAPE of the clip, not in where it sits.
##
## So the carve is no longer `min()` clipped at a boundary: it is `min()` faded to zero across the
## outer corridor by `_bank_fade()`, an S-curve. Continuity is then automatic — the carve is worth
## exactly nothing at the corridor edge no matter how tall the ground there is, so there is no step
## left to be vertical. What is left instead is a steep FACE whose gradient is roughly
## `depth / (corridor - hold) * width`: about 45-55 degrees through a 15 m hill on a 7 m-wide mouth.
##
## **That face is supposed to be steep. A river cutting a hill is a gorge, and a gorge is good.**
## The failure play reported was never "steep", it was "vertical, and wearing the same grass as the
## meadow above it". Steep is handled here; rock is handled by `ChunkMesher`'s slope-driven vertex
## alpha and by `world/gen/cliff_dresser.gd`, which runs A-016a's cliff modules along the contour.
##
## THE BENCHING is the third piece. A smooth S-curve face reads as a ramp, because real rock does
## not erode evenly: it fails along its bedding planes and leaves treads and risers. `_carve()`
## soft-quantises the FINISHED WORLD HEIGHT to `CLIFF_BENCH_HEIGHT` bands on the face — world
## height, not local depth, so the ledges are horizontal and continuous across chunk and LOD
## boundaries the way strata are, and free of any noise sample.
##
## Soft-quantised, twice, rather than floored: `f*f*(3-2f)` applied to the fractional part flattens
## the tread and steepens the riser while leaving the surface CONTINUOUS. A true `floor()` staircase
## would put genuine vertical risers back into the heightfield — the exact defect this is fixing,
## only smaller and repeated — and would give `NavBaker` a run of unwalkable steps to choke on.
const RIVER_BANK_HOLD: float = 1.0          # inside this many half-widths nothing here applies
## THE CLIFF RAMP, in metres of rise per metre of ground — `tan(52 degrees)`, which is the angle a
## cut face stands at once the parabola has run out.
##
## This is the number that replaced the clip. Past `width * RIVER_CORRIDOR` the ceiling no longer
## stops; it climbs at a FIXED GRADIENT until it meets the ground, wherever that is. A 38 m hill
## therefore gets a 24 m run of cliff and a 3 m plateau gets none at all, because the parabola has
## already crossed the surface long before the corridor edge there — which is why F-372's tuning
## survives this untouched, to the last decimal, everywhere it was ever measured.
##
## Chosen at 52 rather than steeper because the BENCHING below lands on top of it: soft-quantising
## the face pushes the local riser well past the mean, and the mean is what this sets. Steeper than
## about 55 and the risers reach the vertical the whole change exists to remove.
const CLIFF_RISE_PER_M: float = 1.28
## The hard end of the carve, in metres past the corridor edge. At the ramp above this is enough to
## climb 56 m — more than `MAX_HEIGHT` — so in a shipped island the ceiling always meets the ground
## before this and the cap is never what ends the carve. It exists so the cost of a sample is
## bounded and so no future retune of the island's height can quietly re-create the wall.
const CLIFF_MAX_RUN_M: float = 44.0
## Where the safety taper starts, as a fraction of that run. If the cap ever DOES fire, the carve is
## already faded to nothing when it does, so the failure mode is a shallower gorge and not a step.
const CLIFF_TAPER_FROM: float = 0.72
## The cliff line WANDERS: the ramp's effective distance is stretched and squeezed by this fraction,
## driven by the coast noise the sample already paid for in `shape_into()`. It is the difference
## between a face at a constant 52 degrees for its whole length — which reads as a moulding — and
## one with buttresses and re-entrants. Nothing extra is sampled for it anywhere in this file.
const CLIFF_WANDER: float = 0.30
## How deep the cut has to be before any of the cliff treatment applies. Below the first number the
## carve is a stream bank and F-372 already decided what those look like; a bench in one would be
## the "random ravine" verdict again in miniature.
const CLIFF_DEPTH_MIN: float = 3.5
const CLIFF_DEPTH_FULL: float = 8.0
## Metres per ledge. Around a human step-up: small enough to read as strata rather than as terraces,
## large enough to survive LOD2's 4 m vertex spacing as something other than a shimmer.
const CLIFF_BENCH_HEIGHT: float = 1.35
## How much of the face is benched. Under half on purpose — this is a modulation of the ramp, not a
## replacement for it.
const CLIFF_BENCH_MIX: float = 0.45
const NO_CHANNEL := Vector3(1.0e9, 0.0, 0.0)

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
	# The lobe reach is its LONG axis: an elliptical lobe stretched radially reaches
	# `radius * stretch` outward, so the bound has to reserve that even though the same lobe is
	# narrower than `radius` across. Deliberately not the clamped offset — this is an outer bound,
	# and an over-estimate costs a little empty ocean while an under-estimate culls coastline.
	var lobe_reach: float = LOBE_OFFSET_MAX + LOBE_RADIUS_MAX * LOBE_STRETCH_MAX
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
## The lobe centres, radii and stretch factors this seed's island is built from: one
## `(centre.x, centre.y, radius, stretch)` per lobe, all in metres except the dimensionless
## stretch. Integer arithmetic only, so it is identical on every platform.
##
## Returns `Vector4` rather than the `Vector3` it did before the ellipse pass (F-447). Nothing
## outside this file reads it; `river_polyline()` below is the only other caller and takes the
## centre and radius exactly as it did.
static func lobes(world_seed: int) -> Array[Vector4]:
	var mixed: int = (world_seed ^ LOBE_SALT) & 0x7FFFFFFF
	var count: int = LOBE_COUNT_MIN + (mixed % (LOBE_COUNT_MAX - LOBE_COUNT_MIN + 1))
	var stretch_span: float = LOBE_STRETCH_MAX - LOBE_STRETCH_MIN
	# The first lobe is the island's body: the largest single mass, pushed slightly off the origin
	# so that it HAS a direction to be elongated along (see LOBE_BODY_OFFSET).
	var body_direction: Vector2 = ISLET_DIRECTIONS[(mixed / 3) % ISLET_DIRECTIONS.size()]
	var body_centre: Vector2 = body_direction * (ISLAND_RADIUS * LOBE_BODY_OFFSET)
	var body_stretch: float = LOBE_STRETCH_MIN + stretch_span * float(mixed % 31) / 30.0
	var out: Array[Vector4] = [Vector4(body_centre.x, body_centre.y,
		ISLAND_RADIUS * LOBE_BODY_RADIUS, body_stretch)]
	# The narrowest half-width the body is guaranteed to have in ANY direction, as a fraction of
	# ISLAND_RADIUS — its short axis, less the distance its centre has moved off the origin. The
	# overlap clamp below is measured against this rather than against LOBE_BODY_RADIUS, because a
	# stretched body is narrower than its nominal radius across the short axis and an outer lobe
	# placed against the nominal figure could sit off the end of it. Being conservative here costs
	# a little reach; being optimistic costs a disconnected island on some seeds.
	var body_min_reach: float = LOBE_BODY_RADIUS / body_stretch - LOBE_BODY_OFFSET
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
		var stretch: float = LOBE_STRETCH_MIN + stretch_span * float(step % 37) / 36.0
		# Pull the lobe in if it would only graze the body: a tangent lobe reads as
		# a separate island that happens to touch, and a gap reads as a bug.
		# Both reaches are the SHORT-axis ones, for the reason `body_min_reach` documents.
		offset = minf(offset, body_min_reach + radius / stretch - LOBE_MIN_OVERLAP)
		var centre: Vector2 = direction * (ISLAND_RADIUS * offset)
		out.append(Vector4(centre.x, centre.y, ISLAND_RADIUS * radius, stretch))
	return out


## The unit axis a lobe is elongated along: outward from the island's middle, which is the
## direction its own centre already names. Radial elongation is what makes peninsulas and waists —
## a lobe stretched along its offset reaches further out to sea and stays narrow across, so the
## union grows arms instead of growing fatter. No `sin`/`cos`: this is a normalised difference of
## coordinates the caller already has, which stays inside the D-017 safe set.
##
## Degenerate only if a lobe sits exactly on the origin, which `LOBE_BODY_OFFSET` exists to
## prevent; the fallback keeps the function total rather than relying on that.
static func _lobe_stretch_axis(centre: Vector2) -> Vector2:
	if centre.length() < 0.001:
		return Vector2(1.0, 0.0)
	return centre.normalized()


## Distance from `point` to an ellipse's centre, measured in the ellipse's own frame: the component
## along `axis` divided by `stretch`, the component across it multiplied by `stretch`. Comparing
## that against the lobe's nominal radius is the same test as comparing a real distance against a
## circle, so every mask, falloff and band in this file works on ellipses unchanged.
##
## Area-preserving by construction (the two scalings are reciprocal), which is what lets
## `LOBE_STRETCH_MAX` rise without the island quietly gaining land.
static func _elliptic_distance(point: Vector2, centre: Vector2, axis: Vector2,
		stretch: float) -> float:
	var to_point: Vector2 = point - centre
	var along: float = to_point.dot(axis)
	# The perpendicular component, via the axis's own perpendicular — no trig, no sqrt of a
	# difference that could go negative under rounding.
	var across: float = to_point.dot(Vector2(-axis.y, axis.x))
	return Vector2(along / stretch, across * stretch).length()


## The point, bent, given already-built warp fields. Split out of `_warp_point` (F-241) so a
## caller sampling many points for the same seed — `height_from_set`'s whole reason to exist —
## bends each point without rebuilding `warp_x`/`warp_z`.
static func _warp_point_with(x: float, z: float, warp_x: FastNoiseLite, warp_z: FastNoiseLite) -> Vector2:
	return Vector2(x + warp_x.get_noise_2d(x, z) * SHAPE_WARP_AMPLITUDE,
		z + warp_z.get_noise_2d(x, z) * SHAPE_WARP_AMPLITUDE)


## The point, bent — public, for instruments only (F-447).
##
## Every landform in this file lives in BENT space: `lobes()` centres, `hills()` centres and the
## river polyline are all coordinates the shape warp has already been applied to. A tool that walks
## "outward from this hill's crown along its cliff bearing" in WORLD coordinates is therefore
## walking some other bearing entirely, and the warp's amplitude is ~67 m on a 590 m island, which
## is several times a scarp's width. `tools/hill_slope_check.gd` measured a hill's steep flank as
## GENTLER than its lee for exactly this reason, and the profile was correct the whole time.
##
## Nothing the game builds should call this — the shipped path bends once inside `shape_into()` and
## shares the result. It exists so a check can invert the warp and put its probe where it meant to.
static func bend(x: float, z: float, world_seed: int) -> Vector2:
	return _warp_point(x, z, world_seed)


## The point, bent. Everything that measures a distance in this file measures it here.
static func _warp_point(x: float, z: float, world_seed: int) -> Vector2:
	var warp_x := _make_noise(world_seed ^ SHAPE_WARP_SALT_X, SHAPE_WARP_FREQUENCY, 3,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	var warp_z := _make_noise(world_seed ^ SHAPE_WARP_SALT_Z, SHAPE_WARP_FREQUENCY, 3,
		BASE_NOISE_LACUNARITY, BASE_NOISE_GAIN)
	return _warp_point_with(x, z, warp_x, warp_z)


## One placed hill. A class rather than the `Vector4` this used before F-447 because a hill now
## carries six numbers, not four — the two new ones are what make it asymmetric — and packing them
## into vector components was already the least readable part of this file.
##
## Nothing here is state: `hills()` rebuilds the list from integer mixing on every call, so these
## are values, and the D-017 portability contract is unchanged.
class Hill:
	var centre: Vector2 = Vector2.ZERO
	## Radius of the FLAT TOP. The ramps lie outside it; `footprint()` is the whole landform.
	var top_radius: float = 0.0
	## Metres of lift at the crown.
	var height: float = 0.0
	## The unit bearing the STEEP face points along. Everything asymmetric about the hill is
	## measured as a dot product against this.
	var cliff_direction: Vector2 = Vector2(1.0, 0.0)
	## The gentle side's run in metres per metre of rise.
	var lee_run: float = HILL_LEE_RUN_MAX
	## The steep face's run in metres per metre of rise, from which its ramp length is derived. Never
	## longer than the lee's: a "steep" face with more run than the gentle one is not a steep face,
	## and a seed that draws one simply gets a symmetric upland — the intended ordinary case.
	var scarp_run: float = HILL_SCARP_RUN_MAX

	## The whole landform's outer radius: flat top plus the longer of its two ramps. What anything
	## asking "how much ground does this upland cover" wants.
	func footprint() -> float:
		return top_radius + height * maxf(lee_run, scarp_run)
	## 0 = smoothstep everywhere. Toward `HILL_SHARPNESS_MAX` the steep face's profile front-loads
	## its rise at the toe; the lee is untouched whatever this is.
	var sharpness: float = 0.0


## This seed's placed hills. Integer arithmetic only, same portability contract as `lobes()`.
static func hills(world_seed: int) -> Array[Hill]:
	var mixed: int = (world_seed ^ HILL_SALT) & 0x7FFFFFFF
	var count: int = HILL_COUNT_MIN + (mixed % (HILL_COUNT_MAX - HILL_COUNT_MIN + 1))
	var lobe_list: Array[Vector4] = lobes(world_seed)
	var out: Array[Hill] = []
	for index in count:
		var step: int = mixed / (5 + index * 19)
		# The lobe this hill stands on. Independent per hill, so a seed can pile three onto the
		# body and leave an outer arm bare — which is landform variety, not a bug. Every lobe is
		# land by construction, which is the whole point of choosing one.
		var lobe: Vector4 = lobe_list[(step / (3 + index * 7)) % lobe_list.size()]
		var lobe_centre := Vector2(lobe.x, lobe.y)
		var axis: Vector2 = _lobe_stretch_axis(lobe_centre)
		# Independent bearing and distance within the lobe, same reasoning as lobes(): a fixed
		# stride spaces them into a ring, and a ring of hills reads as a crater rim.
		var direction: Vector2 = ISLET_DIRECTIONS[(step / (7 + index * 3)) % ISLET_DIRECTIONS.size()]
		var offset: float = HILL_LOBE_OFFSET_MAX * float(step % 13) / 12.0
		# The offset is chosen in the lobe's elliptical frame and mapped back out of it — along the
		# long axis it reaches `stretch` times further, across the short axis `1 / stretch`, which
		# is exactly the inverse of `_elliptic_distance()` and therefore lands inside the ellipse
		# whenever `offset` is inside the unit circle.
		var local: Vector2 = direction * (lobe.z * offset)
		var perpendicular := Vector2(-axis.y, axis.x)
		var hill := Hill.new()
		hill.centre = lobe_centre + axis * (local.dot(axis) * lobe.w) \
			+ perpendicular * (local.dot(perpendicular) / lobe.w)
		hill.top_radius = HILL_TOP_RADIUS_MIN \
			+ (HILL_TOP_RADIUS_MAX - HILL_TOP_RADIUS_MIN) * float(step % 29) / 28.0
		# ...but never broader than the lobe can carry. The SHORT half-axis is the binding one: an
		# upland wider than that hangs off the lobe's waist however long the lobe is.
		hill.top_radius = minf(hill.top_radius, lobe.z / lobe.w * HILL_LOBE_FIT)
		var lift_per_radius: float = HILL_LIFT_PER_RADIUS_MIN \
			+ (HILL_LIFT_PER_RADIUS_MAX - HILL_LIFT_PER_RADIUS_MIN) * float(step % 7) / 6.0
		hill.height = clampf(hill.top_radius * lift_per_radius, HILL_HEIGHT_MIN, HILL_HEIGHT_MAX)
		hill.lee_run = HILL_LEE_RUN_MIN \
			+ (HILL_LEE_RUN_MAX - HILL_LEE_RUN_MIN) * float(step % 23) / 22.0
		# The cliff faces its OWN way, off the same table and a different divisor — deliberately
		# not the hill's offset direction. Tying it to the offset would point every cliff either
		# out to sea or back at the island's middle, and the whole island would read as a bowl or
		# as a dome. An unrelated bearing is what makes one hill's bluff face the coast and its
		# neighbour's face inland.
		hill.cliff_direction = ISLET_DIRECTIONS[(step / (11 + index * 7)) % ISLET_DIRECTIONS.size()]
		# Two independent modulo spreads. Both reach the ordinary end of their range, so a seed
		# produces gentle rolling hills, lopsided ones and outright bluffs on the same island.
		hill.scarp_run = HILL_SCARP_RUN_MIN \
			+ (HILL_SCARP_RUN_MAX - HILL_SCARP_RUN_MIN) * float(step % 11) / 10.0
		hill.sharpness = HILL_SHARPNESS_MIN \
			+ (HILL_SHARPNESS_MAX - HILL_SHARPNESS_MIN) * float(step % 17) / 16.0
		# Separation, in one deterministic pass against the hills already placed. A later hill that
		# lands too close to an earlier one is pushed straight out along the line between them,
		# exactly far enough; the earlier one never moves, so the result does not depend on
		# iteration order beyond the order this loop already fixes, and no seed can loop forever.
		for placed: Hill in out:
			var gap: Vector2 = hill.centre - placed.centre
			var needed: float = (hill.footprint() + placed.footprint()) * HILL_MIN_SEPARATION
			var apart: float = gap.length()
			if apart >= needed:
				continue
			# Coincident centres have no line to push along; fall back to the hill's own bearing.
			var push: Vector2 = gap.normalized() if apart > 0.001 else direction
			hill.centre = placed.centre + push * needed
		out.append(hill)
	return out


## Metres of placed-hill lift at `bent`. Overlapping hills merge with `maxf` so neighbours read as
## one broader rise rather than stacking into a peak.
##
## The profile is asymmetric about `cliff_direction` (F-447). `facing` is the cosine of the bearing
## from the hill's crown to the sample — +1 straight down the steep face, -1 straight down the lee,
## and it is a plain normalised dot product, nothing outside the D-017 safe set. It does two jobs:
##
##  · it scales the RADIUS, so the steep face spends the crown height over less ground;
##  · it gates the SHARPNESS, so only the steep face gets the front-loaded curve. `maxf(0, facing)`
##    means the lee half is exactly the smoothstep mound it has always been, and the two halves
##    meet continuously at `facing == 0` because both terms vanish there.
##
## Both curves are polynomials written out longhand — `t*t*(3-2t)` and `1-inv*inv*inv` — never
## `pow()`, for the reason the file header gives.
static func _hill_lift(bent: Vector2, hill_list: Array[Hill]) -> float:
	var lift: float = 0.0
	for hill: Hill in hill_list:
		var to_point: Vector2 = bent - hill.centre
		var distance: float = to_point.length()
		# At the crown itself there is no bearing to speak of; the symmetric profile is the limit
		# from every side, so take it rather than dividing by zero.
		var facing: float = 0.0
		if distance > 0.001:
			facing = to_point.dot(hill.cliff_direction) / distance
		# The FLAT TOP first: inside it the upland is at full crown height and perfectly level, and
		# it is a circle, not an ellipse — the asymmetry belongs to the ramp, not to the summit.
		if distance <= hill.top_radius:
			lift = maxf(lift, hill.height)
			continue
		# Then the RAMP outside it, whose LENGTH varies with bearing: each side's own gradient times
		# the height it has to climb, so both sides keep the gradient they were given whatever the
		# upland's size.
		#
		# **The blend is CUBED toward the steep side, and that is a land-budget decision, not a
		# cosmetic one.** With a linear blend, half of every upland's perimeter carries a long
		# gentle ramp, and a ramp is sloping ground: measured over four seeds, three to five uplands
		# spent so much of the island on their own flanks that level ground fell from 62% of the
		# land to 32%, which is the "map always goes up and down" complaint arriving by a different
		# road. There is only so much island, and a metre of it is either flat or it is a way up.
		#
		# Cubing spends the gentle ramp where it is worth spending: `away` is near zero across most
		# of the perimeter and only opens up in the sector directly opposite the steep face. So an
		# upland is a table with a defined edge nearly all the way round and ONE walkable approach —
		# which is both more level ground and a more legible landform than a cone. An upland whose
		# seed gave it a long `scarp_run` is gentle everywhere regardless; the shaping only decides
		# how much of the perimeter is like the steep side, not how steep that side is.
		var lee_ramp: float = hill.height * hill.lee_run
		var scarp_ramp: float = minf(lee_ramp, hill.height * hill.scarp_run)
		var away: float = (1.0 - facing) * 0.5
		away = away * away * away
		var ramp: float = scarp_ramp + (lee_ramp - scarp_ramp) * away
		if distance >= hill.top_radius + ramp:
			continue
		var t: float = 1.0 - (distance - hill.top_radius) / ramp
		var rounded: float = t * t * (3.0 - 2.0 * t)
		var inv: float = 1.0 - t
		var scarped: float = 1.0 - inv * inv * inv
		var sharp: float = hill.sharpness * maxf(0.0, facing)
		lift = maxf(lift, hill.height * (rounded + (scarped - rounded) * sharp))
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
	var lobe_list: Array[Vector4] = lobes(world_seed)
	for index in range(1, lobe_list.size()):
		var lobe: Vector4 = lobe_list[index]
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
static func _river_channel(bent: Vector2, world_seed: int, wander: float = 0.0) -> Vector3:
	var points: PackedVector2Array = river_polyline(world_seed)
	var total_length: float = 0.0
	for index in range(points.size() - 1):
		total_length += points[index].distance_to(points[index + 1])
	if total_length <= 0.0:
		return NO_CHANNEL

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
	var bed: float = lerpf(RIVER_BED_SOURCE, RIVER_BED_MOUTH, best_t)
	var corridor_m: float = width * RIVER_CORRIDOR
	if best_distance <= corridor_m:
		# F-372's parabola, unchanged. On the interior plateau this is the whole story: the ceiling
		# crosses the surface a few metres out and the carve ends itself, exactly as it did.
		var lateral: float = best_distance / width
		var face_in: float = clampf((lateral - RIVER_BANK_HOLD) / 0.6, 0.0, 1.0)
		return Vector3(bed + lateral * lateral * RIVER_BANK_RISE, 1.0,
			face_in * face_in * (3.0 - 2.0 * face_in))
	# F-464. Past the corridor the ceiling used to stop dead, which is what left a wall wherever the
	# ground was still above it. It ramps instead — at a fixed gradient, for as far as it takes.
	var over: float = (best_distance - corridor_m) * (1.0 + wander * CLIFF_WANDER)
	if over >= CLIFF_MAX_RUN_M:
		return NO_CHANNEL
	var ceiling: float = bed + RIVER_CORRIDOR * RIVER_CORRIDOR * RIVER_BANK_RISE \
		+ over * CLIFF_RISE_PER_M
	var taper: float = 1.0
	var taper_from: float = CLIFF_MAX_RUN_M * CLIFF_TAPER_FROM
	if over > taper_from:
		var t: float = (over - taper_from) / (CLIFF_MAX_RUN_M - taper_from)
		var inv: float = 1.0 - t
		taper = inv * inv * (3.0 - 2.0 * inv)
	return Vector3(ceiling, taper, taper)


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
## F-464 rewrote the second half of this. `channel` is now `_river_channel()`'s
## `(ceiling, fade, face)` triple rather than a bare ceiling, and the carve is scaled by `fade` as
## well as by the mask — which is the whole fix for the vertical wall, because a carve worth zero at
## the corridor edge cannot leave a step there however tall the ground is. Inside the water channel
## `fade` is exactly 1.0 and `face` exactly 0.0, so the bed is bit-for-bit what it was.
static func _carve(channel: Vector3, surface: float, mask: float) -> float:
	var drop: float = channel.x - surface
	if drop >= 0.0:
		return surface
	var carve_strength: float = smoothstep(0.0, 0.35, mask) * channel.y
	if carve_strength <= 0.0:
		return surface
	var carved: float = surface + drop * carve_strength
	# How much of a CLIFF this cross-section is, from the cut the channel is asking for here —
	# `-drop`, the unfaded depth, so the whole face shares one verdict instead of the benching
	# petering out toward the brow where the fade has already thinned the carve.
	var bench: float = channel.z * CLIFF_BENCH_MIX \
		* smoothstep(CLIFF_DEPTH_MIN, CLIFF_DEPTH_FULL, -drop)
	if bench <= 0.0:
		return carved
	# Strata. Soft-quantise the WORLD height (see the CLIFFS block) — flat tread, steep riser, still
	# a continuous surface.
	var band: float = carved / CLIFF_BENCH_HEIGHT
	var whole: float = floorf(band)
	var f: float = band - whole
	f = f * f * (3.0 - 2.0 * f)
	f = f * f * (3.0 - 2.0 * f)
	return lerpf(carved, (whole + f) * CLIFF_BENCH_HEIGHT, bench)


## Falloff for one circular landmass.
##
## An S-curve (smoothstep's own polynomial, hand-written per this file's `t*t*t, never pow()`
## rule), NOT the cubic `inv^3` this used before. The shape of the curve is what a walker feels:
## `inv^3` leaves the plateau at three times the average gradient and then flattens, so all the
## relief was spent in the first few metres of the band and the coast came out as a wall with a
## gentle apron below it. An S-curve leaves the plateau flat, does its steepest work in the middle
## of the band, and arrives at the waterline flat again — a beach at both ends.
## The taper band is a FRACTION of the landmass's own radius, but never narrower than
## [constant MIN_FALLOFF_BAND_M] of actual ground. Without that floor a small landmass gets a
## proportionally small horizontal budget while still having to spend the same absolute relief
## (plateau above water plus sea floor below it) — which is why the steepest coasts left on the
## map after the curve fix were all on islets and on the smallest lobes, exactly where the probe
## found them. A beach is an absolute distance a player walks, not a percentage.
static func _radial_mask(distance: float, radius: float) -> float:
	var band: float = maxf(radius * (1.0 - FALLOFF_START_FRACTION),
		minf(MIN_FALLOFF_BAND_M, radius * MAX_FALLOFF_RADIUS_FRACTION))
	var falloff_start: float = radius - band
	if distance <= falloff_start:
		return 1.0
	if distance >= radius:
		return 0.0
	var t: float = (distance - falloff_start) / (radius - falloff_start)
	var inv: float = 1.0 - t
	return inv * inv * (3.0 - 2.0 * inv)


## The mask body, for a caller that already bent the point — `continent()`/`height()` bend once
## and share it between the mask and the river (4.14), keeping the per-sample noise count flat.
## Takes the seed's landform lists rather than the seed, so the caller's `NoiseSet` supplies them
## once per chunk instead of this rebuilding them once per vertex (see `NoiseSet.lobe_list`).
static func _island_mask_bent(point: Vector2, lobe_list: Array[Vector4],
		islet_list: Array[Vector2], jitter: float = 0.0) -> float:
	var mask: float = 0.0
	for lobe: Vector4 in lobe_list:
		var centre := Vector2(lobe.x, lobe.y)
		# Measured in the lobe's OWN elliptical frame (F-447), so the falloff, the taper band and
		# the jitter all apply to an ellipse exactly as they applied to a disc. The jitter is
		# subtracted in that frame too, which means a stretched lobe's coastline wobbles a little
		# less along its long axis and a little more across it — the right way round, since that is
		# also where its coast is shortest.
		var distance: float = _elliptic_distance(point, centre,
			_lobe_stretch_axis(centre), lobe.w)
		mask = maxf(mask, _radial_mask(distance - jitter, lobe.z))
	# The islets take the LARGER of the masks rather than adding, so where one
	# overlaps the main island it merges into a headland instead of stacking into
	# a spike offshore.
	var islet_radius: float = ISLAND_RADIUS * ISLET_RADIUS_FRACTION
	for centre: Vector2 in islet_list:
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
	## This seed's LANDFORMS, built once alongside the noise fields (F-447).
	##
	## `lobes()`, `islet_centres()` and `hills()` are pure integer arithmetic, but they ALLOCATE —
	## an array, and for hills a `Hill` per entry — and `shape_into()` called all three on every
	## sample. That was tolerable when a hill was four floats in a `Vector4` and there were three of
	## them; with 5-8 asymmetric hills each carrying a bearing it is 5-8 object allocations per
	## vertex, and `world/chunk/chunk_mesher.gd` takes ~1,089 vertices per chunk.
	##
	## Measured by `tools/noise_reuse_check.gd`, which times the shared-set path against rebuilding
	## per sample: the F-447 hills dropped that ratio from 1.88x to 1.22x, tripping its 1.3x floor.
	## Hoisting the three lists onto the set — where they belong, being per-seed constants exactly
	## like the noise fields — put it back. Same threading rule as the rest of the set for the same
	## reason: one set per `WorkerThreadPool` task, never shared.
	var lobe_list: Array[Vector4] = []
	var islet_list: Array[Vector2] = []
	var hill_list: Array[Hill] = []


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
	## `_river_channel()` at `bent`: `(ceiling, fade, face)`, or `NO_CHANNEL` outside the corridor.
	##
	## A `Vector3` rather than the bare ceiling it was before F-464, because the carve now needs the
	## bank fade (what stops the corridor edge from being a vertical wall) and the face weight (what
	## decides where the strata benching applies) at the same point, and a builtin value type costs
	## no allocation to carry all three.
	##
	## Cached here because the carve is applied TWICE per biome-shaped sample — once to the continent
	## the biome is classified from, once to the finished surface — and the channel is a function of
	## `bent` and `world_seed` alone, so the two applications cannot disagree. Walking the polyline
	## twice was measured at roughly a third of a sample's cost: `_river_channel()` rebuilds the
	## polyline (which rebuilds `lobes()`), sums its length and then walks its segments again.
	var channel: Vector3 = NO_CHANNEL


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
	set.lobe_list = lobes(world_seed)
	set.islet_list = islet_centres(world_seed)
	set.hill_list = hills(world_seed)
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
	# One sample, two consumers: the coast's own jitter in metres, and (F-464) the -1..1 field that
	# wanders the cliff line so it is not a parabolic offset from the polyline. Nothing extra is
	# sampled for the cliffs anywhere in this file.
	var coast: float = set.coast_noise.get_noise_2d(x, z)
	var jitter: float = coast * COAST_JITTER
	out.bent = _warp_point_with(x, z, set.warp_x, set.warp_z)
	out.mask = _island_mask_bent(out.bent, set.lobe_list, set.islet_list, jitter)
	# Plateau + placed hills (D-184 second pass): the noise is damped to an undulation on a
	# near-flat interior, and the hills are seeded landforms — both ride the island mask so the
	# coast still tapers into the sea wherever this seed put it. Where the mask runs out the
	# ground settles onto the OCEAN FLOOR below the waterline instead of a plain at exactly 0 —
	# one continuous surface, land above the sea and seabed under it.
	# CUBED, not linear: the seabed term is what the water column is made of, and a linear
	# `(1 - mask)` spends it at full rate the instant the mask leaves 1.0 — so the sea floor fell
	# away at the same place the land was already falling, and the two stacked into the coastal
	# wall the playtest hit. Cubing gives a SHELF: near shore `1 - mask` is small and its cube is
	# far smaller, so the water stays ankle-to-knee deep for a long wade out, then deepens toward
	# the full OCEAN_FLOOR_DEPTH offshore where depth is scenery rather than something you cross.
	var offshore: float = 1.0 - out.mask
	out.raw_continent = ((set.base_noise.get_noise_2d(x, z) * BASE_NOISE_WEIGHT + LAND_BIAS)
		* HEIGHT_SCALE + _hill_lift(out.bent, set.hill_list)) * out.mask \
		- OCEAN_FLOOR_DEPTH * offshore * offshore * offshore
	out.channel = _river_channel(out.bent, world_seed, coast)


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
