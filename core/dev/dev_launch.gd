extends Node
## DevLaunch — autoload. Turns "two connected windows" into one keypress (task 1.3).
##
## Reads the launch arguments and, in a debug build only, either hosts or joins a
## LOCAL, LAN or STEAM session at startup. WITH NO ARGUMENTS IT DOES NOTHING AT ALL — this file
## ships in the retail build, and a stray auto-host would open a socket on every
## player's machine that they never asked for.
##
## Accepted arguments (either form works, see "How to launch" below):
##     -- host      or  --host      host a LOCAL session
##     -- client    or  --client    join a LOCAL session on loopback
##     --lan-host                   host a LAN session, bound to every interface
##     --lan-join=<address>         join a LAN session at that host's IP or hostname
##     --port=<n>                   override the port for LAN/LOCAL (default NetConfig.DEFAULT_PORT)
##     --steam-host                 create a friends-only Steam lobby and host in it
##     --steam-join=<lobby_id>      join a MIRE Steam lobby by its id
##
## LAN is the cheap cross-platform test (F-054): it exercises admission, the version handshake,
## spawning and replication over real sockets between real machines, with no Steam accounts and —
## unlike Steam, whose callback pump ticks once per rendered frame (F-025) — no dependence on the
## client's frame rate. That makes it the right instrument for a correctness run on a slow VM.
##
## AUTHORITY: none of its own. It only calls NetTransport, which is infrastructure.
## The session it opens is host-authoritative per docs/ARCHITECTURE.md §2.2.
##
## How to launch two connected windows (one-time editor setup, ~30 seconds).
## The config lives under .godot/, which is gitignored — so it is not committed and
## must be redone on a fresh clone. That is why the recipe lives here, in the file
## that consumes it:
##
##     Debug → Customize Run Instances...
##       ✔ Enable Multiple Instances
##       Instance count: 2
##       Instance 1 → Launch Arguments:  --host
##       Instance 2 → Launch Arguments:  --client
##     Then F5. Both windows launch, both report to the editor's Output panel, and
##     breakpoints hit in either one.
##
## Prefer `--host` over `-- host` in that field: a bare `--` would swallow any
## engine argument the editor appends after it (remote debug, scene path). Godot
## 4.7.1 ignores the unrecognised `--host` flag, which is why the plain form is safe.

const MAX_JOIN_ATTEMPTS: int = 6
const RETRY_DELAY_SECONDS: float = 0.4

enum Role { NONE, HOST, CLIENT }

enum LaunchMode { LOCAL, LAN, STEAM }

var _role: Role = Role.NONE
var _mode: LaunchMode = LaunchMode.LOCAL
var _steam_lobby_id: String = ""
## Where a LAN client dials. No default on purpose: LOCAL means loopback, LAN means "a machine you
## have to name", and silently falling back to 127.0.0.1 would turn a typo'd address into a
## confusing local session that looks like it worked.
var _lan_address: String = ""
## -1 means "whatever NetTransport resolves", i.e. NetConfig.DEFAULT_PORT.
var _port: int = -1
var _join_attempts: int = 0
var _connected: bool = false

## Latches on the first successful connection and never clears. Everything below it is about the
## cold-start race — two instances launched together, the client winning by a few milliseconds. Once
## a session has actually existed, reconnecting is NetSession's job (task 1.7), and two systems
## calling join() at once produce ERR_ALREADY_IN_USE and a leave() that kills the other's attempt.
var _ever_connected: bool = false


const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")

## Task 4.15 (D-143): `--procedural` swaps the main scene for a code-built ProceduralWorld before
## any session opens. Since 4.19's cutover the shipped main scene IS procedural
## (`levels/procedural_island.tscn`), so on a default boot this flag is a no-op; it still swaps
## when the main scene is an authored map (e.g. the Hollowmere fixture set as main scene for a
## comparison run). Debug-only like every other DevLaunch behaviour.
var _procedural: bool = false


func _swap_to_procedural() -> void:
	var tree: SceneTree = get_tree()
	var old_scene: Node = tree.current_scene
	# 4.19: the shipped scene root already runs procedural_world.gd — swapping would rebuild the
	# same island minus the scene's environment shell (sky, sun, atmosphere). Nothing to do.
	if old_scene != null and old_scene.get_script() == ProceduralWorldScript:
		MireLog.info(NetConfig.LOG_CHANNEL, "[DevLaunch] --procedural: main scene is already procedural — no swap")
		return
	var world: Node3D = ProceduralWorldScript.new()
	world.name = "ProceduralWorld"
	tree.root.add_child(world)
	tree.current_scene = world
	if old_scene != null:
		old_scene.queue_free()
	MireLog.info(NetConfig.LOG_CHANNEL, "[DevLaunch] --procedural: swapped to ProceduralWorld")


