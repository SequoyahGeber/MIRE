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
## number), an `EventBus` emission, and a log line. The `EventBus` emission reaches every peer's own
## bus, not just the host's process — `_announce()` itself only ever runs host-side, but
## `_on_world_delta_applied()` re-derives the identical emit on a client from the same
## `WorldDeltaLog` record landing there (F-250; before this, a client's own
## `EventBus.subscribe_cycle_advanced()` listeners never fired at all).
##
## F-154: this file is also now the run-lifecycle owner COMMANDS.md §5.2's illustrative hook
## vocabulary was missing — see `run_started`'s own doc comment below for the exact "once per
## process, host/solo only" contract `CommandService._HOOK_EVENTS`'s new row binds against.
##
## F-243: and the run-RESTART owner — `run_started` above fires exactly once per process by design
## (see its own doc comment) and stays that way; a second "a run began" moment needed a signal of its
## own, `EVENT_BUS.run_restarted` (subscribed by every run-scoped system: MireGrid, CycleModifier-
## Service, PowerupService, InventoryService, PlayerHealth, EnemyWorld, BuildService, DefeatService,
## and every live Wellspring/Chest/ExtractionShip instance). `host_restart_run()` is HOST-only and
## deliberately NOT its own RPC — see docs/DECISIONS.md's F-243 entry: only the host peer can ever
## trigger it (the HUD button only shows for the local host; a non-host sees "waiting on the host"),
## so there is no client request to carry across the wire, the same reason `GameState.
## host_generate_seed()` needs none either. What DOES need to reach every peer — the reset itself —
## reuses the exact `WorldDeltaLog` no-new-RPC trick `_announce()`/`_on_world_delta_applied()` already
## prove below for `cycle_advanced`, under a second `kind` so the two never collide.
##
## SCOPE CUT, written down so nobody "fixes" it as an oversight: a restart keeps the same
## `GameState.run_seed` — same island, same POI/Wellspring/Chest/ExtractionShip positions, same
## biome/terrain layout. Only RUN-scoped state resets (Cycle, Mire corruption, modifiers, inventory,
## health, enemies, buildables, chest/wellspring/ship progress). Drawing a fresh world seed on
## restart would need a live re-broadcast to every already-connected peer, which nothing in this
## codebase does today (`WorldDeltaLog.net_world_snapshot` only ever reaches a NEWLY joining peer) —
## real scope, not this finding's, and filed as F-258.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

## `WorldDeltaLog` addressing for the one scalar this file owns. Not a real spatial chunk — `Cycle`
## has no position — but the log's shape does not require one; MireGrid proved the same reuse.
const GLOBAL_CHUNK: Vector2i = Vector2i.ZERO
const KIND: StringName = &"cycle"
const KEY: String = "current"
## F-243: a second, unrelated scalar under the SAME pseudo-chunk — `WorldDeltaLog` keys by
## `(chunk, kind, key)`, so a distinct `kind` here can never collide with the Cycle record above.
## Monotonically increasing rather than a bool: `_apply()` (WorldDeltaLog's own) always re-emits
## `delta_applied` regardless of whether the stored value actually changed, so even this could in
## principle be a bare "ping" — but a real counter also gives a check something to assert moved by
## exactly 1, and costs nothing extra.
const RUN_KIND: StringName = &"run"
const RUN_KEY: String = "generation"

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
var _run_generation: int = 0
var _transport_node: Node


func _ready() -> void:
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night != null and day_night.has_signal(&"day_started"):
		day_night.connect(&"day_started", _on_day_started)
	# F-250: a client's own EventBus never gets `_announce()`'s emit directly (host-only, see that
	# method's header) — this re-derives it locally from the log record the host's `_announce()` also
	# writes, the moment it actually lands.
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null and world_delta_log.has_signal(&"delta_applied"):
		world_delta_log.connect(&"delta_applied", _on_world_delta_applied)
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


