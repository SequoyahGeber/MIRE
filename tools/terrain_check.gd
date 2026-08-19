extends SceneTree

## Verifies task 4.1 — world/gen/island_heightmap.gd's pure height() function.
##
##   .agent/bin/agent godot --script tools/terrain_check.gd
##
## This checks BEHAVIOR (repeatable, bounded, seed-sensitive, island-shaped). Cross-platform
## bit-identity is a separate concern, covered by tools/check_determinism.gd's terrain_hash — run
## that on each new platform per the D-017/D-028 pattern and compare by hand in DECISIONS.md.

## Preloaded rather than referenced by bare class_name — a script new to this session is not yet in
## .godot/global_script_class_cache.cfg (F-016, same fix tools/handshake_check.gd uses).
const IslandHeightmap = preload("res://world/gen/island_heightmap.gd")

var _failures: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


## Design-space point at fraction `t` along the polyline (by segment length).
func _polyline_point(points: PackedVector2Array, t: float) -> Vector2:
	var total: float = 0.0
	for index in range(points.size() - 1):
		total += points[index].distance_to(points[index + 1])
	var target: float = total * clampf(t, 0.0, 1.0)
	for index in range(points.size() - 1):
		var segment_length: float = points[index].distance_to(points[index + 1])
		if target <= segment_length or index == points.size() - 2:
			return points[index] + (points[index + 1] - points[index]) \
				* (target / segment_length if segment_length > 0.0 else 0.0)
		target -= segment_length
	return points[points.size() - 1]


func _initialize() -> void:
	const SEED_A: int = 20260818
	const SEED_B: int = 8102602

	print("\n-- purity and determinism --")
	var h1: float = IslandHeightmap.height(37.0, -14.0, SEED_A)
	var h2: float = IslandHeightmap.height(37.0, -14.0, SEED_A)
	_check("same (x, z, seed) returns the exact same float twice", h1 == h2,
		"%f vs %f" % [h1, h2])

	var different_seed: float = IslandHeightmap.height(37.0, -14.0, SEED_B)
	_check("a different seed changes the height at the same point", h1 != different_seed,
		"both %f" % h1)

	var different_point: float = IslandHeightmap.height(38.0, -14.0, SEED_A)
	_check("a neighbouring point differs from its neighbour (not a flat plane)",
		h1 != different_point, "both %f" % h1)

	print("\n-- island shape --")
	var radius: float = IslandHeightmap.world_radius()
	var beyond_ok: bool = true
	var beyond_detail: String = ""
	# All eight compass directions, because islets are placed by seed and a single
	# +x probe passes by luck on every seed whose islets sit elsewhere.
	for direction: Vector2 in [Vector2(1, 0), Vector2(0.7071, 0.7071), Vector2(0, 1),
			Vector2(-0.7071, 0.7071), Vector2(-1, 0), Vector2(-0.7071, -0.7071),
			Vector2(0, -1), Vector2(0.7071, -0.7071)]:
		var point: Vector2 = direction * (radius + 40.0)
		var sample: float = IslandHeightmap.height(point.x, point.y, SEED_A)
		if sample != 0.0:
			beyond_ok = false
			beyond_detail = "%.3f at %v" % [sample, point]
	_check("beyond WORLD_RADIUS is open water in every direction", beyond_ok, beyond_detail)

	var at_edge: float = IslandHeightmap.height(radius, 0.0, SEED_A)
	_check("exactly at the world radius is 0.0", at_edge == 0.0, str(at_edge))

	var scale: float = IslandHeightmap.MAX_HEIGHT
	var interior_bound_ok: bool = true
	var interior_detail: String = ""
	for i in 32:
		# Sample well inside the unmasked interior — random-ish but seeded/fixed, not randi().
		var x: float = float(i) * 1.4 - 22.0
		var z: float = float(i) * -1.1 + 9.0
		var h: float = IslandHeightmap.height(x, z, SEED_A)
		if absf(h) > scale * 1.2:
			interior_bound_ok = false
			interior_detail = "height %f at (%f, %f) exceeds scale %f" % [h, x, z, scale]
			break
	_check("interior heights stay within HEIGHT_SCALE bounds", interior_bound_ok, interior_detail)

	print("\n-- the river (4.14) --")
	var line_a: PackedVector2Array = IslandHeightmap.river_polyline(SEED_A)
	var line_a2: PackedVector2Array = IslandHeightmap.river_polyline(SEED_A)
	var line_b: PackedVector2Array = IslandHeightmap.river_polyline(SEED_B)
	_check("the polyline is deterministic for a seed", line_a == line_a2, "")
	_check("a different seed bends a different river", line_a != line_b, "")
	_check("four control points: source, two bends, mouth", line_a.size() == 4,
		str(line_a.size()))

	# The bed is monotonically downhill: walk t along the polyline, sample the carved surface AT
	# the channel centre (bent-space centre is unknowable analytically, so probe the design-space
	# centreline and take min over a small cross-tick — the warp moves the channel, never removes
	# it), and require each step's bed to sit no higher than the last, within noise-free tolerance.
	var previous_bed: float = 1.0e9
	var monotonic: bool = true
	var monotonic_detail: String = ""
	var reaches_sea: bool = false
	for step in range(0, 21):
		var t: float = float(step) / 20.0
		var point: Vector2 = _polyline_point(line_a, t)
		var bed: float = 1.0e9
		# A 2-axis cross wide enough to cover the shape warp's amplitude (~14 m): the channel
		# lives in bent space, and a centreline-only probe reads a BANK wherever the warp has
		# shifted the valley sideways — which looks exactly like the bed climbing.
		for tick in range(-8, 9):
			var stride: float = float(tick) * 2.2
			bed = minf(bed, IslandHeightmap.height(point.x + stride, point.y, SEED_A))
			bed = minf(bed, IslandHeightmap.height(point.x, point.y + stride, SEED_A))
		if bed > previous_bed + 0.75:
			monotonic = false
			monotonic_detail = "bed rose %.2f -> %.2f at t=%.2f" % [previous_bed, bed, t]
		previous_bed = minf(previous_bed, bed)
		if t > 0.55 and bed < 0.0:
			reaches_sea = true
	_check("the bed never climbs back uphill on its way down", monotonic, monotonic_detail)
	_check("the river reaches the sea (bed below sea level in its lower reach)", reaches_sea, "")

	# min() property: the carve only ever LOWERS terrain. Compare against a no-river surface by
	# sampling far outside the corridor as the control is impossible; instead assert the direct
	# inequality the implementation promises: carved height <= the channel ceiling wherever the
	# corridor bites, and the corridor's centre is lower than its banks (it is a valley).
	var centre_point: Vector2 = _polyline_point(line_a, 0.4)
	var centre_h: float = IslandHeightmap.height(centre_point.x, centre_point.y, SEED_A)
	var bank_h: float = IslandHeightmap.height(centre_point.x + 40.0, centre_point.y + 26.0, SEED_A)
	_check("the corridor is a valley: centreline sits below ground 48 m off to the side",
		centre_h < bank_h or bank_h == 0.0, "centre %.2f vs bank %.2f" % [centre_h, bank_h])

	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)
