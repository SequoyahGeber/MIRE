extends SceneTree

## Proof for task 4.7's POI placement. Everything here is offline and pure — `PoiMap` is a function,
## so this check drives it directly across many seeds rather than booting an island and looking.
##
##   .agent/bin/agent godot --script tools/poi_check.gd
##
## The four things worth asserting, in the order they would actually break:
##   1. DETERMINISM — same seed, same sites, twice, and across a re-sorted def list. This is the one
##      that matters most: a POI layout that differs between peers is a desync of the world itself,
##      and seed replication (4.6) has no way to notice.
##   2. SPACING — the whole reason 4.7 says Poisson-disc. Checked between every pair of sites, not
##      just within a kind.
##   3. CONSTRAINTS — every site actually satisfies its own def's height/biome/radius/slope rules,
##      re-derived from the heightmap rather than trusted from the generator.
##   4. HONEST COUNTS — a def whose constraints cannot fit its target places fewer and says so,
##      instead of padding the list or spinning.
const PoiMapScript = preload("res://world/gen/poi_map.gd")
const PoiDefScript = preload("res://world/gen/poi_def.gd")
const HeightmapScript = preload("res://world/gen/island_heightmap.gd")
const BiomeMapScript = preload("res://world/gen/biome_map.gd")

const SEEDS: Array[int] = [1, 20260818, -77, 0x5EED, 999983]

var failures: int = 0
var poi_defs: Array = []
var biome_defs: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null and registry.has_method(&"poi_defs"),
		"Registry exposes the poi family (poi_defs)")
	if registry == null or not registry.has_method(&"poi_defs"):
		finish()
		return
	poi_defs = (registry.call("poi_defs") as Dictionary).values()
	biome_defs = (registry.get(&"biomes") as Dictionary).values()
	check(poi_defs.size() >= 3, "content/poi/ loaded %d def(s)" % poi_defs.size())
	check(not biome_defs.is_empty(), "biome defs are available for the biome constraint")

	_check_defs_valid()
	_check_determinism()
	_check_spacing()
	_check_constraints()
	_check_seeds_differ()
	_check_honest_counts()
	_check_every_kind_appears()

	print("\nPOI_CHECK failures=%d" % failures)
	finish()


func _check_defs_valid() -> void:
	print("\n== every authored PoiDef is valid ==")
	for definition: Resource in poi_defs:
		var errors: PackedStringArray = definition.call("validation_errors")
		check(errors.is_empty(), "'%s' is a valid PoiDef (%s)"
			% [definition.get(&"id"), "; ".join(errors)])


## The load-bearing one. A POI layout is never sent over the wire — every peer regenerates it from
## the shared seed (ARCHITECTURE.md §4) — so anything that makes two runs disagree is a world desync
## that nothing downstream can detect.
func _check_determinism() -> void:
	print("\n== same seed, same island ==")
	for world_seed: int in SEEDS:
		var first: Array = PoiMapScript.sites_for_island(world_seed, poi_defs, biome_defs)
		var second: Array = PoiMapScript.sites_for_island(world_seed, poi_defs, biome_defs)
		check(_fingerprint(first) == _fingerprint(second),
			"seed %d places identically twice (%d sites)" % [world_seed, first.size()])

	# Registry hands back Dictionary.values(), and directory-scan order is not a contract. If the
	# generator's output depended on it, two peers whose filesystems enumerated content/poi/
	# differently would build different islands — silently, and only on some machines.
	var reversed_defs: Array = poi_defs.duplicate()
	reversed_defs.reverse()
	for world_seed: int in SEEDS:
		var normal: Array = PoiMapScript.sites_for_island(world_seed, poi_defs, biome_defs)
		var shuffled: Array = PoiMapScript.sites_for_island(world_seed, reversed_defs, biome_defs)
		check(_fingerprint(normal) == _fingerprint(shuffled),
			"seed %d is immune to def ORDER — sorted by id, not by scan order" % world_seed)


