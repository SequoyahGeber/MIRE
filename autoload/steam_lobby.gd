extends Node

## SteamLobby — the Steam-facing half of a session: create, invite, join by id, leave, member list.
## Task 1.4. Register as autoload `SteamLobby` → res://autoload/steam_lobby.gd
##
## WHY THIS EXISTS SEPARATELY FROM NetTransport. NetTransport.host()/join() are synchronous: they
## return an Error and the peer is live when they return. Steam is not. createLobby and joinLobby
## answer by callback, and GodotSteam's peer refuses to help until that callback has landed —
## host_with_lobby() requires you to already own the lobby, connect_to_lobby() requires you to already
## be a member (both check GetLobbyOwner first and bail on 0, verified in the pinned build's source,
## D-022). So somebody has to wait. This file waits, and only then calls NetTransport, which is why
## NetTransport's contract survived task 1.4 without a single signature change.
##
## The division of labour, in one line each:
##   · SteamLobby  — who can see the session, who is in it, how they got invited
##   · NetTransport — the bytes, once they are in
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none. Lobby membership is Steam's state, not
## simulated state — it is never replicated, and nothing here decides anything about the game. The
## lobby answers "who may connect"; the host still decides everything that happens after they do.
## The one thing to hold onto: [b]lobby membership is not session membership[/b]. Someone in the lobby
## whose P2P connection has not completed is not yet a peer, and gameplay must read
## NetTransport.peer_ids() — never members() — for anything authoritative.
##
## Everything degrades to a clear no-op when GodotSteam is absent or Steam is not running, because
## that is the normal state during LOCAL development.

# ── Signals ───────────────────────────────────────────────────────────────────────────────────────

## A lobby now exists and we own it. The session itself follows via NetTransport.server_started.
signal lobby_created(lobby_id: int)

## We are a member of [param lobby_id]. For a joiner, connecting starts immediately after this.
signal lobby_joined(lobby_id: int)

## Neither of the above will arrive. [param reason] is human-readable and already logged.
signal lobby_failed(reason: String)

## We are out of the lobby — by leaving, or because it went away.
signal lobby_left(lobby_id: int)

## The member list changed. [param members] is the same array [method members] returns.
signal members_changed(members: Array[Dictionary])

## A friend's invite was accepted, from the overlay or from a cold start. Auto-joined only when we
## were idle; if a session is already running, this is a request for the UI to decide.
signal invite_accepted(lobby_id: int, auto_joining: bool)

enum _State { IDLE, CREATING, JOINING, IN_LOBBY }

var _state: _State = _State.IDLE
var _lobby_id: int = 0
var _steam: Object = null
var _initialised: bool = false
var _members: Array[Dictionary] = []
var _deadline_msec: int = 0
## Set while host_session() is in flight, so the lobby_created callback knows to start the session.
var _hosting: bool = false


func _ready() -> void:
	# Steam's callbacks must keep being pumped while the tree is paused — a paused lobby screen that
	# stops calling run_callbacks() silently stops receiving joins, which looks like a network bug.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Not a plain set_physics_process(false): initialise() can legitimately have run before _ready —
	# an autoload's _ready lands late under a --script main loop — and turning processing back off
	# here would silently stop pumping Steam's callbacks, so every request would hang until it timed
	# out.
	set_physics_process(_initialised)

	if not _bind_steam():
		MireLog.info(NetConfig.LOG_CHANNEL, "SteamLobby idle — GodotSteam not installed, STEAM mode unavailable")
		return

	# Steam is NOT initialised at boot. Launching the game must not announce you to Steam or open
	# anything; initialise() is called when the player actually asks for a Steam session (a menu, in
	# M6). The one exception is a launch that is itself an accepted invite — nothing else would ever
	# get around to reading it, and the player has already said yes by clicking Join.
	#
	# Task 8.3 considered — and reverted — having RichPresenceService/SteamStats call initialise()
	# eagerly from their own _ready() so a solo player would earn achievements without ever hosting a
	# lobby. On any machine with a real Steam client running, that turned EVERY headless
	# `agent godot` run project-wide into a real SteamAPI_Init() call, confirmed by diffing
	# `tools/salvage_check.gd`'s log before and after. Both of those files now only ever read Steam
	# state THIS method (or a launch invite) already brought up — see their own headers and
	# docs/DECISIONS.md.
	if _has_launch_invite():
		MireLog.info(NetConfig.LOG_CHANNEL, "launched from a Steam invite — bringing Steam up")
		initialise()
	_register_commands()



