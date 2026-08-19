extends SceneTree

## LobbyMenu proof (6.10's lobby-UI slice): the panel builds, opens and closes cleanly, owns the
## cursor and the blocking group while open, refuses to stack on another cursor UI (D-032), and
## every refusal path a Steam-less headless run can reach reports through the status line instead of
## crashing. The happy path (a real lobby) needs the Steam client and is covered by 1.12's live run.
##
## F-170: the Steam-unavailable assertions only mean anything on a machine whose own Steam client
## really is unreachable. Firing them with a fake lobby ID against a machine where Steam IS running
## and logged in does not test a refusal — it starts a REAL async join, which leaves SteamLobby
## stuck mid-request (its `_lobby_id` is set the instant `join_by_id()` runs, before Steam answers)
## and cascades into every assertion after it. So this probes `SteamLobby.is_ready()` (via the same
## `initialise()` request_join()/request_host() would call anyway — idempotent, safe to call early)
## before committing to those fake IDs, and skips them with a named reason when Steam is actually
## reachable, instead of firing a request that can't fail the way the assertion expects.
##
## Run with: .agent/bin/agent godot --script tools/lobby_menu_check.gd

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var menu: Node = root.get_node_or_null(^"LobbyMenu")
	var lobby: Node = root.get_node_or_null(^"SteamLobby")
	check(menu != null, "LobbyMenu autoload exists")
	check(lobby != null, "SteamLobby autoload exists")
	if menu == null or lobby == null:
		finish()
		return

	check(not bool(menu.call("is_open")), "menu starts closed")
	check(not menu.is_in_group(&"blocks_gameplay_input"), "closed menu does not block gameplay input")

	menu.call("set_open", true)
	check(bool(menu.call("is_open")), "menu opens")
	check(menu.is_in_group(&"blocks_gameplay_input"), "open menu blocks gameplay input (D-032)")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "open menu frees the cursor")
	check(int(menu.call("member_row_count")) == 0, "no member rows render outside a lobby")

	# Join with nothing pasted: refused by the UI itself, before SteamLobby is ever asked.
	menu.call("set_join_field_text", "")
	menu.call("request_join")
	check(String(menu.call("status_text")).to_lower().contains("lobby id"),
		"empty join asks for a lobby ID")
	check(not bool(lobby.call("in_lobby")), "empty join created no lobby state")

	# F-170: which branch this machine is actually on, decided before any fake ID is used.
	lobby.call("initialise")
	var steam_available: bool = bool(lobby.call("is_ready"))

	if steam_available:
		print("STEAM AVAILABLE on this machine — skipping the Steam-unavailable join/host assertions (F-170); their happy-path coverage is 1.12's live run.")
		skip("joining without Steam names Steam as the reason")
		skip("refused join left no lobby state")
		skip("hosting without Steam names Steam as the reason")
		skip("refused host left no lobby state")
	else:
		print("STEAM UNAVAILABLE on this machine — running the Steam-unavailable join/host assertions.")
		# Join with text on a Steam-less machine: SteamLobby refuses, the menu says why, nothing crashes.
		menu.call("set_join_field_text", "109775242382594016")
		menu.call("request_join")
		check(String(menu.call("status_text")).to_lower().contains("steam"),
			"joining without Steam names Steam as the reason")
		check(not bool(lobby.call("in_lobby")), "refused join left no lobby state")

		menu.call("request_host")
		check(String(menu.call("status_text")).to_lower().contains("steam"),
			"hosting without Steam names Steam as the reason")
		check(not bool(lobby.call("in_lobby")), "refused host left no lobby state")

	menu.call("request_copy_lobby_id")
	check(String(menu.call("status_text")).to_lower().contains("host"),
		"copy with no lobby points at hosting first")

	menu.call("set_open", false)
	check(not bool(menu.call("is_open")), "menu closes")
	check(not menu.is_in_group(&"blocks_gameplay_input"), "closing releases the blocking group")

	# D-032: while another cursor UI holds the group, the menu must refuse to open.
	var other := Node.new()
	other.name = "LobbyMenuCheckOtherUI"
	other.add_to_group(&"blocks_gameplay_input")
	root.add_child(other)
	menu.call("set_open", true)
	check(not bool(menu.call("is_open")), "menu refuses to stack on another cursor UI (D-032)")
	root.remove_child(other)
	other.free()

	menu.call("set_open", true)
	check(bool(menu.call("is_open")), "menu opens again once the other UI is gone")
	menu.call("set_open", false)

	print("LOBBY_MENU_CHECK failures=%d" % failures)
	finish()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


## F-170: an assertion this machine's Steam state makes untestable, not a failure to report.
func skip(description: String) -> void:
	print("SKIP: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
