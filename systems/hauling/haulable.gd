extends Node3D

## Host-owned carryable object — docs/SPECS.md 3.10, DESIGN.md §4.5 "heavy hauling" / §5's solo rule.
## Spawner-attached, same shape as systems/building/buildable_piece.gd: autoload/haul_service.gd's
## code-built MultiplayerSpawner (D-023) instantiates this identically on every peer and attaches
## this script to whichever root doesn't already bring its own, then sets `def_id` before the node
## enters the tree (so `_ready()` sees it).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Carryable objects" row — added this task): HOST.
## `request_pickup()`/`request_drop()` follow the exact request -> host validates -> replicated
## result shape autoload/build_service.gd's placement RPCs use ("the host revalidates from scratch").
## Carriers' own movement is unaffected and stays client-authoritative (§2.2 row 1) — this script
## never writes to a player's transform, only reads it, every host physics tick, to recompute where
## THIS object sits. A carrier that reports an impossible position for itself only ever drags the
## object toward that lie at HaulMath's bounded speed (systems/hauling/haul_math.gd); it can never
## make the object itself jump — proved by tools/haul_net_check.gd.
##
## Replicated transform => must be smoothed (D-043). Named NetConfig.PLAYER_SYNC_NODE and attaches
## NetInterp exactly like systems/enemies/enemy.gd does, for the same reason: same node name means
## `NetInterp.attach_to()` works with no change.

const HAUL_MATH := preload("res://systems/hauling/haul_math.gd")

const HAULABLE_GROUP: StringName = &"haulable"
## DESIGN.md §4.5: heavy hauling is a 2-player mechanic. A third requester is refused, not queued.
const MAX_CARRIERS: int = 2

signal pickup_confirmed(request_id: int, accepted: bool, reason: String)
signal drop_confirmed(request_id: int, accepted: bool, reason: String)
## Host-side and replicated (ON_CHANGE) — everyone sees who is carrying, not just the carriers.
signal carriers_changed(carrier_ids: PackedInt32Array)

## Set by HaulService._net_spawn_haulable() before add_child(), identically on every peer — the only
## thing that travels over the spawn payload besides position (D-023).
@export var def_id: StringName = &""

## Replicated (ON_CHANGE): who currently carries this object, 0, 1 or 2 peer ids. Discrete state, so
## it wants to snap on arrival rather than blend (D-043's reasoning for Chest.opened) — nothing here
## interpolates it, only `position` does.
var carriers: PackedInt32Array = PackedInt32Array():
	set(value):
		if carriers == value:
			return
		carriers = value
		carriers_changed.emit(carriers)

var _def: Resource
var _sync: MultiplayerSynchronizer
var _next_request_id: int = 1
var _transport_node: Node


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(HAULABLE_GROUP)
	_def = _resolve_def()
	_build_synchronizer()

	# Only the host simulates the object's position; a client's copy is moved entirely by
	# replication, same split as Enemy (F-004).
	set_physics_process(_owns_simulation())
	if not _owns_simulation():
		var interp: Node = get_node_or_null(^"/root/NetInterp")
		if interp != null:
			interp.call_deferred(&"attach_to", self)


func _physics_process(delta: float) -> void:
	if _def == null or carriers.is_empty():
		return
	var positions: Array = _carrier_positions()
	var target: Vector3 = HAUL_MATH.target_position(positions, global_position)
	global_position = HAUL_MATH.step(global_position, target, positions.size(), _def, delta)


# ── Client-facing request seam ───────────────────────────────────────────────────────────────────


## Returns a local request id immediately; the answer always arrives through pickup_confirmed.
func request_pickup() -> int:
	var request_id: int = _take_request_id()
	if _owns_simulation():
		_accept_pickup(_local_peer_id(), request_id)
	elif _transport_is_active():
		net_request_pickup.rpc_id(NetConfig.HOST_PEER_ID, request_id)
	else:
		pickup_confirmed.emit(request_id, false, "no authoritative session")
	return request_id


