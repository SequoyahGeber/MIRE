extends Node

## NetTransport — the single seam between MIRE and whatever is actually moving bytes.
## docs/ARCHITECTURE.md §2.3. Register as autoload `NetTransport` → res://autoload/net_transport.gd
##
## Gameplay code never touches [code]multiplayer.multiplayer_peer[/code], never names ENet, never
## names Steam. It calls host()/join()/leave() and listens to the six signals below. That contract is
## byte-identical in all three modes, which is the whole point: the two-window LOCAL loop you iterate
## in is the same code path that ships over Steam P2P.
##
## NETWORK AUTHORITY (§2.2) — none of its own. This is infrastructure, not simulated state: nothing
## here is replicated and nothing here is authoritative. It is the pipe the table rides on:
##   · Own player movement (CLIENT-authoritative) sends over it
##   · Other players' movement, enemies, world mutation, inventory/crafting, the Mire grid, and
##     day/night + wave director + Cycle state (all HOST-authoritative) replicate over it
##   · VFX, audio, camera, UI (client-local) must never touch it — §2.2's last row is free, keep it free
##
## The one authority fact this file does establish is [method is_host]: the answer to "am I the
## simulation?". Every host-authoritative system gates on it, so read the note on that method before
## you reach for multiplayer.is_server() instead.

# ── Signals ───────────────────────────────────────────────────────────────────────────────────────
#
# Contract, so M1 can be written against it without reading the body:
#   · The local peer is always in peer_ids() but NEVER produces peer_joined — you learn you are in a
#     session from server_started / connected_to_host. peer_joined is remote peers only.
#   · connection_failed fires for every failure, synchronous or not. The Error returned by
#     host()/join() is the same information for callers that would rather branch inline than connect.
#   · disconnected fires exactly once whenever an established session ends, for any reason: you left,
#     the host quit, the host called leave(). A join that never connected fails, it does not disconnect.
#   · server_started and the synchronous failures are emitted deferred, so `host(); connect(...)` is
#     as safe as `connect(...); host()`.

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connection_failed(reason: String)
signal connected_to_host()
signal server_started()
signal disconnected()

## F-157: the peer id -> display name map changed. Fires on the host (who applied/decided it) and on
## every peer that received the broadcast or the joining snapshot — same "everyone ends up agreeing"
## shape as peer_joined/peer_left, just for a name instead of membership.
signal display_name_changed(peer_id: int, display_name: String)

## Private on purpose — callers branch on is_host() / is_active() / current_mode(), not on this.
enum _Status { OFFLINE, HOSTING, CONNECTING, CONNECTED }

## Why the last session or attempt ended, as far as the transport can tell. NetSession (task 1.7)
## refines this into a player-facing reason — the transport cannot tell "the host quit" from "the link
## died", because ENet reports both as server_disconnected. Read via [method last_end_kind].
## The last two are both "an attempt that never became a session", and splitting them is what makes a
## retry policy possible (F-023). CONNECT_FAILED is an answer — refused, or nothing at that address —
## and asking again gets the same answer. CONNECT_TIMEOUT is the absence of one: the deadline expired
## with the handshake still in flight, which on Steam means a rendezvous that had not finished yet.
## Only the second is worth retrying, and NetSession is what decides to.
enum EndKind {
	NONE,            ## Nothing has ended yet this process.
	LOCAL_LEAVE,     ## We ended it: leave(), or the tree going away.
	REMOTE_CLOSED,   ## The host went away — cleanly or not. Only a client sees this.
	CONNECT_FAILED,  ## Refused, or nothing there. A verdict; repeating the attempt repeats it.
	CONNECT_TIMEOUT, ## Ran out of time with no verdict either way. Worth one more attempt.
}

const _STEAM_UNAVAILABLE: String = "STEAM mode unavailable: the GodotSteam GDExtension is not installed yet (task 1.1) — use Mode.LOCAL for the two-window dev loop, or Mode.LAN for a second machine"

## Extra connection slots ENet accepts beyond the game's own capacity. The game's limit is enforced by
## the admission gate below, NOT by the backend, and that is deliberate (D-027): a peer refused by ENet
## itself is dropped at the socket with nothing said, so the joiner sees only "timed out" and has no
## idea the session was full. Accepting them costs one short-lived connection and buys a real reason.
## Two, so a pair of friends clicking Join at the same moment both get told, rather than one being told
## and the other timing out.
const ADMISSION_SLACK: int = 2

# ENet's own dead-peer detection, which is what turns "someone's wifi died" into peer_left. Defaults
# are 32 / 5000 / 30000 ms, and the 30 s ceiling is far too long to leave a body standing in the world.
# ENet declares a peer dead once an unacknowledged reliable packet has gone unanswered for
# timeout_limit × mean-RTT-deviation, clamped to [timeout_min, timeout_max]. Lowering the ceiling to
# 8 s is the part that matters; the floor stays well above any plausible stall so a peer that is merely
# hitching (an asset load, an OS sleep of a second or two) is not thrown out of the game for it.
const _PEER_TIMEOUT_LIMIT: int = 32
const _PEER_TIMEOUT_MIN_MSEC: int = 2500
const _PEER_TIMEOUT_MAX_MSEC: int = 8000

## F-157. A display name is a label, not an identifier — this only needs to fit on an in-game roster
## line and a kill-feed entry, not be unique or precise.
const _DISPLAY_NAME_MAX_LEN: int = 24

var _status: _Status = _Status.OFFLINE
var _mode: NetConfig.Mode = NetConfig.Mode.OFFLINE

