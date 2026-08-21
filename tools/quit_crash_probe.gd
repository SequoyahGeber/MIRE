extends SceneTree

## F-421 — does quitting from the in-game menu crash the process on the way out?
##
## macOS raises "Godot quit unexpectedly" every time Sequoyah closes the game from the F1 menu's
## QUIT button. Four crash reports in one evening share one stack: EXC_BAD_ACCESS at 0x0 on the main
## thread, inside SceneTree processing under `Main::iteration`, with the whole engine still up. It is
## a shutdown crash, not a gameplay one, and the exit code is 0 either way — so nothing in CI or in
## `agent godot` has ever noticed it.
##
## This drives the SHIPPED path rather than a simplification of it: boot the real main scene, let the
## world stream until the streamer is quiet, open `MainMenu` exactly as F1 does, then call
## `request_quit()` — the same call the QUIT button is wired to. `--quit-after` does NOT exercise
## this: it calls `SceneTree::quit()` from the engine side with no menu open, no mouse capture to
## restore and no settings screen ever having existed, which is why six runs of it shut down cleanly
## while the real button crashes.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Diagnostic only.
##
##   .agent/bin/agent godot --windowed --script tools/quit_crash_probe.gd
##
## Optional `-- --settings` also pushes the settings screen and pops it before quitting, because
## "the in-game settings menu" is how the crash was reported and the settings screen holds a
## persistence lease (`settings_screen.gd::_cancel_preview`) that a quit could race.

const ProbeScene := preload("res://tools/probe_scene.gd")

## Frames to keep iterating after `request_quit()` before declaring the shutdown clean. The crash
## happens INSIDE the frame that follows the quit, so the probe has to survive that frame to prove
## anything; the engine tears itself down of its own accord well inside this.
const GRACE_FRAMES: int = 20


func _initialize() -> void:
	print("F-421 quit-crash probe — %s" % ProbeScene.describe(ProbeScene.resolve()))
	_run()


