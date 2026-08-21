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
##   blend splits      — NOT a cost lever; the stability partner of the two above (F-377)
##   shadow bias scale — NOT a cost lever either; keeps bias proportional to texel size (F-377)
##   glow, volumetric  — post/froxel passes that touch the whole frame
##   ssao              — a per-pixel screen-space occlusion pass, plus a global quality tier
##                       (samples, half-resolution, blur passes, fade distance) that costs as much
##                       as the on/off flag does. Off entirely on LOW (F-398)
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
##
## ── Shadow stability is a property of the whole preset, not of one knob (F-377) ────────────────
## Reported from play: "shadows flicker and flash on low graphics quality". LOW had lowered four
## shadow knobs independently — 2 splits instead of 4, 55 m of distance, a 2048 atlas instead of
## 4096, and a 0.59 render scale — each of which is a defensible cost cut on its own and which
## together produced a configuration that was cheap and wrong. Nothing owned the stability of the
## result, because stability is not a property any one of those knobs has.
##
## The three things that were actually wrong, and what LOW now does about each:
##
##   1. Texel size. Halving the atlas halves the resolution of every split, and halving the split
##      count roughly doubles the ground each remaining split has to cover. Those multiply. The
##      fix is not to give the atlas back — LOW exists for the worst machine we target and 2048
##      is most of why it is cheap — but to stop asking those two splits to cover 55 m. At 38 m
##      the far split's slice is about 34 m of the frustum against HIGH's ~42 m, so LOW's far
##      texel ends up roughly 1.6x HIGH's rather than the ~2.3x it was, for no extra fill.
##      tools/graphics_quality_check.gd derives both ratios from the preset table itself, so this
##      paragraph cannot rot into a comment that describes numbers the file no longer has.
##   2. The cascade seam. Without `directional_shadow_blend_splits` the boundary between the two
##      splits is a hard cut, and with only two splits that cut sits right where the player walks.
##      The three shipped gameplay levels happen to author it `true`, which is why this never got
##      caught in review — but `levels/greybox_test.tscn` and the frontend backdrop's runtime sun
##      do not, and a procedurally generated world has no author to rely on at all. So LOW states
##      it rather than inheriting it. It costs a boundary blend, not a third cascade.
##   3. Bias. `shadow_bias`/`shadow_normal_bias` are authored against the split geometry the level
##      was tuned at, and LOW changes that geometry underneath them. They are applied here as
##      SCALES on the level's own authored values, never as absolute numbers: an absolute would
##      restate one level's tuning (procedural_island's 2.4 normal bias) onto every other one
##      (Hollowmere's 1.3, greybox's engine default) and quietly break the "a preset names only
##      what it overrides" property that makes `high` an exact restore. `shadow_normal_bias_scale`
##      tracks the 1.6x texel growth from (1); `shadow_bias_scale` is deliberately smaller, because
##      depth bias is the one that detaches a shadow from its caster and LOW's shorter depth range
##      already needs less of it. Both magnitudes are the taste half of this fix — the geometry is
##      derived, the exact values want a human's eyes on a moving camera.
##
## MEDIUM does NOT have this problem and deliberately gets none of this treatment: it overrides no
## shadow knob at all, so it runs HIGH's authored cascades, distance, atlas and bias, all mutually
## consistent. Its only exposure is render scale 0.77, which is the mildest of the four causes
## acting alone and on a full-quality shadow map. Adding shadow overrides to MEDIUM would make it
## differ from HIGH for no reason. Note that dynamic resolution (F-098) can drive MEDIUM and HIGH
## down to DYNAMIC_SCALE_MIN, i.e. LOW's render scale — they keep the good shadow map while it
## does, which is exactly the trade that makes the render-scale contribution survivable.

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
		# 55.0 before F-377. Two splits over 55 m at a 2048 atlas gave the far cascade a texel
		# roughly 2.3x HIGH's, which at 0.59 render scale is what the crawl actually was;
		# tools/graphics_quality_check.gd derives both ratios rather than trusting this line.
		"shadow_distance": 38.0,
		"shadow_atlas": 2048,
		# Stated, not inherited: with two splits the seam sits in walking range, and not every
		# level (greybox, anything generated) authors this on. See the F-377 block at the top.
		"blend_splits": true,
		# Multipliers on the level's own authored bias, never absolutes — see the F-377 block.
		"shadow_normal_bias_scale": 1.6,
		"shadow_bias_scale": 1.25,
		"glow": false,
		"volumetric": false,
		# F-398. SSAO is a per-pixel screen-space pass and LOW exists for the worst machine we
		# target, so it goes in the same list glow and volumetric are already in. Off means the
		# pass does not run at all — `ssao_quality` below is not consulted on this preset.
		"ssao": false,
		"undergrowth": 0.45,
		"draw_distance": 0.55,
		"lod_threshold": 4.0,
	},
	# Checked for F-377's problem and deliberately left alone: MEDIUM names no shadow knob, so it
	# runs HIGH's authored cascades/distance/atlas/bias as one consistent set. Do not "fix" it to
	# match LOW — that would make it differ from the authored look for no reason.
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
## The atlas size the last `apply()` actually pushed to the RenderingServer. The server has no
## getter for it, so without this a check can only assert what the preset table INTENDS, which is
## the one thing that was never in doubt in F-377. Written from the same expression that makes the
## call, on the line after it, so the two cannot drift.
var applied_shadow_atlas: int = DEFAULT_SHADOW_ATLAS
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
	applied_shadow_atlas = int(spec.get("shadow_atlas", DEFAULT_SHADOW_ATLAS))
	RenderingServer.directional_shadow_atlas_set_size(applied_shadow_atlas, true)
	if scene == null:
		return

	for light: Node in scene.find_children("*", "DirectionalLight3D", true, false):
		var sun := light as DirectionalLight3D
		var authored: Dictionary = _authored_lights.get_or_add(sun.get_instance_id(), {
			"mode": sun.directional_shadow_mode,
			"distance": sun.directional_shadow_max_distance,
			"blend_splits": sun.directional_shadow_blend_splits,
			"bias": sun.shadow_bias,
			"normal_bias": sun.shadow_normal_bias,
		}) as Dictionary
		sun.directional_shadow_mode = int(spec.get("cascades", authored["mode"]))
		sun.directional_shadow_max_distance = float(
			spec.get("shadow_distance", authored["distance"]))
		sun.directional_shadow_blend_splits = bool(
			spec.get("blend_splits", authored["blend_splits"]))
		# Both biases are derived from the AUTHORED value every time, never from the light's
		# current one, so re-applying a preset — which `_process()` does on every scene change —
		# cannot compound the scale, and `high` lands back on the level's exact numbers (F-377).
		sun.shadow_bias = float(authored["bias"]) * float(spec.get("shadow_bias_scale", 1.0))
		sun.shadow_normal_bias = float(authored["normal_bias"]) \
			* float(spec.get("shadow_normal_bias_scale", 1.0))

	for holder: Node in scene.find_children("*", "WorldEnvironment", true, false):
		var environment: Environment = (holder as WorldEnvironment).environment
		if environment == null:
			continue
		var authored: Dictionary = _authored_environments.get_or_add(
			environment.get_instance_id(), {
				"glow": environment.glow_enabled,
				"volumetric": environment.volumetric_fog_enabled,
				# F-398. Captured exactly like the two above and for the same reason: the level owns
				# whether it has contact shading, the preset only owns whether this machine can
				# afford it. `world/environment/playtest_atmosphere.gd` writes the AO tuning in its
				# own `_ready()` and deliberately never writes this flag, so it is still the LEVEL's
				# value being captured here and HIGH is still an exact restore.
				"ssao": environment.ssao_enabled,
			}) as Dictionary
		environment.glow_enabled = bool(spec.get("glow", authored["glow"]))
		environment.volumetric_fog_enabled = bool(spec.get("volumetric", authored["volumetric"]))
		environment.ssao_enabled = bool(spec.get("ssao", authored["ssao"]))

	prop_draw_distance_scale = float(spec.get("draw_distance", 1.0))
	DrawPolicy.rescale(get_tree())

	var target_scale: float = float(spec.get("undergrowth", 1.0))
	if target_scale != undergrowth_density_scale:
		undergrowth_density_scale = target_scale
		var undergrowth: Node = scene.get_node_or_null(^"Undergrowth")
		if undergrowth != null and undergrowth.has_method(&"rescatter"):
			undergrowth.call(&"rescatter")


