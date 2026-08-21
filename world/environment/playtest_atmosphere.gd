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
## Everything in this file is client-local presentation (docs/ARCHITECTURE.md §2.2, "VFX, audio,
## camera, UI" row). It reads a replicated number and touches no gameplay state, so nothing here
## bumps the protocol version.

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
## cloud deck should be at their warmest, not already grey. Driving the sky's mie/rayleigh colours
## off `daylight` (which is ~0.3 by then) washed the sunset out entirely — the first night render
## showed a grey 18:00 with pale clouds, which is F-065 again, just an hour earlier.
const SKY_NIGHT_FULL_ELEVATION: float = -14.0
const SKY_NIGHT_START_ELEVATION: float = -1.0
## Half-width, in degrees of elevation, of the golden hour either side of the horizon.
const GOLDEN_HALF_WIDTH: float = 18.0
## F-090: DayNight advances time every physics tick, and a sun transform that dirties every
## tick keeps the PhysicalSky radiance perpetually regenerating for ~0.001° of motion no eye
## can see. The applied hour is stepped instead: at the default 900 s day this moves the sun
## about five times a second in ~0.1° increments — under the sun's own 1.1 shadow blur.
const SUN_STEP_HOURS: float = 0.005
## Night ends of the sky-material lerps. Their day ends are read off the authored resource in
## _ready() rather than written here, so noon renders exactly as the scene author tuned it and this
## fix can only change how dusk and night look.
const NIGHT_RAYLEIGH_COLOR := Color(0.07, 0.11, 0.29)
const NIGHT_MIE_COLOR := Color(0.14, 0.18, 0.31)
const NIGHT_GROUND_COLOR := Color(0.017, 0.022, 0.036)
## The 26% of ambient that does not come from the sky (see the level's
## ambient_light_sky_contribution). With the night sky now genuinely dark, this is the floor that
## keeps a night you can still fight in — night should be dangerous, not unreadable.
const NIGHT_AMBIENT_COLOR := Color(0.34, 0.42, 0.62)
## Cool cast on what little directional light survives the sun going down.
const MOONLIGHT_COLOR := Color(0.55, 0.68, 1.0)

