extends Node3D

## Builds an authored map — terrain, water, props, collision, lights, markers —
## from one layout file at load.
##
## ## Network authority (ARCHITECTURE.md §2.2)
##
## **None, and deliberately so.** The layout is a frozen file shipped in the build,
## so every peer constructs a byte-identical world from it without a byte crossing
## the wire. This node owns no gameplay state: the markers it drops are read by
## host-authoritative systems (spawning, objectives, enemy nests), and those
## systems keep their authority. If a future map needs runtime variation — a
## destroyed bridge, a flooded zone — that is host-authoritative state replicated
## to clients, and it does not live here.
##
## ## Why this map has one consumer where Playtest Hollow has two
##
## The Hollow bakes its visuals in Blender and rebuilds its collision in GDScript
## from the same JSON, which is the right call at 88 m across: what you see is
## authored art. Hollowmere is 356 m across, and a single baked mesh that size
## cannot be culled — the renderer would draw the far valley wall through a hill
## every frame. So this script builds both halves, which has a second benefit the
## Hollow has to work for: the visual and the collision cannot drift apart,
## because they are produced by the same loop over the same array.
##
## Props are grouped into `MultiMeshInstance3D` per chunk per asset, so a hillside
## culls in one test rather than five hundred, and a forest of 300 pines is a
## handful of draw calls.

const PROP_GROUP: StringName = &"authored_world_prop"
const MARKER_GROUP: StringName = &"authored_world_marker"
const TERRAIN_GROUP: StringName = &"authored_world_terrain"

@export_file("*.json") var layout_path: String = "res://world/gen/layouts/hollowmere.json"
## Skip prop instancing. Useful when profiling terrain or collision on its own.
@export var build_props: bool = true

var terrain_triangles: int = 0
var prop_count: int = 0
var multimesh_count: int = 0
var collider_count: int = 0
var water_surfaces: int = 0

var _layout: Dictionary = {}
var _origin := Vector2.ZERO
var _cell: float = 1.0
var _nx: int = 0
var _nz: int = 0
var _heights: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	var started := Time.get_ticks_msec()
	_layout = _read_layout()
	if _layout.is_empty():
		return
	_read_heightfield()
	_build_terrain()
	_build_water()
	if build_props:
		_build_props()
	_build_lights()
	_build_markers()
	print(
		"AUTHORED_WORLD id=%s terrain_tris=%d props=%d multimeshes=%d colliders=%d water=%d ms=%d" % [
			String(_layout.get("id", "?")), terrain_triangles, prop_count, multimesh_count,
			collider_count, water_surfaces, Time.get_ticks_msec() - started
		]
	)


