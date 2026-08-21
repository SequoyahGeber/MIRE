extends CanvasLayer

## SettingsMenu — task 7.5's real graphics/audio/look/accessibility/keybind controls (task 7.6 added
## gamepad look sensitivity and a gamepad-button rebind section), built into the D-032
## exclusivity/open-close/visual-frame shell task 6.10 shipped (D-110). Every control here is a thin
## view over `SettingsService`: this file owns no settings state of its own, only the widgets and the
## two InputMap rebind-capture flows the service's `rebind_action()`/`rebind_action_joypad()` need a
## listener for.
## Register as autoload `SettingsMenu` → res://ui/menu/settings_menu.gd, AFTER `MainMenu` in
## `project.godot` (`MainMenu.request_open_settings()` opens this by node path).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI, the table's free last row.
## Opened from `MainMenu`; no keybind of its own yet since nothing inside it needs one.
##
## ## Preview, then commit (F-386)
##
## Opening this panel starts a `SettingsService` preview: every control still applies live, because
## FOV and sensitivity are settings you have to see to judge, but nothing reaches disk until SAVE.
## CLOSE and Esc both hand the whole opening state back and drop the write — which is what makes an
## accidentally-dragged handle recoverable, together with F-385's numeric readouts. `set_open(false)`
## is the single close path (`MenuStack.close_blocking_panel()` calls exactly that, F-384), so the
## revert cannot be bypassed by whichever way the player leaves.

const FocusRingSlider := preload("res://ui/menu/focus_ring_slider.gd")

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

## F-387: the scroll viewport was a fixed 380 px, which is both too short to be worth scrolling on a
## 1080p screen and — with the title, footer and margins on top — taller than the window on nothing.
## Sized from the window instead: a fraction of its height, capped so the panel as a whole always
## fits, floored so a tiny window still shows more than one row.
const SCROLL_HEIGHT_FRACTION: float = 0.62
## Title + separator + footer buttons + hint + the panel's own margins, in pixels. The height the
## scroll viewport must leave behind for the panel to fit the window.
const SCROLL_CHROME_HEIGHT: float = 210.0
const SCROLL_MIN_HEIGHT: float = 180.0

const COLOUR_SCREEN_SHADE := Color(0.018, 0.035, 0.028, 0.78)
const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_FIELD := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_ACCENT := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)

const ACTION_LABELS: Dictionary = {
	&"move_forward": "Move Forward",
	&"move_back": "Move Back",
	&"move_left": "Move Left",
	&"move_right": "Move Right",
	&"jump": "Jump",
	&"sprint": "Sprint",
	&"interact": "Interact",
	&"inventory": "Inventory",
	&"build": "Build",
	&"dodge": "Dodge",
	&"eat": "Eat",
	&"build_rotate": "Rotate Piece",
	&"hotbar_prev": "Hotbar Previous",
	&"hotbar_next": "Hotbar Next",
}

var _root: Control
var _shade: ColorRect
var _center: CenterContainer
var _scroll: ScrollContainer
var _close_button: Button
var _save_button: Button
var _restore_defaults_button: Button
var _unsaved_label: Label

var _graphics_option: OptionButton
var _master_slider: HSlider
var _music_slider: HSlider
var _sfx_slider: HSlider
var _sensitivity_slider: HSlider
var _fov_slider: HSlider
var _invert_checkbox: CheckBox
var _reduce_motion_checkbox: CheckBox
var _gamepad_sensitivity_slider: HSlider
var _keybind_buttons: Dictionary = {}
var _reset_keybind_button: Button
var _gamepad_keybind_buttons: Dictionary = {}
var _status_label: Label

