class_name Wellspring
extends Node3D

## Host-authoritative capture ritual for one Wellspring objective (DESIGN.md §4.2).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Wellspring ritual" row): HOST. A request to
## start/cancel the channel carries no timer, no player count and no roll — the host alone decides
## whether it is accepted, exactly the "harvest pattern" Chest and Harvestable already established.
## `capped`/`channeling`/`progress_sec`/`duration_sec`/`required_players` are the only state that
## crosses the wire, through a code-built MultiplayerSynchronizer (D-023), same as Chest's `opened`.
## Offline play runs the identical authority path locally.
##
## Built and positioned identically on every peer by `autoload/wellspring_service.gd` from the
## map's own `objective` marker — this node holds no map-specific knowledge of its own, same split
## `autoload/harvest_world.gd` uses for harvestable holders.
##
## D-092: capping does NOT require the defense wave to be cleared, and does not grant a chest, Mire
## corruption-clear, or Attunement selection. See docs/DECISIONS.md for why — the short version is
## that Mire (4.9-4.11) does not exist yet and Attunement already fires at run start, not at cap
## (D-071). `EventBus.emit_wellspring_capped()` is the seam those future systems hook into.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const UNCAPPED_MESH_PATH: String = "res://assets/wellsprings/exports/wellspring_uncapped.glb"
const CAPPED_MESH_PATH: String = "res://assets/wellsprings/exports/wellspring_capped.glb"
## Shared across all four A-008 condition states (assets/wellsprings/README.md's state-swap
## contract): same 4.6 m foundation, centred at the shared origin, regardless of which state is
## showing. Collision is therefore built once and never swapped.
const FOUNDATION_RADIUS_M: float = 2.4
const FOUNDATION_HEIGHT_M: float = 0.6

## A player counts as "present" within this radius — comfortably past the 7.1 m boundary-stones
## ring (assets/wellsprings/catalog.json), so standing inside the ring always counts.
const PRESENCE_RANGE_M: float = 4.5
const COOP_DURATION_SEC: float = 60.0
## D-092: 2.5× the co-op duration. DESIGN.md §4.5 says only "longer", not a number.
const SOLO_DURATION_SEC: float = 150.0
const DEFENSE_WAVE_BASE_COUNT: int = 3
const DEFENSE_WAVE_PER_PLAYER: int = 1
const DEFENSE_WAVE_ENEMY_ID: StringName = &"crawler"
const DEFENSE_WAVE_SCATTER_M: float = 5.0

const WELLSPRING_GROUP: StringName = &"wellspring"
const SYNC_NODE_NAME: StringName = &"WellspringSync"
const VISUAL_NODE_NAME: StringName = &"WellspringVisual"

## Replicated. Setter keeps the visual correct when a network delta arrives on a client.
var capped: bool = false:
	set(value):
		if capped == value:
			return
		capped = value
		_schedule_visual_refresh()

## Replicated. Presentation reads this to show/hide the progress prompt.
var channeling: bool = false
## Replicated. Seconds of channel time accumulated so far this attempt.
var progress_sec: float = 0.0
## Replicated. Snapshotted when the channel starts — the duration this attempt needs to finish.
var duration_sec: float = COOP_DURATION_SEC
## Replicated. Snapshotted when the channel starts — how many players must stay present.
var required_players: int = 2

var _visual: Node3D
var _sync: MultiplayerSynchronizer
var _visual_refresh_scheduled: bool = false


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(WELLSPRING_GROUP)
	_build_collision()
	_build_synchronizer()
	_refresh_visual()
	set_process(false)


## Client-facing: press interact while in range. Toggles start/cancel; a no-op once capped.
func request_toggle_channel() -> void:
	if _owns_mutation():
		_process_toggle(_local_peer_id())
	elif _transport_is_active():
		net_request_toggle_channel.rpc_id(NetConfig.HOST_PEER_ID)


## Local-only convenience for the HUD prompt: is the LOCAL player close enough to act on this
## Wellspring right now? Presentation-only, same caveat as every other `local_*`/`nearby_*` helper
## in this codebase — the host repeats this check independently before accepting a request.
func is_local_player_in_range() -> bool:
	var player: Node3D = _player_by_peer(_local_peer_id())
	return player != null and _in_range(player)


@rpc("any_peer", "call_remote", "reliable")
func net_request_toggle_channel() -> void:
	if not _transport_is_host():
		return
	_process_toggle(multiplayer.get_remote_sender_id())


func _process_toggle(peer_id: int) -> void:
	if not _owns_mutation() or capped:
		return
	var player: Node3D = _player_by_peer(peer_id)
	if player == null or not _in_range(player):
		return
	if channeling:
		_cancel_channel()
	else:
		_start_channel()


func _start_channel() -> void:
	channeling = true
	progress_sec = 0.0
	required_players = 1 if _session_player_total() <= 1 else 2
	duration_sec = SOLO_DURATION_SEC if required_players == 1 else COOP_DURATION_SEC
	set_process(true)
	_spawn_defense_wave()


