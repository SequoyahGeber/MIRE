extends Node

## Runs the benchmark suite in a world and reports what it measured.
##
## ## What this owns, and what it deliberately does not
##
## It owns staging: putting the player somewhere, making it night, spawning a wave, walking the
## streamer into unbuilt ground, and sampling frames while that happens. It does NOT own the world
## — the caller hands it a level that is already loaded and settled, because the two callers stage
## that differently (the screen loads a pinned benchmark island; `tools/benchmark_check.gd` uses
## whatever the project boots) and neither should have to inherit the other's choice.
##
## ## Why the benchmark never runs inside a real run (D-192)
##
## Two of the nine scenes change the world permanently: crossing into night fires `night_started`
## and the wave it spawns stays in the world afterwards. A benchmark that did that to a run in
## progress would be a benchmark that killed people's characters, and the alternative — a
## "benchmark mode" that suppresses those two scenes — would measure a game without night or
## combat in it, which is most of what MIRE's frame budget is spent on. So the benchmark always
## runs in its own freshly generated world on a pinned seed, and is offered from the front end
## only.
##
## ## The measurement discipline
##
## Every rule docs/PERFORMANCE.md §1 sets out applies here, because a player-facing number that is
## wrong is worse than no number: the seed is pinned so two runs measure the same island; the
## streamer is settled before anything is sampled; `Engine.max_fps` is forced to 0 for the
## duration, because a frame limiter turns every scene into the same number and reads as "nothing
## costs anything"; the first frames after every transition are discarded; and the headline is the
## 1% low.
##
## Unlike `tools/perf_probe.gd` this does NOT pair each sample against an adjacent reference. It
## does not need to: the probe measures the *difference* one toggle makes, where a 1.9 ms run drift
## can swallow the whole effect, and this measures absolute frame rates against a target dozens of
## frames away. Where it does compare — the calibration pass — it re-measures the same scene under
## each candidate back to back, which is the pairing that comparison needs.
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row). Nothing here is
## replicated; the benchmark world is single-player and never opens a session.

const FrameSampler := preload("res://core/bench/frame_sampler.gd")
const BenchmarkSuite := preload("res://core/bench/benchmark_suite.gd")
const BenchmarkReport := preload("res://core/bench/benchmark_report.gd")
const SettingsAdvisor := preload("res://core/bench/settings_advisor.gd")
const MachineProbe := preload("res://core/bench/machine_probe.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")

## The island every benchmark generates. Fixed so that two players comparing numbers, or one player
## comparing before and after a driver update, are looking at the same world — an unpinned seed
## makes every run a different island and every comparison meaningless (docs/PERFORMANCE.md §1,
## rule 5).
##
## CHOSEN, not arbitrary (F-458). `20260821` was a date, picked because a constant was needed, and
## nobody had looked at the island it makes. This one is the winner of a 150-candidate survey —
## `tools/bench_seed_survey.gd`, re-runnable, deterministic — scored on the coverage the suite
## actually depends on. Its row, so the choice is reviewable and can be re-made when worldgen moves:
##
##   seed        score   land  peak  pois  kinds   biome shares (% of land)
##   20260024    0.989    29%   46m    33   8/8    birc 16 fore 13 gras 24 heat 12 high 14
##                                                 mars 7 shor 14
##
## All seven biomes present with the weakest (marsh) at 7.2% of land, evenness 0.97, 33 POI sites
## across all eight kinds, an island of median size with better-than-median high ground for the
## vista scene to stand on. Every destination the suite searches for exists on it, so no scene
## silently substitutes the shore for something the island does not have.
const BENCH_SEED: int = 20260024

## How far out from the island centre destination searches look, and how finely. The island is a
## few hundred metres across; 96 rings of 24 angles is dense enough to find any biome that exists
## on it and cheap enough to run in one frame.
const SEARCH_RADIUS_M: float = 420.0
const SEARCH_RINGS: int = 96
const SEARCH_ANGLES: int = 24

## The lowest ground a scene may be measured from. Below this the camera is at or under the
## waterline, where it renders open water and almost nothing else — a view no scene in the suite is
## supposed to be about.
const MIN_STANDING_HEIGHT_M: float = 0.6

## The calibration pass re-measures the worst scene for this long at each candidate preset. Shorter
## than a full scene because it is one scene rather than nine and the player is already waiting;
## still long enough for a stable tail at 30 fps (~120 frames).
const CALIBRATION_SECONDS: float = 4.0
const CALIBRATION_SETTLE: float = 2.5

## A TRAVELLING scene is calibrated for the full scene length instead of `CALIBRATION_SECONDS`.
## Its 1% low is a hitch rate rather than a steady cost — the streamer produces a few large spikes
## per window and how many land inside a short sample is close to chance — so four seconds of
## traversal cannot separate one preset from another, and the run picked MEDIUM over HIGH on what
## was almost certainly noise. Six seconds is what the suite already decided a traversal sample
## needs to be worth reading.
const TRAVEL_CALIBRATION_SECONDS: float = BenchmarkSuite.SAMPLE_SECONDS

## Least distance the flyover keeps above the ground beneath it, in metres, when the terrain rises
## higher than the nominal altitude.
const FLY_CLEARANCE_M: float = 45.0

## Seconds spent looking at each destination during the warm-up pass. Long enough to render the
## view a few hundred times, which is what forces first-sight work to happen; short enough that
## warming nine destinations costs well under a minute. See `_prewarm()`.
const PREWARM_SECONDS: float = 1.5

