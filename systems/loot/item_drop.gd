extends RigidBody3D

## One item lying on the ground — the physical form every yield now takes before it reaches a pack
## (F-535). Spawner-attached, same shape as systems/hauling/haulable.gd: autoload/item_drop_service.gd's
## code-built MultiplayerSpawner (D-023) builds an identical body on every peer and sets `item_id`,
## `amount` and the launch velocity through the spawn payload, before the node enters the tree.
##
## ## Why the item exists in the world at all
##
## Harvesting used to credit the swinger's inventory the instant a prop depleted, so a full pack
## silently voided the yield and a felled tree paid out with no visible event. Sequoyah's call is
## Minecraft's: the item FALLS, then walks into you when you get close, with [E] as the manual
## fallback. That gives the swing a physical read, lets a teammate collect what you knocked loose,
## and — because a rejected `host_add()` now leaves the drop on the ground instead of erasing it —
## makes a full pack recoverable rather than a silent loss.
##
## ## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "World item drops" row): HOST.
##
## The host runs the rigid body, owns the proximity scan that decides an auto-pickup, and is the only
## peer that ever calls `InventoryService.host_add()`. Clients freeze their copy and are moved purely
## by replication, the same host-simulates/client-replicates split Enemy and Haulable use (F-004).
## `request_pickup()` follows the request -> host revalidates from scratch -> replicated result shape
## `Haulable.request_pickup()` established; a client that lies about its position can at worst ask for
## a drop it is nowhere near, and the host's own range check refuses it.
##
## Replicated transform => must be smoothed (D-043). The synchroniser is named
## `NetConfig.PLAYER_SYNC_NODE` so `NetInterp.attach_to()` works with no change, exactly as Haulable does.

const DROP_GROUP: StringName = &"item_drop"

## Minecraft's half-second: a drop cannot be collected while it is still leaving the block it came
## from. Without it the pop-out is invisible — the item would be back in the pack on the same frame
## the swing landed, which is precisely the feel this file exists to replace.
const ARM_SEC: float = 0.5
## Walk-into-it range. Deliberately shorter than the manual reach: auto-pickup should feel like
## brushing past the item, not like a vacuum that empties the clearing from across it.
const AUTO_PICKUP_RANGE_M: float = 1.7
## [E] reach. Matches the interaction distances the focus prompt already offers for a chest or a
## crate, so "the prompt lit up" and "the host accepted" can never disagree.
const MANUAL_PICKUP_RANGE_M: float = 3.2
## How long an uncollected drop survives. Long enough that a full pack can be emptied at camp and the
## logs still be there on the way back; bounded so a long run cannot accumulate rigid bodies forever.
const LIFETIME_SEC: float = 300.0
## 10 Hz. The scan walks every player, and a drop's collection radius is metres wide — a per-frame
## test would cost real time on a clearing full of drops and read no differently (F-099).
const SCAN_SEC: float = 0.1

## Presentation only, applied identically on every peer from a local clock: the icon hovers clear of
## the ground and bobs, which is what makes a small object on busy terrain read as loot rather than
## as scenery — and what stops a log lying in tall grass from being invisible.
const BOB_AMPLITUDE_M: float = 0.07
const BOB_HZ: float = 0.7
## How high the icon floats above the drop's collider. Minecraft's read: the item is clearly ABOVE
## the ground it landed on, not resting in it.
const HOVER_HEIGHT_M: float = 0.38
## Metres across for the icon billboard. `Sprite3D.pixel_size` is derived from this and the texture's
## own width, so a 64 px icon and a 512 px icon end up the same size in the world.
const ICON_SIZE_M: float = 0.34
## Spin, for the fallback cube only — a billboarded icon always faces the camera, so turning it does
## nothing. Kept because a drop with no icon authored yet still has to read as an item.
const SPIN_DEGREES_PER_SEC: float = 55.0

## Fallback cube size when the item authors neither an `icon` nor a `world_model` — content is
## hand-authored (D-073) and some items still ship without either, so this is what keeps every drop
## visible rather than silently empty.
const FALLBACK_SIZE_M: float = 0.22

