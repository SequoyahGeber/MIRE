extends CanvasLayer

## SettingsMenu — the settings panel SHELL: the D-032 exclusivity, close behaviour and visual frame
## every future settings control needs, with the actual knobs left for task 7.5 to fill in.
## Register as autoload `SettingsMenu` → res://ui/menu/settings_menu.gd, AFTER `MainMenu` in
## `project.godot` (`MainMenu.request_open_settings()` opens this by node path).
##
## Deliberately holds no real settings. `autoload/graphics_quality.gd`'s own header comment already
## reserves "Task 7.5's settings menu gets three buttons now" for graphics, and `docs/SPECS.md`'s
## M7 look-ahead names 7.5 as the task that ships `user://settings.cfg` persistence and a
## `SettingsService` autoload for graphics/audio/sensitivity/keybinds/FOV/accessibility. Building
## any of those controls here would be 6.10 designing 6.10's own content ahead of 7.5's own task —
## the same trap task 6.1 already named for `game_state.gd` (D-089) and task 6.7 named again for
## `defeat_service.gd` (D-109). What 6.10 owns is the door into the panel and the panel's frame;
## 7.5 opens this exact file and adds rows to `stack` in `_build_ui()`, nothing else needs to change.
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

var _root: Control
var _shade: ColorRect
var _center: CenterContainer
var _close_button: Button

var _open: bool = false
var _restore_mouse_captured: bool = false


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
	else:
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
	panel.custom_minimum_size = Vector2(420.0, 0.0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	_center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	# 7.5 adds its rows to this stack — quality/fps/sensitivity/etc, each its own row like
	# lobby_menu.gd's idle/lobby boxes — leaving everything above and below untouched.
	var stack := VBoxContainer.new()
	stack.name = "SettingsStack"
	stack.add_theme_constant_override("separation", 10)
	margin.add_child(stack)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOUR_TEXT)
	stack.add_child(title)

	var placeholder := Label.new()
	placeholder.name = "Placeholder"
	placeholder.text = "Graphics, audio and sensitivity controls land in task 7.5."
	placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	placeholder.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	placeholder.add_theme_font_size_override("font_size", 12)
	placeholder.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(placeholder)

	stack.add_child(HSeparator.new())

	_close_button = Button.new()
	_close_button.text = "CLOSE"
	_close_button.add_theme_color_override("font_color", COLOUR_TEXT)
	_close_button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
	_close_button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	_close_button.add_theme_stylebox_override("pressed", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	_close_button.pressed.connect(request_close)
	stack.add_child(_close_button)

	var close_hint := Label.new()
	close_hint.text = "ESC  CLOSE"
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_hint.add_theme_font_size_override("font_size", 10)
	close_hint.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(close_hint)


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
