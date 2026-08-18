extends SceneTree

## Verifies task 4.2 — world/gen/biome_def.gd's schema, world/gen/biome_map.gd's pure moisture/
## assignment functions, and the registry.gd loader wiring for content/biomes/.
##
##   .agent/bin/agent godot --script tools/biome_check.gd
##
## Drives the REGISTERED /root/Registry (F-068/F-069 precedent — a harness that builds its own copy
## proves the script works and says nothing about whether the shipped project loads it), same
## get_node_or_null(^"Registry") pattern tools/attunement_check.gd uses. BiomeMap and IslandHeightmap
## are preloaded rather than referenced by bare class_name — both are new/recent this milestone and
## not yet guaranteed to be in .godot/global_script_class_cache.cfg (F-016, same fix
## tools/terrain_check.gd uses for IslandHeightmap).

const BiomeMap := preload("res://world/gen/biome_map.gd")
const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")

const SEED_A: int = 20260818
const SEED_B: int = 8102602

var failures: int = 0
var registry: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	_check_biome_def_content()
	_check_moisture_noise()
	_check_assign_resolution()
	_check_biome_at()

	print("\nBIOME_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually loads biome content ==")
	registry = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry is registered as an autoload")
	if registry == null:
		return false
	var biomes: Dictionary = registry.get(&"biomes")
	check(biomes.size() == 3, "exactly 3 worked-example biomes load (%d)" % biomes.size())
	for id: StringName in [&"shore", &"grassland", &"forest"]:
		check(bool(registry.call(&"has_biome", id)), "content/biomes/%s.tres is indexed by its id" % id)
	return true


## Pins the three worked examples' authored ranges so a future edit that breaks the deliberate
## shore-wins-at-sea-level / forest-wins-the-0.5-tie design (see biome_def.gd's priority doc comment)
## fails loudly here instead of silently in world generation.
func _check_biome_def_content() -> void:
	print("\n== worked-example content matches the documented design ==")
	var shore: Resource = registry.call(&"get_biome", &"shore")
	var grassland: Resource = registry.call(&"get_biome", &"grassland")
	var forest: Resource = registry.call(&"get_biome", &"forest")
	for def: Resource in [shore, grassland, forest]:
		var errors: PackedStringArray = def.call(&"validation_errors")
		check(errors.is_empty(), "%s has no validation errors (%s)" % [def.get(&"id"), errors])
	check(int(shore.get(&"priority")) < int(grassland.get(&"priority")),
		"shore's priority is lower (wins ties) than grassland's")
	check(int(shore.get(&"priority")) < int(forest.get(&"priority")),
		"shore's priority is lower (wins ties) than forest's")
	check(is_equal_approx(float(grassland.get(&"moisture_max")), float(forest.get(&"moisture_min"))),
		"grassland's moisture ceiling meets forest's moisture floor (no coverage gap)")


func _check_moisture_noise() -> void:
	print("\n== BiomeMap.moisture() is pure, deterministic, seed-sensitive, and bounded ==")
	var m1: float = BiomeMap.moisture(12.0, -40.0, SEED_A)
	var m2: float = BiomeMap.moisture(12.0, -40.0, SEED_A)
	check(m1 == m2, "same (x, z, seed) returns the exact same float twice (%f vs %f)" % [m1, m2])

	var different_seed: float = BiomeMap.moisture(12.0, -40.0, SEED_B)
	check(m1 != different_seed, "a different seed changes moisture at the same point (both %f)" % m1)

	var bounds_ok: bool = true
	var bounds_detail: String = ""
	for i in 32:
		var x: float = float(i) * 5.3 - 60.0
		var z: float = float(i) * -3.1 + 25.0
		var m: float = BiomeMap.moisture(x, z, SEED_A)
		if m < 0.0 or m > 1.0:
			bounds_ok = false
			bounds_detail = "moisture %f at (%f, %f) is outside [0, 1]" % [m, x, z]
			break
	check(bounds_ok, bounds_detail)


## Exercises BiomeMap.assign() directly against fixed (height, moisture) inputs and the real
## Registry content, so the resolution rule (priority, then id, then fallback) is pinned independent
## of what any particular noise field happens to sample.
func _check_assign_resolution() -> void:
	print("\n== BiomeMap.assign() resolves height/moisture to the right biome ==")
	var defs: Array = registry.get(&"biomes").values()

	check(BiomeMap.assign(-10.0, 0.5, defs) == &"shore",
		"low height resolves to shore regardless of moisture")
	check(BiomeMap.assign(50.0, 0.2, defs) == &"grassland",
		"mid height + low moisture resolves to grassland")
	check(BiomeMap.assign(50.0, 0.8, defs) == &"forest",
		"mid height + high moisture resolves to forest")
	check(BiomeMap.assign(50.0, 0.5, defs) == &"forest",
		"the exact moisture boundary (0.5) breaks the grassland/forest tie alphabetically toward forest")
	check(BiomeMap.assign(200.0, 0.5, defs) == &"shore",
		"a height outside every authored range falls back to the lowest-priority def (shore) rather than an empty id")
	check(BiomeMap.assign(50.0, 0.5, []) == &"",
		"an empty biome list has nothing to fall back to and returns an empty StringName")


## End-to-end: a real world (x, z, seed) resolves through IslandHeightmap + BiomeMap.moisture to a
## non-empty, deterministic biome id — this is the actual API 4.3/4.4 will call.
func _check_biome_at() -> void:
	print("\n== BiomeMap.biome_at() combines height + moisture deterministically ==")
	var defs: Array = registry.get(&"biomes").values()
	var known_ids: Array[StringName] = [&"shore", &"grassland", &"forest"]

	var b1: StringName = BiomeMap.biome_at(37.0, -114.0, SEED_A, defs)
	var b2: StringName = BiomeMap.biome_at(37.0, -114.0, SEED_A, defs)
	check(b1 == b2, "same (x, z, seed) returns the same biome twice (%s vs %s)" % [b1, b2])
	check(known_ids.has(b1), "resolves to one of the registered biome ids, not an empty one (%s)" % b1)

	var every_point_covered: bool = true
	var coverage_detail: String = ""
	for i in 40:
		var x: float = float(i) * 17.0 - 340.0
		var z: float = float(i) * -11.0 + 180.0
		var b: StringName = BiomeMap.biome_at(x, z, SEED_A, defs)
		if b == &"":
			every_point_covered = false
			coverage_detail = "no biome resolved at (%f, %f)" % [x, z]
			break
	check(every_point_covered, coverage_detail)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
