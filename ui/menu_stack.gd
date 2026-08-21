extends CanvasLayer

## MenuStack — MENU-2: the single navigation stack every front-end screen lives on
## (docs/MENU.md §2). Push and pop only; no screen ever opens beside another.
## Register as autoload `MenuStack` → res://ui/menu_stack.gd, AFTER `SettingsService` (the theme
## kit reads UI scale and reduce-motion through it) and BEFORE any screen autoload that pushes.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI, the table's free last
## row. This file moves Control nodes and focus around one process. It sends nothing and trusts
## nothing.
##
## ## What this replaces
##
## The shipped panels each implement the same four behaviours privately, four times over:
## a `blocks_gameplay_input` join/leave, an `_other_blocking_ui_open()` guard that makes a panel
## silently REFUSE to open when another is up (D-032), a mouse-mode save/restore, and a raw-keycode
## Esc branch. That convention has two costs the stack removes. First, "refuse to open" is a dead
## end for the player: pressing SETTINGS with another panel up does nothing at all, with no feedback
## about why. Second, every panel that wants to open another has to close itself first and hope the
## other one opens — a hand-off with no return path, which is why nothing in the shipped front end
## can go BACK anywhere.
##
## A stack answers both: opening a screen from a screen pushes, Esc pops to exactly where you were,
## and the "one cursor UI at a time" invariant D-032 wanted is now structural rather than a rule
## every new panel has to remember to re-implement.
##
## ## The screen contract
##
## A screen is any `Control`. Optionally it implements any of these — all duck-typed via
## `has_method`, so a screen only declares what it cares about:
##
##   `menu_default_focus() -> Control`   what to focus when shown (else: first focusable descendant)
##   `menu_shown()`                      called after it becomes the top screen
##   `menu_hidden()`                     called after it stops being the top screen
##   `menu_allows_cancel() -> bool`      false pins the screen — Esc/B will not pop it. For screens
##                                       with a mandatory choice (the attunement picker, F-216) or a
##                                       terminal one (the run summary, F-275). A pinned screen MUST
##                                       provide its own way out, or it is the focus trap F-275 filed.
##   `menu_is_modal() -> bool`           true keeps the screen BELOW this one visible behind the
##                                       shade — confirm dialogs read as "over" the screen they
##                                       interrupt, not as a separate place you travelled to.
##   `menu_dims_background() -> bool`    false suppresses the full-screen shade. The shade exists to
##                                       separate a PANEL from whatever is behind it; a screen that
##                                       fills the frame with its own art (the title, over the live
##                                       island) would only be dimming its own backdrop.
##
## ## The Esc/B contract, and why it is safe to land before the screens are migrated
##
## `ui_cancel` (Escape + joypad button 1, bound project-wide since F-209/D-134) means "back one
## level", everywhere, always. With screens on the stack this file consumes the press and pops.
## With an EMPTY stack it emits `cancel_at_root` and consumes the press ONLY IF a listener responded
## by pushing something — which is how the pause menu (MENU-5) will claim Esc in-run without this
## file knowing anything about runs.
##
## That conditional consume is deliberate and load-bearing during the migration: while
## `main_menu.gd`/`lobby_menu.gd`/`settings_menu.gd` still own their own Esc branches, an empty
## stack leaves their press untouched and they keep working exactly as they do today. Nothing about
## the shipped front end changes on the frame this autoload is registered.
##
## ## Legacy panels close BEFORE the root listener is offered the press (F-384)
##
## The migration's "leave their press untouched" clause had a hole the shipped build fell straight
## into. This autoload is registered after `LobbyMenu` in `project.godot`, and `_input` propagates in
## reverse tree order, so a legacy panel's own Esc branch runs *after* this one — but `cancel_at_root`
## has already fired by then, the pause menu has already opened, and the event is already marked
## handled. Every legacy panel's Esc branch opens with `if get_viewport().is_input_handled(): return`,
## so the press never reaches it. Played result: the multiplayer menu could not be closed at all.
##
## So an empty stack now checks the `blocks_gameplay_input` group first and closes whatever is open
## there, and only offers `cancel_at_root` when the screen is otherwise clear. That is the rule
## Sequoyah asked for in the 2026-08-20 playtest — *Esc closes any open menu or interface before it
## opens the pause menu* — and stating it here rather than in each panel means it holds for panels
## that do not exist yet.
##
## Membership in that group IS the "I am open" flag (every member adds itself in its own
## `set_open(true)` and removes itself in `set_open(false)`), and `set_open(bool)` is the shared
## close API across all six shipped members. A member that does not implement it is left alone —
## which is exactly right for `AttunementUI`, whose pick is mandatory and whose reachability is
## F-321's call to make, not this file's.

