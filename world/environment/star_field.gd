extends Node3D

## Client-local night sky: a deterministic dome of star quads that fades in across dusk, plus the
## moon disc (F-378) — everything you can SEE at night. The moon's light, and the clock both halves
## ride, belong to `world/environment/playtest_atmosphere.gd`.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row): NONE — this is
## presentation only. Nothing here is replicated and no gameplay reads it back. The one number that
## drives it, time of day, is host-authoritative and arrives via DayNight -> Atmosphere, which calls
## set_night_amount() and set_sky_rotation() every time it applies the atmosphere.
##
## WHY GEOMETRY, NOT PhysicalSkyMaterial.night_sky (D-042): the same reason low_poly_clouds.gd is
## geometry. A panorama texture would have to be authored or generated into the repo, sits behind
## the engine's own scattering term where the fade cannot be tuned, and — the deciding argument on a
## project whose rule is "verify it yourself, headless" — cannot be asserted on without a
## framebuffer. A dome of quads is deterministic from a seed, costs one draw call, and
## tools/atmosphere_night_check.gd reads its alpha straight off the material.
##
## The dome rides the camera (top_level, position copied each frame), so stars never parallax as you
## cross a 356 m valley and the radius only has to clear the near geometry, not the map. Terrain
## still occludes them, because the quads are real geometry at dome_radius and depth-test normally.

## Deterministic layout. Change it and every star moves; leave it and two peers see the same sky.
const STAR_SEED: int = 20260818
## Stars sit on the cap above this height fraction, so none are buried under the horizon.
const HORIZON_FRACTION: float = 0.055
## Fraction of stars promoted to "hero" — bigger, full brightness, the ones you actually notice.
const HERO_FRACTION: float = 0.08
## Rim vertices per star. Each star is a fan: one full-alpha vertex at the centre and a ring of
## zero-alpha ones around it, so the hardware interpolates a soft round point out of flat geometry.
## Two triangles with uniform colour instead reads as a small square — the first version did, and
## the night render showed a sky full of confetti.
const STAR_RIM_POINTS: int = 6
## Celestial pole. Not straight up: a tilted axis makes the field wheel rather than spin flat.
const POLE_AXIS := Vector3(0.28, 0.93, 0.24)
const STAR_COOL := Color(0.72, 0.82, 1.0)
const STAR_WARM := Color(1.0, 0.86, 0.68)

## ── The moon (F-378) ──────────────────────────────────────────────────────────────────────────
## "there is no moon at night at all." `playtest_atmosphere.gd` now adds a second DirectionalLight3D
## for the light; this is the thing you can actually see, and it lives here because it is night sky
## and the night sky is already one draw call that rides the camera.
##
## It could NOT come from the sky material: `PhysicalSkyMaterial` draws a disc for LIGHT0 only, and
## the moon light is deliberately SKY_MODE_LIGHT_ONLY so it can never steal that slot from the sun
## (see the moon's factory in the atmosphere controller). So it is geometry, for the same three
## reasons D-042 chose geometry for the stars — deterministic, one draw call, and assertable
## headless without a framebuffer.
##
## A separate MeshInstance3D rather than more vertices in the star mesh, because the two do not move
## together: the star dome WHEELS about POLE_AXIS, while the moon tracks the sun's own antipode. It
## is a child of the dome all the same, so it inherits the camera-following transform for free —
## `_place_moon()` is what undoes the wheel.
##
## Rim points, not a quad: at 2 deg across, a square moon is unmistakably square. The disc is a fan
## with a full-alpha core ring and a zero-alpha outer ring, so the hardware interpolates one pixel
## of edge softening and nothing more — a moon needs a hard rim, which is the opposite of the soft
## point a star wants.
const MOON_TINT := Color(0.92, 0.95, 1.0)
const MOON_RIM_POINTS: int = 28
## Where the hard core ends and the one-pixel antialiasing ring begins, as a fraction of the radius.
const MOON_CORE_FRACTION: float = 0.94