signal pickup_confirmed(request_id: int, accepted: bool, reason: String)
## Host-side, after the grant landed. `ItemDropService` listens to log it; UI can hang off it later.
signal collected(peer_id: int, item_id: StringName, amount: int)

## Spawn-replicated: what this drop is, and how much of it. Set by
## `ItemDropService._net_spawn_drop()` before `add_child()`, identically on every peer.
@export var item_id: StringName = &""
@export var amount: int = 0

var _visual: Node3D
var _visual_rest_y: float = 0.0
## True while the visual is the billboarded icon, which must not be spun (it always faces you).
var _billboarded: bool = false
var _age: float = 0.0
var _scan_accumulator: float = 0.0
var _collected: bool = false
var _next_request_id: int = 1
var _transport_node: Node
var _inventory_node: Node


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(DROP_GROUP)
	_build_body()
	_build_visual()
	_build_synchronizer()

	# Only the host simulates; a client's copy is placed entirely by replication, so its body must
	# not fight the incoming transform (F-004). STATIC freeze rather than KINEMATIC: nothing on a
	# client writes this transform except the synchroniser.
	var host: bool = _owns_simulation()
	freeze = not host
	if not host:
		freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		var interp: Node = get_node_or_null(^"/root/NetInterp")
		if interp != null:
			interp.call_deferred(&"attach_to", self)
	set_physics_process(host)


## Presentation runs on every peer — the hover and the spin are local, never replicated.
func _process(delta: float) -> void:
	if _visual == null:
		return
	if not _billboarded:
		_visual.rotate_y(deg_to_rad(SPIN_DEGREES_PER_SEC) * delta)
	_visual.position.y = _visual_rest_y + sin(_age * TAU * BOB_HZ) * BOB_AMPLITUDE_M


func _physics_process(delta: float) -> void:
	_age += delta
	if _collected:
		return
	if _age >= LIFETIME_SEC:
		_despawn()
		return
	if _age < ARM_SEC:
		return
	_scan_accumulator += delta
	if _scan_accumulator < SCAN_SEC:
		return
	_scan_accumulator = 0.0
	var peer_id: int = _nearest_peer_within(AUTO_PICKUP_RANGE_M)
	if peer_id > 0:
		_try_collect(peer_id)


# ── Client-facing request seam ───────────────────────────────────────────────────────────────────


## [E]. Returns a local request id immediately; the answer always arrives through
## `pickup_confirmed`, whether this peer is the host or a client.
func request_pickup() -> int:
	var request_id: int = _take_request_id()
	if _owns_simulation():
		_accept_pickup(_local_peer_id(), request_id)
	elif _transport_is_active():
		net_request_pickup.rpc_id(NetConfig.HOST_PEER_ID, request_id)
	else:
		pickup_confirmed.emit(request_id, false, "no authoritative session")
	return request_id


## Whether [E] would be offered at all. False during the arm window, so the prompt cannot promise a
## pickup the host is about to refuse.
func is_collectable() -> bool:
	return not _collected and amount > 0 and _age >= ARM_SEC


## Whether another yield may fold into this pile. Deliberately NOT `is_collectable()`: a burst of
## yields from one swing all arrive inside the arm window, which is precisely when merging matters
## most — gating the merge on arming was what made a ten-log tree leave ten separate piles.
func is_mergeable() -> bool:
	return not _collected and amount > 0


func display_name() -> String:
	var definition: Resource = _item_def()
	if definition != null and not String(definition.get(&"display_name")).is_empty():
		return String(definition.get(&"display_name"))
	return String(item_id).replace("_", " ").capitalize()


## Host-only. Folds another yield of the same item into this drop instead of spawning a second body —
## chopping a tree for ten logs leaves ONE pile, not ten. Refused once collected, so a merge can
## never resurrect a drop that has already paid out.
func host_merge(extra: int) -> bool:
	if not _owns_simulation() or _collected or extra <= 0:
		return false
	amount += extra
	# The pile is fresh again: a drop that keeps growing should not expire on the first yield's clock.
	_age = minf(_age, ARM_SEC)
	return true