var _open: bool = false
var _restore_mouse_captured: bool = false
## F-386: every persisted value as it stood when this panel opened, from
## `SettingsService.capture_state()`. Handed back verbatim by CLOSE/Esc, and re-taken by SAVE so a
## second CLOSE after a save reverts to what was saved rather than to what was on screen an hour ago.
var _baseline: Dictionary = {}
## True once anything in the panel has written a setting since the last open or save. Drives the
## "unsaved changes" line — a confirm step the player cannot see the state of is not a confirm step.
var _dirty: bool = false
## Non-empty while waiting for the next physical key press to rebind this action (see `_input()`).
var _rebinding_action: StringName = &""
var _rebinding_button: Button
## Non-empty while waiting for the next gamepad button press to rebind this action (task 7.6) — kept
## separate from `_rebinding_action` so a keyboard-row capture and a gamepad-row capture can never be
## started at the same time by mistake (`_start_rebind`/`_start_rebind_joypad` each refuse to start a
## capture while the OTHER kind is already waiting, see their own guard).
var _rebinding_joypad_action: StringName = &""
var _rebinding_joypad_button: Button


func _ready() -> void:
	layer = 58
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if get_viewport().is_input_handled():
		return
	if _rebinding_joypad_action != &"" and event is InputEventJoypadButton \
			and (event as InputEventJoypadButton).pressed:
		get_viewport().set_input_as_handled()
		_finish_rebind_joypad(event as InputEventJoypadButton)
		return
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.is_echo():
		return
	if _rebinding_action != &"":
		get_viewport().set_input_as_handled()
		_finish_rebind(key)
		return
	if _rebinding_joypad_action != &"" and key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_cancel_rebind_joypad()
		return
	if key.keycode == KEY_ESCAPE:
		set_open(false)
		get_viewport().set_input_as_handled()


func set_open(open: bool) -> void:
	if open == _open:
		return
	if open and _other_blocking_ui_open():
		return
	_open = open
	_shade.visible = open
	_center.visible = open
	if open:
		add_to_group(BLOCKING_UI_GROUP)
		_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_begin_preview()
		_refresh_from_settings()
		_refresh_scroll_height()
		_graphics_option.grab_focus()
	else:
		# F-386: closing is CANCEL. Every route out of this panel lands here — the CLOSE button, the
		# Esc branch in `_input()`, and `MenuStack.close_blocking_panel()`'s `set_open(false)` (F-384)
		# — so there is exactly one place that has to remember to put the player's settings back, and
		# no way to leave by a door that forgets. SAVE reaches this too, having already committed and
		# re-taken the baseline, which makes the revert below a no-op rather than an undo of the save.
		_cancel_preview()
		_rebinding_action = &""
		_rebinding_button = null
		_rebinding_joypad_action = &""
		_rebinding_joypad_button = null
		remove_from_group(BLOCKING_UI_GROUP)
		_root.release_focus()
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_open() -> bool:
	return _open


func request_close() -> void:
	set_open(false)