@export_range(64, 2000, 1) var star_count: int = 520
## Inside tools/hollowmere_render_check.gd's 520 m far plane and the player camera's default, with
## room to spare. The dome follows the camera, so this is a distance from the eye, not from origin.
@export_range(80.0, 900.0, 1.0) var dome_radius: float = 380.0
## 0 = daylight, nothing drawn. 1 = full night. Atmosphere owns this; see set_night_amount().
@export_range(0.0, 1.0, 0.001) var night_amount: float = 0.0
@export var follow_camera: bool = true
## Apparent diameter of the moon, in degrees. Deliberately NOT the moon light's
## `light_angular_distance` (0.6 deg in `playtest_atmosphere.gd`): that number is the shadow
## penumbra and wants to be tight, this one is how big the moon LOOKS and wants to read across a
## 1280 px frame. The sun's disc is split between two knobs for exactly the same reason.
@export_range(0.2, 12.0, 0.05) var moon_angular_diameter_deg: float = 2.4

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _moon_instance: MeshInstance3D
var _moon_material: StandardMaterial3D
## Direction from the viewer TOWARD the moon, in world space — the atmosphere hands this over in
## world space on purpose, because the dome it is parented under is rotating underneath it.
var _moon_direction := Vector3.DOWN
var _sky_rotation: float = 0.0


func _ready() -> void:
	# The dome is a skybox: its transform is its own, whatever it happens to be parented under
	# (Atmosphere is a plain Node, with no transform to inherit in the first place).
	top_level = true
	rebuild_stars()
	_apply_night_amount()


func _process(_delta: float) -> void:
	_follow_camera()


## Rebuilds the whole field from STAR_SEED. Safe to call again — it frees what it built last time.
func rebuild_stars() -> void:
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		_mesh_instance.queue_free()
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Additive, so a star adds light to the sky behind it instead of punching a hole in it, and so
	# the field disappears cleanly into a bright sky rather than greying it out.
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# Every quad is built facing the dome centre, but CULL_DISABLED means a winding mistake can
	# never cost us half the sky.
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_material.disable_receive_shadows = true
	_material.disable_ambient_light = true
	_material.albedo_color = Color(1.0, 1.0, 1.0, night_amount)

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "StarDome"
	_mesh_instance.mesh = _build_star_mesh()
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_mesh_instance)
	_rebuild_moon()


## The moon disc (F-378). Rebuilt alongside the stars so a caller that re-seeds the field gets a
## whole night sky back, not most of one.
func _rebuild_moon() -> void:
	if _moon_instance != null and is_instance_valid(_moon_instance):
		_moon_instance.queue_free()
	_moon_material = StandardMaterial3D.new()
	_moon_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_moon_material.vertex_color_use_as_albedo = true
	_moon_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Additive, like the stars: the moon ADDS to the sky behind it rather than punching a hole in
	# it, so it fades out cleanly into a brightening dawn instead of leaving a grey coin in the sky.
	_moon_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_moon_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_moon_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_moon_material.disable_receive_shadows = true
	_moon_material.disable_ambient_light = true
	_moon_material.albedo_color = Color(1.0, 1.0, 1.0, night_amount)

	_moon_instance = MeshInstance3D.new()
	_moon_instance.name = "MoonDisc"
	_moon_instance.mesh = _build_moon_mesh()
	_moon_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_moon_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_moon_instance.visible = false
	add_child(_moon_instance)
	_place_moon()


## 0 = daylight, 1 = full night. Drives the material alpha, which multiplies each star's own
## vertex alpha, so the whole field dims together while keeping its brightness variety.
func set_night_amount(value: float) -> void:
	night_amount = clampf(value, 0.0, 1.0)
	_apply_night_amount()


