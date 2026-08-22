extends Node

## SessionLog — autoload. The game records its own performance while it is played, so a session on a
## machine we cannot reach still produces something we can read afterwards.
##
## Sequoyah, before a co-op playtest with a friend: *"We can gather some good info from his game
## session as well, so maybe make the game log stuff that could be useful performance info, make the
## log easily accessible for him to send to me after the session"*.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): **none, and deliberately so.** Every peer logs its
## OWN machine and nothing is ever sent on the wire. Performance is a local fact — the whole point is
## the friend's M1 Air, and a host-authoritative version would record the host's frame rate and miss
## the machine that matters. Two players produce two logs.
##
## ── Why a TIME SERIES and not a summary ──────────────────────────────────────────────────────────
##
## The target machine is fanless, so it thermally throttles after five to ten minutes of sustained
## load. A session average smears that into one meaningless figure; a row per minute makes it visible
## as a shape. **"Held 60 for eight minutes, settled to 41 after twelve" is the finding, and no
## aggregate can express it.** This is the single decision the rest of the file follows from.
##
## ── Why rows are stamped with events ─────────────────────────────────────────────────────────────
##
## A bad minute nobody can explain is not a finding. "The 1% low halved when the night wave spawned"
## is. Every row carries what happened during it, taken from the `EventBus` signals that already
## exist, so a dip has a cause beside it instead of needing one reconstructed from memory.
##
## ── Why it costs nothing ─────────────────────────────────────────────────────────────────────────
##
## A telemetry system that slows the machine it measures is worse than none, and this one runs for a
## whole evening on the weakest hardware we ship to. So:
##
##   · Sampling is once a SECOND, not once a frame, off an accumulator on `_process` — no timer node,
##     no signal, no allocation per frame.
##   · The per-second sample writes into a preallocated `PackedFloat32Array` ring rather than
##     appending to a growing array, so a sixty-minute session allocates exactly as much as a
##     one-minute one.
##   · Nothing is formatted until the minute closes, and the file is touched only on flush.
##   · `tools/session_log_check.gd` asserts the per-sample cost rather than assuming it.

