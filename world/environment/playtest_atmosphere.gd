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

@export_range(0.0, 24.0, 0.05) var time_of_day: float = 8.35
@export var cycle_enabled: bool = false
@export_range(60.0, 3600.0, 1.0) var day_length_seconds: float = 900.0
@export_range(0.25, 2.0, 0.01) var haze_strength: float = 1.0
@export_range(0.0, 2.5, 0.01) var god_ray_strength: float = 1.35

@onready var world_environment := get_node(^"../WorldEnvironment") as WorldEnvironment
@onready var sun := get_node(^"../Sun") as DirectionalLight3D

var _environment: Environment
var _sky_material: PhysicalSkyMaterial
var _local_fog_materials: Array[FogMaterial] = []
var _local_fog_densities: Array[float] = [0.24, 0.07, 0.09]
var _cloud_deck: Node = null
var _star_field: Node3D = null
# Authored day ends, captured once so the night lerps cannot drift the tuned daytime look.
var _day_rayleigh_color := Color(0.2, 0.4, 0.9)
var _day_mie_color := Color(0.94, 0.7, 0.48)
var _day_ground_color := Color(0.06, 0.085, 0.07)
var _day_ambient_color := Color(1.0, 1.0, 1.0)


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
	var solar_phase := (time_of_day - 6.0) / 24.0 * TAU
	var elevation := sin(solar_phase) * 90.0
	var daylight := smoothstep(-7.0, 12.0, elevation)
	var warm_horizon := 1.0 - smoothstep(10.0, 42.0, elevation)
	var starlight := 1.0 - smoothstep(STARS_FULL_ELEVATION, STARS_GONE_ELEVATION, elevation)
	var sky_night := 1.0 - smoothstep(
		SKY_NIGHT_FULL_ELEVATION, SKY_NIGHT_START_ELEVATION, elevation
	)
	var golden := 1.0 - smoothstep(0.0, GOLDEN_HALF_WIDTH, absf(elevation))
	var azimuth := -118.0 + (time_of_day / 24.0) * 236.0

	sun.rotation_degrees = Vector3(-elevation, azimuth, 0.0)
	var daylight_color := Color(1.0, 0.955, 0.86)
	var sunrise_color := Color(1.0, 0.58, 0.3)
	var horizon_mix := sunrise_color.lerp(daylight_color, 1.0 - warm_horizon * 0.72)
	sun.light_color = horizon_mix.lerp(MOONLIGHT_COLOR, starlight)
	sun.light_energy = lerpf(0.04, 1.22, daylight)
	sun.light_volumetric_fog_energy = god_ray_strength * lerpf(0.2, 1.0, daylight)
	sun.shadow_opacity = lerpf(0.4, 0.88, daylight)

	_environment.background_energy_multiplier = lerpf(0.12, 0.82, daylight)
	_environment.ambient_light_energy = lerpf(0.22, 0.52, daylight)
	_environment.ambient_light_color = NIGHT_AMBIENT_COLOR.lerp(_day_ambient_color, daylight)
	_environment.tonemap_exposure = lerpf(0.82, 1.08, daylight)
	_environment.fog_light_color = Color(0.19, 0.22, 0.3).lerp(
		Color(0.62, 0.67, 0.72), daylight
	)
	# Keep the open routes clear. FogVolume nodes, not the global environment, define mist pockets.
	_environment.fog_density = 0.0
	_environment.volumetric_fog_density = 0.00045 * haze_strength
	_environment.volumetric_fog_ambient_inject = lerpf(0.28, 0.62, daylight)
	var local_density_scale := haze_strength * lerpf(1.18, 0.92, daylight)
	for index: int in mini(_local_fog_materials.size(), _local_fog_densities.size()):
		_local_fog_materials[index].density = _local_fog_densities[index] * local_density_scale
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
		_star_field.call(&"set_night_amount", starlight)
		# The field wheels on the same clock the sun turns on, so a long night visibly passes.
		_star_field.call(&"set_sky_rotation", time_of_day / 24.0 * TAU)
