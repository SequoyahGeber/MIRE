extends Node3D

## TitleBackdrop — MENU-3: the live island behind the title screen (docs/MENU.md §4).
##
## The backdrop IS the pitch. DESIGN.md's whole structural idea is "the island is the health bar",
## so the first thing a stranger sees is an island at warm low sun with the Mire's purple-black
## stain visibly eating one shoreline. No text has to explain the game; the menu is a picture of it.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local presentation, the table's
## free last row. Nothing here is replicated, and this scene never exists while a session is open:
## `frontend.gd` frees the whole front end before the world scene loads.
##
## ## Why this builds its own mesh instead of instantiating the real world
##
## It samples the REAL heightmap — `world/gen/island_heightmap.gd`, the same pure `height()` the
## game generates from — so the island on the title screen is an honest MIRE island for that seed,
## not an artist's impression of one. What it does NOT do is instantiate `ProceduralWorld`: that
## would bake navigation, build collision, scatter resources and spawn entities, all for a picture
## nobody can walk on. A menu that pays a full world generation before it draws its first frame is
## the wrong trade, and a front end holding live gameplay entities is a category error that would
## surface later as "why did the menu tick the wave director".
##
## The mesh is flat-shaded with unshared vertices (DESIGN.md §6: flat-shaded low-poly, strong
## silhouettes) and coloured by height band, with the Mire overlaid in the fragment shader from a
## world-space distance to a moving origin — so corruption spreads smoothly without ever rebuilding
## or re-uploading the mesh.
##
## ## The daily seed
##
## The island is drawn from a date-derived seed, so everyone launching MIRE on the same day sees the
## same island on the title screen — a free shared-world touch that costs one line and gives friends
## something to notice. It is cosmetic: nothing about a run's seed comes from here.

const Heightmap := preload("res://world/gen/island_heightmap.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")

## Half-width of the sampled patch, in metres. Wider than the island's own 118 m radius so the
## shoreline is never the edge of the mesh — open water has to continue past the land or the
## silhouette reads as a floating tile.
const PATCH_EXTENT: float = 150.0
## Metres between samples. 3 m gives ~100×100 quads: enough for a readable silhouette and the
## faceting the art direction wants, cheap enough to build in one frame at boot.
const SAMPLE_STEP: float = 3.0

## Relief amplitudes passed to the heightmap, which takes both as first-class parameters (they are
## how a biome authors its own roughness). The island's SHAPE — its coastline, lobes, river mouth,
## the thing that makes it this seed's island and not another's — is untouched; only the fine
## ridge and detail relief is eased. At the 240 m the backdrop camera sits at, full ridge amplitude
## resolves into a field of small sharp spikes that reads as noise rather than as terrain, and
## competes with the menu text for the eye.
const BACKDROP_DETAIL_AMPLITUDE: float = 0.85
const BACKDROP_RIDGE_AMPLITUDE: float = 0.62

## Every land vertex drops by this much before the water plane is laid at y = 0, which is what makes
## a beach: anything the heightmap put below this is simply under the water. It also guarantees the
## flat open-sea floor sits safely beneath the water plane instead of z-fighting it.
const SHORE_DROP: float = 0.8

## Height bands, in metres above the dropped surface. Hard boundaries on purpose — with flat shading
## a crisp band reads as deliberate stylisation, where a soft gradient reads as a bad texture.
const BAND_SAND: float = 1.4
const BAND_GRASS: float = 7.0
const BAND_FOREST: float = 15.0

const COLOUR_SAND := Color(0.78, 0.71, 0.52)
const COLOUR_GRASS := Color(0.31, 0.46, 0.26)
const COLOUR_FOREST := Color(0.21, 0.35, 0.22)
const COLOUR_ROCK := Color(0.44, 0.43, 0.40)

## Where the corruption eats in from, and how far it gets. Off-centre and beyond the shoreline so it
## arrives from the sea at one edge rather than blooming out of the middle of the island.
const MIRE_ORIGIN := Vector3(-104.0, 0.0, 88.0)
const MIRE_RADIUS_START: float = 26.0
## Deliberately short of consuming the island. The title screen shows a game being lost, not a game
## already over — and a backdrop that ends up fully purple has nowhere left to go.
const MIRE_RADIUS_END: float = 132.0
const MIRE_CREEP_SECONDS: float = 150.0
const MIRE_EDGE_SOFTNESS: float = 22.0

