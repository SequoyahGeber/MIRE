extends CanvasLayer

## Client-local build-mode presentation (F-086 — 3.6 shipped BuildService/BuildGhost/PlacementValidator
## with no way for a player to reach any of it). Built directly by
## entities/player/player_controller.gd for the local player only, the same way it builds its
## Viewmodel and debug avatar — NOT an autoload like ui/crafting/crafting_ui.gd or
## ui/inventory/inventory_ui.gd. Two reasons: nobody needs to see another player's piece picker
## (client-local presentation, §2.2 last row, same as the ghost it sits beside), and `project.godot`
## is held by another lane's task (F-095) as this ships — this follows ui/hud/vitals_hud.gd's own
## EAT_KEY precedent of avoiding that file entirely rather than waiting on it. No new InputMap action
## either: piece rotate (R) and destroy (right-click) are raw input handled in
## player_controller.gd itself, not here — this bar is selection and status display only. Toggling
## build mode (the existing "build" InputMap action) is also read in player_controller.gd, so this
## bar and the player's build-mode state can never disagree about whether the mode is on; the player
## pushes state into this bar (`set_active`, `set_selected_piece`, `set_ghost_status`) rather than
## this bar polling for it.
##
## NETWORK AUTHORITY: none (§2.2 last row). A slot click only emits `piece_selected` — the player
## decides whether/how to act on it, and BuildService remains the only thing that ever actually
## places or destroys anything.

const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_ROW := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_READY := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)
const COLOUR_ERROR := Color(0.96, 0.47, 0.39, 1.0)


## One registered buildable. Selecting never places anything — it only tells the player which piece
## the ghost should preview.
class PieceSlot extends PanelContainer:
	var piece_id: StringName = &""
	var select_requested: Callable

	var _label: Label
	var _icon: TextureRect
	var _base_style: StyleBoxFlat
	var _selected_style: StyleBoxFlat


	func setup(def: Resource, select_callback: Callable) -> void:
		piece_id = StringName(String(def.get(&"id")))
		select_requested = select_callback
		name = "BuildSlot_%s" % String(piece_id)
		custom_minimum_size = Vector2(88.0, 56.0)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		focus_mode = Control.FOCUS_ALL
		_build_contents(def)
		_build_styles()


	func present(selected: bool) -> void:
		add_theme_stylebox_override("panel", _selected_style if selected else _base_style)


	func _build_contents(def: Resource) -> void:
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 6)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_right", 6)
		margin.add_theme_constant_override("margin_bottom", 4)
		add_child(margin)

		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 2)
		margin.add_child(stack)

		_icon = TextureRect.new()
		_icon.custom_minimum_size = Vector2(0.0, 22.0)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.texture = def.get(&"icon")
		_icon.visible = _icon.texture != null
		stack.add_child(_icon)

		var display_name: String = String(def.get(&"display_name"))
		if display_name.is_empty():
			display_name = String(piece_id)

		_label = Label.new()
		_label.text = display_name
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_label.add_theme_font_size_override("font_size", 12)
		_label.add_theme_color_override("font_color", COLOUR_TEXT)
		stack.add_child(_label)

		var cost_label := Label.new()
		cost_label.text = _cost_text(def.get(&"cost"))
		cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost_label.add_theme_font_size_override("font_size", 10)
		cost_label.add_theme_color_override("font_color", COLOUR_MUTED)
		stack.add_child(cost_label)

		var description: String = String(def.get(&"description"))
		tooltip_text = "%s\n%s" % [display_name, description] if not description.is_empty() \
			else display_name
		accessibility_name = "%s build slot" % display_name


	func _cost_text(cost: Dictionary) -> String:
		if cost.is_empty():
			return "free"
		var parts: PackedStringArray = PackedStringArray()
		for item_id: StringName in cost:
			parts.append("%d %s" % [int(cost[item_id]), String(item_id)])
		return "  ·  ".join(parts)


	func _build_styles() -> void:
		_base_style = _slot_style(COLOUR_BORDER, 1)
		_selected_style = _slot_style(COLOUR_READY, 3)
		add_theme_stylebox_override("panel", _base_style)


	func _slot_style(border: Color, border_width: int) -> StyleBoxFlat:
		var style := StyleBoxFlat.new()
		style.bg_color = COLOUR_ROW
		style.border_color = border
		style.set_border_width_all(border_width)
		style.set_corner_radius_all(6)
		return style


	func _gui_input(event: InputEvent) -> void:
		if (
			event is InputEventMouseButton
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
			and (event as InputEventMouseButton).pressed
		):
			select_requested.call(piece_id)


