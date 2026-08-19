extends CanvasLayer

## UnlockMenu — task 6.9's UI half: browse every authored UnlockDef and spend Salvage on one.
## Register as autoload `UnlockMenu` → res://ui/menu/unlock_menu.gd, BEFORE `MainMenu` in
## `project.godot` (`MainMenu.request_open_unlocks()` opens this by node path, same "kept before
## it so the ordering reads the same way the panels nest" convention `SettingsMenu` already
## established for the same reason).
##
## Opened only from `MainMenu`'s UNLOCKS button — no keypress of its own, same shape `SettingsMenu`
## already uses (D-032: sub-panels hand off from the menu that owns the F1 hotkey, they don't grow
## a second one).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI, reading/spending only
## THIS peer's own SalvageService/UnlockService state, the same "Unlocks" row those two claim.

const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

const COLOUR_SCREEN_SHADE := Color(0.018, 0.035, 0.028, 0.78)
const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_FIELD := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_ACCENT := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)
const COLOUR_ERROR := Color(0.96, 0.47, 0.39, 1.0)
const COLOUR_OWNED := Color(0.56, 0.80, 0.60, 1.0)

var _root: Control
var _shade: ColorRect
var _center: CenterContainer
var _balance_label: Label
var _status_label: Label
var _rows_stack: VBoxContainer
var _close_button: Button

## unlock_id -> {"def": UnlockDef, "name_label": Label, "buy_button": Button}, built once from
## Registry at `_build_ui()` time (content is boot-time-static, D-073) and refreshed in place —
## `_refresh()` never rebuilds the row list, only the affordability/owned state of each row.
var _rows: Dictionary = {}

var _open: bool = false
var _restore_mouse_captured: bool = false


func _ready() -> void:
	layer = 56
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


# ── Public API (the check drives these; buttons call the same paths) ──────────────────────────────


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
		_refresh()
		_grab_initial_focus()
	else:
		remove_from_group(BLOCKING_UI_GROUP)
		_root.release_focus()
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_open() -> bool:
	return _open


func request_close() -> void:
	set_open(false)


## Spends Salvage on `unlock_id` through `UnlockService.purchase()` and refreshes every row's
## afford/owned state. Returns the same bool `UnlockService.purchase()` returned, so a check can
## assert on it directly without re-deriving success from label text.
func request_purchase(unlock_id: StringName) -> bool:
	var unlock_service: Node = get_node_or_null(^"/root/UnlockService")
	if unlock_service == null:
		return false
	var ok: bool = bool(unlock_service.call("purchase", unlock_id))
	if ok:
		var row: Dictionary = _rows.get(unlock_id, {})
		var display_name: String = String((row.get("def") as Resource).get(&"display_name")) if row.has("def") else String(unlock_id)
		_show_status("Purchased %s." % display_name, false)
	else:
		_show_status("Could not purchase — already owned, or not enough Salvage.", true)
	_refresh()
	return ok


func status_text() -> String:
	return _status_label.text


func balance_text() -> String:
	return _balance_label.text


func row_count() -> int:
	return _rows.size()


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


func _other_blocking_ui_open() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node != self:
			return true
	return false


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)


