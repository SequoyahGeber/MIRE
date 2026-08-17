extends CanvasLayer

## Client-local inventory presentation. The host remains the only inventory authority: this UI
## renders duplicated InventoryService snapshots and turns every drag/drop into a move request.
## It never mutates a slot dictionary or predicts the result of a request.

const SLOT_COUNT: int = 24
const HOTBAR_SLOT_COUNT: int = 8
const DESKTOP_INVENTORY_COLUMNS: int = 8
const NARROW_INVENTORY_COLUMNS: int = 6
const NARROW_BREAKPOINT_PX: float = 700.0
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

const COLOUR_SCREEN_SHADE := Color(0.018, 0.035, 0.028, 0.78)
const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_SLOT := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_SLOT_HOVER := Color(0.115, 0.170, 0.137, 1.0)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_SELECTED := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)
const COLOUR_ERROR := Color(0.96, 0.47, 0.39, 1.0)


class InventorySlot extends PanelContainer:
	var slot_index: int = -1
	var hotbar_copy: bool = false
	var item_id: StringName = &""
	var amount: int = 0
	var move_requested: Callable
	var selected_requested: Callable

	var _key_label: Label
	var _icon: TextureRect
	var _item_label: Label
	var _amount_label: Label
	var _base_style: StyleBoxFlat
	var _hover_style: StyleBoxFlat
	var _selected_style: StyleBoxFlat
	var _selected: bool = false


	func setup(index: int, is_hotbar_copy: bool, move_callback: Callable, select_callback: Callable) -> void:
		slot_index = index
		hotbar_copy = is_hotbar_copy
		move_requested = move_callback
		selected_requested = select_callback
		name = ("HotbarSlot%d" if hotbar_copy else "InventorySlot%d") % index
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		focus_mode = Control.FOCUS_ALL
		_build_contents()
		_build_styles()


	func present(slot: Dictionary, item: ItemDef, selected: bool) -> void:
		_selected = selected
		item_id = StringName(String(slot.get("item_id", "")))
		amount = int(slot.get("amount", 0))
		set_meta(&"item_id", item_id)
		set_meta(&"amount", amount)

		if item_id == &"" or amount <= 0:
			_icon.texture = null
			_icon.visible = false
			_item_label.visible = true
			_item_label.text = ""
			_amount_label.text = ""
			tooltip_text = "Empty slot"
		else:
			var display_name: String = item.display_name if item != null else String(item_id)
			_icon.texture = item.icon if item != null else null
			_icon.visible = _icon.texture != null
			_item_label.visible = not _icon.visible
			_item_label.text = _compact_name(display_name)
			_amount_label.text = str(amount) if amount > 1 else ""
			tooltip_text = "%s\n%s" % [
				display_name,
				item.description if item != null and not item.description.is_empty() else String(item_id),
			]

		add_theme_stylebox_override("panel", _selected_style if selected else _base_style)
		accessibility_name = "%s, slot %d" % [tooltip_text.replace("\n", ", "), slot_index + 1]


	func set_slot_size(size_px: float) -> void:
		custom_minimum_size = Vector2(size_px, size_px)
		var compact: bool = size_px < 50.0
		_item_label.add_theme_font_size_override("font_size", 11 if compact else 12)
		_amount_label.add_theme_font_size_override("font_size", 11 if compact else 13)
		_key_label.add_theme_font_size_override("font_size", 10 if compact else 11)


	func _get_drag_data(_at_position: Vector2) -> Variant:
		if item_id == &"" or amount <= 0:
			return null
		var preview := PanelContainer.new()
		preview.custom_minimum_size = Vector2(72.0, 48.0)
		preview.add_theme_stylebox_override("panel", _selected_style)
		var preview_label := Label.new()
		preview_label.text = "%s  ×%d" % [_item_label.text, amount]
		preview_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		preview_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		preview_label.add_theme_color_override("font_color", COLOUR_TEXT)
		preview.add_child(preview_label)
		set_drag_preview(preview)
		return {
			"kind": &"inventory_slot",
			"from_index": slot_index,
			"item_id": item_id,
		}


	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return (
			data is Dictionary
			and StringName(String((data as Dictionary).get("kind", ""))) == &"inventory_slot"
			and int((data as Dictionary).get("from_index", -1)) != slot_index
		)


	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if not _can_drop_data(_at_position, data):
			return
		move_requested.call(int((data as Dictionary).get("from_index", -1)), slot_index)


	func _gui_input(event: InputEvent) -> void:
		if (
			hotbar_copy
			and event is InputEventMouseButton
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
			and (event as InputEventMouseButton).pressed
		):
			selected_requested.call(slot_index)


	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER and not _selected:
			add_theme_stylebox_override("panel", _hover_style)
		elif what == NOTIFICATION_MOUSE_EXIT:
			add_theme_stylebox_override("panel", _selected_style if _selected else _base_style)


	func _build_contents() -> void:
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 5)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_right", 5)
		margin.add_theme_constant_override("margin_bottom", 4)
		add_child(margin)

		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 0)
		margin.add_child(stack)

		_key_label = Label.new()
		_key_label.text = str(slot_index + 1) if hotbar_copy else ""
		_key_label.add_theme_color_override("font_color", COLOUR_MUTED)
		stack.add_child(_key_label)

		var item_center := CenterContainer.new()
		item_center.custom_minimum_size = Vector2(0.0, 24.0)
		item_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
		stack.add_child(item_center)

		_icon = TextureRect.new()
		_icon.custom_minimum_size = Vector2(26.0, 26.0)
		_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		item_center.add_child(_icon)

		_item_label = Label.new()
		_item_label.custom_minimum_size = Vector2(34.0, 20.0)
		_item_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_item_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_item_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_item_label.add_theme_color_override("font_color", COLOUR_TEXT)
		item_center.add_child(_item_label)

		_amount_label = Label.new()
		_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_amount_label.add_theme_color_override("font_color", COLOUR_TEXT)
		stack.add_child(_amount_label)


	func _build_styles() -> void:
		_base_style = _slot_style(COLOUR_SLOT, COLOUR_BORDER, 1)
		_hover_style = _slot_style(COLOUR_SLOT_HOVER, COLOUR_SELECTED, 1)
		_selected_style = _slot_style(COLOUR_SLOT, COLOUR_SELECTED, 3)
		add_theme_stylebox_override("panel", _base_style)


	func _slot_style(fill: Color, border: Color, border_width: int) -> StyleBoxFlat:
		var style := StyleBoxFlat.new()
		style.bg_color = fill
		style.border_color = border
		style.set_border_width_all(border_width)
		style.set_corner_radius_all(5)
		return style


	func _compact_name(display_name: String) -> String:
		var words: PackedStringArray = display_name.split(" ", false)
		if words.size() <= 1:
			return display_name.left(5)
		var initials: String = ""
		for word: String in words:
			initials += word.left(1).to_upper()
		return initials.left(4)


