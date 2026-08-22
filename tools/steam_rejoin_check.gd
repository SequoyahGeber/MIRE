extends SceneTree

## Steam rejoin-after-drop check (F-020). Headless, no Steam, no editor:
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/steam_rejoin_check.gd
##
## EXPECTED ENGINE ERRORS (F-052 triage): the autoloads tick without a multiplayer peer for the whole
## run, so `No multiplayer peer is assigned` repeats from SfxDirector. Declared by PATTERN:
##   grep 'ERROR:' | grep -vE 'No multiplayer peer is assigned' | wc -l   → must be 0
##
## Exits non-zero on failure. Takes about 15 seconds — most of it the one deliberate
## lobby-never-answers timeout, which is the branch worth paying for.
##
## WHAT THIS PROVES, AND WHAT IT CANNOT. F-020 is about a real lobby on a real Steam backend, and a
## headless probe has neither. So this replaces SteamLobby with a stub that speaks the three-method
## slice NetSession drives it through, and proves the ROUTING — that a dropped STEAM client now
## re-enters the lobby instead of declining to try, that it leaves first so join_by_id's IDLE
## precondition holds, that a lobby which never answers is a failed attempt rather than a hung loop,
## and that the membership is handed back on the way out.
##
##   proved here   the STEAM branch of _should_rejoin, in all four of its answers · that a STEAM
##                 attempt is leave() then join_by_id(the recorded lobby) and NOT a bare
##                 NetTransport.join() · that the recorded lobby survives the drop that clears
##                 SteamLobby's own copy · that the lobby timeout bounds one attempt and releases
##                 the membership · that a LOCAL session records no lobby
##
##   NOT proved    that a real Steam rendezvous recovers, or that 10 s is the right lobby budget.
##                 Both need task 1.12's two physical machines, same as F-023.
##
## Reaches into two private fields on purpose — NetTransport._target_mode and
## NetSession._steam_lobby_id — because the only supported way to set them is a live Steam join, and
## that is precisely what a headless box cannot do. Everything downstream of them is the real code.

## Any value that NetTransport.is_lobby_id() would accept; the stub never asks Steam about it.
const LOBBY_ID: int = 109775241234567890

## Nothing is ever bound here. A closed loopback port leaves ENet connecting for its full budget,
## which is how the stub makes `is_connecting()` true without a host child.
const DEAD_PORT: int = 47431

## Must outlast NetSession.STEAM_LOBBY_REJOIN_TIMEOUT_SEC so the timeout is the thing that resolves.
const TIMEOUT_WAIT_SEC: float = 14.0

var _failures: int = 0
var _transport: Node
var _session: Node
var _lobby: StubLobby

## Written from inside a lambda coroutine, so it cannot be a local (see the wait that reads it).
var _attempt_result: Variant = null


func _initialize() -> void:
	# Autoloads are children of root but have NOT entered the tree during _initialize (F-011).
	_start.call_deferred()


func _start() -> void:
	await process_frame
	_transport = root.get_node_or_null(^"NetTransport")
	_session = root.get_node_or_null(^"NetSession")
	if _transport == null or _session == null:
		print("autoloads missing — NetTransport / NetSession")
		quit(1)
		return

	_install_stub_lobby()
	await _run()

	print("\n%s — %d failure(s)\n" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)


## The real SteamLobby autoload is inert here (no GodotSteam), but it still owns the node name
## NetSession looks up, so it has to go before the stub can take the path.
func _install_stub_lobby() -> void:
	var real: Node = root.get_node_or_null(^"SteamLobby")
	if real != null:
		root.remove_child(real)
		real.queue_free()
	_lobby = StubLobby.new()
	_lobby.name = "SteamLobby"
	root.add_child(_lobby)


func _run() -> void:
	print("\n== Steam rejoin after a drop (F-020) ==")
	_check_a_local_session_records_no_lobby()
	_check_should_rejoin()
	await _check_an_attempt_goes_through_the_lobby()
	await _check_a_silent_lobby_is_a_failed_attempt()


## The record has to be STEAM-only. A LOCAL client that picked one up would take the lobby branch on
## its next drop and never call rejoin_last_target() at all.
func _check_a_local_session_records_no_lobby() -> void:
	print("\n-- a LOCAL session records no lobby --")
	_lobby.lobby_id = LOBBY_ID
	_transport.set("_target_mode", NetConfig.Mode.LOCAL)
	_session.set("_steam_lobby_id", 0)
	_session.call("_on_session_opened")
	_check("no lobby recorded", int(_session.get("_steam_lobby_id")) == 0,
		"a LOCAL drop must still use rejoin_last_target()")
	_session.set("_open", false)


