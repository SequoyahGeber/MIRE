extends SceneTree

## Proof for F-377: the LOW graphics preset's shadow configuration is internally consistent, and
## MEDIUM and HIGH still get the level's authored one.
##
##   .agent/bin/agent godot --script tools/graphics_quality_check.gd
##
## What this can and cannot prove, stated up front because the finding is a MOTION artefact and a
## check that quietly implies otherwise is worse than no check:
##
##   CAN  — that the parameters which decide shadow stability actually reach the light and the
##          RenderingServer, that they are mutually consistent (bias in proportion to the texel
##          size the cascade/atlas/distance triple produces), that they HOLD while the world moves
##          under a walking camera with the day/night cycle running, that re-applying a preset
##          cannot compound them, and that LOW is still cheap rather than quietly promoted to
##          MEDIUM.
##   CANNOT — that the crawl is gone. Flicker is temporal and sub-pixel; headless has no
##          framebuffer, and even `--windowed` would only give stills. Whether 1.6x/1.25x are the
##          right bias magnitudes is a judgement someone has to make with the camera moving.
##
## The camera walk is not decoration. `world/environment/playtest_atmosphere.gd` writes the sun
## every frame the cycle runs (`light_energy`, `light_color`, `shadow_opacity`, rotation), and
## `world/chunk/chunk_streamer.gd` builds and retires chunks around the anchor. A fix that only
## survives until the first sunset or the first chunk swap is not a fix, and asserting once at
## apply() time would not have caught that.
##
## Authority: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row) — a graphics preset is
## one machine's own presentation, so there is nothing here for a second process to prove.

const ProbeScene := preload("res://tools/probe_scene.gd")

const LOW: int = 0
const MEDIUM: int = 1
const HIGH: int = 2
const PRESET_NAMES: PackedStringArray = ["low", "medium", "high"]

## The distance LOW's cascades covered before F-377, kept so the check can show the fix moved the
## far-texel ratio rather than just assert a number that happens to pass today.
const PRE_F377_LOW_DISTANCE: float = 55.0

## Godot's default PSSM split fractions (`directional_shadow_split_1/2/3` = 0.1/0.2/0.5). The far
## cascade runs from the last fraction out to `directional_shadow_max_distance`, which is the span
## that sets its texel size — and therefore how much bias it needs.
const FAR_SPLIT_START_4: float = 0.5
const FAR_SPLIT_START_2: float = 0.1

## The far cascade may be 1.75x HIGH's texel and no worse. Above that the bias needed to hide the
## self-shadowing starts detaching contact shadows instead, which trades crawl for peter-panning.
const MAX_FAR_TEXEL_RATIO: float = 1.75

## How closely `shadow_normal_bias_scale` must track the texel growth it exists to compensate.
## Normal bias offsets the sample along the surface normal by a distance that only makes sense in
## texels, so the two numbers are the same number and should not be tunable apart by much.
const BIAS_TRACKING_TOLERANCE: float = 0.2

## A walk long enough to cross LOW's near/far cascade boundary (38 m * 0.1 = ~3.8 m) several times
## over and to make the streamer build and retire real chunks around the anchor.
const WALK_STEPS: int = 40
const WALK_START := Vector3(-32.0, 0.0, -32.0)
const WALK_END := Vector3(32.0, 0.0, 32.0)

## Fast enough that 40 frames of walking cross a visible part of the cycle, so the sun is genuinely
## being rewritten while the assertions below claim its shadow config held.
const CHECK_DAY_LENGTH_SEC: float = 45.0

const EPSILON: float = 0.0001

