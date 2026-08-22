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
## Preloaded, not named bare: a new class_name is not resolvable in a --script run until an editor
## scan rebuilds the cache (F-016).
const RUN_IDENTITY: GDScript = preload("res://core/net/run_identity.gd")

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

## Client-side. A join that never connected is being tried again (F-023). Deliberately not the same
## signal as [signal rejoin_attempted]: that one means a session you were in is being recovered and
## the world has just vanished, this one means you are still on the join screen and nothing has been
## lost yet. A UI that conflated them would say "Reconnecting…" to someone who has never connected.
signal connect_retry_attempted(attempt: int, of: int)

## The first join has given up for good. [param detail] is a sentence for the player. [signal
## session_ended] does NOT fire for this — there was never a session to end.
signal connect_failed(detail: String)

## Host-side. A peer was turned away, with the reason it was given. Capacity/policy refusals happen
## before admission; a version refusal happens just after connection and is immediately despawned.
signal peer_refused(peer_id: int, detail: String)

## F-032. A reconnecting client arrives under a NEW peer id, and every host-owned system keys its
## state by peer id. These two signals are how that state follows the player instead of being
## orphaned. HOST-ONLY — a client never sees another player's identity.
##
## The same run-player is now [param new_peer_id] and was [param old_peer_id]. Move whatever you
## keyed under the old id; it is gone the moment this returns.
signal run_player_rebound(old_peer_id: int, new_peer_id: int)
## [param peer_id] is not coming back — its grace window expired. Release its state now. Consumers
## must NOT release on `peer_left`: between a drop and a rejoin, a player is still a player.
signal run_player_expired(peer_id: int)

## Task 4.6. Host-only. Fired once a peer's version handshake AND identity claim both succeed — the
## first moment it is safe to hand it session state that is not itself part of admission (the run
## seed, `WorldDeltaLog`'s accumulated deltas). Distinct from [signal run_player_rebound]: this fires
## for EVERY admitted peer, first-time joiners included, where that one fires only for a RETURNING
## one.
signal peer_admitted(peer_id: int)

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

## Extra attempts at a first join that timed out, and the wait before each (F-023). Short waits,
## because the manual retries that recovered F-023's failures were immediate: a rendezvous that is
## going to complete completes quickly on the second attempt, and one that is not going to complete
## is not helped by waiting longer to ask. Two extra attempts on Steam's 20 s budget is ~43 s worst
## case before we tell the player it did not work, which is long — but it is bounded, it is visible
## through connect_retry_attempted, and the alternative F-023 actually observed was a cross-platform
## session that simply failed.
const CONNECT_RETRY_BACKOFF_SEC: Array[float] = [0.5, 2.0]

## How long one STEAM rejoin attempt gets to become a lobby member again before we call it a failed
## attempt and back off (F-020). Generous next to a local join because it is two Steam round trips —
## joinLobby's callback, then the rendezvous — and short enough that four attempts still bound the
## whole loop under a minute.
const STEAM_LOBBY_REJOIN_TIMEOUT_SEC: float = 10.0

## How often the rejoin loop checks whether the attempt in flight has resolved.
const REJOIN_POLL_SEC: float = 0.1

## How often the host sweeps for identities whose grace has run out. Coarse on purpose: the grace
## window is 90 s, so a second of slack either side is irrelevant and a per-frame sweep is waste.
const IDENTITY_SWEEP_SEC: float = 5.0

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

## Client-side. Whether a first join that TIMED OUT is retried (F-023). Same reasoning as above, and
## same off switch for probes — tools/connect_retry_check.gd toggles this to prove both branches.
var auto_connect_retry: bool = true

# ── State ─────────────────────────────────────────────────────────────────────────────────────────

var _open: bool = false
var _was_host: bool = false

## Set by the host's notices. Cleared at the start of every session, because a stale one would
## mislabel the NEXT disconnect.
var _host_closing: bool = false
var _refusal: String = ""

var _rejoining: bool = false

## True while the first-join retry loop is running. Separate from _rejoining because they are
## mutually exclusive states with different exits, and because the loop's own failed attempts come
## back through _on_connection_failed — without this it would start a second loop inside itself.
var _connect_retrying: bool = false

