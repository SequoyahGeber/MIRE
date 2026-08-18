extends Node
## PlayerNet — autoload. One player node per peer: the host decides who exists, each peer drives its
## own copy, everyone sees everyone (task 1.5).
##
## Network authority (docs/ARCHITECTURE.md §2.2):
##   Spawning               → HOST. Only the host calls spawn(); clients receive and instantiate.
##   Own player movement    → CLIENT. The owning peer holds authority over its own player node, so
##                            that node's MultiplayerSynchronizer sends and every other peer receives.
##                            The host relays between clients (SceneMultiplayer.server_relay).
##   Speed sanity check     → HOST, advisory only. It logs a warning; it never corrects.
##
## Node layout — identical on every peer. The high-level multiplayer API matches nodes by path, so
## these names are load-bearing, and they are built in code rather than authored in a scene (D-023):
##
##     /root/PlayerNet
##       ├── Players               Node3D               every networked player lives here
##       │     ├── "1"             PlayerController     named for the peer that owns it
##       │     └── "2"             PlayerController
##       └── PlayerSpawner         MultiplayerSpawner   spawn_path → ../Players
##
## Players hang off this autoload rather than off the level because the level is scenery and gets
## swapped in M4; a session's players outlive it.
##
## OFFLINE THIS DOES NOTHING. The container and the spawner are still built — both peers must build
## the same tree and an idle spawner costs nothing — but nothing is spawned, and the level's
## hand-placed Player is left exactly where it is. "Open the project, press Play, walk around" is
## unchanged.

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")

## A player body appeared on THIS peer — spawned locally on the host, replicated in on a client.
## Fires during `add_child`, so [param body] has not run its own `_ready()` yet and its
## MultiplayerSynchronizer does not exist; defer anything that needs a finished node (F-018).
signal player_spawned(peer_id: int, body: Node3D)
## A player body is leaving this peer's tree. Still valid when the signal fires, gone right after.
signal player_despawned(peer_id: int, body: Node3D)

## Where the Nth player of a session stands relative to the level's spawn point, so six players do
## not spawn inside one another. A fixed table rather than a ring computed with sin/cos: the values
## are decided once, by hand, and are easier to read than the formula that would produce them.
const SPAWN_OFFSETS: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(1.6, 0.0, 0.0),
	Vector3(-1.6, 0.0, 0.0),
	Vector3(0.0, 0.0, 1.6),
	Vector3(0.0, 0.0, -1.6),
	Vector3(1.6, 0.0, 1.6),
]

var _players: Node3D
var _spawner: MultiplayerSpawner

## Which SPAWN_OFFSETS index each peer holds, keyed by peer id. A *claim*, not a count: the slot is
## reserved when a player spawns and released only when that player despawns. Deriving placement
## from `_players.get_child_count()` instead is F-129 — a count stops being unique the moment
## anyone leaves, so a rejoining player lands on top of whoever inherited their old index.
var _slots: Dictionary[int, int] = {}

## Where the level says players belong. Read off the level's hand-placed Player before freeing it.
var _spawn_point: Transform3D = Transform3D.IDENTITY
var _session_open: bool = false

## Host-only speed check state, keyed by peer id.
var _last_sample: Dictionary[int, Vector3] = {}
var _strikes: Dictionary[int, int] = {}
var _sample_timer: float = 0.0


func _ready() -> void:
	_build_replication_nodes()

	NetTransport.server_started.connect(_on_session_opened)
	NetTransport.connected_to_host.connect(_on_session_opened)
	NetTransport.disconnected.connect(_on_disconnected)
	NetTransport.peer_joined.connect(_on_peer_joined)
	NetTransport.peer_left.connect(_on_peer_left)

	# The speed check only has anything to watch while we are hosting a session.
	set_physics_process(false)

	# Autoload order matters here: DevLaunch is registered before this file and opens its session
	# inside its own _ready(), which is before this node exists to hear server_started. Catch up
	# instead of depending on registration order.
	if NetTransport.is_active():
		_on_session_opened.call_deferred()