const MireTheme := preload("res://ui/theme/mire_theme.gd")

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

const TOAST_SECONDS: float = 3.0

## Emitted after a screen becomes the top of the stack.
signal screen_pushed(screen: Control)
## Emitted after a screen is removed. The screen may already be queued for free.
signal screen_popped(screen: Control)
## Emitted when the last screen pops — the front end is showing nothing of its own.
signal stack_emptied()
## Emitted when `ui_cancel` arrives with an empty stack. The pause menu's cue (MENU-5). A listener
## that pushes a screen in response causes the press to be consumed; one that ignores it leaves the
## press to whoever else is listening, which is what keeps the un-migrated panels working.
signal cancel_at_root()

var _stack: Array[Control] = []
## Parallel to `_stack`: what had focus at the moment each screen was pushed, so popping can put it
## back. Entries may go stale (the owner freed underneath us) and are null-checked on restore.
var _focus_memory: Array[Control] = []
## Parallel to `_stack`: whether `pop()` should free that screen. A screen the caller intends to
## re-push (the title screen) is pushed with `free_on_pop = false` and merely hidden.
var _free_on_pop: Array[bool] = []

var _root: Control
var _shade: ColorRect
var _screen_host: Control
var _toast_host: VBoxContainer

var _restore_mouse_captured: bool = false


func _ready() -> void:
	# Above every shipped panel (LobbyMenu 55, MainMenu 57) so a stacked screen is never drawn
	# under a legacy one during the migration; the toast layer sits above this in _build().
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if not event.is_action_pressed(&"ui_cancel"):
		return

	if _stack.is_empty():
		# F-384: a legacy blocking panel outranks the root listener. Close it and stop here — the
		# pause menu must not open over an interface the player was trying to leave.
		if close_blocking_panel():
			get_viewport().set_input_as_handled()
			return
		# Nothing of ours is up. Offer the press to whoever owns "back" at the root (the pause menu
		# in-run), and consume it only if they actually took it — see the class doc.
		cancel_at_root.emit()
		if not _stack.is_empty():
			get_viewport().set_input_as_handled()
		return

	var screen: Control = _stack.back()
	if not _screen_allows_cancel(screen):
		# A pinned screen still swallows the press: falling through would let a legacy panel or the
		# player controller act on an Esc the player aimed at this screen.
		get_viewport().set_input_as_handled()
		return

	pop()
	get_viewport().set_input_as_handled()


# ── Public API ────────────────────────────────────────────────────────────────────────────────────


## Closes the open legacy blocking panel, if there is one, and reports whether it closed anything.
## Public because the check drives it directly and because a caller that is about to open something
## cursor-owning has the same "clear the screen first" need Esc does.
##
## Walks the group backwards: `get_nodes_in_group` returns tree order, and D-032's interlock means at
## most one member is ever open, so the direction only matters for the degenerate case — and there,
## closing the one nearest the front is the better guess.
func close_blocking_panel() -> bool:
	var members: Array[Node] = get_tree().get_nodes_in_group(BLOCKING_UI_GROUP)
	for index: int in range(members.size() - 1, -1, -1):
		var panel: Node = members[index]
		if panel == self or not is_instance_valid(panel):
			continue
		if not panel.has_method(&"set_open"):
			# A mandatory panel with no close API (AttunementUI). Not ours to force shut, but it IS
			# still holding the screen, so the press stops here rather than reaching the pause menu.
			return true
		panel.call(&"set_open", false)
		return true
	return false