## Every peer in the session including the local one, ascending. Host is always 1, so it sorts first.
var _peers: PackedInt32Array = PackedInt32Array()

## F-157's registry: peer id -> sanitized display name. The HOST's copy is the canonical one — only
## the host ever writes an entry (see net_request_display_name) — every other peer's copy is a mirror
## kept current by net_display_name_changed/net_display_name_snapshot. Cleared entirely on _teardown,
## same lifecycle as _peers: a display name means nothing outside the session that assigned it.
var _display_names: Dictionary = {}

## Cached rather than read from multiplayer.get_unique_id() on demand. By the time the host-quit path
## runs, ENet has already torn the connection down and get_unique_id() no longer returns our id — so
## the "don't announce yourself" filter in _teardown() silently failed and every client emitted a
## peer_left for itself. Caught by the two-process probe; keep the cache.
var _local_id: int = 0

## Where join() was pointed, kept for error messages.
var _address: String = ""
var _port: int = 0

## Time.get_ticks_msec() past which a CONNECTING session is declared dead. 0 when not connecting.
var _connect_deadline_msec: int = 0

## Time.get_ticks_msec() at the last join(), and how long that handshake ended up taking. Together
## they are F-023's missing measurement: the deadline was chosen without anyone ever having recorded
## what a real first join costs, least of all on Windows over Steam. Every successful join now leaves
## the number in the log and in last_connect_msec(), so the next cross-platform run produces the
## distribution as a side effect instead of needing its own trip.
var _connect_started_msec: int = 0

## Engine.get_frames_drawn() when the attempt started (F-025). The pair of these gives the AVERAGE
## render rate across the handshake, which is the number that matters: Steam's pump and this file's
## watchdog were both starved by a frame-rate collapse, and a first-join latency measured on a
## software-rendered machine is contaminated by it. An instantaneous FPS reading at the moment of
## success would miss exactly the case that caused F-023 — a slow start that warmed up.
var _connect_frames_drawn: int = 0

## Average frames per second across the last successful connect, or -1.0 if none. Headless reports
## 0.0 rather than -1.0: no frames is a real answer, and one this deliberately does not hide.
var _last_connect_fps: float = -1.0
var _last_connect_msec: int = -1

## Set by the _create_*_peer helpers on the way out; read once by host()/join().
var _create_error: Error = OK
var _create_reason: String = ""

## Survives teardown on purpose — it is read by whoever handles the disconnected signal, which fires
## after the session state has already been cleared.
var _last_end_kind: EndKind = EndKind.NONE

## Where the last join() pointed, kept past teardown for the same reason: a reconnect has to know
## where it was, and by the time anything hears about the drop, _address and _port are already gone.
## Only join() writes these — a host has nothing to reconnect to.
var _target_mode: NetConfig.Mode = NetConfig.Mode.OFFLINE
var _target_address: String = ""
var _target_port: int = 0

## Host-only. Consulted for each connecting peer BEFORE it is announced; see set_admission_gate().
var _admission_gate: Callable = Callable()


func _ready() -> void:
	# The connect watchdog has to keep ticking while the game is paused — a lobby screen that pauses
	# the tree would otherwise hang forever on a dead host.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_physics_process(false)

	# These live on the MultiplayerAPI, not on the peer, so they survive every leave/rejoin. Connect
	# once, here, and never re-connect them — doing it per-session is how you get duplicate signals
	# after the third rejoin.
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	MireLog.info(NetConfig.LOG_CHANNEL, "NetTransport ready (offline)")


func _exit_tree() -> void:
	# Quiet: the tree is going away, nobody is left to hear the signals, but the socket still has to
	# be released or a fast relaunch hits "address already in use".
	_last_end_kind = EndKind.LOCAL_LEAVE
	_teardown(false)


## The connect watchdog runs on the PHYSICS tick for the same reason SteamLobby's pump does (F-025):
## on the render frame, a machine at 2 FPS checks a 10 s deadline roughly every 390 ms, so the
## deadline it enforces is not the deadline that was configured. The physics tick is fixed and the
## engine runs several of them per slow frame.
func _physics_process(_delta: float) -> void:
	if _status != _Status.CONNECTING:
		set_physics_process(false)
		return
	if Time.get_ticks_msec() < _connect_deadline_msec:
		return

	var reason: String = "connect to %s timed out after %.1fs" % [
		_describe_target(), connect_timeout_sec(_mode)
	]
	_last_end_kind = EndKind.CONNECT_TIMEOUT
	_teardown(false)
	MireLog.error(NetConfig.LOG_CHANNEL, reason)
	connection_failed.emit(reason)


# ── Public API ────────────────────────────────────────────────────────────────────────────────────


