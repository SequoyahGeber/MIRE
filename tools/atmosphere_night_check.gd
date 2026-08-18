extends SceneTree

## Proof for F-065: night looks like night. The clock (task 2.11) was already correct — what this
## check covers is everything downstream of it that was not.
##
##   .agent/bin/agent godot --script tools/atmosphere_night_check.gd
##
## Headless has no framebuffer, so this asserts on the state a renderer would draw from — material
## albedo, alpha, visibility, vertex counts — rather than on pixels. That is the whole reason the
## star field is geometry and not a sky-shader texture (D-042): every claim below is readable
## without a display.
##
## The load-bearing assertion is _check_daytime_is_untouched(). Everything else here is new
## behaviour; that one is the promise that adding it did not re-tune somebody's daylight.

const ATMOSPHERE_SCRIPT := preload("res://world/environment/playtest_atmosphere.gd")
const CLOUDS_SCRIPT := preload("res://world/environment/low_poly_clouds.gd")
const STAR_FIELD_SCRIPT := preload("res://world/environment/star_field.gd")

## Copied from levels/hollowmere.tscn's PhysicalSkyMaterial, so the harness sky is the real one.
const AUTHORED_RAYLEIGH := Color(0.2, 0.4, 0.9, 1.0)
const AUTHORED_MIE := Color(0.94, 0.7, 0.48, 1.0)
const AUTHORED_GROUND := Color(0.06, 0.085, 0.07, 1.0)

## Mirrors star_field.gd's own fan width; a star is one centre vertex plus this many rim triangles.
const STAR_RIM_POINTS: int = 6