func _check_spacing() -> void:
	print("\n== minimum spacing holds between every pair, not just within a kind ==")
	for world_seed: int in SEEDS:
		var sites: Array = PoiMapScript.sites_for_island(world_seed, poi_defs, biome_defs)
		var worst_violation: String = ""
		for i: int in sites.size():
			for j: int in range(i + 1, sites.size()):
				var a: Dictionary = sites[i]
				var b: Dictionary = sites[j]
				# The two-ruler contract D-095 settled: `min_spacing_m` separates two sites of the
				# SAME kind, `clearance_m` (the larger of the pair) separates different kinds. The
				# first version of this check applied same-kind spacing to every pair, which is the
				# rule that carved four 180 m holes out of the island.
				var required: float = float(a["spacing"]) if a["def_id"] == b["def_id"] \
					else maxf(float(a["clearance"]), float(b["clearance"]))
				var apart: float = (a["position"] as Vector3).distance_to(b["position"] as Vector3)
				# Compared in the XZ plane the generator actually used — two sites on a slope are
				# further apart in 3D than the spacing rule ever promised, so a 3D distance here
				# would pass a layout the rule should have rejected.
				var flat: float = Vector2(
					(a["position"] as Vector3).x - (b["position"] as Vector3).x,
					(a["position"] as Vector3).z - (b["position"] as Vector3).z).length()
				if flat < required - 0.001:
					worst_violation = "%s and %s are %.1fm apart, need %.1fm (3D %.1f)" % [
						a["site_id"], b["site_id"], flat, required, apart]
		check(worst_violation.is_empty(),
			"seed %d: no pair is too close" % world_seed
				+ ("" if worst_violation.is_empty() else " — %s" % worst_violation))


## Re-derived from the heightmap rather than trusted: the generator could satisfy its own predicate
## and still be sampling the wrong point, which is exactly the bug a "does it agree with itself"
## check cannot see.
func _check_constraints() -> void:
	print("\n== every site satisfies its own def's constraints, re-measured ==")
	var by_id: Dictionary = {}
	for definition: Resource in poi_defs:
		by_id[StringName(String(definition.get(&"id")))] = definition

	for world_seed: int in SEEDS:
		var bad: PackedStringArray = []
		for site: Dictionary in PoiMapScript.sites_for_island(world_seed, poi_defs, biome_defs):
			var definition: Resource = by_id[StringName(String(site["def_id"]))]
			var position: Vector3 = site["position"]
			var height: float = HeightmapScript.height(position.x, position.z, world_seed)
			if not is_equal_approx(height, position.y):
				bad.append("%s: y is %.2f but the heightmap says %.2f" % [site["site_id"], position.y, height])
				continue
			if height < float(definition.get(&"height_min")) \
					or height > float(definition.get(&"height_max")):
				bad.append("%s: height %.1f outside [%.1f, %.1f]" % [site["site_id"], height,
					definition.get(&"height_min"), definition.get(&"height_max")])
			var radius_fraction: float = Vector2(position.x, position.z).length() \
				/ HeightmapScript.ISLAND_RADIUS
			if radius_fraction > float(definition.get(&"radius_max_fraction")) + 0.001 \
					or radius_fraction < float(definition.get(&"radius_min_fraction")) - 0.001:
				bad.append("%s: radius fraction %.3f out of range" % [site["site_id"], radius_fraction])
			var biome: StringName = BiomeMapScript.biome_at(position.x, position.z, world_seed, biome_defs)
			if not bool(definition.call("accepts_biome", biome)):
				bad.append("%s: landed in biome '%s', which its def excludes" % [site["site_id"], biome])
			if StringName(String(site["biome"])) != biome:
				bad.append("%s: reports biome '%s' but the map says '%s'" % [
					site["site_id"], site["biome"], biome])
		check(bad.is_empty(), "seed %d: every site is legal" % world_seed
			+ ("" if bad.is_empty() else " — %s" % "; ".join(bad)))


## Different seeds must produce different islands, or the seed is not doing anything — the failure
## mode where a salt is dropped and every world looks the same, which no determinism test can catch
## because a constant layout is perfectly deterministic.
func _check_seeds_differ() -> void:
	print("\n== different seeds place differently ==")
	var fingerprints: Dictionary = {}
	for world_seed: int in SEEDS:
		fingerprints[_fingerprint(PoiMapScript.sites_for_island(world_seed, poi_defs, biome_defs))] = world_seed
	check(fingerprints.size() == SEEDS.size(),
		"%d seeds produced %d distinct layouts" % [SEEDS.size(), fingerprints.size()])


