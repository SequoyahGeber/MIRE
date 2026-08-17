extends Node

## PlayerHealth — autoload. Host-keyed hp/downed/bleed-out/respawn per peer, plus the confirmed
## local snapshot and the broadcast downed flag task 2.5's inventory pattern already proved out.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): player health is HOST. Downed/revive is
## HOST-VALIDATED — a client's hold duration is presentation only, the same split D-034 uses for
## melee (the swing wind-up runs client-local, the hit is host-resolved). Death/downed PRESENTATION
## (crawl, blocked input) is client-local, driven off the replicated flags.
##
## Damage comes IN two ways, both host-only:
##   · The shared melee seam (2.8) — entities/player/player_controller.gd joins &"damageable" and
##     forwards its host_apply_damage() call here, keyed by its own multiplayer authority.
##   · EventBus.enemy_attack_landed — 2.10's enemies emit it on a landed hit; this file is the
##     subscriber that seam was built for (see systems/enemies/enemy.gd's own note on the event).
##     enemy_attack_landed_subscriber_count() proves that wiring exists rather than trusting it.
##
## Replication mirrors autoload/inventory_service.gd (D-035-safe): an owner-only reliable snapshot
## carries the full hp/state, and a broadcast bool carries just "is this peer downed" to everyone —
## teammates have to see who needs help, but nobody else needs a stranger's exact hp.

const DOWNED_STATE := preload("res://systems/health/downed_state.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")
## Health logging has no dedicated channel in core/util/mire_log.gd's CHANNELS list — that file was
## not part of this task's claim, so `combat` carries damage/downed/revive lines instead. FINDINGS
## records adding a `health` channel for whoever next holds mire_log.gd.
const LOG_CHANNEL: StringName = &"combat"

@export_group("Tuning")
## Full health at spawn and at respawn. Not a run-scoped stat yet (DESIGN.md §4.6: Salvage never
## unlocks +health) — this is the M2 flat value every player starts and returns to.
@export_range(1, 500, 1) var max_hp: int = 100
## DESIGN.md §4.5 "Downed, not dead" — how long a downed player can be revived before dying.
@export_range(1.0, 120.0, 1.0) var bleed_out_seconds: float = 30.0
## How long a teammate must hold interact next to a downed player to revive them.
@export_range(0.5, 15.0, 0.5) var revive_seconds: float = 3.0
## How close a reviver must stay, re-checked by the host at the moment the request lands.
@export_range(0.5, 10.0, 0.1) var revive_radius_m: float = 3.0
## Fraction of max_hp restored by a successful revive.
@export_range(0.05, 1.0, 0.05) var revive_hp_fraction: float = 0.5
## How long a dead player waits before respawning at full hp. M2 rule: a solo death just respawns —
## there is no run-fail state yet (task 6.7 owns the lose condition).
@export_range(0.5, 30.0, 0.5) var respawn_seconds: float = 5.0

## Owner-only presentation snapshot. downed/dead are DOWNED_STATE.State ints.
signal local_health_changed(hp: int, max_hp: int, state: int, bleed_out_remaining: float)
## Host-side observer hook, mirrors InventoryService.host_inventory_changed — checks and any future
## host-only HUD read this instead of reaching into the private state dictionary.
signal host_health_changed(peer_id: int, hp: int, max_hp: int, state: int)
## Broadcast to every peer, including the downed peer itself: teammates must see who needs help.
signal downed_flag_changed(peer_id: int, downed: bool)
## Feedback for a revive request, owner-only. Mirrors InventoryService.operation_confirmed.
signal revive_confirmed(request_id: int, accepted: bool, detail: String)

## Host-owned. peer_id -> DownedState.
var _states: Dictionary[int, RefCounted] = {}
var _revisions: Dictionary[int, int] = {}
## Every peer's last-known downed flag, from the broadcast — read by any peer, including the host
## (kept in step with _states so callers do not need to branch on who they are).
var _downed_flags: Dictionary[int, bool] = {}
## The transform PlayerNet spawned each peer at, captured off PlayerNet.player_spawned. Respawn
## returns a player here rather than to wherever they happened to die.
var _spawn_transforms: Dictionary[int, Dictionary] = {}

