extends Node

## GraphicsQuality — autoload. The one seam every hardware-scalability knob hangs off (F-090).
## Three presets instead of loose settings: `low` is the worst-computer floor, `high` is exactly
## the authored look (it restores values captured from the level, never hardcoded copies), and
## `medium` is the authored look at a reduced render scale. Task 7.5's settings menu gets three
## buttons now and can grow per-knob rows later without any other system changing.
##
## What each preset controls, and why it is a low-end lever:
##   render scale      — fill rate, the biggest cost on weak GPUs (tools/perf_probe.gd measured
##                       -2.0 ms at 50% even on the M5 Pro)
##   shadow cascades   — every PSSM split re-renders the caster scene; 4 -> 2 halves that load
##   shadow distance   — bounds how much of the world is a shadow caster at all
##   shadow atlas size — shadow-pass fill and memory
##   glow, volumetric  — post/froxel passes that touch the whole frame
##   undergrowth scale — instance budget of the densest scatter; a lower budget is a strict
##                       prefix of the full placement sequence, so it rescatters deterministically
##   draw distance     — how far props and harvestables are drawn at all; the only knob that
##                       removes work from the opaque pass and all four shadow cascades at once
##   mesh LOD threshold— how eagerly the renderer drops to a coarser LOD. Worth nothing until
##                       F-144 gave the merged meshes a LOD ladder to drop to; now it is the
##                       cheapest way to trade silhouette detail for triangles on a weak GPU
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row). Presentation is
## local to one machine; peers on different presets run the same simulation.
##
## Release worlds are randomly generated — nothing here assumes the authored map. Levels are
## discovered through the tree at apply time (any DirectionalLight3D, any WorldEnvironment, a
## node named Undergrowth), and authored values are captured per node the first time a preset
## touches it, so `high` on a generated level restores that level's own numbers.

## Preloaded rather than referenced by `class_name`: a new global class is invisible to a
## headless `--script` run until the editor rescans the project.
const DrawPolicy := preload("res://world/environment/draw_policy.gd")

enum Preset { LOW, MEDIUM, HIGH }

const PRESET_NAMES: PackedStringArray = ["low", "medium", "high"]

## A preset names only what it overrides; anything absent falls back to the level's authored
## value (lights, environment) or the engine default (render scale 1.0, atlas 4096).
const PRESETS: Dictionary = {
	Preset.LOW: {
		"render_scale": 0.59,
		"cascades": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"shadow_distance": 55.0,
		"shadow_atlas": 2048,
		"glow": false,
		"volumetric": false,
		"undergrowth": 0.45,
		"draw_distance": 0.55,
		"lod_threshold": 4.0,
	},
	Preset.MEDIUM: {
		"render_scale": 0.77,
		"undergrowth": 0.8,
		"draw_distance": 0.8,
		"lod_threshold": 2.0,
	},
	Preset.HIGH: {},
}
const DEFAULT_SHADOW_ATLAS: int = 4096
## The engine's own default, restored by `high` the same way every other authored value is.
const DEFAULT_LOD_THRESHOLD: float = 1.0

var preset: Preset = Preset.HIGH
## Read by world/gen/undergrowth.gd when it scatters; 1.0 until a preset lowers it.
var undergrowth_density_scale: float = 1.0
## Multiplies every draw distance `world/environment/draw_policy.gd` hands out. Pulling props in
## is the strongest single lever a weak machine has, because an out-of-range instance costs
## nothing in the opaque pass AND nothing in any of the shadow cascades — one cut is worth five
## draw calls at the shipped four splits (F-144).
var prop_draw_distance_scale: float = 1.0

# Authored values captured the first time a preset touches a node, keyed by instance id, so
# `high` restores rather than guesses. Ids from freed levels are never read again — an apply
# always fetches through the node it just found — so stale entries are only a few bytes.
var _authored_lights: Dictionary = {}
var _authored_environments: Dictionary = {}
var _applied_scene_id: int = 0

## ── Dynamic resolution (F-098) ────────────────────────────────────────────────────────────────
## DOOM-style: hold a target frame rate by stepping the 3D render scale between
## DYNAMIC_SCALE_MIN and the active preset's own scale — the safety net that keeps a weak
## machine playable through its worst moments instead of tuning for its average ones. v1 steers
## by measured fps because Metal's viewport GPU timer reads 0 in this build (F-090). With vsync
## on, fps can never exceed the panel rate, so "comfortably at target" is the up signal: the
## controller probes upward in small steps and backs off in bigger ones — asymmetry keeps the
## worst case short.
const DYNAMIC_SCALE_MIN: float = 0.59
const DYNAMIC_STEP_UP: float = 0.03
const DYNAMIC_STEP_DOWN: float = 0.07
const DYNAMIC_INTERVAL_SEC: float = 0.5

var dynamic_scale_enabled: bool = false
## 0 = follow the panel's refresh rate.
var dynamic_scale_target_fps: float = 0.0
var _dynamic_elapsed: float = 0.0


func _ready() -> void:
	_register_commands()
	_update_processing()


## Runs while a non-default preset is active (a level change arrives authored-high and needs
## the preset re-applied) or while dynamic resolution is steering.
func _process(delta: float) -> void:
	if preset != Preset.HIGH:
		var scene: Node = get_tree().current_scene
		var scene_id: int = 0 if scene == null else scene.get_instance_id()
		if scene_id != _applied_scene_id:
			apply(preset)
	if dynamic_scale_enabled:
		_dynamic_step(delta)


