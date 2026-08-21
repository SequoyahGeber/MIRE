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
## F-410 deliberately replaces the old physical sky, so the daytime assertion now guards the shared
## procedural baseline rather than treating scene-authored physical scattering as immutable.

const ATMOSPHERE_SCRIPT := preload("res://world/environment/playtest_atmosphere.gd")
const CLOUDS_SCRIPT := preload("res://world/environment/low_poly_clouds.gd")
const STAR_FIELD_SCRIPT := preload("res://world/environment/star_field.gd")

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
	_check_daytime_uses_shared_baseline()
	await process_frame
	_check_sun_has_a_disc()
	await process_frame
	_check_there_is_a_moon()
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
	var environment := (level.get_node(^"WorldEnvironment") as WorldEnvironment).environment
	check(is_equal_approx(sky.sky_energy_multiplier, ATMOSPHERE_SCRIPT.NIGHT_SKY_ENERGY),
		"the night sky itself dims (energy %.3f)" % sky.sky_energy_multiplier)
	check(sky.sky_top_color.b > sky.sky_top_color.r,
		"the night sky stays blue rather than washing to grey")
	# F-356: all three values used to compound toward black even though each looked plausible alone.
	check(environment.background_energy_multiplier >= 0.6,
		"night keeps enough authored sky to show an indigo gradient (%.3f)"
			% environment.background_energy_multiplier)
	check(environment.tonemap_white < 2.0,
		"night does not bury moonlight in the ACES toe (white %.3f)" % environment.tonemap_white)
	check(environment.adjustment_saturation <= 0.9,
		"night desaturates authored green albedos instead of turning the ground teal (%.3f)"
			% environment.adjustment_saturation)
	check(environment.ambient_light_energy < ATMOSPHERE_SCRIPT.DAY_AMBIENT_ENERGY,
		"night remains darker than day even with a readable ambient floor (%.3f < %.3f)" % [
			environment.ambient_light_energy, ATMOSPHERE_SCRIPT.DAY_AMBIENT_ENERGY])
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
	check(sunset_sky.sky_horizon_color.r > sunset_sky.sky_horizon_color.b,
		"the sun on the horizon warms the gradient (%s)" % sunset_sky.sky_horizon_color)
	# `sky_night` must not kick in early: at 18:00 the sun is still on the horizon, so the gradient
	# keeps full day energy while its colours turn warm.
	check(sunset_sky.sky_energy_multiplier > ATMOSPHERE_SCRIPT.DAY_SKY_ENERGY * 0.99,
		"the sky is not force-dimmed while the sun is still up (%.3f of a %.3f day)" % [
			sunset_sky.sky_energy_multiplier, ATMOSPHERE_SCRIPT.DAY_SKY_ENERGY])
	atmosphere.call(&"set_time_of_day", 19.5)
	var after_dark := _sky_material(level)
	check(after_dark.sky_horizon_color.b > after_dark.sky_horizon_color.r,
		"once the sun is down the horizon turns cold (%s)" % after_dark.sky_horizon_color)
	level.queue_free()


## F-410's reset is intentionally controller-owned so every current and future level gets one sky.
func _check_daytime_uses_shared_baseline() -> void:
	print("\n== full daylight uses the shared stylized sky baseline ==")
	var level := _build_level(NOON)
	var sky := _sky_material(level)
	check(sky.sky_top_color.is_equal_approx(ATMOSPHERE_SCRIPT.DAY_SKY_TOP),
		"the sky top returns to the shared day colour (%s)" % sky.sky_top_color)
	check(sky.sky_horizon_color.is_equal_approx(ATMOSPHERE_SCRIPT.DAY_SKY_HORIZON),
		"the horizon returns to the shared day colour (%s)" % sky.sky_horizon_color)
	check(sky.ground_horizon_color.is_equal_approx(ATMOSPHERE_SCRIPT.DAY_GROUND_HORIZON),
		"the lower horizon returns to the shared day colour (%s)" % sky.ground_horizon_color)
	check(is_equal_approx(sky.sky_energy_multiplier, ATMOSPHERE_SCRIPT.DAY_SKY_ENERGY),
		"the day sky returns to shared energy (%.2f)" % sky.sky_energy_multiplier)
	level.queue_free()


# ── F-378: the sun is a disc, and there is a moon ────────────────────────────────────────────────


## Sequoyah's verdict was "the sun doesnt have a clear circle form in the sky its more of a faded
## haze thats way to wide". Three numbers decide that, and until F-378 the controller owned none of
## them: the disc's angular size lived in each level's `.tscn`, and the two knobs that set the halo's
## width and density were either authored per level or lerped the wrong way.
##
## Headless, so this asserts the numbers a renderer would draw the disc FROM. The bounds are the
## interesting part — a disc has to exist (a zero angular size draws nothing at all) and it has to
## stay a disc (six degrees of "sun" is the haze again by another route).
func _check_sun_has_a_disc() -> void:
	print("\n== the sun is a circle, and the haze around it is not a quarter of the sky ==")
	var level := _build_level(NOON)
	var sun := level.get_node(^"Sun") as DirectionalLight3D
	var sky := _sky_material(level)

	check(sun.light_angular_distance > 0.0,
		"the sun has an angular size at all — at 0 the sky shader draws no disc (%.2f deg)"
			% sun.light_angular_distance)
	check(sun.light_angular_distance <= 1.0,
		"the sun's own angle stays tight, because it is also the shadow penumbra (%.2f deg)"
			% sun.light_angular_distance)
	check(sky.sun_angle_max > 0.5 and sky.sun_angle_max < 3.0,
		"the procedural sky draws a compact visible disc (%.2f deg)" % sky.sun_angle_max)
	check(sky.sun_curve <= 0.1,
		"the sun edge stays defined rather than becoming a broad haze (curve %.2f)" % sky.sun_curve)
	level.queue_free()


