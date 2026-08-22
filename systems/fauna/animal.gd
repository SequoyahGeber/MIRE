class_name Animal
extends CharacterBody3D

## One living animal. Phase 1 of docs/FAUNA.md: it exists, it stands where the world put it, and it
## is the same node on every peer. Behaviour — grazing, fleeing, the charge of §2's boar — is Phase 3
## and deliberately absent rather than stubbed, because a half-written flee is harder to replace than
## an empty one.
##
## ## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Enemy AI, spawns, damage" row): HOST.
##
## `FaunaService` spawns these through a code-built `MultiplayerSpawner` (D-023), so every peer
## builds an identical body from the same payload before it enters the tree — the shape `ItemDrop`
## and `Haulable` already use. The host simulates; a client's copy is placed purely by replication
## and never runs AI, exactly the split `Enemy` documents (F-004). Replicated transform => must be
## smoothed (D-043), so the synchroniser is named `NetConfig.PLAYER_SYNC_NODE` and `NetInterp`
## attaches to it unchanged.

const ANIMAL_GROUP: StringName = &"fauna"

## Placeholder body, until Phase 2's art. A capsule is chosen over a box on purpose: it is the shape
## a quadruped's collider will actually be, so the collision behaviour a playtest sees now is the
## behaviour it will see after the art lands rather than something that changes underneath it.
const PLACEHOLDER_RADIUS_FRACTION: float = 0.32

## Spawn-replicated, set by `FaunaService._net_spawn_animal()` before `add_child()`.
@export var animal_id: StringName = &""

var _definition: Resource
var _sync: MultiplayerSynchronizer
var _visual: Node3D
var _gravity: float = 9.8


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(ANIMAL_GROUP)
	_definition = _resolve_definition()
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_build_body()
	_build_visual()
	_build_synchronizer()

	# Host simulates, client is replicated into place (F-004). A client's body must not fight the
	# incoming transform, so it does not run physics at all.
	var host: bool = _owns_simulation()
	set_physics_process(host)
	if not host:
		var interp: Node = get_node_or_null(^"/root/NetInterp")
		if interp != null:
			interp.call_deferred(&"attach_to", self)


## Phase 1 physics is gravity and nothing else: the animal stays on the ground it was placed on, and
## on ground that turns out to be a slope it settles rather than hanging in the air. Movement arrives
## with the AI in Phase 3.
func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0
	move_and_slide()


func definition() -> Resource:
	return _definition


func display_name() -> String:
	if _definition != null and not String(_definition.get(&"display_name")).is_empty():
		return String(_definition.get(&"display_name"))
	return String(animal_id).replace("_", " ").capitalize()


func _resolve_definition() -> Resource:
	if animal_id == &"":
		return null
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method(&"get_animal"):
		return null
	return registry.call(&"get_animal", animal_id) as Resource


func _build_body() -> void:
	var height: float = _body_size()
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = height * PLACEHOLDER_RADIUS_FRACTION
	capsule.height = maxf(height, capsule.radius * 2.0 + 0.01)
	shape.shape = capsule
	shape.position.y = capsule.height * 0.5
	add_child(shape)
	# Layer 1 with the rest of the world's bodies: an animal is something you bump into and, from
	# Phase 3, something you can shoot. It does not join `damageable` yet — nothing can kill it until
	# drops exist, and a killable animal that drops nothing would be a worse first impression than
	# one that cannot be killed at all.
	collision_layer = 1
	collision_mask = 1 | PlacementValidator.TERRAIN_LAYER


## The authored `model` when there is one, and a tinted capsule until Phase 2 authors it. Built on
## every peer from the definition, never replicated — presentation is client-local (§3).
func _build_visual() -> void:
	var model: PackedScene = _definition.get(&"model") as PackedScene if _definition != null else null
	if model != null:
		_visual = model.instantiate() as Node3D
	if _visual == null:
		var height: float = _body_size()
		var mesh := CapsuleMesh.new()
		mesh.radius = height * PLACEHOLDER_RADIUS_FRACTION
		mesh.height = maxf(height, mesh.radius * 2.0 + 0.01)
		var material := StandardMaterial3D.new()
		material.albedo_color = _tint()
		# Roughness rather than the default half-gloss: a placeholder that reads as a plastic pill
		# invites feedback about the shading instead of about the placement, which is the only thing
		# Phase 1 is asking anyone to judge.
		material.roughness = 0.95
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		instance.position.y = mesh.height * 0.5
		_visual = instance
	_visual.name = "AnimalVisual"
	add_child(_visual)


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	var position_path := NodePath(".:position")
	config.add_property(position_path)
	config.property_set_spawn(position_path, true)
	config.property_set_replication_mode(
		position_path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS
	)
	var rotation_path := NodePath(".:rotation")
	config.add_property(rotation_path)
	config.property_set_spawn(rotation_path, true)
	config.property_set_replication_mode(
		rotation_path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS
	)

	_sync = MultiplayerSynchronizer.new()
	# The name NetInterp looks for (D-043) — a replicated transform that is not smoothed is the
	# stutter F-004 and D-043 exist to prevent.
	_sync.name = NetConfig.PLAYER_SYNC_NODE
	_sync.root_path = NodePath("..")
	_sync.replication_config = config
	_sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	_sync.add_to_group(NetConfig.SYNCED_GROUP)
	add_child(_sync)


func _body_size() -> float:
	var size: float = float(_definition.get(&"body_size_m")) if _definition != null else 1.0
	return maxf(size, 0.1)


func _tint() -> Color:
	return _definition.get(&"tint") as Color if _definition != null else Color(0.72, 0.63, 0.48)


func _owns_simulation() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