var _root: Control
var _shade: ColorRect
var _inventory_center: CenterContainer
var _inventory_panel: PanelContainer
var _inventory_grid: GridContainer
var _hotbar_center: CenterContainer
var _status_label: Label
var _inventory_slots: Array[InventorySlot] = []
var _hotbar_slots: Array[InventorySlot] = []
var _snapshot: Array[Dictionary] = []
var _inventory_open: bool = false
var _selected_hotbar_index: int = 0
var _restore_mouse_captured: bool = false


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	InventoryService.local_inventory_changed.connect(_on_inventory_changed)
	InventoryService.operation_confirmed.connect(_on_operation_confirmed)
	_on_inventory_changed(InventoryService.local_slots(), InventoryService.local_revision())
	get_viewport().size_changed.connect(_apply_responsive_layout)
	_apply_responsive_layout()


func _exit_tree() -> void:
	if InventoryService.local_inventory_changed.is_connected(_on_inventory_changed):
		InventoryService.local_inventory_changed.disconnect(_on_inventory_changed)
	if InventoryService.operation_confirmed.is_connected(_on_operation_confirmed):
		InventoryService.operation_confirmed.disconnect(_on_operation_confirmed)


func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if event.is_action_pressed(&"inventory"):
		var focus_owner: Control = get_viewport().gui_get_focus_owner()
		if focus_owner == null or not (focus_owner is LineEdit or focus_owner is TextEdit):
			set_open(not _inventory_open)
			get_viewport().set_input_as_handled()
		return
	if _inventory_open and event.is_action_pressed(&"ui_cancel"):
		set_open(false)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		var key: InputEventKey = event
		var focus_owner: Control = get_viewport().gui_get_focus_owner()
		var text_input_focused: bool = focus_owner is LineEdit or focus_owner is TextEdit
		if not text_input_focused and key.keycode >= KEY_1 and key.keycode <= KEY_8:
			select_hotbar_slot(int(key.keycode - KEY_1))


