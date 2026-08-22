extends SceneTree

## @verify windowed — this check photographs the ground, and a capture needs a framebuffer, so
## `agent verify` must launch it with a framebuffer instead of the `--headless` it injects by
## default (F-556).

## F-435 — the Mire is visible on the ground now, and this both PROVES it and PHOTOGRAPHS it.
##
##   .agent/bin/agent godot --windowed --script tools/blight_ground_check.gd
##
## Windowed, always: it renders. Same shape as `tools/terrain_texture_check.gd` — a SubViewport of
## its own size sharing the booted world's `World3D`, so the 64x64 window the wrapper forces (F-077)
## is irrelevant and only the renderer has to be real.
##
## The finding is a LOOK complaint ("the tainted ground that starts damaging you has no indication
## that it's different"), so the only honest gate is pixels. Every frame here is taken from the
## identical camera over the identical ground; the four differ in exactly two uniforms —
## `blight_strength` on the terrain shader and on the fog shader — which is what lets the two halves
## of the fix be measured separately and blamed separately.
##
## Six assertions, in the order they would catch a regression:
##
##   1. **FIELD** — `MireGrid.corruption_field_texture()` carries the simulation. A cell set to 1.0
##      reads back as 1.0 at the pixel the SHADER'S OWN UV FORMULA lands on, recomputed here in
##      GDScript rather than assumed. This is the assertion that catches a flipped V or a half-texel
##      slip, which every other assertion below would pass while the purple sat metres off the
##      ground that actually hurts you.
##   2. **PURPLE** — over the corrupted patch, ground pixels move toward purple: blue rises relative
##      to green by a real margin. Stated as `B - G` and not as a hue angle because the ground's
##      base is a green-yellow, so `B - G` starts firmly negative and the sign of the change is
##      unambiguous.
##   3. **DARKER** — and the ground loses brightness rather than gaining it. A tint that brightened
##      would read as a highlight, which is the wrong signal entirely for ground that drains you.
##   4. **LOCAL** — clean ground 90 m away is untouched by the same toggle. This is what separates
##      "the Mire is visible" from "someone tinted the whole island purple", and it is the assertion
##      a global-uniform implementation fails.
##   5. **SOUR FOG** — with the terrain half switched OFF and the fog half on, the same view gains
##      yellow-green: `(R + G) / 2 - B` rises. Isolating it this way is the point — the purple
##      ground would otherwise satisfy any test of "something changed" all by itself.
##   6. **CLEAN GROUND IS UNCHANGED** — with BOTH halves at their shipped strength, the frame over
##      clean ground matches the frame with both off. The shader's `hint_default_black` is what is
##      really under test: a world with no Mire in it must render exactly as it did before F-435.
##
## The `both` frames are also the ones worth looking at, and they are written out for exactly that.
##
## Authority (docs/ARCHITECTURE.md §2.2): none. It boots a world for its renderer, drives no
## session, and mutates the corruption grid through `MireGrid.host_set_corruption_at()` — the
## host-only test seam that file already documents for this purpose.

const WorldScene := preload("res://levels/procedural_island.tscn")
const Heightmap := preload("res://world/gen/island_heightmap.gd")
const SIM := preload("res://world/mire/mire_grid_sim.gd")

const WIDTH: int = 1280
const HEIGHT: int = 720
const OUT_DIR: String = "user://blight_ground"

## The seed the rest of the terrain work is measured on, so these shots sit beside
## `tools/terrain_texture_check.gd`'s.
const SEED: int = 20260819
## Mid-morning, same reason that check gives: the ground is lit rather than raking, which is the
## light a colour shift hides best in.
const HOUR: float = 9.5
const EYE_M: float = 1.7

## The painted patch. Radius is deliberately larger than the camera's crop covers, so the crop is
## entirely inside the saturated core and the measurement is not diluted by the ramp at its edge —
## the edge gets its own frame to be looked at, not to be measured.
const PATCH_RADIUS_M: float = 44.0
## Where the "clean" control ground is taken from, as a distance from the patch centre. Well past
## `PATCH_RADIUS_M` plus the camera's own reach.
const CLEAN_OFFSET_M: float = 150.0
## Camera distance for the measured views. 22 m is the range a player judges ground they are walking
## toward at; 70 m is "can I see it coming from across the clearing", which is the whole point of
## the finding.
const NEAR_M: float = 22.0
const FAR_M: float = 70.0