func request_drop() -> int:
	var request_id: int = _take_request_id()
	if _owns_simulation():
		_accept_drop(_local_peer_id(), request_id)
	elif _transport_is_active():
		net_request_drop.rpc_id(NetConfig.HOST_PEER_ID, request_id)
	else:
		drop_confirmed.emit(request_id, false, "no authoritative session")
	return request_id


func is_carrying(peer_id: int) -> bool:
	return carriers.has(peer_id)


func carrier_count() -> int:
	return carriers.size()


# ── Host decisions ───────────────────────────────────────────────────────────────────────────────


func _accept_pickup(peer_id: int, request_id: int) -> void:
	if not _owns_simulation() or _def == null or peer_id <= 0:
		_answer_pickup(peer_id, request_id, false, "cannot be picked up")
		return
	if carriers.has(peer_id):
		_answer_pickup(peer_id, request_id, false, "already carrying this")
		return
	if carriers.size() >= MAX_CARRIERS:
		_answer_pickup(peer_id, request_id, false, "already fully carried")
		return
	if _peer_hauling_elsewhere(peer_id):
		_answer_pickup(peer_id, request_id, false, "already carrying something else")
		return
	if not _requester_in_range(peer_id):
		_answer_pickup(peer_id, request_id, false, "too far away")
		return

	var updated: PackedInt32Array = carriers.duplicate()
	updated.append(peer_id)
	carriers = updated
	_answer_pickup(peer_id, request_id, true, "")


func _accept_drop(peer_id: int, request_id: int) -> void:
	if not _owns_simulation():
		_answer_drop(peer_id, request_id, false, "cannot be dropped")
		return
	if not carriers.has(peer_id):
		_answer_drop(peer_id, request_id, false, "not carrying this")
		return
	host_release_carrier(peer_id)
	_answer_drop(peer_id, request_id, true, "")


## D-035 consumer contract: NetSession's grace window, not `peer_left`, decides whether a departure
## is final. The same run-player reconnecting under a new peer id keeps its carry rather than being
## silently dropped and picked back up by someone else mid-round-trip. Called by
## HaulService._on_run_player_rebound() for every live Haulable — see that file's header for why the
## fan-out lives there rather than each object subscribing to NetSession itself.
func host_rebind_carrier(old_peer_id: int, new_peer_id: int) -> void:
	if not _owns_simulation():
		return
	var index: int = carriers.find(old_peer_id)
	if index == -1:
		return
	var updated: PackedInt32Array = carriers.duplicate()
	updated[index] = new_peer_id
	carriers = updated


## The grace window expired (or an ordinary in-session drop) — release the slot. Safe to call for a
## peer that was never carrying: `find()` returns -1 and this is a no-op.
func host_release_carrier(peer_id: int) -> void:
	if not _owns_simulation():
		return
	var index: int = carriers.find(peer_id)
	if index == -1:
		return
	var updated: PackedInt32Array = carriers.duplicate()
	updated.remove_at(index)
	carriers = updated


# ── Replication ──────────────────────────────────────────────────────────────────────────────────


@rpc("any_peer", "call_remote", "reliable")
func net_request_pickup(request_id: int) -> void:
	if not _transport_is_host():
		return
	_accept_pickup(multiplayer.get_remote_sender_id(), request_id)


@rpc("authority", "call_remote", "reliable")
func net_pickup_result(request_id: int, accepted: bool, reason: String) -> void:
	pickup_confirmed.emit(request_id, accepted, reason)


@rpc("any_peer", "call_remote", "reliable")
func net_request_drop(request_id: int) -> void:
	if not _transport_is_host():
		return
	_accept_drop(multiplayer.get_remote_sender_id(), request_id)


@rpc("authority", "call_remote", "reliable")
func net_drop_result(request_id: int, accepted: bool, reason: String) -> void:
	drop_confirmed.emit(request_id, accepted, reason)


