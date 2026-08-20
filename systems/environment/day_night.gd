extends Node

## DayNight — autoload. HOST-authoritative time_of_day, replicated to clients and applied to the
## level's sky every tick.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Day/night, wave director, Cycle state, active
## modifiers" row): HOST. The host advances time_of_day every physics tick and pushes it to clients
## at ~1 Hz over an unreliable RPC (docs/SPECS.md 2.11 names this or a code-built synchronizer as
## interchangeable — an RPC push needs no per-entity node for a single scalar, so that's what this
## file does). A client only ever lerps between the last two host snapshots; it NEVER runs its own
## clock. Sky rendering itself stays client-local (world/environment/playtest_atmosphere.gd) — this
## autoload's whole job is pushing the one number that drives it. Offline (no session) this process
## is host-of-one and runs the exact same advance path.
##
## THE TRAP THIS FILE EXISTS TO AVOID (docs/SPECS.md 2.11): playtest_atmosphere.gd's own
## `cycle_enabled` free-runs a LOCAL clock per peer from its own boot time — divergent time-of-day
## with no error and nothing on the wire to catch it. It must stay false forever. This autoload
## calls `set_time_of_day()` on it every tick instead; nothing here ever sets `cycle_enabled = true`.
##
## time_of_day is a 0..1 fraction of one full day (0 = midnight, 0.25 = dawn, 0.5 = noon, 0.75 =
## dusk), independent of playtest_atmosphere.gd's own 0..24 hour export — _apply_to_level() is the
## one place that converts between the two.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const REPLICATE_INTERVAL_SEC: float = 1.0

## Fraction of a day. 0.348 matches Atmosphere's own 8.35h default (8.35 / 24.0).
@export_range(0.0, 1.0, 0.0001) var time_of_day: float = 0.348
## Mirrors world/environment/playtest_atmosphere.gd's day_length_seconds default (900s). Not a
## second source of truth in practice: _resolve_day_length() overwrites it from the level's own
## Atmosphere node export the moment one is found, so this value only matters before a level with an
## Atmosphere node has loaded (harnesses, main menu).
##
## Task 3.14 made this a gamerule (`day_length_seconds`). It is the ONE first-wave knob with a
## pre-existing competing source, so the precedence is explicit and recorded as D-085: a rule
## somebody actually set beats the level's Atmosphere; a rule still sitting at its authored default
## defers to it, exactly as before. `_resolve_day_length()` is the single place that decides.
@export_range(60.0, 3600.0, 1.0) var day_length_seconds: float = 900.0
## Fires once per crossing, HOST ONLY — consumers are host-side systems (2.12's WaveSpawner).
@export_range(0.0, 1.0, 0.001) var night_started_at: float = 0.75
## Fires once per crossing, HOST ONLY.
@export_range(0.0, 1.0, 0.001) var day_started_at: float = 0.25

signal night_started()
signal day_started()

var _replicate_elapsed: float = 0.0
## Per-tick node lookups cached (F-099): the level's Atmosphere is re-resolved only when the current
## scene changes (or the node is freed), and the transport autoload once it exists. Both were being
## re-found by path every physics tick.
var _atmosphere: Node
var _atmosphere_scene: Node
var _transport_node: Node
var _rule_service: Node
# Client-side interpolation source: the last two host snapshots, and how long ago the second one
# arrived. Nothing here ever advances on its own — see _advance_client().
var _client_prev_time: float = 0.0
var _client_target_time: float = 0.0
var _client_since_update: float = 0.0
var _has_client_snapshot: bool = false
## F-278: the value a run STARTS at, captured from the export before anything has moved the clock,
## so retuning `time_of_day`'s authored default retunes the restart with it rather than leaving a
## second copy of 0.348 to drift out of sync.
var _run_start_time_of_day: float = 0.348


func _ready() -> void:
	_run_start_time_of_day = time_of_day
	set_physics_process(true)
	_apply_to_level(time_of_day)
	_register_commands()
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)



# ── Simulation (§5a: physics tick, delta-scaled, never a frame count) ────────────────────────────


func _physics_process(delta: float) -> void:
	if _owns_mutation():
		_advance_host(delta)
	else:
		_advance_client(delta)


## Cycle Modifier `long_night` (F-245, content/cycle_modifiers/long_night.tres: "nights last twice as
## long"). Rather than a second day-length knob, this halves how much of `delta` counts toward
## `time_of_day` while the clock currently sits in the night phase, so the day half of the cycle is
## untouched and only the night half stretches to roughly double its real-time length.
const LONG_NIGHT_RATE_MULTIPLIER: float = 0.5