## The attunement the benchmark picks for itself when the world starts without one. Fixed rather
## than random for the same reason the seed is: two runs have to measure the same thing. `warden` is
## the first entry in `AttunementUI.ROLE_ORDER`, so it is the one a player mashing accept would get.
const BENCH_ATTUNEMENT: StringName = &"warden"

## Frames to wait, at most, for the streaming world to finish arriving before ANY scene is
## sampled. At 8 chunks of load radius the neighbourhood is 17x17 and the streamer holds itself to
## a 4 ms frame budget, so settling takes real time; a cap that is too tight silently measures a
## half-built world and reports it as a cheap one.
const SETTLE_MAX_FRAMES: int = 900
## Consecutive frames with nothing in flight before the world counts as settled. More than one
## because the streamer evaluates its rings on an interval, so a single quiet frame proves nothing.
const SETTLE_QUIET_FRAMES: int = 30


signal scene_started(index: int, total: int, scene: Dictionary)
signal scene_finished(index: int, total: int, result: Dictionary)
signal phase_changed(message: String)
signal finished(report: Dictionary)
signal failed(message: String)

## Set true from outside to stop after the scene in flight. Everything already measured is on disk
## and the run resumes from there.
var cancelled: bool = false

var _world: Node3D
var _player: Node3D
var _viewport: Viewport
var _viewport_rid: RID
## The ledger and report writer. Public so `tools/benchmark_check.gd` can repoint its paths at a
## scratch directory — a check that overwrote the player's own last benchmark would be a check that
## destroys data every time it runs.
var report_writer: BenchmarkReport = BenchmarkReport.new()
var _saved_max_fps: int = 0
var _saved_settings: Dictionary = {}
var _travel_heading: float = 0.0
var _biome_defs: Array = []
## Whether god mode was already on when the benchmark started, so it can be handed back exactly as
## found. `GodModeService` state is per-peer and lives for the whole session, not for the world —
## leaving it on would put the player into their NEXT real run invulnerable, which is a far worse
## bug than anything the benchmark was protecting them from.
var _god_mode_restore: bool = false
## False if invulnerability could not be established. The combat scene refuses to spawn anything
## when this is false — see `_ensure_invulnerable()`.
var _invulnerable: bool = false
## Where the current scene is anchored. Re-asserted every sampled frame on stationary scenes so
## enemy knockback cannot drag the camera somewhere else mid-measurement.
var _anchor: Vector3 = Vector3.ZERO
## True if the benchmark chose the attunement itself, and must therefore clear it on the way out.
var _chose_attunement: bool = false


## Runs the suite plus the calibration pass. `world` must be a loaded, settled level; the caller is
## responsible for both. Emits progress as it goes and `finished` with the report.
##
## `scenes` overrides which scenes run — empty means the whole suite, which is what the screen
## always passes. `tools/benchmark_check.gd` passes one cheap scene and `calibrate = false`, because
## a check that took three minutes is a check nobody runs; the code path it exercises is otherwise
## identical, which is the point.
func run(world: Node3D, target_fps: int = SettingsAdvisor.DEFAULT_TARGET_FPS,
		resume: bool = true, scene_override: Array[Dictionary] = [],
		calibrate: bool = true) -> void:
	_world = world
	_viewport = get_viewport()
	if _viewport == null:
		failed.emit("no viewport — the benchmark needs a window to measure")
		return
	_viewport_rid = _viewport.get_viewport_rid()
	_target_fps = target_fps
	_player = _find_player(world)
	if _player == null:
		failed.emit("no player body in the benchmark world — nothing to anchor the streamer on")
		return

	_begin_measurement()
	await _ensure_invulnerable()
	await _dismiss_class_picker()
	_biome_defs = _load_biome_defs()

	var machine: Dictionary = MachineProbe.read_hardware()
	# The machine's STATE, read before the first scene and again after the last. A run that starts
	# cool and plugged in and ends throttled did not measure one machine, and the results screen
	# has to be able to say so — see `core/bench/machine_probe.gd`.
	var power_before: Dictionary = MachineProbe.read_power()
	var settings_state: Dictionary = _settings_state()
	var signature: String = BenchmarkReport.signature_for(
		machine, settings_state, _viewport.get_visible_rect().size)
	if not resume:
		report_writer.discard()
	var done: Array = report_writer.begin(signature)
	var completed: Dictionary = {}
	for row: Dictionary in done:
		completed[String(row.get("id", ""))] = row
	if not completed.is_empty():
		phase_changed.emit("resuming — %d scene(s) already measured" % completed.size())

	var scenes: Array[Dictionary] = scene_override if not scene_override.is_empty() \
		else BenchmarkSuite.scenes()
	await _prewarm(scenes)
	var results: Array = []
	for index: int in scenes.size():
		var scene: Dictionary = scenes[index]
		var id: String = String(scene["id"])
		if completed.has(id):
			results.append(completed[id])
			continue
		if cancelled:
			break
		scene_started.emit(index, scenes.size(), scene)
		var result: Dictionary = await _run_scene(scene)
		# On disk BEFORE anything else happens to it. See BenchmarkReport's header — a run stopped
		# here must cost the scene in flight and nothing more.
		report_writer.append_scene(result)
		results.append(result)
		scene_finished.emit(index, scenes.size(), result)

	if cancelled:
		_end_measurement()
		report_writer.close()
		failed.emit("benchmark cancelled — %d of %d scenes measured, and kept"
			% [results.size(), scenes.size()])
		return

	var power_after: Dictionary = MachineProbe.read_power()
	var calibration: Dictionary = {}
	if calibrate:
		calibration = await _calibrate(results, settings_state)
	_end_measurement()
	report_writer.close()

	var recommendation: Dictionary = SettingsAdvisor.recommend(
		results, calibration, target_fps, int(settings_state.get("graphics_preset", 2)))
	# The scene the presets were actually compared on — the basis, not the overall worst. The report
	# labels its calibration rows with this, and mislabelling them would put the traversal scene's
	# name on numbers taken somewhere else entirely.
	var basis: Dictionary = SettingsAdvisor.preset_basis(results)
	var report: Dictionary = {
		"format": BenchmarkReport.FORMAT_VERSION,
		"date": Time.get_datetime_string_from_system(false, true),
		"seed": BENCH_SEED,
		"machine": machine,
		"power_before": power_before,
		"power_after": power_after,
		"power_drift": MachineProbe.drift(power_before, power_after),
		"power_summary": MachineProbe.describe_power(power_before),
		# Everything about the machine's condition that makes the table below less trustworthy:
		# what was already wrong when the player pressed RUN, plus what went wrong during the run.
		"state_notes": _state_notes(power_before, MachineProbe.drift(power_before, power_after)),
		"viewport": "%dx%d" % [_viewport.get_visible_rect().size.x,
			_viewport.get_visible_rect().size.y],
		"settings": settings_state,
		"settings_summary": _settings_summary(settings_state),
		"target_fps": target_fps,
		"scenes": results,
		"calibration": _calibration_for_report(calibration),
		"calibration_scene": String(basis.get("label", "")),
		"recommendation": recommendation,
	}
	report["text_path"] = report_writer.write_report(report)
	finished.emit(report)


