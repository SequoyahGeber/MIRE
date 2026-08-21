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


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n=== benchmark check (F-453) ===")
	_check_sampler()
	_check_suite()
	_check_advisor()
	_check_ledger()
	_check_machine_probe()
	await _check_live()

	print("\n%d assertion(s), %d failure(s)" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL  %s" % failure)
	quit(1 if _failures.size() > 0 else 0)


# ── the statistics ────────────────────────────────────────────────────────────────────────────


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
	_expect(scenes.size() >= 5, "the suite has enough scenes to be worth running")

	var ids: Dictionary = {}
	for scene: Dictionary in scenes:
		var id: String = String(scene.get("id", ""))
		_expect(not id.is_empty(), "every scene has an id")
		_expect(not ids.has(id), "scene id '%s' is unique — the ledger resumes on it" % id)
		ids[id] = true
		for key: String in ["label", "stresses", "where"]:
			_expect(not String(scene.get(key, "")).is_empty(),
				"scene '%s' has a %s" % [id, key])

	# The ordering rule the suite's header states: nothing is measured in a world an earlier scene
	# permanently changed.
	var seen_mutating: bool = false
	for scene: Dictionary in scenes:
		if bool(scene.get("mutates", false)):
			seen_mutating = true
		elif seen_mutating:
			_fail("scene '%s' runs after a scene that changed the world" % String(scene["id"]))
	_expect(seen_mutating, "the suite includes the scenes that change the world (night, a wave)")

	_expect(BenchmarkSuite.estimated_seconds() > 30.0
		and BenchmarkSuite.estimated_seconds() < 300.0,
		"the estimate is a plausible thing to ask a player for (%.0f s)"
		% BenchmarkSuite.estimated_seconds())
	_expect(not BenchmarkSuite.scene_by_id(&"shore").is_empty(), "scene_by_id finds a real scene")
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
	var path: String = "%s/ledger.jsonl" % SCRATCH_DIR

	var writer: BenchmarkReport = _scratch_report()
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


# ── one real scene ────────────────────────────────────────────────────────────────────────────


func _check_live() -> void:
	print("\n-- live --")
	if DisplayServer.get_name() == "headless":
		print("  SKIPPED — no framebuffer. Re-run with `agent godot --windowed` to measure.")
		return

	var full: bool = OS.get_cmdline_user_args().has("--full")
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
	# The two things that must be true DURING a run, checked while it is still going rather than
	# after: the player cannot be killed, and the class picker is not sitting in front of the
	# camera. Both are sampled on the first scene's `scene_started`, which fires once the runner
	# has finished its setup and before it has measured anything.
	runner.scene_started.connect(func(index: int, _n: int, _scene: Dictionary) -> void:
		if index != 0:
			return
		_saw_god_mode = _god_mode_on()
		_saw_picker_open = _picker_open())

	var subset: Array[Dictionary] = []
	if not full:
		# One cheap scene, no calibration: enough to prove destination resolution, teleporting,
		# sampling, the ledger write and the report, without a three-minute check.
		subset.append(BenchmarkSuite.scene_by_id(&"forest"))
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


func _scratch_report() -> BenchmarkReport:
	var writer := BenchmarkReport.new()
	writer.ledger_path = "%s/ledger.jsonl" % SCRATCH_DIR
	writer.report_json_path = "%s/report.json" % SCRATCH_DIR
	writer.report_text_path = "%s/report.txt" % SCRATCH_DIR
	return writer


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