## The lobby a STEAM session was entered through, remembered while the session is open (F-020).
## SteamLobby drops its own copy the moment the transport disconnects — it is a member of nothing at
## that point — so by the time we decide to rejoin, this is the only record of where to go back to.
var _steam_lobby_id: int = 0


## Host-only registry of who is who this run. A client's copy stays empty.
var _identity: RefCounted = RUN_IDENTITY.new()
## This peer's own token, issued by the host and presented again on every rejoin. In memory only —
## a run is one sitting (D-010), so there is nothing to persist and nothing to leak.
var _run_token: String = ""
var _identity_sweep_accumulator: float = 0.0


func _ready() -> void:
	# The rejoin loop and the closing notice both have to survive a paused tree — a pause menu is
	# exactly where "the host quit" tends to be noticed.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# The physics tick only runs the host's identity sweep; it stays off until a hosted session
	# opens (F-099). _sweep_identities keeps its own guard as belt and braces.
	set_physics_process(false)

	NetTransport.server_started.connect(_on_session_opened)
	NetTransport.connected_to_host.connect(_on_session_opened)
	NetTransport.disconnected.connect(_on_disconnected)
	# A join that never connected fails, it does not disconnect — so before F-023 this file heard
	# nothing at all about it and no first join was ever retried by anything that ships.
	NetTransport.connection_failed.connect(_on_connection_failed)

	# Ignored while not hosting, so it can be installed once and left alone.
	NetTransport.set_admission_gate(_gate_peer)

	# F-032: the host has to notice a departure to start that identity's grace clock. Consumers of
	# the two run_player_* signals deliberately do NOT watch peer_left themselves.
	NetTransport.peer_left.connect(_on_peer_left_identity)

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

	# Cancels any attempt in flight; see _run_rejoin and _run_connect_retry.
	_rejoining = false
	_connect_retrying = false

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


## True while a first join that timed out is still being retried (F-023). Distinct from
## [method is_rejoining]: nothing has been lost, we simply are not in yet.
func is_connect_retrying() -> bool:
	return _connect_retrying


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
func net_client_hello(protocol_version: int, run_token: String = "") -> void:
	if not NetTransport.is_host():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var reason: String = NET_VERSION.mismatch_reason(NET_VERSION.PROTOCOL_VERSION, protocol_version)
	if reason.is_empty():
		_admit_identity(sender, run_token)
		return
	MireLog.warn(NetConfig.LOG_CHANNEL, "NetSession: peer %d speaks protocol v%d, we speak v%d" % [
		sender, protocol_version, NET_VERSION.PROTOCOL_VERSION
	])
	_refuse(sender, reason)


# ── Run-player identity (F-032) ───────────────────────────────────────────────────────────────────


## The identity sweep is the only per-tick work this node does, and it is host-only. Physics tick
## rather than render frame for the same reason as F-025: a housekeeping deadline should not be
## measured by how fast the machine happens to be drawing.
func _physics_process(delta: float) -> void:
	_sweep_identities(delta)


## Host side of the hello. Decides whether this peer is somebody we have seen this run, tells it its
## token, and announces a rebind so peer-keyed state can follow.
func _admit_identity(peer_id: int, presented: String) -> void:
	var result: Dictionary = _identity.call("claim", peer_id, presented)
	var token: String = String(result.get("token", ""))
	if token.is_empty():
		return
	net_run_identity.rpc_id(peer_id, token)
	peer_admitted.emit(peer_id)

	var previous: int = int(result.get("rebound_from", 0))
	if previous <= 0 or previous == peer_id:
		return
	MireLog.info(NetConfig.LOG_CHANNEL,
		"NetSession: peer %d is peer %d returning — rebinding run state" % [peer_id, previous])
	run_player_rebound.emit(previous, peer_id)


## Host → one client, never broadcast: a token is that player's identity and nobody else's business.
@rpc("authority", "call_remote", "reliable")
func net_run_identity(token: String) -> void:
	_run_token = token


## Starts the grace clock. Deliberately does not release anything — that is what makes a rejoin able
## to reclaim state, and it is why consumers must not do their own cleanup on peer_left.
func _on_peer_left_identity(peer_id: int) -> void:
	if not NetTransport.is_host():
		return
	_identity.call("mark_left", peer_id, Time.get_ticks_msec())


