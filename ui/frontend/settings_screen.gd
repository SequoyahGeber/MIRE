extends Control

## SettingsScreen — MENU-6: settings, in tabs (docs/MENU.md §7.1).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI. This file owns NO settings
## state whatsoever: every control is a thin view over `SettingsService`, which keeps owning the
## values, the `InputMap` writes and the persistence. The only state here is which tab is showing
## and which rebind capture is armed.
##
## ## Why this is the single settings surface
##
## The retired vertical panel put graphics, five sliders, two checkboxes, twelve keyboard rebind rows and
## ten gamepad rebind rows in one column. That is around thirty controls in a single vertical focus
## chain: on a gamepad, reaching "gamepad rebind: hotbar next" is roughly thirty D-pad presses from
## the top, and there is no way to skip. Tabs turn that into one bumper press plus a short chain,
## which is the whole reason this screen is grouped rather than merely restyled.
##
## Opened from the title AND from the pause menu, pushed onto `MenuStack` both times, so Esc returns
## to whichever one you came from without this file knowing which that was.
##
## ## Scope: this presents the settings that exist
##
## docs/MENU.md §7.1 also lists settings this project does not have yet (window mode, vsync, fps cap,
## UI scale, screen-shake intensity, damage numbers, streamer mode). Each is a `SettingsService`
## addition plus a `settings_save.gd` migration, and adding eight of them is its own task with its
## own persistence round-trip evidence — not something to bolt onto the screen that presents them.
## The tab structure below already has a home for each, and `MireTheme.ui_scale()` is already written
## to read a `ui_scale()` method the moment one exists. Filed as a finding rather than half-built.
##
## ## Preview, then commit (F-386), and reaching the rows below the fold (F-387)
##
## Showing this screen starts a `SettingsService` preview: controls keep applying live — FOV and
## sensitivity are unjudgeable otherwise — but nothing is persisted until SAVE. Backing out (the back
## link, Esc, or any pop of the stack) hands the opening state back. Together with the numeric
## readouts F-385 added, that is what makes a handle knocked by accident recoverable.
##
## The CONTROLS tab is twelve rebind rows plus a slider and a toggle, which is taller than the
## viewport on every screen this ships to, and none of it could be reached: the page host was a bare
## `Control`, which reports no minimum size of its own, so the `ScrollContainer` never had anything
## taller than itself to scroll and the overflow was simply clipped. It is a `VBoxContainer` now.

const MireTheme := preload("res://ui/theme/mire_theme.gd")
const FocusRingSlider := preload("res://ui/menu/focus_ring_slider.gd")
const GraphicsSettingsPage := preload("res://ui/frontend/graphics_settings_page.gd")
const BenchmarkScreen := preload("res://ui/frontend/benchmark_screen.gd")

## Fixed width of a slider's numeric readout, in pixels at `MireTheme.BODY`. Wide enough for the
## longest string any row produces ("720°/s") so the row cannot reflow while the handle moves.
const READOUT_WIDTH: float = 96.0

## Tab order is deliberate: the things a player changes most often first, the long rebind tables
## last. GAME is present but currently empty — see the scope note above.
const TABS: Array[String] = ["DISPLAY", "AUDIO", "CONTROLS", "GAMEPAD", "ACCESSIBILITY", "PLAYTESTING"]

var _tab_buttons: Array[Button] = []
var _pages: Array[Control] = []
var _page_host: VBoxContainer
var _active_tab: int = 0
var _status_label: Label
var _back_button: Button
var _save_button: Button
var _restore_button: Button
var _first_focus: Control
var _god_mode_toggle: CheckBox

## F-386: what every setting was when this screen was shown, from `SettingsService.capture_state()`.
## Handed back on the way out, re-taken on SAVE so leaving after a save keeps the save.
var _baseline: Dictionary = {}
var _previewing: bool = false
var _dirty: bool = false

