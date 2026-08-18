extends Node

## BuildService — autoload. Places and destroys buildable pieces.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "world mutation" row): **HOST**. A client asks; the
## host decides, charges, and spawns. There is no client-side spawn path and there must not be one —
## a wall a client can conjure is a wall a client can conjure for free, inside you, on the extraction
## pad. Protocol 12 carries three RPCs:
##
##   · `net_request_place`   client -> host, piece id + transform. Reliable: a dropped build request
##                           is a player pressing the button and nothing happening.
##   · `net_request_destroy` client -> host, the piece's node name. The host resolves the
##                           requester's own body and re-enforces the piece def's
##                           `max_build_range_m`, the same rule placement trusts nobody about — a
##                           piece's node name is never itself proof of the right to destroy it
##                           (F-084). Ownership is not checked; any peer in range may clear it.
##   · `net_build_result`    host -> the one requester, accepted/reason for its request id.
##
## THE HOST REVALIDATES FROM SCRATCH. `PlacementValidator.evaluate()` runs again here, against the
## host's own space state, and the only things believed from the wire are the piece id and the
## transform — both of which are then re-checked. The client's green ghost is a hint it drew for its
## own player, never an input to this decision. Sharing the validator's CODE with the ghost is what
## keeps the hint honest; it is not what makes the decision.
##
## Placed pieces replicate through a code-built MultiplayerSpawner (D-023), mirroring
## autoload/enemy_world.gd — same reason: a headless spike cannot author .tscn files, and building
## the node tree in code is the only way to guarantee every peer arrives at a byte-identical tree,
## because the high-level API matches nodes by PATH and a mismatch fails as silence rather than as an
## error.

const VALIDATOR := preload("res://systems/building/placement_validator.gd")
## F-085: the `&"damageable"` group's damage implementation. Attached to whichever piece root
## doesn't already bring its own — see `_net_spawn_piece()` and the script's own doc comment.
const BUILDABLE_PIECE := preload("res://systems/building/buildable_piece.gd")

const LOG_CHANNEL: StringName = &"world"
const CONTAINER_NODE: StringName = &"Buildings"
const SPAWNER_NODE: StringName = &"BuildSpawner"
const PIECE_GROUP: StringName = &"buildable_piece"
const DAMAGEABLE_GROUP: StringName = &"damageable"

## Layers the validator queries. World statics, props and existing pieces all sit on 1 today — see
## F-075, which is why the validator has to lift its overlap box off the ground rather than simply
## not looking at it.
const QUERY_MASK: int = 1

## docs/SPECS.md 3.6: rebake navigation after any placement or destruction, **debounced**, one per
## second at most. A full-level rebake is the M2-scale answer and costs real milliseconds (21,364
## polygons on Hollowmere); a player dragging out a ten-piece wall would otherwise trigger ten of
## them back to back and hitch the host every time. Per-chunk baking is task 4.5's problem.
const NAV_REBAKE_INTERVAL_SEC: float = 1.0

signal build_confirmed(request_id: int, accepted: bool, reason: String)
## Host-side, for anything that wants to react to the world changing shape.
signal piece_placed(piece: Node3D, def_id: StringName, owner_peer_id: int)
signal piece_destroyed(def_id: StringName, owner_peer_id: int)

var _container: Node3D
var _spawner: MultiplayerSpawner
var _next_index: int = 1
var _next_request_id: int = 1
## Piece node name -> { "def": StringName, "owner": int }. Host-side only; it is what a destroy
## request is resolved against and what a refund is computed from.
var _placed: Dictionary[StringName, Dictionary] = {}
var _nav_rebake_pending: bool = false
var _nav_rebake_elapsed: float = 0.0
## Cached transport ref (F-099). Path-resolved (F-011 — harnesses install theirs at /root).
var _transport_node: Node


func _ready() -> void:
	_build_spawner()
	# The tick exists only to time a pending nav rebake; _request_nav_rebake() turns it on (F-099).
	set_physics_process(false)
	_register_commands()



