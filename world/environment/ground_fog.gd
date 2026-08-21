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

## F-435. Resolution of the coarse terrain height map handed to the shader, per side. 64 is chosen
## against what it is FOR: the blight layer is metres thick and its job is to hug the ground, so
## relief finer than the layer itself changes nothing anyone can see, and every texel costs a
## `height_at()` call at level load. On a 590 m island that is ~9 m per texel and 4,096 calls, once.
const HEIGHT_FIELD_CELLS: int = 64
## F-435. How far above the highest terrain in the level the evaluation window has to reach. The
## box used to be sized for the MIST alone — `layer_height * HEADROOM_FACTOR` above `base_height`,
## which on a streamed island is a lid about 17 m over the waterline. The blight fog hugs the ground
## wherever the ground is, so on any terrain taller than that lid the layer was outside the window
## and evaluated for nobody. Comfortably clears the shader's own `BLIGHT_REACH_M` halo.
const BLIGHT_HEADROOM_M: float = 34.0

## How far out the evaluation window reaches. Beyond `Environment.volumetric_fog_length` (120 m by
## default) nothing is sampled at all, so there is no reason to pay for a wider box than that.
const EXTENT_M: float = 260.0
## Head-room above the mist layer, as a multiple of it. The layer fades out well before the top of
## the box; this is only so the fade is not clipped by the box's own lid.
const HEADROOM_FACTOR: float = 1.9
## How far above the water surface a measured mist datum is lifted when the terrain's own quarter-
## height lands underwater — see `_measure_base_height()`.
const WATER_CLEARANCE_M: float = 0.75

## Where the mist sits, in world Y. NAN means "measure it from the level's terrain the first frame
## that terrain exists" — see `_measure_base_height()`.
@export var base_height: float = NAN
@export_range(1.0, 60.0, 0.5) var layer_height: float = 9.0
@export_range(1.0, 80.0, 0.5) var pool_depth: float = 14.0
## Multiplied into the shader's own `base_density`. `PlaytestAtmosphere` drives this on the daylight
## curve — dawn and dusk are when a valley actually holds mist.
@export_range(0.0, 4.0, 0.01) var density_scale: float = 1.0

var _shader: Shader
## Highest terrain Y in the level, measured alongside `base_height`. NAN until then, in which case
## the window is sized exactly as it was before F-435.
var _terrain_top: float = NAN


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
		# Same frame the terrain first exists, and only ever once: this is the frame where
		# `height_at()` has something to answer with.
		_build_terrain_height_field()

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	place_window(camera.global_position)


## Places the evaluation window for an eye at [param eye], XZ only — the mist's height is a property
## of the world, not of where the camera happens to be, and following in Y is what would make a
## plateau look as foggy as the mere.
##
## Public because `_process()` is not the only thing that needs to drive it: a check that renders
## through a SubViewport of its own has no camera on the MAIN viewport, so the line above finds
## nothing and the window would sit at the world origin through every frame it photographs.
func place_window(eye: Vector3) -> void:
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
	return (_window_top() + _window_bottom()) * 0.5


func _apply_shape() -> void:
	size = Vector3(EXTENT_M, _window_top() - _window_bottom(), EXTENT_M)


## The lid. High enough for the mist, and — once the terrain has been measured — high enough that
## the blight fog's ground-hugging layer is inside the window on the tallest ground in the level.
func _window_top() -> float:
	var top := base_height + layer_height * HEADROOM_FACTOR
	if is_finite(_terrain_top):
		top = maxf(top, _terrain_top + BLIGHT_HEADROOM_M)
	return top


func _window_bottom() -> float:
	return base_height - pool_depth


func _push_parameters() -> void:
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return
	shader_material.set_shader_parameter(&"base_height", base_height)
	shader_material.set_shader_parameter(&"layer_height", layer_height)
	shader_material.set_shader_parameter(&"pool_depth", pool_depth)
	shader_material.set_shader_parameter(&"density_scale", density_scale)
	_push_mire_field(shader_material)