func _refresh() -> void:
	var salvage_service: Node = get_node_or_null(^"/root/SalvageService")
	var total: int = int(salvage_service.call("total_salvage")) if salvage_service != null else 0
	_balance_label.text = "SALVAGE: %d" % total

	var unlock_service: Node = get_node_or_null(^"/root/UnlockService")
	for unlock_id: StringName in _rows:
		var row: Dictionary = _rows[unlock_id]
		var def: Resource = row["def"]
		var cost: int = int(def.get(&"cost"))
		var owned: bool = unlock_service != null and bool(unlock_service.call("is_purchased", unlock_id))
		var buy_button: Button = row["buy_button"]
		if owned:
			buy_button.text = "OWNED"
			buy_button.disabled = true
		else:
			buy_button.text = "BUY %d" % cost
			buy_button.disabled = total < cost


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "UnlockMenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "UnlockMenuShade"
	_shade.color = COLOUR_SCREEN_SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_center = CenterContainer.new()
	_center.name = "UnlockMenuCenter"
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_center.visible = false
	_root.add_child(_center)

	var panel := PanelContainer.new()
	panel.name = "UnlockMenuPanel"
	panel.custom_minimum_size = Vector2(460.0, 0.0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	_center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	margin.add_child(stack)

	var title := Label.new()
	title.text = "UNLOCKS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOUR_TEXT)
	stack.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Salvage unlocks variety, never power (DESIGN.md §4.6)."
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(subtitle)

	_balance_label = Label.new()
	_balance_label.name = "Balance"
	_balance_label.text = "SALVAGE: 0"
	_balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_balance_label.add_theme_font_size_override("font_size", 14)
	_balance_label.add_theme_color_override("font_color", COLOUR_ACCENT)
	stack.add_child(_balance_label)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.text = ""
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_status_label)

	stack.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.name = "UnlockScroll"
	scroll.custom_minimum_size = Vector2(0.0, 220.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stack.add_child(scroll)

	_rows_stack = VBoxContainer.new()
	_rows_stack.name = "UnlockRows"
	_rows_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_stack.add_theme_constant_override("separation", 8)
	scroll.add_child(_rows_stack)

	_build_rows()

	stack.add_child(HSeparator.new())

	_close_button = Button.new()
	_close_button.text = "CLOSE"
	_close_button.add_theme_color_override("font_color", COLOUR_TEXT)
	_close_button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
	_close_button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	_close_button.add_theme_stylebox_override("pressed", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
	_close_button.add_theme_stylebox_override("focus", _focus_style())
	_close_button.pressed.connect(request_close)
	stack.add_child(_close_button)

	# F-209: chain every BUY button plus CLOSE, in row order, wrapping top<->bottom.
	var chain: Array = []
	for unlock_id: StringName in _rows:
		chain.append((_rows[unlock_id] as Dictionary)["buy_button"])
	chain.append(_close_button)
	_wire_vertical_chain(chain)

	var close_hint := Label.new()
	close_hint.text = "ESC  CLOSE"
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_hint.add_theme_font_size_override("font_size", 10)
	close_hint.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(close_hint)


## Content is boot-time-static (D-073), so the row list is built once here, sorted by id for a
## deterministic, reproducible-in-a-check order — `Registry.unlock_defs()` is a plain Dictionary
## and iteration order is not itself a contract worth depending on.
func _build_rows() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("unlock_defs"):
		return
	var defs: Dictionary = registry.call("unlock_defs")
	var ids: Array = defs.keys()
	ids.sort_custom(func(a, b): return String(a) < String(b))
	for unlock_id: StringName in ids:
		var def: Resource = defs[unlock_id]
		var row := HBoxContainer.new()
		row.name = "Row_%s" % unlock_id
		row.add_theme_constant_override("separation", 8)
		_rows_stack.add_child(row)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)

		var name_label := Label.new()
		name_label.text = "%s  [%s]" % [String(def.get(&"display_name")), String(def.get(&"category"))]
		name_label.add_theme_font_size_override("font_size", 13)
		name_label.add_theme_color_override("font_color", COLOUR_TEXT)
		info.add_child(name_label)

		var desc_label := Label.new()
		desc_label.text = String(def.get(&"description"))
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_label.add_theme_font_size_override("font_size", 10)
		desc_label.add_theme_color_override("font_color", COLOUR_MUTED)
		info.add_child(desc_label)

		var buy_button := Button.new()
		buy_button.custom_minimum_size = Vector2(90.0, 0.0)
		buy_button.add_theme_color_override("font_color", COLOUR_TEXT)
		buy_button.add_theme_color_override("font_disabled_color", COLOUR_OWNED)
		buy_button.add_theme_stylebox_override("normal", _field_style(COLOUR_FIELD, COLOUR_BORDER))
		buy_button.add_theme_stylebox_override("hover", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
		buy_button.add_theme_stylebox_override("pressed", _field_style(COLOUR_FIELD, COLOUR_ACCENT))
		buy_button.add_theme_stylebox_override("focus", _focus_style())
		buy_button.pressed.connect(func() -> void: request_purchase(unlock_id))
		row.add_child(buy_button)

		_rows[unlock_id] = {"def": def, "name_label": name_label, "buy_button": buy_button}


## First BUY button — a disabled one (owned, or unaffordable) still takes and keeps focus like any
## other Button, it just no-ops on ui_accept/click until it becomes enabled — or CLOSE if somehow no
## unlocks are registered.
func _grab_initial_focus() -> void:
	for unlock_id: StringName in _rows:
		(_rows[unlock_id] as Dictionary)["buy_button"].grab_focus()
		return
	_close_button.grab_focus()


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