func _physics_process(delta: float) -> void:
	if not _nav_rebake_pending:
		set_physics_process(false)
		return
	_nav_rebake_elapsed += delta
	if _nav_rebake_elapsed < NAV_REBAKE_INTERVAL_SEC:
		return
	_nav_rebake_pending = false
	_nav_rebake_elapsed = 0.0
	set_physics_process(false)
	var enemy_world: Node = get_node_or_null(^"/root/EnemyWorld")
	if enemy_world != null and enemy_world.has_method(&"bake_navigation"):
		enemy_world.call(&"bake_navigation")


# ── Client-facing request seam ───────────────────────────────────────────────────────────────────


## Returns a local request id immediately; the answer always arrives through `build_confirmed`.
## Same shape as InventoryService.request_remove() and Chest.request_open() — a build is a round
## trip and pretending otherwise is how a UI ends up lying about what it owns.
func request_place(piece_id: StringName, placement: Transform3D) -> int:
	var request_id: int = _take_request_id()
	if _owns_mutation():
		_process_place(_local_peer_id(), piece_id, placement, request_id)
	elif bool(_transport().call("is_active")):
		net_request_place.rpc_id(NetConfig.HOST_PEER_ID, String(piece_id), placement, request_id)
	else:
		build_confirmed.emit(request_id, false, "no authoritative session")
	return request_id


func request_destroy(piece_name: StringName) -> int:
	var request_id: int = _take_request_id()
	if _owns_mutation():
		_process_destroy(_local_peer_id(), piece_name, request_id)
	elif bool(_transport().call("is_active")):
		net_request_destroy.rpc_id(NetConfig.HOST_PEER_ID, String(piece_name), request_id)
	else:
		build_confirmed.emit(request_id, false, "no authoritative session")
	return request_id


# ── Host decisions ───────────────────────────────────────────────────────────────────────────────


## The whole authority story in one function. Nothing above it is trusted and nothing below it runs
## unless every rule passed.
func _process_place(
	peer_id: int, piece_id: StringName, placement: Transform3D, request_id: int
) -> void:
	if not _owns_mutation():
		return
	var def: Resource = _definition(piece_id)
	if def == null:
		_answer(peer_id, request_id, false, VALIDATOR.reason_text(VALIDATOR.Reason.UNKNOWN_PIECE))
		return

	# Re-snap rather than trusting the client's transform. A client that sends an unsnapped or
	# absurd transform gets it corrected, not honoured — and snapping is pure, so the host's answer
	# is the same one an honest client already computed for itself.
	var snapped: Transform3D = VALIDATOR.snap_transform(
		def, placement.origin, placement.basis.get_euler().y)

	var reason: int = VALIDATOR.evaluate(
		_space_state(), def, snapped, _builder_position(peer_id, snapped.origin), QUERY_MASK)
	if reason != VALIDATOR.Reason.OK:
		_answer(peer_id, request_id, false, VALIDATOR.reason_text(reason))
		return

	# Cost last, because it is the only check with a side effect: rejecting after a successful
	# host_transaction would silently eat the materials.
	var cost: Dictionary = def.get(&"cost")
	if not cost.is_empty():
		var inventory: Node = get_node_or_null(^"/root/InventoryService")
		if inventory == null or not bool(
			inventory.call(&"host_transaction", peer_id, cost, {} as Dictionary)
		):
			_answer(peer_id, request_id, false,
				VALIDATOR.reason_text(VALIDATOR.Reason.CANNOT_AFFORD))
			return

	var piece: Node3D = _spawn_piece(piece_id, snapped)
	if piece == null:
		# Refund: the transaction above already succeeded, so failing to spawn without giving the
		# materials back would charge the player for nothing.
		if not cost.is_empty():
			var inventory: Node = get_node_or_null(^"/root/InventoryService")
			if inventory != null:
				inventory.call(&"host_transaction", peer_id, {} as Dictionary, cost)
		_answer(peer_id, request_id, false, "could not place it")
		return

	_placed[StringName(piece.name)] = {"def": piece_id, "owner": peer_id}
	_request_nav_rebake()
	piece_placed.emit(piece, piece_id, peer_id)
	MireLog.info(LOG_CHANNEL, "peer %d placed %s at %s" % [peer_id, piece_id, snapped.origin])
	_answer(peer_id, request_id, true, "")