## Open a session and become the authority. Emits server_started (deferred) on success.
## [param port] of -1 means NetConfig.DEFAULT_PORT. Ignored in STEAM mode.
func host(mode: NetConfig.Mode, port: int = -1) -> Error:
	# Cleared before the first thing that can fail, not after the last thing that can succeed. A
	# synchronous failure below must not leave the PREVIOUS attempt's ending standing: NetSession's
	# retry policy reads this to decide whether to ask again, and a stale CONNECT_TIMEOUT would make
	# it retry a call that never got as far as opening a socket (F-023).
	_last_end_kind = EndKind.NONE

	if mode == NetConfig.Mode.OFFLINE:
		return _fail(ERR_INVALID_PARAMETER, "host() called with Mode.OFFLINE")
	if _status != _Status.OFFLINE:
		return _fail(ERR_ALREADY_IN_USE, "already in a %s session — call leave() first" % mode_name(_mode))

	var resolved_port: int = _resolve_port(port)
	if mode != NetConfig.Mode.STEAM and not _is_valid_port(resolved_port):
		return _fail(ERR_INVALID_PARAMETER, "port %d is outside %d..%d" % [
			resolved_port, NetConfig.PORT_MIN, NetConfig.PORT_MAX
		])

	_create_error = FAILED
	_create_reason = "no peer created for %s" % mode_name(mode)
	var peer: MultiplayerPeer = null
	match mode:
		NetConfig.Mode.LOCAL, NetConfig.Mode.LAN:
			peer = _create_enet_host(mode, resolved_port)
		NetConfig.Mode.STEAM:
			peer = _create_steam_host()
	if peer == null:
		return _fail(_create_error, _create_reason)

	multiplayer.multiplayer_peer = peer
	_mode = mode
	_status = _Status.HOSTING
	_address = NetConfig.LOOPBACK_ADDRESS if mode == NetConfig.Mode.LOCAL else NetConfig.ANY_ADDRESS
	_port = resolved_port
	_local_id = NetConfig.HOST_PEER_ID
	_peers = PackedInt32Array([NetConfig.HOST_PEER_ID])
	_last_end_kind = EndKind.NONE
	# F-157: the host is a peer too, and nothing else will ever submit a name on its behalf.
	_host_apply_display_name(_local_id, _compute_default_display_name())

	MireLog.info(NetConfig.LOG_CHANNEL, "hosting %s on %s — room for %d more" % [
		mode_name(mode), _describe_target(), NetConfig.MAX_CLIENTS
	])
	_emit_server_started.call_deferred()
	return OK


## Connect to a host. Returns OK once the attempt has *started*; success arrives as connected_to_host
## and failure as connection_failed — a returned OK is not a connection.
## [param address] is an IP/hostname for LOCAL and LAN, or a Steam ID for STEAM. Empty means loopback
## in LOCAL mode, which is what the two-window launcher passes.
func join(mode: NetConfig.Mode, address: String, port: int = -1) -> Error:
	# See host(): cleared up front so a synchronous failure cannot inherit the last attempt's ending.
	_last_end_kind = EndKind.NONE

	if mode == NetConfig.Mode.OFFLINE:
		return _fail(ERR_INVALID_PARAMETER, "join() called with Mode.OFFLINE")
	if _status != _Status.OFFLINE:
		return _fail(ERR_ALREADY_IN_USE, "already in a %s session — call leave() first" % mode_name(_mode))

	var resolved_address: String = _resolve_address(mode, address)
	if resolved_address.is_empty():
		return _fail(ERR_INVALID_PARAMETER, "join(%s) needs an address" % mode_name(mode))

	var resolved_port: int = _resolve_port(port)
	if mode != NetConfig.Mode.STEAM and not _is_valid_port(resolved_port):
		return _fail(ERR_INVALID_PARAMETER, "port %d is outside %d..%d" % [
			resolved_port, NetConfig.PORT_MIN, NetConfig.PORT_MAX
		])

	# Set before creating the peer so failure messages can name the target.
	_address = resolved_address
	_port = resolved_port

	_create_error = FAILED
	_create_reason = "no peer created for %s" % mode_name(mode)
	var peer: MultiplayerPeer = null
	match mode:
		NetConfig.Mode.LOCAL, NetConfig.Mode.LAN:
			peer = _create_enet_client(resolved_address, resolved_port)
		NetConfig.Mode.STEAM:
			peer = _create_steam_client(resolved_address)
	if peer == null:
		_address = ""
		_port = 0
		return _fail(_create_error, _create_reason)

	multiplayer.multiplayer_peer = peer
	_mode = mode
	_status = _Status.CONNECTING
	# ENet assigns the client id locally at create_client(), so this is already real and stable.
	_local_id = multiplayer.get_unique_id()
	_peers = PackedInt32Array()
	_connect_started_msec = Time.get_ticks_msec()
	_connect_frames_drawn = Engine.get_frames_drawn()
	_last_connect_msec = -1
	_last_connect_fps = -1.0
	_connect_deadline_msec = _connect_started_msec + int(connect_timeout_sec(mode) * 1000.0)
	_last_end_kind = EndKind.NONE
	_target_mode = mode
	_target_address = resolved_address
	_target_port = resolved_port
	set_physics_process(true)

	MireLog.info(NetConfig.LOG_CHANNEL, "connecting to %s (%s, %.1fs timeout)" % [
		_describe_target(), mode_name(mode), connect_timeout_sec(mode)
	])
	return OK


## End the session — hosting, connected, or still connecting. Idempotent: calling it when already
## offline does nothing and emits nothing. After this returns, host()/join() work again in the same
## process; that is what makes the two-window loop a relaunch-free ~3 seconds.
func leave() -> void:
	if _status == _Status.OFFLINE:
		return

	var was_connecting: bool = _status == _Status.CONNECTING
	MireLog.info(NetConfig.LOG_CHANNEL, "leaving %s session (%s)" % [
		mode_name(_mode), "mid-connect" if was_connecting else "established"
	])
	_last_end_kind = EndKind.LOCAL_LEAVE
	# An attempt that never completed was never a session, so it does not get a disconnected.
	_teardown(not was_connecting)


