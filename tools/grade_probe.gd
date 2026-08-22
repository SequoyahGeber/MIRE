extends SceneTree

## F-353 — A/B probe for the DAYTIME grade. Boots the shipped island, poses the clock at one hour,
## then renders the SAME camera under a series of grade variants so "washed out" can be judged by
## looking at the pairs instead of by reading constants.
##
##   .agent/bin/agent godot --windowed --script tools/grade_probe.gd
##
## Writes to `assets/audit/lighting/`. Each variant is a set of Environment / sun / terrain-material
## overrides applied AFTER the atmosphere controller's last apply — DayNight's physics processing is
## stopped first, so nothing rewrites them before the frame is drawn.
##
## Set `GRADE_SPEC` to a JSON file to override [constant VARIANTS] without editing this script; the
## file is an array of the same four-or-five element entries. That is what makes a tuning round cheap
## — the 420-frame settle is the expensive part and it is paid once per run either way.

## The MAP, not `run/main_scene` (F-564). Since MENU-3's cutover the main scene is the front
## end, so loading that setting and treating the result as a level boots a menu. `ProbeScene`
## asks the front end what world it bypasses into (F-561).
const ProbeScene := preload("res://tools/probe_scene.gd")


const OUT_DIR: String = "res://assets/audit/lighting"
const SETTLE_FRAMES: int = 420
const PER_SHOT_FRAMES: int = 90
## The run-start morning DayNight poses (0.348 of a day), which is the hour the existing
## `island_spawn_view.png` evidence was shot at — same hour keeps the A/B honest.
const MORNING_HOUR: float = 8.35

## label, hour, {env property: value}, {sun property: value}, [optional] extras:
##   "albedo": [r,g,b]  terrain shader albedo · "sky": {property: value} on the PhysicalSkyMaterial
##   "view": "spawn"|"shore"|"orbit"
const VARIANTS: Array = [
	["00_baseline", MORNING_HOUR, {}, {}, {}],
]

## Every property any variant is allowed to override. Their values are CAPTURED from the level at
## startup rather than written here, and restored before each variant, so a variant reads as a
## change from whatever is currently committed — and a run with no overrides at all renders the
## shipped grade exactly. Hard-coding them (the first version of this) silently reverted the very
## scene edits a verification run existed to check.
const RESTORED_ENV_PROPERTIES: Array = [
	"fog_height_density", "fog_density", "fog_sky_affect", "fog_aerial_perspective",
	"tonemap_white", "tonemap_exposure", "glow_bloom", "glow_intensity", "glow_hdr_threshold",
	"adjustment_saturation", "adjustment_contrast", "ambient_light_energy",
	"volumetric_fog_sky_affect",
]
const RESTORED_SUN_PROPERTIES: Array = ["light_energy"]
const RESTORED_SKY_PROPERTIES: Array = [
	"turbidity", "mie_coefficient", "ground_color", "rayleigh_color", "mie_color",
]