func _check_honest_counts() -> void:
	print("\n== a def that cannot fit its target places fewer, and does not spin ==")
	# Impossible on purpose: a mountain-height shore landmark, with spacing wider than the island.
	var impossible: Resource = PoiDefScript.new()
	impossible.id = &"impossible"
	impossible.display_name = "Impossible"
	impossible.target_count = 12
	impossible.min_spacing_m = 4096.0
	impossible.height_min = 900.0
	impossible.height_max = 1000.0

	var started_msec: int = Time.get_ticks_msec()
	var sites: Array = PoiMapScript.sites_for_island(4242, [impossible], biome_defs)
	var elapsed: int = Time.get_ticks_msec() - started_msec
	check(sites.is_empty(), "an unsatisfiable def places nothing rather than inventing sites (%d)"
		% sites.size())
	check(elapsed < 2000, "and it gives up quickly rather than spinning (%d ms)" % elapsed)

	# D-151's ladder, both directions. Same impossible constraints twice; the only difference is
	# the `required` flag — the optional def stays honestly empty, the required one lands anyway.
	var must_land: Resource = PoiDefScript.new()
	must_land.id = &"must_land"
	must_land.display_name = "Must Land"
	must_land.required = true
	must_land.target_count = 1
	must_land.min_spacing_m = 24.0
	must_land.height_min = 900.0
	must_land.height_max = 1000.0
	must_land.max_slope_m = 0.01
	var landed: Array = PoiMapScript.sites_for_island(4242, [must_land], biome_defs)
	check(landed.size() == 1,
		"a REQUIRED def with unsatisfiable constraints still lands via the relax ladder (%d)"
			% landed.size())
	if landed.size() == 1:
		var position: Vector3 = landed[0]["position"]
		check(position.y >= 0.5, "and it landed on LAND, not seabed (y=%.2f)" % position.y)
		var twice: Array = PoiMapScript.sites_for_island(4242, [must_land], biome_defs)
		check(_fingerprint(landed) == _fingerprint(twice),
			"the ladder is deterministic — same seed, same fallback site")

	var generous: Resource = PoiDefScript.new()
	generous.id = &"generous"
	generous.display_name = "Generous"
	generous.target_count = 3
	generous.min_spacing_m = 40.0
	generous.height_min = -1000.0
	generous.height_max = 1000.0
	generous.max_slope_m = 0.0  # slope test disabled
	var placed: Array = PoiMapScript.sites_for_island(4242, [generous], biome_defs)
	check(placed.size() == 3, "a satisfiable def reaches its target exactly (%d)" % placed.size())


## Honest counts are not enough on their own: a def whose constraints never match would place zero
## on every island, report that honestly, and pass every test above — while 4.8's whole capture
## ritual quietly had nowhere to happen. This is the assertion that would have caught it, and it is
## the reason the per-kind numbers are printed rather than just totalled.
func _check_every_kind_appears() -> void:
	print("\n== every authored kind actually lands on a real island ==")
	var totals: Dictionary = {}
	for definition: Resource in poi_defs:
		totals[StringName(String(definition.get(&"id")))] = 0
	for world_seed: int in SEEDS:
		var per_seed: Dictionary = {}
		for site: Dictionary in PoiMapScript.sites_for_island(world_seed, poi_defs, biome_defs):
			var id := StringName(String(site["def_id"]))
			per_seed[id] = int(per_seed.get(id, 0)) + 1
			totals[id] = int(totals[id]) + 1
		var parts: PackedStringArray = []
		for definition: Resource in poi_defs:
			var id := StringName(String(definition.get(&"id")))
			parts.append("%s %d/%d" % [id, int(per_seed.get(id, 0)), definition.get(&"target_count")])
		print("    seed %d: %s" % [world_seed, ", ".join(parts)])

	for definition: Resource in poi_defs:
		var id := StringName(String(definition.get(&"id")))
		check(int(totals[id]) > 0,
			"'%s' placed %d site(s) across %d seeds — a kind that never lands is a dead def"
				% [id, int(totals[id]), SEEDS.size()])

	# The Wellspring and the shipwreck specifically: the run's objective and its only exit need
	# somewhere to happen on EVERY island. The 5-seed list above is for expensive assertions; this
	# one is cheap enough to sweep WIDE, because the zero-Wellspring seed that motivated D-151 was
	# found by a random boot, not by a curated list.
	var objective_gaps: PackedStringArray = []
	for sweep_seed: int in range(1, 65):
		var wellsprings: int = 0
		var ships: int = 0
		for site: Dictionary in PoiMapScript.sites_for_island(sweep_seed * 7919, poi_defs, biome_defs):
			match StringName(String(site["def_id"])):
				&"wellspring":
					wellsprings += 1
				&"shipwreck":
					ships += 1
		if wellsprings < 1:
			objective_gaps.append("seed %d: no wellspring" % (sweep_seed * 7919))
		if ships != 1:
			objective_gaps.append("seed %d: %d ships" % [sweep_seed * 7919, ships])
	check(objective_gaps.is_empty(),
		"64-seed sweep: every island has >=1 Wellspring and exactly 1 shipwreck"
			+ ("" if objective_gaps.is_empty() else " — %s" % "; ".join(objective_gaps)))


## Position rounded to a millimetre: two runs that agree must agree bit-for-bit in practice, but
## comparing raw floats through a String would make this check hostage to float formatting rather
## than to the thing it is testing.
func _fingerprint(sites: Array) -> String:
	var parts: PackedStringArray = []
	for site: Dictionary in sites:
		var position: Vector3 = site["position"]
		parts.append("%s|%.3f,%.3f,%.3f|%.4f" % [
			site["site_id"], position.x, position.y, position.z, site["rotation_y"]])
	return "\n".join(parts)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
