extends Node

## Loads the authored Blender playtest map and adds gameplay collision.
##
## The visible layout lives in assets/source/playtest_map.blend and exports as one GLB. This script
## does not choose or scatter visible prop positions. Static map presentation/collision is
## client-local; future harvesting, construction, damage, and mutation remain host-authoritative.
## Only activates for GreyboxTest and never edits the human-owned .tscn file.

const GREYBOX_SCENE_NAME: String = "GreyboxTest"
const AUTHORED_MAP_PATH: String = "res://assets/maps/playtest_map.glb"
const PLAYTEST_SEED: int = 20260816

const ASSET_GROUP: StringName = &"playtest_asset"
const VISUAL_GROUP: StringName = &"playtest_visual"
const COLLIDER_GROUP: StringName = &"playtest_collider"
const ZONE_GROUP: StringName = &"playtest_zone"

const PINE_ASSETS := ["tree_pine_a", "tree_pine_b", "tree_pine_c", "tree_pine_d", "tree_pine_e", "tree_pine_f"]
const BIRCH_ASSETS := ["tree_birch_a", "tree_birch_b", "tree_birch_c", "tree_birch_d"]
const CROOKED_ASSETS := ["tree_crooked_a", "tree_crooked_b", "tree_crooked_c", "tree_crooked_d"]
const BARE_ASSETS := ["tree_bare_a", "tree_bare_b", "tree_bare_c", "tree_bare_d"]
const BOULDER_ASSETS := ["boulder_a", "boulder_b", "boulder_c", "boulder_d", "boulder_e", "boulder_f", "boulder_g", "boulder_h"]
const GRASS_ASSETS := ["grass_clump_a", "grass_clump_b", "grass_clump_c", "grass_clump_d", "grass_clump_e", "grass_clump_f"]
const FERN_ASSETS := ["fern_a", "fern_b", "fern_c", "fern_d", "fern_e", "fern_f"]
const MUSHROOM_ASSETS := ["mushroom_cluster_a", "mushroom_cluster_b", "mushroom_cluster_c", "mushroom_cluster_d", "mushroom_cluster_e", "mushroom_cluster_f"]
const CRYSTAL_ASSETS := ["mire_crystal_a", "mire_crystal_b", "mire_crystal_c", "mire_crystal_d", "mire_crystal_e", "mire_crystal_f"]
const TENDRIL_ASSETS := ["mire_tendril_a", "mire_tendril_b", "mire_tendril_c", "mire_tendril_d"]

var _spawned_asset_count: int = 0
var _visual_mesh_count: int = 0
var _collision_shape_count: int = 0


func _ready() -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.name != GREYBOX_SCENE_NAME:
		return
	if scene.get_node_or_null("PlaytestMap") != null:
		return

	_remove_old_greybox_obstacles(scene)
	_hide_greybox_ground_visual(scene)

	var map_root := Node3D.new()
	map_root.name = "PlaytestMap"
	scene.add_child(map_root)
	var authored_map := _load_authored_map()
	if authored_map != null:
		authored_map.name = "AuthoredVisuals"
		map_root.add_child(authored_map)
		_visual_mesh_count = _tag_visual_meshes(authored_map)

	# Collision stays separate from the visual source so it can become gameplay-aware later.
	var rng := RandomNumberGenerator.new()
	rng.seed = PLAYTEST_SEED
	_build_spawn_camp(_zone(map_root, "SpawnCamp"), rng)
	_build_west_forest(_zone(map_root, "WestForest"), rng)
	_build_north_ruins(_zone(map_root, "NorthRuins"), rng)
	_build_east_mire(_zone(map_root, "EastMire"), rng)
	_build_south_ridge(_zone(map_root, "SouthRidge"), rng)
	_build_routes_and_boundary(_zone(map_root, "RoutesAndBoundary"), rng)

	print(
		"world: PlaytestMap loaded authored GLB with %d meshes; built %d collision markers and %d shapes"
		% [_visual_mesh_count, _spawned_asset_count, _collision_shape_count]
	)


func _remove_old_greybox_obstacles(scene: Node) -> void:
	for path: NodePath in [^"Ramps", ^"Stairs", ^"Gaps", ^"Walls"]:
		var old_node := scene.get_node_or_null(path)
		if old_node != null:
			old_node.queue_free()


