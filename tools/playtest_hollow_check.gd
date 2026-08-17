extends SceneTree

## Headless structural proof for the shared-layout playtest scene.

const SCENE_PATH: String = "res://levels/playtest_hollow.tscn"
const LAYOUT_PATH: String = "res://world/gen/layouts/playtest_hollow.json"
const EXPECTED_ZONES := [
	"SpawnCamp",
	"WestForest",
	"NorthRuins",
	"EastMire",
	"SouthRidge",
	"RoutesAndBoundary",
]

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	check(packed != null, "playtest_hollow scene loads")
	if packed == null:
		quit(1)
		return
	var scene := packed.instantiate() as Node3D
	check(scene != null, "playtest_hollow instantiates as Node3D")
	if scene == null:
		quit(1)
		return
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 8:
		await process_frame

	var runtime := scene.get_node_or_null(^"LayoutRuntime") as Node3D
	check(runtime != null, "layout runtime exists")
	check(scene.get_node_or_null(^"AuthoredVisuals") != null, "authored GLB exists")
	var player := scene.get_node_or_null(^"Player") as Node3D
	check(player != null, "player exists at the camp spawn")
	_check_atmosphere(scene)
	if runtime == null:
		finish()
		return
	var layout := _load_layout()
	if layout.is_empty():
		finish()
		return
	var layout_props: Array = layout.get("props", []) as Array
	var layout_terrain: Array = layout.get("terrain", []) as Array
	var expected_terrain: int = 0
	var expected_colliders: int = 0
	for terrain_value: Variant in layout_terrain:
		if bool((terrain_value as Dictionary).get("collide", false)):
			expected_terrain += 1
			expected_colliders += 1
	for prop_value: Variant in layout_props:
		expected_colliders += ((prop_value as Dictionary).get("cols", []) as Array).size()
	if player != null:
		var expected_spawn := _vector3((layout.get("spawn", {}) as Dictionary).get("pos", []))
		check(
			Vector2(player.position.x, player.position.z).distance_to(Vector2(expected_spawn.x, expected_spawn.z)) < 0.01,
			"scene player matches the shared horizontal spawn record"
		)
		_check_gate_egress(scene, player)

	var zones := get_nodes_in_group(&"playtest_hollow_zone")
	var props := get_nodes_in_group(&"playtest_hollow_asset")
	var colliders := get_nodes_in_group(&"playtest_hollow_collider")
	var terrain := get_nodes_in_group(&"playtest_hollow_terrain")
	var markers := get_nodes_in_group(&"playtest_hollow_marker")
	check(zones.size() == 6, "exactly six collision zones (%d)" % zones.size())
	check(props.size() == layout_props.size(), "all prop records consumed (%d)" % props.size())
	check(terrain.size() == expected_terrain, "all colliding terrain records consumed (%d)" % terrain.size())
	check(colliders.size() == expected_colliders, "all terrain and prop shapes built (%d)" % colliders.size())
	check(markers.size() == 1, "enemy spawn marker built (%d)" % markers.size())
	for zone_name: String in EXPECTED_ZONES:
		check(
			runtime.get_node_or_null(NodePath("CollisionZones/%s" % zone_name)) != null,
			"collision zone exists: %s" % zone_name
		)

	var visual_root := scene.get_node_or_null(^"AuthoredVisuals")
	var visual_meshes := _count_meshes(visual_root)
	check(visual_meshes >= 1000, "authored visual contains at least 1000 meshes (%d)" % visual_meshes)
	_check_layout_file(visual_root, layout)
	print(
		"PLAYTEST_HOLLOW_CHECK zones=%d props=%d terrain=%d colliders=%d visuals=%d failures=%d"
		% [zones.size(), props.size(), terrain.size(), colliders.size(), visual_meshes, failures]
	)
	finish()


func _load_layout() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_PATH))
	check(parsed is Dictionary, "shared layout JSON parses")
	return parsed as Dictionary if parsed is Dictionary else {}


