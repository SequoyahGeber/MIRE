extends SceneTree

## F-608 — the session log records a readable time series, survives a crash, and costs nothing.
##
##   .agent/bin/agent godot --script tools/session_log_check.gd
##
## Three things worth asserting, and one of them is the reason this file exists rather than a manual
## eyeball:
##
##   1. **The document is readable and correctly shaped.** A header naming the machine and the
##      graphics preset (without which every number below it is uninterpretable), and one table row
##      per minute with the 1% low ahead of the median.
##   2. **A minute's row is derived correctly from its samples** — specifically that the 1% low is
##      the WORST second and the median is the middle one, and not the other way round. Getting
##      those two the wrong way around would produce a plausible, wrong, and permanently misleading
##      report.
##   3. **The per-sample cost is measured, not assumed.** This is the assertion the whole design
##      rests on: telemetry that measurably slows the machine it measures is worse than none, and
##      this runs for a whole evening on the weakest hardware we ship to.
##
## Drives the registered autoload (F-068/F-069) rather than a fresh instance, so what is measured is
## the thing that will actually run.

## Samples to time when measuring cost. Large enough that the total is well clear of timer
## granularity, so the per-sample figure is not an artefact of the clock.
const COST_SAMPLE_COUNT: int = 20000

## The budget, as a share of one frame at 60 fps (16.67 ms). A sample happens once a SECOND, so its
## real cost is this divided by sixty — but asserting against a frame is the honest comparison,
## because a frame is the thing it could damage. 1% of a frame is already a hundred times more
## headroom than this needs.
const COST_BUDGET_FRACTION: float = 0.01

var failures: int = 0
var session_log: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	session_log = root.get_node_or_null(^"SessionLog")
	check(session_log != null, "SessionLog is registered as an autoload")
	if session_log == null:
		_finish()
		return

	_check_machine_header()
	_check_row_derivation()
	_check_document_shape()
	_check_events_are_attributed()
	_check_sample_cost()

	print("\nSESSION_LOG_CHECK failures=%d" % failures)
	_finish()


## Without the machine and the preset, the table underneath is uninterpretable: the same 41 fps is a
## catastrophe on `high` and expected on a fanless laptop at `low`.
func _check_machine_header() -> void:
	print("\n== the header identifies the machine and the settings ==")
	var header: Dictionary = session_log.call(&"machine_header")
	for key: String in ["OS", "CPU", "GPU", "Renderer", "Graphics preset", "Build"]:
		check(header.has(key) and not String(header[key]).strip_edges().is_empty(),
			"header names %s (%s)" % [key, header.get(key, "MISSING")])
	check(String(header.get("Graphics preset", "")) in ["low", "medium", "high"],
		"the graphics preset is one of the three real presets (%s)" % header.get("Graphics preset"))


## The assertion that matters most for correctness. Feeds known frame times and requires the row to
## report the WORST second as the 1% low and the MIDDLE one as the median — swapping them would
## produce a report that looks right and says the opposite of the truth.
func _check_row_derivation() -> void:
	print("\n== a row reports the worst second as the 1% low, not the best ==")
	session_log.call(&"set_enabled", true)
	var before: int = int(session_log.call(&"rows_recorded"))
	# KNOWN frame times, not live ones. A headless process runs far under PerfFormat's
	# MIN_MEASURABLE_MS, so every real sample renders as "—" and the ordering could not be read at
	# all. Feeding a known distribution is also the stronger test: 59 comfortable frames and one bad
	# one is exactly the shape this table exists to expose — a healthy median hiding a stutter.
	for _index: int in 59:
		session_log.call(&"sample_frame_ms", 16.0)   # 62.5 fps
	session_log.call(&"sample_frame_ms", 50.0)       # 20 fps — the worst second of the minute
	var after: int = int(session_log.call(&"rows_recorded"))
	check(after == before + 1, "sixty samples close exactly one row (%d -> %d)" % [before, after])

	session_log.call(&"flush")
	var document: String = _read_log()
	check(document.contains("| 1% low | median |"),
		"the table puts the 1% low BEFORE the median — Sequoyah's 'thats what you feel'")
	var row: String = _last_data_row(document)
	check(row != "", "a data row was written")
	if row == "":
		return
	var cells: PackedStringArray = row.split("|", false)
	if cells.size() < 3:
		check(false, "row has the expected columns (got %d)" % cells.size())
		return
	var low_fps: float = _leading_number(cells[1])
	var median_fps: float = _leading_number(cells[2])
	check(low_fps > 0.0 and median_fps > 0.0,
		"both figures parse as fps (1%% low %.0f, median %.0f)" % [low_fps, median_fps])
	# The worst second is the SLOWEST, so as an fps figure it is the SMALLER of the two. Against the
	# known input above: the 1% low must be the 50 ms frame (20 fps) and the median a 16 ms one
	# (62 fps). Asserting the VALUES and not merely their order is what catches a swap.
	check(is_equal_approx(low_fps, 20.0),
		"the 1%% low is the worst second — 20 fps from the 50 ms frame (got %.0f)" % low_fps)
	check(is_equal_approx(median_fps, 62.0) or is_equal_approx(median_fps, 63.0),
		"the median is a typical second — ~62 fps from the 16 ms frames (got %.0f)" % median_fps)
	check(low_fps < median_fps,
		"a healthy median (%.0f fps) can hide a bad second (%.0f fps), which is the whole point"
			% [median_fps, low_fps])


