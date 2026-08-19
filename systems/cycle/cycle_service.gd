extends Node

## CycleService — autoload. Task 6.1 (docs/DESIGN.md §5.1): the run's Cycle state machine.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Day/night, wave director, Cycle state, active
## modifiers" row): HOST. Only the host advances `_current_cycle`; a client reads it back through
## `WorldDeltaLog`, the same generic host-authoritative log task 4.9's MireGrid piggybacked on for
## the identical reason (D-099: a real new RPC pair needs a `PROTOCOL_VERSION` bump in
## `core/net/net_version.gd` + `tools/handshake_check.gd`, docs/SPECS.md's own standing rule, and
## both files are held all task by lane slate17's 3.7 claim). A single global scalar fits the
## existing `(chunk, kind, key) -> value` shape at the fixed pseudo-chunk `GLOBAL_CHUNK`; see D-100.
##
## A Cycle is ~3 in-game days (DESIGN.md §5.1: "roughly 3 in-game days"). This file counts
## `DayNight.day_started` crossings — HOST-only, same subscription `WaveSpawner` already uses — and
## every `DAYS_PER_CYCLE` of them runs the state machine step DESIGN.md names:
##   1. escalate the Mire's spread rate  -> `MireGrid.set_cycle_spread_multiplier()`
##   2. draw a Cycle Modifier            -> OUT OF SCOPE here, see D-100: 6.2 owns the deck/draw/
##      stacking framework and it does not exist yet. `EventBus.emit_cycle_advanced()` is the seam
##      6.2 hangs a draw off; nothing consumes it today.
##   3. expand the enemy roster          -> `WaveSpawner.host_unlock_next_enemy()`
## then announces: a `WorldDeltaLog` record (every peer, including a late joiner, learns the new
## number), an `EventBus` emission (in-process listeners), and a log line.
##
## F-154: this file is also now the run-lifecycle owner COMMANDS.md §5.2's illustrative hook
## vocabulary was missing — see `run_started`'s own doc comment below for the exact "once per
## process, host/solo only" contract `CommandService._HOOK_EVENTS`'s new row binds against.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

## `WorldDeltaLog` addressing for the one scalar this file owns. Not a real spatial chunk — `Cycle`
## has no position — but the log's shape does not require one; MireGrid proved the same reuse.
const GLOBAL_CHUNK: Vector2i = Vector2i.ZERO
const KIND: StringName = &"cycle"
const KEY: String = "current"

const DAYS_PER_CYCLE: int = 3
## DESIGN.md §5.1 "Mire base spread rate increases, permanently" — +15%/Cycle, compounding
## multiplicatively across the run the same way MireGrid's own per-Wellspring-cap reduction
## compounds (`SPREAD_REDUCTION_PER_CAP`). Placeholder-tuned, same status as
## `MireGrid.BASE_SPREAD_RATE` — nothing tunes this until a real playtest measures the wall (Q3).
const SPREAD_ESCALATION_PER_CYCLE: float = 1.15

## Fires exactly once per process, the instant Cycle 1's state is live — the real "run started"
## moment F-154 asked for (COMMANDS.md §5.2's illustrative hook vocabulary names it; nothing emitted
## it until now). Deliberately NOT "the level loaded": this file's own `_ready()` only reaches the
## emit after `_owns_cycle()` passes, the same host/solo-only gate `_announce()` uses, so a client
## connecting to someone else's run never fires its own copy — same split `night_started`/
## `day_started` already use, which is why `player_downed`'s new sibling row in
## `CommandService._HOOK_EVENTS` and this one bind the same way. A run's lifetime is the whole
## process lifetime here (`_current_cycle` has no session-close reset anywhere in this file, task
## 6.1's existing behavior, not something this task changes), so "once per process" is the correct
## "once per run", not an approximation of it.
signal run_started()

var _current_cycle: int = 1
var _spread_multiplier: float = 1.0
var _days_elapsed: int = 0
var _run_started_emitted: bool = false
var _transport_node: Node


func _ready() -> void:
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night != null and day_night.has_signal(&"day_started"):
		day_night.connect(&"day_started", _on_day_started)
	# Seeds WorldDeltaLog with Cycle 1 immediately, so a peer joining before the first advance still
	# reads a real recorded value instead of falling back to `latest()`'s default parameter.
	_announce()
	_emit_run_started()
	_register_commands()


