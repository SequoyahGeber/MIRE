extends Node
## NetSession — autoload. The lifecycle NetTransport deliberately does not have an opinion about
## (task 1.7): who is allowed in, what a drop MEANS, and what to do about it.
##
## NetTransport is the pipe — it opens, it closes, it tells you a peer appeared. It cannot tell you
## whether the host quit or your wifi died, because ENet reports both as the same event, and it has no
## business knowing that six is the maximum number of players. That is all here.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2) — HOST, for the one thing this owns: admission.
## Only the host decides whether a peer is in the session, exactly as only the host decides that a
## player exists (PlayerNet). Nothing here is replicated. Host notices use `@rpc("authority")`; the
## one client hello uses `@rpc("any_peer")` with an explicit host guard and sender-id lookup.
##
##   · Admission (is there room, are joins open) → HOST. Clients are told, never asked.
##   · Rejoining after a drop                    → CLIENT-local. Your own client decides to try
##                                                 again; the host just sees an ordinary new joiner.
##
## WHAT A CLIENT ENDS UP KNOWING, which is the whole point — every ending is one of these, with a
## sentence that can go straight on a screen:
##
##     LOCAL_LEAVE      you left
##     HOST_CLOSED      the host ended the session (they told us before going)
##     CONNECTION_LOST  contact was lost, and rejoining did not get it back
##     REFUSED          the host would not let us in, and said why
##
## THE MID-SESSION JOIN NEEDS NOTHING HERE. A peer that arrives at minute forty gets the existing
## players because MultiplayerSpawner replays its spawns to every new peer by itself, and gets
## authority right because it is derived from the node name (task 1.5). This file only decides whether
## that peer is let in at all — see the harness, which proves the late joiner really does see everyone.

## Task 1.11's version handshake lands here rather than in NetTransport, where its note proposed it:
## refusing a peer whose build disagrees is the same act as refusing one that does not fit, and this
## file already owns "say why, flush, close". One caveat that came with the shape — the hello can only
## be sent once the peer is connected, so a mismatched joiner is admitted and spawned for the few
## milliseconds before it is refused. Catching it earlier means SceneMultiplayer's auth_callback, which
## is a bigger seam than a wrong-build case justifies today.
##
## F-016: NetVersion is a class_name that is not in .godot/global_script_class_cache.cfg yet, so a bare
## reference does not resolve in a --script main loop. preload() resolves in both.
const NET_VERSION: GDScript = preload("res://core/net/net_version.gd")

## Why a session ended. LOCAL_LEAVE covers the host ending its own session too: from the host's side,
## quitting is leaving.
enum EndReason { NONE, LOCAL_LEAVE, HOST_CLOSED, CONNECTION_LOST, REFUSED }

## Fired once per session, on host and client alike, when there is a session to be in.
signal session_opened(is_host: bool)

## Fired once per session when it is over for good — after any rejoin attempts have been exhausted,
## never before them. [param reason] is an EndReason; [param detail] is a sentence for the player.
signal session_ended(reason: EndReason, detail: String)

## Client-side. Contact was lost and a rejoin is starting. Between this and either [signal rejoined]
## or [signal session_ended] the world is already gone — PlayerNet clears on disconnect — so this is
## the cue for "Reconnecting…", not for keeping the game running.
signal connection_interrupted(detail: String)
signal rejoin_attempted(attempt: int, of: int)
signal rejoined()

## Host-side. A peer was turned away, with the reason it was given. Capacity/policy refusals happen
## before admission; a version refusal happens just after connection and is immediately despawned.
signal peer_refused(peer_id: int, detail: String)

## How long the refusal notice gets to reach the joiner before its connection is closed. The RPC is
## reliable, so this is flush time, not hope: a loopback round trip is under a millisecond and a bad
## home connection is well inside this.
const REFUSAL_FLUSH_SEC: float = 0.25

## How long the host's "I'm closing" notice gets before the socket goes. Same reasoning; this one runs
## while the host is quitting, so it is the pause a player waits through when they end a session.
const CLOSING_FLUSH_SEC: float = 0.15

