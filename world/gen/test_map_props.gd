extends Node

## Scatters throwaway test geometry (crates, cover walls, stumps, parkour platforms) into the
## current greybox level at boot, so playtesting has something in it besides an empty box.
##
## Deterministic and client-local, same category as terrain gen (ARCHITECTURE.md §2.2/§4): every
## client regenerates identical props from PROP_SEED, so nothing here needs to be networked or
## replicated. Only runs when the loaded scene is the greybox test level — a real level built later
## just won't match GREYBOX_SCENE_NAME and this autoload does nothing.

const GREYBOX_SCENE_NAME: String = "GreyboxTest"
const PROP_SEED: int = 20260816

const CRATE_COUNT: int = 30
const STUMP_COUNT: int = 16
const COVER_WALL_COUNT: int = 12
const PLATFORM_COUNT: int = 8

## Ground plane is 60x60 centred on the origin (see greybox_test.tscn). Existing hand-built
## features (ramps, stairs, gaps, walls, spawn) occupy roughly x[-20,15] z[-10,14], so new props
## are scattered in a ring outside that box, inset from the ground edge.
const FIELD_HALF_EXTENT: float = 27.0
const EXCLUSION_MIN: Vector2 = Vector2(-22.0, -12.0)
const EXCLUSION_MAX: Vector2 = Vector2(17.0, 16.0)

const CRATE_COLOR: Color = Color(0.5, 0.36, 0.22)
const STUMP_COLOR: Color = Color(0.28, 0.22, 0.16)
const COVER_COLOR: Color = Color(0.4, 0.46, 0.34)
const PLATFORM_COLOR: Color = Color(0.42, 0.44, 0.52)


func _ready() -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.name != GREYBOX_SCENE_NAME:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = PROP_SEED

	var root := Node3D.new()
	root.name = "TestMapProps"
	scene.add_child(root)

	_spawn_crates(root, rng)
	_spawn_stumps(root, rng)
	_spawn_cover_walls(root, rng)
	_spawn_platforms(root, rng)

	var total: int = CRATE_COUNT + STUMP_COUNT + COVER_WALL_COUNT + PLATFORM_COUNT
	print("world: TestMapProps scattered %d test props into %s" % [total, scene.name])


func _random_point_outside_exclusion(rng: RandomNumberGenerator) -> Vector2:
	var point: Vector2
	var attempts: int = 0
	while attempts < 20:
		point = Vector2(
			rng.randf_range(-FIELD_HALF_EXTENT, FIELD_HALF_EXTENT),
			rng.randf_range(-FIELD_HALF_EXTENT, FIELD_HALF_EXTENT)
		)
		var inside_exclusion: bool = (
			point.x > EXCLUSION_MIN.x and point.x < EXCLUSION_MAX.x
			and point.y > EXCLUSION_MIN.y and point.y < EXCLUSION_MAX.y
		)
		if not inside_exclusion:
			return point
		attempts += 1
	return point


func _spawn_box(
	parent: Node3D,
	obj_name: String,
	pos: Vector3,
	size: Vector3,
	color: Color,
	yaw: float
) -> void:
	var body := StaticBody3D.new()
	body.name = obj_name
	body.transform = Transform3D(Basis(Vector3.UP, yaw), pos)

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9

	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)

	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	parent.add_child(body)


func _spawn_cylinder(
	parent: Node3D, obj_name: String, pos: Vector3, radius: float, height: float, color: Color
) -> void:
	var body := StaticBody3D.new()
	body.name = obj_name
	body.position = pos

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.95

	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius * 1.15
	mesh.height = height
	mesh.material = material
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)

	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	parent.add_child(body)


func _spawn_crates(parent: Node3D, rng: RandomNumberGenerator) -> void:
	var group := Node3D.new()
	group.name = "Crates"
	parent.add_child(group)

	for i: int in CRATE_COUNT:
		var flat: Vector2 = _random_point_outside_exclusion(rng)
		var size: float = rng.randf_range(0.8, 1.4)
		var stacked: bool = rng.randf() < 0.3
		var height: float = size if not stacked else size * 2.0
		_spawn_box(
			group,
			"Crate_%d" % i,
			Vector3(flat.x, height * 0.5, flat.y),
			Vector3(size, height, size),
			CRATE_COLOR.lightened(rng.randf_range(-0.1, 0.1)),
			rng.randf_range(0.0, TAU)
		)


func _spawn_stumps(parent: Node3D, rng: RandomNumberGenerator) -> void:
	var group := Node3D.new()
	group.name = "Stumps"
	parent.add_child(group)

	for i: int in STUMP_COUNT:
		var flat: Vector2 = _random_point_outside_exclusion(rng)
		var radius: float = rng.randf_range(0.3, 0.6)
		var height: float = rng.randf_range(0.6, 2.5)
		_spawn_cylinder(
			group,
			"Stump_%d" % i,
			Vector3(flat.x, height * 0.5, flat.y),
			radius,
			height,
			STUMP_COLOR.lightened(rng.randf_range(-0.08, 0.08))
		)


func _spawn_cover_walls(parent: Node3D, rng: RandomNumberGenerator) -> void:
	var group := Node3D.new()
	group.name = "CoverWalls"
	parent.add_child(group)

	for i: int in COVER_WALL_COUNT:
		var flat: Vector2 = _random_point_outside_exclusion(rng)
		var length: float = rng.randf_range(2.0, 4.5)
		var height: float = rng.randf_range(0.8, 1.6)
		_spawn_box(
			group,
			"CoverWall_%d" % i,
			Vector3(flat.x, height * 0.5, flat.y),
			Vector3(length, height, 0.4),
			COVER_COLOR.lightened(rng.randf_range(-0.1, 0.1)),
			rng.randf_range(0.0, TAU)
		)


func _spawn_platforms(parent: Node3D, rng: RandomNumberGenerator) -> void:
	var group := Node3D.new()
	group.name = "Platforms"
	parent.add_child(group)

	for i: int in PLATFORM_COUNT:
		var flat: Vector2 = _random_point_outside_exclusion(rng)
		var size: Vector3 = Vector3(rng.randf_range(2.5, 4.5), 0.5, rng.randf_range(2.5, 4.5))
		var height: float = rng.randf_range(1.0, 4.5)
		_spawn_box(
			group,
			"Platform_%d" % i,
			Vector3(flat.x, height, flat.y),
			size,
			PLATFORM_COLOR.lightened(rng.randf_range(-0.08, 0.08)),
			rng.randf_range(0.0, TAU)
		)