## True only while this process is the authority. Note this is NOT multiplayer.is_server(): with no
## peer assigned Godot installs an OfflineMultiplayerPeer whose is_server() is true, so every
## host-authoritative check in the game would pass in the main menu. Gate on this instead.
func is_host() -> bool:
	return _status == _Status.HOSTING


## This process's peer id, or 0 when offline. Never returns 1 for "no session" — see is_host().
func local_peer_id() -> int:
	return _local_id


## Every peer in the session INCLUDING the local one, ascending — so the host is always first.
## Empty when offline. This is the list to spawn players from; filter out local_peer_id() when you
## want remotes only.
func peer_ids() -> PackedInt32Array:
	return _peers.duplicate()


## Membership without the copy peer_ids() makes — for the F-059 "is this peer still here" guards
## that every service runs before an rpc_id() send (F-099).
func has_peer(peer_id: int) -> bool:
	return _peers.has(peer_id)


## F-157. [param peer_id]'s display name, or a "Player N" placeholder if the registry has no entry
## yet — the gap between a peer joining and its name actually landing (still in flight over the wire,
## or this process's own mirror hasn't received the broadcast/snapshot yet), and the permanent state
## for a peer id nobody ever named (offline single-player, or a check that never calls host()/join()).
func display_name(peer_id: int) -> String:
	var name: String = String(_display_names.get(peer_id, ""))
	return name if not name.is_empty() else "Player %d" % peer_id


## F-157. The whole peer id -> display name map as this process currently knows it — the host's copy
## is authoritative, every other peer's is a mirror that may briefly lag it. Entries only exist for
## peers that have actually submitted a name; missing entries fall back the same way display_name()
## does, so a caller that just wants one name should use that instead of indexing this directly.
func display_names() -> Dictionary:
	return _display_names.duplicate()


## F-157. Submit (or change) THIS process's own display name. Safe to call before a name is picked —
## host()/join() already call it once with a computed default (SteamLobby's persona in STEAM mode, an
## OS username otherwise) so nobody ends up with an empty entry — a settings/name-entry UI calls this
## again later with whatever the player actually typed. Offline or mid-connect, this is a no-op: there
## is nobody to submit to yet, and the auto-submit on connect will run once there is.
func submit_display_name(name: String) -> void:
	if _status == _Status.HOSTING:
		_host_apply_display_name(_local_id, name)
	elif _status == _Status.CONNECTED:
		net_request_display_name.rpc_id(NetConfig.HOST_PEER_ID, name)


## The mode of the current session, or of the attempt in flight. OFFLINE when there is neither.
func current_mode() -> NetConfig.Mode:
	return _mode


## True once a session is established — hosting, or connected as a client. False while connecting.
func is_active() -> bool:
	return _status == _Status.HOSTING or _status == _Status.CONNECTED


## True between join() returning OK and connected_to_host / connection_failed.
func is_connecting() -> bool:
	return _status == _Status.CONNECTING


## Why the last session or attempt ended. Valid while handling disconnected / connection_failed, and
## until the next host()/join(). NetSession turns this into something a player can read.
func last_end_kind() -> EndKind:
	return _last_end_kind


## How long the last SUCCESSFUL join took, in milliseconds, or -1 if this process has not completed
## one since its last join(). This is the number F-023 needed and nobody had: log it per platform,
## and set NetConfig.STEAM_CONNECT_TIMEOUT_SEC from the tail rather than from a guess.
func last_connect_msec() -> int:
	return _last_connect_msec


## Average FPS across the last successful connect; -1.0 before there has been one (F-025). Read it
## next to last_connect_msec(): a duration without it cannot be told apart from a duration taken on a
## machine that was rendering at 2 FPS, and that is the whole reason F-023's number is still owed.
func last_connect_fps() -> float:
	return _last_connect_fps


## The mode of the last join() this process attempted — OFFLINE if it has never joined one. Survives
## teardown, unlike current_mode(), because it is what a rejoin has to repeat AFTER the drop.
func last_target_mode() -> NetConfig.Mode:
	return _target_mode


## Human-readable form of the same target, for logs and "reconnecting to …" text.
func last_target_name() -> String:
	if _target_mode == NetConfig.Mode.OFFLINE:
		return "nowhere"
	if _target_mode == NetConfig.Mode.STEAM:
		return "steam:%s" % _target_address
	return "%s:%d" % [_target_address, _target_port]


## True if this process has a client session to get back to.
func has_rejoin_target() -> bool:
	return _target_mode != NetConfig.Mode.OFFLINE and not _target_address.is_empty()


## Repeat the last join() at the same target. Same contract as join(): OK means the attempt started,
## not that it succeeded. Exists so a reconnect does not have to carry a mode enum around the codebase
## — the target is the transport's own memory of where it was.
func rejoin_last_target() -> Error:
	if not has_rejoin_target():
		return _fail(ERR_UNCONFIGURED, "rejoin_last_target(): this process has never joined a session")
	return join(_target_mode, _target_address, _target_port)


## Install the host's admission policy. [param gate] takes a peer id and returns "" to admit, or a
## refusal reason to reject. It is consulted BEFORE peer_joined is emitted, so a refused peer is never
## announced: nothing spawns for it, nothing has to be despawned, and no other system ever sees it.
##
## The gate does NOT disconnect the peer — it only decides. Saying why (an RPC the joiner can read)
## and then closing the connection is the gate owner's job, on the deferred call queue, because the
## refusal has to reach the joiner before the socket shuts. NetSession (task 1.7) owns both halves.
##
## Ignored while not hosting. Only one gate at a time; installing a second replaces the first.
func set_admission_gate(gate: Callable) -> void:
	_admission_gate = gate