func _answer_pickup(peer_id: int, request_id: int, accepted: bool, reason: String) -> void:
	if peer_id == _local_peer_id():
		pickup_confirmed.emit(request_id, accepted, reason)
		return
	if _transport_is_active() and _peer_connected(peer_id):
		net_pickup_result.rpc_id(peer_id, request_id, accepted, reason)


func _answer_drop(peer_id: int, request_id: int, accepted: bool, reason: String) -> void:
	if peer_id == _local_peer_id():
		drop_confirmed.emit(request_id, accepted, reason)
		return
	if _transport_is_active() and _peer_connected(peer_id):
		net_drop_result.rpc_id(peer_id, request_id, accepted, reason)


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	var position_path := NodePath(".:position")
	config.add_property(position_path)
	config.property_set_spawn(position_path, true)
	config.property_set_replication_mode(
		position_path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS
	)

	# Discrete state — wants to snap on arrival, not blend (D-043's reasoning for Chest.opened).
	var carriers_path := NodePath(".:carriers")
	config.add_property(carriers_path)
	config.property_set_spawn(carriers_path, true)
	config.property_set_replication_mode(
		carriers_path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
	)

	_sync = MultiplayerSynchronizer.new()
	# Same node name as a player's/an enemy's, so NetInterp smooths this with no change (F-004).
	_sync.name = NetConfig.PLAYER_SYNC_NODE
	_sync.root_path = NodePath("..")
	_sync.replication_config = config
	# BEFORE add_child, never after (F-012).
	_sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	NetInterest.configure(_sync, self, NetInterest.Class.ENEMY)
	add_child(_sync)


func _resolve_def() -> Resource:
	if def_id == &"":
		return null
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method(&"get_haulable"):
		return null
	return registry.call(&"get_haulable", def_id) as Resource


func _carrier_positions() -> Array:
	var positions: Array = []
	if carriers.is_empty():
		return positions
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net == null or not player_net.has_method(&"player_for"):
		return positions
	for peer_id: int in carriers:
		var body: Node3D = player_net.call(&"player_for", peer_id) as Node3D
		if body != null:
			positions.append(body.global_position)
	return positions


## Offline mode has no PlayerNet spawn — same fallback Chest._requester_in_range and
## BuildService use: the validation seam there is the local interact that owns this call.
func _requester_in_range(peer_id: int) -> bool:
	if not _transport_is_active():
		return true
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net == null or not player_net.has_method(&"player_for"):
		return false
	var player: Node3D = player_net.call(&"player_for", peer_id) as Node3D
	if player == null:
		return false
	var range_m: float = float(_def.get(&"pickup_range_m"))
	return global_position.distance_squared_to(player.global_position) <= range_m * range_m


## Prevents one peer holding two haulables at once — "carrying" is one pair of hands, not one slot
## per object. Cheap: haulables are dozens at most, and this only runs on a pickup request, never
## per tick.
func _peer_hauling_elsewhere(peer_id: int) -> bool:
	var service: Node = get_node_or_null(^"/root/HaulService")
	if service == null or not service.has_method(&"is_peer_hauling"):
		return false
	return bool(service.call(&"is_peer_hauling", peer_id, self))


func _owns_simulation() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


func _transport_is_host() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_host"))


func _peer_connected(peer_id: int) -> bool:
	var transport: Node = _transport()
	return transport != null and (transport.call("peer_ids") as PackedInt32Array).has(peer_id)


func _local_peer_id() -> int:
	var transport: Node = _transport()
	if transport == null or not _transport_is_active():
		return NetConfig.HOST_PEER_ID
	return int(transport.call("local_peer_id"))


func _take_request_id() -> int:
	var result: int = _next_request_id
	_next_request_id += 1
	if _next_request_id <= 0:
		_next_request_id = 1
	return result


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node