## Built unconditionally and identically on every peer. Only the spawn CALLS are host-only.
func _build_replication_nodes() -> void:
	_players = Node3D.new()
	_players.name = NetConfig.PLAYER_CONTAINER_NODE
	# F-018: observers used to connect to these two themselves, which meant reaching in for the
	# container by name from outside this file. PlayerNet listens to its own container and re-emits,
	# so the paths stay ours. This is also why the signals cannot be emitted from _spawn_for(): that
	# runs on the host only, while on a client the MultiplayerSpawner puts the body here directly.
	_players.child_entered_tree.connect(_on_player_child_entered)
	_players.child_exiting_tree.connect(_on_player_child_exiting)
	add_child(_players)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = NetConfig.PLAYER_SPAWNER_NODE
	_spawner.spawn_limit = NetConfig.MAX_PLAYERS
	_spawner.spawn_function = _net_spawn_player
	add_child(_spawner)

	# After add_child, and relative: setting spawn_path resolves it immediately, which errors from
	# outside the tree, and a relative path keeps working if this subtree is ever renamed.
	_spawner.spawn_path = _spawner.get_path_to(_players)


# ── Public read API — for 1.6 (interpolation), 1.7 (lifecycle) and 1.10 (debug panel) ──────────────


## The player node owned by [param peer_id], or null if that peer has none. Never reach into the
## tree by path from outside this file; the paths are ours to change.
func player_for(peer_id: int) -> Node3D:
	if _players == null:
		return null
	return _players.get_node_or_null(NodePath(str(peer_id))) as Node3D


## The container every player body hangs off. For the rare caller that genuinely needs the node
## itself — a group query, a debug dump — rather than one player or one signal. Prefer
## `player_spawned` / `player_despawned`; this exists so that wanting the container is not a reason
## to hard-code its name from outside (F-018).
func players_root() -> Node:
	return _players


## Every peer that currently has a player node, ascending. Empty offline.
func spawned_peers() -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	if _players == null:
		return ids
	for child: Node in _players.get_children():
		ids.append(String(child.name).to_int())
	ids.sort()
	return ids


## Who is spawned, where, and who drives them — one dictionary per player. Allocates, so read it a
## few times a second at most and never per frame.
func debug_snapshot() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if _players == null:
		return rows
	for child: Node in _players.get_children():
		var body: Node3D = child as Node3D
		if body == null:
			continue
		rows.append({
			"peer": String(body.name).to_int(),
			"position": body.position,
			"yaw": body.rotation.y,
			"authority": body.get_multiplayer_authority(),
			"is_local": body.is_multiplayer_authority(),
		})
	return rows


# ── Spawning ──────────────────────────────────────────────────────────────────────────────────────


## The spawner's spawn_function: runs on EVERY peer — on the host when it calls spawn(), on each
## client when the spawn packet lands. Both sides therefore build the same node, with the same name
## and the same authority, from the same data.
##
## Authority is set here, before the node enters the tree, because PlayerController._ready() reads
## is_multiplayer_authority() and immediately decides whether to run physics and capture the mouse.
## The controller re-derives the same value from the node's name, which is what makes this correct
## even though the engine renames the node on the receiving side after this returns.
func _net_spawn_player(data: Variant) -> Node:
	var info: Dictionary = data as Dictionary
	var peer_id: int = int(info.get("peer", 0))

	var player: Node3D = PLAYER_SCENE.instantiate() as Node3D
	player.name = str(peer_id)
	player.position = info.get("origin", Vector3.ZERO)
	player.rotation.y = float(info.get("yaw", 0.0))
	player.set_multiplayer_authority(peer_id)
	return player


func _spawn_for(peer_id: int) -> void:
	if not NetTransport.is_host():
		return
	if player_for(peer_id) != null:
		return

	var slot: int = _claim_slot(peer_id)
	var origin: Vector3 = _spawn_point.origin + _spawn_point.basis * SPAWN_OFFSETS[slot]

	var spawned: Node = _spawner.spawn({
		"peer": peer_id,
		"origin": origin,
		"yaw": _spawn_point.basis.get_euler().y,
	})
	if spawned == null:
		MireLog.error(NetConfig.LOG_CHANNEL, "PlayerNet: spawn failed for peer %d" % peer_id)
		return

	MireLog.info(NetConfig.LOG_CHANNEL, "PlayerNet: spawned player %d at %v" % [peer_id, origin])


