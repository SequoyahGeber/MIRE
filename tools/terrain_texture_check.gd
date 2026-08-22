extends SceneTree

## @verify windowed — this check photographs the ground, and a capture needs a framebuffer, so
## `agent verify` must launch it with a framebuffer instead of the `--headless` it injects by
## default (F-556).

## F-399 — the ground is no longer one flat value per biome, and this both PROVES it and
## PHOTOGRAPHS it.
##
##   .agent/bin/agent godot --windowed --script tools/terrain_texture_check.gd
##
## Windowed, always: it renders. The wrapper forces a 64x64 window (F-077), so like
## `tools/atmosphere_look_shot.gd` this draws through a SubViewport of its own size sharing the
## booted world's `World3D` — the window is irrelevant, only the renderer has to be real.
##
## Why a render and not an inspection of the shader source: what F-399 asks for is a judgement about
## how ground READS, and the only honest way to gate that is on pixels. Every frame here is taken
## twice from the identical camera — once with `ground_detail_strength = 0`, which collapses the
## whole detail term to `vec3(1.0)` and is bit-for-bit the pre-F-399 shader, and once at the shipped
## 1.0. So "before" is not a reconstruction or a memory of an older commit; it is this build with
## one uniform turned off, and the two frames differ in exactly one thing.
##
## Four assertions, in the order they would catch a regression:
##
##   1. **PRESENT** — the ground crop's per-pixel colour spread (mean per-channel standard
##      deviation) rises at every distance. This is the finding's literal ask: a hillside that was
##      one RGB value across forty metres no longer is.
##   2. **SUBTLE** — the mean absolute per-pixel change stays small, and the crop's MEAN colour
##      barely moves. Together those say the effect is a centred modulation of whatever base colour
##      arrived, not a repaint and not a global brightening. The mean-colour half matters more than
##      it looks: F-397 is re-authoring the biome palette concurrently, and a detail pass that
##      shifted the average would be silently fighting that work.
##   3. **NOT DITHERING** — the mean difference between horizontally adjacent pixels barely rises.
##      A field finer than the ~1 m facet, or a per-facet jitter turned up too far, shows up here
##      first and shows up nowhere else: it can raise the spread in (1) while looking like noise
##      sitting on the geometry, which is worse than the flat colour it replaced.
##   4. **WORLD-ANCHORED** — two orthographic top-downs of the same ground, the camera moved by
##      exactly a whole number of pixels' worth of metres, agree after that shift. A field computed
##      from view-space position or from screen UV passes 1-3 and fails this one, and it is the
##      failure that would look worst in play: ground that slides under the player as they walk.
##      An ortho pair is used rather than two perspective poses so the expected relationship between
##      the two frames is an exact integer pixel translation, with no reprojection and no
##      distance-dependent fog to model. Compared as a MEDIAN so a swaying prop in a minority of
##      pixels cannot decide it.
##
## The gates are calibrated from the first clean run and recorded at each constant. They are
## deliberately loose in the direction of "the effect got stronger" — this is a look that will be
## retuned — and tight in the direction of "the effect vanished" or "it became a pattern".
##
## Authority (docs/ARCHITECTURE.md §2.2): none. It boots a world for its renderer and its terrain,
## drives no session, and mutates nothing outside its own SubViewport and one shader uniform it puts
## back before it exits.

const WorldScene := preload("res://levels/procedural_island.tscn")
const Heightmap := preload("res://world/gen/island_heightmap.gd")

const WIDTH: int = 1280
const HEIGHT: int = 720
const OUT_DIR: String = "user://terrain_texture"

## The seed the rest of the terrain work is measured on (`tools/terrain_normal_check.gd`,
## `tools/spawn_ground_check.gd`), so the renders here can be compared against theirs.
const SEED: int = 20260819
## Mid-morning: the sun is well clear of the horizon, the grade is not doing anything dramatic, and
## the ground is lit rather than raking — which is the light a flat ground colour hides best in.
const HOUR: float = 9.5
const EYE_M: float = 1.7

## The same slope from three distances. Chosen for what they are asked to show, not as a spread:
##   7 m  — facet scale. If the per-facet jitter reads as dithering, it reads as dithering here.
##  30 m — the distance the player actually judges ground at while walking.
##  90 m — a whole hillside in frame, which is the "forty metres of one RGB value" F-399 names.
const DISTANCES: PackedFloat32Array = [7.0, 30.0, 90.0]

