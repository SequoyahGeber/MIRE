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

const REPLICATE_INTERVAL_SEC: float = 1.0

## Fraction of a day. 0.348 matches Atmosphere's own 8.35h default (8.35 / 24.0).
@export_range(0.0, 1.0, 0.0001) var time_of_day: float = 0.348
## Mirrors world/environment/playtest_atmosphere.gd's day_length_seconds default (900s). Not a
## second source of truth in practice: _resolve_day_length() overwrites it from the level's own
## Atmosphere node export the moment one is found, so this value only matters before a level with an
## Atmosphere node has loaded (harnesses, main menu).
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
# Client-side interpolation source: the last two host snapshots, and how long ago the second one
# arrived. Nothing here ever advances on its own — see _advance_client().
var _client_prev_time: float = 0.0
var _client_target_time: float = 0.0
var _client_since_update: float = 0.0
var _has_client_snapshot: bool = false


func _ready() -> void:
	set_physics_process(true)
	_apply_to_level(time_of_day)


# ── Simulation (§5a: physics tick, delta-scaled, never a frame count) ────────────────────────────


func _physics_process(delta: float) -> void:
	if _owns_mutation():
		_advance_host(delta)
	else:
		_advance_client(delta)


func _advance_host(delta: float) -> void:
	var day_length: float = _resolve_day_length()
	var previous: float = time_of_day
	time_of_day = fposmod(time_of_day + delta / day_length, 1.0)
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


func _resolve_day_length() -> float:
	_level_atmosphere()  # refreshes day_length_seconds whenever the level's Atmosphere is re-found
	return day_length_seconds


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


@rpc("authority", "call_remote", "unreliable")
func net_push_time(value: float) -> void:
	if _owns_mutation():
		return
	_client_prev_time = _client_target_time if _has_client_snapshot else value
	_client_target_time = value
	_client_since_update = 0.0
	_has_client_snapshot = true
