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

## Private on purpose — callers branch on is_host() / is_active() / current_mode(), not on this.
enum _Status { OFFLINE, HOSTING, CONNECTING, CONNECTED }

const _STEAM_UNAVAILABLE: String = "STEAM mode unavailable: the GodotSteam GDExtension is not installed yet (task 1.1) — use Mode.LOCAL for the two-window dev loop, or Mode.LAN for a second machine"

var _status: _Status = _Status.OFFLINE
var _mode: NetConfig.Mode = NetConfig.Mode.OFFLINE

## Every peer in the session including the local one, ascending. Host is always 1, so it sorts first.
var _peers: PackedInt32Array = PackedInt32Array()

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

## Set by the _create_*_peer helpers on the way out; read once by host()/join().
var _create_error: Error = OK
var _create_reason: String = ""


func _ready() -> void:
	# The connect watchdog has to keep ticking while the game is paused — a lobby screen that pauses
	# the tree would otherwise hang forever on a dead host.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

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
	_teardown(false)


func _process(_delta: float) -> void:
	if _status != _Status.CONNECTING:
		set_process(false)
		return
	if Time.get_ticks_msec() < _connect_deadline_msec:
		return

	var reason: String = "connect to %s timed out after %.1fs" % [
		_describe_target(), _timeout_for(_mode)
	]
	_teardown(false)
	MireLog.error(NetConfig.LOG_CHANNEL, reason)
	connection_failed.emit(reason)


# ── Public API ────────────────────────────────────────────────────────────────────────────────────


