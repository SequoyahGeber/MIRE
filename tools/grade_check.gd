extends SceneTree

## F-410: the daytime grade is a neutral baseline, while night retains its authored grade.
## Flat-shaded materials already carry strong albedo colour, so noon must not stack extra contrast
## or saturation over them. This also guards the stylized procedural sky that replaces the grey
## PhysicalSky horizon consistently in every level.
##
## Runs headless — every assertion is Environment state, not rendered pixels. To actually LOOK at
## the grade, use `tools/grade_probe.gd --windowed`, which poses any hour and saves PNGs.
##
## Run with: .agent/bin/agent godot --script tools/grade_check.gd

const ATMOSPHERE := preload("res://world/environment/playtest_atmosphere.gd")
## Both shipped levels share one grade and must not drift apart; hollowmere is the authored map and
## procedural_island is what actually ships, but a player cannot tell which one they are standing in
## and neither should the lighting.
const LEVELS: Array = [
	"res://levels/procedural_island.tscn",
	"res://levels/hollowmere.tscn",
]
## Hours whose `daylight` is exactly 1 and exactly 0 — see `apply_atmosphere()`'s smoothstep.
const NOON: float = 12.0
const MIDNIGHT: float = 0.0

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for level_path: String in LEVELS:
		await _check_level(level_path)
	print("GRADE_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)


func _check_level(level_path: String) -> void:
	print("\n== %s ==" % level_path)
	var packed := load(level_path) as PackedScene
	check(packed != null, "the level loads")
	if packed == null:
		return

	# THE VEIL. `fog_height_density` is the one that has to be read off the AUTHORED resource rather
	# than after the controller has run, because the controller never touches it — which is exactly
	# why it survived F-115 and kept painting grey on everything below y=6 at every distance, the
	# player's own feet included. Godot maxes the height term in independently of `fog_density`, so
	# zeroing the latter (which F-115 did) does not disable it. Only this does.
	var authored := _environment_of(packed.instantiate() as Node3D)
	check(authored != null, "the level has a WorldEnvironment with an Environment")
	if authored == null:
		return
	check(is_zero_approx(authored.fog_height_density),
		"no distance-independent height veil (fog_height_density=%.4f)" % authored.fog_height_density)

	# SNAPSHOT, not a reference. Every instance of a PackedScene shares its sub-resources, so the
	# Environment `authored` points at is the SAME object the controller writes to below — holding
	# the node and reading it later compares the day grade against itself and passes no matter what
	# (the first version of this check did exactly that and reported "1.30 > 1.30").
	var authored_values := {
		"tonemap_white": authored.tonemap_white,
		"glow_bloom": authored.glow_bloom,
		"adjustment_saturation": authored.adjustment_saturation,
		"adjustment_contrast": authored.adjustment_contrast,
	}

	# The authored values ARE the night ends of the controller's lerps. Asserting the match here is
	# what keeps the two copies from drifting: change one without the other and night silently stops
	# being the thing this file claims it is.
	check(is_equal_approx(authored_values["tonemap_white"], ATMOSPHERE.NIGHT_TONEMAP_WHITE),
		"authored tonemap_white is the controller's night end (%.2f)" % authored_values["tonemap_white"])
	check(is_equal_approx(authored_values["glow_bloom"], ATMOSPHERE.NIGHT_GLOW_BLOOM),
		"authored glow_bloom is the controller's night end (%.2f)" % authored_values["glow_bloom"])
	check(is_equal_approx(authored_values["adjustment_saturation"],
			ATMOSPHERE.NIGHT_ADJUSTMENT_SATURATION),
		"authored saturation is the controller's night end (%.2f)"
			% authored_values["adjustment_saturation"])
	check(is_equal_approx(authored_values["adjustment_contrast"],
			ATMOSPHERE.NIGHT_ADJUSTMENT_CONTRAST),
		"authored contrast is the controller's night end (%.2f)"
			% authored_values["adjustment_contrast"])

	# NOON — neutral authored colour, with highlight headroom and restrained contact shading.
	var noon := await _environment_at(packed, NOON)
	if noon == null:
		return
	check(is_equal_approx(noon.tonemap_white, ATMOSPHERE.DAY_TONEMAP_WHITE),
		"noon uses the day white point, so the frame reaches black and white (%.2f)"
			% noon.tonemap_white)
	check(is_zero_approx(noon.glow_bloom),
		"noon has no whole-frame glow bloom (%.3f)" % noon.glow_bloom)
	check(is_equal_approx(noon.adjustment_saturation, 1.0),
		"noon adds no global saturation over authored albedo (%.2f)"
			% noon.adjustment_saturation)
	check(is_equal_approx(noon.adjustment_contrast, 1.0),
		"noon adds no global contrast curve (%.2f)" % noon.adjustment_contrast)
	check(is_equal_approx(noon.ambient_light_energy, ATMOSPHERE.DAY_AMBIENT_ENERGY),
		"noon uses the shared readable-shadow fill (%.2f)"
			% noon.ambient_light_energy)
	check(is_equal_approx(
			noon.ambient_light_sky_contribution, ATMOSPHERE.DAY_AMBIENT_SKY_CONTRIBUTION),
		"noon fill is primarily cool sky bounce (%.2f)" % noon.ambient_light_sky_contribution)
	var noon_sky := noon.sky.sky_material as ProceduralSkyMaterial
	check(noon_sky != null, "noon installs the shared ProceduralSkyMaterial")
	if noon_sky != null:
		check(noon_sky.sky_horizon_color.b > noon_sky.sky_horizon_color.r,
			"the horizon is coloured blue-green instead of achromatic grey (%s)"
				% noon_sky.sky_horizon_color)
		check(not noon_sky.sky_top_color.is_equal_approx(noon_sky.sky_horizon_color),
			"the sky has a readable top-to-horizon gradient")
	# Aerial perspective, the half of the fog trade that has to exist for the other half to be safe:
	# the haze belongs at range, not on the player's feet.
	check(noon.fog_density > 0.0,
		"distant geometry still hazes (fog_density=%.5f)" % noon.fog_density)

	# CONTACT SHADING (F-398). The grade and the occlusion term are the same complaint — "the game
	# lighting/color grading looks really bad" — and they fail the same way: with no AO the only
	# thing separating a trunk from the ground behind it is its albedo, which is what makes the
	# frame read as one flat hue band no matter how the tonemap is tuned. Guarded HERE, next to the
	# grade, because that is the relationship, and because the flag is one line in a .tscn that
	# anybody can drop without noticing.
	check(noon.ssao_enabled, "the level authors contact shading (ssao_enabled)")
	# Radius is the number that decides whether this is contact shading or a grey wash over the
	# whole hillside. The controller owns it; the assertion is that it ARRIVED, not what it is.
	check(is_equal_approx(noon.ssao_radius, ATMOSPHERE.SSAO_RADIUS_M),
		"the controller's AO radius reaches the Environment (%.2f m)" % noon.ssao_radius)
	check(is_equal_approx(noon.ssao_intensity, ATMOSPHERE.SSAO_INTENSITY),
		"the controller's AO intensity reaches the Environment (%.2f)" % noon.ssao_intensity)
	check(is_equal_approx(noon.ssao_light_affect, ATMOSPHERE.SSAO_LIGHT_AFFECT),
		"AO has only a restrained direct-light term (%.2f)" % noon.ssao_light_affect)

	# MIDNIGHT — every grade value is back where the scene author put it.
	var night := await _environment_at(packed, MIDNIGHT)
	if night == null:
		return
	check(is_equal_approx(night.tonemap_white, authored_values["tonemap_white"]),
		"midnight restores the authored white point (%.2f)" % night.tonemap_white)
	check(is_equal_approx(night.glow_bloom, authored_values["glow_bloom"]),
		"midnight restores the authored glow bloom (%.2f)" % night.glow_bloom)
	check(is_equal_approx(night.adjustment_saturation, authored_values["adjustment_saturation"]),
		"midnight restores the authored saturation (%.2f)" % night.adjustment_saturation)
	check(is_equal_approx(night.adjustment_contrast, authored_values["adjustment_contrast"]),
		"midnight restores the authored contrast (%.2f)" % night.adjustment_contrast)


## Instantiates the level, poses DayNight at [param hour], and returns the Environment the
## controller has written. Goes through DayNight rather than the Atmosphere node directly because
## DayNight re-applies every physics tick and would otherwise overwrite the pose before it is read.
func _environment_at(packed: PackedScene, hour: float) -> Environment:
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 4:
		await process_frame
	var day_night: Node = root.get_node_or_null(^"DayNight")
	check(day_night != null, "DayNight autoload exists to pose the clock")
	if day_night == null:
		scene.queue_free()
		return null
	day_night.call(&"host_set_time", hour / 24.0)
	await physics_frame
	await process_frame
	var environment := _environment_of(scene)
	# Detached, not freed: the caller reads the resource, and the Environment outlives the node.
	root.remove_child(scene)
	scene.queue_free()
	return environment


func _environment_of(scene: Node3D) -> Environment:
	var holder := scene.get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	return null if holder == null else holder.environment


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