## Applies a recommendation through `SettingsService`, which owns every one of these values and
## their persistence. Nothing here writes a setting directly — a benchmark that had its own way of
## setting the preset would be a second place presets are applied from, and the one that is not
## exercised by any other check.
func apply_recommendation(recommendation: Dictionary) -> bool:
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings == null:
		return false
	settings.call(&"set_graphics_preset", int(recommendation.get("preset", 2)))
	settings.call(&"set_anti_aliasing", int(recommendation.get("anti_aliasing", 2)))
	settings.call(&"set_dynamic_resolution", bool(recommendation.get("dynamic_resolution", false)))
	var cap: int = int(recommendation.get("fps_cap", 0))
	if cap > 0:
		settings.call(&"set_fps_cap", cap)
	return true


## Visits every destination once, measuring nothing, before the suite starts.
##
## Waiting on the chunk streamer is not enough to make a location's first sample honest. Measured on
## the 18-scene suite: `Deep forest — day` reported a 22 fps 1% low against a 114 fps median, and
## `Deep forest — NIGHT` — the same trees, the same place, visited later in the same run — reported
## 74. Marshland did the same thing (39 by day, 73 by night). The pattern is first-visit, not
## day-versus-night: whatever it costs to show a kind of ground for the first time, it costs once,
## and the streamer has already reported itself idle by then. Shader and pipeline compilation on
## first sight of an unseen material is the obvious suspect; this does not diagnose it, it just
## refuses to charge it to whichever scene happened to go first.
##
## Which matters especially here, because the suite pairs every location across day and night to
## make that comparison possible (F-458). Without a warm-up the day half systematically eats the
## first-visit cost of every location and the night half never does, so the pairing measures visit
## order rather than lighting — the exact thing it exists to control for.
##
## Warm-up runs in daylight only. The night block is downstream of it and measured clean, and
## flipping the clock back and forth to warm both would cross the day/night thresholds repeatedly,
## firing `night_started`/`day_started` and the wave and refill logic that hang off them.
func _prewarm(scenes: Array[Dictionary]) -> void:
	var seen: Dictionary = {}
	var destinations: Array[Dictionary] = []
	for scene: Dictionary in scenes:
		var where: String = String(scene.get("where", "spawn"))
		if seen.has(where):
			continue
		seen[where] = true
		destinations.append(scene)
	if destinations.is_empty():
		return

	_set_time_of_day(BenchmarkSuite.DAY_TIME_OF_DAY)
	for index: int in destinations.size():
		var scene: Dictionary = destinations[index]
		phase_changed.emit("warming up — %d of %d" % [index + 1, destinations.size()])
		var motion: StringName = StringName(scene.get("motion", BenchmarkSuite.MOTION_STILL))
		_place_player(_resolve_destination(String(scene.get("where", "spawn"))))
		_set_camera_pitch(BenchmarkSuite.FLY_PITCH_DEGREES
			if motion == BenchmarkSuite.MOTION_FLY else 0.0)
		await settle_world(_world, get_tree())
		await _sleep(PREWARM_SECONDS)
		if cancelled:
			return


# ── one scene ─────────────────────────────────────────────────────────────────────────────────


