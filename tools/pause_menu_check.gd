extends SceneTree

## MENU-5 proof (docs/MENU.md §6.1, §11): the in-run menu opens on Esc only while a run is on
## screen, never pauses the tree, and states real numbers before it takes anything away.
##
## The property most worth protecting here is the negative one: pressing Esc in the FRONT END must
## not summon the pause menu, and pressing it in a run must not fall through to the front end's
## handling. One key, one meaning, decided by whether the front end exists.
##
## Run with: .agent/bin/agent godot --script tools/pause_menu_check.gd

const MireTheme := preload("res://ui/theme/mire_theme.gd")

const FRONTEND_GROUP: StringName = &"mire_frontend"

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var stack: Node = root.get_node_or_null(^"/root/MenuStack")
	var pause: Node = root.get_node_or_null(^"/root/PauseMenu")
	check(stack != null, "MenuStack autoload exists")
	check(pause != null, "PauseMenu autoload exists")
	if stack == null or pause == null:
		finish()
		return
	stack.call("pop_all")

	# ── "in a run" means "the front end is not on screen" ────────────────────────────────────────
	var fake_frontend := Node.new()
	fake_frontend.add_to_group(FRONTEND_GROUP)
	root.add_child(fake_frontend)
	await process_frame
	check(not bool(pause.call("run_in_progress")),
		"with the front end up, no run is in progress")

	# Esc in the front end must NOT open the pause menu.
	_send_cancel()
	await process_frame
	check(not bool(pause.call("is_open")), "Esc in the front end does not open the pause menu")
	check(int(stack.call("depth")) == 0, "Esc in the front end pushes nothing")

	fake_frontend.free()
	await process_frame
	check(bool(pause.call("run_in_progress")), "with no front end, a run is in progress")

	# ── Esc in a run opens it; Esc again closes it ───────────────────────────────────────────────
	_send_cancel()
	await process_frame
	check(bool(pause.call("is_open")), "Esc in a run opens the pause menu")
	check(int(stack.call("depth")) == 1, "the pause menu is on the stack")

	# The tree must never be paused: a listen server that stalls its own frame stalls networking for
	# every connected peer.
	check(not paused, "the pause menu does not pause the tree")

	var screen: Control = stack.call("top")
	var focus_target: Control = screen.call("menu_default_focus")
	check(focus_target != null and String(focus_target.text) == "RESUME",
		"the pause menu focuses RESUME")

	_send_cancel()
	await process_frame
	check(not bool(pause.call("is_open")), "Esc again closes the pause menu")
	check(int(stack.call("depth")) == 0, "closing leaves an empty stack")
	check(not paused, "the tree is still not paused after closing")

	# Opening twice must not stack two copies of itself.
	pause.call("open")
	pause.call("open")
	await process_frame
	check(int(stack.call("depth")) == 1, "the pause menu refuses to stack on itself")
	pause.call("close")
	await process_frame

	# ── abandoning quotes real numbers ───────────────────────────────────────────────────────────
	var summary: Dictionary = pause.call("abandon_summary")
	check(summary.has("full") and summary.has("banked") and summary.has("cycle"),
		"the abandon summary reports the cycle, the full payout and what a death banks")

	var salvage: Node = root.get_node_or_null(^"/root/SalvageService")
	if salvage != null:
		var cycle: int = int(summary["cycle"])
		var expected_full: int = int(salvage.call("reward_for_cycle", cycle))
		check(int(summary["full"]) == expected_full,
			"the quoted full payout is SalvageService's own number (%d)" % expected_full)
		check(int(summary["banked"]) < int(summary["full"]) or int(summary["full"]) == 0,
			"abandoning banks strictly less than finishing — the bet has to cost something")
		var fraction: float = float(salvage.get("DEATH_BANK_FRACTION"))
		check(int(summary["banked"]) == int(round(float(expected_full) * fraction)),
			"the quoted bank is the death fraction of the payout, not an invented number")

	# The dialog must actually say those numbers — a confirm that hides the cost is one players
	# learn to click through.
	pause.call("open")
	await process_frame
	pause.call("request_abandon")
	await process_frame
	check(int(stack.call("depth")) == 2, "abandoning asks first")
	var dialog: Control = stack.call("top")
	check(bool(dialog.call("menu_is_modal")), "the abandon confirmation is modal")
	var body: String = _all_text(dialog)
	check(body.contains(str(int(summary["banked"]))),
		"the abandon dialog states the number of Salvage you would bank")
	check(body.contains("KEEP FIGHTING"), "the abandon dialog offers a way out")

	var default_focus: Control = dialog.call("menu_default_focus")
	check(default_focus != null and String(default_focus.text) == "KEEP FIGHTING",
		"the abandon dialog focuses KEEP FIGHTING — you travel to the destructive answer")

	stack.call("pop_all")
	await process_frame
	check(not bool(pause.call("is_open")), "popping everything closes the pause menu cleanly")

	print("PAUSE_MENU_CHECK failures=%d" % failures)
	finish()


func _send_cancel() -> void:
	var event := InputEventAction.new()
	event.action = &"ui_cancel"
	event.pressed = true
	root.push_input(event)


func _all_text(node: Node) -> String:
	var text: String = ""
	if node is Label:
		text += (node as Label).text + " "
	elif node is Button:
		text += (node as Button).text + " "
	for child: Node in node.get_children():
		text += _all_text(child)
	return text


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