## Resolve the Steam singleton and hook the transport. Called from _ready, and again from
## initialise() so this node works whether or not _ready has already run — the tools/ checks drive it
## from a --script main loop, where autoload _ready lands after the script's first call.
func _bind_steam() -> bool:
	if _steam == null:
		if not NetTransport.steam_available():
			return false
		_steam = Engine.get_singleton(NetConfig.STEAM_SINGLETON)
	# Leaving the lobby is not optional on the way out: Steam keeps a lobby alive for a moment after
	# the process dies, so a fast relaunch can otherwise see its own stale lobby.
	if not NetTransport.disconnected.is_connected(_on_transport_disconnected):
		NetTransport.disconnected.connect(_on_transport_disconnected)
	return _steam != null


## Pumped on the PHYSICS tick, not the render frame (F-025). `run_callbacks()` is the call that makes
## every other Steam call arrive — lobby entry, the P2P rendezvous, connection state — so servicing it
## once per rendered frame tied the whole handshake to frame rate. Measured on a live session: a
## software-rendered Windows client at 2-3 FPS got ~20 pumps inside a 10 s connect window while the
## macOS host at 113 FPS got ~1,130, which is a far better explanation of that client's connect
## timeouts than a slow Steam network. The physics tick is fixed at
## `physics/common/physics_ticks_per_second` and the engine runs up to
## `max_physics_steps_per_frame` of them per rendered frame, so a frame-rate collapse no longer
## starves Steam by the same factor. At a healthy frame rate this is the same 60 Hz as before.
func _physics_process(_delta: float) -> void:
	_steam.run_callbacks()

	if _deadline_msec == 0 or Time.get_ticks_msec() < _deadline_msec:
		return
	var what: String = "create" if _state == _State.CREATING else "join"
	_abandon("Steam never answered the lobby %s request (%.0fs)" % [what, NetConfig.STEAM_LOBBY_TIMEOUT_SEC])


# ── Public API ────────────────────────────────────────────────────────────────────────────────────


## Bring Steam up. Safe to call repeatedly; the first call does the work. Returns false with a logged
## reason when GodotSteam is missing or the Steam client is not running — both normal, neither fatal.
func initialise() -> bool:
	if _initialised:
		return true
	if not _bind_steam():
		MireLog.warn(NetConfig.LOG_CHANNEL, "Steam unavailable: the GodotSteam addon is not installed")
		return false

	var result: Dictionary = _steam.steamInitEx(NetConfig.STEAM_APP_ID, false)
	var status: int = int(result.get("status", -1))
	if status != 0:
		MireLog.error(NetConfig.LOG_CHANNEL, "Steam init failed (status %d): %s — is the Steam client running?" % [
			status, str(result.get("verbal", "no detail"))
		])
		return false

	_initialised = true
	set_physics_process(true)
	_connect_steam_signals()
	MireLog.info(NetConfig.LOG_CHANNEL, "Steam ready — %s (%d), App ID %d" % [
		str(_steam.getPersonaName()), int(_steam.getSteamID()), NetConfig.STEAM_APP_ID
	])

	# A cold start from an accepted invite arrives as a launch argument rather than a callback.
	_check_launch_invite()
	return true


## Create a friends-only lobby and, once Steam confirms it, host a STEAM session in it.
## Returns OK when the request was *sent*; success arrives as lobby_created then
## NetTransport.server_started, failure as lobby_failed.
func host_session() -> Error:
	if not initialise():
		return ERR_UNAVAILABLE
	if _state != _State.IDLE:
		return _reject("already %s a lobby" % _state_verb())

	_hosting = true
	_state = _State.CREATING
	_arm_deadline()
	MireLog.info(NetConfig.LOG_CHANNEL, "creating a friends-only lobby for %d players" % NetConfig.MAX_PLAYERS)
	_steam.createLobby(NetConfig.STEAM_LOBBY_TYPE_FRIENDS_ONLY, NetConfig.MAX_PLAYERS)
	return OK