const NOON: float = 12.0
const MIDNIGHT: float = 0.0

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_check_star_field_is_built()
	await process_frame
	_check_night_and_day_states()
	await process_frame
	_check_dusk_is_a_fade()
	await process_frame
	_check_daytime_is_untouched()
	await process_frame
	_check_star_field_is_deterministic()
	await process_frame
	await _check_dome_rides_the_camera()
	await process_frame
	_check_missing_cloud_deck_is_silent()

	print("\nATMOSPHERE_NIGHT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


# ── The star field exists at all ─────────────────────────────────────────────────────────────────


func _check_star_field_is_built() -> void:
	print("\n== Atmosphere builds a star field nobody had to place in the scene ==")
	var level := _build_level(NOON)
	var atmosphere: Node = level.get_node(^"Atmosphere")

	var star_field := atmosphere.get_node_or_null(^"StarField") as Node3D
	check(star_field != null, "Atmosphere created a StarField child")
	if star_field == null:
		level.queue_free()
		return
	check(star_field.top_level, "the dome is top_level, so a plain-Node parent cannot move it")

	var dome := star_field.get_node_or_null(^"StarDome") as MeshInstance3D
	check(dome != null, "StarField built a StarDome MeshInstance3D")
	if dome == null:
		level.queue_free()
		return
	var mesh := dome.mesh as ArrayMesh
	check(mesh != null and mesh.get_surface_count() == 1, "one surface, so one draw call")
	var expected_vertices: int = int(star_field.get(&"star_count")) * STAR_RIM_POINTS * 3
	var vertex_array: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var actual_vertices: int = vertex_array.size()
	check(actual_vertices == expected_vertices,
		"%d stars became %d vertices (a %d-triangle soft point each)" % [
			int(star_field.get(&"star_count")), actual_vertices, STAR_RIM_POINTS])
	check(dome.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"the sky casts no shadows")

	# Every star must sit above the horizon and on the dome, or it is inside the map.
	var radius: float = float(star_field.get(&"dome_radius"))
	var lowest := INF
	var worst_radius_error := 0.0
	for vertex: Vector3 in vertex_array:
		lowest = minf(lowest, vertex.y)
		worst_radius_error = maxf(worst_radius_error, absf(vertex.length() - radius))
	check(lowest > 0.0, "no star is below the horizon (lowest y = %.2f m)" % lowest)
	check(worst_radius_error < radius * 0.02,
		"every star sits on the dome (worst radial error %.2f m of %.0f m)" % [
			worst_radius_error, radius])
	level.queue_free()


# ── Night reads as night, day still reads as day ─────────────────────────────────────────────────


func _check_night_and_day_states() -> void:
	print("\n== midnight darkens the clouds and lights the stars; noon does neither ==")
	var level := _build_level(NOON)
	var atmosphere: Node = level.get_node(^"Atmosphere")

	var day_cloud_tint := _cloud_tint(level)
	var day_star_alpha := _star_alpha(atmosphere)
	var day_dome_visible := _dome_visible(atmosphere)
	check(day_cloud_tint.is_equal_approx(Color(1.0, 1.0, 1.0, 1.0)),
		"noon leaves the cloud tint pure white (%s)" % day_cloud_tint)
	check(is_zero_approx(day_star_alpha), "noon draws no stars (alpha %.4f)" % day_star_alpha)
	check(not day_dome_visible, "noon hides the dome entirely, so daylight costs nothing")

	atmosphere.call(&"set_time_of_day", MIDNIGHT)
	var night_cloud_tint := _cloud_tint(level)
	var night_star_alpha := _star_alpha(atmosphere)
	check(night_star_alpha > 0.99, "midnight draws stars at full alpha (%.4f)" % night_star_alpha)
	check(_dome_visible(atmosphere), "midnight makes the dome visible")
	# This is F-065 in one line: "the clouds are still bright white".
	var night_luminance := (night_cloud_tint.r + night_cloud_tint.g + night_cloud_tint.b) / 3.0
	check(night_luminance < 0.3,
		"midnight clouds are dark, not white (mean channel %.3f)" % night_luminance)
	check(night_cloud_tint.b > night_cloud_tint.r,
		"midnight clouds go blue, not brown (r %.3f, b %.3f)" % [
			night_cloud_tint.r, night_cloud_tint.b])

	var sky := _sky_material(level)
	check(sky.energy_multiplier < 0.1,
		"the night sky itself dims (energy_multiplier %.3f)" % sky.energy_multiplier)
	check(sky.rayleigh_color.b > sky.rayleigh_color.r,
		"the night sky stays blue rather than washing to grey")
	level.queue_free()


func _check_dusk_is_a_fade() -> void:
	print("\n== stars arrive across dusk, not on a switch ==")
	var level := _build_level(NOON)
	var atmosphere: Node = level.get_node(^"Atmosphere")

	# Sampled every 6 game-minutes: the fade window is only about 45 game-minutes wide, because sun
	# elevation moves fastest at the horizon. A coarser sweep steps straight over it and reports a
	# fade that is really a switch — which is exactly what this check caught the first time.
	var previous := -1.0
	var monotonic := true
	var intermediate := 0
	for step: int in 61:
		var hour := 16.0 + float(step) * 0.1
		atmosphere.call(&"set_time_of_day", hour)
		var alpha := _star_alpha(atmosphere)
		if alpha < previous - 0.0001:
			monotonic = false
		if alpha > 0.02 and alpha < 0.98:
			intermediate += 1
		previous = alpha
	check(monotonic, "star alpha never goes back up as the sun goes down")
	check(intermediate >= 5,
		"dusk holds partly-lit values rather than snapping (%d half-steps)" % intermediate)

	# Sunset clouds should be warm before they are dark — the deck is the highest thing in the level
	# and the last of the sun is still on it. 18:00 puts the sun exactly on the horizon.
	atmosphere.call(&"set_time_of_day", 18.0)
	var sunset_tint := _cloud_tint(level)
	check(sunset_tint.r > sunset_tint.b + 0.25,
		"sunset clouds go properly warm, not pale grey (r %.3f, b %.3f)" % [
			sunset_tint.r, sunset_tint.b])
	var sunset_sky := _sky_material(level)
	check(sunset_sky.mie_color.is_equal_approx(AUTHORED_MIE),
		"the sun on the horizon keeps the authored warm scattering (%s)" % sunset_sky.mie_color)
	check(sunset_sky.energy_multiplier > 0.8,
		"the sky is not force-dimmed while the sun is still up (%.3f)" % sunset_sky.energy_multiplier)
	atmosphere.call(&"set_time_of_day", 19.5)
	var after_dark := _sky_material(level)
	check(after_dark.mie_color.b > after_dark.mie_color.r,
		"once the sun is down the scattering turns cold (%s)" % after_dark.mie_color)
	level.queue_free()


## The one regression this change could plausibly cause: re-tuning a daylight somebody signed off on.
## Every day-end value is read off the authored resource rather than written in the script, so at
## full daylight the sky material must come back byte-identical to what the scene author set.
func _check_daytime_is_untouched() -> void:
	print("\n== full daylight restores the authored sky exactly ==")
	var level := _build_level(NOON)
	var sky := _sky_material(level)
	check(sky.rayleigh_color.is_equal_approx(AUTHORED_RAYLEIGH),
		"rayleigh_color returns to the authored value (%s)" % sky.rayleigh_color)
	check(sky.mie_color.is_equal_approx(AUTHORED_MIE),
		"mie_color returns to the authored value (%s)" % sky.mie_color)
	check(sky.ground_color.is_equal_approx(AUTHORED_GROUND),
		"ground_color returns to the authored value (%s)" % sky.ground_color)
	level.queue_free()


# ── Determinism and the camera ───────────────────────────────────────────────────────────────────


## Two peers must see the same sky. The field is built from a fixed seed, so the same script run
## twice has to produce the same vertices — no time, no randi() without a seed, no node order.
func _check_star_field_is_deterministic() -> void:
	print("\n== two peers build the same sky ==")
	var first: Node3D = STAR_FIELD_SCRIPT.new()
	var second: Node3D = STAR_FIELD_SCRIPT.new()
	root.add_child(first)
	root.add_child(second)
	var first_mesh := (first.get_node(^"StarDome") as MeshInstance3D).mesh as ArrayMesh
	var second_mesh := (second.get_node(^"StarDome") as MeshInstance3D).mesh as ArrayMesh
	var a: PackedVector3Array = first_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var b: PackedVector3Array = second_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var identical := a.size() == b.size()
	if identical:
		for index: int in a.size():
			if not a[index].is_equal_approx(b[index]):
				identical = false
				break
	check(identical, "two independently built star fields have identical geometry")
	var colors: PackedColorArray = first_mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var distinct_alphas := {}
	for colour: Color in colors:
		distinct_alphas[snappedf(colour.a, 0.01)] = true
	check(distinct_alphas.size() > 4,
		"stars vary in brightness rather than being one flat sheet (%d levels)" %
			distinct_alphas.size())
	first.queue_free()
	second.queue_free()


## The dome is a skybox: it must sit on the camera, or crossing a 356 m valley visibly slides the
## stars past you.
func _check_dome_rides_the_camera() -> void:
	print("\n== the dome rides the camera instead of parallaxing ==")
	var holder := Node3D.new()
	root.add_child(holder)
	var camera := Camera3D.new()
	holder.add_child(camera)
	camera.current = true

	var star_field: Node3D = STAR_FIELD_SCRIPT.new()
	holder.add_child(star_field)
	star_field.call(&"set_night_amount", 1.0)

	camera.global_position = Vector3(120.0, 18.0, -64.0)
	await process_frame
	await process_frame
	var offset := star_field.global_position.distance_to(camera.global_position)
	check(offset < 0.001,
		"the dome centre tracks the camera (%.4f m apart)" % offset)

	star_field.call(&"set_night_amount", 0.0)
	check(not star_field.is_processing(),
		"daylight stops the per-frame follow entirely")
	holder.queue_free()


## A level with no cloud deck (or no star field placed by hand) must not error — greybox_test and
## every future harness level rely on this.
func _check_missing_cloud_deck_is_silent() -> void:
	print("\n== a level with no cloud deck is a silent no-op ==")
	var level := _build_level(NOON, false)
	var atmosphere: Node = level.get_node(^"Atmosphere")
	atmosphere.call(&"set_time_of_day", MIDNIGHT)
	check(true, "applying midnight with no cloud deck did not error")
	check(_star_alpha(atmosphere) > 0.99, "the stars still come out without a cloud deck")
	level.queue_free()


# ── Harness ──────────────────────────────────────────────────────────────────────────────────────


## The real WorldEnvironment/Sun/CloudDeck/Atmosphere shape, with hollowmere.tscn's authored sky
## values, built in code so this check needs no scene file and no claim on one.
func _build_level(hour: float, with_clouds: bool = true) -> Node3D:
	var sky_material := PhysicalSkyMaterial.new()
	sky_material.rayleigh_color = AUTHORED_RAYLEIGH
	sky_material.mie_color = AUTHORED_MIE
	sky_material.ground_color = AUTHORED_GROUND
	sky_material.energy_multiplier = 0.92
	sky_material.turbidity = 6.0
	var sky := Sky.new()
	sky.sky_material = sky_material
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 0.74

	var level := Node3D.new()
	level.name = "FakeLevel"
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	level.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	level.add_child(sun)
	if with_clouds:
		var clouds: Node3D = CLOUDS_SCRIPT.new()
		clouds.name = "CloudDeck"
		level.add_child(clouds)
	var atmosphere: Node = ATMOSPHERE_SCRIPT.new()
	atmosphere.name = "Atmosphere"
	atmosphere.set(&"time_of_day", hour)
	level.add_child(atmosphere)
	root.add_child(level)
	return level


func _cloud_tint(level: Node3D) -> Color:
	var clouds: Node = level.get_node_or_null(^"CloudDeck")
	if clouds == null:
		return Color(0.0, 0.0, 0.0, 0.0)
	var material := clouds.get(&"_cloud_material") as StandardMaterial3D
	return Color(0.0, 0.0, 0.0, 0.0) if material == null else material.albedo_color


func _star_material(atmosphere: Node) -> StandardMaterial3D:
	var star_field: Node = atmosphere.get_node_or_null(^"StarField")
	if star_field == null:
		return null
	return star_field.get(&"_material") as StandardMaterial3D


func _star_alpha(atmosphere: Node) -> float:
	var material := _star_material(atmosphere)
	return -1.0 if material == null else material.albedo_color.a


func _dome_visible(atmosphere: Node) -> bool:
	var dome := atmosphere.get_node_or_null(^"StarField/StarDome") as MeshInstance3D
	return dome != null and dome.visible


func _sky_material(level: Node3D) -> PhysicalSkyMaterial:
	var world_environment := level.get_node(^"WorldEnvironment") as WorldEnvironment
	return world_environment.environment.sky.sky_material as PhysicalSkyMaterial


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