func _check_document_shape() -> void:
	print("\n== the document is something a non-technical player can paste into a message ==")
	session_log.call(&"flush")
	var document: String = _read_log()
	check(document.begins_with("# MIRE session log"), "it opens as Markdown with a title")
	check(document.contains("## Machine"), "it has a Machine section")
	check(document.contains("## Per-minute performance"), "it has the per-minute table")
	check(document.contains("Static memory at last flush"), "it records static memory")
	check(not document.contains("ms)\n"), "milliseconds never stand alone as the primary figure")
	var directory: String = String(session_log.call(&"log_directory"))
	check(directory.contains("session_logs"),
		"the folder the UI opens is the folder the log is in (%s)" % directory)
	check(FileAccess.file_exists(String(session_log.call(&"log_path"))),
		"the log file exists on disk before the session ends — a crash keeps what it has")


## A bad minute nobody can explain is not a finding. This asserts the mechanism that attributes one.
func _check_events_are_attributed() -> void:
	print("\n== a row carries what happened during it ==")
	session_log.call(&"note", "night fell")
	session_log.call(&"note", "night fell")
	session_log.call(&"note", "Cycle 2 began")
	for _index: int in 60:
		session_log.call(&"sample_frame_ms", 16.0)
	session_log.call(&"flush")
	var row: String = _last_data_row(_read_log())
	check(row.contains("night fell"), "the row names the event")
	check(row.contains("Cycle 2 began"), "and a second, different event")
	check(row.count("night fell") == 1,
		"a repeated event is recorded once, not once per emission")


## The assertion the design rests on. Measured, not assumed.
func _check_sample_cost() -> void:
	print("\n== sampling costs nothing measurable ==")
	# Warm first: the first call resolves nothing lazily today, but timing a cold path would measure
	# whatever the engine happened to do on first touch rather than the steady-state cost.
	for _warm: int in 200:
		session_log.call(&"sample_now")

	var started_us: int = Time.get_ticks_usec()
	for _index: int in COST_SAMPLE_COUNT:
		session_log.call(&"sample_now")
	var elapsed_us: int = Time.get_ticks_usec() - started_us
	var per_sample_ms: float = (float(elapsed_us) / float(COST_SAMPLE_COUNT)) / 1000.0
	var frame_ms: float = 1000.0 / 60.0
	var share: float = per_sample_ms / frame_ms

	# Reported the way F-592 requires: a percentage of the frame it was taken against, never a bare
	# millisecond. The `.call()` indirection this loop uses is itself slower than the direct
	# `_process` path in the real game, so this figure is a ceiling and not an estimate.
	print("  one sample costs %.4f%% of a 60 fps frame (%.5f ms, measured over %d samples via .call())"
		% [share * 100.0, per_sample_ms, COST_SAMPLE_COUNT])
	check(share < COST_BUDGET_FRACTION,
		"a sample costs under %.0f%% of a frame, and happens once a SECOND" % (COST_BUDGET_FRACTION * 100.0))

	# 20,000 samples closed ~333 rows of unmeasurable headless frames. The measurement is honest and
	# the artefact it leaves is not: a 300-row document of "—" is useless as an example of what a
	# player actually sends. Clear and re-flush, then assert the file is readable again — the log's
	# whole purpose is being pasted into a message, so the check has to leave one that could be.
	session_log.call(&"clear_rows_for_check")
	session_log.call(&"note", "night fell")
	for _index: int in 59:
		session_log.call(&"sample_frame_ms", 16.0)
	# The stutter last, so the example shows the shape this table exists to expose: a comfortable
	# median with one bad second under it, attributed to the thing that caused it.
	session_log.call(&"sample_frame_ms", 38.0)
	session_log.call(&"flush")
	var document: String = _read_log()
	check(document.count("| — fps") == 0 and not document.contains("—      fps"),
		"the log left on disk contains no unmeasurable rows — it is a readable example")
	print("\n  example row as a player would send it:")
	print("  %s" % _last_data_row(document))


# ── Shared ───────────────────────────────────────────────────────────────────────────────────────


func _read_log() -> String:
	var path: String = String(session_log.call(&"log_path"))
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()


## The last line that is a table row of DATA rather than the header or the separator.
func _last_data_row(document: String) -> String:
	var found: String = ""
	for line: String in document.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with("|") or trimmed.begins_with("|---") or trimmed.contains("1% low"):
			continue
		found = trimmed
	return found


func _leading_number(cell: String) -> float:
	return float(cell.strip_edges().split(" ", false)[0])


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	quit(0 if failures == 0 else 1)