func _process_destroy(peer_id: int, piece_name: StringName, request_id: int) -> void:
	if not _owns_mutation():
		return
	if not _placed.has(piece_name):
		_answer(peer_id, request_id, false, "no such piece")
		return
	var record: Dictionary = _placed[piece_name]
	var piece: Node = _container.get_node_or_null(NodePath(String(piece_name)))
	if piece == null:
		_placed.erase(piece_name)
		_answer(peer_id, request_id, false, "no such piece")
		return

	var def_id: StringName = record["def"]
	var def: Resource = _definition(def_id)

	# F-084: destruction mirrors placement (docs/SPECS.md 3.6) — the host resolves the requesting
	# player's OWN body and enforces the same range rule `_process_place` already trusts nobody
	# about, rather than treating `_placed.has(piece_name)` alone as authority. Node names are
	# sequential ("Piece1", "Piece2", ...), so without this any peer could enumerate every piece on
	# the map and free/refund it from wherever they stood. Ownership is deliberately NOT checked
	# here — the refund-to-whoever-tears-it-down comment below is an existing, intentional design
	# choice that any teammate may clear a misplaced piece; only the range that already gates
	# placement gates its reversal.
	if def != null:
		var range_m: float = float(def.get(&"max_build_range_m"))
		var piece_position: Vector3 = (piece as Node3D).global_position
		if _builder_position(peer_id, piece_position).distance_to(piece_position) > range_m:
			_answer(peer_id, request_id, false, VALIDATOR.reason_text(VALIDATOR.Reason.OUT_OF_RANGE))
			return

	# Refund goes to whoever tears it down, not to whoever built it — otherwise clearing a
	# teammate's misplaced wall costs you and pays them.
	if def != null:
		var refund: Dictionary = _refund_for(def)
		if not refund.is_empty():
			var inventory: Node = get_node_or_null(^"/root/InventoryService")
			if inventory != null:
				inventory.call(&"host_transaction", peer_id, {} as Dictionary, refund)

	_placed.erase(piece_name)
	piece.queue_free()
	_request_nav_rebake()
	piece_destroyed.emit(def_id, int(record["owner"]))
	_answer(peer_id, request_id, true, "")


## F-085: called by `systems/building/buildable_piece.gd` once its host-side hp reaches zero. Not a
## teardown request, so unlike `_process_destroy` there is neither a range check (whoever landed the
## killing blow already had to pass the weapon's own range/arc test in `CombatService`) nor a refund
## (a piece that was fought and lost is not one its owner meant to reclaim — the same as a
## Harvestable or an Enemy never paying out on death).
func host_piece_destroyed_by_damage(piece_name: StringName, instigator_peer_id: int) -> void:
	if not _owns_mutation() or not _placed.has(piece_name):
		return
	var record: Dictionary = _placed[piece_name]
	var piece: Node = _container.get_node_or_null(NodePath(String(piece_name)))
	_placed.erase(piece_name)
	if piece != null:
		piece.queue_free()
	_request_nav_rebake()
	piece_destroyed.emit(StringName(String(record.get("def", ""))), int(record.get("owner", 0)))
	MireLog.info(LOG_CHANNEL, "peer %d destroyed %s by damage" % [instigator_peer_id, piece_name])


## floor(cost * refund_fraction) per item, never more than was paid and never a fractional log.
func _refund_for(def: Resource) -> Dictionary:
	var fraction: float = float(def.get(&"refund_fraction"))
	var refund: Dictionary = {}
	if fraction <= 0.0:
		return refund
	var cost: Dictionary = def.get(&"cost") as Dictionary
	for item_id: StringName in cost:
		var amount: int = int(floorf(float(cost[item_id]) * fraction))
		if amount > 0:
			refund[item_id] = amount
	return refund


