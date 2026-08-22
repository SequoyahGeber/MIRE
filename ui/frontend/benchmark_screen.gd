extends Control

## BenchmarkScreen — the player-facing benchmark (F-453).
##
## Three states in one screen: an explanation you agree to, a thin progress panel over the game
## actually being measured, and a results table that ends in a button which applies what the
## measurement recommends.
##
## ## Why the world is visible while it runs
##
## The obvious build of this is a progress bar over a black screen. That is worse in two ways. It
## gives the player no reason to believe the number — a benchmark you cannot watch is indistinguishable
## from a loading bar with a made-up score at the end — and it hides the one thing that makes the
## result actionable, which is *what the hard scene looked like*. A player who watches the frame
## rate collapse in the night wave, and reads "Night wave was the worst scene", has learned
## something about their machine. So the shade and the panel are dropped for the duration and the
## progress panel sits in a corner over the live game.
##
## ## Why this owns the benchmark world
##
## The benchmark never runs inside a real run (D-192 — two of its scenes change the world
## permanently), so somebody has to build it a world of its own. That is this screen: it pins the
## seed, instantiates the shipped level, waits for the streamer to settle, hands the level to
## `core/bench/benchmark_runner.gd`, and frees it afterwards. The runner stays free of scene
## loading, which is what lets `tools/benchmark_check.gd` drive it against a level the check
## staged itself.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI, and a single-player
## world that never opens a session.

const MireTheme := preload("res://ui/theme/mire_theme.gd")
const BenchmarkRunner := preload("res://core/bench/benchmark_runner.gd")
const BenchmarkSuite := preload("res://core/bench/benchmark_suite.gd")
const BenchmarkReport := preload("res://core/bench/benchmark_report.gd")
const SettingsAdvisor := preload("res://core/bench/settings_advisor.gd")
const MachineProbe := preload("res://core/bench/machine_probe.gd")

const WORLD_SCENE_PATH: String = "res://levels/procedural_island.tscn"

enum State { INTRO, RUNNING, RESULTS }

var _state: int = State.INTRO
var _shade: ColorRect
var _panel_host: CenterContainer
var _progress_host: Control
var _progress_bar: ProgressBar
var _progress_label: Label
var _progress_detail: Label
var _countdown_label: Label
var _readout_labels: Dictionary = {}
var _first_focus: Control

var _target_fps: int = SettingsAdvisor.DEFAULT_TARGET_FPS
var _runner: Node
var _world: Node3D
var _report: Dictionary = {}
var _recommendation: Dictionary = {}
## The front end is hidden while the benchmark world is up — its live 3D backdrop would otherwise
## be rendered behind the measured world and priced as part of it.
var _hidden_frontend: Node


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_show_intro()


func menu_default_focus() -> Control:
	return _first_focus


## The screen paints its own shade for the intro and results, and deliberately has none while the
## benchmark runs — see the header.
func menu_dims_background() -> bool:
	return false


## Esc during a run means "stop the benchmark", not "leave the screen": popping the screen out from
## under a running measurement would leave a world parented to the tree and a runner sampling it.
func menu_allows_cancel() -> bool:
	if _state == State.RUNNING:
		_cancel_run()
		return false
	return true


## A benchmark abandoned by any other route — the stack being cleared, the screen freed — must
## still put the world and the frame limiter back.
func _exit_tree() -> void:
	if _state == State.RUNNING:
		_cancel_run()
	_teardown_world()


func _build() -> void:
	_shade = ColorRect.new()
	_shade.color = MireTheme.SHADE
	_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_shade)

	_panel_host = CenterContainer.new()
	_panel_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel_host)

	_progress_host = _build_progress_panel()
	add_child(_progress_host)
	_progress_host.hide()


# ── intro ─────────────────────────────────────────────────────────────────────────────────────