var failures: int = 0
var scene_path: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene_path = ProbeScene.resolve()
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("could not load %s" % scene_path)
		_finish()
		return
	var level: Node = packed.instantiate()
	root.add_child(level)
	current_scene = level
	for _frame in 8:
		await process_frame
		await physics_frame
	await ProbeScene.settle(level)

	print("\n=== MIRE graphics quality (F-377) — %s ===" % ProbeScene.describe(scene_path))

	var gfx: Node = root.get_node_or_null(^"GraphicsQuality")
	check(gfx != null, "GraphicsQuality autoload exists")
	var sun: DirectionalLight3D = _find_sun(level)
	check(sun != null, "the level has a shadow-casting DirectionalLight3D to configure")
	if gfx == null or sun == null:
		_finish()
		return

	# Read before any preset touches the light, so every "restores the authored value" claim below
	# is against the level's real numbers rather than against a preset's idea of them.
	var authored: Dictionary = _sample_light(sun)
	print("authored sun: mode=%d distance=%.1f blend=%s bias=%.4f normal_bias=%.3f" % [
		int(authored["mode"]), float(authored["distance"]), authored["blend"],
		float(authored["bias"]), float(authored["normal_bias"])])

	_check_preset_table(gfx)
	_check_far_texel_geometry(gfx)

	_start_day_cycle(level)

	var walks: Dictionary = {}
	for preset: int in [LOW, MEDIUM, HIGH]:
		walks[preset] = await _walk(gfx, level, preset)

	_check_low(gfx, walks[LOW] as Dictionary, authored)
	_check_medium(walks[MEDIUM] as Dictionary, walks[HIGH] as Dictionary, authored)
	_check_high(walks[HIGH] as Dictionary, authored)
	_check_low_is_still_cheap(gfx, walks[LOW] as Dictionary, walks[MEDIUM] as Dictionary,
		walks[HIGH] as Dictionary)
	await _check_reapply_does_not_compound(gfx, sun, authored)
	await _check_unauthored_light(gfx, level)

	gfx.call(&"apply", HIGH)
	_finish()


## ── The preset table's shape ──────────────────────────────────────────────────────────────────
## The property F-377 explicitly asked to preserve: a preset names only what it overrides. Restating
## HIGH's values inside LOW would look like a fix and would silently impose one level's tuning on
## every other level, so it is asserted rather than trusted.
func _check_preset_table(gfx: Node) -> void:
	var presets: Dictionary = _preset_table(gfx)
	var low: Dictionary = presets[LOW] as Dictionary
	var medium: Dictionary = presets[MEDIUM] as Dictionary
	var high: Dictionary = presets[HIGH] as Dictionary

	check(high.is_empty(), "HIGH overrides nothing — it is the authored look by construction")

	check(low.has("blend_splits") and bool(low["blend_splits"]),
		"LOW states directional_shadow_blend_splits rather than inheriting it (F-377)")
	check(low.has("shadow_normal_bias_scale") and low.has("shadow_bias_scale"),
		"LOW scales both biases with its own atlas/cascade geometry (F-377)")
	check(not low.has("shadow_normal_bias") and not low.has("shadow_bias"),
		"LOW scales the authored bias instead of restating an absolute one")

	var distance: float = float(low.get("shadow_distance", 0.0))
	check(distance >= 35.0 and distance <= 40.0,
		"LOW pulls shadow distance into 35-40 m (F-377) — got %.1f" % distance)

	# MEDIUM's answer to "does it have the same latent problem": no, because it names no shadow
	# knob at all, so there is no combination of knobs for it to be inconsistent about.
	for key: String in ["cascades", "shadow_distance", "shadow_atlas", "blend_splits",
			"shadow_bias_scale", "shadow_normal_bias_scale"]:
		check(not medium.has(key),
			"MEDIUM names no shadow knob (%s) — it inherits HIGH's consistent set" % key)