func set_open(open: bool) -> void:
	if open == _inventory_open:
		return
	_inventory_open = open
	_shade.visible = open
	_inventory_center.visible = open
	if open:
		add_to_group(BLOCKING_UI_GROUP)
		_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_status_label.text = "Drag a stack onto another slot to move or merge it."
	else:
		remove_from_group(BLOCKING_UI_GROUP)
		_root.release_focus()
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_inventory_open() -> bool:
	return _inventory_open


func select_hotbar_slot(index: int) -> void:
	_selected_hotbar_index = clampi(index, 0, HOTBAR_SLOT_COUNT - 1)
	_refresh_slots()


func selected_hotbar_slot() -> int:
	return _selected_hotbar_index


func request_slot_move(from_index: int, to_index: int, amount: int = 0) -> int:
	if from_index < 0 or from_index >= SLOT_COUNT or to_index < 0 or to_index >= SLOT_COUNT:
		_show_status("That slot move is out of range.", true)
		return -1
	if from_index == to_index:
		return -1
	_show_status("Moving stack…", false)
	return InventoryService.request_move_stack(from_index, to_index, amount)


func inventory_slot_view_count() -> int:
	return _inventory_slots.size()


func hotbar_slot_view_count() -> int:
	return _hotbar_slots.size()


func displayed_item_id(index: int, hotbar: bool = false) -> StringName:
	var views: Array[InventorySlot] = _hotbar_slots if hotbar else _inventory_slots
	if index < 0 or index >= views.size():
		return &""
	return views[index].item_id


func displayed_amount(index: int, hotbar: bool = false) -> int:
	var views: Array[InventorySlot] = _hotbar_slots if hotbar else _inventory_slots
	if index < 0 or index >= views.size():
		return 0
	return views[index].amount


func hotbar_slot_size() -> Vector2:
	return _hotbar_slots[0].custom_minimum_size if not _hotbar_slots.is_empty() else Vector2.ZERO


func inventory_columns() -> int:
	return _inventory_grid.columns