func _request_nav_rebake() -> void:
	_nav_rebake_pending = true
	set_physics_process(true)


func placed_count() -> int:
	return _placed.size()


func placed_record(piece_name: StringName) -> Dictionary:
	return (_placed.get(piece_name, {} as Dictionary) as Dictionary).duplicate()


# ── Spawning (D-023: built in code so every peer's tree is identical) ─────────────────────────────


func _build_spawner() -> void:
	_container = Node3D.new()
	_container.name = CONTAINER_NODE
	add_child(_container)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = SPAWNER_NODE
	_spawner.spawn_limit = 0
	_spawner.spawn_function = _net_spawn_piece
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_container)


func _spawn_piece(piece_id: StringName, placement: Transform3D) -> Node3D:
	var spawned: Node = _spawner.spawn({
		"def": String(piece_id),
		"index": _take_index(),
		"origin": placement.origin,
		"yaw": placement.basis.get_euler().y,
	})
	return spawned as Node3D


## Runs on every peer with the same data, so host and client build identical bodies. The name is
## derived from the spawn index and set before the node enters the tree, matching how EnemyWorld
## names enemies and PlayerNet names players.
func _net_spawn_piece(data: Variant) -> Node:
	var payload: Dictionary = data as Dictionary
	if payload == null:
		return null
	var def: Resource = _definition(StringName(String(payload.get("def", ""))))
	if def == null:
		return null

	var piece: Node3D
	var scene: PackedScene = def.get(&"scene")
	if scene != null:
		piece = scene.instantiate() as Node3D
	if piece == null:
		# No authored art yet — task 3.7 supplies it. A generated box is not a placeholder for
		# convenience: without a real collider the piece would not block anything, would not appear
		# in the navmesh rebake, and every placement rule that queries the world would be testing
		# against nothing.
		piece = _generated_piece(def)

	piece.name = "Piece%d" % int(payload.get("index", 0))
	piece.position = payload.get("origin", Vector3.ZERO)
	piece.rotation.y = float(payload.get("yaw", 0.0))
	piece.add_to_group(PIECE_GROUP)
	piece.add_to_group(DAMAGEABLE_GROUP)
	piece.set_meta(&"buildable_id", String(payload.get("def", "")))

	# F-085: `&"damageable"`'s contract is `host_apply_damage()`, not the tag alone. A generated
	# piece never has one; a future authored scene root might bring its own richer one (staged
	# damage states) — only fall back to the shared implementation when nothing is there already,
	# so this never clobbers a root that already knows how to take a hit.
	if not piece.has_method(&"host_apply_damage"):
		piece.set_script(BUILDABLE_PIECE)
		piece.set(&"hp", int(def.get(&"max_hp")))
	return piece


func _generated_piece(def: Resource) -> Node3D:
	var size: Vector3 = def.get(&"size")
	var body := StaticBody3D.new()
	body.collision_layer = QUERY_MASK

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	# The placement origin is the piece's FLOOR centre, so the box sits half its height above it.
	shape.position = Vector3(0.0, size.y * 0.5, 0.0)
	body.add_child(shape)

	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.position = shape.position
	body.add_child(mesh_instance)
	return body


# ── Replication ──────────────────────────────────────────────────────────────────────────────────


