extends SceneTree

## MENU-2 proof (docs/MENU.md §2, §11): the navigation stack's invariants, the ones every screen
## built on it will silently depend on.
##
## Covers: push/pop ordering and visibility; focus memory restored across a pop; the default-focus
## fallback that keeps a controller from landing nowhere (F-216); the blocking-group and cursor
## handover; modal screens keeping the screen below visible; pinned screens refusing Esc (F-275);
## the conditional root-cancel consume that lets this autoload land BEFORE the shipped panels are
## migrated without changing their behaviour; and toasts.
##
## Run with: .agent/bin/agent godot --script tools/menu_stack_check.gd

const MireTheme := preload("res://ui/theme/mire_theme.gd")

var failures: int = 0
var _confirm_fired: int = 0
var _root_cancels: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var stack: Node = root.get_node_or_null(^"/root/MenuStack")
	check(stack != null, "MenuStack autoload exists")
	if stack == null:
		finish()
		return

	check(not bool(stack.call("is_open")), "stack starts empty")
	check(int(stack.call("depth")) == 0, "depth starts at 0")
	check(not stack.is_in_group(&"blocks_gameplay_input"), "empty stack does not block gameplay input")

	# ── push / pop ordering and visibility ───────────────────────────────────────────────────────
	var first: Control = _screen("First")
	var second: Control = _screen("Second")

	stack.call("push", first, false)
	check(int(stack.call("depth")) == 1, "push adds one screen")
	check(stack.call("top") == first, "the pushed screen is on top")
	check(first.visible, "the pushed screen is visible")
	check(first.get_parent() != null, "the stack reparents the screen into itself")
	check(stack.is_in_group(&"blocks_gameplay_input"), "a non-empty stack blocks gameplay input")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "a non-empty stack frees the cursor")

	stack.call("push", second, false)
	check(int(stack.call("depth")) == 2, "a second push stacks rather than replacing")
	check(stack.call("top") == second, "the newest screen is on top")
	check(not first.visible, "a non-modal push hides the screen below")

	check(bool(stack.call("pop")), "pop reports success")
	check(int(stack.call("depth")) == 1, "pop removes exactly one screen")
	check(first.visible, "popping reveals the screen below")
	check(stack.call("top") == first, "the revealed screen is on top again")

	stack.call("pop")
	check(int(stack.call("depth")) == 0, "the stack empties")
	check(not stack.is_in_group(&"blocks_gameplay_input"), "an emptied stack releases the blocking group")
	check(not bool(stack.call("pop")), "popping an empty stack reports failure rather than erroring")

	# ── focus memory across a push/pop ───────────────────────────────────────────────────────────
	# The property the whole "Esc means back one level" contract rests on: you return to exactly the
	# control you left, not to the top of the revealed screen.
	var outer: Control = _screen("Outer")
	var outer_first: Button = MireTheme.button("outer-first")
	var outer_second: Button = MireTheme.button("outer-second")
	outer.add_child(outer_first)
	outer.add_child(outer_second)
	stack.call("push", outer, false)
	await process_frame

	outer_second.grab_focus()
	check(root.gui_get_focus_owner() == outer_second, "focus can be placed on a lower screen's control")

	var inner: Control = _screen("Inner")
	var inner_button: Button = MireTheme.button("inner")
	inner.add_child(inner_button)
	stack.call("push", inner, false)
	await process_frame
	check(root.gui_get_focus_owner() == inner_button, "pushing focuses the new screen's first focusable control")

	stack.call("pop")
	await process_frame
	check(root.gui_get_focus_owner() == outer_second,
		"popping restores the exact control that had focus, not the screen's first")

	# ── a screen that names its own default focus is obeyed ──────────────────────────────────────
	var picky := PickyScreen.new()
	stack.call("push", picky, false)
	await process_frame
	check(root.gui_get_focus_owner() == picky.preferred, "menu_default_focus() overrides the first-focusable fallback")
	stack.call("pop")
	await process_frame

	stack.call("pop_all")
	check(int(stack.call("depth")) == 0, "pop_all empties the stack")

	# ── modal screens keep the screen below visible ──────────────────────────────────────────────
	var page: Control = _screen("Page")
	stack.call("push", page, false)
	var modal := ModalScreen.new()
	stack.call("push", modal, false)
	check(page.visible, "a modal push leaves the screen below visible (it reads as 'over', not 'elsewhere')")
	stack.call("pop")
	stack.call("pop_all")

	# ── confirm(): cancel is the default, confirm runs after the pop ─────────────────────────────
	_confirm_fired = 0
	var base: Control = _screen("Base")
	stack.call("push", base, false)
	var dialog: Control = stack.call(
		"confirm", "Quit?", "The bog will keep.", "QUIT", "STAY", _on_confirmed, true
	)
	await process_frame
	check(int(stack.call("depth")) == 2, "confirm pushes a dialog")
	check(bool(dialog.call("menu_is_modal")), "the confirm dialog is modal")
	check(base.visible, "the screen behind a confirm dialog stays visible")
	var focus_owner: Control = root.gui_get_focus_owner()
	check(focus_owner != null and focus_owner == dialog.call("menu_default_focus"),
		"the confirm dialog focuses CANCEL, so the destructive answer must be travelled to")

	check(_confirm_fired == 0, "the confirm handler has not run yet")
	dialog.call("_accept")
	await process_frame
	check(_confirm_fired == 1, "accepting runs the handler exactly once")
	check(int(stack.call("depth")) == 1, "accepting pops the dialog")
	stack.call("pop_all")

	# ── pinned screens refuse Esc (F-275's focus trap, deliberately chosen) ──────────────────────
	var pinned := PinnedScreen.new()
	stack.call("push", pinned, false)
	check(not bool(pinned.call("menu_allows_cancel")), "a pinned screen declares it")
	_send_cancel()
	await process_frame
	check(int(stack.call("depth")) == 1, "ui_cancel does not pop a pinned screen")
	stack.call("pop_all")
	check(int(stack.call("depth")) == 0, "a pinned screen can still be popped in code")

	# ── ui_cancel pops a normal screen ───────────────────────────────────────────────────────────
	var poppable: Control = _screen("Poppable")
	stack.call("push", poppable, false)
	_send_cancel()
	await process_frame
	check(int(stack.call("depth")) == 0, "ui_cancel pops the top screen")

	# ── the root-cancel contract: emitted when empty, consumed only if someone answered ──────────
	# This is what lets MenuStack ship before the front end is migrated: with nothing on the stack
	# and nobody listening, an Esc press must reach the un-migrated panels untouched.
	stack.connect("cancel_at_root", _on_root_cancel)
	_root_cancels = 0
	_send_cancel()
	await process_frame
	check(_root_cancels == 1, "an empty stack emits cancel_at_root")
	check(int(stack.call("depth")) == 0, "an unanswered cancel_at_root leaves the stack empty")

	# ── toasts ───────────────────────────────────────────────────────────────────────────────────
	var before: int = int(stack.call("toast_count"))
	stack.call("toast", "Lobby ID copied", false)
	check(int(stack.call("toast_count")) == before + 1, "toast() shows a message")
	check(not bool(stack.call("is_open")), "a toast does not open the stack or steal focus")

	outer.free()
	inner.free()
	page.free()
	base.free()
	first.free()
	second.free()
	poppable.free()
	print("MENU_STACK_CHECK failures=%d" % failures)
	finish()


func _screen(name_text: String) -> Control:
	var control := Control.new()
	control.name = name_text
	return control


func _send_cancel() -> void:
	var event := InputEventAction.new()
	event.action = &"ui_cancel"
	event.pressed = true
	root.push_input(event)


func _on_confirmed() -> void:
	_confirm_fired += 1


func _on_root_cancel() -> void:
	_root_cancels += 1


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)


## A screen that names a default-focus control which is NOT its first focusable child, so the check
## can tell `menu_default_focus()` from the fallback.
class PickyScreen extends Control:
	const Kit := preload("res://ui/theme/mire_theme.gd")

	var preferred: Button

	func _init() -> void:
		var decoy: Button = Kit.button("decoy")
		add_child(decoy)
		preferred = Kit.button("preferred")
		add_child(preferred)

	func menu_default_focus() -> Control:
		return preferred


class ModalScreen extends Control:
	func menu_is_modal() -> bool:
		return true


class PinnedScreen extends Control:
	func menu_allows_cancel() -> bool:
		return false
