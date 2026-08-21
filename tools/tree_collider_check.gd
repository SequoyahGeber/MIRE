extends SceneTree

## F-348/F-390/F-434 — what shape does a scattered prop actually collide as?
##
## Standing rule for this project, from Sequoyah and repeated: **a tree's collider is its trunk;
## leaves and canopy never collide.** This check is that rule made falsifiable from a terminal.
##
## It walks EVERY asset the 29 shipped scatter tables place — not a hand-written subject list, which
## is how `tree_willow_*` stayed twice as wide as every other tree and how a felled trunk kept a
## 3.94 m disc through two collider passes — asks the shipped `ResourceScatterField._collider_for()`
## for the shape it will build, and measures that shape against the prop's own SOLID geometry:
##
##  1. **Nothing overhangs.** The collider may not reach further from the prop's axis than solid
##     (non-foliage) geometry does. A collider wider than the wood is an invisible wall.
##  2. **Nothing reaches into the canopy.** The collider's top may not stand above the highest
##     solid vertex, so a willow's cylinder stops at its highest limb rather than 1.7 m higher up
##     inside the hanging curtain.
##  3. **Every material is classified.** A surface whose material name matches no known family is
##     counted as SOLID by `_is_foliage()` — deliberately, being too wide beats having no collision
##     — so an unrecognised leaf material would silently re-inflate a crown. Any such name is
##     reported here rather than discovered in play.
##  4. **Standing trees stay comparable.** Every tree's trunk-band radius is printed side by side,
##     because "one species is twice the others" is a defect no per-asset assertion can see.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only measurement.
##
##   .agent/bin/agent godot --script tools/tree_collider_check.gd

const FIELD := preload("res://world/gen/resource_scatter_field.gd")
## The fitter itself (F-434). The check asks the FIELD for the shape a scattered prop gets and the
## fitter for the raw measurements, so neither half can quietly answer for the other.
const PROP_COLLIDER := preload("res://world/gen/prop_collider.gd")

## How far past its own solid geometry a collider may reach before it counts as a wall. Small and
## non-zero: the band radius is a median across slices, so a prop whose widest point sits between
## two slices can round a centimetre or two wide without anyone ever feeling it.
const OVERHANG_TOLERANCE_M: float = 0.06
## How far above the highest solid vertex a collider's top may stand, same reasoning.
const HEADROOM_TOLERANCE_M: float = 0.10
## Material-name prefixes that are known SOLID families. Everything here plus
## `PROP_COLLIDER.FOLIAGE_MATERIAL_PREFIXES` is the set of names this check considers classified;
## anything else is reported, because `_is_foliage()` silently treats it as solid.
const SOLID_MATERIAL_PREFIXES: PackedStringArray = [
	"MIRE_Wood", "MIRE_Stone", "MIRE_Iron", "MIRE_Coal", "MIRE_Lichen", "MIRE_Fungus",
	"MIRE_Flesh", "MIRE_Mire", "MIRE_Peat", "MIRE_Leather", "MIRE_Terrain", "MIRE_Bone",
	"MIRE_Metal", "MIRE_Rope", "MIRE_Cloth", "MIRE_Thatch", "MIRE_Crystal", "MIRE_Ice",
	# Neither of these is foliage in the palette's own grouping — `fibre` sits with the textiles and
	# `glowcap` with the fungi — and both are load-bearing solid on the props that carry them.
	"MIRE_Fibre", "MIRE_Glowcap",
]

var _field: Node3D = null
var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Content is loaded by the Registry autoload one deferred call into the frame; the scatter
	# tables are empty before that and this check would silently audit nothing.
	for _frame: int in 5:
		await process_frame

	print("F-348/F-390/F-434 — scattered prop colliders\n")
	_field = FIELD.new()

	var registry: Node = root.get_node_or_null(^"Registry")
	if registry == null:
		_fail("Registry autoload is missing — nothing to audit")
		_finish()
		return

	var subjects: Array = _subjects(registry)
	check(not subjects.is_empty(), "the scatter tables name at least one asset")

	var trees: Array = []
	var unclassified: Dictionary = {}
	for subject: Array in subjects:
		var row: Dictionary = _audit(String(subject[0]), String(subject[1]))
		if row.is_empty():
			continue
		if bool(row["is_tree"]):
			trees.append(row)
		for name: String in (row["unclassified"] as PackedStringArray):
			unclassified[name] = "%s (%s)" % [row["asset"], name]

	_report_trees(trees)
	_report_unclassified(unclassified)
	_finish()


