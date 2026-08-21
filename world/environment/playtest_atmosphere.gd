extends Node

## Local presentation controller for the level's sky, sun, fog, star field, and light shafts.
## The optional clock is deliberately disabled by default and must stay that way — DayNight (the
## host-authoritative autoload) calls set_time_of_day() on every peer instead. Leaving
## cycle_enabled true would free-run a separate local clock per peer, which is the trap
## docs/SPECS.md 2.11 and systems/environment/day_night.gd both warn about.
##
## F-065 lived here: the clock arrived correctly and nothing downstream of it made night look like
## night. The cloud deck is an UNSHADED material, so dimming the sun could never darken it, and
## there was no star layer at all. apply_atmosphere() now drives both, plus the night ends of the
## sky material, on the same daylight curve everything else already used.
##
## F-378 is the same shape of bug one level up: the clock and the grade were both right, and the sky
## still had no SUN in it — only a haze where one should be — and no moon at all, because the level
## contained exactly one light. Both are owned here now (see the SUN_* and moon blocks below), which
## also settles F-356: night is dark because nothing is lit at night, and the fix for that is a
## second light, not a higher ambient floor.
##
## Everything in this file is client-local presentation (docs/ARCHITECTURE.md §2.2, "VFX, audio,
## camera, UI" row). It reads a replicated number and touches no gameplay state, so nothing here
## bumps the protocol version. That covers the moon too: it is derived from the same replicated
## `time_of_day` every peer already has, so every peer builds an identical one and none of it
## crosses the wire.

const STAR_FIELD_SCRIPT := preload("res://world/environment/star_field.gd")
const GROUND_FOG_SCRIPT := preload("res://world/environment/ground_fog.gd")

## Sun elevation, in degrees, across which the stars come out: fully out below the first, gone above
## the second. A window rather than a threshold, so dusk is a fade and not a light switch.
##
## The width is not cosmetic. Elevation moves fastest exactly at the horizon (~24 deg per game hour
## here), so a narrow window is crossed in a couple of real seconds and reads as a switch — the
## first version of this used -9..+3 and tools/atmosphere_night_check.gd caught it snapping. Ending
## at -1 also keeps the physics honest: no stars while the sun is still up.
const STARS_FULL_ELEVATION: float = -16.0
const STARS_GONE_ELEVATION: float = -1.0
## Sun elevation window over which the SKY MATERIAL itself turns to its night colours. Deliberately
## later than `daylight`: at elevation 0 the sun is on the horizon, which is when the sky and the
## cloud deck should be at their warmest, not already grey. Driving the sky gradient colours off
## `daylight` (which is ~0.3 by then) washed the sunset out entirely — the first night render
## showed a grey 18:00 with pale clouds, which is F-065 again, just an hour earlier.
const SKY_NIGHT_FULL_ELEVATION: float = -14.0
const SKY_NIGHT_START_ELEVATION: float = -1.0
## Half-width, in degrees of elevation, of the golden hour either side of the horizon.
const GOLDEN_HALF_WIDTH: float = 18.0
## F-090: DayNight advances time every physics tick, and a sun transform that dirties every
## tick keeps the sky radiance perpetually regenerating for ~0.001° of motion no eye
## can see. The applied hour is stepped instead: at the default 900 s day this moves the sun
## about five times a second in ~0.1° increments — under the sun's own 1.1 shadow blur.
const SUN_STEP_HOURS: float = 0.005
## F-410 resets the accumulated physical-sky tuning to one authored low-poly gradient. The
## PhysicalSkyMaterial's achromatic scattering lobe remained a flat grey band at the horizon even
## when turbidity, Mie, Rayleigh, fog sky-affect and ground colour were isolated. A procedural
## gradient is also closer to the target: a clear blue upper sky, a deliberately coloured horizon,
## and a warm transition at golden hour rather than photographic haze controlling the palette.
const DAY_SKY_TOP := Color(0.357, 0.525, 0.631)
const DAY_SKY_HORIZON := Color(0.702, 0.773, 0.769)
const DAY_GROUND_HORIZON := Color(0.569, 0.667, 0.639)
const DAY_GROUND_BOTTOM := Color(0.192, 0.275, 0.235)
const GOLDEN_SKY_TOP := Color(0.40, 0.49, 0.59)
const GOLDEN_SKY_HORIZON := Color(0.92, 0.58, 0.34)
const GOLDEN_GROUND_HORIZON := Color(0.69, 0.50, 0.34)
const NIGHT_SKY_TOP := Color(0.035, 0.060, 0.18)
const NIGHT_SKY_HORIZON := Color(0.12, 0.17, 0.32)
const NIGHT_GROUND_HORIZON := Color(0.065, 0.095, 0.18)
const NIGHT_GROUND_BOTTOM := Color(0.018, 0.030, 0.075)
const SKY_CURVE: float = 0.18
const SKY_SUN_ANGLE_MAX_DEG: float = 1.5
const SKY_SUN_CURVE: float = 0.08
const DAY_SKY_ENERGY: float = 1.0
const NIGHT_SKY_ENERGY: float = 0.75
const NIGHT_BACKGROUND_ENERGY: float = 0.62
## The non-sky ambient floor keeps a moonlit night playable without flattening the terrain.
const NIGHT_AMBIENT_COLOR := Color(0.42, 0.48, 0.66)
const NIGHT_AMBIENT_SKY_CONTRIBUTION: float = 0.28
const DAY_AMBIENT_SKY_CONTRIBUTION: float = 0.78