## ── The daytime varnish (F-353) ────────────────────────────────────────────────────────────────
## Sequoyah, on the shipped island: "it looks super washed out and looks like it needs a coat of
## varnish to make everything clear and saturated." Measured, the frame lived in a 0.48-0.71
## luminance band with nothing black, nothing white, and a saturation median of 0.24.
##
## Every constant below is the DAY end of a lerp whose NIGHT end is the value the scene author
## already set, so this is a daytime change and only a daytime change — at `daylight` 0 the grade
## comes back byte-identical to what shipped, which is what keeps a separately-broken night (F-356)
## out of this fix's blast radius. They are hard-coded ends rather than captured exports for the
## same reason `ambient_light_energy` and `tonemap_exposure` already were: this block is a tuned
## curve, and reading half of it off the resource would hide half the tuning.
##
## What each one was doing to the frame:
##
##   · WHITE POINT. ACES normalises by the tonemapped white, so `tonemap_white = 3.0` mapped the
##     scene's real 0..1 range into the toe of the curve — blacks lifted, highlights never
##     arrived. 1.0 gives the range back.
##   · GLOW BLOOM. `glow_bloom` applies glow to the whole frame BELOW the HDR threshold; at 0.14 it
##     is a milk pass over every pixel regardless of brightness. Dropping it took the darkest pixel
##     in the frame from 0.164 to 0.070 — that is where the blacks had gone. The threshold goes to
##     1.0 and the intensity down with it so the sun disk stops smearing across a quarter of the sky.
##   · AMBIENT FILL. D-184's terrain is flat-shaded with no texture and no normal map, so
##     facet-to-facet radiance difference is the ONLY thing that gives the ground form. At 0.62 a
##     facet turned 30 deg off the sun read the same as one facing it: two ground samples 150 px
##     apart measured one 1/255 step apart. The sky contribution stays at the authored 0.68, so what
##     is left of the fill is blue — warm light against cool shadow is most of the perceived chroma.
##   · SATURATION AND CONTRAST. The grade's own last word, once the three above stopped fighting it.
const DAY_TONEMAP_WHITE: float = 1.0
const DAY_TONEMAP_EXPOSURE: float = 0.95
const DAY_AMBIENT_ENERGY: float = 0.30
const DAY_ADJUSTMENT_CONTRAST: float = 1.14
const DAY_ADJUSTMENT_SATURATION: float = 1.30
const DAY_GLOW_BLOOM: float = 0.0
const DAY_GLOW_HDR_THRESHOLD: float = 1.0
const DAY_GLOW_INTENSITY: float = 0.70
const DAY_SUN_ENERGY: float = 1.55
## Night ends — the values `levels/procedural_island.tscn` and `levels/hollowmere.tscn` author, kept
## here so the lerp is readable in one place. A scene that authors different ones is not wrong, it
## just stops being the night end of this particular curve; nothing downstream depends on the match.
const NIGHT_TONEMAP_WHITE: float = 3.0
const NIGHT_TONEMAP_EXPOSURE: float = 0.85
const NIGHT_AMBIENT_ENERGY: float = 0.22
const NIGHT_ADJUSTMENT_CONTRAST: float = 1.03
const NIGHT_ADJUSTMENT_SATURATION: float = 1.14
const NIGHT_GLOW_BLOOM: float = 0.14
const NIGHT_GLOW_HDR_THRESHOLD: float = 0.92
const NIGHT_GLOW_INTENSITY: float = 1.05
## Exponential DISTANCE fog, restored. F-115 zeroed this to kill a uniform grey blanket, and that
## was right, but zero left the level's `fog_height_density` as the only fog the Environment
## applied — and the height term is `max`ed in independently of this one, so it kept blending grey
## into everything below y=6 AT EVERY DISTANCE, the player's own feet included. The heights are off
## in the scenes now and this puts the haze back where it belongs: 1.6% at 10 m, 15% at 100 m,
## nothing you can see up close and real aerial perspective on a far shore.
const DAY_FOG_DENSITY: float = 0.0016

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
var _sky_material: PhysicalSkyMaterial
var _local_fog_materials: Array[FogMaterial] = []
var _local_fog_densities: Array[float] = [0.24, 0.07, 0.09]
var _cloud_deck: Node = null
var _star_field: Node3D = null
var _ground_fog: FogVolume = null
# Authored day ends, captured once so the night lerps cannot drift the tuned daytime look.
var _day_rayleigh_color := Color(0.2, 0.4, 0.9)
var _day_mie_color := Color(0.94, 0.7, 0.48)
var _day_ground_color := Color(0.06, 0.085, 0.07)
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
	if _environment.sky != null:
		_sky_material = _environment.sky.sky_material as PhysicalSkyMaterial
	if _sky_material != null:
		_day_rayleigh_color = _sky_material.rayleigh_color
		_day_mie_color = _sky_material.mie_color
		_day_ground_color = _sky_material.ground_color
	for fog_path: NodePath in [^"../MireGroundFog", ^"../ForestMist", ^"../RuinsMist"]:
		var fog_volume := get_node_or_null(fog_path) as FogVolume
		if fog_volume != null and fog_volume.material is FogMaterial:
			_local_fog_materials.append(fog_volume.material as FogMaterial)
	_cloud_deck = _resolve_cloud_deck()
	_star_field = _resolve_star_field()
	_ground_fog = _resolve_ground_fog()
	apply_atmosphere()
	set_process(cycle_enabled)


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
		if _star_field != null and starlight > 0.001:
			_star_field.call(&"set_sky_rotation", hour / 24.0 * TAU)

	# Everything below only responds to these drivers, so while they hold — which is every tick
	# outside the dawn/dusk windows — the writes are identical and skipping them is invisible.
	var drivers := PackedFloat64Array([
		daylight, warm_horizon, starlight, sky_night, golden, haze_strength, god_ray_strength
	])
	if drivers == _applied_drivers:
		return
	_applied_drivers = drivers

	# Warmer than neutral daylight even at noon, and holding the sunrise tint further up the sky
	# (0.58 rather than 0.72 of it burned off) — the difference between "correctly lit" and the
	# warm hour Sequoyah asked for. Colour is the cheapest half of that look; the other half is the
	# shafts below.
	var daylight_color := Color(1.0, 0.94, 0.815)
	var sunrise_color := Color(1.0, 0.55, 0.27)
	var horizon_mix := sunrise_color.lerp(daylight_color, 1.0 - warm_horizon * 0.58)
	sun.light_color = horizon_mix.lerp(MOONLIGHT_COLOR, starlight)
	sun.light_energy = lerpf(0.04, DAY_SUN_ENERGY, daylight)
	# Shafts peak at GOLDEN HOUR, not at noon. A sun overhead lights the mist from above and there
	# is nothing to rake through; a sun on the horizon fires the length of the valley through every
	# trunk in it, which is the shot this is for. `golden` is the extra 60% either side of dawn.
	sun.light_volumetric_fog_energy = (
		god_ray_strength * lerpf(0.25, 1.0, daylight) * (1.0 + golden * 0.6)
	)
	sun.shadow_opacity = lerpf(0.4, 0.88, daylight)

	_environment.background_energy_multiplier = lerpf(0.12, 0.9, daylight)
	# The day end is the floor under everything the sun is NOT hitting, and F-353 took it from 0.62
	# down to DAY_AMBIENT_ENERGY. The old value's own comment worried that 0.5 "crushed a hillside
	# facing away from a low sun to pure black" — but it was measured under `tonemap_white = 3.0`,
	# which lifted the blacks that were doing the crushing, and the fill it chose to compensate is
	# what erased the flat-shaded facets. With the white point back at 1.0 the curve is different and
	# the shadow is dark AND coloured, which is what that comment actually wanted. The colour half of
	# it is unchanged: ambient stays 68% sky (the level's own ambient_light_sky_contribution), so the
	# fill that remains is blue and reads as sky bouncing into shade rather than as grey.
	_environment.ambient_light_energy = lerpf(NIGHT_AMBIENT_ENERGY, DAY_AMBIENT_ENERGY, daylight)
	_environment.ambient_light_color = NIGHT_AMBIENT_COLOR.lerp(_day_ambient_color, daylight)
	_environment.tonemap_exposure = lerpf(NIGHT_TONEMAP_EXPOSURE, DAY_TONEMAP_EXPOSURE, daylight)
	# F-353's four remaining knobs, all on the same `daylight` curve as everything above so night
	# lands on the authored values and this stays a daytime change. See the DAY_* block's header for
	# what each was doing to the frame.
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
		# PhysicalSkyMaterial already dims itself as LIGHT0 drops, so let it do that work while the
		# sun is up and only force the night colours once the sun is actually below the horizon.
		_sky_material.energy_multiplier = lerpf(0.9, 0.055, sky_night)
		_sky_material.turbidity = lerpf(10.0, 5.2, daylight)
		_sky_material.rayleigh_color = _day_rayleigh_color.lerp(NIGHT_RAYLEIGH_COLOR, sky_night)
		_sky_material.mie_color = _day_mie_color.lerp(NIGHT_MIE_COLOR, sky_night)
		_sky_material.ground_color = _day_ground_color.lerp(NIGHT_GROUND_COLOR, sky_night)
	if _cloud_deck != null:
		_cloud_deck.call(&"set_sky_light", daylight, golden)
	if _star_field != null:
		# The wheel itself (set_sky_rotation) turns above the gate, every tick of the night.
		_star_field.call(&"set_night_amount", starlight)