## Guarded separately from `_announce()` (which re-runs on every later `host_advance_cycle()`) so
## this can never fire more than once — `run_started` names the run BEGINNING, not each Cycle bump.
func _emit_run_started() -> void:
	if _run_started_emitted or not _owns_cycle():
		return
	_run_started_emitted = true
	run_started.emit()


func _on_day_started() -> void:
	if not _owns_cycle():
		return
	_days_elapsed += 1
	if _days_elapsed < DAYS_PER_CYCLE:
		return
	_days_elapsed = 0
	host_advance_cycle()


## The current Cycle number, readable on any peer. Host reads its own authoritative int; a client
## reads WorldDeltaLog's replicated copy — same split MireGrid.corruption_at() uses and for the same
## reason (`_owns_cycle()` below mirrors `_owns_simulation()`).
func current_cycle() -> int:
	if _owns_cycle():
		return _current_cycle
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log == null:
		return _current_cycle
	return int(world_delta_log.call("latest", GLOBAL_CHUNK, KIND, KEY, _current_cycle))


func spread_multiplier() -> float:
	return _spread_multiplier


func days_elapsed_this_cycle() -> int:
	return _days_elapsed


## The whole state machine step: escalate, expand, announce. Public and host-guarded so a console
## command and the real day-count path drive the exact same code — the split `_on_night_started`/
## `host_start_wave` already uses in `systems/waves/wave_spawner.gd`.
func host_advance_cycle() -> int:
	if not _owns_cycle():
		return current_cycle()
	_current_cycle += 1
	_spread_multiplier *= SPREAD_ESCALATION_PER_CYCLE
	_escalate_spread_rate()
	_expand_enemy_pool()
	_announce()
	return _current_cycle


func _escalate_spread_rate() -> void:
	var mire_grid: Node = get_node_or_null(^"/root/MireGrid")
	if mire_grid != null and mire_grid.has_method(&"set_cycle_spread_multiplier"):
		mire_grid.call("set_cycle_spread_multiplier", _spread_multiplier)


func _expand_enemy_pool() -> StringName:
	var wave_spawner: Node = get_node_or_null(^"/root/WaveSpawner")
	if wave_spawner == null or not wave_spawner.has_method(&"host_unlock_next_enemy"):
		return &""
	return StringName(wave_spawner.call("host_unlock_next_enemy"))


## Host-only. Records the current Cycle into WorldDeltaLog (broadcasts to every already-connected
## peer, and folds into the snapshot a late joiner gets — see the header note) and fires
## EventBus.emit_cycle_advanced() for in-process listeners.
func _announce() -> void:
	if not _owns_cycle():
		return
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, KEY, _current_cycle)
	EVENT_BUS.emit_cycle_advanced(_current_cycle)
	MireLog.info(&"world", "Cycle %d begins — spread x%.2f" % [_current_cycle, _spread_multiplier])


func _owns_cycle() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node


# ── Commands (docs/COMMANDS.md §7 — task 3.16's convention) ─────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"cycle", {
		# Dynamic scope (D-086), same split `time`/`rule` use: reading status answers off this
		# peer's own replicated copy, forcing an advance is a host mutation.
		"scope": _cycle_scope,
		"args": [
			{"name": "op", "type": &"enum", "values": ["status", "advance"]},
		],
		"handler": _cmd_cycle,
		"help": "cycle status | cycle advance — read or force-advance the Cycle state machine",
	})


func _cycle_scope(raw_args: PackedStringArray) -> StringName:
	return &"local" if raw_args.is_empty() or raw_args[0].to_lower() == "status" else &"host"


func _cmd_cycle(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var operation: String = String(args.get("op", "status"))
	if operation == "status":
		return {"ok": true, "message": "Cycle %d — spread x%.2f, %d/%d day(s) elapsed" % [
			current_cycle(), _spread_multiplier, _days_elapsed, DAYS_PER_CYCLE
		], "data": {"cycle": current_cycle(), "spread_multiplier": _spread_multiplier}}

	var new_cycle: int = host_advance_cycle()
	return {"ok": true, "message": "Cycle %d begins" % new_cycle, "data": {"cycle": new_cycle}}
