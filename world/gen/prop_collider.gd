extends RefCounted

## One answer to "what shape does this prop collide as", measured off the prop's own geometry.
##
## ## Why this file exists (F-434)
##
## The rule it enforces is a standing art directive for this project, from Sequoyah and repeated:
## **a tree's collider is its trunk; leaves and canopy never collide.** Two world builders have to
## honour it and until now only one could:
##
## * `world/gen/resource_scatter_field.gd` measures the mesh, which is where F-348 and F-390 put
##   the trunk-band rule this file carries.
## * `world/gen/authored_world.gd` reads a collider out of the layout JSON, and the Python mapgen
##   that writes those layouts has never been able to open a `.glb`. `tools/mapgen/hollowmere_layout.py`
##   therefore sizes a tree's cylinder as `footprint_radius(asset) * 0.62` — a fraction of the
##   CANOPY — so every willow in Hollowmere carries a 1.25 m collider derived from its leaves.
##
## Sharing the fitter is what lets the authored map ask the same question the generated one does,
## about the same mesh, and get the same answer.
##
## ## What it measures
##
## Foliage surfaces contribute nothing (`FOLIAGE_MATERIAL_PREFIXES`). Of the solid geometry left,
## a standing prop is fitted with a vertical cylinder whose radius is the MEDIAN horizontal
## cross-section through the trunk band, and a prop that lies down gets a box along its own length.
## Height and centre come from the solid bounds, so a collider never reaches up into a canopy.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2. Geometry classification, identical on every peer, never sent. The
## bodies built from these numbers are static world collision.

## Above this height (metres, in the prop's own unscaled space) geometry is scenery, not an
## obstacle — a branch you walk under is not a wall. Cuts the SOLID surfaces only; foliage is
## already gone by then. Together the two rules give a tree its trunk and root flare, while a
## boulder, a stump or a fallen log — solid all over, and widest down low anyway — keeps its true
## full width (F-348).
const COLLIDER_OBSTACLE_HEIGHT_M: float = 1.8
## F-390: the trunk band. Solid geometry is measured from here up to
## [constant COLLIDER_OBSTACLE_HEIGHT_M], NOT from the ground up, because the widest solid wood on a
## tree below head height is the ROOT FLARE at its very base — and taking the max over the whole
## sub-1.8 m column meant the flare, not the trunk, set the radius. Measured on the shipped willows:
## `tree_willow_a` came out at 1.29 m against a trunk nearer 0.3, so the player was stopped over a
## metre from bark they were walking at. Reported as "the collision box doesnt let you get close to
## the tree".
##
## 0.5 m is chosen as clearly above a root flare and clearly below the waist. Everything under it
## stays walk-through, which is the right trade: brushing an ankle through a root is invisible, being
## held a metre off a tree is not.
const COLLIDER_TRUNK_BAND_MIN_M: float = 0.5
## F-390: nothing shorter than this gets a collider at all. You step over it, so a cylinder there can
## only ever be something to trip on.
const COLLIDER_MIN_HEIGHT_M: float = 0.4
## Material-name prefixes that mark a surface as leaves, fronds, grass, moss or blossom — the parts
## of a prop a player walks straight through.
##
## `tools/blender/mire_art.py` names every material `"MIRE_" + CamelCase(palette_token)`
## (docs/SPECS.md, F-092), and its palette groups these tokens under one `-- foliage` heading, so
## these prefixes are the foliage family as the art pipeline itself defines it rather than a list
## guessed from the assets that happen to exist today. A willow carries its trunk on `MIRE_WoodBark`
## and its crown on `MIRE_Leaf`/`MIRE_LeafDeep`/`MIRE_LeafLight`: four surfaces of one mesh, which is
## what makes "collide the trunk, not the leaves" answerable at all without hand-authored shapes.
const FOLIAGE_MATERIAL_PREFIXES: PackedStringArray = [
	"MIRE_Leaf", "MIRE_Pine", "MIRE_Grass", "MIRE_Moss",
	"MIRE_Reed", "MIRE_Sedge", "MIRE_Bracken", "MIRE_Flower",
]


## [method fit] behind a caller-owned cache, keyed however the caller identifies an asset. The walk
## is per-vertex, so the cache is not an optimisation to skip — it is what makes the fitter usable
## a few hundred times per chunk.
static func fit_cached(cache: Dictionary, key: String, mesh_parts: Array) -> Dictionary:
	if cache.has(key):
		return cache[key]
	var shape: Dictionary = fit(mesh_parts)
	cache[key] = shape
	return shape