## Camera drift: a slow arc offshore, high enough to see the island AS an island. Small numbers on
## the motion — this is a breath, not a flythrough, and anything faster fights the menu text for
## attention.
##
## The height is the parameter that took a render to get right. At boat height the ridgelines stack
## up into a jagged wall on the horizon and the shot reads as a mountain range; the whole point of
## the backdrop is the SHAPE of a landmass with water all the way around it, which only appears once
## the camera is well above the tallest ridge and looking slightly down.
const CAMERA_DISTANCE: float = 240.0
const CAMERA_HEIGHT: float = 76.0
const CAMERA_LOOK_AT := Vector3(0.0, 2.0, 0.0)
const CAMERA_SWING_DEGREES: float = 7.0
const CAMERA_SWING_SECONDS: float = 74.0
const CAMERA_BOB_METRES: float = 1.6
const CAMERA_BOB_SECONDS: float = 11.0

var _camera: Camera3D
var _island: MeshInstance3D
var _island_material: ShaderMaterial
var _elapsed: float = 0.0
var _seed: int = 0


func _ready() -> void:
	_seed = daily_seed()
	_build_environment()
	_build_sun()
	_build_island(_seed)
	_build_water()
	_build_camera()
	_apply_drift(0.0)


func _process(delta: float) -> void:
	# Reduce motion freezes the drift and the creep at their opening values rather than snapping to
	# the end state: for an ambient backdrop "still" is the correct reduced form of "drifting", where
	# jumping to a fully-corrupted island would change what the screen says (docs/MENU.md §3.4).
	if MireTheme.motion_scale() <= 0.0:
		return
	_elapsed += delta
	_apply_drift(_elapsed)
	_apply_creep(_elapsed)


## The island everyone sees today. Date-derived rather than random so it is the same for every
## player on a given day, and never zero (the heightmap treats a seed as an arbitrary int, but a
## zero seed is the value every "unset" bug produces, so it is worth not being able to hit).
static func daily_seed() -> int:
	var date: Dictionary = Time.get_date_dict_from_system(true)
	var packed: int = int(date.get("year", 2026)) * 10000 + int(date.get("month", 1)) * 100 + int(date.get("day", 1))
	var value: int = hash(packed)
	return value if value != 0 else 1


func seed_value() -> int:
	return _seed


func camera() -> Camera3D:
	return _camera


## 0 at boot, 1 once the corruption has finished creeping. The check reads this rather than timing
## the tween, so it can assert the direction of travel without waiting 150 seconds.
func creep_fraction() -> float:
	return clampf(_elapsed / MIRE_CREEP_SECONDS, 0.0, 1.0)


func mire_radius() -> float:
	if _island_material == null:
		return 0.0
	return float(_island_material.get_shader_parameter("mire_radius"))


# ── Build ─────────────────────────────────────────────────────────────────────────────────────────


## Warm low sun, blue-scattered sky, and fog that sits on the ground rather than washing the whole
## frame. The art direction is explicit that flat even lighting and full-screen haze are both wrong:
## depth fog alone greys everything equally, so the height-fog terms below keep the murk in the
## hollows and leave the sky and the hilltops clear.
func _build_environment() -> void:
	var sky_material := PhysicalSkyMaterial.new()
	sky_material.rayleigh_coefficient = 2.6
	sky_material.rayleigh_color = Color(0.24, 0.42, 0.88)
	sky_material.mie_coefficient = 0.0062
	sky_material.mie_eccentricity = 0.78
	sky_material.mie_color = Color(0.96, 0.74, 0.51)
	sky_material.turbidity = 7.0
	# A modest disk: at 4.0 the sun blew a white column down the water that read as a rendering
	# fault rather than a sunset, and swallowed the corner of the frame the expedition card sits in.
	sky_material.sun_disk_scale = 1.8
	sky_material.ground_color = Color(0.05, 0.08, 0.07)
	sky_material.energy_multiplier = 1.0

	var sky := Sky.new()
	sky.sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 0.72
	environment.ambient_light_energy = 0.85

	environment.fog_enabled = true
	environment.fog_light_color = Color(0.66, 0.69, 0.60)
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = 0.36
	# Deliberately faint. The first cut ran an order of magnitude thicker and produced exactly the
	# full-screen haze the art direction rules out: the island greyed out into the sky and the whole
	# frame read as weather rather than as a place. Depth fog here only softens the far shore; the
	# murk that gives the bog its character comes from the height terms below, which sit ON the
	# water and are gone before they reach the ridgelines.
	environment.fog_density = 0.0006
	environment.fog_aerial_perspective = 0.12
	environment.fog_height = 2.0
	environment.fog_height_density = 0.020

	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_white = 1.4

	# Enough bloom to get the warm scatter around the sun the art direction asks for, not enough to
	# blow the highlight into the menu text.
	environment.glow_enabled = true
	environment.glow_intensity = 0.16
	environment.glow_bloom = 0.03

	var holder := WorldEnvironment.new()
	holder.name = "BackdropEnvironment"
	holder.environment = environment
	add_child(holder)