func status_text() -> String:
	return _status_label.text


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "InventoryUIRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.name = "InventoryShade"
	_shade.color = COLOUR_SCREEN_SHADE
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.visible = false
	_root.add_child(_shade)

	_inventory_center = CenterContainer.new()
	_inventory_center.name = "InventoryCenter"
	_inventory_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_inventory_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_inventory_center.visible = false
	_root.add_child(_inventory_center)

	_inventory_panel = PanelContainer.new()
	_inventory_panel.name = "InventoryPanel"
	_inventory_panel.add_theme_stylebox_override("panel", _panel_style())
	_inventory_center.add_child(_inventory_panel)

	var inventory_margin := MarginContainer.new()
	inventory_margin.add_theme_constant_override("margin_left", 18)
	inventory_margin.add_theme_constant_override("margin_top", 16)
	inventory_margin.add_theme_constant_override("margin_right", 18)
	inventory_margin.add_theme_constant_override("margin_bottom", 16)
	_inventory_panel.add_child(inventory_margin)

	var inventory_stack := VBoxContainer.new()
	inventory_stack.add_theme_constant_override("separation", 10)
	inventory_margin.add_child(inventory_stack)

	var title := Label.new()
	title.text = "FIELD PACK"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOUR_TEXT)
	inventory_stack.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "24 SLOTS  ·  FIRST 8 FEED THE HOTBAR"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", COLOUR_MUTED)
	inventory_stack.add_child(subtitle)

	_inventory_grid = GridContainer.new()
	_inventory_grid.name = "InventoryGrid"
	_inventory_grid.columns = DESKTOP_INVENTORY_COLUMNS
	_inventory_grid.add_theme_constant_override("h_separation", 6)
	_inventory_grid.add_theme_constant_override("v_separation", 6)
	inventory_stack.add_child(_inventory_grid)

	for index: int in SLOT_COUNT:
		var slot := InventorySlot.new()
		slot.setup(index, false, _on_move_requested, _on_hotbar_selected)
		_inventory_slots.append(slot)
		_inventory_grid.add_child(slot)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.text = "Drag a stack onto another slot to move or merge it."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	inventory_stack.add_child(_status_label)

	var close_hint := Label.new()
	close_hint.text = "TAB / ESC  CLOSE"
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_hint.add_theme_font_size_override("font_size", 10)
	close_hint.add_theme_color_override("font_color", COLOUR_MUTED)
	inventory_stack.add_child(close_hint)

	_hotbar_center = CenterContainer.new()
	_hotbar_center.name = "HotbarCenter"
	_hotbar_center.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hotbar_center.offset_top = -92.0
	_hotbar_center.offset_bottom = -12.0
	_hotbar_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hotbar_center)

	var hotbar_panel := PanelContainer.new()
	hotbar_panel.name = "HotbarPanel"
	hotbar_panel.add_theme_stylebox_override("panel", _panel_style())
	_hotbar_center.add_child(hotbar_panel)

	var hotbar_margin := MarginContainer.new()
	hotbar_margin.add_theme_constant_override("margin_left", 6)
	hotbar_margin.add_theme_constant_override("margin_top", 6)
	hotbar_margin.add_theme_constant_override("margin_right", 6)
	hotbar_margin.add_theme_constant_override("margin_bottom", 6)
	hotbar_panel.add_child(hotbar_margin)

	var hotbar_row := HBoxContainer.new()
	hotbar_row.name = "HotbarSlots"
	hotbar_row.add_theme_constant_override("separation", 4)
	hotbar_margin.add_child(hotbar_row)

	for index: int in HOTBAR_SLOT_COUNT:
		var slot := InventorySlot.new()
		slot.setup(index, true, _on_move_requested, _on_hotbar_selected)
		_hotbar_slots.append(slot)
		hotbar_row.add_child(slot)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	return style


func _on_inventory_changed(slots: Array[Dictionary], _revision: int) -> void:
	_snapshot.clear()
	for slot: Dictionary in slots:
		_snapshot.append(slot.duplicate())
	_refresh_slots()


func _refresh_slots() -> void:
	for index: int in _inventory_slots.size():
		var slot: Dictionary = _snapshot[index] if index < _snapshot.size() else {}
		_inventory_slots[index].present(slot, _item_for(slot), false)
	for index: int in _hotbar_slots.size():
		var slot: Dictionary = _snapshot[index] if index < _snapshot.size() else {}
		_hotbar_slots[index].present(slot, _item_for(slot), index == _selected_hotbar_index)


func _item_for(slot: Dictionary) -> ItemDef:
	var item_id := StringName(String(slot.get("item_id", "")))
	return Registry.get_item(item_id) if item_id != &"" else null


func _on_move_requested(from_index: int, to_index: int) -> void:
	request_slot_move(from_index, to_index)


func _on_hotbar_selected(index: int) -> void:
	select_hotbar_slot(index)


func _on_operation_confirmed(_request_id: int, accepted: bool, detail: String) -> void:
	_show_status(detail, not accepted)


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)


func _apply_responsive_layout() -> void:
	if _inventory_grid == null:
		return
	_apply_layout_for_width(get_viewport().get_visible_rect().size.x)


func _apply_layout_for_width(viewport_width: float) -> void:
	var narrow: bool = viewport_width < NARROW_BREAKPOINT_PX
	_inventory_grid.columns = NARROW_INVENTORY_COLUMNS if narrow else DESKTOP_INVENTORY_COLUMNS
	var inventory_slot_px: float = 48.0 if narrow else 66.0
	for slot: InventorySlot in _inventory_slots:
		slot.set_slot_size(inventory_slot_px)

	var available_hotbar_width: float = maxf(320.0, viewport_width - 16.0)
	var hotbar_slot_px: float = clampf((available_hotbar_width - 54.0) / HOTBAR_SLOT_COUNT, 38.0, 62.0)
	for slot: InventorySlot in _hotbar_slots:
		slot.set_slot_size(hotbar_slot_px)