## Every control that mirrors a `SettingsService` value, as `{control, getter}`. RESTORE DEFAULTS
## changes nine values at once and the widgets have to follow, which a screen that reads each value
## exactly once at build time cannot do — this is the registry that makes `_refresh_controls()`
## possible without a member variable per row.
var _bound_controls: Array[Dictionary] = []

## The rebind row currently listening for a key or button, or an empty StringName. Two captures can
## never be armed at once: arming one disarms the other, because a player who pressed two rows in a
## row would otherwise bind the same key to both.
var _capturing_action: StringName = &""
var _capturing_joypad: bool = false
var _capture_button: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	show_tab(0)


func menu_default_focus() -> Control:
	return _first_focus if _first_focus != null else _back_button


## While a rebind is armed, Esc must cancel the capture rather than leave the screen — otherwise the
## only way out of "press a key…" is to bind a key you did not want.
##
## With nothing armed this returns true and the stack pops, which reaches `menu_hidden()` — where the
## preview is handed back (F-386). Esc means "leave it as I found it" here, the same as the back link.
func menu_allows_cancel() -> bool:
	if _capturing_action != &"":
		_cancel_capture()
		return false
	return true


## F-386: the preview starts when the screen actually goes on screen, not in `_ready()` — a screen
## built but never pushed must not leave `SettingsService` holding its writes forever. Guarded
## because `MenuStack` calls this again every time a modal pushed over this screen pops back off.
func menu_shown() -> void:
	if _previewing:
		return
	var settings: Node = _settings()
	if settings == null or not settings.has_method("hold_persistence"):
		return
	settings.call("hold_persistence")
	_baseline = settings.call("capture_state") as Dictionary
	_previewing = true
	_set_dirty(false)


## Called both when this screen is COVERED by a pushed modal and when it is popped for good, so the
## two have to be told apart: `MenuStack.pop()` removes the screen from the stack before calling this,
## `push()` leaves it on. Only the genuine departure hands the preview back.
func menu_hidden() -> void:
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null and bool(stack.call("has_screen", self)):
		return
	_cancel_preview()


## The stack frees a popped screen, but `pop_all()` on a screen pushed with `free_on_pop = false`
## (and an outright `queue_free()` from anywhere else) would otherwise leave the service holding a
## preview no one can ever release. Idempotent with `menu_hidden()`.
func _exit_tree() -> void:
	_cancel_preview()


func _input(event: InputEvent) -> void:
	if _capturing_action == &"":
		return
	if _capturing_joypad:
		if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
			_finish_capture_joypad(event)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).is_echo():
		var key: InputEventKey = event
		if key.keycode == KEY_ESCAPE:
			_cancel_capture()
		else:
			_finish_capture_key(key)
		get_viewport().set_input_as_handled()


# ── Public API (the check drives these) ───────────────────────────────────────────────────────────


func show_tab(index: int) -> void:
	_active_tab = clampi(index, 0, _pages.size() - 1)
	for i: int in _pages.size():
		_pages[i].visible = i == _active_tab
		_tab_buttons[i].disabled = i == _active_tab
	_first_focus = _first_focusable(_pages[_active_tab])
	if _first_focus == null:
		_first_focus = _tab_buttons[_active_tab]


func active_tab() -> int:
	return _active_tab


func tab_count() -> int:
	return _pages.size()


func status_text() -> String:
	return _status_label.text


func is_capturing() -> bool:
	return _capturing_action != &""


func begin_capture(action: StringName, joypad: bool, button: Button) -> void:
	if _capturing_action != &"":
		_cancel_capture()
	_capturing_action = action
	_capturing_joypad = joypad
	_capture_button = button
	button.text = "press a button…" if joypad else "press a key…"
	_status_label.text = "Listening… Esc cancels."