## F-435. A coarse height map of the level's own ground, so the blight fog hugs the terrain instead
## of the single `base_height` datum — which on a streamed island is pinned just above the waterline
## and would put the whole layer under the sea. See the shader's header for the full reasoning.
##
## Built ONCE, from whichever node in this level answers `height_at(x, z)` — the same duck-typed
## seam `_measure_base_height()` already uses for `water_surface_at`, so a procedural island and an
## authored map both work without this file knowing which it is in. A level with no such node leaves
## `terrain_field_ready` at 0 and the shader falls back to `base_height`, unchanged from before.
##
## The extent is the terrain's own measured AABB, NOT the Mire grid's: the two fields are sampled
## with separate uniforms precisely so neither has to be wrong for the other's sake.
func _build_terrain_height_field() -> void:
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return
	var provider: Node = _height_provider()
	if provider == null:
		return
	var half: float = _terrain_half_extent()
	if not is_finite(half) or half <= 0.0:
		return
	var image := Image.create_empty(
		HEIGHT_FIELD_CELLS, HEIGHT_FIELD_CELLS, false, Image.FORMAT_RF)
	var span: float = half * 2.0 / float(HEIGHT_FIELD_CELLS)
	var highest: float = -INF
	for cell_z: int in HEIGHT_FIELD_CELLS:
		var world_z: float = -half + (float(cell_z) + 0.5) * span
		for cell_x: int in HEIGHT_FIELD_CELLS:
			var world_x: float = -half + (float(cell_x) + 0.5) * span
			var height: float = float(provider.call(&"height_at", world_x, world_z))
			highest = maxf(highest, height)
			image.set_pixel(cell_x, cell_z, Color(height, 0.0, 0.0, 1.0))
	# The window's lid has to clear the tallest ground in the level, and this loop is the only place
	# that knows what that is: `_measure_base_height()`'s AABB covers the chunks RESIDENT at level
	# load, which on a streamed island is a few rings around the spawn and says nothing about the
	# plateau on the far side. Re-shaping here is what makes the blight fog exist up there.
	if is_finite(highest):
		_terrain_top = highest
		_apply_shape()
	shader_material.set_shader_parameter(
		&"terrain_height_field", ImageTexture.create_from_image(image))
	shader_material.set_shader_parameter(&"terrain_field_half_extent", half)
	shader_material.set_shader_parameter(&"terrain_field_ready", 1.0)


## The level node that can answer for its own ground. Searched up the ancestor chain first (the
## world root is this node's grandparent on every level that has an `Atmosphere`), then across the
## terrain group, so neither layout has to be assumed.
func _height_provider() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node.has_method(&"height_at"):
			return node
		node = node.get_parent()
	for terrain: Node in get_tree().get_nodes_in_group(TERRAIN_GROUP):
		if terrain.has_method(&"height_at"):
			return terrain
	return null


## Half the square the height map has to cover, in XZ.
##
## The terrain AABB alone is NOT enough and this is the trap worth naming: on a streamed world the
## group only holds the chunks currently resident around the player, so measured at level load it
## describes a few rings, not the island — and the shader maps [-half, +half] symmetrically about
## the origin, so an under-sized half would smear those few rings' heights across the whole map.
## `MireGrid`'s own half extent is the island's authored radius and is exactly right there; the
## AABB is exactly right on an authored map, which is fully resident from the first frame. The
## larger of the two is correct in both cases, and over-covering only costs resolution.
func _terrain_half_extent() -> float:
	var half: float = 0.0
	var mire_grid: Node = get_node_or_null(^"/root/MireGrid")
	if mire_grid != null and mire_grid.has_method(&"corruption_field_half_extent"):
		half = float(mire_grid.call(&"corruption_field_half_extent"))
	for node: Node in get_tree().get_nodes_in_group(TERRAIN_GROUP):
		var visual := node as VisualInstance3D
		if visual == null:
			continue
		var box: AABB = visual.global_transform * visual.get_aabb()
		half = maxf(half, maxf(absf(box.position.x), absf(box.end.x)))
		half = maxf(half, maxf(absf(box.position.z), absf(box.end.z)))
	return half if half > 0.0 else NAN


## F-435. Hands the fog shader the same live corruption field the terrain shader gets, so the low
## yellow-green blight fog and the purple ground agree about where the Mire is. Pushed once — the
## texture's RID never changes, only the image behind it — and silently skipped when there is no
## MireGrid, where `hint_default_black` leaves this shader exactly the pre-F-435 mist.
func _push_mire_field(shader_material: ShaderMaterial) -> void:
	var mire_grid: Node = get_node_or_null(^"/root/MireGrid")
	if mire_grid == null or not mire_grid.has_method(&"corruption_field_texture"):
		return
	shader_material.set_shader_parameter(
		&"mire_field", mire_grid.call(&"corruption_field_texture"))
	shader_material.set_shader_parameter(
		&"mire_field_half_extent", float(mire_grid.call(&"corruption_field_half_extent")))


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
	# F-435. Recorded here rather than in a second AABB walk: this is the only place in the file
	# that has the level's terrain bounds in hand.
	_terrain_top = bounds.end.y
	var measured: float = bounds.position.y + bounds.size.y * 0.25
	# Streamed terrain includes the seabed — the island falloff runs tens of metres below the
	# waterline — so a quarter-height datum measured off it sits underwater, where mist renders for
	# no one. The mist's datum is DRY low ground: when the world can say where its water is
	# (F-284's `water_surface_at` pair, on both map kinds), clamp to just above the surface at the
	# terrain's centre. An authored map with no water there answers -INF and is unchanged.
	var centre: Vector3 = bounds.get_center()
	for node: Node in get_tree().get_nodes_in_group(TERRAIN_GROUP):
		if not node.has_method(&"water_surface_at"):
			continue
		var water: float = float(node.call(&"water_surface_at", centre.x, centre.z))
		if is_finite(water):
			measured = maxf(measured, water + WATER_CLEARANCE_M)
		break
	return measured