func clear_admission_gate() -> void:
	_admission_gate = Callable()


## Close a peer's connection. Host only. The peer is disconnected gracefully — pending reliable
## packets still go out, which is what lets a refusal reason arrive ahead of the close — and both
## sides then see it as an ordinary departure: peer_left here, disconnected there.
func kick_peer(peer_id: int) -> void:
	if _status != _Status.HOSTING:
		MireLog.warn(NetConfig.LOG_CHANNEL, "kick_peer(%d) ignored — not hosting" % peer_id)
		return
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return
	MireLog.info(NetConfig.LOG_CHANNEL, "disconnecting peer %d" % peer_id)
	peer.disconnect_peer(peer_id)


## For logs and UI. Static so callers can name a mode they have not connected with yet.
static func mode_name(mode: NetConfig.Mode) -> String:
	var index: int = int(mode)
	if index < 0 or index >= NetConfig.MODE_NAMES.size():
		return "MODE_%d" % index
	return NetConfig.MODE_NAMES[index]


## Whether STEAM mode can be selected at all. False until task 1.1 installs GodotSteam.
static func steam_available() -> bool:
	return ClassDB.class_exists(NetConfig.STEAM_PEER_CLASS) and Engine.has_singleton(NetConfig.STEAM_SINGLETON)


## True if this 64-bit Steam id names a lobby rather than a player. join(Mode.STEAM, id) accepts
## either and this is how it tells them apart: Steam packs the account type into bits 52-55, so a
## lobby reads back as k_EAccountTypeChat and a person as k_EAccountTypeIndividual. Cheaper and more
## reliable than asking Steam, and it works before the addon has been initialised.
static func is_lobby_id(steam_id: int) -> bool:
	var account_type: int = (steam_id >> NetConfig.STEAM_ACCOUNT_TYPE_SHIFT) & NetConfig.STEAM_ACCOUNT_TYPE_MASK
	return account_type == NetConfig.STEAM_ACCOUNT_TYPE_CHAT


# ── MultiplayerAPI callbacks ──────────────────────────────────────────────────────────────────────


func _on_peer_connected(id: int) -> void:
	if _status == _Status.OFFLINE:
		return

	# ENet clients connect directly only to peer 1; their notifications for other clients describe
	# relayed high-level peers which ENetPacketPeer cannot look up. The host owns every client link.
	if _status == _Status.HOSTING or id == NetConfig.HOST_PEER_ID:
		_tune_peer_timeout(id)

	if _status == _Status.HOSTING and not _admit(id):
		return

	if _status == _Status.CONNECTING:
		# Godot can deliver the host's id before it tells us the handshake finished. Record it, but
		# hold the peer_joined: nobody should hear about membership in a session they have not yet
		# been told they are in. _on_connected_to_server flushes these.
		_track_peer(id)
		return
	_add_peer(id)


func _on_peer_disconnected(id: int) -> void:
	var index: int = _peers.find(id)
	if index == -1:
		return
	_peers.remove_at(index)
	MireLog.info(NetConfig.LOG_CHANNEL, "peer %d left (%d/%d)" % [
		id, _peers.size(), NetConfig.MAX_PLAYERS
	])
	# Erased AFTER the signal, not before: a listener naming who just left (NetDebugPanel's log line,
	# F-157) needs display_name(id) to still resolve during peer_left, not already be back to the
	# "Player N" placeholder.
	peer_left.emit(id)
	_display_names.erase(id)


## Frames actually drawn across the attempt, over its wall-clock duration. Not Engine.get_frames_
## per_second(), which is an instantaneous reading and would report the healthy rate a slow handshake
## finally warmed up to rather than the starved one that made it slow.
func _measure_connect_fps() -> float:
	if _last_connect_msec <= 0:
		return -1.0
	var frames: int = Engine.get_frames_drawn() - _connect_frames_drawn
	return float(frames) * 1000.0 / float(_last_connect_msec)


func _on_connected_to_server() -> void:
	set_physics_process(false)
	_connect_deadline_msec = 0
	_last_connect_msec = Time.get_ticks_msec() - _connect_started_msec
	_last_connect_fps = _measure_connect_fps()
	_status = _Status.CONNECTED

	# Re-read rather than trust the id join() cached: the host has the final say on who we are.
	_local_id = multiplayer.get_unique_id()
	var self_id: int = _local_id
	var pending: PackedInt32Array = _peers.duplicate()
	_peers = PackedInt32Array([self_id])

	# The elapsed time is not decoration. It is the only per-platform record of what a handshake
	# actually costs, and F-023 exists because the deadline above it was set without one.
	MireLog.info(NetConfig.LOG_CHANNEL, "connected to %s as peer %d (%s) in %.2fs at %.1f FPS" % [
		_describe_target(), self_id, mode_name(_mode), _last_connect_msec / 1000.0, _last_connect_fps
	])
	connected_to_host.emit()

	# The host is always a peer. Then anything that arrived mid-handshake, in id order. _add_peer
	# de-duplicates, so it does not matter whether Godot already told us about these.
	_add_peer(NetConfig.HOST_PEER_ID)
	pending.sort()
	for id: int in pending:
		if id != self_id:
			_add_peer(id)

	# F-157: tell the host who we'd like to be called. Sent after the peer bookkeeping above so a
	# server-side handler reading _peers for validation already sees us in it.
	submit_display_name(_compute_default_display_name())


