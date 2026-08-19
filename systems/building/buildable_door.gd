extends "res://systems/building/buildable_piece.gd"

## A placed buildable that opens: the wood door, the double gate, the palisade gate.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, world mutation row): HOST. A client's toggle
## request carries no state — request → host validates range and ownership of the mutation → host
## flips `open` → the bool replicates to everyone through a code-built MultiplayerSynchronizer
## (D-023), exactly the shape `Chest.opened` already uses. Offline play runs the same path locally.
## Nothing about the swing is predicted client-side: a door that opens on your screen and stays shut
## on the host is worse than one that opens a frame late.
##
## The rotation itself is free, and that is not luck. A-010 exports every door and gate leaf with its
## origin ON THE HINGE AXIS (`assets/construction/README.md`), and `scenes/buildables/*.tscn` places
## each leaf at the `hinge_offset_m` its catalog entry names — so opening a door is
## `leaf.rotation.y = angle` and there is no pivot for anyone to find by hand (D-039, D-090).
##
## Extends `buildable_piece.gd` rather than duplicating it, so a door still satisfies the
## `&"damageable"` contract F-085 is about: `BuildService._net_spawn_piece()` leaves an authored root
## alone precisely when it already implements `host_apply_damage()`, which this inherits.

const DOOR_GROUP: StringName = &"door"
const SYNC_NODE_NAME: StringName = &"DoorSync"

## (open, by_peer_id). Local; presentation and prompts listen to it. The replicated `open` bool is
## what other peers actually learn from.
signal toggled(open: bool, by_peer_id: int)

## The leaf nodes to swing, and how far each one turns, in degrees. Two parallel arrays rather than
## one array of dictionaries because .tscn authoring of a typed dictionary array is miserable, and
## because a length mismatch is then a thing `validation_errors()` can say out loud.
@export var leaves: Array[NodePath] = []
## Positive swings the leaf one way, negative the other — the double gate's two halves open outward
## from each other, so they are +90 and -90 rather than one mirrored value.
@export var leaf_degrees: Array[float] = []
## The collision shapes that exist only while the door is SHUT — the span across the opening. A
## door whose collider does not change is a door you can watch swing open and still walk into, which
## is a worse bug than one that never opens, because it looks like it works. The jambs, posts,
## header and lintel are separate shapes and stay on in both states.
@export var blocking_shapes: Array[NodePath] = []
## How close a player must be to work it. Matches the chest's default reach.
@export_range(0.5, 12.0, 0.1, "or_greater") var interact_range_m: float = 3.0
## Seconds the leaf takes to swing. Presentation only — the state flips instantly and host-side.
@export_range(0.0, 3.0, 0.05) var swing_seconds: float = 0.45

## Replicated. The setter drives presentation, so a client that learns the new value from the
## network animates exactly like the peer that asked for it.
var open: bool = false:
	set(value):
		if open == value:
			return
		open = value
		_apply_swing()
		_apply_blocking()

var _sync: MultiplayerSynchronizer
var _tween: Tween


func _ready() -> void:
	add_to_group(DOOR_GROUP)
	_build_synchronizer()
	_apply_swing(true)
	_apply_blocking()


## The interact seam. Returns whether a request was actually sent, so a prompt knows the input was
## consumed. Offline and host answer synchronously; a client's answer arrives as a replicated `open`.
func request_toggle() -> bool:
	var peer_id: int = _local_peer_id()
	if _owns_world_mutation():
		return _accept_toggle(peer_id)
	if not _transport_is_active():
		return false
	net_request_toggle.rpc_id(NetConfig.HOST_PEER_ID)
	return true


@rpc("any_peer", "call_remote", "reliable")
func net_request_toggle() -> void:
	if not _owns_world_mutation():
		return
	_accept_toggle(multiplayer.get_remote_sender_id())


func _accept_toggle(peer_id: int) -> bool:
	if not _owns_world_mutation() or hp <= 0 or peer_id <= 0:
		return false
	if not _requester_in_range(peer_id):
		return false
	open = not open
	toggled.emit(open, peer_id)
	return true