## Ground crop the statistics are taken over. NOT a fixed band of the frame: the first cut used the
## lower-middle third, which is the foreground at every distance, and at 70 m the foreground is the
## CLEAN ground the camera is standing on — the patch was up near the horizon and the far view
## measured a change of +0.013 on ground that had none. The crop is placed around where the aim
## point actually projects instead, as a fraction of the frame's height, so both distances measure
## the same ground.
const CROP_HALF_W: float = 0.22
const CROP_HALF_H: float = 0.10
## How far a pixel has to move when the ground's albedo is forced to black before it counts as
## terrain — same mask trick, and the same calibration, as `terrain_texture_check`.
const GROUND_MASK_DELTA: float = 0.06

## Assertion 2. How far `B - G` must rise over the patch, in 0..1 colour units. Calibrated at seed
## 20260819: the lit forest floor sits near -0.11 and the blighted one near +0.02, a swing of ~0.13.
## The gate is a third of that, which leaves room for F-397's palette work to move the base without
## failing a working shader.
const MIN_PURPLE_GAIN: float = 0.040
## Assertion 3. The ground must lose at least this fraction of its mean brightness. One gate for
## both distances, set by the harder of the two: at 70 m the Environment's aerial perspective has
## already lifted the ground toward the sky colour, so the same shader loses ~2.5% there against
## ~16% at 22 m. Gating on the near view alone would be the easier test and would say nothing about
## the distance the finding is actually about.
##
## Low on purpose, and it is the WEAK half of the pair deliberately: `BLIGHT_TINT`'s blue multiplier
## is above 1, so the tint lifts blue while pulling red and green down hard. That is what makes the
## result violet instead of a neutral purple-grey, and it necessarily costs some of the darkening.
## Assertion 2 is what says the effect is there; this one only rules out the tint reading as a
## highlight.
const MIN_DARKENING: float = 0.015
## Assertion 4/6. Floor under what "untouched" means for the control ground, as a mean per-channel
## difference. Never zero: volumetric fog reprojects temporally and the foliage sways, so two draws
## of the same pose never match. The real gate is this OR one and a half times the pose's own
## measured noise floor, whichever is larger — see `_shoot()`.
const MAX_CONTROL_DELTA: float = 0.015
## Assertion 5. How far `(R + G) / 2 - B` must rise from the fog alone.
const MIN_SOUR_GAIN: float = 0.006