## Emitted on a slot click. The player decides what to do with it (player_controller.gd's
## set_selected_build_piece()) — this file never touches BuildGhost or BuildService directly.
signal piece_selected(piece_id: StringName)

var _root: Control
var _bar_center: CenterContainer
var _panel: PanelContainer
var _row: HBoxContainer
var _hint_label: Label
var _status_label: Label
var _slots: Array[PieceSlot] = []
var _selected_piece_id: StringName = &""


func _ready() -> void:
	layer = 41
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_populate_slots()
	var service: Node = get_node_or_null(^"/root/BuildService")
	if service != null:
		service.connect(&"build_confirmed", _on_build_confirmed)


func _exit_tree() -> void:
	var service: Node = get_node_or_null(^"/root/BuildService")
	if service != null and service.is_connected(&"build_confirmed", _on_build_confirmed):
		service.disconnect(&"build_confirmed", _on_build_confirmed)


## The player calls this on entering/leaving build mode. Never decided here.
func set_active(active: bool) -> void:
	_bar_center.visible = active
	if active:
		_show_status("R rotate  ·  click place  ·  right-click destroy", false)


func set_selected_piece(piece_id: StringName) -> void:
	_selected_piece_id = piece_id
	for slot: PieceSlot in _slots:
		slot.present(slot.piece_id == piece_id)


## Fed every physics tick the player is in build mode, straight from BuildGhost's own
## is_valid()/last_reason_text() — this file never re-derives a verdict of its own.
func set_ghost_status(valid: bool, reason_text: String) -> void:
	if reason_text.is_empty():
		return
	_hint_label.text = reason_text
	_hint_label.add_theme_color_override("font_color", COLOUR_MUTED if valid else COLOUR_ERROR)


func is_active() -> bool:
	return _bar_center.visible


func slot_count() -> int:
	return _slots.size()


func slot_piece_id(index: int) -> StringName:
	return _slots[index].piece_id if index >= 0 and index < _slots.size() else &""


## Presses the slot exactly as a click would, so a check exercises the real seam.
func select_slot(index: int) -> void:
	if index < 0 or index >= _slots.size():
		return
	piece_selected.emit(_slots[index].piece_id)


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BuildBarRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_bar_center = CenterContainer.new()
	_bar_center.name = "BuildBarCenter"
	_bar_center.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_bar_center.offset_top = -172.0
	_bar_center.offset_bottom = -96.0
	_bar_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_bar_center.visible = false
	_root.add_child(_bar_center)

	_panel = PanelContainer.new()
	_panel.name = "BuildBarPanel"
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_bar_center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 4)
	margin.add_child(stack)

	_row = HBoxContainer.new()
	_row.name = "BuildSlots"
	_row.add_theme_constant_override("separation", 4)
	stack.add_child(_row)

	_hint_label = Label.new()
	_hint_label.name = "GhostHint"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_hint_label)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_status_label)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	return style


## Registry.buildables loads once at boot and never changes at runtime (task 3.7 authors more .tres
## files, it does not hot-reload them), so slots are built once here rather than rebuilt on a poll —
## unlike CraftingUI's rows, which change with whichever station is nearby.
func _populate_slots() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return
	var buildables: Dictionary = registry.get(&"buildables")
	for id: StringName in buildables:
		var def: Resource = buildables[id]
		var slot := PieceSlot.new()
		slot.setup(def, _on_slot_pressed)
		_slots.append(slot)
		_row.add_child(slot)


func _on_slot_pressed(piece_id: StringName) -> void:
	piece_selected.emit(piece_id)


## Fires for both a place and a destroy request (BuildService.build_confirmed carries no "kind"), so
## the accepted message stays generic rather than claiming "placed" for what might be a destroy.
func _on_build_confirmed(_request_id: int, accepted: bool, reason: String) -> void:
	if accepted:
		_show_status("done" if reason.is_empty() else reason, false)
	else:
		_show_status(reason if not reason.is_empty() else "refused", true)


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)