# ── Build ─────────────────────────────────────────────────────────────────────────────────────────


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", MireTheme.GRID * 9)
	margin.add_theme_constant_override("margin_right", MireTheme.GRID * 9)
	margin.add_theme_constant_override("margin_top", MireTheme.GRID * 5)
	margin.add_theme_constant_override("margin_bottom", MireTheme.GRID * 5)
	add_child(margin)

	var centre: HBoxContainer = MireTheme.row(0)
	margin.add_child(centre)
	centre.add_child(_spacer())

	var page: VBoxContainer = MireTheme.column(MireTheme.GRID * 2)
	page.custom_minimum_size = Vector2(880.0, 0.0)
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	centre.add_child(page)
	centre.add_child(_spacer())

	var header: HBoxContainer = MireTheme.row()
	page.add_child(header)
	_back_button = MireTheme.link("◀  back", _go_back)
	header.add_child(_back_button)
	var title: Label = MireTheme.label("SETTINGS", MireTheme.HEADLINE, MireTheme.TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(title)
	header.add_child(_spacer())

	var tab_bar: HBoxContainer = MireTheme.row(MireTheme.GRID / 2)
	page.add_child(tab_bar)
	for index: int in TABS.size():
		var button: Button = MireTheme.button(TABS[index], func() -> void: show_tab(index))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab_bar.add_child(button)
		_tab_buttons.append(button)
	MireTheme.wire_row(_tab_buttons)

	page.add_child(MireTheme.separator())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# F-387: a gamepad walking the focus chain past the fold has to bring the viewport with it, or
	# the rows below stay unreachable on a controller no matter what the mouse wheel does.
	scroll.follow_focus = true
	page.add_child(scroll)

	# F-387: a `VBoxContainer`, NOT a bare `Control`. A `Control` has no minimum size of its own, so
	# whatever it holds, a `ScrollContainer` sees a child exactly as tall as its own viewport and
	# concludes there is nothing to scroll — the twelve rebind rows of the CONTROLS tab were being
	# clipped, not scrolled past. A `BoxContainer` reports its VISIBLE children's minimum size, and
	# `show_tab()` leaves exactly one page visible, so the scroll range is always the showing tab's.
	_page_host = VBoxContainer.new()
	_page_host.name = "SettingsPages"
	_page_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_page_host)

	_pages.append(_build_display_page())
	_pages.append(_build_audio_page())
	_pages.append(_build_controls_page())
	_pages.append(_build_gamepad_page())
	_pages.append(_build_accessibility_page())
	_pages.append(_build_playtesting_page())
	for entry: Control in _pages:
		entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_page_host.add_child(entry)

	_status_label = MireTheme.paragraph("", MireTheme.CAPTION, MireTheme.MUTED)
	page.add_child(_status_label)

	# F-386's commit step. Outside the scroll viewport, because a SAVE button you have to scroll to
	# find is a SAVE button players report as missing — which is how both settings surfaces got here.
	var footer: HBoxContainer = MireTheme.row()
	page.add_child(footer)
	_restore_button = MireTheme.button("RESTORE DEFAULTS", _on_restore_defaults)
	footer.add_child(_restore_button)
	footer.add_child(_spacer())
	_save_button = MireTheme.button("SAVE", _on_save, MireTheme.Variant.PRIMARY)
	footer.add_child(_save_button)
	MireTheme.wire_row([_restore_button, _save_button])


func _page() -> VBoxContainer:
	var column: VBoxContainer = MireTheme.column()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return column


## One settings row: a label on the left, its control on the right, at a fixed label measure so
## every row in every tab lines up.
func _row(label_text: String, control: Control, hint: String = "") -> Control:
	var wrapper: VBoxContainer = MireTheme.column(2)
	var row: HBoxContainer = MireTheme.row()
	wrapper.add_child(row)

	var label: Label = MireTheme.label(label_text, MireTheme.BODY, MireTheme.TEXT)
	label.custom_minimum_size = Vector2(300.0, 0.0)
	row.add_child(label)

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)

	if not hint.is_empty():
		var hint_label: Label = MireTheme.label(hint, MireTheme.CAPTION, MireTheme.MUTED)
		wrapper.add_child(hint_label)
	return wrapper