func _sweep_identities(delta: float) -> void:
	if not NetTransport.is_host() or not _open:
		return
	_identity_sweep_accumulator += delta
	if _identity_sweep_accumulator < IDENTITY_SWEEP_SEC:
		return
	_identity_sweep_accumulator = 0.0
	for peer_id: int in (_identity.call("expire", Time.get_ticks_msec()) as Array[int]):
		if peer_id <= 0:
			continue
		MireLog.info(NetConfig.LOG_CHANNEL,
			"NetSession: peer %d did not return — releasing its run state" % peer_id)
		run_player_expired.emit(peer_id)


## Read-only, for checks and a future lobby UI: how many players are parked waiting to reconnect.
func orphaned_run_players() -> int:
	return int(_identity.call("orphan_count"))


## This peer's own run token. Empty until the host has issued one. Exposed for harnesses; gameplay
## code should use the two signals rather than reasoning about tokens.
func run_token() -> String:
	return _run_token


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
	set_physics_process(_was_host)

	# Whichever loop got us here has done its job and must not keep running.
	_connect_retrying = false

	if _rejoining:
		_rejoining = false
		MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: rejoined as peer %d" % NetTransport.local_peer_id())
		rejoined.emit()

	MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: session open as %s (peer %d)" % [
		"host" if _was_host else "client", NetTransport.local_peer_id()
	])

	if not _was_host and NetTransport.last_target_mode() == NetConfig.Mode.STEAM:
		_steam_lobby_id = _current_steam_lobby_id()

	# Only the client hellos — the host never has to tell itself what it is running. The host is the
	# arbiter of the answer (task 1.11); we report our version and accept its verdict.
	if not _was_host:
		net_client_hello.rpc_id(NetConfig.HOST_PEER_ID, NET_VERSION.PROTOCOL_VERSION, _run_token)

	session_opened.emit(_was_host)


func _on_disconnected() -> void:
	if not _open:
		return
	_open = false
	set_physics_process(false)

	# A run's identities do not outlive its session: the host forgets everyone, and a client forgets
	# the token it was issued so a later join to a DIFFERENT host starts clean. The rejoin path below
	# runs before this on a drop it intends to recover, so a genuine reconnect still presents it.
	if _was_host:
		_identity.call("clear")

	var reason: EndReason = _classify_end()
	var detail: String = _describe_end(reason)

	MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: session ended — %s (%s)" % [
		reason_name(reason), detail
	])

	if reason == EndReason.CONNECTION_LOST and _should_rejoin():
		connection_interrupted.emit(detail)
		_run_rejoin()
		return

	_steam_lobby_id = 0
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


# ── Retrying a first join (CLIENT) ────────────────────────────────────────────────────────────────
#
# F-023. Everything below is about a join that never became a session, which is a different animal
# from the rejoin loop underneath it: there is no world to lose, no host notice to interpret, and the
# transport is already back at OFFLINE by the time we hear about it.


func _on_connection_failed(_reason: String) -> void:
	# Our own retry attempts fail through here too. Without this guard the loop restarts inside itself.
	if _connect_retrying or _rejoining or _open:
		return
	if not _should_retry_connect():
		return
	_run_connect_retry()


func _should_retry_connect() -> bool:
	if not auto_connect_retry:
		return false

	# The whole point of splitting the enum. A refusal, a bad address or a missing GodotSteam is an
	# answer, and asking again just gets it again — only a deadline that expired mid-handshake is
	# worth another attempt.
	if NetTransport.last_end_kind() != NetTransport.EndKind.CONNECT_TIMEOUT:
		return false

	# STEAM and LAN, and LOCAL deliberately not (F-024).
	#
	# On STEAM the retry rests on a Steam-specific invariant: a timed-out attempt tears down WITHOUT
	# announcing, so SteamLobby never sees `disconnected`, never calls _leave_lobby(), and we are
	# still a member of the lobby — which is the one precondition connect_to_lobby() has. That is what
	# makes the retry a plain NetTransport.join() and NOT the rejoin-after-drop case, where the
	# session WAS announced, the lobby WAS left, and getting back in means re-entering the lobby
	# first — that is what _rejoin_steam_lobby() does (F-020).
	#
	# LAN needs no invariant at all: an address and a port do not expire, so asking again is simply
	# asking again. It is here because M6's join screen is a SHIPPED entry point, and without this a
	# player typing an address at a host that is still coming up gets one attempt and a dead end
	# while the same failure over Steam quietly recovers.
	#
	# LOCAL stays DevLaunch's. It has no shipped entry point — loopback is reachable only from the
	# two-window dev launcher — and that launcher's cold start is a client racing its own host, which
	# its six short attempts serve better than two long ones. DevLaunch defers to us on LAN and STEAM
	# instead, so no mode ever runs both loops.
	var mode: NetConfig.Mode = NetTransport.last_target_mode()
	if mode != NetConfig.Mode.STEAM and mode != NetConfig.Mode.LAN:
		return false
	return NetTransport.has_rejoin_target()