## Keep the light's angular size small for useful shadow definition. The visible disc is authored
## separately by ProceduralSkyMaterial, so it can read clearly without turning every shadow soft.
const SUN_ANGULAR_DIAMETER_DEG: float = 0.85

## ── The moon (F-378, and the answer to F-356) ─────────────────────────────────────────────────
## Sequoyah, same session: "night time could be slightly less dark but only because of moonlight so
## we need to add a moon in that cast cool white light dimmly over the map."
##
## Until this there was exactly one DirectionalLight3D in the level, named `Sun`, and night was that
## light dimmed to 0.04 and tinted blue. That is why F-356 measured a night whose ground luminance
## median was 0.000: nothing was LIT, so there was nothing for the grade to bring back. The fix is a
## second light and specifically NOT a higher ambient floor — ambient with no key flattens the
## flat-shaded facets (D-184) that are the only thing giving the ground form, so a raised floor
## would have bought a visible night by deleting the terrain's shape.
##
## Built in code, like the star field and the ground mist above it, for the same reason: release
## worlds are procedurally generated and have no level author to remember to place one.
##
## It rides the sun's own clock, rotated exactly opposite, so it rises as the sun sets. Its energy
## follows `starlight` — the same window the stars fade in across — and the sun's shadows are
## switched off for as long as the moon's are on, so the map never pays for two shadow-casting
## directional lights at once and exactly one of the two is meaningfully lit at any hour.
const MOONLIGHT_COLOR := Color(0.74, 0.82, 1.0)
## Strong enough to carve directional facet and trunk shadows, but still well below the day sun.
## The sky and ambient floor provide legibility; this provides shape, so night stays dangerous.
const MOON_ENERGY: float = 0.62
## Tighter than the sun's, because the moon's shadows are the ones most likely to look wrong — a
## soft-edged shadow at this energy is a smudge rather than a shape.
const MOON_ANGULAR_DIAMETER_DEG: float = 0.6
## Moonlight is a rim light, not a key. At full opacity its shadows read as a second midday's, which
## is the tell that a "moon" is really just a blue sun.
const MOON_SHADOW_OPACITY: float = 0.55
## One split, and only as far as anything is legible at night anyway — this is the "shadows on but
## cheap" half of the trade that lets the sun's own shadows switch off at the same time.
const MOON_SHADOW_DISTANCE_M: float = 48.0

## ── Contact shading (F-398/F-410) ─────────────────────────────────────────────────────────────
## A restrained trunk-base radius anchors props without turning broad terrain facets into dirty
## halos. Only ten percent reaches direct light, so AO still reads at noon without outlining every
## object. The enable flag remains level/quality-owned; this controller owns only the shared look.
const SSAO_RADIUS_M: float = 1.25
const SSAO_INTENSITY: float = 1.4
const SSAO_POWER: float = 1.0
const SSAO_DETAIL: float = 0.5
const SSAO_HORIZON: float = 0.06
const SSAO_SHARPNESS: float = 0.98
const SSAO_LIGHT_AFFECT: float = 0.1
## Zero, and it stays zero until something in the project ships a baked AO map: this is the weight
## of a material's own red-channel AO texture, and every mesh here is untextured flat colour.
const SSAO_AO_CHANNEL_AFFECT: float = 0.0

