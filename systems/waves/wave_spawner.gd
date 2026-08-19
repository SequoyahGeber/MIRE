extends Node

## One-shot night population director. It disables EnemyWorld's ambient replacement loop while a
## night is active, then clears the wave and restores the daytime field at dawn.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Day/night, wave director, Cycle state, active
## modifiers"): **HOST**. Only the host creates or clears the population; EnemyWorld's existing
## MultiplayerSpawner replicates those host-owned bodies, so this service adds no RPC.

const DEFAULT_SEED: int = 0x57415645  # "WAVE"
## Task 4.11's "corrupted spawn tables": a spawn landing on corrupted ground has a chance to produce
## this Mire-tainted variant instead of the requested kind. Substitution only ever applies to the
## default `enemy_id` slot (bog_crawler is a crawler variant, not a stand-in for anything else a
## future caller might request).
const CORRUPTED_ENEMY_ID: StringName = &"bog_crawler"
## Ceiling probability at full (1.0) corruption — never certainty, so a heavily corrupted wave reads
## as "worse," not "a different game."
const CORRUPTED_SPAWN_CAP_PROBABILITY: float = 0.75

## Gamerules `wave_base_count` and `wave_per_player` (task 3.14). Both exports stay as the
## COMMANDS.md §4.3 fallback and are adopted from RuleService by `_bind_rules()` when authored.
## Nothing re-sizes a wave already on the ground: these are read once, at dusk, in `_on_night_started`
## — so a change mid-night lands on the NEXT night, which is the only reading that does not leave
## players fighting a population that grew around them.
@export_range(0, 128, 1) var base_count: int = 4
@export_range(0, 32, 1) var per_player: int = 2
@export_range(0.0, 20.0, 0.25) var scatter_m: float = 4.0
@export var enemy_id: StringName = &"crawler"

var _rng := RandomNumberGenerator.new()
var _night_active: bool = false
var _ambient_was_enabled: bool = true
## Cached MireGrid ref (F-099). MireGrid registers after this autoload, so it is resolved lazily
## rather than in _ready() (F-011).
var _mire_grid_node: Node


func _ready() -> void:
	_rng.seed = DEFAULT_SEED
	# Before the DayNight lookup, which returns early when there is none (a harness, the main menu).
	# Binding rules is not conditional on a day cycle existing — the wave sizes are still the sizes.
	_bind_rules()
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night == null:
		return
	if day_night.has_signal(&"night_started"):
		day_night.connect(&"night_started", _on_night_started)
	if day_night.has_signal(&"day_started"):
		day_night.connect(&"day_started", _on_day_started)
	_register_commands()



## COMMANDS.md §4.3's export-fallback seam — this file asks, the service never reaches in. Both
## values are adopted into their exports so `_on_night_started`'s arithmetic stays one expression.
func _bind_rules() -> void:
	var rules: Node = get_node_or_null(^"/root/RuleService")
	if rules == null:
		return
	rules.connect(&"rule_changed", _on_rule_changed)
	if bool(rules.call("has_rule", &"wave_base_count")):
		base_count = int(rules.call("value_int", &"wave_base_count", base_count))
	if bool(rules.call("has_rule", &"wave_per_player")):
		per_player = int(rules.call("value_int", &"wave_per_player", per_player))


func _on_rule_changed(id: StringName, new_value: float) -> void:
	if id == &"wave_base_count":
		base_count = roundi(new_value)
	elif id == &"wave_per_player":
		per_player = roundi(new_value)


## Starts exactly one population for the night. A repeated threshold signal cannot add a second
## population, and deaths do not feed any replacement loop because ambient spawning stays disabled.
##
## A thin adapter over `host_start_wave()` since task 3.16, so `wave start` and dusk drive the same
## code — two copies of this would be two things to keep in step, and the command is the one that
## would quietly rot.
func _on_night_started() -> void:
	host_start_wave()


## Spawns `count` enemies scattered around a single fixed `position`, independent of night/day
## state or the ambient population — task 4.8's Wellspring ritual defense wave is the first caller,
## giving its own position override rather than one of EnemyWorld's ambient_spawn_points(). Host-only
## (`_owns_wave_director()`, same guard every other mutation here uses); returns the number actually
## spawned. Does not touch `ambient_enabled` — an ambient population and a ritual wave are
## independent one-shot populations that may coexist.
func host_spawn_wave_at(
	position: Vector3, count: int, wave_enemy_id: StringName = enemy_id,
	wave_scatter_m: float = scatter_m
) -> int:
	if not _owns_wave_director() or count <= 0:
		return 0
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return 0
	for _index: int in count:
		_spawn_one(world, position, wave_scatter_m, wave_enemy_id)
	return count


func _spawn_one(
	world: Node, origin: Vector3, spawn_scatter_m: float, spawn_enemy_id: StringName = enemy_id
) -> void:
	var offset := Vector3(
		_rng.randf_range(-spawn_scatter_m, spawn_scatter_m),
		0.0,
		_rng.randf_range(-spawn_scatter_m, spawn_scatter_m)
	)
	var position: Vector3 = origin + offset
	world.call("host_spawn", _corrupted_enemy_id_for(position, spawn_enemy_id), position)