## Ground crop the statistics are taken over: the lower-middle band, which is terrain in all three
## shots. Fractions of the frame so it follows WIDTH/HEIGHT.
const CROP: Rect2 = Rect2(0.20, 0.55, 0.60, 0.40)
## Every pixel in the crop for the ground-level stats (~180k samples); every second pixel for the
## much larger ortho overlap.
const ORTHO_STEP: int = 2
## How far a pixel has to move when the ground's albedo is forced to black before it counts as
## terrain (see `_ground_mask`). Lit ground moves 0.15-0.35; canopy and water move by whatever the
## bounced light off the ground was worth, which is far under this.
const GROUND_MASK_DELTA: float = 0.06

## How far apart, in pixels, the "local contrast" statistic compares ground pixels. Three
## separations rather than one, because a facet is tens of pixels across at 7 m and a few at 90 m,
## and a single offset would be measuring a different thing in each shot. All well above one pixel
## and all well below the frame, which is the band the detail field is supposed to occupy.
const CONTRAST_OFFSETS: PackedInt32Array = [4, 16, 48]
## Assertion 1. That local contrast, as a fraction of the ground's mean brightness, must rise — by a
## FRACTION of what the ground already had, with an absolute floor under it. Two conditions for the
## same reason `tools/terrain_normal_check.gd` has them (F-372): the baseline is not a fixed
## quantity. It depends on how much of the frame is in shadow, how far the fog reaches, and how
## rough the terrain currently is, and a bare absolute gate calibrated on today's island is a gate
## that fails on next month's for no reason. The floor is there because the baseline can be very
## nearly zero — at 7 m the pre-F-399 ground is one flat value and there is nothing to take a
## fraction of.
##
## Calibrated at seed 20260819, before -> after:
##      7 m   0.0006 -> 0.0059   (+0.0054, ten times over)
##     30 m   0.0101 -> 0.0129   (+0.0028, +28%)
##     90 m   0.0090 -> 0.0107   (+0.0017, +19%)
## The gates sit at 8% and 0.0005, roughly a third of the tightest observed margin on both.
const MIN_CONTRAST_FRACTION: float = 0.08
const MIN_CONTRAST_FLOOR: float = 0.0005
## Assertion 2. Ceiling on the mean absolute per-pixel change, as a fraction of the ground's own
## brightness. Observed 3% / 8% / 5%; the gate is a little over double the worst.
const MAX_MEAN_DELTA: float = 0.18
## And on how far a whole view's mean ground colour may move. This is NOT expected to be near zero —
## a low-frequency field does not average out over one view, and a hillside coming out 5% darker
## than the flat colour it replaced is the effect working. What it rules out is a repaint or a
## global brightening, which would move the mean far past the field's own amplitude. Observed
## 3% / 7% / 5% against a peak field amplitude of 24%.
const MAX_MEAN_SHIFT: float = 0.15
## Assertion 3. Ceiling on the rise in mean horizontal neighbour difference, same normalisation.
## Observed +0.0004 / +0.0008 / +0.0002 — three to four thousandths of the ground's brightness per
## pixel pair, which is what "no visible high-frequency content was added" looks like as a number.
## A field finer than the facet would multiply this.
const MAX_NEIGHBOUR_GAIN: float = 0.0060
## Assertion 4. The ortho pair's median absolute difference after the shift, in 0..1 units. Not
## zero: the two frames are separate draws of a scene with animated foliage and temporal
## reprojection in the volumetric fog. Observed ~0.004 with the detail on and off alike; a
## view-locked field would put this in the tenths.
const MAX_ANCHOR_MEDIAN: float = 0.030
## And the detail must not make it worse than the control by more than this.
const MAX_ANCHOR_REGRESSION: float = 0.012

## Ortho anchor shot: metres across the frame, and the camera shift between the two frames. The
## shift is a whole number of pixels by construction — 32 m at 1280 px / 64 m = 640 px — which is
## what lets the two be compared by an integer crop instead of a resample.
const ANCHOR_SPAN_M: float = 64.0
const ANCHOR_SHIFT_M: float = 32.0
const ANCHOR_ALTITUDE_M: float = 90.0

