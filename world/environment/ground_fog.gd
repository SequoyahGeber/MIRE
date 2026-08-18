extends FogVolume

## Procedural ground mist that follows the camera (F-115).
##
## ## Why this is a node and not an Environment setting
##
## `Environment.volumetric_fog_density` is ONE number for the whole 120 m froxel volume, so every
## value of it is a flat, even haze — thin enough to be pointless or thick enough to grey out the
## world, and never "low over the mere and clear on the plateau". The shipped map had the second
## kind and nothing else, because the three `FogVolume` nodes `playtest_atmosphere.gd` was written
## to drive (`MireGroundFog`, `ForestMist`, `RuinsMist`) belong to Playtest Hollow and were never
## in Hollowmere.
##
## `world/environment/ground_fog.gdshader` computes density from WORLD POSITION, so this node is
## only a window that says "evaluate the mist here". It slides along with the camera and the mist
## does not slide with it: banks stay where they are in the world, thin out with height, thicken in
## hollows, and drift on their own clock.
##
## ## Built from code, never placed in a level (same reasoning as the star field)
##
## Release worlds are procedurally generated, so a mist that has to be remembered and placed by a
## level author is a mist that generated worlds will not have. `PlaytestAtmosphere` creates one of
## these for any level that has an `Atmosphere` node, and it needs no authored values: the height
## the mist sits at is measured off the level's own terrain.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2, "VFX, audio, camera, UI". Every peer runs its own copy from its own
## camera and nothing crosses the wire — two players standing in different valleys are each meant
## to see different fog. It also switches itself off wholesale on the `low` graphics preset, which
## disables volumetric fog on the Environment and makes every FogVolume a no-op for free.

const SHADER_PATH: String = "res://world/environment/ground_fog.gdshader"
const TERRAIN_GROUP: StringName = &"authored_world_terrain"

## How far out the evaluation window reaches. Beyond `Environment.volumetric_fog_length` (120 m by
## default) nothing is sampled at all, so there is no reason to pay for a wider box than that.
const EXTENT_M: float = 260.0
## Head-room above the mist layer, as a multiple of it. The layer fades out well before the top of
## the box; this is only so the fade is not clipped by the box's own lid.
const HEADROOM_FACTOR: float = 1.9

## Where the mist sits, in world Y. NAN means "measure it from the level's terrain the first frame
## that terrain exists" — see `_measure_base_height()`.
@export var base_height: float = NAN
@export_range(1.0, 60.0, 0.5) var layer_height: float = 9.0
@export_range(1.0, 80.0, 0.5) var pool_depth: float = 14.0
## Multiplied into the shader's own `base_density`. `PlaytestAtmosphere` drives this on the daylight
## curve — dawn and dusk are when a valley actually holds mist.
@export_range(0.0, 4.0, 0.01) var density_scale: float = 1.0

var _shader: Shader


func _ready() -> void:
	shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		push_error("GroundFog cannot load %s" % SHADER_PATH)
		set_process(false)
		return
	# A FogVolume takes EITHER a `FogMaterial` — one constant density, which is the flat haze this
	# file exists to stop — or a `ShaderMaterial` whose shader is `shader_type fog`. It is the
	# second one.
	var shader_material := ShaderMaterial.new()
	shader_material.shader = _shader
	material = shader_material

	_apply_shape()
	_push_parameters()
	set_process(true)


## Keeps the evaluation window centred on whoever is looking. Only XZ: the mist's height is a
## property of the world, not of where the camera happens to be, and following in Y is what would
## make a plateau look as foggy as the mere.
func _process(_delta: float) -> void:
	# Measured here rather than in `_ready()` because the terrain does not exist yet at that point:
	# `Atmosphere` is an earlier sibling than `World` in the level scene, so its `_ready()` runs
	# first and finds an empty group. The first version of this measured once, got nothing, and
	# silently sat the mist at y=0 — 4 m too low, which on this map is under the valley floor.
	if is_nan(base_height):
		var measured := _measure_base_height()
		if is_nan(measured):
			return
		base_height = measured
		_apply_shape()
		_push_parameters()

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var eye := camera.global_position
	global_position = Vector3(eye.x, _centre_height(), eye.z)


## Drives the daylight response from `PlaytestAtmosphere`. Colour is passed in rather than derived
## here so the mist, the sky and the god rays cannot disagree about what time it is.
func apply_look(scale: float, albedo: Color, emission: Color, emission_energy: float) -> void:
	density_scale = maxf(scale, 0.0)
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return
	shader_material.set_shader_parameter(&"density_scale", density_scale)
	shader_material.set_shader_parameter(&"fog_albedo", albedo)
	shader_material.set_shader_parameter(&"fog_emission", emission)
	shader_material.set_shader_parameter(&"emission_energy", emission_energy)


func _centre_height() -> float:
	var top := base_height + layer_height * HEADROOM_FACTOR
	var bottom := base_height - pool_depth
	return (top + bottom) * 0.5


func _apply_shape() -> void:
	var height := layer_height * HEADROOM_FACTOR + pool_depth
	size = Vector3(EXTENT_M, height, EXTENT_M)


func _push_parameters() -> void:
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return
	shader_material.set_shader_parameter(&"base_height", base_height)
	shader_material.set_shader_parameter(&"layer_height", layer_height)
	shader_material.set_shader_parameter(&"pool_depth", pool_depth)
	shader_material.set_shader_parameter(&"density_scale", density_scale)


## Where the mist sits, measured off the level rather than authored per map.
##
## A quarter of the way up the terrain's own height range: on Hollowmere that is about y=4, which
## puts mist over the mere (-3.2), the fen (-1.2), the river and the valley floor (median 4.5) and
## leaves the plateau (23 m) standing clear above it — the view this whole file exists to produce.
## A generated world gets the same relationship to its own terrain without anyone tuning a number.
func _measure_base_height() -> float:
	var bounds := AABB()
	var found := false
	for node: Node in get_tree().get_nodes_in_group(TERRAIN_GROUP):
		var visual := node as VisualInstance3D
		if visual == null:
			continue
		var world_box: AABB = visual.global_transform * visual.get_aabb()
		bounds = world_box if not found else bounds.merge(world_box)
		found = true
	# NAN, never a guess: "no terrain in the tree yet" and "terrain that happens to sit at y=0" are
	# different answers, and only the first one should be retried next frame.
	if not found or bounds.size.y <= 0.0:
		return NAN
	return bounds.position.y + bounds.size.y * 0.25