## Join a lobby by id and connect to whoever owns it — the "paste me the lobby id" path, and the one
## the overlay uses. Accepts the id as text because that is how it travels: overlay, chat, argument.
func join_by_id(lobby_id_text: String) -> Error:
	if not initialise():
		return ERR_UNAVAILABLE
	if _state != _State.IDLE:
		return _reject("already %s a lobby" % _state_verb())

	var trimmed: String = lobby_id_text.strip_edges()
	if not trimmed.is_valid_int():
		return _reject("'%s' is not a lobby id" % lobby_id_text)
	var lobby_id: int = trimmed.to_int()
	if not NetTransport.is_lobby_id(lobby_id):
		# Almost always someone pasting a friend's Steam profile id. Say which one they gave us.
		return _reject("%d is a player's Steam ID, not a lobby id — to connect directly to a player use NetTransport.join(Mode.STEAM, id)" % lobby_id)

	_hosting = false
	_state = _State.JOINING
	_lobby_id = lobby_id
	_arm_deadline()
	MireLog.info(NetConfig.LOG_CHANNEL, "joining lobby %d" % lobby_id)
	_steam.joinLobby(lobby_id)
	return OK


## Leave the lobby and end the session. Idempotent.
func leave() -> void:
	NetTransport.leave()
	_leave_lobby()


## Open Steam's own invite dialog for the current lobby — the overlay path, and the only invite UI we
## ever have to build. Needs the Steam overlay to be enabled and the game launched through Steam.
func open_invite_overlay() -> bool:
	if _lobby_id == 0:
		MireLog.warn(NetConfig.LOG_CHANNEL, "no lobby to invite anyone to — host_session() first")
		return false
	_steam.activateGameOverlayInviteDialog(_lobby_id)
	return true


## Invite one specific friend without the overlay, for a UI of our own.
func invite_user(steam_id: int) -> bool:
	if _lobby_id == 0:
		MireLog.warn(NetConfig.LOG_CHANNEL, "no lobby to invite %d to" % steam_id)
		return false
	var sent: bool = bool(_steam.inviteUserToLobby(_lobby_id, steam_id))
	if not sent:
		MireLog.warn(NetConfig.LOG_CHANNEL, "Steam refused the invite to %d" % steam_id)
	return sent


## The current lobby id, or 0. NetTransport reads this when it builds a STEAM host peer.
func current_lobby_id() -> int:
	return _lobby_id


## Who owns the current lobby — the host of the session — or 0.
func lobby_owner_id() -> int:
	if _lobby_id == 0:
		return 0
	return int(_steam.getLobbyOwner(_lobby_id))


## This machine's Steam ID, or 0 before initialise().
func local_steam_id() -> int:
	if not _initialised:
		return 0
	return int(_steam.getSteamID())


## This machine's own Steam persona name, or "" before initialise() — NetTransport threads this
## through as the STEAM-mode source for its own peer id -> display name registry (F-157). Distinct
## from _persona(steam_id), which resolves any lobby member's name and falls back to the id itself;
## this one has no id to fall back to, so "not ready yet" has to read as empty, not as a number.
func local_persona_name() -> String:
	if not _initialised:
		return ""
	return _persona(local_steam_id())


## Everyone in the lobby: [code]{steam_id: int, name: String, is_owner: bool, is_local: bool}[/code],
## owner first. This is lobby membership, NOT session membership — see the note at the top of the
## file before using it for anything that matters.
func members() -> Array[Dictionary]:
	return _members.duplicate()


## True once Steam is up and this process can host or join.
func is_ready() -> bool:
	return _initialised


## True while we hold a lobby.
func in_lobby() -> bool:
	return _lobby_id != 0


# ── Steam callbacks ───────────────────────────────────────────────────────────────────────────────


func _connect_steam_signals() -> void:
	_steam.lobby_created.connect(_on_lobby_created)
	_steam.lobby_joined.connect(_on_lobby_joined)
	_steam.lobby_chat_update.connect(_on_lobby_chat_update)
	# Two distinct Steam callbacks reach us here, and connecting only one is why the overlay's
	# "Join Game" silently did nothing (F-125). `join_requested` is GameLobbyJoinRequested_t — a
	# direct *lobby invite*. `join_game_requested` is GameRichPresenceJoinRequested_t, which is what
	# Steam fires when a friend is joinable through the `connect` rich presence key we now publish,
	# and it carries that key's raw string rather than a lobby id.
	_steam.join_requested.connect(_on_join_requested)
	_steam.join_game_requested.connect(_on_join_game_requested)