func _advance_host(delta: float) -> void:
	var day_length: float = _resolve_day_length()
	var previous: float = time_of_day
	var effective_delta: float = delta
	if _is_night(previous) and _has_modifier(&"long_night"):
		effective_delta *= LONG_NIGHT_RATE_MULTIPLIER
	time_of_day = fposmod(time_of_day + effective_delta / day_length, 1.0)
	_check_thresholds(previous, time_of_day)
	_apply_to_level(time_of_day)

	_replicate_elapsed += delta
	while _replicate_elapsed >= REPLICATE_INTERVAL_SEC:
		_replicate_elapsed -= REPLICATE_INTERVAL_SEC
		if bool(_transport_call(&"is_active")):
			net_push_time.rpc(time_of_day)


## Never advances time on its own — only lerps toward the most recent host snapshot, and holds flat
## at it once _client_since_update passes REPLICATE_INTERVAL_SEC. If the host stops sending (a stall,
## not a disconnect — a real disconnect makes this process its own host-of-one via _owns_mutation()),
## the displayed time freezes here instead of free-running, which is exactly what day_night_net_check
## proves by pausing the host's own processing rather than the connection.
func _advance_client(delta: float) -> void:
	if not _has_client_snapshot:
		return
	_client_since_update += delta
	var weight: float = clampf(_client_since_update / REPLICATE_INTERVAL_SEC, 0.0, 1.0)
	time_of_day = _lerp_wrapped_unit(_client_prev_time, _client_target_time, weight)
	_apply_to_level(time_of_day)


## Test/host-only manual step — identical math to the host branch of _physics_process, exposed so a
## harness can drive many in-game days in a fraction of a real second instead of waiting on the wall
## clock. No-ops for a peer that does not own mutation, same guard as the real tick.
func host_advance(delta: float) -> void:
	if not _owns_mutation():
		return
	_advance_host(delta)


# ── Run lifecycle (F-278 / F-281 item 3) ─────────────────────────────────────────────────────────


## `time_of_day` is RUN-scoped state, and D-149's enumeration of what a restart resets did not name
## it — so `CycleService.host_restart_run()` zeroed `_days_elapsed` while the clock kept running from
## wherever the ended run stopped. Since a run almost always ends at night, the next run began mid-
## night: the day COUNT and the clock disagreed from the first frame, the new run's first "day" was a
## partial one, and WaveSpawner never got a fresh `night_started` edge because that crossing had
## already happened during the PREVIOUS run (F-259 cleared the latch, but clearing a latch cannot
## re-fire a signal). Resetting to the run-start morning puts the 0.75 crossing back in front of the
## clock, so the edge arrives on its own the way it does in a first run.
##
## Unconditional on authority, like every other `run_restarted` subscriber in this codebase — but the
## two peer roles reset different fields, and both halves matter:
##
##   · HOST — the authoritative clock itself, plus `_replicate_elapsed` armed at a full interval so
##     the reset reaches clients on the NEXT tick instead of up to a second later. No new RPC: this
##     rides `net_push_time`, DayNight's existing authority path, exactly as the finding asks.
##   · CLIENT — its interpolation source, snapped to the same value. This is the half that is easy to
##     miss. A client's `_advance_client()` lerps `_client_prev_time` -> `_client_target_time` through
##     `_lerp_wrapped_unit()`, which always takes the SHORTEST way round; left alone, the host's
##     backwards jump from ~0.80 to 0.348 would be served to the player as a full second of the sun
##     visibly running BACKWARDS through dusk and afternoon before settling. Setting prev and target
##     both to the reset value makes the lerp flat until the host's next snapshot lands, and that
##     snapshot then interpolates forward from 0.348 like any other.
##
## Deliberately NOT `host_set_time()`, even though that is the seam for jumping the clock: it crosses
## thresholds on the way, and `day_started_at` (0.25) sits between the typical night-time end of a run
## and 0.348. `CycleService._on_day_started()` would take the reset as a full elapsed day and set
## `_days_elapsed` to 1 the instant after `host_restart_run()` set it to 0 — the same clock/count
## disagreement this fix exists to remove, merely inverted. A run BEGINS at morning; it does not cross
## into it.
func _on_run_restarted() -> void:
	time_of_day = _run_start_time_of_day
	_replicate_elapsed = REPLICATE_INTERVAL_SEC
	_client_prev_time = _run_start_time_of_day
	_client_target_time = _run_start_time_of_day
	_client_since_update = 0.0
	_apply_to_level(time_of_day)


## The morning a run starts at — the authored `time_of_day` default, captured before the clock moved.
## Read by `tools/day_night_restart_check.gd` so the assertion and the reset cannot drift apart.
func run_start_time_of_day() -> float:
	return _run_start_time_of_day