## Wheels the field about POLE_AXIS. Atmosphere passes the day's own angle, so the stars track the
## same clock the sun does instead of hanging fixed all night.
func set_sky_rotation(radians: float) -> void:
	_sky_rotation = radians
	_apply_transform(global_position)
	# The wheel just moved under the moon, so its place in the dome's frame changed even though its
	# place in the sky did not.
	_place_moon()


## Where the moon is, as a direction from the viewer toward it in WORLD space. `playtest_atmosphere.gd`
## passes the moon light's own `global_basis.z`, so the disc and the light that casts the shadows
## are the same object by construction and cannot drift apart (F-378).
func set_moon_direction(direction: Vector3) -> void:
	if direction.length_squared() < 0.000001:
		return
	_moon_direction = direction.normalized()
	_place_moon()


## Puts the disc on the dome in the direction the atmosphere last gave, undoing the star wheel's own
## rotation on the way — the dome spins about POLE_AXIS and the moon does not, so a moon parented
## under it has to be expressed in the dome's frame or it would slide across the sky all night.
##
## Hidden below the horizon rather than drawn and occluded: the dome is only 380 m across and the
## terrain that would hide it is the player's own hill, so a moon at -0.4 elevation would otherwise
## be a bright disc sitting underground a short walk away.
func _place_moon() -> void:
	if _moon_instance == null or not is_instance_valid(_moon_instance):
		return
	var above_horizon: bool = _moon_direction.y > 0.0
	_moon_instance.visible = above_horizon and night_amount > 0.001
	if not _moon_instance.visible:
		return
	var local: Vector3 = global_transform.basis.inverse() * _moon_direction
	# The disc is rotationally symmetric and CULL_DISABLED, so which way is "up" on it does not
	# matter — the guard is only here because Basis.looking_at() errors when the two are parallel,
	# and a moon directly overhead at midnight is not a corner case, it is every midnight.
	var up: Vector3 = Vector3.UP if absf(local.y) < 0.99 else Vector3.RIGHT
	_moon_instance.transform = Transform3D(Basis.looking_at(local, up), local * dome_radius)


func _apply_night_amount() -> void:
	if _material != null:
		_material.albedo_color = Color(1.0, 1.0, 1.0, night_amount)
	if _moon_material != null:
		_moon_material.albedo_color = Color(1.0, 1.0, 1.0, night_amount)
	var lit: bool = night_amount > 0.001
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		_mesh_instance.visible = lit
	_place_moon()
	# Daylight costs nothing: no per-frame camera follow while the field is invisible. Snap the
	# transform once on the way back in so the first visible frame is already in the right place.
	set_process(lit and follow_camera)
	if lit:
		_follow_camera()


func _follow_camera() -> void:
	if not follow_camera or not is_inside_tree():
		return
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var camera: Camera3D = viewport.get_camera_3d()
	if camera == null:
		return
	_apply_transform(camera.global_position)


func _apply_transform(where: Vector3) -> void:
	global_transform = Transform3D(Basis(POLE_AXIS.normalized(), _sky_rotation), where)