func _other_blocking_ui_open() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node != self:
			return true
	return false


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "SettingsMenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "SettingsShade"
	_shade.color = COLOUR_SCREEN_SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_center = CenterContainer.new()
	_center.name = "SettingsCenter"
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_center.visible = false
	_root.add_child(_center)

	var panel := PanelContainer.new()
	panel.name = "SettingsPanel"
	panel.custom_minimum_size = Vector2(460.0, 0.0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	_center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var outer := VBoxContainer.new()
	outer.name = "SettingsOuterStack"
	outer.add_theme_constant_override("separation", 10)
	margin.add_child(outer)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOUR_TEXT)
	outer.add_child(title)

	_scroll = ScrollContainer.new()
	_scroll.name = "SettingsScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# F-387: a gamepad walking the focus chain past the fold has to bring the viewport with it, or
	# the rows below are unreachable on a controller even once the wheel works on mouse.
	_scroll.follow_focus = true
	outer.add_child(_scroll)
	_refresh_scroll_height()
	get_viewport().size_changed.connect(_refresh_scroll_height)

	# 7.5's controls live here — each is a thin view over SettingsService, nothing else in this
	# file needs to change to add another row.
	var stack := VBoxContainer.new()
	stack.name = "SettingsStack"
	stack.add_theme_constant_override("separation", 10)
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(stack)

	_build_graphics_row(stack)
	_build_audio_rows(stack)
	_build_look_rows(stack)
	_build_accessibility_rows(stack)
	_build_keybind_rows(stack)
	_build_gamepad_bind_rows(stack)

	outer.add_child(HSeparator.new())

	# F-386's footer. It sits OUTSIDE the scroll viewport on purpose: a Save button you have to
	# scroll to find is a Save button players report as missing, which is how this panel got here.
	_unsaved_label = Label.new()
	_unsaved_label.name = "UnsavedNotice"
	_unsaved_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_unsaved_label.add_theme_font_size_override("font_size", 11)
	_unsaved_label.add_theme_color_override("font_color", COLOUR_ACCENT)
	outer.add_child(_unsaved_label)

	var actions := HBoxContainer.new()
	actions.name = "SettingsActions"
	actions.add_theme_constant_override("separation", 8)
	outer.add_child(actions)

	_restore_defaults_button = _footer_button("RESTORE DEFAULTS", _on_restore_defaults)
	_restore_defaults_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(_restore_defaults_button)

	_save_button = _footer_button("SAVE", _on_save)
	_save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(_save_button)

	# Still literally CLOSE, still the last entry in the focus chain: with SAVE beside it, "close"
	# means "leave it as I found it", which is exactly the way out F-386 says the panel was missing.
	_close_button = _footer_button("CLOSE", request_close)
	outer.add_child(_close_button)

	var close_hint := Label.new()
	close_hint.text = "ESC  CLOSE WITHOUT SAVING"
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_hint.add_theme_font_size_override("font_size", 10)
	close_hint.add_theme_color_override("font_color", COLOUR_MUTED)
	outer.add_child(close_hint)

	# F-209: gamepad/keyboard focus chain down the visible order. Sliders/OptionButton/CheckBox
	# already answer ui_left/ui_right/ui_accept once focused (Godot's own Range/Button gui_input) —
	# only the chain, initial focus (set_open() above) and a visible ring on every control were
	# missing. HSlider draws no built-in focus stylebox (Slider's theme has no "focus" item, unlike
	# Button/OptionButton/CheckBox) — F-215 gives it one via FocusRingSlider's own _draw() override.
	var chain: Array = [_graphics_option, _master_slider, _music_slider, _sfx_slider,
		_sensitivity_slider, _gamepad_sensitivity_slider, _fov_slider, _invert_checkbox,
		_reduce_motion_checkbox]
	chain.append_array(_keybind_buttons.values())
	chain.append(_reset_keybind_button)
	chain.append_array(_gamepad_keybind_buttons.values())
	chain.append(_restore_defaults_button)
	chain.append(_save_button)
	chain.append(_close_button)
	_wire_vertical_chain(chain)


func _build_graphics_row(parent: VBoxContainer) -> void:
	_add_section_label(parent, "GRAPHICS")
	_graphics_option = OptionButton.new()
	_graphics_option.add_item("Low")
	_graphics_option.add_item("Medium")
	_graphics_option.add_item("High")
	_graphics_option.add_theme_color_override("font_color", COLOUR_TEXT)
	_graphics_option.add_theme_stylebox_override("focus", _focus_style())
	_graphics_option.item_selected.connect(_on_graphics_selected)
	parent.add_child(_graphics_option)


func _on_graphics_selected(index: int) -> void:
	_settings_call("set_graphics_preset", [index])


func _build_audio_rows(parent: VBoxContainer) -> void:
	_add_section_label(parent, "AUDIO")
	_master_slider = _build_slider_row(parent, "Master Volume", 0.0, 1.0, 0.01,
		FocusRingSlider.Readout.PERCENT,
		func(v: float) -> void: _settings_call("set_master_volume", [v]))
	_music_slider = _build_slider_row(parent, "Music Volume", 0.0, 1.0, 0.01,
		FocusRingSlider.Readout.PERCENT,
		func(v: float) -> void: _settings_call("set_music_volume", [v]))
	_sfx_slider = _build_slider_row(parent, "SFX Volume", 0.0, 1.0, 0.01,
		FocusRingSlider.Readout.PERCENT,
		func(v: float) -> void: _settings_call("set_sfx_volume", [v]))