## ── Neutral daytime baseline (F-353/F-408/F-410) ──────────────────────────────────────────────
## This deliberately removes the accumulated "varnish" stack. Flat-shaded albedos already carry
## colour; neutral contrast and saturation let authored materials speak for themselves. ACES keeps
## modest highlight headroom, the sun stays below clipping, and cool sky fill preserves readable
## facets. Future look changes should be judged from renders against this baseline, one knob at a
## time, rather than stacking another correction over it.
const DAY_TONEMAP_WHITE: float = 1.5
const DAY_TONEMAP_EXPOSURE: float = 0.92
const DAY_AMBIENT_ENERGY: float = 0.48
const DAY_ADJUSTMENT_CONTRAST: float = 1.0
const DAY_ADJUSTMENT_SATURATION: float = 1.0
const DAY_GLOW_BLOOM: float = 0.0
const DAY_GLOW_HDR_THRESHOLD: float = 1.0
const DAY_GLOW_INTENSITY: float = 0.70
const DAY_SUN_ENERGY: float = 1.15
## Night ends are controller-owned alongside the procedural sky. F-356's old 3.0 white point, 0.12
## background, and 1.14 saturation multiplied into a black sky and radioactive green terrain. The
## restrained grade below keeps authored moonlight out of the ACES toe and pulls flat albedos toward
## cool moonlit colour without making the scene a blue daytime.
const NIGHT_TONEMAP_WHITE: float = 1.8
const NIGHT_TONEMAP_EXPOSURE: float = 0.90
const NIGHT_AMBIENT_ENERGY: float = 0.23
const NIGHT_ADJUSTMENT_CONTRAST: float = 1.0
const NIGHT_ADJUSTMENT_SATURATION: float = 0.78
const NIGHT_GLOW_BLOOM: float = 0.14
const NIGHT_GLOW_HDR_THRESHOLD: float = 0.92
const NIGHT_GLOW_INTENSITY: float = 1.05
## Exponential DISTANCE fog, restored. F-115 zeroed this to kill a uniform grey blanket, and that
## was right, but zero left the level's `fog_height_density` as the only fog the Environment
## applied — and the height term is `max`ed in independently of this one, so it kept blending grey
## into everything below y=6 AT EVERY DISTANCE, the player's own feet included. The heights are off
## in the scenes now and this puts the haze back where it belongs: 1.6% at 10 m, 15% at 100 m,
## nothing you can see up close and real aerial perspective on a far shore.
const DAY_FOG_DENSITY: float = 0.0014

## ── Ground mist (F-115) ───────────────────────────────────────────────────────────────────────
## Mist is a dawn and dusk thing. It burns off through the morning, is thinnest at noon, and comes
## back as the ground gives up its heat — which is also exactly when the low sun is raking through
## it, so the two effects pay for each other. `daylight` is 0 at night and 1 at noon, so the curve
## below is "thick at both ends, thin in the middle" rather than a straight lerp.
const FOG_NIGHT_SCALE: float = 1.35
const FOG_DAWN_SCALE: float = 1.75
const FOG_NOON_SCALE: float = 0.55
## What the mist is made of, at noon and at midnight. Warm grey by day so a sunbeam through it
## reads as light rather than as smoke; cold and dim by night so it hides things.
const FOG_DAY_ALBEDO := Color(0.80, 0.80, 0.76)
const FOG_NIGHT_ALBEDO := Color(0.36, 0.42, 0.55)
## A little self-lit warmth at golden hour, so mist in shadow still catches the hour's colour
## instead of going flat grey the moment the sun is behind a ridge.
const FOG_GOLDEN_EMISSION := Color(1.0, 0.62, 0.34)