var failures: int = 0
var _viewport: SubViewport
var _camera: Camera3D
var _world: Node3D
var _terrain: ShaderMaterial
var _fog: ShaderMaterial
var _fog_volume: FogVolume


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("blight_ground_check renders — run it with --windowed")
		# The bail needs the verdict as much as the end does. This check requires a framebuffer and
		# `agent verify` launches everything headless (F-556), so in the suite it only ever reaches
		# here — and without the line the row reads as "reported nothing" rather than as the honest
		# "could not run in this environment" that it is (F-555).
		print("BLIGHT_GROUND_CHECK failures=1")
		quit(1)
		return
	await process_frame

	var game_state: Node = root.get_node_or_null(^"GameState")
	check(game_state != null, "GameState autoload exists")
	if game_state == null:
		return finish()
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
	var mire_grid: Node = root.get_node_or_null(^"MireGrid")
	check(mire_grid != null, "MireGrid autoload exists")
	if streamer == null or mire_grid == null:
		return finish()

	# `ProceduralWorld._physics_process()` rewrites the streamer's anchors to the LOCAL PLAYER's
	# position every physics tick. This check points its camera at ground the player is not standing
	# on, so left running it walks `_stream_around()`'s anchors straight back to the spawn and the
	# far site never streams — the first run of this control photographed open ocean, because the
	# chunks that should have been under the camera had never been built. Nothing else this check
	# needs comes from that loop.
	_world.set_physics_process(false)
	_pose_clock()
	_build_viewport()

	_terrain = _find_terrain_material()
	check(_terrain != null, "resident terrain chunks bind a ShaderMaterial")
	_fog = _find_fog_material()
	check(_fog != null, "the level's GroundFog binds a ShaderMaterial")
	if _terrain == null or _fog == null:
		return finish()
	check(_has_uniform(_terrain, "mire_field") and _has_uniform(_terrain, "blight_strength"),
		"terrain_flat.gdshader compiles and exposes mire_field / blight_strength")
	check(_has_uniform(_fog, "mire_field") and _has_uniform(_fog, "blight_strength"),
		"ground_fog.gdshader compiles and exposes mire_field / blight_strength")
	check(_terrain.get_shader_parameter(&"mire_field") != null,
		"ChunkStreamer bound the live corruption field to the terrain material")
	check(_fog.get_shader_parameter(&"mire_field") != null,
		"GroundFog bound the live corruption field to the fog material")
	# The blight fog hangs off this map, not off `base_height` — without it the whole layer sits at
	# the waterline datum and never reaches the ground the Mire is actually on.
	check(float(_fog.get_shader_parameter(&"terrain_field_ready")) > 0.5,
		"GroundFog built its coarse terrain height map (half extent %.1f m)"
			% float(_fog.get_shader_parameter(&"terrain_field_half_extent")))

	var target: Vector3 = _pick_ground(Vector2.ZERO)
	var clean: Vector3 = _pick_ground(Vector2(target.x, target.z).normalized() * -CLEAN_OFFSET_M)
	print("PATCH centre=%.1f,%.1f  clean=%.1f,%.1f  (island radius %.0f m)"
		% [target.x, target.z, clean.x, clean.z, Heightmap.ISLAND_RADIUS])

	_paint_patch(mire_grid, target)
	await _await_field_upload()
	_assert_field(mire_grid, target, clean)

	var view: Vector3 = _lit_view_direction()
	await _shoot(streamer, target, view, NEAR_M, "patch_near", true)
	await _shoot(streamer, target, view, FAR_M, "patch_far", true)
	await _shoot(streamer, clean, view, NEAR_M, "clean_near", false)

	# Leave the world as the game ships it.
	_set_terrain_parameter(&"blight_strength", 1.0)
	_fog.set_shader_parameter(&"blight_strength", 1.0)
	print("BLIGHT_GROUND dir=%s" % ProjectSettings.globalize_path(OUT_DIR))
	finish()


# ── the field ────────────────────────────────────────────────────────────────────────────────────


## Paints a saturated disc through the host-only test seam, then stops the simulation so the field
## the frames are taken through is the field this function set. `_tick()` would otherwise diffuse
## the disc between the first shot and the last, and every gate below would be measured against a
## slightly different patch than the one it was calibrated on.
func _paint_patch(mire_grid: Node, centre: Vector3) -> void:
	mire_grid.set_physics_process(false)
	# Zeroed first. `MireGrid.ensure_ready()` seeds four corrupted clusters from the run seed, and on
	# an island this size one of them can easily land under the control camera — which would make
	# assertion 4 fail for a completely correct shader, and make the far view's numbers a mixture of
	# this check's patch and whatever the seed happened to put there. The Mire this check photographs
	# is the one it painted, and nothing else.
	for cell_z: int in SIM.CELLS_PER_SIDE:
		for cell_x: int in SIM.CELLS_PER_SIDE:
			var cell: Vector2 = SIM.cell_to_world_center(cell_x, cell_z)
			mire_grid.call(&"host_set_corruption_at", Vector3(cell.x, 0.0, cell.y), 0.0)
	var span: int = int(ceil(PATCH_RADIUS_M / SIM.CELL_SIZE_M))
	var centre_cell: Vector2i = SIM.world_to_cell(centre.x, centre.z)
	for delta_z: int in range(-span, span + 1):
		for delta_x: int in range(-span, span + 1):
			var cell_x: int = centre_cell.x + delta_x
			var cell_z: int = centre_cell.y + delta_z
			if cell_x < 0 or cell_x >= SIM.CELLS_PER_SIDE:
				continue
			if cell_z < 0 or cell_z >= SIM.CELLS_PER_SIDE:
				continue
			var world: Vector2 = SIM.cell_to_world_center(cell_x, cell_z)
			var distance: float = world.distance_to(Vector2(centre.x, centre.z))
			if distance > PATCH_RADIUS_M:
				continue
			# Saturated for the inner two thirds, ramped over the last third — a hard-edged disc
			# would photograph a step that the real spreading Mire never produces.
			var value: float = clampf((PATCH_RADIUS_M - distance) / (PATCH_RADIUS_M / 3.0), 0.0, 1.0)
			mire_grid.call(&"host_set_corruption_at", Vector3(world.x, 0.0, world.y), value)