func _hide_greybox_ground_visual(scene: Node) -> void:
	var ground_mesh := scene.get_node_or_null(^"Ground/Mesh") as MeshInstance3D
	if ground_mesh == null:
		return
	ground_mesh.visible = false


func _zone(parent: Node3D, zone_name: String) -> Node3D:
	var zone := Node3D.new()
	zone.name = zone_name
	zone.add_to_group(ZONE_GROUP)
	parent.add_child(zone)
	return zone


func _load_authored_map() -> Node3D:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var import_error: Error = document.append_from_file(
		ProjectSettings.globalize_path(AUTHORED_MAP_PATH), state
	)
	if import_error != OK:
		push_error(
			"PlaytestMap could not read authored map %s: %s"
			% [AUTHORED_MAP_PATH, error_string(import_error)]
		)
		return null
	var generated := document.generate_scene(state) as Node3D
	if generated == null:
		push_error("PlaytestMap authored map root is not Node3D: %s" % AUTHORED_MAP_PATH)
	return generated


func _tag_visual_meshes(node: Node) -> int:
	var count: int = 0
	if node is MeshInstance3D:
		node.add_to_group(VISUAL_GROUP)
		count += 1
	for child: Node in node.get_children():
		count += _tag_visual_meshes(child)
	return count


func _spawn_asset(
	parent: Node3D,
	asset_id: String,
	position: Vector3,
	yaw: float = 0.0,
	scale_value: float = 1.0
) -> Node3D:
	var holder := Node3D.new()
	holder.name = "%s_%03d" % [asset_id, _spawned_asset_count]
	holder.position = position
	holder.rotation.y = yaw
	holder.scale = Vector3.ONE * scale_value
	holder.add_to_group(ASSET_GROUP)
	parent.add_child(holder)
	_spawned_asset_count += 1
	return holder


func _collision_body(holder: Node3D) -> StaticBody3D:
	var existing := holder.get_node_or_null(^"CollisionBody") as StaticBody3D
	if existing != null:
		return existing
	var body := StaticBody3D.new()
	body.name = "CollisionBody"
	holder.add_child(body)
	return body


func _add_box_collider(
	holder: Node3D,
	size: Vector3,
	offset: Vector3,
	rotation: Vector3 = Vector3.ZERO
) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.name = "Collision_%02d" % _collision_shape_count
	collision.shape = shape
	collision.position = offset
	collision.rotation = rotation
	collision.add_to_group(COLLIDER_GROUP)
	_collision_body(holder).add_child(collision)
	_collision_shape_count += 1