@rpc("any_peer", "call_remote", "reliable")
func net_request_place(piece_id: String, placement: Transform3D, request_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_process_place(
		multiplayer.get_remote_sender_id(), StringName(piece_id), placement, request_id)


@rpc("any_peer", "call_remote", "reliable")
func net_request_destroy(piece_name: String, request_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_process_destroy(multiplayer.get_remote_sender_id(), StringName(piece_name), request_id)


@rpc("authority", "call_remote", "reliable")
func net_build_result(request_id: int, accepted: bool, reason: String) -> void:
	if _owns_mutation():
		return
	build_confirmed.emit(request_id, accepted, reason)


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────


func _answer(peer_id: int, request_id: int, accepted: bool, reason: String) -> void:
	if peer_id == _local_peer_id():
		build_confirmed.emit(request_id, accepted, reason)
		return
	# F-059: rpc_id() to a peer that has already gone throws "unknown peer ID". A build request from
	# someone who disconnected mid-round-trip is an ordinary case, not an exotic one.
	if bool(_transport().call("is_active")) and _peer_connected(peer_id):
		net_build_result.rpc_id(peer_id, request_id, accepted, reason)


## Where the requesting player is standing, for the range rule. Falls back to the caller-supplied
## position (the placement or piece itself) only when the body cannot be found, which would
## otherwise reject every build in a harness that has no player bodies at all. (The old code
## documented that fallback but returned Vector3.ZERO, so with no bodies present the range rule
## measured from the world origin and rejected everything placed away from it — review F-099.)
func _builder_position(peer_id: int, fallback: Vector3) -> Vector3:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net != null and player_net.has_method(&"players_root"):
		var players: Node = player_net.call(&"players_root") as Node
		if players != null:
			var body := players.get_node_or_null(NodePath(str(peer_id))) as Node3D
			if body != null:
				return body.global_position
	return fallback


func _space_state() -> PhysicsDirectSpaceState3D:
	var scene: Node = get_tree().current_scene
	if scene == null or not scene is Node3D:
		return null
	var world: World3D = (scene as Node3D).get_world_3d()
	return null if world == null else world.direct_space_state


func _definition(piece_id: StringName) -> Resource:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return null
	return registry.call(&"get_buildable", piece_id)


func _take_index() -> int:
	var index: int = _next_index
	_next_index += 1
	return index


func _take_request_id() -> int:
	var request_id: int = _next_request_id
	_next_request_id += 1
	return request_id


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _peer_connected(peer_id: int) -> bool:
	return bool(_transport().call("has_peer", peer_id))


func _local_peer_id() -> int:
	var peer_id: int = int(_transport().call("local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node(^"/root/NetTransport")
	return _transport_node


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"build", {
		"scope": &"host",
		"args": [
			{"name": "piece", "type": &"buildable_id"},
			{"name": "at", "type": &"vec3"},
		],
		"handler": _cmd_build,
		"help": "build <buildable_id> <x y z> — place a piece (~ is relative to you)",
	})
	command_service.call("register_spec", &"demolish", {
		"scope": &"host",
		"args": [{"name": "target", "type": &"selector"}],
		"handler": _cmd_demolish,
		"help": "demolish <selector> — destroy placed pieces",
	})


## Through `request_place()`, the same seam the placement ghost submits — so the command inherits
## the host's own validation (overlap, support, ownership) rather than a second, laxer copy of it
## (§3.3, and D-034's trust stance about never believing a client-supplied transform).
func _cmd_build(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var piece_id: StringName = args.get("piece", &"")
	var placement := Transform3D(Basis.IDENTITY, args.get("at", Vector3.ZERO) as Vector3)
	var request_id: int = request_place(piece_id, placement)
	if request_id <= 0:
		return {"ok": false, "message": "build refused for '%s'" % piece_id, "data": {}}
	return {"ok": true, "message": "build %s requested (#%d)" % [piece_id, request_id],
		"data": {"piece": String(piece_id), "request": request_id}}


func _cmd_demolish(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var directory: Node = get_node_or_null(^"/root/EntityDirectory")
	if directory == null:
		return {"ok": false, "message": "EntityDirectory is not loaded", "data": {}}
	var requested: int = 0
	for entry: Dictionary in directory.call("resolve", args.get("target", {}), ctx):
		if String(entry["kind"]) != "buildable":
			continue
		if request_destroy(StringName((entry["node"] as Node).name)) > 0:
			requested += 1
	return {"ok": true,
		"message": "demolish requested for %d piece(s)" % requested, "data": {"count": requested}}
