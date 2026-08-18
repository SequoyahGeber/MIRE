extends SceneTree

## F-103 regression guard: MultiMesh instance transforms are WRITE-ONLY under `--headless`.
##
## Instance transforms live in the RenderingServer, not in the `MultiMesh` resource. The headless
## dummy driver stores nothing, so the buffer comes back empty and every `get_instance_transform`
## returns identity — with no error and no warning.
##
## This check asserts the trap rather than the fix, on purpose. If a future Godot starts retaining
## the data headlessly this check FAILS, which is the moment to revisit anything written around the
## limitation. Until then it is the cheap proof of why `EnvironmentVfx` reads placements from the
## generator's `placements` meta instead of reading them back out of the batch.
##
## What it cost when nobody knew: F-097's first implementation placed firelight by reading the prop
## batches back, so Hollowmere's 101 crystals, 163 tendrils and 5 fires all collapsed onto the world
## origin — and the check passed, because "one site per class" is still more than zero.

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = BoxMesh.new()
	multimesh.instance_count = 3
	for index: int in 3:
		multimesh.set_instance_transform(index, Transform3D(
			Basis.IDENTITY, Vector3(float(index) * 10.0, 0.0, 0.0)))

	var distinct: Dictionary = {}
	for index: int in 3:
		distinct[multimesh.get_instance_transform(index).origin] = true
	print("MULTIMESH_READBACK distinct_origins=%d buffer=%d" % [distinct.size(), multimesh.buffer.size()])

	check(distinct.size() == 1 and multimesh.buffer.is_empty(),
		"headless MultiMesh readback is still write-only (F-103 assumption holds)")
	if distinct.size() > 1:
		push_warning(
			"MultiMesh transforms now survive headless. F-103's workaround may no longer be needed.")

	# The contract that replaced the readback: a generator publishes where each copy stands.
	var holder := Node3D.new()
	holder.set_meta(&"placements", PackedVector3Array([
		Vector3.ZERO, Vector3(10.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0)]))
	var published: PackedVector3Array = holder.get_meta(&"placements")
	check(published.size() == 3, "published placements survive where MultiMesh transforms do not")
	holder.free()

	print("MULTIMESH_READBACK_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
