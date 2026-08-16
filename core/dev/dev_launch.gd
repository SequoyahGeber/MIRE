extends Node
## DevLaunch — autoload. Turns "two connected windows" into one keypress (task 1.3).
##
## Reads the launch arguments and, in a debug build only, either hosts or joins a
## LOCAL session at startup. WITH NO ARGUMENTS IT DOES NOTHING AT ALL — this file
## ships in the retail build, and a stray auto-host would open a socket on every
## player's machine that they never asked for.
##
## Accepted arguments (either form works, see "How to launch" below):
##     -- host      or  --host      host a LOCAL session
##     -- client    or  --client    join a LOCAL session on loopback
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

var _role: Role = Role.NONE
var _join_attempts: int = 0
var _connected: bool = false


func _ready() -> void:
	if not OS.is_debug_build():
		return

	_role = _parse_role()
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


## Returns the role asked for on the command line, or Role.NONE if none was.
## Checks the user args (after a bare `--`) first, then the engine's own arg list,
## so it works whichever way the editor's run-instance field passes them through.
func _parse_role() -> Role:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "host" or arg == "--host":
			return Role.HOST
		if arg == "client" or arg == "--client":
			return Role.CLIENT

	# Dashes are required here: an undashed token in the full argument list could
	# just as easily be a path fragment as an instruction.
	for arg: String in OS.get_cmdline_args():
		if arg == "--host":
			return Role.HOST
		if arg == "--client":
			return Role.CLIENT

	return Role.NONE


func _start_host() -> void:
	MireLog.info(NetConfig.LOG_CHANNEL, "%s hosting LOCAL session on port %d" % [_tag(), NetConfig.DEFAULT_PORT])
	var err: Error = NetTransport.host(NetConfig.Mode.LOCAL)
	if err != OK:
		MireLog.error(NetConfig.LOG_CHANNEL, "%s host() failed: %s" % [_tag(), error_string(err)])


func _attempt_join() -> void:
	_join_attempts += 1
	MireLog.info(NetConfig.LOG_CHANNEL, "%s joining LOCAL session (attempt %d/%d)" % [_tag(), _join_attempts, MAX_JOIN_ATTEMPTS])
	var err: Error = NetTransport.join(NetConfig.Mode.LOCAL, "")
	if err != OK:
		_retry_join("join() returned %s" % error_string(err))


## A client launched a moment before its host WILL fail to connect, which is the
## normal case for two instances started together. Retry a few times, then stop —
## never forever, or a genuinely absent host looks like a hang.
func _retry_join(reason: String) -> void:
	if _connected:
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
	MireLog.info(NetConfig.LOG_CHANNEL, "%s server up, waiting for peers" % _tag())


func _on_connected_to_host() -> void:
	_connected = true
	MireLog.info(NetConfig.LOG_CHANNEL, "%s connected to host" % _tag())


func _on_connection_failed(reason: String) -> void:
	if _role != Role.CLIENT:
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


## Log prefix. Both windows write to the same editor Output panel, so every line
## has to say on sight which instance produced it.
func _tag() -> String:
	var role_name: String = "HOST" if _role == Role.HOST else "CLIENT"
	var peer_id: int = NetTransport.local_peer_id()
	if peer_id == 0:
		return "[DevLaunch %s peer=?]" % role_name
	return "[DevLaunch %s peer=%d]" % [role_name, peer_id]