var _terrain_material: ShaderMaterial
var _sky_material: PhysicalSkyMaterial
var _captured_env: Dictionary = {}
var _captured_sun: Dictionary = {}
var _captured_sky: Dictionary = {}
var _captured_albedo: Variant = null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("grade_probe needs a renderer — run it with --windowed")
		quit(1)
		return
	var variants: Array = _load_variants()
	var scene_path := String(ProbeScene.shipped_map_path())
	var scene := (load(scene_path) as PackedScene).instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene

	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = false
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 72.0
	camera.far = 4000.0
	viewport.add_child(camera)
	camera.make_current()

	for _frame: int in SETTLE_FRAMES:
		await process_frame

	var spawn: Vector3 = scene.get(&"spawn_position")
	# Framings by name, so a variant can ask for the wide shot without repeating coordinates.
	# "spawn" matches `procedural_look_probe.gd`'s own spawn shot exactly.
	var framings := {
		"spawn": [spawn + Vector3.UP * 2.0, Vector3.UP * 12.0],
		"shore": [spawn + Vector3.UP * 22.0 + spawn.normalized() * 55.0, spawn],
		"orbit": [Vector3(spawn.x * 1.15, 260.0, spawn.z * 1.15), Vector3.ZERO],
	}

	# DayNight re-applies the whole grade every physics tick; stopping it is what lets a variant's
	# overrides survive to the frame that gets saved.
	var day_night: Node = root.get_node_or_null(^"DayNight")
	if day_night != null:
		day_night.set_physics_process(false)
	var atmosphere: Node = scene.get_node_or_null(^"Atmosphere")
	var world_environment := scene.get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	var sun := scene.get_node_or_null(^"Sun") as DirectionalLight3D
	if atmosphere == null or world_environment == null or sun == null:
		push_error("main scene %s is not the procedural composer" % scene_path)
		quit(1)
		return
	var environment: Environment = world_environment.environment
	if environment.sky != null:
		_sky_material = environment.sky.sky_material as PhysicalSkyMaterial
	var streamer: Node = scene.get(&"streamer")
	if streamer != null:
		_terrain_material = streamer.get(&"_shared_material") as ShaderMaterial

	_capture(environment, sun)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for variant: Array in variants:
		var label := String(variant[0])
		var hour := float(variant[1])
		var env_overrides: Dictionary = variant[2]
		var sun_overrides: Dictionary = variant[3]
		var extra: Dictionary = variant[4] if variant.size() > 4 else {}

		_restore(environment, sun)
		# Re-posing the hour makes the controller write its full authored grade back first, so the
		# overrides below are the only difference between this variant and the baseline.
		atmosphere.call(&"set_time_of_day", hour)
		for key: String in env_overrides:
			environment.set(key, env_overrides[key])
		for key: String in sun_overrides:
			sun.set(key, sun_overrides[key])
		if extra.has("sky") and _sky_material != null:
			# The controller writes turbidity/rayleigh/mie/ground every apply, so these land after
			# `set_time_of_day` above for the same reason the Environment overrides do.
			var sky_overrides: Dictionary = extra["sky"]
			for key: String in sky_overrides:
				var value: Variant = sky_overrides[key]
				if value is Array:
					value = Color(value[0], value[1], value[2])
				_sky_material.set(key, value)
		if extra.has("albedo") and _terrain_material != null:
			var rgb: Array = extra["albedo"]
			_terrain_material.set_shader_parameter(
				&"albedo_color", Color(rgb[0], rgb[1], rgb[2])
			)
		var framing: Array = framings.get(String(extra.get("view", "spawn")), framings["spawn"])
		camera.global_position = framing[0]
		camera.look_at(framing[1] as Vector3, Vector3.UP)

		# Volumetric fog reprojects temporally; give the froxels frames to converge per view.
		for _frame: int in PER_SHOT_FRAMES:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = viewport.get_texture().get_image()
		image.save_png("%s/%s.png" % [OUT_DIR, label])
		print("GRADE %s" % label)

	print("GRADE_PROBE done")
	quit(0)


func _load_variants() -> Array:
	var spec_path := OS.get_environment("GRADE_SPEC")
	if spec_path.is_empty() or not FileAccess.file_exists(spec_path):
		return VARIANTS
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(spec_path))
	if parsed is Array and not (parsed as Array).is_empty():
		print("GRADE_PROBE spec %s (%d variants)" % [spec_path, (parsed as Array).size()])
		return parsed as Array
	push_error("GRADE_SPEC %s did not parse as a non-empty array" % spec_path)
	return VARIANTS


## Snapshot the committed values, once, before any variant has touched them.
func _capture(environment: Environment, sun: DirectionalLight3D) -> void:
	for key: String in RESTORED_ENV_PROPERTIES:
		_captured_env[key] = environment.get(key)
	for key: String in RESTORED_SUN_PROPERTIES:
		_captured_sun[key] = sun.get(key)
	if _sky_material != null:
		for key: String in RESTORED_SKY_PROPERTIES:
			_captured_sky[key] = _sky_material.get(key)
	if _terrain_material != null:
		_captured_albedo = _terrain_material.get_shader_parameter(&"albedo_color")


func _restore(environment: Environment, sun: DirectionalLight3D) -> void:
	for key: String in _captured_env:
		environment.set(key, _captured_env[key])
	for key: String in _captured_sun:
		sun.set(key, _captured_sun[key])
	if _sky_material != null:
		for key: String in _captured_sky:
			_sky_material.set(key, _captured_sky[key])
	if _terrain_material != null and _captured_albedo != null:
		_terrain_material.set_shader_parameter(&"albedo_color", _captured_albedo)
