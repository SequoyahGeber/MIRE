extends SceneTree

## Verifies the in-game benchmark (F-453) — the statistics, the suite's shape, the advisor's
## decisions, the ledger's resume behaviour, and one real sampled scene end to end.
##
##   .agent/bin/agent godot --windowed --script tools/benchmark_check.gd
##
## `--windowed` is required: the live half loads the world and samples frames, and a headless run
## has no framebuffer to measure. Without it the live half is SKIPPED and says so rather than
## passing vacuously.
##
##   ... --script tools/benchmark_check.gd -- --full
##
## runs the whole nine-scene suite plus calibration instead of one cheap scene — about three
## minutes, and what to run before believing a change to the suite or the advisor.
##
## The pure half needs nothing: no window, no world, no autoloads. That is deliberate. The maths
## that decides what settings a player ends up with is the part most worth testing and the part
## least able to afford needing a GPU to test it, which is why `FrameSampler` never reads a clock
## and `SettingsAdvisor` never reads a node.

const FrameSampler := preload("res://core/bench/frame_sampler.gd")
const BenchmarkSuite := preload("res://core/bench/benchmark_suite.gd")
const BenchmarkReport := preload("res://core/bench/benchmark_report.gd")
const SettingsAdvisor := preload("res://core/bench/settings_advisor.gd")
const BenchmarkRunner := preload("res://core/bench/benchmark_runner.gd")
const MachineProbe := preload("res://core/bench/machine_probe.gd")
const BenchmarkScreen := preload("res://ui/frontend/benchmark_screen.gd")

const SCRATCH_DIR: String = "user://benchmark_check"

## How long the live half waits for the runner before calling it a failure. Generous — the full
## suite is minutes — but finite, because a check that hangs is a check that gets killed by a
## timeout and reports nothing at all.
const LIVE_TIMEOUT_FRAMES: int = 200000

## The least a stationary scene's 1% low may be, as a fraction of its own median frame rate, before
## the check calls it "the world was still arriving". Generous — real hitches exist and a slow
## machine has a deeper tail than a fast one — but a stationary sample at a fifth of its median is
## not a hitch, it is a measurement of the wrong thing.
const STATIONARY_TAIL_FLOOR: float = 0.2

## The least a scene may draw, as a fraction of the suite's median draw calls, before the check
## calls it "pointed at nothing". Generous — the traversal scene legitimately draws far less,
## because it spends the sample in ground that has not finished arriving — but an order of
## magnitude below the rest of the suite means the destination search picked somewhere empty.
const EMPTY_VIEW_FLOOR: float = 0.25

var _failures: PackedStringArray = []
var _checks: int = 0