var failures: int = 0
var _viewport: SubViewport
var _camera: Camera3D
var _material: ShaderMaterial
var _world: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("terrain_texture_check renders — run it with --windowed")
		# The bail needs the verdict as much as the end does (F-555). Note this path is now
		# UNREACHABLE under `agent verify`: F-556 gave this file the `@verify windowed` marker, so
		# the suite launches it with a framebuffer and it never lands here. The only reader left is
		# a person who ran it headless by hand, and for them `failures=1` beside "run it with
		# --windowed" is exactly right — it says "you ran this wrong" and exits non-zero.
		print("TERRAIN_TEXTURE_CHECK failures=1")
		quit(1)
		return
	await process_frame

	var game_state: Node = root.get_node_or_null(^"GameState")
	check(game_state != null, "GameState autoload exists")
	if game_state == null:
		return finish()
	# The two lines every world-booting check uses: adopt THIS seed rather than let the world draw
	# its own, so the shots are the same ground every run.
	game_state.set(&"run_seed", SEED)
	game_state.set("_seed_ready", true)

	_world = WorldScene.instantiate() as Node3D
	root.add_child(_world)
	current_scene = _world
	for _settle: int in 20:
		await process_frame
	await physics_frame

	var streamer: Node = _world.get(&"streamer") as Node
	check(streamer != null, "the procedural world built a ChunkStreamer")
	if streamer == null:
		return finish()

	_pose_clock()
	_build_viewport()

	# The shipped material, reached through a resident chunk rather than through the streamer's
	# private field: this is the same object every chunk on the island binds, so toggling the
	# uniform on it is toggling it everywhere, and finding it this way also proves the shipped
	# terrain is actually rendering through this shader.
	_material = _find_terrain_material()
	check(_material != null, "resident terrain chunks bind a ShaderMaterial")
	if _material == null:
		return finish()
	var uniforms: Array = []
	for entry: Dictionary in _material.shader.get_shader_uniform_list():
		uniforms.append(String(entry.get("name", "")))
	check(uniforms.has("ground_detail_strength"),
		"terrain_flat.gdshader compiles and exposes ground_detail_strength (uniforms: %s)"
			% ", ".join(uniforms))

	var target: Vector3 = _pick_slope()
	print("SLOPE target=%.1f,%.1f,%.1f (radius %.0f m of %.0f)" % [
		target.x, target.y, target.z, Vector2(target.x, target.z).length(),
		Heightmap.ISLAND_RADIUS])

	var view_dir: Vector3 = _lit_view_direction()
	for distance: float in DISTANCES:
		await _shoot_slope(streamer, target, view_dir, distance)
	await _shoot_anchor(streamer, target)

	# Leave the world as the game ships it, in case anything after this looks at it.
	_material.set_shader_parameter(&"ground_detail_strength", 1.0)
	print("TERRAIN_TEXTURE dir=%s" % ProjectSettings.globalize_path(OUT_DIR))
	finish()


# ── the shots ────────────────────────────────────────────────────────────────────────────────────