## One flat disc in the XY plane, normal +Z, centred on the origin — `_place_moon()` is what puts it
## somewhere. Sized off `dome_radius` so the ANGULAR diameter is what the export says regardless of
## how far out the dome happens to sit.
func _build_moon_mesh() -> ArrayMesh:
	var half_angle: float = deg_to_rad(moon_angular_diameter_deg) * 0.5
	var radius: float = dome_radius * tan(half_angle)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var core: Color = MOON_TINT
	var rim := Color(MOON_TINT.r, MOON_TINT.g, MOON_TINT.b, 0.0)
	var normal := Vector3(0.0, 0.0, 1.0)
	for edge: int in MOON_RIM_POINTS:
		var angle_a: float = TAU * float(edge) / float(MOON_RIM_POINTS)
		var angle_b: float = TAU * float(edge + 1) / float(MOON_RIM_POINTS)
		var inner_a := Vector3(cos(angle_a), sin(angle_a), 0.0) * radius * MOON_CORE_FRACTION
		var inner_b := Vector3(cos(angle_b), sin(angle_b), 0.0) * radius * MOON_CORE_FRACTION
		var outer_a := Vector3(cos(angle_a), sin(angle_a), 0.0) * radius
		var outer_b := Vector3(cos(angle_b), sin(angle_b), 0.0) * radius
		# The solid core, as a fan from the centre.
		for corner: Array in [
			[Vector3.ZERO, core], [inner_a, core], [inner_b, core]
		]:
			vertices.append(corner[0] as Vector3)
			normals.append(normal)
			colors.append(corner[1] as Color)
		# The one-pixel rim that keeps the circle from stair-stepping, as a quad per segment.
		for corner: Array in [
			[inner_a, core], [outer_a, rim], [outer_b, rim],
			[inner_a, core], [outer_b, rim], [inner_b, core]
		]:
			vertices.append(corner[0] as Vector3)
			normals.append(normal)
			colors.append(corner[1] as Color)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _moon_material)
	# Same reasoning as the star dome's: the disc is a few metres of geometry that lives 380 m from
	# the camera and moves every frame, so the culler must not be given a tight local box to test.
	mesh.custom_aabb = AABB(
		Vector3.ONE * -dome_radius * 1.05, Vector3.ONE * dome_radius * 2.1
	)
	return mesh


## One ArrayMesh, one surface, one draw call. Each star is a quad in the plane tangent to the dome,
## which faces the centre exactly — a billboard without needing a shader to billboard it.
func _build_star_mesh() -> ArrayMesh:
	var random := RandomNumberGenerator.new()
	random.seed = STAR_SEED
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	for star_index: int in star_count:
		# Uniform by area over the cap above HORIZON_FRACTION: pick height first, then the ring
		# angle. Picking a polar angle instead would crowd the zenith.
		var height := random.randf_range(HORIZON_FRACTION, 1.0)
		var ring_radius := sqrt(maxf(0.0, 1.0 - height * height))
		var ring_angle := random.randf_range(0.0, TAU)
		var direction := Vector3(
			cos(ring_angle) * ring_radius, height, sin(ring_angle) * ring_radius
		).normalized()

		var is_hero := random.randf() < HERO_FRACTION
		var half_size := dome_radius * random.randf_range(0.0016, 0.0034)
		if is_hero:
			half_size *= 2.0
		# Squared bias keeps most stars cool-white and only a few warm, which is what a real field
		# looks like and what stops it reading as confetti.
		var tint := STAR_COOL.lerp(STAR_WARM, pow(random.randf(), 2.2))
		tint.a = 1.0 if is_hero else random.randf_range(0.22, 0.72)

		var centre := direction * dome_radius
		var inward := -direction
		var right := inward.cross(Vector3.UP)
		if right.length_squared() < 0.0001:
			right = inward.cross(Vector3.RIGHT)
		right = right.normalized() * half_size
		var up := inward.cross(right).normalized() * half_size

		var core := tint
		var rim := Color(tint.r, tint.g, tint.b, 0.0)
		for edge: int in STAR_RIM_POINTS:
			var angle_a := TAU * float(edge) / float(STAR_RIM_POINTS)
			var angle_b := TAU * float(edge + 1) / float(STAR_RIM_POINTS)
			var point_a := centre + right * cos(angle_a) + up * sin(angle_a)
			var point_b := centre + right * cos(angle_b) + up * sin(angle_b)
			for corner: Array in [[centre, core], [point_a, rim], [point_b, rim]]:
				vertices.append(corner[0] as Vector3)
				normals.append(inward)
				colors.append(corner[1] as Color)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	# The dome always surrounds the camera, so its real AABB is the only correct one; without this
	# a frustum test on a 380 m box can pop the whole sky out when you look at the horizon.
	mesh.custom_aabb = AABB(
		Vector3.ONE * -dome_radius * 1.05, Vector3.ONE * dome_radius * 2.1
	)
	return mesh