## Container children are named for the peer that owns them (see `_net_spawn_player`), on every peer,
## before the node enters the tree — so the peer id is readable here with nothing extra on the wire.
func _on_player_child_entered(child: Node) -> void:
	var body := child as Node3D
	var peer_id: int = _peer_id_of(child)
	if body == null or peer_id <= 0:
		return
	player_spawned.emit(peer_id, body)


func _on_player_child_exiting(child: Node) -> void:
	var body := child as Node3D
	var peer_id: int = _peer_id_of(child)
	if body == null or peer_id <= 0:
		return
	player_despawned.emit(peer_id, body)


func _peer_id_of(child: Node) -> int:
	var node_name: String = String(child.name)
	return node_name.to_int() if node_name.is_valid_int() else 0


## The lowest offset index nobody currently holds. Lowest-free rather than next-highest so a session
## that churns players keeps reusing the tight cluster near the level's spawn point instead of
## drifting outward, and so the result depends only on who is presently in the session — never on
## the order they arrived or on how many have come and gone (F-129).
func _claim_slot(peer_id: int) -> int:
	if _slots.has(peer_id):
		return _slots[peer_id]
	var taken: Array = _slots.values()
	for index: int in range(SPAWN_OFFSETS.size()):
		if not taken.has(index):
			_slots[peer_id] = index
			return index
	# More players than authored offsets. MAX_PLAYERS is 6 and so is SPAWN_OFFSETS, so this is
	# unreachable today; it wraps rather than crashing if either number ever moves.
	var fallback: int = _slots.size() % SPAWN_OFFSETS.size()
	_slots[peer_id] = fallback
	MireLog.warn(NetConfig.LOG_CHANNEL,
		"PlayerNet: no free spawn offset for peer %d — reusing slot %d" % [peer_id, fallback])
	return fallback


func _despawn(peer_id: int) -> void:
	var player: Node3D = player_for(peer_id)
	if player == null:
		return
	# Out of the tree first, so its name is free again immediately if the peer reconnects before the
	# queued free runs.
	_players.remove_child(player)
	player.queue_free()
	# Release the claim, or the offsets leak and later joiners are pushed into the fallback below.
	_slots.erase(peer_id)
	_last_sample.erase(peer_id)
	_strikes.erase(peer_id)
	NetInterest.clear_observer(peer_id)
	MireLog.info(NetConfig.LOG_CHANNEL, "PlayerNet: despawned player %d" % peer_id)


# ── Session lifecycle (the obvious signal handling only — 1.7 owns the hard cases) ─────────────────


func _on_session_opened() -> void:
	if _session_open:
		return

	# We can be called during startup, before the main scene is instantiated.
	if get_tree().current_scene == null:
		await get_tree().process_frame

	_session_open = true
	_claim_spawn_point()

	if not NetTransport.is_host():
		MireLog.info(NetConfig.LOG_CHANNEL, "PlayerNet: client ready, awaiting spawns from host")
		return

	for peer_id: int in NetTransport.peer_ids():
		_spawn_for(peer_id)

	_sample_timer = 0.0
	set_physics_process(true)


## In a session, the level's hand-placed Player is a SPAWN POINT, not a player: read its transform,
## then free it. Every peer does this to its own copy — a client that kept it would have an
## unowned body standing in the level. Offline this is never called and the node is left alone.
func _claim_spawn_point() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		MireLog.warn(NetConfig.LOG_CHANNEL, "PlayerNet: no current scene — spawning at world origin")
		return

	var placeholder: Node = scene.get_node_or_null(^"Player")
	if placeholder == null:
		MireLog.warn(NetConfig.LOG_CHANNEL, "PlayerNet: level has no Player spawn point — using world origin")
		return

	var body: Node3D = placeholder as Node3D
	if body != null:
		_spawn_point = body.global_transform

	scene.remove_child(placeholder)
	placeholder.queue_free()
	MireLog.info(NetConfig.LOG_CHANNEL, "PlayerNet: spawn point taken from level at %v" % _spawn_point.origin)