func _show_intro() -> void:
	_state = State.INTRO
	_shade.show()
	_progress_host.hide()
	_clear_panel()

	var panel: PanelContainer = MireTheme.panel()
	var column: VBoxContainer = MireTheme.column(MireTheme.GRID * 2)
	column.custom_minimum_size = Vector2(620.0 * MireTheme.ui_scale(), 0.0)
	panel.add_child(_margins(column))

	column.add_child(MireTheme.label("BENCHMARK", MireTheme.HEADLINE))
	column.add_child(MireTheme.paragraph(
		"MIRE will generate the same island every time and walk %d scenes across it — the shore, "
		% BenchmarkSuite.scenes().size()
		+ "deep forest, marshland, a vista, ruins, the Mire, running inland while the world "
		+ "builds, night, and a night wave — measuring the frame rate in each. Then it tries the "
		+ "hardest of those scenes at each graphics preset and tells you which one your machine "
		+ "actually holds.", MireTheme.BODY, MireTheme.TEXT))
	column.add_child(MireTheme.paragraph(
		"About %d seconds, plus generating the island. Your controls are switched off while it "
		% int(BenchmarkSuite.estimated_seconds())
		+ "runs, so nothing you press can walk the camera out of the scene being measured — Esc "
		+ "still stops it, and keeps whatever it already measured."))

	# What state this machine is in RIGHT NOW, before two minutes are spent measuring it. A player
	# who is on battery in Low Power Mode can plug in and switch it off in ten seconds — but only
	# if somebody tells them, and afterwards is too late.
	var power: Dictionary = MachineProbe.read_power()
	var machine_warnings: PackedStringArray = MachineProbe.warnings(power)
	if bool(power.get("supported", false)):
		column.add_child(MireTheme.label(MachineProbe.describe_power(power),
			MireTheme.CAPTION, MireTheme.MUTED))
	if not machine_warnings.is_empty():
		var warning_card: PanelContainer = MireTheme.card(MireTheme.AMBER)
		var warning_column: VBoxContainer = MireTheme.column()
		warning_card.add_child(_margins(warning_column))
		warning_column.add_child(MireTheme.label("BEFORE YOU RUN IT", MireTheme.TITLE,
			MireTheme.AMBER))
		for warning: String in machine_warnings:
			warning_column.add_child(MireTheme.paragraph(warning))
		warning_column.add_child(MireTheme.button("CHECK AGAIN", _show_intro))
		column.add_child(warning_card)

	column.add_child(MireTheme.separator())

	var target_row: HBoxContainer = MireTheme.row(MireTheme.GRID * 2)
	var target_label: Label = MireTheme.label("Frame rate you want", MireTheme.BODY)
	target_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_row.add_child(target_label)
	var target_dropdown: OptionButton = MireTheme.dropdown()
	for index: int in SettingsAdvisor.TARGET_OPTIONS.size():
		var fps: int = SettingsAdvisor.TARGET_OPTIONS[index]
		target_dropdown.add_item("%d fps" % fps, index)
		if fps == _target_fps:
			target_dropdown.selected = index
	target_dropdown.item_selected.connect(func(index: int) -> void:
		_target_fps = SettingsAdvisor.TARGET_OPTIONS[index])
	target_row.add_child(target_dropdown)
	column.add_child(target_row)
	column.add_child(MireTheme.paragraph(
		"The recommendation is made against the WORST scene, not the average — a preset that holds "
		+ "your target everywhere except the night wave has not held your target."))

	column.add_child(MireTheme.separator())

	var buttons: HBoxContainer = MireTheme.row()
	var start: Button = MireTheme.button("RUN BENCHMARK",
		func() -> void: _start_run(false), MireTheme.Variant.PRIMARY)
	start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(start)
	if _has_resumable_run():
		var resume: Button = MireTheme.button("RESUME", func() -> void: _start_run(true))
		resume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		buttons.add_child(resume)
	column.add_child(buttons)
	column.add_child(MireTheme.link("BACK", _leave))

	_first_focus = start
	MireTheme.wire_chain([start, target_dropdown])
	_panel_host.add_child(panel)
	start.grab_focus()


## True when a ledger exists that a resumed run could still use. The signature check inside
## `BenchmarkReport` is the authority — this is only whether it is worth offering the button.
func _has_resumable_run() -> bool:
	return FileAccess.file_exists(BenchmarkReport.LEDGER_PATH)


# ── running ───────────────────────────────────────────────────────────────────────────────────