# ── Host decisions ───────────────────────────────────────────────────────────────────────────────


func _accept_pickup(peer_id: int, request_id: int) -> void:
	if not _owns_simulation() or _collected:
		_answer(peer_id, request_id, false, "already collected")
		return
	if _age < ARM_SEC:
		_answer(peer_id, request_id, false, "still settling")
		return
	if not _peer_within(peer_id, MANUAL_PICKUP_RANGE_M):
		_answer(peer_id, request_id, false, "too far away")
		return
	if not _try_collect(peer_id):
		_answer(peer_id, request_id, false, "pack is full")
		return
	_answer(peer_id, request_id, true, "")


## The single grant seam. A refusal (a full pack) leaves the drop lying exactly where it was, which
## is the whole reason the item became physical: nothing is destroyed by a failed collection.
func _try_collect(peer_id: int) -> bool:
	if _collected or peer_id <= 0 or amount <= 0:
		return false
	var inventory: Node = _inventory()
	if inventory == null:
		return false
	if not bool(inventory.call(&"host_add", peer_id, item_id, amount)):
		return false
	_collected = true
	collected.emit(peer_id, item_id, amount)
	MireLog.info(&"inventory", "peer %d picked up %d %s from the ground" % [peer_id, amount, item_id])
	_despawn()
	return true


func _despawn() -> void:
	_collected = true
	# Detached first, so `ItemDropService.live_count()` and the merge scan stop seeing this drop on
	# the same frame it paid out rather than at the end of it (a queued free stays a child).
	var parent: Node = get_parent()
	if parent != null:
		parent.remove_child(self)
	queue_free()


# ── Replication ──────────────────────────────────────────────────────────────────────────────────


@rpc("any_peer", "call_remote", "reliable")
func net_request_pickup(request_id: int) -> void:
	if not _transport_is_host():
		return
	_accept_pickup(multiplayer.get_remote_sender_id(), request_id)


@rpc("authority", "call_remote", "reliable")
func net_pickup_result(request_id: int, accepted: bool, reason: String) -> void:
	pickup_confirmed.emit(request_id, accepted, reason)


func _answer(peer_id: int, request_id: int, accepted: bool, reason: String) -> void:
	if peer_id == _local_peer_id():
		pickup_confirmed.emit(request_id, accepted, reason)
		return
	if _transport_is_active() and _peer_connected(peer_id):
		net_pickup_result.rpc_id(peer_id, request_id, accepted, reason)


# ── Construction ─────────────────────────────────────────────────────────────────────────────────


## Layer 0, mask terrain-plus-world: a drop must LAND on the ground, but nothing should ever have to
## walk around one. Colliding with players would let a pile of logs shove someone off a ledge, and
## colliding with each other would turn a ten-log yield into a jitter pit.
func _build_body() -> void:
	collision_layer = 0
	collision_mask = 1 | PlacementValidator.TERRAIN_LAYER
	# A sphere, not a box: it rolls off a slope and settles instead of balancing on an edge, and it
	# is the cheapest shape Jolt has.
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = FALLBACK_SIZE_M * 0.5
	shape.shape = sphere
	shape.position.y = sphere.radius
	add_child(shape)
	# Drops settle rather than skate; without damping a popped item slides for metres on flat ground.
	linear_damp = 0.6
	angular_damp = 4.0
	# The body itself never turns — the visual child owns the spin, so a tumbling collider cannot
	# desync the look from the replicated transform.
	axis_lock_angular_x = true
	axis_lock_angular_y = true
	axis_lock_angular_z = true


