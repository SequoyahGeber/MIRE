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


func _initialize() -> void:
	const SEED_A: int = 20260818
	const SEED_B: int = 8102602

	print("\n-- purity and determinism --")
	var h1: float = IslandHeightmap.height(37.0, -114.0, SEED_A)
	var h2: float = IslandHeightmap.height(37.0, -114.0, SEED_A)
	_check("same (x, z, seed) returns the exact same float twice", h1 == h2,
		"%f vs %f" % [h1, h2])

	var different_seed: float = IslandHeightmap.height(37.0, -114.0, SEED_B)
	_check("a different seed changes the height at the same point", h1 != different_seed,
		"both %f" % h1)

	var different_point: float = IslandHeightmap.height(38.0, -114.0, SEED_A)
	_check("a neighbouring point differs from its neighbour (not a flat plane)",
		h1 != different_point, "both %f" % h1)

	print("\n-- island shape --")
	var radius: float = IslandHeightmap.ISLAND_RADIUS
	var beyond: float = IslandHeightmap.height(radius + 50.0, 0.0, SEED_A)
	_check("well beyond the island radius is exactly flat 0.0", beyond == 0.0, str(beyond))

	var at_edge: float = IslandHeightmap.height(radius, 0.0, SEED_A)
	_check("exactly at the island radius is 0.0", at_edge == 0.0, str(at_edge))

	var scale: float = IslandHeightmap.HEIGHT_SCALE
	var interior_bound_ok: bool = true
	var interior_detail: String = ""
	for i in 32:
		# Sample well inside the unmasked interior — random-ish but seeded/fixed, not randi().
		var x: float = float(i) * 3.1 - 48.0
		var z: float = float(i) * -2.3 + 21.0
		var h: float = IslandHeightmap.height(x, z, SEED_A)
		if absf(h) > scale * 1.2:
			interior_bound_ok = false
			interior_detail = "height %f at (%f, %f) exceeds scale %f" % [h, x, z, scale]
			break
	_check("interior heights stay within HEIGHT_SCALE bounds", interior_bound_ok, interior_detail)

	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)
