extends SceneTree

## F-496: the answer is NO — filling a `MultiMesh` through `MultiMesh.buffer` from GDScript is
## roughly **2.5x SLOWER** than calling `set_instance_transform()` once per instance.
##
## This file exists so nobody has to find that out twice. The idea is an obvious one and it is the
## right instinct everywhere else in this project — `MireGrid._upload_field_texture()` documents the
## same reasoning about replacing "65,536 Variant-boxed calls" with one buffer write, and there it is
## a real win. It does not transfer here, and the reason is arithmetic rather than anything about
## MultiMesh:
##
##   · `set_instance_transform(index, t)` is ONE call into the engine per instance.
##   · Filling the buffer is TWELVE `PackedFloat32Array` element writes per instance, and an indexed
##     write into a Packed array from GDScript is itself a boxed operation. Twelve of them do not
##     come out cheaper than the one call they were meant to replace.
##
## The `Image.set_pixel` case wins because the loop there builds a `PackedByteArray` of ONE byte per
## cell — a 12:1 ratio the other way. The rule of thumb worth carrying: a buffer write beats a
## per-item call only when the buffer holds FEWER elements per item than the call would cost.
##
## Measured on an M5 Pro, Godot 4.7.1, 200 groups x 400 instances (sized from F-454's census of
## ~10,000 MultiMeshInstance3D nodes in a settled world):
##
##     set_instance_transform 9.14 ms | buffer 23.10 ms | 0.40x
##
## Both paths are warmed before either is timed, and the buffer path is additionally timed FIRST in
## its own pass, because on a 2x difference a first-loop warm-up cost would otherwise be the entire
## result. It is not: the buffer path measures the same either way.
##
## **Needs a real renderer** for the correctness half — MultiMesh instance transforms are write-only
## under `--headless` (F-103, `tools/multimesh_readback_check.gd` asserts exactly that), so a
## headless run would compare identity to identity and report a meaningless PASS.
##
##     .agent/bin/agent godot --display-driver macos --script tools/multimesh_fill_bench.gd

## Enough instances to catch an index-stride error, which a one- or two-instance case cannot.
const VERIFY_INSTANCES: int = 16
## Transforms round-trip through 32-bit floats, so this compares near, not equal.
const EPSILON: float = 0.0005
const BENCH_INSTANCES: int = 400
const BENCH_GROUPS: int = 200

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("multimesh_fill_bench needs a real renderer — instance transforms are write-only "
			+ "headless (F-103), so the correctness half would compare identity to identity and "
			+ "pass regardless. Re-run with --display-driver macos (see the header).")
		quit(1)
		return

	_verify_layout()
	_report_speed()
	print("MULTIMESH_FILL_BENCH failures=%d" % failures)
	quit(0 if failures == 0 else 1)


## The buffer path is not shipped, so this is not a regression guard — it is the proof that the
## benchmark below is comparing two ways of doing the SAME thing. A buffer layout that quietly wrote
## the basis transposed would still fill an array of the right length at the right speed, and the
## timing would be just as real and completely meaningless.
func _verify_layout() -> void:
	# Deliberately awkward: non-uniform scale, rotation on all three axes, and a rotated offset.
	var offset := Transform3D(
		Basis.from_euler(Vector3(0.1, -0.4, 0.25)).scaled(Vector3(1.0, 1.3, 0.8)),
		Vector3(0.5, -1.25, 2.0))
	var transforms: Array[Transform3D] = []
	for index: int in VERIFY_INSTANCES:
		var f: float = float(index)
		transforms.append(Transform3D(
			Basis.from_euler(Vector3(f * 0.21, f * 0.37, f * -0.13))
				.scaled(Vector3(0.7 + f * 0.05, 1.0 + f * 0.03, 1.4 - f * 0.02)),
			Vector3(f * 3.5, f * -1.75, f * 0.9)))

	var reference := _multimesh(VERIFY_INSTANCES)
	for index: int in VERIFY_INSTANCES:
		reference.set_instance_transform(index, transforms[index] * offset)
	var subject := _multimesh(VERIFY_INSTANCES)
	_fill_via_buffer(subject, transforms, offset)

	# Guard the guard: if the renderer is not retaining these, every comparison is vacuous.
	var origins: Dictionary = {}
	for index: int in VERIFY_INSTANCES:
		origins[reference.get_instance_transform(index).origin] = true
	_check(origins.size() == VERIFY_INSTANCES,
		"the renderer retains MultiMesh transforms, so the comparison means something (%d of %d)"
			% [origins.size(), VERIFY_INSTANCES])

	var worst: float = 0.0
	for index: int in VERIFY_INSTANCES:
		worst = maxf(worst, _delta(
			reference.get_instance_transform(index), subject.get_instance_transform(index)))
	_check(worst <= EPSILON,
		"the buffer path produces exactly what set_instance_transform does, so the timings below "
			+ "compare like with like (worst %.6f, tolerance %.6f)" % [worst, EPSILON])