@export_range(0.0, 24.0, 0.05) var time_of_day: float = 8.35
@export var cycle_enabled: bool = false
@export_range(60.0, 3600.0, 1.0) var day_length_seconds: float = 900.0
@export_range(0.25, 2.0, 0.01) var haze_strength: float = 1.0
## How hard the sun writes into the volumetric medium. Raised well above 1 for F-115's second half:
## with the uniform haze gone, the medium a shaft travels through is thin, and the shaft has to be
## driven harder to read at all. This is the knob for "more Valheim", and it costs nothing —
## `DirectionalLight3D.light_volumetric_fog_energy` is a multiply in a pass that already runs.
@export_range(0.0, 6.0, 0.01) var god_ray_strength: float = 2.4

@onready var world_environment := get_node(^"../WorldEnvironment") as WorldEnvironment
@onready var sun := get_node(^"../Sun") as DirectionalLight3D

var _environment: Environment
var _sky_material: ProceduralSkyMaterial
var _local_fog_materials: Array[FogMaterial] = []
var _local_fog_densities: Array[float] = [0.24, 0.07, 0.09]
var _cloud_deck: Node = null
var _star_field: Node3D = null
var _ground_fog: FogVolume = null
var _moon: DirectionalLight3D = null
var _day_ambient_color := Color(1.0, 1.0, 1.0)
# The driver values the last full apply ran with — empty forces the first apply through. F-090:
# DayNight re-applies ~60x/s, and outside dawn/dusk every driver below is a saturated constant,
# so the sky/environment/fog writes were identical rewrites that still dirtied the sky's
# radiance. Comparing the drivers is the cheap way to skip them; any input change (time,
# haze_strength, god_ray_strength) lands in the vector, so explicit setters need no special
# invalidation.
var _applied_drivers := PackedFloat64Array()
# The stepped hour the sun/star transforms were last written at. NAN so the first apply always
# writes. Rewriting an identical rotation still dirties the Node3D and the light behind it,
# which is exactly the per-tick radiance invalidation this file is trying to stop.
var _applied_sun_hour: float = NAN


func _ready() -> void:
	if world_environment == null or world_environment.environment == null or sun == null:
		push_error("PlaytestAtmosphere requires sibling WorldEnvironment and Sun nodes")
		set_process(false)
		return
	_environment = world_environment.environment
	_day_ambient_color = _environment.ambient_light_color
	_apply_ssao_look()
	_install_stylized_sky()
	# F-378: the sun's angular size was never set from here, so how big the game's sun is depended on
	# which level you were standing in. It is also the shadow penumbra, so it stays tight.
	sun.light_angular_distance = SUN_ANGULAR_DIAMETER_DEG
	# The sky shader only ever reads LIGHT0, and the moon below sets SKY_MODE_LIGHT_ONLY so it can
	# never become that light. Stating the sun's own mode explicitly is the other half of that
	# guarantee: if the moon ever took LIGHT0, the sun's disc would be drawn wherever the MOON is.
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	_moon = _resolve_moon()
	for fog_path: NodePath in [^"../MireGroundFog", ^"../ForestMist", ^"../RuinsMist"]:
		var fog_volume := get_node_or_null(fog_path) as FogVolume
		if fog_volume != null and fog_volume.material is FogMaterial:
			_local_fog_materials.append(fog_volume.material as FogMaterial)
	_cloud_deck = _resolve_cloud_deck()
	_star_field = _resolve_star_field()
	_ground_fog = _resolve_ground_fog()
	apply_atmosphere()
	set_process(cycle_enabled)


## Replaces scene-specific physical-sky resources with the same authored low-poly gradient in every
## world. This is presentation-only and intentionally leaves the Environment resource itself in
## place so quality settings keep ownership of their feature flags.
func _install_stylized_sky() -> void:
	if _environment.sky == null:
		_environment.sky = Sky.new()
	_sky_material = ProceduralSkyMaterial.new()
	_sky_material.sky_top_color = DAY_SKY_TOP
	_sky_material.sky_horizon_color = DAY_SKY_HORIZON
	_sky_material.sky_curve = SKY_CURVE
	_sky_material.sky_energy_multiplier = DAY_SKY_ENERGY
	_sky_material.ground_horizon_color = DAY_GROUND_HORIZON
	_sky_material.ground_bottom_color = DAY_GROUND_BOTTOM
	_sky_material.ground_curve = SKY_CURVE
	_sky_material.ground_energy_multiplier = DAY_SKY_ENERGY
	_sky_material.sun_angle_max = SKY_SUN_ANGLE_MAX_DEG
	_sky_material.sun_curve = SKY_SUN_CURVE
	_environment.sky.sky_material = _sky_material
	# Fog colours distance without repainting the sky into the old flat grey horizon band.
	_environment.fog_sky_affect = 0.12
	_environment.fog_aerial_perspective = 0.40
	_environment.volumetric_fog_sky_affect = 0.12