## The panel shown over the live world while the benchmark runs: what it is doing, how much longer,
## and what the frame is costing right now (F-462).
##
## The live readout is the reason this benchmark shows the world instead of a black screen. A player
## watching the night wave stutter should be able to see the number that says it stuttered — that is
## what turns "the game feels bad here" into something they can act on. It updates at
## `BenchmarkRunner.TELEMETRY_HZ`, not per frame: writing label text is canvas work inside the
## sample window, and a readout that costs the thing it reports is worse than none.
func _build_progress_panel() -> Control:
	var anchor := MarginContainer.new()
	anchor.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	anchor.add_theme_constant_override("margin_left", MireTheme.GRID * 4)
	anchor.add_theme_constant_override("margin_right", MireTheme.GRID * 4)
	anchor.add_theme_constant_override("margin_bottom", MireTheme.GRID * 4)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel: PanelContainer = MireTheme.panel()
	var column: VBoxContainer = MireTheme.column()
	panel.add_child(_margins(column))

	# Heading row: what is being measured, and how much longer the whole run has to go.
	var heading: HBoxContainer = MireTheme.row(MireTheme.GRID * 2)
	_progress_label = MireTheme.label("Preparing…", MireTheme.TITLE)
	_progress_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(_progress_label)
	_countdown_label = MireTheme.label("--:--", MireTheme.HEADLINE, MireTheme.AMBER)
	heading.add_child(_countdown_label)
	column.add_child(heading)

	_progress_detail = MireTheme.paragraph("")
	column.add_child(_progress_detail)

	_progress_bar = ProgressBar.new()
	_progress_bar.max_value = 1.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(0.0, 6.0)
	column.add_child(_progress_bar)

	column.add_child(_build_readout())
	column.add_child(MireTheme.paragraph("Esc stops the benchmark and keeps what it measured."))

	anchor.add_child(panel)
	return anchor


## The live numbers, in two rows of labelled figures.
##
## Row one is the frame itself — what it costs and how bad its worst moment was. Row two is what the
## frame is made of, which is what tells a player WHY it costs that. `1% LOW` and `WORST` carry the
## accent colour because they are the two numbers that describe how the game feels; a median frame
## time describes the stretches nobody complains about.
##
## `CHUNKS` earns its place over any other engine counter: the traversal and flyover scenes are
## stressing the chunk streamer, and watching that number climb while the frame time spikes is what
## makes the hitch legible as it happens instead of only in the report.
func _build_readout() -> Control:
	var rows: VBoxContainer = MireTheme.column(MireTheme.GRID)
	rows.add_child(_readout_row([
		["fps", "FPS", MireTheme.TEXT],
		["low1_fps", "1% LOW", MireTheme.AMBER],
		["frame_ms", "FRAME ms", MireTheme.TEXT],
		["worst_ms", "WORST ms", MireTheme.AMBER],
		["gpu_ms", "GPU ms", MireTheme.MUTED],
		["cpu_ms", "CPU ms", MireTheme.MUTED],
	]))
	rows.add_child(_readout_row([
		["draws", "DRAWS", MireTheme.MUTED],
		["mprims", "PRIMS M", MireTheme.MUTED],
		["vram_mb", "VRAM MB", MireTheme.MUTED],
		["physics_ms", "PHYS ms", MireTheme.MUTED],
		["nodes", "NODES", MireTheme.MUTED],
		["chunks", "CHUNKS", MireTheme.MOSS],
	]))
	return rows


func _readout_row(fields: Array) -> Control:
	var row: HBoxContainer = MireTheme.row(MireTheme.GRID * 3)
	for field: Array in fields:
		var cell: VBoxContainer = MireTheme.column(0)
		cell.custom_minimum_size = Vector2(84.0 * MireTheme.ui_scale(), 0.0)
		cell.add_child(MireTheme.label(String(field[1]), MireTheme.CAPTION, MireTheme.MUTED))
		var value: Label = MireTheme.label("—", MireTheme.TITLE, field[2])
		cell.add_child(value)
		_readout_labels[String(field[0])] = value
		row.add_child(cell)
	return row