func _resolve_day_length() -> float:
	_level_atmosphere()  # refreshes day_length_seconds whenever the level's Atmosphere is re-found
	var rules: Node = _rules()
	if rules != null and bool(rules.call("is_overridden", &"day_length_seconds")):
		return float(rules.call("value", &"day_length_seconds", day_length_seconds))
	return day_length_seconds


## COMMANDS.md §4.3's export-fallback seam. Path-resolved and cached (F-011/F-099) because this runs
## inside the per-tick advance; a null service simply means the export wins, which is the documented
## fallback rather than an error — a harness that never loaded content still ticks a normal day.
func _rules() -> Node:
	if _rule_service == null or not is_instance_valid(_rule_service):
		_rule_service = get_node_or_null(^"/root/RuleService")
	return _rule_service


## The cached Atmosphere for the current scene, or null. Re-resolves on scene change or a freed
## node; a scene with no Atmosphere is remembered as null so it costs nothing per tick (F-099).
func _level_atmosphere() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	if scene != _atmosphere_scene or (_atmosphere != null and not is_instance_valid(_atmosphere)):
		_atmosphere_scene = scene
		var found: Node = scene.get_node_or_null(^"Atmosphere")
		_atmosphere = found if found != null and found.has_method(&"set_time_of_day") else null
		if _atmosphere != null:
			var raw: Variant = _atmosphere.get(&"day_length_seconds")
			if (typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT) and float(raw) > 0.0:
				day_length_seconds = float(raw)
	return _atmosphere


func _check_thresholds(previous: float, current: float) -> void:
	if _crossed(previous, current, night_started_at):
		night_started.emit()
	if _crossed(previous, current, day_started_at):
		day_started.emit()


## True if advancing from previous to current (wrapping through 1.0 -> 0.0 if current < previous)
## passed over threshold. Half-open on the entry side so sitting exactly on a threshold for multiple
## ticks in a row (previous == threshold) does not re-fire.
func _crossed(previous: float, current: float, threshold: float) -> bool:
	if current >= previous:
		return previous < threshold and threshold <= current
	return previous < threshold or threshold <= current


## Shortest-path lerp around a period-1.0 wrap (0.99 -> 0.02 moves forward through 0.0, not backward
## through 0.5) — the fractional-day equivalent of Godot's own lerp_angle().
func _lerp_wrapped_unit(from: float, to: float, weight: float) -> float:
	var diff: float = fposmod(to - from + 0.5, 1.0) - 0.5
	return fposmod(from + diff * weight, 1.0)


## Every peer, host included, reaches the sky the same way: find the level's Atmosphere node and
## hand it the time. No Atmosphere (a harness, a menu, a level that doesn't have one) is a silent
## no-op, never an error. Atmosphere's own time_of_day is 0..24 hours; DayNight's is a 0..1 fraction
## of the day, so this is the one conversion point between the two.
func _apply_to_level(fraction_of_day: float) -> void:
	var atmosphere: Node = _level_atmosphere()
	if atmosphere == null:
		return
	atmosphere.call(&"set_time_of_day", fraction_of_day * 24.0)


func _is_night(fraction: float) -> bool:
	return fraction >= night_started_at or fraction < day_started_at


func _has_modifier(id: StringName) -> bool:
	var modifiers: Node = get_node_or_null(^"/root/CycleModifierService")
	return modifiers != null and bool(modifiers.call(&"has_modifier", id))


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


## Path-resolved (F-011 — harnesses install the transport at /root themselves), cached once found.
func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node


func _transport_call(method: StringName) -> Variant:
	var transport: Node = _transport()
	if transport == null:
		return false
	return transport.call(method)


# ── Replication (host -> clients, unreliable, ~1 Hz) ──────────────────────────────────────────────


## F-278. A snapshot this much of a day away from the last one is a JUMP, not a tick, and gets
## snapped to rather than interpolated toward. The bound is generous on both sides: the largest step
## a normally-advancing host can produce in one interval is `REPLICATE_INTERVAL_SEC / day_length`,
## which is 0.017 even at the 60-second minimum day and 0.001 at the shipped 900, while the jumps
## that need snapping (a run restart back to morning, a `time set midnight` from noon) are 0.2 to
## 0.5. Nothing legitimate lands in between.
const CLIENT_SNAP_THRESHOLD: float = 0.1