## `MireGrid._process()` uploads at most every FIELD_REFRESH_SEC and only when the field is dirty,
## so the texture is not current the frame after painting. Waits for real time to pass rather than
## for a fixed frame count, because the two are not the same thing at an unknown frame rate.
func _await_field_upload() -> void:
	var deadline: int = Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline:
		await process_frame
	await RenderingServer.frame_post_draw


## Assertion 1. Reads the published texture back and compares it to the grid at two positions, at
## the pixel THE SHADER would sample — `(world.xz + half) / (2 * half)`, scaled by the texture size
## and floored, which is the UV-to-texel rule a `filter_linear` sampler follows at texel centres.
## Recomputed here instead of calling `SIM.world_to_cell()` on purpose: the two agreeing is the
## thing being tested, and using one to test the other proves nothing.
func _assert_field(mire_grid: Node, hot: Vector3, cold: Vector3) -> void:
	var texture: Texture2D = mire_grid.call(&"corruption_field_texture") as Texture2D
	check(texture != null, "MireGrid publishes a corruption field texture")
	if texture == null:
		return
	var half: float = float(mire_grid.call(&"corruption_field_half_extent"))
	check(is_equal_approx(half, Heightmap.ISLAND_RADIUS),
		"the field's half extent (%.1f m) is the island's own radius (%.1f m)"
			% [half, Heightmap.ISLAND_RADIUS])
	var image: Image = texture.get_image()
	check(image != null and image.get_width() == SIM.CELLS_PER_SIDE,
		"the field is %d x %d, one texel per simulation cell"
			% [image.get_width() if image != null else -1,
				image.get_height() if image != null else -1])
	if image == null:
		return

	var hot_value: float = _sample_field(image, half, hot)
	var cold_value: float = _sample_field(image, half, cold)
	var hot_sim: float = float(mire_grid.call(&"corruption_at", hot))
	print("FIELD hot texel=%.3f sim=%.3f | cold texel=%.3f" % [hot_value, hot_sim, cold_value])
	check(absf(hot_value - hot_sim) <= 0.02,
		"the texel the shader samples at the patch centre carries the simulation's own value "
			+ "(%.3f vs %.3f)" % [hot_value, hot_sim])
	check(hot_value >= 0.9,
		"and that value is the saturated corruption this check painted (%.3f >= 0.9)" % hot_value)
	check(cold_value <= 0.02,
		"ground %.0f m away reads clean (%.3f <= 0.02) — the field is not smeared across the island"
			% [CLEAN_OFFSET_M, cold_value])


func _sample_field(image: Image, half: float, world: Vector3) -> float:
	var u: float = (world.x + half) / maxf(half * 2.0, 0.001)
	var v: float = (world.z + half) / maxf(half * 2.0, 0.001)
	var x: int = clampi(int(floor(u * float(image.get_width()))), 0, image.get_width() - 1)
	var y: int = clampi(int(floor(v * float(image.get_height()))), 0, image.get_height() - 1)
	return image.get_pixel(x, y).r


# ── the shots ────────────────────────────────────────────────────────────────────────────────────