func _on_peer_joined(peer_id: int) -> void:
	if not NetTransport.is_host():
		return
	_spawn_for(peer_id)


func _on_peer_left(peer_id: int) -> void:
	if not NetTransport.is_host():
		return
	_despawn(peer_id)


func _on_disconnected() -> void:
	_session_open = false
	set_physics_process(false)
	_last_sample.clear()
	_strikes.clear()
	NetInterest.clear_observers()

	for child: Node in _players.get_children():
		_players.remove_child(child)
		child.queue_free()


# ── Interest management observers (§2.5) ──────────────────────────────────────────────────────────


## Publish every player's position to NetInterest, which is what the visibility filters on enemies
## and props measure their distance from.
##
## HOST ONLY, because _physics_process is host-only, and that is exactly right today: a visibility
## filter runs on the peer holding the synchronizer's authority, and every filtered class in §2.5 is
## host-authoritative. The one client-authoritative row — a player's own movement — is deliberately
## unfiltered. If a client ever owns something filtered, this is the line that has to move.
func _publish_observers() -> void:
	for child: Node in _players.get_children():
		var body: Node3D = child as Node3D
		if body == null:
			continue
		# A body's peer id never changes, so it is parsed from the name once and cached as meta
		# instead of allocating and parsing a String per player per tick (F-099).
		var peer_id: int = int(body.get_meta(&"observer_peer_id", 0))
		if peer_id == 0:
			peer_id = String(body.name).to_int()
			body.set_meta(&"observer_peer_id", peer_id)
		NetInterest.set_observer(peer_id, body.global_position)


# ── Host speed sanity check (§2.2 row 1) ──────────────────────────────────────────────────────────
#
# Advisory ONLY. It watches how far a remote player's replicated position moves between samples and
# warns if the implied horizontal speed stays impossible for several samples in a row. It does not
# correct, rubber-band, teleport or kick — what to DO about a cheating peer is a later decision, and
# the wrong one to make silently now. Requiring consecutive strikes is what keeps a lag spike or a
# legitimate teleport from tripping it.


func _physics_process(delta: float) -> void:
	# Interest management (§2.5) reads these; it does not gather them, because a static filter called
	# 1000 times a tick must not walk the tree. Published every tick, not on the sample timer below —
	# visibility is re-evaluated at 60Hz, and filtering against a position up to a quarter of a second
	# stale is how an entity 24 m outside the leave radius stays subscribed.
	_publish_observers()

	_sample_timer += delta
	if _sample_timer < NetConfig.SPEED_CHECK_INTERVAL_SEC:
		return

	var elapsed: float = _sample_timer
	_sample_timer = 0.0

	var local_id: int = NetTransport.local_peer_id()
	for child: Node in _players.get_children():
		var player: PlayerController = child as PlayerController
		if player == null:
			continue

		var peer_id: int = String(player.name).to_int()
		if peer_id == local_id:
			continue  # our own player is simulated here, not replicated to us.

		_check_speed(peer_id, player, elapsed)


func _check_speed(peer_id: int, player: PlayerController, elapsed: float) -> void:
	var position: Vector3 = player.position
	if not _last_sample.has(peer_id):
		_last_sample[peer_id] = position
		return

	var previous: Vector3 = _last_sample[peer_id]
	_last_sample[peer_id] = position

	var moved: Vector2 = Vector2(position.x - previous.x, position.z - previous.z)
	var speed: float = moved.length() / elapsed
	var limit: float = player.sprint_speed * NetConfig.SPEED_CHECK_TOLERANCE

	if speed <= limit:
		_strikes[peer_id] = 0
		return

	var strikes: int = _strikes.get(peer_id, 0) + 1
	if strikes < NetConfig.SPEED_CHECK_STRIKES:
		_strikes[peer_id] = strikes
		return

	# Reset rather than latch, so a peer that keeps it up logs about once a second instead of once.
	_strikes[peer_id] = 0
	MireLog.warn(NetConfig.LOG_CHANNEL, "PlayerNet: peer %d moving at %.1f m/s over %d samples (limit %.1f) — not corrected" % [
		peer_id, speed, NetConfig.SPEED_CHECK_STRIKES, limit
	])