## Shows `screen` as the top of the stack, hiding the one below unless this screen is modal.
## The screen is reparented under this layer; the caller does not add it to the tree itself.
func push(screen: Control, free_on_pop: bool = true) -> void:
	if screen == null or _stack.has(screen):
		return

	_focus_memory.append(get_viewport().gui_get_focus_owner())

	var below: Control = _stack.back() if not _stack.is_empty() else null
	if below != null and not _screen_is_modal(screen):
		below.visible = false
		if below.has_method("menu_hidden"):
			below.call("menu_hidden")

	_stack.append(screen)
	_free_on_pop.append(free_on_pop)

	if screen.get_parent() != _screen_host:
		if screen.get_parent() != null:
			screen.get_parent().remove_child(screen)
		_screen_host.add_child(screen)
	# `set_anchors_and_offsets_preset`, NOT `set_anchors_preset`. The latter sets the anchors and
	# then rewrites the OFFSETS to preserve the control's current rect — so a screen that is still
	# 0×0 when it enters the tree (every screen, since `_ready()` runs on `add_child` before any
	# layout pass) comes out anchored full-rect with offsets of -1280,-720 and a computed size of
	# exactly zero. It builds, it reports visible, it passes every behavioural test, and it draws
	# nothing anchored to its bottom edge. This one call is the difference.
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.visible = true
	# Newest child draws last, so a modal is painted over the screen it interrupts.
	_screen_host.move_child(screen, _screen_host.get_child_count() - 1)

	_sync_open_state()
	if screen.has_method("menu_shown"):
		screen.call("menu_shown")
	_grab_default_focus(screen)
	MireTheme.fade_in(screen, MireTheme.DURATION_FAST)
	screen_pushed.emit(screen)


## Removes the top screen and restores the one below it, along with the focus that screen had when
## it was covered. Returns false when the stack was already empty.
func pop() -> bool:
	if _stack.is_empty():
		return false

	var screen: Control = _stack.pop_back()
	var free_it: bool = _free_on_pop.pop_back()
	var remembered: Control = _focus_memory.pop_back()

	if screen.has_method("menu_hidden"):
		screen.call("menu_hidden")
	screen.visible = false
	if free_it:
		if screen.get_parent() != null:
			screen.get_parent().remove_child(screen)
		screen.queue_free()

	var below: Control = _stack.back() if not _stack.is_empty() else null
	if below != null:
		below.visible = true
		if below.has_method("menu_shown"):
			below.call("menu_shown")

	_sync_open_state()

	# Restore focus to exactly what the player left, falling back to the revealed screen's own
	# default. `is_instance_valid` because the remembered owner may have been freed underneath us.
	if remembered != null and is_instance_valid(remembered) and remembered.is_inside_tree():
		remembered.grab_focus()
	elif below != null:
		_grab_default_focus(below)

	screen_popped.emit(screen)
	if _stack.is_empty():
		stack_emptied.emit()
	return true


## Pops every screen. Used when a run starts (the front end gets out of the way) and when the
## player quits to the title from deep in a sub-screen.
func pop_all() -> void:
	while not _stack.is_empty():
		pop()


## Pops everything, then pushes `screen` — "go here, and make it the only thing on the stack".
## The transition a run summary uses to hand back to the title.
func replace(screen: Control, free_on_pop: bool = true) -> void:
	pop_all()
	push(screen, free_on_pop)


func top() -> Control:
	return _stack.back() if not _stack.is_empty() else null


func depth() -> int:
	return _stack.size()


func is_open() -> bool:
	return not _stack.is_empty()


func has_screen(screen: Control) -> bool:
	return _stack.has(screen)


