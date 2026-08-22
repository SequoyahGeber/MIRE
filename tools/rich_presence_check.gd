extends SceneTree

## Asserts the pieces F-123 depends on actually exist (task 1.12 groundwork).
##
##   .agent/bin/agent godot --headless --script tools/rich_presence_check.gd
##
## Steam decides whether a friend's entry in the friends list shows **Join Game** purely from the
## `connect` rich presence key. `SteamLobby` sets it on lobby create and join and clears it on leave,
## but every one of those calls happens inside a live Steam session — so a typo in the method name,
## or a GodotSteam rename, would surface only when a real lobby is created with a real friend
## watching. That is the most expensive place to find it and the hardest to reproduce. This check
## catches it headlessly instead, with no Steam client required.
##
## Assertions run against the live `SteamLobby` autoload, deliberately. Reflecting on the script
## object instead does not work here: `load("res://autoload/steam_lobby.gd").get_script_method_list()`
## reports only `_ready`, and `has_method()` on a bare `.new()` instance reports false even for
## long-standing methods like `_check_launch_invite`. Both would fail identically whether the code
## were present or missing, which is the one thing a check must never do.
##
## Exits non-zero on failure.

const STEAM_SINGLETON: String = "Steam"

var _failures: int = 0


func _init() -> void:
	root.ready.connect(_run, CONNECT_ONE_SHOT)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, "" if detail.is_empty() else " — " + detail])


func _run() -> void:
	print("-- rich presence (F-123) --")

	if Engine.has_singleton(STEAM_SINGLETON):
		# The whole point of the check: the exact method SteamLobby calls, by the exact name it uses.
		var steam: Object = Engine.get_singleton(STEAM_SINGLETON)
		_check("Steam exposes setRichPresence", steam.has_method("setRichPresence"),
			"GodotSteam renamed it — update SteamLobby._advertise_joinable/_clear_joinable together")
	else:
		# Not a failure: the extension is gitignored, so a fresh clone legitimately lacks it (F-009).
		print("  skip  Steam singleton absent — GodotSteam not installed")

	var lobby: Node = root.get_node_or_null("SteamLobby")
	_check("SteamLobby autoload is registered", lobby != null)
	if lobby != null:
		_check("SteamLobby advertises the lobby", lobby.has_method("_advertise_joinable"),
			"without this a friend shows In Game with no Join Game entry")
		_check("SteamLobby stops advertising on leave", lobby.has_method("_clear_joinable"),
			"a stale connect key offers friends a Join Game that drops them into nothing")
		_check("SteamLobby still parses the launch invite", lobby.has_method("_check_launch_invite"),
			"the advertised value is only useful if the receiving half still exists")

	# The advertised value has to be the same command line the launch path already parses, or an
	# accepted invite cold-starts the game with an argument it does not recognise.
	var arg: String = load("res://core/net/net_config.gd").STEAM_CONNECT_LOBBY_ARG
	_check("connect arg is '+connect_lobby'", arg == "+connect_lobby",
		"SteamLobby advertises this and _check_launch_invite() parses it — they must not drift")

	print("")
	print("-- overlay Join Game (F-127) --")

	if lobby != null:
		# Steam raises a *different* callback for the friends-list Join Game than for a lobby invite,
		# and connecting only the invite one made Join Game visible but inert (F-127).
		_check("SteamLobby handles the rich-presence join", lobby.has_method("_on_join_game_requested"),
			"overlay Join Game raises GameRichPresenceJoinRequested_t, not GameLobbyJoinRequested_t")
		_check("both join paths share one acceptance rule", lobby.has_method("_accept_invite"),
			"otherwise the 'never yank someone out of a running game' rule drifts between them")

		# The round trip, not the halves: feed the parser exactly what the advertiser publishes.
		# Asserting the two separately is what would let them drift apart unnoticed.
		if lobby.has_method("_lobby_id_from_connect"):
			var published: String = "%s %d" % [arg, 109775242382594016]
			var parsed: int = int(lobby.call("_lobby_id_from_connect", published))
			_check("published connect string parses back to its lobby id",
				parsed == 109775242382594016,
				"published '%s' but parsed %d" % [published, parsed])
			_check("an unusable connect string is refused, not guessed at",
				int(lobby.call("_lobby_id_from_connect", "garbage")) == 0,
				"a wrong lobby id fails far more confusingly than no join")
		else:
			_check("SteamLobby parses the connect string", false, "_lobby_id_from_connect missing")

	if Engine.has_singleton(STEAM_SINGLETON):
		# Guards the specific mix-up behind F-127: the two callbacks differ by one word.
		var steam2: Object = Engine.get_singleton(STEAM_SINGLETON)
		_check("Steam still exposes both join callbacks",
			steam2.has_signal("join_requested") and steam2.has_signal("join_game_requested"),
			"lobby invite and rich-presence join are separate signals — connect both")

	print("")
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("RICH_PRESENCE_CHECK failures=%d" % _failures)
	if _failures > 0:
		print("%d check(s) failed" % _failures)
		quit(1)
	else:
		print("all checks passed")
		quit(0)