## Offline has no PlayerNet spawn, so the local interact that owns the call is the validation seam
## there; in a session the host independently verifies the remote player's position. Harvestable and
## Chest both reason exactly this way — the check is copied deliberately, not by accident.
func _requester_in_range(peer_id: int) -> bool:
	if not _transport_is_active():
		return true
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net == null or not player_net.has_method("player_for"):
		return false
	var player: Node3D = player_net.call("player_for", peer_id) as Node3D
	if player == null:
		return false
	return global_position.distance_squared_to(player.global_position) <= interact_range_m * interact_range_m


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if leaves.is_empty():
		errors.append("a door with no leaves cannot open")
	if leaves.size() != leaf_degrees.size():
		errors.append("%d leaves but %d angles" % [leaves.size(), leaf_degrees.size()])
	for index: int in leaves.size():
		if get_node_or_null(leaves[index]) == null:
			errors.append("leaf %d (%s) is not in this scene" % [index, leaves[index]])
		elif index < leaf_degrees.size() and is_zero_approx(leaf_degrees[index]):
			errors.append("leaf %d swings 0 degrees, so it does nothing" % index)
	if blocking_shapes.is_empty():
		errors.append("no blocking shapes, so opening it would not let anyone through")
	for path: NodePath in blocking_shapes:
		if not (get_node_or_null(path) is CollisionShape3D):
			errors.append("blocking shape %s is not a CollisionShape3D in this scene" % path)
	return errors


## Whether the doorway is currently walkable. What a check should assert, and what a player feels.
func is_passable() -> bool:
	for path: NodePath in blocking_shapes:
		var shape: CollisionShape3D = get_node_or_null(path) as CollisionShape3D
		if shape != null and not shape.disabled:
			return false
	return true


## Deferred, because a toggle can arrive from an RPC delivered inside the physics step and changing
## a shape's state mid-query is how you get a frame where the door is neither.
func _apply_blocking() -> void:
	for path: NodePath in blocking_shapes:
		var shape: CollisionShape3D = get_node_or_null(path) as CollisionShape3D
		if shape != null:
			shape.set_deferred(&"disabled", open)


## The angle a leaf is currently supposed to be at. Exists so a check can assert the swing without
## reaching into a Tween's internals.
func leaf_target_degrees(index: int) -> float:
	if index < 0 or index >= leaf_degrees.size():
		return 0.0
	return leaf_degrees[index] if open else 0.0


func _apply_swing(instant: bool = false) -> void:
	if not is_inside_tree():
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	var animate: bool = not instant and swing_seconds > 0.0
	if animate:
		_tween = create_tween().set_parallel(true)
		_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for index: int in leaves.size():
		var leaf: Node3D = get_node_or_null(leaves[index]) as Node3D
		if leaf == null:
			continue
		var target: float = deg_to_rad(leaf_target_degrees(index))
		if animate:
			_tween.tween_property(leaf, ^"rotation:y", target, swing_seconds)
		else:
			leaf.rotation.y = target


## `open` is the entire replicated schema — everything else about a door is either authored content
## or presentation. Same shape as Chest's `opened`.
func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	var property_path := NodePath(".:open")
	config.add_property(property_path)
	config.property_set_spawn(property_path, true)
	config.property_set_replication_mode(property_path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)

	_sync = MultiplayerSynchronizer.new()
	_sync.name = SYNC_NODE_NAME
	_sync.root_path = NodePath("..")
	_sync.replication_config = config
	_sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	NetInterest.configure(_sync, self, NetInterest.Class.PROP)
	add_child(_sync)


func _transport() -> Node:
	return get_node_or_null(^"/root/NetTransport")


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


func _local_peer_id() -> int:
	var transport: Node = _transport()
	if transport == null or not _transport_is_active():
		return NetConfig.HOST_PEER_ID
	return int(transport.call("local_peer_id"))