func _run() -> void:
	var scene_path: String = ProbeScene.resolve()
	var packed: PackedScene = load(scene_path)
	if packed == null:
		print("FAIL: could not load %s" % scene_path)
		quit(1)
		return
	# `agent godot --windowed` parks a 64x64 window offscreen (F-077). At that size MainMenu's
	# layout collapses and a click lands on a MarginContainer instead of the QUIT button, so the
	# probe silently proves nothing. Give it a real window before the UI is ever built.
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(Vector2i(1280, 720))
		# The crashing reports all say `Role: Foreground` — an activated, focused app. `agent godot
		# --windowed` parks the window offscreen and never activates it (`Role: Unspecified`), and
		# the crash happens inside the macOS CFRunLoop observer, which is exactly the code path that
		# cares. Bring it on screen and to the front unless asked not to.
		if not OS.get_cmdline_user_args().has("--background"):
			DisplayServer.window_set_position(Vector2i(80, 80))
			DisplayServer.window_move_to_foreground()
		print("window %s at %s" % [DisplayServer.window_get_size(), DisplayServer.window_get_position()])
	var world: Node = packed.instantiate()
	root.add_child(world)
	await process_frame

	var settled: Dictionary = await ProbeScene.settle(world)
	print("world settled: %s" % settled)

	var menu: Node = root.get_node_or_null(^"MainMenu")
	if menu == null:
		print("FAIL: no /root/MainMenu — autoloads are not up under --script")
		quit(1)
		return

	if OS.get_cmdline_user_args().has("--settings"):
		print("opening the settings screen first")
		menu.call("set_open", true)
		await process_frame
		menu.call("request_open_settings")
		for _i: int in 30:
			await process_frame
		var stack: Node = root.get_node_or_null(^"MenuStack")
		if stack != null:
			stack.call("pop_all")
		for _i: int in 10:
			await process_frame

	# The attunement picker auto-opens at run start and holds `blocks_gameplay_input` until the
	# player picks (`ui/attunement/attunement_ui.gd::_open_picker`). A real session answers it within
	# seconds; a probe that does not is refused by MainMenu.set_open() and proves nothing. Answer it
	# the way a player does, through the service.
	var attunement: Node = root.get_node_or_null(^"AttunementService")
	if attunement != null and String(attunement.call("local_selection")).is_empty():
		print("answering the attunement picker (forager)")
		attunement.call("request_select", &"forager")
		for _i: int in 30:
			await process_frame

	# `-- --soak N` plays on for N frames before quitting. The crash reports span sessions of one
	# to twenty-seven minutes, so whatever is wrong is not "long session" specific — but a settled
	# world that has never run a wave, spawned an enemy or captured the mouse is still a thinner
	# shutdown than a real one, and this is the cheapest way to thicken it.
	var soak: int = _int_arg("--soak", 0)
	if soak > 0:
		print("soaking %d frames of live gameplay before quitting" % soak)
		for _i: int in soak:
			await process_frame
		print("soak done: %d enemies, mouse_mode=%d"
			% [get_nodes_in_group(&"enemies").size(), Input.mouse_mode])

	# A soak long enough to matter can leave a MenuStack screen up (the defeat summary, most often),
	# which blocks MainMenu the same way the attunement picker does. Clear it: the point of the probe
	# is the QUIT click, and a run that never reaches the click is a run that proves nothing.
	var stack_now: Node = root.get_node_or_null(^"MenuStack")
	if stack_now != null and stack_now.is_in_group(&"blocks_gameplay_input"):
		print("popping the MenuStack screen that is holding the input gate")
		stack_now.call("pop_all")
		for _i: int in 20:
			await process_frame

	# A real session has the mouse CAPTURED when the player presses F1: `set_open` then flips it to
	# VISIBLE and latches `_restore_mouse_captured`, and the quit happens with that history behind
	# it. A probe window parked offscreen never gets capture on its own, so ask for it explicitly —
	# it is the last piece of shutdown state that differs from the crashing runs.
	if not OS.get_cmdline_user_args().has("--no-capture"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		await process_frame
		print("mouse_mode before opening the menu: %d" % Input.mouse_mode)

	print("opening MainMenu (what F1 does)")
	menu.call("set_open", true)
	for _i: int in 10:
		await process_frame
	# `set_open` refuses silently whenever anything else is already in `blocks_gameplay_input`
	# (D-032's "hand off, don't stack"). A probe that does not check this clicks at whatever happens
	# to be under a stale rect and reports "no crash" without ever having opened the menu.
	var blockers: Array = get_nodes_in_group(&"blocks_gameplay_input")
	print("MainMenu.is_open()=%s  blockers=%s"
		% [str(menu.call("is_open")), str(blockers.map(func(n: Node) -> String: return n.name))])
	if not bool(menu.call("is_open")):
		print("FAIL: MainMenu refused to open — nothing below this proves anything")
		quit(1)
		return

	# The QUIT button is pressed with a real mouse, and that is not a detail: clicking leaves the
	# viewport's GUI state (`gui.mouse_focus`, `mouse_over`, the focus owner) pointing at a Control
	# that the quit is about to tear down. Calling `request_quit()` straight from code leaves all of
	# that null, which is a different shutdown from the one the player performs. `-- --no-click`
	# runs the code-only form for the comparison.
	if OS.get_cmdline_user_args().has("--no-click"):
		print("--- calling request_quit() directly (no mouse) ---")
		menu.call("request_quit")
	else:
		var button: Button = menu.get(&"_quit_button") as Button
		if button == null:
			print("FAIL: MainMenu has no _quit_button")
			quit(1)
			return
		var centre: Vector2 = button.get_global_rect().get_center()
		print("--- clicking QUIT at %s (button rect %s) ---" % [centre, button.get_global_rect()])
		# `root.push_input` rather than `Input.parse_input_event`: pushing straight at the viewport
		# is what a real click does to GUI state and does not depend on the OS window holding focus,
		# which a probe window parked offscreen never does.
		var motion := InputEventMouseMotion.new()
		motion.position = centre
		motion.global_position = centre
		root.push_input(motion)
		await process_frame
		for pressed: bool in [true, false]:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
			click.pressed = pressed
			click.position = centre
			click.global_position = centre
			root.push_input(click)
			await process_frame
		print("after the click: hovered=%s focus_owner=%s button_pressed_signal_connections=%d"
			% [str(root.gui_get_hovered_control()), str(root.gui_get_focus_owner()),
				button.get_signal_connection_list(&"pressed").size()])
	for i: int in GRACE_FRAMES:
		await process_frame
		print("survived frame %d after quit()" % (i + 1))
	print("--- probe reached the end without crashing ---")
	quit(0)


## `-- --soak 1800` -> 1800. Absent or malformed -> `fallback`.
func _int_arg(name: String, fallback: int) -> int:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] == name and i + 1 < args.size() and args[i + 1].is_valid_int():
			return int(args[i + 1])
	return fallback