func _check_should_rejoin() -> void:
	print("\n-- _should_rejoin, on a STEAM session --")
	_transport.set("_target_mode", NetConfig.Mode.STEAM)
	_session.auto_rejoin = true
	_session.set("_was_host", false)

	_session.set("_steam_lobby_id", LOBBY_ID)
	_check("a recorded lobby is now worth trying", bool(_session.call("_should_rejoin")),
		"this returned false before F-020 — the whole finding")

	_session.set("_steam_lobby_id", 0)
	_check("no recorded lobby declines", not bool(_session.call("_should_rejoin")),
		"nowhere to go back to")

	_session.set("_steam_lobby_id", LOBBY_ID)
	root.remove_child(_lobby)
	_check("SteamLobby absent declines", not bool(_session.call("_should_rejoin")),
		"nothing to drive the re-entry")
	root.add_child(_lobby)

	_session.auto_rejoin = false
	_check("auto_rejoin off still wins", not bool(_session.call("_should_rejoin")),
		"the probe off-switch must outrank the mode")
	_session.auto_rejoin = true


## The point of the finding: a STEAM attempt is not NetTransport.rejoin_last_target().
func _check_an_attempt_goes_through_the_lobby() -> void:
	print("\n-- one attempt re-enters the lobby --")
	_lobby.reset()
	_lobby.connect_on_join = true
	_transport.set("_target_mode", NetConfig.Mode.STEAM)
	_session.set("_steam_lobby_id", LOBBY_ID)
	_session.set("_rejoining", true)

	var started: bool = await _session.call("_start_rejoin_attempt")
	_check("the attempt is in flight", started)
	_check("it left the lobby first", _lobby.calls.size() >= 1 and _lobby.calls[0] == "leave",
		"join_by_id() refuses unless the state is IDLE")
	_check("then rejoined the recorded lobby", _lobby.joined_id == LOBBY_ID,
		str(_lobby.joined_id))
	_check("and did not bypass it with a bare rejoin", _lobby.calls.has("join_by_id"))

	_session.set("_rejoining", false)
	_transport.leave()
	await process_frame


## A lobby that never answers must fail its attempt and hand the membership back — the loop backs off
## and tries again, and the player's own manual retry is not blocked by "already in a lobby".
func _check_a_silent_lobby_is_a_failed_attempt() -> void:
	print("\n-- a lobby that never answers --")
	_lobby.reset()
	_lobby.connect_on_join = false
	_transport.set("_target_mode", NetConfig.Mode.STEAM)
	_session.set("_steam_lobby_id", LOBBY_ID)
	_session.set("_rejoining", true)

	# A member, not a local: GDScript lambdas capture locals BY VALUE, so a local written from inside
	# the coroutine would still read null out here and the wait would always time out.
	_attempt_result = null
	var resolve: Callable = func() -> void:
		_attempt_result = await _session.call("_start_rejoin_attempt")
	resolve.call()

	var resolved: bool = await _until(func() -> bool: return _attempt_result != null, TIMEOUT_WAIT_SEC)
	_check("the attempt resolved rather than hanging", resolved)
	_check("and resolved as a failure", _attempt_result == false, str(_attempt_result))
	_check("the membership was handed back", _lobby.calls.count("leave") >= 2,
		"a lobby held with no session makes the manual retry fail with 'already in a lobby'")

	_session.set("_rejoining", false)


# ── Plumbing ──────────────────────────────────────────────────────────────────────────────────────


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s%s" % [label, ("  — " + detail) if detail != "" else ""])
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _until(condition: Callable, timeout_sec: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await create_timer(0.1).timeout
	return bool(condition.call())


## The three methods NetSession._steam_lobby() requires, and nothing else — which is itself part of
## what this proves: the rejoin path must not depend on any more of SteamLobby than that.
class StubLobby extends Node:
	var lobby_id: int = 0
	var joined_id: int = 0
	var calls: PackedStringArray = PackedStringArray()

	## When true, join_by_id starts a real (doomed) ENet connect, so `is_connecting()` becomes true
	## the way a lobby_joined handler's NetTransport.join() would make it.
	var connect_on_join: bool = false

	func reset() -> void:
		calls = PackedStringArray()
		joined_id = 0

	func current_lobby_id() -> int:
		return lobby_id

	func leave() -> void:
		calls.append("leave")

	func join_by_id(lobby_id_text: String) -> Error:
		calls.append("join_by_id")
		joined_id = lobby_id_text.to_int()
		if connect_on_join:
			var transport: Node = get_node_or_null(^"/root/NetTransport")
			if transport != null:
				transport.call(&"join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, DEAD_PORT)
		return OK