## Rejoin attempts after an unexpected drop, and the wait before each. Backing off matters: a host
## that is restarting needs a second, and hammering it is how you get refused by a socket that is
## still coming up. Four attempts spread over ~7 s covers a transient wifi drop and gives up fast
## enough that a genuinely dead host does not look like a hang.
const REJOIN_BACKOFF_SEC: Array[float] = [0.5, 1.0, 2.0, 4.0]

## How often the rejoin loop checks whether the attempt in flight has resolved.
const REJOIN_POLL_SEC: float = 0.1

# ── Policy — the host's, and only the host's ──────────────────────────────────────────────────────
#
# These are vars rather than NetConfig constants on purpose: unlike replication settings, none of them
# has to be byte-identical across processes. Capacity is enforced in one place, on one machine, and a
# client never evaluates it. That is also what makes them testable — tools/session_lifecycle_check.gd
# lowers the capacity rather than launching seven Godots.

## Players allowed in the session, INCLUDING the host. The game never changes this; tests do.
var capacity: int = NetConfig.MAX_PLAYERS

## Set false to hold the door shut with room to spare — a run that has started, a loading screen.
## Nothing in M1 sets it; it exists so that "no new players right now" has one answer instead of
## being reinvented per system.
var accepting_joins: bool = true

## Client-side. Whether an unexpected drop is retried at all. Off for headless probes that want the
## drop reported rather than papered over.
var auto_rejoin: bool = true

# ── State ─────────────────────────────────────────────────────────────────────────────────────────

var _open: bool = false
var _was_host: bool = false

## Set by the host's notices. Cleared at the start of every session, because a stale one would
## mislabel the NEXT disconnect.
var _host_closing: bool = false
var _refusal: String = ""

var _rejoining: bool = false


func _ready() -> void:
	# The rejoin loop and the closing notice both have to survive a paused tree — a pause menu is
	# exactly where "the host quit" tends to be noticed.
	process_mode = Node.PROCESS_MODE_ALWAYS

	NetTransport.server_started.connect(_on_session_opened)
	NetTransport.connected_to_host.connect(_on_session_opened)
	NetTransport.disconnected.connect(_on_disconnected)

	# Ignored while not hosting, so it can be installed once and left alone.
	NetTransport.set_admission_gate(_gate_peer)

	# DevLaunch opens its session inside its own _ready(), which runs before this autoload exists to
	# hear server_started. Catch up rather than depend on registration order — same reason PlayerNet
	# does it, and the same fix.
	if NetTransport.is_active():
		_on_session_opened.call_deferred()


# ── Public API ────────────────────────────────────────────────────────────────────────────────────


## End the session deliberately. Prefer this over NetTransport.leave(): a host that goes through here
## tells its clients first, so they report "the host ended the session" instead of "connection lost"
## and do not spend seven seconds trying to reconnect to a process that has quit.
##
## Safe to await or to fire and forget. Idempotent.
func end_session() -> void:
	if not NetTransport.is_active() and not NetTransport.is_connecting():
		return

	_rejoining = false  # cancels any attempt in flight; see _run_rejoin.

	if NetTransport.is_host():
		MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: closing the session, telling %d peer(s)" % [
			maxi(NetTransport.peer_ids().size() - 1, 0)
		])
		net_host_closing.rpc()
		await get_tree().create_timer(CLOSING_FLUSH_SEC).timeout

	NetTransport.leave()


## Turn a peer away by hand. Host only. It is told why, exactly as an over-capacity joiner is.
func refuse_peer(peer_id: int, detail: String) -> void:
	if not NetTransport.is_host():
		MireLog.warn(NetConfig.LOG_CHANNEL, "NetSession: refuse_peer(%d) ignored — not hosting" % peer_id)
		return
	_refuse(peer_id, detail)


## True while a rejoin is being attempted — the window in which the game has no session but has not
## given up on one either.
func is_rejoining() -> bool:
	return _rejoining


## How many more players fit. Host-side; 0 on a client, which does not evaluate capacity.
func free_slots() -> int:
	if not NetTransport.is_host():
		return 0
	return maxi(capacity - NetTransport.peer_ids().size(), 0)


## For logs and UI.
static func reason_name(reason: EndReason) -> String:
	match reason:
		EndReason.LOCAL_LEAVE:
			return "LOCAL_LEAVE"
		EndReason.HOST_CLOSED:
			return "HOST_CLOSED"
		EndReason.CONNECTION_LOST:
			return "CONNECTION_LOST"
		EndReason.REFUSED:
			return "REFUSED"
		_:
			return "NONE"


