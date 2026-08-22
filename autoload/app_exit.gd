extends Node

## AppExit — the one place the game is allowed to end. F-537.
## Register as autoload `AppExit` → res://autoload/app_exit.gd
##
## WHY THIS EXISTS. Closing the window used to be a bare `get_tree().quit()` in four unrelated
## files, and on macOS that is not a guarantee of anything. Two things happen after the last line of
## GDScript runs: the engine finalises its servers, and every native library the game pulled in gets
## to finalise too. The Steam API is the one that matters here — `steamInitEx` spawns its own
## threads and installs the overlay hook, and it had no shutdown counterpart anywhere in the repo,
## so those threads were still live when the SceneTree went away. A macOS app whose window vanishes
## while the process stays up, still holding the GPU and the audio device, is exactly what that
## looks like from the outside.
##
## So this node owns the close path end to end:
##
##   1. It takes the close request itself (`set_auto_accept_quit(false)`), rather than letting the
##      engine quit out from under the shutdown steps below.
##   2. It shuts down in dependency order — network first, then Steam — so nothing is mid-callback
##      when its library goes away.
##   3. It arms a watchdog BEFORE any of that, because steps 1 and 2 are the ones that can hang and
##      by the time they do there is no GDScript left running to notice.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none. Quitting is a local act — a peer leaving is
## already replicated by NetTransport's teardown, and nothing here decides any simulated state.

## Seconds between "the player asked to quit" and the watchdog killing the process outright. Long
## enough that a healthy exit (well under a second, measured) never races it, short enough that a
## wedged one does not sit in the background unnoticed.
const WATCHDOG_GRACE_SEC: float = 8.0

const LOG_CHANNEL: StringName = &"ui"

## Idempotent guard. Every entry point below funnels here, and a second request while the first is
## in flight must not re-run teardown on half-torn-down services.
var _quitting: bool = false

## PID of the detached watchdog, so a second quit request does not arm a second one. 0 = none armed.
var _watchdog_pid: int = 0


func _ready() -> void:
	# The tree is paused on the pause menu and during the defeat screen; quitting has to work there.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# From here on the engine hands us the close request instead of acting on it. Everything that
	# used to happen implicitly now happens in quit(), in an order we control.
	get_tree().set_auto_accept_quit(false)
	get_tree().set_quit_on_go_back(false)


func _notification(what: int) -> void:
	# WM_CLOSE_REQUEST is the red button, Cmd+Q, and the Dock's Quit. GO_BACK_REQUEST is the mobile
	# back gesture; harmless to route the same way. NOTIFICATION_CRASH is the engine's own last
	# gasp — Steam still wants shutting down, and there is no point arming a watchdog for a process
	# that is already on its way out.
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_WM_GO_BACK_REQUEST:
			quit()
		NOTIFICATION_CRASH:
			_shutdown_steam()


## The only supported way to end the game. Safe to call from anywhere, at any time, twice.
func quit(exit_code: int = 0) -> void:
	if _quitting:
		return
	_quitting = true

	# Armed FIRST, deliberately. Each step below is a step that could block, and the whole point of
	# the watchdog is to cover the window in which nothing else can react any more.
	_arm_watchdog()

	MireLog.info(LOG_CHANNEL, "quitting")
	_shutdown_net()
	_shutdown_steam()

	get_tree().quit(exit_code)


## Releases the UDP/Steam socket ahead of the tree teardown that would otherwise do it. Doing it
## here means the peer is gone before Steam's own shutdown pulls the transport out from under it —
## GodotSteam's multiplayer peer talks to the Steam API on close, and that call has to land while
## the API is still initialised.
func _shutdown_net() -> void:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport != null and transport.has_method("leave"):
		transport.call("leave")


func _shutdown_steam() -> void:
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby != null and lobby.has_method("shutdown"):
		lobby.call("shutdown")


## Spawns a detached `sh` that sleeps out the grace period and then kills us if we are somehow still
## here. Deliberately a separate PROCESS rather than a Thread, and deliberately never called off:
##
##   · A Thread lives inside the very process that is trying to die. It is subject to the same
##     engine finalisation that would be holding things up, and Godot's own thread bookkeeping runs
##     during that teardown. An outside process is not.
##   · Nothing disarms it, because the window it exists to cover opens AFTER the last GDScript runs.
##     `_exit_tree` fires while the SceneTree is being destroyed — the servers, the audio device and
##     Steam's threads all come down after that, and those are what can wedge. A watchdog cancelled
##     at `_exit_tree` would be cancelled a moment before it was needed.
##
## The cost of never disarming is one sleeping `sh` outliving a clean exit by the grace period, which
## is nothing. The risk is that macOS recycles our PID inside that window and the watchdog shoots an
## innocent process, so it re-checks the executable name and only fires if the PID is still us.
func _arm_watchdog() -> void:
	if _watchdog_pid != 0:
		return
	if not OS.has_feature("macos"):
		return
	# A headless tool run (`agent godot --script ...`) has no window to close and its own harness
	# already bounds it; spawning killers from checks would be a nasty surprise.
	if DisplayServer.get_name() == "headless":
		return

	var pid: int = OS.get_process_id()
	var name: String = OS.get_executable_path().get_file()
	var script: String = (
		'sleep %.1f; [ "$(ps -p %d -o comm= 2>/dev/null | sed \'s|.*/||\')" = "%s" ] && kill -9 %d 2>/dev/null'
		% [WATCHDOG_GRACE_SEC, pid, name, pid]
	)
	var spawned: int = OS.create_process("/bin/sh", ["-c", script], false)
	if spawned <= 0:
		MireLog.warn(LOG_CHANNEL, "exit watchdog could not be armed — quit is unguarded")
		return
	_watchdog_pid = spawned


func _exit_tree() -> void:
	# Reached on a clean exit, and also on a quit that never came through quit() at all (a tool
	# script, the editor's stop button). Steam still has to come down in that second case. The
	# watchdog is left armed on purpose — see above.
	_shutdown_steam()