func _run_scene(scene: Dictionary) -> Dictionary:
	var tree: SceneTree = get_tree()
	var destination: Vector3 = _resolve_destination(String(scene.get("where", "spawn")))
	var motion: StringName = StringName(scene.get("motion", BenchmarkSuite.MOTION_STILL))
	_place_player(destination)
	_anchor = destination
	_travel_heading = 0.0
	_set_camera_pitch(BenchmarkSuite.FLY_PITCH_DEGREES
		if motion == BenchmarkSuite.MOTION_FLY else 0.0)

	# Day and night are set explicitly on EVERY scene, not only on the night ones. The suite runs
	# the whole day block and then the whole night block, and a scene that only ever set night
	# would leave the world dark for anything that came after it.
	_set_time_of_day(BenchmarkSuite.NIGHT_TIME_OF_DAY if bool(scene.get("night", false))
		else BenchmarkSuite.DAY_TIME_OF_DAY)
	var enemies: int = int(scene.get("enemies", 0))
	if enemies > 0 and _invulnerable:
		_spawn_enemies(destination, enemies)
	elif enemies > 0:
		push_warning("benchmark: skipping the wave in '%s' — the player is not invulnerable"
			% String(scene["label"]))

	# Settling is not part of the scene's cost: teleporting re-anchors the streamer, and the 17x17
	# neighbourhood it then builds is the cost of ARRIVING somewhere, not of standing there.
	#
	# This waits for the STREAMER, not for a fixed number of seconds. A fixed wait was the first
	# implementation and it was wrong in the flattering-to-nothing direction: `Deep forest`
	# reported a 21 fps 1% low against a 113 fps median while the camera was not moving, because
	# two seconds after a teleport across the island the world was still arriving and every chunk
	# landing inside the sample window went into the tail. That is the same mistake
	# docs/PERFORMANCE.md §1 rule 5 records against the developer instruments, made again here.
	#
	# The traversal scene still measures streaming, and has to: it starts from a settled world and
	# then RUNS, so the chunks it forces arrive inside the window because the player moved, which
	# is the thing a player actually feels.
	await settle_world(_world, tree)
	# Then a short fixed tail for what settling cannot see — shadow atlas re-render, draw-policy
	# state, first-frame shader compiles for whatever this view contains that the last one did not.
	await _sleep(BenchmarkSuite.SETTLE_SECONDS)

	var sampler: FrameSampler = FrameSampler.new()
	var start: int = Time.get_ticks_usec()
	var last: int = start
	while Time.get_ticks_usec() - start < int(BenchmarkSuite.SAMPLE_SECONDS * 1e6):
		await tree.process_frame
		_step_motion(motion)
		var now: int = Time.get_ticks_usec()
		sampler.record(
			float(now - last) / 1000.0,
			RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid),
			RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		last = now
		if cancelled:
			break

	var result: Dictionary = sampler.stats()
	result["id"] = String(scene["id"])
	result["label"] = String(scene["label"])
	result["stresses"] = String(scene["stresses"])
	# Carried into the report because the advisor needs it: a scene whose cost is streaming rather
	# than fill is not a scene a graphics preset can be chosen with. See `SettingsAdvisor`.
	result["travel"] = bool(scene.get("travel", false))
	result["motion"] = String(motion)
	result["position"] = [destination.x, destination.y, destination.z]
	result["night"] = bool(scene.get("night", false))
	# Whatever this scene spawned goes away before the next one starts. Enemies persist and wander,
	# so a wave left in the world would still be in frame — and still be animating and pathing —
	# three scenes later, quietly adding its cost to measurements that are supposed to be about
	# something else.
	if enemies > 0:
		_despawn_enemies()
	return result


## Re-measures the worst scene under each preset that could be an answer, so the recommendation is
## made from numbers taken on THIS machine rather than predicted from a table measured on another
## one (see `settings_advisor.gd`). The player's own preset is included even though the suite
## already measured it, because the suite's number for it came from a differently-settled world.
func _calibrate(results: Array, settings_state: Dictionary) -> Dictionary:
	# NOT the worst scene overall — the worst scene a preset can actually change.
	#
	# The traversal scene is reliably the worst thing in the suite, and its cost is the chunk
	# streamer hitching, which no resolution or shadow lever touches. Calibrating on it produced a
	# recommendation that contradicted its own diagnostic: "MEDIUM holds 73 fps where HIGH managed
	# 17" printed directly above "that gap is hitching, and a lower preset will not remove it".
	#
	# Worse, the comparison was not even measuring the presets. Every calibration pass restarts the
	# traversal from the same place and walks the same spiral, so the FIRST pass streams that
	# ground in and every later pass runs across chunks that are already resident. Whichever preset
	# was measured second won, every time, by a factor of four. That is not noise that a longer
	# sample fixes; it is the samples measuring different worlds.
	#
	# So the preset is chosen against the hardest scene whose cost is fill — and the traversal
	# hitch is reported on its own terms instead, which is the only honest thing to do with a
	# problem that changing settings cannot solve.
	var worst: Dictionary = SettingsAdvisor.preset_basis(results)
	if worst.is_empty():
		return {}
	var scene: Dictionary = BenchmarkSuite.scene_by_id(StringName(worst.get("id", "")))
	if scene.is_empty():
		return {}
	var graphics: Node = get_node_or_null(^"/root/GraphicsQuality")
	if graphics == null:
		return {}

	var calibration: Dictionary = {}
	var original_preset: int = int(settings_state.get("graphics_preset", 2))
	for preset: int in [SettingsAdvisor.PRESET_HIGH, SettingsAdvisor.PRESET_MEDIUM,
			SettingsAdvisor.PRESET_LOW]:
		if cancelled:
			break
		phase_changed.emit("checking %s at %s" % [
			String(scene["label"]), SettingsAdvisor.PRESET_NAMES[preset]])
		graphics.call(&"apply", preset)
		calibration[preset] = await _sample_calibration(scene)
		# Highest first, and stop as soon as one clears comfortably: there is nothing to learn
		# from measuring LOW on a machine that already held HIGH, and every candidate costs the
		# player another seven seconds of black-box waiting.
		if float(calibration[preset]) >= float(_target_hint()) * SettingsAdvisor.COMFORTABLE_MARGIN:
			break
	graphics.call(&"apply", original_preset)
	return calibration