func _build_look_rows(parent: VBoxContainer) -> void:
	_add_section_label(parent, "LOOK")
	_sensitivity_slider = _build_slider_row(parent, "Mouse Sensitivity", 0.01, 1.0, 0.01,
		FocusRingSlider.Readout.DECIMAL2,
		func(v: float) -> void: _settings_call("set_look_sensitivity", [v]))
	_gamepad_sensitivity_slider = _build_slider_row(parent, "Gamepad Look Sensitivity", 30.0, 720.0, 5.0,
		FocusRingSlider.Readout.DEGREES_PER_SECOND,
		func(v: float) -> void: _settings_call("set_gamepad_look_sensitivity", [v]))
	_fov_slider = _build_slider_row(parent, "Field of View", 60.0, 110.0, 1.0,
		FocusRingSlider.Readout.DEGREES,
		func(v: float) -> void: _settings_call("set_fov_degrees", [v]))
	_invert_checkbox = CheckBox.new()
	_invert_checkbox.text = "Invert Look Y"
	_invert_checkbox.add_theme_color_override("font_color", COLOUR_TEXT)
	_invert_checkbox.add_theme_stylebox_override("focus", _focus_style())
	_invert_checkbox.toggled.connect(func(pressed: bool) -> void:
		_settings_call("set_invert_y", [pressed]))
	parent.add_child(_invert_checkbox)


func _build_accessibility_rows(parent: VBoxContainer) -> void:
	_add_section_label(parent, "ACCESSIBILITY")
	_reduce_motion_checkbox = CheckBox.new()
	_reduce_motion_checkbox.text = "Reduce Camera Motion"
	_reduce_motion_checkbox.add_theme_color_override("font_color", COLOUR_TEXT)
	_reduce_motion_checkbox.add_theme_stylebox_override("focus", _focus_style())
	_reduce_motion_checkbox.toggled.connect(func(pressed: bool) -> void:
		_settings_call("set_reduce_camera_motion", [pressed]))
	parent.add_child(_reduce_motion_checkbox)


func _build_keybind_rows(parent: VBoxContainer) -> void:
	_add_section_label(parent, "KEYBINDS")
	_keybind_buttons.clear()
	var settings: Node = _settings_node()
	var actions: PackedStringArray = PackedStringArray()
	if settings != null and settings.has_method("rebindable_actions"):
		actions = settings.call("rebindable_actions") as PackedStringArray

	for action_name: String in actions:
		var action := StringName(action_name)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var label := Label.new()
		label.text = String(ACTION_LABELS.get(action, action_name.capitalize()))
		label.custom_minimum_size = Vector2(150.0, 0.0)
		label.add_theme_color_override("font_color", COLOUR_TEXT)
		row.add_child(label)

		var button := Button.new()
		button.custom_minimum_size = Vector2(130.0, 0.0)
		button.text = String(settings.call("keybind_label", action)) if settings != null else "—"
		button.add_theme_color_override("font_color", COLOUR_TEXT)
		button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
		button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
		button.add_theme_stylebox_override("focus", _focus_style())
		button.pressed.connect(_start_rebind.bind(action, button))
		row.add_child(button)

		_keybind_buttons[action] = button
		parent.add_child(row)

	_reset_keybind_button = Button.new()
	_reset_keybind_button.text = "RESET KEYBINDS"
	_reset_keybind_button.add_theme_color_override("font_color", COLOUR_TEXT)
	_reset_keybind_button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
	_reset_keybind_button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	_reset_keybind_button.add_theme_stylebox_override("focus", _focus_style())
	_reset_keybind_button.pressed.connect(func() -> void:
		_settings_call("reset_keybinds", [])
		_refresh_from_settings())
	parent.add_child(_reset_keybind_button)

	_status_label = Label.new()
	_status_label.name = "KeybindStatus"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	parent.add_child(_status_label)


