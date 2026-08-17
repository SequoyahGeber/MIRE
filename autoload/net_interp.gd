extends Node
## NetInterp — autoload. Gives every player this peer does not own a [RemoteInterpolator], so remote
## players glide instead of stepping thirty times a second (task 1.6).
##
## Network authority (docs/ARCHITECTURE.md §2.2): none. Client-local presentation only — the last row
## of the table. Nothing here is replicated, nothing here is trusted, and nothing here writes to a
## node this peer owns. See core/net/remote_interp.gd for why it exists alongside the engine's own
## physics interpolation (D-026, F-004).
##
## WHY THIS IS AN AUTOLOAD AND NOT A LINE IN PlayerController._ready(). Interpolation is a different
## concern from replication: it is what the RECEIVER does with what arrived, it applies identically
## to enemies (2.10) and physics props, and it is the one part of this that a player on a good
## connection could switch off entirely. Keeping it a separate node attached from outside means the
## same component covers all three of F-004's cases with one line each, and means no replicated
## entity has to know it is being smoothed.
##
## It watches PlayerNet's container rather than the whole tree, so it costs exactly nothing outside
## a player spawn — get_tree().node_added would fire for every chunk node M4 streams in.
##
## OFFLINE THIS DOES NOTHING. With no session there are no spawned players, and the level's
## hand-placed Player is this peer's own — is_multiplayer_authority() is true for it, so it is
## skipped and "press Play and walk around" is untouched.

# Preloaded rather than reached by class_name: a --script harness run must not depend on the editor
# having refreshed the global class cache (F-011, and tools/bench_replication.gd does the same).
const RemoteInterp = preload("res://core/net/remote_interp.gd")

## Name of the interpolator node under each remote player. One per player, checked before attaching.
const INTERP_NODE: StringName = &"RemoteInterp"

var _players: Node = null


func _ready() -> void:
	# Nothing per-frame of its own: every frame's work happens in the interpolators themselves.
	set_process(false)
	set_physics_process(false)
	_bind()


## PlayerNet builds its container inside its own _ready(), and it is registered before this file, so
## by the time we run it is ready to subscribe to. Resolved by path rather than by identifier so this
## also works in a --script main loop, where autoloads are not compile-time names (F-011).
##
## F-018: this used to find PlayerNet's container by name and connect to its `child_entered_tree`,
## which is exactly what PlayerNet's own header forbids — "the paths are ours to change". PlayerNet
## now pushes `player_spawned`, so the container's shape is nobody else's business.
func _bind() -> void:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net == null:
		MireLog.warn(NetConfig.LOG_CHANNEL, "NetInterp: PlayerNet not registered — remote players will not be smoothed")
		return

	if not player_net.has_signal(&"player_spawned"):
		MireLog.warn(NetConfig.LOG_CHANNEL, "NetInterp: PlayerNet exposes no player_spawned signal")
		return
	player_net.connect(&"player_spawned", _on_player_spawned)

	# Catch up on anything already spawned, in case registration order ever changes underneath us.
	_players = player_net.call(&"players_root") as Node
	if _players != null:
		for child: Node in _players.get_children():
			attach_to(child)


# ── Attaching ─────────────────────────────────────────────────────────────────────────────────────


## player_spawned fires DURING add_child, before the player's own _ready() has built its
## MultiplayerSynchronizer — so decide one call later, when the node is actually finished.
func _on_player_spawned(_peer_id: int, body: Node3D) -> void:
	attach_to.call_deferred(body)


## Give [param body] an interpolator if it deserves one. Returns whether one is now attached.
##
## Public because the headless harness drives this same path against its own bodies rather than a
## second copy of the rules — the rules are the interesting part.
func attach_to(body: Node) -> bool:
	if not is_instance_valid(body) or not body.is_inside_tree():
		return false

	var target: Node3D = body as Node3D
	if target == null:
		return false

	# Our own player is simulated here, at full frame rate, from real input. Interpolating it would
	# add latency to the one thing in the game that must have none.
	if target.is_multiplayer_authority():
		return false

	if target.get_node_or_null(NodePath(INTERP_NODE)) != null:
		return true

	# A body with no synchronizer receives nothing, so there is nothing to smooth. This is also what
	# keeps the level's hand-placed Player alone before a session opens.
	var sync: MultiplayerSynchronizer = target.get_node_or_null(
		NodePath(NetConfig.PLAYER_SYNC_NODE)
	) as MultiplayerSynchronizer
	if sync == null:
		return false

	var interp: RemoteInterp = RemoteInterp.new()
	interp.name = INTERP_NODE
	interp.configure(target, target.get_node_or_null(^"CameraPivot") as Node3D, sync)
	target.add_child(interp)

	MireLog.debug(NetConfig.LOG_CHANNEL, "NetInterp: smoothing remote player %s" % target.name)
	return true


## The interpolator on [param body], or null. Nothing needs this yet; the debug panel will.
func interpolator_for(body: Node) -> RemoteInterp:
	if not is_instance_valid(body):
		return null
	return body.get_node_or_null(NodePath(INTERP_NODE)) as RemoteInterp


# ── Read-only ─────────────────────────────────────────────────────────────────────────────────────


## Whether we found PlayerNet's container and are watching it. False means remote players will
## judder and the cause is wiring, not netcode — worth being able to ask.
func is_watching() -> bool:
	return _players != null


## One row per remote player being smoothed: peer id, how far behind live it is drawn, and how much
## state it is holding. Allocates — read it a few times a second at most, never per frame.
func debug_snapshot() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if _players == null:
		return rows
	for child: Node in _players.get_children():
		var interp: RemoteInterp = interpolator_for(child)
		if interp == null:
			continue
		rows.append({
			"peer": String(child.name).to_int(),
			"lag_ms": interp.lag_seconds() * 1000.0,
			"buffered": interp.buffered(),
		})
	return rows