## A yes/no dialog pushed as a modal, so the screen it interrupts stays visible behind the shade.
## `on_confirm` runs after the dialog pops, never before — a confirm handler that pushes its own
## screen (QUIT TO TITLE) must not have this dialog pop out from under it afterwards.
## Cancel is always the default focus: the player should have to travel to the destructive answer.
func confirm(
	title: String,
	body: String,
	confirm_label: String,
	cancel_label: String,
	on_confirm: Callable,
	destructive: bool = true,
) -> Control:
	var dialog := ConfirmScreen.new()
	dialog.setup(title, body, confirm_label, cancel_label, on_confirm, destructive)
	push(dialog)
	return dialog


## A transient message, top-centre, that fades out on its own. For results that do not need an
## acknowledgement ("Lobby ID copied"), so a screen does not need a permanent status line for every
## momentary outcome.
func toast(message: String, is_error: bool = false) -> void:
	var frame: PanelContainer = MireTheme.card(MireTheme.ERROR if is_error else MireTheme.BORDER)
	frame.modulate.a = 0.0
	var text: Label = MireTheme.label(message, MireTheme.BODY, MireTheme.ERROR if is_error else MireTheme.TEXT)
	frame.add_child(text)
	_toast_host.add_child(frame)

	var motion: float = MireTheme.motion_scale()
	if motion <= 0.0:
		# Reduce motion: appear and disappear instantly, but still for the full readable duration.
		frame.modulate.a = 1.0
		var timer: SceneTreeTimer = get_tree().create_timer(TOAST_SECONDS, true, false, true)
		timer.timeout.connect(frame.queue_free)
		return

	var tween: Tween = frame.create_tween()
	tween.tween_property(frame, ^"modulate:a", 1.0, MireTheme.DURATION_FAST)
	tween.tween_interval(TOAST_SECONDS)
	tween.tween_property(frame, ^"modulate:a", 0.0, MireTheme.DURATION_FAST)
	tween.tween_callback(frame.queue_free)


func toast_count() -> int:
	return _toast_host.get_child_count()


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


## The stack owns the cursor and the gameplay-input gate for as long as anything is on it. Joining
## the same `blocks_gameplay_input` group the shipped panels use is what makes
## `player_controller.gd`'s `gameplay_input_allowed()` keep working unchanged — the group is the
## contract, the stack is just a second, better-behaved member of it.
func _sync_open_state() -> void:
	var open: bool = not _stack.is_empty()
	_screen_host.visible = open
	# The shade follows the TOP screen's wish, not merely whether anything is open: the title screen
	# is a full-bleed screen over a live 3D backdrop and dimming it would be dimming its own art,
	# while a confirm dialog pushed on top of that same title must bring the shade back.
	_shade.visible = open and _screen_dims_background(_stack.back())

	if open:
		if not is_in_group(BLOCKING_UI_GROUP):
			add_to_group(BLOCKING_UI_GROUP)
			_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif is_in_group(BLOCKING_UI_GROUP):
		remove_from_group(BLOCKING_UI_GROUP)
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_restore_mouse_captured = false


func _grab_default_focus(screen: Control) -> void:
	var target: Control = null
	if screen.has_method("menu_default_focus"):
		target = screen.call("menu_default_focus")
	if target == null:
		target = _first_focusable(screen)
	if target != null and target.is_inside_tree():
		target.grab_focus()


## Depth-first search for something a gamepad can land on. The fallback when a screen does not name
## its own default — a screen that lands focus nowhere is unusable on a controller (F-216).
func _first_focusable(node: Node) -> Control:
	for child: Node in node.get_children():
		if child is Control:
			var control: Control = child
			if control.visible and control.focus_mode == Control.FOCUS_ALL:
				return control
		var deeper: Control = _first_focusable(child)
		if deeper != null:
			return deeper
	return null


func _screen_allows_cancel(screen: Control) -> bool:
	if screen.has_method("menu_allows_cancel"):
		return bool(screen.call("menu_allows_cancel"))
	return true


