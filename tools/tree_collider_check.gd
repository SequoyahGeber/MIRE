extends SceneTree

## F-348 — what shape does a scattered NODE harvestable actually collide as?
##
## Reproduces `ResourceScatterField._load_mesh_parts()` + `_build_node_holder()` exactly, on the
## flora the procedural island scatters, and prints the cylinder those two functions hand Jolt next
## to the trunk the player can see. A tree whose collider radius is the crown's half-width is an
## invisible wall metres out from the bark, and the number is the whole argument, so measure it
## rather than reason about it.
##
## The trunk width is measured as the widest X/Z extent of the mesh parts that survive a slab cut at
## ankle height (0.0-0.4 m local) — at that height a tree is trunk and root flare and nothing else,
## which is exactly the cross-section a walking collider should match.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only measurement.
##
##   .agent/bin/agent godot --script tools/tree_collider_check.gd

const FIELD := preload("res://world/gen/resource_scatter_field.gd")

## Everything the procedural island scatters as a NODE harvestable, not only the trees: the fix has
## to narrow a tree WITHOUT narrowing a boulder, and a check that only looked at trees could not
## tell the two apart.
const SUBJECTS: Array[Array] = [
	["flora", "tree_willow_a"],
	["flora", "tree_willow_b"],
	["flora", "tree_willow_c"],
	["flora", "tree_snag_a"],
	["flora", "bush_round_a"],
	["flora", "sapling_b"],
]


func _initialize() -> void:
	print("F-348 — scattered NODE harvestable colliders\n")
	_field = FIELD.new()
	var worst: float = 0.0
	for subject: Array in SUBJECTS:
		worst = maxf(worst, _report(String(subject[0]), String(subject[1])))
	print("\nWidest overhang of collider past the solid geometry: %.2f m" % worst)
	_field.free()
	quit()


var _field: Node3D = null


func _report(kit: String, asset: String) -> float:
	var parts: Array = _field.call("_load_mesh_parts", kit, asset)
	if parts.is_empty():
		print("%-18s MISSING or mesh-less" % asset)
		return 0.0

	var merged := AABB()
	for part: Dictionary in parts:
		var box: AABB = (part["offset"] as Transform3D) * (part["mesh"] as Mesh).get_aabb()
		merged = box if merged.size == Vector3.ZERO else merged.merge(box)

	# What the SHIPPED path now builds, called straight through so this cannot drift from it.
	var fit: Dictionary = _field.call("_collider_for", kit, asset, parts)
	var radius: float = float(fit["radius"])
	# What the old full-AABB rule built, for the before/after.
	var was: float = maxf(maxf(merged.size.x, merged.size.z) * 0.5, 0.05)
	# The real solid half-width down where a body walks.
	var solid: float = _solid_half_width(parts)

	print("%s  (%d mesh parts)" % [asset, parts.size()])
	print("  full AABB     %6.2f x %6.2f x %6.2f m" % [merged.size.x, merged.size.y, merged.size.z])
	print("  solid trunk below %.1f m   half-width %.2f m" % [FIELD.COLLIDER_OBSTACLE_HEIGHT_M, solid])
	print("  collider was  radius %.2f m   (overhang %+.2f m)" % [was, was - solid])
	print("  collider now  radius %.2f m   (overhang %+.2f m)" % [radius, radius - solid])
	print("  height %.2f m, centre y %.2f m, base y %.2f m" % [
		float(fit["height"]), float(fit["center_y"]),
		float(fit["center_y"]) - float(fit["height"]) * 0.5,
	])
	return radius - solid


## Widest distance from the prop's vertical axis reached by SOLID (non-foliage) geometry below
## obstacle height — the thing a walking body can genuinely run into. Measured here straight off the
## vertex buffers, deliberately not by calling the shipped helper, so the check is a measurement of
## the geometry rather than a restatement of the implementation.
func _solid_half_width(parts: Array) -> float:
	var worst_sq: float = 0.0
	for part: Dictionary in parts:
		var mesh: Mesh = part["mesh"] as Mesh
		var offset: Transform3D = part["offset"] as Transform3D
		for surface: int in mesh.get_surface_count():
			var material: Material = mesh.surface_get_material(surface)
			var name: String = material.resource_name if material != null else ""
			var foliage := false
			for prefix: String in FIELD.FOLIAGE_MATERIAL_PREFIXES:
				if name.begins_with(prefix):
					foliage = true
					break
			if foliage:
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for v: Vector3 in verts:
				var p: Vector3 = offset * v
				if p.y > FIELD.COLLIDER_OBSTACLE_HEIGHT_M:
					continue
				worst_sq = maxf(worst_sq, p.x * p.x + p.z * p.z)
	return sqrt(worst_sq)
