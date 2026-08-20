extends Node

## HaulService — autoload. Spawns and tracks heavy-hauling objects — docs/SPECS.md 3.10,
## DESIGN.md §4.5 "heavy hauling" / §5's solo rule.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Carryable objects" row — added this task): HOST.
## This autoload only spawns/tracks; the per-object request/host-validate/position-simulate story
## lives entirely in systems/hauling/haulable.gd, same split autoload/enemy_world.gd and
## autoload/build_service.gd use for their own spawned entities.
##
## Placed/spawned objects replicate through a code-built MultiplayerSpawner (D-023), mirroring
## autoload/build_service.gd — same reason: a headless spike cannot author .tscn files, and building
## the node tree in code is the only way to guarantee every peer arrives at a byte-identical tree,
## because the high-level API matches nodes by PATH and a mismatch fails as silence rather than an
## error.

const HAULABLE_SCRIPT := preload("res://systems/hauling/haulable.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const LOG_CHANNEL: StringName = &"world"
const CONTAINER_NODE: StringName = &"Haulables"
const SPAWNER_NODE: StringName = &"HaulSpawner"

var _container: Node3D
var _spawner: MultiplayerSpawner
var _next_index: int = 1
## Cached transport ref (F-099 pattern). Path-resolved (F-011 — harnesses install theirs at /root).
var _transport_node: Node


func _ready() -> void:
	_build_spawner()
	# F-032/D-035: NetSession owns run-player identity and decides when a departure is final —
	# rebind moves a carry across a reconnect's new peer id, expire releases it after the grace
	# window. Neither Haulable nor this autoload ever acts on `peer_left` directly (same contract
	# InventoryService's worked no-op example follows). Guarded and path-resolved because this
	# autoload boots in --script harnesses with no session layer at all (F-011).
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null and session.has_signal(&"run_player_rebound"):
		session.connect(&"run_player_rebound", _on_run_player_rebound)
		session.connect(&"run_player_expired", _on_run_player_expired)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


## F-268's sibling, found by that finding's sweep. A haulable is run-scoped world state exactly as a
## placed buildable is, and this file spawns through the same code-built `MultiplayerSpawner` it says
## in its own header it mirrors from `BuildService` — so it inherited the same omission: nothing
## cleared the container on `run_restarted`, and after F-258 the next run draws a FRESH SEED, so a
## surviving crate sits at coordinates chosen against terrain that no longer exists (D-161).
##
## Latent rather than live today: `host_spawn()` has no shipped gameplay caller yet (only
## `tools/haul_check.gd` and `tools/haul_net_check.gd`), so no real run has a crate to strand. Wired
## now because the wiring is the part that gets forgotten — F-268 is precisely the case of a
## subscriber list written from intent while the subscription never shipped.
##
## Unconditional on authority, like every other `run_restarted` subscriber; `host_clear_all()`
## self-guards. Carriers need no explicit release: freeing the body takes its `carriers` list with
## it, and `PlayerHealth`'s own `run_restarted` handler respawns every player regardless.
func _on_run_restarted() -> void:
	host_clear_all()


## Host-only. Frees the node rather than merely forgetting it, for the reason
## `BuildService.host_clear_all()` spells out: these are `MultiplayerSpawner` children, and a
## spawner replays every LIVE spawn to a newly connected peer (`core/net/net_session.gd`).
func host_clear_all() -> void:
	if not _owns_mutation() or _container == null:
		return
	var cleared: int = _container.get_child_count()
	if cleared == 0:
		return
	for child: Node in _container.get_children():
		child.queue_free()
	MireLog.info(LOG_CHANNEL, "run restarted — cleared %d haulable(s)" % cleared)


# ── Spawning (D-023: built in code so every peer's tree is identical) ─────────────────────────────


func _build_spawner() -> void:
	_container = Node3D.new()
	_container.name = CONTAINER_NODE
	add_child(_container)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = SPAWNER_NODE
	_spawner.spawn_limit = 0
	_spawner.spawn_function = _net_spawn_haulable
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_container)