## One view, four frames, and whichever assertions apply to the ground it is looking at.
func _shoot(
	streamer: Node, target: Vector3, view_dir: Vector3, distance: float,
	label: String, corrupted: bool
) -> void:
	# The pose is CHOSEN, not assumed: several bearings onto the same ground are tried and the first
	# one whose crop actually shows ground is kept (F-447).
	#
	# `_pick_ground()` guarantees dry, standable ground — it says nothing about what is growing on
	# it, and the camera stands 22 or 70 m back from the aim point on whatever bearing the sun
	# happens to give. When the island's shape changed, the control site's near camera came down
	# INSIDE A TREE TRUNK: every pixel of the frame was bark, the ground mask was empty, and the
	# check reported "0 of 45504 px" terrain — a true statement about a photograph of the inside of
	# a tree, and a useless one about the shader under test. Its own saved PNG showed it instantly
	# and no assertion could.
	#
	# Rotating the bearing is the right retry because nothing this check measures depends on which
	# way the camera faces: every frame in a shot is taken from ONE pose and compared against the
	# others from that same pose. Yaw is stepped in both directions from the lit bearing so the
	# accepted pose stays as close to it as the trees allow.
	var yaw_steps: Array[float] = [0.0, 0.5, -0.5, 1.0, -1.0, 1.6, -1.6, 2.4]
	var off: Image
	var crop: Rect2i
	var mask := PackedByteArray()
	var ground_fraction: float = 0.0
	var eye: Vector3 = Vector3.ZERO
	for yaw: float in yaw_steps:
		var bearing: Vector3 = view_dir.rotated(Vector3.UP, yaw)
		eye = target - bearing * distance
		eye.y = _height(eye.x, eye.z) + EYE_M
		await _stream_around(streamer, [eye, target])
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		_camera.fov = 72.0
		_camera.global_position = eye
		await process_frame
		_camera.look_at(target, Vector3.UP)
		# `GroundFog._process()` slides its evaluation window onto `get_viewport().get_camera_3d()` —
		# the MAIN viewport's camera, which is correct in the shipped game and null here, because
		# this check renders through a SubViewport of its own. Without this the FogVolume sits at
		# the world origin and every fog frame below is a photograph of no fog at all, which is
		# exactly how the first run of this check read. Only XZ, matching what that method does.
		if _fog_volume != null and _fog_volume.has_method(&"place_window"):
			_fog_volume.call(&"place_window", eye)

		off = await _frame(0.0, 0.0, "%s_off" % label)
		crop = _crop_around(target)
		mask = await _ground_mask(off, crop)
		ground_fraction = float(_mask_count(mask)) / float(mask.size())
		if ground_fraction >= 0.3:
			break
		print("  info  %s: %.0f%% ground at yaw %+.2f rad — turning and retrying"
			% [label, ground_fraction * 100.0, yaw])

	var ground_only: Image = await _frame(1.0, 0.0, "%s_ground" % label)
	var fog_only: Image = await _frame(0.0, 1.0, "%s_fog" % label)
	var both: Image = await _frame(1.0, 1.0, "%s_both" % label)

	print("CROP %s = %s" % [label, crop])
	check(ground_fraction >= 0.3,
		"%s: the crop is mostly terrain (%d of %d px)"
			% [label, _mask_count(mask), mask.size()])

	var mean_off: Color = _crop_mean(off, crop, mask)
	var mean_ground: Color = _crop_mean(ground_only, crop, mask)
	var mean_fog: Color = _crop_mean(fog_only, crop, mask)
	var purple_off: float = mean_off.b - mean_off.g
	var purple_on: float = mean_ground.b - mean_ground.g
	var sour_off: float = (mean_off.r + mean_off.g) * 0.5 - mean_off.b
	var sour_on: float = (mean_fog.r + mean_fog.g) * 0.5 - mean_fog.b
	var luma_off: float = _luma(mean_off)
	var luma_on: float = _luma(mean_ground)
	print("STATS %s ground %.0f%% | B-G %+.4f -> %+.4f (%+.4f) | sour %+.4f -> %+.4f (%+.4f) | "
		% [label, ground_fraction * 100.0, purple_off, purple_on, purple_on - purple_off,
			sour_off, sour_on, sour_on - sour_off]
		+ "luma %.4f -> %.4f (%+.1f%%)"
		% [luma_off, luma_on, (luma_on / maxf(luma_off, 0.0001) - 1.0) * 100.0])

	if corrupted:
		check(purple_on - purple_off >= MIN_PURPLE_GAIN,
			"%s: corrupted ground reads purple — B-G rises %+.4f (>= %.4f)"
				% [label, purple_on - purple_off, MIN_PURPLE_GAIN])
		check(luma_on <= luma_off * (1.0 - MIN_DARKENING),
			"%s: and darker, not brighter — %.4f -> %.4f (>= %.0f%% down)"
				% [label, luma_off, luma_on, MIN_DARKENING * 100.0])
		check(sour_on - sour_off >= MIN_SOUR_GAIN,
			"%s: the fog over it goes yellow-green on its own — (R+G)/2-B rises %+.4f (>= %.4f)"
				% [label, sour_on - sour_off, MIN_SOUR_GAIN])
	else:
		# The gate is calibrated against THIS pose's own noise floor, not against a constant alone.
		# Two draws of an identical frame never match here — the foliage sways and the volumetric
		# fog reprojects temporally — and that floor moves with how much canopy is in shot. A fixed
		# 0.015 failed a shader whose measured colour change was 0.0000 on every channel, which is a
		# gate testing the wind rather than the effect.
		var repeat: Image = await _frame(0.0, 0.0, "")
		var floor_delta: float = _mean_abs_delta(off, repeat, crop, mask)
		var delta: float = _mean_abs_delta(off, both, crop, mask)
		var gate: float = maxf(MAX_CONTROL_DELTA, floor_delta * 1.5)
		print("  CONTROL %s mean |delta| off->both %.4f | noise floor %.4f | gate %.4f"
			% [label, delta, floor_delta, gate])
		check(delta <= gate,
			"%s: clean ground renders exactly as it did before F-435 (%.4f <= %.4f)"
				% [label, delta, gate])