# ── Admission (HOST) ──────────────────────────────────────────────────────────────────────────────


## NetTransport's admission gate: "" admits, anything else refuses with that reason. Called before the
## peer is announced, so a refused peer is invisible to the rest of the game — no spawn, no despawn,
## no interest-management churn for someone who was never in the session.
##
## The refusal itself is scheduled rather than done here, because we are inside NetTransport's signal
## handler: the reason has to be sent, and the socket closed, in that order, on a later frame.
func _gate_peer(peer_id: int) -> String:
	if not accepting_joins:
		var closed: String = "the host is not accepting new players right now"
		_refuse.call_deferred(peer_id, closed)
		return closed

	# peer_ids() does not yet include this peer — the gate runs before it is tracked — so this is the
	# count of everyone already in, host included.
	var occupied: int = NetTransport.peer_ids().size()
	if occupied >= capacity:
		var full: String = "session is full (%d/%d players)" % [occupied, capacity]
		_refuse.call_deferred(peer_id, full)
		return full

	MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: admitting peer %d (%d/%d)" % [
		peer_id, occupied + 1, capacity
	])
	return ""


func _refuse(peer_id: int, detail: String) -> void:
	peer_refused.emit(peer_id, detail)
	# rpc_id, not rpc: nobody else in the session needs to hear about someone who did not get in.
	net_refused.rpc_id(peer_id, detail)
	await get_tree().create_timer(REFUSAL_FLUSH_SEC).timeout
	NetTransport.kick_peer(peer_id)


# ── Host → client notices ─────────────────────────────────────────────────────────────────────────
#
# Both are @rpc("authority"), which in Godot means "only the node's multiplayer authority may call
# this". An autoload's authority is peer 1 on every peer, so a client that tries to tell everyone the
# session is closing is rejected by the engine before this code runs.


## The joiner's build, sent the moment it is connected. "any_peer" because a client is the only thing
## that ever calls it; the guard below is what makes that safe. A mismatch is refused exactly like a
## full session — same notice, same flush, same reason on the client's screen (task 1.11).
@rpc("any_peer", "call_remote", "reliable")
func net_client_hello(protocol_version: int) -> void:
	if not NetTransport.is_host():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var reason: String = NET_VERSION.mismatch_reason(NET_VERSION.PROTOCOL_VERSION, protocol_version)
	if reason.is_empty():
		return
	MireLog.warn(NetConfig.LOG_CHANNEL, "NetSession: peer %d speaks protocol v%d, we speak v%d" % [
		sender, protocol_version, NET_VERSION.PROTOCOL_VERSION
	])
	_refuse(sender, reason)


@rpc("authority", "call_remote", "reliable")
func net_refused(detail: String) -> void:
	# Arrives a fraction of a second before the host closes our connection. Recording it is what turns
	# the drop that follows from "connection lost" into "the host said no, and here is why".
	_refusal = detail
	_rejoining = false
	MireLog.error(NetConfig.LOG_CHANNEL, "NetSession: refused by host — %s" % detail)


@rpc("authority", "call_remote", "reliable")
func net_host_closing() -> void:
	_host_closing = true
	MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: host is closing the session")


# ── Session lifecycle ─────────────────────────────────────────────────────────────────────────────


func _on_session_opened() -> void:
	if _open:
		return
	_open = true
	_was_host = NetTransport.is_host()
	_host_closing = false
	_refusal = ""

	if _rejoining:
		_rejoining = false
		MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: rejoined as peer %d" % NetTransport.local_peer_id())
		rejoined.emit()

	MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: session open as %s (peer %d)" % [
		"host" if _was_host else "client", NetTransport.local_peer_id()
	])

	# Only the client hellos — the host never has to tell itself what it is running. The host is the
	# arbiter of the answer (task 1.11); we report our version and accept its verdict.
	if not _was_host:
		net_client_hello.rpc_id(NetConfig.HOST_PEER_ID, NET_VERSION.PROTOCOL_VERSION)

	session_opened.emit(_was_host)