const PERF_FORMAT := preload("res://tools/perf_format.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const LOG_DIR: String = "user://session_logs"
const LOG_CHANNEL: StringName = &"session"

## One sample a second, sixty to a row. Both are deliberate: a second is slow enough to cost nothing
## and fast enough that sixty of them make a real 1% low, and a minute is the granularity a human
## reads a session at ("about ten minutes in it got worse").
const SAMPLE_INTERVAL_SEC: float = 1.0
const SAMPLES_PER_ROW: int = 60

## Written to disk on this cadence AND on exit. 30 s rather than per-row because the log's worst-case
## job is surviving a crash — if the game does fall over on his machine, this file is the single most
## valuable artefact of the evening, and losing the last minute of it to a hard kill would be the one
## failure this system cannot afford.
const FLUSH_INTERVAL_SEC: float = 30.0

## Frame times for the minute in progress, in milliseconds. Preallocated and overwritten in place.
var _frame_ms := PackedFloat32Array()
var _sample_count: int = 0
var _time_since_sample: float = 0.0
var _time_since_flush: float = 0.0
var _minute_index: int = 0

## Rows already closed, as finished Markdown table lines — formatted once, at the moment the minute
## closed, so a flush is a join and not a re-render of the whole session.
var _rows: PackedStringArray = PackedStringArray()
## What happened during the minute in progress. Cleared when the row closes.
var _events: PackedStringArray = PackedStringArray()

var _path: String = ""
var _header_written: bool = false
var _started_unix: int = 0
var _enabled: bool = true


func _ready() -> void:
	_frame_ms.resize(SAMPLES_PER_ROW)
	_started_unix = int(Time.get_unix_time_from_system())
	_path = "%s/session_%s.md" % [LOG_DIR, _timestamp_slug()]
	DirAccess.make_dir_recursive_absolute(LOG_DIR)
	_subscribe()
	# `_process` and not `_physics_process`: this measures the FRAME the player sees, and the physics
	# tick runs at a fixed rate that would report the same number whatever the renderer was doing.
	set_process(true)
	note("session started")


func _exit_tree() -> void:
	# The row in progress is closed on the way out rather than discarded — a session ended at 40 s
	# into a minute still has 40 samples worth reading, and throwing them away loses precisely the
	# last minute, which is the one most likely to contain whatever made them stop playing.
	_close_row()
	flush()
	_unsubscribe()


func _process(delta: float) -> void:
	if not _enabled:
		return
	_time_since_sample += delta
	if _time_since_sample >= SAMPLE_INTERVAL_SEC:
		_time_since_sample = 0.0
		_take_sample()
	_time_since_flush += delta
	if _time_since_flush >= FLUSH_INTERVAL_SEC:
		_time_since_flush = 0.0
		flush()


## One second's frame time, straight into the ring. Deliberately the cheapest thing in the file: one
## engine monitor read and one array write, no allocation, no branch on session state.
func _take_sample() -> void:
	if _sample_count < SAMPLES_PER_ROW:
		_frame_ms[_sample_count] = float(
			Performance.get_monitor(Performance.TIME_PROCESS)
		) * 1000.0
		_sample_count += 1
	if _sample_count >= SAMPLES_PER_ROW:
		_close_row()


## Turns the minute's samples into one Markdown row and clears the ring.
##
## The 1% LOW leads the median, per Sequoyah's standing rule — *"thats what you feel"*. With 60
## samples the 1% low is the single worst one, which is the honest reading at this sample count: it
## is the worst second of that minute, and calling it a percentile would imply a precision 60 samples
## do not carry.
func _close_row() -> void:
	if _sample_count <= 0:
		return
	var sorted := PackedFloat32Array()
	sorted.resize(_sample_count)
	for index: int in _sample_count:
		sorted[index] = _frame_ms[index]
	sorted.sort()
	# Sorted by frame TIME ascending, so the worst frame is last and the best is first.
	var median_ms: float = sorted[int(_sample_count / 2)]
	var worst_ms: float = sorted[_sample_count - 1]

	_rows.append("| %d | %s | %s | %d | %s | %d | %d | %d | %d | %s |" % [
		_minute_index,
		PERF_FORMAT.frame_cell(worst_ms),
		PERF_FORMAT.frame_cell(median_ms),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		_megabytes(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		_live_enemies(),
		_loaded_chunks(),
		" · ".join(_events) if not _events.is_empty() else "",
	])
	_minute_index += 1
	_sample_count = 0
	_events.clear()


## Appends whatever is not yet on disk. Rewrites the whole file rather than appending in place: the
## header carries a "session length so far" line that changes every flush, and a session log is a few
## kilobytes of text, so a rewrite costs less than the bookkeeping to avoid one.
func flush() -> void:
	if not _enabled:
		return
	var file: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		# Never an error: a machine that cannot write to user:// is a machine where the player should
		# still get to play. The log is diagnostics, not gameplay, and it fails silent-but-warned.
		MireLog.warn(LOG_CHANNEL, "cannot write session log to %s" % _path)
		return
	file.store_string(_render())
	file.close()


## The whole document. Header block first, because without the machine and the graphics preset the
## numbers below are uninterpretable — the same 41 fps is a catastrophe on `high` and expected on a
## fanless laptop at `low`.
func _render() -> String:
	var lines := PackedStringArray()
	lines.append("# MIRE session log")
	lines.append("")
	lines.append("Started %s · %d minute(s) recorded" % [
		Time.get_datetime_string_from_unix_time(_started_unix, true), _rows.size()
	])
	lines.append("")
	lines.append("## Machine")
	lines.append("")
	var machine: Dictionary = machine_header()
	for key: String in machine:
		lines.append("- **%s:** %s" % [key, machine[key]])
	lines.append("")
	lines.append("## Per-minute performance")
	lines.append("")
	lines.append("**1% low leads the median on purpose — the worst second of each minute is what a")
	lines.append("player actually feels.** A steady median with a collapsing 1% low is a stutter, not")
	lines.append("a slowdown, and the two want different fixes.")
	lines.append("")
	lines.append("| min | 1% low | median | draws | VRAM | nodes | bodies | enemies | chunks | what happened |")
	lines.append("|---:|---|---|---:|---|---:|---:|---:|---:|---|")
	if _rows.is_empty():
		lines.append("| — | — | — | — | — | — | — | — | — | no full minute recorded yet |")
	else:
		lines.append_array(_rows)
	lines.append("")
	lines.append("Static memory at last flush: %s." % _megabytes(
		Performance.get_monitor(Performance.MEMORY_STATIC)
	))
	lines.append("")
	return "\n".join(lines) + "\n"


## Machine and settings, as a Dictionary so a tool can read it as data rather than parsing the
## Markdown. Public because `tools/` and any other instrument wants the identical block — one
## definition, so two reports of the same machine cannot disagree.
func machine_header() -> Dictionary:
	var quality: Node = get_node_or_null(^"/root/GraphicsQuality")
	var preset_name: String = "unknown"
	if quality != null:
		var preset: int = int(quality.get(&"preset"))
		preset_name = ["low", "medium", "high"][preset] if preset >= 0 and preset < 3 else str(preset)
	return {
		"OS": "%s %s" % [OS.get_name(), OS.get_version()],
		"CPU": "%s (%d cores)" % [OS.get_processor_name(), OS.get_processor_count()],
		# Never blank. A headless process has no video adapter and returns "", and an empty field in
		# a report reads as "we forgot to record this" rather than "there was nothing to record" —
		# which are different facts and only one of them is a bug.
		"GPU": _or_unavailable(RenderingServer.get_video_adapter_name()),
		"GPU driver": _or_unavailable(RenderingServer.get_video_adapter_api_version()),
		"Renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")),
		"Graphics preset": preset_name,
		"Window": "%s @ %d Hz max" % [
			str(DisplayServer.window_get_size()), int(Engine.max_fps)
		],
		"Build": "debug" if OS.is_debug_build() else "release",
	}