func _on_lobby_created(result: int, lobby_id: int) -> void:
	if _state != _State.CREATING:
		return
	_disarm_deadline()

	if result != NetConfig.STEAM_RESULT_OK:
		_hosting = false
		_abandon("Steam could not create the lobby (EResult %d)" % result)
		return

	_lobby_id = lobby_id
	_state = _State.IN_LOBBY
	# Metadata a joiner can read before committing to a connection. App ID 480 is shared with every
	# other developer testing worldwide, so "is this even our game" is a real question there.
	_steam.setLobbyData(lobby_id, NetConfig.STEAM_LOBBY_KEY_GAME, NetConfig.STEAM_LOBBY_GAME_VALUE)
	_steam.setLobbyData(lobby_id, NetConfig.STEAM_LOBBY_KEY_HOST, str(local_steam_id()))
	_refresh_members()

	_advertise_joinable(lobby_id)

	MireLog.info(NetConfig.LOG_CHANNEL, "lobby %d created — invite with SteamLobby.open_invite_overlay()" % lobby_id)
	lobby_created.emit(lobby_id)

	if _hosting:
		_hosting = false
		# The lobby exists and we own it, so host_with_lobby() inside NetTransport will now succeed.
		var err: Error = NetTransport.host(NetConfig.Mode.STEAM)
		if err != OK:
			# The session failed but the lobby is real; drop it rather than leave a ghost that
			# friends can still see and join into nothing.
			_leave_lobby()


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if _state != _State.JOINING:
		return
	_disarm_deadline()

	# EChatRoomEnterResponse, where 1 is success. Anything else and we were never in.
	if response != NetConfig.STEAM_RESULT_OK:
		_lobby_id = 0
		_abandon("could not enter lobby %d (response %d — full, private, or gone)" % [lobby_id, response])
		return

	_lobby_id = lobby_id
	_state = _State.IN_LOBBY
	_refresh_members()

	var game: String = str(_steam.getLobbyData(lobby_id, NetConfig.STEAM_LOBBY_KEY_GAME))
	if game != NetConfig.STEAM_LOBBY_GAME_VALUE:
		# Someone else's App ID 480 lobby. Connecting would hang instead of failing.
		_leave_lobby()
		_abandon("lobby %d is not a MIRE lobby (game='%s') — App ID 480 is shared with every developer testing on Steam" % [lobby_id, game])
		return

	_advertise_joinable(lobby_id)

	MireLog.info(NetConfig.LOG_CHANNEL, "in lobby %d with %d member(s), connecting to the host" % [
		lobby_id, _members.size()
	])
	lobby_joined.emit(lobby_id)

	# We are a member now, so connect_to_lobby() inside NetTransport will resolve the owner.
	var err: Error = NetTransport.join(NetConfig.Mode.STEAM, str(lobby_id))
	if err != OK:
		_leave_lobby()


func _on_lobby_chat_update(lobby_id: int, changed_id: int, _making_change_id: int, chat_state: int) -> void:
	if lobby_id != _lobby_id:
		return
	_refresh_members()
	var what: String = "entered" if chat_state == 1 else "left"
	MireLog.info(NetConfig.LOG_CHANNEL, "%s %s the lobby (%d/%d)" % [
		_persona(changed_id), what, _members.size(), NetConfig.MAX_PLAYERS
	])


func _on_join_requested(lobby_id: int, friend_id: int) -> void:
	_accept_invite(lobby_id, friend_id)


## Shared by both join paths — the lobby invite and the rich-presence "Join Game".
func _accept_invite(lobby_id: int, friend_id: int) -> void:
	var idle: bool = _state == _State.IDLE and not NetTransport.is_active()
	MireLog.info(NetConfig.LOG_CHANNEL, "%s invited us to lobby %d%s" % [
		_persona(friend_id), lobby_id, "" if idle else " (already in a session — ignoring)"
	])
	invite_accepted.emit(lobby_id, idle)
	# Never yank someone out of a running game because a friend clicked invite. If we are busy, the
	# signal is fired and the decision belongs to whatever UI is listening.
	if idle:
		join_by_id(str(lobby_id))


