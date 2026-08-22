extends SceneTree

## Proof for F-573 — the `standing_stones` POI now builds something, and what it builds is a stone
## circle rather than a heap.
##
##   .agent/bin/agent godot --script tools/stone_circle_check.gd
##
## Two halves, in the order they would break:
##
##   1. THE WIRING, which is the finding itself. `content/poi/standing_stones.tres` names a
##      `structure_id`, `PoiStructures` has a builder registered under that id, and a real
##      `ProceduralWorld` therefore builds pieces at all six sites instead of six empty Node3Ds.
##      Asserted against a booted island, not against the content file, because reading the .tres
##      back is what a wiring bug looks like from the inside.
##   2. THE LAYOUT, driven directly — `StoneCircleSite.pieces_for_site()` is pure, so the geometry
##      is checked offline across many seeds rather than by looking at one island. Determinism
##      first (a structure that differs between peers is a desync of the world itself, and nothing
##      replicates it), then that the ring is actually a ring, then that the spread across sites
##      contains ordinary circles and not only interesting ones.
const StoneCircleScript = preload("res://world/gen/stone_circle_site.gd")
const PoiStructuresScript = preload("res://world/gen/poi_structures.gd")

const SEEDS: Array[int] = [1, 20260822, -77, 0x5EED, 999983, 42, 31337, 8675309]
const STRUCTURE_ID: StringName = &"stone_circle"

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_check_registration()
	_check_determinism()
	_check_ring_geometry()
	_check_spread()
	await _check_world_builds_them()
	print("\nSTONE_CIRCLE_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)


# ── 1 · the wiring ────────────────────────────────────────────────────────────────────────────────


func _check_registration() -> void:
	print("\n== F-573: the def names a structure and the structure exists ==")
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload is up")
	if registry == null:
		return
	var def: Resource = registry.call(&"poi_defs").get(&"standing_stones")
	check(def != null, "content/poi/standing_stones.tres loads as a PoiDef")
	if def == null:
		return
	var structure_id := StringName(String(def.get(&"structure_id")))
	check(structure_id == STRUCTURE_ID,
		"THE FINDING: standing_stones declares structure_id '%s' (was &\"\", which built nothing)"
			% structure_id)
	check(PoiStructuresScript.has_structure(structure_id),
		"PoiStructures has a builder registered for '%s'" % structure_id)
	# The def is otherwise unchanged, and the finding turns on it still reserving its footprint —
	# if someone "fixes" this by shrinking the clearance instead, that is a different island.
	check(int(def.get(&"target_count")) == 6,
		"still six sites an island (target_count=%d)" % int(def.get(&"target_count")))


# ── 2 · determinism ───────────────────────────────────────────────────────────────────────────────


func _check_determinism() -> void:
	print("\n== the same site seed builds the identical circle ==")
	for site_seed: int in SEEDS:
		var first: Array = StoneCircleScript.pieces_for_site(site_seed)
		var second: Array = StoneCircleScript.pieces_for_site(site_seed)
		check(_fingerprint(first) == _fingerprint(second),
			"seed %d rebuilds identically (%d pieces)" % [site_seed, first.size()])
	# Different seeds must NOT agree, or "deterministic" is being satisfied by a constant.
	var distinct: Dictionary = {}
	for site_seed: int in SEEDS:
		distinct[_fingerprint(StoneCircleScript.pieces_for_site(site_seed))] = true
	check(distinct.size() == SEEDS.size(),
		"%d seeds produce %d distinct circles — no two sites are twins"
			% [SEEDS.size(), distinct.size()])


# ── 3 · it is a ring ──────────────────────────────────────────────────────────────────────────────


func _check_ring_geometry() -> void:
	print("\n== the ring stones actually lie on a ring ==")
	for site_seed: int in SEEDS:
		var pieces: Array = StoneCircleScript.pieces_for_site(site_seed)
		check(not pieces.is_empty(), "seed %d builds pieces at all" % site_seed)
		if pieces.is_empty():
			continue

		# Ring members are the standing/fallen megaliths; cairn and debris use the rock_cluster
		# assets and the outlier is the one boulder, so filtering by asset isolates the ring.
		var radii: Array[float] = []
		for piece: Dictionary in pieces:
			var asset := String(piece.get("asset", ""))
			if not (asset.begins_with("standing_stone") or asset.begins_with("stone_marker")):
				continue
			var offset: Vector3 = piece.get("offset", Vector3.ZERO)
			radii.append(Vector2(offset.x, offset.z).length())
		check(radii.size() >= StoneCircleScript.MIN_STONES - 3,
			"seed %d keeps %d ring stones standing or fallen" % [site_seed, radii.size()])
		if radii.is_empty():
			continue

		var mean: float = 0.0
		for r: float in radii:
			mean += r
		mean /= float(radii.size())
		check(mean >= StoneCircleScript.RADIUS_MIN_M - 0.5
				and mean <= StoneCircleScript.RADIUS_MAX_M + 0.5,
			"seed %d ring radius %.2f m is in the authored 6.5-9.0 m band" % [site_seed, mean])
		var worst: float = 0.0
		for r: float in radii:
			worst = maxf(worst, absf(r - mean))
		# The jitter is +/-0.4 m by construction. Anything beyond a metre means a stone escaped the
		# ring, which is the failure that makes a circle read as a rubble pile.
		check(worst <= 1.0,
			"seed %d worst stone sits %.2f m off the ring (jitter budget is 0.4 m)"
				% [site_seed, worst])

		# Everything must fit inside the def's 30 m clearance, or the circle overlaps whatever the
		# spacing rules were protecting.
		var furthest: float = 0.0
		for piece: Dictionary in pieces:
			var offset: Vector3 = piece.get("offset", Vector3.ZERO)
			furthest = maxf(furthest, Vector2(offset.x, offset.z).length())
		check(furthest <= 30.0,
			"seed %d furthest piece is %.2f m out, inside the def's 30 m clearance"
				% [site_seed, furthest])


# ── 4 · the spread contains ordinary circles ──────────────────────────────────────────────────────


func _check_spread() -> void:
	print("\n== across many sites, most circles are plain ==")
	var sites: int = 200
	var with_outlier: int = 0
	var with_centre: int = 0
	var with_fallen: int = 0
	for i: int in sites:
		var pieces: Array = StoneCircleScript.pieces_for_site(0x5747E + i * 7919)
		var outlier: bool = false
		var centre: bool = false
		var fallen: bool = false
		for piece: Dictionary in pieces:
			if String(piece.get("asset", "")) == StoneCircleScript.OUTLIER_ASSET:
				outlier = true
			if float(piece.get("lying_radius", 0.0)) > 0.0:
				fallen = true
			var offset: Vector3 = piece.get("offset", Vector3.ZERO)
			if Vector2(offset.x, offset.z).length() < 2.0:
				centre = true
		with_outlier += 1 if outlier else 0
		with_centre += 1 if centre else 0
		with_fallen += 1 if fallen else 0

	# The point of this subtest is the memory of every generated feature that applied its new trick
	# to 100% of instances. A centre feature on every circle is not variety, it is a new default.
	check(with_centre > 0 and with_centre < sites / 2,
		"centre feature on %d/%d sites — a minority, so a plain ring is still the ordinary case"
			% [with_centre, sites])
	check(with_outlier > 0 and with_outlier < sites,
		"outlier monolith on %d/%d sites — present but not universal" % [with_outlier, sites])
	check(with_fallen > 0 and with_fallen < sites,
		"at least one fallen stone on %d/%d sites" % [with_fallen, sites])


# ── 5 · a real island actually builds them ────────────────────────────────────────────────────────


func _check_world_builds_them() -> void:
	print("\n== a booted ProceduralWorld builds pieces at the standing_stones sites ==")
	var packed: PackedScene = load("res://levels/procedural_island.tscn") as PackedScene
	check(packed != null, "levels/procedural_island.tscn loads")
	if packed == null:
		return
	var world: Node = packed.instantiate()
	root.add_child(world)
	for _i: int in 12:
		await process_frame

	# Every structure piece is tagged with its kit and asset by PoiStructures.build(), so the
	# megaliths are countable without knowing how the world names its site roots.
	var megaliths: int = 0
	var found: Array[Node] = []
	_collect_assets(world, found)
	for node: Node in found:
		var asset := String(node.get_meta(&"asset", ""))
		if asset.begins_with("standing_stone") or asset.begins_with("stone_marker"):
			megaliths += 1
	check(megaliths > 0,
		"THE FINDING: %d megalith pieces stand on the island (was 0 — six empty Node3Ds)"
			% megaliths)
	# Six sites at nine-plus stones each, minus the missing ones. Well under this would mean only
	# some sites built.
	check(megaliths >= 30,
		"%d pieces is consistent with six circles building, not one" % megaliths)
	world.queue_free()
	await process_frame


func _collect_assets(node: Node, out: Array[Node]) -> void:
	if node.has_meta(&"asset"):
		out.append(node)
	for child: Node in node.get_children():
		_collect_assets(child, out)


# ── helpers ───────────────────────────────────────────────────────────────────────────────────────


## Rounded so the comparison is about the layout, not about float formatting.
func _fingerprint(pieces: Array) -> String:
	var parts: PackedStringArray = []
	for piece: Dictionary in pieces:
		var offset: Vector3 = piece.get("offset", Vector3.ZERO)
		parts.append("%s|%.4f,%.4f|%.4f|%.4f" % [
			String(piece.get("asset", "")), offset.x, offset.z,
			float(piece.get("yaw", 0.0)), float(piece.get("scale", 1.0)),
		])
	return "/".join(parts)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		failures += 1
		print("FAIL: %s" % description)