## A slider row: `_row()`, plus the number the slider was missing (F-385). Every slider on this
## screen shipped with a bare handle and no readout — field of view spans 60-110 in steps of 1, so
## once you moved it, the value you had was gone. `FocusRingSlider.bind_readout()` owns the format
## and pins the label's width so the row cannot reflow mid-drag and every tab uses one
## percentage/degree format.
func _slider_row(label_text: String, slider: HSlider, readout: int, hint: String = "") -> Control:
	var holder: HBoxContainer = MireTheme.row()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_child(slider)

	var value_label: Label = MireTheme.label("", MireTheme.BODY, MireTheme.TEXT)
	value_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.add_child(value_label)
	(slider as FocusRingSlider).bind_readout(value_label, readout, READOUT_WIDTH)

	return _row(label_text, holder, hint)


func _build_display_page() -> Control:
	var settings: Node = _settings()
	# The benchmark row only exists on the front end: it builds its own world on a pinned seed and
	# two of its scenes change that world permanently, so it can never run over a live run (D-192).
	# Membership of the front end's group IS the definition of "not in a run" — the same test
	# `ui/menu/pause_menu.gd` uses, so the two cannot drift apart.
	var on_frontend: bool = not get_tree().get_nodes_in_group(&"mire_frontend").is_empty()
	var graphics_page := GraphicsSettingsPage.new(settings, on_frontend)
	graphics_page.setting_requested.connect(func(setter: String, value: Variant) -> void:
		_write(setter, value))
	graphics_page.note_requested.connect(_note)
	graphics_page.benchmark_requested.connect(_open_benchmark)
	return graphics_page


## Hands the settings off to the benchmark and gets out of the way (F-453).
##
## Two things have to happen first, and both are this screen's job rather than the benchmark's.
## The current values are SAVED, because the benchmark measures the settings that are actually in
## effect and a preview that has not been committed is not what it would be measuring. Then the
## preview is released outright: the benchmark's whole purpose is to change these values, and a
## screen still holding a preview would hand its own baseline back over the top of the
## recommendation the moment the player left. `menu_shown()` re-takes the preview when this screen
## comes back, against whatever the benchmark left behind.
func _open_benchmark() -> void:
	_on_save()
	_cancel_preview()
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack == null or not stack.has_method("push"):
		_note("The benchmark needs the menu stack, which is not running.")
		return
	var screen := BenchmarkScreen.new()
	screen.name = "BenchmarkScreen"
	stack.call("push", screen)


func _build_audio_page() -> Control:
	var column: VBoxContainer = _page()
	var settings: Node = _settings()
	if settings == null:
		return column

	for entry: Array in [
		["Master volume", "master_volume", "set_master_volume"],
		["Music", "music_volume", "set_music_volume"],
		["Sound effects", "sfx_volume", "set_sfx_volume"],
	]:
		var slider: HSlider = MireTheme.slider(0.0, 1.0, 0.01)
		slider.value = float(settings.call(String(entry[1])))
		var setter: String = String(entry[2])
		slider.value_changed.connect(func(value: float) -> void: _write(setter, value))
		_bind(slider, String(entry[1]))
		column.add_child(_slider_row(String(entry[0]), slider, FocusRingSlider.Readout.PERCENT))
	return column


func _build_controls_page() -> Control:
	var column: VBoxContainer = _page()
	var settings: Node = _settings()
	if settings == null:
		return column

	var sensitivity: HSlider = MireTheme.slider(
		float(settings.get("MIN_SENSITIVITY")), float(settings.get("MAX_SENSITIVITY")), 0.005
	)
	sensitivity.value = float(settings.call("look_sensitivity"))
	sensitivity.value_changed.connect(func(value: float) -> void: _write("set_look_sensitivity", value))
	_bind(sensitivity, "look_sensitivity")
	column.add_child(_slider_row("Mouse sensitivity", sensitivity, FocusRingSlider.Readout.DECIMAL2))

	var invert: CheckBox = MireTheme.toggle()
	invert.button_pressed = bool(settings.call("invert_y"))
	invert.toggled.connect(func(pressed: bool) -> void: _write("set_invert_y", pressed))
	_bind(invert, "invert_y")
	column.add_child(_row("Invert vertical look", invert))

	column.add_child(MireTheme.separator())
	column.add_child(MireTheme.label("KEYBOARD", MireTheme.CAPTION, MireTheme.MUTED))
	for action_name: String in settings.call("rebindable_actions"):
		column.add_child(_rebind_row(StringName(action_name), false))

	var reset: Button = MireTheme.button("RESET KEYS TO DEFAULTS", func() -> void:
		_write_no_arg("reset_keybinds")
		_refresh_rebind_labels()
		_note("Back to how the swamp intended."))
	column.add_child(reset)
	return column


