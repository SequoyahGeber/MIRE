class_name Harvestable
extends Node3D

## Hit -> damage -> yield -> logical despawn -> respawn for a static world prop.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md section 2.2, world mutation row): HOST.
## Clients may request one definition-authored hit, but send neither damage nor yield. The host
## checks the sender's player, range and cooldown, applies damage, emits the yield event exactly
## once, disables the prop, and runs the respawn clock. Health, visual state and active state are
## replicated on-change through a code-built MultiplayerSynchronizer (D-023). Offline play runs the
## same authority path locally.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const HARVESTABLE_DEFINITION := preload("res://systems/harvesting/harvestable_def.gd")
const SYNC_NODE_NAME: StringName = &"HarvestSync"
const VISUAL_NODE_NAME: StringName = &"HarvestVisual"
const HARVESTABLE_GROUP: StringName = &"harvestable"

signal hit_accepted(peer_id: int, damage: int, health_remaining: int)
signal depleted(peer_id: int, item_id: StringName, amount: int)
signal respawned

@export var definition: HARVESTABLE_DEFINITION
@export_node_path("CollisionObject3D") var collision_body_path: NodePath

## Replicated state. Setters keep presentation correct when a network delta arrives on a client.
var health: int = 0:
	set(value):
		health = value

var visual_state: int = 0:
	set(value):
		if visual_state == value:
			return
		visual_state = value
		_refresh_visual()

var active: bool = true:
	set(value):
		if active == value:
			return
		active = value
		_refresh_collision()
		_refresh_visual()

var _configuration_valid: bool = false
var _collision_body: CollisionObject3D
var _collision_layer: int = 0
var _collision_mask: int = 0
var _visual: Node3D
var _sync: MultiplayerSynchronizer
var _respawn_remaining: float = 0.0
var _last_request_msec: Dictionary[int, int] = {}


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(HARVESTABLE_GROUP)
	_resolve_collision_body()
	_configuration_valid = _validate_configuration()

	if definition != null:
		health = definition.max_health
		visual_state = 0
		active = true

	_build_synchronizer()
	_refresh_collision()
	_refresh_visual()
	set_physics_process(_owns_world_mutation() and _configuration_valid)


## Convenience path for an interact/raycast hit. A client sends no parameters, so it cannot choose
## damage or yield. The host validates the sender and reads damage_per_hit from HarvestableDef.
func request_hit() -> void:
	if not _configuration_valid or not active:
		return
	if not _transport_is_active() or _transport_is_host():
		_accept_hit_request(_local_peer_id())
	else:
		net_request_hit.rpc_id(NetConfig.HOST_PEER_ID)


## Trusted host seam for task 2.8's hitbox. Combat owns attack validation and damage calculation;
## this method still rejects non-authority callers, non-positive damage and depleted props.
func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
	if not _owns_world_mutation() or not _configuration_valid or not active or amount <= 0:
		return false

	health = maxi(health - amount, 0)
	visual_state = _state_for_health(health)
	hit_accepted.emit(instigator_peer_id, amount, health)

	if health == 0:
		_deplete(instigator_peer_id)
	return true


## Host-only explicit reset for admin commands and deterministic checks. Normal gameplay uses the
## physics-tick respawn clock.
func host_respawn() -> bool:
	if not _owns_world_mutation() or not _configuration_valid or active:
		return false
	_respawn_remaining = 0.0
	health = definition.max_health
	visual_state = 0
	active = true
	_last_request_msec.clear()
	respawned.emit()
	return true


func respawn_remaining() -> float:
	return _respawn_remaining


@rpc("any_peer", "call_remote", "reliable")
func net_request_hit() -> void:
	if not _transport_is_host():
		return
	_accept_hit_request(multiplayer.get_remote_sender_id())


func _accept_hit_request(peer_id: int) -> void:
	if not _request_is_valid(peer_id):
		return
	_last_request_msec[peer_id] = Time.get_ticks_msec()
	host_apply_damage(definition.damage_per_hit, peer_id)