## Stamp the minute in progress with something that happened. Public: any system with a fact worth
## correlating against a frame rate can call it, and the cost is one string append per event.
func note(what: String) -> void:
	if not _enabled or what.is_empty():
		return
	if not _events.has(what):
		_events.append(what)


## Where the log lives, for the UI that opens it.
func log_directory() -> String:
	return ProjectSettings.globalize_path(LOG_DIR)


func log_path() -> String:
	return ProjectSettings.globalize_path(_path)


## Opens the folder in the platform's file browser. This is the half of "easily accessible" that
## gets skipped: a non-technical player will never find
## `~/Library/Application Support/Godot/app_userdata/MIRE/session_logs/` over voice chat, and a log
## nobody can retrieve is the same as no log. Flushes first, so what they see is current.
func open_log_folder() -> void:
	flush()
	DirAccess.make_dir_recursive_absolute(LOG_DIR)
	OS.shell_open(log_directory())


## Test seam: `tools/session_log_check.gd` drives sampling deterministically rather than waiting out
## real seconds, and a headless probe that does not want a file on disk turns it off.
func set_enabled(value: bool) -> void:
	_enabled = value


func sample_now() -> void:
	_take_sample()


## Test seam: push a KNOWN frame time. `tools/session_log_check.gd` uses it to assert that a row
## derives its 1% low from the worst second and its median from the middle one — which cannot be
## checked against live frame times, because a headless process runs far under
## `PerfFormat.MIN_MEASURABLE_MS` and every cell reads "—". Asserting the derivation on known input
## is the stronger test anyway: it fails if the two are ever swapped, which is the mistake that would
## produce a plausible, wrong, permanently misleading report.
func sample_frame_ms(frame_ms: float) -> void:
	if _sample_count < SAMPLES_PER_ROW:
		_frame_ms[_sample_count] = frame_ms
		_sample_count += 1
	if _sample_count >= SAMPLES_PER_ROW:
		_close_row()


func rows_recorded() -> int:
	return _rows.size()


## Test seam. `tools/session_log_check.gd` measures the per-sample cost by driving 20,000 samples
## through the real path, which necessarily closes ~333 rows — an honest measurement that leaves a
## dishonest artefact, since the document it writes afterwards would be 300 rows of "—" and unusable
## as an example of what a player actually sends. Clearing the accumulated rows after the timing
## keeps both halves true. Never called by the game.
func clear_rows_for_check() -> void:
	_rows.clear()
	_events.clear()
	_sample_count = 0
	_minute_index = 0


# ── Events ───────────────────────────────────────────────────────────────────────────────────────


func _subscribe() -> void:
	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.subscribe_boss_engaged(_on_boss_engaged)
	EVENT_BUS.subscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.subscribe_run_wiped(_on_run_wiped)
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if health != null and health.has_signal(&"player_downed"):
		health.connect(&"player_downed", _on_player_downed)
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night != null and day_night.has_signal(&"night_started"):
		day_night.connect(&"night_started", _on_night_started)


func _unsubscribe() -> void:
	EVENT_BUS.unsubscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.unsubscribe_boss_engaged(_on_boss_engaged)
	EVENT_BUS.unsubscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.unsubscribe_run_wiped(_on_run_wiped)


func _on_cycle_advanced(cycle: int) -> void:
	note("Cycle %d began" % cycle)


func _on_wellspring_capped(_name: StringName, _position: Vector3) -> void:
	note("Wellspring capped")


func _on_boss_engaged(boss_id: StringName, _position: Vector3) -> void:
	note("boss engaged (%s)" % boss_id)


func _on_run_extracted(_cycle: int, _position: Vector3) -> void:
	note("extraction")


func _on_run_wiped(_cycle: int, _position: Vector3) -> void:
	note("party wiped")


func _on_player_downed(peer_id: int) -> void:
	note("player %d went down" % peer_id)


func _on_night_started() -> void:
	note("night fell")


# ── Small shared helpers ─────────────────────────────────────────────────────────────────────────


func _live_enemies() -> int:
	var enemy_world: Node = get_node_or_null(^"/root/EnemyWorld")
	return 0 if enemy_world == null else int(enemy_world.call(&"live_count"))


func _loaded_chunks() -> int:
	var scene: Node = get_tree().current_scene if get_tree() != null else null
	if scene == null:
		return 0
	var field: Node = scene.get_node_or_null(^"ResourceScatterField")
	return 0 if field == null else int(field.call(&"chunk_count"))


func _or_unavailable(value: String) -> String:
	return "unavailable (headless)" if value.strip_edges().is_empty() else value


func _megabytes(bytes: float) -> String:
	return "%.0f MB" % (bytes / 1048576.0)


## Filesystem-safe and sortable, so a folder of sessions reads in order.
func _timestamp_slug() -> String:
	var stamp: Dictionary = Time.get_datetime_dict_from_unix_time(_started_unix)
	return "%04d%02d%02d_%02d%02d%02d" % [
		stamp["year"], stamp["month"], stamp["day"],
		stamp["hour"], stamp["minute"], stamp["second"],
	]