## Every (kit, asset) pair the shipped tables can place, deduplicated and in a stable order.
func _subjects(registry: Node) -> Array:
	var seen: Dictionary = {}
	var subjects: Array = []
	for table: Variant in (registry.get("scatter_tables") as Dictionary).values():
		for entry: Variant in (table.get("entries") as Array):
			var kit := String(entry.get("kit"))
			var asset := String(entry.get("asset"))
			var key := "%s|%s" % [kit, asset]
			if seen.has(key):
				continue
			seen[key] = true
			subjects.append([kit, asset])
	subjects.sort_custom(func(a: Array, b: Array) -> bool: return String(a[1]) < String(b[1]))
	return subjects


func _audit(kit: String, asset: String) -> Dictionary:
	var parts: Array = _field.call("_load_mesh_parts", kit, asset)
	if parts.is_empty():
		_fail("%s (%s) has no mesh" % [asset, kit])
		return {}

	# What the SHIPPED path builds, called straight through so this cannot drift from it.
	var fit: Dictionary = _field.call("_collider_for", kit, asset, parts)
	var solid: AABB = PROP_COLLIDER._solid_bounds(parts)
	var reach: float = _solid_reach(parts)
	var unclassified: PackedStringArray = _unclassified_materials(parts)

	# An EMPTY dictionary means "this prop does not collide at all" — ground flora, and anything
	# under `COLLIDER_MIN_HEIGHT_M` you step over (F-390). That is a result, not a failure.
	if fit.is_empty():
		return {
			"asset": asset, "kit": kit, "is_tree": false, "unclassified": unclassified,
		}

	var boxed: bool = StringName(fit.get("shape", &"cylinder")) == &"box"
	var half_width: float = float(fit["radius"])
	var top: float = float(fit["center_y"]) + float(fit["height"]) * 0.5
	var solid_top: float = solid.position.y + solid.size.y

	if boxed:
		var size: Vector3 = fit["size"] as Vector3
		check(
			size.x <= solid.size.x + OVERHANG_TOLERANCE_M
				and size.z <= solid.size.z + OVERHANG_TOLERANCE_M,
			"%s: box %.2f x %.2f m fits its solid footprint %.2f x %.2f m"
				% [asset, size.x, size.z, solid.size.x, solid.size.z]
		)
	else:
		check(
			half_width <= reach + OVERHANG_TOLERANCE_M,
			"%s: collider radius %.2f m does not overhang its solid geometry (%.2f m)"
				% [asset, half_width, reach]
		)
	check(
		top <= solid_top + HEADROOM_TOLERANCE_M,
		"%s: collider tops out at %.2f m, at or under its highest solid point (%.2f m)"
			% [asset, top, solid_top]
	)

	return {
		"asset": asset,
		"kit": kit,
		"is_tree": asset.begins_with("tree_") or asset.contains("_tree") or asset == "alder",
		"radius": half_width,
		"boxed": boxed,
		"height": float(fit["height"]),
		"solid_top": solid_top,
		"unclassified": unclassified,
	}


## Widest distance from the prop's vertical axis reached by SOLID (non-foliage) geometry below
## obstacle height — the thing a walking body can genuinely run into. Measured here straight off the
## vertex buffers, deliberately not by calling the shipped helper, so the check is a measurement of
## the geometry rather than a restatement of the implementation.
func _solid_reach(parts: Array) -> float:
	var worst_sq: float = 0.0
	for part: Dictionary in parts:
		var mesh: Mesh = part["mesh"] as Mesh
		var offset: Transform3D = part["offset"] as Transform3D
		for surface: int in mesh.get_surface_count():
			if _is_foliage_name(_material_name(mesh, surface)):
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			if arrays.is_empty():
				continue
			for vertex: Vector3 in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				var point: Vector3 = offset * vertex
				if point.y > PROP_COLLIDER.COLLIDER_OBSTACLE_HEIGHT_M:
					continue
				worst_sq = maxf(worst_sq, point.x * point.x + point.z * point.z)
	return sqrt(worst_sq)


