extends Node3D

## Deterministic, presentation-only cloud field built from faceted mesh clusters.
## It deliberately uses geometry instead of a screen-space/noise cloud shader so the sky
## shares the chunky low-poly language of the authored map.

@export var movement_enabled: bool = true
@export var wind_velocity := Vector2(0.42, 0.1)
@export_range(100.0, 400.0, 1.0) var wrap_extent: float = 150.0
## Lifts the whole deck. The authored cloud heights suit an 88 m map whose highest
## ground is 3 m; on Hollowmere the boundary ridge crests near 59 m and the deck
## would sit *inside* the hills. Kept as an offset rather than an edit to the
## constants so the Hollow's sky is untouched.
@export var altitude_offset: float = 0.0
## Spreads the deck out for a larger map, so a dozen clusters still cover the sky.
@export var spread_scale: float = 1.0

## Sky tint, multiplied into every puff's vertex colour by the unshaded material. The day value is
## pure white on purpose: at noon the deck renders exactly as it did before F-065 touched it, so the
## fix can only ever change how night and dusk look.
const CLOUD_DAY_TINT := Color(1.0, 1.0, 1.0)
const CLOUD_NIGHT_TINT := Color(0.13, 0.16, 0.26)
const CLOUD_SUNSET_TINT := Color(1.0, 0.55, 0.32)

const CLOUD_SEED: int = 20260817
const CLOUD_CENTERS: Array[Vector3] = [
	Vector3(-92.0, 34.0, -82.0),
	Vector3(-44.0, 39.0, -105.0),
	Vector3(12.0, 34.0, -91.0),
	Vector3(70.0, 40.0, -87.0),
	Vector3(108.0, 35.0, -34.0),
	Vector3(111.0, 41.0, 37.0),
	Vector3(78.0, 36.0, 91.0),
	Vector3(20.0, 42.0, 108.0),
	Vector3(-48.0, 35.0, 104.0),
	Vector3(-103.0, 40.0, 67.0),
	Vector3(-116.0, 35.0, 4.0),
	Vector3(-38.0, 45.0, -48.0),
]
const ICOSAHEDRON_FACES: Array[Vector3i] = [
	Vector3i(0, 11, 5), Vector3i(0, 5, 1), Vector3i(0, 1, 7),
	Vector3i(0, 7, 10), Vector3i(0, 10, 11), Vector3i(1, 5, 9),
	Vector3i(5, 11, 4), Vector3i(11, 10, 2), Vector3i(10, 7, 6),
	Vector3i(7, 1, 8), Vector3i(3, 9, 4), Vector3i(3, 4, 2),
	Vector3i(3, 2, 6), Vector3i(3, 6, 8), Vector3i(3, 8, 9),
	Vector3i(4, 9, 5), Vector3i(2, 4, 11), Vector3i(6, 2, 10),
	Vector3i(8, 6, 7), Vector3i(9, 8, 1),
]

var _daylight: float = 1.0
var _golden: float = 0.0
var _clusters: Array[Node3D] = []
var _cloud_mesh: ArrayMesh
var _cloud_material: StandardMaterial3D


func _ready() -> void:
	rebuild_clouds()
	set_process(movement_enabled)


func _process(delta: float) -> void:
	for cluster: Node3D in _clusters:
		cluster.position.x += wind_velocity.x * delta
		cluster.position.z += wind_velocity.y * delta
		if cluster.position.x > wrap_extent:
			cluster.position.x -= wrap_extent * 2.0
		elif cluster.position.x < -wrap_extent:
			cluster.position.x += wrap_extent * 2.0
		if cluster.position.z > wrap_extent:
			cluster.position.z -= wrap_extent * 2.0
		elif cluster.position.z < -wrap_extent:
			cluster.position.z += wrap_extent * 2.0