func _read_layout() -> Dictionary:
	var text := FileAccess.get_file_as_string(layout_path)
	if text.is_empty():
		push_error("AuthoredWorld could not read %s" % layout_path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("AuthoredWorld layout is not a JSON object: %s" % layout_path)
		return {}
	return parsed as Dictionary


func _read_heightfield() -> void:
	var field: Dictionary = _layout.get("heightfield", {}) as Dictionary
	var origin: Array = field.get("origin", [0.0, 0.0]) as Array
	_origin = Vector2(float(origin[0]), float(origin[1]))
	_cell = float(field.get("cell", 1.0))
	_nx = int(field.get("nx", 0))
	_nz = int(field.get("nz", 0))
	var raw: Array = field.get("heights", []) as Array
	_heights.resize(raw.size())
	for index in raw.size():
		_heights[index] = float(raw[index])
	if _heights.size() != _nx * _nz:
		push_error("AuthoredWorld heightfield is %d values for %dx%d" % [_heights.size(), _nx, _nz])


func height_at(x: float, z: float) -> float:
	var fx := (x - _origin.x) / _cell
	var fz := (z - _origin.y) / _cell
	var ix := clampi(int(floor(fx)), 0, _nx - 2)
	var iz := clampi(int(floor(fz)), 0, _nz - 2)
	var tx := clampf(fx - ix, 0.0, 1.0)
	var tz := clampf(fz - iz, 0.0, 1.0)
	var h00 := _heights[iz * _nx + ix]
	var h10 := _heights[iz * _nx + ix + 1]
	var h01 := _heights[(iz + 1) * _nx + ix]
	var h11 := _heights[(iz + 1) * _nx + ix + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## Terrain is emitted as one surface per ground material, so the valley floor
## reads as patches of mud, scree, sand and moss rather than as one flat green —
## and it still costs one MeshInstance3D and one collider for the whole map.
func _build_terrain() -> void:
	var field: Dictionary = _layout.get("heightfield", {}) as Dictionary
	var material_names: Array = field.get("material_names", []) as Array
	var indices: Array = field.get("material_index", []) as Array
	var palette: Dictionary = _layout.get("materials", {}) as Dictionary

	var vertices: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	for _index in material_names.size():
		vertices.append(PackedVector3Array())
		normals.append(PackedVector3Array())

	var collision := PackedVector3Array()
	for iz in _nz - 1:
		for ix in _nx - 1:
			var a := _corner(ix, iz)
			var b := _corner(ix + 1, iz)
			var c := _corner(ix + 1, iz + 1)
			var d := _corner(ix, iz + 1)
			var slot := 0
			if indices.size() == _heights.size():
				slot = clampi(int(indices[iz * _nx + ix]), 0, material_names.size() - 1)
			var target := vertices[slot]
			var target_normals := normals[slot]
			_emit_triangle(target, target_normals, a, b, c)
			_emit_triangle(target, target_normals, a, c, d)
			collision.append_array(PackedVector3Array([a, b, c, a, c, d]))

	var mesh := ArrayMesh.new()
	for slot in material_names.size():
		if vertices[slot].is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices[slot]
		arrays[Mesh.ARRAY_NORMAL] = normals[slot]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(
			mesh.get_surface_count() - 1,
			_ground_material(palette.get(String(material_names[slot]), {}) as Dictionary)
		)
		terrain_triangles += vertices[slot].size() / 3

	var instance := MeshInstance3D.new()
	instance.name = "TerrainMesh"
	instance.mesh = mesh
	instance.add_to_group(TERRAIN_GROUP)
	add_child(instance)

	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	body.add_to_group(TERRAIN_GROUP)
	add_child(body)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(collision)
	var collider := CollisionShape3D.new()
	collider.name = "TerrainShape"
	collider.shape = shape
	body.add_child(collider)
	collider_count += 1


func _corner(ix: int, iz: int) -> Vector3:
	return Vector3(_origin.x + ix * _cell, _heights[iz * _nx + ix], _origin.y + iz * _cell)


## Flat normals, computed per face. The whole art direction depends on faceted
## shading; a smoothed heightfield would read as a different game.
func _emit_triangle(into: PackedVector3Array, into_normals: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3) -> void:
	into.append(a)
	into.append(b)
	into.append(c)
	var normal := (b - a).cross(c - a).normalized()
	if normal.y < 0.0:
		normal = -normal
	into_normals.append(normal)
	into_normals.append(normal)
	into_normals.append(normal)


func _ground_material(spec: Dictionary) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var color: Array = spec.get("color", [0.3, 0.3, 0.3, 1.0]) as Array
	material.albedo_color = Color(float(color[0]), float(color[1]), float(color[2]),
		float(color[3]) if color.size() > 3 else 1.0)
	material.roughness = float(spec.get("roughness", 0.95))
	material.metallic = float(spec.get("metallic", 0.0))
	return material


## Water is clipped to the ground it actually covers: a quad is emitted only where
## the terrain beneath it is lower than the surface. A lake drawn as a flat disc
## would hang over the hillside it is supposed to be sitting in.
func _build_water() -> void:
	var palette: Dictionary = _layout.get("water_materials", {}) as Dictionary
	var root := Node3D.new()
	root.name = "Water"
	add_child(root)
	for body_value: Variant in _layout.get("water", []):
		var body := body_value as Dictionary
		var built := _water_surface(body)
		if built == null:
			continue
		built.name = String(body.get("name", "Water"))
		var material := _ground_material(palette.get(String(body.get("material", "lake")), {}) as Dictionary)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		(built.mesh as ArrayMesh).surface_set_material(0, material)
		root.add_child(built)
		water_surfaces += 1


func _water_surface(body: Dictionary) -> MeshInstance3D:
	var kind := String(body.get("kind", ""))
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var step := _cell
	var min_x: float
	var max_x: float
	var min_z: float
	var max_z: float
	match kind:
		"circle":
			var centre: Array = body.get("centre", [0.0, 0.0]) as Array
			var radius := float(body.get("radius", 1.0))
			min_x = float(centre[0]) - radius
			max_x = float(centre[0]) + radius
			min_z = float(centre[1]) - radius
			max_z = float(centre[1]) + radius
		"rect":
			var lo: Array = body.get("min", [0.0, 0.0]) as Array
			var hi: Array = body.get("max", [0.0, 0.0]) as Array
			min_x = float(lo[0]); max_x = float(hi[0])
			min_z = float(lo[1]); max_z = float(hi[1])
		"strip":
			var a: Array = body.get("a", [0.0, 0.0]) as Array
			var b: Array = body.get("b", [0.0, 0.0]) as Array
			var half := float(body.get("half_width", 1.0))
			min_x = minf(float(a[0]), float(b[0])) - half
			max_x = maxf(float(a[0]), float(b[0])) + half
			min_z = minf(float(a[1]), float(b[1])) - half
			max_z = maxf(float(a[1]), float(b[1])) + half
		_:
			return null

	var x := min_x
	while x < max_x:
		var z := min_z
		while z < max_z:
			var corners := [
				Vector2(x, z), Vector2(x + step, z), Vector2(x + step, z + step), Vector2(x, z + step)
			]
			var levels: Array[float] = []
			var covered := true
			for corner: Vector2 in corners:
				var level := _water_level(body, corner)
				if is_nan(level) or height_at(corner.x, corner.y) >= level:
					covered = false
					break
				levels.append(level)
			if covered:
				var p := []
				for index in 4:
					p.append(Vector3(corners[index].x, levels[index], corners[index].y))
				for triangle in [[0, 1, 2], [0, 2, 3]]:
					for index: int in triangle:
						vertices.append(p[index])
						normals.append(Vector3.UP)
			z += step
		x += step

	if vertices.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	return instance


func _water_level(body: Dictionary, point: Vector2) -> float:
	match String(body.get("kind", "")):
		"circle":
			var centre: Array = body.get("centre", [0.0, 0.0]) as Array
			if point.distance_to(Vector2(float(centre[0]), float(centre[1]))) > float(body.get("radius", 0.0)):
				return NAN
			return float(body.get("level", 0.0))
		"rect":
			return float(body.get("level", 0.0))
		"strip":
			var a: Array = body.get("a", [0.0, 0.0]) as Array
			var b: Array = body.get("b", [0.0, 0.0]) as Array
			var start := Vector2(float(a[0]), float(a[1]))
			var end := Vector2(float(b[0]), float(b[1]))
			var span := end - start
			var length_sq := span.length_squared()
			var t := 0.0 if length_sq < 0.0001 else clampf((point - start).dot(span) / length_sq, 0.0, 1.0)
			if start.lerp(end, t).distance_to(point) > float(body.get("half_width", 0.0)):
				return NAN
			return lerpf(float(body.get("level_a", 0.0)), float(body.get("level_b", 0.0)), t)
	return NAN


## One MultiMeshInstance3D per (chunk, asset, mesh part). Chunking is what makes a
## map this size affordable: the renderer discards a whole hillside of trees with
## one frustum test.
func _build_props() -> void:
	var grouped: Dictionary = {}
	for prop_value: Variant in _layout.get("props", []):
		var prop := prop_value as Dictionary
		var chunk: Array = prop.get("chunk", [0, 0]) as Array
		var key := "%d_%d|%s|%s" % [int(chunk[0]), int(chunk[1]),
			String(prop.get("kit", "")), String(prop.get("asset", ""))]
		grouped.get_or_add(key, [] as Array).append(prop)

	var visuals := Node3D.new()
	visuals.name = "PropVisuals"
	add_child(visuals)
	var bodies := Node3D.new()
	bodies.name = "PropCollision"
	add_child(bodies)

	var cache: Dictionary = {}
	for key: String in grouped:
		var props: Array = grouped[key] as Array
		var parts := key.split("|")
		var kit := parts[1]
		var asset := parts[2]
		var meshes: Array = cache.get_or_add(key.substr(key.find("|") + 1), _mesh_parts(kit, asset))
		if meshes.is_empty():
			continue
		var transforms: Array[Transform3D] = []
		for prop_value: Variant in props:
			var prop := prop_value as Dictionary
			var pos: Array = prop.get("pos", [0.0, 0.0, 0.0]) as Array
			var placement := Transform3D(
				Basis(Vector3.UP, float(prop.get("yaw", 0.0))),
				Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
			).scaled_local(Vector3.ONE * float(prop.get("scale", 1.0)))
			transforms.append(placement)
			_add_prop_collision(bodies, prop, placement)
			prop_count += 1
		var holder := Node3D.new()
		holder.name = key.replace("|", "_")
		visuals.add_child(holder)
		for entry_value: Variant in meshes:
			var entry := entry_value as Dictionary
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = entry["mesh"]
			multimesh.instance_count = transforms.size()
			for index in transforms.size():
				multimesh.set_instance_transform(index, transforms[index] * (entry["offset"] as Transform3D))
			var instance := MultiMeshInstance3D.new()
			instance.name = String(entry["name"])
			instance.multimesh = multimesh
			holder.add_child(instance)
			multimesh_count += 1


## Collapse an asset to ONE mesh with one surface per material.
##
## This is not an optimisation, it is the difference between the map running and
## not. The environment kit's assets are built from dozens of separate Blender
## objects — a pine is around forty — and each one arrives as its own
## MeshInstance3D. Instanced per chunk that produced **4,749 MultiMeshInstance3D
## nodes for 1,408 props**: more draw calls than props, which is the exact
## opposite of what instancing is for. Merging first takes it to one node per
## (chunk, asset) and a handful of surfaces each.
##
## The flora kit already joins at export time, which is the better place to do it;
## doing it here as well means the older kits get the same benefit without a
## rebuild that would collide with another agent's claim.
func _mesh_parts(kit: String, asset: String) -> Array:
	var path := "res://assets/%s/exports/%s.glb" % [kit, asset]
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("AuthoredWorld could not load %s" % path)
		return []
	var sample := packed.instantiate()
	var found: Array[MeshInstance3D] = []
	_collect_meshes(sample, found)

	var buckets: Dictionary = {}
	var order: Array[String] = []
	for part in found:
		var offset := _offset_to(part, sample)
		var basis := offset.basis
		var mesh := part.mesh
		for surface in mesh.get_surface_count():
			var material := mesh.surface_get_material(surface)
			var key := material.resource_name if material != null else "surface_%d" % surface
			if not buckets.has(key):
				buckets[key] = {"material": material, "v": PackedVector3Array(), "n": PackedVector3Array()}
				order.append(key)
			var arrays: Array = mesh.surface_get_arrays(surface)
			var source_v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var source_n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var bucket: Dictionary = buckets[key]
			var out_v: PackedVector3Array = bucket["v"]
			var out_n: PackedVector3Array = bucket["n"]
			if indices.is_empty():
				for index in source_v.size():
					out_v.append(offset * source_v[index])
					out_n.append((basis * source_n[index]).normalized() if index < source_n.size() else Vector3.UP)
			else:
				for index in indices:
					out_v.append(offset * source_v[index])
					out_n.append((basis * source_n[index]).normalized() if index < source_n.size() else Vector3.UP)
			bucket["v"] = out_v
			bucket["n"] = out_n
	sample.free()

	var combined := ArrayMesh.new()
	for key in order:
		var bucket: Dictionary = buckets[key]
		var vertices: PackedVector3Array = bucket["v"]
		if vertices.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = bucket["n"]
		combined.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		combined.surface_set_material(combined.get_surface_count() - 1, bucket["material"])
	if combined.get_surface_count() == 0:
		return []
	return [{"mesh": combined, "offset": Transform3D.IDENTITY, "name": asset}]


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, out)


func _offset_to(node: Node3D, root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _add_prop_collision(parent: Node3D, prop: Dictionary, placement: Transform3D) -> void:
	var shapes: Array = prop.get("cols", []) as Array
	if shapes.is_empty():
		return
	var body := StaticBody3D.new()
	body.name = "%s_%03d" % [String(prop.get("asset", "Prop")), collider_count]
	body.transform = placement
	body.set_meta(&"asset", String(prop.get("asset", "")))
	body.set_meta(&"kit", String(prop.get("kit", "")))
	body.add_to_group(PROP_GROUP)
	parent.add_child(body)
	for shape_value: Variant in shapes:
		var data := shape_value as Dictionary
		var collider := CollisionShape3D.new()
		if String(data.get("t", "")) == "box":
			var size: Array = data.get("size", [1.0, 1.0, 1.0]) as Array
			var box := BoxShape3D.new()
			box.size = Vector3(float(size[0]), float(size[1]), float(size[2]))
			collider.shape = box
			var off: Array = data.get("off", [0.0, 0.0, 0.0]) as Array
			collider.position = Vector3(float(off[0]), float(off[1]), float(off[2]))
		else:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = float(data.get("r", 0.5))
			cylinder.height = float(data.get("h", 1.0))
			collider.shape = cylinder
			collider.position.y = float(data.get("y", cylinder.height * 0.5))
		collider.name = "Shape_%03d" % collider_count
		body.add_child(collider)
		collider_count += 1


func _build_lights() -> void:
	var root := Node3D.new()
	root.name = "LayoutLights"
	add_child(root)
	for light_value: Variant in _layout.get("lights", []):
		var data := light_value as Dictionary
		var light := OmniLight3D.new()
		light.name = String(data.get("name", "Light"))
		var pos: Array = data.get("pos", [0.0, 0.0, 0.0]) as Array
		light.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		var color: Array = data.get("color", [1.0, 1.0, 1.0]) as Array
		light.light_color = Color(float(color[0]), float(color[1]), float(color[2]))
		light.light_energy = float(data.get("energy", 1.0))
		light.omni_range = float(data.get("range", 8.0))
		light.shadow_enabled = false
		root.add_child(light)


func _build_markers() -> void:
	var root := Node3D.new()
	root.name = "GameplayMarkers"
	add_child(root)
	for marker_value: Variant in _layout.get("markers", []):
		var data := marker_value as Dictionary
		var marker := Marker3D.new()
		marker.name = String(data.get("name", "Marker"))
		var pos: Array = data.get("pos", [0.0, 0.0, 0.0]) as Array
		marker.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		marker.set_meta(&"kind", String(data.get("kind", "")))
		marker.set_meta(&"zone", String(data.get("zone", "")))
		marker.add_to_group(MARKER_GROUP)
		root.add_child(marker)