## One telemetry tick from the runner.
func _on_telemetry(info: Dictionary) -> void:
	_set_readout("fps", "%.0f" % float(info.get("fps", 0.0)))
	# Zero means no sample yet — during staging there is nothing being measured, and printing "0"
	# would read as the machine rendering at zero frames a second.
	for key: String in ["low1_fps", "worst_ms"]:
		var value: float = float(info.get(key, 0.0))
		_set_readout(key, "—" if value <= 0.0 else "%.0f" % value)
	_set_readout("frame_ms", "%.1f" % float(info.get("frame_ms", 0.0)))
	_set_readout("gpu_ms", "%.1f" % float(info.get("gpu_ms", 0.0)))
	_set_readout("cpu_ms", "%.1f" % float(info.get("cpu_ms", 0.0)))
	_set_readout("draws", "%.0f" % float(info.get("draws", 0.0)))
	_set_readout("mprims", "%.2f" % float(info.get("mprims", 0.0)))
	_set_readout("vram_mb", "%.0f" % float(info.get("vram_mb", 0.0)))
	_set_readout("physics_ms", "%.1f" % float(info.get("physics_ms", 0.0)))
	_set_readout("nodes", "%.0f" % float(info.get("nodes", 0.0)))
	_set_readout("chunks", "%.0f" % float(info.get("chunks", 0.0)))
	_set_countdown(float(info.get("total_seconds_left", 0.0)))


func _set_readout(key: String, text: String) -> void:
	var label: Label = _readout_labels.get(key, null)
	if label != null:
		label.text = text


## M:SS remaining. Prefixed with a tilde until the runner has timed a scene of its own, because
## until then the figure comes from nominal constants rather than from this machine — and a
## countdown that presents a guess as a measurement is how a player learns to ignore it.
func _set_countdown(seconds_left: float) -> void:
	if _countdown_label == null:
		return
	var whole: int = int(ceilf(maxf(seconds_left, 0.0)))
	var measured: bool = _runner != null and is_instance_valid(_runner) \
		and bool(_runner.call(&"has_measured_pace"))
	_countdown_label.text = "%s%d:%02d" % ["" if measured else "~", whole / 60, whole % 60]


func _start_run(resume: bool) -> void:
	_state = State.RUNNING
	_clear_panel()
	_shade.hide()
	_progress_host.show()
	_set_progress("Generating the island…", "seed %d — the same island every run, so two "
		% BenchmarkRunner.BENCH_SEED + "benchmarks can be compared", 0.0)
	# Deferred so the progress panel is on screen for a frame before the level starts loading —
	# instantiating the world blocks, and a player who pressed RUN should see it acknowledged.
	_run_async.call_deferred(resume)


func _run_async(resume: bool) -> void:
	if not await _build_world():
		_show_results_error("could not load the benchmark world")
		return

	_runner = BenchmarkRunner.new()
	_runner.name = "BenchmarkRunner"
	add_child(_runner)
	var total: int = BenchmarkSuite.scenes().size()
	_runner.scene_started.connect(func(index: int, count: int, scene: Dictionary) -> void:
		_set_progress("%s  (%d of %d)" % [String(scene["label"]), index + 1, count],
			String(scene["stresses"]), float(index) / float(count)))
	_runner.scene_finished.connect(func(index: int, count: int, result: Dictionary) -> void:
		_set_progress("%s — %.0f fps" % [String(result.get("label", "")),
			float(result.get("low1_fps", 0.0))],
			"1% low, the number that decides how it feels", float(index + 1) / float(count)))
	_runner.telemetry.connect(_on_telemetry)
	_runner.phase_changed.connect(func(message: String) -> void:
		_set_progress(message, "measuring the hardest scene at each preset", 1.0))
	_runner.finished.connect(_on_finished)
	_runner.failed.connect(_on_failed)
	_runner.run(_world, _target_fps, resume)


## Builds the world the benchmark measures: pinned seed, shipped level, settled streamer. Returns
## false if the level could not be loaded at all.
func _build_world() -> bool:
	_hide_frontend()
	_pin_seed()
	var packed := load(WORLD_SCENE_PATH) as PackedScene
	if packed == null:
		return false
	_world = packed.instantiate() as Node3D
	if _world == null:
		return false
	get_tree().root.add_child(_world)
	# Undergrowth waits two physics frames then scatters; give colliders and the player spawn a
	# moment beyond that before asking the streamer whether it is finished.
	for _i: int in 8:
		await get_tree().physics_frame
	_set_progress("Streaming the island…", "measuring a half-built world would report it as a "
		+ "cheap one", 0.0)
	var settled: Dictionary = await BenchmarkRunner.settle_world(_world, get_tree())
	if not bool(settled.get("settled", true)):
		push_warning("benchmark: world still streaming after %d frames — the numbers below are a "
			% int(settled.get("frames", 0)) + "partly-built world")
	return true


