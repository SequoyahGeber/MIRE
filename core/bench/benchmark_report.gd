extends RefCounted

## Where a benchmark run's results live while it is still running, and after it finishes.
##
## ## Why there is a ledger at all
##
## A benchmark is a list-processing run that takes minutes, and AGENTS.md's rule for those is
## absolute: anything held in memory until the end is a total loss the moment the run is stopped —
## and benchmark runs get stopped, by an alt-F4, a crash on the exact hardware least able to
## survive the night scene, or a player who changed their mind. So each scene's result is appended
## to `user://benchmark/ledger.jsonl` the instant that scene finishes, one JSON object per line,
## flushed. A run interrupted after six of nine scenes resumes having lost only the scene that was
## in flight.
##
## The ledger is keyed by a SIGNATURE — the machine, the resolution, the graphics settings and the
## suite the results were taken under. Resume is only ever offered when the signature still
## matches; change a setting, plug in a monitor, or edit the suite, and the old ledger is
## discarded rather than mixed with new numbers. Half a benchmark from before you changed the
## preset is not half a benchmark.
##
## ## Two artefacts at the end
##
## `report.json` is the machine-readable record — every scene, every statistic, the machine, the
## settings, and the recommendation. `report.txt` is the same thing as a table a player can paste
## into a bug report or a forum thread, which is most of why anyone runs a benchmark that is not
## about their own settings.
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row). Local files only.

const DIR: String = "user://benchmark"
const LEDGER_PATH: String = "user://benchmark/ledger.jsonl"
const REPORT_JSON_PATH: String = "user://benchmark/report.json"
const REPORT_TEXT_PATH: String = "user://benchmark/report.txt"

## Bumped whenever the suite or a statistic's definition changes, so a ledger written by an older
## build can never be resumed into a newer one and reported as though the two halves were
## comparable.
const FORMAT_VERSION: int = 1

var ledger_path: String = LEDGER_PATH
var report_json_path: String = REPORT_JSON_PATH
var report_text_path: String = REPORT_TEXT_PATH

var _signature: String = ""
var _file: FileAccess = null


## Opens the ledger for a run with this signature. Returns the scene results already recorded under
## the same signature — an empty array for a fresh run, and the completed prefix for a resumed one.
func begin(signature: String) -> Array:
	_signature = signature
	DirAccess.make_dir_recursive_absolute(DIR)
	var existing: Array = _read_matching(signature)
	if existing.is_empty():
		# Either nothing to resume or a ledger for different conditions. Truncate and re-stamp:
		# appending a new signature's rows after an old signature's would leave a file whose
		# meaning depends on where you start reading.
		_file = FileAccess.open(ledger_path, FileAccess.WRITE)
		if _file != null:
			_file.store_line(JSON.stringify({
				"kind": "header", "signature": signature, "format": FORMAT_VERSION,
			}))
			_file.flush()
	else:
		_file = FileAccess.open(ledger_path, FileAccess.READ_WRITE)
		if _file != null:
			_file.seek_end()
	return existing


## Appends one scene's result and flushes it. Called the moment a scene finishes sampling, never
## batched — see the header.
func append_scene(result: Dictionary) -> void:
	if _file == null:
		return
	var row: Dictionary = result.duplicate()
	row["kind"] = "scene"
	_file.store_line(JSON.stringify(row))
	_file.flush()


func close() -> void:
	if _file != null:
		_file.close()
		_file = null


## Discards any partial run. Used when the player restarts a benchmark from the beginning rather
## than resuming one.
func discard() -> void:
	close()
	if FileAccess.file_exists(ledger_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ledger_path))


## Scene rows already in the ledger, if and only if its header signature matches. A torn final line
## — what a hard kill mid-write leaves behind — is dropped, not parsed: `JSON.parse_string` returns
## null on it and the row is skipped, so one truncated line cannot poison a resume.
func _read_matching(signature: String) -> Array:
	if not FileAccess.file_exists(ledger_path):
		return []
	var file: FileAccess = FileAccess.open(ledger_path, FileAccess.READ)
	if file == null:
		return []
	var rows: Array = []
	var header_ok: bool = false
	while not file.eof_reached():
		var line: String = file.get_line()
		if line.strip_edges().is_empty():
			continue
		# `JSON.new().parse()` rather than `JSON.parse_string()`: the torn final line a hard kill
		# leaves behind is EXPECTED here, and the static helper pushes an engine error for it —
		# which would print a scary "Unterminated string" every time a resume worked correctly.
		var json := JSON.new()
		if json.parse(line) != OK or typeof(json.data) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = json.data
		match String(row.get("kind", "")):
			"header":
				header_ok = String(row.get("signature", "")) == signature \
					and int(row.get("format", 0)) == FORMAT_VERSION
				if not header_ok:
					file.close()
					return []
			"scene":
				if header_ok:
					rows.append(row)
	file.close()
	return rows