func _build_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "BackdropSun"
	sun.light_color = Color(1.0, 0.87, 0.66)
	sun.light_energy = 1.45
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 320.0
	# Low and raking, from behind-left of the camera: long shadows down the island's flanks are what
	# make a low-poly silhouette read as landscape instead of as a shape.
	sun.rotation_degrees = Vector3(-16.0, 138.0, 0.0)
	add_child(sun)


func _build_island(world_seed: int) -> void:
	var noise_set: Variant = Heightmap.make_noise_set(world_seed)

	var steps: int = int((PATCH_EXTENT * 2.0) / SAMPLE_STEP)
	# One height sample per grid corner, taken once and reused by the four quads that share it —
	# sampling per triangle instead would multiply the cost of the whole build by six.
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize((steps + 1) * (steps + 1))
	for iz: int in steps + 1:
		for ix: int in steps + 1:
			var x: float = -PATCH_EXTENT + float(ix) * SAMPLE_STEP
			var z: float = -PATCH_EXTENT + float(iz) * SAMPLE_STEP
			var raw: float = float(Heightmap.height_from_set(
				x, z, noise_set, world_seed, BACKDROP_DETAIL_AMPLITUDE, BACKDROP_RIDGE_AMPLITUDE
			))
			heights[iz * (steps + 1) + ix] = raw - SHORE_DROP

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()

	for iz: int in steps:
		for ix: int in steps:
			var x0: float = -PATCH_EXTENT + float(ix) * SAMPLE_STEP
			var z0: float = -PATCH_EXTENT + float(iz) * SAMPLE_STEP
			var x1: float = x0 + SAMPLE_STEP
			var z1: float = z0 + SAMPLE_STEP

			var a := Vector3(x0, heights[iz * (steps + 1) + ix], z0)
			var b := Vector3(x1, heights[iz * (steps + 1) + ix + 1], z0)
			var c := Vector3(x1, heights[(iz + 1) * (steps + 1) + ix + 1], z1)
			var d := Vector3(x0, heights[(iz + 1) * (steps + 1) + ix], z1)

			_add_triangle(vertices, normals, colours, a, b, c)
			_add_triangle(vertices, normals, colours, a, c, d)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_island_material = ShaderMaterial.new()
	_island_material.shader = _island_shader()
	_island_material.set_shader_parameter("mire_origin", MIRE_ORIGIN)
	_island_material.set_shader_parameter("mire_radius", MIRE_RADIUS_START)
	_island_material.set_shader_parameter("mire_softness", MIRE_EDGE_SOFTNESS)
	_island_material.set_shader_parameter("mire_colour", Vector3(MireTheme.MIRE.r, MireTheme.MIRE.g, MireTheme.MIRE.b))

	_island = MeshInstance3D.new()
	_island.name = "BackdropIsland"
	_island.mesh = mesh
	_island.material_override = _island_material
	add_child(_island)


## One flat-shaded triangle: three unshared vertices sharing one face normal. Sharing vertices
## between faces would average the normals and give the smooth shading the art direction is
## explicitly not asking for.
func _add_triangle(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colours: PackedColorArray,
	a: Vector3,
	b: Vector3,
	c: Vector3,
) -> void:
	var normal: Vector3 = (c - a).cross(b - a).normalized()
	var colour: Color = _band_colour((a.y + b.y + c.y) / 3.0)
	for vertex: Vector3 in [a, b, c]:
		vertices.append(vertex)
		normals.append(normal)
		colours.append(colour)


