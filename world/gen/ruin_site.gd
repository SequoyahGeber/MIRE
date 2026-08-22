extends RefCounted

## Lays out one ruined hall from the `environment` kit's ruin pieces (F-493).
##
## ## Why this exists
##
## `ruin_wall_a-d`, `ruin_column_a-d` and `ruin_arch_a-b` were modelled, exported and then placed
## only by the two hand-authored layouts — so the game that ships, which generates its island, had
## no ruin anywhere in it. A scatter table could not fix that: scatter places single props at
## independent points, and a ruin is not a prop, it is an ARRANGEMENT. One wall alone in a meadow
## reads as a dropped asset; three walls, a corner column and an arch on the same rectangle read as
## a building somebody left.
##
## ## What it produces
##
## A pure list of pieces in the site's LOCAL space, deterministic from `site_seed` alone —
## `{asset, kit, offset: Vector3, yaw: float, tilt: Vector2, scale: float, sink: float}`. The caller
## owns the world: it samples the surface under each piece and drops it there (`sink` is how far
## into the ground it settles, which is what stops a ruin standing on the grass like furniture).
##
## The plan is a hall on a 13.4 x 9 m rectangle, because that is what the pieces measure: a wall
## segment is 4.48 m long and 2.41 m tall, an arch 3.45 m, a column 1.10 m across. Three segments a
## side and two per end is the smallest arrangement in which a missing segment reads as a GAP rather
## than as the whole building being absent. Roughly a third of the segments are gone, one end
## carries the arch as its doorway, some columns still stand and one has come down; a couple of
## walls lie flat where they fell, outward, because a wall falls away from the floor it faced.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2. Pure content geometry derived from the world seed, identical on
## every peer, never sent. Same standing as `world/gen/resource_scatter.gd`.

const KIT: String = "environment"

## Metres. Wall segments are 4.48 m long; the hall is three of them by two.
const BAY_M: float = 4.48
const HALF_LENGTH_M: float = BAY_M * 1.5
const HALF_WIDTH_M: float = 4.48
## Wall thickness, used to lie a fallen segment down on its side rather than through the floor.
const WALL_THICKNESS_M: float = 0.79

## Fraction of wall segments that are simply gone. Tuned by eye on the check's census: below about
## a quarter the hall reads as intact-but-roofless, above about a half it stops reading as a
## building at all.
const WALL_MISSING_CHANCE: float = 0.34
const COLUMN_MISSING_CHANCE: float = 0.4


