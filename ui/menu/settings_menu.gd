extends CanvasLayer

## SettingsMenu — task 7.5's real graphics/audio/look/accessibility/keybind controls, built into
## the D-032 exclusivity/open-close/visual-frame shell task 6.10 shipped (D-110). Every control here
## is a thin view over `SettingsService`: this file owns no settings state of its own, only the
## widgets and the InputMap rebind-capture flow the service's `rebind_action()` needs a listener for.
## Register as autoload `SettingsMenu` → res://ui/menu/settings_menu.gd, AFTER `MainMenu` in
## `project.godot` (`MainMenu.request_open_settings()` opens this by node path).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI, the table's free last row.
## Opened from `MainMenu`; no keybind of its own yet since nothing inside it needs one.

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

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
}

var _root: Control
var _shade: ColorRect
var _center: CenterContainer
var _close_button: Button

var _graphics_option: OptionButton
var _master_slider: HSlider
var _music_slider: HSlider
var _sfx_slider: HSlider
var _sensitivity_slider: HSlider
var _fov_slider: HSlider
var _invert_checkbox: CheckBox
var _reduce_motion_checkbox: CheckBox
var _keybind_buttons: Dictionary = {}
var _status_label: Label

var _open: bool = false
var _restore_mouse_captured: bool = false
## Non-empty while waiting for the next physical key press to rebind this action (see `_input()`).
var _rebinding_action: StringName = &""
var _rebinding_button: Button


func _ready() -> void:
	layer = 58
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if get_viewport().is_input_handled():
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
		_refresh_from_settings()
	else:
		_rebinding_action = &""
		_rebinding_button = null
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

	var scroll := ScrollContainer.new()
	scroll.name = "SettingsScroll"
	scroll.custom_minimum_size = Vector2(0.0, 380.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	# 7.5's controls live here — each is a thin view over SettingsService, nothing else in this
	# file needs to change to add another row.
	var stack := VBoxContainer.new()
	stack.name = "SettingsStack"
	stack.add_theme_constant_override("separation", 10)
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(stack)

	_build_graphics_row(stack)
	_build_audio_rows(stack)
	_build_look_rows(stack)
	_build_accessibility_rows(stack)
	_build_keybind_rows(stack)

	outer.add_child(HSeparator.new())

	_close_button = Button.new()
	_close_button.text = "CLOSE"
	_close_button.add_theme_color_override("font_color", COLOUR_TEXT)
	_close_button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
	_close_button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	_close_button.add_theme_stylebox_override("pressed", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	_close_button.pressed.connect(request_close)
	outer.add_child(_close_button)

	var close_hint := Label.new()
	close_hint.text = "ESC  CLOSE"
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_hint.add_theme_font_size_override("font_size", 10)
	close_hint.add_theme_color_override("font_color", COLOUR_MUTED)
	outer.add_child(close_hint)


func _build_graphics_row(parent: VBoxContainer) -> void:
	_add_section_label(parent, "GRAPHICS")
	_graphics_option = OptionButton.new()
	_graphics_option.add_item("Low")
	_graphics_option.add_item("Medium")
	_graphics_option.add_item("High")
	_graphics_option.add_theme_color_override("font_color", COLOUR_TEXT)
	_graphics_option.item_selected.connect(_on_graphics_selected)
	parent.add_child(_graphics_option)


func _on_graphics_selected(index: int) -> void:
	_settings_call("set_graphics_preset", [index])


func _build_audio_rows(parent: VBoxContainer) -> void:
	_add_section_label(parent, "AUDIO")
	_master_slider = _build_slider_row(parent, "Master Volume", 0.0, 1.0, 0.01,
		func(v: float) -> void: _settings_call("set_master_volume", [v]))
	_music_slider = _build_slider_row(parent, "Music Volume", 0.0, 1.0, 0.01,
		func(v: float) -> void: _settings_call("set_music_volume", [v]))
	_sfx_slider = _build_slider_row(parent, "SFX Volume", 0.0, 1.0, 0.01,
		func(v: float) -> void: _settings_call("set_sfx_volume", [v]))


func _build_look_rows(parent: VBoxContainer) -> void:
	_add_section_label(parent, "LOOK")
	_sensitivity_slider = _build_slider_row(parent, "Mouse Sensitivity", 0.01, 1.0, 0.01,
		func(v: float) -> void: _settings_call("set_look_sensitivity", [v]))
	_fov_slider = _build_slider_row(parent, "Field of View", 60.0, 110.0, 1.0,
		func(v: float) -> void: _settings_call("set_fov_degrees", [v]))
	_invert_checkbox = CheckBox.new()
	_invert_checkbox.text = "Invert Look Y"
	_invert_checkbox.add_theme_color_override("font_color", COLOUR_TEXT)
	_invert_checkbox.toggled.connect(func(pressed: bool) -> void:
		_settings_call("set_invert_y", [pressed]))
	parent.add_child(_invert_checkbox)


func _build_accessibility_rows(parent: VBoxContainer) -> void:
	_add_section_label(parent, "ACCESSIBILITY")
	_reduce_motion_checkbox = CheckBox.new()
	_reduce_motion_checkbox.text = "Reduce Camera Motion"
	_reduce_motion_checkbox.add_theme_color_override("font_color", COLOUR_TEXT)
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
		button.pressed.connect(_start_rebind.bind(action, button))
		row.add_child(button)

		_keybind_buttons[action] = button
		parent.add_child(row)

	var reset_button := Button.new()
	reset_button.text = "RESET KEYBINDS"
	reset_button.add_theme_color_override("font_color", COLOUR_TEXT)
	reset_button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
	reset_button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	reset_button.pressed.connect(func() -> void:
		_settings_call("reset_keybinds", [])
		_refresh_from_settings())
	parent.add_child(reset_button)

	_status_label = Label.new()
	_status_label.name = "KeybindStatus"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	parent.add_child(_status_label)


func _start_rebind(action: StringName, button: Button) -> void:
	if _rebinding_action != &"":
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
			_set_status("Bound %s." % String(ACTION_LABELS.get(action, String(action))))
	else:
		_set_status("")
	button.text = String(settings.call("keybind_label", action))


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
	_set_slider(_fov_slider, float(settings.call("fov_degrees")))

	_invert_checkbox.set_block_signals(true)
	_invert_checkbox.button_pressed = bool(settings.call("invert_y"))
	_invert_checkbox.set_block_signals(false)

	_reduce_motion_checkbox.set_block_signals(true)
	_reduce_motion_checkbox.button_pressed = bool(settings.call("reduce_camera_motion"))
	_reduce_motion_checkbox.set_block_signals(false)

	for action: StringName in _keybind_buttons.keys():
		(_keybind_buttons[action] as Button).text = String(settings.call("keybind_label", action))
	_set_status("")


func _set_slider(slider: HSlider, value: float) -> void:
	slider.set_block_signals(true)
	slider.value = value
	slider.set_block_signals(false)


func _add_section_label(parent: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", COLOUR_ACCENT)
	parent.add_child(label)


func _build_slider_row(parent: VBoxContainer, label_text: String, min_v: float, max_v: float,
		step: float, on_change: Callable) -> HSlider:
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", COLOUR_MUTED)
	parent.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value_changed.connect(on_change)
	parent.add_child(slider)
	return slider


func _settings_node() -> Node:
	return get_node_or_null(^"/root/SettingsService")


func _settings_call(method: StringName, args: Array) -> void:
	var settings: Node = _settings_node()
	if settings != null:
		settings.callv(method, args)


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