## Open a session and become the authority. Emits server_started (deferred) on success.
## [param port] of -1 means NetConfig.DEFAULT_PORT. Ignored in STEAM mode.
func host(mode: NetConfig.Mode, port: int = -1) -> Error:
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
	_connect_deadline_msec = Time.get_ticks_msec() + int(_timeout_for(mode) * 1000.0)
	set_process(true)

	MireLog.info(NetConfig.LOG_CHANNEL, "connecting to %s (%s, %.1fs timeout)" % [
		_describe_target(), mode_name(mode), _timeout_for(mode)
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


## The mode of the current session, or of the attempt in flight. OFFLINE when there is neither.
func current_mode() -> NetConfig.Mode:
	return _mode


## True once a session is established — hosting, or connected as a client. False while connecting.
func is_active() -> bool:
	return _status == _Status.HOSTING or _status == _Status.CONNECTED


## True between join() returning OK and connected_to_host / connection_failed.
func is_connecting() -> bool:
	return _status == _Status.CONNECTING


## For logs and UI. Static so callers can name a mode they have not connected with yet.
static func mode_name(mode: NetConfig.Mode) -> String:
	var index: int = int(mode)
	if index < 0 or index >= NetConfig.MODE_NAMES.size():
		return "MODE_%d" % index
	return NetConfig.MODE_NAMES[index]


## Whether STEAM mode can be selected at all. False until task 1.1 installs GodotSteam.
static func steam_available() -> bool:
	return ClassDB.class_exists(NetConfig.STEAM_PEER_CLASS) and Engine.has_singleton(NetConfig.STEAM_SINGLETON)


# ── MultiplayerAPI callbacks ──────────────────────────────────────────────────────────────────────


func _on_peer_connected(id: int) -> void:
	match _status:
		_Status.OFFLINE:
			return
		_Status.CONNECTING:
			# Godot can deliver the host's id before it tells us the handshake finished. Record it,
			# but hold the peer_joined: nobody should hear about membership in a session they have
			# not yet been told they are in. _on_connected_to_server flushes these.
			_track_peer(id)
		_:
			_add_peer(id)


func _on_peer_disconnected(id: int) -> void:
	var index: int = _peers.find(id)
	if index == -1:
		return
	_peers.remove_at(index)
	MireLog.info(NetConfig.LOG_CHANNEL, "peer %d left (%d/%d)" % [
		id, _peers.size(), NetConfig.MAX_PLAYERS
	])
	peer_left.emit(id)


func _on_connected_to_server() -> void:
	set_process(false)
	_connect_deadline_msec = 0
	_status = _Status.CONNECTED

	# Re-read rather than trust the id join() cached: the host has the final say on who we are.
	_local_id = multiplayer.get_unique_id()
	var self_id: int = _local_id
	var pending: PackedInt32Array = _peers.duplicate()
	_peers = PackedInt32Array([self_id])

	MireLog.info(NetConfig.LOG_CHANNEL, "connected to %s as peer %d (%s)" % [
		_describe_target(), self_id, mode_name(_mode)
	])
	connected_to_host.emit()

	# The host is always a peer. Then anything that arrived mid-handshake, in id order. _add_peer
	# de-duplicates, so it does not matter whether Godot already told us about these.
	_add_peer(NetConfig.HOST_PEER_ID)
	pending.sort()
	for id: int in pending:
		if id != self_id:
			_add_peer(id)


func _on_connection_failed() -> void:
	var reason: String = "%s refused the connection or is not there" % _describe_target()
	_teardown(false)
	MireLog.error(NetConfig.LOG_CHANNEL, reason)
	connection_failed.emit(reason)


func _on_server_disconnected() -> void:
	MireLog.warn(NetConfig.LOG_CHANNEL, "host closed the session")
	# Announces: every remote peer gets a peer_left so gameplay can despawn them, then disconnected.
	_teardown(true)


# ── Peer bookkeeping ──────────────────────────────────────────────────────────────────────────────


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


# ── Teardown ──────────────────────────────────────────────────────────────────────────────────────


## The only path back to OFFLINE. [param announce] emits peer_left for every remote peer and then
## disconnected; pass false when there was no established session to lose.
func _teardown(announce: bool) -> void:
	var departed: PackedInt32Array = _peers.duplicate()
	var local_id: int = _local_id

	set_process(false)
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
		return
	for id: int in departed:
		if id != local_id:
			peer_left.emit(id)
	disconnected.emit()


# ── ENet peers (LOCAL, LAN) ───────────────────────────────────────────────────────────────────────


func _create_enet_host(mode: NetConfig.Mode, port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	# LOCAL binds loopback only. Nothing is exposed to the network while developing, and macOS stops
	# raising its "accept incoming connections?" prompt on every single launch — that prompt is most
	# of the difference between a 3-second iteration and an annoying one.
	peer.set_bind_ip(
		NetConfig.LOOPBACK_ADDRESS if mode == NetConfig.Mode.LOCAL else NetConfig.ANY_ADDRESS
	)
	var err: Error = peer.create_server(port, NetConfig.MAX_CLIENTS)
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
# Task 1.4 owns finishing this. It replaces the two function bodies below and touches nothing else in
# the file: no signature moves, no caller changes, no gameplay code recompiled. That is the seam.
# What 1.4 still has to add, in the marked spots:
#   · Steam.steamInit / App ID 480 bootstrap (NetConfig.STEAM_APP_ID)
#   · createLobby on host, joinLobby on join, and the lobby id → owner Steam ID lookup
#   · the overlay invite path, and lobby member list → peer list reconciliation
#   · verify create_host/create_client signatures against the installed GodotSteam version


func _create_steam_host() -> MultiplayerPeer:
	var peer: MultiplayerPeer = _instantiate_steam_peer()
	if peer == null:
		return null
	# TODO(1.4): create the Steam lobby first and keep its id — create_host() only opens the P2P
	# listen socket, it does not make the session findable or invitable.
	return _call_steam_peer(peer, &"create_host", [NetConfig.STEAM_VIRTUAL_PORT])


func _create_steam_client(steam_id: String) -> MultiplayerPeer:
	var peer: MultiplayerPeer = _instantiate_steam_peer()
	if peer == null:
		return null
	if not steam_id.is_valid_int():
		_note_failure(ERR_INVALID_PARAMETER, "STEAM mode needs a numeric Steam ID, got '%s'" % steam_id)
		return null
	# TODO(1.4): if the caller handed us a *lobby* id, join the lobby and resolve the owner's Steam ID
	# here before opening the P2P connection.
	return _call_steam_peer(peer, &"create_client", [steam_id.to_int(), NetConfig.STEAM_VIRTUAL_PORT])


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


func _timeout_for(mode: NetConfig.Mode) -> float:
	if mode == NetConfig.Mode.LOCAL:
		return NetConfig.LOCAL_CONNECT_TIMEOUT_SEC
	return NetConfig.CONNECT_TIMEOUT_SEC


func _describe_target() -> String:
	if _mode == NetConfig.Mode.STEAM:
		return "steam:%s" % _address
	if _address.is_empty():
		return "port %d" % _port
	return "%s:%d" % [_address, _port]