func _screen_is_modal(screen: Control) -> bool:
	if screen.has_method("menu_is_modal"):
		return bool(screen.call("menu_is_modal"))
	return false


func _screen_dims_background(screen: Control) -> bool:
	if screen != null and screen.has_method("menu_dims_background"):
		return bool(screen.call("menu_dims_background"))
	return true


func _build() -> void:
	_root = Control.new()
	_root.name = "MenuStackRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "Shade"
	_shade.color = MireTheme.SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_screen_host = Control.new()
	_screen_host.name = "Screens"
	_screen_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screen_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen_host.visible = false
	_root.add_child(_screen_host)

	# Toasts live above the shade and outside the stack: a message about what just happened must be
	# readable whether or not a screen is up, and must never take focus.
	var toast_layer := Control.new()
	toast_layer.name = "Toasts"
	toast_layer.set_anchors_preset(Control.PRESET_TOP_WIDE)
	toast_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(toast_layer)

	_toast_host = VBoxContainer.new()
	_toast_host.name = "ToastHost"
	_toast_host.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast_host.anchor_left = 0.5
	_toast_host.anchor_right = 0.5
	_toast_host.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_host.offset_top = float(MireTheme.GRID * 4)
	_toast_host.alignment = BoxContainer.ALIGNMENT_CENTER
	_toast_host.add_theme_constant_override("separation", MireTheme.GRID)
	_toast_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_layer.add_child(_toast_host)


## The confirm dialog `confirm()` builds. An inner class rather than its own file because it has no
## existence apart from that call and no other screen ever instantiates it.
class ConfirmScreen extends Control:

	var _on_confirm: Callable
	var _cancel_button: Button

	func setup(
		title: String,
		body: String,
		confirm_label: String,
		cancel_label: String,
		on_confirm: Callable,
		destructive: bool,
	) -> void:
		_on_confirm = on_confirm
		mouse_filter = Control.MOUSE_FILTER_STOP

		var centre := CenterContainer.new()
		centre.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(centre)

		var panel: PanelContainer = MireTheme.panel()
		panel.custom_minimum_size = Vector2(460.0, 0.0)
		centre.add_child(panel)

		var stack: VBoxContainer = MireTheme.column(MireTheme.GRID + MireTheme.GRID / 2)
		panel.add_child(stack)

		var heading: Label = MireTheme.label(title, MireTheme.TITLE, MireTheme.TEXT)
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stack.add_child(heading)
		stack.add_child(MireTheme.paragraph(body, MireTheme.BODY, MireTheme.MUTED))
		stack.add_child(MireTheme.separator())

		var buttons: HBoxContainer = MireTheme.row()
		buttons.alignment = BoxContainer.ALIGNMENT_CENTER
		stack.add_child(buttons)

		_cancel_button = MireTheme.button(cancel_label, _dismiss)
		_cancel_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		buttons.add_child(_cancel_button)

		var accept: Button = MireTheme.button(
			confirm_label,
			_accept,
			MireTheme.Variant.DESTRUCTIVE if destructive else MireTheme.Variant.PRIMARY,
		)
		accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		buttons.add_child(accept)

		MireTheme.wire_row([_cancel_button, accept])
		MireTheme.wire_chain([_cancel_button, accept])

	## Cancel, not confirm: the player must travel to the answer that costs something.
	func menu_default_focus() -> Control:
		return _cancel_button

	func menu_is_modal() -> bool:
		return true

	func _dismiss() -> void:
		var stack: Node = get_node_or_null(^"/root/MenuStack")
		if stack != null:
			stack.call("pop")

	## Pops first, then runs the handler — so a handler that pushes its own screen does not have
	## this dialog pop out from underneath it a moment later.
	func _accept() -> void:
		var stack: Node = get_node_or_null(^"/root/MenuStack")
		if stack != null:
			stack.call("pop")
		if _on_confirm.is_valid():
			_on_confirm.call()
