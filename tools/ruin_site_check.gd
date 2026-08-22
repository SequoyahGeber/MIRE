extends SceneTree

## F-493 — procedural islands actually contain ruins, and a ruin is a building rather than a pile.
##
## Checks the pure layout (deterministic, varied, made of the pieces the kit ships, standing on its
## own rectangle) and then builds real sites through `PoiStructures` to prove the pieces reach a
## world with collision on them.
##
##   .agent/bin/agent godot --script tools/ruin_site_check.gd

const RuinSite := preload("res://world/gen/ruin_site.gd")
const PoiStructures := preload("res://world/gen/poi_structures.gd")

const SEEDS: Array[int] = [11, 4242, 20260821, 90210, 7]

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	_check_layout()
	_check_variation()
	_check_build()
	_check_content()
	print("RUIN_SITE_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_layout() -> void:
	print("== the layout is a building ==")
	var assets_seen: Dictionary = {}
	for site_seed: int in SEEDS:
		var pieces: Array[Dictionary] = RuinSite.pieces_for_site(site_seed)
		check(pieces.size() >= 6, "seed %d lays out %d piece(s)" % [site_seed, pieces.size()])
		var standing: int = 0
		var walls: int = 0
		var within: bool = true
		for piece: Dictionary in pieces:
			assets_seen[piece["asset"]] = true
			if String(piece["asset"]).begins_with("ruin_wall"):
				walls += 1
			if not piece.has("lying_radius"):
				standing += 1
			var offset: Vector3 = piece["offset"]
			# Everything belongs to one footprint. A piece 30 m away is not part of the building.
			if absf(offset.x) > 12.0 or absf(offset.z) > 12.0:
				within = false
		check(standing >= 3, "seed %d leaves %d piece(s) standing" % [site_seed, standing])
		check(walls >= 2, "seed %d keeps %d wall segment(s)" % [site_seed, walls])
		check(within, "seed %d keeps every piece inside the hall's footprint" % site_seed)

	# Deterministic: same seed, same ruin, on every peer and after a rejoin.
	var a: Array[Dictionary] = RuinSite.pieces_for_site(4242)
	var b: Array[Dictionary] = RuinSite.pieces_for_site(4242)
	check(str(a) == str(b), "the same site seed lays out the identical ruin twice")


func _check_variation() -> void:
	print("\n== no two ruins are the same building ==")
	var shapes: Dictionary = {}
	for site_seed: int in range(40):
		shapes[str(RuinSite.pieces_for_site(site_seed * 7919))] = true
	check(shapes.size() >= 38, "40 seeds produce %d distinct ruins" % shapes.size())

	# Every piece the kit ships must be reachable, or the arrangement is quietly ignoring art.
	var used: Dictionary = {}
	for site_seed: int in range(200):
		for piece: Dictionary in RuinSite.pieces_for_site(site_seed * 131):
			used[String(piece["asset"])] = true
	for asset: String in [
		"ruin_wall_a", "ruin_wall_b", "ruin_wall_c", "ruin_wall_d",
		"ruin_column_a", "ruin_column_b", "ruin_column_c", "ruin_column_d",
		"ruin_arch_a", "ruin_arch_b",
	]:
		check(used.has(asset), "%s appears across 200 sites" % asset)


func _check_build() -> void:
	print("\n== a built ruin has meshes and collision on the ground ==")
	var scene := Node3D.new()
	scene.name = "RuinCheckScene"
	root.add_child(scene)
	var site_root := Node3D.new()
	site_root.name = "ruins_00"
	scene.add_child(site_root)
	site_root.global_position = Vector3(120.0, 12.0, -80.0)
	site_root.rotation.y = 0.8

	var ground := func(_x: float, _z: float) -> float: return 12.0
	var built: int = PoiStructures.build(site_root, &"ruins", 4242, ground)
	check(built > 0, "built %d piece(s)" % built)
	check(site_root.get_child_count() == built, "every piece became a node")

	var with_mesh: int = 0
	var with_body: int = 0
	var on_ground: bool = true
	for child: Node in site_root.get_children():
		var holder := child as Node3D
		var visual: Node = holder.get_node_or_null(^"Visual")
		if visual != null and visual.get_child_count() > 0:
			with_mesh += 1
		if holder.get_node_or_null(^"CollisionBody") != null:
			with_body += 1
		# Nothing floats and nothing is buried. A standing piece sinks up to 0.3 m into the turf; a
		# piece lying on its side is lifted by half its own thickness (a wall) or its shaft radius
		# (a column), which is at most 0.55 m — so this band is the whole legitimate range.
		var above: float = holder.global_position.y - 12.0
		if above < -0.35 or above > 0.6:
			on_ground = false
	check(with_mesh == built, "%d/%d piece(s) carry mesh geometry" % [with_mesh, built])
	check(with_body == built, "%d/%d piece(s) carry collision — masonry is solid" % [with_body, built])
	check(on_ground, "every piece sits on the surface it was placed on")

	check(PoiStructures.build(site_root, &"not_a_structure", 1, ground) == 0,
		"an unknown structure id builds nothing rather than erroring")
	scene.queue_free()


func _check_content() -> void:
	print("\n== the content wires it up ==")
	var registry: Node = root.get_node_or_null(^"Registry")
	if registry == null:
		fail("Registry autoload is missing")
		return
	var pois: Dictionary = registry.get(&"poi")
	var def: Resource = pois.get(&"ruins", null)
	check(def != null, "content/poi/ruins.tres is registered")
	if def == null:
		return
	check(StringName(String(def.get(&"structure_id"))) == &"ruins",
		"it names the ruins structure")
	check(PoiStructures.has_structure(StringName(String(def.get(&"structure_id")))),
		"and PoiStructures knows how to build that")
	check(int(def.get(&"target_count")) > 0, "it asks for %d site(s) an island" % int(def.get(&"target_count")))


func check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		fail(label)


func fail(label: String) -> void:
	failures += 1
	print("  FAIL  %s" % label)
