extends Node

## Local presentation controller for the Playtest Hollow sky, sun, fog, and light shafts.
## The optional clock is deliberately disabled by default. A future network-owned day/night system
## can call set_time_of_day() on every peer without moving gameplay authority into this script.

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
var _local_fog_densities: Array[float] = [0.028, 0.01, 0.008]


func _ready() -> void:
	if world_environment == null or world_environment.environment == null or sun == null:
		push_error("PlaytestAtmosphere requires sibling WorldEnvironment and Sun nodes")
		set_process(false)
		return
	_environment = world_environment.environment
	if _environment.sky != null:
		_sky_material = _environment.sky.sky_material as PhysicalSkyMaterial
	for fog_path: NodePath in [^"../MireGroundFog", ^"../ForestMist", ^"../RuinsMist"]:
		var fog_volume := get_node_or_null(fog_path) as FogVolume
		if fog_volume != null and fog_volume.material is FogMaterial:
			_local_fog_materials.append(fog_volume.material as FogMaterial)
	apply_atmosphere()
	set_process(cycle_enabled)


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
	var azimuth := -118.0 + (time_of_day / 24.0) * 236.0

	sun.rotation_degrees = Vector3(-elevation, azimuth, 0.0)
	var daylight_color := Color(1.0, 0.955, 0.86)
	var sunrise_color := Color(1.0, 0.58, 0.3)
	sun.light_color = sunrise_color.lerp(daylight_color, 1.0 - warm_horizon * 0.72)
	sun.light_energy = lerpf(0.04, 1.22, daylight)
	sun.light_volumetric_fog_energy = god_ray_strength * lerpf(0.2, 1.0, daylight)
	sun.shadow_opacity = lerpf(0.4, 0.88, daylight)

	_environment.background_energy_multiplier = lerpf(0.12, 0.82, daylight)
	_environment.ambient_light_energy = lerpf(0.16, 0.52, daylight)
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
		_sky_material.energy_multiplier = lerpf(0.18, 0.9, daylight)
		_sky_material.turbidity = lerpf(10.0, 5.2, daylight)
