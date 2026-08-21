extends SceneTree

## Renders the shipped map at several times of day to PNGs, so a change to the LOOK can be judged
## by looking at it instead of by reading the diff.
##
## Needs a real renderer, so run it windowed. The wrapper forces a 64x64 window (F-077), which is
## why this renders through a SubViewport of its own size rather than through the main window — the
## window is irrelevant, only the renderer has to be real.
##
##   .agent/bin/agent godot --windowed --script tools/atmosphere_look_shot.gd
##
## Writes to `user://atmosphere_look/`; the run prints the absolute paths.
##
## ── Every camera used to be a hardcoded world position, and that broke (F-398) ─────────────────
## The shot table was authored against a 118 m island whose terrain topped out a couple of metres
## above the sea. `IslandHeightmap.ISLAND_RADIUS` is 295 m now and the hills are taller, and the
## consequence was not subtle: re-run as it stood, `forest_sunward` rendered the inside of a
## hillside (a black wall filling the left third of frame), `canopy_leaves` rendered the underside
## of the terrain over open water, and the six ground shots at (6, 6, 34) sat on bare hilltop with
## not one tree, rock or prop anywhere in frame. Nineteen renders, nothing to judge in any of them —
## and a grade pass judged on those frames would have been tuned against an empty hillside.
##
## So no shot names a world position any more. Every one is an offset from the world's OWN spawn
## point along the axis pointing at the island's centre, put at the ground height the world reports
## for that spot plus an eye height, with the chunk streamer primed around it first. That survives
## the next island resize, the next terrain retune, and a different seed, none of which a literal
## `Vector3(6, 6, 34)` does.
##
## Each shot prints how many scattered props are standing within `PROP_CENSUS_RADIUS_M` of the
## camera. That line is the honest answer to "was there anything in frame to look at" — a shot
## reporting `props=0` is a shot nobody should draw a conclusion from, whatever it looks like.

const WIDTH: int = 1280
const HEIGHT: int = 720
const OUT_DIR: String = "user://atmosphere_look"

## Standing eye height. The default for every ground shot, because the whole point of these frames
## is what the game looks like from where the player's head actually is.
const EYE_HEIGHT_M: float = 1.7
## How far out the per-shot prop census counts. Roughly "the near half of the frame" — far enough to
## include the trunks a contact-shading change is judged on, near enough that a distant forest on
## the far shore cannot make an empty foreground look populated.
const PROP_CENSUS_RADIUS_M: float = 35.0
## How far a `prop` shot will look for something to stand next to. Wide, because the point is to
## find a trunk on ANY seed, and a shot that silently falls back to open ground is the failure this
## exists to stop.
const PROP_SEARCH_RADIUS_M: float = 150.0
## How far back from the prop a `prop` shot stands, and how high up its trunk the camera looks. Close
## enough that the base of the trunk and the ground around it fill the lower half of frame, which is
## the only part of any of these renders where contact shading can actually be judged.
const PROP_STANDOFF_M: float = 6.5
const PROP_AIM_HEIGHT_M: float = 1.1
## The node-name prefixes that mean "a standing object with a base", as opposed to grass or a fallen
## leaf. Same prefix convention `systems/harvesting/harvest_library.gd` keys HARVEST_RULES off.
const PROP_SHOT_PREFIXES: PackedStringArray = ["tree_", "wild_tree", "rock_", "boulder", "stone_"]
## Frames to let the streamer and the scatter field catch up after the camera is moved, if their own
## queues do not drain first. A cap, not a wait: `_settle_world()` returns as soon as both are idle.
const SETTLE_FRAME_CAP: int = 240
## Volumetric fog uses temporal reprojection, so the first frames after a jump are still blending in
## the previous camera's froxels. Judge a shot on a smear and the mist looks like a bug.
const CONVERGE_FRAMES: int = 30

