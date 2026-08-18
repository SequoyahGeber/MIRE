extends SceneTree

## LobbyMenu proof (6.10's lobby-UI slice): the panel builds, opens and closes cleanly, owns the
## cursor and the blocking group while open, refuses to stack on another cursor UI (D-032), and
## every refusal path a Steam-less headless run can reach reports through the status line instead of
## crashing. The happy path (a real lobby) needs the Steam client and is covered by 1.12's live run.
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


func finish() -> void:
	quit(0 if failures == 0 else 1)