## Host-only. Future world-gen callers (a POI, an ore vein) use this exactly like
## EnemyWorld.host_spawn(); nothing in this task calls it except tools/haul_check.gd and
## tools/haul_net_check.gd.
func host_spawn(def_id: StringName, pos: Vector3) -> Node3D:
	if not _owns_mutation():
		return null
	if _definition(def_id) == null:
		MireLog.error(LOG_CHANNEL, "HaulService: unknown haulable id '%s'" % def_id)
		return null
	return _spawner.spawn({
		"def": String(def_id),
		"index": _take_index(),
		"origin": pos,
	}) as Node3D


## Runs on every peer with the same data, so host and client build identical bodies. Mirrors
## BuildService._net_spawn_piece()'s shape exactly, including the has_method guard that lets a
## future authored scene root bring its own richer script without this ever clobbering it.
func _net_spawn_haulable(data: Variant) -> Node:
	var payload: Dictionary = data as Dictionary
	if payload == null:
		return null
	var def_id: StringName = StringName(String(payload.get("def", "")))
	var def: Resource = _definition(def_id)
	if def == null:
		return null

	var body: Node3D
	var scene: PackedScene = def.get(&"scene")
	if scene != null:
		body = scene.instantiate() as Node3D
	if body == null:
		# No authored art yet — same "framework before content" split BuildableDef makes. Without a
		# real collider this would neither block anything nor be visible, so it is not a
		# convenience placeholder, it is what makes the mechanic provable at all.
		body = _generated_body(def)

	if not body.has_method(&"request_pickup"):
		body.set_script(HAULABLE_SCRIPT)

	body.name = "Haulable%d" % int(payload.get("index", 0))
	body.position = payload.get("origin", Vector3.ZERO)
	body.set(&"def_id", def_id)
	return body


## AnimatableBody3D, not StaticBody3D: this root's Transform3D is rewritten every host physics tick
## by Haulable._physics_process(), and Godot's own docs are explicit that a body meant to be MOVED by
## script (rather than truly static) should be Animatable so it still pushes RigidBodies it touches
## and physics queries see it where it currently is, not where it started.
func _generated_body(def: Resource) -> Node3D:
	var size: Vector3 = def.get(&"size")
	var body := AnimatableBody3D.new()
	body.collision_layer = 1

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	# The spawn origin is the object's FLOOR centre, so the box sits half its height above it —
	# same convention BuildService's generated piece uses.
	shape.position = Vector3(0.0, size.y * 0.5, 0.0)
	body.add_child(shape)

	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.position = shape.position
	body.add_child(mesh_instance)
	return body


func live_count() -> int:
	return 0 if _container == null else _container.get_child_count()


func live_haulables() -> Array[Node]:
	return [] if _container == null else _container.get_children()


## Whether [param peer_id] already carries some OTHER haulable — DESIGN §4.5's "2 players carry"
## reads as one pair of hands per player, not one slot per object. [param exclude] lets a Haulable
## ask this without tripping over its own not-yet-updated `carriers` (harmless either way, since the
## caller checks its own list first, but cheap to make exact).
func is_peer_hauling(peer_id: int, exclude: Node = null) -> bool:
	if _container == null:
		return false
	for child: Node in _container.get_children():
		if child == exclude:
			continue
		if child.has_method(&"is_carrying") and bool(child.call(&"is_carrying", peer_id)):
			return true
	return false


# ── D-035: run-player identity outlives peer_left ────────────────────────────────────────────────


func _on_run_player_rebound(old_peer_id: int, new_peer_id: int) -> void:
	if not _owns_mutation() or _container == null:
		return
	for child: Node in _container.get_children():
		if child.has_method(&"host_rebind_carrier"):
			child.call(&"host_rebind_carrier", old_peer_id, new_peer_id)


func _on_run_player_expired(peer_id: int) -> void:
	if not _owns_mutation() or _container == null:
		return
	for child: Node in _container.get_children():
		if child.has_method(&"host_release_carrier"):
			child.call(&"host_release_carrier", peer_id)


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────


func _definition(def_id: StringName) -> Resource:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method(&"get_haulable"):
		return null
	return registry.call(&"get_haulable", def_id) as Resource


func _take_index() -> int:
	var index: int = _next_index
	_next_index += 1
	return index


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node(^"/root/NetTransport")
	return _transport_node