func _add_cylinder_collider(holder: Node3D, radius: float, height: float, y_offset: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var collision := CollisionShape3D.new()
	collision.name = "Collision_%02d" % _collision_shape_count
	collision.shape = shape
	collision.position.y = y_offset
	collision.add_to_group(COLLIDER_GROUP)
	_collision_body(holder).add_child(collision)
	_collision_shape_count += 1


func _spawn_tree(parent: Node3D, asset_id: String, flat: Vector2, yaw: float) -> void:
	var holder := _spawn_asset(parent, asset_id, Vector3(flat.x, 0.0, flat.y), yaw)
	_add_cylinder_collider(holder, 0.42, 3.6, 1.8)


func _spawn_boulder(parent: Node3D, asset_id: String, flat: Vector2, yaw: float) -> void:
	var holder := _spawn_asset(parent, asset_id, Vector3(flat.x, 0.0, flat.y), yaw)
	_add_box_collider(holder, Vector3(2.25, 1.35, 1.85), Vector3(0.0, 0.68, 0.0))


func _spawn_ruin_wall(parent: Node3D, asset_id: String, position: Vector3, yaw: float) -> void:
	var holder := _spawn_asset(parent, asset_id, position, yaw)
	_add_box_collider(holder, Vector3(4.0, 2.35, 0.62), Vector3(0.0, 1.18, 0.0))


func _spawn_ruin_arch(parent: Node3D, asset_id: String, position: Vector3, yaw: float) -> void:
	var holder := _spawn_asset(parent, asset_id, position, yaw)
	_add_box_collider(holder, Vector3(0.8, 3.1, 0.75), Vector3(-1.35, 1.55, 0.0))
	_add_box_collider(holder, Vector3(0.8, 3.1, 0.75), Vector3(1.35, 1.55, 0.0))
	_add_box_collider(holder, Vector3(2.1, 0.65, 0.75), Vector3(0.0, 2.92, 0.0))


func _spawn_building_piece(parent: Node3D, asset_id: String, position: Vector3, yaw: float = 0.0) -> Node3D:
	var holder := _spawn_asset(parent, asset_id, position, yaw)
	match asset_id:
		"wood_foundation":
			_add_box_collider(holder, Vector3(4.0, 0.4, 4.0), Vector3(0.0, 0.2, 0.0))
		"wood_floor", "stone_floor":
			_add_box_collider(holder, Vector3(4.0, 0.24, 4.0), Vector3(0.0, 0.12, 0.0))
		"stone_foundation":
			_add_box_collider(holder, Vector3(3.94, 0.72, 3.94), Vector3(0.0, 0.36, 0.0))
		"wood_wall_solid", "stone_wall_solid":
			_add_box_collider(holder, Vector3(4.05, 3.0, 0.44), Vector3(0.0, 1.5, 0.0))
		"wood_half_wall", "stone_half_wall":
			_add_box_collider(holder, Vector3(4.05, 1.6, 0.44), Vector3(0.0, 0.8, 0.0))
		"wood_wall_window", "stone_wall_window":
			_add_box_collider(holder, Vector3(1.05, 3.0, 0.48), Vector3(-1.48, 1.5, 0.0))
			_add_box_collider(holder, Vector3(1.05, 3.0, 0.48), Vector3(1.48, 1.5, 0.0))
			_add_box_collider(holder, Vector3(1.95, 0.86, 0.48), Vector3(0.0, 0.43, 0.0))
			_add_box_collider(holder, Vector3(1.95, 0.52, 0.48), Vector3(0.0, 2.74, 0.0))
		"wood_wall_door", "stone_wall_door":
			_add_box_collider(holder, Vector3(1.05, 3.0, 0.5), Vector3(-1.48, 1.5, 0.0))
			_add_box_collider(holder, Vector3(1.05, 3.0, 0.5), Vector3(1.48, 1.5, 0.0))
			_add_box_collider(holder, Vector3(1.95, 0.42, 0.5), Vector3(0.0, 2.79, 0.0))
		"wood_stairs", "stone_stairs":
			for index: int in 8:
				_add_box_collider(
					holder,
					Vector3(2.05, 0.38, 0.54),
					Vector3(0.0, 0.19 + index * 0.2, 1.75 - index * 0.5)
				)
		"wood_post":
			_add_box_collider(holder, Vector3(0.62, 3.0, 0.62), Vector3(0.0, 1.5, 0.0))
		"stone_pillar":
			_add_box_collider(holder, Vector3(0.9, 3.15, 0.9), Vector3(0.0, 1.575, 0.0))
		"wood_railing":
			_add_box_collider(holder, Vector3(4.1, 1.27, 0.24), Vector3(0.0, 0.635, 0.0))
		"fence_straight", "fence_corner", "fence_gate":
			_add_box_collider(holder, Vector3(4.2, 1.55, 0.28), Vector3(0.0, 0.775, 0.0))
		"fence_post":
			_add_box_collider(holder, Vector3(0.56, 2.18, 0.56), Vector3(0.0, 1.09, 0.0))
	return holder


func _random_asset(rng: RandomNumberGenerator, assets: Array) -> String:
	return assets[rng.randi_range(0, assets.size() - 1)] as String


func _build_spawn_camp(zone: Node3D, rng: RandomNumberGenerator) -> void:
	# A small roofed cabin west of spawn, with a second open work platform east.
	_spawn_building_piece(zone, "wood_foundation", Vector3(-6.0, 0.0, 8.0))
	_spawn_building_piece(zone, "wood_floor", Vector3(-6.0, 0.4, 8.0))
	_spawn_building_piece(zone, "wood_wall_solid", Vector3(-6.0, 0.4, 6.0))
	_spawn_building_piece(zone, "wood_wall_window", Vector3(-8.0, 0.4, 8.0), PI * 0.5)
	_spawn_building_piece(zone, "wood_wall_solid", Vector3(-4.0, 0.4, 8.0), PI * 0.5)
	_spawn_building_piece(zone, "wood_wall_door", Vector3(-6.0, 0.4, 10.0))
	_spawn_asset(zone, "wood_roof_corner", Vector3(-6.0, 3.4, 8.0))

	_spawn_building_piece(zone, "wood_foundation", Vector3(5.0, 0.0, 9.0))
	_spawn_building_piece(zone, "wood_floor", Vector3(5.0, 0.4, 9.0))
	_spawn_building_piece(zone, "wood_half_wall", Vector3(5.0, 0.4, 7.0))
	_spawn_building_piece(zone, "wood_railing", Vector3(3.0, 0.4, 9.0), PI * 0.5)
	_spawn_building_piece(zone, "wood_railing", Vector3(7.0, 0.4, 9.0), PI * 0.5)

	for x: float in [-8.0, -4.0, 4.0, 8.0]:
		_spawn_building_piece(zone, "fence_straight", Vector3(x, 0.0, 14.0))
	_spawn_building_piece(zone, "fence_gate", Vector3(0.0, 0.0, 14.0))
	for z: float in [5.0, 9.0, 13.0]:
		_spawn_building_piece(zone, "fence_straight", Vector3(-10.0, 0.0, z), PI * 0.5)
		_spawn_building_piece(zone, "fence_straight", Vector3(10.0, 0.0, z), PI * 0.5)

	_spawn_asset(zone, "fallen_log_a", Vector3(2.4, 0.0, 5.0), -0.25)
	_spawn_asset(zone, "stump_b", Vector3(0.0, 0.0, 4.0), 0.4)
	_add_box_collider(_spawn_asset(zone, "station_workbench_primitive", Vector3(5.0, 0.65, 8.1), PI), Vector3(2.1, 1.25, 0.9), Vector3(0.0, 0.625, 0.0))
	_add_box_collider(_spawn_asset(zone, "station_repair_bench", Vector3(5.0, 0.65, 9.8)), Vector3(2.2, 1.6, 0.95), Vector3(0.0, 0.8, 0.0))
	_add_cylinder_collider(_spawn_asset(zone, "station_campfire", Vector3(0.0, 0.0, 7.0)), 0.8, 0.75, 0.375)
	_add_box_collider(_spawn_asset(zone, "station_cooking_spit", Vector3(0.0, 0.0, 4.5), PI * 0.5), Vector3(2.3, 1.75, 1.65), Vector3(0.0, 0.875, 0.0))
	_add_box_collider(_spawn_asset(zone, "station_woodcutting_block", Vector3(-1.8, 0.0, 4.0), -0.35), Vector3(2.1, 1.2, 1.3), Vector3(0.0, 0.6, 0.0))
	for i: int in 10:
		var flat := Vector2(rng.randf_range(-9.0, 9.0), rng.randf_range(3.0, 13.0))
		if flat.distance_to(Vector2(0.0, 8.0)) > 3.2:
			_spawn_asset(zone, _random_asset(rng, GRASS_ASSETS), Vector3(flat.x, 0.0, flat.y), rng.randf_range(0.0, TAU), rng.randf_range(0.85, 1.15))

	var camp_light := OmniLight3D.new()
	camp_light.name = "CampLight"
	camp_light.position = Vector3(0.0, 2.4, 7.0)
	camp_light.light_color = Color(1.0, 0.52, 0.18)
	camp_light.light_energy = 2.2
	camp_light.omni_range = 9.0
	zone.add_child(camp_light)


func _build_west_forest(zone: Node3D, rng: RandomNumberGenerator) -> void:
	var tree_positions: Array[Vector2] = [
		Vector2(-25.0, -15.0), Vector2(-20.5, -14.0), Vector2(-15.5, -17.0),
		Vector2(-26.0, -8.0), Vector2(-21.0, -7.0), Vector2(-16.0, -10.0),
		Vector2(-27.0, 0.0), Vector2(-22.0, 1.5), Vector2(-16.0, -1.0),
		Vector2(-26.0, 8.0), Vector2(-21.0, 9.5), Vector2(-16.5, 6.5),
		Vector2(-25.0, 16.0), Vector2(-19.5, 17.0), Vector2(-15.0, 14.0)
	]
	for i: int in tree_positions.size():
		var assets: Array = PINE_ASSETS if i % 3 != 1 else BIRCH_ASSETS
		_spawn_tree(zone, _random_asset(rng, assets), tree_positions[i], rng.randf_range(0.0, TAU))

	for i: int in 22:
		var flat := Vector2(rng.randf_range(-27.0, -14.0), rng.randf_range(-17.0, 18.0))
		var assets: Array = FERN_ASSETS if i % 2 == 0 else GRASS_ASSETS
		_spawn_asset(zone, _random_asset(rng, assets), Vector3(flat.x, 0.0, flat.y), rng.randf_range(0.0, TAU), rng.randf_range(0.8, 1.2))

	_spawn_asset(zone, "fallen_log_b", Vector3(-20.0, 0.0, 4.0), 0.8)
	_spawn_asset(zone, "fallen_log_d", Vector3(-23.0, 0.0, -11.0), -0.4)
	_spawn_asset(zone, "root_cluster_c", Vector3(-17.0, 0.0, 11.0), 1.2)
	_spawn_asset(zone, "stump_d", Vector3(-18.0, 0.0, -5.0), 0.4)
	_spawn_boulder(zone, "boulder_b", Vector2(-24.0, 5.0), 0.2)
	_spawn_boulder(zone, "boulder_g", Vector2(-15.0, 2.5), 1.0)


func _build_north_ruins(zone: Node3D, _rng: RandomNumberGenerator) -> void:
	_spawn_ruin_arch(zone, "ruin_arch_a", Vector3(0.0, 0.0, -13.5), 0.0)
	_spawn_ruin_wall(zone, "ruin_wall_a", Vector3(-5.0, 0.0, -19.0), PI * 0.5)
	_spawn_ruin_wall(zone, "ruin_wall_b", Vector3(5.0, 0.0, -19.0), PI * 0.5)
	_spawn_ruin_wall(zone, "ruin_wall_c", Vector3(-3.0, 0.0, -24.5), 0.0)
	_spawn_ruin_wall(zone, "ruin_wall_d", Vector3(3.0, 0.0, -24.5), 0.0)
	_spawn_asset(zone, "ruin_column_a", Vector3(-3.5, 0.0, -16.5), 0.1)
	_spawn_asset(zone, "ruin_column_c", Vector3(3.5, 0.0, -16.5), -0.1)
	_spawn_asset(zone, "stone_marker_a", Vector3(-6.5, 0.0, -13.0), 0.25)
	_spawn_asset(zone, "stone_marker_b", Vector3(6.5, 0.0, -13.0), -0.25)

	_spawn_building_piece(zone, "stone_foundation", Vector3(10.0, 0.0, -21.0))
	_spawn_building_piece(zone, "stone_floor", Vector3(10.0, 0.72, -21.0))
	_spawn_building_piece(zone, "stone_half_wall", Vector3(10.0, 0.72, -23.0))
	_spawn_building_piece(zone, "stone_stairs", Vector3(10.0, 0.0, -17.3))
	_add_box_collider(_spawn_asset(zone, "station_stone_furnace", Vector3(10.0, 0.85, -21.0), PI), Vector3(2.45, 2.3, 1.8), Vector3(0.0, 1.15, 0.0))
	_add_box_collider(_spawn_asset(zone, "station_anvil", Vector3(7.8, 0.75, -20.0), 0.35), Vector3(1.4, 1.4, 0.95), Vector3(0.0, 0.7, 0.0))
	_spawn_boulder(zone, "boulder_d", Vector2(-8.0, -22.0), 0.6)
	_spawn_boulder(zone, "boulder_f", Vector2(7.0, -26.0), 1.1)


func _build_east_mire(zone: Node3D, rng: RandomNumberGenerator) -> void:
	var dead_tree_positions: Array[Vector2] = [
		Vector2(16.0, -10.0), Vector2(22.0, -12.0), Vector2(26.0, -7.0),
		Vector2(17.0, 0.0), Vector2(24.0, 2.0), Vector2(27.0, 8.0)
	]
	for i: int in dead_tree_positions.size():
		var assets: Array = BARE_ASSETS if i % 2 == 0 else CROOKED_ASSETS
		_spawn_tree(zone, _random_asset(rng, assets), dead_tree_positions[i], rng.randf_range(0.0, TAU))

	var crystal_positions: Array[Vector2] = [
		Vector2(18.0, -7.0), Vector2(22.0, -5.0), Vector2(25.0, -1.0),
		Vector2(19.0, 3.0), Vector2(23.0, 6.0), Vector2(16.0, 7.0)
	]
	for i: int in crystal_positions.size():
		_spawn_asset(zone, CRYSTAL_ASSETS[i], Vector3(crystal_positions[i].x, 0.0, crystal_positions[i].y), rng.randf_range(0.0, TAU))
	for i: int in 8:
		var flat := Vector2(rng.randf_range(15.0, 27.0), rng.randf_range(-10.0, 10.0))
		_spawn_asset(zone, _random_asset(rng, MUSHROOM_ASSETS), Vector3(flat.x, 0.0, flat.y), rng.randf_range(0.0, TAU), rng.randf_range(0.8, 1.15))
	for i: int in 4:
		var flat := Vector2(18.0 + i * 2.2, -3.0 + (i % 2) * 8.0)
		_spawn_asset(zone, TENDRIL_ASSETS[i], Vector3(flat.x, 0.0, flat.y), rng.randf_range(0.0, TAU))
	_spawn_asset(zone, "standing_stone_a", Vector3(14.5, 0.0, -4.0), 0.2)
	_spawn_asset(zone, "standing_stone_c", Vector3(27.0, 0.0, 3.0), -0.3)


func _build_south_ridge(zone: Node3D, rng: RandomNumberGenerator) -> void:
	var rock_positions: Array[Vector2] = [
		Vector2(-10.0, 23.0), Vector2(-5.0, 25.0), Vector2(1.0, 22.0),
		Vector2(8.0, 25.0), Vector2(15.0, 23.0), Vector2(22.0, 25.0),
		Vector2(26.0, 20.0), Vector2(18.0, 18.0)
	]
	for i: int in rock_positions.size():
		_spawn_boulder(zone, BOULDER_ASSETS[i], rock_positions[i], rng.randf_range(0.0, TAU))

	# A small lookout tests floors, railings, posts, and traversable stairs together.
	_spawn_building_piece(zone, "wood_foundation", Vector3(12.0, 0.0, 20.0))
	_spawn_building_piece(zone, "wood_floor", Vector3(12.0, 0.4, 20.0))
	_spawn_building_piece(zone, "wood_stairs", Vector3(12.0, 0.0, 16.2))
	_spawn_building_piece(zone, "wood_railing", Vector3(12.0, 0.4, 22.0))
	_spawn_building_piece(zone, "wood_railing", Vector3(10.0, 0.4, 20.0), PI * 0.5)
	_spawn_building_piece(zone, "wood_railing", Vector3(14.0, 0.4, 20.0), PI * 0.5)
	_spawn_building_piece(zone, "wood_post", Vector3(10.1, 0.4, 18.1))
	_spawn_building_piece(zone, "wood_post", Vector3(13.9, 0.4, 18.1))
	_spawn_asset(zone, "grass_clump_c", Vector3(7.0, 0.0, 20.0), 0.4)
	_spawn_asset(zone, "reeds_b", Vector3(-2.0, 0.0, 24.0), -0.2)


func _build_routes_and_boundary(zone: Node3D, rng: RandomNumberGenerator) -> void:
	# A clear north-south route with low, non-colliding dressing.
	for i: int in 14:
		var z_pos: float = 2.0 - i * 1.0
		var side: float = -1.0 if i % 2 == 0 else 1.0
		_spawn_asset(
			zone,
			_random_asset(rng, GRASS_ASSETS),
			Vector3(side * rng.randf_range(3.6, 5.8), 0.0, z_pos),
			rng.randf_range(0.0, TAU),
			rng.randf_range(0.75, 1.05)
		)

	# Trees and rocks suggest the finite island edge without making an invisible wall.
	var boundary_trees: Array[Vector2] = [
		Vector2(-27.0, -25.0), Vector2(-20.0, -27.0), Vector2(-12.0, -27.0),
		Vector2(12.0, -27.0), Vector2(20.0, -27.0), Vector2(27.0, -24.0),
		Vector2(28.0, 13.0), Vector2(27.0, 18.0), Vector2(25.0, 27.0),
		Vector2(-25.0, 27.0), Vector2(-28.0, 20.0), Vector2(-28.0, 13.0)
	]
	for i: int in boundary_trees.size():
		var assets: Array = PINE_ASSETS if i % 2 == 0 else BIRCH_ASSETS
		_spawn_tree(zone, _random_asset(rng, assets), boundary_trees[i], rng.randf_range(0.0, TAU))

	var boundary_rocks: Array[Vector2] = [
		Vector2(-5.0, -28.0), Vector2(4.0, -27.5), Vector2(28.0, -16.0),
		Vector2(28.0, 14.0), Vector2(6.0, 28.0), Vector2(-5.0, 28.0),
		Vector2(-28.0, -19.0), Vector2(-28.0, -3.0)
	]
	for i: int in boundary_rocks.size():
		_spawn_boulder(zone, BOULDER_ASSETS[i], boundary_rocks[i], rng.randf_range(0.0, TAU))
