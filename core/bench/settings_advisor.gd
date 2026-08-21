extends RefCounted

## Turns what the benchmark measured into settings the player can apply, and into the one or two
## sentences that say why.
##
## ## The rule this file follows: never recommend from a number measured on another machine (D-193)
##
## docs/PERFORMANCE.md has a table of what every graphics lever costs, and it is tempting to use it
## here — measure once at the current preset, subtract the table's milliseconds, predict the rest.
## Do not. Every row of that table came from the fastest machine in the project (F-174), the file
## says so in bold, and its own paired-versus-serial columns disagree about MEDIUM by 4 ms depending
## on which reference you read it against. A prediction built on it would be a confident number
## about a machine nobody has ever run this on, which is the exact failure F-342 filed.
##
## So the runner MEASURES each candidate instead. It re-samples the single worst scene at each
## preset — about eight seconds per candidate — and this file only ever compares measurements taken
## on the machine in front of the player. That costs a little wall clock and buys a recommendation
## that is evidence rather than arithmetic.
##
## ## What counts as passing
##
## The worst scene's **1% low** must reach the target frame rate. Not the median, and not the
## average across scenes: a build whose median is 90 and whose worst scene stutters to 34 is a
## build that feels bad, and averaging the shore into the night wave hides exactly the scene the
## player would have complained about. This is strict on purpose — it biases every recommendation
## downward, the same way `core/render/hardware_tier.gd` breaks its ties, because a player who
## lands one preset low can raise it in five seconds and a player who lands one preset high blames
## the game.
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row).

const PRESET_LOW: int = 0
const PRESET_MEDIUM: int = 1
const PRESET_HIGH: int = 2
const PRESET_NAMES: PackedStringArray = ["LOW", "MEDIUM", "HIGH"]

## `SettingsService.ANTI_ALIASING_MODES` indices. Duplicated as ints rather than reached through the
## autoload so this class stays pure and callable from a headless check with nothing registered.
const AA_OFF: int = 0
const AA_MSAA_2X: int = 3

## Fraction of the target the chosen preset must beat before the safety net is left off. A preset
## that clears 60 fps by two frames a second will not clear it on a hotter day with a browser open,
## and dynamic resolution exists precisely for that margin.
const COMFORTABLE_MARGIN: float = 1.15

## Below this ratio of 1% low to median frame rate, the frame is not slow, it is *uneven* — the
## smooth stretches are fine and something periodic ruins them. On this game that is nearly always
## the chunk streamer, the nav bake or the Mire tick, all of which are main-thread work that no
## resolution lever touches. Saying so is more useful than recommending a resolution cut that will
## not fix it.
const HITCH_RATIO: float = 0.5

## Frame rates the player can aim at. 30 is the floor a low-end machine can actually hold; anything
## above 144 is for people who already know what they want and will not be running this.
const TARGET_OPTIONS: PackedInt32Array = [30, 60, 90, 120, 144]
const DEFAULT_TARGET_FPS: int = 60