func _register_commands() -> void:
	# Migrated off DebugConsole.register()'s deprecation shim (F-130) — the last of the three
	# stragglers, behind dev_frame_cap's two, because this file was under another task's claim when
	# they were done. Same LOCAL-scope reasoning as fps_cap/vsync: a render preset is this machine's
	# own presentation, never simulated state, so a client changing its own must not need op.
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"gfx", {
		"scope": &"local",
		# Two raw strings, dispatched by the handler: `gfx` has a two-form grammar
		# (`gfx [low|medium|high]` vs `gfx auto [<fps>|off]`) that the flat arg table cannot
		# express — same reasoning as `rule`'s value argument, where only the handler knows.
		"args": [
			{"name": "mode", "type": &"string", "optional": true, "default": ""},
			{"name": "value", "type": &"string", "optional": true, "default": ""},
		],
		"handler": _cmd_gfx,
		"help": "gfx [low|medium|high] | gfx auto [<fps>|off] — hardware preset / dynamic resolution",
	})


func _cmd_gfx(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var mode: String = String(args.get("mode", ""))
	var value: String = String(args.get("value", ""))
	if mode.is_empty():
		var auto_state := "off"
		if dynamic_scale_enabled:
			auto_state = "on (target %s)" % ("panel refresh" if dynamic_scale_target_fps <= 0.0 \
				else "%.0f fps" % dynamic_scale_target_fps)
		return {"ok": true, "message": "gfx preset is %s (render scale %.0f%%, auto %s)" % [
			PRESET_NAMES[preset], get_viewport().scaling_3d_scale * 100.0, auto_state], "data": {}}
	if mode == "auto":
		if value == "off":
			set_dynamic_scale(false)
			return {"ok": true, "message": "dynamic resolution off — render scale back to %.0f%%" % \
				(get_viewport().scaling_3d_scale * 100.0), "data": {}}
		var target: float = 0.0
		if value.is_valid_float():
			target = value.to_float()
		set_dynamic_scale(true, target)
		return {"ok": true, "message": "dynamic resolution on — holding %s" % \
			("the panel's refresh rate" if target <= 0.0 else "%.0f fps" % target), "data": {}}
	var index: int = PRESET_NAMES.find(mode)
	if index < 0:
		return {"ok": false,
			"message": "usage: gfx [low|medium|high] | gfx auto [<fps>|off]", "data": {}}
	apply(index as Preset)
	return {"ok": true, "message": "gfx preset now %s (render scale %.0f%%)" % [
		mode, get_viewport().scaling_3d_scale * 100.0], "data": {}}
