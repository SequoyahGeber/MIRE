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
	check(scene.get_node_or_null(^"Player") != null, "player exists at the camp spawn")
	_check_atmosphere(scene)
	if runtime == null:
		finish()
		return

	var zones := get_nodes_in_group(&"playtest_hollow_zone")
	var props := get_nodes_in_group(&"playtest_hollow_asset")
	var colliders := get_nodes_in_group(&"playtest_hollow_collider")
	var terrain := get_nodes_in_group(&"playtest_hollow_terrain")
	var markers := get_nodes_in_group(&"playtest_hollow_marker")
	check(zones.size() == 6, "exactly six collision zones (%d)" % zones.size())
	check(props.size() == 463, "all 463 prop records consumed (%d)" % props.size())
	check(terrain.size() == 20, "all 20 colliding terrain records consumed (%d)" % terrain.size())
	check(colliders.size() == 274, "254 prop shapes plus 20 terrain shapes built (%d)" % colliders.size())
	check(markers.size() == 1, "enemy spawn marker built (%d)" % markers.size())
	for zone_name: String in EXPECTED_ZONES:
		check(
			runtime.get_node_or_null(NodePath("CollisionZones/%s" % zone_name)) != null,
			"collision zone exists: %s" % zone_name
		)

	var visual_root := scene.get_node_or_null(^"AuthoredVisuals")
	var visual_meshes := _count_meshes(visual_root)
	check(visual_meshes >= 1000, "authored visual contains at least 1000 meshes (%d)" % visual_meshes)
	_check_layout_file(visual_root)
	print(
		"PLAYTEST_HOLLOW_CHECK zones=%d props=%d terrain=%d colliders=%d visuals=%d failures=%d"
		% [zones.size(), props.size(), terrain.size(), colliders.size(), visual_meshes, failures]
	)
	finish()


func _check_layout_file(visual_root: Node) -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_PATH))
	check(parsed is Dictionary, "shared layout JSON parses")
	if not parsed is Dictionary:
		return
	var layout := parsed as Dictionary
	check(int(layout.get("seed", 0)) == 20260817, "layout seed is frozen")
	check(float(layout.get("bound", 0.0)) == 34.0, "closed hollow boundary is 34m")
	var props: Array = layout.get("props", []) as Array
	var terrain: Array = layout.get("terrain", []) as Array
	check(props.size() == 463, "layout contains 463 props")
	check(terrain.size() == 26, "layout contains 26 terrain records")
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


func _check_atmosphere(scene: Node3D) -> void:
	var world_environment := scene.get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	var sun := scene.get_node_or_null(^"Sun") as DirectionalLight3D
	var atmosphere := scene.get_node_or_null(^"Atmosphere")
	var mire_fog := scene.get_node_or_null(^"MireGroundFog") as FogVolume
	check(world_environment != null and world_environment.environment != null, "atmosphere environment exists")
	check(sun != null and sun.shadow_enabled, "shadow-casting sun exists")
	check(atmosphere != null and atmosphere.has_method("set_time_of_day"), "time-of-day controller exists")
	check(mire_fog != null and mire_fog.material is FogMaterial, "localized Mire fog volume exists")
	if world_environment == null or world_environment.environment == null or sun == null:
		return
	var environment := world_environment.environment
	check(environment.sky != null and environment.sky.sky_material is PhysicalSkyMaterial, "physical sky is active")
	check(environment.fog_enabled, "distance fog is enabled")
	check(environment.volumetric_fog_enabled, "volumetric fog is enabled")
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