func _report_speed() -> void:
	var transforms: Array[Transform3D] = []
	for index: int in BENCH_INSTANCES:
		var f: float = float(index)
		transforms.append(Transform3D(
			Basis.from_euler(Vector3(f * 0.01, f * 0.02, 0.0)),
			Vector3(f, f * 0.5, f * 0.25)))
	var offset := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.5, 0.0))

	for _warm: int in 4:
		var warm := _multimesh(BENCH_INSTANCES)
		for index: int in BENCH_INSTANCES:
			warm.set_instance_transform(index, transforms[index] * offset)
		_fill_via_buffer(_multimesh(BENCH_INSTANCES), transforms, offset)

	# The buffer path, timed first — see the header on why the order is stated rather than assumed.
	var buffer_first_usec: int = Time.get_ticks_usec()
	for _group: int in BENCH_GROUPS:
		_fill_via_buffer(_multimesh(BENCH_INSTANCES), transforms, offset)
	buffer_first_usec = Time.get_ticks_usec() - buffer_first_usec

	var call_usec: int = Time.get_ticks_usec()
	for _group: int in BENCH_GROUPS:
		var multimesh := _multimesh(BENCH_INSTANCES)
		for index: int in BENCH_INSTANCES:
			multimesh.set_instance_transform(index, transforms[index] * offset)
	call_usec = Time.get_ticks_usec() - call_usec

	var buffer_usec: int = Time.get_ticks_usec()
	for _group: int in BENCH_GROUPS:
		_fill_via_buffer(_multimesh(BENCH_INSTANCES), transforms, offset)
	buffer_usec = Time.get_ticks_usec() - buffer_usec

	print("MULTIMESH_FILL_BENCH_SPEED groups=%d instances_each=%d total=%d"
		% [BENCH_GROUPS, BENCH_INSTANCES, BENCH_GROUPS * BENCH_INSTANCES])
	print("  set_instance_transform  %7.2f ms" % [float(call_usec) / 1000.0])
	print("  MultiMesh.buffer        %7.2f ms  (%.2f ms when timed first)"
		% [float(buffer_usec) / 1000.0, float(buffer_first_usec) / 1000.0])
	print("  buffer is %.2fx the speed of the per-instance call — under 1.0 means SLOWER, and it is"
		% [float(call_usec) / maxf(float(buffer_usec), 1.0)])


## The buffer layout, kept here rather than in a shipped file precisely because it is NOT shipped.
## `TRANSFORM_3D` packs 12 floats per instance: the 3x4 matrix ROW-major, which is the transpose of
## how `Basis` stores its columns.
func _fill_via_buffer(multimesh: MultiMesh, transforms: Array, offset: Transform3D) -> void:
	var count: int = transforms.size()
	var buffer := PackedFloat32Array()
	buffer.resize(count * 12)
	for index: int in count:
		var t: Transform3D = (transforms[index] as Transform3D) * offset
		var b: Basis = t.basis
		var o: Vector3 = t.origin
		var base: int = index * 12
		buffer[base] = b.x.x
		buffer[base + 1] = b.y.x
		buffer[base + 2] = b.z.x
		buffer[base + 3] = o.x
		buffer[base + 4] = b.x.y
		buffer[base + 5] = b.y.y
		buffer[base + 6] = b.z.y
		buffer[base + 7] = o.y
		buffer[base + 8] = b.x.z
		buffer[base + 9] = b.y.z
		buffer[base + 10] = b.z.z
		buffer[base + 11] = o.z
	multimesh.buffer = buffer


func _multimesh(count: int) -> MultiMesh:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = BoxMesh.new()
	multimesh.instance_count = count
	return multimesh


## Worst component-wise divergence — origin and all three basis columns, so a mirrored or transposed
## basis cannot hide behind a matching origin.
func _delta(expected: Transform3D, actual: Transform3D) -> float:
	return maxf(
		(actual.origin - expected.origin).length(),
		maxf((actual.basis.x - expected.basis.x).length(),
			maxf((actual.basis.y - expected.basis.y).length(),
				(actual.basis.z - expected.basis.z).length())))


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