## ── The geometry the bias scale is derived from ───────────────────────────────────────────────
## Both halves of the fix — pulling shadow distance in, and scaling normal bias up — exist to serve
## one number: how big the far cascade's texel is compared with HIGH's. Deriving it here from the
## preset table means the doc comment in graphics_quality.gd cannot rot into a claim about numbers
## the file no longer holds.
func _check_far_texel_geometry(gfx: Node) -> void:
	var presets: Dictionary = _preset_table(gfx)
	var low: Dictionary = presets[LOW] as Dictionary
	var default_atlas: int = int(_script_const(gfx, &"DEFAULT_SHADOW_ATLAS"))

	# HIGH is the authored light, whose distance the preset table does not carry — read it from the
	# level rather than assuming, so a re-authored sun re-derives instead of silently passing.
	var sun: DirectionalLight3D = _find_sun(current_scene)
	var high_texel: float = _far_texel(
		sun.directional_shadow_max_distance, _cascade_count(sun.directional_shadow_mode),
		default_atlas)
	var low_cascades: int = _cascade_count(int(low["cascades"]))
	var low_atlas: int = int(low["shadow_atlas"])
	var now_texel: float = _far_texel(float(low["shadow_distance"]), low_cascades, low_atlas)
	var before_texel: float = _far_texel(PRE_F377_LOW_DISTANCE, low_cascades, low_atlas)

	var now_ratio: float = now_texel / high_texel
	var before_ratio: float = before_texel / high_texel
	print("far cascade texel vs high: was %.2fx at %.0f m, now %.2fx at %.0f m" % [
		before_ratio, PRE_F377_LOW_DISTANCE, now_ratio, float(low["shadow_distance"])])

	check(now_ratio < before_ratio,
		"pulling shadow distance in shrank LOW's far texel (%.2fx -> %.2fx of HIGH's)"
			% [before_ratio, now_ratio])
	check(now_ratio <= MAX_FAR_TEXEL_RATIO,
		"LOW's far texel stays within %.2fx of HIGH's — got %.2fx"
			% [MAX_FAR_TEXEL_RATIO, now_ratio])

	# The load-bearing consistency claim: bias is not a free knob, it is the texel ratio expressed
	# as a multiplier. If someone retunes shadow_distance or the atlas without moving this, the two
	# stop describing the same configuration and F-377 comes back in a new shape.
	var normal_scale: float = float(low["shadow_normal_bias_scale"])
	check(absf(normal_scale - now_ratio) <= BIAS_TRACKING_TOLERANCE,
		"shadow_normal_bias_scale %.2f tracks the %.2fx texel growth it compensates (F-377)"
			% [normal_scale, now_ratio])
	# Depth bias moves with the same geometry but is deliberately the smaller of the two: it is the
	# one that lifts a shadow off its caster, and LOW's shorter depth range needs less of it.
	var depth_scale: float = float(low["shadow_bias_scale"])
	check(depth_scale >= 1.0 and depth_scale < normal_scale,
		"shadow_bias_scale %.2f rises with the atlas cut but stays under the normal-bias scale"
			% depth_scale)


## Relative world size of the far cascade's texel. Godot gives a 4-split light one quadrant of the
## atlas per split and a 2-split light one half, so the short side is `atlas / 2` either way — the
## cascade count shows up in how much GROUND the far split has to cover, not in its pixel count.
func _far_texel(distance: float, cascades: int, atlas: int) -> float:
	var start: float = FAR_SPLIT_START_4 if cascades == 4 else FAR_SPLIT_START_2
	if cascades <= 1:
		start = 0.0
	return (distance * (1.0 - start)) / (float(atlas) / 2.0)


func _cascade_count(mode: int) -> int:
	match mode:
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS: return 2
		DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS: return 4
	return 1