## The item's own inventory ICON, floating above the ground and facing you — Minecraft's read, and
## Sequoyah's call. It is the right thing for MIRE specifically: every item already authors an icon
## (`tools/item_icons_check.gd` asserts it), while `world_model` is authored for only a handful, so
## the icon is the one visual that is guaranteed to exist and to be instantly recognisable as the
## same thing the player will see in their pack.
func _build_visual() -> void:
	var definition: Resource = _item_def()
	var icon: Texture2D = definition.get(&"icon") as Texture2D if definition != null else null
	if icon != null:
		var sprite := Sprite3D.new()
		sprite.texture = icon
		# Faces the camera on every axis: the icon is a flat picture, and a picture seen edge-on is
		# an invisible drop.
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		# Unshaded, so a log lying in night-time shadow is still legible as a log — the icon is a
		# UI-like affordance that happens to live in the world, not a lit surface.
		sprite.shaded = false
		# Alpha SCISSOR rather than blending: icons are cut-outs, and a blended transparent quad both
		# sorts badly against foliage and writes no depth for the hover to read against.
		sprite.transparent = true
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		var widest: int = maxi(icon.get_width(), icon.get_height())
		sprite.pixel_size = ICON_SIZE_M / float(maxi(widest, 1))
		_visual = sprite
		_billboarded = true
	if _visual == null:
		var world_model: PackedScene = definition.get(&"world_model") as PackedScene if definition != null else null
		if world_model != null:
			_visual = world_model.instantiate() as Node3D
	if _visual == null:
		var mesh_instance := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3.ONE * FALLBACK_SIZE_M
		mesh_instance.mesh = box
		_visual = mesh_instance
	# The icon hovers; a real model or the fallback cube sits just clear of the collider's centre so
	# the bob never sinks it into the ground.
	_visual_rest_y = HOVER_HEIGHT_M if _billboarded else FALLBACK_SIZE_M * 0.5
	_visual.position.y = _visual_rest_y
	add_child(_visual)


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	var position_path := NodePath(".:position")
	config.add_property(position_path)
	config.property_set_spawn(position_path, true)
	config.property_set_replication_mode(
		position_path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS
	)
	# Discrete state: the stack grows only when a merge folds a second yield in, and it wants to snap
	# on arrival rather than blend (D-043's reasoning for Chest.opened).
	var amount_path := NodePath(".:amount")
	config.add_property(amount_path)
	config.property_set_spawn(amount_path, true)
	config.property_set_replication_mode(
		amount_path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
	)

	var sync := MultiplayerSynchronizer.new()
	sync.name = NetConfig.PLAYER_SYNC_NODE
	sync.root_path = NodePath("..")
	sync.replication_config = config
	# BEFORE add_child, never after (F-012).
	sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	NetInterest.configure(sync, self, NetInterest.Class.ENEMY)
	add_child(sync)


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────


## Nearest player inside [param range_m], or 0. Reads the players group rather than PlayerNet so that
## offline runs — which spawn a player with no PlayerNet container — collect exactly like a session
## does; a body's multiplayer authority IS its peer id (the same identity `player_controller.gd`
## reads when it looks for a downed teammate).
func _nearest_peer_within(range_m: float) -> int:
	var best_peer: int = 0
	var best_distance: float = range_m * range_m
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var body := node as Node3D
		if body == null or not body.is_inside_tree():
			continue
		var distance: float = global_position.distance_squared_to(body.global_position)
		if distance > best_distance:
			continue
		best_distance = distance
		best_peer = body.get_multiplayer_authority()
	return best_peer


func _peer_within(peer_id: int, range_m: float) -> bool:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var body := node as Node3D
		if body == null or body.get_multiplayer_authority() != peer_id:
			continue
		return global_position.distance_squared_to(body.global_position) <= range_m * range_m
	# Offline harnesses spawn no player body at all — same fallback Chest and Haulable make: the
	# local interact that owns the call is the validation seam there.
	return not _transport_is_active()


func _item_def() -> Resource:
	if item_id == &"":
		return null
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method(&"get_item"):
		return null
	return registry.call(&"get_item", item_id) as Resource


func _inventory() -> Node:
	if _inventory_node == null or not is_instance_valid(_inventory_node):
		_inventory_node = get_node_or_null(^"/root/InventoryService")
	return _inventory_node


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