func _sample_calibration(scene: Dictionary) -> float:
	var tree: SceneTree = get_tree()
	var destination: Vector3 = _resolve_destination(String(scene.get("where", "spawn")))
	_place_player(destination)
	_anchor = destination
	_travel_heading = 0.0
	# Same two-part settle as a scene: wait for the world, then for the toggle's own transient. A
	# preset change re-renders the shadow atlas and rebuilds draw-policy state, and that belongs to
	# the toggle rather than to the preset (docs/PERFORMANCE.md §1, rule 3).
	await settle_world(_world, get_tree())
	await _sleep(CALIBRATION_SETTLE)

	var sampler: FrameSampler = FrameSampler.new()
	var motion: StringName = StringName(scene.get("motion", BenchmarkSuite.MOTION_STILL))
	var moving: bool = motion != BenchmarkSuite.MOTION_STILL
	var seconds: float = TRAVEL_CALIBRATION_SECONDS if moving else CALIBRATION_SECONDS
	var start: int = Time.get_ticks_usec()
	var last: int = start
	while Time.get_ticks_usec() - start < int(seconds * 1e6):
		await tree.process_frame
		_step_motion(motion)
		var now: int = Time.get_ticks_usec()
		sampler.record(
			float(now - last) / 1000.0,
			RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid),
			RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		last = now
		if cancelled:
			break
	return float(sampler.stats().get("low1_fps", 0.0))


## The target the calibration pass uses to decide it can stop early. Set by `run()` through
## `_target_fps`; kept behind a method so the early-exit rule has one name in the code.
var _target_fps: int = SettingsAdvisor.DEFAULT_TARGET_FPS


func _target_hint() -> int:
	return _target_fps


# ── staging ───────────────────────────────────────────────────────────────────────────────────


## Where a scene's `where` key points, in world space. Every branch falls back to the spawn point
## rather than failing: a generated island might genuinely have no marsh, and a benchmark that
## refuses to run because one biome did not appear is worse than one that measures the shore twice
## and says which scene it substituted.
func _resolve_destination(where: String) -> Vector3:
	if where.begins_with("biome:"):
		var found: Vector3 = _find_biome(StringName(where.substr(6)))
		return found if found != Vector3.INF else _spawn_position()
	match where:
		"poi":
			return _find_poi()
		"mire":
			return _find_mire()
		"vista":
			return _find_vista()
		"flyover":
			return _flyover_start()
		_:
			return _spawn_position()


func _spawn_position() -> Vector3:
	var spawn: Variant = _world.get(&"spawn_position")
	return spawn if spawn is Vector3 and spawn != Vector3.ZERO else _ground(Vector3.ZERO)


## The nearest standable point whose biome is `id`, searched outward from the island centre so the
## answer is deterministic for a given seed. `Vector3.INF` when the island has none of that biome.
func _find_biome(id: StringName) -> Vector3:
	if _biome_defs.is_empty():
		return Vector3.INF
	var seed_value: int = int(_world.get(&"world_seed"))
	for ring: int in range(1, SEARCH_RINGS + 1):
		var radius: float = SEARCH_RADIUS_M * float(ring) / float(SEARCH_RINGS)
		for step: int in SEARCH_ANGLES:
			var angle: float = TAU * float(step) / float(SEARCH_ANGLES)
			var x: float = cos(angle) * radius
			var z: float = sin(angle) * radius
			if BiomeMap.biome_at(x, z, seed_value, _biome_defs) != id:
				continue
			var height: float = float(_world.call(&"height_at", x, z))
			# Above the waterline and not on a cliff: a camera underwater or inside a slope
			# measures the inside of a mesh, which is not a scene anybody plays.
			if height < MIN_STANDING_HEIGHT_M:
				continue
			return _ground(Vector3(x, height, z))
	return Vector3.INF


## A point just outside the nearest point-of-interest that actually instanced a scene — scenery
## sites with no `scene_path` are the ones with nothing to draw, so they are skipped. Standing a
## few metres back rather than on top of it keeps the buildings in frame instead of clipping the
## near plane through a wall.
func _find_poi() -> Vector3:
	var sites: Variant = _world.get(&"poi_sites")
	if not sites is Array:
		return _spawn_position()
	var spawn: Vector3 = _spawn_position()
	var best: Vector3 = Vector3.INF
	var best_distance: float = INF
	for site: Dictionary in sites as Array:
		if String(site.get("scene_path", "")).is_empty():
			continue
		var position: Vector3 = site.get("position", Vector3.ZERO)
		var distance: float = position.distance_to(spawn)
		if distance < best_distance:
			best_distance = distance
			best = position
	if best == Vector3.INF:
		return spawn
	var offset: Vector3 = (spawn - best).normalized() * 12.0
	return _ground(best + Vector3(offset.x, 0.0, offset.z))


