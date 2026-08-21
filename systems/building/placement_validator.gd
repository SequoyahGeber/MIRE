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

## Dedicated ground layer (F-075). World generators put terrain here and NOTHING else — props,
## harvestables, placed buildable pieces, players and enemies all stay on the shared "solid" layer
## (1) that callers pass as `collision_mask`. `_probe_support` ALWAYS ORs this in regardless of the
## caller's mask, because a piece needs ground to stand on whether or not the caller thought to ask
## for it; `_overlaps` never adds it, because a piece resting flush on the ground must not read the
## ground it is standing on as "something in the way". Before this layer existed, terrain and props
## shared `collision_mask` and the overlap query worked around the ground being indistinguishable
## from an obstruction by lifting its query box — see `_overlaps` for what that cost.
## `world/gen/authored_world.gd` is the one generator that emits terrain today; anything new that
## emits ground collision must put it here too, or its slopes will read every placement as blocked.
const TERRAIN_LAYER: int = 2

## Group every placed piece is in (`BuildService.PIECE_GROUP`). Neighbour snapping finds its mates
## through the physics world rather than through `BuildService._placed`, and that is not a stylistic
## choice: `_placed` is populated on the HOST only (`_process_place`), while clients learn about a
## piece purely by the replicated spawn. A client ghost that consulted `_placed` would find nothing
## to snap to in a real session and would silently behave like the host's single-player case.
const PIECE_GROUP: StringName = &"buildable_piece"
## Metadata `BuildService._net_spawn_piece()` already stamps on every piece root, on every peer,
## naming the definition it was built from. Without it a neighbour is an anonymous collider with no
## footprint and the mate points below cannot be computed — which is why snapping reads this rather
## than adding a stamp of its own.
const PIECE_DEF_META: StringName = &"buildable_id"

## How far from the aim point to look for a piece worth mating to. Generous, because the candidate
## mate positions it produces are themselves filtered by SNAP_TOLERANCE_M — this radius only has to
## reach the NEIGHBOUR, and a 2 m piece's far mate sits a full piece-width away from its centre.
const SNAP_SEARCH_RADIUS_M: float = 4.0
## How close the raw aim point must already be to a candidate mate for the mate to win. Roughly a
## third of a module: close enough that snapping feels like a magnet you aimed at, far enough that
## you do not have to be precise. Beyond it the aim point is used as-is.
const SNAP_TOLERANCE_M: float = 0.75
## Cap on how many neighbours one snap resolves against. A player building a fort has hundreds of
## pieces; only the nearest few can plausibly win, and this runs every physics tick inside the ghost.
const SNAP_MAX_NEIGHBOURS: int = 12


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
		# X/Z only. Y used to snap to the same grid (F-083) on the theory that it kept stacked
		# floors seamless, but `origin.y` here is never an arbitrary value to round — it is
		# wherever the caller's aim ray actually hit, terrain or another piece's real top surface.
		# Hollowmere's ground is not restricted to whole metres, so rounding it either buries the
		# piece (0.4 -> 0.0, support probe starts inside the ground) or floats it (0.6 -> 1.0, a
		# 0.4 m gap the validator waves through as OK). Preserving the raw hit height fixes both,
		# and it still gives flush stacking for free: a ray against an already-placed piece reports
		# that piece's exact top, so no separate anchor rule is needed (D-056).
		snapped_origin = Vector3(snappedf(origin.x, step), origin.y, snappedf(origin.z, step))
	var yaw: float = yaw_radians
	var rotation_step: float = float(def.get(&"rotation_step_degrees"))
	if rotation_step > 0.0:
		var step_radians: float = deg_to_rad(rotation_step)
		yaw = snappedf(yaw_radians, step_radians)
	return Transform3D(Basis(Vector3.UP, yaw), snapped_origin)