func _build_gamepad_page() -> Control:
	var column: VBoxContainer = _page()
	var settings: Node = _settings()
	if settings == null:
		return column

	var sensitivity: HSlider = MireTheme.slider(
		float(settings.get("MIN_GAMEPAD_SENSITIVITY")), float(settings.get("MAX_GAMEPAD_SENSITIVITY")), 5.0
	)
	sensitivity.value = float(settings.call("gamepad_look_sensitivity"))
	sensitivity.value_changed.connect(func(value: float) -> void:
		_write("set_gamepad_look_sensitivity", value))
	_bind(sensitivity, "gamepad_look_sensitivity")
	column.add_child(_slider_row(
		"Gamepad look sensitivity", sensitivity, FocusRingSlider.Readout.DEGREES_PER_SECOND))

	column.add_child(MireTheme.separator())
	column.add_child(MireTheme.label("BUTTONS", MireTheme.CAPTION, MireTheme.MUTED))
	# Only button-primary actions appear: a single-press capture cannot express "hold a stick
	# direction" or "pull a trigger", which is the boundary SettingsService already draws.
	for action_name: String in settings.call("rebindable_actions_joypad"):
		column.add_child(_rebind_row(StringName(action_name), true))
	return column


func _build_accessibility_page() -> Control:
	var column: VBoxContainer = _page()
	var settings: Node = _settings()
	if settings == null:
		return column

	var reduce: CheckBox = MireTheme.toggle()
	reduce.button_pressed = bool(settings.call("reduce_camera_motion"))
	reduce.toggled.connect(func(pressed: bool) -> void:
		_write("set_reduce_camera_motion", pressed)
		_note("Menu animation and camera motion %s." % ("off" if pressed else "on")))
	_bind(reduce, "reduce_camera_motion")
	column.add_child(_row("Reduce motion", reduce,
		"Stops camera shake, menu fades and the title screen's drift. Everything cuts instantly instead."))
	return column


## God mode is deliberately runtime-only, so this control does not participate in the
## SettingsService preview/save registry. It uses GodModeService's ordinary HOST command front door;
## a multiplayer client without operator permission gets the same refusal as the developer console.
func _build_playtesting_page() -> Control:
	var column: VBoxContainer = _page()
	var service: Node = _god_mode()

	_god_mode_toggle = MireTheme.toggle()
	_god_mode_toggle.name = "GodModeToggle"
	_god_mode_toggle.button_pressed = service != null and bool(service.call(&"is_local_enabled"))
	_god_mode_toggle.toggled.connect(_on_god_mode_toggled)
	column.add_child(_row(
		"God Mode",
		_god_mode_toggle,
		"Invulnerability and collision-preserving flight. Jump rises, Dodge descends, and Sprint flies faster. Resets when the game closes."
	))

	if service != null:
		if service.has_signal(&"god_mode_changed"):
			service.connect(&"god_mode_changed", _on_god_mode_changed)
		if service.has_signal(&"god_mode_request_completed"):
			service.connect(&"god_mode_request_completed", _on_god_mode_request_completed)
	return column


func _on_god_mode_toggled(enabled: bool) -> void:
	var service: Node = _god_mode()
	if service == null or not bool(service.call(&"request_local_enabled", enabled)):
		_set_god_mode_toggle(service != null and bool(service.call(&"is_local_enabled")))
		_note("God Mode is unavailable.")