## Substitutes CORRUPTED_ENEMY_ID with probability scaling linearly with corruption at the actual
## spawn point, capped at CORRUPTED_SPAWN_CAP_PROBABILITY. Only ever touches the default `enemy_id`
## slot — a caller that explicitly asked for some other kind gets exactly that, never a surprise
## reskin.
func _corrupted_enemy_id_for(position: Vector3, base_id: StringName) -> StringName:
	if base_id != enemy_id:
		return base_id
	var mire_grid: Node = _mire_grid()
	if mire_grid == null:
		return base_id
	var corruption: float = float(mire_grid.call(&"corruption_at", position))
	if corruption <= 0.0:
		return base_id
	if _rng.randf() < corruption * CORRUPTED_SPAWN_CAP_PROBABILITY:
		return CORRUPTED_ENEMY_ID
	return base_id


func _mire_grid() -> Node:
	if _mire_grid_node == null or not is_instance_valid(_mire_grid_node):
		_mire_grid_node = get_node_or_null(^"/root/MireGrid")
	return _mire_grid_node


## Clears the one-shot night population, restores the exact ambient setting found at dusk, and
## refills only after queued enemy frees have left the tree so live_count() cannot suppress refill.
## An adapter over `host_stop_wave()` for the same reason `_on_night_started` is one.
func _on_day_started() -> void:
	host_stop_wave()


func _refill_daytime(world: Node) -> void:
	if not is_instance_valid(world) or not _owns_wave_director():
		return
	# Preserve an intentionally disabled daytime field. The common true case refills immediately;
	# false means another director owned the field before dusk and remains authoritative after dawn.
	if _ambient_was_enabled:
		world.call("top_up_ambient")


func _live_player_count() -> int:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	var live_bodies: int = 0
	if player_net != null and player_net.has_method(&"players_root"):
		var players: Node = player_net.call("players_root") as Node
		if players != null:
			live_bodies = players.get_child_count()

	var transport: Node = get_node_or_null(^"/root/NetTransport")
	var offline: bool = transport == null or (
		not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
	)
	return maxi(live_bodies, 1) if offline else live_bodies


func _owns_wave_director() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"wave", {
		"scope": &"host",
		"args": [
			{"name": "op", "type": &"enum", "values": ["start", "stop", "status"]},
			{"name": "count", "type": &"int", "optional": true, "default": 0, "min": 0, "max": 128},
		],
		"handler": _cmd_wave,
		"help": "wave start [count] | wave stop | wave status — drive a night wave without waiting for dusk",
	})


func _cmd_wave(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var operation: String = String(args.get("op", "status"))
	if operation == "status":
		return {"ok": true, "message": "wave %s — base %d + %d per player" % [
			"active" if _night_active else "idle", base_count, per_player
		], "data": {"active": _night_active, "base": base_count, "per_player": per_player}}

	if operation == "stop":
		if not host_stop_wave():
			return {"ok": true, "message": "no wave was running", "data": {"active": false}}
		return {"ok": true, "message": "wave cleared, daytime field restored", "data": {"active": false}}

	var requested: int = int(args.get("count", 0))
	var spawned: int = host_start_wave(requested)
	if spawned < 0:
		return {"ok": false, "message": "a wave is already running — `wave stop` first", "data": {}}
	if spawned == 0:
		return {"ok": false,
			"message": "nowhere to spawn — the level has no enemy_spawn markers", "data": {}}
	return {"ok": true, "message": "wave started: %d enemies" % spawned,
		"data": {"active": true, "spawned": spawned}}


## The start/stop seams COMMANDS.md §7 marks as "formalized" for this task. `_on_night_started` and
## `_on_day_started` are now thin signal adapters over them, so the command and the day cycle drive
## the SAME code — a wave started by hand behaves identically to one dusk started, including the
## ambient-field suppression and the dawn restore that goes with it.
##
## Returns how many spawned, 0 for "nowhere to put them", or -1 for "already running".
func host_start_wave(override_count: int = 0) -> int:
	if _night_active or not _owns_wave_director():
		return -1
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return -1
	_night_active = true
	_ambient_was_enabled = bool(world.get("ambient_enabled"))
	world.set("ambient_enabled", false)

	var points: Array = world.call("ambient_spawn_points")
	if points.is_empty():
		return 0
	var spawn_count: int = override_count if override_count > 0 \
		else base_count + per_player * _live_player_count()
	for _index: int in spawn_count:
		var origin: Vector3 = points[_rng.randi_range(0, points.size() - 1)] as Vector3
		_spawn_one(world, origin, scatter_m)
	return spawn_count


func host_stop_wave() -> bool:
	if not _night_active or not _owns_wave_director():
		return false
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return false
	_night_active = false
	world.call("host_despawn_all")
	world.set("ambient_enabled", _ambient_was_enabled)
	_refill_daytime.call_deferred(world)
	return true
