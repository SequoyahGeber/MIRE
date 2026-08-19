extends SceneTree

## End-to-end check of the Steam lobby path (task 1.4), against the REAL Steam client. Creates a
## friends-only lobby on App ID 480, hosts a STEAM session in it, reads the member list back, then
## leaves and confirms the lobby is gone.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/steam_lobby_check.gd
##
## Requires the Steam client running and signed in. Everything it touches is your own lobby, and it
## leaves it before exiting — but while it runs, friends can see you in a Spacewar lobby.
##
## WHAT THIS CANNOT COVER: the joining half. A second peer needs a second Steam account on another
## machine, so join_by_id() and the overlay invite are verified by two humans, not by this script.
## See the task write-up for the two-machine steps.

const TIMEOUT_MSEC: int = 20000

## Autoload identifiers (NetTransport, SteamLobby) are not resolvable at parse time in a --script
## main-loop script, though the autoloads themselves are very much running. Fetch them from the tree
## and call through these instead — the nodes are the same objects the game uses. Paths are relative
## to root: an absolute /root/... path is refused this early, before the tree is considered active.
@warning_ignore("unsafe_property_access")
var net: Node = null
var lobby: Node = null

var _failures: int = 0
var _phase: String = "init"
var _lobby_id: int = 0
var _deadline: int = 0
var _done: bool = false


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	net = root.get_node_or_null(^"NetTransport")
	lobby = root.get_node_or_null(^"SteamLobby")

	print("\n-- autoloads --")
	_check("NetTransport registered", net != null)
	_check("SteamLobby registered", lobby != null, "add it to [autoload] in project.godot")
	if net == null or lobby == null:
		_finish()
		return

	print("\n-- preconditions --")
	_check("GodotSteam present", net.steam_available(),
		"addon missing, or .godot/extension_list.cfg does not list it (F-009)")
	if not net.steam_available():
		_finish()
		return

	# Bit-level id classification, checked before anything touches the network: these two are the
	# reason join(Mode.STEAM, id) can accept a lobby id and a player id through one parameter.
	print("\n-- id classification --")
	_check("a player id is not a lobby id", not net.is_lobby_id(76561199137706116))
	_check("a lobby id is a lobby id", net.is_lobby_id(109775244893884567))

	print("\n-- steam init --")
	_check("lobby.initialise()", lobby.initialise(), "is the Steam client running?")
	if not lobby.is_ready():
		_finish()
		return
	_check("local Steam ID resolved", lobby.local_steam_id() != 0)

	lobby.lobby_created.connect(_on_lobby_created)
	lobby.lobby_failed.connect(_on_lobby_failed)
	# The session is deliberately a separate announcement from the lobby: lobby_created means the
	# lobby exists, server_started means we are hosting in it. Asserting session state on the former
	# is a race, and reading one signal as if it were the other is the mistake this ordering prevents.
	net.server_started.connect(_on_server_started)
	net.connection_failed.connect(_on_connection_failed)

	print("\n-- create lobby + host --")
	_phase = "creating"
	_deadline = Time.get_ticks_msec() + TIMEOUT_MSEC
	_check("host_session() accepted", lobby.host_session() == OK)


func _process(_delta: float) -> bool:
	if _done:
		return true
	if _deadline > 0 and Time.get_ticks_msec() > _deadline:
		_check("Steam answered the %s request" % _phase, false,
			"timed out after %.0fs" % (TIMEOUT_MSEC / 1000.0))
		_finish()
		return true
	return false


func _on_lobby_failed(reason: String) -> void:
	_check("lobby request succeeded", false, reason)
	_finish()


func _on_lobby_created(lobby_id: int) -> void:
	_lobby_id = lobby_id
	_deadline = 0
	_check("lobby id looks like a lobby", net.is_lobby_id(lobby_id), str(lobby_id))
	_check("lobby.in_lobby()", lobby.in_lobby())
	_check("current_lobby_id() matches", lobby.current_lobby_id() == lobby_id)
	_check("we own the lobby", lobby.lobby_owner_id() == lobby.local_steam_id(),
		"owner %d, us %d" % [lobby.lobby_owner_id(), lobby.local_steam_id()])

	print("\n-- member list --")
	var members: Array = lobby.members()
	_check("exactly one member (us)", members.size() == 1, "got %d" % members.size())
	if members.size() > 0:
		var me: Dictionary = members[0]
		_check("member is flagged owner", bool(me.get("is_owner", false)))
		_check("member is flagged local", bool(me.get("is_local", false)))
		_check("member has a persona name", str(me.get("name", "")).length() > 0)
		print("  members: %s" % str(members))

	# host_session() hands off to NetTransport next; _on_server_started picks it up from there.
	_phase = "hosting"
	_deadline = Time.get_ticks_msec() + TIMEOUT_MSEC


func _on_connection_failed(reason: String) -> void:
	_check("STEAM session started", false, reason)
	_finish()


func _on_server_started() -> void:
	print("\n-- session --")
	_check("NetTransport is hosting", net.is_host())
	_check("mode is STEAM", net.current_mode() == NetConfig.Mode.STEAM,
		net.mode_name(net.current_mode()))
	_check("host peer id is 1", net.local_peer_id() == NetConfig.HOST_PEER_ID,
		str(net.local_peer_id()))
	_check("peer list is just the host", net.peer_ids().size() == 1)

	print("\n-- leave --")
	# F-201: this synchronous leave(), called from inside a server_started handler, provokes one
	# engine ERROR every run — not a production bug. This script's own _on_server_started connects
	# to NetTransport.server_started in _initialize() (line 77), which under a --script main loop
	# runs BEFORE NetSession's autoload _ready() connects its own _on_session_opened to the same
	# signal (steam_lobby.gd's header documents that autoload _ready() lands late here). So this
	# handler's leave() runs and tears the peer down first, then NetSession._on_session_opened()
	# runs second against the same emission, reads NetTransport.is_host() as now false, and tries
	# net_client_hello.rpc_id() with no active peer. No real game code connects server_started and
	# calls leave() synchronously from inside the handler (confirmed by grepping every
	# server_started connection site) — this ordering only exists because of this check's own
	# --script harness registering its handler ahead of the autoloads. Declared by pattern per
	# SPECS.md standing rule 4 rather than restructured away, since restructuring this check's leave
	# to be deferred would stop testing the thing task 1.4 actually needs proven: that a real,
	# synchronous lobby.leave() call this soon after hosting starts leaves a clean lobby/session.
	lobby.leave()
	_check("out of the lobby", not lobby.in_lobby())
	_check("lobby id cleared", lobby.current_lobby_id() == 0)
	_check("session ended", not net.is_active())
	_check("mode back to OFFLINE", net.current_mode() == NetConfig.Mode.OFFLINE)

	# Leaving twice must not throw or re-emit — leave() is documented idempotent.
	lobby.leave()
	_check("leave() is idempotent", not lobby.in_lobby())
	_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	print("")
	if _failures == 0:
		print("all checks passed")
	else:
		print("%d check(s) failed" % _failures)
	# F-201: the SceneTree keeps draining deferred calls after this and prints one engine ERROR —
	# see the comment on the "-- leave --" section above for why it is this check's own harness
	# shape, not a production bug. Declared per SPECS.md standing rule 4.
	print("EXPECTED_ERROR_PATTERNS=\"Trying to call an RPC while no multiplayer peer is active\"")
	quit(1 if _failures > 0 else 0)