## ── The walk ──────────────────────────────────────────────────────────────────────────────────
## Applies a preset, then moves the streaming anchor across the island while the day/night cycle
## runs, sampling every frame. Returns the first sample plus whether anything drifted.
func _walk(gfx: Node, level: Node, preset: int) -> Dictionary:
	gfx.call(&"apply", preset)
	await process_frame

	var sun: DirectionalLight3D = _find_sun(level)
	var samples: Array[Dictionary] = []
	for step: int in WALK_STEPS:
		var t: float = float(step) / float(maxi(WALK_STEPS - 1, 1))
		_set_anchor(level, WALK_START.lerp(WALK_END, t))
		await process_frame
		var sample: Dictionary = _sample_light(sun)
		sample["atlas"] = int(gfx.get(&"applied_shadow_atlas"))
		sample["render_scale"] = root.scaling_3d_scale
		sample["preset"] = int(gfx.get(&"preset"))
		samples.append(sample)

	var first: Dictionary = samples[0]
	var drifted: String = ""
	for sample: Dictionary in samples:
		for key: String in first:
			if not _same(first[key], sample[key]):
				drifted = key
				break
	print("%-6s walk: mode=%d distance=%.1f blend=%s bias=%.4f normal_bias=%.3f atlas=%d scale=%.2f%s"
		% [PRESET_NAMES[preset], int(first["mode"]), float(first["distance"]), first["blend"],
			float(first["bias"]), float(first["normal_bias"]), int(first["atlas"]),
			float(first["render_scale"]),
			"" if drifted.is_empty() else "  DRIFTED: %s" % drifted])
	check(drifted.is_empty(),
		"%s holds its shadow config across %d frames of movement and day/night (F-377)"
			% [PRESET_NAMES[preset], WALK_STEPS])
	return first


func _check_low(gfx: Node, low: Dictionary, authored: Dictionary) -> void:
	var spec: Dictionary = _preset_table(gfx)[LOW] as Dictionary

	check(int(low["mode"]) == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"LOW applies 2 PSSM splits")
	check(is_equal_approx(float(low["distance"]), float(spec["shadow_distance"])),
		"LOW's pulled-in shadow distance reaches the light (%.1f m)" % float(low["distance"]))
	check(bool(low["blend"]), "LOW blends the cascade seam, so the boundary is not a hard cut")
	check(int(low["atlas"]) == int(spec["shadow_atlas"]),
		"LOW's 2048 atlas reaches the RenderingServer")
	check(is_equal_approx(float(low["render_scale"]), float(spec["render_scale"])),
		"LOW's render scale reaches the viewport")

	var want_normal: float = float(authored["normal_bias"]) * float(spec["shadow_normal_bias_scale"])
	var want_bias: float = float(authored["bias"]) * float(spec["shadow_bias_scale"])
	check(is_equal_approx(float(low["normal_bias"]), want_normal),
		"LOW scales the AUTHORED normal bias (%.3f -> %.3f), not an absolute of its own"
			% [float(authored["normal_bias"]), float(low["normal_bias"])])
	check(is_equal_approx(float(low["bias"]), want_bias),
		"LOW scales the AUTHORED depth bias (%.4f -> %.4f)"
			% [float(authored["bias"]), float(low["bias"])])
	check(float(low["normal_bias"]) > float(authored["normal_bias"]),
		"LOW's normal bias is larger than HIGH's, as the coarser texel requires")


## The answer to "check MEDIUM for the same latent problem": it does not have one, and the proof is
## that every shadow parameter it applies is byte-identical to HIGH's. Its only exposure to F-377 is
## render scale 0.77, which is one of the four causes acting alone on a full-quality shadow map.
func _check_medium(medium: Dictionary, high: Dictionary, authored: Dictionary) -> void:
	for key: String in ["mode", "distance", "blend", "bias", "normal_bias", "atlas"]:
		check(_same(medium[key], high[key]),
			"MEDIUM's %s is identical to HIGH's — it has no shadow config of its own" % key)
	for key: String in ["mode", "distance", "blend", "bias", "normal_bias"]:
		check(_same(medium[key], authored[key]),
			"MEDIUM leaves the level's authored %s alone" % key)
	check(float(medium["render_scale"]) < 1.0 and float(medium["render_scale"]) > 0.7,
		"MEDIUM's only F-377 exposure is its render scale (%.2f)" % float(medium["render_scale"]))