## One [CollisionShape3D] built from a [method fit] answer, in the PROP's own space — the shape it
## returns is positioned relative to the prop origin, so a caller places it by composing its own
## placement transform onto `shape.transform` (batched scatter) or by parenting it under a holder
## that already carries that transform (node scatter).
##
## F-586: this used to be written out by hand at every call site, three times, and the batched
## scatter path — every rock and boulder on the generated island — simply never wrote it at all.
## `fit` returning empty still means "this prop does not collide"; callers check that first.
static func make_shape(fit_result: Dictionary) -> CollisionShape3D:
	var node := CollisionShape3D.new()
	if StringName(fit_result.get("shape", &"cylinder")) == &"box":
		# A prop that lies down gets a box along its own length, not a disc as wide as it is long.
		var box := BoxShape3D.new()
		box.size = fit_result["size"] as Vector3
		node.shape = box
		node.position = fit_result["center"] as Vector3
	else:
		var cylinder := CylinderShape3D.new()
		cylinder.radius = float(fit_result["radius"])
		cylinder.height = float(fit_result["height"])
		node.shape = cylinder
		node.position.y = float(fit_result["center_y"])
	return node


## True when this prop has any foliage on it at all — the question an AUTHORED map asks, because a
## layout's own collider is only suspect for props with a canopy. Solid props keep whatever the
## mapgen authored for them.
static func has_foliage(mesh_parts: Array) -> bool:
	for part: Dictionary in mesh_parts:
		var mesh: Mesh = part["mesh"] as Mesh
		for surface: int in mesh.get_surface_count():
			if _is_foliage(mesh.surface_get_material(surface)):
				return true
	return false


## The shape a NODE prop collides as: a vertical cylinder as wide as the widest SOLID thing a
## walking body could hit, or — for a prop that lies down — a box along its own length.
##
## F-348: this used to be the union AABB of every mesh part, which for a tree is the LEAF CROWN —
## a willow ended up with a 1.89 m-radius invisible wall around a trunk about 0.9 m across at the
## root flare, so the player was stopped a metre short of every tree on the island with nothing on
## screen to explain it. Leaves are not an obstacle; the trunk is.
##
## Two rules get there, and both are needed. Surfaces painted with a foliage material contribute
## nothing — that removes the crown outright. Of what is left, only vertices below
## [constant COLLIDER_OBSTACLE_HEIGHT_M] count — that removes the bark BRANCHES, which are solid
## wood spreading twice as wide as the trunk they grow from and are still something you walk under.
## Radius is measured from the prop's own vertical axis rather than off an AABB corner: props are
## authored around their origin, and a radial measure is what a cylinder actually needs. Height runs
## the full height of the SOLID geometry, so an arrow still hits a trunk forty feet up while a
## willow's cylinder stops at its highest limb instead of 1.7 m higher, inside the hanging curtain
## (F-434).
##
## **Returns an EMPTY dictionary for a prop that should not collide at all**, and `_build_node_holder`
## emits no body for one. Two ways to get there, both added by F-390:
##
##  · **It is foliage all the way down.** The old code treated that as a content bug and fell back to
##    measuring the foliage, then to the full AABB — "a collider that is too wide beats one that is
##    missing". That is right for an UNRECOGNISED material and exactly wrong for a recognised one:
##    every surface being known foliage is not ambiguity, it is the answer. What it actually shipped
##    was a solid cylinder around every blade of grass, every flower and every clover patch on the
##    island — `grass_short_c` measured r=0.89 h=0.27, `flowers_meadow_a` r=0.84 — invisible, in the
##    thousands, and directly against the standing rule for this project that leaves and canopy never
##    collide. A player walking over a field of ankle-high cylinders bounces, which is what was
##    reported.
##  · **It is shorter than [constant COLLIDER_MIN_HEIGHT_M].** You step over it.
##
## A prop with geometry the material table does not recognise still gets the old benefit of the
## doubt — `_is_foliage()` treats an unnamed material as SOLID, so this only ever drops props whose
## surfaces are all POSITIVELY identified as leaves, grass, moss, reed, sedge, bracken or blossom.
static func fit(mesh_parts: Array) -> Dictionary:
	# The old measure: widest solid geometry anywhere below the cut. Still the fallback for props
	# with nothing in the band at all — a fallen log, a low boulder, a stump.
	var solid_radius: float = 0.0
	for part: Dictionary in mesh_parts:
		var mesh: Mesh = part["mesh"] as Mesh
		var offset: Transform3D = part["offset"] as Transform3D
		var box: AABB = offset * mesh.get_aabb()
		if box.position.y > COLLIDER_OBSTACLE_HEIGHT_M:
			continue
		for surface: int in mesh.get_surface_count():
			if _is_foliage(mesh.surface_get_material(surface)):
				continue
			# Vertices, not the surface's bounds: a willow's crown hangs down past head height, so a
			# bounds test would call the whole canopy "below the cut" and change nothing.
			solid_radius = maxf(solid_radius, _surface_reach(mesh, surface, offset, 0.0))

	# F-434: the prop's extent measured over SOLID surfaces only, and this is what sizes the shape.
	# It used to be the union AABB of every mesh part, foliage included, which put the top of a
	# willow's cylinder 1.7 m above its highest branch — inside the hanging curtain, where the
	# standing rule for this project says nothing may ever collide.
	var solid: AABB = _solid_bounds(mesh_parts)
	var height: float = maxf(solid.size.y, 0.1)
	# Nothing solid anywhere, or too short to matter: no body at all.
	if solid_radius <= 0.0 or height < COLLIDER_MIN_HEIGHT_M:
		return {}

	return _box_fit(solid) if _lies_down(solid) else {
		"shape": &"cylinder",
		"radius": maxf(_band_radius(mesh_parts, solid_radius), 0.05),
		"height": height,
		"center_y": solid.get_center().y,
	}


