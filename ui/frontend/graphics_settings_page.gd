class_name GraphicsSettingsPage
extends VBoxContainer

## Complete DISPLAY settings page. State remains in SettingsService; this is only its view.
## NETWORK AUTHORITY: none — every value affects this peer's presentation only.

const MireTheme := preload("res://ui/theme/mire_theme.gd")
const FocusRingSlider := preload("res://ui/menu/focus_ring_slider.gd")

signal setting_requested(setter: String, value: Variant)
signal note_requested(message: String)
## The player asked to measure this machine rather than guess at it (F-453). The page does not open
## the benchmark itself — it runs in its own world and the settings screen has to commit and stop
## previewing before that can happen, which is the screen's business, not this page's.
signal benchmark_requested()

const GRAPHICS_PRESETS: Array[String] = ["LOW", "MEDIUM", "HIGH"]
const SSAO_MODES: Array[String] = ["AUTO (PRESET)", "OFF", "ON"]
const READOUT_WIDTH: float = 96.0

var _settings: Node
var _controls: Array[Dictionary] = []
var _resolution_dropdown: OptionButton
## False in-run: the benchmark generates its own world and cannot run over a live session (D-192),
## so the row is absent rather than present-and-refusing. A button that explains why it will not
## work is a worse answer than no button.
var _allow_benchmark: bool = true


func _init(settings: Node, allow_benchmark: bool = true) -> void:
	_settings = settings
	_allow_benchmark = allow_benchmark
	add_theme_constant_override("separation", MireTheme.GRID)
	_build()
	if _settings != null and _settings.has_signal(&"settings_changed"):
		_settings.connect(&"settings_changed", refresh)


func refresh() -> void:
	if _settings == null:
		return
	for entry: Dictionary in _controls:
		var control: Control = entry[&"control"]
		var value: Variant = _settings.call(String(entry[&"getter"]))
		control.set_block_signals(true)
		if control is OptionButton:
			var selected: int = int(value) + int(entry.get(&"offset", 0))
			if entry.has(&"values"):
				selected = (entry[&"values"] as PackedInt32Array).find(int(value))
			(control as OptionButton).selected = maxi(selected, 0)
		elif control is CheckBox:
			(control as CheckBox).button_pressed = bool(value)
		elif control is Range:
			(control as Range).value = float(value)
		control.set_block_signals(false)
		if control is FocusRingSlider:
			(control as FocusRingSlider).refresh_readout()


func _build() -> void:
	if _settings == null:
		return
	add_child(_heading("DISPLAY"))
	add_child(_dropdown_row("Window mode", _settings.get("WINDOW_MODES"),
		"window_mode", "set_window_mode"))
	var resolutions: Array[String] = []
	for size: Vector2i in _settings.get("RESOLUTIONS"):
		resolutions.append("%d × %d" % [size.x, size.y])
	var resolution_row: Control = _dropdown_row(
		"Resolution", resolutions, "resolution_index", "set_resolution_index",
		"Window size in windowed mode. In fullscreen, sets the 3D render resolution for performance; UI stays native and sharp.")
	_resolution_dropdown = (_controls.back()[&"control"] as OptionButton)
	add_child(resolution_row)
	add_child(_toggle_row("VSync", "vsync_enabled", "set_vsync_enabled",
		"Prevents tearing. Disable only for the lowest possible input latency."))
	var cap_labels: Array[String] = []
	for cap: int in _settings.get("FPS_CAPS"):
		cap_labels.append("UNCAPPED" if cap == 0 else "%d FPS" % cap)
	add_child(_value_dropdown_row("Frame-rate limit", cap_labels, _settings.get("FPS_CAPS"),
		"fps_cap", "set_fps_cap"))

	add_child(MireTheme.separator())
	add_child(_heading("QUALITY"))
	add_child(_dropdown_row("Graphics quality", GRAPHICS_PRESETS,
		"graphics_preset", "set_graphics_preset",
		"Presets scale shadows, effects, foliage, draw distance, LOD and render resolution."))
	add_child(_dropdown_row("Anti-aliasing", _settings.get("ANTI_ALIASING_MODES"),
		"anti_aliasing", "set_anti_aliasing"))
	add_child(_dropdown_row("Ambient occlusion", SSAO_MODES,
		"ssao_override", "set_ssao_override", "Auto follows the selected quality preset.", 1))
	add_child(_toggle_row("Dynamic resolution", "dynamic_resolution", "set_dynamic_resolution",
		"Lowers 3D resolution during expensive scenes to protect the target frame rate."))

	if _allow_benchmark:
		add_child(_benchmark_row())

	add_child(MireTheme.separator())
	add_child(_heading("IMAGE"))
	var fov: HSlider = MireTheme.slider(
		float(_settings.get("MIN_FOV")), float(_settings.get("MAX_FOV")), 1.0)
	fov.value_changed.connect(func(value: float) -> void: _request("set_fov_degrees", value))
	_bind(fov, "fov_degrees")
	add_child(_slider_row("Field of view", fov, FocusRingSlider.Readout.DEGREES))
	var brightness: HSlider = MireTheme.slider(0.5, 1.5, 0.05)
	brightness.value_changed.connect(func(value: float) -> void: _request("set_brightness", value))
	_bind(brightness, "brightness")
	add_child(_slider_row("Brightness", brightness, FocusRingSlider.Readout.PERCENT,
		"Adjusts the final environment grade without changing gameplay lighting."))
	refresh()