## The live half's results, as MEMBERS rather than locals captured by a signal lambda. GDScript
## closures capture locals by VALUE, so `runner.finished.connect(func(v): report = v)` assigns to
## the lambda's own copy and the waiting loop outside it never sees anything — which hangs the
## check forever on a run that completed perfectly. Members are reached through `self` and do not
## have that problem.
var _live_report: Dictionary = {}
var _live_error: String = ""
## Sampled during the first scene — see the connect in `_check_live()`.
var _saw_god_mode: bool = false
var _saw_picker_open: bool = true
## F-462: how many live-readout ticks arrived, over how many frames, and the first countdown seen.
var _telemetry_ticks: int = 0
var _telemetry_frames: int = 1
var _saw_countdown: float = 0.0
var _saw_input_blocked: bool = false
var _saw_mouse_mode: int = Input.MOUSE_MODE_CAPTURED
var _saw_hud_visible: bool = true
var _saw_vsync: int = DisplayServer.VSYNC_ENABLED


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n=== benchmark check (F-453) ===")
	_go_fullscreen()
	_check_sampler()
	_check_suite()
	_check_advisor()
	_check_ledger()
	_check_machine_probe()
	await _check_screen()
	await _check_live()

	print("\n%d assertion(s), %d failure(s)" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL  %s" % failure)
	quit(1 if _failures.size() > 0 else 0)


# ── the statistics ────────────────────────────────────────────────────────────────────────────


## Fullscreen, at the very top of the run, before anything else touches the tree.
##
## This was originally done inside `_check_live()`, most of the way through the check, and it
## silently did nothing: the run reported a 1280x803 viewport on a 3024x1898 display and burned a
## measurement window that had been asked for specifically. `tools/perf_probe.gd` sets the mode as
## the first thing it does and has always worked, which is the difference — the wrapper passes
## `--headless` ahead of `--display-driver macos`, so the window arrives late and a mode set after
## other nodes exist is refused.
##
## Verified rather than assumed: the resulting size is printed and asserted against the screen, so a
## refusal says so in the first line of output instead of at the end of a seven-minute run.
func _go_fullscreen() -> void:
	if not OS.get_cmdline_user_args().has("--fullscreen"):
		return
	if DisplayServer.get_name() == "headless":
		_fail("--fullscreen asked for but this process has no display — add --display-driver macos")
		return
	root.title = "MIRE benchmark — leave this window in front, do not cover it"
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	DisplayServer.window_move_to_foreground()
	var screen: Vector2i = DisplayServer.screen_get_size()
	var window: Vector2i = DisplayServer.window_get_size()
	print("  window %dx%d on a %dx%d screen | focused %s" % [
		window.x, window.y, screen.x, screen.y, DisplayServer.window_is_focused()])
	# Height is allowed to fall short of the screen: macOS keeps the menu bar, so a genuinely
	# fullscreen window on a 3024x1964 display measures 3024x1898 — the same figure
	# docs/PERFORMANCE.md quotes for `perf_probe`'s fullscreen runs. Width has no such excuse.
	_expect(window.x >= screen.x and float(window.y) >= float(screen.y) * 0.9,
		"the window really is fullscreen (%dx%d of %dx%d) — a frame time from a small window is "
		% [window.x, window.y, screen.x, screen.y] + "not the frame time of the game")


func _check_sampler() -> void:
	print("\n-- frame sampler --")

	# A perfectly steady 10 ms stream, once the discarded frames are past.
	var steady := FrameSampler.new()
	for _i: int in FrameSampler.DISCARD_FRAMES + 400:
		steady.record(10.0, 0.0, 0.0, 100.0, 1000.0)
	var stats: Dictionary = steady.stats()
	_expect(stats["frames"] == 400, "discards exactly DISCARD_FRAMES frames (got %d)"
		% int(stats["frames"]))
	_expect(absf(float(stats["median_ms"]) - 10.0) < 0.001, "median of a steady stream is 10 ms")
	_expect(absf(float(stats["fps"]) - 100.0) < 0.01, "100 fps from 10 ms frames")
	_expect(absf(float(stats["low1_fps"]) - 100.0) < 0.01,
		"1% low equals the median when nothing varies")
	_expect(absf(float(stats["draws"]) - 100.0) < 0.001, "draw calls are averaged, not summed")

	# The case the whole metric exists for: a smooth stream with a few bad frames in it. The
	# median must not notice; the 1% low must.
	var hitchy := FrameSampler.new()
	for _i: int in FrameSampler.DISCARD_FRAMES:
		hitchy.record(10.0, 0.0, 0.0, 0.0, 0.0)
	for i: int in 400:
		hitchy.record(50.0 if i % 100 == 0 else 10.0, 0.0, 0.0, 0.0, 0.0)
	var hitch_stats: Dictionary = hitchy.stats()
	_expect(absf(float(hitch_stats["median_ms"]) - 10.0) < 0.001,
		"four 50 ms frames in 400 do not move the median")
	_expect(float(hitch_stats["low1_ms"]) > 40.0,
		"the 1%% low reports them (%.1f ms)" % float(hitch_stats["low1_ms"]))

	# A suspended process must not be able to decide a recommendation.
	var stalled := FrameSampler.new()
	for _i: int in FrameSampler.DISCARD_FRAMES + 200:
		stalled.record(10.0, 0.0, 0.0, 0.0, 0.0)
	stalled.record(4000.0, 0.0, 0.0, 0.0, 0.0)
	var stalled_stats: Dictionary = stalled.stats()
	_expect(int(stalled_stats["stalls"]) == 1, "a 4 s frame is counted as a stall")
	_expect(float(stalled_stats["low1_ms"]) < 20.0,
		"and is excluded from the tail (%.1f ms)" % float(stalled_stats["low1_ms"]))

	var empty: Dictionary = FrameSampler.new().stats()
	_expect(int(empty["frames"]) == 0 and float(empty["low1_fps"]) == 0.0,
		"an unmeasured scene reports zero frames rather than zero fps")


# ── the suite ─────────────────────────────────────────────────────────────────────────────────


func _check_suite() -> void:
	print("\n-- suite --")
	var scenes: Array[Dictionary] = BenchmarkSuite.scenes()
	_expect(scenes.size() >= 10, "the suite has enough scenes to be worth running (%d)"
		% scenes.size())

	var ids: Dictionary = {}
	for scene: Dictionary in scenes:
		var id: String = String(scene.get("id", ""))
		_expect(not id.is_empty(), "every scene has an id")
		_expect(not ids.has(id), "scene id '%s' is unique — the ledger resumes on it" % id)
		ids[id] = true
		for key: String in ["label", "stresses", "where"]:
			_expect(not String(scene.get(key, "")).is_empty(),
				"scene '%s' has a %s" % [id, key])

	# F-458: equal by construction, not by counting rows. Night is when this game is played hard,
	# and a suite weighted toward daylight recommends settings for the easy half of it.
	var split: Vector2i = BenchmarkSuite.day_night_counts()
	_expect(split.x == split.y,
		"the suite measures as much night as day (%d day, %d night)" % [split.x, split.y])
	_expect(split.x > 0, "and actually has some of each")

	# The whole day block, then the whole night block. Crossing into darkness fires `night_started`
	# and is a one-way step, so it must happen exactly once, half way through.
	var seen_night: bool = false
	for scene: Dictionary in scenes:
		if bool(scene.get("night", false)):
			seen_night = true
		elif seen_night:
			_fail("scene '%s' runs in daylight after the suite has gone dark"
				% String(scene["id"]))

	# Every situation appears in both halves, or the pairing is not a pairing.
	for situation: Dictionary in BenchmarkSuite.situations():
		var base: String = String(situation["id"])
		_expect(ids.has("%s_day" % base) and ids.has("%s_night" % base),
			"'%s' is measured by both day and night" % base)

	var motions: Dictionary = {}
	for scene: Dictionary in scenes:
		motions[String(scene.get("motion", ""))] = true
		_expect(bool(scene.get("travel", false))
			== (StringName(scene.get("motion", "")) != BenchmarkSuite.MOTION_STILL),
			"scene '%s' agrees with itself about whether the camera moves" % String(scene["id"]))
	_expect(motions.has(String(BenchmarkSuite.MOTION_FLY)),
		"the suite includes a flyover — nothing else shows the island as a whole (F-458)")
	_expect(motions.has(String(BenchmarkSuite.MOTION_WALK)),
		"and a ground traversal, which is where the hitches are")
	_expect(motions.has(String(BenchmarkSuite.MOTION_STILL)),
		"and stationary scenes, which are the only ones a preset can be chosen on")

	var waves: int = 0
	for scene: Dictionary in scenes:
		if int(scene.get("enemies", 0)) > 0:
			waves += 1
	_expect(waves == 2, "a wave is measured in each half (%d)" % waves)

	_expect(BenchmarkSuite.estimated_seconds() > 30.0
		and BenchmarkSuite.estimated_seconds() < 400.0,
		"the estimate is a plausible thing to ask a player for (%.0f s)"
		% BenchmarkSuite.estimated_seconds())
	_expect(not BenchmarkSuite.scene_by_id(&"shore_day").is_empty(),
		"scene_by_id finds a real scene")
	_expect(BenchmarkSuite.scene_by_id(&"nonexistent").is_empty(),
		"scene_by_id returns empty for an unknown id rather than crashing")


# ── the advisor ───────────────────────────────────────────────────────────────────────────────


func _check_advisor() -> void:
	print("\n-- advisor --")

	var fast: Array = [
		_scene_result("shore", 300.0, 320.0), _scene_result("night", 140.0, 150.0),
	]
	var comfortable: Dictionary = SettingsAdvisor.recommend(
		fast, {SettingsAdvisor.PRESET_HIGH: 140.0}, 60, 2)
	_expect(comfortable["preset"] == SettingsAdvisor.PRESET_HIGH,
		"a machine that holds 140 fps at HIGH is recommended HIGH")
	_expect(comfortable["verdict"] == &"comfortable", "and told so plainly")
	_expect(not bool(comfortable["dynamic_resolution"]),
		"with the safety net left OFF — it would only ever fire during a hitch")

	# Clears the target, but only just: the machine gets the safety net.
	var marginal: Dictionary = SettingsAdvisor.recommend(
		[_scene_result("night", 62.0, 70.0)], {SettingsAdvisor.PRESET_MEDIUM: 62.0}, 60, 2)
	_expect(marginal["preset"] == SettingsAdvisor.PRESET_MEDIUM, "62 fps at MEDIUM clears 60")
	_expect(marginal["verdict"] == &"tight", "but not comfortably")
	_expect(bool(marginal["dynamic_resolution"]), "so dynamic resolution is switched on")

	# The highest preset that passed wins, not the first one measured.
	var stepped: Dictionary = SettingsAdvisor.recommend(
		[_scene_result("night", 40.0, 60.0)],
		{SettingsAdvisor.PRESET_HIGH: 40.0, SettingsAdvisor.PRESET_MEDIUM: 95.0,
			SettingsAdvisor.PRESET_LOW: 180.0}, 60, 2)
	_expect(stepped["preset"] == SettingsAdvisor.PRESET_MEDIUM,
		"MEDIUM is chosen over LOW when both clear the target")

	# No calibration at all: no evidence, so no recommendation and nothing changed.
	var uncalibrated: Dictionary = SettingsAdvisor.recommend(
		[_scene_result("night", 45.0, 60.0)], {}, 60, 1)
	_expect(uncalibrated["verdict"] == &"unmeasured",
		"an uncalibrated run recommends nothing rather than guessing from no data")
	_expect(int(uncalibrated["preset"]) == 1 and not bool(uncalibrated["dynamic_resolution"]),
		"and leaves every setting exactly as it found them")

	# Nothing cleared it. The player must be told, not handed a preset as though it had.
	var hopeless: Dictionary = SettingsAdvisor.recommend(
		[_scene_result("night", 18.0, 24.0)],
		{SettingsAdvisor.PRESET_HIGH: 12.0, SettingsAdvisor.PRESET_MEDIUM: 16.0,
			SettingsAdvisor.PRESET_LOW: 28.0}, 60, 2)
	_expect(hopeless["verdict"] == &"below_target", "a machine that cannot hold 60 is told so")
	_expect(hopeless["preset"] == SettingsAdvisor.PRESET_LOW, "and lands on LOW")
	_expect(int(hopeless["anti_aliasing"]) == SettingsAdvisor.AA_OFF,
		"with anti-aliasing off — no preset touches it, so it is the largest cost left")
	_expect(_reasons_mention(hopeless, "30 fps"), "and is offered a target it can actually hold")

	# The preset is chosen against the hardest scene a preset can CHANGE, never against a traversal
	# scene — whose cost is the chunk streamer, which no graphics lever touches, and whose repeated
	# samples measure different worlds because the first pass streams the ground in for the rest.
	var mixed: Array = [
		_travel_result("traverse", 17.0, 110.0), _scene_result("forest", 54.0, 118.0),
		_scene_result("shore", 62.0, 119.0),
	]
	_expect(String(SettingsAdvisor.preset_basis(mixed).get("id", "")) == "forest",
		"the preset basis is the worst NON-travelling scene, not the worst scene overall")
	_expect(String(SettingsAdvisor.worst_scene(mixed).get("id", "")) == "traverse",
		"while the worst scene overall is still the travelling one")
	var mixed_recommendation: Dictionary = SettingsAdvisor.recommend(
		mixed, {SettingsAdvisor.PRESET_HIGH: 54.0, SettingsAdvisor.PRESET_MEDIUM: 88.0}, 60, 2)
	_expect(mixed_recommendation["preset"] == SettingsAdvisor.PRESET_MEDIUM,
		"and the verdict follows the basis scene")
	_expect(_reasons_mention(mixed_recommendation, "hitching"),
		"with the traversal hitch still reported, on its own terms")
	_expect(not _reasons_mention(mixed_recommendation, "Traverse holds"),
		"and never as something a preset fixed")
	_expect(SettingsAdvisor.preset_basis([_travel_result("traverse", 17.0, 110.0)])
		.get("id", "") == "traverse",
		"a suite where everything travels still yields a basis rather than nothing")

	# A non-monotonic ladder is noise, not physics, and the report must say so rather than let a
	# reader conclude the whole thing is junk.
	var noisy: Dictionary = SettingsAdvisor.recommend(
		[_scene_result("mire", 62.0, 142.0)],
		{SettingsAdvisor.PRESET_HIGH: 62.0, SettingsAdvisor.PRESET_MEDIUM: 58.0,
			SettingsAdvisor.PRESET_LOW: 69.0}, 60, 2)
	_expect(noisy["preset"] == SettingsAdvisor.PRESET_HIGH,
		"a noisy ladder still recommends the highest preset that cleared the target")
	_expect(_reasons_mention(noisy, "within noise of each other"),
		"and says the presets could not be told apart, rather than presenting noise as a result")
	var clean: Dictionary = SettingsAdvisor.recommend(
		[_scene_result("mire", 40.0, 90.0)],
		{SettingsAdvisor.PRESET_HIGH: 40.0, SettingsAdvisor.PRESET_MEDIUM: 72.0,
			SettingsAdvisor.PRESET_LOW: 130.0}, 60, 2)
	_expect(not _reasons_mention(clean, "within noise of each other"),
		"a ladder that IS a ladder gets no such caveat")

	# The diagnostic: uneven, not slow. A resolution lever does not fix this and the advice says so.
	var hitching: Dictionary = SettingsAdvisor.recommend(
		[_scene_result("traverse", 25.0, 120.0)], {SettingsAdvisor.PRESET_HIGH: 25.0}, 60, 2)
	_expect(_reasons_mention(hitching, "hitching"),
		"a 1% low far below the median is named as hitching, not as a slow frame")

	# Scenes that never recorded a frame are not the worst scene in the world.
	var partial: Array = [_scene_result("shore", 200.0, 210.0), _unmeasured("night")]
	_expect(String(SettingsAdvisor.worst_scene(partial).get("id", "")) == "shore",
		"an unmeasured scene is skipped rather than counted as 0 fps")
	_expect(SettingsAdvisor.ranked(partial).size() == 1, "and is left out of the results table")


# ── the ledger ────────────────────────────────────────────────────────────────────────────────


func _check_ledger() -> void:
	print("\n-- ledger --")
	DirAccess.make_dir_recursive_absolute(SCRATCH_DIR)
	# Ask the writer for its path rather than rebuilding it: `--tag` renames the ledger so a
	# sequence of ablation runs does not overwrite each other's reports, and a second copy of the
	# naming rule here silently broke `discard() removes the ledger` on every tagged run.
	var writer: BenchmarkReport = _scratch_report()
	var path: String = writer.ledger_path
	_expect(writer.begin("sig-a").is_empty(), "a fresh ledger resumes nothing")
	writer.append_scene(_scene_result("shore", 200.0, 210.0))
	writer.append_scene(_scene_result("forest", 90.0, 110.0))
	writer.close()

	var resumed: Array = _scratch_report().begin("sig-a")
	_expect(resumed.size() == 2, "a matching signature resumes both rows (got %d)" % resumed.size())
	_expect(String(resumed[0].get("id", "")) == "shore", "in order")

	var mismatched: Array = _scratch_report().begin("sig-B-different-settings")
	_expect(mismatched.is_empty(),
		"a ledger taken under different settings is discarded, not half-resumed")

	# A hard kill mid-write leaves a torn final line. It must cost that row and nothing else.
	var rebuilt: BenchmarkReport = _scratch_report()
	rebuilt.begin("sig-a")
	rebuilt.append_scene(_scene_result("shore", 200.0, 210.0))
	rebuilt.close()
	var torn: FileAccess = FileAccess.open(path, FileAccess.READ_WRITE)
	torn.seek_end()
	torn.store_string('{"kind": "scene", "id": "for')
	torn.close()
	var after_tear: Array = _scratch_report().begin("sig-a")
	_expect(after_tear.size() == 1,
		"a torn final line is dropped and the complete rows survive (got %d)" % after_tear.size())

	var discarding: BenchmarkReport = _scratch_report()
	discarding.discard()
	_expect(not FileAccess.file_exists(path), "discard() removes the ledger")

	var text: String = BenchmarkReport.format_text({
		"machine": {"adapter_name": "Test GPU", "os": "TestOS", "cpu": "Test CPU"},
		"scenes": [_scene_result("shore", 200.0, 210.0), _unmeasured("night")],
		"recommendation": {"headline": "HIGH", "reasons": ["because"]},
		"calibration": {"HIGH": 200.0},
	})
	_expect(text.contains("Test GPU") and text.contains("not measured")
		and text.contains("Recommended: HIGH"),
		"the pasteable report names the machine, the unmeasured scene and the recommendation")


# ── the machine probe ─────────────────────────────────────────────────────────────────────────


func _check_machine_probe() -> void:
	print("\n-- machine probe --")
	var hardware: Dictionary = MachineProbe.read_hardware()
	_expect(not String(hardware.get("cpu", "")).is_empty(), "the CPU is named (%s)"
		% String(hardware.get("cpu", "")))
	_expect(int(hardware.get("memory_mib", 0)) > 0, "system memory is read (%d MiB)"
		% int(hardware.get("memory_mib", 0)))

	var power: Dictionary = MachineProbe.read_power()
	print("  state: %s" % MachineProbe.describe_power(power))
	if OS.get_name() == "macOS":
		# Every field below is parsed from a real `pmset` invocation, so this is the assertion that
		# catches a format change in a future macOS rather than one that restates the source.
		_expect(bool(power.get("supported", false)),
			"macOS power state is readable without a password")
		_expect(power.has("ac_power"), "the power source is known")
		_expect(int(power.get("cpu_speed_limit", 0)) > 0 and int(power.get("cpu_speed_limit", 0))
			<= 100, "the CPU speed limit parses to a percentage (%d%%)"
			% int(power.get("cpu_speed_limit", -1)))
		_expect(MachineProbe.POWER_MODE_NAMES.has(int(power.get("power_mode", -1))),
			"the performance profile is one this build knows (%s)"
			% String(MachineProbe.POWER_MODE_NAMES.get(int(power.get("power_mode", -1)), "?")))
		_expect(hardware.has("cpu_performance_cores"),
			"the performance/efficiency core split is read (%dP + %dE)"
			% [int(hardware.get("cpu_performance_cores", 0)),
				int(hardware.get("cpu_efficiency_cores", 0))])
	else:
		_expect(not bool(power.get("supported", true)),
			"an unimplemented platform says so instead of returning defaults that read as facts")
		_expect(not String(power.get("reason", "")).is_empty(), "and names why")

	# The warnings are what a player acts on, so they are asserted against synthetic states rather
	# than against whatever this machine happens to be doing right now.
	_expect(MachineProbe.warnings({"supported": true, "ac_power": true, "power_mode": 0,
		"cpu_speed_limit": 100}).is_empty(), "a healthy machine produces no warnings")
	_expect(MachineProbe.warnings({"supported": true, "ac_power": false, "power_mode": 0,
		"cpu_speed_limit": 100}).size() == 1, "running on battery is one warning")
	_expect(MachineProbe.warnings({"supported": true, "ac_power": false, "power_mode": 1,
		"cpu_speed_limit": 60}).size() == 3, "battery + Low Power Mode + throttling is three")
	_expect(MachineProbe.warnings({"supported": false}).is_empty(),
		"an unsupported platform warns about nothing rather than warning wrongly")

	var got_hot: Dictionary = MachineProbe.drift(
		{"supported": true, "cpu_speed_limit": 100, "ac_power": true, "battery_percent": 90},
		{"supported": true, "cpu_speed_limit": 60, "ac_power": true, "battery_percent": 88})
	_expect(bool(got_hot.get("throttled", false)), "a run that throttled mid-way is flagged")
	_expect((got_hot.get("notes", []) as PackedStringArray)[0].contains("getting hot"),
		"and the note names the scenes it affected")
	var steady: Dictionary = MachineProbe.drift(
		{"supported": true, "cpu_speed_limit": 100, "ac_power": true, "battery_percent": 90},
		{"supported": true, "cpu_speed_limit": 100, "ac_power": true, "battery_percent": 90})
	_expect((steady.get("notes", []) as PackedStringArray).is_empty(),
		"a clean run says nothing about its conditions")


# ── the screen ────────────────────────────────────────────────────────────────────────────────


## Builds the player-facing screen and checks the parts that are logic rather than looks: that it
## comes up, that it offers the controls it promises, and that Esc means "stop the benchmark"
## instead of "leave the screen" while one is running. It does NOT start a benchmark — that is
## `_check_live()`'s job, through the runner directly.
##
## What this cannot check is whether the screen LOOKS right. That needs eyes.
func _check_screen() -> void:
	print("\n-- screen --")
	var screen: Control = BenchmarkScreen.new()
	root.add_child(screen)
	await process_frame

	var buttons: Array[Button] = []
	_collect_buttons(screen, buttons)
	var labels: PackedStringArray = []
	for button: Button in buttons:
		labels.append(button.text)
	_expect(labels.has("RUN BENCHMARK"),
		"the intro offers the run button (found: %s)" % ", ".join(labels))
	_expect(labels.has("BACK"), "and a way out")
	_expect(screen.call(&"menu_default_focus") != null,
		"it names a default focus — a controller never lands nowhere")
	_expect(not bool(screen.call(&"menu_dims_background")),
		"it paints its own shade, so the benchmark world is not dimmed while it is measured")
	_expect(bool(screen.call(&"menu_allows_cancel")),
		"Esc leaves the screen when nothing is running")

	# The state that matters: while a benchmark is in flight Esc must cancel the benchmark and
	# refuse to pop, or the stack would free the screen out from under a running measurement and
	# leave a world parented to the tree.
	screen.set(&"_state", 1)
	_expect(not bool(screen.call(&"menu_allows_cancel")),
		"and cancels the benchmark instead of popping while one is running")
	screen.set(&"_state", 0)

	# F-462: the live readout exists and is wired. Driven with a synthetic tick rather than a real
	# run, so the check covers the formatting rules — which are where the lies would be — without
	# spending four minutes.
	screen.call(&"_on_telemetry", {
		"fps": 118.4, "low1_fps": 71.6, "frame_ms": 8.31, "gpu_ms": 6.02, "cpu_ms": 1.44,
		"draws": 4193.0, "total_seconds_left": 137.0, "worst_ms": 41.2, "mprims": 1.84,
		"vram_mb": 726.0, "physics_ms": 0.9, "nodes": 5120.0, "chunks": 289.0,
	})
	var readout: Dictionary = screen.get(&"_readout_labels")
	_expect(readout.size() >= 12, "the readout shows every live figure (%d)" % readout.size())
	for key: String in ["fps", "low1_fps", "frame_ms", "worst_ms", "gpu_ms", "cpu_ms",
			"draws", "mprims", "vram_mb", "physics_ms", "nodes", "chunks"]:
		_expect(readout.has(key), "the readout has a cell for '%s'" % key)
	_expect((readout["fps"] as Label).text == "118", "frames per second are shown whole")
	_expect((readout["low1_fps"] as Label).text == "72", "and the 1%% low beside them")
	_expect((readout["draws"] as Label).text == "4193", "and the draw calls")
	_expect((readout["worst_ms"] as Label).text == "41",
		"and the worst frame, which is the hitch as it happens")
	_expect((readout["chunks"] as Label).text == "289",
		"and the streamer's chunk count, which is what the moving scenes stress")
	_expect((readout["vram_mb"] as Label).text == "726", "and video memory")
	var countdown: Label = screen.get(&"_countdown_label")
	_expect(countdown.text == "~2:17",
		"the countdown reads M:SS and is marked a guess until a scene has been timed (%s)"
		% countdown.text)

	# A staging tick has no sample behind it. Zero must read as "nothing measured yet", never as a
	# machine rendering at zero frames a second.
	screen.call(&"_on_telemetry", {"fps": 61.0, "low1_fps": 0.0, "total_seconds_left": 5.0})
	_expect((readout["low1_fps"] as Label).text == "—",
		"an unmeasured 1%% low shows a dash, not 0 fps")
	_expect(countdown.text == "~0:05", "and the countdown pads its seconds")

	var target_dropdowns: int = _count_option_buttons(screen)
	_expect(target_dropdowns >= 1, "the target frame rate is selectable")

	screen.queue_free()
	await process_frame


func _collect_buttons(node: Node, into: Array[Button]) -> void:
	if node is Button:
		into.append(node as Button)
	for child: Node in node.get_children():
		_collect_buttons(child, into)


func _count_option_buttons(node: Node) -> int:
	var count: int = 1 if node is OptionButton else 0
	for child: Node in node.get_children():
		count += _count_option_buttons(child)
	return count


# ── one real scene ────────────────────────────────────────────────────────────────────────────


func _check_live() -> void:
	print("\n-- live --")
	if DisplayServer.get_name() == "headless":
		print("  SKIPPED — no framebuffer. Re-run with `agent godot --windowed` to measure.")
		return

	var args: PackedStringArray = OS.get_cmdline_user_args()
	var full: bool = args.has("--full")
	var packed := load("res://levels/procedural_island.tscn") as PackedScene
	if packed == null:
		_fail("could not load the benchmark world")
		return

	var game_state: Node = root.get_node_or_null(^"/root/GameState")
	if game_state != null:
		game_state.call(&"set_pending_seed", BenchmarkRunner.BENCH_SEED)
		game_state.call(&"host_generate_seed")

	var world := packed.instantiate() as Node3D
	root.add_child(world)
	current_scene = world
	for _i: int in 8:
		await physics_frame
	var settled: Dictionary = await BenchmarkRunner.settle_world(world, self)
	print("  streamed %d chunk(s) in %d frame(s)%s" % [
		int(settled.get("chunks", 0)), int(settled.get("frames", 0)),
		"" if bool(settled.get("settled", true)) else " — NOT SETTLED"])
	_expect(bool(settled.get("settled", true)), "the world settles inside the frame budget")

	var runner := BenchmarkRunner.new()
	# Ablations for the follow-up measurements: `--no-prewarm` re-checks F-459's first-visit hitch,
	# `--no-readout` produces the reference the instrument-frame correction has to reproduce.
	runner.prewarm_enabled = not args.has("--no-prewarm")
	runner.readout_enabled = not args.has("--no-readout")
	runner.report_writer = _scratch_report()
	root.add_child(runner)

	runner.finished.connect(func(value: Dictionary) -> void: _live_report = value)
	runner.failed.connect(func(message: String) -> void: _live_error = message)
	runner.scene_finished.connect(func(_i: int, _n: int, result: Dictionary) -> void:
		print("  %-16s 1%% low %6.0f fps  median %6.2f ms  draws %6.0f" % [
			String(result.get("label", "?")), float(result.get("low1_fps", 0.0)),
			float(result.get("median_ms", 0.0)), float(result.get("draws", 0.0))]))

	# The runner forces `Engine.max_fps = 0` for the duration — a limiter would make every scene
	# report the same number (docs/PERFORMANCE.md §1, rule 4) — and must hand back whatever the
	# game had set, which on this project is `DevFrameCap`'s runtime value and not a project setting.
	var limiter_before: int = Engine.max_fps
	var god_before: bool = _god_mode_on()
	var vsync_before: int = DisplayServer.window_get_vsync_mode()
	# The two things that must be true DURING a run, checked while it is still going rather than
	# after: the player cannot be killed, and the class picker is not sitting in front of the
	# camera. Both are sampled on the first scene's `scene_started`, which fires once the runner
	# has finished its setup and before it has measured anything.
	runner.telemetry.connect(func(info: Dictionary) -> void:
		_telemetry_ticks += 1
		if _saw_countdown <= 0.0:
			_saw_countdown = float(info.get("total_seconds_left", 0.0)))

	runner.scene_started.connect(func(index: int, _n: int, _scene: Dictionary) -> void:
		if index != 0:
			return
		_saw_god_mode = _god_mode_on()
		_saw_picker_open = _picker_open()
		_saw_input_blocked = _player_input_blocked()
		_saw_mouse_mode = Input.mouse_mode
		_saw_hud_visible = _hud_visible()
		_saw_vsync = DisplayServer.window_get_vsync_mode())

	var subset: Array[Dictionary] = []
	if not full:
		# One cheap scene, no calibration: enough to prove destination resolution, teleporting,
		# sampling, the ledger write and the report, without a three-minute check.
		subset.append(BenchmarkSuite.scene_by_id(&"forest_day"))
	runner.run(world, 60, false, subset, full)
	# Bounded: a runner that dies without emitting either signal must fail the check, not hang it.
	var waited: int = 0
	while _live_report.is_empty() and _live_error.is_empty() and waited < LIVE_TIMEOUT_FRAMES:
		await process_frame
		waited += 1

	if not _live_error.is_empty():
		_fail("the runner failed: %s" % _live_error)
		return
	if _live_report.is_empty():
		_fail("the runner emitted neither `finished` nor `failed` within %d frames"
			% LIVE_TIMEOUT_FRAMES)
		return

	var report: Dictionary = _live_report
	_telemetry_frames = waited
	var scenes: Array = report.get("scenes", [])
	var median_draws: float = _median_draws(scenes)
	_expect(scenes.size() == (BenchmarkSuite.scenes().size() if full else 1),
		"the runner measured every scene it was given")
	for entry: Dictionary in scenes:
		_expect(int(entry.get("frames", 0)) > 30,
			"'%s' recorded a usable number of frames (%d)"
			% [String(entry.get("label", "?")), int(entry.get("frames", 0))])
		_expect(float(entry.get("low1_fps", 0.0)) > 0.0,
			"'%s' produced a 1%% low" % String(entry.get("label", "?")))
		# The regression guard for the settle. A scene sampled while the camera is NOT moving has
		# no reason for a tail this deep — if its 1% low is a fraction of its median, the world was
		# still arriving inside the sample window and the scene measured the teleport rather than
		# the place. That shipped once: `Deep forest` reported 21 fps against a 113 fps median
		# standing still, because the settle was a fixed two seconds instead of a wait on the
		# streamer.
		# A scene drawing a small fraction of what the rest of the suite draws is not a cheap
		# scene, it is a scene pointed at nothing. `The Mire` measured 632 draw calls against
		# 4,000-5,500 everywhere else, because its destination search took the strongest
		# corruption reading anywhere on the grid and that was out at sea.
		if scenes.size() > 2:
			_expect(float(entry.get("draws", 0.0)) >= median_draws * EMPTY_VIEW_FLOOR,
				"'%s' is looking at the world, not past it (%.0f draws vs %.0f typical)"
				% [String(entry.get("label", "?")), float(entry.get("draws", 0.0)), median_draws])

		var scene: Dictionary = BenchmarkSuite.scene_by_id(StringName(entry.get("id", "")))
		if not bool(scene.get("travel", false)):
			var median_fps: float = float(entry.get("fps", 0.0))
			var low1: float = float(entry.get("low1_fps", 0.0))
			_expect(median_fps <= 0.0 or low1 >= median_fps * STATIONARY_TAIL_FLOOR,
				"'%s' is not still streaming while it is sampled (1%% low %.0f vs %.0f fps)"
				% [String(entry.get("label", "?")), low1, median_fps])
		var position: Array = entry.get("position", [])
		_expect(position.size() == 3 and not (float(position[0]) == 0.0
			and float(position[2]) == 0.0),
			"'%s' was measured somewhere the destination search actually chose"
			% String(entry.get("label", "?")))

	_expect(Engine.max_fps == limiter_before,
		"the frame limiter is put back after the run (was %d, now %d)"
		% [limiter_before, Engine.max_fps])
	var recommendation: Dictionary = report.get("recommendation", {})
	_expect(not String(recommendation.get("headline", "")).is_empty(),
		"the run ends in a recommendation")
	if full:
		var calibration_scene: String = String(report.get("calibration_scene", ""))
		_expect(not calibration_scene.is_empty(),
			"the report names the scene the presets were compared on (%s)" % calibration_scene)
		for entry: Dictionary in scenes:
			if String(entry.get("label", "")) == calibration_scene:
				_expect(not bool(entry.get("travel", false)),
					"the presets were compared on a scene a preset can change, not on '%s'"
					% calibration_scene)

	if not full:
		# The short run deliberately skips the calibration pass, so there is no evidence for any
		# preset and the advisor must say so rather than inventing one.
		_expect(recommendation.get("verdict", &"") == &"unmeasured",
			"a run with no calibration recommends nothing rather than guessing")
	_expect(bool((report.get("power_before", {}) as Dictionary).get("supported", false))
		== (OS.get_name() == "macOS"),
		"the run recorded the machine's power state at the start")
	_expect(report.has("power_after") and report.has("power_drift"),
		"and again at the end, with the drift between them")
	# F-466: the run must say whether it was actually on screen. This check normally runs in an
	# offscreen 64x64 window, so the EXPECTED result here is "not focused, and flagged" — the
	# assertion is that the flag tracks reality, not that the window happened to be in front.
	var unfocused: int = 0
	for entry: Dictionary in scenes:
		unfocused += int(entry.get("unfocused", 0))
	var focus_flagged: bool = false
	for note: String in report.get("state_notes", []):
		if note.contains("was not in front"):
			focus_flagged = true
	_expect(unfocused == 0 or focus_flagged,
		"a run measured while the window was not in front says so, and says what it does and "
		+ "does not prove (%d unfocused frame(s))" % unfocused)
	_expect(unfocused > 0 or not focus_flagged,
		"and a run that WAS in front carries no such warning")
	print("  focus: %d unfocused frame(s)%s" % [unfocused, " — FLAGGED" if focus_flagged else ""])

	_expect(_saw_vsync == DisplayServer.VSYNC_DISABLED,
		"vsync was off while the benchmark measured — with it on, every scene that can hold the "
		+ "refresh rate reports the refresh rate and the numbers describe the display")
	_expect(DisplayServer.window_get_vsync_mode() == vsync_before,
		"and the player's own vsync setting is restored afterwards")
	_expect(_telemetry_ticks > 0,
		"the runner published live numbers while it measured (%d tick(s))" % _telemetry_ticks)
	_expect(_saw_countdown > 0.0,
		"and a countdown with time left on it (%.0f s at the first tick)" % _saw_countdown)
	_expect(_telemetry_ticks < _telemetry_frames,
		"throttled below one update per frame — a readout must not cost what it reports "
		+ "(%d tick(s) over %d frame(s))" % [_telemetry_ticks, _telemetry_frames])
	_expect(_saw_input_blocked,
		"the player's controls were switched off while the benchmark measured — a hand on WASD "
		+ "would otherwise walk the camera out of the scene being measured")
	_expect(_saw_mouse_mode != Input.MOUSE_MODE_CAPTURED,
		"and the mouse was released, which is what gates look input in the controller")
	_expect(not _player_input_blocked(),
		"controls are given back when the run ends")
	_expect(not _saw_hud_visible,
		"the gameplay HUD — health, hunger, the hotbar, the crosshair — was hidden while the "
		+ "benchmark measured")
	_expect(_hud_visible(), "and shown again when the run ended")
	_expect(_saw_god_mode,
		"the player was invulnerable while the benchmark measured — the night wave stands still "
		+ "in front of six enemies and must not be able to kill them")
	_expect(not _saw_picker_open,
		"the class picker was not on screen during the run — it is a full-screen overlay, and a "
		+ "scene measured behind it measures the overlay")
	_expect(_god_mode_on() == god_before,
		"god mode is handed back exactly as it was found, so nothing leaks into the next run")
	_expect(_picker_visible(),
		"and the class picker is visible again afterwards")
	print("  state: %s" % String(report.get("power_summary", "?")))
	print("  → %s" % String(report.get("recommendation", {}).get("headline", "")))
	for reason: String in report.get("recommendation", {}).get("reasons", []):
		print("    %s" % reason)


# ── helpers ───────────────────────────────────────────────────────────────────────────────────


## The suite's typical draw-call count, used to spot a scene that is looking at nothing. A median
## rather than a mean so one empty scene cannot drag the very threshold that is meant to catch it.
func _median_draws(scenes: Array) -> float:
	var values: PackedFloat64Array = []
	for entry: Dictionary in scenes:
		if int(entry.get("frames", 0)) > 0:
			values.append(float(entry.get("draws", 0.0)))
	if values.is_empty():
		return 0.0
	values.sort()
	return values[values.size() / 2]


## Mirrors `entities/player/player_controller.gd`'s own `gameplay_input_allowed()`, deliberately
## re-derived from the group rather than read off the runner — the assertion is about the CONTROLLER
## refusing input, not about the runner believing it asked for that.
func _player_input_blocked() -> bool:
	return root.get_tree().get_first_node_in_group(&"blocks_gameplay_input") != null


## True if any of the HUD autoloads the runner hides is currently on screen.
func _hud_visible() -> bool:
	for autoload_name: String in BenchmarkRunner.HUD_AUTOLOADS:
		var node: Node = root.get_node_or_null(NodePath("/root/%s" % autoload_name))
		if node is CanvasLayer and (node as CanvasLayer).visible:
			return true
		if node is CanvasItem and (node as CanvasItem).visible:
			return true
	return false


func _god_mode_on() -> bool:
	var service: Node = root.get_node_or_null(^"/root/GodModeService")
	return service != null and bool(service.call(&"is_local_enabled"))


func _picker_open() -> bool:
	var picker: Node = root.get_node_or_null(^"/root/AttunementUI")
	if picker == null:
		return false
	var open: bool = picker.has_method(&"is_open") and bool(picker.call(&"is_open"))
	return open and (not (picker is CanvasLayer) or (picker as CanvasLayer).visible)


func _picker_visible() -> bool:
	var picker: Node = root.get_node_or_null(^"/root/AttunementUI")
	return not (picker is CanvasLayer) or (picker as CanvasLayer).visible


## `-- --tag NAME` writes this run's report to its own file, so a sequence of runs comparing
## ablations against each other does not have each one overwrite the last.
func _scratch_report() -> BenchmarkReport:
	var writer := BenchmarkReport.new()
	var tag: String = _string_arg("--tag", "")
	var suffix: String = "" if tag.is_empty() else "_%s" % tag
	writer.ledger_path = "%s/ledger%s.jsonl" % [SCRATCH_DIR, suffix]
	writer.report_json_path = "%s/report%s.json" % [SCRATCH_DIR, suffix]
	writer.report_text_path = "%s/report%s.txt" % [SCRATCH_DIR, suffix]
	return writer


func _string_arg(name: String, fallback: String) -> String:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] == name and i + 1 < args.size():
			return args[i + 1]
	return fallback


func _scene_result(id: String, low1_fps: float, fps: float) -> Dictionary:
	return {
		"id": id, "label": id.capitalize(), "stresses": "test", "frames": 400, "stalls": 0,
		"fps": fps, "median_ms": 1000.0 / fps, "p95_ms": 1000.0 / fps,
		"low1_ms": 1000.0 / low1_fps, "low1_fps": low1_fps,
		"gpu_ms": 0.0, "cpu_ms": 0.0, "draws": 1000.0, "mprims": 1.0, "travel": false,
	}


func _travel_result(id: String, low1_fps: float, fps: float) -> Dictionary:
	var row: Dictionary = _scene_result(id, low1_fps, fps)
	row["travel"] = true
	return row


func _unmeasured(id: String) -> Dictionary:
	var row: Dictionary = _scene_result(id, 0.0001, 0.0001)
	row["frames"] = 0
	row["low1_fps"] = 0.0
	return row


func _reasons_mention(recommendation: Dictionary, needle: String) -> bool:
	for reason: String in recommendation.get("reasons", []):
		if reason.contains(needle):
			return true
	return false


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("  ok    %s" % description)
	else:
		_failures.append(description)


func _fail(description: String) -> void:
	_checks += 1
	_failures.append(description)