## The bounding box of every SOLID surface on the prop — the foliage rule of `_collider_for()`
## applied to the whole mesh rather than to one horizontal band. Measured per VERTEX rather than
## per surface AABB for the same reason `_collider_for()` is: one surface can carry both a limb
## inside the band and a twig far outside it.
static func _solid_bounds(mesh_parts: Array) -> AABB:
	var bounds := AABB()
	var found: bool = false
	for part: Dictionary in mesh_parts:
		var mesh: Mesh = part["mesh"] as Mesh
		var offset: Transform3D = part["offset"] as Transform3D
		for surface: int in mesh.get_surface_count():
			if _is_foliage(mesh.surface_get_material(surface)):
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			if arrays.is_empty():
				continue
			for vertex: Vector3 in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				var point: Vector3 = offset * vertex
				if not found:
					bounds = AABB(point, Vector3.ZERO)
					found = true
				else:
					bounds = bounds.expand(point)
	return bounds


## How much longer one horizontal axis has to be than the other before the prop is treated as
## something LYING DOWN rather than something standing up (F-434).
##
## A vertical cylinder is the right shape for anything built around its own trunk or centre — a
## tree, a boulder, an ore node — and the wrong shape for anything long: `_collider_for()` gave
## `harvest_tree_felled_trunk` a 3.94 m-radius disc and `uprooted_tree` a 2.88 m one, because a
## cylinder wide enough to contain a 7.9 m log is also 7.9 m wide across the log. That is F-348's
## invisible wall again in a shape the trunk-band radius cannot see, and it is worst exactly where
## the prop is small enough to expect to step over.
##
## 1.7 is chosen to sit clearly above the plan aspect of everything round — measured across all 96
## colliding assets the shipped scatter tables place, no boulder, rock cluster, stump, ore node or
## standing tree exceeds 1.5 — and clearly below the logs and the uprooted trees, which run 2.2 and
## up.
const COLLIDER_BOX_ASPECT: float = 1.7

static func _lies_down(solid: AABB) -> bool:
	var long_axis: float = maxf(solid.size.x, solid.size.z)
	var short_axis: float = minf(solid.size.x, solid.size.z)
	if short_axis <= 0.01 or long_axis <= short_axis * COLLIDER_BOX_ASPECT:
		return false
	# Longer than it is TALL, as well as longer than it is wide. Without this second half a leaning
	# willow qualifies on its limb spread alone — its solid bark reaches 8 m one way and 4 m the
	# other — and a standing tree would collide as a box the size of its whole branch structure,
	# which is the opposite of what this rule exists to do.
	return solid.size.y < long_axis * 0.9


## A box around the solid geometry, for the props `_lies_down()` picks out. The box is authored in
## the prop's own space and the holder's yaw turns it with the prop, so a log that runs east-west in
## Blender still collides along its own length wherever it is scattered.
static func _box_fit(solid: AABB) -> Dictionary:
	return {
		"shape": &"box",
		"size": Vector3(maxf(solid.size.x, 0.1), maxf(solid.size.y, 0.1), maxf(solid.size.z, 0.1)),
		"center": solid.get_center(),
		# Kept so callers that only want a scalar footprint — checks, spacing — still have one.
		"radius": maxf(maxf(solid.size.x, solid.size.z) * 0.5, 0.05),
		"height": maxf(solid.size.y, 0.1),
		"center_y": solid.get_center().y,
	}