## The rich-presence half of accepting a join. Steam hands back exactly the `connect` string we
## published — `+connect_lobby <id>` — so this parses it and then behaves identically to a lobby
## invite. Reuses `_accept_invite()` so the "never yank someone out of a running game" rule cannot
## drift between the two entry points (F-125).
func _on_join_game_requested(user: int, connect_string: String) -> void:
	var lobby_id: int = _lobby_id_from_connect(connect_string)
	if lobby_id == 0:
		MireLog.warn(NetConfig.LOG_CHANNEL, "join request from %s carried an unusable connect string '%s'" % [
			_persona(user), connect_string
		])
		return
	_accept_invite(lobby_id, user)


## `+connect_lobby <id>`, the one format we publish and the one Steam echoes back. Returns 0 for
## anything else rather than guessing — a wrong lobby id fails far more confusingly than no join.
func _lobby_id_from_connect(connect_string: String) -> int:
	var parts: PackedStringArray = connect_string.strip_edges().split(" ", false)
	if parts.size() < 2 or parts[0] != NetConfig.STEAM_CONNECT_LOBBY_ARG:
		return 0
	return parts[1].to_int()


func _on_transport_disconnected() -> void:
	_leave_lobby()


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


func _has_launch_invite() -> bool:
	return OS.get_cmdline_args().has(NetConfig.STEAM_CONNECT_LOBBY_ARG)


## Steam hands invites to a cold-started game as `+connect_lobby <id>` on the command line.
func _check_launch_invite() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	for i: int in range(args.size()):
		if args[i] != NetConfig.STEAM_CONNECT_LOBBY_ARG:
			continue
		if i + 1 >= args.size():
			MireLog.warn(NetConfig.LOG_CHANNEL, "%s given with no lobby id" % NetConfig.STEAM_CONNECT_LOBBY_ARG)
			return
		var lobby_id: String = args[i + 1]
		MireLog.info(NetConfig.LOG_CHANNEL, "launched from an invite to lobby %s" % lobby_id)
		invite_accepted.emit(lobby_id.to_int(), true)
		join_by_id(lobby_id)
		return


func _refresh_members() -> void:
	_members.clear()
	if _lobby_id == 0:
		members_changed.emit(_members.duplicate())
		return

	var owner_id: int = int(_steam.getLobbyOwner(_lobby_id))
	var local_id: int = local_steam_id()
	var count: int = int(_steam.getNumLobbyMembers(_lobby_id))
	for i: int in range(count):
		var steam_id: int = int(_steam.getLobbyMemberByIndex(_lobby_id, i))
		_members.append({
			"steam_id": steam_id,
			"name": _persona(steam_id),
			"is_owner": steam_id == owner_id,
			"is_local": steam_id == local_id,
		})
	# Owner first; the rest in join order as Steam reports them.
	_members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["is_owner"] and not b["is_owner"])
	members_changed.emit(_members.duplicate())


func _leave_lobby() -> void:
	_disarm_deadline()
	_hosting = false
	_state = _State.IDLE
	if _lobby_id == 0:
		return

	var left: int = _lobby_id
	_lobby_id = 0
	_members.clear()
	if _initialised:
		_clear_joinable()
		_steam.leaveLobby(left)
	MireLog.info(NetConfig.LOG_CHANNEL, "left lobby %d" % left)
	members_changed.emit(_members.duplicate())
	lobby_left.emit(left)


## Give up on whatever was in flight, loudly. Never leaves _state stuck mid-request.
func _abandon(reason: String) -> void:
	_disarm_deadline()
	_hosting = false
	_state = _State.IN_LOBBY if _lobby_id != 0 else _State.IDLE
	MireLog.error(NetConfig.LOG_CHANNEL, reason)
	lobby_failed.emit(reason)


## Refused before anything was sent — log it, tell listeners, and hand the caller an Error.
func _reject(reason: String) -> Error:
	MireLog.warn(NetConfig.LOG_CHANNEL, reason)
	lobby_failed.emit(reason)
	return ERR_ALREADY_IN_USE


func _arm_deadline() -> void:
	_deadline_msec = Time.get_ticks_msec() + int(NetConfig.STEAM_LOBBY_TIMEOUT_SEC * 1000.0)


func _disarm_deadline() -> void:
	_deadline_msec = 0


func _persona(steam_id: int) -> String:
	if not _initialised or steam_id == 0:
		return str(steam_id)
	var name: String = str(_steam.getFriendPersonaName(steam_id))
	return name if not name.is_empty() else str(steam_id)


func _state_verb() -> String:
	match _state:
		_State.CREATING:
			return "creating"
		_State.JOINING:
			return "joining"
		_State.IN_LOBBY:
			return "in"
		_:
			return "idle in"