## Renders the current camera pose with the two halves at the given strengths and writes the PNG.
func _frame(ground_strength: float, fog_strength: float, shot_name: String) -> Image:
	_set_terrain_parameter(&"blight_strength", ground_strength)
	_fog.set_shader_parameter(&"blight_strength", fog_strength)
	# Volumetric fog reprojects temporally and foliage sways, so a frame taken immediately after a
	# change is a smear of the previous one. Thirty frames is what the other look checks settled on.
	for _frame_index: int in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = _viewport.get_texture().get_image()
	if shot_name.is_empty():
		return image
	var path: String = "%s/%s.png" % [OUT_DIR, shot_name]
	var error: int = image.save_png(path)
	print("SHOT %s -> %s (%s)"
		% [shot_name, ProjectSettings.globalize_path(path), error_string(error)])
	return image


# ── the world ────────────────────────────────────────────────────────────────────────────────────


func _stream_around(streamer: Node, anchors: Array) -> void:
	var typed: Array[Vector3] = []
	for anchor: Variant in anchors:
		typed.append(anchor as Vector3)
	streamer.call(&"set_anchors", typed)
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


## Reached through a resident chunk rather than the streamer's private field: this is the object
## every chunk on the island binds, so it also proves the shipped terrain renders through it.
func _find_terrain_material() -> ShaderMaterial:
	var found: Array[ShaderMaterial] = _terrain_materials()
	return found[0] if not found.is_empty() else null


## EVERY resident terrain chunk's material, re-scanned on each call (F-447).
##
## Terrain chunks do not share one `ShaderMaterial`: each carries its own `material_override`, so a
## parameter written to the first one found is written to exactly one chunk. That was invisible
## while every shot this check takes happened to include that chunk — and it stopped being
## invisible when the island doubled and the control site moved out of its view. `_ground_mask()`
## blackens the ground to find which pixels are terrain; with only one chunk blackened and that
## chunk offscreen, the mask came back EMPTY and the control shot failed as "0 of 45504 px" terrain
## while its own saved PNG plainly shows grass.
##
## Re-scanned rather than cached because the streamer builds and frees chunks as the camera moves
## between shots, so a list taken at boot goes stale exactly when the camera travels — which is the
## same bug one level up.
func _terrain_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for node: Node in get_nodes_in_group(&"authored_world_terrain"):
		var mi := node as MeshInstance3D
		if mi != null and mi.material_override is ShaderMaterial:
			out.append(mi.material_override as ShaderMaterial)
	return out


## Write one shader parameter to every resident terrain chunk. See `_terrain_materials()`.
func _set_terrain_parameter(name: StringName, value: Variant) -> void:
	for material: ShaderMaterial in _terrain_materials():
		material.set_shader_parameter(name, value)