func _request_is_valid(peer_id: int) -> bool:
	if not _owns_world_mutation() or not active or peer_id <= 0:
		return false

	var cooldown_msec: int = ceili(definition.request_cooldown_seconds * 1000.0)
	var now_msec: int = Time.get_ticks_msec()
	if _last_request_msec.has(peer_id):
		var elapsed_msec: int = now_msec - _last_request_msec[peer_id]
		if elapsed_msec < cooldown_msec:
			return false

	# Offline mode has no PlayerNet spawn. The local raycast that owns this call is the validation
	# seam there; in a session the host must independently verify the remote player's position.
	if not _transport_is_active():
		return true

	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net == null or not player_net.has_method("player_for"):
		return false
	var player: Node3D = player_net.call("player_for", peer_id) as Node3D
	if player == null:
		return false
	var range_sq: float = definition.request_range_m * definition.request_range_m
	return global_position.distance_squared_to(player.global_position) <= range_sq


func _deplete(instigator_peer_id: int) -> void:
	active = false
	visual_state = definition.active_state_scenes.size()
	_respawn_remaining = definition.respawn_seconds
	depleted.emit(instigator_peer_id, definition.yield_item_id, definition.yield_amount)
	EVENT_BUS.emit_harvest_yielded(
		definition.id,
		instigator_peer_id,
		definition.yield_item_id,
		definition.yield_amount,
		global_position
	)


func _physics_process(delta: float) -> void:
	if active or not _owns_world_mutation():
		return
	_respawn_remaining = maxf(_respawn_remaining - delta, 0.0)
	if _respawn_remaining <= 0.0:
		host_respawn()


func _state_for_health(value: int) -> int:
	if value <= 0:
		return definition.active_state_scenes.size()
	var state_count: int = definition.active_state_scenes.size()
	var damage_fraction: float = 1.0 - float(value) / float(definition.max_health)
	return clampi(floori(damage_fraction * float(state_count)), 0, state_count - 1)


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property_name: StringName in [&"health", &"visual_state", &"active"]:
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


func _resolve_collision_body() -> void:
	if not collision_body_path.is_empty():
		_collision_body = get_node_or_null(collision_body_path) as CollisionObject3D
	else:
		var bodies: Array[Node] = find_children("*", "CollisionObject3D", true, false)
		if not bodies.is_empty():
			_collision_body = bodies[0] as CollisionObject3D
	if _collision_body != null:
		_collision_layer = _collision_body.collision_layer
		_collision_mask = _collision_body.collision_mask


func _refresh_collision() -> void:
	if _collision_body == null:
		return
	_collision_body.set_deferred("collision_layer", _collision_layer if active else 0)
	_collision_body.set_deferred("collision_mask", _collision_mask if active else 0)
	for child: Node in _collision_body.find_children("*", "CollisionShape3D", true, false):
		(child as CollisionShape3D).set_deferred("disabled", not active)


func _refresh_visual() -> void:
	if not is_inside_tree() or definition == null:
		return
	var scene: PackedScene
	if active:
		if visual_state < 0 or visual_state >= definition.active_state_scenes.size():
			return
		scene = definition.active_state_scenes[visual_state]
	else:
		scene = definition.depleted_scene

	if _visual != null:
		remove_child(_visual)
		_visual.queue_free()
		_visual = null
	if scene == null:
		return

	_visual = scene.instantiate() as Node3D
	if _visual == null:
		push_error("Harvestable %s: state scene root must be Node3D" % name)
		return
	_visual.name = VISUAL_NODE_NAME
	add_child(_visual)


func _validate_configuration() -> bool:
	if definition == null:
		push_error("Harvestable %s has no definition" % name)
		return false
	var errors: PackedStringArray = definition.validation_errors()
	if not errors.is_empty():
		push_error("Harvestable %s definition is invalid: %s" % [name, "; ".join(errors)])
		return false

	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("has_item"):
		push_error("Harvestable %s cannot validate yield item without Registry" % name)
		return false
	if not bool(registry.call("has_item", definition.yield_item_id)):
		push_error(
			"Harvestable %s references unknown yield item '%s'"
			% [name, definition.yield_item_id]
		)
		return false
	return true


func _owns_world_mutation() -> bool:
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