## The middle of the corruption. A run starts with exactly ONE corrupted area (Sequoyah's design
## call — the Mire spreads from one seed, it is never several), so this looks for the strongest
## corruption near the island rather than for "a" corrupted tile. If nothing is corrupted yet —
## a freshly generated world before the first Mire tick — it seeds a patch itself, because
## measuring the corruption shader is the entire point of this scene and a clean world would
## silently measure ordinary ground instead.
func _find_mire() -> Vector3:
	var grid: Node = get_node_or_null(^"/root/MireGrid")
	var fallback: Vector3 = _find_biome(&"marsh")
	if fallback == Vector3.INF:
		fallback = _spawn_position()
	if grid == null:
		return fallback
	var best: Vector3 = Vector3.INF
	var best_value: float = 0.05
	for ring: int in range(1, SEARCH_RINGS + 1):
		var radius: float = SEARCH_RADIUS_M * float(ring) / float(SEARCH_RINGS)
		for step: int in SEARCH_ANGLES:
			var angle: float = TAU * float(step) / float(SEARCH_ANGLES)
			var x: float = cos(angle) * radius
			var z: float = sin(angle) * radius
			# ON LAND, and above the waterline. The corruption field is defined over the whole
			# grid including the sea, and the first version of this search took the strongest
			# reading anywhere — which put the camera offshore looking at open water. It measured
			# 632 draw calls where every other scene measured four to five thousand, and reported
			# that as the cost of standing in the Mire. A scene that measures the wrong place is
			# worse than a missing scene, because it still produces a number.
			if float(_world.call(&"height_at", x, z)) < MIN_STANDING_HEIGHT_M:
				continue
			var value: float = float(grid.call(&"corruption_at", Vector3(x, 0.0, z)))
			if value > best_value:
				best_value = value
				best = Vector3(x, 0.0, z)
	if best != Vector3.INF:
		return _ground(Vector3(best.x, float(_world.call(&"height_at", best.x, best.z)), best.z))
	if grid.has_method(&"host_set_corruption_at"):
		grid.call(&"host_set_corruption_at", fallback, 1.0)
	return fallback


## The highest standable ground the search finds — the long-sightline scene. Height is the whole
## criterion: the point of this scene is that terrain culls nothing.
func _find_vista() -> Vector3:
	var best: Vector3 = _spawn_position()
	var best_height: float = best.y
	for ring: int in range(1, SEARCH_RINGS + 1):
		var radius: float = SEARCH_RADIUS_M * float(ring) / float(SEARCH_RINGS)
		for step: int in SEARCH_ANGLES:
			var angle: float = TAU * float(step) / float(SEARCH_ANGLES)
			var x: float = cos(angle) * radius
			var z: float = sin(angle) * radius
			var height: float = float(_world.call(&"height_at", x, z))
			if height > best_height:
				best_height = height
				best = Vector3(x, height, z)
	return _ground(best)


## Where the flyover begins: upwind of the island centre along the flight axis, at altitude, so the
## sample crosses the middle of the map rather than a corner of it. Deterministic from the constants
## alone — the flight is the same every run on the same seed, which is the whole point of pinning
## one.
func _flyover_start() -> Vector3:
	var half_run: float = BenchmarkSuite.FLY_SPEED * BenchmarkSuite.SAMPLE_SECONDS * 0.5
	return Vector3(-half_run, BenchmarkSuite.FLY_ALTITUDE_M, 0.0)


## Ground-snaps a point through the world's own standing-position logic when it has one, so the
## benchmark stands where a player would rather than inside the terrain or hovering over it.
func _ground(position: Vector3) -> Vector3:
	if _world.has_method(&"standing_position_at"):
		return _world.call(&"standing_position_at", position)
	return position


## Teleports the anchor body and aims it at the island centre, which is where the world is. A
## benchmark that arrives facing out to sea measures an empty horizon and calls it a forest.
func _place_player(position: Vector3) -> void:
	_player.global_position = position
	var to_centre := Vector2(-position.x, -position.z)
	if to_centre.length() > 1.0:
		_player.rotation.y = atan2(-to_centre.x, -to_centre.y)


## Aims the view up or down. Pitch lives on the player's camera pivot, not on the body — the body
## owns yaw (`PlayerCamera._rotate_view()`), so a flyover that only rotated the body would fly over
## the island looking straight at the horizon. Reset to level for every ground scene, because a
## pitch left over from the flyover would have the next scene measuring the sky.
func _set_camera_pitch(degrees: float) -> void:
	var pivot: Node3D = _player.get_node_or_null(^"CameraPivot") as Node3D
	if pivot == null:
		return
	pivot.rotation.x = deg_to_rad(degrees)


## Walks the anchor body outward at sprint speed, turning a little each frame so the path spirals
## rather than leaving the island. Position is written directly rather than driven through the
## controller: the benchmark wants a repeatable path through unstreamed ground, not a physics
## simulation, and the world re-anchors its streamer on whatever the body's position is either way.
func _travel() -> void:
	var delta: float = get_process_delta_time()
	_travel_heading += delta * 0.35
	var step: float = BenchmarkSuite.TRAVEL_SPEED * delta
	var direction := Vector3(cos(_travel_heading), 0.0, sin(_travel_heading))
	var next: Vector3 = _player.global_position + direction * step
	next.y = float(_world.call(&"height_at", next.x, next.z)) + 1.0
	_player.global_position = next
	_player.rotation.y = atan2(-direction.x, -direction.z)


