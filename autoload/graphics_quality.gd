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
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row). Presentation is
## local to one machine; peers on different presets run the same simulation.
##
## Release worlds are randomly generated — nothing here assumes the authored map. Levels are
## discovered through the tree at apply time (any DirectionalLight3D, any WorldEnvironment, a
## node named Undergrowth), and authored values are captured per node the first time a preset
## touches it, so `high` on a generated level restores that level's own numbers.

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
	},
	Preset.MEDIUM: {
		"render_scale": 0.77,
		"undergrowth": 0.8,
	},
	Preset.HIGH: {},
}
const DEFAULT_SHADOW_ATLAS: int = 4096

var preset: Preset = Preset.HIGH
## Read by world/gen/undergrowth.gd when it scatters; 1.0 until a preset lowers it.
var undergrowth_density_scale: float = 1.0

# Authored values captured the first time a preset touches a node, keyed by instance id, so
# `high` restores rather than guesses. Ids from freed levels are never read again — an apply
# always fetches through the node it just found — so stale entries are only a few bytes.
var _authored_lights: Dictionary = {}
var _authored_environments: Dictionary = {}
var _applied_scene_id: int = 0


func _ready() -> void:
	_register_commands()
	set_process(false)


## Only runs while a non-default preset is active: when the level changes out from under it,
## the fresh level arrives authored-high and needs the preset re-applied.
func _process(_delta: float) -> void:
	var scene: Node = get_tree().current_scene
	var scene_id: int = 0 if scene == null else scene.get_instance_id()
	if scene_id != _applied_scene_id:
		apply(preset)


func apply(new_preset: Preset) -> void:
	preset = new_preset
	var spec: Dictionary = PRESETS[preset] as Dictionary
	var scene: Node = get_tree().current_scene
	_applied_scene_id = 0 if scene == null else scene.get_instance_id()
	set_process(preset != Preset.HIGH)

	get_viewport().scaling_3d_scale = float(spec.get("render_scale", 1.0))
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
		"gfx [low|medium|high] — hardware preset (F-090); no argument shows the current one")


func _cmd_gfx(args: PackedStringArray) -> String:
	if args.is_empty():
		return "gfx preset is %s (render scale %.0f%%)" % [
			PRESET_NAMES[preset], get_viewport().scaling_3d_scale * 100.0]
	var index: int = PRESET_NAMES.find(args[0])
	if index < 0:
		return "usage: gfx [low|medium|high]"
	apply(index as Preset)
	return "gfx preset now %s (render scale %.0f%%)" % [
		args[0], get_viewport().scaling_3d_scale * 100.0]