## D-092: cancelling forfeits progress rather than merely pausing it — a deliberate, simple rule
## distinct from "everyone stepped away", which pauses (see _process below) without resetting.
func _cancel_channel() -> void:
	channeling = false
	progress_sec = 0.0
	set_process(false)


func _process(delta: float) -> void:
	host_tick(delta)


## Advances the ritual by `delta` seconds, host-only. Split out of `_process()` so a check can cross
## a whole 60-150 s ritual in a handful of calls instead of thousands of real engine frames — the
## same reason `DayNight.host_advance()` is public rather than something only `_physics_process`
## calls.
func host_tick(delta: float) -> void:
	if not _owns_mutation() or not channeling:
		set_process(false)
		return
	if _present_count() >= required_players:
		progress_sec = minf(progress_sec + delta, duration_sec)
	if progress_sec >= duration_sec:
		_finish_cap()


func _finish_cap() -> void:
	channeling = false
	progress_sec = 0.0
	capped = true
	set_process(false)
	EVENT_BUS.emit_wellspring_capped(name, global_position)


func _spawn_defense_wave() -> void:
	var waves: Node = get_node_or_null(^"/root/WaveSpawner")
	if waves == null:
		return
	var count: int = DEFENSE_WAVE_BASE_COUNT + DEFENSE_WAVE_PER_PLAYER * _session_player_total()
	waves.call(
		&"host_spawn_wave_at", global_position, count, DEFENSE_WAVE_ENEMY_ID, DEFENSE_WAVE_SCATTER_M
	)


## Every live player within PRESENCE_RANGE_M, host-side. Works offline too: even solo, the local
## player is in the `&"players"` group as its own multiplayer authority (same technique
## `entities/player/player_controller.gd`'s `_nearest_downed_teammate` uses on the client side).
func _present_count() -> int:
	var count: int = 0
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and _in_range(player):
			count += 1
	return count


## Total live players THIS SESSION (offline = 1) — snapshotted once at channel start, same
## read-once-at-the-threshold-moment rule `systems/waves/wave_spawner.gd`'s base_count/per_player
## already follow, so a player joining or leaving mid-ritual does not retroactively change what an
## already-running attempt needs.
func _session_player_total() -> int:
	var count: int = 0
	for _node: Node in get_tree().get_nodes_in_group(&"players"):
		count += 1
	return maxi(count, 1)


func _in_range(player: Node3D) -> bool:
	var range_sq: float = PRESENCE_RANGE_M * PRESENCE_RANGE_M
	return global_position.distance_squared_to(player.global_position) <= range_sq


func _player_by_peer(peer_id: int) -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.get_multiplayer_authority() == peer_id:
			return player
	return null


func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "WellspringCollision"
	add_child(body)
	var shape := CylinderShape3D.new()
	shape.radius = FOUNDATION_RADIUS_M
	shape.height = FOUNDATION_HEIGHT_M
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position.y = FOUNDATION_HEIGHT_M * 0.5
	body.add_child(collider)


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property_name: String in [
		"capped", "channeling", "progress_sec", "duration_sec", "required_players"
	]:
		var property_path := NodePath(".:%s" % property_name)
		config.add_property(property_path)
		config.property_set_spawn(property_path, true)
		config.property_set_replication_mode(
			property_path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
		)

	_sync = MultiplayerSynchronizer.new()
	_sync.name = SYNC_NODE_NAME
	_sync.root_path = NodePath("..")
	_sync.replication_config = config
	_sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	NetInterest.configure(_sync, self, NetInterest.Class.PROP)
	add_child(_sync)


func _refresh_visual() -> void:
	if not is_inside_tree():
		return
	if _visual != null:
		remove_child(_visual)
		_visual.queue_free()
		_visual = null
	var packed: PackedScene = load(CAPPED_MESH_PATH if capped else UNCAPPED_MESH_PATH) as PackedScene
	if packed == null:
		return
	_visual = packed.instantiate() as Node3D
	if _visual == null:
		push_error("Wellspring %s: state mesh root must be Node3D" % name)
		return
	_visual.name = VISUAL_NODE_NAME
	add_child(_visual)


func _schedule_visual_refresh() -> void:
	if _visual_refresh_scheduled:
		return
	_visual_refresh_scheduled = true
	call_deferred("_flush_visual_refresh")


func _flush_visual_refresh() -> void:
	if not _visual_refresh_scheduled:
		return
	_visual_refresh_scheduled = false
	_refresh_visual()


func _owns_mutation() -> bool:
	return not _transport_is_active() or _transport_is_host()


func _transport() -> Node:
	return get_node_or_null(^"/root/NetTransport")


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


func _transport_is_host() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_host"))


func _local_peer_id() -> int:
	var transport: Node = _transport()
	if transport == null or not _transport_is_active():
		return NetConfig.HOST_PEER_ID
	return int(transport.call("local_peer_id"))
