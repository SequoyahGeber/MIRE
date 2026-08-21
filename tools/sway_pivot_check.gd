extends SceneTree

## F-341: two flora assets that agree on everything except where their geometry sits vertically must
## not share a sway material.
##
## `EnvironmentVfx._sway_material()` caches by colour, roughness, sway profile and `bounds.size.y`,
## then bakes `bounds.position.y` into the shader's `wind_root_y` uniform and `1.0 / bounds.size.y`
## into `wind_inv_height`. Height was in the key; the ORIGIN was not. So a plant modelled with its
## base at y=0 and one of the same height modelled centred on its origin hashed to the same entry,
## and the second one bent around a pivot that belongs to the first — on the deliberately faceted
## 4.18 terrain, around a point that is not on its own geometry at all.
##
## The fixture the finding asks for, built both ways:
##
##   1. Two real `ArrayMesh`es with equal `size.y` and different `position.y`, to show the collision
##      is reachable from actual geometry rather than only from a hand-made `AABB`.
##   2. The same two AABBs through the shipped `_sway_material()`, asserting each material carries
##      its OWN root — and a negative control proving the cache still collapses assets that really
##      do match, which is the behaviour the key exists for and the thing a careless fix breaks.
##
##   .agent/bin/agent godot --script tools/sway_pivot_check.gd
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Presentation only — sway is a vertex-shader effect
## with no simulation or replication behind it.

const HEIGHT: float = 2.0
const PROFILE: Dictionary = {
	"strength": 0.12, "speed": 1.3, "bob": 0.0, "mask_power": 1.0, "vertex_phase": 1.0,
}

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var vfx: Node = root.get_node_or_null(^"EnvironmentVfx")
	check(vfx != null, "EnvironmentVfx is registered as an autoload")
	if vfx == null:
		_finish()
		return

	_check_fixture_geometry()
	_check_materials_do_not_alias(vfx)
	_check_cache_still_collapses(vfx)

	_finish()


## Real geometry, so this is not a check about a struct someone typed. Both boxes are the same
## height; one stands on its origin, the other straddles it.
func _check_fixture_geometry() -> void:
	print("\n== the fixture: equal height, different vertical origin ==")
	var grounded: ArrayMesh = _box_mesh(0.0)          # base at y=0, top at y=2
	var centred: ArrayMesh = _box_mesh(-HEIGHT / 2.0)  # base at y=-1, top at y=1
	var a: AABB = grounded.get_aabb()
	var b: AABB = centred.get_aabb()
	check(is_equal_approx(a.size.y, b.size.y),
		"both meshes are the same height (%.3f m)" % a.size.y)
	check(not is_equal_approx(a.position.y, b.position.y),
		"their vertical origins differ (%.3f vs %.3f)" % [a.position.y, b.position.y])


## The assertion. Before the fix both calls returned the SAME ShaderMaterial, so the centred mesh
## reported the grounded mesh's root.
func _check_materials_do_not_alias(vfx: Node) -> void:
	print("\n== each mesh bends around its own root ==")
	var grounded := AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, HEIGHT, 1.0))
	var centred := AABB(Vector3(-0.5, -HEIGHT / 2.0, -0.5), Vector3(1.0, HEIGHT, 1.0))
	var source: StandardMaterial3D = _source_material()

	var first: ShaderMaterial = vfx.call(&"_sway_material", source, PROFILE, grounded)
	var second: ShaderMaterial = vfx.call(&"_sway_material", source, PROFILE, centred)
	check(first != null and second != null, "both meshes got a sway material")
	if first == null or second == null:
		return

	check(first != second,
		"two meshes with the same height and different origins do NOT share a material")
	check(is_equal_approx(float(first.get_shader_parameter(&"wind_root_y")), grounded.position.y),
		"the grounded mesh's wind_root_y is its own base (%.3f)" % grounded.position.y)
	check(is_equal_approx(float(second.get_shader_parameter(&"wind_root_y")), centred.position.y),
		"the centred mesh's wind_root_y is its own base (%.3f)" % centred.position.y)
	# The other uniform derived from bounds. Equal here by construction — stated so a future change
	# that swaps which end of the AABB is keyed cannot pass this file by accident.
	check(is_equal_approx(
			float(first.get_shader_parameter(&"wind_inv_height")),
			float(second.get_shader_parameter(&"wind_inv_height"))),
		"equal heights still share an inverse height, as they should")


## The negative control. A key that included something per-instance would pass every assertion above
## while quietly turning the eighty-odd flora assets back into eighty-odd shaders.
func _check_cache_still_collapses(vfx: Node) -> void:
	print("\n== the cache still collapses assets that really do match ==")
	var bounds := AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, HEIGHT, 1.0))
	var source: StandardMaterial3D = _source_material()
	var first: ShaderMaterial = vfx.call(&"_sway_material", source, PROFILE, bounds)
	var again: ShaderMaterial = vfx.call(&"_sway_material", _source_material(), PROFILE, bounds)
	check(first == again,
		"identical appearance, profile, height AND origin reuse one cached material")

	# A different width/depth with the same vertical extents must also still share: only the vertical
	# terms are baked into the shader, so anything else in the AABB is correctly not in the key.
	var wider := AABB(Vector3(-4.0, 0.0, -4.0), Vector3(8.0, HEIGHT, 8.0))
	check(vfx.call(&"_sway_material", source, PROFILE, wider) == first,
		"a wider mesh at the same vertical extents still shares — only the vertical terms matter")


func _source_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.24, 0.42, 0.16)
	material.roughness = 0.9
	return material


## A unit box whose base sits at `base_y`, built through `ArrayMesh` so `get_aabb()` is the engine's
## own answer rather than one this file asserts.
func _box_mesh(base_y: float) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3(1.0, HEIGHT, 1.0)
	var arrays: Array = box.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# BoxMesh is centred on its origin; shifting every vertex moves the AABB with it.
	var offset: float = base_y + HEIGHT / 2.0
	for i: int in verts.size():
		verts[i] = verts[i] + Vector3(0.0, offset, 0.0)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	print("\nSWAY_PIVOT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