## The recommendation.
##
## `baseline` is the full suite as measured at the player's current settings — an Array of the
## per-scene result dictionaries the runner wrote to its ledger. `calibration` maps a preset int to
## the 1% low fps the WORST baseline scene reached at that preset; the runner fills in only the
## presets it actually sampled, and this function never invents an entry for one it did not.
##
## Returns `{preset, dynamic_resolution, anti_aliasing, fps_cap, headline, reasons, worst_scene,
## worst_low1_fps, verdict}`. `verdict` is one of `&"comfortable"`, `&"tight"`, `&"below_target"`.
static func recommend(
	baseline: Array, calibration: Dictionary, target_fps: int, current_preset: int
) -> Dictionary:
	# Two different scenes answer two different questions. `basis` is the hardest scene a preset can
	# actually change, and the verdict is about it. `worst` is the hardest scene there is, and it is
	# what the hitch diagnostic at the bottom talks about. On this game they are usually not the
	# same scene, because the worst thing in the suite is the chunk streamer and no graphics lever
	# touches it.
	var basis: Dictionary = preset_basis(baseline)
	var worst: Dictionary = worst_scene(baseline)
	if calibration.is_empty():
		# Nothing was measured at any preset, so there is no evidence for a preset either way.
		# Saying "LOW, everything turned down" here would be exactly the predicted-rather-than-
		# measured recommendation this file exists to refuse (D-193) — with the added insult that
		# it would be predicted from nothing at all.
		return _unmeasured(basis, target_fps, current_preset)
	var basis_low1: float = float(basis.get("low1_fps", 0.0))
	var worst_low1: float = float(worst.get("low1_fps", 0.0))
	var worst_median_fps: float = float(worst.get("fps", 0.0))
	var reasons: PackedStringArray = []

	# The highest preset that was MEASURED to clear the target. Walked downward from HIGH so the
	# answer is the best one that passed, never merely the first one tried.
	var chosen: int = -1
	var chosen_fps: float = 0.0
	for preset: int in [PRESET_HIGH, PRESET_MEDIUM, PRESET_LOW]:
		if not calibration.has(preset):
			continue
		var measured: float = float(calibration[preset])
		if measured >= float(target_fps):
			chosen = preset
			chosen_fps = measured
			break

	var verdict: StringName = &"comfortable"
	if chosen < 0:
		# Nothing cleared it. Take the best thing measured and say plainly that it did not reach
		# the target, rather than recommending a preset as though it had.
		chosen = _best_measured(calibration, current_preset)
		chosen_fps = float(calibration.get(chosen, worst_low1))
		verdict = &"below_target"
		reasons.append(
			"No preset held %d fps in %s, which is the hardest scene a graphics setting can "
			% [target_fps, String(basis.get("label", "?"))]
			+ "change — even at LOW it managed %.0f fps." % chosen_fps)
	elif chosen_fps < float(target_fps) * COMFORTABLE_MARGIN:
		verdict = &"tight"

	var recommendation: Dictionary = {
		"preset": chosen,
		"preset_name": PRESET_NAMES[clampi(chosen, PRESET_LOW, PRESET_HIGH)],
		"verdict": verdict,
		"target_fps": target_fps,
		"measured_fps": chosen_fps,
		"worst_scene": String(worst.get("label", "")),
		"worst_scene_id": String(worst.get("id", "")),
		"worst_low1_fps": worst_low1,
		"basis_scene": String(basis.get("label", "")),
		"basis_low1_fps": basis_low1,
		# Defaults: change nothing the measurement did not ask to be changed.
		"dynamic_resolution": false,
		"anti_aliasing": AA_MSAA_2X,
		"fps_cap": 0,
	}

	match verdict:
		&"comfortable":
			reasons.append("%s holds %.0f fps in %s, the most demanding scene a graphics setting "
				% [PRESET_NAMES[chosen], chosen_fps, String(basis.get("label", "?"))]
				+ "can do anything about.")
		&"tight":
			# Clears it, but not by enough to survive a warm laptop or a second application.
			recommendation["dynamic_resolution"] = true
			reasons.append(
				"%s reaches %.0f fps in %s — over %d, but not by much, so dynamic resolution is "
				% [PRESET_NAMES[chosen], chosen_fps, String(basis.get("label", "?")), target_fps]
				+ "switched on to protect the target when the frame gets heavier than this.")
		&"below_target":
			# Every lever that is not already in a preset, because the presets are exhausted.
			recommendation["dynamic_resolution"] = true
			recommendation["anti_aliasing"] = AA_OFF
			reasons.append(
				"Anti-aliasing is off and dynamic resolution is on: no graphics preset touches "
				+ "anti-aliasing, so it is the largest cost left after LOW has done everything "
				+ "it can.")
			if target_fps > 30:
				reasons.append(
					"Consider aiming at 30 fps instead — a steady 30 reads better than an "
					+ "unsteady %d." % target_fps)

	# When the ladder is not a ladder, say so. On a machine with plenty of headroom every preset
	# clears the target and the differences between them fall inside the 1% low's own run-to-run
	# variance, which shows up as a non-monotonic table — LOW slower than HIGH, or MEDIUM slower
	# than both. That does not make the recommendation wrong (the highest preset that cleared the
	# target is still the right answer), but a reader who sees MEDIUM below HIGH and is told
	# nothing will conclude the whole report is junk. It is more honest, and more useful, to say
	# that the presets could not be told apart than to present noise as a measurement.
	if _ladder_is_noisy(calibration):
		reasons.append(
			"The presets measured within noise of each other on this machine — it has enough "
			+ "headroom that the choice barely matters here. Any of them will run; %s is "
			% PRESET_NAMES[chosen] + "recommended because it is the best-looking one that held "
			+ "your target.")

	# The diagnostic that changes what the advice is FOR. An uneven frame is a different problem
	# from a slow one, and the resolution levers do not fix it.
	if worst_low1 > 0.0 and worst_median_fps > 0.0 \
			and worst_low1 < worst_median_fps * HITCH_RATIO:
		reasons.append(
			"%s ran at %.0f fps most of the time but dropped to %.0f in its worst frames. That "
			% [String(worst.get("label", "?")), worst_median_fps, worst_low1]
			+ "gap is hitching rather than a slow frame — it comes from the world being built "
			+ "as you move, and a lower preset will not remove it. A faster disk or fewer "
			+ "background applications will.")

	recommendation["headline"] = _headline(recommendation)
	recommendation["reasons"] = reasons
	return recommendation