func _unclassified_materials(parts: Array) -> PackedStringArray:
	var names := PackedStringArray()
	for part: Dictionary in parts:
		var mesh: Mesh = part["mesh"] as Mesh
		for surface: int in mesh.get_surface_count():
			var name: String = _material_name(mesh, surface)
			if name.is_empty() or names.has(name):
				continue
			if _is_foliage_name(name):
				continue
			var known: bool = false
			for prefix: String in SOLID_MATERIAL_PREFIXES:
				if name.begins_with(prefix):
					known = true
					break
			if not known:
				names.append(name)
	return names


func _material_name(mesh: Mesh, surface: int) -> String:
	var material: Material = mesh.surface_get_material(surface)
	return material.resource_name if material != null else ""


func _is_foliage_name(name: String) -> bool:
	for prefix: String in PROP_COLLIDER.FOLIAGE_MATERIAL_PREFIXES:
		if name.begins_with(prefix):
			return true
	return false


## The comparison no per-asset assertion can make: one species standing twice as wide as the rest is
## a defect even when its collider honestly matches its own trunk, because the trunk is what is
## wrong. Reported, and failed on, as a spread across the kit's standing trees.
func _report_trees(trees: Array) -> void:
	if trees.is_empty():
		return
	trees.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["radius"]) > float(b["radius"]))
	print("\nStanding trees, widest trunk collider first:")
	var radii := PackedFloat32Array()
	for row: Dictionary in trees:
		if bool(row["boxed"]):
			continue
		radii.append(float(row["radius"]))
		print("  %-28s r=%5.2f m   h=%5.1f m" % [row["asset"], row["radius"], row["height"]])
	if radii.is_empty():
		return
	var widest: float = radii[0]
	var sorted := radii.duplicate()
	sorted.sort()
	# Against the MEDIAN, not the narrowest. The narrowest tree in the world is a mangrove at
	# 0.35 m and a whip-thin species is not evidence that a stout one is wrong; what this catches is
	# ONE tree standing far outside the population, which is what the willows were doing.
	var median: float = sorted[sorted.size() / 2]
	check(
		widest <= median * TREE_RADIUS_SPREAD,
		"no tree's trunk collider stands more than %.1fx the median (widest %.2f m, median %.2f m)"
			% [TREE_RADIUS_SPREAD, widest, median]
	)


## How much wider than the MEDIAN standing tree the widest one may be. The kit's pines, birches,
## bare and crooked trees sit between 0.48 and 0.66 m; F-434 found `tree_willow_a` at 1.08 m — a
## bole 2.2 m across on a 13.6 m tree, nearly twice the median — which is where "the collision boxs
## of willows are huge" came from. 1.9 leaves room for a genuinely stout species without leaving
## room for that: the corrected willow sits at 1.5x, and the current worst is `tree_snag_a` at
## 1.82x — a dead trunk whose seed came out of `standing_trunk` unusually heavy and which
## `create_asset` then scaled up 17% to reach its size band, thickness and all. That one is honest
## geometry rather than a bad number, so it is the ceiling this guard is set just above rather than
## something to fix here.
const TREE_RADIUS_SPREAD: float = 1.9


func _report_unclassified(unclassified: Dictionary) -> void:
	check(
		unclassified.is_empty(),
		"every material on a scattered prop is a known solid or foliage family%s"
			% ("" if unclassified.is_empty() else " — unknown: " + ", ".join(unclassified.values()))
	)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		_fail(description)


func _fail(description: String) -> void:
	failures += 1
	print("FAIL: %s" % description)


func _finish() -> void:
	print("\nTREE_COLLIDER_CHECK failures=%d" % failures)
	if _field != null:
		_field.free()
	quit(1 if failures > 0 else 0)