## The placement rule the ghost previews and the host enforces, and the ONLY function either should
## call to turn an aim point into a transform (D-202).
##
## `snapping` is the player's toggle. It is passed across the wire with the request rather than being
## inferred, because the two modes are not refinements of each other — one is "put it exactly where I
## am pointing" and the other is "pull it flush against what is already there", and a host that
## guessed would override a deliberate off-grid placement.
##
##   snapping OFF -> the aim point, untouched in x/y/z. Rotation still quantises to the piece's own
##                   `rotation_step_degrees`, because yaw does not come from the aim at all — it
##                   comes from the player pressing rotate, already in whole steps.
##   snapping ON  -> the nearest MATE on a neighbouring piece if one is within SNAP_TOLERANCE_M,
##                   otherwise the world grid `snap_transform()` has always used.
##
## **Idempotent, and it has to be.** `BuildService._process_place()` re-resolves whatever a client
## sent. Re-running this on a transform it already produced must return that transform, or every
## placement would visibly jump on confirmation: a mated origin's nearest candidate is itself at
## distance 0, and a grid-snapped origin is already on the grid. The check asserts this directly
## rather than trusting the argument.
##
## `space` may be null (a caller with no physics world, and every pure unit case): neighbour snapping
## is skipped and the grid answer is returned, which is exactly the old behaviour.
static func resolve_placement(
	def: Resource,
	origin: Vector3,
	yaw_radians: float,
	snapping: bool,
	space: PhysicsDirectSpaceState3D = null,
	collision_mask: int = 1
) -> Transform3D:
	if def == null:
		return Transform3D(Basis(Vector3.UP, yaw_radians), origin)
	if not snapping:
		return Transform3D(Basis(Vector3.UP, _snap_yaw(def, yaw_radians)), origin)
	# The RAW yaw goes to _nearest_mate, not a pre-quantised one. Quantising to world axes first
	# destroys the very thing the mate is about to measure: beside a wall turned 45 degrees, a raw
	# 132 would round to 90 and the neighbour-relative angle would read 45 — half a step, which
	# rounds back to a piece facing the world grid rather than the wall it is being built onto.
	var mate: Dictionary = _nearest_mate(def, origin, yaw_radians, space, collision_mask)
	if not mate.is_empty():
		return Transform3D(Basis(Vector3.UP, float(mate["yaw"])), mate["origin"] as Vector3)

	# No mate for the raw aim, so fall back to the world grid — but ask ONE more time from the
	# grid-snapped point before committing to it. This second look is not thoroughness, it is what
	# makes the whole function idempotent, and without it the host visibly moves pieces:
	# rounding to the metre can carry an origin that was just outside SNAP_TOLERANCE_M to just
	# INSIDE it, so the client would show a grid placement, send it, and the host's re-resolve would
	# find the mate the client never saw and snap the piece somewhere else.
	#
	# Two looks are provably enough. Each of the three returns below is a fixed point of this
	# function: a mated origin's nearest candidate is itself at distance 0, and a grid origin that
	# reached this last line has already been shown to have no mate and is already on the grid. So
	# resolving any output again returns that same output, which is the property
	# `tools/build_snap_check.gd` asserts directly rather than trusting this comment.
	var grid: Transform3D = snap_transform(def, origin, yaw_radians)
	var grid_mate: Dictionary = _nearest_mate(
		def, grid.origin, grid.basis.get_euler().y, space, collision_mask)
	if not grid_mate.is_empty():
		return Transform3D(
			Basis(Vector3.UP, float(grid_mate["yaw"])), grid_mate["origin"] as Vector3)
	return grid