## The one control on this page that measures instead of setting. It sits directly under the
## quality dropdowns because that is where a player is when they are guessing — every value above
## it is a guess about this machine, and this is the button that stops it being one.
func _benchmark_row() -> Control:
	var wrapper: VBoxContainer = MireTheme.column(MireTheme.GRID)
	var button: Button = MireTheme.button("RUN BENCHMARK",
		func() -> void: benchmark_requested.emit())
	wrapper.add_child(button)
	wrapper.add_child(MireTheme.label(
		"Measures this machine across the whole island — shore, forest, night, a wave — and "
		+ "recommends the settings it actually holds. Takes about two minutes.",
		MireTheme.CAPTION, MireTheme.MUTED))
	return wrapper


func _heading(text: String) -> Label:
	return MireTheme.label(text, MireTheme.CAPTION, MireTheme.MUTED)


func _dropdown_row(label_text: String, labels: Variant, getter: String, setter: String,
		hint: String = "", offset: int = 0) -> Control:
	var dropdown: OptionButton = MireTheme.dropdown()
	for label: String in labels:
		dropdown.add_item(label)
	dropdown.item_selected.connect(func(index: int) -> void: _request(setter, index - offset))
	_bind(dropdown, getter, offset)
	return _row(label_text, dropdown, hint)


func _value_dropdown_row(label_text: String, labels: Array[String], values: Variant,
		getter: String, setter: String) -> Control:
	var dropdown: OptionButton = MireTheme.dropdown()
	for label: String in labels:
		dropdown.add_item(label)
	dropdown.item_selected.connect(func(index: int) -> void: _request(setter, int(values[index])))
	_controls.append({&"control": dropdown, &"getter": getter, &"values": values})
	return _row(label_text, dropdown)


func _toggle_row(label_text: String, getter: String, setter: String, hint: String = "") -> Control:
	var toggle: CheckBox = MireTheme.toggle()
	toggle.toggled.connect(func(value: bool) -> void: _request(setter, value))
	_bind(toggle, getter)
	return _row(label_text, toggle, hint)


func _slider_row(label_text: String, slider: HSlider, readout: int, hint: String = "") -> Control:
	var holder: HBoxContainer = MireTheme.row()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_child(slider)
	var value_label: Label = MireTheme.label("", MireTheme.BODY, MireTheme.TEXT)
	holder.add_child(value_label)
	(slider as FocusRingSlider).bind_readout(value_label, readout, READOUT_WIDTH)
	return _row(label_text, holder, hint)


func _row(label_text: String, control: Control, hint: String = "") -> Control:
	var wrapper: VBoxContainer = MireTheme.column(MireTheme.GRID / 2)
	var row: HBoxContainer = MireTheme.row()
	wrapper.add_child(row)
	var label: Label = MireTheme.label(label_text, MireTheme.BODY, MireTheme.TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	control.custom_minimum_size.x = 300.0
	row.add_child(control)
	if not hint.is_empty():
		wrapper.add_child(MireTheme.label(hint, MireTheme.CAPTION, MireTheme.MUTED))
	return wrapper


func _bind(control: Control, getter: String, offset: int = 0) -> void:
	_controls.append({&"control": control, &"getter": getter, &"offset": offset})


func _request(setter: String, value: Variant) -> void:
	setting_requested.emit(setter, value)