## label · hour · metres toward the island centre from spawn · metres sideways · eye height ·
## facing · pitch in degrees.
##
## The sun's elevation is `sin((hour - 6) / 24 * TAU) * 90`, so hour 6 is exactly sunrise, 12 is
## exactly overhead and 18 is exactly sunset — and golden hour is only about 1.2 game-hours wide
## either side of those. The first version of this used 18.6 for "dusk" and rendered full night.
##
## `facing` is one of:
##   inward   — along the axis toward the island's centre, pitched by the last column. The ordinary
##              landscape shot: the interior is where the forest, the POIs and the hills are.
##   sunward  — along the sun light's own axis, pitch ignored. The only frame that can show whether
##              the shafts are working, since a shaft is a shadow cut through the fog.
##   moonward — the same for the moon (F-378). Night was the half of the cycle nobody could judge
##              until there was a moon, because the only night shot was a black frame with stars.
const SHOTS: Array = [
	["dawn", 6.25, 55.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
	["golden_morning", 6.9, 55.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
	["morning", 8.35, 55.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
	["noon", 12.0, 55.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
	["golden_evening", 17.2, 55.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
	["dusk", 17.85, 55.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
	## From above the canopy, looking down the slope — the one frame that shows landform and the
	## forest's extent rather than what is within arm's reach.
	["dawn_ridge", 6.5, 95.0, 34.0, 18.0, "inward", -14.0],
	["night", 22.0, 55.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
	["golden_sunward", 6.7, 55.0, 0.0, EYE_HEIGHT_M, "sunward", 0.0],
	["morning_sunward", 8.35, 55.0, 0.0, EYE_HEIGHT_M, "sunward", 0.0],
	["evening_sunward", 17.3, 55.0, 0.0, EYE_HEIGHT_M, "sunward", 0.0],
	## Deeper into the interior, where the scatter is densest — a low sun behind a stand of trunks
	## is the only place shafts can actually be carved.
	["forest_sunward", 6.7, 130.0, 0.0, EYE_HEIGHT_M, "sunward", 0.0],
	["forest_evening_sunward", 17.35, 130.0, 0.0, EYE_HEIGHT_M, "sunward", 0.0],
	## Close on a stand of trees, where falling leaves are large enough on screen to judge.
	["canopy_leaves", 9.5, 130.0, 0.0, EYE_HEIGHT_M, "inward", -4.0],
	["canopy_leaves_golden", 6.8, 130.0, 0.0, EYE_HEIGHT_M, "inward", -4.0],
	## F-398's own frames. Pitched hard down at the ground a few metres ahead, which is where a
	## trunk meets the terrain and therefore the only place contact shading can be judged at all —
	## every other shot in this table has the horizon in it and answers a different question.
	["contact_noon", 12.0, 55.0, 0.0, EYE_HEIGHT_M, "prop", 0.0],
	["contact_golden", 6.9, 55.0, 0.0, EYE_HEIGHT_M, "prop", 0.0],
	["contact_afternoon", 15.5, 55.0, 0.0, EYE_HEIGHT_M, "prop", 0.0],
	["moonrise_moonward", 19.4, 55.0, 0.0, EYE_HEIGHT_M, "moonward", 0.0],
	["midnight_moonward", 0.0, 55.0, 0.0, EYE_HEIGHT_M, "moonward", 0.0],
	["midnight_ground", 0.0, 55.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
	["late_night_ground", 22.0, 130.0, 0.0, EYE_HEIGHT_M, "inward", -6.0],
]

var _world: Node3D = null
var _streamer: Node = null
var _scatter_field: Node3D = null
## Unit vectors in the XZ plane: `_inward` points from the spawn at the island's centre, `_lateral`
## is the right-hand perpendicular. Every camera in SHOTS is a combination of the two.
var _inward := Vector2(0.0, -1.0)
var _lateral := Vector2(1.0, 0.0)
var _spawn := Vector3.ZERO


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("atmosphere_look_shot needs a renderer — run it with --windowed")
		quit(1)
		return
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	var scene := (load(scene_path) as PackedScene).instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 20:
		await process_frame
	await physics_frame

	var atmosphere: Node = scene.get_node_or_null(^"Atmosphere")
	if atmosphere == null:
		push_error("no Atmosphere node on %s" % scene_path)
		quit(1)
		return
	# DayNight owns the clock and re-applies it EVERY physics tick, so setting the hour on the
	# atmosphere directly is overwritten before the next frame is drawn — the first run of this
	# script rendered six identical mid-morning shots for exactly that reason. Drive DayNight
	# instead, in its own 0..1 units.
	var day_night: Node = root.get_node_or_null(^"DayNight")
	if day_night == null:
		push_error("DayNight autoload is missing; the clock cannot be posed")
		quit(1)
		return

	_world = scene
	_streamer = scene.get(&"streamer") as Node
	_scatter_field = scene.get(&"scatter_field") as Node3D
	_spawn = scene.get(&"spawn_position") as Vector3
	var to_centre := Vector2(-_spawn.x, -_spawn.z)
	if to_centre.length() > 0.001:
		_inward = to_centre.normalized()
	_lateral = Vector2(-_inward.y, _inward.x)
	print("WORLD spawn=%s inward=%s streamer=%s scatter=%s" % [
		str(_spawn), str(_inward), _streamer != null, _scatter_field != null])

	var fog: Node = atmosphere.get_node_or_null(^"GroundFog")
	print("GROUNDFOG present=%s base_height=%s size=%s material=%s" % [
		fog != null,
		"n/a" if fog == null else str(fog.get("base_height")),
		"n/a" if fog == null else str(fog.get("size")),
		"n/a" if fog == null else str(fog.get("material")),
	])
	var environment: Environment = _environment_of(scene)
	print("ENVIRONMENT ssao=%s radius=%.2f intensity=%.2f light_affect=%.2f" % [
		environment == null or environment.ssao_enabled,
		0.0 if environment == null else environment.ssao_radius,
		0.0 if environment == null else environment.ssao_intensity,
		0.0 if environment == null else environment.ssao_light_affect,
	])

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(WIDTH, HEIGHT)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = false
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 72.0
	camera.far = 400.0
	viewport.add_child(camera)
	camera.make_current()

	var sun := scene.get_node_or_null(^"Sun") as DirectionalLight3D
	# F-378: the moon is built by the Atmosphere controller rather than placed in the scene (release
	# worlds have no level author), so it is found under it, not beside it.
	var moon := atmosphere.get_node_or_null(^"Moon") as DirectionalLight3D
	# The star dome (and the moon riding it) follows whatever camera the MAIN viewport reports, which
	# is the player's — hundreds of metres from the SubViewport camera these shots are taken through,
	# so the whole night sky parallaxes out of place in every frame here. Park it on the shot camera
	# instead. In play there is one camera and none of this applies.
	var star_field := atmosphere.get_node_or_null(^"StarField") as Node3D
	if star_field != null:
		star_field.set("follow_camera", false)
	for shot_value: Variant in SHOTS:
		var shot: Array = shot_value as Array
		var label := String(shot[0])
		var hour := float(shot[1])
		var position: Vector3 = _site(float(shot[2]), float(shot[3]), float(shot[4]))
		# Stream and prime the ground around where the camera is about to stand, BEFORE it stands
		# there. Without this the first frames at a new site render whatever chunks the previous
		# site happened to leave resident, which for a 75 m move is a hole.
		camera.global_position = position
		await _settle_world(position)

		# A `prop` shot re-sites itself once the ground it is standing on exists: it asks the world
		# for its nearest trunk or boulder and stands off from that, because on a generated island
		# no fixed offset can promise there is one there. `target` stays null for every other shot.
		var target: Node3D = null
		if String(shot[5]) == "prop":
			target = _nearest_named_prop(position, PROP_SHOT_PREFIXES)
			if target != null:
				var base: Vector3 = target.global_position
				position = _stand_off(base)
				camera.global_position = position
				await _settle_world(position)
			else:
				push_warning("%s found no trunk or boulder within %.0f m — framing open ground"
					% [label, PROP_SEARCH_RADIUS_M])

		day_night.set("time_of_day", hour / 24.0)
		atmosphere.call(&"set_time_of_day", hour)
		if star_field != null:
			star_field.global_position = camera.global_position
			if moon != null:
				# Re-places the disc in the dome's frame now that the dome itself has moved.
				star_field.call(&"set_moon_direction", moon.global_basis.z)
		await process_frame
		if target != null:
			camera.look_at(target.global_position + Vector3.UP * PROP_AIM_HEIGHT_M, Vector3.UP)
		else:
			_aim(camera, String(shot[5]), float(shot[6]), sun, moon)

		for _frame: int in CONVERGE_FRAMES:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = viewport.get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, label]
		var error: int = image.save_png(path)
		var fog_scale: Variant = "n/a" if fog == null else fog.get("density_scale")
		print("SHOT %s hour=%.2f pos=(%.1f, %.1f, %.1f) props=%d fog_scale=%s -> %s (%s)" % [
			label, hour, position.x, position.y, position.z, _props_near(position), str(fog_scale),
			ProjectSettings.globalize_path(path), error_string(error)
		])
	print("ATMOSPHERE_LOOK_SHOT dir=%s" % ProjectSettings.globalize_path(OUT_DIR))
	quit(0)


## The camera position for one shot: [param along] metres from the spawn toward the island's centre,
## [param lateral] metres to the right of that, and [param eye] metres above whatever ground the
## WORLD reports there. Clamped to sea level so a site that lands in the shallows still puts the
## camera above the water rather than under it.
func _site(along: float, lateral: float, eye: float) -> Vector3:
	var xz := Vector2(_spawn.x, _spawn.z) + _inward * along + _lateral * lateral
	var ground: float = 0.0
	if _world != null and _world.has_method(&"height_at"):
		ground = float(_world.call(&"height_at", xz.x, xz.y))
	return Vector3(xz.x, maxf(ground, 0.0) + eye, xz.y)


## Where to stand to photograph [param base]: [constant PROP_STANDOFF_M] back along the axis that
## points at the island's centre, at eye height over the ground THERE rather than over the prop's own
## footing — a trunk on a slope would otherwise put the camera underground or in the air.
func _stand_off(base: Vector3) -> Vector3:
	var xz := Vector2(base.x, base.z) - _inward * PROP_STANDOFF_M
	var ground: float = 0.0
	if _world != null and _world.has_method(&"height_at"):
		ground = float(_world.call(&"height_at", xz.x, xz.y))
	return Vector3(xz.x, maxf(ground, 0.0) + EYE_HEIGHT_M, xz.y)


## Waits for the ground and the props around [param position] to actually exist. `prime()` is the
## blocking seam the streamer exposes for exactly this (F-324) and it builds the mesh and cooks the
## collision before it returns; the scatter field is the lazy half, draining a visual queue over
## several frames, so it is polled rather than primed.
func _settle_world(position: Vector3) -> void:
	if _streamer != null:
		var anchors: Array[Vector3] = [position]
		_streamer.call(&"set_anchors", anchors)
		if _streamer.has_method(&"prime"):
			_streamer.call(&"prime", anchors)
	for _frame: int in SETTLE_FRAME_CAP:
		await process_frame
		if _scatter_field == null:
			continue
		var pending: int = int(_scatter_field.call(&"pending_count"))
		var queued: int = int(_scatter_field.call(&"visual_queue_count"))
		if pending == 0 and queued == 0:
			return


## Points the camera. `sunward`/`moonward` look straight along the light's own axis and ignore the
## pitch column: a shaft is a shadow cut through fog and it is only visible from directly down-sun,
## so overriding the elevation there would aim the shot at the wrong part of the sky.
func _aim(camera: Camera3D, facing: String, pitch_deg: float, sun: DirectionalLight3D,
		moon: DirectionalLight3D) -> void:
	# A DirectionalLight3D shines along its own -Z, so the light itself is at +Z of its basis.
	if facing == "sunward" and sun != null:
		camera.look_at(camera.global_position + sun.global_basis.z * 60.0, Vector3.UP)
		return
	if facing == "moonward" and moon != null:
		camera.look_at(camera.global_position + moon.global_basis.z * 60.0, Vector3.UP)
		return
	var direction := _inward if facing != "outward" else -_inward
	var drop: float = tan(deg_to_rad(pitch_deg)) * 60.0
	camera.look_at(camera.global_position
		+ Vector3(direction.x * 60.0, drop, direction.y * 60.0), Vector3.UP)


## How many scattered props are standing within [constant PROP_CENSUS_RADIUS_M] of [param position].
## Printed with every shot because "it looked fine" is not a judgement anyone can make about a frame
## that turned out to contain no props at all — which is exactly what the pre-F-398 shot table was
## quietly producing after the island grew.
func _props_near(position: Vector3) -> int:
	return _placed_props(position, PROP_CENSUS_RADIUS_M).size()


## Every PLACED prop within [param radius] of [param position], nearest first.
##
## Keyed on the `asset` meta and a non-identity transform rather than on node class or name, because
## neither of the obvious answers works on this scene graph:
##
##   · `VisualInstance3D` misses most of the world. A decorative or batched prop is one
##     `MultiMeshInstance3D` for the whole chunk sitting at the chunk holder's ORIGIN, with every
##     instance's real position living inside the MultiMesh — so a distance test against the node
##     measures the distance to (0, 0, 0) and reports an empty forest.
##   · Node names are `MeshInstance3D` for a node-harvestable's parts and `Visual` for its wrapper.
##     The asset identity is on the meta, which is also what `HarvestWorld` and `EnvironmentVfx`
##     already key off, so this reads the same seam they do.
##
## `ResourceScatterField` puts the same `asset` meta on the per-chunk GROUP holder too, and that one
## sits at the origin with an identity transform — hence the origin test, which is what separates a
## real placement from the container that holds them.
func _placed_props(position: Vector3, radius: float) -> Array[Node3D]:
	var found: Array[Node3D] = []
	if _scatter_field == null:
		return found
	for node: Node in _scatter_field.find_children("*", "Node3D", true, false):
		var spatial := node as Node3D
		if spatial == null or not spatial.has_meta(&"asset"):
			continue
		if spatial.transform.origin.is_zero_approx():
			continue
		if spatial.global_position.distance_to(position) <= radius:
			found.append(spatial)
	found.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.global_position.distance_to(position) < b.global_position.distance_to(position))
	return found


## The nearest placed prop to [param position] whose asset id starts with one of [param prefixes] —
## the same prefix convention `systems/harvesting/harvest_library.gd` keys HARVEST_RULES off, so
## "tree_" really does mean a trunk and not a tuft of grass.
##
## This is what the `prop` shots are sited from. A hardcoded offset cannot find a trunk on a
## procedurally generated island: the spot 130 m inland of the spawn is dense forest on one seed and
## open grassland on the next, and the first run of the re-sited table put all three contact shots in
## the second kind of place. Asking the world where its nearest trunk actually is works on every
## seed, which is the only version of this shot worth keeping.
func _nearest_named_prop(position: Vector3, prefixes: PackedStringArray) -> Node3D:
	for candidate: Node3D in _placed_props(position, PROP_SEARCH_RADIUS_M):
		var asset := String(candidate.get_meta(&"asset")).to_lower()
		for prefix: String in prefixes:
			if asset.begins_with(prefix):
				return candidate
	return null


func _environment_of(scene: Node3D) -> Environment:
	var holder := scene.get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	return null if holder == null else holder.environment