func _ready() -> void:
	if not OS.is_debug_build():
		return

	_parse_launch()
	if _procedural:
		# Deferred: the engine is still assigning the authored main scene during autoload _ready;
		# swapping now would race it. One frame later there is a current_scene to replace.
		_swap_to_procedural.call_deferred()
	if _role == Role.NONE:
		return

	NetTransport.server_started.connect(_on_server_started)
	NetTransport.connected_to_host.connect(_on_connected_to_host)
	NetTransport.connection_failed.connect(_on_connection_failed)
	NetTransport.disconnected.connect(_on_disconnected)
	NetTransport.peer_joined.connect(_on_peer_joined)
	NetTransport.peer_left.connect(_on_peer_left)

	if _role == Role.HOST:
		_start_host()
	else:
		_attempt_join()


## Reads the role and transport asked for on the command line. Steam arguments are deliberately
## debug-only: they are a physical cross-platform test driver, not a player-facing lobby UI.
## Checks the user args (after a bare `--`) first, then the engine's own arg list,
## so it works whichever way the editor's run-instance field passes them through.
func _parse_launch() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()

	for index: int in range(args.size()):
		var arg: String = args[index]
		if arg == "host" or arg == "--host":
			_role = Role.HOST
			_mode = LaunchMode.LOCAL
		elif arg == "client" or arg == "--client":
			_role = Role.CLIENT
			_mode = LaunchMode.LOCAL
		elif arg == "--steam-host":
			_role = Role.HOST
			_mode = LaunchMode.STEAM
		elif arg.begins_with("--steam-join="):
			_role = Role.CLIENT
			_mode = LaunchMode.STEAM
			_steam_lobby_id = arg.trim_prefix("--steam-join=")
		elif arg == "--steam-join" and index + 1 < args.size():
			_role = Role.CLIENT
			_mode = LaunchMode.STEAM
			_steam_lobby_id = args[index + 1]
		elif arg == "--lan-host":
			_role = Role.HOST
			_mode = LaunchMode.LAN
		elif arg.begins_with("--lan-join="):
			_role = Role.CLIENT
			_mode = LaunchMode.LAN
			_lan_address = arg.trim_prefix("--lan-join=").strip_edges()
		elif arg == "--lan-join" and index + 1 < args.size():
			_role = Role.CLIENT
			_mode = LaunchMode.LAN
			_lan_address = args[index + 1].strip_edges()
		elif arg.begins_with("--port="):
			_port = arg.trim_prefix("--port=").strip_edges().to_int()
		elif arg == "--procedural":
			_procedural = true

	if _mode == LaunchMode.STEAM and _role == Role.CLIENT and _steam_lobby_id.is_empty():
		MireLog.error(NetConfig.LOG_CHANNEL, "[DevLaunch] --steam-join needs a lobby id")
		_role = Role.NONE

	if _mode == LaunchMode.LAN and _role == Role.CLIENT and _lan_address.is_empty():
		MireLog.error(NetConfig.LOG_CHANNEL, "[DevLaunch] --lan-join needs the host's address")
		_role = Role.NONE


func _start_host() -> void:
	if _mode == LaunchMode.STEAM:
		MireLog.info(NetConfig.LOG_CHANNEL, "%s creating a Steam lobby" % _tag())
		var lobby: Node = _steam_lobby()
		if lobby == null:
			MireLog.error(NetConfig.LOG_CHANNEL, "%s SteamLobby autoload is unavailable" % _tag())
			return
		var steam_err: Error = lobby.host_session()
		if steam_err != OK:
			MireLog.error(NetConfig.LOG_CHANNEL, "%s SteamLobby.host_session() failed: %s" % [_tag(), error_string(steam_err)])
		return
	var mode: NetConfig.Mode = NetConfig.Mode.LAN if _mode == LaunchMode.LAN else NetConfig.Mode.LOCAL
	var port: int = _port if _port > 0 else NetConfig.DEFAULT_PORT
	MireLog.info(NetConfig.LOG_CHANNEL, "%s hosting %s session on port %d" % [
		_tag(), NetConfig.MODE_NAMES[mode], port
	])
	var err: Error = NetTransport.host(mode, _port)
	if err != OK:
		MireLog.error(NetConfig.LOG_CHANNEL, "%s host() failed: %s" % [_tag(), error_string(err)])