var _local_hp: int = 0
var _local_max_hp: int = 0
var _local_state: int = DOWNED_STATE.State.ALIVE
var _local_bleed_out_remaining: float = 0.0
var _local_revision: int = -1
var _next_request_id: int = 1
var _session_open: bool = false


func _ready() -> void:
	_reset_local_cache()
	EVENT_BUS.subscribe_enemy_attack_landed(_on_enemy_attack_landed)
	_connect_player_net()

	var transport: Node = _transport()
	transport.get("server_started").connect(_on_session_opened)
	transport.get("connected_to_host").connect(_on_session_opened)
	transport.get("disconnected").connect(_on_disconnected)
	transport.get("peer_joined").connect(_on_peer_joined)
	transport.get("peer_left").connect(_on_peer_left)
	# F-032/D-035: NetSession owns run-player identity, so it decides when a departure is final.
	# Connected by path rather than by identifier because this autoload is reached from --script
	# harnesses (F-011), and guarded because a harness may drive PlayerHealth with no session layer.
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null and session.has_signal(&"run_player_rebound"):
		session.connect(&"run_player_rebound", _on_run_player_rebound)
		session.connect(&"run_player_expired", _on_run_player_expired)

	set_physics_process(true)
	if bool(transport.call("is_active")):
		_on_session_opened.call_deferred()
	else:
		_ensure_host_state(NetConfig.HOST_PEER_ID)
		_publish_snapshot(NetConfig.HOST_PEER_ID)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_enemy_attack_landed(_on_enemy_attack_landed)


# ── Physics tick (host-owned bleed-out / respawn timers) ─────────────────────────────────────────


func _physics_process(delta: float) -> void:
	if not _owns_mutation() or _states.is_empty():
		return
	for peer_id: int in _states.keys():
		var downed_state: DOWNED_STATE = _states[peer_id]
		var transition: int = downed_state.tick(delta, respawn_seconds)
		match transition:
			DOWNED_STATE.Transition.DIED:
				MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d bled out" % peer_id)
				_commit(peer_id)
			DOWNED_STATE.Transition.RESPAWNED:
				MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d respawning" % peer_id)
				_commit(peer_id)
				_teleport_to_spawn(peer_id)


# ── The damage seam (shared with 2.8's &"damageable" group, and 2.10's enemy hits) ───────────────


## Host-only. entities/player/player_controller.gd forwards its own host_apply_damage() call here.
## Returns false while downed or dead (no corpse-kicking in M2) or for an unknown peer — CombatService
## treats false as a miss, not a phantom hit.
func host_apply_damage(peer_id: int, amount: int, instigator_peer_id: int) -> bool:
	if not _owns_mutation() or amount <= 0 or not _states.has(peer_id):
		return false
	var downed_state: DOWNED_STATE = _states[peer_id]
	if not downed_state.is_alive():
		return false
	var transition: int = downed_state.apply_damage(amount, bleed_out_seconds)
	_commit(peer_id)
	if transition == DOWNED_STATE.Transition.WENT_DOWN:
		MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d downed (instigator %d)" % [
			peer_id, instigator_peer_id
		])
	return true


func _on_enemy_attack_landed(
	_enemy_id: StringName, peer_id: int, damage: int, _world_position: Vector3
) -> void:
	if not _owns_mutation() or peer_id <= 0:
		return
	# instigator 0: no player threw this hit. host_apply_damage's instigator arg is only ever used
	# for logging today; 0 is never a valid peer id so it reads unambiguously as "an enemy."
	host_apply_damage(peer_id, damage, 0)


# ── Revive — client hold is presentation, the host re-validates everything ───────────────────────