func _on_god_mode_changed(peer_id: int, enabled: bool) -> void:
	var service: Node = _god_mode()
	if service == null:
		return
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	var local_peer_id: int = int(transport.call(&"local_peer_id")) if transport != null else 1
	if local_peer_id <= 0:
		local_peer_id = 1
	if peer_id == local_peer_id:
		_set_god_mode_toggle(enabled)


func _on_god_mode_request_completed(_requested: bool, accepted: bool, detail: String) -> void:
	var service: Node = _god_mode()
	_set_god_mode_toggle(service != null and bool(service.call(&"is_local_enabled")))
	_note(detail if not detail.is_empty() else ("God Mode updated." if accepted else "God Mode refused."))


func _set_god_mode_toggle(enabled: bool) -> void:
	if not is_instance_valid(_god_mode_toggle):
		return
	_god_mode_toggle.set_block_signals(true)
	_god_mode_toggle.button_pressed = enabled
	_god_mode_toggle.set_block_signals(false)


## A rebind row's button shows the current binding and, when pressed, listens for the next key or
## button. `SettingsService` refuses a binding already used by another action and returns which one,
## so the refusal can say what the conflict actually is.
func _rebind_row(action: StringName, joypad: bool) -> Control:
	var settings: Node = _settings()
	var label_text: String = String(action).replace("_", " ").capitalize()
	var button: Button = MireTheme.button("—")
	button.set_meta(&"action", action)
	button.set_meta(&"joypad", joypad)
	button.pressed.connect(func() -> void: begin_capture(action, joypad, button))
	if settings != null:
		button.text = String(settings.call(
			"keybind_label_joypad" if joypad else "keybind_label", action
		))
	return _row(label_text, button)


func _finish_capture_key(event: InputEventKey) -> void:
	var settings: Node = _settings()
	if settings == null:
		_cancel_capture()
		return
	var clash: StringName = StringName(settings.call("rebind_action", _capturing_action, event))
	_report_rebind(clash)


func _finish_capture_joypad(event: InputEventJoypadButton) -> void:
	var settings: Node = _settings()
	if settings == null:
		_cancel_capture()
		return
	var clash: StringName = StringName(settings.call("rebind_action_joypad", _capturing_action, event))
	_report_rebind(clash)


func _report_rebind(clash: StringName) -> void:
	if clash == &"":
		# F-386: a rebind stages like any other change — live in the InputMap so the player can try
		# it, on disk only once they press SAVE, gone again if they back out.
		_set_dirty(true)
		_note("Bound.")
	elif clash == &"__not_rebindable__":
		_note("That one can't be rebound.")
	else:
		_note("Already used by %s." % String(clash).replace("_", " ").capitalize())
	_capturing_action = &""
	_capturing_joypad = false
	_capture_button = null
	_refresh_rebind_labels()


func _cancel_capture() -> void:
	_capturing_action = &""
	_capturing_joypad = false
	_capture_button = null
	_note("Cancelled.")
	_refresh_rebind_labels()


## Re-derives every rebind button's caption from `SettingsService`. Called after any rebind or
## reset, so a row can never show a stale binding — including the row whose key was stolen by
## another action's rebind.
func _refresh_rebind_labels() -> void:
	var settings: Node = _settings()
	if settings == null:
		return
	for button: Button in _rebind_buttons(self):
		var action: StringName = button.get_meta(&"action")
		var joypad: bool = bool(button.get_meta(&"joypad"))
		button.text = String(settings.call(
			"keybind_label_joypad" if joypad else "keybind_label", action
		))


func _rebind_buttons(node: Node) -> Array[Button]:
	var found: Array[Button] = []
	if node is Button and (node as Button).has_meta(&"action"):
		found.append(node)
	for child: Node in node.get_children():
		found.append_array(_rebind_buttons(child))
	return found


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


# ── F-386: preview, save, cancel, restore defaults ───────────────────────────────────────────────


