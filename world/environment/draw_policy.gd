extends RefCounted

## How far a piece of world geometry is worth drawing, and whether it is worth a shadow — decided
## from the geometry itself, so it travels with the asset rather than with any map (F-144).
##
## The numbers this file exists to move: Hollowmere submitted 36,442 draw calls per frame, 28,088
## of them shadow-pass copies of the same 7,022 casters in four cascades. DOOM 2016 held ~1,331.
## Nothing on the map had a draw distance at all except the undergrowth, which had proved the rule
## already — `world/gen/undergrowth.gd` fades ground cover at 60 m and taller flora at 110 m, and
## measured the shadow pass at 2.4 ms of 4.1 before it stopped moss from casting.
##
## Godot skips an out-of-range instance ENTIRELY, shadow passes included, so one range cut is
## worth `1 + cascades` draw calls — five of them at the shipped four splits. That is why this is
## the cheapest lever in the renderer and why it is applied per instance rather than globally.
##
## Sizing by the mesh's own AABB rather than by an asset list is the part that matters for
## release: worlds are randomly generated, so a rule that reads "reeds fade at 80 m" is a rule
## that only ever describes the authored map. A rule that reads "things under 1.5 m fade at 80 m"
## describes whatever the generator stamps, including assets that do not exist yet.
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row). Draw distance is
## presentation, local to one machine; two peers on different presets simulate identically.

## Ranges are for the base preset; `GraphicsQuality` scales them per machine.
##
## Chosen to be generous rather than clever. A landmark you navigate by must not fade — you would
## feel that as the world rearranging itself behind you — so anything tall keeps a distance longer
## than Hollowmere's own diameter and only bites on a large generated world. Small clutter is the
## opposite: it reads as texture, not as landmark, and dithering it out is invisible.
const TALL_MIN_HEIGHT: float = 4.0
const SMALL_MAX_HEIGHT: float = 1.5
const TALL_RANGE: float = 260.0
const MEDIUM_RANGE: float = 150.0
const SMALL_RANGE: float = 80.0
## Dithered hand-over distance. Godot fades the instance out across this margin BEFORE the range
## ends, so nothing ever pops; the cost is that both states are drawn inside the margin, which is
## why it is a band and not a curve.
const FADE_MARGIN: float = 12.0

## Below this, an object's shadow is a smudge under itself that no player will ever identify, and
## it costs one draw call per cascade to produce. Undergrowth draws the same line at 0.75 m for
## ground cover; props sit a little higher because a knee-height rock still grounds visually.
const SHADOW_MIN_HEIGHT: float = 1.2

## Instances that took a policy, so a preset change can re-apply it without the level's help.
const GROUP: StringName = &"draw_policy"
## The un-scaled range this instance was given, kept so a rescale multiplies the base rather than
## compounding on whatever the last preset left behind.
const BASE_RANGE_META: StringName = &"draw_policy_base_range"


## Give one instance its draw distance and shadow decision.
##
## `aabb` is the merged local bounds of what it draws — for a MultiMesh, the bounds of ONE copy,
## since every copy is the same mesh. `scale_hint` carries any uniform scale the placements apply,
## so a pine stamped at 1.4x is measured at the size it is actually drawn.
static func apply(instance: GeometryInstance3D, aabb: AABB, scale_hint: float = 1.0) -> void:
	var height: float = aabb.size.y * maxf(scale_hint, 0.001)
	var range_end: float = MEDIUM_RANGE
	if height >= TALL_MIN_HEIGHT:
		range_end = TALL_RANGE
	elif height <= SMALL_MAX_HEIGHT:
		range_end = SMALL_RANGE

	instance.set_meta(BASE_RANGE_META, range_end)
	instance.add_to_group(GROUP)
	instance.visibility_range_end = range_end * _scale()
	instance.visibility_range_end_margin = FADE_MARGIN
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if height < SHADOW_MIN_HEIGHT:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Re-apply every live policy at the current preset's scale. `GraphicsQuality` calls this when a
## preset lands; nothing else needs to know the group exists.
static func rescale(tree: SceneTree) -> int:
	var scale: float = _scale()
	var touched: int = 0
	for node: Node in tree.get_nodes_in_group(GROUP):
		var instance := node as GeometryInstance3D
		if instance == null:
			continue
		var base: float = float(instance.get_meta(BASE_RANGE_META, 0.0))
		if base <= 0.0:
			continue
		instance.visibility_range_end = base * scale
		touched += 1
	return touched


## The active preset's draw-distance multiplier, read defensively: this library is preloaded by
## the world builder, which headless checks run without the autoload present.
static func _scale() -> float:
	var quality: Object = Engine.get_singleton(&"GraphicsQuality") \
		if Engine.has_singleton(&"GraphicsQuality") else null
	if quality == null:
		var loop := Engine.get_main_loop() as SceneTree
		if loop != null and loop.root != null:
			quality = loop.root.get_node_or_null(^"GraphicsQuality")
	if quality == null:
		return 1.0
	var value: Variant = quality.get(&"prop_draw_distance_scale")
	return float(value) if value != null else 1.0