func _on_connection_failed() -> void:
	var reason: String = "%s refused the connection or is not there" % _describe_target()
	_last_end_kind = EndKind.CONNECT_FAILED
	_teardown(false)
	MireLog.error(NetConfig.LOG_CHANNEL, reason)
	connection_failed.emit(reason)


func _on_server_disconnected() -> void:
	MireLog.warn(NetConfig.LOG_CHANNEL, "host closed the session")
	_last_end_kind = EndKind.REMOTE_CLOSED
	# Announces: every remote peer gets a peer_left so gameplay can despawn them, then disconnected.
	_teardown(true)


# ── Peer bookkeeping ──────────────────────────────────────────────────────────────────────────────


## Ask the installed gate whether this peer may join. True when there is no gate — an ungated host
## admits everyone, which is exactly what every mode did before the gate existed.
func _admit(peer_id: int) -> bool:
	if not _admission_gate.is_valid():
		return true
	var refusal: String = str(_admission_gate.call(peer_id))
	if refusal.is_empty():
		return true
	# Deliberately not announced and deliberately not disconnected here: the gate owner still has to
	# get the reason onto the wire, and disconnecting inside this callback would beat it there.
	MireLog.warn(NetConfig.LOG_CHANNEL, "peer %d refused: %s" % [peer_id, refusal])
	return false