## The round trip. LOW mutated three properties on this light; HIGH has to land back on the level's
## own numbers rather than on a hardcoded copy of them, which is the whole reason the biases are
## applied as scales on a captured authored value.
func _check_high(high: Dictionary, authored: Dictionary) -> void:
	for key: String in ["mode", "distance", "blend", "bias", "normal_bias"]:
		check(_same(high[key], authored[key]),
			"HIGH restores the authored %s exactly after LOW changed it" % key)
	check(is_equal_approx(float(high["render_scale"]), 1.0), "HIGH renders at full scale")


## F-377 is fixed by making LOW's shadows internally consistent, NOT by giving quality back. This is
## the guard against the fix quietly promoting the worst-machine preset into a second MEDIUM.
func _check_low_is_still_cheap(gfx: Node, low: Dictionary, medium: Dictionary,
		high: Dictionary) -> void:
	check(int(low["atlas"]) < int(high["atlas"]),
		"LOW still runs a smaller shadow atlas than HIGH")
	check(_cascade_count(int(low["mode"])) < _cascade_count(int(high["mode"])),
		"LOW still re-renders the caster scene fewer times per frame than HIGH")
	check(float(low["distance"]) < float(high["distance"]),
		"LOW still makes less of the world a shadow caster than HIGH")
	check(float(low["render_scale"]) < float(medium["render_scale"]),
		"LOW still renders at a lower scale than MEDIUM")
	# The non-shadow levers, so a future edit cannot pay for shadow stability out of the scatter
	# budget without this check noticing.
	gfx.call(&"apply", LOW)
	check(is_equal_approx(float(gfx.get(&"undergrowth_density_scale")), 0.45),
		"LOW still scatters undergrowth at 45%")
	check(is_equal_approx(float(gfx.get(&"prop_draw_distance_scale")), 0.55),
		"LOW still pulls prop draw distance to 55%")


## `_process()` re-applies the active preset on every scene change, and the settings menu can apply
## the same preset repeatedly. Both biases are computed from the captured authored value, so this
## must be idempotent — computing them from the light's CURRENT value would multiply 1.6x per apply
## until every shadow floated off its caster.
func _check_reapply_does_not_compound(gfx: Node, sun: DirectionalLight3D,
		authored: Dictionary) -> void:
	gfx.call(&"apply", LOW)
	await process_frame
	var once: Dictionary = _sample_light(sun)
	for _repeat in 4:
		gfx.call(&"apply", LOW)
		await process_frame
	var many: Dictionary = _sample_light(sun)
	check(_same(once["normal_bias"], many["normal_bias"]) and _same(once["bias"], many["bias"]),
		"re-applying LOW five times does not compound the bias scale (%.3f stays %.3f)"
			% [float(once["normal_bias"]), float(many["normal_bias"])])

	gfx.call(&"apply", HIGH)
	await process_frame
	var restored: Dictionary = _sample_light(sun)
	check(_same(restored["normal_bias"], authored["normal_bias"])
			and _same(restored["bias"], authored["bias"]),
		"HIGH after five LOW applies still lands on the authored bias")