@rpc("authority", "call_remote", "unreliable")
func net_push_time(value: float) -> void:
	if _owns_mutation():
		return
	# Signature deliberately unchanged (`core/net/rpc_manifest.gd` scans SHAPE, so a new parameter
	# would be a PROTOCOL_VERSION bump): the client infers a discontinuity from the value itself
	# rather than being told about one. That is what makes this robust to the delivery order the
	# two-process check found — this push is UNRELIABLE and `run_restarted` reaches a client over
	# WorldDeltaLog's RELIABLE ORDERED channel, so a reset push routinely overtakes the event that
	# explains it, arriving while `_client_target_time` still holds the ended run's night. Without
	# the snap the client spends up to a full interval lerping backwards through dusk and afternoon
	# — `_lerp_wrapped_unit()` takes the shortest way round, and the shortest way from 0.80 to 0.348
	# is straight back through the afternoon it just played.
	var snap: bool = not _has_client_snapshot \
		or absf(fposmod(value - _client_target_time + 0.5, 1.0) - 0.5) >= CLIENT_SNAP_THRESHOLD
	_client_prev_time = value if snap else _client_target_time
	_client_target_time = value
	_client_since_update = 0.0
	_has_client_snapshot = true
	if snap:
		time_of_day = value
		_apply_to_level(time_of_day)


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"time", {
		# Dynamic scope (D-086): `time query` reads this peer's own replicated clock and needs no
		# round trip; `time set`/`time add` move the host's authoritative one.
		"scope": _time_scope,
		"args": [
			{"name": "op", "type": &"enum", "values": ["set", "add", "query"]},
			{"name": "value", "type": &"string", "optional": true, "default": ""},
		],
		"handler": _cmd_time,
		"help": "time set <0..1|dawn|noon|dusk|midnight> | time add <seconds> | time query",
	})


func _time_scope(raw_args: PackedStringArray) -> StringName:
	return &"local" if raw_args.is_empty() or raw_args[0].to_lower() == "query" else &"host"


## The named times are the four this file already knows: `night_started_at`/`day_started_at` are
## exports, and noon/midnight are the halfway points of the same 0..1 fraction. Reading dusk off the
## export rather than hard-coding 0.75 means retuning the threshold retunes the command with it.
func _named_time(word: String) -> float:
	match word:
		"dawn":
			return day_started_at
		"dusk":
			return night_started_at
		"noon":
			return 0.5
		"midnight":
			return 0.0
		_:
			return NAN


func _cmd_time(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var operation: String = String(args.get("op", "query"))
	var raw: String = String(args.get("value", "")).strip_edges()

	if operation == "query":
		return {"ok": true, "message": "time %.4f (%s), day length %.0fs" % [
			time_of_day, _phase_word(time_of_day), _resolve_day_length()
		], "data": {"time_of_day": time_of_day, "day_length": _resolve_day_length()}}

	if raw.is_empty():
		return {"ok": false, "message": "usage: time %s <value>" % operation, "data": {}}

	if operation == "add":
		if not raw.is_valid_float() and not raw.is_valid_int():
			return {"ok": false, "message": "'%s' is not a number of seconds" % raw, "data": {}}
		# Through host_advance, which is the same path the real tick uses — its own doc comment
		# predicted this caller. A command must not write time_of_day directly.
		host_advance(raw.to_float())
		return {"ok": true, "message": "time %.4f (%s)" % [time_of_day, _phase_word(time_of_day)],
			"data": {"time_of_day": time_of_day}}

	var target: float = _named_time(raw.to_lower())
	if is_nan(target):
		if not raw.is_valid_float() and not raw.is_valid_int():
			return {"ok": false,
				"message": "'%s' is not a time — use 0..1 or dawn/noon/dusk/midnight" % raw, "data": {}}
		target = fposmod(raw.to_float(), 1.0)
	if not host_set_time(target):
		return {"ok": false, "message": "only the host can set the time", "data": {}}
	return {"ok": true, "message": "time %.4f (%s)" % [time_of_day, _phase_word(time_of_day)],
		"data": {"time_of_day": time_of_day}}


## Jumps the clock, crossing the day/night thresholds on the way so a `time set dusk` actually starts
## the night rather than silently skipping past the signal WaveSpawner is waiting on. That is the
## whole reason this is a seam here and not `time_of_day = x` at the call site.
func host_set_time(fraction: float) -> bool:
	if not _owns_mutation():
		return false
	var previous: float = time_of_day
	time_of_day = fposmod(fraction, 1.0)
	_check_thresholds(previous, time_of_day)
	_apply_to_level(time_of_day)
	_replicate_elapsed = REPLICATE_INTERVAL_SEC  # push it to clients on the next tick, not in 1s
	return true


func _phase_word(fraction: float) -> String:
	if fraction >= night_started_at or fraction < day_started_at:
		return "night"
	if fraction < 0.5:
		return "morning"
	return "afternoon"