func _build_gamepad_bind_rows(parent: VBoxContainer) -> void:
	_add_section_label(parent, "GAMEPAD BINDS")
	_gamepad_keybind_buttons.clear()
	var settings: Node = _settings_node()
	var actions: PackedStringArray = PackedStringArray()
	if settings != null and settings.has_method("rebindable_actions_joypad"):
		actions = settings.call("rebindable_actions_joypad") as PackedStringArray

	for action_name: String in actions:
		var action := StringName(action_name)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var label := Label.new()
		label.text = String(ACTION_LABELS.get(action, action_name.capitalize()))
		label.custom_minimum_size = Vector2(150.0, 0.0)
		label.add_theme_color_override("font_color", COLOUR_TEXT)
		row.add_child(label)

		var button := Button.new()
		button.custom_minimum_size = Vector2(130.0, 0.0)
		button.text = String(settings.call("keybind_label_joypad", action)) if settings != null else "—"
		button.add_theme_color_override("font_color", COLOUR_TEXT)
		button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
		button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
		button.add_theme_stylebox_override("focus", _focus_style())
		button.pressed.connect(_start_rebind_joypad.bind(action, button))
		row.add_child(button)

		_gamepad_keybind_buttons[action] = button
		parent.add_child(row)


func _start_rebind(action: StringName, button: Button) -> void:
	if _rebinding_action != &"" or _rebinding_joypad_action != &"":
		return
	_rebinding_action = action
	_rebinding_button = button
	button.text = "PRESS A KEY…"
	_set_status("Press a key to bind %s, or Esc to cancel." %
		String(ACTION_LABELS.get(action, String(action))))


func _finish_rebind(key: InputEventKey) -> void:
	var action := _rebinding_action
	var button := _rebinding_button
	_rebinding_action = &""
	_rebinding_button = null
	var settings: Node = _settings_node()
	if settings == null or button == null:
		return
	if key.physical_keycode != KEY_ESCAPE:
		var conflict: StringName = StringName(settings.call("rebind_action", action, key))
		if conflict != &"":
			_set_status("Already bound to %s." % String(ACTION_LABELS.get(conflict, String(conflict))))
		else:
			# F-386: a rebind stages like every other change — applied to the InputMap now so the
			# player can try it, persisted only by SAVE, undone by CLOSE.
			_set_dirty(true)
			_set_status("Bound %s." % String(ACTION_LABELS.get(action, String(action))))
	else:
		_set_status("")
	button.text = String(settings.call("keybind_label", action))


func _start_rebind_joypad(action: StringName, button: Button) -> void:
	if _rebinding_action != &"" or _rebinding_joypad_action != &"":
		return
	_rebinding_joypad_action = action
	_rebinding_joypad_button = button
	button.text = "PRESS A BUTTON…"
	_set_status("Press a gamepad button to bind %s, or Esc to cancel." %
		String(ACTION_LABELS.get(action, String(action))))


func _finish_rebind_joypad(joy_event: InputEventJoypadButton) -> void:
	var action := _rebinding_joypad_action
	var button := _rebinding_joypad_button
	_rebinding_joypad_action = &""
	_rebinding_joypad_button = null
	var settings: Node = _settings_node()
	if settings == null or button == null:
		return
	var conflict: StringName = StringName(settings.call("rebind_action_joypad", action, joy_event))
	if conflict != &"":
		_set_status("Already bound to %s." % String(ACTION_LABELS.get(conflict, String(conflict))))
	else:
		_set_dirty(true)
		_set_status("Bound %s." % String(ACTION_LABELS.get(action, String(action))))
	button.text = String(settings.call("keybind_label_joypad", action))