func _check_layout_file(visual_root: Node, layout: Dictionary) -> void:
	check(int(layout.get("seed", 0)) == 20260817, "layout seed is frozen")
	check(float(layout.get("bound", 0.0)) == 44.0, "closed hollow boundary is 44m")
	var props: Array = layout.get("props", []) as Array
	var terrain: Array = layout.get("terrain", []) as Array
	check(props.size() >= 700, "enlarged layout contains at least 700 props (%d)" % props.size())
	check(terrain.size() >= 30, "layout contains transition terrain and trails (%d)" % terrain.size())
	_check_open_gates_and_grass(props)
	var aligned_visuals: int = 0
	var visual_alignment_examples: Array[String] = []
	for index: int in props.size():
		var prop := props[index] as Dictionary
		var expected_name := "Placed_%03d_%s" % [index, String(prop.get("asset", "Prop"))]
		var visual := visual_root.find_child(expected_name, true, false) as Node3D
		if visual != null and visual.global_position.distance_to(_vector3(prop.get("pos", []))) < 0.01:
			aligned_visuals += 1
		elif visual_alignment_examples.size() < 5:
			visual_alignment_examples.append(
				"%s missing" % expected_name if visual == null else "%s delta=%.3f" % [
					expected_name,
					visual.global_position.distance_to(_vector3(prop.get("pos", []))),
				]
			)
	check(aligned_visuals == props.size(), "all visual prop origins match the shared layout (%d)" % aligned_visuals)
	if not visual_alignment_examples.is_empty():
		print("PLAYTEST_HOLLOW_ALIGNMENT " + " | ".join(visual_alignment_examples))
	var steep_ramps: int = 0
	for terrain_value: Variant in terrain:
		var record := terrain_value as Dictionary
		if absf(float(record.get("tilt", 0.0))) > deg_to_rad(40.0):
			steep_ramps += 1
	check(steep_ramps == 0, "no terrain ramp exceeds 40 degrees")


func _check_open_gates_and_grass(props: Array) -> void:
	var gates: int = 0
	var blocked_gates: int = 0
	var grass_count: int = 0
	var grass_assets: Dictionary = {}
	for prop_value: Variant in props:
		var prop := prop_value as Dictionary
		var asset := String(prop.get("asset", ""))
		if asset.begins_with("grass_"):
			grass_count += 1
			grass_assets[asset] = true
		if asset != "fence_gate":
			continue
		gates += 1
		for shape_value: Variant in prop.get("cols", []):
			var shape := shape_value as Dictionary
			if String(shape.get("t", "")) != "box":
				continue
			var size := _vector3(shape.get("size", []))
			var offset := _vector3(shape.get("off", []))
			if absf(offset.x) - size.x * 0.5 < 0.9:
				blocked_gates += 1
	check(gates == 4, "spawn camp has four gates (%d)" % gates)
	check(blocked_gates == 0, "every gate leaves a 1.8m clear centre passage")
	check(grass_count >= 220, "map uses at least 220 grass placements (%d)" % grass_count)
	check(grass_assets.size() >= 14, "map uses at least 14 grass variants (%d)" % grass_assets.size())


func _check_gate_egress(scene: Node3D, player: Node3D) -> void:
	var world := scene.get_world_3d()
	check(world != null, "playtest hollow has a physics world")
	if world == null:
		return
	var rays := {
		"north": [Vector3(0.0, 1.0, -4.0), Vector3(0.0, 1.0, -12.0)],
		"south": [Vector3(0.0, 1.0, 7.4), Vector3(0.0, 1.0, 16.0)],
		"west": [Vector3(-4.0, 1.0, 2.1), Vector3(-14.0, 1.0, 2.1)],
		"east": [Vector3(4.0, 1.0, 2.1), Vector3(14.0, 1.0, 2.1)],
	}
	for direction: String in rays:
		var endpoints: Array = rays[direction] as Array
		var query := PhysicsRayQueryParameters3D.create(endpoints[0] as Vector3, endpoints[1] as Vector3)
		if player is CollisionObject3D:
			query.exclude = [(player as CollisionObject3D).get_rid()]
		var hit := world.direct_space_state.intersect_ray(query)
		check(hit.is_empty(), "%s spawn-camp gate has a clear physical egress" % direction)


