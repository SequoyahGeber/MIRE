extends RefCounted

## Lays out one prehistoric stone circle from the `environment` kit's megalith pieces (F-573).
##
## ## Why this exists
##
## `standing_stone_a-d` and `stone_marker_a-b` were modelled and exported, and
## `content/poi/standing_stones.tres` asks for six sites an island — but that def carried no
## `scene_path`, no `structure_id` and no `marker_kind`, so `procedural_world.gd` built six bare
## `Node3D` roots and moved on. Six invisible sites, each still holding a 30 m clearance radius and
## a 90 m mutual spacing, shoving real POIs apart and keeping scatter out of six empty circles of
## grassland. `entities/props/standing_stone_circle.tscn` is the authored arrangement that was
## presumably meant to fill them and nothing ever referenced it.
##
## ## Why a STRUCTURE and not that scene
##
## `PoiDef.scene_path`'s own docstring draws the line (F-493): a scene is ONE authored arrangement,
## so every island — and here, all six sites on the SAME island — would get the identical circle;
## a structure is a function of the seed, so each one is its own. Six copies of one prop, ninety
## metres apart on ground a player crosses repeatedly, is exactly the case that doc names. The
## authored scene stays in the repo as the reference this was laid out against.
##
## ## What a real one looks like
##
## Measured against the surviving British circles rather than invented. Diameters run from about
## 11 m (Nine Ladies, Derbyshire, nine stones) through 22 m (Boskednan) to 30 m (Castlerigg,
## thirty-eight stones), so the small-to-middling end is the common case and the one that fits
## inside this def's 30 m clearance. Stones stand 2-3 m and sit 3-4 m apart. Four details do most
## of the work of reading as ancient rather than as decoration:
##
##   · **They are incomplete.** Essentially no circle survives whole — stones are missing, robbed
##     for walls, or lying where they fell. An intact ring reads as a garden feature.
##   · **They lean.** Almost nothing is plumb after four thousand years of frost.
##   · **A fallen stone lies OUTWARD.** A leaning stone topples the way it was already going, away
##     from the ring it was set facing.
##   · **Some have an outlier.** Castlerigg, the Rollright King Stone, Long Meg: a single taller
##     monolith set apart from the ring. Common, not universal.
##
## A central feature (a cairn, a single monolith) is real but decidedly a minority — most circles
## are an empty ring. It is drawn on a minority of sites here for that reason: the spread has to
## contain plain ordinary circles or the unusual ones stop reading as unusual.
##
## ## What it produces
##
## A pure list of pieces in the site's LOCAL space, deterministic from `site_seed` alone —
## `{asset, kit, offset: Vector3, yaw: float, tilt: Vector2, scale: float, sink: float,
## lying_radius: float}`. Identical contract to `ruin_site.gd`, because `PoiStructures.build()`
## consumes both; the caller owns the world and samples the surface under each piece.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2. Pure content geometry derived from the world seed, identical on
## every peer, never sent. Same standing as `world/gen/ruin_site.gd`.

const KIT: String = "environment"

## The ring stones, tallest first. Heights from `assets/environment/catalog.json`:
## a 3.258 m, b 2.891 m, d 2.352 m, c 2.203 m.
const RING_ASSETS: Array[String] = [
	"standing_stone_a", "standing_stone_b", "standing_stone_c", "standing_stone_d",
]
## Shorter, squatter markers, mixed into the ring so it is not four meshes in rotation.
const MARKER_ASSETS: Array[String] = ["stone_marker_a", "stone_marker_b"]
## Field debris and the centre cairn. `boulder_b` is the tallest piece in the kit at 3.383 m, which
## is what makes it the outlier stone as well.
const OUTLIER_ASSET: String = "boulder_b"
const CAIRN_ASSETS: Array[String] = ["rock_cluster_a", "rock_cluster_c"]

## Ring radius. 6.5-9.0 m is a 13-18 m circle — the small-to-middling real range, and the largest
## that leaves margin inside the def's 30 m clearance for the outlier and the debris.
const RADIUS_MIN_M: float = 6.5
const RADIUS_MAX_M: float = 9.0
## Target gap between neighbouring stones along the ring, which is what actually sets the count:
## a wider ring gets more stones, not stones further apart. 3.6 m is Swinside's spacing.
const SPACING_M: float = 3.6
const MIN_STONES: int = 9
const MAX_STONES: int = 16

## Fraction of ring positions with no stone standing at all — robbed or buried. Real circles run
## far higher than this; this is the readable floor, below which the ring stops looking ancient and
## above which it stops looking like a ring.
const MISSING_CHANCE: float = 0.18
## Of the stones that DO remain, the fraction lying flat rather than standing.
const FALLEN_CHANCE: float = 0.16

## How far a standing stone leans off plumb, radians. Four degrees is plenty to read at a distance.
const MAX_LEAN_RAD: float = 0.07
## How far a stone sits into the ground, metres. They are set in sockets, not stood on the turf.
const SINK_M: float = 0.35
## A fallen stone lies on its side, so its half-thickness is how far its axis is off the ground.
const LYING_RADIUS_M: float = 0.42

## The outlier monolith, when a site has one: how far beyond the ring, and how likely.
const OUTLIER_CHANCE: float = 0.45
const OUTLIER_GAP_MIN_M: float = 3.5
const OUTLIER_GAP_MAX_M: float = 7.0

## A centre feature is the minority case — see the header. Most circles are an empty ring.
const CENTRE_CHANCE: float = 0.3
## Loose stones lying in the field around the ring. Always a couple, so the ground reads as worked.
const DEBRIS_MIN: int = 2
const DEBRIS_MAX: int = 5