func _band_colour(height: float) -> Color:
	if height < BAND_SAND:
		return COLOUR_SAND
	if height < BAND_GRASS:
		return COLOUR_GRASS
	if height < BAND_FOREST:
		return COLOUR_FOREST
	return COLOUR_ROCK


## Land colour comes from the mesh's own vertex colours; the Mire is laid over it per-fragment from
## a world-space distance, so the corruption front can move every frame without touching the mesh.
func _island_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform vec3 mire_origin;
uniform float mire_radius;
uniform float mire_softness;
uniform vec3 mire_colour;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float distance_to_origin = distance(world_position.xz, mire_origin.xz);
	float corruption = 1.0 - smoothstep(mire_radius - mire_softness, mire_radius, distance_to_origin);
	vec3 land = COLOR.rgb;
	// Drain, tint, THEN darken. The darkening multiply is the important step: tinting alone turned
	// bright sand and rock into a pale mauve that read as dead grass, when DESIGN calls for
	// purple-black. Corrupted ground has to be markedly darker than healthy ground, or the Mire
	// looks like a season rather than a disease.
	float grey = dot(land, vec3(0.299, 0.587, 0.114));
	vec3 rotted = mix(vec3(grey), mire_colour, 0.85) * 0.22;
	ALBEDO = mix(land, rotted, corruption);
	ROUGHNESS = mix(0.96, 0.62, corruption);
	// A warm low sun at this energy washes a merely-dark albedo back out to dusty pink, which is
	// what the first two attempts at this actually rendered: corrupted cliffs came out lighter than
	// the healthy grass beside them. Driving the albedo far down and carrying the hue in a faint
	// emission instead keeps the Mire purple under direct sun and stops it going flat black in
	// shadow — it should look lit from within, not merely unlit.
	EMISSION = mire_colour * 0.075 * corruption;
}
"""
	return shader


## Bog water: dark, wet, and just reflective enough to catch the low sun. Sized past the sampled
## patch so the horizon is water, never the mesh's cut edge.
func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(2400.0, 2400.0)

	var material := StandardMaterial3D.new()
	# Opaque, deliberately. Translucent water let the sampled patch's flat sea floor show through as
	# a huge dark rectangle with a visible cut edge running across the frame — the mesh's boundary,
	# announcing itself. Opaque water hides the seabed entirely and the horizon becomes the only
	# edge in the shot, which is what "an island in open sea" needs.
	material.albedo_color = Color(0.068, 0.125, 0.116)
	material.metallic = 0.32
	material.roughness = 0.12
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	var water := MeshInstance3D.new()
	water.name = "BackdropWater"
	water.mesh = plane
	water.material_override = material
	add_child(water)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "BackdropCamera"
	_camera.fov = 58.0
	_camera.far = 2600.0
	_camera.current = true
	add_child(_camera)


# ── Drift ─────────────────────────────────────────────────────────────────────────────────────────


## A slow arc plus a gentle bob, both sine-driven and both small. `sin` is fine here where it would
## not be in worldgen: nothing about a camera path has to be bit-identical across platforms (D-017's
## determinism rule is about generated WORLD state, and this is a picture).
func _apply_drift(time: float) -> void:
	if _camera == null:
		return
	var swing: float = sin(time * TAU / CAMERA_SWING_SECONDS) * deg_to_rad(CAMERA_SWING_DEGREES)
	var bob: float = sin(time * TAU / CAMERA_BOB_SECONDS) * CAMERA_BOB_METRES
	var position := Vector3(
		sin(swing) * CAMERA_DISTANCE,
		CAMERA_HEIGHT + bob,
		cos(swing) * CAMERA_DISTANCE
	)
	_camera.position = position
	_camera.look_at(CAMERA_LOOK_AT, Vector3.UP)


## The corruption front, easing outward and settling rather than stopping dead — the island should
## look like it is still losing even once the creep has run its course.
func _apply_creep(time: float) -> void:
	if _island_material == null:
		return
	var t: float = clampf(time / MIRE_CREEP_SECONDS, 0.0, 1.0)
	var eased: float = 1.0 - (1.0 - t) * (1.0 - t)
	_island_material.set_shader_parameter(
		"mire_radius", lerpf(MIRE_RADIUS_START, MIRE_RADIUS_END, eased)
	)