## Ask again, a bounded number of times. Each attempt is a real join() and the transport's own
## watchdog decides when it has failed, exactly as in _run_rejoin.
func _run_connect_retry() -> void:
	_connect_retrying = true
	var target: String = NetTransport.last_target_name()
	var total: int = CONNECT_RETRY_BACKOFF_SEC.size()

	for index: int in range(total):
		await get_tree().create_timer(CONNECT_RETRY_BACKOFF_SEC[index]).timeout
		if not _connect_retrying:
			return
		if NetTransport.is_active() or NetTransport.is_connecting():
			_connect_retrying = false
			return

		var attempt: int = index + 1
		MireLog.info(NetConfig.LOG_CHANNEL, "NetSession: connect retry %d/%d to %s" % [
			attempt, total, target
		])
		connect_retry_attempted.emit(attempt, total)

		if NetTransport.rejoin_last_target() != OK:
			continue
		if await _await_connect_result():
			# _on_session_opened clears the flag.
			return
		if not _connect_retrying:
			return

	_connect_retrying = false
	var detail: String = "could not reach %s — gave up after %d attempts" % [target, total + 1]
	MireLog.error(NetConfig.LOG_CHANNEL, "NetSession: %s" % detail)

	# Hand the lobby back before giving up. We stayed a member on purpose so the retries could use it,
	# but a member with no session is a trap: SteamLobby.join_by_id() refuses while _state is IN_LOBBY,
	# so leaving it held would make the player's own manual retry fail with "already in a lobby".
	#
	# STEAM only — there is no membership behind a LAN join, and SteamLobby.leave() also calls
	# NetTransport.leave(), which a LAN give-up has no business doing.
	if NetTransport.last_target_mode() == NetConfig.Mode.STEAM:
		_leave_steam_lobby()
	connect_failed.emit(detail)


## By node path, not by name: this file must keep parsing and running with the SteamLobby autoload
## absent, which is every LOCAL session and every headless probe (same reason, same shape, as
## NetTransport._current_steam_lobby). Returns null unless the node is there AND speaks the small
## slice of the lobby API the rejoin path needs, so a stub in a probe is enough to drive it.
func _steam_lobby() -> Node:
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby == null:
		return null
	if not lobby.has_method(&"leave") or not lobby.has_method(&"join_by_id"):
		return null
	return lobby


func _leave_steam_lobby() -> void:
	var lobby: Node = _steam_lobby()
	if lobby != null:
		lobby.call(&"leave")


func _current_steam_lobby_id() -> int:
	var lobby: Node = _steam_lobby()
	if lobby == null or not lobby.has_method(&"current_lobby_id"):
		return 0
	return int(lobby.call(&"current_lobby_id"))


# ── Rejoining (CLIENT) ────────────────────────────────────────────────────────────────────────────