func _attempt_join() -> void:
	if _mode == LaunchMode.STEAM:
		MireLog.info(NetConfig.LOG_CHANNEL, "%s joining Steam lobby %s" % [_tag(), _steam_lobby_id])
		var lobby: Node = _steam_lobby()
		if lobby == null:
			MireLog.error(NetConfig.LOG_CHANNEL, "%s SteamLobby autoload is unavailable" % _tag())
			return
		var steam_err: Error = lobby.join_by_id(_steam_lobby_id)
		if steam_err != OK:
			MireLog.error(NetConfig.LOG_CHANNEL, "%s SteamLobby.join_by_id() failed: %s" % [_tag(), error_string(steam_err)])
		return
	var mode: NetConfig.Mode = NetConfig.Mode.LAN if _mode == LaunchMode.LAN else NetConfig.Mode.LOCAL
	_join_attempts += 1
	MireLog.info(NetConfig.LOG_CHANNEL, "%s joining %s session at %s (attempt %d/%d)" % [
		_tag(), NetConfig.MODE_NAMES[mode],
		_lan_address if mode == NetConfig.Mode.LAN else NetConfig.LOOPBACK_ADDRESS,
		_join_attempts, MAX_JOIN_ATTEMPTS
	])
	var err: Error = NetTransport.join(mode, _lan_address, _port)
	if err != OK:
		_retry_join("join() returned %s" % error_string(err))


## A client launched a moment before its host WILL fail to connect, which is the
## normal case for two instances started together. Retry a few times, then stop —
## never forever, or a genuinely absent host looks like a hang.
func _retry_join(reason: String) -> void:
	if _connected:
		return

	if _ever_connected:
		MireLog.info(NetConfig.LOG_CHANNEL, "%s not retrying (%s) — reconnection belongs to NetSession" % [_tag(), reason])
		return

	if _join_attempts >= MAX_JOIN_ATTEMPTS:
		MireLog.error(NetConfig.LOG_CHANNEL, "%s giving up after %d attempts — last failure: %s" % [_tag(), _join_attempts, reason])
		return

	MireLog.warn(NetConfig.LOG_CHANNEL, "%s connect failed (%s) — retrying in %.1fs" % [_tag(), reason, RETRY_DELAY_SECONDS])
	await get_tree().create_timer(RETRY_DELAY_SECONDS).timeout

	if _connected:
		return
	if NetTransport.is_active() or NetTransport.is_connecting():
		NetTransport.leave()
	_attempt_join()


func _on_server_started() -> void:
	_connected = true
	_ever_connected = true
	MireLog.info(NetConfig.LOG_CHANNEL, "%s server up, waiting for peers" % _tag())


func _on_connected_to_host() -> void:
	_connected = true
	_ever_connected = true
	MireLog.info(NetConfig.LOG_CHANNEL, "%s connected to host" % _tag())


func _on_connection_failed(reason: String) -> void:
	# A Steam client's retry belongs to NetSession (F-023), not here: it is the half that knows a
	# timed-out attempt left us still holding lobby membership, so it can simply join() again. A
	# second loop here would double every attempt — which is why STEAM is excluded from _retry_join.
	# It is reported as a warning rather than an error because it is not yet an ending, and the logs
	# this line lands in are the evidence a cross-platform run is judged on.
	if _role == Role.CLIENT and _mode == LaunchMode.STEAM \
			and NetTransport.last_end_kind() == NetTransport.EndKind.CONNECT_TIMEOUT:
		MireLog.warn(NetConfig.LOG_CHANNEL, "%s connect timed out (%s) — NetSession retries from here" % [
			_tag(), reason
		])
		return
	if _role != Role.CLIENT or _mode == LaunchMode.STEAM:
		MireLog.error(NetConfig.LOG_CHANNEL, "%s connection failed: %s" % [_tag(), reason])
		return
	_retry_join(reason)


func _on_disconnected() -> void:
	_connected = false
	MireLog.info(NetConfig.LOG_CHANNEL, "%s disconnected" % _tag())


func _on_peer_joined(peer_id: int) -> void:
	MireLog.info(NetConfig.LOG_CHANNEL, "%s peer %d joined — peers now %s" % [_tag(), peer_id, NetTransport.peer_ids()])


func _on_peer_left(peer_id: int) -> void:
	MireLog.info(NetConfig.LOG_CHANNEL, "%s peer %d left — peers now %s" % [_tag(), peer_id, NetTransport.peer_ids()])


## DevLaunch starts before SteamLobby in [autoload]. Resolve its node path at call time rather than
## naming the singleton, so the debug-only Steam driver does not depend on autoload parse order.
func _steam_lobby() -> Node:
	return get_node_or_null(^"/root/SteamLobby")


## Log prefix. Both windows write to the same editor Output panel, so every line
## has to say on sight which instance produced it.
func _tag() -> String:
	var role_name: String = "HOST" if _role == Role.HOST else "CLIENT"
	# All three modes, not just STEAM-or-LOCAL: a LAN run used to log itself as LOCAL, which is
	# exactly backwards in the one situation where the log is the only evidence you have — two
	# machines, one of them headless over SSH.
	var mode_name: String = ["LOCAL", "LAN", "STEAM"][_mode]
	var peer_id: int = NetTransport.local_peer_id()
	if peer_id == 0:
		return "[DevLaunch %s %s peer=?]" % [mode_name, role_name]
	return "[DevLaunch %s %s peer=%d]" % [mode_name, role_name, peer_id]