## F-243: the whole run-restart trigger. HOST-only, and only once the run has actually ended — a
## defeat (`DefeatService.defeated`) or a completed extraction (any `&"extraction_ship"` group member
## with `departed == true`); nothing here ends a run in progress. Resets THIS process's own Cycle
## state, then broadcasts `run_restarted` twice over: directly (host's own local subscribers, e.g.
## this process's own MireGrid/PlayerHealth/...) and through the `RUN_KIND`/`RUN_KEY` WorldDeltaLog
## record every OTHER connected peer's own `_on_world_delta_applied()` re-derives the identical emit
## from. `_announce()` runs last so CycleModifierService's stack is already cleared before the
## `cycle_advanced(1)` it fires triggers that service's own Cycle-1 draw check.
func host_restart_run() -> int:
	if not _owns_cycle() or not _run_has_ended():
		return _current_cycle
	_current_cycle = 1
	_spread_multiplier = 1.0
	_days_elapsed = 0
	_run_generation += 1
	EVENT_BUS.emit_run_restarted()
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		world_delta_log.call("host_record", GLOBAL_CHUNK, RUN_KIND, RUN_KEY, _run_generation)
	_announce()
	MireLog.info(&"world", "Run restarted — Cycle 1 begins")
	return _current_cycle


func _run_has_ended() -> bool:
	var defeat_service: Node = get_node_or_null(^"/root/DefeatService")
	if defeat_service != null and bool(defeat_service.get(&"defeated")):
		return true
	for node: Node in get_tree().get_nodes_in_group(&"extraction_ship"):
		if bool(node.get(&"departed")):
			return true
	return false


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
## EventBus.emit_cycle_advanced() for this process's own in-process listeners. A client never runs
## this method (guarded below) — see `_on_world_delta_applied()` for how its own peer's
## `cycle_advanced` still fires.
func _announce() -> void:
	if not _owns_cycle():
		return
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, KEY, _current_cycle)
	EVENT_BUS.emit_cycle_advanced(_current_cycle)
	MireLog.info(&"world", "Cycle %d begins — spread x%.2f" % [_current_cycle, _spread_multiplier])


## F-250: `_announce()` above only ever runs host-side (`_owns_cycle()`), so a real connected
## client's own `EventBus.cycle_advanced` never fired at all — every `subscribe_cycle_advanced()`
## listener went silent on every peer but the host's, no matter how many Cycles actually passed.
## `WorldDeltaLog.delta_applied` fires the instant this process's own `_apply()` stores a value —
## for a client that is `net_delta_applied` landing the host's live `host_record()` write, the same
## real mutation `_announce()` itself is derived from. Re-emitting from here gives every peer's own
## bus a real, live `cycle_advanced` — not a poll — without a new RPC (D-099/D-100's no-new-RPC
## reuse of `WorldDeltaLog` for exactly this shape). Guarded on `_owns_cycle()` so the host — whose
## own `host_record()` call also runs through `_apply()` and fires this same signal — never
## double-emits; it already emitted directly above.
func _on_world_delta_applied(chunk: Vector2i, kind: StringName, key: String, value: Variant) -> void:
	if _owns_cycle() or chunk != GLOBAL_CHUNK:
		return
	if kind == KIND and key == KEY:
		EVENT_BUS.emit_cycle_advanced(int(value))
	elif kind == RUN_KIND and key == RUN_KEY:
		# F-243: a client's own copy of this same landing — `host_restart_run()`'s `RUN_KIND` record —
		# re-derived the identical way `cycle_advanced` is just above. Guarded on `_owns_cycle()` like
		# every other branch here: the host already emitted this directly inside `host_restart_run()`.
		EVENT_BUS.emit_run_restarted()


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
	# F-243: console/dev convenience only — the host is always op (CommandService._is_op()), so this
	# works for the one peer that can ever restart anyway. The real HUD trigger (`ui/hud/defeat_hud.gd`
	# / `ui/hud/extraction_hud.gd`) calls `host_restart_run()` directly rather than through here, since
	# a non-host player pressing that button must also work and HOST-scope commands require op.
	command_service.call("register_spec", &"restart", {
		"scope": &"host",
		"args": [],
		"handler": _cmd_restart,
		"help": "restart — start the next run (host only, once this one has ended)",
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


func _cmd_restart(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	if not _run_has_ended():
		return {"ok": false, "message": "run still in progress", "data": {}}
	var new_cycle: int = host_restart_run()
	return {"ok": true, "message": "Cycle %d begins" % new_cycle, "data": {"cycle": new_cycle}}