## One frame of whatever this scene's camera is doing.
func _step_motion(motion: StringName) -> void:
	match motion:
		BenchmarkSuite.MOTION_WALK:
			_travel()
		BenchmarkSuite.MOTION_FLY:
			_fly()
		_:
			_hold()


## Crosses the island in a straight line at altitude. Straight rather than a spiral because this
## scene is a map flyover — the player should recognise the island they are about to play on — and
## because a constant heading at 40 m/s walks the streamer's neighbourhood across new ground at a
## steady rate instead of circling back over chunks it just built.
func _fly() -> void:
	var delta: float = get_process_delta_time()
	var next: Vector3 = _player.global_position + Vector3(BenchmarkSuite.FLY_SPEED * delta, 0.0, 0.0)
	# Hold the altitude above the TERRAIN, not above sea level, so the camera keeps its distance
	# from the ground when it passes over the highland rather than skimming it.
	next.y = maxf(BenchmarkSuite.FLY_ALTITUDE_M,
		float(_world.call(&"height_at", next.x, next.z)) + FLY_CLEARANCE_M)
	_player.global_position = next
	_player.rotation.y = -PI * 0.5


## Pins a stationary scene's camera to where the scene said it should be. Without this the combat
## scene measures a moving target: six enemies shoving a character body around is exactly what they
## are built to do, and the view drifting mid-sample makes the numbers unrepeatable between runs.
func _hold() -> void:
	if _anchor != Vector3.ZERO and _player.global_position.distance_to(_anchor) > 0.05:
		_player.global_position = _anchor


func _spawn_enemies(position: Vector3, count: int) -> void:
	var spawner: Node = get_node_or_null(^"/root/WaveSpawner")
	if spawner != null and spawner.has_method(&"host_spawn_wave_at"):
		spawner.call(&"host_spawn_wave_at", position, count)


func _despawn_enemies() -> void:
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world != null and world.has_method(&"host_despawn_all"):
		world.call(&"host_despawn_all")


func _set_time_of_day(fraction: float) -> void:
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night != null:
		day_night.set(&"time_of_day", fraction)


# ── measurement environment ───────────────────────────────────────────────────────────────────


## Everything that has to be true for the numbers to mean anything, set once for the whole run.
func _begin_measurement() -> void:
	_saved_max_fps = Engine.max_fps
	_god_mode_restore = _god_mode_enabled()
	# A frame limiter turns every scene into the same number. `perf_probe` printed 120 fps for all
	# fourteen of its rows on a 120 Hz panel this way and it read as "shadows and fog cost
	# nothing" (docs/PERFORMANCE.md §1, rule 4). A benchmark capped at the refresh rate would
	# recommend HIGH to every machine that can hold vsync, which is the wrong answer for exactly
	# the machines this exists to help.
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)


func _end_measurement() -> void:
	Engine.max_fps = _saved_max_fps
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, false)
	# Hand invulnerability back exactly as it was found, on EVERY exit path — the cancelled one and
	# the failed one included, which is why this lives here rather than at the end of `run()`.
	if _god_mode_enabled() != _god_mode_restore:
		_set_god_mode(_god_mode_restore)
	_restore_class_picker()


## Makes the player unkillable for the duration, through the shipped `GodModeService` rather than
## through anything benchmark-specific.
##
## The benchmark stands still for six seconds in the middle of a wave of six enemies, and stands in
## the Mire's corruption for six more. Both of those kill people — that is their job — and a player
## who dies in the middle of measuring their own machine gets a defeat screen instead of a result,
## with the remaining scenes measured on a corpse. Nothing about the frame cost changes when the
## damage is refused: the enemies still spawn, still animate, still path, still draw.
##
## God mode is the right seam because it already gates all three ways to die that the suite can
## trigger — `host_apply_damage` for the wave, `_tick_blight` for the Mire, `_tick_hunger` for a
## long run — so this needs no new code in `systems/health/player_health.gd` and cannot drift out of
## step with it. `request_local_enabled()` is used rather than `host_set_enabled()` deliberately:
## it is the same front door the settings screen goes through, and the benchmark does not deserve a
## privileged second mutation path any more than the settings screen did.
func _ensure_invulnerable() -> void:
	if _god_mode_enabled():
		_invulnerable = true
		return
	_set_god_mode(true)
	# Solo and host complete synchronously; a frame of slack costs nothing and covers the rest.
	await get_tree().process_frame
	_invulnerable = _god_mode_enabled()
	if not _invulnerable:
		push_warning("benchmark: could not make the player invulnerable — the combat scene will "
			+ "run without enemies rather than risk killing them mid-measurement")