## Every control writes through here, which makes it the one place that has to notice something
## changed. The value applies immediately — `SettingsService` is holding the persistence, not the
## application — so the live preview the player is judging is untouched by the staging.
func _write(setter: String, value: Variant) -> void:
	var settings: Node = _settings()
	if settings == null:
		return
	settings.call(setter, value)
	_set_dirty(true)


## `_write()` for the one setter that takes no argument (`reset_keybinds`). Separate rather than a
## nullable parameter, because `null` is a value a bool setter could plausibly be handed by mistake.
func _write_no_arg(setter: String) -> void:
	var settings: Node = _settings()
	if settings == null:
		return
	settings.call(setter)
	_set_dirty(true)


## Hands the baseline back and drops the deferred write. Guarded on `_previewing` because both
## `menu_hidden()` and `_exit_tree()` call it on the way out and only the first one has work to do.
func _cancel_preview() -> void:
	if not _previewing:
		return
	_previewing = false
	var settings: Node = _settings()
	if settings == null or not settings.has_method("release_persistence"):
		return
	if not _baseline.is_empty():
		settings.call("apply_state", _baseline)
	settings.call("release_persistence", false)
	_baseline = {}
	_set_dirty(false)


## SAVE: the deferred write reaches disk, then the preview restarts against what was just saved —
## which is what makes backing out afterwards keep the save rather than undo it.
func _on_save() -> void:
	var settings: Node = _settings()
	if settings == null or not settings.has_method("release_persistence"):
		return
	if _previewing:
		settings.call("release_persistence", true)
	settings.call("hold_persistence")
	_baseline = settings.call("capture_state") as Dictionary
	_previewing = true
	_set_dirty(false)
	_note("Settings saved.")


## RESTORE DEFAULTS puts the factory values into the LIVE state without persisting them, so it is a
## proposal like any other: SAVE keeps it, backing out throws it away.
func _on_restore_defaults() -> void:
	var settings: Node = _settings()
	if settings == null or not settings.has_method("default_state"):
		return
	settings.call("apply_state", settings.call("default_state"))
	_refresh_controls()
	_set_dirty(true)
	_note("Defaults loaded — SAVE to keep them.")


## Records `control` as the view of `getter`, so `_refresh_controls()` can put a whole-state change
## back on screen without this file growing a member variable per row.
func _bind(control: Control, getter: String) -> void:
	_bound_controls.append({&"control": control, &"getter": getter})


## Re-derives every value control from `SettingsService`. Signals are blocked around the write so a
## refresh cannot re-fire the setters it is reflecting — which also swallows `value_changed`, hence
## the explicit `refresh_readout()` or the numbers would keep showing the pre-refresh values (F-385).
func _refresh_controls() -> void:
	var settings: Node = _settings()
	if settings == null:
		return
	for entry: Dictionary in _bound_controls:
		var control: Control = entry[&"control"]
		if not is_instance_valid(control):
			continue
		var value: Variant = settings.call(String(entry[&"getter"]))
		control.set_block_signals(true)
		if control is OptionButton:
			var dropdown: OptionButton = control
			dropdown.selected = clampi(int(value), 0, dropdown.item_count - 1)
		elif control is CheckBox:
			(control as CheckBox).button_pressed = bool(value)
		elif control is Range:
			(control as Range).value = float(value)
		control.set_block_signals(false)
		if control is FocusRingSlider:
			(control as FocusRingSlider).refresh_readout()
	_refresh_rebind_labels()


func _set_dirty(dirty: bool) -> void:
	_dirty = dirty


func has_unsaved_changes() -> bool:
	return _dirty


func is_previewing() -> bool:
	return _previewing


func _note(message: String) -> void:
	_status_label.text = message


func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _settings() -> Node:
	return get_node_or_null(^"/root/SettingsService")


func _god_mode() -> Node:
	return get_node_or_null(^"/root/GodModeService")


## Backing out means "leave it as I found it" (F-386) — the pop reaches `menu_hidden()`, which hands
## the baseline back. Nothing is reverted here directly, so the back link, Esc and any other pop of
## the stack all take exactly the same road out and none of them can forget.
func _go_back() -> void:
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null:
		stack.call("pop")