## One slope, before and after, plus the three statistics assertions over the ground crop.
func _shoot_slope(
	streamer: Node, target: Vector3, view_dir: Vector3, distance: float
) -> void:
	var label: String = "%dm" % int(distance)
	var eye: Vector3 = target - view_dir * distance
	eye.y = _height(eye.x, eye.z) + EYE_M
	await _stream_around(streamer, [eye, target])
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 72.0
	_camera.global_position = eye
	await process_frame
	_camera.look_at(target, Vector3.UP)

	var before: Image = await _frame(0.0, "slope_%s_before" % label)
	var after: Image = await _frame(1.0, "slope_%s_after" % label)

	var crop := Rect2i(
		int(CROP.position.x * float(WIDTH)), int(CROP.position.y * float(HEIGHT)),
		int(CROP.size.x * float(WIDTH)), int(CROP.size.y * float(HEIGHT)))
	var mask: PackedByteArray = await _ground_mask(before, crop)
	var ground_fraction: float = float(_mask_count(mask)) / float(mask.size())
	var stats_before: Array = _crop_stats(before, crop, mask)
	var stats_after: Array = _crop_stats(after, crop, mask)
	# EVERY statistic is a fraction of the crop's own mean brightness, so none of them can be
	# satisfied — or failed — by the ground merely coming out darker. Ratios also make the three
	# distances comparable to each other and keep the gates meaningful when F-397 re-authors the
	# palette underneath this.
	var mean_before: float = _luma(stats_before[0] as Color)
	var mean_after: float = _luma(stats_after[0] as Color)
	var neighbour_before: float = float(stats_before[1]) / maxf(mean_before, 0.0001)
	var neighbour_after: float = float(stats_after[1]) / maxf(mean_after, 0.0001)
	var contrast_before: float = float(stats_before[2]) / maxf(mean_before, 0.0001)
	var contrast_after: float = float(stats_after[2]) / maxf(mean_after, 0.0001)
	var contrast_gain: float = contrast_after - contrast_before
	var neighbour_gain: float = neighbour_after - neighbour_before
	var mean_shift: float = _channel_distance(
		stats_before[0] as Color, stats_after[0] as Color) / maxf(mean_before, 0.0001)
	var mean_delta: float = _mean_abs_delta(before, after, crop, mask) / maxf(mean_before, 0.0001)

	print("STATS %s ground %.0f%% mean %.3f | contrast %.4f -> %.4f (%+.4f) | "
		% [label, ground_fraction * 100.0, mean_before,
			contrast_before, contrast_after, contrast_gain]
		+ "neighbour %.4f -> %.4f (%+.4f) | mean_delta %.4f | mean_shift %.4f"
		% [neighbour_before, neighbour_after, neighbour_gain, mean_delta, mean_shift])
	check(ground_fraction >= 0.3,
		"%s: the crop is mostly terrain (%.0f%%) — the statistics below are about the ground"
			% [label, ground_fraction * 100.0])

	var contrast_gate: float = maxf(
		MIN_CONTRAST_FLOOR, contrast_before * MIN_CONTRAST_FRACTION)
	check(contrast_gain >= contrast_gate,
		"%s: the ground changes across a footstep now — local contrast %.4f -> %.4f (%+.4f >= %.4f)"
			% [label, contrast_before, contrast_after, contrast_gain, contrast_gate])
	check(mean_delta <= MAX_MEAN_DELTA,
		"%s: and stays subtle — mean |delta| is %.1f%% of the ground's own brightness (<= %.1f%%)"
			% [label, mean_delta * 100.0, MAX_MEAN_DELTA * 100.0])
	check(mean_shift <= MAX_MEAN_SHIFT,
		"%s: the view's mean ground colour moves %.1f%% (<= %.1f%%) — a modulation, not a repaint"
			% [label, mean_shift * 100.0, MAX_MEAN_SHIFT * 100.0])
	check(neighbour_gain <= MAX_NEIGHBOUR_GAIN,
		"%s: no pixel-scale noise added — neighbour difference %+.4f <= %.4f"
			% [label, neighbour_gain, MAX_NEIGHBOUR_GAIN])


## Assertion 4 — the field is anchored to the world, not to the view.
func _shoot_anchor(streamer: Node, target: Vector3) -> void:
	var shift := Vector3(ANCHOR_SHIFT_M, 0.0, 0.0)
	var eye: Vector3 = Vector3(target.x, ANCHOR_ALTITUDE_M, target.z)
	await _stream_around(streamer, [eye, eye + shift])
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# KEEP_HEIGHT is the default and is stated rather than assumed, because the whole comparison
	# below is an exact pixel count derived from it: `size` is the VERTICAL extent in metres, so the
	# scale is HEIGHT / size pixels per metre and the frame is wider than `size` by the aspect ratio.
	# Reading it as the horizontal extent puts the shift 78% out and fails a correct shader.
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.size = ANCHOR_SPAN_M
	_camera.global_position = eye
	await process_frame
	_camera.look_at(eye + Vector3.DOWN * 10.0, Vector3.FORWARD)

	var poses: Dictionary = {}
	for strength: float in [0.0, 1.0]:
		var tag: String = "on" if strength > 0.5 else "off"
		_camera.global_position = eye
		poses["a_" + tag] = await _frame(strength, "anchor_%s_a" % tag)
		_camera.global_position = eye + shift
		poses["b_" + tag] = await _frame(strength, "anchor_%s_b" % tag)
	_camera.global_position = eye

	# The camera moved +X by ANCHOR_SHIFT_M, and looks down -Y with FORWARD as up, so world +X is
	# screen +X: frame B's ground is frame A's shifted LEFT by exactly this many pixels.
	var pixels: int = int(round(ANCHOR_SHIFT_M / ANCHOR_SPAN_M * float(HEIGHT)))
	var control: float = _shifted_median_delta(poses["a_off"], poses["b_off"], pixels)
	var detailed: float = _shifted_median_delta(poses["a_on"], poses["b_on"], pixels)
	print("ANCHOR shift=%d px | median |delta| off %.4f on %.4f" % [pixels, control, detailed])
	check(detailed <= MAX_ANCHOR_MEDIAN,
		"the ground detail is anchored to the world — the same ground from a camera %.0f m away "
			% ANCHOR_SHIFT_M
			+ "matches after the shift (median %.4f <= %.4f)" % [detailed, MAX_ANCHOR_MEDIAN])
	check(detailed - control <= MAX_ANCHOR_REGRESSION,
		"and it is no more view-dependent than the flat ground it replaced (+%.4f <= %.4f)"
			% [detailed - control, MAX_ANCHOR_REGRESSION])


