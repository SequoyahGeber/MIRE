extends Control

## SettingsScreen — MENU-6: settings, in tabs (docs/MENU.md §7.1).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI. This file owns NO settings
## state whatsoever: every control is a thin view over `SettingsService`, which keeps owning the
## values, the `InputMap` writes and the persistence. The only state here is which tab is showing
## and which rebind capture is armed.
##
## ## Why a rebuild rather than a re-skin of `ui/menu/settings_menu.gd`
##
## The shipped panel puts graphics, five sliders, two checkboxes, twelve keyboard rebind rows and
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

const MireTheme := preload("res://ui/theme/mire_theme.gd")

## Tab order is deliberate: the things a player changes most often first, the long rebind tables
## last. GAME is present but currently empty — see the scope note above.
const TABS: Array[String] = ["DISPLAY", "AUDIO", "CONTROLS", "GAMEPAD", "ACCESSIBILITY"]

const GRAPHICS_PRESETS: Array[String] = ["LOW", "MEDIUM", "HIGH"]

var _tab_buttons: Array[Button] = []
var _pages: Array[Control] = []
var _page_host: Control
var _active_tab: int = 0
var _status_label: Label
var _back_button: Button
var _first_focus: Control

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
func menu_allows_cancel() -> bool:
	if _capturing_action != &"":
		_cancel_capture()
		return false
	return true


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
	page.add_child(scroll)

	_page_host = Control.new()
	_page_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_page_host)

	_pages.append(_build_display_page())
	_pages.append(_build_audio_page())
	_pages.append(_build_controls_page())
	_pages.append(_build_gamepad_page())
	_pages.append(_build_accessibility_page())
	for entry: Control in _pages:
		entry.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_page_host.add_child(entry)

	_status_label = MireTheme.paragraph("", MireTheme.CAPTION, MireTheme.MUTED)
	page.add_child(_status_label)


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


func _build_display_page() -> Control:
	var column: VBoxContainer = _page()
	var settings: Node = _settings()

	var preset: OptionButton = MireTheme.dropdown()
	for name_text: String in GRAPHICS_PRESETS:
		preset.add_item(name_text)
	if settings != null:
		preset.selected = clampi(int(settings.call("graphics_preset")), 0, GRAPHICS_PRESETS.size() - 1)
		preset.item_selected.connect(func(index: int) -> void:
			settings.call("set_graphics_preset", index)
			_note("Graphics set to %s." % GRAPHICS_PRESETS[index]))
	column.add_child(_row("Graphics quality", preset,
		"Lower presets cut shadows and draw distance first — the settings that cost the most on a weak machine."))

	if settings != null:
		var fov: HSlider = MireTheme.slider(
			float(settings.get("MIN_FOV")), float(settings.get("MAX_FOV")), 1.0
		)
		fov.value = float(settings.call("fov_degrees"))
		fov.value_changed.connect(func(value: float) -> void: settings.call("set_fov_degrees", value))
		column.add_child(_row("Field of view", fov))
	return column


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
		slider.value_changed.connect(func(value: float) -> void: settings.call(setter, value))
		column.add_child(_row(String(entry[0]), slider))
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
	sensitivity.value_changed.connect(func(value: float) -> void: settings.call("set_look_sensitivity", value))
	column.add_child(_row("Mouse sensitivity", sensitivity))

	var invert: CheckBox = MireTheme.toggle()
	invert.button_pressed = bool(settings.call("invert_y"))
	invert.toggled.connect(func(pressed: bool) -> void: settings.call("set_invert_y", pressed))
	column.add_child(_row("Invert vertical look", invert))

	column.add_child(MireTheme.separator())
	column.add_child(MireTheme.label("KEYBOARD", MireTheme.CAPTION, MireTheme.MUTED))
	for action_name: String in settings.call("rebindable_actions"):
		column.add_child(_rebind_row(StringName(action_name), false))

	var reset: Button = MireTheme.button("RESET KEYS TO DEFAULTS", func() -> void:
		settings.call("reset_keybinds")
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
		settings.call("set_gamepad_look_sensitivity", value))
	column.add_child(_row("Gamepad look sensitivity", sensitivity))

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
		settings.call("set_reduce_camera_motion", pressed)
		_note("Menu animation and camera motion %s." % ("off" if pressed else "on")))
	column.add_child(_row("Reduce motion", reduce,
		"Stops camera shake, menu fades and the title screen's drift. Everything cuts instantly instead."))
	return column


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


func _note(message: String) -> void:
	_status_label.text = message


func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _settings() -> Node:
	return get_node_or_null(^"/root/SettingsService")


func _go_back() -> void:
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null:
		stack.call("pop")