func _cancel_rebind_joypad() -> void:
	var button := _rebinding_joypad_button
	var action := _rebinding_joypad_action
	_rebinding_joypad_action = &""
	_rebinding_joypad_button = null
	var settings: Node = _settings_node()
	if settings == null or button == null:
		return
	_set_status("")
	button.text = String(settings.call("keybind_label_joypad", action))


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _refresh_from_settings() -> void:
	var settings: Node = _settings_node()
	if settings == null:
		return

	_graphics_option.set_block_signals(true)
	_graphics_option.selected = int(settings.call("graphics_preset"))
	_graphics_option.set_block_signals(false)

	_set_slider(_master_slider, float(settings.call("master_volume")))
	_set_slider(_music_slider, float(settings.call("music_volume")))
	_set_slider(_sfx_slider, float(settings.call("sfx_volume")))
	_set_slider(_sensitivity_slider, float(settings.call("look_sensitivity")))
	_set_slider(_gamepad_sensitivity_slider, float(settings.call("gamepad_look_sensitivity")))
	_set_slider(_fov_slider, float(settings.call("fov_degrees")))

	_invert_checkbox.set_block_signals(true)
	_invert_checkbox.button_pressed = bool(settings.call("invert_y"))
	_invert_checkbox.set_block_signals(false)

	_reduce_motion_checkbox.set_block_signals(true)
	_reduce_motion_checkbox.button_pressed = bool(settings.call("reduce_camera_motion"))
	_reduce_motion_checkbox.set_block_signals(false)

	for action: StringName in _keybind_buttons.keys():
		(_keybind_buttons[action] as Button).text = String(settings.call("keybind_label", action))
	for action: StringName in _gamepad_keybind_buttons.keys():
		(_gamepad_keybind_buttons[action] as Button).text = \
			String(settings.call("keybind_label_joypad", action))
	_set_status("")


## Signals are blocked so re-showing the panel does not fire every setter again — which also swallows
## `value_changed`, so the readout has to be re-derived by hand or it would keep showing the last
## value the player dragged to rather than the one just loaded (F-385).
func _set_slider(slider: HSlider, value: float) -> void:
	slider.set_block_signals(true)
	slider.value = value
	slider.set_block_signals(false)
	if slider is FocusRingSlider:
		(slider as FocusRingSlider).refresh_readout()