## Every piece of one ruin, in local space. `site_seed` is the only input, so the same site rebuilds
## identically on every peer and across a rejoin.
static func pieces_for_site(site_seed: int) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = site_seed
	var pieces: Array[Dictionary] = []
	var fallen: Array[Dictionary] = []

	# The two long sides, three bays each, running along X.
	for side: int in 2:
		var z: float = HALF_WIDTH_M * (1.0 if side == 0 else -1.0)
		for bay: int in 3:
			var x: float = (float(bay) - 1.0) * BAY_M
			if rng.randf() < WALL_MISSING_CHANCE:
				# A segment that is gone did not evaporate. Half the time it is lying just outside
				# the wall line, which is what makes the gap read as collapse.
				if rng.randf() < 0.5:
					fallen.append(_fallen_wall(rng, x, z, 0.0))
				continue
			pieces.append(_wall(rng, Vector3(x, 0.0, z), 0.0))

	# The two ends, two bays each, running along Z — minus the doorway.
	var door_side: int = rng.randi_range(0, 1)
	for side: int in 2:
		var x: float = HALF_LENGTH_M * (1.0 if side == 0 else -1.0)
		if side == door_side:
			# The arch IS the doorway: centred on the end wall, with the two half-bays beside it.
			pieces.append({
				"asset": StringName("ruin_arch_%s" % ("a" if rng.randf() < 0.5 else "b")),
				"kit": KIT,
				"offset": Vector3(x, 0.0, 0.0),
				"yaw": deg_to_rad(90.0) + _jitter_yaw(rng),
				"tilt": Vector2(_jitter_tilt(rng), _jitter_tilt(rng)),
				"scale": 1.0,
				"sink": _sink(rng),
			})
			continue
		for bay: int in 2:
			var z: float = (float(bay) - 0.5) * BAY_M
			if rng.randf() < WALL_MISSING_CHANCE:
				if rng.randf() < 0.5:
					fallen.append(_fallen_wall(rng, x, z, deg_to_rad(90.0)))
				continue
			pieces.append(_wall(rng, Vector3(x, 0.0, z), deg_to_rad(90.0)))

	# Corner columns, plus two down the spine where a roof would have been carried.
	var column_spots: Array[Vector3] = [
		Vector3(HALF_LENGTH_M, 0.0, HALF_WIDTH_M),
		Vector3(HALF_LENGTH_M, 0.0, -HALF_WIDTH_M),
		Vector3(-HALF_LENGTH_M, 0.0, HALF_WIDTH_M),
		Vector3(-HALF_LENGTH_M, 0.0, -HALF_WIDTH_M),
		Vector3(BAY_M * 0.5, 0.0, 0.0),
		Vector3(-BAY_M * 0.5, 0.0, 0.0),
	]
	var standing_columns: int = 0
	for spot: Vector3 in column_spots:
		var letter: String = "abcd"[rng.randi_range(0, 3)]
		if rng.randf() < COLUMN_MISSING_CHANCE:
			# A toppled column lies where it fell, pointing away from the middle of the hall.
			if rng.randf() < 0.55:
				var away: float = atan2(spot.z, spot.x)
				fallen.append({
					"asset": StringName("ruin_column_%s" % letter),
					"kit": KIT,
					"offset": Vector3(spot.x + cos(away) * 1.4, 0.0, spot.z + sin(away) * 1.4),
					"yaw": away,
					# Lying down: 90 degrees about its own X, so the shaft runs along the ground.
					"tilt": Vector2(deg_to_rad(90.0), _jitter_tilt(rng)),
					"scale": 1.0,
					"sink": 0.0,
					"lying_radius": 0.55,
				})
			continue
		standing_columns += 1
		pieces.append({
			"asset": StringName("ruin_column_%s" % letter),
			"kit": KIT,
			"offset": spot,
			"yaw": rng.randf_range(-PI, PI),
			"tilt": Vector2(_jitter_tilt(rng) * 2.0, _jitter_tilt(rng) * 2.0),
			"scale": rng.randf_range(0.95, 1.08),
			"sink": _sink(rng),
		})

	pieces.append_array(fallen)

	# A ruin with nothing above knee height is a rubble field. If the dice took everything, stand
	# the two spine columns back up rather than shipping a site with no silhouette.
	if standing_columns == 0:
		for spot: Vector3 in [Vector3(BAY_M * 0.5, 0.0, 0.0), Vector3(-BAY_M * 0.5, 0.0, 0.0)]:
			pieces.append({
				"asset": &"ruin_column_a", "kit": KIT, "offset": spot,
				"yaw": rng.randf_range(-PI, PI), "tilt": Vector2(_jitter_tilt(rng), _jitter_tilt(rng)),
				"scale": 1.0, "sink": _sink(rng),
			})
	return pieces


static func _wall(rng: RandomNumberGenerator, offset: Vector3, yaw: float) -> Dictionary:
	return {
		"asset": StringName("ruin_wall_%s" % "abcd"[rng.randi_range(0, 3)]),
		"kit": KIT,
		"offset": offset,
		"yaw": yaw + _jitter_yaw(rng),
		"tilt": Vector2(_jitter_tilt(rng), _jitter_tilt(rng)),
		"scale": 1.0,
		"sink": _sink(rng),
	}


## A wall on its back, pushed clear of the line it stood on. `lying_radius` tells the caller how far
## off the ground the piece's own origin has to sit once it is on its side — the caller cannot know
## that from a transform alone, and a wall lying half-buried in the turf is the usual way this goes
## wrong.
static func _fallen_wall(rng: RandomNumberGenerator, x: float, z: float, yaw: float) -> Dictionary:
	var outward: float = 1.6 + rng.randf() * 1.2
	var offset := Vector3(x, 0.0, z + signf(z) * outward) if is_zero_approx(yaw) \
		else Vector3(x + signf(x) * outward, 0.0, z)
	return {
		"asset": StringName("ruin_wall_%s" % "abcd"[rng.randi_range(0, 3)]),
		"kit": KIT,
		"offset": offset,
		"yaw": yaw + rng.randf_range(-0.5, 0.5),
		"tilt": Vector2(deg_to_rad(90.0), 0.0),
		"scale": 1.0,
		"sink": 0.0,
		"lying_radius": WALL_THICKNESS_M * 0.5,
	}


## Small, deliberately: a ruin is masonry that has settled, not a shanty. Enough to break the
## right angles that would otherwise say "placed by a computer".
static func _jitter_yaw(rng: RandomNumberGenerator) -> float:
	return rng.randf_range(-0.06, 0.06)


static func _jitter_tilt(rng: RandomNumberGenerator) -> float:
	return rng.randf_range(-0.045, 0.045)


## How far a standing piece sinks into the ground, in metres. Ruins are old; the turf has come up
## around them, and a footing sitting exactly on the surface reads as scenery placed this morning.
static func _sink(rng: RandomNumberGenerator) -> float:
	return rng.randf_range(0.08, 0.3)