## "night time could be slightly less dark but only because of moonlight so we need to add a moon in
## that cast cool white light dimmly over the map." Before F-378 the level held exactly one
## DirectionalLight3D and night was that one dimmed to 0.04, which is also the whole of F-356: the
## ground was not dark, it was UNLIT.
##
## The load-bearing assertion here is the handover. Two directional lights that are both on is a
## night lit from two directions and a second shadow map nobody budgeted for, so the check is not
## "there is a moon" but "exactly one of the two is lit, at both ends of the day".
func _check_there_is_a_moon() -> void:
	print("\n== a second light nobody placed, opposite the sun, and only one of them is ever on ==")
	var level := _build_level(NOON)
	var atmosphere: Node = level.get_node(^"Atmosphere")
	var sun := level.get_node(^"Sun") as DirectionalLight3D

	var moon := atmosphere.get_node_or_null(^"Moon") as DirectionalLight3D
	check(moon != null, "Atmosphere created a Moon DirectionalLight3D")
	if moon == null:
		level.queue_free()
		return
	# LIGHT_ONLY is not tidiness: ProceduralSkyMaterial draws its disc for LIGHT0, and a moon that
	# contributed to the sky could take that slot and be handed the SUN's disc.
	check(moon.sky_mode == DirectionalLight3D.SKY_MODE_LIGHT_ONLY,
		"the moon never contributes to the sky, so it can never be given the sun's disc")
	check(moon.light_color.b > moon.light_color.r,
		"the moon is cool white, not a second sun (%s)" % moon.light_color)

	check(is_zero_approx(moon.light_energy),
		"noon leaves the moon completely dark (%.3f)" % moon.light_energy)
	check(not moon.visible, "noon hides the moon entirely, so daylight pays nothing for it")
	check(sun.light_energy > 1.0, "noon is the sun's (%.2f)" % sun.light_energy)
	check(sun.shadow_enabled and not moon.shadow_enabled,
		"by day the sun casts the shadows and the moon casts none")

	atmosphere.call(&"set_time_of_day", MIDNIGHT)
	check(moon.light_energy > 0.1,
		"midnight actually lights the map from the moon (%.3f)" % moon.light_energy)
	check(moon.visible, "midnight makes the moon visible")
	check(is_zero_approx(sun.light_energy),
		"midnight takes the sun to zero rather than to a token 0.04 (%.4f)" % sun.light_energy)
	check(moon.shadow_enabled and not sun.shadow_enabled,
		"at night the moon casts the shadows and the sun casts none — never two shadow maps")

	# The antipode, at four hours rather than one: a moon that only happens to be opposite at
	# midnight is a moon on its own clock.
	var worst_dot: float = 1.0
	for hour: float in [0.0, 3.5, 12.0, 21.0]:
		atmosphere.call(&"set_time_of_day", hour)
		worst_dot = minf(worst_dot, sun.global_basis.z.dot(moon.global_basis.z))
	check(worst_dot < -0.999,
		"the moon is the sun's antipode at every hour (worst dot %.5f)" % worst_dot)

	# And the thing you actually see. It is geometry in the star field, so it is readable headless
	# for the same reason the stars are (D-042).
	atmosphere.call(&"set_time_of_day", MIDNIGHT)
	var star_field: Node3D = atmosphere.get_node_or_null(^"StarField")
	var disc := atmosphere.get_node_or_null(^"StarField/MoonDisc") as MeshInstance3D
	check(disc != null, "the star field built a visible moon disc, not just a light")
	if disc == null or star_field == null:
		level.queue_free()
		return
	check(disc.visible, "the disc is drawn at midnight")
	var to_disc: Vector3 = (disc.global_position - star_field.global_position).normalized()
	check(to_disc.dot(moon.global_basis.z) > 0.999,
		"the disc sits where the light comes from, star wheel and all (dot %.5f)"
			% to_disc.dot(moon.global_basis.z))
	atmosphere.call(&"set_time_of_day", NOON)
	check(not disc.visible, "and it is gone by day")
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


## The real WorldEnvironment/Sun/CloudDeck/Atmosphere shape, starting from a physical sky to prove
## the controller replaces scene-local sky tuning without requiring a scene edit.
func _build_level(hour: float, with_clouds: bool = true) -> Node3D:
	var sky_material := PhysicalSkyMaterial.new()
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


func _sky_material(level: Node3D) -> ProceduralSkyMaterial:
	var world_environment := level.get_node(^"WorldEnvironment") as WorldEnvironment
	return world_environment.environment.sky.sky_material as ProceduralSkyMaterial


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
