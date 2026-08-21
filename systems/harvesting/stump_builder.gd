extends RefCounted

## The stump a felled tree leaves, cut from the tree that was standing there.
##
## ## Why this file exists (F-432)
##
## Every `tree_*` asset in the game harvests as `content/harvestables/wild_tree.tres`, whose
## `depleted_scene` is the one authored broadleaf stump in `assets/harvestables/exports`. So felling
## a 13.6 m willow with a 1.4 m bole left behind a 1.1 m oak stump 0.56 m across, and felling a
## pine left the same one. One species' stump standing in for ninety.
##
## Authoring a stump per species is the obvious fix and the wrong one: **release worlds are
## procedurally generated** (`systems/harvesting/harvest_library.gd` makes the same argument about
## harvestability), so any answer that needs a Blender export per tree is an answer that only works
## for the trees that exist today. The durable answer is to cut the stump out of the tree's OWN
## trunk at runtime: measure the trunk's real cross-section at three heights, build a nine-sided
## tapered tube through them, and cap it. A willow's stump is then as thick as the willow's bole and
## a birch's is as thin as the birch's, with no content to author and nothing to keep in sync.
##
## The geometry is deliberately tiny — 9 sides, 3 rings, ~50 triangles — because a stump is a thing
## you glance at from standing height, and because there may be a few hundred of them by the end of
## a long run.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2. Presentation built identically on every peer from content every peer
## already has. Whether the prop is depleted at all is host-owned inside
## `systems/harvesting/harvestable.gd`; this file only draws the result.

const PROP_COLLIDER := preload("res://world/gen/prop_collider.gd")

## How high the stump stands, in the prop's own unscaled space. A felled tree is cut at about knee
## height — high enough to read as a cut trunk rather than a scar in the ground, low enough to walk
## over rather than around.
const CUT_HEIGHT_M: float = 0.62
## Sides on the tube. Nine matches `tools/blender/build_flora_set.py`'s own trunks (`vertices=9` on
## the willow, 8 on the snag), so a stump has the same silhouette resolution as the tree it came
## from rather than reading rounder than the trunk above it did.
const SIDES: int = 9
## The three heights the trunk is measured at, as fractions of [constant CUT_HEIGHT_M]. The lowest is
## just off the ground rather than at 0, because a trunk's very bottom ring is usually buried in its
## own root flare and measures wider than the wood a stump should show.
const RING_FRACTIONS: PackedFloat32Array = [0.08, 0.55, 1.0]
## How much wider than the cut face the stump may be down at the ground. See `_build()`.
const MAX_FLARE_RATIO: float = 1.35
## Below this the prop is not a tree and gets no generated stump — a fallen log, a stump that was
## already a stump, a sapling you snap off at the ground. Its definition's own `depleted_scene`
## (or nothing at all) is the right answer for those.
const MIN_TREE_HEIGHT_M: float = 2.5
## How far the cut face is lightened toward fresh end-grain, and what colour it lightens toward.
##
## Taken from the tree's OWN bark material rather than authored as a flat colour: the material comes
## out of the glTF importer already in the renderer's colour space, and a hand-written `Color` here
## would have to guess that conversion — which is how a "pale" swatch ends up glowing. Lightening
## what is already there cannot drift. The target is `mire_art.py`'s `wood_cut` swatch (#DDAA65,
## "fresh cut end-grain and axe scars") in spirit; the lerp keeps each species' own hue underneath,
## so a birch's cut is paler than a willow's exactly as the bark is.
const CUT_TINT: Color = Color(0.87, 0.67, 0.40)
const CUT_TINT_WEIGHT: float = 0.62

## asset id -> the stump mesh built for it. Every copy of one species shares one mesh; a hundred
## felled pines cost one build and one Mesh.
static var _cache: Dictionary[StringName, Mesh] = {}


## The stump for [param asset_id], built from [param mesh] the first time it is asked for.
##
## Returns null when this prop should not get a generated stump at all — it is too short to be a
## tree, or its trunk cannot be measured — and the caller then falls back to whatever the definition
## authored.
static func stump_for(asset_id: StringName, mesh: Mesh) -> Mesh:
	if mesh == null:
		return null
	if _cache.has(asset_id):
		return _cache[asset_id]
	var built: Mesh = _build(mesh)
	_cache[asset_id] = built
	return built


## Drops the cache. For checks that rebuild the same asset under different conditions; nothing in a
## running game needs it, because an asset's geometry does not change mid-run.
static func clear_cache() -> void:
	_cache.clear()