func _find_fog_material() -> ShaderMaterial:
	for node: Node in _all_nodes(_world):
		var volume := node as FogVolume
		if volume != null and volume.material is ShaderMaterial:
			_fog_volume = volume
			# `GroundFog._process()` re-centres the evaluation window on
			# `get_viewport().get_camera_3d()` EVERY frame — the main viewport's camera, which in a
			# booted level is the spawned player's, three hundred metres from anywhere this check
			# points its own SubViewport camera. It has to stop driving itself before `place_window()`
			# means anything: the first run of this check placed the window correctly and then
			# watched the node walk it back over the next thirty frames, and photographed no fog at
			# all at twenty-five times the shipped density before that was noticed.
			volume.set_process(false)
			return volume.material as ShaderMaterial
	return null


func _all_nodes(node: Node) -> Array[Node]:
	var found: Array[Node] = [node]
	for child: Node in node.get_children():
		found.append_array(_all_nodes(child))
	return found


func _height(x: float, z: float) -> float:
	return float(_world.call(&"height_at", x, z))


## The level's water surface at the origin, or -INF on a map with none (F-284's duck-typed pair,
## which `world/environment/ground_fog.gd` reads the same way).
func _water_surface() -> float:
	if not _world.has_method(&"water_surface_at"):
		return -INF
	var surface: float = float(_world.call(&"water_surface_at", 0.0, 0.0))
	return surface if is_finite(surface) else -INF


## A DirectionalLight3D shines along its own -Z; looking the way the light travels puts the lit face
## of the ground in frame, which is where a colour shift is hardest to fake.
func _lit_view_direction() -> Vector3:
	var sun := _world.get_node_or_null(^"Sun") as DirectionalLight3D
	if sun == null:
		return Vector3(0.0, 0.0, -1.0)
	var flat := Vector3(-sun.global_basis.z.x, 0.0, -sun.global_basis.z.z)
	if flat.length_squared() < 0.0001:
		return Vector3(0.0, 0.0, -1.0)
	return flat.normalized()


## Dry, walkable ground near [param preferred], FOUND rather than hardcoded — F-372's lesson that a
## coordinate in metres is secretly a fraction of an island that keeps moving. Wanted: well clear of
## the waterline, with dry ground behind it for the far camera to stand on.
func _pick_ground(preferred: Vector2) -> Vector3:
	var view: Vector3 = _lit_view_direction()
	var reach: float = Heightmap.ISLAND_RADIUS * 0.55
	# Ground is DRY ground. `height_at()` answers for the terrain surface, which on this island runs
	# tens of metres below the waterline before the falloff ends, so a bare "height >= 3" accepted a
	# seabed under three metres of ocean — the first run of this check photographed its control from
	# a camera standing in open water, and measured a crop that was 0.1% terrain.
	var water: float = _water_surface()
	var best: Vector3 = Vector3.ZERO
	# Scores below are NEGATIVE distances, so the floor has to be below every possible one.
	var best_score: float = -INF
	for ring: int in 6:
		var radius: float = reach * (0.15 + 0.16 * float(ring))
		for step: int in 24:
			var angle: float = float(step) / 24.0 * TAU
			var x: float = cos(angle) * radius
			var z: float = sin(angle) * radius
			var h: float = _height(x, z)
			if h < water + 3.0:
				continue
			var standable: bool = true
			for distance: float in [NEAR_M, FAR_M]:
				var back := Vector3(x, 0.0, z) - view * distance
				if _height(back.x, back.z) < water + 1.5:
					standable = false
					break
			if not standable:
				continue
			# Closest qualifying ground to where the caller asked for it. The two calls want the
			# same island but a long way apart, and "nearest dry land to this point" is the only
			# criterion that expresses that without either of them being a fixed coordinate.
			var score: float = -Vector2(x, z).distance_to(preferred)
			if score > best_score:
				best_score = score
				best = Vector3(x, h, z)
	if best_score == -INF:
		best = Vector3(0.0, _height(0.0, 0.0), 0.0)
	return best


# ── measurement ──────────────────────────────────────────────────────────────────────────────────