## Renders the current camera pose at [param strength] and writes the PNG. Returns the image.
func _frame(strength: float, shot_name: String) -> Image:
	_material.set_shader_parameter(&"ground_detail_strength", strength)
	# Volumetric fog reprojects temporally and foliage sways, so a frame taken immediately after a
	# camera move is a smear of the previous pose. Thirty frames is what atmosphere_look_shot
	# settled on for the same reason.
	for _frame_index: int in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = _viewport.get_texture().get_image()
	# An unnamed frame is a working frame (the ground mask's black pass) — measured, not kept.
	if shot_name.is_empty():
		return image
	var path: String = "%s/%s.png" % [OUT_DIR, shot_name]
	var error: int = image.save_png(path)
	print("SHOT %s -> %s (%s)" % [shot_name, ProjectSettings.globalize_path(path),
		error_string(error)])
	return image


# ── the world ────────────────────────────────────────────────────────────────────────────────────


## Waits until the streamer has nothing in flight around [param anchors], so a shot is never taken
## of a hole. Capped rather than unbounded: a stall should fail the shot it belongs to, not hang the
## check.
func _stream_around(streamer: Node, anchors: Array) -> void:
	var typed: Array[Vector3] = []
	for anchor: Variant in anchors:
		typed.append(anchor as Vector3)
	streamer.call(&"set_anchors", typed)
	# Both conditions, and held: nothing in flight AND the resident set stopped growing. Ring
	# evaluation only runs every RING_EVAL_INTERVAL_SEC, so "no jobs pending" alone is true in the
	# gap between two rings being requested, and a shot taken there is a shot of the next ring's
	# hole. 45 frames comfortably spans that interval at any frame rate this renders at.
	var settled: int = 0
	var resident: int = -1
	for _frame_index: int in 900:
		await process_frame
		var loaded: int = int(streamer.call(&"loaded_chunk_count"))
		if int(streamer.call(&"pending_job_count")) == 0 and loaded == resident:
			settled += 1
			if settled >= 45:
				return
		else:
			settled = 0
		resident = loaded
	print("  note: streamer still had %d job(s) in flight after 900 frames"
		% int(streamer.call(&"pending_job_count")))


## The clock has to be driven through DayNight, which re-applies the hour every physics tick and
## would otherwise overwrite anything set on the Atmosphere directly (atmosphere_look_shot's own
## first run rendered six identical frames for exactly this reason).
func _pose_clock() -> void:
	var day_night: Node = root.get_node_or_null(^"DayNight")
	if day_night != null:
		day_night.set(&"time_of_day", HOUR / 24.0)
	var atmosphere: Node = _world.get_node_or_null(^"Atmosphere")
	if atmosphere != null and atmosphere.has_method(&"set_time_of_day"):
		atmosphere.call(&"set_time_of_day", HOUR)


func _build_viewport() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(WIDTH, HEIGHT)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.own_world_3d = false
	_viewport.world_3d = _world.get_viewport().world_3d
	root.add_child(_viewport)
	_camera = Camera3D.new()
	_camera.far = 500.0
	_viewport.add_child(_camera)
	_camera.make_current()


func _find_terrain_material() -> ShaderMaterial:
	for node: Node in get_nodes_in_group(&"authored_world_terrain"):
		var mi := node as MeshInstance3D
		if mi != null and mi.material_override is ShaderMaterial:
			return mi.material_override as ShaderMaterial
	return null


func _height(x: float, z: float) -> float:
	return float(_world.call(&"height_at", x, z))