func set_dynamic_scale(enabled: bool, target_fps: float = 0.0) -> void:
	dynamic_scale_enabled = enabled
	dynamic_scale_target_fps = maxf(0.0, target_fps)
	_dynamic_elapsed = 0.0
	if not enabled:
		get_viewport().scaling_3d_scale = _preset_render_scale()
	_update_processing()


func _dynamic_step(delta: float) -> void:
	_dynamic_elapsed += delta
	if _dynamic_elapsed < DYNAMIC_INTERVAL_SEC:
		return
	_dynamic_elapsed = 0.0
	var target := dynamic_scale_target_fps
	if target <= 0.0:
		target = DisplayServer.screen_get_refresh_rate()
		if target <= 0.0:
			target = 60.0
	var fps := Engine.get_frames_per_second()
	var scale := get_viewport().scaling_3d_scale
	if fps < target * 0.97:
		scale -= DYNAMIC_STEP_DOWN
	elif fps >= target * 0.99:
		scale += DYNAMIC_STEP_UP
	get_viewport().scaling_3d_scale = clampf(scale, DYNAMIC_SCALE_MIN, _preset_render_scale())


func _preset_render_scale() -> float:
	return float((PRESETS[preset] as Dictionary).get("render_scale", 1.0))


func _update_processing() -> void:
	set_process(preset != Preset.HIGH or dynamic_scale_enabled)


func apply(new_preset: Preset) -> void:
	preset = new_preset
	var spec: Dictionary = PRESETS[preset] as Dictionary
	var scene: Node = get_tree().current_scene
	_applied_scene_id = 0 if scene == null else scene.get_instance_id()
	_update_processing()

	get_viewport().scaling_3d_scale = float(spec.get("render_scale", 1.0))
	# Screen-space size, in pixels, below which the renderer takes the next LOD down. The engine
	# default is 1.0 — near enough to "only switch when it cannot possibly show" — which is the
	# right default for a machine that can afford it and the wrong one for the machine this game
	# is meant to run on. Raising it costs silhouette detail at distance and nothing else.
	get_viewport().mesh_lod_threshold = float(spec.get("lod_threshold", DEFAULT_LOD_THRESHOLD))
	RenderingServer.directional_shadow_atlas_set_size(
		int(spec.get("shadow_atlas", DEFAULT_SHADOW_ATLAS)), true)
	if scene == null:
		return

	for light: Node in scene.find_children("*", "DirectionalLight3D", true, false):
		var sun := light as DirectionalLight3D
		var authored: Dictionary = _authored_lights.get_or_add(sun.get_instance_id(), {
			"mode": sun.directional_shadow_mode,
			"distance": sun.directional_shadow_max_distance,
		}) as Dictionary
		sun.directional_shadow_mode = int(spec.get("cascades", authored["mode"]))
		sun.directional_shadow_max_distance = float(
			spec.get("shadow_distance", authored["distance"]))

	for holder: Node in scene.find_children("*", "WorldEnvironment", true, false):
		var environment: Environment = (holder as WorldEnvironment).environment
		if environment == null:
			continue
		var authored: Dictionary = _authored_environments.get_or_add(
			environment.get_instance_id(), {
				"glow": environment.glow_enabled,
				"volumetric": environment.volumetric_fog_enabled,
			}) as Dictionary
		environment.glow_enabled = bool(spec.get("glow", authored["glow"]))
		environment.volumetric_fog_enabled = bool(spec.get("volumetric", authored["volumetric"]))

	prop_draw_distance_scale = float(spec.get("draw_distance", 1.0))
	DrawPolicy.rescale(get_tree())

	var target_scale: float = float(spec.get("undergrowth", 1.0))
	if target_scale != undergrowth_density_scale:
		undergrowth_density_scale = target_scale
		var undergrowth: Node = scene.get_node_or_null(^"Undergrowth")
		if undergrowth != null and undergrowth.has_method(&"rescatter"):
			undergrowth.call(&"rescatter")


func _register_commands() -> void:
	var console: Node = get_node_or_null(^"/root/DebugConsole")
	if console == null or not console.has_method("register"):
		return
	console.call("register", &"gfx", _cmd_gfx,
		"gfx [low|medium|high] | gfx auto [<fps>|off] — hardware preset / dynamic resolution")


func _cmd_gfx(args: PackedStringArray) -> String:
	if args.is_empty():
		var auto_state := "off"
		if dynamic_scale_enabled:
			auto_state = "on (target %s)" % ("panel refresh" if dynamic_scale_target_fps <= 0.0 \
				else "%.0f fps" % dynamic_scale_target_fps)
		return "gfx preset is %s (render scale %.0f%%, auto %s)" % [
			PRESET_NAMES[preset], get_viewport().scaling_3d_scale * 100.0, auto_state]
	if args[0] == "auto":
		if args.size() >= 2 and args[1] == "off":
			set_dynamic_scale(false)
			return "dynamic resolution off — render scale back to %.0f%%" % \
				(get_viewport().scaling_3d_scale * 100.0)
		var target: float = 0.0
		if args.size() >= 2 and args[1].is_valid_float():
			target = args[1].to_float()
		set_dynamic_scale(true, target)
		return "dynamic resolution on — holding %s" % \
			("the panel's refresh rate" if target <= 0.0 else "%.0f fps" % target)
	var index: int = PRESET_NAMES.find(args[0])
	if index < 0:
		return "usage: gfx [low|medium|high] | gfx auto [<fps>|off]"
	apply(index as Preset)
	return "gfx preset now %s (render scale %.0f%%)" % [
		args[0], get_viewport().scaling_3d_scale * 100.0]