## The best mate across every nearby piece, or empty if none is close enough. Returns the WHOLE
## transform (origin and yaw), not just a position: adopting the neighbour's facing is most of what
## removes the gaps, because two walls a millimetre out of parallel leave a wedge no snap of the
## origin alone can close.
static func _nearest_mate(
	def: Resource,
	origin: Vector3,
	yaw: float,
	space: PhysicsDirectSpaceState3D,
	collision_mask: int
) -> Dictionary:
	if space == null:
		return {}
	var best: Dictionary = {}
	var best_distance: float = SNAP_TOLERANCE_M
	for neighbour: Node3D in _neighbours(origin, space, collision_mask):
		var other: Resource = _def_of(neighbour)
		if other == null:
			continue
		# The facing this piece would take beside that neighbour: the player's own rotation, but
		# counted in whole steps FROM the neighbour's yaw rather than from world zero. The player
		# still chooses which way the piece faces; they just cannot choose to be 3 degrees off it.
		var neighbour_yaw: float = neighbour.global_transform.basis.get_euler().y
		var mate_yaw: float = neighbour_yaw + _snap_yaw(def, yaw - neighbour_yaw)
		for candidate: Vector3 in _mate_points(def, other, neighbour, mate_yaw):
			var distance: float = candidate.distance_to(origin)
			if distance < best_distance:
				best_distance = distance
				best = {"origin": candidate, "yaw": mate_yaw}
	return best


## Where this piece can sit against one neighbour: flush on each of the neighbour's four sides, and
## squarely on top of it. Every offset is measured in the NEIGHBOUR's own frame and then rotated into
## the world, so a neighbour placed at any angle still mates along its own faces rather than along
## the world axes — which is the difference between a fort you can turn and a fort that must be
## axis-aligned to be gapless.
##
## The extent used for this piece is its footprint rotated into the neighbour's frame, not its raw
## `size`: a wall turned 90 degrees against another wall meets it across its THICKNESS, and using
## `size.x` there would leave a 1.75 m gap on every corner.
static func _mate_points(
	def: Resource, other: Resource, neighbour: Node3D, mate_yaw: float
) -> Array[Vector3]:
	var basis: Basis = neighbour.global_transform.basis
	var neighbour_yaw: float = basis.get_euler().y
	var size: Vector3 = def.get(&"size")
	var other_size: Vector3 = other.get(&"size")
	# Half-extents of this piece along the neighbour's local x and z, under the relative rotation.
	var relative: float = mate_yaw - neighbour_yaw
	var cos_r: float = absf(cos(relative))
	var sin_r: float = absf(sin(relative))
	var half_x: float = (size.x * cos_r + size.z * sin_r) * 0.5
	var half_z: float = (size.x * sin_r + size.z * cos_r) * 0.5
	var base: Vector3 = neighbour.global_position
	var forward: Vector3 = basis.z.normalized()
	var right: Vector3 = basis.x.normalized()
	var points: Array[Vector3] = [
		base + right * (other_size.x * 0.5 + half_x),
		base - right * (other_size.x * 0.5 + half_x),
		base + forward * (other_size.z * 0.5 + half_z),
		base - forward * (other_size.z * 0.5 + half_z),
		# Straight on top. The origin is the piece's FLOOR centre everywhere in this system, so
		# stacking is the neighbour's floor plus the neighbour's full height and nothing else.
		base + Vector3.UP * other_size.y,
	]
	return points


## Nearby pieces, nearest first and capped. A sphere shape query rather than a ray: the aim point is
## usually ON a surface, and a ray from it would find whatever it is already touching and nothing
## else — the neighbour worth mating to is frequently the one BESIDE the aim, not under it.
static func _neighbours(
	origin: Vector3, space: PhysicsDirectSpaceState3D, collision_mask: int
) -> Array[Node3D]:
	var sphere := SphereShape3D.new()
	sphere.radius = SNAP_SEARCH_RADIUS_M
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, origin)
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.margin = 0.0
	var found: Array[Node3D] = []
	for hit: Dictionary in space.intersect_shape(query, SNAP_MAX_NEIGHBOURS * 3):
		var piece: Node3D = _piece_root(hit.get("collider") as Node)
		if piece != null and not found.has(piece):
			found.append(piece)
	found.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.global_position.distance_squared_to(origin) \
			< b.global_position.distance_squared_to(origin))
	return found.slice(0, SNAP_MAX_NEIGHBOURS)