## Bound ENet's dead-peer detection for a directly connected peer. No-op on any other transport —
## SteamMultiplayerPeer has no equivalent knob, so Steam keeps its own keepalive policy.
func _tune_peer_timeout(id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var link: ENetPacketPeer = enet.get_peer(id)
	if link == null:
		return
	link.set_timeout(_PEER_TIMEOUT_LIMIT, _PEER_TIMEOUT_MIN_MSEC, _PEER_TIMEOUT_MAX_MSEC)


## Add to the roster without announcing it.
func _track_peer(id: int) -> bool:
	if _peers.has(id):
		return false
	_peers.append(id)
	_peers.sort()
	return true


func _add_peer(id: int) -> void:
	if not _track_peer(id):
		return
	MireLog.info(NetConfig.LOG_CHANNEL, "peer %d joined (%d/%d)" % [
		id, _peers.size(), NetConfig.MAX_PLAYERS
	])
	peer_joined.emit(id)
	# F-157: hand the newcomer everyone's name so far — this peer's own submit_display_name() call
	# (fired separately, once it reaches CONNECTED) tells the host what IT wants to be called, not
	# what everyone else already picked.
	if _status == _Status.HOSTING and id != _local_id:
		net_display_name_snapshot.rpc_id(id, _display_names)


# ── Display names (F-157) ─────────────────────────────────────────────────────────────────────────
#
# Authority (§2.2): HOST. The map lives here because NetTransport already owns the right lifecycle
# hooks (_peers, _track_peer/_add_peer, peer_joined/peer_left) and the right key — the in-session net
# peer id every other system uses, unlike SteamLobby's Steam-id-keyed lobby roster. A client's chosen
# name is untrusted input crossing the wire, same stance every other write RPC in this project takes
# (D-078's neighbor): sanitization happens ONLY on the host, in _host_apply_display_name. Two peers
# picking the same name is allowed, not deduped — CommandService._parse_peer() refuses an ambiguous
# name instead of guessing which peer it means.


## Host-only: receives a client's own chosen name and decides what actually lands in the registry.
## Ignored outside HOSTING (a stray call after leave()) and from anyone not currently a tracked peer
## (a departed peer's in-flight packet, F-059's usual guard in reverse).
@rpc("any_peer", "call_remote", "reliable")
func net_request_display_name(raw_name: String) -> void:
	if _status != _Status.HOSTING:
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id <= 0 or not _peers.has(sender_id):
		return
	_host_apply_display_name(sender_id, raw_name)


## Host -> every other peer: one id's name changed. `rpc()` without call_local reaches every
## CONNECTED remote, including the peer being renamed — which is correct here, not wasteful: that
## peer's own mirror needs the host's SANITIZED result (it may differ from what it submitted), and it
## learns that no other way. Only the host's own entry skips a round trip, applied directly by
## _host_apply_display_name before this ever fires.
@rpc("authority", "call_remote", "reliable")
func net_display_name_changed(peer_id: int, name: String) -> void:
	_display_names[peer_id] = name
	display_name_changed.emit(peer_id, name)


## Host -> one newly admitted peer: the full map as it stands, so a joiner sees every existing
## player's name without waiting on each of them to individually resubmit. Same shape as
## net_rule_snapshot (task 3.14) — one full-state catch-up RPC, ongoing changes ride the smaller
## per-id broadcast above.
@rpc("authority", "call_remote", "reliable")
func net_display_name_snapshot(names: Dictionary) -> void:
	for id_v: Variant in names:
		var id: int = int(id_v)
		var name: String = String(names[id_v])
		_display_names[id] = name
		display_name_changed.emit(id, name)


## The only writer of _display_names. Applies the sanitized name and — since this may be called for
## the host's OWN id with nobody else on the wire yet (see host()) — only broadcasts when there is
## somebody to broadcast to. A no-op change (same name resubmitted) still gets here but is filtered
## before it costs a broadcast.
func _host_apply_display_name(peer_id: int, raw_name: String) -> void:
	var name: String = _sanitize_display_name(raw_name, peer_id)
	if String(_display_names.get(peer_id, "")) == name:
		return
	_display_names[peer_id] = name
	display_name_changed.emit(peer_id, name)
	if _status == _Status.HOSTING:
		net_display_name_changed.rpc(peer_id, name)


## Never trust the client's string raw (same stance as every other write RPC in this project): strip
## control characters, trim, cap length, and fall back to a placeholder if nothing printable survives
## — an empty or all-control-character submission must still leave the peer addressable by name rather
## than by a name nobody can type.
func _sanitize_display_name(raw: String, peer_id: int) -> String:
	var cleaned: String = ""
	for c: String in raw:
		var code: int = c.unicode_at(0)
		if code >= 0x20 and code != 0x7F:
			cleaned += c
	cleaned = cleaned.strip_edges()
	if cleaned.length() > _DISPLAY_NAME_MAX_LEN:
		cleaned = cleaned.substr(0, _DISPLAY_NAME_MAX_LEN).strip_edges()
	return cleaned if not cleaned.is_empty() else "Player %d" % peer_id


## What this process would like to be called, before anyone has typed anything into a name-entry UI
## (none exists yet — F-157 is the registry, not the UI). STEAM threads through SteamLobby's own
## persona lookup (`_persona`, already resolved for lobby members); LOCAL/LAN has no such source, so
## an OS username is the best available default. Sanitized on arrival at the host either way, so an
## empty or unusable result here is fine — it becomes the "Player N" fallback there, not here.
func _compute_default_display_name() -> String:
	if _mode == NetConfig.Mode.STEAM:
		var lobby: Node = get_node_or_null(^"/root/SteamLobby")
		if lobby != null and lobby.has_method(&"local_persona_name"):
			var persona: String = String(lobby.call(&"local_persona_name"))
			if not persona.is_empty():
				return persona
	var username: String = OS.get_environment("USERNAME")
	return username if not username.is_empty() else OS.get_environment("USER")


# ── Teardown ──────────────────────────────────────────────────────────────────────────────────────


## The only path back to OFFLINE. [param announce] emits peer_left for every remote peer and then
## disconnected; pass false when there was no established session to lose.
func _teardown(announce: bool) -> void:
	var departed: PackedInt32Array = _peers.duplicate()
	var local_id: int = _local_id

	set_physics_process(false)
	_connect_deadline_msec = 0

	# close() before dropping the reference. Without it the UDP socket lingers and re-hosting on the
	# same port in the same process fails — which is exactly the rejoin case the dev loop depends on.
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	multiplayer.multiplayer_peer = null

	_status = _Status.OFFLINE
	_mode = NetConfig.Mode.OFFLINE
	_peers = PackedInt32Array()
	_local_id = 0
	_address = ""
	_port = 0

	if not announce:
		_display_names.clear()
		return
	for id: int in departed:
		if id != local_id:
			peer_left.emit(id)
	disconnected.emit()
	# Cleared AFTER the announcements, not before — same reasoning as _on_peer_disconnected: a
	# listener naming who just left (NetDebugPanel's log line, F-157) needs display_name(id) to still
	# resolve while peer_left is firing.
	_display_names.clear()


# ── ENet peers (LOCAL, LAN) ───────────────────────────────────────────────────────────────────────


func _create_enet_host(mode: NetConfig.Mode, port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	# LOCAL binds loopback only. Nothing is exposed to the network while developing, and macOS stops
	# raising its "accept incoming connections?" prompt on every single launch — that prompt is most
	# of the difference between a 3-second iteration and an annoying one.
	peer.set_bind_ip(
		NetConfig.LOOPBACK_ADDRESS if mode == NetConfig.Mode.LOCAL else NetConfig.ANY_ADDRESS
	)
	# Capacity is the admission gate's call, not ENet's — see ADMISSION_SLACK.
	var err: Error = peer.create_server(port, NetConfig.MAX_CLIENTS + ADMISSION_SLACK)
	if err != OK:
		_note_failure(err, "could not bind port %d (%s) — another instance is probably still running" % [
			port, error_string(err)
		])
		return null
	return peer


func _create_enet_client(address: String, port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		_note_failure(err, "could not open a client socket for %s:%d (%s)" % [
			address, port, error_string(err)
		])
		return null
	return peer


# ── Steam seam ────────────────────────────────────────────────────────────────────────────────────
#
# GodotSteam is a GDExtension, so `SteamMultiplayerPeer` is not a symbol the parser can see until the
# addon is installed (task 1.1). Everything below therefore goes through ClassDB/Engine by name: this
# file parses, and the whole project runs, with the addon absent — which is the state we are in.
#
# Task 1.4 filled this in. Both bodies below stayed synchronous and no signature moved, because the
# asynchronous half of Steam — createLobby and joinLobby answer by callback — lives in the SteamLobby
# autoload instead. That split is forced by GodotSteam itself, and it is worth knowing why:
#
#   · host_with_lobby(id) fails unless you ALREADY own that lobby
#   · connect_to_lobby(id) fails unless you are ALREADY a member of it
#
# (Both verified in godotsteam_multiplayer_peer.cpp at the pinned build, D-022: each calls
# GetLobbyOwner first and bails on 0.) So the lobby must exist before either call, and something has
# to wait for Steam's callback. SteamLobby does that waiting and only then calls host()/join() here —
# by which time the lobby is real and these two functions are ordinary synchronous peer setup.
#
# Direct connection by a player's Steam ID still works with no lobby at all; it is just invisible to
# the friends list, which is what the lobby buys.


func _create_steam_host() -> MultiplayerPeer:
	var peer: MultiplayerPeer = _instantiate_steam_peer()
	if peer == null:
		return null

	# host_with_lobby also adds every member already sitting in the lobby as a peer, which is what
	# makes "friends join the lobby, then the host starts" work rather than only the reverse.
	var lobby_id: int = _current_steam_lobby()
	if lobby_id != 0:
		return _call_steam_peer(peer, &"host_with_lobby", [lobby_id])

	# No lobby: a valid session, reachable only by someone who already knows our Steam ID.
	MireLog.warn(NetConfig.LOG_CHANNEL,
		"hosting STEAM without a lobby — friends cannot see or be invited to this session; use SteamLobby.host_session() for that")
	return _call_steam_peer(peer, &"create_host", [NetConfig.STEAM_VIRTUAL_PORT])


func _create_steam_client(steam_id: String) -> MultiplayerPeer:
	var peer: MultiplayerPeer = _instantiate_steam_peer()
	if peer == null:
		return null
	if not steam_id.is_valid_int():
		_note_failure(ERR_INVALID_PARAMETER, "STEAM mode needs a numeric Steam ID, got '%s'" % steam_id)
		return null

	var id: int = steam_id.to_int()
	if is_lobby_id(id):
		# SteamLobby.join_by_id() has already put us in this lobby and waited for the callback, so the
		# owner lookup inside connect_to_lobby resolves. Reached directly, this is the failure the
		# GodotSteam source words as "You must be a member of the lobby you are trying to connect".
		return _call_steam_peer(peer, &"connect_to_lobby", [id])
	return _call_steam_peer(peer, &"create_client", [id, NetConfig.STEAM_VIRTUAL_PORT])


## The lobby SteamLobby currently holds, or 0. Looked up by node path rather than by name so this file
## keeps working with the SteamLobby autoload absent — the state every non-Steam mode runs in.
func _current_steam_lobby() -> int:
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby == null or not lobby.has_method(&"current_lobby_id"):
		return 0
	return int(lobby.call(&"current_lobby_id"))


## Returns null and records a clear reason when GodotSteam is not installed — the "not yet" path that
## every STEAM call takes today.
func _instantiate_steam_peer() -> MultiplayerPeer:
	if not steam_available():
		_note_failure(ERR_UNAVAILABLE, _STEAM_UNAVAILABLE)
		return null
	var instance: Variant = ClassDB.instantiate(NetConfig.STEAM_PEER_CLASS)
	var peer := instance as MultiplayerPeer
	if peer == null:
		_note_failure(ERR_UNAVAILABLE, "%s is registered but is not a MultiplayerPeer — wrong GodotSteam branch?" % NetConfig.STEAM_PEER_CLASS)
	return peer


## Dynamic dispatch so an API drift in GodotSteam surfaces as a readable error instead of a crash.
func _call_steam_peer(peer: MultiplayerPeer, method: StringName, args: Array) -> MultiplayerPeer:
	if not peer.has_method(method):
		_note_failure(ERR_UNAVAILABLE, "%s has no %s() — check the GodotSteam version against §2.4" % [
			NetConfig.STEAM_PEER_CLASS, method
		])
		return null
	var result: Variant = peer.callv(method, args)
	var code: int = result if typeof(result) == TYPE_INT else int(OK)
	if code != int(OK):
		_note_failure(ERR_CANT_CREATE, "%s.%s() failed with code %d" % [
			NetConfig.STEAM_PEER_CLASS, method, code
		])
		return null
	return peer


# ── Small helpers ─────────────────────────────────────────────────────────────────────────────────


## Log it, hand it to anyone listening on the signal, and give it back to the caller. Deferred so a
## caller that connects the signal after the call still hears about a synchronous failure.
func _fail(err: Error, reason: String) -> Error:
	MireLog.error(NetConfig.LOG_CHANNEL, reason)
	_emit_failure.call_deferred(reason)
	return err


func _note_failure(err: Error, reason: String) -> void:
	_create_error = err
	_create_reason = reason


func _emit_failure(reason: String) -> void:
	connection_failed.emit(reason)


func _emit_server_started() -> void:
	server_started.emit()


func _resolve_port(port: int) -> int:
	return NetConfig.DEFAULT_PORT if port < 0 else port


func _is_valid_port(port: int) -> bool:
	return port >= NetConfig.PORT_MIN and port <= NetConfig.PORT_MAX


func _resolve_address(mode: NetConfig.Mode, address: String) -> String:
	if mode == NetConfig.Mode.LOCAL and address.is_empty():
		return NetConfig.LOOPBACK_ADDRESS
	return address


## How long a join() in this mode is given before the watchdog calls it dead. Public and static
## because a caller that waits on a connect has to wait at least this long: NetSession's rejoin
## backstop used to hard-code the ENet number, which after F-023 gave Steam a 12 s backstop over a
## 20 s budget and would have cancelled attempts that were still perfectly alive.
static func connect_timeout_sec(mode: NetConfig.Mode) -> float:
	match mode:
		NetConfig.Mode.LOCAL:
			return NetConfig.LOCAL_CONNECT_TIMEOUT_SEC
		NetConfig.Mode.STEAM:
			return NetConfig.STEAM_CONNECT_TIMEOUT_SEC
		_:
			return NetConfig.CONNECT_TIMEOUT_SEC


func _describe_target() -> String:
	if _mode == NetConfig.Mode.STEAM:
		return "steam:%s" % _address
	if _address.is_empty():
		return "port %d" % _port
	return "%s:%d" % [_address, _port]