## The collider radius, measured as the prop's HORIZONTAL CROSS-SECTION through the trunk band.
##
## Three approaches were tried against the shipped assets and the first two both failed on real
## content, so the reasoning is worth keeping:
##
## 1. **Widest solid geometry below head height** (what shipped). Set by the ROOT FLARE at the very
##    base, so `tree_willow_a` measured 1.29 m around a trunk nearer 0.3 and the player was stopped
##    over a metre from bark they were walking at.
## 2. **A percentile of solid VERTEX radii inside the band.** Correct in principle and blind in
##    practice: these are low-poly meshes, and a willow's trunk is a cylinder with a vertex ring at
##    its base and the next one above head height. Nothing at all lands between 0.5 m and 1.8 m, so
##    two of the three willows contributed zero samples and silently fell back to (1).
##
## 3. **Slice it.** For each of [constant COLLIDER_BAND_SLICES] heights across the band, find every
##    triangle EDGE that crosses that height, interpolate the crossing point, and take the widest —
##    a true silhouette at that height, independent of where the vertices happen to sit. Then take
##    the MEDIAN across the slices.
##
## The median across slices is what separates a trunk from a rock without knowing which it is. A
## tree is a narrow column at almost every height in the band, with at most a couple of slices
## catching a branch — outliers the median drops. A boulder is wide at every height, so its median
## IS its width. Content that is neither still gets a defensible answer rather than a special case.
const COLLIDER_BAND_SLICES: int = 9

static func _band_radius(mesh_parts: Array, fallback: float) -> float:
	var slice_radii := PackedFloat32Array()
	var span: float = COLLIDER_OBSTACLE_HEIGHT_M - COLLIDER_TRUNK_BAND_MIN_M
	for slice: int in COLLIDER_BAND_SLICES:
		var height: float = COLLIDER_TRUNK_BAND_MIN_M \
			+ span * (float(slice) + 0.5) / float(COLLIDER_BAND_SLICES)
		var widest: float = _cross_section_radius(mesh_parts, height)
		if widest > 0.0:
			slice_radii.append(widest)
	if slice_radii.is_empty():
		# The band is above the whole prop, or below nothing solid. Its widest solid geometry below
		# the cut is the honest answer and always was — a fallen log, a stump, a low rock.
		return fallback
	slice_radii.sort()
	return slice_radii[slice_radii.size() / 2]


## Widest solid point on the horizontal plane at [param height], found by interpolating every
## triangle edge that crosses it. Returns 0.0 when nothing solid reaches that height.
static func _cross_section_radius(mesh_parts: Array, height: float) -> float:
	var widest_sq: float = 0.0
	for part: Dictionary in mesh_parts:
		var mesh: Mesh = part["mesh"] as Mesh
		var offset: Transform3D = part["offset"] as Transform3D
		for surface: int in mesh.get_surface_count():
			if _is_foliage(mesh.surface_get_material(surface)):
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var count: int = indices.size() if indices.size() > 0 else verts.size()
			for i: int in range(0, count - 2, 3):
				for edge: int in 3:
					var ia: int = i + edge
					var ib: int = i + (edge + 1) % 3
					var a: Vector3 = offset * verts[indices[ia] if indices.size() > 0 else ia]
					var b: Vector3 = offset * verts[indices[ib] if indices.size() > 0 else ib]
					if (a.y - height) * (b.y - height) > 0.0:
						continue
					if is_equal_approx(a.y, b.y):
						continue
					var t: float = (height - a.y) / (b.y - a.y)
					var x: float = a.x + (b.x - a.x) * t
					var z: float = a.z + (b.z - a.z) * t
					widest_sq = maxf(widest_sq, x * x + z * z)
	return sqrt(widest_sq)


## How far one surface reaches from the prop's vertical axis, counting only vertices between
## [param min_y] and [constant COLLIDER_OBSTACLE_HEIGHT_M].
static func _surface_reach(mesh: Mesh, surface: int, offset: Transform3D, min_y: float) -> float:
	var arrays: Array = mesh.surface_get_arrays(surface)
	if arrays.is_empty():
		return 0.0
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var worst_sq: float = 0.0
	for vertex: Vector3 in verts:
		var point: Vector3 = offset * vertex
		if point.y > COLLIDER_OBSTACLE_HEIGHT_M or point.y < min_y:
			continue
		worst_sq = maxf(worst_sq, point.x * point.x + point.z * point.z)
	return sqrt(worst_sq)


## True for a surface a player walks straight through. An unnamed or missing material counts as
## SOLID: silently dropping an unrecognised surface from the collider is how a prop ends up with no
## collision at all, and being too wide is the safer failure.
static func _is_foliage(material: Material) -> bool:
	if material == null:
		return false
	var name: String = material.resource_name
	for prefix: String in FOLIAGE_MATERIAL_PREFIXES:
		if name.begins_with(prefix):
			return true
	return false