## Walks up from a collider to the piece root, the same defensive shape `BuildGhost`'s destroy ray
## uses: a generated piece IS its own collider, but an authored scene wraps one in a child holder.
static func _piece_root(collider: Node) -> Node3D:
	var cursor: Node = collider
	while cursor != null:
		if cursor.is_in_group(PIECE_GROUP):
			return cursor as Node3D
		cursor = cursor.get_parent()
	return null


## The definition a placed piece was built from, via the metadata `BuildService` stamps at spawn.
## Returns null for a piece that predates the stamp or whose id is no longer in the Registry, and a
## null neighbour is simply skipped — an unknown neighbour must not block snapping to a known one.
static func _def_of(piece: Node3D) -> Resource:
	if not piece.has_meta(PIECE_DEF_META):
		return null
	var registry: Node = piece.get_node_or_null(^"/root/Registry")
	if registry == null:
		return null
	return registry.call(&"get_buildable", StringName(piece.get_meta(PIECE_DEF_META))) as Resource


## Yaw quantised to the piece's own authored step. Shared by both modes so that turning snapping off
## never changes which way a piece faces — only where it sits.
static func _snap_yaw(def: Resource, yaw_radians: float) -> float:
	var rotation_step: float = float(def.get(&"rotation_step_degrees"))
	if rotation_step <= 0.0:
		return yaw_radians
	return snappedf(yaw_radians, deg_to_rad(rotation_step))


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
		var slope_degrees: float = float(support["slope_degrees"])
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
	var size: Vector3 = def.get(&"size")

	# Lift the query box a hair clear of the piece's own floor. This clearance used to be derived
	# from the piece's steepest permitted slope (half_footprint * tan(max_ground_slope)) — up to
	# 0.58 m for a 2 m wall permitting 30 degrees, and an obstruction sitting entirely below that
	# band was invisible to this check. That was a workaround for terrain and props sharing
	# `collision_mask`, so the ground itself registered as the overlap on any slope. F-075 gave
	# terrain its own layer instead (TERRAIN_LAYER, above), which `collision_mask` here never
	# includes, so the box no longer has to out-climb the slope it is resting on. What is left is a
	# flat floor's worth of margin so two pieces stacked exactly flush (D-056) don't read their
	# touching faces as a collision.
	var clearance: float = MIN_GROUND_CLEARANCE_M

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


## Looks for ground under the footprint's four bottom corners AND its centre, and requires EVERY
## probe to find something before the placement counts as supported at all. Used to skip missing
## probes and report only the flattest hit among whatever survived (F-082): a 2 m wall resting on a
## 20 cm pillar under its centre, or a piece with three of four corners hanging over a cliff, still
## has one hit — the centre ray, or the one grounded corner — and that lone flat hit used to read as
## fully supported. There is no authored field distinguishing "required" from "optional" probes, so
## all five are required; a piece meant to bridge a gap sets `requires_support = false` instead.
## Slope is then judged by the WORST (steepest) of the five hits, not the flattest survivor, so one
## good corner can no longer hide three bad ones.
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
	var worst_slope: float = 0.0
	for offset: Vector3 in offsets:
		var point: Vector3 = placement.origin + placement.basis * offset
		var query := PhysicsRayQueryParameters3D.create(
			point + Vector3.UP * SUPPORT_PROBE_LIFT_M,
			point + Vector3.DOWN * SUPPORT_PROBE_DEPTH_M
		)
		# ORs TERRAIN_LAYER in regardless of what the caller asked for: a piece needs ground to
		# stand on whether or not the caller's mask includes it (F-075).
		query.collision_mask = collision_mask | TERRAIN_LAYER
		query.exclude = ignore_bodies
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			# One missed probe fails the whole footprint (F-082) — an empty Dictionary is the same
			# "unsupported" sentinel evaluate() already checks for via is_empty().
			return {}
		var normal: Vector3 = hit["normal"]
		var slope: float = rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0)))
		worst_slope = maxf(worst_slope, slope)
	return {"slope_degrees": worst_slope}