func _check_atmosphere(scene: Node3D) -> void:
	var world_environment := scene.get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	var sun := scene.get_node_or_null(^"Sun") as DirectionalLight3D
	var atmosphere := scene.get_node_or_null(^"Atmosphere")
	var fog_volumes: Array[FogVolume] = []
	for fog_path: NodePath in [^"MireGroundFog", ^"ForestMist", ^"RuinsMist"]:
		var volume := scene.get_node_or_null(fog_path) as FogVolume
		if volume != null:
			fog_volumes.append(volume)
	var cloud_deck := scene.get_node_or_null(^"CloudDeck") as Node3D
	check(world_environment != null and world_environment.environment != null, "atmosphere environment exists")
	check(sun != null and sun.shadow_enabled, "shadow-casting sun exists")
	check(atmosphere != null and atmosphere.has_method("set_time_of_day"), "time-of-day controller exists")
	check(fog_volumes.size() == 3, "three localized fog pockets exist")
	check(
		fog_volumes.all(func(volume: FogVolume) -> bool: return volume.material is FogMaterial),
		"all fog pockets have local FogMaterials"
	)
	check(
		fog_volumes.all(func(volume: FogVolume) -> bool: return (volume.material as FogMaterial).density >= 0.05),
		"localized fog is dense enough to remain visible"
	)
	var cloud_clusters := get_nodes_in_group(&"low_poly_cloud")
	var cloud_puffs := get_nodes_in_group(&"low_poly_cloud_puff")
	check(
		cloud_deck != null and cloud_deck.has_method("rebuild_clouds"),
		"faceted cloud field controller exists"
	)
	check(cloud_clusters.size() == 12, "twelve low-poly cloud clusters exist (%d)" % cloud_clusters.size())
	check(cloud_puffs.size() >= 84, "cloud field contains at least 84 overlapping mesh puffs (%d)" % cloud_puffs.size())
	if not cloud_puffs.is_empty():
		var first_puff := cloud_puffs[0] as MeshInstance3D
		check(
			first_puff != null and first_puff.mesh is ArrayMesh
			and first_puff.get_active_material(0) is StandardMaterial3D,
			"cloud puffs use faceted geometry and a standard material"
		)
	if world_environment == null or world_environment.environment == null or sun == null:
		return
	var environment := world_environment.environment
	check(environment.sky != null and environment.sky.sky_material is PhysicalSkyMaterial, "physical sky is active")
	check(not environment.fog_enabled, "blanket distance fog is disabled")
	check(environment.volumetric_fog_enabled, "volumetric fog is enabled")
	check(environment.volumetric_fog_density <= 0.001, "global volumetric haze stays nearly clear")
	check(environment.volumetric_fog_anisotropy >= 0.65, "fog is directional enough for light shafts")
	check(sun.light_volumetric_fog_energy >= 0.8, "sun injects energy into volumetric fog")
	check(sun.directional_shadow_max_distance >= 68.0, "sun shadows cover the playable hollow")
	if atmosphere != null:
		var morning_energy := sun.light_energy
		atmosphere.call("set_time_of_day", 19.0)
		check(not is_equal_approx(sun.light_energy, morning_energy), "time-of-day updates sun energy")
		atmosphere.call("set_time_of_day", 8.35)


func _count_meshes(node: Node) -> int:
	if node == null:
		return 0
	var count: int = 1 if node is MeshInstance3D else 0
	for child: Node in node.get_children():
		count += _count_meshes(child)
	return count


func _vector3(value: Variant) -> Vector3:
	var values := value as Array
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