## Steam decides whether a friend shows a **Join Game** entry purely from the `connect` rich presence
## key: unset means "in game, unreachable", and the friends-list menu degrades to Invite to Watch
## (F-123). The value is the same `+connect_lobby <id>` command line that `_check_launch_invite()`
## already parses on a cold start, so this closes a round trip whose receiving half was always built.
## Set on both create and join, so a joiner is joinable too and a third player can arrive through
## either of the first two.
func _advertise_joinable(lobby_id: int) -> void:
	if not _initialised or lobby_id == 0:
		return
	_steam.setRichPresence("connect", "%s %d" % [NetConfig.STEAM_CONNECT_LOBBY_ARG, lobby_id])


## Clearing matters as much as setting: a stale `connect` key advertises a lobby we have already left,
## so friends get a Join Game button that drops them into nothing (F-123).
func _clear_joinable() -> void:
	if not _initialised:
		return
	_steam.setRichPresence("connect", "")


## Sets Steam's raw rich-presence "status" key — task 8.3's human-readable line, distinct from the
## `connect` key above (that one controls the Join Game button, not the text a friend actually
## reads). No-op when Steam is not initialised. `RichPresenceService` is the one caller today and is
## expected to remain the only one — route any other status text through it rather than calling
## setRichPresence a second place, the same "one place owns this API surface" reasoning
## `_advertise_joinable`/`_clear_joinable` already follow for the `connect` key.
func set_status(text: String) -> void:
	if not _initialised:
		return
	_steam.setRichPresence("status", text)


# ── Commands (docs/COMMANDS.md §7 — task 3.16, and D-030's cross-play test delivered) ────────────


## LOCAL scope, every one of them, and that is not an oversight. A lobby verb acts on THIS process's
## own Steam session — hosting, joining or inviting is something this machine does, not something the
## host does on its behalf. There is no host to route to before `lobby host` runs, which is rather
## the point: these are the commands D-030 needs to set a cross-play test up from a cold start on
## three machines, typed into each machine's own console.
func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"lobby", {
		"scope": &"local",
		"args": [
			{"name": "op", "type": &"enum", "values": ["host", "join", "invite", "leave", "status"]},
			{"name": "id", "type": &"string", "optional": true, "default": ""},
		],
		"handler": _cmd_lobby,
		"help": "lobby host | join <id> | invite | leave | status — Steam session control",
	})


func _cmd_lobby(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var operation: String = String(args.get("op", "status"))

	if operation == "status":
		if not in_lobby():
			return {"ok": true, "message": "not in a lobby (Steam %s)" % (
				"ready" if is_ready() else "unavailable"
			), "data": {"in_lobby": false, "ready": is_ready()}}
		var member_list: Array[Dictionary] = members()
		return {"ok": true, "message": "lobby %d — %d member(s), owner %d" % [
			current_lobby_id(), member_list.size(), lobby_owner_id()
		], "data": {"in_lobby": true, "lobby": current_lobby_id(), "members": member_list.size()}}

	if not is_ready():
		# The single most likely thing to go wrong on the day of the cross-play test, so it gets a
		# named answer rather than a generic failure — Steam not running is not a bug in the lobby.
		return {"ok": false,
			"message": "Steam is not available in this process — start the game through Steam",
			"data": {"ready": false}}

	match operation:
		"host":
			var error: Error = host_session()
			return {"ok": error == OK, "message": "hosting a lobby" if error == OK
				else "could not host: %s" % error_string(error), "data": {"error": error}}
		"join":
			var lobby_text: String = String(args.get("id", "")).strip_edges()
			if lobby_text.is_empty():
				return {"ok": false, "message": "usage: lobby join <lobby_id>", "data": {}}
			var error: Error = join_by_id(lobby_text)
			return {"ok": error == OK, "message": "joining lobby %s" % lobby_text if error == OK
				else "could not join: %s" % error_string(error), "data": {"error": error}}
		"invite":
			if not in_lobby():
				return {"ok": false, "message": "not in a lobby — `lobby host` first", "data": {}}
			var opened: bool = open_invite_overlay()
			return {"ok": opened, "message": "invite overlay opened" if opened
				else "the Steam overlay is not available", "data": {"opened": opened}}
		_:
			leave()
			return {"ok": true, "message": "left the lobby", "data": {}}