func _pin_seed() -> void:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state == null:
		return
	game_state.call(&"set_pending_seed", BenchmarkRunner.BENCH_SEED)
	game_state.call(&"host_generate_seed")


func _hide_frontend() -> void:
	for node: Node in get_tree().get_nodes_in_group(&"mire_frontend"):
		if node is CanvasItem:
			(node as CanvasItem).visible = false
			_hidden_frontend = node
		elif node is Node3D:
			(node as Node3D).visible = false
			_hidden_frontend = node


func _restore_frontend() -> void:
	if _hidden_frontend == null or not is_instance_valid(_hidden_frontend):
		return
	if _hidden_frontend is CanvasItem:
		(_hidden_frontend as CanvasItem).visible = true
	elif _hidden_frontend is Node3D:
		(_hidden_frontend as Node3D).visible = true
	_hidden_frontend = null


func _teardown_world() -> void:
	if _runner != null and is_instance_valid(_runner):
		_runner.queue_free()
		_runner = null
	if _world != null and is_instance_valid(_world):
		_world.queue_free()
		_world = null
	# The benchmark deliberately replaces the process-wide run seed with BENCH_SEED. Do not let
	# that measurement fixture become the next expedition's island: once the benchmark world is
	# gone, gameplay must be back in the normal "no run yet" state so its first ensure_seed() draws
	# fresh entropy. A second benchmark run pins BENCH_SEED again in _build_world().
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state != null:
		game_state.call(&"reset")
	_restore_frontend()


func _cancel_run() -> void:
	if _runner != null and is_instance_valid(_runner):
		_runner.set(&"cancelled", true)


func _set_progress(headline: String, detail: String, fraction: float) -> void:
	if _progress_label != null:
		_progress_label.text = headline
	if _progress_detail != null:
		_progress_detail.text = detail
	if _progress_bar != null:
		_progress_bar.value = clampf(fraction, 0.0, 1.0)


# ── results ───────────────────────────────────────────────────────────────────────────────────


func _on_failed(message: String) -> void:
	_teardown_world()
	_show_results_error(message)


func _on_finished(report: Dictionary) -> void:
	_report = report
	_recommendation = report.get("recommendation", {})
	_teardown_world()
	_show_results()


func _show_results_error(message: String) -> void:
	_state = State.RESULTS
	_shade.show()
	_progress_host.hide()
	_clear_panel()
	var panel: PanelContainer = MireTheme.panel()
	var column: VBoxContainer = MireTheme.column(MireTheme.GRID * 2)
	panel.add_child(_margins(column))
	column.add_child(MireTheme.label("BENCHMARK STOPPED", MireTheme.HEADLINE))
	column.add_child(MireTheme.paragraph(message, MireTheme.BODY, MireTheme.TEXT))
	var again: Button = MireTheme.button("BACK TO SETTINGS", _leave, MireTheme.Variant.PRIMARY)
	column.add_child(again)
	_first_focus = again
	_panel_host.add_child(panel)
	again.grab_focus()


func _show_results() -> void:
	_state = State.RESULTS
	_shade.show()
	_progress_host.hide()
	_clear_panel()

	var panel: PanelContainer = MireTheme.panel()
	var column: VBoxContainer = MireTheme.column(MireTheme.GRID * 2)
	column.custom_minimum_size = Vector2(720.0 * MireTheme.ui_scale(), 0.0)
	panel.add_child(_margins(column))

	column.add_child(MireTheme.label("RESULTS", MireTheme.HEADLINE))
	column.add_child(MireTheme.label(String(_report.get("power_summary", "")),
		MireTheme.CAPTION, MireTheme.MUTED))
	# Above the recommendation, because these qualify it. A run that throttled half way through
	# produced real numbers for a machine that was getting hot, and the player has to know that
	# before they act on what it recommends.
	var state_notes: Array = _report.get("state_notes", [])
	if not state_notes.is_empty():
		var card: PanelContainer = MireTheme.card(MireTheme.AMBER)
		var card_column: VBoxContainer = MireTheme.column()
		card.add_child(_margins(card_column))
		card_column.add_child(MireTheme.label("ABOUT THIS RUN", MireTheme.TITLE, MireTheme.AMBER))
		for note: String in state_notes:
			card_column.add_child(MireTheme.paragraph(note))
		column.add_child(card)
	column.add_child(_recommendation_card())
	column.add_child(MireTheme.separator())
	column.add_child(MireTheme.label("EVERY SCENE, WORST FIRST", MireTheme.TITLE))
	column.add_child(_results_table())
	column.add_child(MireTheme.paragraph(
		"Full report saved to %s — paste it into a bug report if something here looks wrong."
		% String(_report.get("text_path", BenchmarkReport.REPORT_TEXT_PATH))))

	var buttons: HBoxContainer = MireTheme.row()
	var apply: Button = MireTheme.button("APPLY THESE SETTINGS", _apply,
		MireTheme.Variant.PRIMARY)
	apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(apply)
	var again: Button = MireTheme.button("RUN AGAIN", func() -> void:
		_discard_ledger()
		_show_intro())
	again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(again)
	column.add_child(buttons)
	column.add_child(MireTheme.link("BACK", _leave))

	_first_focus = apply
	MireTheme.wire_chain([apply, again])
	_panel_host.add_child(panel)
	apply.grab_focus()