## Gets the class-selection screen off the camera, and keeps it off.
##
## `AttunementUI` opens itself as soon as a local player exists and no attunement has been chosen —
## that is its job, the pick is mandatory (F-216) — and it is a full-screen shaded overlay. Left
## alone it would cover the world for the entire benchmark, so every scene would measure a dark
## rectangle with a menu on it and report the machine as extremely fast.
##
## Closing it once is NOT enough: `_poll_for_local_player()` re-opens it every half second for as
## long as `AttunementService.local_selection()` is empty, so a benchmark that only called
## `_close_picker()` would watch it reappear inside the first scene. The fix is to satisfy the
## condition rather than to fight the symptom — the benchmark CHOOSES an attunement, which is also
## the more honest world to measure: a real player has one, and its passives and VFX are part of
## the frame they see. The picker then never opens at all, and the close below is only a fallback
## for the case where it opened before this ran.
##
## The choice is cleared again in `_end_measurement()` so nothing leaks into the player's next run.
func _dismiss_class_picker() -> void:
	var service: Node = get_node_or_null(^"/root/AttunementService")
	if service != null and String(service.call(&"local_selection")).is_empty():
		service.call(&"request_select", BENCH_ATTUNEMENT)
		_chose_attunement = true
		await get_tree().process_frame

	var picker: Node = get_node_or_null(^"/root/AttunementUI")
	if picker == null:
		return
	if picker.has_method(&"is_open") and bool(picker.call(&"is_open")):
		picker.call(&"_close_picker")
	# Belt and braces: if some future path opens it anyway, it is not allowed to be in front of a
	# measurement. Cheap, and it cannot break a picker that is already closed.
	if picker is CanvasLayer:
		(picker as CanvasLayer).visible = false


func _restore_class_picker() -> void:
	var picker: Node = get_node_or_null(^"/root/AttunementUI")
	if picker is CanvasLayer:
		(picker as CanvasLayer).visible = true
	if not _chose_attunement:
		return
	# The benchmark's own pick must not become the player's. The world it was made in is about to
	# be freed, and the next real run clears selections anyway — this is the belt to that braces.
	var service: Node = get_node_or_null(^"/root/AttunementService")
	if service != null and service.has_method(&"host_clear_all"):
		service.call(&"host_clear_all")
	_chose_attunement = false


func _god_mode_enabled() -> bool:
	var service: Node = get_node_or_null(^"/root/GodModeService")
	return service != null and bool(service.call(&"is_local_enabled"))


func _set_god_mode(enabled: bool) -> void:
	var service: Node = get_node_or_null(^"/root/GodModeService")
	if service != null:
		service.call(&"request_local_enabled", enabled)


func _settings_state() -> Dictionary:
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings == null or not settings.has_method(&"capture_state"):
		return {}
	return settings.call(&"capture_state") as Dictionary


func _settings_summary(state: Dictionary) -> String:
	var preset: int = clampi(int(state.get("graphics_preset", 2)), 0, 2)
	return "preset %s | AA mode %d | dynamic res %s | vsync %s" % [
		SettingsAdvisor.PRESET_NAMES[preset], int(state.get("anti_aliasing", -1)),
		"on" if bool(state.get("dynamic_resolution", false)) else "off",
		"on" if bool(state.get("vsync_enabled", true)) else "off"]


## The condition warnings a reader must see next to the numbers. Kept out of the recommendation's
## own reasons on purpose: a reason explains the advice, and these explain how much to trust it,
## which is a different question and belongs in its own place on the screen.
func _state_notes(power: Dictionary, power_drift: Dictionary) -> PackedStringArray:
	var notes: PackedStringArray = MachineProbe.warnings(power)
	for note: String in power_drift.get("notes", []):
		notes.append(note)
	return notes


## JSON object keys are strings, so the integer preset keys have to be spelled before the report is
## written or a round-trip through `report.json` silently renames them.
func _calibration_for_report(calibration: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for preset: int in calibration.keys():
		out[SettingsAdvisor.PRESET_NAMES[clampi(preset, 0, 2)]] = calibration[preset]
	return out


func _load_biome_defs() -> Array:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return []
	return (registry.get(&"biomes") as Dictionary).values()


func _find_player(node: Node) -> Node3D:
	var direct: Node = node.get_node_or_null(^"Player")
	if direct is Node3D:
		return direct as Node3D
	for child: Node in node.get_children():
		var found: Node3D = _find_player(child)
		if found != null:
			return found
	return null


func _sleep(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Waits until `world`'s chunk streamer has nothing left in flight. Both callers need this before
## the first sample and neither should hand-roll it: measuring a world that is still arriving is
## the mistake F-452 filed against every developer instrument at once, and it produces numbers that
## are wrong in the flattering direction — a third-built island draws a third of the geometry.
##
## Duck-typed on `pending_job_count`/`loaded_chunk_count` rather than a class check, so a level
## with no streamer settles instantly. This is deliberately the same shape as
## `tools/probe_scene.gd`'s `settle()`; that one belongs to the developer instruments and this one
## ships, and neither may import the other's directory.
static func settle_world(world: Node, tree: SceneTree) -> Dictionary:
	var streamer: Node = _find_streamer(world)
	if streamer == null:
		return {"streaming": false, "frames": 0, "chunks": 0, "settled": true}
	var quiet: int = 0
	var frames: int = 0
	while frames < SETTLE_MAX_FRAMES:
		await tree.process_frame
		frames += 1
		if int(streamer.call(&"pending_job_count")) == 0:
			quiet += 1
			if quiet >= SETTLE_QUIET_FRAMES:
				break
		else:
			quiet = 0
	return {
		"streaming": true, "frames": frames,
		"chunks": int(streamer.call(&"loaded_chunk_count")),
		"settled": frames < SETTLE_MAX_FRAMES,
	}


static func _find_streamer(node: Node) -> Node:
	if node.has_method(&"pending_job_count") and node.has_method(&"loaded_chunk_count"):
		return node
	for child: Node in node.get_children():
		var found: Node = _find_streamer(child)
		if found != null:
			return found
	return null
