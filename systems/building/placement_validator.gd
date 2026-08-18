class_name PlacementValidator
extends RefCounted

## Decides whether a buildable may sit at a transform. **One implementation, two callers**, and that
## is the whole point of the file existing separately from either of them:
##
##   · the client's ghost calls it every frame to colour itself green or red — a HINT;
##   · the host calls the same function to accept or reject the placement — the ANSWER.
##
## docs/SPECS.md 3.6 requires the host to "revalidate from scratch", and it does: it runs this
## against its own physics world with its own inputs and believes nothing the client sent but the
## piece id and the transform. Sharing the CODE is not sharing the verdict. What it buys is that a
## green ghost and an accepted placement cannot drift apart through two subtly different rules, which
## is the bug that makes a building system feel broken — you line a wall up, it reads green, and the
## server refuses it with no explanation.
##
## Deliberately has no state, no autoload, and no knowledge of inventory. Cost is the one rule it
## does NOT check, because affordability needs a peer's inventory and only the host has that;
## `Reason.CANNOT_AFFORD` lives in the enum anyway so the whole flow speaks one vocabulary and the
## ghost can display a host rejection it could not itself have predicted.

enum Reason {
	OK,
	UNKNOWN_PIECE,
	OUT_OF_RANGE,
	OVERLAPS,
	NO_SUPPORT,
	TOO_STEEP,
	CANNOT_AFFORD,
}

## How far below the footprint to look for ground before calling it unsupported.
const SUPPORT_PROBE_DEPTH_M: float = 0.6
## Lifts the support ray's start slightly so a piece resting exactly on the ground still probes from
## outside the surface rather than starting inside it, which reads as no hit.
const SUPPORT_PROBE_LIFT_M: float = 0.15
## Shrinks the overlap box a hair. Two walls placed on adjacent grid cells share a face exactly, and
## an unshrunk box query reports that touching face as an intersection — every second wall would be
## refused for overlapping its neighbour.
const OVERLAP_SKIN_M: float = 0.02
## Floor of the ground clearance below. A piece on perfectly flat ground still needs its query box
## lifted clear of the surface it is resting on.
const MIN_GROUND_CLEARANCE_M: float = 0.12


## Grid- and rotation-snapped placement for a raw aim point. Pure: no physics, no world, so it is
## identical on every peer by construction and the check can assert it without a scene.
##
## Snapping happens in world space, not relative to the builder — a wall placed by one player has to
## line up with a wall placed by another, and a builder-relative grid guarantees they never do.
static func snap_transform(def: Resource, origin: Vector3, yaw_radians: float) -> Transform3D:
	if def == null:
		return Transform3D(Basis(Vector3.UP, yaw_radians), origin)
	var step: float = float(def.get(&"snap_step"))
	var snapped_origin: Vector3 = origin
	if step > 0.0:
		# Y is snapped too: a floor at 2.5 m and another at 2.51 m is a seam you cannot see and
		# cannot walk over.
		snapped_origin = Vector3(
			snappedf(origin.x, step), snappedf(origin.y, step), snappedf(origin.z, step)
		)
	var yaw: float = yaw_radians
	var rotation_step: float = float(def.get(&"rotation_step_degrees"))
	if rotation_step > 0.0:
		var step_radians: float = deg_to_rad(rotation_step)
		yaw = snappedf(yaw_radians, step_radians)
	return Transform3D(Basis(Vector3.UP, yaw), snapped_origin)


## The verdict. `placement` is the snapped transform whose origin sits at the piece's FLOOR centre,
## `builder_position` is where the player asking for it is standing.
##
## Returns a Reason. Order matters: the cheapest and most explanatory checks run first, so a player
## reaching too far is told that rather than being told the ground is too steep 8 m away.
static func evaluate(
	space: PhysicsDirectSpaceState3D,
	def: Resource,
	placement: Transform3D,
	builder_position: Vector3,
	collision_mask: int = 1,
	ignore_bodies: Array[RID] = []
) -> Reason:
	if def == null:
		return Reason.UNKNOWN_PIECE

	var range_m: float = float(def.get(&"max_build_range_m"))
	if builder_position.distance_to(placement.origin) > range_m:
		return Reason.OUT_OF_RANGE

	# No physics world (a pure harness, a headless menu) means the geometric rules above are all we
	# can honestly check. Returning OK here rather than inventing a failure keeps snap/range testable
	# without a scene; every caller that matters has a space state.
	if space == null:
		return Reason.OK

	# Ground BEFORE obstruction, and the order is load-bearing rather than stylistic. A piece on a
	# slope steep enough to refuse is also, geometrically, buried in that slope — so an
	# overlap-first order reports every steep placement as "something is in the way", which is true
	# and useless. The player needs to be told about the slope, because that is the thing they can
	# do something about.
	if bool(def.get(&"requires_support")):
		var support: Dictionary = _probe_support(space, def, placement, collision_mask, ignore_bodies)
		if support.is_empty():
			return Reason.NO_SUPPORT
		var normal: Vector3 = support["normal"]
		var slope_degrees: float = rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0)))
		if slope_degrees > float(def.get(&"max_ground_slope_degrees")):
			return Reason.TOO_STEEP

	if _overlaps(space, def, placement, collision_mask, ignore_bodies):
		return Reason.OVERLAPS

	return Reason.OK