func _add_section_label(parent: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", COLOUR_ACCENT)
	parent.add_child(label)


## One slider row: its name on the left, its NUMBER on the right, the handle underneath.
##
## F-385: the readout half is the fix. All six sliders in this panel came through here, and this
## helper put a label on the left and nothing at all on the right — so a 60-110 FOV slider in steps
## of 1 could be dragged with no way to read where it now was, and no way to know where it had been.
## The `Label` is styled here (this panel has its own palette, predating `MireTheme`) but formatted
## and width-pinned by `FocusRingSlider.bind_readout()`, which `ui/frontend/settings_screen.gd` calls
## too — the format table and the "fixed width so the row does not reflow mid-drag" rule live in one
## place for both settings surfaces rather than being written twice and drifting.
func _build_slider_row(parent: VBoxContainer, label_text: String, min_v: float, max_v: float,
		step: float, readout: int, on_change: Callable) -> HSlider:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	parent.add_child(header)

	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", COLOUR_MUTED)
	header.add_child(label)

	var value_label := Label.new()
	value_label.add_theme_font_size_override("font_size", 12)
	value_label.add_theme_color_override("font_color", COLOUR_TEXT)
	header.add_child(value_label)

	var slider := FocusRingSlider.new()
	slider.focus_ring_style = _focus_style()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.bind_readout(value_label, readout)
	slider.value_changed.connect(on_change)
	parent.add_child(slider)
	return slider


## Sizes the scroll viewport to the window (F-387). The 380 px it was hard-coded to showed barely two
## sections of six on any screen, and — with the title, footer and margins on top — had no relation
## to whether the panel as a whole fitted. Re-run on every window resize, so a player who alt-tabs to
## a different resolution or docks a Steam Deck does not get a panel sized for the old one.
func _refresh_scroll_height() -> void:
	if _scroll == null:
		return
	var window_height: float = float(get_viewport().get_visible_rect().size.y)
	var budget: float = minf(
		window_height * SCROLL_HEIGHT_FRACTION, window_height - SCROLL_CHROME_HEIGHT)
	_scroll.custom_minimum_size = Vector2(0.0, maxf(budget, SCROLL_MIN_HEIGHT))


func _footer_button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_color_override("font_color", COLOUR_TEXT)
	button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
	button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	button.add_theme_stylebox_override("pressed", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	button.add_theme_stylebox_override("focus", _focus_style())
	button.pressed.connect(on_pressed)
	return button


# ── F-386: preview, save, cancel, restore defaults ───────────────────────────────────────────────


## Takes the baseline and asks `SettingsService` to stop writing. Every control keeps applying live
## from here — that is the point — but nothing is persisted until `_on_save()`.
func _begin_preview() -> void:
	var settings: Node = _settings_node()
	if settings == null or not settings.has_method("hold_persistence"):
		return
	settings.call("hold_persistence")
	_baseline = settings.call("capture_state") as Dictionary
	_set_dirty(false)


## Hands the baseline back and drops the deferred write. Safe to call when nothing was previewing
## (`_baseline` empty) and safe to call twice — `release_persistence` floors its own counter.
func _cancel_preview() -> void:
	var settings: Node = _settings_node()
	if settings == null or not settings.has_method("release_persistence"):
		return
	if not _baseline.is_empty():
		settings.call("apply_state", _baseline)
	settings.call("release_persistence", false)
	_baseline = {}
	_set_dirty(false)


## SAVE: the deferred write goes to disk, then the preview restarts against the state just saved.
## Re-taking the baseline is what makes CLOSE-after-SAVE keep the save instead of undoing it.
func _on_save() -> void:
	var settings: Node = _settings_node()
	if settings == null or not settings.has_method("release_persistence"):
		return
	settings.call("release_persistence", true)
	settings.call("hold_persistence")
	_baseline = settings.call("capture_state") as Dictionary
	_set_dirty(false)
	_set_status("Settings saved.")


## RESTORE DEFAULTS loads the factory values into the LIVE state without persisting them (F-386), so
## it is a proposal like any other drag of a handle: SAVE keeps it, CLOSE throws it away.
func _on_restore_defaults() -> void:
	var settings: Node = _settings_node()
	if settings == null or not settings.has_method("default_state"):
		return
	settings.call("apply_state", settings.call("default_state"))
	_refresh_from_settings()
	_set_dirty(true)
	_set_status("Defaults loaded — SAVE to keep them.")


func _set_dirty(dirty: bool) -> void:
	_dirty = dirty
	if _unsaved_label != null:
		_unsaved_label.text = "Unsaved changes" if dirty else ""


func has_unsaved_changes() -> bool:
	return _dirty


func _settings_node() -> Node:
	return get_node_or_null(^"/root/SettingsService")


## Every control in this panel writes through here, which makes it the one place that has to notice
## something changed (F-386). The value still applies immediately — `SettingsService` is holding the
## persistence, not the application — so the preview the player is judging is unaffected.
func _settings_call(method: StringName, args: Array) -> void:
	var settings: Node = _settings_node()
	if settings != null:
		settings.callv(method, args)
		if _open:
			_set_dirty(true)


func _wire_vertical_chain(controls: Array) -> void:
	var count: int = controls.size()
	for i: int in count:
		var current: Control = controls[i]
		var prev: Control = controls[(i - 1 + count) % count]
		var next: Control = controls[(i + 1) % count]
		current.focus_neighbor_top = current.get_path_to(prev)
		current.focus_neighbor_bottom = current.get_path_to(next)


## Visible focus ring (F-209) — see main_menu.gd's copy of this helper for why it is a
## transparent-fill outline stylebox rather than a themed default.
func _focus_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.draw_center = false
	style.border_color = COLOUR_ACCENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	return style


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	return style


func _field_style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	return style