## Which pixels of [param crop] are TERRAIN. Found by rendering one extra frame with the shader's
## global `albedo_color` set to black — which takes the ground to nothing while leaving trees, water
## and sky untouched — exactly as `tools/terrain_texture_check.gd` does, and for the reason its own
## header gives: masking on "pixels that changed" instead would select the pixels where the effect
## is strongest and report a strong effect for any amplitude at all.
##
## Black survives F-435: `ALBEDO` is `mix(base, tainted, blight)` and `tainted` is built from
## `base`, so a black base is black at every corruption value. The mask is the same pixels with the
## Mire on or off.
func _ground_mask(baseline: Image, crop: Rect2i) -> PackedByteArray:
	_set_terrain_parameter(&"albedo_color", Color(0, 0, 0))
	var black: Image = await _frame(0.0, 0.0, "")
	_set_terrain_parameter(&"albedo_color", Color(1, 1, 1))
	var mask := PackedByteArray()
	mask.resize(crop.size.x * crop.size.y)
	var i: int = 0
	for y: int in range(crop.position.y, crop.end.y):
		for x: int in range(crop.position.x, crop.end.x):
			var a: Color = baseline.get_pixel(x, y)
			var b: Color = black.get_pixel(x, y)
			mask[i] = 1 if _channel_distance(a, b) > GROUND_MASK_DELTA else 0
			i += 1
	return mask


func _mask_count(mask: PackedByteArray) -> int:
	var count: int = 0
	for value: int in mask:
		count += value
	return count


## A box around where [param target] projects, clamped inside the frame. Sized in fractions of the
## frame HEIGHT on both axes so it stays the same shape whatever WIDTH/HEIGHT are.
func _crop_around(target: Vector3) -> Rect2i:
	var centre: Vector2 = _camera.unproject_position(target)
	var half_w: int = int(CROP_HALF_W * float(HEIGHT))
	var half_h: int = int(CROP_HALF_H * float(HEIGHT))
	var x: int = clampi(int(centre.x) - half_w, 0, WIDTH - 2 * half_w - 1)
	# BELOW the aim point, not centred on it. Centred, the top half of the box is whatever is behind
	# the target — on a hilltop that is sky, and the first run measured a crop that was 5% terrain.
	# Everything below the aim point is ground running back toward the camera, on every pose here.
	var y: int = clampi(int(centre.y), 0, HEIGHT - 2 * half_h - 1)
	return Rect2i(x, y, half_w * 2, half_h * 2)


func _crop_mean(image: Image, crop: Rect2i, mask: PackedByteArray) -> Color:
	var sum := Vector3.ZERO
	var count: int = 0
	var i: int = 0
	for y: int in range(crop.position.y, crop.end.y):
		for x: int in range(crop.position.x, crop.end.x):
			if mask[i] == 1:
				var c: Color = image.get_pixel(x, y)
				sum += Vector3(c.r, c.g, c.b)
				count += 1
			i += 1
	if count == 0:
		return Color(0, 0, 0)
	var mean: Vector3 = sum / float(count)
	return Color(mean.x, mean.y, mean.z)


func _mean_abs_delta(a: Image, b: Image, crop: Rect2i, mask: PackedByteArray) -> float:
	var total: float = 0.0
	var count: int = 0
	var i: int = 0
	for y: int in range(crop.position.y, crop.end.y):
		for x: int in range(crop.position.x, crop.end.x):
			if mask[i] == 1:
				total += _channel_distance(a.get_pixel(x, y), b.get_pixel(x, y))
				count += 1
			i += 1
	return total / float(maxi(count, 1))


func _channel_distance(a: Color, b: Color) -> float:
	return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0


func _luma(c: Color) -> float:
	return (c.r + c.g + c.b) / 3.0


func _has_uniform(material: ShaderMaterial, name: String) -> bool:
	for entry: Dictionary in material.shader.get_shader_uniform_list():
		if String(entry.get("name", "")) == name:
			return true
	return false


func check(condition: bool, label: String) -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		failures += 1
		print("  FAIL  %s" % label)


func finish() -> void:
	print("blight_ground_check: failures=%d" % failures)
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("BLIGHT_GROUND_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)