func _should_rejoin() -> bool:
	if not auto_rejoin or _was_host:
		return false
	if NetTransport.last_target_mode() == NetConfig.Mode.STEAM:
		# A Steam rejoin is not join(same address): the peer has to be a lobby MEMBER again first,
		# and that is SteamLobby's asynchronous flow (F-020). We can still drive it — but only if we
		# know which lobby, and only if SteamLobby is actually present to drive.
		if _steam_lobby_id == 0:
			MireLog.warn(NetConfig.LOG_CHANNEL,
				"NetSession: no lobby recorded for this STEAM session — rejoin via the lobby")
			return false
		if _steam_lobby() == null:
			MireLog.warn(NetConfig.LOG_CHANNEL,
				"NetSession: SteamLobby is absent — a STEAM session cannot be rejoined without it")
			return false
		return true
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

		if not await _start_rejoin_attempt():
			continue
		if await _await_connect_result():
			# _on_session_opened clears _rejoining and emits rejoined().
			return
		if not _rejoining:
			return

	_rejoining = false
	MireLog.error(NetConfig.LOG_CHANNEL, "NetSession: gave up rejoining after %d attempts" % REJOIN_BACKOFF_SEC.size())

	# Same trap as the connect-retry give-up: a lobby membership held with no session left to reach
	# makes the player's own manual retry fail with "already in a lobby".
	if _steam_lobby_id != 0:
		_leave_steam_lobby()
		_steam_lobby_id = 0

	session_ended.emit(EndReason.CONNECTION_LOST,
		"lost contact with the host and could not reconnect after %d attempts" % REJOIN_BACKOFF_SEC.size())


## Kick off ONE rejoin attempt, whatever the mode needs. True if something is now in flight and
## _await_connect_result has a verdict coming; false if this attempt is already dead and the loop
## should back off and try the next one.
func _start_rejoin_attempt() -> bool:
	if NetTransport.last_target_mode() == NetConfig.Mode.STEAM:
		return await _rejoin_steam_lobby()
	return NetTransport.rejoin_last_target() == OK


## F-020. Re-enter the lobby, then let SteamLobby connect us the same way a fresh join does.
##
## The order is what matters. SteamLobby.join_by_id() refuses unless its state is IDLE, and after a
## drop it usually IS — _on_transport_disconnected leaves the lobby for us — but the two handlers
## hang off the same transport signal and nothing orders them, so a leave() first makes the
## precondition true either way and is a no-op when it already was. On success SteamLobby itself
## calls NetTransport.join() out of its lobby_joined handler, so there is deliberately no join here:
## a second one would race its own.
func _rejoin_steam_lobby() -> bool:
	var lobby: Node = _steam_lobby()
	if lobby == null or _steam_lobby_id == 0:
		return false

	lobby.call(&"leave")
	if lobby.call(&"join_by_id", str(_steam_lobby_id)) != OK:
		return false

	# The lobby answers asynchronously through Steam's callbacks; the transport join that follows is
	# what _await_connect_result then waits on. Poll rather than await the signal so that a lobby
	# that never answers at all cannot park the loop forever.
	var deadline: int = Time.get_ticks_msec() + int(STEAM_LOBBY_REJOIN_TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not _rejoining:
			return false
		if NetTransport.is_connecting() or NetTransport.is_active():
			return true
		await get_tree().create_timer(REJOIN_POLL_SEC).timeout

	MireLog.warn(NetConfig.LOG_CHANNEL,
		"NetSession: lobby %d did not let us back in within %.0fs" % [
			_steam_lobby_id, STEAM_LOBBY_REJOIN_TIMEOUT_SEC
		])
	lobby.call(&"leave")
	return false


## Wait out one join attempt. True if it became a session. The deadline is a backstop only — the
## transport's own watchdog resolves every attempt long before it — but without one, a transport bug
## would hang the rejoin loop forever instead of failing.
##
## It has to be derived from the mode rather than hard-coded, and F-023 is why: Steam's budget is now
## 20 s, so the old flat CONNECT_TIMEOUT_SEC + 2 would have expired at 12 s and cancelled attempts
## that were still perfectly alive — turning the fix into a slower version of the same bug.
func _await_connect_result() -> bool:
	var budget: float = NetTransport.connect_timeout_sec(NetTransport.last_target_mode())
	var deadline: int = Time.get_ticks_msec() + int((budget + 2.0) * 1000.0)
	while NetTransport.is_connecting() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(REJOIN_POLL_SEC).timeout
	if NetTransport.is_active():
		return true
	# An attempt that is still "connecting" past the backstop is not a session; drop it so the next
	# attempt is not refused with ERR_ALREADY_IN_USE.
	if NetTransport.is_connecting():
		NetTransport.leave()
	return false