## The half of F-377 that the three shipped gameplay levels hide: they all author
## `directional_shadow_blend_splits = true`, so inheriting it looked fine. levels/greybox_test.tscn
## does not, the frontend backdrop's runtime-built sun does not, and a procedurally generated world
## has no author at all. A light at engine defaults must come out of LOW configured, not defaulted.
func _check_unauthored_light(gfx: Node, level: Node) -> void:
	var bare := DirectionalLight3D.new()
	bare.name = "UnauthoredSunProbe"
	bare.shadow_enabled = true
	level.add_child(bare)
	var defaults: Dictionary = _sample_light(bare)
	check(not bool(defaults["blend"]),
		"a light at engine defaults starts with no cascade blending — the case levels hide")

	gfx.call(&"apply", LOW)
	await process_frame
	var applied: Dictionary = _sample_light(bare)
	check(bool(applied["blend"]),
		"LOW turns cascade blending on for a light that never authored it (F-377)")
	var spec: Dictionary = _preset_table(gfx)[LOW] as Dictionary
	check(is_equal_approx(float(applied["normal_bias"]),
			float(defaults["normal_bias"]) * float(spec["shadow_normal_bias_scale"])),
		"LOW scales an unauthored light's default normal bias by the same factor")

	gfx.call(&"apply", HIGH)
	await process_frame
	var restored: Dictionary = _sample_light(bare)
	check(not bool(restored["blend"]) and _same(restored["normal_bias"], defaults["normal_bias"]),
		"HIGH restores the unauthored light to the engine defaults it arrived with")

	# Freed immediately rather than queued: the check quits within a few frames of here, and a
	# deferred free that never runs shows up as a leaked ObjectDB instance in the exit log.
	level.remove_child(bare)
	bare.free()


## ── Helpers ───────────────────────────────────────────────────────────────────────────────────

## `PRESETS` and `DEFAULT_SHADOW_ATLAS` are script constants, not properties, so `Object.get()`
## cannot see them — read them out of the script's own constant map instead. Reading the shipped
## table rather than restating it is the point: a check that hardcodes 38.0 proves only that this
## file and graphics_quality.gd were edited by the same person on the same day.
func _preset_table(gfx: Node) -> Dictionary:
	return _script_const(gfx, &"PRESETS") as Dictionary


func _script_const(node: Node, name: StringName) -> Variant:
	return (node.get_script() as Script).get_script_constant_map()[name]


func _sample_light(sun: DirectionalLight3D) -> Dictionary:
	return {
		"mode": sun.directional_shadow_mode,
		"distance": sun.directional_shadow_max_distance,
		"blend": sun.directional_shadow_blend_splits,
		"bias": sun.shadow_bias,
		"normal_bias": sun.shadow_normal_bias,
	}


## Free-runs the day/night cycle for the duration of the walks. Without this the sun is written once
## at _ready() and the "it holds while the world moves" claim would be proving nothing.
func _start_day_cycle(level: Node) -> void:
	for node: Node in level.find_children("*", "Node", true, false):
		if not node.has_method(&"set_cycle_enabled"):
			continue
		node.set(&"day_length_seconds", CHECK_DAY_LENGTH_SEC)
		node.call(&"set_cycle_enabled", true)
		print("day/night cycle running at %.0f s per day during the walks"
			% CHECK_DAY_LENGTH_SEC)
		return
	push_warning("no atmosphere node found — the walks move the camera but not the sun")


## Moves the chunk streamer's anchor, so the walk builds and retires real chunks rather than just
## advancing frames. Duck-typed: a fixture with no streamer is a silent no-op.
func _set_anchor(level: Node, position: Vector3) -> void:
	for node: Node in level.find_children("*", "Node", true, false):
		if node.has_method(&"set_anchors"):
			# Typed to match the streamer's own `Array[Vector3]` parameter — `call()` will not
			# coerce an untyped array into a typed one.
			var anchors: Array[Vector3] = [position]
			node.call(&"set_anchors", anchors)
			return


func _find_sun(node: Node) -> DirectionalLight3D:
	if node == null:
		return null
	var light := node as DirectionalLight3D
	if light != null and light.shadow_enabled and light.name != "UnauthoredSunProbe":
		return light
	for child: Node in node.get_children():
		var found: DirectionalLight3D = _find_sun(child)
		if found != null:
			return found
	return null


## Float-tolerant equality, because two of the five sampled properties are floats and an exact
## comparison on those would report a rounding artefact as a drift.
func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return absf(float(a) - float(b)) < EPSILON
	return a == b


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	print("\nGRAPHICS_QUALITY_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