## Looking the way the sunlight travels, so the slope in frame is the lit side of it. A
## DirectionalLight3D shines along its own -Z.
func _lit_view_direction() -> Vector3:
	var sun := _world.get_node_or_null(^"Sun") as DirectionalLight3D
	if sun == null:
		return Vector3(0.0, 0.0, -1.0)
	var flat := Vector3(-sun.global_basis.z.x, 0.0, -sun.global_basis.z.z)
	if flat.length_squared() < 0.0001:
		return Vector3(0.0, 0.0, -1.0)
	return flat.normalized()


## The ground this photographs is FOUND, not hardcoded (F-372's lesson — a coordinate in metres is
## secretly a fraction of an island that keeps moving). Wanted: real relief, well clear of the
## waterline, and dry ground behind it for the far camera to stand on.
func _pick_slope() -> Vector3:
	var view: Vector3 = _lit_view_direction()
	var best: Vector3 = Vector3.ZERO
	var best_score: float = -1.0
	var reach: float = Heightmap.ISLAND_RADIUS * 0.62
	var radius: float = reach * 0.25
	while radius <= reach:
		for step: int in 24:
			var angle: float = float(step) / 24.0 * TAU
			var x: float = cos(angle) * radius
			var z: float = sin(angle) * radius
			var h: float = _height(x, z)
			if h < 3.0:
				continue
			# Every camera has to stand on land, or the "same slope" shots are taken from the sea.
			var standable: bool = true
			for distance: float in DISTANCES:
				var back := Vector3(x, 0.0, z) - view * distance
				if _height(back.x, back.z) < 1.5:
					standable = false
					break
			if not standable:
				continue
			# Relief across the frame, not the local gradient: a slope worth photographing is one
			# that changes height over the tens of metres the camera sees, and a single derivative
			# would happily pick a one-metre bump on flat ground.
			var relief: float = 0.0
			for probe: int in 4:
				var d: float = 12.0 * float(probe + 1)
				relief += absf(_height(x + view.x * d, z + view.z * d) - h)
			if relief > best_score:
				best_score = relief
				best = Vector3(x, h, z)
		radius += reach * 0.15
	if best_score < 0.0:
		# Nothing qualified (an island retuned flatter than this expects): the centre is still
		# ground, and a shot of flat ground still answers "is it one colour".
		best = Vector3(0.0, _height(0.0, 0.0), 0.0)
	return best


# ── measurement ──────────────────────────────────────────────────────────────────────────────────