func _on_disconnected() -> void:
	if not _open:
		return
	_open = false

	var reason: EndReason = _classify_end()
	var detail: String = _describe_end(reason)

	MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: session ended — %s (%s)" % [
		reason_name(reason), detail
	])

	if reason == EndReason.CONNECTION_LOST and _should_rejoin():
		connection_interrupted.emit(detail)
		_run_rejoin()
		return

	session_ended.emit(reason, detail)


## The transport knows WHAT happened to the socket; the notices above are what make it mean something.
## Order matters — a refusal is also a remote close, and it is the more specific answer.
func _classify_end() -> EndReason:
	if not _refusal.is_empty():
		return EndReason.REFUSED
	if NetTransport.last_end_kind() == NetTransport.EndKind.LOCAL_LEAVE:
		return EndReason.LOCAL_LEAVE
	if _host_closing:
		return EndReason.HOST_CLOSED
	# REMOTE_CLOSED with nothing said first: the host process died, or the link did. Same handling —
	# find out by trying to get back in.
	return EndReason.CONNECTION_LOST


func _describe_end(reason: EndReason) -> String:
	match reason:
		EndReason.REFUSED:
			return _refusal
		EndReason.LOCAL_LEAVE:
			return "you ended the session" if _was_host else "you left the session"
		EndReason.HOST_CLOSED:
			return "the host ended the session"
		_:
			return "lost contact with the host"


# ── Rejoining (CLIENT) ────────────────────────────────────────────────────────────────────────────


func _should_rejoin() -> bool:
	if not auto_rejoin or _was_host:
		return false
	if NetTransport.last_target_mode() == NetConfig.Mode.STEAM:
		# A Steam rejoin is not join(same address) — the peer has to be a lobby member again first,
		# which is SteamLobby's asynchronous flow, not this file's. Recorded as F-020 rather than
		# faked here, because a rejoin that silently does nothing is worse than one that says so.
		MireLog.warn(NetConfig.LOG_CHANNEL,
			"NetSession: STEAM sessions do not auto-rejoin yet (F-020) — rejoin via the lobby")
		return false
	return NetTransport.has_rejoin_target()


## Try to get back into the session we just lost. Each attempt is a real join(): NetTransport's own
## connect watchdog decides when one has failed, and we wait for its verdict rather than guessing.
func _run_rejoin() -> void:
	_rejoining = true
	var target: String = NetTransport.last_target_name()

	for index: int in range(REJOIN_BACKOFF_SEC.size()):
		await get_tree().create_timer(REJOIN_BACKOFF_SEC[index]).timeout
		# Cancelled while we waited — end_session(), or something else got us into a session.
		if not _rejoining:
			return
		if NetTransport.is_active() or NetTransport.is_connecting():
			_rejoining = false
			return

		var attempt: int = index + 1
		MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: rejoin attempt %d/%d to %s" % [
			attempt, REJOIN_BACKOFF_SEC.size(), target
		])
		rejoin_attempted.emit(attempt, REJOIN_BACKOFF_SEC.size())

		if NetTransport.rejoin_last_target() != OK:
			continue
		if await _await_connect_result():
			# _on_session_opened clears _rejoining and emits rejoined().
			return
		if not _rejoining:
			return

	_rejoining = false
	MireLog.error(NetConfig.LOG_CHANNEL, "NetSession: gave up rejoining after %d attempts" % REJOIN_BACKOFF_SEC.size())
	session_ended.emit(EndReason.CONNECTION_LOST,
		"lost contact with the host and could not reconnect after %d attempts" % REJOIN_BACKOFF_SEC.size())


## Wait out one join attempt. True if it became a session. The deadline is a backstop only — the
## transport's own watchdog resolves every attempt long before it — but without one, a transport bug
## would hang the rejoin loop forever instead of failing.
func _await_connect_result() -> bool:
	var deadline: int = Time.get_ticks_msec() + int((NetConfig.CONNECT_TIMEOUT_SEC + 2.0) * 1000.0)
	while NetTransport.is_connecting() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(REJOIN_POLL_SEC).timeout
	if NetTransport.is_active():
		return true
	# An attempt that is still "connecting" past the backstop is not a session; drop it so the next
	# attempt is not refused with ERR_ALREADY_IN_USE.
	if NetTransport.is_connecting():
		NetTransport.leave()
	return false