func _recommendation_card() -> Control:
	var card: PanelContainer = MireTheme.card(_verdict_colour())
	var column: VBoxContainer = MireTheme.column()
	card.add_child(_margins(column))
	column.add_child(MireTheme.label(String(_recommendation.get("headline", "")),
		MireTheme.TITLE, _verdict_colour()))
	for reason: String in _recommendation.get("reasons", []):
		column.add_child(MireTheme.paragraph(reason))
	return card


func _verdict_colour() -> Color:
	match StringName(_recommendation.get("verdict", &"comfortable")):
		&"comfortable":
			return MireTheme.MOSS
		&"tight":
			return MireTheme.AMBER
		&"unmeasured":
			return MireTheme.MUTED
		_:
			return MireTheme.ERROR


## One row per scene, worst first, with the 1% low as both a number and a bar. The bar is scaled to
## the target rather than to the fastest scene: the question a player has is "does this reach what
## I asked for", and a bar normalised to the best scene answers a different one.
func _results_table() -> Control:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", MireTheme.GRID * 2)
	grid.add_theme_constant_override("v_separation", MireTheme.GRID)
	var target: float = float(_report.get("target_fps", SettingsAdvisor.DEFAULT_TARGET_FPS))
	for entry: Dictionary in SettingsAdvisor.ranked(_report.get("scenes", [])):
		var low1: float = float(entry.get("low1_fps", 0.0))
		var name_label: Label = MireTheme.label(String(entry.get("label", "?")), MireTheme.BODY)
		name_label.tooltip_text = String(entry.get("stresses", ""))
		grid.add_child(name_label)

		var bar := ProgressBar.new()
		bar.max_value = maxf(target * 2.0, low1)
		bar.value = low1
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(280.0 * MireTheme.ui_scale(), 8.0)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(bar)

		var colour: Color = MireTheme.MOSS if low1 >= target else MireTheme.ERROR
		grid.add_child(MireTheme.label("%.0f fps" % low1, MireTheme.BODY, colour))
	return grid


func _apply() -> void:
	var runner := BenchmarkRunner.new()
	add_child(runner)
	var applied: bool = runner.apply_recommendation(_recommendation)
	runner.queue_free()
	var message: String = "Graphics set to %s" % String(_recommendation.get("preset_name", "")) \
		if applied else "Could not apply — SettingsService is unavailable"
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null and stack.has_method(&"toast"):
		stack.call(&"toast", message, not applied)
	if applied:
		_leave()


func _discard_ledger() -> void:
	var report := BenchmarkReport.new()
	report.discard()


func _leave() -> void:
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null and stack.has_method(&"pop"):
		stack.call(&"pop")


# ── helpers ───────────────────────────────────────────────────────────────────────────────────


func _clear_panel() -> void:
	for child: Node in _panel_host.get_children():
		child.queue_free()


func _margins(inner: Control) -> MarginContainer:
	var margins := MarginContainer.new()
	var pad: int = MireTheme.GRID * 3
	for side: String in ["left", "right", "top", "bottom"]:
		margins.add_theme_constant_override("margin_%s" % side, pad)
	margins.add_child(inner)
	return margins
