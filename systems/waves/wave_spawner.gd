extends Node

## One-shot night population director. It disables EnemyWorld's ambient replacement loop while a
## night is active, then clears the wave and restores the daytime field at dawn.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Day/night, wave director, Cycle state, active
## modifiers"): **HOST**. Only the host creates or clears the population; EnemyWorld's existing
## MultiplayerSpawner replicates those host-owned bodies, so this service adds no RPC.

const DEFAULT_SEED: int = 0x57415645  # "WAVE"

@export_range(0, 128, 1) var base_count: int = 4
@export_range(0, 32, 1) var per_player: int = 2
@export_range(0.0, 20.0, 0.25) var scatter_m: float = 4.0
@export var enemy_id: StringName = &"crawler"

var _rng := RandomNumberGenerator.new()
var _night_active: bool = false
var _ambient_was_enabled: bool = true


func _ready() -> void:
	_rng.seed = DEFAULT_SEED
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night == null:
		return
	if day_night.has_signal(&"night_started"):
		day_night.connect(&"night_started", _on_night_started)
	if day_night.has_signal(&"day_started"):
		day_night.connect(&"day_started", _on_day_started)


## Starts exactly one population for the night. A repeated threshold signal cannot add a second
## population, and deaths do not feed any replacement loop because ambient spawning stays disabled.
func _on_night_started() -> void:
	if _night_active or not _owns_wave_director():
		return
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return
	_night_active = true
	_ambient_was_enabled = bool(world.get("ambient_enabled"))
	world.set("ambient_enabled", false)

	var points: Array = world.call("ambient_spawn_points")
	if points.is_empty():
		return
	var spawn_count: int = base_count + per_player * _live_player_count()
	for index: int in spawn_count:
		var origin: Vector3 = points[_rng.randi_range(0, points.size() - 1)] as Vector3
		var offset := Vector3(
			_rng.randf_range(-scatter_m, scatter_m),
			0.0,
			_rng.randf_range(-scatter_m, scatter_m)
		)
		world.call("host_spawn", enemy_id, origin + offset)


## Clears the one-shot night population, restores the exact ambient setting found at dusk, and
## refills only after queued enemy frees have left the tree so live_count() cannot suppress refill.
func _on_day_started() -> void:
	if not _night_active or not _owns_wave_director():
		return
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return
	_night_active = false
	world.call("host_despawn_all")
	world.set("ambient_enabled", _ambient_was_enabled)
	_refill_daytime.call_deferred(world)


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