## F-398: writes the SSAO LOOK and nothing else. Once, in `_ready()`, because none of it moves with
## the hour — an occlusion term is a property of the geometry, and a radius that changed at dusk
## would be a bug, not a feature.
##
## `ssao_enabled` is conspicuously absent and must stay absent: it is the level's authored value and
## `autoload/graphics_quality.gd`'s to override (off on LOW, restored on HIGH). See the SSAO_* block
## for the full reasoning. A level that authors the flag off keeps a correctly-tuned AO pass that is
## simply switched off, which costs nothing and is exactly what a preset restore needs to find.
func _apply_ssao_look() -> void:
	_environment.ssao_radius = SSAO_RADIUS_M
	_environment.ssao_intensity = SSAO_INTENSITY
	_environment.ssao_power = SSAO_POWER
	_environment.ssao_detail = SSAO_DETAIL
	_environment.ssao_horizon = SSAO_HORIZON
	_environment.ssao_sharpness = SSAO_SHARPNESS
	_environment.ssao_light_affect = SSAO_LIGHT_AFFECT
	_environment.ssao_ao_channel_affect = SSAO_AO_CHANNEL_AFFECT


## The cloud deck is a sibling, but it is named differently in different levels ("CloudDeck" today),
## so match on the seam rather than the name. A level with no clouds is a silent no-op.
func _resolve_cloud_deck() -> Node:
	var parent: Node = get_parent()
	if parent == null:
		return null
	for child: Node in parent.get_children():
		if child != self and child.has_method(&"set_sky_light"):
			return child
	return null


## Built here rather than added to each level scene: it is pure presentation with no authored
## values, and every level with an Atmosphere node should have a night sky without anyone
## remembering to place one. Reuses an authored StarField child if a level ever adds one.
func _resolve_star_field() -> Node3D:
	var existing := get_node_or_null(^"StarField") as Node3D
	if existing != null:
		return existing
	var created: Node3D = STAR_FIELD_SCRIPT.new()
	created.name = "StarField"
	add_child(created)
	return created


## Same reasoning as the star field above, and the same fix for the same bug: every level with an
## Atmosphere node should have ground mist without a level author remembering to place one, because
## release worlds have no level author. This is what F-115 actually was — the controller drove three
## FogVolumes by name and the shipped map contained none of them, so the only fog left was the
## uniform `volumetric_fog_density` blanket. A level that authors its own `GroundFog` child keeps it.
func _resolve_ground_fog() -> FogVolume:
	var existing := get_node_or_null(^"GroundFog") as FogVolume
	if existing != null:
		return existing
	var created: FogVolume = GROUND_FOG_SCRIPT.new()
	created.name = "GroundFog"
	add_child(created)
	return created


## The moon (F-378). Same build-it-here reasoning as the star field and the ground mist, and the
## same escape hatch: a level that places its own `Moon` beside its `Sun` keeps it, so an authored
## map can pose a moon by hand without this file fighting it. `apply_atmosphere()` still drives
## whatever it finds, because the clock is not the level's to own (docs/SPECS.md 2.11).
##
## Everything configured here is the part that never changes with the hour. The three things that DO
## — rotation, energy, and whether it casts shadows at all — are written by `apply_atmosphere()`.
func _resolve_moon() -> DirectionalLight3D:
	var authored := get_node_or_null(^"../Moon") as DirectionalLight3D
	if authored != null:
		return authored
	var existing := get_node_or_null(^"Moon") as DirectionalLight3D
	if existing != null:
		return existing
	var created := DirectionalLight3D.new()
	created.name = "Moon"
	created.light_color = MOONLIGHT_COLOR
	created.light_energy = 0.0
	created.light_angular_distance = MOON_ANGULAR_DIAMETER_DEG
	# LIGHT_ONLY, and this is load-bearing rather than tidy: `ProceduralSkyMaterial` draws its sun disc
	# for LIGHT0, Godot picks LIGHT0 from the directional lights that contribute to the sky, and a
	# moon that qualified could take that slot — which would paint the sun's disc on the moon and
	# leave the real sun blank. The moon's own disc is geometry in `star_field.gd` instead.
	created.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	# Shadows on, but the cheapest kind: one split, and only across the distance anything is legible
	# at night. The sun's shadows go off while these are on (see apply_atmosphere), so the map never
	# renders two directional shadow maps at once and this costs nothing net.
	created.shadow_enabled = true
	created.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	created.directional_shadow_max_distance = MOON_SHADOW_DISTANCE_M
	created.shadow_opacity = MOON_SHADOW_OPACITY
	created.shadow_bias = 0.05
	created.shadow_normal_bias = 1.6
	# `shadow_enabled` above is the standing capability; whether it is actually ON at a given hour is
	# apply_atmosphere()'s call, and so are energy, colour, rotation and volumetric contribution.
	# Starting hidden matters on its own: a level that boots at noon must never pay a frame for a
	# light that is about to be switched off anyway.
	created.visible = false
	add_child(created)
	return created