func rebuild_clouds() -> void:
	for child: Node in get_children():
		child.queue_free()
	_clusters.clear()
	_cloud_material = StandardMaterial3D.new()
	_cloud_material.vertex_color_use_as_albedo = true
	_cloud_material.roughness = 1.0
	_cloud_material.metallic = 0.0
	_cloud_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cloud_mesh = _build_cloud_mesh()
	_apply_sky_light()

	var random := RandomNumberGenerator.new()
	random.seed = CLOUD_SEED
	for cluster_index: int in CLOUD_CENTERS.size():
		var cluster := Node3D.new()
		cluster.name = "CloudCluster_%02d" % cluster_index
		var centre := CLOUD_CENTERS[cluster_index]
		cluster.position = Vector3(
			centre.x * spread_scale, centre.y + altitude_offset, centre.z * spread_scale
		)
		cluster.rotation_degrees.y = random.randf_range(-18.0, 18.0)
		cluster.add_to_group(&"low_poly_cloud")
		add_child(cluster)
		_clusters.append(cluster)

		# A broad, low base joins the lobes into one readable cloud silhouette.
		var base_puff := MeshInstance3D.new()
		base_puff.name = "Puff_Base"
		base_puff.mesh = _cloud_mesh
		base_puff.position = Vector3(0.0, -1.2, 0.0)
		base_puff.scale = Vector3(
			random.randf_range(10.5, 13.5),
			random.randf_range(2.2, 3.0),
			random.randf_range(6.0, 8.0)
		)
		base_puff.rotation_degrees.y = random.randf_range(-20.0, 20.0)
		base_puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		base_puff.add_to_group(&"low_poly_cloud_puff")
		cluster.add_child(base_puff)

		var puff_count := random.randi_range(6, 8)
		for puff_index: int in puff_count:
			var puff := MeshInstance3D.new()
			puff.name = "Puff_%02d" % puff_index
			puff.mesh = _cloud_mesh
			var spread := float(puff_index) / maxf(1.0, float(puff_count - 1)) - 0.5
			var arch_height := (1.0 - absf(spread) * 2.0) * 3.5
			puff.position = Vector3(
				spread * random.randf_range(17.0, 23.0) + random.randf_range(-1.8, 1.8),
				arch_height + random.randf_range(-0.5, 1.8),
				random.randf_range(-4.0, 4.0)
			)
			puff.scale = Vector3(
				random.randf_range(4.8, 7.4),
				random.randf_range(2.8, 4.6),
				random.randf_range(4.2, 6.5)
			)
			puff.rotation_degrees = Vector3(
				random.randf_range(-8.0, 8.0),
				random.randf_range(-35.0, 35.0),
				random.randf_range(-7.0, 7.0)
			)
			puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			puff.add_to_group(&"low_poly_cloud_puff")
			cluster.add_child(puff)


## Called by world/environment/playtest_atmosphere.gd every time it applies the atmosphere.
## `daylight` is 0 at full night and 1 with the sun up. `golden` peaks at 1 with the sun exactly on
## the horizon and falls to 0 either side of it — the deck is the highest thing in the level, so it
## is what the last of the sun actually hits. Presentation only; the clock behind both is
## host-authoritative.
##
## This is what F-065 was: the material is SHADING_MODE_UNSHADED, so no amount of dropping the sun's
## energy could ever darken a cloud. The tint has to be driven explicitly, and nothing was driving it.
func set_sky_light(daylight: float, golden: float) -> void:
	_daylight = clampf(daylight, 0.0, 1.0)
	_golden = clampf(golden, 0.0, 1.0)
	_apply_sky_light()


func _apply_sky_light() -> void:
	if _cloud_material == null:
		return
	var tint := CLOUD_NIGHT_TINT.lerp(CLOUD_DAY_TINT, _daylight)
	_cloud_material.albedo_color = tint.lerp(CLOUD_SUNSET_TINT, _golden * 0.8)


func _build_cloud_mesh() -> ArrayMesh:
	var phi := (1.0 + sqrt(5.0)) * 0.5
	var points: Array[Vector3] = [
		Vector3(-1.0, phi, 0.0).normalized(), Vector3(1.0, phi, 0.0).normalized(),
		Vector3(-1.0, -phi, 0.0).normalized(), Vector3(1.0, -phi, 0.0).normalized(),
		Vector3(0.0, -1.0, phi).normalized(), Vector3(0.0, 1.0, phi).normalized(),
		Vector3(0.0, -1.0, -phi).normalized(), Vector3(0.0, 1.0, -phi).normalized(),
		Vector3(phi, 0.0, -1.0).normalized(), Vector3(phi, 0.0, 1.0).normalized(),
		Vector3(-phi, 0.0, -1.0).normalized(), Vector3(-phi, 0.0, 1.0).normalized(),
	]
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var upper_color := Color(0.96, 0.94, 0.86, 1.0)
	var lower_color := Color(0.58, 0.62, 0.66, 1.0)
	for face: Vector3i in ICOSAHEDRON_FACES:
		var a := points[face.x]
		var b := points[face.y]
		var c := points[face.z]
		var normal := (b - a).cross(c - a).normalized()
		var face_color := lower_color.lerp(upper_color, smoothstep(-0.45, 0.8, normal.y))
		vertices.append(a)
		vertices.append(b)
		vertices.append(c)
		normals.append(normal)
		normals.append(normal)
		normals.append(normal)
		colors.append(face_color)
		colors.append(face_color)
		colors.append(face_color)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _cloud_material)
	return mesh
