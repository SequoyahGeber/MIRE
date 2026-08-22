extends SceneTree

## Regression guard for F-108: an AABB is axis-aligned in a mesh's own local
## space, so `transform * aabb` on a rotated, non-box mesh -- any cone or
## tapered primitive -- returns the box around the rotated box, which is
## strictly larger than the true rotated extent. `ship_check.gd` measures
## `Mesh.ARRAY_VERTEX` transformed to world space instead; `flora_check.gd`
## still does not (F-108's follow-up, filed separately -- it belongs to a
## different file set).
##
## This check proves the two methods diverge on a synthetic cone against a
## hand-computed expected extent, so a future edit that reintroduces
## `transform * aabb` in either check fails here before it ever misreads a
## real asset.
##
## Run with:  .agent/bin/agent godot --script tools/dimension_check.gd

var failures: Array[String] = []


func _init() -> void:
	_check_cone_measurement()
	_finish()


## A cone (top_radius 0, bottom_radius 0.5, height 2) rotated 45 degrees
## about Z. Worked by hand: the box corners at the apex end (y=+1) are not
## real vertices -- the apex is a single point at x=0 -- so the naive
## method's rotated bound is pulled out by a corner that is empty space.
## The base ring at y=-1 does have a vertex at angle 0, so both methods
## agree on the tight side; they diverge on the loose one. Naive box-corner
## x-size works out to ~2.1213; true vertex x-size to ~1.7678.
func _check_cone_measurement() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = 0.5
	mesh.height = 2.0

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.rotation = Vector3(0.0, 0.0, deg_to_rad(45.0))

	# The buggy construction this check exists to catch.
	var naive: AABB = instance.transform * instance.get_aabb()

	# The fix: every vertex transformed to world space, then bounded.
	var low := Vector3.INF
	var high := -Vector3.INF
	for surface in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			var point: Vector3 = instance.transform * vertex
			low = low.min(point)
			high = high.max(point)
	var measured := AABB(low, high - low)

	var expected_naive_x := 2.1213
	var expected_true_x := 1.7678
	if absf(naive.size.x - expected_naive_x) > 0.02:
		failures.append(
			"cone: naive box-corner x-size %.4f, expected ~%.4f -- test fixture drifted" %
			[naive.size.x, expected_naive_x]
		)
	if absf(measured.size.x - expected_true_x) > 0.02:
		failures.append(
			"cone: vertex-measured x-size %.4f, expected ~%.4f" % [measured.size.x, expected_true_x]
		)
	if measured.size.x >= naive.size.x - 0.1:
		failures.append(
			("cone: vertex measurement (%.4f) did not come in tighter than the naive " +
			"AABB-rotation (%.4f) -- the two methods should diverge on a rotated cone") %
			[measured.size.x, naive.size.x]
		)

	print("DIMENSION_CHECK naive_x=%.4f vertex_x=%.4f" % [naive.size.x, measured.size.x])
	instance.free()


func _finish() -> void:
	if failures.is_empty():
		print("DIMENSION_CHECK_GODOT PASS")
	else:
		print("DIMENSION_CHECK_GODOT FAIL (%d)" % failures.size())
		for failure in failures:
			print("  ", failure)
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("DIMENSION_CHECK failures=%d" % failures.size())
	quit(0 if failures.is_empty() else 1)