## Every piece of one stone circle, in local space. `site_seed` is the only input, so the same site
## rebuilds identically on every peer and across a rejoin.
static func pieces_for_site(site_seed: int) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = site_seed
	var pieces: Array[Dictionary] = []

	var radius: float = rng.randf_range(RADIUS_MIN_M, RADIUS_MAX_M)
	# Count follows from circumference, so the ring's spacing stays constant as its size varies —
	# a big circle is a bigger circle, not a sparser one.
	var count: int = clampi(int(round(TAU * radius / SPACING_M)), MIN_STONES, MAX_STONES)
	# One arbitrary rotation for the whole ring, so a site's stones are not all on the same bearing
	# as the site next to it. The site root's own yaw turns the finished circle again.
	var ring_phase: float = rng.randf_range(0.0, TAU)

	for index: int in count:
		if rng.randf() < MISSING_CHANCE:
			continue
		# Positions are jittered off the exact division: these were set by eye with rope, and a
		# ring that surveys perfectly reads as machined.
		var angle: float = ring_phase + TAU * float(index) / float(count) \
			+ rng.randf_range(-0.055, 0.055)
		var stone_radius: float = radius + rng.randf_range(-0.4, 0.4)
		var offset := Vector3(cos(angle) * stone_radius, 0.0, sin(angle) * stone_radius)
		var asset: String = (
			MARKER_ASSETS[rng.randi_range(0, MARKER_ASSETS.size() - 1)]
			if rng.randf() < 0.25
			else RING_ASSETS[rng.randi_range(0, RING_ASSETS.size() - 1)]
		)
		# A slab's broad face turns to follow the ring, which is how they were set — you walk into
		# the circle between two faces, not past two edges.
		var facing: float = angle + PI * 0.5

		if rng.randf() < FALLEN_CHANCE:
			# Tipped onto its side, and outward: a leaning stone falls the way it was already
			# going, away from the ring it faced. `lying_radius` lifts its axis clear of the ground.
			pieces.append({
				"asset": asset,
				"kit": KIT,
				"offset": offset,
				"yaw": facing,
				"tilt": Vector2(PI * 0.5 * (1.0 if rng.randf() < 0.75 else -1.0), 0.0),
				"scale": rng.randf_range(0.92, 1.08),
				"sink": 0.12,
				"lying_radius": LYING_RADIUS_M,
			})
			continue

		pieces.append({
			"asset": asset,
			"kit": KIT,
			"offset": offset,
			"yaw": facing + rng.randf_range(-0.12, 0.12),
			"tilt": Vector2(
				rng.randf_range(-MAX_LEAN_RAD, MAX_LEAN_RAD),
				rng.randf_range(-MAX_LEAN_RAD, MAX_LEAN_RAD),
			),
			"scale": rng.randf_range(0.88, 1.14),
			"sink": SINK_M,
			"lying_radius": 0.0,
		})

	# The outlier — one taller monolith set apart from the ring, on its own bearing.
	if rng.randf() < OUTLIER_CHANCE:
		var out_angle: float = rng.randf_range(0.0, TAU)
		var out_radius: float = radius + rng.randf_range(OUTLIER_GAP_MIN_M, OUTLIER_GAP_MAX_M)
		pieces.append({
			"asset": OUTLIER_ASSET,
			"kit": KIT,
			"offset": Vector3(cos(out_angle) * out_radius, 0.0, sin(out_angle) * out_radius),
			"yaw": rng.randf_range(0.0, TAU),
			"tilt": Vector2(
				rng.randf_range(-MAX_LEAN_RAD, MAX_LEAN_RAD),
				rng.randf_range(-MAX_LEAN_RAD, MAX_LEAN_RAD),
			),
			"scale": rng.randf_range(1.0, 1.2),
			"sink": SINK_M,
			"lying_radius": 0.0,
		})

	# The centre, on the minority of sites that have one — a low cairn of loose stone.
	if rng.randf() < CENTRE_CHANCE:
		var cairn_count: int = rng.randi_range(1, 3)
		for _i: int in cairn_count:
			var cairn_angle: float = rng.randf_range(0.0, TAU)
			var cairn_radius: float = rng.randf_range(0.0, 1.6)
			pieces.append({
				"asset": CAIRN_ASSETS[rng.randi_range(0, CAIRN_ASSETS.size() - 1)],
				"kit": KIT,
				"offset": Vector3(
					cos(cairn_angle) * cairn_radius, 0.0, sin(cairn_angle) * cairn_radius
				),
				"yaw": rng.randf_range(0.0, TAU),
				"tilt": Vector2(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12)),
				"scale": rng.randf_range(0.7, 1.0),
				"sink": 0.5,
				"lying_radius": 0.0,
			})

	# Loose stone lying in the field between the ring and its clearance — spoil from the sockets,
	# and pieces of whatever is no longer standing.
	var debris: int = rng.randi_range(DEBRIS_MIN, DEBRIS_MAX)
	for _i: int in debris:
		var debris_angle: float = rng.randf_range(0.0, TAU)
		var debris_radius: float = radius * rng.randf_range(0.35, 1.75)
		pieces.append({
			"asset": CAIRN_ASSETS[rng.randi_range(0, CAIRN_ASSETS.size() - 1)],
			"kit": KIT,
			"offset": Vector3(
				cos(debris_angle) * debris_radius, 0.0, sin(debris_angle) * debris_radius
			),
			"yaw": rng.randf_range(0.0, TAU),
			"tilt": Vector2(rng.randf_range(-0.2, 0.2), rng.randf_range(-0.2, 0.2)),
			"scale": rng.randf_range(0.45, 0.8),
			"sink": 0.45,
			"lying_radius": 0.0,
		})

	return pieces