static func _build(mesh: Mesh) -> Mesh:
	var parts: Array = [{"mesh": mesh, "offset": Transform3D.IDENTITY}]
	var bounds: AABB = PROP_COLLIDER._solid_bounds(parts)
	if bounds.size.y < MIN_TREE_HEIGHT_M:
		return null

	var base: float = bounds.position.y
	var radii := PackedFloat32Array()
	for fraction: float in RING_FRACTIONS:
		var height: float = base + CUT_HEIGHT_M * fraction
		var measured: float = PROP_COLLIDER._cross_section_radius(parts, height)
		radii.append(measured)
	# A trunk that measures nothing at the cut is not a trunk — a canopy on a stalk the slicer
	# cannot see, or a prop whose solid geometry starts above knee height. Nothing to cut.
	if radii[radii.size() - 1] <= 0.01:
		return null
	# Every ring falls back UPWARD, never to a guess: a ring the slicer missed takes the width of the
	# ring above it, so a stump can taper or stay straight but can never pinch to a point. The same
	# pass bounds the ROOT FLARE against the cut: a pine measures 1.08 m at the ground and 0.53 m at
	# knee height, and a stump built through both of those is a cone rather than a cut trunk. Some
	# flare is what plants it; twice the trunk is a different shape.
	var cut_radius: float = radii[radii.size() - 1]
	for index: int in range(radii.size() - 2, -1, -1):
		if radii[index] <= 0.01:
			radii[index] = radii[index + 1]
		radii[index] = minf(radii[index], cut_radius * MAX_FLARE_RATIO)

	var bark: Material = _bark_material(mesh, parts, base)
	var surfaces := SurfaceTool.new()
	surfaces.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_sides(surfaces, base, radii)
	var stump := ArrayMesh.new()
	surfaces.generate_normals()
	surfaces.commit(stump)
	if bark != null:
		stump.surface_set_material(0, bark)

	var cap := SurfaceTool.new()
	cap.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_cap(cap, base + CUT_HEIGHT_M, radii[radii.size() - 1])
	cap.generate_normals()
	cap.commit(stump)
	stump.surface_set_material(1, _cut_material(bark))
	return stump


static func _add_sides(surfaces: SurfaceTool, base: float, radii: PackedFloat32Array) -> void:
	for ring: int in radii.size() - 1:
		var low_y: float = base + CUT_HEIGHT_M * RING_FRACTIONS[ring]
		var high_y: float = base + CUT_HEIGHT_M * RING_FRACTIONS[ring + 1]
		# The bottom ring drops to the ground rather than stopping where it was measured, so the
		# stump is planted instead of hovering the 8% of the cut height `RING_FRACTIONS` skips.
		if ring == 0:
			low_y = base - 0.02
		for side: int in SIDES:
			var a: float = TAU * float(side) / float(SIDES)
			var b: float = TAU * float(side + 1) / float(SIDES)
			var low_a := Vector3(cos(a) * radii[ring], low_y, sin(a) * radii[ring])
			var low_b := Vector3(cos(b) * radii[ring], low_y, sin(b) * radii[ring])
			var high_a := Vector3(cos(a) * radii[ring + 1], high_y, sin(a) * radii[ring + 1])
			var high_b := Vector3(cos(b) * radii[ring + 1], high_y, sin(b) * radii[ring + 1])
			# Wound so the faces point OUT. Godot culls back faces, and an inside-out stump is an
			# invisible one lit from the wrong side — which is exactly what the first cut of this
			# shipped until the normals were measured.
			for vertex: Vector3 in [low_a, high_b, high_a, low_a, low_b, high_b]:
				surfaces.add_vertex(vertex)


static func _add_cap(surfaces: SurfaceTool, height: float, radius: float) -> void:
	var centre := Vector3(0.0, height, 0.0)
	for side: int in SIDES:
		var a: float = TAU * float(side) / float(SIDES)
		var b: float = TAU * float(side + 1) / float(SIDES)
		# Wound so the cut face looks UP, for the same reason the sides are wound outward.
		surfaces.add_vertex(centre)
		surfaces.add_vertex(Vector3(cos(a) * radius, height, sin(a) * radius))
		surfaces.add_vertex(Vector3(cos(b) * radius, height, sin(b) * radius))


## The tree's own bark, chosen as the SOLID surface with the most geometry down where the cut is.
## A trunk carries two or three bark tones plus its limbs; the one that owns the bole at knee height
## is the one a stump should be made of.
static func _bark_material(mesh: Mesh, parts: Array, base: float) -> Material:
	var best: Material = null
	var best_count: int = 0
	for surface: int in mesh.get_surface_count():
		var material: Material = mesh.surface_get_material(surface)
		if PROP_COLLIDER._is_foliage(material):
			continue
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.is_empty():
			continue
		var count: int = 0
		for vertex: Vector3 in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array):
			if vertex.y >= base and vertex.y <= base + CUT_HEIGHT_M * 2.0:
				count += 1
		if count > best_count:
			best_count = count
			best = material
	return best


static func _cut_material(bark: Material) -> Material:
	var standard := bark as StandardMaterial3D
	if standard == null:
		var plain := StandardMaterial3D.new()
		plain.albedo_color = CUT_TINT
		plain.roughness = 0.8
		return plain
	var cut := standard.duplicate() as StandardMaterial3D
	cut.albedo_color = standard.albedo_color.lerp(CUT_TINT, CUT_TINT_WEIGHT)
	# Named for what it is, in the art pipeline's own vocabulary (`mire_art.py`'s `wood_cut`). A
	# material's `resource_name` is load-bearing in this codebase — `prop_collider.gd` classifies
	# surfaces by it — so a duplicate that kept the bark's name would be a small lie waiting to be
	# read by something else (F-442).
	cut.resource_name = "MIRE_WoodCut"
	return cut