## Which pixels of [param crop] are TERRAIN, as one byte per pixel.
##
## Found by rendering one extra frame with the shader's global `albedo_color` set to black, which
## takes the ground to nothing while leaving every other surface in the scene — trees, water, sky,
## props — untouched. Whatever changed is ground.
##
## This exists because the first cut of this check measured the whole crop and the numbers were
## meaningless: at 30 m a third of the crop is canopy, foliage and ocean, whose variance is an order
## of magnitude larger than the ground's and completely swamps it — the measured colour spread
## actually went DOWN when the detail was switched on. The obvious alternative, masking on "pixels
## that changed between before and after", is circular: it selects exactly the pixels where the
## effect is strongest and would report a strong effect for any amplitude at all.
func _ground_mask(baseline: Image, crop: Rect2i) -> PackedByteArray:
	_material.set_shader_parameter(&"albedo_color", Color(0, 0, 0))
	var black: Image = await _frame(0.0, "")
	_material.set_shader_parameter(&"albedo_color", Color(1, 1, 1))
	var mask := PackedByteArray()
	mask.resize(crop.size.x * crop.size.y)
	var i: int = 0
	for y: int in range(crop.position.y, crop.end.y):
		for x: int in range(crop.position.x, crop.end.x):
			var a: Color = baseline.get_pixel(x, y)
			var b: Color = black.get_pixel(x, y)
			var delta: float = (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			mask[i] = 1 if delta > GROUND_MASK_DELTA else 0
			i += 1
	return mask


func _mask_count(mask: PackedByteArray) -> int:
	var count: int = 0
	for value: int in mask:
		count += value
	return count


## [mean colour, mean ADJACENT-pixel difference, mean LOCAL contrast] over the terrain pixels of
## [param crop]. Both differences count only pairs where BOTH pixels are terrain, so the mask's own
## boundary — a tree's silhouette against the ground, the highest-contrast edge in the frame —
## cannot be mistaken for structure in the ground.
##
## The two difference statistics are the pair the whole check turns on, and they are deliberately
## the same measurement at two separations:
##
##   * `CONTRAST_OFFSETS` px apart is where the added variation lives. A facet is tens of pixels
##     across at these camera distances and the 17 m field is hundreds, so this is "does the ground
##     change over the space of a footstep".
##   * ONE pixel apart is where dithering would live, and nothing else does — a field at metre scale
##     changes almost nothing between two touching pixels. So the effect is right exactly when the
##     first rises and the second does not.
##
## A standard deviation over the crop was tried first and thrown out: it measures the whole frame's
## brightness range, which is dominated by the lighting gradient from the near ground to the horizon
## and by cast shadows. Switching the detail on darkened one 90 m view by 5%, which compressed that
## gradient, and the measured deviation FELL while the ground visibly gained variation. Normalising
## it by the mean did not save it — the field is low-frequency enough to move different parts of one
## view by different amounts, which is not a scaling and cannot be normalised away. A difference at
## a fixed separation has no such term in it.
func _crop_stats(image: Image, crop: Rect2i, mask: PackedByteArray) -> Array:
	var sum := Vector3.ZERO
	var count: int = 0
	var neighbour: float = 0.0
	var neighbour_pairs: int = 0
	var contrast: float = 0.0
	var contrast_pairs: int = 0
	var width: int = crop.size.x
	var row := PackedColorArray()
	row.resize(width)
	for y: int in range(crop.position.y, crop.end.y):
		var base: int = (y - crop.position.y) * width
		for x: int in width:
			row[x] = image.get_pixel(crop.position.x + x, y)
			if mask[base + x] == 1:
				sum += Vector3(row[x].r, row[x].g, row[x].b)
				count += 1
		for x: int in range(1, width):
			if mask[base + x] == 1 and mask[base + x - 1] == 1:
				neighbour += _channel_distance(row[x], row[x - 1])
				neighbour_pairs += 1
		for offset: int in CONTRAST_OFFSETS:
			for x: int in range(0, width - offset):
				if mask[base + x] == 1 and mask[base + x + offset] == 1:
					contrast += _channel_distance(row[x], row[x + offset])
					contrast_pairs += 1
	if count == 0:
		return [Color(0, 0, 0), 0.0, 0.0]
	var mean: Vector3 = sum / float(count)
	return [
		Color(mean.x, mean.y, mean.z),
		neighbour / float(maxi(neighbour_pairs, 1)),
		contrast / float(maxi(contrast_pairs, 1)),
	]


func _mean_abs_delta(a: Image, b: Image, crop: Rect2i, mask: PackedByteArray) -> float:
	var total: float = 0.0
	var count: int = 0
	var i: int = 0
	for y: int in range(crop.position.y, crop.end.y):
		for x: int in range(crop.position.x, crop.end.x):
			if mask[i] == 1:
				var ca: Color = a.get_pixel(x, y)
				var cb: Color = b.get_pixel(x, y)
				total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
				count += 1
			i += 1
	return total / float(maxi(count, 1))


## Median |delta| between [param a] and [param b] once [param b] is shifted left by
## [param pixels] — i.e. comparing the same world point in both frames. A median rather than a mean
## because a minority of pixels genuinely differ (wind-swayed foliage, temporally reprojected fog)
## and no tolerance on a mean can tell that apart from the failure this is looking for.
func _shifted_median_delta(a: Image, b: Image, pixels: int) -> float:
	var deltas := PackedFloat32Array()
	var y: int = 0
	while y < HEIGHT:
		var x: int = 0
		while x + pixels < WIDTH:
			var ca: Color = a.get_pixel(x + pixels, y)
			var cb: Color = b.get_pixel(x, y)
			deltas.append((absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0)
			x += ORTHO_STEP
		y += ORTHO_STEP
	if deltas.is_empty():
		return 0.0
	deltas.sort()
	return deltas[deltas.size() / 2]


func _channel_distance(a: Color, b: Color) -> float:
	return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0


## Flat channel mean, not a weighted luminance: every statistic here is a per-channel mean absolute
## something, so the normaliser has to be built the same way or the ratios are not comparable.
func _luma(c: Color) -> float:
	return (c.r + c.g + c.b) / 3.0


func check(condition: bool, label: String) -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		failures += 1
		print("  FAIL  %s" % label)


func finish() -> void:
	print("terrain_texture_check: failures=%d" % failures)
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("TERRAIN_TEXTURE_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
