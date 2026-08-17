extends Node3D

## Builds collision, lights, and gameplay markers from the same frozen layout used by Blender.
## Visual placement is exported in assets/maps/playtest_hollow.glb; this script never scatters.

const LAYOUT_PATH: String = "res://world/gen/layouts/playtest_hollow.json"
const ASSET_GROUP: StringName = &"playtest_hollow_asset"
const COLLIDER_GROUP: StringName = &"playtest_hollow_collider"
const TERRAIN_GROUP: StringName = &"playtest_hollow_terrain"
const ZONE_GROUP: StringName = &"playtest_hollow_zone"
const MARKER_GROUP: StringName = &"playtest_hollow_marker"

var prop_count: int = 0
var collision_shape_count: int = 0
var terrain_body_count: int = 0


func _ready() -> void:
	build_from_layout()


func build_from_layout() -> void:
	var text := FileAccess.get_file_as_string(LAYOUT_PATH)
	if text.is_empty():
		push_error("PlaytestHollow could not read %s" % LAYOUT_PATH)
		return
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("PlaytestHollow layout is not a JSON object: %s" % LAYOUT_PATH)
		return
	var layout := parsed as Dictionary
	var zones_root := Node3D.new()
	zones_root.name = "CollisionZones"
	add_child(zones_root)
	var zones: Dictionary = {}
	for zone_value: Variant in layout.get("zones", []):
		var zone_name := String(zone_value)
		var zone := Node3D.new()
		zone.name = zone_name
		zone.add_to_group(ZONE_GROUP)
		zones_root.add_child(zone)
		zones[zone_name] = zone

	var terrain_root := Node3D.new()
	terrain_root.name = "TerrainCollision"
	add_child(terrain_root)
	for terrain_value: Variant in layout.get("terrain", []):
		var terrain := terrain_value as Dictionary
		if not bool(terrain.get("collide", false)):
			continue
		_add_terrain_body(terrain_root, terrain)

	for prop_value: Variant in layout.get("props", []):
		var prop := prop_value as Dictionary
		var zone := zones.get(String(prop.get("zone", ""))) as Node3D
		if zone == null:
			push_error("PlaytestHollow prop references unknown zone: %s" % prop)
			continue
		_add_prop_collision(zone, prop)

	var marker_root := Node3D.new()
	marker_root.name = "GameplayMarkers"
	add_child(marker_root)
	for marker_value: Variant in layout.get("markers", []):
		var marker_data := marker_value as Dictionary
		var marker := Marker3D.new()
		marker.name = String(marker_data.get("name", "Marker"))
		marker.position = _vector3(marker_data.get("pos", [0.0, 0.0, 0.0]))
		marker.set_meta(&"kind", String(marker_data.get("kind", "")))
		marker.set_meta(&"zone", String(marker_data.get("zone", "")))
		marker.add_to_group(MARKER_GROUP)
		marker_root.add_child(marker)

	var lights_root := Node3D.new()
	lights_root.name = "LayoutLights"
	add_child(lights_root)
	for light_value: Variant in layout.get("lights", []):
		_add_light(lights_root, light_value as Dictionary)

	print(
		"PLAYTEST_HOLLOW_RUNTIME props=%d terrain=%d shapes=%d markers=%d"
		% [prop_count, terrain_body_count, collision_shape_count, marker_root.get_child_count()]
	)


func _add_terrain_body(parent: Node3D, data: Dictionary) -> void:
	var body := StaticBody3D.new()
	body.name = String(data.get("name", "Terrain"))
	body.position = _vector3(data.get("pos", [0.0, 0.0, 0.0]))
	var tilt := float(data.get("tilt", 0.0))
	if String(data.get("axis", "x")) == "z":
		body.rotation.z = tilt
	else:
		body.rotation.x = tilt
	body.add_to_group(TERRAIN_GROUP)
	parent.add_child(body)
	_add_box_shape(body, _vector3(data.get("size", [1.0, 1.0, 1.0])), Vector3.ZERO)
	terrain_body_count += 1


func _add_prop_collision(parent: Node3D, data: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "%s_%03d" % [String(data.get("asset", "Prop")), prop_count]
	holder.position = _vector3(data.get("pos", [0.0, 0.0, 0.0]))
	holder.rotation.y = float(data.get("yaw", 0.0))
	holder.scale = Vector3.ONE * float(data.get("scale", 1.0))
	holder.set_meta(&"asset", String(data.get("asset", "")))
	holder.set_meta(&"kit", String(data.get("kit", "")))
	holder.add_to_group(ASSET_GROUP)
	parent.add_child(holder)
	var shapes: Array = data.get("cols", []) as Array
	if not shapes.is_empty():
		var body := StaticBody3D.new()
		body.name = "CollisionBody"
		holder.add_child(body)
		for shape_value: Variant in shapes:
			var shape_data := shape_value as Dictionary
			if String(shape_data.get("t", "")) == "cyl":
				_add_cylinder_shape(
					body,
					float(shape_data.get("r", 0.5)),
					float(shape_data.get("h", 1.0)),
					float(shape_data.get("y", 0.5))
				)
			else:
				_add_box_shape(
					body,
					_vector3(shape_data.get("size", [1.0, 1.0, 1.0])),
					_vector3(shape_data.get("off", [0.0, 0.0, 0.0]))
				)
	prop_count += 1


func _add_box_shape(parent: StaticBody3D, size: Vector3, offset: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.name = "Collision_%03d" % collision_shape_count
	collision.shape = shape
	collision.position = offset
	collision.add_to_group(COLLIDER_GROUP)
	parent.add_child(collision)
	collision_shape_count += 1


func _add_cylinder_shape(parent: StaticBody3D, radius: float, height: float, y: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var collision := CollisionShape3D.new()
	collision.name = "Collision_%03d" % collision_shape_count
	collision.shape = shape
	collision.position.y = y
	collision.add_to_group(COLLIDER_GROUP)
	parent.add_child(collision)
	collision_shape_count += 1


func _add_light(parent: Node3D, data: Dictionary) -> void:
	var light := OmniLight3D.new()
	light.name = String(data.get("name", "LayoutLight"))
	light.position = _vector3(data.get("pos", [0.0, 2.0, 0.0]))
	var color_values: Array = data.get("color", [1.0, 1.0, 1.0]) as Array
	light.light_color = Color(
		float(color_values[0]), float(color_values[1]), float(color_values[2]), 1.0
	)
	light.light_energy = float(data.get("energy", 1.0))
	light.omni_range = float(data.get("range", 8.0))
	light.shadow_enabled = false
	parent.add_child(light)


func _vector3(value: Variant) -> Vector3:
	var values := value as Array
	return Vector3(float(values[0]), float(values[1]), float(values[2]))