## What must be identical for two halves of a run to belong to the same benchmark. Deliberately
## includes the window size and the whole graphics-relevant settings set: the same machine at a
## different resolution is a different measurement.
static func signature_for(machine: Dictionary, settings: Dictionary, viewport: Vector2i) -> String:
	return "%s|%s|%dx%d|p%d|aa%d|dyn%d|ssao%d|v%d" % [
		String(machine.get("adapter_name", "?")), OS.get_name(), viewport.x, viewport.y,
		int(settings.get("graphics_preset", -1)), int(settings.get("anti_aliasing", -1)),
		int(settings.get("dynamic_resolution", false)), int(settings.get("ssao_override", -1)),
		FORMAT_VERSION,
	]


## Writes both end-of-run artefacts. Returns the path of the human-readable one, which is what the
## screen shows the player so they can find it.
func write_report(report: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var json_file: FileAccess = FileAccess.open(report_json_path, FileAccess.WRITE)
	if json_file != null:
		json_file.store_string(JSON.stringify(report, "  "))
		json_file.close()
	var text_file: FileAccess = FileAccess.open(report_text_path, FileAccess.WRITE)
	if text_file != null:
		text_file.store_string(format_text(report))
		text_file.close()
	return ProjectSettings.globalize_path(report_text_path)


## The pasteable table. Kept as a static so `tools/benchmark_check.gd` can render a synthetic
## report without writing a file.
## Cores as the machine actually has them: Apple Silicon's performance/efficiency split predicts
## main-thread behaviour — the streamer, the nav bake, the Mire tick — in a way one total cannot.
static func _core_summary(machine: Dictionary) -> String:
	if machine.has("cpu_performance_cores"):
		return "%d thread(s) (%dP + %dE)" % [int(machine.get("cpu_threads", 0)),
			int(machine.get("cpu_performance_cores", 0)),
			int(machine.get("cpu_efficiency_cores", 0))]
	return "%d thread(s)" % int(machine.get("cpu_threads", 0))


static func format_text(report: Dictionary) -> String:
	var machine: Dictionary = report.get("machine", {})
	var recommendation: Dictionary = report.get("recommendation", {})
	var lines: PackedStringArray = []
	lines.append("MIRE benchmark")
	lines.append("%s%s | %s | %s" % [
		String(machine.get("adapter_name", "?")),
		(" (%d GPU cores)" % int(machine["gpu_cores"])) if machine.has("gpu_cores") else "",
		String(machine.get("os", "?")), String(machine.get("cpu", "?"))])
	lines.append("%s | %s | %s | %s" % [
		String(report.get("viewport", "?")), _core_summary(machine),
		String(report.get("settings_summary", "?")), String(report.get("date", ""))])
	# The machine's CONDITION, on its own line and above the table, because a reader who skips it
	# will quote a throttled laptop's numbers as that laptop's numbers.
	lines.append("state: %s" % String(report.get("power_summary", "unknown")))
	var notes: Array = report.get("state_notes", [])
	if not notes.is_empty():
		lines.append("")
		for note: String in notes:
			lines.append("  ! %s" % note)
	lines.append("")
	lines.append("  %-16s %9s %9s %9s %8s" % ["scene", "1% low", "median", "fps", "draws"])
	for entry: Dictionary in report.get("scenes", []):
		if int(entry.get("frames", 0)) <= 0:
			lines.append("  %-16s %9s   (not measured)" % [String(entry.get("label", "?")), "-"])
			continue
		lines.append("  %-16s %6.0f fps %6.2f ms %6.0f fps %8.0f" % [
			String(entry.get("label", "?")), float(entry.get("low1_fps", 0.0)),
			float(entry.get("median_ms", 0.0)), float(entry.get("fps", 0.0)),
			float(entry.get("draws", 0.0))])
	lines.append("")
	for candidate_key: String in report.get("calibration", {}).keys():
		lines.append("  %s at preset %s: %.0f fps (1%% low)" % [
			String(report.get("calibration_scene", "worst scene")), candidate_key,
			float((report["calibration"] as Dictionary)[candidate_key])])
	lines.append("")
	lines.append("Recommended: %s" % String(recommendation.get("headline", "?")))
	for reason: String in recommendation.get("reasons", []):
		lines.append("  - %s" % reason)
	return "\n".join(lines) + "\n"