func _process(delta: float) -> void:
	if not cycle_enabled:
		return
	time_of_day = fmod(time_of_day + delta * 24.0 / day_length_seconds, 24.0)
	apply_atmosphere()


func set_time_of_day(value: float) -> void:
	time_of_day = fposmod(value, 24.0)
	apply_atmosphere()


func set_weather_haze(value: float) -> void:
	haze_strength = clampf(value, 0.25, 2.0)
	apply_atmosphere()


func set_cycle_enabled(value: bool) -> void:
	cycle_enabled = value
	set_process(cycle_enabled)


func apply_atmosphere() -> void:
	if _environment == null or sun == null:
		return
	var hour := snappedf(time_of_day, SUN_STEP_HOURS)
	var solar_phase := (hour - 6.0) / 24.0 * TAU
	var elevation := sin(solar_phase) * 90.0
	var daylight := smoothstep(-7.0, 12.0, elevation)
	var warm_horizon := 1.0 - smoothstep(10.0, 42.0, elevation)
	var starlight := 1.0 - smoothstep(STARS_FULL_ELEVATION, STARS_GONE_ELEVATION, elevation)
	var sky_night := 1.0 - smoothstep(
		SKY_NIGHT_FULL_ELEVATION, SKY_NIGHT_START_ELEVATION, elevation
	)
	var golden := 1.0 - smoothstep(0.0, GOLDEN_HALF_WIDTH, absf(elevation))
	var azimuth := -118.0 + (hour / 24.0) * 236.0

	# The sun's angle and the wheeling star dome move on the stepped hour — once per step, never
	# a rewrite of the same value (see _applied_sun_hour).
	if hour != _applied_sun_hour:
		_applied_sun_hour = hour
		sun.rotation_degrees = Vector3(-elevation, azimuth, 0.0)
		# F-378: the moon is the sun's antipode on the same clock — negate the elevation, add half a
		# turn of azimuth. At midnight (elevation -90) that puts it directly overhead, and at the
		# moment of sunset it is exactly rising, which is the only arrangement where "one of the two
		# is lit" is true by construction rather than by tuning.
		if _moon != null:
			_moon.rotation_degrees = Vector3(elevation, azimuth + 180.0, 0.0)
		if _star_field != null and starlight > 0.001:
			_star_field.call(&"set_sky_rotation", hour / 24.0 * TAU)
			# The dome carries the star wheel's own rotation, so the moon's direction is handed over
			# in WORLD space and the star field puts it into the dome's frame itself — otherwise the
			# moon would wheel with the stars instead of tracking the clock it is actually on.
			if _moon != null:
				_star_field.call(&"set_moon_direction", _moon.global_basis.z)

	# Everything below only responds to these drivers, so while they hold — which is every tick
	# outside the dawn/dusk windows — the writes are identical and skipping them is invisible.
	var drivers := PackedFloat64Array([
		daylight, warm_horizon, starlight, sky_night, golden, haze_strength, god_ray_strength
	])
	if drivers == _applied_drivers:
		return
	_applied_drivers = drivers

	# Noon stays close to neutral so authored low-poly colours do not skew yellow. The warmth belongs
	# at the horizon, where the sky gradient and shafts reinforce it together.
	var daylight_color := Color(1.0, 0.97, 0.90)
	var sunrise_color := Color(1.0, 0.55, 0.27)
	var horizon_mix := sunrise_color.lerp(daylight_color, 1.0 - warm_horizon * 0.58)
	# F-378: the sun stays the sun all the way down. It used to lerp toward MOONLIGHT_COLOR as the
	# stars came out, which was this file pretending to be a moon it did not have — and the give-away
	# was that the "moonlight" came from wherever the sun had set. There is a real moon now, so the
	# sun keeps its sunset warmth and simply goes out.
	sun.light_color = horizon_mix
	# To zero, not to 0.04. A key light at 0.04 against a 0.06-linear albedo lands under what the
	# tonemapper resolves at all (F-356 measured the result at luminance median 0.000), so all it
	# ever bought was the illusion that night was lit. The moon below is what lights night now.
	sun.light_energy = DAY_SUN_ENERGY * daylight
	# Shafts peak at GOLDEN HOUR, not at noon. A sun overhead lights the mist from above and there
	# is nothing to rake through; a sun on the horizon fires the length of the valley through every
	# trunk in it, which is the shot this is for. `golden` is the extra 60% either side of dawn.
	sun.light_volumetric_fog_energy = (
		god_ray_strength * lerpf(0.25, 1.0, daylight) * (1.0 + golden * 0.6)
	)
	sun.shadow_opacity = lerpf(0.4, 0.88, daylight)
	# F-378: a light at zero energy still renders a shadow map. Once the sun is down that is a full
	# directional shadow pass for a light contributing nothing, and it is exactly the budget the
	# moon's own shadows need — so the two hand it back and forth rather than both holding one.
	sun.shadow_enabled = daylight > 0.004
	if _moon != null:
		var moonlight := starlight
		_moon.visible = moonlight > 0.002
		_moon.light_color = MOONLIGHT_COLOR
		_moon.light_energy = MOON_ENERGY * moonlight
		# Off below the point where the moon is too dim to cast anything you could identify — which
		# is also the dusk window where the sun's shadows are still on, so the handover never leaves
		# both enabled for longer than the fade itself.
		_moon.shadow_enabled = moonlight > 0.25
		# Moonlight through mist is a lot of what makes a night READ as a night rather than as a
		# dark day, but at a quarter of the sun's rate: a shaft you can follow the length of a
		# valley at midnight is a searchlight, not a moon.
		_moon.light_volumetric_fog_energy = god_ray_strength * 0.25 * moonlight

	_environment.background_energy_multiplier = lerpf(NIGHT_BACKGROUND_ENERGY, 0.9, daylight)
	# The ambient term is a readable-shadow floor, not a second key light. At night most of it comes
	# from the authored cool colour rather than the green ground half of the sky, preventing grass
	# albedo from tinting every unlit facet teal. By day the shared sky again supplies most of it.
	_environment.ambient_light_energy = lerpf(NIGHT_AMBIENT_ENERGY, DAY_AMBIENT_ENERGY, daylight)
	_environment.ambient_light_color = NIGHT_AMBIENT_COLOR.lerp(_day_ambient_color, daylight)
	_environment.ambient_light_sky_contribution = lerpf(
		NIGHT_AMBIENT_SKY_CONTRIBUTION, DAY_AMBIENT_SKY_CONTRIBUTION, daylight
	)
	_environment.tonemap_exposure = lerpf(NIGHT_TONEMAP_EXPOSURE, DAY_TONEMAP_EXPOSURE, daylight)
	# All grade knobs follow the same daylight curve, so midnight still lands on the authored values.
	_environment.tonemap_white = lerpf(NIGHT_TONEMAP_WHITE, DAY_TONEMAP_WHITE, daylight)
	_environment.glow_bloom = lerpf(NIGHT_GLOW_BLOOM, DAY_GLOW_BLOOM, daylight)
	_environment.glow_hdr_threshold = lerpf(
		NIGHT_GLOW_HDR_THRESHOLD, DAY_GLOW_HDR_THRESHOLD, daylight
	)
	_environment.glow_intensity = lerpf(NIGHT_GLOW_INTENSITY, DAY_GLOW_INTENSITY, daylight)
	_environment.adjustment_contrast = lerpf(
		NIGHT_ADJUSTMENT_CONTRAST, DAY_ADJUSTMENT_CONTRAST, daylight
	)
	_environment.adjustment_saturation = lerpf(
		NIGHT_ADJUSTMENT_SATURATION, DAY_ADJUSTMENT_SATURATION, daylight
	)
	_environment.fog_light_color = Color(0.19, 0.22, 0.3).lerp(
		Color(0.62, 0.67, 0.72), daylight
	)
	# Aerial perspective, not a blanket: FogVolume nodes still define every mist pocket you actually
	# look at, and this is only the depth cue that makes a far shore sit behind a near one. Scaled by
	# `haze_strength` like the rest of the weather knobs. See DAY_FOG_DENSITY for why zero was worse.
	_environment.fog_density = DAY_FOG_DENSITY * haze_strength
	# F-115: this used to be the ONLY fog on the shipped map, at a density that greyed out
	# everything evenly. It is now just the thin medium a sunbeam needs in order to be visible at
	# all — an eighth of what it was — and `GroundFog` carries every bit of fog you actually look
	# at. Turning it off entirely would take the god rays with it, which is the opposite mistake.
	_environment.volumetric_fog_density = 0.00006 * haze_strength
	# Ambient injection is what washes a volumetric medium out into milk. Low by day so shafts keep
	# their contrast against the air around them; higher at night, where the alternative is fog you
	# cannot see at all.
	_environment.volumetric_fog_ambient_inject = lerpf(0.34, 0.16, daylight)
	var local_density_scale := haze_strength * lerpf(1.18, 0.92, daylight)
	for index: int in mini(_local_fog_materials.size(), _local_fog_densities.size()):
		_local_fog_materials[index].density = _local_fog_densities[index] * local_density_scale
	if _ground_fog != null:
		# Thick at dawn and dusk, thinnest at noon — see the FOG_* constants. `golden` peaks either
		# side of the horizon, which is the only time the mist is lit warmly enough to say so.
		var noon_amount := smoothstep(0.0, 1.0, daylight)
		var mist_scale := lerpf(FOG_NIGHT_SCALE, FOG_NOON_SCALE, noon_amount)
		mist_scale = lerpf(mist_scale, FOG_DAWN_SCALE, golden * 0.85)
		_ground_fog.call(
			&"apply_look",
			mist_scale * haze_strength,
			FOG_NIGHT_ALBEDO.lerp(FOG_DAY_ALBEDO, daylight),
			FOG_GOLDEN_EMISSION,
			golden * 0.22 * daylight
		)
	if _sky_material != null:
		# Golden-hour warmth is deliberately confined to the horizon. Once the sun is below it, the
		# whole gradient fades toward the moonlit night palette without a grey intermediate band.
		var golden_amount := golden * daylight
		var day_top := DAY_SKY_TOP.lerp(GOLDEN_SKY_TOP, golden_amount * 0.35)
		var day_horizon := DAY_SKY_HORIZON.lerp(
			GOLDEN_SKY_HORIZON, golden_amount * 0.72
		)
		var day_ground_horizon := DAY_GROUND_HORIZON.lerp(
			GOLDEN_GROUND_HORIZON, golden_amount * 0.65
		)
		_sky_material.sky_top_color = day_top.lerp(NIGHT_SKY_TOP, sky_night)
		_sky_material.sky_horizon_color = day_horizon.lerp(NIGHT_SKY_HORIZON, sky_night)
		_sky_material.ground_horizon_color = day_ground_horizon.lerp(
			NIGHT_GROUND_HORIZON, sky_night
		)
		_sky_material.ground_bottom_color = DAY_GROUND_BOTTOM.lerp(
			NIGHT_GROUND_BOTTOM, sky_night
		)
		var sky_energy := lerpf(DAY_SKY_ENERGY, NIGHT_SKY_ENERGY, sky_night)
		_sky_material.sky_energy_multiplier = sky_energy
		_sky_material.ground_energy_multiplier = sky_energy
	if _cloud_deck != null:
		_cloud_deck.call(&"set_sky_light", daylight, golden)
	if _star_field != null:
		# The wheel itself (set_sky_rotation) turns above the gate, every tick of the night.
		_star_field.call(&"set_night_amount", starlight)