static func is_placeable(reason: Reason) -> bool:
	return reason == Reason.OK


## Player-facing text. Lives here so the ghost, the host's rejection log and any future UI all say
## the same words for the same refusal.
static func reason_text(reason: Reason) -> String:
	match reason:
		Reason.OK: return "ok"
		Reason.UNKNOWN_PIECE: return "no such piece"
		Reason.OUT_OF_RANGE: return "too far away"
		Reason.OVERLAPS: return "something is in the way"
		Reason.NO_SUPPORT: return "nothing underneath it"
		Reason.TOO_STEEP: return "the ground is too steep"
		Reason.CANNOT_AFFORD: return "not enough materials"
	return "cannot build here"


static func _overlaps(
	space: PhysicsDirectSpaceState3D,
	def: Resource,
	placement: Transform3D,
	collision_mask: int,
	ignore_bodies: Array[RID]
) -> bool:
	var half: Vector3 = def.call(&"half_extents")
	var size: Vector3 = def.get(&"size")

	# Lift the query box clear of the ground it is standing on. Without this the terrain IS the
	# overlap: on flat ground the base face is flush, and on any slope the uphill side of the
	# footprint rises into the box, so every sloped placement reads as obstructed. The clearance is
	# derived rather than a magic number — it is exactly how high the ground can legitimately reach
	# within this piece's own footprint at the steepest slope it permits, so a piece that allows
	# steeper ground automatically lifts further. Capped at a third of the height so the box always
	# still tests a real volume.
	#
	# A dedicated terrain collision layer would be the cleaner answer and would let the overlap query
	# simply not look at the ground. The project puts world statics and props on layer 1 together
	# today, so that is a project-wide change and not this task's to make — filed as F-075.
	var footprint_reach: float = maxf(half.x, half.z)
	var slope_rise: float = footprint_reach * tan(deg_to_rad(
		clampf(float(def.get(&"max_ground_slope_degrees")), 0.0, 80.0)))
	var clearance: float = clampf(
		maxf(MIN_GROUND_CLEARANCE_M, slope_rise), MIN_GROUND_CLEARANCE_M, size.y / 3.0)

	var shape := BoxShape3D.new()
	shape.size = Vector3(
		maxf(0.01, size.x - OVERLAP_SKIN_M * 2.0),
		maxf(0.01, size.y - clearance - OVERLAP_SKIN_M),
		maxf(0.01, size.z - OVERLAP_SKIN_M * 2.0)
	)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	# The placement origin is the piece's FLOOR centre; the query box spans from `clearance` above
	# that up to the piece's full height, so its centre sits accordingly.
	query.transform = Transform3D(
		placement.basis, placement.origin + Vector3.UP * (clearance + shape.size.y * 0.5))
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = ignore_bodies
	return not space.intersect_shape(query, 1).is_empty()


## Looks for ground under the footprint's four bottom corners AND its centre, and reports the
## flattest thing it finds. Five probes rather than one because a single centre ray happily reports
## solid ground for a wall with three quarters of it hanging over a cliff.
static func _probe_support(
	space: PhysicsDirectSpaceState3D,
	def: Resource,
	placement: Transform3D,
	collision_mask: int,
	ignore_bodies: Array[RID]
) -> Dictionary:
	var half: Vector3 = def.call(&"half_extents")
	var offsets: Array[Vector3] = [
		Vector3.ZERO,
		Vector3(half.x, 0.0, half.z), Vector3(-half.x, 0.0, half.z),
		Vector3(half.x, 0.0, -half.z), Vector3(-half.x, 0.0, -half.z),
	]
	var best: Dictionary = {}
	var best_slope: float = 1000.0
	for offset: Vector3 in offsets:
		var point: Vector3 = placement.origin + placement.basis * offset
		var query := PhysicsRayQueryParameters3D.create(
			point + Vector3.UP * SUPPORT_PROBE_LIFT_M,
			point + Vector3.DOWN * SUPPORT_PROBE_DEPTH_M
		)
		query.collision_mask = collision_mask
		query.exclude = ignore_bodies
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit["normal"]
		var slope: float = rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0)))
		if slope < best_slope:
			best_slope = slope
			best = hit
	return best