## The scene whose 1% low was worst — the one the recommendation is made against. Scenes that
## recorded no frames at all (a run stopped part-way) are skipped rather than counted as zero fps.
## The honest answer when the calibration pass did not run: report what WAS measured, change no
## setting, and say why there is no recommendation. Reached by `tools/benchmark_check.gd`'s short
## run and by any future caller that samples without calibrating.
static func _unmeasured(worst: Dictionary, target_fps: int, current_preset: int) -> Dictionary:
	var preset: int = clampi(current_preset, PRESET_LOW, PRESET_HIGH)
	var worst_low1: float = float(worst.get("low1_fps", 0.0))
	return {
		"preset": preset,
		"preset_name": PRESET_NAMES[preset],
		"verdict": &"unmeasured",
		"target_fps": target_fps,
		"measured_fps": worst_low1,
		"worst_scene": String(worst.get("label", "")),
		"worst_scene_id": String(worst.get("id", "")),
		"worst_low1_fps": worst_low1,
		"dynamic_resolution": false,
		"anti_aliasing": AA_MSAA_2X,
		"fps_cap": 0,
		"headline": "No recommendation — the presets were not compared",
		"reasons": PackedStringArray([
			"%s was the hardest scene at %.0f fps, but no preset was measured against it, so "
			% [String(worst.get("label", "?")), worst_low1]
			+ "there is nothing to recommend. Your settings are unchanged.",
		]),
	}


## The scene a PRESET is chosen against: the worst one whose cost a graphics setting can actually
## move. Scenes flagged `travel` are excluded, because what they measure is the chunk streamer
## building the world as the player runs through it — main-thread work that no resolution, shadow
## or draw-distance lever touches (docs/PERFORMANCE.md §2: the draw-call knobs buy draw calls and
## not milliseconds).
##
## Falls back to the overall worst if every measured scene travels, so a caller that hands this a
## traversal-only suite still gets an answer rather than an empty dictionary.
## True when the measured presets do not form a ladder — a lower preset measuring slower than a
## higher one, which cannot be a real effect and means the differences are inside the noise.
static func _ladder_is_noisy(calibration: Dictionary) -> bool:
	var previous: float = -1.0
	for preset: int in [PRESET_HIGH, PRESET_MEDIUM, PRESET_LOW]:
		if not calibration.has(preset):
			continue
		var measured: float = float(calibration[preset])
		# Walking from HIGH down, each step should be at least as fast as the one above it.
		if previous >= 0.0 and measured < previous:
			return true
		previous = measured
	return false


static func preset_basis(results: Array) -> Dictionary:
	var basis: Dictionary = {}
	for entry: Dictionary in results:
		if int(entry.get("frames", 0)) <= 0 or bool(entry.get("travel", false)):
			continue
		if basis.is_empty() or float(entry.get("low1_fps", 0.0)) < float(basis.get("low1_fps", 0.0)):
			basis = entry
	return basis if not basis.is_empty() else worst_scene(results)


static func worst_scene(results: Array) -> Dictionary:
	var worst: Dictionary = {}
	for entry: Dictionary in results:
		if int(entry.get("frames", 0)) <= 0:
			continue
		if worst.is_empty() or float(entry.get("low1_fps", 0.0)) < float(worst.get("low1_fps", 0.0)):
			worst = entry
	return worst


## Every measured scene's 1% low, sorted worst first — the results table the screen renders and the
## thing worth reading even when the recommendation is obvious.
static func ranked(results: Array) -> Array:
	var measured: Array = []
	for entry: Dictionary in results:
		if int(entry.get("frames", 0)) > 0:
			measured.append(entry)
	measured.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("low1_fps", 0.0)) < float(b.get("low1_fps", 0.0)))
	return measured


## Falls back to the best preset that WAS measured when none of them cleared the target. Prefers
## the lowest preset present, because the reason we are here is that nothing was fast enough.
static func _best_measured(calibration: Dictionary, current_preset: int) -> int:
	for preset: int in [PRESET_LOW, PRESET_MEDIUM, PRESET_HIGH]:
		if calibration.has(preset):
			return preset
	return current_preset


static func _headline(recommendation: Dictionary) -> String:
	var preset_name: String = String(recommendation["preset_name"])
	match StringName(recommendation["verdict"]):
		&"comfortable":
			return "%s — comfortably above %d fps" % [preset_name, int(recommendation["target_fps"])]
		&"tight":
			return "%s, with dynamic resolution on" % preset_name
		_:
			return "%s, everything turned down" % preset_name
