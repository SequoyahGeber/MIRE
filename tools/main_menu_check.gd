extends SceneTree

## MainMenu / seed-entry proof (6.10's remaining slice, after the lobby-UI half shipped ahead of
## it). Covers: the legacy seed panel still builds and hands SETTINGS to the live MenuStack screen;
## MainMenu owns the cursor and blocking group while open and refuses to stack on LobbyMenu (D-032);
## entry stages a value into GameState (numeric text used as-is, other text hashed, empty clears)
## that only `GameState.host_generate_seed()`/`ensure_seed()` ever consume, never sent anywhere on
## its own; opening the lobby or settings panel from MainMenu hands off rather than stacking.
##
## Run with: .agent/bin/agent godot --script tools/main_menu_check.gd

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var menu: Node = root.get_node_or_null(^"MainMenu")
	var stack: Node = root.get_node_or_null(^"MenuStack")
	var lobby: Node = root.get_node_or_null(^"LobbyMenu")
	var game_state: Node = root.get_node_or_null(^"GameState")
	check(menu != null, "MainMenu autoload exists")
	check(stack != null, "MenuStack autoload exists")
	check(lobby != null, "LobbyMenu autoload exists")
	check(game_state != null, "GameState autoload exists")
	if menu == null or stack == null or lobby == null or game_state == null:
		finish()
		return

	check(not bool(menu.call("is_open")), "MainMenu starts closed")
	check(not menu.is_in_group(&"blocks_gameplay_input"), "closed MainMenu does not block gameplay input")

	# ── open / close, cursor and group ──────────────────────────────────────────────────────────
	menu.call("set_open", true)
	check(bool(menu.call("is_open")), "MainMenu opens")
	check(menu.is_in_group(&"blocks_gameplay_input"), "open MainMenu blocks gameplay input (D-032)")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "open MainMenu frees the cursor")

	# ── seed entry: numeric text used as-is ─────────────────────────────────────────────────────
	game_state.call("set_pending_seed", 0)
	menu.call("set_seed_field_text", "424242")
	menu.call("request_set_seed")
	check(bool(game_state.call("has_pending_seed")), "numeric seed text stages a pending seed")
	check(int(game_state.call("pending_seed")) == 424242, "numeric seed text is used verbatim")
	check(String(menu.call("status_text")).contains("424242"), "status line echoes the staged seed")

	# ── seed entry: non-numeric text is hashed, deterministically ──────────────────────────────
	menu.call("set_seed_field_text", "oakhollow")
	menu.call("request_set_seed")
	var staged_word_seed: int = int(game_state.call("pending_seed"))
	check(staged_word_seed != 0, "word seed hashes to a non-zero value")
	menu.call("set_seed_field_text", "oakhollow")
	menu.call("request_set_seed")
	check(int(game_state.call("pending_seed")) == staged_word_seed,
		"the same seed word always hashes to the same value")

	# ── seed entry: empty clears the override ───────────────────────────────────────────────────
	menu.call("set_seed_field_text", "")
	menu.call("request_set_seed")
	check(not bool(game_state.call("has_pending_seed")), "empty seed text clears the override")

	# ── staged seed actually wins the next draw, real entropy otherwise ────────────────────────
	game_state.call("set_pending_seed", 777)
	var drawn: int = int(game_state.call("host_generate_seed"))
	check(drawn == 777, "a staged seed wins host_generate_seed()'s next draw")
	check(not bool(game_state.call("has_pending_seed")), "the staged seed is consumed, not reused")
	game_state.call("reset")

	# ── RANDOM clears a staged seed ──────────────────────────────────────────────────────────────
	game_state.call("set_pending_seed", 999)
	menu.call("request_random_seed")
	check(not bool(game_state.call("has_pending_seed")), "RANDOM clears a staged seed")
	check(menu.call("seed_field_text") == "", "RANDOM clears the seed field text")

	# ── handing off to the lobby panel: MainMenu closes, LobbyMenu opens ────────────────────────
	menu.call("set_open", true)
	menu.call("request_open_multiplayer")
	check(not bool(menu.call("is_open")), "opening MULTIPLAYER closes MainMenu")
	check(bool(lobby.call("is_open")), "opening MULTIPLAYER opens LobbyMenu")
	lobby.call("set_open", false)

	# ── handing off to the live tabbed settings screen ──────────────────────────────────────────
	menu.call("set_open", true)
	menu.call("request_open_settings")
	check(not bool(menu.call("is_open")), "opening SETTINGS closes MainMenu")
	check(int(stack.call(&"depth")) == 1, "opening SETTINGS pushes one MenuStack screen")
	var settings_screen: Control = stack.call(&"top") as Control
	check(settings_screen != null and settings_screen.get_script().resource_path == "res://ui/frontend/settings_screen.gd",
		"MainMenu opens the same tabbed SettingsScreen used by title and pause")
	check(settings_screen != null and settings_screen.find_child("GodModeToggle", true, false) != null,
		"MainMenu's Settings destination contains God Mode")
	stack.call(&"pop_all")

	# ── D-032: none of the three panels will stack on another ──────────────────────────────────
	lobby.call("set_open", true)
	menu.call("set_open", true)
	check(not bool(menu.call("is_open")), "MainMenu refuses to open while LobbyMenu holds the group")
	lobby.call("set_open", false)

	print("MAIN_MENU_CHECK failures=%d" % failures)
	finish()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