## Called by the reviving player's own controller once its local hold timer reaches revive_seconds.
## Returns a local request id immediately; completion always arrives through revive_confirmed.
func request_revive(target_peer: int) -> int:
	var request_id: int = _take_request_id()
	if _owns_mutation():
		_process_revive_request(_local_peer_id(), target_peer, request_id)
	elif bool(_transport().call("is_active")):
		net_request_revive.rpc_id(NetConfig.HOST_PEER_ID, target_peer, request_id)
	else:
		revive_confirmed.emit(request_id, false, "no authoritative session")
	return request_id


@rpc("any_peer", "call_remote", "reliable")
func net_request_revive(target_peer: int, request_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_process_revive_request(multiplayer.get_remote_sender_id(), target_peer, request_id)


@rpc("authority", "call_remote", "reliable")
func net_revive_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	revive_confirmed.emit(request_id, accepted, detail)


func _process_revive_request(reviver_peer: int, target_peer: int, request_id: int) -> void:
	var detail: String = _validate_revive(reviver_peer, target_peer)
	var accepted: bool = detail.is_empty()
	if accepted:
		(_states[target_peer] as DOWNED_STATE).revive(revive_hp_fraction)
		_commit(target_peer)
		MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d revived peer %d" % [reviver_peer, target_peer])
	_confirm_peer(reviver_peer, request_id, accepted, "revived" if accepted else detail)


## A client cannot heal itself (reviver == target is rejected outright, before anything else is
## checked) and cannot revive at all unless it is itself able-bodied and within range NOW — the
## host's own copy of both positions, never a client-supplied distance.
func _validate_revive(reviver_peer: int, target_peer: int) -> String:
	if reviver_peer <= 0 or target_peer <= 0:
		return "revive rejected: invalid peer"
	if reviver_peer == target_peer:
		return "revive rejected: cannot revive yourself"
	if not _states.has(reviver_peer) or not (_states[reviver_peer] as DOWNED_STATE).is_alive():
		return "revive rejected: reviver is not able-bodied"
	if not _states.has(target_peer) or not (_states[target_peer] as DOWNED_STATE).is_downed():
		return "revive rejected: target is not downed"
	var reviver_body: Node3D = _player_body(reviver_peer)
	var target_body: Node3D = _player_body(target_peer)
	if reviver_body == null or target_body == null:
		return "revive rejected: player not spawned"
	if reviver_body.global_position.distance_to(target_body.global_position) > revive_radius_m:
		return "revive rejected: out of range"
	return ""


func _confirm_peer(peer_id: int, request_id: int, accepted: bool, detail: String) -> void:
	if peer_id == _local_peer_id():
		revive_confirmed.emit(request_id, accepted, detail)
	elif bool(_transport().call("is_active")):
		net_revive_confirmed.rpc_id(peer_id, request_id, accepted, detail)


# ── Respawn teleport ───────────────────────────────────────────────────────────────────────────────


## Own player movement is CLIENT authority (§2.2 row 1) — the host cannot just write another peer's
## position, so it tells that peer's own client to place itself, the same way it is the only thing
## allowed to move its own body at all.
func _teleport_to_spawn(peer_id: int) -> void:
	var spawn: Dictionary = _spawn_transforms.get(peer_id, {})
	var position: Vector3 = spawn.get("position", Vector3.ZERO)
	var yaw: float = float(spawn.get("yaw", 0.0))
	if peer_id == _local_peer_id():
		_apply_respawn_transform(position, yaw)
	elif bool(_transport().call("is_active")):
		net_force_respawn.rpc_id(peer_id, position, yaw)


@rpc("authority", "call_remote", "reliable")
func net_force_respawn(position: Vector3, yaw: float) -> void:
	_apply_respawn_transform(position, yaw)


func _apply_respawn_transform(position: Vector3, yaw: float) -> void:
	var body := _local_player_body() as CharacterBody3D
	if body == null:
		return
	body.position = position
	body.rotation.y = yaw
	body.velocity = Vector3.ZERO


func _connect_player_net() -> void:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net != null and player_net.has_signal(&"player_spawned"):
		player_net.connect(&"player_spawned", _on_player_spawned)


## PlayerNet sets position/rotation on the body before add_child (see its own _net_spawn_player), so
## this signal — fired during that same add_child — already carries the real spawn transform.
func _on_player_spawned(peer_id: int, body: Node3D) -> void:
	_spawn_transforms[peer_id] = {"position": body.position, "yaw": body.rotation.y}


# ── Read API ───────────────────────────────────────────────────────────────────────────────────────


func local_hp() -> int:
	return _local_hp


func local_max_hp() -> int:
	return _local_max_hp


func local_is_downed() -> bool:
	return _local_state == DOWNED_STATE.State.DOWNED


func local_is_dead() -> bool:
	return _local_state == DOWNED_STATE.State.DEAD


func local_is_alive() -> bool:
	return _local_state == DOWNED_STATE.State.ALIVE


func local_bleed_out_remaining() -> float:
	return _local_bleed_out_remaining


func local_revision() -> int:
	return _local_revision


## What the broadcast flag last said about [param peer_id] — the host's own truth included, so
## callers never have to special-case "am I the host". Unknown peers read as not-downed.
func is_downed_known(peer_id: int) -> bool:
	return bool(_downed_flags.get(peer_id, false))


func host_hp(peer_id: int) -> int:
	if not _owns_mutation() or not _states.has(peer_id):
		return 0
	return int((_states[peer_id] as DOWNED_STATE).hp)


func host_is_downed(peer_id: int) -> bool:
	if not _owns_mutation() or not _states.has(peer_id):
		return false
	return bool((_states[peer_id] as DOWNED_STATE).is_downed())


func host_is_dead(peer_id: int) -> bool:
	if not _owns_mutation() or not _states.has(peer_id):
		return false
	return bool((_states[peer_id] as DOWNED_STATE).is_dead())


func host_is_alive(peer_id: int) -> bool:
	if not _owns_mutation() or not _states.has(peer_id):
		return false
	return bool((_states[peer_id] as DOWNED_STATE).is_alive())


func host_bleed_out_remaining(peer_id: int) -> float:
	if not _owns_mutation() or not _states.has(peer_id):
		return 0.0
	return float((_states[peer_id] as DOWNED_STATE).bleed_out_remaining)


# ── Session lifecycle (mirrors autoload/inventory_service.gd) ────────────────────────────────────


func _on_session_opened() -> void:
	if _session_open:
		return
	_session_open = true
	_states.clear()
	_revisions.clear()
	_downed_flags.clear()
	_reset_local_cache()
	if not bool(_transport().call("is_host")):
		return
	for peer_id: int in _transport().call("peer_ids"):
		_ensure_host_state(peer_id)
		_publish_snapshot(peer_id)


func _on_peer_joined(peer_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_ensure_host_state(peer_id)
	_publish_snapshot(peer_id)


## Deliberately a no-op (D-035, F-032). Between a drop and a rejoin the player is still a player;
## NetSession decides which of run_player_rebound/run_player_expired actually applies. Same shape as
## InventoryService._on_peer_left — see its comment for the fuller story.
func _on_peer_left(_peer_id: int) -> void:
	pass


func _on_run_player_rebound(old_peer_id: int, new_peer_id: int) -> void:
	if not _owns_mutation() or not _states.has(old_peer_id):
		return
	_states[new_peer_id] = _states[old_peer_id]
	_revisions[new_peer_id] = int(_revisions.get(old_peer_id, 0))
	_states.erase(old_peer_id)
	_revisions.erase(old_peer_id)
	if _spawn_transforms.has(old_peer_id):
		_spawn_transforms[new_peer_id] = _spawn_transforms[old_peer_id]
		_spawn_transforms.erase(old_peer_id)
	_publish_snapshot(new_peer_id)


func _on_run_player_expired(peer_id: int) -> void:
	if not _owns_mutation():
		return
	_states.erase(peer_id)
	_revisions.erase(peer_id)
	_downed_flags.erase(peer_id)
	_spawn_transforms.erase(peer_id)


func _on_disconnected() -> void:
	_session_open = false
	_states.clear()
	_revisions.clear()
	_downed_flags.clear()
	_reset_local_cache()
	_ensure_host_state(NetConfig.HOST_PEER_ID)
	_publish_snapshot(NetConfig.HOST_PEER_ID)


# ── Replication ────────────────────────────────────────────────────────────────────────────────────


@rpc("authority", "call_remote", "reliable")
func net_health_snapshot(revision: int, hp: int, hp_max: int, state: int, bleed_out_remaining: float) -> void:
	if revision < _local_revision:
		return
	_accept_local_snapshot(hp, hp_max, state, bleed_out_remaining, revision)


@rpc("authority", "call_remote", "reliable")
func net_downed_flag(peer_id: int, downed: bool) -> void:
	_apply_downed_flag(peer_id, downed)


func _commit(peer_id: int) -> void:
	_revisions[peer_id] = int(_revisions.get(peer_id, 0)) + 1
	_publish_snapshot(peer_id)


func _publish_snapshot(peer_id: int) -> void:
	if not _states.has(peer_id):
		return
	var downed_state: DOWNED_STATE = _states[peer_id]
	var revision: int = int(_revisions.get(peer_id, 0))
	host_health_changed.emit(peer_id, downed_state.hp, downed_state.max_hp, downed_state.state, revision)
	if peer_id == _local_peer_id():
		_accept_local_snapshot(
			downed_state.hp, downed_state.max_hp, downed_state.state,
			downed_state.bleed_out_remaining, revision
		)
	elif bool(_transport().call("is_active")):
		net_health_snapshot.rpc_id(
			peer_id, revision, downed_state.hp, downed_state.max_hp,
			downed_state.state, downed_state.bleed_out_remaining
		)
	_broadcast_downed_flag(peer_id, not downed_state.is_alive())


func _broadcast_downed_flag(peer_id: int, downed: bool) -> void:
	_apply_downed_flag(peer_id, downed)
	if bool(_transport().call("is_active")):
		net_downed_flag.rpc(peer_id, downed)


func _apply_downed_flag(peer_id: int, downed: bool) -> void:
	_downed_flags[peer_id] = downed
	downed_flag_changed.emit(peer_id, downed)


func _accept_local_snapshot(
	hp: int, hp_max: int, state: int, bleed_out_remaining: float, revision: int
) -> void:
	_local_hp = hp
	_local_max_hp = hp_max
	_local_state = state
	_local_bleed_out_remaining = bleed_out_remaining
	_local_revision = revision
	local_health_changed.emit(hp, hp_max, state, bleed_out_remaining)


func _reset_local_cache() -> void:
	_local_hp = max_hp
	_local_max_hp = max_hp
	_local_state = DOWNED_STATE.State.ALIVE
	_local_bleed_out_remaining = 0.0
	_local_revision = -1


# ── Shared lookups ────────────────────────────────────────────────────────────────────────────────


func _ensure_host_state(peer_id: int) -> void:
	if _states.has(peer_id):
		return
	_states[peer_id] = DOWNED_STATE.new(max_hp)
	_revisions[peer_id] = 0


## PlayerNet.player_for() first (it knows every peer it spawned); the &"players" group second, so a
## harness that builds PlayerController nodes directly — without going through PlayerNet — still
## resolves a body. Same fallback order as systems/enemies/enemy.gd's own _player_for().
func _player_body(peer_id: int) -> Node3D:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net != null and player_net.has_method(&"player_for"):
		var body: Node3D = player_net.call("player_for", peer_id) as Node3D
		if body != null:
			return body
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and int(player.get_multiplayer_authority()) == peer_id:
			return player
	return null


func _local_player_body() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _take_request_id() -> int:
	var result: int = _next_request_id
	_next_request_id += 1
	if _next_request_id <= 0:
		_next_request_id = 1
	return result


func _local_peer_id() -> int:
	var peer_id: int = int(_transport().call("local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


func _transport() -> Node:
	return get_node(^"/root/NetTransport")
